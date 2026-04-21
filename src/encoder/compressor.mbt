/// ZSTD Compressor - LZ77 + Entropy Coding

/// Hash table size for LZ77 matching (64K buckets)
let hash_table_size : Int = 65536

/// Maximum block size (128KB)
let max_block_size : Int = 131072

/// Streaming block size (64KB)
let streaming_block_size : Int = 65536

/// 单序列直写路径当前变长编码可承载的最大基础值。
///
/// 这里对应当前实现中的三段式编码：
/// - 1 字节
/// - 2 字节
/// - 3 字节（`0xFF + u16`）
///
/// 对 `LL / (OF-1) / (ML-3)` 来说，可直接表示的最大值为：
/// `0x7F00 + 0xFFFF = 98047`
let single_sequence_varint_max : Int = 0x7F00 + 0xFFFF

/// Streaming checksum seed
let checksum_seed : UInt = 0x9E3779B1U

/// Frame content size thresholds for FCS field size selection
let fcs_threshold_1byte : Int = 256      // < 256: 1-byte FCS
let fcs_threshold_2byte : Int = 65792    // < 65792: 2-byte FCS, else 4-byte FCS

/// Default window size (64KB)
let default_window_size : Int = 65536

/// Helper: Write 16-bit value in little-endian
fn write_u16_le(output: Array[Byte], value: Int) -> Unit {
  output.push((value & 0xFF).to_byte())
  output.push(((value >> 8) & 0xFF).to_byte())
}

/// Helper: Write 32-bit value in little-endian
fn write_u32_le(output: Array[Byte], value: UInt) -> Unit {
  output.push((value & 0xFFU).to_byte())
  output.push(((value >> 8) & 0xFFU).to_byte())
  output.push(((value >> 16) & 0xFFU).to_byte())
  output.push(((value >> 24) & 0xFFU).to_byte())
}

/// Helper: Write 24-bit block header (last_block | block_type | block_size)
fn write_block_header(output: Array[Byte], last_block: Bool, block_type: Int, block_size: Int) -> Unit {
  let last = if last_block { 0x01 } else { 0x00 }
  let header = last | (block_type << 1) | (block_size << 3)
  output.push((header & 0xFF).to_byte())
  output.push(((header >> 8) & 0xFF).to_byte())
  output.push(((header >> 16) & 0xFF).to_byte())
}

/// Helper: Write sequence count header (variable-length encoding)
fn write_sequence_count(output: Array[Byte], count: Int) -> Unit {
  if count < 128 {
    output.push(count.to_byte())
  } else if count < 32768 {
    output.push(((count >> 8) + 128).to_byte())
    output.push((count & 0xFF).to_byte())
  } else {
    output.push(0xFF)
    output.push((count & 0xFF).to_byte())
    output.push(((count >> 8) & 0xFF).to_byte())
  }
}

/// Simple XXH32-like checksum
fn calculate_checksum(data: Bytes) -> UInt {
  let mut hash = checksum_seed
  for i = 0; i < data.length(); i = i + 1 {
    hash = hash + data[i].to_uint()
    hash = hash * 0x85EBCA77U
    hash = hash ^ (hash >> 13)
  }
  hash
}

/// Write 32-bit checksum in little-endian
fn write_checksum(output: Array[Byte], checksum: UInt) -> Unit {
  write_u32_le(output, checksum)
}

/// Write ZSTD magic number (0xFD2FB528 in little-endian)
fn write_zstd_magic(output: Array[Byte]) -> Unit {
  output.push(0x28)
  output.push(0xB5)
  output.push(0x2F)
  output.push(0xFD)
}

/// Write 32-bit dictionary ID in little-endian format
fn write_dict_id(output: Array[Byte], dict_id: UInt) -> Unit {
  write_u32_le(output, dict_id)
}

/// Write frame header descriptor and content size with optional checksum
fn write_frame_header_descriptor_with_checksum(output: Array[Byte], data_length: Int, with_checksum: Bool) -> Unit {
  let checksum_flag = if with_checksum { 0x04 } else { 0x00 }
  if data_length < fcs_threshold_1byte {
    output.push((0x20 | checksum_flag).to_byte())
    output.push(data_length.to_byte())
  } else if data_length < fcs_threshold_2byte {
    output.push((0x60 | checksum_flag).to_byte())
    write_u16_le(output, data_length - fcs_threshold_1byte)
  } else {
    output.push((0xA0 | checksum_flag).to_byte())
    write_u32_le(output, data_length.reinterpret_as_uint())
  }
}

/// Write frame header descriptor and content size based on data length
fn write_frame_header_descriptor(output: Array[Byte], data_length: Int) -> Unit {
  write_frame_header_descriptor_with_checksum(output, data_length, false)
}

/// Write frame content size for dictionary frames (updates FHD byte if needed)
fn write_frame_content_size_with_dict(output: Array[Byte], data_length: Int, fhd_index: Int) -> Unit {
  if data_length < fcs_threshold_1byte {
    output.push(data_length.to_byte())
  } else if data_length < fcs_threshold_2byte {
    output[fhd_index] = 0x63
    write_u16_le(output, data_length - fcs_threshold_1byte)
  } else {
    output[fhd_index] = 0xA3
    write_u32_le(output, data_length.reinterpret_as_uint())
  }
}

pub struct Compressor {
  level: Int
  hash_table: Array[Int]
  window_size: Int
}

priv struct Match {
  offset: Int
  length: Int
}

priv struct LZSequence {
  literal_length: Int
  match_length: Int
  offset: Int
}

pub struct CompressionConfig {
  level: Int         // 1-22
  window_log: Int    // Window = 2^window_log (controls LZ77 match distance limit)
  min_match: Int     // Min match length for LZ77
  search_depth: Int  // Search depth (quality vs speed)
}

pub struct CompressionContext {
  config: CompressionConfig
}

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

/// 增量更新 checksum。
///
/// 这里复用与 `calculate_checksum` 相同的按字节更新逻辑，
/// 这样可以在流式写入时逐块累计，最终结果与一次性计算保持一致。
fn update_checksum_state(current: UInt, data: Bytes) -> UInt {
  let mut hash = current
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
  write_zstd_magic(output)

  let checksum_flag = if with_checksum { 0x04 } else { 0x00 }
  output.push(checksum_flag.to_byte())

  // Window_Descriptor 采用 mantissa=0 的精确 2^window_log 表达。
  let clamped_window_log = config.window_log.max(10).min(41)
  let exponent = clamped_window_log - 10
  output.push((exponent << 3).to_byte())
}

/// 确保流式帧头仅写出一次。
fn ensure_streaming_header(compressor: StreamingCompressor, output: Array[Byte]) -> Unit {
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
  for i = 0; i < data.length(); i = i + 1 {
    compressor.history_window.push(data[i])
  }

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
  let actual_size = size.min(compressor.pending.length()).max(0)
  let block_bytes: Array[Byte] = []
  let remaining: Array[Byte] = []

  for i = 0; i < compressor.pending.length(); i = i + 1 {
    if i < actual_size {
      block_bytes.push(compressor.pending[i])
    } else {
      remaining.push(compressor.pending[i])
    }
  }

  compressor.pending = remaining
  Bytes::from_array(block_bytes)
}

