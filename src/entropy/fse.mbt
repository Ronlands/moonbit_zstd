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
pub fn decode_fse_sequences(
  data: Bytes,
  offset: Int,
  num_sequences: Int,
  ll_weights: Array[Int],
  ml_weights: Array[Int],
  of_weights: Array[Int]
) -> Result[Array[Sequence], String] {
  // 构建FSE表
  let ll_table_result = build_fse_table_from_weights(ll_weights, 6)
  let ml_table_result = build_fse_table_from_weights(ml_weights, 6)
  let of_table_result = build_fse_table_from_weights(of_weights, 5)
  
  match (ll_table_result, ml_table_result, of_table_result) {
    (Ok(ll_table), Ok(ml_table), Ok(of_table)) => {
  let sequences: Array[Sequence] = []
  let mut bit_pos = offset * 8  // 转换为位位置
      
      for _i = 0; _i < num_sequences; _i = _i + 1 {
        // 解码literal length
        let ll_state = create_fse_state(ll_table)
        let ll_result = fse_decode_symbol(ll_state, data, bit_pos)
        
        // 解码match length
        let ml_state = create_fse_state(ml_table)
        let ml_result = fse_decode_symbol(ml_state, data, bit_pos)
        
        // 解码offset
        let of_state = create_fse_state(of_table)
        let of_result = fse_decode_symbol(of_state, data, bit_pos)
        
        match (ll_result, ml_result, of_result) {
          (Ok((ll_symbol, _, new_bit_pos1)), Ok((ml_symbol, _, new_bit_pos2)), Ok((of_symbol, _, new_bit_pos3))) => {
            let sequence = make_sequence(ll_symbol, ml_symbol, of_symbol)
            sequences.push(sequence)
            bit_pos = new_bit_pos1.max(new_bit_pos2).max(new_bit_pos3)
          }
          _ => return Err("FSE序列解码失败")
        }
      }
      
      Ok(sequences)
    }
    _ => Err("FSE表构建失败")
  }
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

/// FSE 编码表（用于编码）
pub struct FSEEncodeTable {
  state_table: Array[Int]      // State transition table
  symbol_table: Array[Int]      // Symbol for each state
  table_log: Int                // Log2 of table size
  normalized_counts: Array[Int] // Normalized symbol frequencies
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

/// 构建 FSE 编码表
pub fn build_fse_encode_table(counts: Array[Int], table_log: Int) -> FSEEncodeTable {
  let normalized = normalize_counts(counts, table_log)
  let table_size = 1 << table_log
  
  let state_table: Array[Int] = []
  let symbol_table: Array[Int] = []
  
  // 构建编码表
  let mut position = 0
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    for _j = 0; _j < normalized[symbol]; _j = _j + 1 {
      if position < table_size {
        state_table.push(position)
        symbol_table.push(symbol)
        position = position + 1
      }
    }
  }
  
  FSEEncodeTable::{
    state_table: state_table,
    symbol_table: symbol_table,
    table_log: table_log,
    normalized_counts: normalized
  }
}

/// 使用 FSE 编码符号序列
pub fn fse_encode_symbols(symbols: Array[Int], table: FSEEncodeTable) -> Bytes {
  // 简化实现：直接返回原始数据
  // 完整实现需要状态机和位流写入
  let output: Array[Byte] = []
  
  for i = 0; i < symbols.length(); i = i + 1 {
    output.push(symbols[i].to_byte())
  }
  
  Bytes::from_array(output)
}