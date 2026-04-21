/// 流式压缩器状态。
///
/// 这是当前仓库的最小可用流式压缩实现：
/// - 支持 `write_chunk / flush / finish / reset`
/// - 支持分块持续产出完整 ZSTD 帧字节流
/// - 支持可选 checksum 尾部写出
/// - 支持基于同帧历史窗口的跨 chunk LZ77 匹配继承
///
/// 设计目标是先补齐“真正可用的流式帧写出能力”，
/// 而不是一次性重构整套编码器为完全增量式状态机。
pub struct StreamingCompressor {
  config: CompressionConfig
  with_checksum: Bool
  mut pending: Array[Byte]
  mut history_window: Array[Byte]
  mut header_written: Bool
  mut finished: Bool
  mut total_input_size: Int
  mut total_output_size: Int
  mut emitted_block_count: Int
  mut raw_block_count: Int
  mut rle_block_count: Int
  mut compressed_block_count: Int
  mut flush_count: Int
  mut auto_flush_count: Int
  mut checksum_state: UInt
  mut final_checksum: UInt
}

/// 流式压缩统计快照。
///
/// 用途：
/// - 对外暴露当前流式会话的输入/输出统计
/// - 记录块类型分布
/// - 提供 checksum 和历史窗口状态
pub struct StreamingCompressionStats {
  total_input_size: Int
  total_output_size: Int
  emitted_block_count: Int
  raw_block_count: Int
  rle_block_count: Int
  compressed_block_count: Int
  flush_count: Int
  auto_flush_count: Int
  pending_size: Int
  history_size: Int
  window_size: Int
  checksum_enabled: Bool
  current_checksum: UInt
  final_checksum: UInt
  header_written: Bool
  finished: Bool
}

/// 创建流式压缩器。
///
/// 说明：
/// - 该对象会把输入分块写成同一个 ZSTD 帧
/// - 帧头使用非 `single_segment` 形式，不预写 `Frame_Content_Size`
/// - 这样可以在不知道总输入长度时也能边写边产出字节流
pub fn new_streaming_compressor(config: CompressionConfig, with_checksum: Bool) -> StreamingCompressor {
  // 第 1 步：写入配置与开关。
  // 这些值在整个流式生命周期内保持稳定。

  // 第 2 步：初始化所有运行态字段。
  // 包括 pending、history、统计计数、checksum 状态等。

  // 第 3 步：返回一个尚未写出帧头、尚未接收任何输入的干净状态机。
  StreamingCompressor::{
    config,
    with_checksum,
    pending: [],
    history_window: [],
    header_written: false,
    finished: false,
    total_input_size: 0,
    total_output_size: 0,
    emitted_block_count: 0,
    raw_block_count: 0,
    rle_block_count: 0,
    compressed_block_count: 0,
    flush_count: 0,
    auto_flush_count: 0,
    checksum_state: checksum_seed,
    final_checksum: 0U,
  }
}

/// 追加字节到输出数组。
fn append_bytes_to_output(output: Array[Byte], data: Bytes) -> Unit {
  for i = 0; i < data.length(); i = i + 1 {
    output.push(data[i])
  }
}

/// 把字节数组复制成 `Bytes`。
fn bytes_from_byte_array(data: Array[Byte]) -> Bytes {
  let copied: Array[Byte] = []
  for i = 0; i < data.length(); i = i + 1 {
    copied.push(data[i])
  }
  Bytes::from_array(copied)
}

/// 增量更新 checksum。
///
/// 这里复用与 `calculate_checksum` 相同的按字节更新逻辑，
/// 这样可以在流式写入时逐块累计，最终结果与一次性计算保持一致。
fn update_checksum_state(current: UInt, data: Bytes) -> UInt {
  let mut hash = current

  // 按字节滚动更新哈希。
  // 这样无论输入被拆成多少个 chunk，最终 checksum 都保持一致。
  for i = 0; i < data.length(); i = i + 1 {
    hash = hash + data[i].to_uint()
    hash = hash * 0x85EBCA77U
    hash = hash ^ (hash >> 13)
  }
  hash
}

