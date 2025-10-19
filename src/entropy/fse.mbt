/// Finite State Entropy (FSE) decoder implementation
/// Used for decoding sequence distributions (Literal Lengths, Match Lengths, Offsets)
/// Following RFC 8878 specification
///
/// TODO: 实现 FSE 编码器
/// - [ ] FSE 表构建（用于编码）
/// - [ ] FSE 符号编码
/// - [ ] 权重归一化算法
/// - [ ] 表序列化输出

/// Sequence structure
pub struct Sequence {
  literal_length: Int
  match_length: Int
  offset: Int
} derive(Default)

/// Create new sequence
pub fn make_sequence(literal_length: Int, match_length: Int, offset: Int) -> Sequence {
  Sequence::{ literal_length, match_length, offset }
}

/// FSE表结构
pub struct FSETable {
  symbols: Array[Int]
  num_bits: Array[Int]
  table_log: Int
  max_symbol: Int
  total_count: Int
} derive(Default)

/// FSE状态
pub struct FSEState {
  state: Int
  table: FSETable
} derive(Default)

/// 创建空的FSE表
pub fn create_fse_table() -> FSETable {
  FSETable::{
    symbols: [],
    num_bits: [],
    table_log: 0,
    max_symbol: 0,
    total_count: 0
  }
}

/// 创建FSE表
pub fn create_fse_table_with_params(
  symbols: Array[Int],
  num_bits: Array[Int],
  table_log: Int,
  max_symbol: Int,
  total_count: Int
) -> FSETable {
  FSETable::{ symbols, num_bits, table_log, max_symbol, total_count }
}

/// 解析FSE权重并构建表
pub fn build_fse_table_from_weights(weights: Array[Int], table_log: Int) -> Result[FSETable, String] {
  let max_symbol = weights.length() - 1
  let mut total_count = 0
  
  // 计算总权重
  for i = 0; i < weights.length(); i = i + 1 {
    total_count = total_count + weights[i]
  }
  
  if total_count == 0 {
    return Err("所有权重都为零")
  }
  
  // 计算归一化因子
  let scale = (1 << table_log) / total_count
  let normalized_weights: Array[Int] = []
  let symbols: Array[Int] = []
  let num_bits: Array[Int] = []
  
  // 归一化权重
  for i = 0; i < weights.length(); i = i + 1 {
    let normalized = (weights[i] * scale).max(1)
    normalized_weights.push(normalized)
  }
  
  // 构建符号表
  for i = 0; i < weights.length(); i = i + 1 {
    for _j = 0; _j < normalized_weights[i]; _j = _j + 1 {
      symbols.push(i)
    }
  }
  
  // 计算每个符号的位数
  for i = 0; i < weights.length(); i = i + 1 {
    if normalized_weights[i] > 0 {
      // 简单的对数近似：log2(x) ≈ 31 - clz(x)
      let weight = normalized_weights[i]
      let bits = if weight <= 0 { 0 } else { table_log - (31 - weight.clz()) }
      num_bits.push(bits.max(1))
    } else {
      num_bits.push(0)
    }
  }
  
  Ok(create_fse_table_with_params(symbols, num_bits, table_log, max_symbol, total_count))
}

/// 创建FSE状态
pub fn create_fse_state(table: FSETable) -> FSEState {
  FSEState::{ state: 0, table: table }
}

/// 初始化FSE状态
pub fn init_fse_state(state: FSEState, initial_value: Int) -> FSEState {
  FSEState::{ state: initial_value, table: state.table }
}

/// 从位流中读取FSE值
pub fn fse_decode_symbol(state: FSEState, bitstream: Bytes, bit_pos: Int) -> Result[(Int, Int, Int), String] {
  let table = state.table
  let state_value = state.state
  
  if state_value >= table.symbols.length() {
    return Err("FSE状态值超出范围")
  }
  
  let symbol = table.symbols[state_value]
  let bits_to_read = if symbol < table.num_bits.length() { table.num_bits[symbol] } else { 1 }
  
  // 从位流中读取位数
  let mut new_state = 0
  let mut current_bit_pos = bit_pos
  for i = 0; i < bits_to_read; i = i + 1 {
    let byte_pos = current_bit_pos / 8
    let bit_offset = current_bit_pos % 8
    
    if byte_pos >= bitstream.length() {
      return Err("位流数据不足")
    }
    
    let bit = (bitstream[byte_pos].to_int() >> bit_offset) & 1
    new_state = new_state | (bit << i)
    current_bit_pos = current_bit_pos + 1
  }
  
  Ok((symbol, new_state, current_bit_pos))
}

/// 批量解码FSE值
pub fn fse_decode_multiple(
  table: FSETable,
  bitstream: Bytes,
  bit_pos: Int,
  count: Int
) -> Result[(Array[Int], Int), String] {
  let result: Array[Int] = []
  let mut state = create_fse_state(table)
  let mut current_bit_pos = bit_pos
  
  for _i = 0; _i < count; _i = _i + 1 {
    let decode_result = fse_decode_symbol(state, bitstream, current_bit_pos)
    match decode_result {
      Ok((symbol, new_state, new_bit_pos)) => {
        result.push(symbol)
        state = FSEState::{ state: new_state, table: table }
        current_bit_pos = new_bit_pos
      }
      Err(e) => return Err(e)
    }
  }
  
  Ok((result, current_bit_pos))
}

/// 解析FSE表头
pub fn parse_fse_table_header(data: Bytes, offset: Int) -> Result[(Array[Int], Int, Int), String] {
  if offset >= data.length() {
    return Err("FSE表头数据不足")
  }
  
  let header_byte = data[offset].to_int()
  let accuracy_log = (header_byte & 0x0F) + 5  // 5-12
  let table_log = accuracy_log.min(12)
  
  let mut current_offset = offset + 1
  let weights: Array[Int] = []
  
  // 解析权重
  let mut i = 0
  while i < 256 && current_offset < data.length() {
    let weight_byte = data[current_offset].to_int()
    current_offset = current_offset + 1
    
    if weight_byte < 128 {
      // 单字节权重
      weights.push(weight_byte)
      i = i + 1
    } else {
      // 重复权重
      let repeat_count = weight_byte - 128
      let next_byte = if current_offset < data.length() { data[current_offset].to_int() } else { 0 }
      current_offset = current_offset + 1
      
      for _j = 0; _j < repeat_count; _j = _j + 1 {
        weights.push(next_byte)
        i = i + 1
      }
    }
  }
  
  Ok((weights, table_log, current_offset - offset))
}

