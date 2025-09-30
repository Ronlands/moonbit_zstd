/// Huffman解码器模块
/// 基于zstd官方库实现的Huffman树解码算法

/// Huffman解码表
struct HuffmanTable {
  table_log: Int              // 表的对数大小
  max_symbol: Int             // 最大符号值
  decode_table: Array[Int]    // 解码表
  symbols: Array[Byte]        // 符号表
  num_bits: Array[Byte]       // 每个符号的位数表
}

/// Huffman权重
struct HuffmanWeights {
  weights: Array[Int]         // 权重数组
  count: Int                  // 权重数量
}

/// 创建空的Huffman表
pub fn create_huffman_table() -> HuffmanTable {
  {
    table_log: 0,
    max_symbol: 0,
    decode_table: [],
    symbols: [],
    num_bits: []
  }
}

/// 解析Huffman权重
/// 参考官方库的HUF_readStats实现
pub fn parse_huffman_weights(data: Bytes, offset: Int, max_size: Int) -> Result[(HuffmanWeights, Int), String] {
  if offset >= data.length() {
    return Err("数据不足以读取Huffman权重")
  }
  
  let header_byte = data[offset].to_int()
  
  if header_byte < 128 {
    // FSE压缩的权重
    parse_fse_compressed_weights(data, offset, header_byte, max_size)
  } else {
    // 直接表示的权重
    parse_direct_weights(data, offset, header_byte - 127, max_size)
  }
}

/// 解析直接表示的权重
fn parse_direct_weights(data: Bytes, offset: Int, num_weights: Int, max_size: Int) -> Result[(HuffmanWeights, Int), String] {
  let bytes_needed = (num_weights + 1) / 2
  
  if offset + bytes_needed > data.length() {
    return Err("数据不足以读取直接权重")
  }
  
  let weights: Array[Int] = Array::make(256, 0)
  let mut i = 0
  let mut byte_offset = offset + 1
  
  while i < num_weights {
    let byte_val = data[byte_offset].to_int()
    weights[i] = (byte_val >> 4) & 0xF
    i = i + 1
    
    if i < num_weights {
      weights[i] = byte_val & 0xF
      i = i + 1
    }
    
    byte_offset = byte_offset + 1
  }
  
  // 计算最后一个权重
  let mut weight_sum = 0
  for j = 0; j < num_weights; j = j + 1 {
    if weights[j] > 0 {
      weight_sum = weight_sum + (1 << (weights[j] - 1))
    }
  }
  
  // 找到下一个2的幂
  let mut power_of_2 = 1
  while power_of_2 <= weight_sum {
    power_of_2 = power_of_2 * 2
  }
  
  // 最后一个权重
  let last_weight = power_of_2 - weight_sum
  if last_weight > 0 {
    let mut last_weight_log = 0
    let mut temp = last_weight
    while temp > 1 {
      temp = temp / 2
      last_weight_log = last_weight_log + 1
    }
    weights[num_weights] = last_weight_log + 1
  }
  
  let result = {
    weights: weights,
    count: num_weights + 1
  }
  
  Ok((result, bytes_needed + 1))
}

/// 解析FSE压缩的权重（改进版本）
fn parse_fse_compressed_weights(data: Bytes, offset: Int, compressed_size: Int, max_size: Int) -> Result[(HuffmanWeights, Int), String] {
  if offset + compressed_size > data.length() {
    return Err("FSE压缩权重数据超出范围")
  }
  
  // 创建权重数组
  let weights: Array[Int] = Array::make(max_size.min(256), 0)
  
  // 简化的FSE解压缩 - 实际应该使用完整的FSE解码器
  // 这里使用基本的位操作来解析权重
  let mut current_offset = offset + 1
  let mut weight_count = 0
  
  // 读取压缩数据并解析权重
  while current_offset < offset + compressed_size && weight_count < weights.length() {
    if current_offset >= data.length() {
      break
    }
    
    let byte_val = data[current_offset].to_int()
    
    // 简单的权重提取（实际FSE会更复杂）
    let weight1 = (byte_val >> 4) & 0xF
    let weight2 = byte_val & 0xF
    
    if weight_count < weights.length() && weight1 > 0 {
      weights[weight_count] = weight1
      weight_count = weight_count + 1
    }
    
    if weight_count < weights.length() && weight2 > 0 {
      weights[weight_count] = weight2  
      weight_count = weight_count + 1
    }
    
    current_offset = current_offset + 1
  }
  
  // 计算最后一个权重以确保权重总和是2的幂
  if weight_count < weights.length() {
    let mut weight_sum = 0
    for i = 0; i < weight_count; i = i + 1 {
      if weights[i] > 0 {
        weight_sum = weight_sum + (1 << (weights[i] - 1))
      }
    }
    
    // 找到下一个2的幂
    let mut power_of_2 = 1
    while power_of_2 <= weight_sum {
      power_of_2 = power_of_2 * 2
    }
    
    // 计算最后权重
    let last_weight = power_of_2 - weight_sum
    if last_weight > 0 && weight_count < weights.length() {
      let mut last_weight_log = 0
      let mut temp = last_weight
      while temp > 1 {
        temp = temp / 2
        last_weight_log = last_weight_log + 1
      }
      weights[weight_count] = last_weight_log + 1
      weight_count = weight_count + 1
    }
  }
  
  let result = {
    weights: weights,
    count: weight_count
  }
  
  Ok((result, compressed_size + 1))
}