/// 写出流式帧头。
///
/// 当前实现使用：
/// - 普通 ZSTD 帧
/// - 非 `single_segment`
/// - 不预写 `Frame_Content_Size`
/// - 根据配置写入 `Window_Descriptor`
fn write_streaming_frame_header(output: Array[Byte], config: CompressionConfig, with_checksum: Bool) -> Unit {
  // 第 1 步：写入固定魔数。
  write_zstd_magic(output)

  // 第 2 步：构造 Frame Header Descriptor。
  // 当前只控制 checksum 标志，其他位保持最小必要集合。
  let checksum_flag = if with_checksum { 0x04 } else { 0x00 }
  output.push(checksum_flag.to_byte())

  // 第 3 步：写入 Window Descriptor。
  // 这里固定使用 mantissa=0，让窗口表达尽量简单直接。
  let clamped_window_log = config.window_log.max(10).min(41)
  let exponent = clamped_window_log - 10
  output.push((exponent << 3).to_byte())
}

/// 确保流式帧头仅写出一次。
fn ensure_streaming_header(compressor: StreamingCompressor, output: Array[Byte]) -> Unit {
  // 只有首次真正产出字节时才写帧头，避免空写或重复写头。
  if !compressor.header_written {
    write_streaming_frame_header(output, compressor.config, compressor.with_checksum)
    compressor.header_written = true
  }
}

/// 记录本次新增输出字节数。
fn record_streaming_output(compressor: StreamingCompressor, output: Array[Byte]) -> Unit {
  compressor.total_output_size = compressor.total_output_size + output.length()
}

/// 把刚刚写出的原始数据加入历史窗口。
///
/// 这里保存的是“解压后的真实历史字节”，供后续块做跨 chunk 匹配。
/// 窗口长度受 `window_log` 控制，只保留尾部窗口范围内的数据。
fn append_to_streaming_history(compressor: StreamingCompressor, data: Bytes) -> Unit {
  // 第 1 步：把刚刚确认写出的原始数据追加到历史窗口末尾。
  for i = 0; i < data.length(); i = i + 1 {
    compressor.history_window.push(data[i])
  }

  // 第 2 步：如果历史超过窗口上限，只保留尾部窗口范围。
  // 这样后续生成 offset 时不会超出协议允许的回溯距离。
  let max_history = 1 << compressor.config.window_log
  if compressor.history_window.length() > max_history {
    let trimmed: Array[Byte] = []
    let start = compressor.history_window.length() - max_history
    for i = start; i < compressor.history_window.length(); i = i + 1 {
      trimmed.push(compressor.history_window[i])
    }
    compressor.history_window = trimmed
  }
}

/// 生成流式压缩统计快照。
pub fn get_streaming_compression_stats(compressor: StreamingCompressor) -> StreamingCompressionStats {
  StreamingCompressionStats::{
    total_input_size: compressor.total_input_size,
    total_output_size: compressor.total_output_size,
    emitted_block_count: compressor.emitted_block_count,
    raw_block_count: compressor.raw_block_count,
    rle_block_count: compressor.rle_block_count,
    compressed_block_count: compressor.compressed_block_count,
    flush_count: compressor.flush_count,
    auto_flush_count: compressor.auto_flush_count,
    pending_size: compressor.pending.length(),
    history_size: compressor.history_window.length(),
    window_size: 1 << compressor.config.window_log,
    checksum_enabled: compressor.with_checksum,
    current_checksum: if compressor.with_checksum { compressor.checksum_state } else { 0U },
    final_checksum: if compressor.with_checksum { compressor.final_checksum } else { 0U },
    header_written: compressor.header_written,
    finished: compressor.finished,
  }
}

/// 格式化流式压缩统计信息。
pub fn format_streaming_compression_stats(stats: StreamingCompressionStats) -> String {
  "流式压缩统计:\n" +
  "  输入字节: " + stats.total_input_size.to_string() + "\n" +
  "  输出字节: " + stats.total_output_size.to_string() + "\n" +
  "  已发块数: " + stats.emitted_block_count.to_string() +
  " (raw=" + stats.raw_block_count.to_string() +
  ", rle=" + stats.rle_block_count.to_string() +
  ", compressed=" + stats.compressed_block_count.to_string() + ")\n" +
  "  flush 次数: " + stats.flush_count.to_string() +
  " (自动=" + stats.auto_flush_count.to_string() + ")\n" +
  "  pending 字节: " + stats.pending_size.to_string() + "\n" +
  "  历史窗口字节: " + stats.history_size.to_string() + "/" + stats.window_size.to_string() + "\n" +
  "  checksum 开启: " + (if stats.checksum_enabled { "是" } else { "否" }) + "\n" +
  "  当前 checksum: " + stats.current_checksum.to_string() + "\n" +
  "  最终 checksum: " + stats.final_checksum.to_string() + "\n" +
  "  帧头已写: " + (if stats.header_written { "是" } else { "否" }) + "\n" +
  "  已完成: " + (if stats.finished { "是" } else { "否" })
}