/// 基于同帧历史窗口尝试构建压缩块负载。
///
/// 这里不再直接复用通用的字典序列生成器，而是使用更保守的
/// “历史窗口前缀复用”策略：
/// - 只寻找当前块开头在历史窗口中的最长匹配
/// - 成功后用单序列直写编码
/// - 剩余数据作为尾部 literals 追加
///
/// 这样能显著降低流式路径和复杂 FSE 状态机的耦合面，
/// 优先保证跨 chunk 历史继承的稳定性与可解码性。
fn build_streaming_compressed_payload_with_history(
  block_data: Bytes,
  config: CompressionConfig,
  history_window: Array[Byte]
) -> Result[Bytes, @zstd_core.ZSTDError] {
  let window_size = 1 << config.window_log
  if history_window.length() < config.min_match || block_data.length() < config.min_match {
    return Err(@zstd_core.message_error("History too short for streaming reuse"))
  }

  let history_len = history_window.length()
  let search_start = (history_len - streaming_block_size).max(0)
  let mut best_match_pos = -1
  let mut best_match_length = 0

  for dict_pos = search_start; dict_pos + config.min_match <= history_len; dict_pos = dict_pos + 1 {
    let offset = history_len - dict_pos
    if offset <= 0 || offset > window_size {
      continue
    }

    let max_match = (history_len - dict_pos).min(block_data.length()).min(131072)
    let mut length = 0
    while length < max_match && history_window[dict_pos + length] == block_data[length] {
      length = length + 1
    }

    if length > best_match_length || (length == best_match_length && dict_pos > best_match_pos) {
      best_match_length = length
      best_match_pos = dict_pos
    }
  }

  if best_match_length < config.min_match || best_match_pos < 0 {
    return Err(@zstd_core.message_error("No reusable history prefix found"))
  }

  let offset = history_len - best_match_pos
  if offset <= 0 || offset > window_size {
    return Err(@zstd_core.message_error("Reusable history offset exceeds window"))
  }

  let sequences = [
    LZSequence::{
      literal_length: 0,
      match_length: best_match_length,
      offset: offset,
    }
  ]
  let literals: Array[Byte] = []
  for i = best_match_length; i < block_data.length(); i = i + 1 {
    literals.push(block_data[i])
  }

  let payload = build_predefined_compressed_block_payload_from_sequences(sequences, literals)
  match payload {
    Ok(bytes) => {
      if bytes.length() < block_data.length() {
        Ok(bytes)
      } else {
        Err(@zstd_core.message_error("History payload not smaller than raw block"))
      }
    }
    Err(e) => Err(e)
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
  if block_data.length() == 0 {
    return Ok((0, Bytes::from_array([]), 0))
  }

  if is_uniform_byte_sequence(block_data) {
    match compress_block_content_rle(block_data) {
      Ok((block_type, payload)) => Ok((block_type, payload, block_data.length()))
      Err(e) => Err(e)
    }
  } else if should_try_compressed_block(block_data) && history_window.length() > 0 {
    match build_streaming_compressed_payload_with_history(block_data, config, history_window) {
      Ok(payload) => Ok((2, payload, payload.length()))
      Err(_) => Ok((0, block_data, block_data.length()))
    }
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

  match build_streaming_block_content(block_data, compressor.config, compressor.history_window) {
    Ok((block_type, payload, header_block_size)) => {
      write_block_header(output, last_block, block_type, header_block_size)
      append_bytes_to_output(output, payload)
      compressor.emitted_block_count = compressor.emitted_block_count + 1
      match block_type {
        0 => compressor.raw_block_count = compressor.raw_block_count + 1
        1 => compressor.rle_block_count = compressor.rle_block_count + 1
        2 => compressor.compressed_block_count = compressor.compressed_block_count + 1
        _ => ()
      }
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
  if compressor.finished {
    return Err(@zstd_core.message_error("Streaming compressor already finished"))
  }

  if chunk.length() == 0 {
    return Ok(Bytes::from_array([]))
  }

  let output: Array[Byte] = []
  ensure_streaming_header(compressor, output)

  compressor.total_input_size = compressor.total_input_size + chunk.length()
  if compressor.with_checksum {
    compressor.checksum_state = update_checksum_state(compressor.checksum_state, chunk)
  }

  for i = 0; i < chunk.length(); i = i + 1 {
    compressor.pending.push(chunk[i])
  }

  while compressor.pending.length() >= streaming_block_size {
    let block_data = take_pending_prefix(compressor, streaming_block_size)
    match encode_streaming_block(compressor, block_data, false) {
      Ok(block_bytes) => append_bytes_to_output(output, block_bytes)
      Err(e) => return Err(e)
    }
    compressor.auto_flush_count = compressor.auto_flush_count + 1
  }

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
  if compressor.finished {
    return Err(@zstd_core.message_error("Streaming compressor already finished"))
  }

  if compressor.pending.length() == 0 {
    return Ok(Bytes::from_array([]))
  }

  let output: Array[Byte] = []
  ensure_streaming_header(compressor, output)

  let block_data = take_pending_prefix(compressor, compressor.pending.length())
  match encode_streaming_block(compressor, block_data, false) {
    Ok(block_bytes) => {
      append_bytes_to_output(output, block_bytes)
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
  if compressor.finished {
    return Err(@zstd_core.message_error("Streaming compressor already finished"))
  }

  compressor.finished = true

  if compressor.total_input_size == 0 && !compressor.header_written {
    return compress_empty_frame()
  }

  let output: Array[Byte] = []
  ensure_streaming_header(compressor, output)

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

  if compressor.with_checksum {
    write_checksum(output, compressor.checksum_state)
    compressor.final_checksum = compressor.checksum_state
  }

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

// ============================================================================
// Hash Table Implementation / 哈希表实现
// ============================================================================

/// Hash a 4-byte sequence for pattern matching
fn hash_bytes(data: Bytes, pos: Int) -> Int {
  if pos + 3 >= data.length() {
    return 0
  }

  let b0 = data[pos].to_int() & 0xFF
  let b1 = data[pos + 1].to_int() & 0xFF
  let b2 = data[pos + 2].to_int() & 0xFF
  let b3 = data[pos + 3].to_int() & 0xFF

  // Improved hash: better distribution using bit shifts and XOR
  let hash = ((b0 << 12) ^ (b1 << 8) ^ (b2 << 4) ^ b3) * 506832829
  (hash >> 16) & 0xFFFF
}

/// Find match at given position using hash table (optimized)
fn find_match(data: Bytes, pos: Int, hash_table: Array[Int], min_match: Int, window_size: Int) -> Match {
  let data_len = data.length()
  if pos + min_match > data_len {
    return Match::{ offset: 0, length: 0 }
  }

  let hash = hash_bytes(data, pos)
  let match_pos = hash_table[hash]

  if match_pos == -1 || match_pos >= pos {
    return Match::{ offset: 0, length: 0 }
  }

  let offset = pos - match_pos
  if offset > window_size {
    return Match::{ offset: 0, length: 0 }
  }

  // Early exit: check min_match bytes first
  let mut i = 0
  while i < min_match && pos + i < data_len {
    if data[match_pos + (i % offset)] != data[pos + i] {
      return Match::{ offset: 0, length: 0 }
    }
    i = i + 1
  }

  let mut match_length = min_match
  let max_match = (data_len - pos).min(131072)

  while match_length < max_match &&
        pos + match_length < data_len &&
        data[match_pos + (match_length % offset)] == data[pos + match_length] {
    match_length = match_length + 1
  }

  Match::{ offset: offset, length: match_length }
}

// ============================================================================
// Compressor Creation / 压缩器创建
// ============================================================================

/// Create new compressor
pub fn new_compressor() -> Compressor {
  let hash_table = Array::make(hash_table_size, -1)
  Compressor::{
    level: 1,
    hash_table: hash_table,
    window_size: default_window_size  // 64KB default window - must match decoder
  }
}

pub fn create_default_config() -> CompressionConfig {
  CompressionConfig::{ level: 3, window_log: 17, min_match: 4, search_depth: 12 }
}

pub fn create_config_with_level(level: Int) -> CompressionConfig {
  let clamped_level = level.max(1).min(22)
  let (window_log, min_match, search_depth) = match clamped_level {
    1 => (16, 4, 4)           // Fast
    2 => (16, 4, 8)
    3 => (17, 4, 12)          // Default
    4 | 5 => (17, 4, 16)
    6 | 7 => (18, 4, 24)      // Better
    8 | 9 => (18, 4, 32)
    10 | 11 | 12 => (19, 3, 48)  // Much better
    13 | 14 | 15 => (19, 3, 64)
    16 | 17 | 18 => (20, 3, 96)  // Ultra
    _ => (20, 3, 128)
  }
  CompressionConfig::{ level: clamped_level, window_log, min_match, search_depth }
}

pub fn create_compression_context(config: CompressionConfig) -> CompressionContext {
  CompressionContext::{ config }
}

// ============================================================================
// LZ77 Compression / LZ77 压缩
// ============================================================================

/// Generate sequences using greedy LZ77 matching with repeat offset optimization
fn generate_sequences(data: Bytes, min_match: Int, window_size: Int) -> (Array[LZSequence], Array[Byte]) {
  let sequences: Array[LZSequence] = []
  let literals: Array[Byte] = []
  let hash_table = Array::make(hash_table_size, -1)

  let mut pos = 0
  let mut literal_start = 0
  let mut rep0 = 1
  let mut rep1 = 4
  let mut rep2 = 8

  while pos < data.length() {
    let match_result = find_match(data, pos, hash_table, min_match, window_size)

    if match_result.length >= min_match {
      let literal_length = pos - literal_start
      for i = literal_start; i < pos; i = i + 1 {
        literals.push(data[i])
      }

      let offset = match_result.offset
      let encoded_offset = if offset == rep0 {
        -1  // Special marker for rep[0]
      } else if offset == rep1 {
        -2  // Special marker for rep[1]
      } else if offset == rep2 {
        -3  // Special marker for rep[2]
      } else {
        rep2 = rep1
        rep1 = rep0
        rep0 = offset
        offset
      }

      sequences.push(LZSequence::{
        literal_length,
        match_length: match_result.length,
        offset: encoded_offset,
      })

      let mut i = pos
      while i < pos + match_result.length && i + 3 < data.length() {
        let hash = hash_bytes(data, i)
        hash_table[hash] = i
        i = i + 1
      }

      pos = pos + match_result.length
      literal_start = pos
    } else {
      if pos + 3 < data.length() {
        let hash = hash_bytes(data, pos)
        hash_table[hash] = pos
      }
      pos = pos + 1
    }
  }

  for i = literal_start; i < data.length(); i = i + 1 {
    literals.push(data[i])
  }

  (sequences, literals)
}

/// 压缩数据 - 支持 Raw / RLE / Compressed 三种块类型
/// 说明：
/// - Raw 块：无压缩，直接存储原始数据
/// - RLE 块：对重复数据进行压缩，可达 2000% 压缩率
/// - Compressed 块：LZ77 + FSE/Huffman 高级压缩
pub fn compress_data(data: Bytes, config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_data_with_checksum(data, config, false)
}

/// Compress data with optional checksum
pub fn compress_data_with_checksum(data: Bytes, config: CompressionConfig, with_checksum: Bool) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 { return compress_empty_frame() }

  if data.length() > max_block_size {
    return compress_multi_block_with_checksum(data, config, with_checksum)
  }

  let result = if is_rle_beneficial(data) {
    compress_as_rle_block(data, config)
  } else if should_try_compressed_block(data) {
    match compress_as_compressed_block(data, config) {
      Ok(compressed) => {
        if compressed.length() < data.length() + 12 {
          Ok(compressed)
        } else {
          compress_as_raw_block(data, config)
        }
      }
      Err(_) => compress_as_raw_block(data, config)
    }
  } else {
    compress_as_raw_block(data, config)
  }

  match result {
    Ok(compressed) => {
      if with_checksum {
        let output: Array[Byte] = []
        for i = 0; i < compressed.length(); i = i + 1 {
          output.push(compressed[i])
        }
        write_checksum(output, calculate_checksum(data))
        Ok(Bytes::from_array(output))
      } else {
        Ok(compressed)
      }
    }
    Err(e) => Err(e)
  }
}

/// Compress large data as multiple blocks with optional checksum
fn compress_multi_block_with_checksum(data: Bytes, config: CompressionConfig, with_checksum: Bool) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []

  write_zstd_magic(output)
  write_frame_header_descriptor_with_checksum(output, data.length(), with_checksum)

  let mut offset = 0
  while offset < data.length() {
    let block_size = (data.length() - offset).min(max_block_size)

    let block_bytes: Array[Byte] = []
    for i = 0; i < block_size; i = i + 1 {
      block_bytes.push(data[offset + i])
    }
    let block_data = Bytes::from_array(block_bytes)
    let is_last = offset + block_size >= data.length()

    let block_result = if is_uniform_byte_sequence(block_data) {
      compress_block_content_rle(block_data)
    } else if should_try_compressed_block(block_data) {
      match compress_block_content_compressed(block_data, config) {
        Ok(compressed) => {
          if compressed.length() < block_size {
            Ok((2, compressed))
          } else {
            compress_block_content_raw(block_data)
          }
        }
        Err(_) => compress_block_content_raw(block_data)
      }
    } else {
      compress_block_content_raw(block_data)
    }

    match block_result {
      Ok((block_type, block_content)) => {
        write_block_header(output, is_last, block_type, block_content.length())
        for i = 0; i < block_content.length(); i = i + 1 {
          output.push(block_content[i])
        }
      }
      Err(e) => return Err(e)
    }

    offset = offset + block_size
  }

  if with_checksum {
    write_checksum(output, calculate_checksum(data))
  }

  Ok(Bytes::from_array(output))
}

/// Compress block content as raw
fn compress_block_content_raw(data: Bytes) -> Result[(Int, Bytes), @zstd_core.ZSTDError] {
  Ok((0, data))
}

/// Compress block content as RLE
fn compress_block_content_rle(data: Bytes) -> Result[(Int, Bytes), @zstd_core.ZSTDError] {
  let output: Array[Byte] = []
  output.push(data[0])
  Ok((1, Bytes::from_array(output)))
}

/// Compress block content as compressed
fn compress_block_content_compressed(data: Bytes, config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  let min_match = config.min_match
  let window_size = 1 << config.window_log
  let (sequences, literals) = generate_sequences(data, min_match, window_size)

  if sequences.length() == 0 {
    return Err(@zstd_core.message_error("No sequences"))
  }

  build_compressed_block_payload_from_sequences(sequences, literals)
}

/// 解析序列的实际 offset。
///
/// 单序列直写路径需要把 `rep` 标记先还原为真实 offset，
/// 这样才能判断当前值是否会超出直写编码的承载上限。
fn resolve_sequence_offset_for_direct_encoding(seq: LZSequence) -> Int {
  if seq.offset == -1 {
    1
  } else if seq.offset == -2 {
    4
  } else if seq.offset == -3 {
    8
  } else {
    seq.offset
  }
}

/// 判断单序列是否能被当前直写编码稳定承载。
fn can_encode_single_sequence_direct(seq: LZSequence) -> Bool {
  let ll = seq.literal_length
  let ml_minus_3 = seq.match_length - 3
  let of = resolve_sequence_offset_for_direct_encoding(seq)
  let of_minus_1 = of - 1

  ll >= 0 &&
  seq.match_length >= 3 &&
  of >= 1 &&
  ll <= single_sequence_varint_max &&
  ml_minus_3 >= 0 && ml_minus_3 <= single_sequence_varint_max &&
  of_minus_1 >= 0 && of_minus_1 <= single_sequence_varint_max
}

/// 将超出单序列直写上限的单个序列切分为多个序列。
///
/// 规则：
/// - 第一段保留原始 `literal_length`
/// - 后续段 `literal_length = 0`
/// - `offset` 保持一致
/// - 每段 `match_length >= 3`
///
/// 这样可以把原本必须走单序列直写的情况，转换为多序列预定义 FSE 路径。
fn split_large_single_sequence(seq: LZSequence) -> Result[Array[LZSequence], @zstd_core.ZSTDError] {
  if can_encode_single_sequence_direct(seq) {
    return Ok([seq])
  }

  if seq.match_length < 6 {
    return Err(@zstd_core.message_error("Single sequence exceeds direct encoding range and cannot be safely split"))
  }

  let max_chunk_match_length = single_sequence_varint_max + 3
  let chunk_lengths: Array[Int] = []
  let mut remaining_match = seq.match_length

  while remaining_match > max_chunk_match_length {
    chunk_lengths.push(max_chunk_match_length)
    remaining_match = remaining_match - max_chunk_match_length
  }

  if remaining_match >= 3 {
    chunk_lengths.push(remaining_match)
  } else {
    if chunk_lengths.length() == 0 {
      return Err(@zstd_core.message_error("Unable to split single sequence into valid chunks"))
    }
    let last_index = chunk_lengths.length() - 1
    let borrow = 3 - remaining_match
    let previous_chunk = chunk_lengths[last_index]
    if previous_chunk - borrow < 3 {
      return Err(@zstd_core.message_error("Unable to rebalance split single sequence chunks"))
    }
    chunk_lengths[last_index] = previous_chunk - borrow
    chunk_lengths.push(3)
  }

  let split_sequences: Array[LZSequence] = []
  for i = 0; i < chunk_lengths.length(); i = i + 1 {
    split_sequences.push(LZSequence::{
      literal_length: if i == 0 { seq.literal_length } else { 0 },
      match_length: chunk_lengths[i],
      offset: seq.offset,
    })
  }

  Ok(split_sequences)
}

/// 为块编码准备序列。
///
/// 当前只在一个场景下做转换：
/// - 原始序列数为 1
/// - 该序列超出单序列直写编码能力
///
/// 转换后让块走多序列路径，从而继续使用预定义 FSE 表编码。
fn normalize_sequences_for_block_encoding(
  sequences: Array[LZSequence]
) -> Result[Array[LZSequence], @zstd_core.ZSTDError] {
  if sequences.length() != 1 {
    return Ok(sequences)
  }

  split_large_single_sequence(sequences[0])
}

/// 从序列和字面量构建压缩块负载。
///
/// 这个 helper 统一了三类调用方：
/// - 普通压缩块
/// - 带字典匹配的压缩块
/// - 流式压缩中带历史窗口的压缩块
fn build_compressed_block_payload_from_sequences(
  sequences: Array[LZSequence],
  literals: Array[Byte]
) -> Result[Bytes, @zstd_core.ZSTDError] {
  if sequences.length() == 0 {
    return Err(@zstd_core.message_error("No compression benefit - fallback to raw block"))
  }

  let normalized_sequences = match normalize_sequences_for_block_encoding(sequences) {
    Ok(v) => v
    Err(e) => return Err(e)
  }

  let output: Array[Byte] = []

  encode_literals_section(literals, output)

  let num_sequences = normalized_sequences.length()
  write_sequence_count(output, num_sequences)

  if num_sequences > 0 {
    if num_sequences == 1 {
      encode_single_sequence_direct(normalized_sequences[0], output)
    } else {
      let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(normalized_sequences)

      // Decide whether to use compressed FSE mode
      if should_use_compressed_fse(ll_symbols, ml_symbols, of_symbols) {
        output.push(0x01)  // Compressed mode flag
        match encode_sequences_compressed_fse(normalized_sequences, output) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      } else {
        output.push(0x00)  // Predefined mode
        match encode_sequences_predefined_fse(normalized_sequences, output) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    }
  }

  Ok(Bytes::from_array(output))
}

/// 从序列和字面量构建保守版压缩块负载。
///
/// 只使用：
/// - 单序列直写
/// - 多序列预定义 FSE
///
/// 不启用自定义压缩 FSE 表，便于在历史窗口压缩场景下优先保证稳定性。
fn build_predefined_compressed_block_payload_from_sequences(
  sequences: Array[LZSequence],
  literals: Array[Byte]
) -> Result[Bytes, @zstd_core.ZSTDError] {
  if sequences.length() == 0 {
    return Err(@zstd_core.message_error("No compression benefit - fallback to raw block"))
  }

  let normalized_sequences = match normalize_sequences_for_block_encoding(sequences) {
    Ok(v) => v
    Err(e) => return Err(e)
  }

  let output: Array[Byte] = []
  encode_literals_section(literals, output)

  let num_sequences = normalized_sequences.length()
  write_sequence_count(output, num_sequences)

  if num_sequences > 0 {
    if num_sequences == 1 {
      encode_single_sequence_direct(normalized_sequences[0], output)
    } else {
      output.push(0x00)
      match encode_sequences_predefined_fse(normalized_sequences, output) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
  }

  Ok(Bytes::from_array(output))
}

/// 判断是否应该尝试 Compressed block
fn should_try_compressed_block(data: Bytes) -> Bool {
  // 数据足够大且有一定的重复模式
  data.length() >= 64
}

/// Check if RLE compression would be beneficial
fn is_rle_beneficial(data: Bytes) -> Bool {
  if data.length() < 4 {
    return false
  }
  
  // Sample the data to check for repetition
  let first_byte = data[0]
  let mut same_count = 0
  let sample_size = data.length().min(100)
  
  for i = 0; i < sample_size; i = i + 1 {
    if data[i] == first_byte {
      same_count = same_count + 1
    }
  }
  
  // If more than 80% are the same, use RLE
  (same_count * 10) > (sample_size * 8)
}

/// 检查整个字节序列是否都由同一个字节组成。
///
/// 说明：
/// - 这是 RLE 块合法性的严格条件
/// - 与 `is_rle_beneficial` 不同，这里不使用抽样启发式
/// - 只有全量相同字节时，才能安全写成标准 RLE 块
fn is_uniform_byte_sequence(data: Bytes) -> Bool {
  if data.length() == 0 {
    return false
  }

  let first_byte = data[0]
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] != first_byte {
      return false
    }
  }

  true
}

/// Compress as RLE (Run Length Encoding) block
pub fn compress_as_rle_block(data: Bytes, _config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }
  
  // Check if all bytes are the same
  let first_byte = data[0]
  let mut all_same = true
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] != first_byte {
      all_same = false
      break
    }
  }
  
  if !all_same {
    // Fall back to raw block if not all bytes are the same
    return compress_as_raw_block(data, _config)
  }
  
  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header Descriptor and Content Size
  write_frame_header_descriptor(output, data.length())

  // Block Header: Last_Block=1, Block_Type=RLE(1), Block_Size (decompressed size ≤ 128KB per chunk)
  // Splits into multiple RLE blocks if data exceeds ZSTD_MAX_BLOCK_SIZE.
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE
  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    write_block_header(output, is_last, 1, chunk_size)
    // RLE block payload: single byte to repeat
    output.push(first_byte)
    pos = pos + chunk_size
  }
  
  Ok(Bytes::from_array(output))
}

/// Compress as raw (uncompressed) block.
/// Splits data into multiple blocks when it exceeds 128KB (ZSTD_MAX_BLOCK_SIZE).
pub fn compress_as_raw_block(data: Bytes, _config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header Descriptor and Content Size
  write_frame_header_descriptor(output, data.length())

  // Emit one or more Raw blocks, each ≤ max_block bytes
  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())

    write_block_header(output, is_last, 0, chunk_size)

    for i = 0; i < chunk_size; i = i + 1 {
      output.push(data[pos + i])
    }
    pos = pos + chunk_size
  }
  
  Ok(Bytes::from_array(output))
}

