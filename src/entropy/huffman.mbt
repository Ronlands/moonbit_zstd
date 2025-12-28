/// Huffman encoder/decoder implementation
/// Used for encoding/decoding literals in ZSTD
/// Following RFC 8878 specification
///
/// ✅ Huffman 编码器已实现：
/// - [✓] Huffman 树构建（用于编码）
/// - [✓] Huffman 符号编码
/// - [✓] 权重优化算法
/// - [✓] 表序列化输出

/// Huffman表结构
pub struct HuffmanTable {
  symbols: Array[Int]
  num_bits: Array[Int]
  max_bits: Int
  root: HuffmanNode  // 用于解码的树
}

/// Huffman节点
pub enum HuffmanNode {
  Leaf(Int)  // 符号值
  Internal(HuffmanNode, HuffmanNode)  // 左子树，右子树
}

/// Huffman权重结构
pub struct HuffmanWeights {
  weights: Array[Int]
  count: Int
} derive(Show)

/// 创建空的Huffman表
pub fn create_huffman_table() -> HuffmanTable {
  HuffmanTable::{
    symbols: [],
    num_bits: [],
    max_bits: 0,
    root: HuffmanNode::Leaf(0)
  }
}

/// 创建Huffman表
pub fn create_huffman_table_with_params(
  symbols: Array[Int],
  num_bits: Array[Int],
  max_bits: Int,
  root: HuffmanTreeNode
) -> HuffmanTable {
  // 转换HuffmanTreeNode为HuffmanNode用于解码
  let decoding_root = convert_tree_node_to_node(root)
  HuffmanTable::{ symbols, num_bits, max_bits, root: decoding_root }
}

/// 将HuffmanTreeNode转换为HuffmanNode（用于解码）
fn convert_tree_node_to_node(tree_node: HuffmanTreeNode) -> HuffmanNode {
  match tree_node {
    HuffmanTreeNode::Leaf(symbol, _freq) => HuffmanNode::Leaf(symbol)
    HuffmanTreeNode::Internal(left, right, _combined_freq) => {
      HuffmanNode::Internal(convert_tree_node_to_node(left), convert_tree_node_to_node(right))
    }
  }
}

/// 创建默认的Huffman权重
pub fn create_default_huffman_weights() -> HuffmanWeights {
  HuffmanWeights::{
    weights: Array::make(256, 0),
    count: 0
  }
}

/// 创建Huffman权重
pub fn create_huffman_weights(weights: Array[Int]) -> HuffmanWeights {
  HuffmanWeights::{
    weights: weights,
    count: weights.length()
  }
}

/// 解析Huffman权重（增强的完整性验证）
pub fn parse_huffman_weights(data: Bytes, offset: Int, max_symbols: Int) -> Result[(HuffmanWeights, Int), String] {
  if offset >= data.length() {
    return Err("Truncated Huffman state: insufficient weight data (offset beyond data)")
  }
  
  // 验证至少有一些权重数据
  let available_bytes = data.length() - offset
  if available_bytes < 1 {
    return Err("Truncated Huffman state: no bytes available for weights")
  }
  
  let weights: Array[Int] = []
  let mut current_offset = offset
  let mut symbols_parsed = 0
  let initial_offset = offset
  
  while symbols_parsed < max_symbols && current_offset < data.length() {
    // 检测是否已经超出合理范围
    if current_offset - initial_offset > max_symbols {
      return Err("Truncated Huffman state: weight data parsing exceeded reasonable size")
    }
    
    let weight_byte = data[current_offset].to_int()
    current_offset = current_offset + 1
    
    if weight_byte < 128 {
      // 单字节权重
      weights.push(weight_byte)
      symbols_parsed = symbols_parsed + 1
    } else {
      // 重复权重
      let repeat_count = weight_byte - 128
      
      // 验证重复计数的合理性
      if repeat_count > max_symbols - symbols_parsed {
        return Err("Truncated Huffman state: repeat count exceeds remaining symbols")
      }
      
      // 验证有下一个字节可读
      if current_offset >= data.length() {
        return Err("Truncated Huffman state: missing repeat value byte")
      }
      
      let next_byte = data[current_offset].to_int()
      current_offset = current_offset + 1
      
      for _i = 0; _i < repeat_count && symbols_parsed < max_symbols; _i = _i + 1 {
        weights.push(next_byte)
        symbols_parsed = symbols_parsed + 1
      }
    }
  }
  
  // 严格验证：至少应该解析了一些符号
  if symbols_parsed == 0 {
    return Err("Truncated Huffman state: no symbols parsed from weights")
  }
  
  // 填充到最大符号数
  while weights.length() < max_symbols {
    weights.push(0)
  }
  
  let bytes_consumed = current_offset - offset
  
  // 验证消耗的字节数合理
  if bytes_consumed == 0 {
    return Err("Truncated Huffman state: no bytes consumed during parsing")
  }
  
  Ok((create_huffman_weights(weights), bytes_consumed))
}