/// 解码FSE压缩的序列
/// 使用 tANS 位流解码，与编码器完全对齐
pub fn decode_fse_sequences(
  data: Bytes,
  offset: Int,
  num_sequences: Int,
  ll_weights: Array[Int],
  ml_weights: Array[Int],
  of_weights: Array[Int]
) -> Result[Array[Sequence], String] {
  // 禁用过多调试输出
  // println("🔍 FSE解码开始: num_sequences=\{num_sequences}, offset=\{offset}")
  
  if num_sequences == 0 {
    return Ok([])
  }
  
  // 构建FSE解码表
  let ll_dtable = build_fse_dtable(ll_weights, 6)
  let ml_dtable = build_fse_dtable(ml_weights, 6)
  let of_dtable = build_fse_dtable(of_weights, 5)
  
  // 创建位流解码器
  // ⚠️ 关键：tANS最终状态在位流末尾！
  // 需要先读取末尾的最终状态（17位：LL 6位 + ML 6位 + OF 5位）
  // 然后再从前面解码符号数据
  
  // 初始化DStream
  let fse_data_len = data.length() - offset
  if fse_data_len < 1 {
    return Err("FSE data too short")
  }
  
  // 初始化 bitstream（参照官方 BIT_initDStream）
  let bitstream = BitstreamReader::{
    data: data,
    offset: 0,
    bit_container: 0UL,
    bit_pos: 0,
    end_offset: offset
  }
  
  let temp_bs = bitstream
  
  if fse_data_len >= 8 {
    // ✅ Normal case: 完全参照官方 bitstream.h:261-266
    // ptr = srcBuffer + srcSize - sizeof(bitContainer)
    temp_bs.offset = offset + fse_data_len - 8
    
    // bitContainer = MEM_readLEST(ptr) - 读取8字节little-endian
    let mut container = 0UL
    for i = 0; i < 8; i = i + 1 {
      let byte_val = data[temp_bs.offset + i].to_uint64()
      container = container | (byte_val << (i * 8))
      if num_sequences == 9 && i < 8 {
        println("    data[\{temp_bs.offset + i}] = \{data[temp_bs.offset + i].to_int()}")
      }
    }
    temp_bs.bit_container = container
    
    if num_sequences == 9 {
      println("    bit_container低32位 = \{(container & 0xFFFFFFFFUL).to_int()}")
    }
    
    // bitsConsumed = lastByte ? 8 - ZSTD_highbit32(lastByte) : 0
    let last_byte_idx = offset + fse_data_len - 1
    let last_byte = data[last_byte_idx].to_int()
    // ⚠️ 实验性修复：调整offset使其指向最后字节
    let bits_consumed_raw = if last_byte == 0 { 0 } else { 8 - highbit32(last_byte) }
    // bits_consumed应该是相对于64位容器的，需要加上偏移
    let bits_consumed = bits_consumed_raw
    temp_bs.bit_pos = bits_consumed
  } else {
    // ✅ Small data case: 完全参照官方 bitstream.h:268-296
    temp_bs.offset = offset
    let mut container = 0UL
    for i = 0; i < fse_data_len; i = i + 1 {
      let byte_val = data[offset + i].to_uint64()
      container = container | (byte_val << (i * 8))
    }
    temp_bs.bit_container = container
    
    let last_byte_idx = offset + fse_data_len - 1
    let last_byte = data[last_byte_idx].to_int()
    let bits_consumed_byte = if last_byte == 0 { 0 } else { 8 - highbit32(last_byte) }
    
    // ✅ 官方：bitsConsumed += (sizeof(bitContainer) - srcSize)*8
    let extra_bits = (8 - fse_data_len) * 8
    let bits_consumed = bits_consumed_byte + extra_bits
    temp_bs.bit_pos = bits_consumed
  }
  
  // ✅ 从 bitstream 读取初始状态（参照官方 ZSTD_initFseState）
  // 编码器写入顺序（从低到高）：ML → OF → LL
  // Bitstream从高位读取，所以读取顺序：LL (先读) → OF (中) → ML (后读)
  
  // Read LL state (6 bits)
  let (bs1, ll_state_raw) = read_bits_uint64(temp_bs, 6)
  
  // Read OF state (5 bits)
  let (bs2, of_state_raw) = read_bits_uint64(bs1, 5)
  
  // Read ML state (6 bits)
  let (bs3, ml_state_raw) = read_bits_uint64(bs2, 6)
  let bs_after_ml_reload = bs3
  
  // 加上 table_size 得到完整状态
  let ll_s = ll_state_raw + 64UL  // LL table_log=6
  let of_s = of_state_raw + 32UL  // OF table_log=5
  let ml_s = ml_state_raw + 64UL  // ML table_log=6
  
  // 解码序列（正向解码）
  let sequences: Array[Sequence] = []
  let mut current_bs = bs_after_ml_reload  // ✅ 使用最后一次reload后的 bitstream
  let mut ll_state = ll_s
  let mut ml_state = ml_s
  let mut of_state = of_s
  
  // 正向解码（RFC 8878: 读取符号顺序 OF -> ML -> LL，更新状态顺序 LL -> ML -> OF）
  for i = 0; i < num_sequences; i = i + 1 {
    let is_last_seq = (i == num_sequences - 1)
    
    // 查表获取符号
    let of_e = get_fse_decode_entry(of_state.to_int(), of_dtable, 5)
    let ml_e = get_fse_decode_entry(ml_state.to_int(), ml_dtable, 6)
    let ll_e = get_fse_decode_entry(ll_state.to_int(), ll_dtable, 6)

    let of_code = match of_e {
      Some(entry) => entry.symbol
      None => 0
    }
    let ml_code = match ml_e {
      Some(entry) => entry.symbol
      None => 0
    }
    let ll_code = match ll_e {
      Some(entry) => entry.symbol
      None => 0
    }
    
    let (of_entry, ml_entry, ll_entry) = if is_last_seq {
      (None, None, None)
    } else {
      (of_e, ml_e, ll_e)
    }
    
    // 读取额外位（参照官方 line 1294, 1326, 1335：OF → ML → LL）
    let of_nb_bits = get_of_bits(of_code)
    let ml_nb_bits = get_ml_bits(ml_code)
    let ll_nb_bits = get_ll_bits(ll_code)
    
    // OF extra bits
    let (bs_tmp1, of_extra_bits) = read_bits_uint64(current_bs, of_nb_bits)
    
    // ML extra bits  
    let (bs_tmp2, ml_extra_bits) = read_bits_uint64(bs_tmp1, ml_nb_bits)
    
    // LL extra bits (暂时禁用中间reload测试)
    let (bs_after_ll, ll_extra_bits) = read_bits_uint64(bs_tmp2, ll_nb_bits)
    
    // 步骤3: 如果不是最后一个序列，按 LL -> ML -> OF 的顺序更新状态
    let final_bs = if !is_last_seq {
      let (bs1, new_ll_state) = match ll_entry {
        Some(entry) => {
          let table_size = 64  // LL table_log = 6
          let (new_bs, extra) = read_bits_uint64(bs_after_ll, entry.nb_bits)
          let new_state = entry.new_state_base + extra.to_int() + table_size
          (new_bs, new_state)
        }
        None => (bs_after_ll, 64)
      }
      
      let (bs2, new_ml_state) = match ml_entry {
        Some(entry) => {
          let table_size = 64  // ML table_log = 6
          let (new_bs, extra) = read_bits_uint64(bs1, entry.nb_bits)
          let new_state = entry.new_state_base + extra.to_int() + table_size
          (new_bs, new_state)
        }
        None => (bs1, 64)
      }
      
      let (bs3, new_of_state) = match of_entry {
        Some(entry) => {
          let table_size = 32  // OF table_log = 5
          let (new_bs, extra) = read_bits_uint64(bs2, entry.nb_bits)
          let new_state = entry.new_state_base + extra.to_int() + table_size
          (new_bs, new_state)
        }
        None => (bs2, 32)
      }
      
      // 更新状态变量
      ll_state = new_ll_state.to_uint64()
      ml_state = new_ml_state.to_uint64()
      of_state = new_of_state.to_uint64()
      
      bs3  // 暂时不reload
    } else {
      bs_after_ll
    }
    
    // 将符号代码和额外位转换为实际值
    let literal_length = decode_ll(ll_code, ll_extra_bits.to_int())
    let match_length = decode_ml(ml_code, ml_extra_bits.to_int())
    let offset = decode_of(of_code, of_extra_bits.to_int())
    
    if i == 0 && num_sequences == 9 {
      println("  序列0解码: ll_code=\{ll_code}+\{ll_extra_bits}=\{literal_length}, ml_code=\{ml_code}+\{ml_extra_bits}=\{match_length}, of_code=\{of_code}+\{of_extra_bits}=\{offset}")
    }
    
    sequences.push(make_sequence(literal_length, match_length, offset))
    current_bs = final_bs
  }
  
  println("  ✅ FSE解码完成: 解码了 \{sequences.length()} 个序列")
  Ok(sequences)
}


