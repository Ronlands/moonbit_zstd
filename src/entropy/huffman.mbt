/// Huffman 基础类型与基础解码入口。

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
} derive(Debug)

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

/// 解析 Huffman 权重，并做基础完整性校验。
pub fn parse_huffman_weights(data: Bytes, offset: Int, max_symbols: Int) -> Result[(HuffmanWeights, Int), String] {
  if offset >= data.length() {
    return Err("Truncated Huffman state: insufficient weight data (offset beyond data)")
  }

  let available_bytes = data.length() - offset
  if available_bytes < 1 {
    return Err("Truncated Huffman state: no bytes available for weights")
  }

  let weights: Array[Int] = []
  let mut current_offset = offset
  let mut symbols_parsed = 0
  let initial_offset = offset

  // 第 1 步：逐字节扫描权重流，支持普通权重和重复权重两种形式。
  while symbols_parsed < max_symbols && current_offset < data.length() {
    if current_offset - initial_offset > max_symbols {
      return Err("Truncated Huffman state: weight data parsing exceeded reasonable size")
    }

    let weight_byte = data[current_offset].to_int()
    current_offset = current_offset + 1

    if weight_byte < 128 {
      weights.push(weight_byte)
      symbols_parsed = symbols_parsed + 1
    } else {
      let repeat_count = weight_byte - 128
      if repeat_count > 256 {
        return Err("Huffman repeat count exceeds safety limit (256)")
      }
      if repeat_count > max_symbols - symbols_parsed {
        return Err("Truncated Huffman state: repeat count exceeds remaining symbols")
      }
      if symbols_parsed + repeat_count > max_symbols {
        return Err("Huffman total symbols would exceed max_symbols")
      }
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

  if symbols_parsed == 0 {
    return Err("Truncated Huffman state: no symbols parsed from weights")
  }

  // 第 2 步：把未提供的尾部符号补零，统一到固定长度。
  while weights.length() < max_symbols {
    weights.push(0)
  }

  let bytes_consumed = current_offset - offset
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
      while bits.length() <= symbol {
        bits.push(0)
      }
      bits[symbol] = depth
    }
    HuffmanTreeNode::Internal(left, right, _combined_freq) => {
      let left_bits = calculate_symbol_bits(left, depth + 1)
      let right_bits = calculate_symbol_bits(right, depth + 1)
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

/// 根据权重构建 Huffman 解码表。
pub fn build_huffman_table(weights: HuffmanWeights) -> Result[HuffmanTable, String] {
  let root = build_huffman_tree(weights.weights)
  let bits = calculate_symbol_bits(root, 0)
  let max_bits = if bits.length() > 0 { bits[0] } else { 0 }

  let symbols: Array[Int] = []
  for i = 0; i < weights.weights.length(); i = i + 1 {
    if weights.weights[i] > 0 {
      symbols.push(i)
    }
  }

  Ok(create_huffman_table_with_params(symbols, bits, max_bits, root))
}

/// 从位流中解码一个 Huffman 符号。
pub fn huffman_decode_symbol(table: HuffmanTable, bitstream: Bytes, bit_pos: Int) -> Result[(Int, Int), String] {
  let mut current_node = table.root
  let mut current_bit_pos = bit_pos
  let mut depth = 0
  let max_depth = 11

  if bit_pos >= bitstream.length() * 8 {
    return Err("Truncated Huffman state: bit position beyond bitstream")
  }

  while current_bit_pos < bitstream.length() * 8 {
    let byte_pos = current_bit_pos / 8
    let bit_offset = current_bit_pos % 8
    if byte_pos >= bitstream.length() {
      return Err("Truncated Huffman state: incomplete bitstream data")
    }

    depth = depth + 1
    if depth > max_depth {
      return Err("Truncated Huffman state: tree traversal depth exceeded")
    }

    match current_node {
      HuffmanNode::Leaf(symbol) => {
        return Ok((symbol, current_bit_pos))
      }
      HuffmanNode::Internal(left, right) => {
        let bit = (bitstream[byte_pos].to_int() >> bit_offset) & 1
        current_bit_pos = current_bit_pos + 1
        current_node = if bit == 0 { left } else { right }
      }
    }
  }

  match current_node {
    HuffmanNode::Leaf(_) => Err("Huffman decoding incomplete: reached end without processing leaf")
    HuffmanNode::Internal(_, _) => Err("Truncated Huffman state: bitstream ended in middle of symbol")
  }
}

/// 连续解码多个 Huffman 符号。
pub fn huffman_decode_multiple(
  table: HuffmanTable,
  bitstream: Bytes,
  bit_pos: Int,
  count: Int
) -> Result[(Array[Int], Int), String] {
  let result: Array[Int] = []
  let mut current_bit_pos = bit_pos

  if bitstream.length() == 0 {
    return Err("Truncated Huffman state: empty bitstream")
  }
  if bit_pos >= bitstream.length() * 8 {
    return Err("Truncated Huffman state: starting position beyond bitstream")
  }

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
        if new_bit_pos <= current_bit_pos {
          return Err("Truncated Huffman state: bit position not advancing at symbol " + i.to_string())
        }
        if new_bit_pos > bitstream.length() * 8 {
          return Err("Truncated Huffman state: bit position exceeded bitstream at symbol " + i.to_string())
        }
        current_bit_pos = new_bit_pos
      }
      Err(e) => {
        return Err(e + " (at symbol " + i.to_string() + "/" + count.to_string() + ")")
      }
    }
  }

  Ok((result, current_bit_pos))
}

/// 解码 Huffman 压缩的字面量区。
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

/// 基础 Huffman 测试。
pub fn test_basic_huffman() -> Bool {
  let weights: Array[Int] = [1, 2, 3, 4, 5]
  let huffman_weights = create_huffman_weights(weights)
  let table_result = build_huffman_table(huffman_weights)

  match table_result {
    Ok(table) => table.symbols.length() > 0
    Err(_) => false
  }
}