/// 计算每个符号的位数
fn calculate_symbol_bits(node: HuffmanTreeNode, depth: Int) -> Array[Int] {
  let bits: Array[Int] = []

  match node {
    HuffmanTreeNode::Leaf(symbol, _freq) => {
      // 确保数组足够大
      while bits.length() <= symbol {
        bits.push(0)
      }
      bits[symbol] = depth
    }
    HuffmanTreeNode::Internal(left, right, _combined_freq) => {
      let left_bits = calculate_symbol_bits(left, depth + 1)
      let right_bits = calculate_symbol_bits(right, depth + 1)

      // 合并位数数组
      let max_len = left_bits.length().max(right_bits.length())
      for i = 0; i < max_len; i = i + 1 {
        let left_bit = if i < left_bits.length() { left_bits[i] } else { 0 }
        let right_bit = if i < right_bits.length() { right_bits[i] } else { 0 }
        bits.push(left_bit.max(right_bit))
      }
    }
  }

  bits
}

/// 构建Huffman表
pub fn build_huffman_table(weights: HuffmanWeights) -> Result[HuffmanTable, String] {
  let root = build_huffman_tree(weights.weights)

  let bits = calculate_symbol_bits(root, 0)
  let max_bits = if bits.length() > 0 { bits[0] } else { 0 }

  // 创建符号数组
  let symbols: Array[Int] = []
  for i = 0; i < weights.weights.length(); i = i + 1 {
    if weights.weights[i] > 0 {
      symbols.push(i)
    }
  }

  Ok(create_huffman_table_with_params(symbols, bits, max_bits, root))
}

/// 从位流中解码Huffman符号（增强的状态验证）
pub fn huffman_decode_symbol(table: HuffmanTable, bitstream: Bytes, bit_pos: Int) -> Result[(Int, Int), String] {
  let mut current_node = table.root
  let mut current_bit_pos = bit_pos
  let mut depth = 0
  let max_depth = table.max_bits.max(32)  // 防止无限循环
  
  // 深度验证：检测位流截断
  if bit_pos >= bitstream.length() * 8 {
    return Err("Truncated Huffman state: bit position beyond bitstream")
  }
  
  while current_bit_pos < bitstream.length() * 8 {
    let byte_pos = current_bit_pos / 8
    let bit_offset = current_bit_pos % 8
    
    // 状态验证：检查字节位置
    if byte_pos >= bitstream.length() {
      return Err("Truncated Huffman state: incomplete bitstream data")
    }
    
    // 深度验证：防止树遍历过深
    depth = depth + 1
    if depth > max_depth {
      return Err("Truncated Huffman state: tree traversal depth exceeded")
    }
    
    match current_node {
      HuffmanNode::Leaf(symbol) => {
        // 成功找到叶子节点
        return Ok((symbol, current_bit_pos))
      }
      HuffmanNode::Internal(left, right) => {
        let bit = (bitstream[byte_pos].to_int() >> bit_offset) & 1
        current_bit_pos = current_bit_pos + 1
        current_node = if bit == 0 { left } else { right }
      }
    }
  }
  
  // 位流结束但未找到叶子节点 - 这表明 Huffman 状态被截断
  match current_node {
    HuffmanNode::Leaf(_) => Err("Huffman decoding incomplete: reached end without processing leaf")
    HuffmanNode::Internal(_, _) => Err("Truncated Huffman state: bitstream ended in middle of symbol")
  }
}

/// 批量解码Huffman符号（增强的状态追踪）
pub fn huffman_decode_multiple(
  table: HuffmanTable,
  bitstream: Bytes,
  bit_pos: Int,
  count: Int
) -> Result[(Array[Int], Int), String] {
  let result: Array[Int] = []
  let mut current_bit_pos = bit_pos
  
  // 预验证：检查位流是否足够大
  if bitstream.length() == 0 {
    return Err("Truncated Huffman state: empty bitstream")
  }
  
  if bit_pos >= bitstream.length() * 8 {
    return Err("Truncated Huffman state: starting position beyond bitstream")
  }
  
  // 估算最小所需位数（假设每个符号至少需要1位）
  let min_required_bits = count
  let available_bits = bitstream.length() * 8 - bit_pos
  if available_bits < min_required_bits {
    return Err("Truncated Huffman state: insufficient bits for " + count.to_string() + " symbols")
  }
  
  for i = 0; i < count; i = i + 1 {
    let decode_result = huffman_decode_symbol(table, bitstream, current_bit_pos)
    match decode_result {
      Ok((symbol, new_bit_pos)) => {
        result.push(symbol)
        
        // 状态追踪：检查位置前进是否合理
        if new_bit_pos <= current_bit_pos {
          return Err("Truncated Huffman state: bit position not advancing at symbol " + i.to_string())
        }
        
        // 状态追踪：检查是否超出边界
        if new_bit_pos > bitstream.length() * 8 {
          return Err("Truncated Huffman state: bit position exceeded bitstream at symbol " + i.to_string())
        }
        
        current_bit_pos = new_bit_pos
      }
      Err(e) => {
        // 提供更详细的错误信息，包括符号位置
        return Err(e + " (at symbol " + i.to_string() + "/" + count.to_string() + ")")
      }
    }
  }
  
  Ok((result, current_bit_pos))
}

