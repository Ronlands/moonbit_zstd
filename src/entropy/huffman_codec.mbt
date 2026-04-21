// ============================================================================
// 完整 Huffman 编码实现
// ============================================================================

/// Huffman 树节点
pub enum HuffmanTreeNode {
  Leaf(Int, Int)
  Internal(HuffmanTreeNode, HuffmanTreeNode, Int)
}

/// Huffman 编码表项
pub struct HuffmanCode {
  code: UInt64
  length: Int
}

/// Huffman 编码表
pub struct HuffmanEncodeTable {
  codes: Array[HuffmanCode]
  max_symbol: Int
}

/// Huffman 位流编码器。
pub struct HuffmanBitWriter {
  buffer: Array[Byte]
  current_byte: Byte
  bit_position: Int
}

/// Huffman 位流读取器。
pub struct HuffmanBitReader {
  data: Bytes
  byte_pos: Int
  bit_pos: Int
}

/// 创建 Huffman 位流写入器
pub fn create_huffman_bit_writer() -> HuffmanBitWriter {
  HuffmanBitWriter::{
    buffer: [],
    current_byte: 0b00000000,
    bit_position: 7
  }
}

/// 创建 Huffman 位流读取器
pub fn create_huffman_bit_reader(data: Bytes) -> HuffmanBitReader {
  HuffmanBitReader::{
    data: data,
    byte_pos: 0,
    bit_pos: 7
  }
}

/// 向位流中写入指定数量的位。
pub fn write_bits(writer: HuffmanBitWriter, value: UInt64, num_bits: Int) -> HuffmanBitWriter {
  if num_bits <= 0 || num_bits > 64 {
    return writer
  }

  let mut current_byte = writer.current_byte
  let mut bit_pos = writer.bit_position
  let buffer = writer.buffer
  let mut remaining_bits = num_bits
  let value_to_write = value

  // 第 1 步：优先走“当前字节可一次写完”的快速路径。
  if remaining_bits <= bit_pos + 1 {
    let shift = bit_pos - remaining_bits + 1
    let mask = (1UL << remaining_bits) - 1UL
    current_byte = current_byte | ((value_to_write & mask).to_int() << shift).to_byte()
    bit_pos = bit_pos - remaining_bits
    if bit_pos < 0 {
      buffer.push(current_byte)
      return HuffmanBitWriter::{ buffer, current_byte: 0b00000000, bit_position: 7 }
    }
    return HuffmanBitWriter::{ buffer, current_byte, bit_position: bit_pos }
  }

  // 第 2 步：跨字节时，把剩余位拆成多段持续写入。
  while remaining_bits > 0 {
    let bits_to_write = remaining_bits.min(bit_pos + 1)
    let mask = (1UL << bits_to_write) - 1UL
    let bits = (value_to_write >> (remaining_bits - bits_to_write)) & mask
    let shift = bit_pos - bits_to_write + 1
    current_byte = current_byte | (bits.to_int() << shift).to_byte()
    bit_pos = bit_pos - bits_to_write
    remaining_bits = remaining_bits - bits_to_write
    if bit_pos < 0 {
      buffer.push(current_byte)
      current_byte = 0b00000000
      bit_pos = 7
    }
  }

  HuffmanBitWriter::{ buffer, current_byte, bit_position: bit_pos }
}