/// 从权重构建Huffman表
/// 参考官方库的HUF_buildDTable实现
pub fn build_huffman_table(weights: HuffmanWeights) -> Result[HuffmanTable, String] {
  if weights.count == 0 {
    return Err("权重数量为0")
  }
  
  // 计算最大权重和表对数
  let mut max_weight = 0
  let mut weight_sum = 0
  
  for i = 0; i < weights.count; i = i + 1 {
    if weights.weights[i] > max_weight {
      max_weight = weights.weights[i]
    }
    if weights.weights[i] > 0 {
      weight_sum = weight_sum + (1 << (weights.weights[i] - 1))
    }
  }
  
  if max_weight == 0 {
    return Err("所有权重都为0")
  }
  
  // 计算表对数
  let mut table_log = 0
  let mut temp = weight_sum
  while temp > 1 {
    temp = temp / 2
    table_log = table_log + 1
  }
  
  if table_log > 12 {  // HUF_TABLELOG_ABSOLUTEMAX
    return Err("表对数超过最大值")
  }
  
  let table_size = 1 << table_log
  let decode_table: Array[Int] = Array::make(table_size, 0)
  let symbols: Array[Byte] = Array::make(table_size, 0)
  let num_bits: Array[Byte] = Array::make(table_size, 0)
  
  // 构建解码表
  let mut position = 0
  
  for symbol = 0; symbol < weights.count; symbol = symbol + 1 {
    let weight = weights.weights[symbol]
    if weight > 0 {
      let num_entries = 1 << (table_log - weight)
      
      for i = 0; i < num_entries; i = i + 1 {
        if position < table_size {
          decode_table[position] = symbol
          symbols[position] = symbol.to_byte()
          num_bits[position] = weight.to_byte()
          position = position + 1
        }
      }
    }
  }
  
  let result = {
    table_log: table_log,
    max_symbol: weights.count - 1,
    decode_table: decode_table,
    symbols: symbols,
    num_bits: num_bits
  }
  
  Ok(result)
}

/// Huffman解码器状态
struct HuffmanDecoder {
  table: HuffmanTable        // 解码表
  mut bit_buffer: Int        // 位缓冲区
  mut bit_count: Int         // 缓冲区中的位数
  mut data_offset: Int       // 当前数据偏移量
}

/// 创建Huffman解码器
pub fn create_huffman_decoder(table: HuffmanTable) -> HuffmanDecoder {
  {
    table: table,
    bit_buffer: 0,
    bit_count: 0,
    data_offset: 0
  }
}

/// 从位流中读取指定数量的位
fn read_bits(decoder: HuffmanDecoder, data: Bytes, num_bits: Int) -> (HuffmanDecoder, Int) {
  let decoder = decoder
  
  // 确保缓冲区有足够的位
  while decoder.bit_count < num_bits && decoder.data_offset < data.length() {
    let byte_val = data[decoder.data_offset].to_int()
    decoder.bit_buffer = decoder.bit_buffer | (byte_val << decoder.bit_count)
    decoder.bit_count = decoder.bit_count + 8
    decoder.data_offset = decoder.data_offset + 1
  }
  
  if decoder.bit_count < num_bits {
    return (decoder, -1)  // 数据不足，返回错误标识
  }
  
  // 提取位
  let mask = (1 << num_bits) - 1
  let result = decoder.bit_buffer & mask
  decoder.bit_buffer = decoder.bit_buffer >> num_bits
  decoder.bit_count = decoder.bit_count - num_bits
  
  (decoder, result)
}