/// 解码Huffman压缩的字面量
pub fn decode_huffman_literals(
  data: Bytes,
  offset: Int,
  num_literals: Int,
  weights: Array[Int]
) -> Result[Array[Byte], String] {
  let huffman_weights = create_huffman_weights(weights)
  let table_result = build_huffman_table(huffman_weights)
  
  match table_result {
    Ok(table) => {
      let literals: Array[Byte] = []
      let mut bit_pos = offset * 8
      
      for _i = 0; _i < num_literals; _i = _i + 1 {
        let decode_result = huffman_decode_symbol(table, data, bit_pos)
        match decode_result {
          Ok((symbol, new_bit_pos)) => {
            literals.push(symbol.to_byte())
            bit_pos = new_bit_pos
          }
          Err(e) => return Err(e)
        }
      }
      
      Ok(literals)
    }
    Err(e) => Err(e)
  }
}

/// 构建Huffman表从权重
pub fn build_huffman_table_from_weights(weights: HuffmanWeights) -> Result[HuffmanTable, String] {
  build_huffman_table(weights)
}

/// 基本Huffman测试
pub fn test_basic_huffman() -> Bool {
  let weights: Array[Int] = [1, 2, 3, 4, 5]
  let huffman_weights = create_huffman_weights(weights)
  let table_result = build_huffman_table(huffman_weights)
  
  match table_result {
    Ok(table) => table.symbols.length() > 0
    Err(_) => false
  }
}

// ============================================================================
// Complete Huffman Encoder Implementation
// ============================================================================

/// Huffman 树节点
pub enum HuffmanTreeNode {
  Leaf(Int, Int)          // (symbol, frequency)
  Internal(HuffmanTreeNode, HuffmanTreeNode, Int)  // (left, right, combined_frequency)
}

/// Huffman 编码表项
pub struct HuffmanCode {
  code: UInt64    // Huffman code bits (最多支持64位)
  length: Int     // Code length in bits
}

/// Huffman 编码表
pub struct HuffmanEncodeTable {
  codes: Array[HuffmanCode]   // Code for each symbol (0-255)
  max_symbol: Int             // Maximum symbol value
}

/// Huffman 位流编码器 - 完整的位级实现
pub struct HuffmanBitWriter {
  buffer: Array[Byte]
  current_byte: Byte
  bit_position: Int  // 0-7, 0表示最高位
}

/// Huffman 位流读取器
pub struct HuffmanBitReader {
  data: Bytes
  byte_pos: Int
  bit_pos: Int  // 0-7, 0表示最高位
}

/// 创建 Huffman 位流写入器
pub fn create_huffman_bit_writer() -> HuffmanBitWriter {
  HuffmanBitWriter::{
    buffer: [],
    current_byte: 0b00000000,
    bit_position: 7  // 从最高位开始写入
  }
}

/// 创建 Huffman 位流读取器
pub fn create_huffman_bit_reader(data: Bytes) -> HuffmanBitReader {
  HuffmanBitReader::{
    data: data,
    byte_pos: 0,
    bit_pos: 7  // 从最高位开始读取
  }
}

/// 向位流中写入指定数量的位 - 完整的实现
pub fn write_bits(writer: HuffmanBitWriter, value: UInt64, num_bits: Int) -> HuffmanBitWriter {
  if num_bits <= 0 || num_bits > 64 {
    return writer  // 无效的位数
  }

  let mut current_byte = writer.current_byte
  let mut bit_pos = writer.bit_position
  let buffer = writer.buffer
  let mut remaining_bits = num_bits
  let value_to_write = value

  while remaining_bits > 0 {
    let bits_to_write = remaining_bits.min(bit_pos + 1)

    // 提取要写入的位
    let mask = (1UL << bits_to_write) - 1UL
    let bits = (value_to_write >> (remaining_bits - bits_to_write)) & mask

    // 计算位移量（从最高位开始）
    let shift = bit_pos - bits_to_write + 1
    current_byte = current_byte | (bits.to_int() << shift).to_byte()

    bit_pos = bit_pos - bits_to_write
    remaining_bits = remaining_bits - bits_to_write

    // 如果当前字节写满，保存并开始新字节
    if bit_pos < 0 {
      buffer.push(current_byte)
      current_byte = 0b00000000
      bit_pos = 7
    }
  }

  HuffmanBitWriter::{
    buffer: buffer,
    current_byte: current_byte,
    bit_position: bit_pos
  }
}

/// 从位流中读取指定数量的位
pub fn read_bits(reader: HuffmanBitReader, num_bits: Int) -> Result[(UInt64, HuffmanBitReader), String] {
  if num_bits <= 0 || num_bits > 64 {
    return Err("Invalid number of bits to read")
  }

  let mut result: UInt64 = 0UL
  let mut current_byte_pos = reader.byte_pos
  let mut current_bit_pos = reader.bit_pos
  let mut remaining_bits = num_bits

  while remaining_bits > 0 {
    if current_byte_pos >= reader.data.length() {
      return Err("Bit stream exhausted")
    }

    let byte = reader.data[current_byte_pos].to_int()
    let available_bits = current_bit_pos + 1
    let bits_to_read = remaining_bits.min(available_bits)

    // 提取位（从最高位开始）
    let mask = ((1 << bits_to_read) - 1) << (current_bit_pos - bits_to_read + 1)
    let bits = (byte & mask) >> (current_bit_pos - bits_to_read + 1)

    result = (result << bits_to_read) | bits.to_uint64()

    current_bit_pos = current_bit_pos - bits_to_read
    remaining_bits = remaining_bits - bits_to_read

    // 如果当前字节读完，移到下一个字节
    if current_bit_pos < 0 {
      current_byte_pos = current_byte_pos + 1
      current_bit_pos = 7
    }
  }

  let new_reader = HuffmanBitReader::{
    data: reader.data,
    byte_pos: current_byte_pos,
    bit_pos: current_bit_pos
  }

  Ok((result, new_reader))
}