/// 从 pending 中取出前缀数据，并把剩余数据保留在状态里。
fn take_pending_prefix(compressor: StreamingCompressor, size: Int) -> Bytes {
  // 第 1 步：计算本次真正能取出的字节数。
  let actual_size = size.min(compressor.pending.length()).max(0)
  let block_bytes: Array[Byte] = []
  let remaining: Array[Byte] = []

  // 第 2 步：把前缀数据和剩余数据拆开。
  for i = 0; i < compressor.pending.length(); i = i + 1 {
    if i < actual_size {
      block_bytes.push(compressor.pending[i])
    } else {
      remaining.push(compressor.pending[i])
    }
  }

  // 第 3 步：更新 pending，并返回本次切出来的块数据。
  compressor.pending = remaining
  Bytes::from_array(block_bytes)
}

/// 基于同帧历史窗口生成真正的增量 LZ77 序列。
///
/// 这里直接复用“预加载字典 + 当前位置继续建哈希”的序列生成逻辑：
/// - `history_window` 作为可回溯历史前缀
/// - `block_data` 在扫描过程中持续加入哈希表
/// - 因此后续匹配既可以命中历史窗口，也可以命中当前块前面已经处理过的数据
///
/// 这比“只找一个最长前缀匹配再机械拆分”更接近真正的增量 LZ77。
fn build_streaming_compressed_payload_with_history(
  block_data: Bytes,
  config: CompressionConfig,
  history_window: Array[Byte]
) -> Result[Bytes, @zstd_core.ZSTDError] {
  // 第 1 步：做最基本的长度守卫。
  // 历史和当前块都必须至少能形成一次最短匹配。
  if history_window.length() < config.min_match || block_data.length() < config.min_match {
    return Err(@zstd_core.message_error("History too short for streaming reuse"))
  }

  // 第 2 步：把历史窗口视为“内部字典”，并预热到哈希表。
  let history = bytes_from_byte_array(history_window)
  let hash_table = Array::make(hash_table_size, -1)
  preload_streaming_history_to_hash_table(history, hash_table)
  let window_size = 1 << config.window_log

  // 第 3 步：使用“历史 + 当前块继续建哈希”的方式生成真实增量序列。
  match generate_sequences_with_dict(block_data, history, hash_table, config.min_match, window_size) {
    Ok((sequences, literals)) => {
      // 第 4 步：如果序列收益不足，直接回退为 raw，不强行写压缩块。
      if sequences.length() == 0 || !should_use_compressed_block(block_data, sequences, literals) {
        return Err(@zstd_core.message_error("No compression benefit from history"))
      }

      // 第 5 步：使用保守的预定义 FSE 路径构造压缩块负载。
      match build_predefined_compressed_block_payload_from_sequences(sequences, literals) {
        Ok(bytes) => {
          // 第 6 步：只在压缩结果确实更小时才接受该负载。
          if bytes.length() < block_data.length() {
            Ok(bytes)
          } else {
            Err(@zstd_core.message_error("History payload not smaller than raw block"))
          }
        }
        Err(e) => Err(e)
      }
    }
    Err(e) => Err(@zstd_core.message_error(e))
  }
}

