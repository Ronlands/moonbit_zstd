/// Finite State Entropy (FSE) decoder

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
    return Err("All weights are zero")
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
      return Err("Insufficient bitstream data")
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
  of_weights: Array[Int],
  prev_offsets: Array[Int]
) -> Result[Array[Sequence], String] {
  // 直接使用原始实现（build_fse_dtable）
  decode_fse_sequences_original(data, offset, num_sequences, ll_weights, ml_weights, of_weights, prev_offsets)
}


/// 位流读取器（用于解码，支持反向读取）
/// 参照官方 BIT_DStream_t
priv struct BitstreamReader {
  data: Bytes              // 原始数据引用（用于 reload）
  mut offset: Int          // 当前指针位置（reload 时向前移动）
  mut bit_container: UInt64
  mut bit_pos: Int         // bitsConsumed：累积消费量
  end_offset: Int          // 数据起始边界（不可越过）
}

/// 从位流读取指定位数
/// 参照官方 BIT_lookBits + BIT_skipBits
fn read_bits_uint64(bs: BitstreamReader, nb_bits: Int) -> (BitstreamReader, UInt64) {
  if nb_bits <= 0 {
    return (bs, 0UL)
  }

  let mask = if nb_bits >= 64 { 0xFFFFFFFFFFFFFFFFUL } else { (1UL << nb_bits) - 1UL }
  let shifted = if bs.bit_pos >= 64 { 0UL } else { bs.bit_container << bs.bit_pos }
  let value = if nb_bits >= 64 { shifted } else { (shifted >> (64 - nb_bits)) & mask }
  bs.bit_pos = bs.bit_pos + nb_bits

  (bs, value)
}