/// 解码单个Huffman符号
pub fn decode_huffman_symbol(decoder: HuffmanDecoder, data: Bytes) -> (HuffmanDecoder, Int) {
  if decoder.table.table_log == 0 {
    return (decoder, -1)  // 无效表
  }
  
  let decoder = decoder
  
  // 确保位缓冲区有足够的位
  while decoder.bit_count < decoder.table.table_log && decoder.data_offset < data.length() {
    let byte_val = data[decoder.data_offset].to_int()
    decoder.bit_buffer = decoder.bit_buffer | (byte_val << decoder.bit_count)
    decoder.bit_count = decoder.bit_count + 8
    decoder.data_offset = decoder.data_offset + 1
  }
  
  if decoder.bit_count < 1 {
    return (decoder, -1)  // 没有足够的位
  }
  
  // 查找符号 - 从最少位数开始尝试
  for bits = 1; bits <= decoder.table.table_log && bits <= decoder.bit_count; bits = bits + 1 {
    let mask = (1 << bits) - 1
    let code = decoder.bit_buffer & mask
    
    // 在解码表中查找对应的符号
    for i = 0; i < decoder.table.decode_table.length(); i = i + 1 {
      if decoder.table.num_bits[i].to_int() == bits {
        let expected_code = i >> (decoder.table.table_log - bits)
        if code == expected_code {
          let symbol = decoder.table.decode_table[i]
          // 消费使用的位
          decoder.bit_buffer = decoder.bit_buffer >> bits
          decoder.bit_count = decoder.bit_count - bits
          return (decoder, symbol)
        }
      }
    }
  }
  
  (decoder, -1)  // 未找到有效符号
}

/// 解码Huffman压缩的数据
pub fn decode_huffman_data(data: Bytes, offset: Int, compressed_size: Int, table: HuffmanTable, expected_output_size: Int) -> Result[Bytes, String] {
  if offset + compressed_size > data.length() {
    return Err("压缩数据超出范围")
  }
  
  if !validate_huffman_table(table) {
    return Err("无效的Huffman表")
  }
  
  let mut decoder = create_huffman_decoder(table)
  decoder.data_offset = offset
  
  let output: Array[Byte] = []
  let end_offset = offset + compressed_size
  
  // 解码直到达到预期输出大小或数据结束
  while output.length() < expected_output_size && decoder.data_offset < end_offset {
    let (new_decoder, symbol) = decode_huffman_symbol(decoder, data)
    decoder = new_decoder
    
    if symbol < 0 {
      if output.length() >= expected_output_size {
        break  // 正常结束
      } else {
        return Err("Huffman解码失败：无法读取更多符号")
      }
    }
    
    if symbol <= 255 {
      output.push(symbol.to_byte())
    } else {
      return Err("无效的Huffman符号：" + symbol.to_string())
    }
  }
  
  if output.length() != expected_output_size {
    return Err("输出大小不匹配：期望 " + expected_output_size.to_string() + "，实际 " + output.length().to_string())
  }
  
  Ok(Bytes::from_array(output))
}

/// 验证Huffman表的有效性
pub fn validate_huffman_table(table: HuffmanTable) -> Bool {
  if table.table_log == 0 || table.table_log > 12 {
    return false
  }
  
  if table.max_symbol < 0 || table.max_symbol > 255 {
    return false
  }
  
  let expected_size = 1 << table.table_log
  if table.decode_table.length() != expected_size {
    return false
  }
  
  // 检查所有符号是否在有效范围内
  for i = 0; i < table.decode_table.length(); i = i + 1 {
    let symbol = table.decode_table[i]
    if symbol < 0 || symbol > table.max_symbol {
      return false
    }
  }
  
  true
}

/// 打印Huffman表信息（用于调试）
pub fn print_huffman_table_info(table: HuffmanTable) -> String {
  "Huffman表: table_log=" + table.table_log.to_string() + 
  ", max_symbol=" + table.max_symbol.to_string() + 
  ", table_size=" + table.decode_table.length().to_string()
}