/// Compress empty data
fn compress_empty_frame() -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header: Single segment, no checksum, FCS=0
  output.push(0x20)
  output.push(0x00)  // Content size = 0
  
  // Empty last block
  output.push(0x01)
  output.push(0x00)
  output.push(0x00)
  
  Ok(Bytes::from_array(output))
}

/// 估算压缩大小
pub fn estimate_compressed_size(data: Bytes, _config: CompressionConfig) -> Int {
  if data.length() == 0 {
    return 10  // Empty frame overhead
  }

  // Check for RLE (highly compressible)
  if is_rle_beneficial(data) {
    return 10 + (data.length() / 128000) * 4  // RLE block overhead
  }

  // Analyze data entropy
  let mut unique_bytes = 0
  let byte_counts = Array::make(256, 0)
  let sample_size = data.length().min(1000)

  for i = 0; i < sample_size; i = i + 1 {
    let b = data[i].to_int() & 0xFF
    if byte_counts[b] == 0 {
      unique_bytes = unique_bytes + 1
    }
    byte_counts[b] = byte_counts[b] + 1
  }

  // Estimate based on entropy
  let entropy_ratio = unique_bytes.to_double() / 256.0
  let compression_ratio = if entropy_ratio < 0.1 {
    0.3  // Low entropy, good compression
  } else if entropy_ratio < 0.3 {
    0.5  // Medium-low entropy
  } else if entropy_ratio < 0.6 {
    0.7  // Medium entropy
  } else {
    0.95  // High entropy, poor compression
  }

  let estimated = (data.length().to_double() * compression_ratio).to_int()
  estimated + 12  // Add frame header overhead
}