/// Reload bitstream — 参照官方 BIT_reloadDStream
/// 当 bit_pos 接近 64 时，向前移动指针并重新加载 container
fn reload_dstream(bs: BitstreamReader) -> Unit {
  if bs.bit_pos > 64 { return }

  let bytes_consumed = bs.bit_pos / 8
  let new_offset = bs.offset - bytes_consumed

  if new_offset < bs.end_offset { return }

  bs.offset = new_offset
  bs.bit_pos = bs.bit_pos % 8

  // 重新加载 8 字节（LE）
  let mut container = 0UL
  for i = 0; i < 8; i = i + 1 {
    if bs.offset + i < bs.data.length() {
      container = container | (bs.data[bs.offset + i].to_uint64() << (i * 8))
    }
  }
  bs.bit_container = container
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

/// 刷新位流（将容器中积累的完整字节输出到缓冲区）
pub fn flush_bits(stream: BitStream) -> Unit {
  while stream.bit_pos >= 8 {
    stream.buffer.push((stream.bit_container & 0xFFUL).to_byte())
    stream.bit_container = stream.bit_container >> 8
    stream.bit_pos = stream.bit_pos - 8
  }
}

/// 关闭位流：添加 padding bit（1）并刷新所有剩余位
/// 这是 ZSTD 位流结束的标准方式——解码器通过找最后一个字节的最高位1来定位起始点
pub fn close_bitstream(stream: BitStream) -> Unit {
  add_bits(stream, 1UL, 1)
  // 刷新所有剩余位（包括不满一字节的）
  if stream.bit_pos > 0 {
    stream.buffer.push((stream.bit_container & 0xFFUL).to_byte())
    stream.bit_container = 0UL
    stream.bit_pos = 0
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
  let max_symbol = normalized.length() - 1
  let table_size = 1 << table_log
  let dtable: Array[FSEDecodeEntry] = Array::make(table_size, FSEDecodeEntry::{ symbol: 0, nb_bits: 0, new_state_base: 0 })

  // Official ZSTD spread algorithm:
  // 1. Place -1 (less-than-1) symbols at high threshold positions
  // 2. Spread remaining symbols using the step algorithm
  let table_symbol: Array[Int] = Array::make(table_size, 0)
  let mut high_threshold = table_size - 1
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    if normalized[symbol] == -1 {
      table_symbol[high_threshold] = symbol
      high_threshold = high_threshold - 1
    }
  }

  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  let mut position = 0
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    let freq = normalized[symbol]
    if freq <= 0 { continue }
    for _i = 0; _i < freq; _i = _i + 1 {
      table_symbol[position] = symbol
      position = (position + step) & mask
      while position > high_threshold { position = (position + step) & mask }
    }
  }
  
  // table_symbol构建完成
  
  // 第二步：计算每个符号的累积位置 (cumul)
  let cumul: Array[Int] = Array::make(max_symbol + 2, 0)
  for s = 0; s <= max_symbol; s = s + 1 {
    let norm = if s < normalized.length() { normalized[s] } else { 0 }
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
  let cumul_copy: Array[Int] = Array::make(max_symbol + 1, 0)
  for s = 0; s <= max_symbol; s = s + 1 {
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
    
    // ZSTD公式：nbBits = MAX(tableLog - highbit32(nextState), 0)
    let nb_bits = (table_log - highbit32(next_state)).max(0)
    // newStateBaseline = (nextState << nbBits) - tableSize
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
) -> Result[FSEDecodeEntry, String] {
  let table_size = 1 << table_log

  // 规范化状态到 [table_size, 2*table_size) 范围
  let normalized_state = if state < table_size {
    state + table_size
  } else if state >= table_size * 2 {
    (state % table_size) + table_size
  } else {
    state
  }

  let u = normalized_state - table_size

  if u < 0 || u >= dtable.length() {
    Err("State out of bounds error: state=\{state}, normalized=\{normalized_state}, u=\{u}, table_size=\{table_size}")
  } else {
    Ok(dtable[u])
  }
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

  // Official ZSTD spread: -1 symbols at high threshold, others via step
  let table_symbol: Array[Int] = Array::make(table_size, 0)
  let mut high_threshold = table_size - 1
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    if normalized[symbol] == -1 {
      table_symbol[high_threshold] = symbol
      high_threshold = high_threshold - 1
    }
  }

  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  let mut position = 0
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    let freq = normalized[symbol]
    if freq <= 0 { continue }
    for _i = 0; _i < freq; _i = _i + 1 {
      table_symbol[position] = symbol
      position = (position + step) & mask
      while position > high_threshold { position = (position + step) & mask }
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
  
  // 计算总频率（跳过-1，表示低频符号）
  for i = 0; i < counts.length(); i = i + 1 {
    if counts[i] == -1 {
      total = total + 1  // -1 表示频率1
    } else if counts[i] > 0 {
      total = total + counts[i]
    }
    // counts[i] == 0 不计入
  }
  
  if total == 0 {
    return Array::make(counts.length(), 0)
  }
  
  let normalized: Array[Int] = []
  let mut distributed = 0
  
  for i = 0; i < counts.length(); i = i + 1 {
    if counts[i] == 0 {
      normalized.push(0)
    } else if counts[i] == -1 {
      // Preserve -1 (less-than-1 probability) — critical for official ZSTD table spread
      normalized.push(-1)
      distributed = distributed + 1
    } else {
      let norm = (counts[i] * table_size) / total
      let final_norm = if norm == 0 && counts[i] > 0 { 1 } else { norm }
      normalized.push(final_norm)
      distributed = distributed + final_norm
    }
  }
  
  // 调整以确保总和等于 table_size
  let remaining = table_size - distributed
  if remaining != 0 {
    // 找到权重最大的符号来调整
    let mut max_idx = -1
    let mut max_norm = 0
    for i = 0; i < normalized.length(); i = i + 1 {
      if normalized[i] > max_norm {
        max_norm = normalized[i]
        max_idx = i
      }
    }
    if max_idx >= 0 {
      normalized[max_idx] = normalized[max_idx] + remaining
    }
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
      // 状态转换计算
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

/// 使用 FSECTable 解码 FSE 序列（与编码器使用相同算法）
pub fn decode_fse_sequences_with_tables(
  data: Bytes,
  offset: Int,
  num_sequences: Int,
  ll_table: FSECTable,
  of_table: FSECTable,
  ml_table: FSECTable
) -> Result[Array[Sequence], String] {
  // println("🔍 使用 FSECTable 解码 \{num_sequences} 个序列")

  if num_sequences == 0 {
    return Ok([])
  }

  // 初始化 bitstream
  let fse_data_len = data.length() - offset
  if fse_data_len < 1 {
    return Err("FSE data too short")
  }

  let temp_bs = BitstreamReader::{
    data: data,
    offset: 0,
    bit_container: 0UL,
    bit_pos: 0,
    end_offset: offset,
  }

  if fse_data_len >= 8 {
    temp_bs.offset = offset + fse_data_len - 8

    let mut container = 0UL
    for i = 0; i < 8; i = i + 1 {
      let byte_val = data[temp_bs.offset + i].to_uint64()
      container = container | (byte_val << (i * 8))
    }
    temp_bs.bit_container = container
    temp_bs.bit_pos = 0
  }

  // 读取最终状态（官方顺序 LL → OF → ML）
  let (bs1, ll_state_raw) = read_bits_uint64(temp_bs, 6)
  let mut ll_state = ll_state_raw + 64UL

  let (bs2, of_state_raw) = read_bits_uint64(bs1, 5)
  let mut of_state = of_state_raw + 32UL

  let (bs3, ml_state_raw) = read_bits_uint64(bs2, 6)
  let mut ml_state = ml_state_raw + 64UL

  let mut current_bs = bs3

  let temp_sequences: Array[Sequence] = Array::make(num_sequences, Sequence::{ literal_length: 0, match_length: 0, offset: 0 })
  let mut seq_count = 0

  for seq_idx = (num_sequences - 1); seq_idx >= 0; seq_idx = seq_idx - 1 {

    // 1. 从状态解码符号（使用与编码器相同的算法）
    let (ll_symbol, new_ll_state, ll_nb_bits) = decode_symbol_from_state(ll_state, ll_table)
    let (of_symbol, new_of_state, of_nb_bits) = decode_symbol_from_state(of_state, of_table)
    let (ml_symbol, new_ml_state, ml_nb_bits) = decode_symbol_from_state(ml_state, ml_table)

    // 2. 读取额外位
    let (bs_ll, ll_extra) = if ll_nb_bits > 0 {
      read_bits_uint64(current_bs, ll_nb_bits)
    } else {
      (current_bs, 0UL)
    }

    let (bs_of, of_extra) = if of_nb_bits > 0 {
      read_bits_uint64(bs_ll, of_nb_bits)
    } else {
      (bs_ll, 0UL)
    }

    let (bs_ml, ml_extra) = if ml_nb_bits > 0 {
      read_bits_uint64(bs_of, ml_nb_bits)
    } else {
      (bs_of, 0UL)
    }

    current_bs = bs_ml

    // 3. 计算最终值
    let final_ll = decode_ll(ll_symbol, ll_extra.to_int())
    let final_of = decode_of(of_symbol, of_extra.to_int())
    let final_ml = decode_ml(ml_symbol, ml_extra.to_int())

    // 4. 创建序列
    let seq = make_sequence(final_ll, final_ml, final_of)
    temp_sequences[num_sequences - 1 - seq_idx] = seq

    // 5. 更新状态用于下一个序列
    ll_state = new_ll_state
    of_state = new_of_state
    ml_state = new_ml_state

    seq_count = seq_count + 1
  }

  // println("  ✅ FSECTable 解码完成: 解码了 \{seq_count} 个序列")
  Ok(temp_sequences)
}

/// 从状态解码单个符号（优化版本）
fn decode_symbol_from_state(state: UInt64, table: FSECTable) -> (Int, UInt64, Int) {
  let state_int = state.to_int()

  // 直接查找对应的符号
  for s = 0; s <= table.max_symbol && s < table.symbol_tt.length(); s = s + 1 {
    let transform = table.symbol_tt[s]
    let sum = state_int + transform.delta_nb_bits
    let nb_bits_out = sum >> 16
    let state_idx = (state_int >> nb_bits_out) + transform.delta_find_state

    if state_idx >= 0 && state_idx < table.state_table.length() &&
       table.state_table[state_idx].to_int() == state_int {
      // 找到匹配的符号，返回结果
      // 新状态初始化为表大小
      let new_state = (1 << table.table_log).to_uint64()
      return (s, new_state, nb_bits_out)
    }
  }

  // 未找到匹配
  (0, state, 0)
}

/// 更新 FSE 状态 (不输出 bits，用于解码)
pub fn update_fse_state(
  state: UInt64,
  symbol: Int,
  table: FSECTable
) -> UInt64 {
  if symbol < 0 || symbol > table.max_symbol {
    return state
  }

  let transform = table.symbol_tt[symbol]

  // 计算输出位数：nb_bits_out = (state + delta_nb_bits) >> 16
  let state_int = state.to_int()
  let sum = state_int + transform.delta_nb_bits
  let nb_bits_out = sum >> 16

  // 计算新状态（ZSTD标准tANS算法）：
  // new_state = stateTable[(state >> nbBitsOut) + deltaFindState]
  let base_state = state_int >> nb_bits_out
  let state_idx = base_state + transform.delta_find_state

  // 从stateTable查找新状态
  let new_state = if state_idx >= 0 && state_idx < table.state_table.length() {
    table.state_table[state_idx].to_int()
  } else {
    // 边界保护：如果索引越界，返回初始状态
    1 << table.table_log
  }

  new_state.to_uint64()
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

/// 调试函数：测试 FSE 解码序列
pub fn debug_fse_decode_sequences(
  data: Bytes,
  offset: Int,
  num_sequences: Int,
  ll_weights: Array[Int],
  ml_weights: Array[Int],
  of_weights: Array[Int]
) -> Unit {
  println("🔍 FSE 调试: num_sequences=\{num_sequences}, offset=\{offset}")

  // 调试：打印权重
  let ll_sample = if ll_weights.length() >= 6 { [ll_weights[0], ll_weights[1], ll_weights[2], ll_weights[3], ll_weights[4], ll_weights[5]] } else { [] }
  let of_sample = if of_weights.length() >= 6 { [of_weights[0], of_weights[1], of_weights[2], of_weights[3], of_weights[4], of_weights[5]] } else { [] }
  let ml_sample = if ml_weights.length() >= 6 { [ml_weights[0], ml_weights[1], ml_weights[2], ml_weights[3], ml_weights[4], ml_weights[5]] } else { [] }
  println("  LL权重 (前6): \{ll_sample}")
  println("  OF权重 (前6): \{of_sample}")
  println("  ML权重 (前6): \{ml_sample}")

  match decode_fse_sequences(data, offset, num_sequences, ll_weights, ml_weights, of_weights, [1, 4, 8]) {
    Ok(sequences) => {
      println("✅ FSE 解码成功: \{sequences.length()} 个序列")
      for i = 0; i < sequences.length(); i = i + 1 {
        let seq = sequences[i]
        println("  序列\{i}: LL=\{seq.literal_length}, ML=\{seq.match_length}, OF=\{seq.offset}")
      }
    }
    Err(e) => {
      println("❌ FSE 解码失败: \{e}")
    }
  }
}

/// 原始的 FSE 解码实现（回退用）
fn decode_fse_sequences_original(
  data: Bytes,
  offset: Int,
  num_sequences: Int,
  ll_weights: Array[Int],
  ml_weights: Array[Int],
  of_weights: Array[Int],
  prev_offsets: Array[Int]
) -> Result[Array[Sequence], String] {
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

  // 初始化 DStream（参照官方 BIT_initDStream）
  let temp_bs = BitstreamReader::{
    data: data,
    offset: 0,
    bit_container: 0UL,
    bit_pos: 0,
    end_offset: offset,
  }

  if fse_data_len >= 8 {
    temp_bs.offset = offset + fse_data_len - 8

    let mut container = 0UL
    for i = 0; i < 8; i = i + 1 {
      let byte_val = data[temp_bs.offset + i].to_uint64()
      container = container | (byte_val << (i * 8))
    }
    temp_bs.bit_container = container

    let last_byte_idx = offset + fse_data_len - 1
    let last_byte = data[last_byte_idx].to_int()
    let bits_consumed_raw = if last_byte == 0 { 0 } else { 8 - highbit32(last_byte) }
    temp_bs.bit_pos = bits_consumed_raw
  } else {
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

    let extra_bits = (8 - fse_data_len) * 8
    let bits_consumed = bits_consumed_byte + extra_bits
    temp_bs.bit_pos = bits_consumed
  }

  // 读取初始状态（官方顺序 LL → OF → ML）
  let (bs1, ll_state_raw) = read_bits_uint64(temp_bs, 6)
  let (bs2, of_state_raw) = read_bits_uint64(bs1, 5)
  let (bs3, ml_state_raw) = read_bits_uint64(bs2, 6)
  let bs_after_ml_reload = bs3

  let ll_s = ll_state_raw + 64UL
  let of_s = of_state_raw + 32UL
  let ml_s = ml_state_raw + 64UL

  let mut current_bs = bs_after_ml_reload
  let mut ll_state = ll_s
  let mut of_state = of_s
  let mut ml_state = ml_s

  // Decode sequences (forward iteration, matching official ZSTD_decodeSequence_body)
  let sequences: Array[Sequence] = []
  for seq_idx = 0; seq_idx < num_sequences; seq_idx = seq_idx + 1 {
    // 1. Peek symbols from current states
    let ll_entry_result = get_fse_decode_entry(ll_state.to_int(), ll_dtable, 6)
    let ml_entry_result = get_fse_decode_entry(ml_state.to_int(), ml_dtable, 6)
    let of_entry_result = get_fse_decode_entry(of_state.to_int(), of_dtable, 5)

    let (ll_entry, ml_entry, of_entry, ll_code, ml_code, of_code) = match (ll_entry_result, ml_entry_result, of_entry_result) {
      (Ok(ll_e), Ok(ml_e), Ok(of_e)) => {
        (ll_e, ml_e, of_e, ll_e.symbol, ml_e.symbol, of_e.symbol)
      }
      _ => return Err("FSE状态越界错误")
    }

    // 2. Read extra bits: OF, ML, (reload), LL — official order
    let mut final_of = decode_of(of_code, 0)
    let of_nb = get_of_bits(of_code)
    let (bs_a, of_ex) = if of_nb > 0 { read_bits_uint64(current_bs, of_nb) } else { (current_bs, 0UL) }
    final_of = final_of + of_ex.to_int()

    let mut final_ml = decode_ml(ml_code, 0)
    let ml_nb = get_ml_bits(ml_code)
    let (bs_b, ml_ex) = if ml_nb > 0 { read_bits_uint64(bs_a, ml_nb) } else { (bs_a, 0UL) }
    final_ml = final_ml + ml_ex.to_int()

    // Reload between ML and LL extras (official behavior for 64-bit)
    reload_dstream(bs_b)

    let mut final_ll = decode_ll(ll_code, 0)
    let ll_nb = get_ll_bits(ll_code)
    let (bs_c, ll_ex) = if ll_nb > 0 { read_bits_uint64(bs_b, ll_nb) } else { (bs_b, 0UL) }
    final_ll = final_ll + ll_ex.to_int()

    // Resolve repeat offsets (RFC 8878 §3.1.1.3.2.1)
    // of_nb == 0  → of_code=0, raw=0: special repeat sentinel
    // of_nb == 1  → of_code=1, raw=1..2: repeat codes
    // of_nb >= 2  → of_code>=2: final_of is already the direct copy distance
    let resolved_of = if of_nb >= 2 {
      // Direct offset: final_of is the copy distance
      let p0 = prev_offsets[0]
      let p1 = prev_offsets[1]
      prev_offsets[2] = p1
      prev_offsets[1] = p0
      prev_offsets[0] = final_of
      final_of
    } else {
      // Repeat offset: use C's ll0 trick to compute a "combined code" 0..3
      let ll0 = if final_ll == 0 { 1 } else { 0 }
      let c_code = final_of + ll0  // 0..3 (of_nb=0 → final_of=0; of_nb=1 → final_of=1 or 2)
      if c_code == 0 {
        // use rep[0], no update
        prev_offsets[0]
      } else if c_code == 1 {
        // use rep[1]; update: swap rep[0] and rep[1], keep rep[2]
        let actual = prev_offsets[1]
        prev_offsets[1] = prev_offsets[0]
        prev_offsets[0] = actual
        actual
      } else if c_code == 2 {
        // use rep[2]; update: rotate all (rep[2] to front)
        let actual = prev_offsets[2]
        prev_offsets[2] = prev_offsets[1]
        prev_offsets[1] = prev_offsets[0]
        prev_offsets[0] = actual
        actual
      } else {
        // c_code == 3: use rep[0]-1; update: shift back
        let actual = prev_offsets[0] - 1
        prev_offsets[2] = prev_offsets[1]
        prev_offsets[1] = prev_offsets[0]
        prev_offsets[0] = actual
        actual
      }
    }
    sequences.push(make_sequence(final_ll, final_ml, resolved_of))

    // 3. State updates: LL, ML, OF — RFC 8878 order (not needed for last sequence)
    if seq_idx < num_sequences - 1 {
      let (bs1, ll_st) = read_bits_uint64(bs_c, ll_entry.nb_bits)
      ll_state = (ll_entry.new_state_base + ll_st.to_int() + 64).to_uint64()

      let (bs2, ml_st) = read_bits_uint64(bs1, ml_entry.nb_bits)
      ml_state = (ml_entry.new_state_base + ml_st.to_int() + 64).to_uint64()

      let (bs3, of_st) = read_bits_uint64(bs2, of_entry.nb_bits)
      of_state = (of_entry.new_state_base + of_st.to_int() + 32).to_uint64()

      reload_dstream(bs3)
      current_bs = bs3
    }
  }

  Ok(sequences)
}