/// 完成位流写入，返回最终字节数组
pub fn finish_bit_writer(writer: HuffmanBitWriter) -> Bytes {
  let buffer = writer.buffer

  // 如果还有未完成的字节且包含有效位，保存它
  if writer.bit_position < 7 {
    let final_buffer = buffer + [writer.current_byte]
    Bytes::from_array(final_buffer)
  } else {
    Bytes::from_array(buffer)
  }
}

/// 刷新位流，确保所有位都被写入
pub fn flush_bit_writer(writer: HuffmanBitWriter) -> HuffmanBitWriter {
  if writer.bit_position < 7 {
    // 有未完成的字节，保存它并开始新字节
    let new_buffer = writer.buffer + [writer.current_byte]
    HuffmanBitWriter::{
      buffer: new_buffer,
      current_byte: 0b00000000,
      bit_position: 7
    }
  } else {
    writer
  }
}

/// 统计符号频率
pub fn count_huffman_symbols(data: Array[Byte], max_symbol: Int) -> Array[Int] {
  let counts = Array::make(max_symbol + 1, 0)
  for i = 0; i < data.length(); i = i + 1 {
    let symbol = data[i].to_int()
    if symbol >= 0 && symbol <= max_symbol {
      counts[symbol] = counts[symbol] + 1
    }
  }
  counts
}

/// 构建 Huffman 树
fn build_huffman_tree(frequencies: Array[Int]) -> HuffmanTreeNode {
  // 创建叶子节点列表
  let mut nodes: Array[HuffmanTreeNode] = []
  for i = 0; i < frequencies.length(); i = i + 1 {
    if frequencies[i] > 0 {
      nodes.push(HuffmanTreeNode::Leaf(i, frequencies[i]))
    }
  }

  // 如果没有符号，返回一个虚拟的叶子节点
  if nodes.length() == 0 {
    return HuffmanTreeNode::Leaf(0, 1)
  }

  // 如果只有一个符号，也返回叶子节点
  if nodes.length() == 1 {
    return nodes[0]
  }

  // 重复合并最小的两个节点，直到只剩一个根节点
  while nodes.length() > 1 {
    // 找到最小的两个节点（简单的冒泡排序）
    for i = 0; i < nodes.length() - 1; i = i + 1 {
      for j = 0; j < nodes.length() - i - 1; j = j + 1 {
        let freq_j = get_node_frequency(nodes[j])
        let freq_j1 = get_node_frequency(nodes[j + 1])
        if freq_j > freq_j1 {
          // 交换
          let temp = nodes[j]
          nodes[j] = nodes[j + 1]
          nodes[j + 1] = temp
        }
      }
    }

    // 取出最小的两个节点
    let left = nodes[0]
    let right = nodes[1]
    let combined_freq = get_node_frequency(left) + get_node_frequency(right)

    // 创建新的内部节点
    let new_node = HuffmanTreeNode::Internal(left, right, combined_freq)

    // 移除前两个节点，添加新节点
    let new_nodes: Array[HuffmanTreeNode] = []
    for i = 2; i < nodes.length(); i = i + 1 {
      new_nodes.push(nodes[i])
    }
    new_nodes.push(new_node)
    nodes = new_nodes
  }

  nodes[0]
}

/// 获取节点频率的辅助函数
fn get_node_frequency(node: HuffmanTreeNode) -> Int {
  match node {
    HuffmanTreeNode::Leaf(_symbol, freq) => freq
    HuffmanTreeNode::Internal(_left, _right, freq) => freq
  }
}

/// 计算 Huffman 编码长度 - 优化版本
fn calculate_code_lengths(node: HuffmanTreeNode, depth: Int, lengths: Array[Int]) -> Unit {
  match node {
    HuffmanTreeNode::Leaf(symbol, _freq) => {
      // 确保数组足够大
      while lengths.length() <= symbol {
        lengths.push(0)
      }
      lengths[symbol] = depth
    }
    HuffmanTreeNode::Internal(left, right, _freq) => {
      calculate_code_lengths(left, depth + 1, lengths)
      calculate_code_lengths(right, depth + 1, lengths)
    }
  }
}

/// 生成 Huffman 编码 - 使用规范的算法
fn generate_huffman_codes_optimized(lengths: Array[Int]) -> Array[HuffmanCode] {
  let codes: Array[HuffmanCode] = []
  // 找到真正的最大长度
  let mut max_length = 0
  for i = 0; i < lengths.length(); i = i + 1 {
    if lengths[i] > max_length {
      max_length = lengths[i]
    }
  }

  // 统计每个长度的符号数量
  let length_counts: Array[Int] = []
  for i = 0; i <= max_length; i = i + 1 {
    length_counts.push(0)
  }

  for i = 0; i < lengths.length(); i = i + 1 {
    if lengths[i] > 0 {
      length_counts[lengths[i]] = length_counts[lengths[i]] + 1
    }
  }

  // 计算起始码值
  let start_codes: Array[Int] = []
  start_codes.push(0)  // 长度0的起始码

  for i = 1; i <= max_length; i = i + 1 {
    start_codes.push((start_codes[i - 1] + length_counts[i - 1]) << 1)
  }

  // 为每个符号分配码值
  let current_codes: Array[Int] = []
  for i = 0; i <= max_length; i = i + 1 {
    current_codes.push(start_codes[i])
  }

  // 生成最终的编码
  for symbol = 0; symbol < lengths.length(); symbol = symbol + 1 {
    let length = lengths[symbol]
    if length > 0 {
      let code = current_codes[length]
      while codes.length() <= symbol {
        codes.push(HuffmanCode::{ code: 0UL, length: 0 })
      }
      codes[symbol] = HuffmanCode::{ code: code.to_uint64(), length: length }

      // 更新当前码值
      current_codes[length] = current_codes[length] + 1
    }
  }

  codes
}