/// 位流读取器（用于解码，支持反向读取）
priv struct BitstreamReader {
  data: Bytes
  mut offset: Int  // 当前读取位置（反向读取时从高地址往低地址）
  mut bit_container: UInt64
  mut bit_pos: Int  // 当前容器中已使用的位数
  end_offset: Int  // 结束位置（不包含）
}

/// Reload bitstream（完全参照官方 BIT_reloadDStream_internal）
fn reload_bitstream(bs: BitstreamReader) -> BitstreamReader {
  // 检查溢出
  if bs.bit_pos > 64 {
    return bs  // overflow
  }
  
  // ✅ 无条件执行（官方没有检查bytes_consumed==0）
  // ptr -= bitsConsumed >> 3
  let bytes_consumed = bs.bit_pos / 8
  let new_offset = bs.offset - bytes_consumed
  
  // 检查边界
  if new_offset < bs.end_offset {
    return bs  // 无法往前移动
  }
  
  bs.offset = new_offset
  
  // bitsConsumed &= 7
  bs.bit_pos = bs.bit_pos % 8
  
  // bitContainer = MEM_readLEST(ptr) - 重新加载8字节
  let mut container = 0UL
  for i = 0; i < 8; i = i + 1 {
    if bs.offset + i < bs.data.length() {
      let byte_val = bs.data[bs.offset + i].to_uint64()
      container = container | (byte_val << (i * 8))
    }
  }
  bs.bit_container = container
  
  bs
}

/// 从位流读取指定位数（反向读取：从高地址往低地址）
fn read_bits_uint64(bs: BitstreamReader, nb_bits: Int) -> (BitstreamReader, UInt64) {
  if nb_bits <= 0 {
    return (bs, 0UL)
  }
  
  // ✅ 简化实现：调用者负责显式reload
  // 读取位（从高位开始，参照官方 BIT_lookBits + BIT_skipBits）
  // start = 64 - bitsConsumed - nbBits
  let start = 64 - bs.bit_pos - nb_bits
  let mask = if nb_bits >= 64 { 0xFFFFFFFFFFFFFFFFUL } else { (1UL << nb_bits) - 1UL }
  let value = (bs.bit_container >> start) & mask
  
  // bitsConsumed += nbBits
  bs.bit_pos = bs.bit_pos + nb_bits
  
  (bs, value)
}