/// 选择单个流式块的编码方式并生成块负载。
///
/// 返回值为：
/// - 块类型编号
/// - 实际块负载
/// - 块头中的 size 字段值
fn build_streaming_block_content(
  block_data: Bytes,
  config: CompressionConfig,
  history_window: Array[Byte]
) -> Result[(Int, Bytes, Int), @zstd_core.ZSTDError] {
  // 第 1 步：空块直接返回空 raw 负载。
  if block_data.length() == 0 {
    return Ok((0, Bytes::from_array([]), 0))
  }

  // 第 2 步：优先检查是否满足严格 RLE 条件。
  if is_uniform_byte_sequence(block_data) {
    match compress_block_content_rle(block_data) {
      Ok((block_type, payload)) => Ok((block_type, payload, block_data.length()))
      Err(e) => Err(e)
    }
  // 第 3 步：如果有历史窗口且值得尝试压缩，则走历史复用压缩路径。
  } else if should_try_compressed_block(block_data) && history_window.length() > 0 {
    match build_streaming_compressed_payload_with_history(block_data, config, history_window) {
      Ok(payload) => Ok((2, payload, payload.length()))
      Err(_) => Ok((0, block_data, block_data.length()))
    }
  // 第 4 步：其余情况直接回退为 raw 块。
  } else {
    Ok((0, block_data, block_data.length()))
  }
}

/// 把一个数据块编码成完整 ZSTD 块字节序列。
fn encode_streaming_block(
  compressor: StreamingCompressor,
  block_data: Bytes,
  last_block: Bool
) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []

  // 第 1 步：先决定块类型与块负载。
  match build_streaming_block_content(block_data, compressor.config, compressor.history_window) {
    Ok((block_type, payload, header_block_size)) => {
      // 第 2 步：写块头与块负载。
      write_block_header(output, last_block, block_type, header_block_size)
      append_bytes_to_output(output, payload)

      // 第 3 步：更新统计信息。
      compressor.emitted_block_count = compressor.emitted_block_count + 1
      match block_type {
        0 => compressor.raw_block_count = compressor.raw_block_count + 1
        1 => compressor.rle_block_count = compressor.rle_block_count + 1
        2 => compressor.compressed_block_count = compressor.compressed_block_count + 1
        _ => ()
      }
      // 第 4 步：把原始块数据加入历史窗口，供后续块继续匹配。
      append_to_streaming_history(compressor, block_data)
      Ok(Bytes::from_array(output))
    }
    Err(e) => Err(e)
  }
}

/// 向流式压缩器写入一个 chunk，并尽可能产出可立即发送的字节流。
///
/// 行为说明：
/// - 首次写入时会输出帧头
/// - 当内部缓存达到 `128KB` 时，会自动写出非最后块
/// - 返回值只包含“本次新增产出”的字节，而不是全部历史输出
pub fn write_streaming_chunk(
  compressor: StreamingCompressor,
  chunk: Bytes
) -> Result[Bytes, @zstd_core.ZSTDError] {
  // 第 1 步：状态守卫。
  // 已 finish 的流式压缩器不能再继续接收输入。
  if compressor.finished {
    return Err(@zstd_core.message_error("Streaming compressor already finished"))
  }

  // 第 2 步：空 chunk 不产生任何输出。
  if chunk.length() == 0 {
    return Ok(Bytes::from_array([]))
  }

  let output: Array[Byte] = []

  // 第 3 步：确保帧头只写一次。
  ensure_streaming_header(compressor, output)

  // 第 4 步：更新输入统计与 checksum。
  compressor.total_input_size = compressor.total_input_size + chunk.length()
  if compressor.with_checksum {
    compressor.checksum_state = update_checksum_state(compressor.checksum_state, chunk)
  }

  // 第 5 步：把 chunk 追加到 pending，等待按块切分。
  for i = 0; i < chunk.length(); i = i + 1 {
    compressor.pending.push(chunk[i])
  }

  // 第 6 步：只要 pending 达到自动落块阈值，就持续写出完整块。
  while compressor.pending.length() >= streaming_block_size {
    let block_data = take_pending_prefix(compressor, streaming_block_size)
    match encode_streaming_block(compressor, block_data, false) {
      Ok(block_bytes) => append_bytes_to_output(output, block_bytes)
      Err(e) => return Err(e)
    }
    compressor.auto_flush_count = compressor.auto_flush_count + 1
  }

  // 第 7 步：记录本次新增输出并返回。
  record_streaming_output(compressor, output)
  Ok(Bytes::from_array(output))
}