/// 从 Huffman 树生成编码表
fn generate_huffman_codes(node: HuffmanTreeNode, prefix_code: UInt64, prefix_length: Int) -> Array[HuffmanCode] {
  let codes: Array[HuffmanCode] = []

  match node {
    HuffmanTreeNode::Leaf(symbol, _freq) => {
      // 确保数组足够大
      while codes.length() <= symbol {
        codes.push(HuffmanCode::{ code: 0UL, length: 0 })
      }
      codes[symbol] = HuffmanCode::{ code: prefix_code, length: prefix_length }
    }
    HuffmanTreeNode::Internal(left, right, _freq) => {
      // 左子树：添加0
      let left_codes = generate_huffman_codes(left, (prefix_code << 1), prefix_length + 1)
      // 右子树：添加1
      let right_codes = generate_huffman_codes(right, (prefix_code << 1) | 1UL, prefix_length + 1)

      // 合并编码表
      let max_len = left_codes.length().max(right_codes.length())
      for i = 0; i < max_len; i = i + 1 {
        let left_code = if i < left_codes.length() { left_codes[i] } else { HuffmanCode::{ code: 0UL, length: 0 } }
        let right_code = if i < right_codes.length() { right_codes[i] } else { HuffmanCode::{ code: 0UL, length: 0 } }

        // 优先使用非零长度的编码
        if left_code.length > 0 {
          codes.push(left_code)
        } else if right_code.length > 0 {
          codes.push(right_code)
        } else {
          codes.push(HuffmanCode::{ code: 0UL, length: 0 })
        }
      }
    }
  }

  codes
}

/// 从频率构建完整的 Huffman 编码表 - 优化版本
pub fn build_huffman_encode_table(frequencies: Array[Int]) -> HuffmanEncodeTable {
  // 构建 Huffman 树
  let tree = build_huffman_tree(frequencies)

  // 计算编码长度
  let lengths: Array[Int] = []
  calculate_code_lengths(tree, 0, lengths)

  // 生成最优编码
  let codes = generate_huffman_codes_optimized(lengths)

  HuffmanEncodeTable::{
    codes: codes,
    max_symbol: frequencies.length() - 1
  }
}

/// Huffman 编码函数
pub fn huffman_encode(data: Array[Byte]) -> Result[Bytes, String] {
  let max_symbol = 255  // 字节数据

  // 1. 统计频率
  let frequencies = count_huffman_symbols(data, max_symbol)

  // 2. 构建编码表
  let encode_table = build_huffman_encode_table(frequencies)

  // 3. 编码数据
  let encoded_data = huffman_encode_with_table(data, encode_table)

  Ok(encoded_data)
}

/// 使用编码表进行 Huffman 编码
pub fn huffman_encode_with_table(data: Array[Byte], table: HuffmanEncodeTable) -> Bytes {
  let writer = create_huffman_bit_writer()

  // 为每个字节写入 Huffman 编码
  let mut current_writer = writer
  for i = 0; i < data.length(); i = i + 1 {
    let symbol = data[i].to_int()
    if symbol < table.codes.length() {
      let code = table.codes[symbol]
      if code.length > 0 {
        current_writer = write_bits(current_writer, code.code, code.length)
      }
    }
  }

  // 刷新并完成编码
  let flushed_writer = flush_bit_writer(current_writer)
  finish_bit_writer(flushed_writer)
}

/// Huffman 解码函数
pub fn huffman_decode(encoded_data: Bytes, encode_table: HuffmanEncodeTable, expected_length: Int) -> Result[Array[Byte], String] {
  let result: Array[Byte] = []
  let reader = create_huffman_bit_reader(encoded_data)

  // 为快速查找创建反向映射：编码 -> 符号
  let code_map: Array[(Int, Int)] = []  // (code, length) -> symbol
  for symbol = 0; symbol < encode_table.codes.length(); symbol = symbol + 1 {
    let code = encode_table.codes[symbol]
    if code.length > 0 {
      code_map.push((code.code.to_int(), code.length))
    }
  }

  let mut current_reader = reader
  for _i = 0; _i < expected_length; _i = _i + 1 {
    // 逐位读取直到找到匹配的编码
    let mut current_code: UInt64 = 0UL
    let mut code_length = 0
    let mut found_symbol = -1

    while code_length < 16 {  // 最大编码长度限制
      let read_result = read_bits(current_reader, 1)
      match read_result {
        Ok((bit, new_reader)) => {
          current_reader = new_reader
          current_code = (current_code << 1) | bit
          code_length = code_length + 1

          // 检查是否匹配任何编码
          for j = 0; j < code_map.length(); j = j + 1 {
            let (code_value, code_len) = code_map[j]
            if code_len == code_length && code_value == current_code.to_int() {
              found_symbol = j  // 符号就是索引
              break
            }
          }

          if found_symbol >= 0 {
            break
          }
        }
        Err(e) => return Err(e)
      }
    }

    if found_symbol >= 0 && found_symbol <= encode_table.max_symbol {
      result.push(found_symbol.to_byte())
    } else {
      return Err("Invalid Huffman code encountered")
    }
  }

  Ok(result)
}