/// Simple compress function
pub fn compress(data : Bytes) -> @zstd_core.ZSTDResult[Bytes] {
  let config = create_default_config()
  compress_data(data, config)
}

/// Compress with context
pub fn compress_with_context(comp : Compressor, data : Bytes) -> @zstd_core.ZSTDResult[(Compressor, Bytes)] {
  let config = create_config_with_level(comp.level)
  match compress_data(data, config) {
    Ok(compressed) => Ok((comp, compressed))
    Err(e) => Err(e)
  }
}

// ============================================================================
// Dictionary Compression Support / 字典压缩支持
// ============================================================================

/// Compress data with dictionary
pub fn compress_data_with_dict(
  data: Bytes,
  config: CompressionConfig,
  dictionary: Bytes,  // 用于在压缩时进行字典匹配
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }
  
  // ✅ 字典匹配实现：将字典内容预加载到哈希表
  // 这可以显著提高相似数据的压缩比
  if dictionary.length() > 0 {
    return compress_with_dictionary_matching(data, config, dictionary, dict_id)
  }
  
  compress_with_dict_id(data, config, dict_id)
}

/// Compress with dictionary ID in frame header
fn compress_with_dict_id(
  data: Bytes,
  _config: CompressionConfig,
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }
  
  // Check if data is RLE beneficial
  if is_rle_beneficial(data) {
    return compress_as_rle_block_with_dict(data, dict_id)
  }
  
  // Use raw block with dictionary ID
  compress_as_raw_block_with_dict(data, dict_id)
}