/// 基本FSE测试
pub fn test_basic_fse() -> Bool {
  let weights: Array[Int] = [1, 2, 3, 4, 5]
  let table_result = build_fse_table_from_weights(weights, 6)
  
  match table_result {
    Ok(table) => table.symbols.length() > 0
    Err(_) => false
  }
}

// ============================================================================
// FSE Encoder Implementation / FSE 编码器实现
// ============================================================================

// ============================================================================
// BitStream Implementation / 位流实现
// ============================================================================

/// 位流结构 - 用于 tANS 编码输出
pub struct BitStream {
  buffer: Array[Byte]           // 输出缓冲区
  mut bit_container: UInt64     // 64位容器
  mut bit_pos: Int              // 容器中的位位置 (0-63)
}

/// 创建新的位流
pub fn create_bitstream() -> BitStream {
  BitStream::{
    buffer: [],
    bit_container: 0UL,
    bit_pos: 0
  }
}

/// 添加位到位流
/// value: 要添加的值
/// nb_bits: 位数 (1-64)
pub fn add_bits(stream: BitStream, value: UInt64, nb_bits: Int) -> Unit {
  if nb_bits <= 0 || nb_bits > 64 {
    return
  }
  
  // 将值添加到容器
  let mask = if nb_bits >= 64 { 0xFFFFFFFFFFFFFFFFUL } else { (1UL << nb_bits) - 1UL }
  let masked_value = value & mask
  stream.bit_container = stream.bit_container | (masked_value << stream.bit_pos)
  stream.bit_pos = stream.bit_pos + nb_bits
  
  // 如果容器满了，刷新到缓冲区
  while stream.bit_pos >= 8 {
    stream.buffer.push((stream.bit_container & 0xFFUL).to_byte())
    stream.bit_container = stream.bit_container >> 8
    stream.bit_pos = stream.bit_pos - 8
  }
}

/// 刷新位流（输出剩余位）
pub fn flush_bits(stream: BitStream) -> Unit {
  // 将剩余位输出
  while stream.bit_pos > 0 {
    stream.buffer.push((stream.bit_container & 0xFFUL).to_byte())
    stream.bit_container = stream.bit_container >> 8
    stream.bit_pos = (stream.bit_pos - 8).max(0)
  }
}

/// 获取位流输出的字节
pub fn get_bytes(stream: BitStream) -> Bytes {
  Bytes::from_array(stream.buffer)
}

/// 获取位流当前位置（用于调试）
pub fn get_bitstream_pos(stream: BitStream) -> Int {
  stream.bit_pos
}

/// 获取位流缓冲区长度（用于调试）
pub fn get_buffer_length(stream: BitStream) -> Int {
  stream.buffer.length()
}

// ============================================================================
// FSE Encoding Tables / FSE 编码表
// ============================================================================

/// 符号转换结构 - 用于 tANS 状态转换
pub struct SymbolTransform {
  delta_nb_bits: Int      // (maxBitsOut << 16) - minStatePlus
  delta_find_state: Int   // total - normalizedCounter[s]
}

/// FSE 编码表（用于编码）
pub struct FSECTable {
  symbol_tt: Array[SymbolTransform]  // 符号转换表
  state_table: Array[UInt16]         // 状态表：存储下一个状态值（tableSize+u）
  symbol_table: Array[Int]           // 符号查找表：state -> symbol映射（用于解码）
  table_log: Int                     // Log2 of table size
  normalized: Array[Int]             // 归一化频率
  max_symbol: Int                    // 最大符号值
}

/// FSE 解码表项
priv struct FSEDecodeEntry {
  symbol: Int        // 符号
  nb_bits: Int       // 需要读取的位数
  new_state_base: Int  // 新状态的基础值
}

/// 构建 FSE 解码表
/// 为每个状态值 [table_size, 2*table_size) 构建解码项
fn build_fse_dtable(normalized: Array[Int], table_log: Int) -> Array[FSEDecodeEntry] {
  let table_size = 1 << table_log
  let dtable: Array[FSEDecodeEntry] = Array::make(table_size, FSEDecodeEntry::{ symbol: 0, nb_bits: 0, new_state_base: 0 })
  
  // 第一步：构建 table_symbol (spread algorithm) - 与编码器相同
  let table_symbol: Array[Int] = Array::make(table_size, 0)
  let mut position = 0
  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    let freq = normalized[symbol]
    // ✅ 频率 -1 表示低频符号（频率为 1），频率 0 表示未使用符号
    if freq == 0 { continue }
    
    let actual_freq = if freq == -1 { 1 } else { freq }
    for _i = 0; _i < actual_freq; _i = _i + 1 {
      table_symbol[position] = symbol
      position = (position + step) & mask
    }
  }
  
  // table_symbol构建完成
  
  // 第二步：计算每个符号的累积位置 (cumul)
  let cumul: Array[Int] = Array::make(normalized.length() + 1, 0)
  for s = 0; s < normalized.length(); s = s + 1 {
    let norm = normalized[s]
    if norm == -1 {
      cumul[s + 1] = cumul[s] + 1
    } else if norm > 0 {
      cumul[s + 1] = cumul[s] + norm
    } else {
      cumul[s + 1] = cumul[s]
    }
  }
  
  // 第三步：构建状态表（用于编码的表，我们需要反向使用）
  // 使用与编码器相同的算法构建 state_table
  let state_table: Array[UInt16] = Array::make(table_size, 0)
  let cumul_copy: Array[Int] = Array::make(normalized.length(), 0)
  for s = 0; s < normalized.length(); s = s + 1 {
    cumul_copy[s] = cumul[s]
  }
  
  for u = 0; u < table_size; u = u + 1 {
    let s = table_symbol[u]
    let idx = cumul_copy[s]
    cumul_copy[s] = idx + 1
    if idx < state_table.length() {
      state_table[idx] = (table_size + u).to_uint16()
    }
  }
  
  // 第四步：为每个状态位置 u 构建解码项
  // 根据 ZSTD 参考实现（fse_decompress.c）
  // symbol_next[s] 跟踪每个符号的"下一个状态值"，初始化为归一化频率
  let symbol_next: Array[Int] = Array::make(normalized.length(), 0)
  for s = 0; s < normalized.length(); s = s + 1 {
    let norm = normalized[s]
    // 对于频率为-1的符号，设为1；其他设为归一化频率
    symbol_next[s] = if norm == -1 { 1 } else if norm > 0 { norm } else { 0 }
  }
  
  for u = 0; u < table_size; u = u + 1 {
    let symbol = table_symbol[u]
    let next_state = symbol_next[symbol]
    symbol_next[symbol] = next_state + 1
    
    // ZSTD 参考实现的公式:
    // nbBits = tableLog - BIT_highbit32(nextState)
    // newStateBaseline = (nextState << nbBits) - tableSize
    let nb_bits = table_log - highbit32(next_state)
    let new_state_base = (next_state << nb_bits) - table_size
    
    dtable[u] = FSEDecodeEntry::{ 
      symbol: symbol, 
      nb_bits: nb_bits, 
      new_state_base: new_state_base
    }
  }
  
  dtable
}