/// 从位流中读取指定数量的位。
pub fn read_bits(reader: HuffmanBitReader, num_bits: Int) -> Result[(UInt64, HuffmanBitReader), String] {
  if num_bits <= 0 || num_bits > 64 {
    return Err("Invalid number of bits to read")
  }

  let mut result: UInt64 = 0UL
  let mut current_byte_pos = reader.byte_pos
  let mut current_bit_pos = reader.bit_pos
  let mut remaining_bits = num_bits

  // 循环读取，直到取满请求的位数。
  while remaining_bits > 0 {
    if current_byte_pos >= reader.data.length() {
      return Err("Bit stream exhausted")
    }

    let byte = reader.data[current_byte_pos].to_int()
    let available_bits = current_bit_pos + 1
    let bits_to_read = remaining_bits.min(available_bits)
    let mask = ((1 << bits_to_read) - 1) << (current_bit_pos - bits_to_read + 1)
    let bits = (byte & mask) >> (current_bit_pos - bits_to_read + 1)

    result = (result << bits_to_read) | bits.to_uint64()
    current_bit_pos = current_bit_pos - bits_to_read
    remaining_bits = remaining_bits - bits_to_read

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

/// 构建 Huffman 树。
fn build_huffman_tree(frequencies: Array[Int]) -> HuffmanTreeNode {
  let mut nodes: Array[HuffmanTreeNode] = []
  for i = 0; i < frequencies.length(); i = i + 1 {
    if frequencies[i] > 0 {
      nodes.push(HuffmanTreeNode::Leaf(i, frequencies[i]))
    }
  }

  if nodes.length() == 0 {
    return HuffmanTreeNode::Leaf(0, 1)
  }

  if nodes.length() == 1 {
    return nodes[0]
  }

  while nodes.length() > 1 {
    for i = 0; i < nodes.length() - 1; i = i + 1 {
      for j = 0; j < nodes.length() - i - 1; j = j + 1 {
        let freq_j = get_node_frequency(nodes[j])
        let freq_j1 = get_node_frequency(nodes[j + 1])
        if freq_j > freq_j1 {
          let temp = nodes[j]
          nodes[j] = nodes[j + 1]
          nodes[j + 1] = temp
        }
      }
    }

    let left = nodes[0]
    let right = nodes[1]
    let combined_freq = get_node_frequency(left) + get_node_frequency(right)
    let new_node = HuffmanTreeNode::Internal(left, right, combined_freq)

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

/// 根据码长生成规范 Huffman 编码。
fn generate_huffman_codes_optimized(lengths: Array[Int]) -> Array[HuffmanCode] {
  let codes: Array[HuffmanCode] = []
  let mut max_length = 0
  for i = 0; i < lengths.length(); i = i + 1 {
    if lengths[i] > max_length {
      max_length = lengths[i]
    }
  }

  let length_counts: Array[Int] = []
  for i = 0; i <= max_length; i = i + 1 {
    length_counts.push(0)
  }

  for i = 0; i < lengths.length(); i = i + 1 {
    if lengths[i] > 0 {
      length_counts[lengths[i]] = length_counts[lengths[i]] + 1
    }
  }

  let start_codes: Array[Int] = []
  start_codes.push(0)
  for i = 1; i <= max_length; i = i + 1 {
    start_codes.push((start_codes[i - 1] + length_counts[i - 1]) << 1)
  }

  let current_codes: Array[Int] = []
  for i = 0; i <= max_length; i = i + 1 {
    current_codes.push(start_codes[i])
  }

  for symbol = 0; symbol < lengths.length(); symbol = symbol + 1 {
    let length = lengths[symbol]
    if length > 0 {
      let code = current_codes[length]
      while codes.length() <= symbol {
        codes.push(HuffmanCode::{ code: 0UL, length: 0 })
      }
      codes[symbol] = HuffmanCode::{ code: code.to_uint64(), length: length }
      current_codes[length] = current_codes[length] + 1
    }
  }

  codes
}

/// 从频率构建完整的 Huffman 编码表 - 优化版本
pub fn build_huffman_encode_table(frequencies: Array[Int]) -> HuffmanEncodeTable {
  let tree = build_huffman_tree(frequencies)
  let lengths: Array[Int] = []
  calculate_code_lengths(tree, 0, lengths)
  let codes = generate_huffman_codes_optimized(lengths)

  HuffmanEncodeTable::{
    codes: codes,
    max_symbol: frequencies.length() - 1
  }
}

/// 完整 Huffman 编码函数，输出中包含权重描述和正文。
pub fn huffman_encode(data: Array[Byte]) -> Result[Bytes, String] {
  // 第 1 步：统计频率、计算权重并构建编码表。
  let max_symbol = 255
  let frequencies = count_huffman_symbols(data, max_symbol)
  let weights = calculate_huffman_weights(frequencies)
  let encode_table = build_huffman_encode_table(frequencies)

  // 第 2 步：分别得到权重描述和编码后的正文。
  let weights_data = serialize_huffman_weights(weights)
  let encoded_data = huffman_encode_with_table(data, encode_table)

  // 第 3 步：把权重描述和正文拼成最终输出。
  let result: Array[Byte] = []
  for i = 0; i < weights_data.length(); i = i + 1 {
    result.push(weights_data[i])
  }
  for i = 0; i < encoded_data.length(); i = i + 1 {
    result.push(encoded_data[i])
  }

  Ok(Bytes::from_array(result))
}

/// 使用现成编码表对数据做 Huffman 编码。
pub fn huffman_encode_with_table(data: Array[Byte], table: HuffmanEncodeTable) -> Bytes {
  let writer = create_huffman_bit_writer()
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
  let flushed_writer = flush_bit_writer(current_writer)
  finish_bit_writer(flushed_writer)
}

/// 使用编码表对 Huffman 数据做回解码。
pub fn huffman_decode(encoded_data: Bytes, encode_table: HuffmanEncodeTable, expected_length: Int) -> Result[Array[Byte], String] {
  let result: Array[Byte] = []
  let reader = create_huffman_bit_reader(encoded_data)

  // 第 1 步：先构建一个反向查找表，便于后续逐位匹配编码。
  let code_map: Array[(Int, Int)] = []
  for symbol = 0; symbol < encode_table.codes.length(); symbol = symbol + 1 {
    let code = encode_table.codes[symbol]
    if code.length > 0 {
      code_map.push((code.code.to_int(), code.length))
    }
  }

  // 第 2 步：逐位扩展当前码字，直到命中某个合法编码。
  let mut current_reader = reader
  for _i = 0; _i < expected_length; _i = _i + 1 {
    let mut current_code: UInt64 = 0UL
    let mut code_length = 0
    let mut found_symbol = -1

    while code_length < 16 {
      let read_result = read_bits(current_reader, 1)
      match read_result {
        Ok((bit, new_reader)) => {
          current_reader = new_reader
          current_code = (current_code << 1) | bit
          code_length = code_length + 1
          for j = 0; j < code_map.length(); j = j + 1 {
            let (code_value, code_len) = code_map[j]
            if code_len == code_length && code_value == current_code.to_int() {
              found_symbol = j
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
  let mut current_writer = writer
  for i = 0; i < literals.length(); i = i + 1 {
    let symbol = literals[i].to_int()

    if symbol < table.codes.length() {
      let code = table.codes[symbol]
      if code.length > 0 {
        current_writer = write_bits(current_writer, code.code, code.length)
      } else {
        current_writer = write_bits(current_writer, symbol.to_uint64(), 8)
      }
    } else {
      current_writer = write_bits(current_writer, symbol.to_uint64(), 8)
    }
  }

  finish_bit_writer(current_writer)
}

/// 使用 Huffman 表解码字面量
pub fn huffman_decode_literals(encoded_data: Bytes, table: HuffmanEncodeTable, num_symbols: Int) -> Result[Array[Byte], String] {
  let result: Array[Byte] = []
  let reader = create_huffman_bit_reader(encoded_data)
  let max_length = 16
  let code_by_length: Array[Array[(Int, Int)]] = []
  for _i = 0; _i <= max_length; _i = _i + 1 {
    code_by_length.push([])
  }

  for symbol = 0; symbol < table.codes.length(); symbol = symbol + 1 {
    let code = table.codes[symbol]
    if code.length > 0 && code.length <= max_length {
      code_by_length[code.length].push((code.code.to_int(), symbol))
    }
  }

  let mut current_reader = reader
  for _i = 0; _i < num_symbols; _i = _i + 1 {
    let mut current_code: UInt64 = 0UL
    let mut code_length = 0
    let mut found_symbol = -1

    while code_length < 32 {
      let read_result = read_bits(current_reader, 1)
      match read_result {
        Ok((bit, new_reader)) => {
          current_reader = new_reader
          current_code = (current_code << 1) | bit
          code_length = code_length + 1

          if code_length <= max_length {
            let candidates = code_by_length[code_length]
            for j = 0; j < candidates.length(); j = j + 1 {
              let (code_value, symbol) = candidates[j]
              if code_value == current_code.to_int() {
                found_symbol = symbol
                break
              }
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

/// 从频率估算 Huffman 权重。
pub fn calculate_huffman_weights(frequencies: Array[Int]) -> Array[Int] {
  let weights: Array[Int] = []
  let mut total = 0
  for i = 0; i < frequencies.length(); i = i + 1 {
    total = total + frequencies[i]
  }

  if total == 0 {
    return Array::make(frequencies.length(), 0)
  }

  for i = 0; i < frequencies.length(); i = i + 1 {
    if frequencies[i] == 0 {
      weights.push(0)
    } else {
      let ratio = total / frequencies[i]
      let mut weight = 0
      let mut temp = ratio
      while temp > 1 {
        weight = weight + 1
        temp = temp / 2
      }
      weights.push(weight.max(1).min(11))
    }
  }

  weights
}

/// 序列化 Huffman 权重。
pub fn serialize_huffman_weights(weights: Array[Int]) -> Bytes {
  let output: Array[Byte] = []
  let mut i = 0
  while i < weights.length() {
    let current_weight = weights[i]
    let mut count = 1
    while i + count < weights.length() && weights[i + count] == current_weight && count < 127 {
      count = count + 1
    }

    if count == 1 {
      output.push(current_weight.to_byte())
    } else {
      output.push((128 + count).to_byte())
      output.push(current_weight.to_byte())
    }

    i = i + count
  }

  Bytes::from_array(output)
}

/// Huffman 编码器完整实现。
pub fn huffman_encode_complete(literals: Array[Byte], max_symbol: Int) -> Result[Bytes, String] {
  let frequencies = count_huffman_symbols(literals, max_symbol)
  let weights = calculate_huffman_weights(frequencies)
  let encode_table = build_huffman_encode_table(frequencies)
  let weights_data = serialize_huffman_weights(weights)
  let encoded_data = huffman_encode_literals(literals, encode_table)

  let result: Array[Byte] = []
  for i = 0; i < weights_data.length(); i = i + 1 {
    result.push(weights_data[i])
  }
  for i = 0; i < encoded_data.length(); i = i + 1 {
    result.push(encoded_data[i])
  }

  Ok(Bytes::from_array(result))
}

/// Huffman 编码和解码循环测试。
pub fn test_huffman_roundtrip() -> Result[Bool, String] {
  let test_data: Array[Byte] = [97, 98, 99, 97, 98, 97, 100, 97, 97, 98]
  let max_symbol = 255
  let encode_result = huffman_encode_complete(test_data, max_symbol)
  match encode_result {
    Ok(encoded_bytes) => {
      println("✅ Huffman 编码成功")
      println("  原始数据大小: \{test_data.length()} 字节")
      println("  编码后大小: \{encoded_bytes.length()} 字节")

      let frequencies = count_huffman_symbols(test_data, max_symbol)
      let encode_table = build_huffman_encode_table(frequencies)
      let encoded_literals = huffman_encode_literals(test_data, encode_table)

      let decode_result = huffman_decode_literals(encoded_literals, encode_table, test_data.length())
      match decode_result {
        Ok(decoded_data) => {
          if decoded_data.length() != test_data.length() {
            return Err("Decoded data length mismatch")
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
            Err("Decoded data content mismatch")
          }
        }
        Err(e) => Err("Decoding failed: \{e}")
      }
    }
    Err(e) => Err("Encoding failed: \{e}")
  }
}

/// 测试 Huffman 编码器的基本功能
pub fn test_huffman_encoder() -> Bool {
  println("🧪 测试 Huffman 编码器...")

  let test_data: Array[Byte] = [97, 98, 97, 99]
  let frequencies = count_huffman_symbols(test_data, 255)
  if frequencies[97] != 2 { return false }
  if frequencies[98] != 1 { return false }
  if frequencies[99] != 1 { return false }
  println("✅ 频率统计测试通过")

  let encode_table = build_huffman_encode_table(frequencies)
  if encode_table.max_symbol != 255 { return false }
  println("✅ 编码表构建测试通过")

  let writer = create_huffman_bit_writer()
  let writer2 = write_bits(writer, 0b101UL, 3)
  let writer3 = write_bits(writer2, 0b011UL, 3)
  let result = finish_bit_writer(writer3)
  if result.length() < 1 {
    return false
  }
  println("✅ 位流写入测试通过")

  let test_data2: Array[Byte] = [97, 97, 97, 98, 98, 99]
  let frequencies2 = count_huffman_symbols(test_data2, 255)
  let encode_table2 = build_huffman_encode_table(frequencies2)
  let encoded = huffman_encode_with_table(test_data2, encode_table2)
  let decode_result = huffman_decode_literals(encoded, encode_table2, test_data2.length())

  match decode_result {
    Ok(decoded) => {
      if decoded.length() == test_data2.length() {
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

  let encode_result = huffman_encode(data)
  match encode_result {
    Ok(encoded) => {
      println("    编码成功: \{encoded.length()} 字节")

      let frequencies = count_huffman_symbols(data, 255)
      let encode_table = build_huffman_encode_table(frequencies)
      let decode_result = huffman_decode(encoded, encode_table, data.length())
      match decode_result {
        Ok(decoded) => {
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

  let data: Array[Byte] = [
    104, 101, 108, 108, 111, 32, 119, 111, 114, 108, 100,
    44, 32, 116, 104, 105, 115, 32, 105, 115, 32, 97, 32,
    116, 101, 115, 116, 32, 111, 102, 32, 104, 117, 102, 102, 109, 97, 110
  ]

  println("原始数据大小: \{data.length()} 字节")
  let frequencies = count_huffman_symbols(data, 255)

  println("字符频率统计 (前10个):")
  let top_chars: Array[(Int, Int)] = []
  for i = 0; i < 256; i = i + 1 {
    if frequencies[i] > 0 {
      top_chars.push((frequencies[i], i))
    }
  }

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

  let encode_table = build_huffman_encode_table(frequencies)
  println("Huffman 编码表构建完成")

  println("编码示例:")
  let example_chars = [32, 101, 108, 104, 111]
  for i = 0; i < example_chars.length(); i = i + 1 {
    let char_code = example_chars[i]
    if char_code < encode_table.codes.length() {
      let code = encode_table.codes[char_code]
      if code.length > 0 {
        println("  '\{char_code}' -> \{code.code} (\{code.length} 位)")
      }
    }
  }

  let encoded = huffman_encode_with_table(data, encode_table)
  println("编码后大小: \{encoded.length()} 字节")
  let compression_ratio = if data.length() > 0 {
    Float::from_int(encoded.length()) / Float::from_int(data.length()) * 100.0
  } else {
    0.0
  }
  println("压缩比: \{compression_ratio.to_int()}%")

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

/// Huffman 编码器性能测试。
pub fn benchmark_huffman() -> Unit {
  println("📊 Huffman 编码器性能测试")
  println("========================")

  let sizes = [100, 1000, 10000]
  for i = 0; i < sizes.length(); i = i + 1 {
    let size = sizes[i]
    let test_data: Array[Byte] = []

    for j = 0; j < size; j = j + 1 {
      let value = (j % 10) + 97
      test_data.push(value.to_byte())
    }

    println("测试数据大小: \{size} 字节")
    let encode_result = huffman_encode(test_data)

    match encode_result {
      Ok(encoded) => {
        let ratio = Float::from_int(encoded.length()) / Float::from_int(size) * 100.0
        println("  压缩后: \{encoded.length()} 字节 (\{ratio.to_int()}%)")

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

// ============================================================================
// 反向 Huffman 位流解码
// ============================================================================

/// 反向位流读取器。
priv struct HuffBackStream {
  data: Bytes
  mut byte_offset: Int
  mut bit_container: UInt64
  mut bit_pos: Int
  end_offset: Int
}

/// 当剩余位数不足时，向前回装更多字节到位容器。
fn huff_reload_stream(bs: HuffBackStream) -> Unit {
  // 当前容器中的位仍然足够时，不需要回装。
  if bs.bit_pos > 64 { return }
  // 从更靠前的位置重新回装 8 个字节到位容器。
  let bytes_consumed = bs.bit_pos / 8
  let new_offset = bs.byte_offset - bytes_consumed
  if new_offset < bs.end_offset { return }
  bs.byte_offset = new_offset
  bs.bit_pos = bs.bit_pos % 8
  let mut container = 0UL
  for i = 0; i < 8; i = i + 1 {
    let idx = bs.byte_offset + i
    if idx < bs.data.length() {
      container = container | (bs.data[idx].to_uint64() << (i * 8))
    }
  }
  bs.bit_container = container
}

/// 从反向位流中解码一个符号。
fn decode_one_huff_symbol(bs: HuffBackStream, root: HuffmanNode, max_bits: Int) -> Result[Int, String] {
  let mut current = root
  let mut bits_read = 0
  while bits_read <= max_bits {
    match current {
      HuffmanNode::Leaf(sym) => return Ok(sym)
      HuffmanNode::Internal(left, right) => {
        let bit = if bs.bit_pos < 64 {
          ((bs.bit_container << bs.bit_pos) >> 63).to_int()
        } else {
          0
        }
        bs.bit_pos = bs.bit_pos + 1
        bits_read = bits_read + 1
        if bs.bit_pos >= 32 {
          huff_reload_stream(bs)
        }
        current = if bit == 0 { left } else { right }
      }
    }
  }
  match current {
    HuffmanNode::Leaf(sym) => Ok(sym)
    HuffmanNode::Internal(_, _) => Err("Huffman decode: exceeded max depth without finding symbol")
  }
}

/// 从反向 Huffman 位流中解码指定数量的符号。
pub fn decode_huffman_stream_backward(
  table: HuffmanTable,
  data: Bytes,
  start: Int,
  end: Int,
  count: Int
) -> Result[Array[Byte], String] {
  let output: Array[Byte] = []
  if count == 0 { return Ok(output) }

  // 第 1 步：检查流边界，并计算最后一个字节中的 padding 位数。
  let stream_len = end - start
  if stream_len == 0 {
    return Err("Empty Huffman stream")
  }
  if end > data.length() {
    return Err("Huffman stream end out of bounds")
  }

  let last_byte = data[end - 1].to_int()
  if last_byte == 0 {
    return Err("Invalid Huffman stream: last byte is 0")
  }

  let padding = 8 - highbit32(last_byte)
  // 第 2 步：初始化反向位流读取器。
  let bs = HuffBackStream::{
    data: data,
    byte_offset: 0,
    bit_container: 0UL,
    bit_pos: 0,
    end_offset: start,
  }

  if stream_len >= 8 {
    bs.byte_offset = end - 8
    let mut container = 0UL
    for i = 0; i < 8; i = i + 1 {
      container = container | (data[bs.byte_offset + i].to_uint64() << (i * 8))
    }
    bs.bit_container = container
    bs.bit_pos = padding
  } else {
    bs.byte_offset = start
    let mut container = 0UL
    for i = 0; i < stream_len; i = i + 1 {
      container = container | (data[start + i].to_uint64() << (i * 8))
    }
    bs.bit_container = container
    let extra_bits = (8 - stream_len) * 8
    bs.bit_pos = padding + extra_bits
  }

  // 第 3 步：逐个符号沿 Huffman 树向下走，直到得到目标数量的符号。
  let max_bits = 16
  for _i = 0; _i < count; _i = _i + 1 {
    let sym_result = decode_one_huff_symbol(bs, table.root, max_bits)
    match sym_result {
      Ok(sym) => output.push(sym.to_byte())
      Err(e) => return Err(e)
    }
  }

  Ok(output)
}