/// Compress as raw block with dictionary ID.
/// Splits data into multiple blocks when it exceeds 128KB.
fn compress_as_raw_block_with_dict(data: Bytes, dict_id: UInt) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header Descriptor with Dictionary_ID_Flag=3 (4 bytes)
  let fhd: Byte = 0x23  // Single_Segment=1, Dictionary_ID_Flag=3
  output.push(fhd)

  // Dictionary ID (4 bytes, little-endian)
  write_dict_id(output, dict_id)

  // Frame Content Size
  write_frame_content_size_with_dict(output, data.length(), 4)

  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    write_block_header(output, is_last, 0, chunk_size)
    for i = 0; i < chunk_size; i = i + 1 {
      output.push(data[pos + i])
    }
    pos = pos + chunk_size
  }
  
  Ok(Bytes::from_array(output))
}

/// Encode literals section into block content
/// Automatically selects the best type: RLE (type=1) if all same byte, Raw (type=0) otherwise
fn encode_literals_section(literals: Array[Byte], output: Array[Byte]) -> Unit {
  encode_literals_with_huffman(literals, output, true)
}

/// Enhanced literals encoding with Huffman support
fn encode_literals_with_huffman(literals: Array[Byte], output: Array[Byte], use_huffman: Bool) -> Unit {
  let size = literals.length()

  if size == 0 {
    output.push(b'\x00')
    return
  }

  // Check RLE
  let first = literals[0]
  let mut all_same = true
  for i = 1; i < size; i = i + 1 {
    if literals[i] != first {
      all_same = false
      break
    }
  }

  if all_same {
    if size < 32 {
      output.push(((size << 3) | 0x01).to_byte())
    } else if size < 4096 {
      output.push((((size & 0xF) << 4) | 0x05).to_byte())
      output.push(((size >> 4) & 0xFF).to_byte())
    } else {
      output.push((((size & 0xF) << 4) | 0x0D).to_byte())
      output.push(((size >> 4) & 0xFF).to_byte())
      output.push(((size >> 12) & 0xFF).to_byte())
    }
    output.push(first)
    return
  }

  // Try Huffman if enabled and beneficial
  if use_huffman && size >= 32 {
    match try_huffman_encode(literals) {
      Ok(huffman_data) => {
        if huffman_data.length() < size {
          write_huffman_literals(literals.length(), huffman_data, output)
          return
        }
      }
      Err(_) => ()
    }
  }

  // Fallback to Raw
  if size < 32 {
    output.push((size << 3).to_byte())
  } else if size < 4096 {
    output.push((((size & 0xF) << 4) | 0x04).to_byte())
    output.push(((size >> 4) & 0xFF).to_byte())
  } else {
    output.push((((size & 0xF) << 4) | 0x0C).to_byte())
    output.push(((size >> 4) & 0xFF).to_byte())
    output.push(((size >> 12) & 0xFF).to_byte())
  }
  for i = 0; i < size; i = i + 1 {
    output.push(literals[i])
  }
}

fn try_huffman_encode(literals: Array[Byte]) -> Result[Bytes, @zstd_core.ZSTDError] {
  match @zstd_entropy.huffman_encode(literals) {
    Ok(v) => Ok(v)
    Err(msg) => Err(@zstd_core.message_error(msg))
  }
}

fn write_huffman_literals(regen_size: Int, compressed: Bytes, output: Array[Byte]) -> Unit {
  let comp_size = compressed.length()
  // Type=2 (Compressed, single stream)
  if regen_size < 32 && comp_size < 512 {
    output.push(((regen_size << 3) | 0x02).to_byte())
    output.push((comp_size << 2).to_byte())
  } else {
    output.push((((regen_size & 0xF) << 4) | 0x06).to_byte())
    output.push(((regen_size >> 4) & 0xFF).to_byte())
    output.push((comp_size & 0xFF).to_byte())
    output.push(((comp_size >> 8) & 0xFF).to_byte())
  }
  for i = 0; i < comp_size; i = i + 1 {
    output.push(compressed[i])
  }
}

/// Compress as compressed block (with LZ77 sequences)
pub fn compress_as_compressed_block(data: Bytes, config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  let min_match = config.min_match
  let window_size = 1 << config.window_log

  let (sequences, literals) = generate_sequences(data, min_match, window_size)

  if sequences.length() == 0 {
    return Err(@zstd_core.message_error("No compression benefit - fallback to raw block"))
  }

  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header Descriptor and Content Size
  write_frame_header_descriptor(output, data.length())

  let block_content = match build_predefined_compressed_block_payload_from_sequences(sequences, literals) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }

  // Block Header: Last_Block=1, Block_Type=Compressed(2), Block_Size
  let block_size = block_content.length()
  write_block_header(output, true, 2, block_size)

  append_bytes_to_output(output, block_content)

  Ok(Bytes::from_array(output))
}

// (Huffman literals encoding reserved for future implementation)

// ============================================================================
// Dictionary Matching Implementation / 字典匹配实现
// ============================================================================

/// Compress data with dictionary matching
/// 使用字典进行压缩，预加载字典内容到哈希表以提高压缩比
fn compress_with_dictionary_matching(
  data: Bytes,
  config: CompressionConfig,
  dictionary: Bytes,
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  // 创建哈希表并预加载字典内容
  let hash_table = Array::make(hash_table_size, -1)

  // 将字典内容预加载到哈希表
  // 这样 LZ77 压缩器就能找到数据和字典内容的匹配
  preload_dictionary_to_hash_table(dictionary, hash_table)

  // 计算窗口大小
  let window_size = 1 << config.window_log

  // 使用预加载了字典的哈希表进行 LZ77 压缩
  let sequences_result = generate_sequences_with_dict(data, dictionary, hash_table, config.min_match, window_size)
  
  match sequences_result {
    Ok((sequences, literals)) => {
      // 如果找到了足够的匹配，使用压缩块
      if sequences.length() > 0 && should_use_compressed_block(data, sequences, literals) {
        // 使用完整的 Compressed 块（带字典 ID）
        compress_as_compressed_block_with_dict(data, sequences, literals, dict_id)
      } else {
        // 降级到 RLE 或 Raw 块
        compress_with_dict_id(data, config, dict_id)
      }
    }
    Err(_) => compress_with_dict_id(data, config, dict_id)
  }
}

/// Preload dictionary content into hash table
/// 将字典内容预加载到哈希表，使 LZ77 能找到字典匹配
fn preload_dictionary_to_hash_table(dictionary: Bytes, hash_table: Array[Int]) -> Unit {
  // 遍历字典，将所有 4 字节序列添加到哈希表
  // 使用负数位置表示来自字典的内容
  let dict_len = dictionary.length()
  
  let mut pos = 0
  while pos + 3 < dict_len {
    let hash = hash_bytes(dictionary, pos)
    // 使用负数偏移表示字典位置：-(pos + 1)
    // 这样可以与数据位置（非负）区分
    hash_table[hash] = -(pos + 1)
    pos = pos + 1
  }
}