/// 使用解码表从 FSE 状态解码符号
/// state: 当前状态 (在 [table_size, 2*table_size) 范围内)
/// dtable: 解码表
/// table_log: 表的对数大小
/// 获取FSE解码表项
fn get_fse_decode_entry(
  state: Int,
  dtable: Array[FSEDecodeEntry],
  table_log: Int
) -> Option[FSEDecodeEntry] {
  let table_size = 1 << table_log
  let u = state - table_size
  
  if u < 0 || u >= dtable.length() {
    println("    ⚠️ 状态越界: state=\{state}, u=\{u}, table_size=\{table_size}")
    None
  } else {
    Some(dtable[u])
  }
}

/// 返回: (new_bitstream, new_state, symbol)
fn decode_fse_symbol_dtable(
  bs: BitstreamReader,
  state: Int,
  dtable: Array[FSEDecodeEntry],
  table_log: Int
) -> (BitstreamReader, Int, Int) {
  let table_size = 1 << table_log
  
  // 将状态映射到表索引: u = state - table_size
  let u = state - table_size
  
  // 边界检查
  if u < 0 || u >= dtable.length() {
    println("    ⚠️ 状态越界: state=\{state}, u=\{u}, table_size=\{table_size}")
    return (bs, table_size, 0)  // 返回默认状态和符号
  }
  
  // 查找解码表项
  let entry = dtable[u]
  
  // 读取额外位
  let (new_bs, extra_bits) = read_bits_uint64(bs, entry.nb_bits)
  
  // ZSTD 参考实现的解码公式:
  // new_state = newState + extra_bits + tableSize
  // 其中 newState = (nextState << nbBits) - tableSize (已存储在表中)
  //
  // 所以: new_state = entry.new_state_base + extra_bits + tableSize
  let new_state = entry.new_state_base + extra_bits.to_int() + table_size
  
  (new_bs, new_state, entry.symbol)
}

/// 旧的 FSE 编码表（兼容性）
pub struct FSEEncodeTable {
  state_table: Array[Int]       // State transition table
  symbol_table: Array[Int]      // Symbol for each state
  num_bits_table: Array[Int]    // Number of bits for each symbol
  next_state_table: Array[Array[Int]]  // Next state for each symbol and bits value
  table_log: Int                // Log2 of table size
  normalized_counts: Array[Int] // Normalized symbol frequencies
  max_symbol: Int               // Maximum symbol value
}

// ============================================================================
// Helper Functions / 辅助函数
// ============================================================================

/// 计算最高位位置 (log2)
fn highbit32(v: Int) -> Int {
  if v <= 0 { return 0 }
  31 - v.clz()
}

/// 构建符号转换表
/// 根据归一化频率构建 tANS 状态转换表
pub fn build_symbol_transform_table(
  normalized: Array[Int],
  table_log: Int,
  max_symbol: Int
) -> Array[SymbolTransform] {
  let table_size = 1 << table_log
  let symbol_tt: Array[SymbolTransform] = []
  
  // 第一遍：为每个符号分配在状态表中的位置
  let cumul: Array[Int] = [0]  // cumul[s] = 符号s在状态表中的起始位置
  for s = 0; s <= max_symbol; s = s + 1 {
    let norm = normalized[s]
    if norm == -1 {
      cumul.push(cumul[s] + 1)
    } else if norm >= 1 {
      cumul.push(cumul[s] + norm)
    } else {
      cumul.push(cumul[s])
    }
  }
  
  // 第二遍：构建SymbolTransform表
  // 按照官方实现（fse_compress.c:176-200）
  let mut total = 0
  for s = 0; s <= max_symbol; s = s + 1 {
    let norm = normalized[s]
    
    if norm == 0 {
      // 零频率符号 - 不会被编码
      symbol_tt.push(SymbolTransform::{
        delta_nb_bits: ((table_log + 1) << 16) - table_size,
        delta_find_state: table_size  // 设置为table_size，确保不会被使用
      })
    } else if norm == -1 || norm == 1 {
      // 特殊低频符号 (-1或1表示频率为1)
      symbol_tt.push(SymbolTransform::{
        delta_nb_bits: (table_log << 16) - table_size,
        delta_find_state: total - 1  // 官方: total - 1
      })
      total = total + 1
    } else {
      // 正常符号 (norm > 1)
      let max_bits_out = table_log - highbit32(norm - 1)
      let min_state_plus = norm << max_bits_out
      symbol_tt.push(SymbolTransform::{
        delta_nb_bits: (max_bits_out << 16) - min_state_plus,
        delta_find_state: total - norm  // 官方: total - norm
      })
      total = total + norm
    }
  }
  
  symbol_tt
}

