/// Huffman decoder implementation
/// Used for decoding literals in ZSTD
/// Following RFC 8878 specification

/// Huffman表结构
pub struct HuffmanTable {
  symbols: Array[Int]
  num_bits: Array[Int]
  max_bits: Int
  root: HuffmanNode
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
  {
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
  root: HuffmanNode
) -> HuffmanTable {
  { symbols, num_bits, max_bits, root }
}

/// 创建默认的Huffman权重
pub fn create_default_huffman_weights() -> HuffmanWeights {
  {
    weights: Array::make(256, 0),
    count: 0
  }
}

/// 创建Huffman权重
pub fn create_huffman_weights(weights: Array[Int]) -> HuffmanWeights {
  {
    weights: weights,
    count: weights.length()
  }
}

/// 解析Huffman权重
pub fn parse_huffman_weights(data: Bytes, offset: Int, max_symbols: Int) -> Result[(HuffmanWeights, Int), String] {
  if offset >= data.length() {
    return Err("Huffman权重数据不足")
  }
  
  let weights: Array[Int] = []
  let mut current_offset = offset
  let mut symbols_parsed = 0
  
  while symbols_parsed < max_symbols && current_offset < data.length() {
    let weight_byte = data[current_offset].to_int()
    current_offset = current_offset + 1
    
    if weight_byte < 128 {
      // 单字节权重
      weights.push(weight_byte)
      symbols_parsed = symbols_parsed + 1
    } else {
      // 重复权重
      let repeat_count = weight_byte - 128
      let next_byte = if current_offset < data.length() { data[current_offset].to_int() } else { 0 }
      current_offset = current_offset + 1
      
      for _i = 0; _i < repeat_count && symbols_parsed < max_symbols; _i = _i + 1 {
        weights.push(next_byte)
        symbols_parsed = symbols_parsed + 1
      }
    }
  }
  
  // 填充到最大符号数
  while weights.length() < max_symbols {
    weights.push(0)
  }
  
  Ok((create_huffman_weights(weights), current_offset - offset))
}

/// 构建Huffman树
fn build_huffman_tree(weights: Array[Int]) -> Result[HuffmanNode, String] {
  // 创建节点列表
  let mut nodes: Array[(Int, HuffmanNode)] = []
  
  for i = 0; i < weights.length(); i = i + 1 {
    if weights[i] > 0 {
      nodes.push((weights[i], HuffmanNode::Leaf(i)))
    }
  }
  
  if nodes.length() == 0 {
    return Err("没有有效的权重")
  }
  
  // 构建Huffman树
  while nodes.length() > 1 {
    // 按权重排序
    nodes.sort_by(fn(a: (Int, HuffmanNode), b: (Int, HuffmanNode)) -> Int {
      a.0.compare(b.0)
    })
    
    // 取两个最小权重的节点
    let (weight1, node1) = nodes[0]
    let (weight2, node2) = nodes[1]
    
    // 创建新的内部节点
    let new_weight = weight1 + weight2
    let new_node = HuffmanNode::Internal(node1, node2)
    
    // 移除已使用的节点，添加新节点
    let new_nodes: Array[(Int, HuffmanNode)] = []
    for i = 2; i < nodes.length(); i = i + 1 {
      new_nodes.push(nodes[i])
    }
    new_nodes.push((new_weight, new_node))
    nodes = new_nodes
  }
  
  Ok(nodes[0].1)
}

/// 计算每个符号的位数
fn calculate_symbol_bits(node: HuffmanNode, depth: Int) -> Array[Int] {
  let bits: Array[Int] = []
  
  match node {
    HuffmanNode::Leaf(symbol) => {
      // 确保数组足够大
      while bits.length() <= symbol {
        bits.push(0)
      }
      bits[symbol] = depth
    }
    HuffmanNode::Internal(left, right) => {
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
  let tree_result = build_huffman_tree(weights.weights)
  
  match tree_result {
    Ok(root) => {
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
    Err(e) => Err(e)
  }
}

/// 从位流中解码Huffman符号
pub fn huffman_decode_symbol(table: HuffmanTable, bitstream: Bytes, bit_pos: Int) -> Result[(Int, Int), String] {
  let mut current_node = table.root
  let mut current_bit_pos = bit_pos
  
  while current_bit_pos < bitstream.length() * 8 {
    let byte_pos = current_bit_pos / 8
    let bit_offset = current_bit_pos % 8
    
    if byte_pos >= bitstream.length() {
      return Err("位流数据不足")
    }
    
    let bit = (bitstream[byte_pos].to_int() >> bit_offset) & 1
    current_bit_pos = current_bit_pos + 1
    
    match current_node {
      HuffmanNode::Leaf(symbol) => {
        return Ok((symbol, current_bit_pos))
      }
      HuffmanNode::Internal(left, right) => {
        current_node = if bit == 0 { left } else { right }
      }
    }
  }
  
  Err("Huffman解码失败：未找到叶子节点")
}

/// 批量解码Huffman符号
pub fn huffman_decode_multiple(
  table: HuffmanTable,
  bitstream: Bytes,
  bit_pos: Int,
  count: Int
) -> Result[(Array[Int], Int), String] {
  let result: Array[Int] = []
  let mut current_bit_pos = bit_pos
  
  for _i = 0; _i < count; _i = _i + 1 {
    let decode_result = huffman_decode_symbol(table, bitstream, current_bit_pos)
    match decode_result {
      Ok((symbol, new_bit_pos)) => {
        result.push(symbol)
        current_bit_pos = new_bit_pos
      }
      Err(e) => return Err(e)
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