/// Generate sequences with dictionary support
/// 使用字典增强的 LZ77 序列生成
fn generate_sequences_with_dict(
  data: Bytes,
  dictionary: Bytes,
  hash_table: Array[Int],
  min_match: Int,
  window_size: Int
) -> Result[(Array[LZSequence], Array[Byte]), String] {
  let sequences: Array[LZSequence] = []
  let literals: Array[Byte] = []
  
  let mut pos = 0
  let mut literal_start = 0
  
  while pos < data.length() {
    // 尝试找到匹配（包括字典匹配）
    let match_result = find_match_with_dict(data, dictionary, pos, hash_table, min_match, window_size)
    
    if match_result.length >= min_match {
      // 找到匹配！
      let literal_length = pos - literal_start
      
      // 添加匹配前的字面量
      for i = literal_start; i < pos; i = i + 1 {
        literals.push(data[i])
      }
      
      // 添加序列
      sequences.push(LZSequence::{
        literal_length: literal_length,
        match_length: match_result.length,
        offset: match_result.offset
      })
      
      // 更新哈希表（只添加数据中的位置）
      let mut i = pos
      while i < pos + match_result.length && i + 3 < data.length() {
        let hash = hash_bytes(data, i)
        hash_table[hash] = i
        i = i + 1
      }
      
      pos = pos + match_result.length
      literal_start = pos
    } else {
      // 没有找到匹配，更新哈希表
      if pos + 3 < data.length() {
        let hash = hash_bytes(data, pos)
        hash_table[hash] = pos
      }
      pos = pos + 1
    }
  }
  
  // 添加剩余字面量
  for i = literal_start; i < data.length(); i = i + 1 {
    literals.push(data[i])
  }
  
  Ok((sequences, literals))
}

/// Find match with dictionary support
/// 在数据和字典中查找匹配
fn find_match_with_dict(
  data: Bytes,
  dictionary: Bytes,
  pos: Int,
  hash_table: Array[Int],
  min_match: Int,
  window_size: Int
) -> Match {
  if pos + min_match > data.length() {
    return Match::{ offset: 0, length: 0 }
  }

  let hash = hash_bytes(data, pos)
  let match_pos = hash_table[hash]

  // 没有匹配
  if match_pos == -1 || match_pos >= pos {
    return Match::{ offset: 0, length: 0 }
  }

  // 区分字典匹配和数据匹配
  if match_pos < 0 {
    // 字典匹配（负数位置）
    let dict_pos = -match_pos - 1
    let match_length = calculate_match_length_from_dict(data, dictionary, pos, dict_pos)

    if match_length >= min_match {
      // 字典匹配的偏移计算（ZSTD标准）
      // offset = 当前位置 + (字典长度 - 匹配位置)
      let offset = pos + (dictionary.length() - dict_pos)
      if offset > window_size {
        return Match::{ offset: 0, length: 0 }
      }
      Match::{ offset: offset, length: match_length }
    } else {
      Match::{ offset: 0, length: 0 }
    }
  } else {
    // 数据内部匹配
    let offset = pos - match_pos
    if offset > window_size {
      return Match::{ offset: 0, length: 0 }
    }

    let match_length = calculate_match_length_in_data(data, pos, match_pos)

    if match_length >= min_match {
      Match::{ offset: offset, length: match_length }
    } else {
      Match::{ offset: 0, length: 0 }
    }
  }
}

/// Calculate match length from dictionary
/// 计算从字典到数据的匹配长度
fn calculate_match_length_from_dict(
  data: Bytes,
  dictionary: Bytes,
  data_pos: Int,
  dict_pos: Int
) -> Int {
  let mut length = 0
  let max_length = (data.length() - data_pos).min(dictionary.length() - dict_pos).min(131072)
  
  while length < max_length &&
        dict_pos + length < dictionary.length() &&
        data_pos + length < data.length() &&
        dictionary[dict_pos + length] == data[data_pos + length] {
    length = length + 1
  }
  
  length
}

/// Calculate match length in data
/// 计算数据内部的匹配长度
fn calculate_match_length_in_data(data: Bytes, pos: Int, match_pos: Int) -> Int {
  let mut length = 0
  let max_length = (data.length() - pos).min(131072)
  
  while length < max_length &&
        match_pos + length < pos &&
        pos + length < data.length() &&
        data[match_pos + length] == data[pos + length] {
    length = length + 1
  }
  
  length
}

/// Determine if compressed block should be used
/// 判断是否应该使用压缩块
fn should_use_compressed_block(
  data: Bytes,
  sequences: Array[LZSequence],
  literals: Array[Byte]
) -> Bool {
  // 估算压缩后的大小
  let literal_size = literals.length()
  let sequence_size = sequences.length() * 6  // 每个序列约 6 字节
  let estimated_compressed_size = literal_size + sequence_size + 20  // 加上头部
  
  // 如果压缩后小于原始数据的 95%，则使用压缩块
  estimated_compressed_size < (data.length() * 95 / 100)
}

// ============================================================================
// FSE Compressed Mode Implementation
// ============================================================================

/// Count symbol frequencies
fn count_frequencies(symbols: Array[Int], max_symbol: Int) -> Array[Int] {
  let freqs = Array::make(max_symbol + 1, 0)
  for i = 0; i < symbols.length(); i = i + 1 {
    let sym = symbols[i]
    if sym >= 0 && sym <= max_symbol {
      freqs[sym] = freqs[sym] + 1
    }
  }
  freqs
}

/// Normalize frequencies to target sum (2^accuracy_log)
fn normalize_frequencies(freqs: Array[Int], accuracy_log: Int) -> Array[Int] {
  let target = 1 << accuracy_log
  let mut total = 0
  for i = 0; i < freqs.length(); i = i + 1 {
    total = total + freqs[i]
  }

  if total == 0 { return freqs }

  let normalized = Array::make(freqs.length(), 0)
  let mut sum = 0

  for i = 0; i < freqs.length(); i = i + 1 {
    if freqs[i] > 0 {
      let norm = (freqs[i] * target / total).max(1)
      normalized[i] = norm
      sum = sum + norm
    }
  }

  // Adjust to exact target
  while sum > target {
    let mut max_idx = 0
    for i = 0; i < normalized.length(); i = i + 1 {
      if normalized[i] > normalized[max_idx] {
        max_idx = i
      }
    }
    normalized[max_idx] = normalized[max_idx] - 1
    sum = sum - 1
  }

  while sum < target {
    let mut max_idx = 0
    for i = 0; i < normalized.length(); i = i + 1 {
      if normalized[i] > normalized[max_idx] {
        max_idx = i
      }
    }
    normalized[max_idx] = normalized[max_idx] + 1
    sum = sum + 1
  }

  normalized
}

/// Serialize FSE table (simplified version)
fn serialize_fse_table(normalized: Array[Int], accuracy_log: Int, output: Array[Byte]) -> Unit {
  output.push(accuracy_log.to_byte())

  let mut i = 0
  while i < normalized.length() {
    let freq = normalized[i]
    if freq > 0 {
      if freq == 1 {
        output.push((i | 0x80).to_byte())
      } else {
        output.push(i.to_byte())
        output.push(freq.to_byte())
      }
    }
    i = i + 1
  }
  output.push(0xFF)
}

/// Build FSE encoding table from normalized frequencies
/// Check if custom FSE tables would be beneficial
fn should_use_compressed_fse(ll_symbols: Array[Int], ml_symbols: Array[Int], of_symbols: Array[Int]) -> Bool {
  let total = ll_symbols.length()
  if total < 64 { return false }

  let ll_freqs = count_frequencies(ll_symbols, 35)
  let ml_freqs = count_frequencies(ml_symbols, 52)
  let of_freqs = count_frequencies(of_symbols, 31)

  let mut ll_unique = 0
  let mut ml_unique = 0
  let mut of_unique = 0

  for i = 0; i < ll_freqs.length(); i = i + 1 {
    if ll_freqs[i] > 0 { ll_unique = ll_unique + 1 }
  }
  for i = 0; i < ml_freqs.length(); i = i + 1 {
    if ml_freqs[i] > 0 { ml_unique = ml_unique + 1 }
  }
  for i = 0; i < of_freqs.length(); i = i + 1 {
    if of_freqs[i] > 0 { of_unique = of_unique + 1 }
  }

  // Use compressed mode if distributions are skewed
  (ll_unique > 4 && ll_unique < 20) || (ml_unique > 4 && ml_unique < 20) || (of_unique > 3 && of_unique < 15)
}