/// 构建状态表（ZSTD标准实现）
/// 返回：(state_table, symbol_table)
/// state_table存储的是下一个状态值（tableSize+u），symbol_table存储state->symbol映射
fn build_state_table(normalized: Array[Int], table_log: Int) -> (Array[UInt16], Array[Int]) {
  let table_size = 1 << table_log
  let state_table: Array[UInt16] = Array::make(table_size, 0)
  let symbol_table: Array[Int] = Array::make(table_size, 0)
  
  // 第一步：构建tableSymbol - 每个位置对应的符号
  let table_symbol: Array[Int] = Array::make(table_size, 0)
  let mut position = 0
  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    let freq = normalized[symbol]
    // ✅ 频率 -1 表示低频符号（频率为 1），频率 0 表示未使用符号
    if freq == 0 { continue }
    
    let actual_freq = if freq == -1 { 1 } else { freq }
    for _i = 0; _i < actual_freq; _i = _i + 1 {
      table_symbol[position] = symbol
      position = (position + step) & mask
    }
  }
  
  // 第二步：构建cumul数组 - 每个符号在stateTable中的起始位置
  let cumul: Array[Int] = Array::make(normalized.length() + 1, 0)
  for s = 1; s <= normalized.length(); s = s + 1 {
    let norm = if s - 1 < normalized.length() { normalized[s - 1] } else { 0 }
    cumul[s] = cumul[s - 1] + (if norm == -1 { 1 } else if norm > 0 { norm } else { 0 })
  }
  
  // 第三步：填充stateTable
  for u = 0; u < table_size; u = u + 1 {
    let s = table_symbol[u]
    let idx = cumul[s]
    cumul[s] = idx + 1
    if idx < state_table.length() {
      state_table[idx] = (table_size + u).to_uint16()  // 存储下一个状态值
    }
  }
  
  // 第四步：填充symbol_table（u -> symbol映射，用于解码）
  // symbol_table[u] = table_symbol[u]，其中u是0到tableSize-1
  for u = 0; u < table_size; u = u + 1 {
    symbol_table[u] = table_symbol[u]
  }
  
  (state_table, symbol_table)
}

/// 构建完整的 FSE 编码表
pub fn build_fse_ctable(
  normalized: Array[Int],
  max_symbol: Int,
  table_log: Int
) -> Result[FSECTable, String] {
  if table_log < 5 || table_log > 12 {
    return Err("table_log must be between 5 and 12")
  }
  
  // 构建符号转换表
  let symbol_tt = build_symbol_transform_table(normalized, table_log, max_symbol)
  
  // 构建状态表和符号查找表
  let (state_table, symbol_table) = build_state_table(normalized, table_log)
  
  Ok(FSECTable::{
    symbol_tt: symbol_tt,
    state_table: state_table,
    symbol_table: symbol_table,
    table_log: table_log,
    normalized: normalized,
    max_symbol: max_symbol
  })
}

/// 统计符号频率
pub fn count_symbols(data: Array[Int], max_symbol: Int) -> Array[Int] {
  let counts = Array::make(max_symbol + 1, 0)
  for i = 0; i < data.length(); i = i + 1 {
    let symbol = data[i]
    if symbol >= 0 && symbol <= max_symbol {
      counts[symbol] = counts[symbol] + 1
    }
  }
  counts
}

/// 归一化频率到 2^tableLog
pub fn normalize_counts(counts: Array[Int], table_log: Int) -> Array[Int] {
  let table_size = 1 << table_log
  let mut total = 0
  
  // 计算总频率
  for i = 0; i < counts.length(); i = i + 1 {
    total = total + counts[i]
  }
  
  if total == 0 {
    return Array::make(counts.length(), 0)
  }
  
  let normalized: Array[Int] = []
  let mut distributed = 0
  
  // 归一化每个符号的频率
  for i = 0; i < counts.length(); i = i + 1 {
    if counts[i] == 0 {
      normalized.push(0)
    } else {
      // 计算归一化后的频率
      let norm = (counts[i] * table_size) / total
      let final_norm = if norm == 0 { 1 } else { norm }  // 至少为1
      normalized.push(final_norm)
      distributed = distributed + final_norm
    }
  }
  
  // 调整以确保总和等于 table_size
  if distributed < table_size {
    // 给最频繁的符号添加剩余
    let mut max_idx = 0
    let mut max_count = counts[0]
    for i = 1; i < counts.length(); i = i + 1 {
      if counts[i] > max_count {
        max_count = counts[i]
        max_idx = i
      }
    }
    normalized[max_idx] = normalized[max_idx] + (table_size - distributed)
  } else if distributed > table_size {
    // 从最频繁的符号减去多余
    let mut max_idx = 0
    let mut max_norm = normalized[0]
    for i = 1; i < normalized.length(); i = i + 1 {
      if normalized[i] > max_norm {
        max_norm = normalized[i]
        max_idx = i
      }
    }
    normalized[max_idx] = normalized[max_idx] - (distributed - table_size)
  }
  
  normalized
}