/// 强制把当前 pending 数据写成一个非最后块。
///
/// 用途：
/// - 需要尽快把当前缓存吐给下游
/// - 即使块未满 `128KB`，也允许提前落块
///
/// 注意：
/// - 这会降低后续跨块压缩机会
/// - 该接口不会结束帧
pub fn flush_streaming_compressor(compressor: StreamingCompressor) -> Result[Bytes, @zstd_core.ZSTDError] {
  // 第 1 步：检查流式状态是否合法。
  if compressor.finished {
    return Err(@zstd_core.message_error("Streaming compressor already finished"))
  }

  // 第 2 步：没有 pending 时，无需产生任何块。
  if compressor.pending.length() == 0 {
    return Ok(Bytes::from_array([]))
  }

  let output: Array[Byte] = []

  // 第 3 步：确保帧头存在。
  ensure_streaming_header(compressor, output)

  // 第 4 步：把当前全部 pending 强制写成一个非最后块。
  let block_data = take_pending_prefix(compressor, compressor.pending.length())
  match encode_streaming_block(compressor, block_data, false) {
    Ok(block_bytes) => {
      append_bytes_to_output(output, block_bytes)
      // 第 5 步：更新 flush 计数和输出统计。
      compressor.flush_count = compressor.flush_count + 1
      record_streaming_output(compressor, output)
      Ok(Bytes::from_array(output))
    }
    Err(e) => Err(e)
  }
}

/// 结束当前流式压缩帧，并返回最后一段字节流。
///
/// 行为说明：
/// - 如果从未写入任何输入，则返回标准空帧
/// - 如果还有 pending 数据，则将其写为最后块
/// - 如果没有 pending 数据，也会补一个空最后块，确保帧完整结束
/// - 如果启用了 checksum，会在最后块后追加 checksum
pub fn finish_streaming_compressor(compressor: StreamingCompressor) -> Result[Bytes, @zstd_core.ZSTDError] {
  // 第 1 步：状态守卫。
  if compressor.finished {
    return Err(@zstd_core.message_error("Streaming compressor already finished"))
  }

  // 第 2 步：先把状态标记为 finished，避免后续重复进入。
  compressor.finished = true

  // 第 3 步：如果整个生命周期内没有写入任何输入，则返回标准空帧。
  if compressor.total_input_size == 0 && !compressor.header_written {
    return compress_empty_frame()
  }

  let output: Array[Byte] = []

  // 第 4 步：确保帧头已经写出。
  ensure_streaming_header(compressor, output)

  // 第 5 步：如果还有 pending，就把它写成最后块；否则补空最后块收尾。
  if compressor.pending.length() > 0 {
    let block_data = take_pending_prefix(compressor, compressor.pending.length())
    match encode_streaming_block(compressor, block_data, true) {
      Ok(block_bytes) => append_bytes_to_output(output, block_bytes)
      Err(e) => return Err(e)
    }
  } else {
    write_block_header(output, true, 0, 0)
    compressor.emitted_block_count = compressor.emitted_block_count + 1
    compressor.raw_block_count = compressor.raw_block_count + 1
  }

  // 第 6 步：如启用 checksum，则把最终值追加到帧尾。
  if compressor.with_checksum {
    write_checksum(output, compressor.checksum_state)
    compressor.final_checksum = compressor.checksum_state
  }

  // 第 7 步：记录本次输出并返回最后字节流。
  record_streaming_output(compressor, output)
  Ok(Bytes::from_array(output))
}

/// 重置流式压缩器。
///
/// 重置后会保留：
/// - 原有配置
/// - checksum 开关
///
/// 同时清空：
/// - pending 缓冲
/// - 已写入状态
/// - 输入总量统计
/// - checksum 累计状态
pub fn reset_streaming_compressor(compressor: StreamingCompressor) -> Unit {
  // 重置所有运行态字段，但保留构造时传入的配置与 checksum 开关。
  compressor.pending = []
  compressor.history_window = []
  compressor.header_written = false
  compressor.finished = false
  compressor.total_input_size = 0
  compressor.total_output_size = 0
  compressor.emitted_block_count = 0
  compressor.raw_block_count = 0
  compressor.rle_block_count = 0
  compressor.compressed_block_count = 0
  compressor.flush_count = 0
  compressor.auto_flush_count = 0
  compressor.checksum_state = checksum_seed
  compressor.final_checksum = 0U
}
