/// FSE 基础类型与基础解码入口。

/// Sequence 类型统一复用 core 模块定义，避免在 entropy 层重复维护字段语义。
pub type Sequence = @zstd_core.Sequence

/// 创建序列对象。
pub fn make_sequence(literal_length: Int, match_length: Int, offset: Int) -> Sequence {
  @zstd_core.make_sequence(literal_length, match_length, offset)
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

/// 解析 FSE 权重并构建基础表。
pub fn build_fse_table_from_weights(weights: Array[Int], table_log: Int) -> Result[FSETable, String] {
  let max_symbol = weights.length() - 1
  let mut total_count = 0
  
  // 第 1 步：先统计所有权重的总和。
  for i = 0; i < weights.length(); i = i + 1 {
    total_count = total_count + weights[i]
  }
  
  if total_count == 0 {
    return Err("All weights are zero")
  }
  
  // 第 2 步：根据目标 table_log 计算归一化缩放系数。
  let scale = (1 << table_log) / total_count
  let normalized_weights: Array[Int] = []
  let symbols: Array[Int] = []
  let num_bits: Array[Int] = []
  
  // 第 3 步：把权重缩放到目标范围。
  for i = 0; i < weights.length(); i = i + 1 {
    let normalized = (weights[i] * scale).max(1)
    normalized_weights.push(normalized)
  }
  
  // 第 4 步：按归一化权重展开符号表。
  for i = 0; i < weights.length(); i = i + 1 {
    for _j = 0; _j < normalized_weights[i]; _j = _j + 1 {
      symbols.push(i)
    }
  }
  
  // 第 5 步：为每个符号估算需要的位数。
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

/// 从位流中读取一个 FSE 符号。
pub fn fse_decode_symbol(state: FSEState, bitstream: Bytes, bit_pos: Int) -> Result[(Int, Int, Int), String] {
  let table = state.table
  let state_value = state.state
  
  if state_value >= table.symbols.length() {
    return Err("FSE状态值超出范围")
  }
  
  let symbol = table.symbols[state_value]
  let bits_to_read = if symbol < table.num_bits.length() { table.num_bits[symbol] } else { 1 }
  
  // 逐位读取当前符号需要的附加位，并计算新状态。
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

/// 连续解码多个 FSE 符号。
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

/// 解析 FSE 表头。
pub fn parse_fse_table_header(data: Bytes, offset: Int) -> Result[(Array[Int], Int, Int), String] {
  if offset >= data.length() {
    return Err("FSE表头数据不足")
  }
  
  let header_byte = data[offset].to_int()
  let accuracy_log = (header_byte & 0x0F) + 5  // 5-12
  let table_log = accuracy_log.min(12)
  
  let mut current_offset = offset + 1
  let weights: Array[Int] = []
  
  // 按仓库当前采用的简化表头格式解析权重流。
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

/// 解码 FSE 压缩的序列。
///
/// 这里对外只暴露统一入口，内部实际转到完整 tANS 解码实现。
pub fn decode_fse_sequences(
  data: Bytes,
  offset: Int,
  num_sequences: Int,
  ll_weights: Array[Int],
  ml_weights: Array[Int],
  of_weights: Array[Int],
  prev_offsets: Array[Int]
) -> Result[Array[Sequence], String] {
  // 直接复用完整实现，保持入口稳定。
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
  mut reload_failed: Bool  // 标记 reload 是否失败
}

/// 从位流读取指定位数
/// 参照官方 BIT_lookBits + BIT_skipBits
fn read_bits_uint64(bs: BitstreamReader, nb_bits: Int) -> (BitstreamReader, UInt64) {
  if nb_bits <= 0 {
    return (bs, 0UL)
  }

  if bs.reload_failed {
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
fn reload_dstream(bs: BitstreamReader) -> BitstreamReader {
  if bs.bit_pos <= 64 { return bs }

  let bytes_consumed = bs.bit_pos / 8
  let new_offset = bs.offset - bytes_consumed

  if new_offset < bs.end_offset {
    bs.reload_failed = true
    return bs
  }

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
  bs
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