/// 构建 FSE 编码表（完整状态机实现）
pub fn build_fse_encode_table(counts: Array[Int], table_log: Int) -> FSEEncodeTable {
  let normalized = normalize_counts(counts, table_log)
  let table_size = 1 << table_log
  let max_symbol = counts.length() - 1
  
  // 状态表：每个位置对应的符号
  let symbol_table: Array[Int] = Array::make(table_size, 0)
  
  // 为每个符号分配状态
  let mut position = 0
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    let count = normalized[symbol]
    for _j = 0; _j < count; _j = _j + 1 {
      if position < table_size {
        symbol_table[position] = symbol
        position = position + 1
      }
    }
  }
  
  // 计算每个符号需要的位数
  let num_bits_table: Array[Int] = Array::make(max_symbol + 1, 0)
  for symbol = 0; symbol <= max_symbol; symbol = symbol + 1 {
    let count = normalized[symbol]
    if count > 0 {
      // num_bits = table_log - log2(count)
      // 限制在合理范围内：0 到 table_log-1
      let log2_count = 31 - count.clz()
      let bits = (table_log - log2_count).max(0).min(table_log - 1)
      num_bits_table[symbol] = bits
    }
  }
  
  // 构建状态转换表：next_state_table[symbol][bits_value] = next_state
  let next_state_table: Array[Array[Int]] = []
  for symbol = 0; symbol <= max_symbol; symbol = symbol + 1 {
    let num_bits = num_bits_table[symbol]
    // 限制数组大小，避免过大
    let max_bits_value = if num_bits <= 10 { 1 << num_bits } else { 1024 }
    let state_transitions: Array[Int] = Array::make(max_bits_value, 0)
    
    // 为每个可能的位值计算下一个状态
    for bits_val = 0; bits_val < max_bits_value; bits_val = bits_val + 1 {
      // 简化的状态转换计算
      let next_state = (normalized[symbol] + bits_val) % table_size
      state_transitions[bits_val] = next_state
    }
    
    next_state_table.push(state_transitions)
  }
  
  FSEEncodeTable::{
    state_table: [],
    symbol_table: symbol_table,
    num_bits_table: num_bits_table,
    next_state_table: next_state_table,
    table_log: table_log,
    normalized_counts: normalized,
    max_symbol: max_symbol
  }
}

/// 使用 FSE 状态机编码符号序列（完整实现）
pub fn fse_encode_symbols(symbols: Array[Int], table: FSEEncodeTable) -> Bytes {
  if symbols.length() == 0 {
    return Bytes::from_array([])
  }
  
  // 位流输出缓冲
  let bit_buffer: Array[Int] = []  // 存储位值 (0 或 1)
  
  // 初始化状态为 table_size（标准 FSE 初始化）
  let table_size = 1 << table.table_log
  let mut state = table_size
  
  // 编码每个符号
  for i = 0; i < symbols.length(); i = i + 1 {
    let symbol = symbols[i]
    
    // 确保符号在有效范围内
    if symbol < 0 || symbol > table.max_symbol {
      continue
    }
    
    // 获取该符号需要的位数
    let num_bits = table.num_bits_table[symbol]
    
    // 如果状态太小，输出位直到状态足够大
    while state < table.normalized_counts[symbol] {
      // 输出最低位
      bit_buffer.push(state & 1)
      state = state >> 1
    }
    
    // 计算要输出的位值
    let bits_value = state % (1 << num_bits)
    
    // 输出位值的每一位
    for bit_idx = 0; bit_idx < num_bits; bit_idx = bit_idx + 1 {
      let bit = (bits_value >> bit_idx) & 1
      bit_buffer.push(bit)
    }
    
    // 更新状态
    let next_state_idx = bits_value.min(table.next_state_table[symbol].length() - 1)
    state = table.next_state_table[symbol][next_state_idx]
  }
  
  // 输出最终状态
  let final_state_bits = table.table_log
  for bit_idx = 0; bit_idx < final_state_bits; bit_idx = bit_idx + 1 {
    let bit = (state >> bit_idx) & 1
    bit_buffer.push(bit)
  }
  
  // 将位缓冲转换为字节
  let output: Array[Byte] = []
  let mut byte_val = 0
  let mut bit_count = 0
  
  for i = 0; i < bit_buffer.length(); i = i + 1 {
    let bit = bit_buffer[i]
    byte_val = byte_val | (bit << bit_count)
    bit_count = bit_count + 1
    
    if bit_count == 8 {
      output.push(byte_val.to_byte())
      byte_val = 0
      bit_count = 0
    }
  }
  
  // 输出剩余位（如果有）
  if bit_count > 0 {
    output.push(byte_val.to_byte())
  }
  
  Bytes::from_array(output)
}

/// 序列化 FSE 表头（兼容解码器格式）
/// 将归一化计数写入表头格式，使用 RLE 压缩重复值
pub fn serialize_fse_table(normalized_counts: Array[Int], table_log: Int) -> Bytes {
  let output: Array[Byte] = []
  
  // 写入表头：accuracy_log - 5（因为 accuracy_log 范围是 5-12）
  let accuracy_byte = (table_log - 5) & 0x0F
  output.push(accuracy_byte.to_byte())
  
  // 使用 RLE 压缩写入归一化计数
  let mut i = 0
  while i < normalized_counts.length() {
    let count = normalized_counts[i]
    
    // 检查是否有重复值（用于 RLE 压缩）
    let mut repeat_count = 1
    while i + repeat_count < normalized_counts.length() && 
          normalized_counts[i + repeat_count] == count && 
          repeat_count < 127 {
      repeat_count = repeat_count + 1
    }
    
    if repeat_count >= 3 {
      // 使用 RLE：128 + repeat_count，然后是值
      output.push((128 + repeat_count).to_byte())
      output.push(count.to_byte())
      i = i + repeat_count
    } else {
      // 直接编码（小于 128 的单个值）
      for _j = 0; _j < repeat_count; _j = _j + 1 {
        if count < 128 {
          output.push(count.to_byte())
        } else {
          // 大值需要特殊处理：拆分为多个字节
          let high = count / 128
          let low = count % 128
          output.push(high.to_byte())
          output.push(low.to_byte())
        }
      }
      i = i + repeat_count
    }
  }
  
  Bytes::from_array(output)
}

// ============================================================================
// tANS Encoding / tANS 编码
// ============================================================================

/// 初始化 FSE 编码状态
pub fn init_fse_cstate(table: FSECTable) -> UInt64 {
  // 初始状态 = table_size
  (1 << table.table_log).to_uint64()
}