/// Encode sequences using compressed FSE mode
fn encode_sequences_compressed_fse(sequences: Array[LZSequence], output: Array[Byte]) -> Result[Unit, @zstd_core.ZSTDError] {
  if sequences.length() == 0 { return Ok(()) }

  let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(sequences)

  // Build custom FSE tables
  let ll_freqs = count_frequencies(ll_symbols, 35)
  let ml_freqs = count_frequencies(ml_symbols, 52)
  let of_freqs = count_frequencies(of_symbols, 31)

  let ll_norm = normalize_frequencies(ll_freqs, 6)
  let ml_norm = normalize_frequencies(ml_freqs, 6)
  let of_norm = normalize_frequencies(of_freqs, 5)

  // Serialize FSE tables
  serialize_fse_table(ll_norm, 6, output)
  serialize_fse_table(ml_norm, 6, output)
  serialize_fse_table(of_norm, 5, output)

  // Build FSE encoding tables from normalized frequencies
  let ll_table = match @zstd_entropy.build_fse_ctable(ll_norm, ll_norm.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build LL FSE table: \{e}"))
  }
  let ml_table = match @zstd_entropy.build_fse_ctable(ml_norm, ml_norm.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build ML FSE table: \{e}"))
  }
  let of_table = match @zstd_entropy.build_fse_ctable(of_norm, of_norm.length() - 1, 5) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build OF FSE table: \{e}"))
  }

  let bitstream = @zstd_entropy.create_bitstream()
  let last_idx = sequences.length() - 1

  // Init states with last sequence symbols
  let mut ll_state = @zstd_entropy.init_fse_cstate_with_symbol(ll_table, ll_symbols[last_idx])
  let mut ml_state = @zstd_entropy.init_fse_cstate_with_symbol(ml_table, ml_symbols[last_idx])
  let mut of_state = @zstd_entropy.init_fse_cstate_with_symbol(of_table, of_symbols[last_idx])

  // Write last sequence extras: LL, ML, OF
  let last_seq = sequences[last_idx]
  let (_, last_ll_extra) = @zstd_entropy.encode_ll(last_seq.literal_length)
  let last_ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[last_idx])
  if last_ll_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ll_extra.to_uint64(), last_ll_nbits)
  }

  let (_, last_ml_extra) = @zstd_entropy.encode_ml(last_seq.match_length)
  let last_ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[last_idx])
  if last_ml_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ml_extra.to_uint64(), last_ml_nbits)
  }

  let (_, last_of_extra) = match @zstd_entropy.encode_of(last_seq.offset) {
    Ok(result) => result
    Err(e) => return Err(@zstd_core.message_error("Invalid offset in last sequence: \{e}"))
  }
  let last_of_nbits = @zstd_entropy.get_of_bits(of_symbols[last_idx])
  if last_of_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_of_extra.to_uint64(), last_of_nbits)
  }

  @zstd_entropy.flush_bits(bitstream)

  // Loop from N-2 down to 0
  let mut n = last_idx - 1
  while n >= 0 {
    let seq = sequences[n]

    // State transitions: OF → ML → LL
    of_state = @zstd_entropy.encode_symbol_fse(of_state, of_symbols[n], of_table, bitstream)
    ml_state = @zstd_entropy.encode_symbol_fse(ml_state, ml_symbols[n], ml_table, bitstream)
    ll_state = @zstd_entropy.encode_symbol_fse(ll_state, ll_symbols[n], ll_table, bitstream)

    // Extra bits: LL, ML, OF
    let (_, ll_extra) = @zstd_entropy.encode_ll(seq.literal_length)
    let ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[n])
    if ll_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ll_extra.to_uint64(), ll_nbits)
    }

    let (_, ml_extra) = @zstd_entropy.encode_ml(seq.match_length)
    let ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[n])
    if ml_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ml_extra.to_uint64(), ml_nbits)
    }

    let (_, of_extra) = match @zstd_entropy.encode_of(seq.offset) {
      Ok(result) => result
      Err(e) => return Err(@zstd_core.message_error("Invalid offset in sequence: \{e}"))
    }
    let of_nbits = @zstd_entropy.get_of_bits(of_symbols[n])
    if of_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, of_extra.to_uint64(), of_nbits)
    }

    @zstd_entropy.flush_bits(bitstream)
    n = n - 1
  }

  // Flush final states: ML → OF → LL
  @zstd_entropy.flush_final_state(bitstream, ml_state, 6)
  @zstd_entropy.flush_final_state(bitstream, of_state, 5)
  @zstd_entropy.flush_final_state(bitstream, ll_state, 6)

  @zstd_entropy.close_bitstream(bitstream)

  let encoded = @zstd_entropy.get_bytes(bitstream)
  for i = 0; i < encoded.length(); i = i + 1 {
    output.push(encoded[i])
  }

  Ok(())
}

// ============================================================================
// Compressed Block Implementation / Compressed 块实现
// ============================================================================









/// 获取预定义的 Literal Lengths 归一化频率

/// 获取预定义的 LL 权重表
fn get_predefined_ll_weights_compressor() -> Array[Int] {
  [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1
  ]
}

/// 获取预定义的 ML 权重表
fn get_predefined_ml_weights_compressor() -> Array[Int] {
  [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1
  ]
}

/// 获取预定义的 OF 权重表
fn get_predefined_of_weights_compressor() -> Array[Int] {
  [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
  ]
}

/// 编码 Literal Length 为符号（使用 RFC 8878 标准表）
fn encode_ll_symbol(ll: Int) -> Int {
  let (code, _) = @zstd_entropy.encode_ll(ll)
  code
}

/// 编码 Match Length 为符号（使用 RFC 8878 标准表）
fn encode_ml_symbol(ml: Int) -> Int {
  let (code, _) = @zstd_entropy.encode_ml(ml)
  code
}

/// Encode Offset symbol with repeat offset support
fn encode_of_symbol(offset: Int) -> Int {
  if offset == -1 {
    return 0  // rep[0]
  } else if offset == -2 {
    return 1  // rep[1]
  } else if offset == -3 {
    return 1  // rep[2] (will need extra bit)
  }
  // Validate offset before encoding to avoid abort
  if offset < 1 {
    abort("Invalid offset: must be >= 1")
  }
  match @zstd_entropy.encode_of(offset) {
    Ok((code, _)) => code
    Err(e) => abort("encode_of failed: " + e)
  }
}

/// 提取序列符号（用于 FSE 编码）
fn extract_sequence_symbols(sequences: Array[LZSequence]) -> (Array[Int], Array[Int], Array[Int]) {
  let ll_symbols: Array[Int] = []
  let ml_symbols: Array[Int] = []
  let of_symbols: Array[Int] = []

  for i = 0; i < sequences.length(); i = i + 1 {
    let seq = sequences[i]
    ll_symbols.push(encode_ll_symbol(seq.literal_length))
    ml_symbols.push(encode_ml_symbol(seq.match_length))
    of_symbols.push(encode_of_symbol(seq.offset))
  }

  (ll_symbols, ml_symbols, of_symbols)
}