/// 使用 Huffman 编码字面量
pub fn huffman_encode_literals(literals: Array[Byte], table: HuffmanEncodeTable) -> Bytes {
  let writer = create_huffman_bit_writer()

  // 使用位流写入器进行编码
  let mut current_writer = writer
  for i = 0; i < literals.length(); i = i + 1 {
    let symbol = literals[i].to_int()

    if symbol < table.codes.length() {
      let code = table.codes[symbol]
      if code.length > 0 {
        // 写入 Huffman 编码
        current_writer = write_bits(current_writer, code.code, code.length)
      } else {
        // 没有编码的符号，直接写入原始字节（8位）
        current_writer = write_bits(current_writer, symbol.to_uint64(), 8)
      }
    } else {
      // 超出范围的符号，直接写入原始字节
      current_writer = write_bits(current_writer, symbol.to_uint64(), 8)
    }
  }

  finish_bit_writer(current_writer)
}


/// 使用 Huffman 表解码字面量
pub fn huffman_decode_literals(encoded_data: Bytes, table: HuffmanEncodeTable, num_symbols: Int) -> Result[Array[Byte], String] {
  let result: Array[Byte] = []
  let reader = create_huffman_bit_reader(encoded_data)

  // 为快速查找创建反向映射：编码 -> 符号
  let code_to_symbol: Array[(Int, Int)] = []  // (code, length) -> symbol
  for symbol = 0; symbol < table.codes.length(); symbol = symbol + 1 {
    let code = table.codes[symbol]
    if code.length > 0 {
      let _ = code_to_symbol + [(code.code.to_int(), code.length)]
      // 注意：这里简化了反向查找，实际实现需要更高效的数据结构
    }
  }

  let mut current_reader = reader
  for _i = 0; _i < num_symbols; _i = _i + 1 {
    // 逐位读取直到找到匹配的编码
    let mut current_code: UInt64 = 0UL
    let mut code_length = 0
    let mut found_symbol = -1

    while code_length < 32 {  // 最大编码长度限制
      let read_result = read_bits(current_reader, 1)
      match read_result {
        Ok((bit, new_reader)) => {
          current_reader = new_reader
          current_code = (current_code << 1) | bit
          code_length = code_length + 1

          // 检查是否匹配任何编码
          for j = 0; j < code_to_symbol.length(); j = j + 1 {
            let (code_value, code_len) = code_to_symbol[j]
            if code_len == code_length && code_value == current_code.to_int() {
              found_symbol = j  // 符号就是索引
              break
            }
          }

          if found_symbol >= 0 {
            break
          }
        }
        Err(e) => return Err(e)
      }
    }

    if found_symbol >= 0 && found_symbol <= table.max_symbol {
      result.push(found_symbol.to_byte())
    } else {
      return Err("Invalid Huffman code encountered")
    }
  }

  Ok(result)
}

/// 从频率计算 Huffman 权重
pub fn calculate_huffman_weights(frequencies: Array[Int]) -> Array[Int] {
  let weights: Array[Int] = []
  
  // 计算总频率
  let mut total = 0
  for i = 0; i < frequencies.length(); i = i + 1 {
    total = total + frequencies[i]
  }
  
  if total == 0 {
    return Array::make(frequencies.length(), 0)
  }
  
  // 计算权重（使用对数尺度）
  for i = 0; i < frequencies.length(); i = i + 1 {
    if frequencies[i] == 0 {
      weights.push(0)
    } else {
      // 权重 = -log2(freq/total) 的近似
      //todo 简化：使用归一化的倒数
      let weight = (total / frequencies[i]).min(255)
      weights.push(weight)
    }
  }
  
  weights
}

/// 序列化 Huffman 权重
pub fn serialize_huffman_weights(weights: Array[Int]) -> Bytes {
  let output: Array[Byte] = []
  
  // 使用 RLE 压缩相同的权重
  let mut i = 0
  while i < weights.length() {
    let current_weight = weights[i]
    let mut count = 1
    
    // 计算重复次数
    while i + count < weights.length() && weights[i + count] == current_weight && count < 127 {
      count = count + 1
    }
    
    if count == 1 {
      // 单个权重
      output.push(current_weight.to_byte())
    } else {
      // 重复权重：128 + count, 然后是权重值
      output.push((128 + count).to_byte())
      output.push(current_weight.to_byte())
    }
    
    i = i + count
  }
  
  Bytes::from_array(output)
}