/// 用指定符号初始化 FSE 编码状态
/// 用于最后一个序列的特殊处理（官方ZSTD实现）
/// 官方 FSE_initCState2 实现（fse.h 第 443-452 行）
pub fn init_fse_cstate_with_symbol(table: FSECTable, symbol: Int) -> UInt64 {
  let table_size = 1 << table.table_log
  
  // 检查符号有效性
  if symbol < 0 || symbol >= table.symbol_tt.length() {
    return table_size.to_uint64()
  }
  
  // 从 symbol_tt 获取该符号的转换信息
  let transform = table.symbol_tt[symbol]
  
  // 官方实现（fse.h:448-450）：
  // U32 nbBitsOut  = (U32)((symbolTT.deltaNbBits + (1<<15)) >> 16);
  // statePtr->value = (nbBitsOut << 16) - symbolTT.deltaNbBits;
  // statePtr->value = stateTable[(statePtr->value >> nbBitsOut) + symbolTT.deltaFindState];
  
  let delta_nb_bits = transform.delta_nb_bits
  let nb_bits_out = ((delta_nb_bits + (1 << 15)) >> 16) & 0xFFFF
  let mut state_value = (nb_bits_out << 16) - delta_nb_bits
  
  // 计算 stateTable 的索引
  let table_idx = (state_value >> nb_bits_out) + transform.delta_find_state
  
  // 从 state_table 查表获取实际的初始状态
  if table_idx >= 0 && table_idx < table.state_table.length() {
    state_value = table.state_table[table_idx].to_int()
  } else {
    // 如果索引越界，使用默认值
    state_value = table_size + transform.delta_find_state
  }
  
  state_value.to_uint64()
}

/// 编码单个符号 (tANS 核心算法)
/// 返回新状态
pub fn encode_symbol_fse(
  state: UInt64,
  symbol: Int,
  table: FSECTable,
  bitstream: BitStream
) -> UInt64 {
  if symbol < 0 || symbol > table.max_symbol {
    println("    ⚠️ 符号超出范围: \{symbol}")
    return state
  }
  
  let transform = table.symbol_tt[symbol]
  
  // 计算输出位数：nb_bits_out = (state + delta_nb_bits) >> 16
  let state_int = state.to_int()
  let sum = state_int + transform.delta_nb_bits
  let nb_bits_out = sum >> 16
  
  // 输出位（状态的低位）
  if nb_bits_out > 0 {
    let mask = if nb_bits_out >= 64 { 0xFFFFFFFFFFFFFFFFUL } else { (1UL << nb_bits_out) - 1UL }
    let bits_to_output = state & mask
    add_bits(bitstream, bits_to_output, nb_bits_out)
  }
  
  // 计算新状态（ZSTD标准tANS算法）：
  // new_state = stateTable[(state >> nbBitsOut) + deltaFindState]
  // stateTable存储的是状态值本身（tableSize + u）
  let base_state = state_int >> nb_bits_out
  let state_idx = base_state + transform.delta_find_state
  
  // 从stateTable查找新状态
  let new_state = if state_idx >= 0 && state_idx < table.state_table.length() {
    table.state_table[state_idx].to_int()
  } else {
    // 边界保护：如果索引越界，返回初始状态
    1 << table.table_log
  }
  
  // println("      new_state查表: stateTable[\{state_idx}] = \{new_state}")
  
  new_state.to_uint64()
}

/// 编码符号序列（tANS 完整实现）
pub fn fse_encode_sequence(
  symbols: Array[Int],
  table: FSECTable,
  bitstream: BitStream
) -> Result[UInt64, String] {
  if symbols.length() == 0 {
    return Ok(init_fse_cstate(table))
  }
  
  // 初始化状态
  let mut state = init_fse_cstate(table)
  
  // ⚠️ tANS 特性：倒序编码（后进先出）
  // 解码器会从后往前读取
  let mut i = symbols.length() - 1
  while i >= 0 {
    state = encode_symbol_fse(state, symbols[i], table, bitstream)
    i = i - 1
  }
  
  Ok(state)
}

/// 刷新最终状态到位流
pub fn flush_final_state(bitstream: BitStream, state: UInt64, table_log: Int) -> Unit {
  // tANS states are in [table_size, 2*table_size), so we normalize by subtracting table_size
  let table_size = 1UL << table_log
  let normalized_state = state - table_size
  // 输出归一化后的状态（table_log 位）
  add_bits(bitstream, normalized_state, table_log)
}

/// ✅ FSE 编码器完整实现（新版本，使用 tANS）
/// 统计频率、归一化、构建表、编码符号
pub fn fse_encode_complete_tans(symbols: Array[Int], max_symbol: Int, table_log: Int) -> Result[Bytes, String] {
  if symbols.length() == 0 {
    return Err("Empty symbol sequence")
  }
  
  // 1. 统计频率
  let counts = count_symbols(symbols, max_symbol)
  
  // 2. 归一化
  let normalized = normalize_counts(counts, table_log)
  
  // 3. 构建编码表
  let table_result = build_fse_ctable(normalized, max_symbol, table_log)
  let table = match table_result {
    Ok(t) => t
    Err(e) => return Err(e)
  }
  
  // 4. 序列化表头
  let table_header = serialize_fse_table(normalized, table_log)
  
  // 5. 编码符号（tANS 位流）
  let bitstream = create_bitstream()
  let final_state = match fse_encode_sequence(symbols, table, bitstream) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  
  // 6. 输出最终状态
  flush_final_state(bitstream, final_state, table_log)
  
  // 7. 刷新位流
  flush_bits(bitstream)
  
  // 8. 合并表头和数据
  let encoded_data = get_bytes(bitstream)
  let result: Array[Byte] = []
  for i = 0; i < table_header.length(); i = i + 1 {
    result.push(table_header[i])
  }
  for i = 0; i < encoded_data.length(); i = i + 1 {
    result.push(encoded_data[i])
  }
  
  Ok(Bytes::from_array(result))
}

/// ✅ FSE 编码器完整实现（兼容旧版本）
/// 统计频率、归一化、构建表、编码符号
pub fn fse_encode_complete(symbols: Array[Int], max_symbol: Int, table_log: Int) -> Result[Bytes, String] {
  fse_encode_complete_tans(symbols, max_symbol, table_log)
}