/// Encode sequences using predefined FSE tables
/// Matches official ZSTD_encodeSequences_body order exactly
/// Encode single sequence directly (RFC 8878: no FSE for single sequence)
fn encode_single_sequence_direct(seq: LZSequence, output: Array[Byte]) -> Unit {
  let ll = seq.literal_length
  let ml = seq.match_length
  let max_value = 16777216
  if ll < 0 || ll >= max_value { abort("LL out of bounds") }
  if ml < 3 || ml >= max_value { abort("ML out of bounds") }

  // Handle repeat offset markers: convert to actual offset values
  // For single sequence, we use initial repeat offsets [1, 4, 8]
  let of = if seq.offset == -1 {
    1  // rep[0]
  } else if seq.offset == -2 {
    4  // rep[1]
  } else if seq.offset == -3 {
    8  // rep[2]
  } else {
    seq.offset
  }
  if of < 1 || of >= max_value { abort("OF out of bounds") }

  // Check for integer overflow: LL + ML + OF must not overflow Int
  // First check ML + OF to avoid underflow in the second check
  if ml > 2147483647 - of { abort("Integer overflow: ML + OF exceeds Int max") }
  if ll > 2147483647 - ml - of { abort("Integer overflow: LL + ML + OF exceeds Int max") }

  // Encode Literal_Length
  if ll < 128 {
    output.push(ll.to_byte())
  } else if ll < 0x7F00 {
    output.push(((ll >> 8) + 128).to_byte())
    output.push((ll & 0xFF).to_byte())
  } else {
    output.push(0xFF)
    let adjusted = ll - 0x7F00
    output.push((adjusted & 0xFF).to_byte())
    output.push(((adjusted >> 8) & 0xFF).to_byte())
  }

  // Encode Offset (stored as offset-1)
  let of_minus_1 = of - 1
  if of_minus_1 < 128 {
    output.push(of_minus_1.to_byte())
  } else if of_minus_1 < 0x7F00 {
    output.push(((of_minus_1 >> 8) + 128).to_byte())
    output.push((of_minus_1 & 0xFF).to_byte())
  } else {
    output.push(0xFF)
    let adjusted = of_minus_1 - 0x7F00
    output.push((adjusted & 0xFF).to_byte())
    output.push(((adjusted >> 8) & 0xFF).to_byte())
  }

  // Encode Match_Length (stored as ml-3)
  let ml_minus_3 = ml - 3
  if ml_minus_3 < 128 {
    output.push(ml_minus_3.to_byte())
  } else if ml_minus_3 < 0x7F00 {
    output.push(((ml_minus_3 >> 8) + 128).to_byte())
    output.push((ml_minus_3 & 0xFF).to_byte())
  } else {
    output.push(0xFF)
    let adjusted = ml_minus_3 - 0x7F00
    output.push((adjusted & 0xFF).to_byte())
    output.push(((adjusted >> 8) & 0xFF).to_byte())
  }
}

fn encode_sequences_predefined_fse(sequences: Array[LZSequence], output: Array[Byte]) -> Result[Unit, @zstd_core.ZSTDError] {
  if sequences.length() == 0 {
    return Ok(())
  }

  let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(sequences)

  let ll_predefined = @zstd_entropy.normalize_counts(get_predefined_ll_weights_compressor(), 6)
  let ml_predefined = @zstd_entropy.normalize_counts(get_predefined_ml_weights_compressor(), 6)
  let of_predefined = @zstd_entropy.normalize_counts(get_predefined_of_weights_compressor(), 5)

  let ll_table = match @zstd_entropy.build_fse_ctable(ll_predefined, ll_predefined.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build LL FSE table: \{e}"))
  }
  let ml_table = match @zstd_entropy.build_fse_ctable(ml_predefined, ml_predefined.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build ML FSE table: \{e}"))
  }
  let of_table = match @zstd_entropy.build_fse_ctable(of_predefined, of_predefined.length() - 1, 5) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build OF FSE table: \{e}"))
  }

  let bitstream = @zstd_entropy.create_bitstream()
  let last_idx = sequences.length() - 1

  // Step 1: Init states with seqN-1 (last sequence) symbols
  let mut ll_state = @zstd_entropy.init_fse_cstate_with_symbol(ll_table, ll_symbols[last_idx])
  let mut ml_state = @zstd_entropy.init_fse_cstate_with_symbol(ml_table, ml_symbols[last_idx])
  let mut of_state = @zstd_entropy.init_fse_cstate_with_symbol(of_table, of_symbols[last_idx])

  // Step 2: Write seqN-1 (last sequence) extras BEFORE the loop: LL, ML, OF
  let last_seq = sequences[last_idx]

  let (_, last_ll_extra) = @zstd_entropy.encode_ll(last_seq.literal_length)
  let last_ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[last_idx])
  if last_ll_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ll_extra.to_uint64(), last_ll_nbits)
  }

  let (_, last_ml_extra) = @zstd_entropy.encode_ml(last_seq.match_length)
  let last_ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[last_idx])
  if last_ml_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ml_extra.to_uint64(), last_ml_nbits)
  }

  let (_, last_of_extra) = match @zstd_entropy.encode_of(last_seq.offset) {
    Ok(result) => result
    Err(e) => return Err(@zstd_core.message_error("Invalid offset in last sequence: \{e}"))
  }
  let last_of_nbits = @zstd_entropy.get_of_bits(of_symbols[last_idx])
  if last_of_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_of_extra.to_uint64(), last_of_nbits)
  }

  @zstd_entropy.flush_bits(bitstream)

  // Step 3: Loop from N-2 down to 0 — encode state transitions + extras
  let mut n = last_idx - 1
  while n >= 0 {
    let seq = sequences[n]

    // State transitions: OF → ML → LL so decoder reads LL → ML → OF (RFC 8878 order)
    of_state = @zstd_entropy.encode_symbol_fse(of_state, of_symbols[n], of_table, bitstream)
    ml_state = @zstd_entropy.encode_symbol_fse(ml_state, ml_symbols[n], ml_table, bitstream)
    ll_state = @zstd_entropy.encode_symbol_fse(ll_state, ll_symbols[n], ll_table, bitstream)

    // Extra bits: LL, ML, OF (official order)
    let (_, ll_extra) = @zstd_entropy.encode_ll(seq.literal_length)
    let ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[n])
    if ll_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ll_extra.to_uint64(), ll_nbits)
    }

    let (_, ml_extra) = @zstd_entropy.encode_ml(seq.match_length)
    let ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[n])
    if ml_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ml_extra.to_uint64(), ml_nbits)
    }

    let (_, of_extra) = match @zstd_entropy.encode_of(seq.offset) {
      Ok(result) => result
      Err(e) => return Err(@zstd_core.message_error("Invalid offset in sequence: \{e}"))
    }
    let of_nbits = @zstd_entropy.get_of_bits(of_symbols[n])
    if of_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, of_extra.to_uint64(), of_nbits)
    }

    @zstd_entropy.flush_bits(bitstream)
    n = n - 1
  }

  // Step 4: Flush final states: ML → OF → LL (official order)
  @zstd_entropy.flush_final_state(bitstream, ml_state, 6)
  @zstd_entropy.flush_final_state(bitstream, of_state, 5)
  @zstd_entropy.flush_final_state(bitstream, ll_state, 6)

  // Step 5: Close bitstream (padding bit)
  @zstd_entropy.close_bitstream(bitstream)

  let encoded = @zstd_entropy.get_bytes(bitstream)
  for i = 0; i < encoded.length(); i = i + 1 {
    output.push(encoded[i])
  }

  Ok(())
}

/// Compress as compressed block with dictionary ID
fn compress_as_compressed_block_with_dict(
  data: Bytes,
  sequences: Array[LZSequence],
  literals: Array[Byte],
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header with Dictionary ID
  let fhd: Byte = 0x23
  output.push(fhd)

  // Dictionary ID (4 bytes, little-endian)
  write_dict_id(output, dict_id)

  // Frame Content Size
  write_frame_content_size_with_dict(output, data.length(), 4)

  let block_content = match build_predefined_compressed_block_payload_from_sequences(sequences, literals) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }

  // Block Header
  let block_size = block_content.length()
  write_block_header(output, true, 2, block_size)

  append_bytes_to_output(output, block_content)

  Ok(Bytes::from_array(output))
}

/// Compress as RLE block with dictionary ID
fn compress_as_rle_block_with_dict(data: Bytes, dict_id: UInt) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }
  
  let first_byte = data[0]
  let mut all_same = true
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] != first_byte {
      all_same = false
      break
    }
  }
  
  if !all_same {
    return compress_as_raw_block_with_dict(data, dict_id)
  }
  
  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header with Dictionary ID
  let fhd: Byte = 0x23
  output.push(fhd)
  
  // Dictionary ID
  write_dict_id(output, dict_id)

  // Frame Content Size
  write_frame_content_size_with_dict(output, data.length(), 4)

  // Emit one or more RLE blocks, each with decompressed size ≤ ZSTD_MAX_BLOCK_SIZE
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE
  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    write_block_header(output, is_last, 1, chunk_size)
    output.push(first_byte)
    pos = pos + chunk_size
  }
  
  Ok(Bytes::from_array(output))
}