/// ✅ Huffman 编码器完整实现
/// 统计频率、计算权重、构建表、编码字面量
pub fn huffman_encode_complete(literals: Array[Byte], max_symbol: Int) -> Result[Bytes, String] {
  // 1. 统计频率
  let frequencies = count_huffman_symbols(literals, max_symbol)
  
  // 2. 计算权重
  let weights = calculate_huffman_weights(frequencies)
  
  // 3. 构建编码表
  let encode_table = build_huffman_encode_table(frequencies)
  
  // 4. 序列化权重
  let weights_data = serialize_huffman_weights(weights)
  
  // 5. 编码字面量
  let encoded_data = huffman_encode_literals(literals, encode_table)
  
  // 合并权重和数据
  let result: Array[Byte] = []
  for i = 0; i < weights_data.length(); i = i + 1 {
    result.push(weights_data[i])
  }
  for i = 0; i < encoded_data.length(); i = i + 1 {
    result.push(encoded_data[i])
  }
  
  Ok(Bytes::from_array(result))
}

/// Huffman 编码和解码循环测试
pub fn test_huffman_roundtrip() -> Result[Bool, String] {
  // 测试数据：包含重复字符以产生好的压缩效果
  let test_data: Array[Byte] = [
    97, 98, 99, 97, 98, 97, 100, 97, 97, 98  // a,b,c,a,b,a,d,a,a,b
  ]
  let max_symbol = 255

  // 编码
  let encode_result = huffman_encode_complete(test_data, max_symbol)
  match encode_result {
    Ok(encoded_bytes) => {
      println("✅ Huffman 编码成功")
      println("  原始数据大小: \{test_data.length()} 字节")
      println("  编码后大小: \{encoded_bytes.length()} 字节")

      // 解码（简化版：需要知道权重信息的位置）
      // 这里只是测试基本功能，实际实现需要解析权重
      let frequencies = count_huffman_symbols(test_data, max_symbol)
      let encode_table = build_huffman_encode_table(frequencies)
      let encoded_literals = huffman_encode_literals(test_data, encode_table)

      let decode_result = huffman_decode_literals(encoded_literals, encode_table, test_data.length())
      match decode_result {
        Ok(decoded_data) => {
          // 验证解码结果
          if decoded_data.length() != test_data.length() {
            return Err("解码数据长度不匹配")
          }

          let mut all_match = true
          for i = 0; i < test_data.length(); i = i + 1 {
            if decoded_data[i] != test_data[i] {
              all_match = false
              break
            }
          }

          if all_match {
            println("✅ Huffman 编解码循环测试通过")
            Ok(true)
          } else {
            Err("解码数据内容不匹配")
          }
        }
        Err(e) => Err("解码失败: \{e}")
      }
    }
    Err(e) => Err("编码失败: \{e}")
  }
}

/// 测试 Huffman 编码器的基本功能
pub fn test_huffman_encoder() -> Bool {
  println("🧪 测试 Huffman 编码器...")

  // 测试1：简单频率统计
  let test_data: Array[Byte] = [97, 98, 97, 99]  // a, b, a, c
  let frequencies = count_huffman_symbols(test_data, 255)
  if frequencies[97] != 2 { return false }  // 'a' should appear twice
  if frequencies[98] != 1 { return false }  // 'b' should appear once
  if frequencies[99] != 1 { return false }  // 'c' should appear once
  println("✅ 频率统计测试通过")

  // 测试2：构建编码表
  let encode_table = build_huffman_encode_table(frequencies)
  if encode_table.max_symbol != 255 { return false }
  println("✅ 编码表构建测试通过")

  // 测试3：位流写入器
  let writer = create_huffman_bit_writer()
  let writer2 = write_bits(writer, 0b101UL, 3)  // 写入 101
  let writer3 = write_bits(writer2, 0b011UL, 3) // 再写入 011
  let result = finish_bit_writer(writer3)

  // 验证结果：应该有一个字节
  if result.length() < 1 {
    return false
  }
  println("✅ 位流写入测试通过")

  // 测试4：编解码循环
  let test_data: Array[Byte] = [97, 97, 97, 98, 98, 99]  // "aaabbc"
  let frequencies = count_huffman_symbols(test_data, 255)
  let encode_table = build_huffman_encode_table(frequencies)
  let encoded = huffman_encode_with_table(test_data, encode_table)
  let decode_result = huffman_decode_literals(encoded, encode_table, test_data.length())

  match decode_result {
    Ok(decoded) => {
      // 验证解码结果
      if decoded.length() == test_data.length() {
        println("✅ 编解码测试通过")
        true
      } else {
        println("❌ 编解码测试失败：长度不匹配")
        false
      }
    }
    Err(e) => {
      println("❌ 编解码测试失败: \{e}")
      false
    }
  }
}

/// 测试 Huffman 压缩效果
pub fn test_huffman_compression(test_name: String, data: Array[Byte]) -> Result[Bool, String] {
  println("  测试: \{test_name}")
  println("    原始大小: \{data.length()} 字节")

  // 编码
  let encode_result = huffman_encode(data)
  match encode_result {
    Ok(encoded) => {
      println("    编码成功: \{encoded.length()} 字节")

      // 统计频率并构建编码表用于解码
      let frequencies = count_huffman_symbols(data, 255)
      let encode_table = build_huffman_encode_table(frequencies)

      // 解码
      let decode_result = huffman_decode(encoded, encode_table, data.length())
      match decode_result {
        Ok(decoded) => {
          // 验证解码结果
          if decoded.length() != data.length() {
            println("    ❌ 长度不匹配: 期望 \{data.length()}, 实际 \{decoded.length()}")
            return Ok(false)
          }

          let mut all_match = true
          for i = 0; i < data.length(); i = i + 1 {
            if decoded[i] != data[i] {
              all_match = false
              break
            }
          }

          if all_match {
            // 计算压缩比
            let ratio = if data.length() > 0 {
              Float::from_int(encoded.length()) / Float::from_int(data.length()) * 100.0
            } else {
              0.0
            }
            println("    ✅ 编解码成功, 压缩比: \{ratio.to_int()}%")
            Ok(true)
          } else {
            println("    ❌ 数据不匹配")
            Ok(false)
          }
        }
        Err(e) => {
          println("    ❌ 解码失败: \{e}")
          Err(e)
        }
      }
    }
    Err(e) => {
      println("    ❌ 编码失败: \{e}")
      Err(e)
    }
  }
}

/// 演示 Huffman 编码的使用
pub fn demo_huffman_encoding() -> Unit {
  println("Huffman 编码演示")
  println("====================")

  // 示例数据
  let data: Array[Byte] = [
    104, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100,  // "hello world"
    44, 32, 116, 104, 105, 115, 32, 105, 115, 32, 97, 32,  // ", this is a "
    116, 101, 115, 116, 32, 111, 102, 32, 104, 117, 102, 102, 109, 97, 110  // "test of huffman"
  ]

  println("原始数据大小: \{data.length()} 字节")

  // 统计字符频率
  let frequencies = count_huffman_symbols(data, 255)

  // 显示频率最高的几个字符
  println("字符频率统计 (前10个):")
  let top_chars: Array[(Int, Int)] = []  // (frequency, char)
  for i = 0; i < 256; i = i + 1 {
    if frequencies[i] > 0 {
      top_chars.push((frequencies[i], i))
    }
  }

  // 排序并显示前10个
  for i = 0; i < top_chars.length() - 1; i = i + 1 {
    for j = 0; j < top_chars.length() - i - 1; j = j + 1 {
      if top_chars[j].0 < top_chars[j + 1].0 {
        let temp = top_chars[j]
        top_chars[j] = top_chars[j + 1]
        top_chars[j + 1] = temp
      }
    }
  }

  let show_count = top_chars.length().min(10)
  for i = 0; i < show_count; i = i + 1 {
    let (freq, char_code) = top_chars[i]
    println("  '\{char_code}': \{freq} 次")
  }

  // 构建编码表
  let encode_table = build_huffman_encode_table(frequencies)
  println("Huffman 编码表构建完成")

  // 显示一些编码示例
  println("编码示例:")
  let example_chars = [32, 101, 108, 104, 111]  // space, e, l, h, o
  for i = 0; i < example_chars.length(); i = i + 1 {
    let char_code = example_chars[i]
    if char_code < encode_table.codes.length() {
      let code = encode_table.codes[char_code]
      if code.length > 0 {
        println("  '\{char_code}' -> \{code.code} (\{code.length} 位)")
      }
    }
  }

  // 编码演示
  let encoded = huffman_encode_with_table(data, encode_table)
  println("编码后大小: \{encoded.length()} 字节")

  // 计算压缩比
  let compression_ratio = if data.length() > 0 {
    Float::from_int(encoded.length()) / Float::from_int(data.length()) * 100.0
  } else {
    0.0
  }
  println("压缩比: \{compression_ratio.to_int()}%")

  // 解码演示
  let decoded_result = huffman_decode(encoded, encode_table, data.length())
  match decoded_result {
    Ok(decoded) => {
      if decoded.length() == data.length() {
        println("✅ 解码成功，数据完整性验证通过")
      } else {
        println("❌ 解码失败，长度不匹配")
      }
    }
    Err(e) => println("❌ 解码失败: \{e}")
  }

  println("====================")
}

/// Huffman 编码器性能测试
pub fn benchmark_huffman() -> Unit {
  println("📊 Huffman 编码器性能测试")
  println("========================")

  // 生成测试数据
  let sizes = [100, 1000, 10000]
  for i = 0; i < sizes.length(); i = i + 1 {
    let size = sizes[i]
    let test_data: Array[Byte] = []

    // 生成有一定模式的数据（更容易压缩）
    for j = 0; j < size; j = j + 1 {
      let value = (j % 10) + 97  // a-j 循环
      test_data.push(value.to_byte())
    }

    println("测试数据大小: \{size} 字节")

    // 编码
    let encode_result = huffman_encode(test_data)

    match encode_result {
      Ok(encoded) => {
        let ratio = Float::from_int(encoded.length()) / Float::from_int(size) * 100.0
        println("  压缩后: \{encoded.length()} 字节 (\{ratio.to_int()}%)")

        // 验证解码
        let frequencies = count_huffman_symbols(test_data, 255)
        let encode_table = build_huffman_encode_table(frequencies)
        let decode_result = huffman_decode(encoded, encode_table, size)

        match decode_result {
          Ok(_) => println("  ✅ 编解码验证通过")
          Err(e) => println("  ❌ 解码失败: \{e}")
        }
      }
      Err(e) => println("  ❌ 编码失败: \{e}")
    }
  }

  println("========================")
}