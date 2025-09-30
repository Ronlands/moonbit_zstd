/// FSE (Finite State Entropy) 解码器模块
/// 基于zstd官方库实现的有限状态熵解码算法

/// FSE解码表项
struct FSETableEntry {
  symbol: Byte              // 符号
  num_bits: Byte            // 需要读取的位数
  new_state: Int            // 新状态
}

/// FSE解码表
pub struct FSETable {
  table_log: Int            // 表的对数大小
  table: Array[FSETableEntry]  // 解码表
}

/// FSE解码器状态
pub struct FSEDecoder {
  table: FSETable           // 解码表
  mut state: Int            // 当前状态
  mut bit_buffer: Int       // 位缓冲区
  mut bit_count: Int        // 缓冲区中的位数
  mut data_offset: Int      // 当前数据偏移量
}

/// 创建空的FSE表
pub fn create_fse_table() -> FSETable {
  {
    table_log: 0,
    table: Array::new()
  }
}

/// 解析FSE表头
/// 参考官方库的FSE_readNCount实现
pub fn parse_fse_header(data: Bytes, offset: Int) -> Result[(Array[Int], Int, Int), String] {
  if offset >= data.length() {
    return Err("数据不足以读取FSE表头")
  }
  
  let mut current_offset = offset
  let mut bit_stream = 0
  let mut bit_count = 0
  let symbol_probabilities: Array[Int] = Array::make(256, 0)
  let mut max_symbol = 0
  
  // 读取表对数
  if current_offset >= data.length() {
    return Err("无法读取表对数")
  }
  
  let first_byte = data[current_offset].to_int()
  current_offset = current_offset + 1
  
  let table_log = (first_byte & 0xF) + 5  // 表对数范围通常是5-12
  if table_log > 12 {
    return Err("表对数超出范围")
  }
  
  // 初始化位流
  bit_stream = first_byte >> 4
  bit_count = 4
  
  // 读取更多字节到位流
  let bytes_to_read = (data.length() - current_offset).min(3)
  for i = 0; i < bytes_to_read; i = i + 1 {
    bit_stream = bit_stream | (data[current_offset + i].to_int() << bit_count)
    bit_count = bit_count + 8
  }
  current_offset = current_offset + bytes_to_read
  
  // 解析符号概率
  let mut symbol = 0
  let mut remaining = 1 << table_log
  
  while symbol < 256 && remaining > 1 {
    // 读取概率值
    let (new_bit_stream, new_bit_count, new_offset, prob) = read_fse_probability(
      data, bit_stream, bit_count, current_offset, remaining
    )
    
    bit_stream = new_bit_stream
    bit_count = new_bit_count
    current_offset = new_offset
    
    if prob < 0 {
      break
    }
    
    symbol_probabilities[symbol] = prob
    remaining = remaining - prob
    max_symbol = symbol
    symbol = symbol + 1
    
    // 如果概率为0，跳过连续的0
    if prob == 0 {
      let (skip_bit_stream, skip_bit_count, skip_offset, skip_count) = read_fse_skip_count(
        data, bit_stream, bit_count, current_offset
      )
      bit_stream = skip_bit_stream
      bit_count = skip_bit_count
      current_offset = skip_offset
      symbol = symbol + skip_count
    }
  }
  
  // 将剩余概率分配给最后一个符号
  if remaining > 0 && max_symbol < 255 {
    symbol_probabilities[max_symbol] = symbol_probabilities[max_symbol] + remaining
  }
  
  let bytes_consumed = current_offset - offset
  Ok((symbol_probabilities, table_log, bytes_consumed))
}

/// 读取FSE概率值
fn read_fse_probability(data: Bytes, bit_stream: Int, bit_count: Int, offset: Int, remaining: Int) -> (Int, Int, Int, Int) {
  let mut bit_stream = bit_stream
  let mut bit_count = bit_count
  let mut offset = offset
  
  // 确保有足够的位
  while bit_count < 16 && offset < data.length() {
    bit_stream = bit_stream | (data[offset].to_int() << bit_count)
    bit_count = bit_count + 8
    offset = offset + 1
  }
  
  if bit_count < 2 {
    return (bit_stream, bit_count, offset, -1)
  }
  
  // 读取概率值（简化版本）
  let small_prob = bit_stream & 0x3
  bit_stream = bit_stream >> 2
  bit_count = bit_count - 2
  
  let prob = if small_prob < 3 {
    small_prob
  } else {
    // 读取更长的概率值
    if bit_count < 8 {
      return (bit_stream, bit_count, offset, -1)
    }
    let extended = bit_stream & 0xFF
    bit_stream = bit_stream >> 8
    bit_count = bit_count - 8
    extended.min(remaining)
  }
  
  (bit_stream, bit_count, offset, prob)
}

/// 读取跳过计数
fn read_fse_skip_count(data: Bytes, bit_stream: Int, bit_count: Int, offset: Int) -> (Int, Int, Int, Int) {
  let mut bit_stream = bit_stream
  let mut bit_count = bit_count
  let mut offset = offset
  
  // 确保有足够的位
  while bit_count < 8 && offset < data.length() {
    bit_stream = bit_stream | (data[offset].to_int() << bit_count)
    bit_count = bit_count + 8
    offset = offset + 1
  }
  
  if bit_count < 2 {
    return (bit_stream, bit_count, offset, 1)
  }
  
  let skip_bits = bit_stream & 0x3
  bit_stream = bit_stream >> 2
  bit_count = bit_count - 2
  
  let skip_count = if skip_bits < 3 {
    skip_bits + 1
  } else {
    // 读取更长的跳过计数
    if bit_count < 8 {
      return (bit_stream, bit_count, offset, 1)
    }
    let extended = bit_stream & 0xFF
    bit_stream = bit_stream >> 8
    bit_count = bit_count - 8
    extended + 4
  }
  
  (bit_stream, bit_count, offset, skip_count)
}

/// 从概率数组构建FSE解码表
/// 参考官方库的FSE_buildDTable实现
pub fn build_fse_table(probabilities: Array[Int], table_log: Int) -> Result[FSETable, String] {
  if table_log > 12 || table_log < 1 {
    return Err("表对数超出范围")
  }
  
  let table_size = 1 << table_log
  let table: Array[FSETableEntry] = Array::make(table_size, {
    symbol: 0,
    num_bits: 0,
    new_state: 0
  })
  
  // 第一步：计算每个符号的起始位置
  let cumulative: Array[Int] = Array::make(256, 0)
  let mut position = 0
  
  for symbol = 0; symbol < probabilities.length(); symbol = symbol + 1 {
    let prob = probabilities[symbol]
    if prob > 0 {
      cumulative[symbol] = position
      position = position + prob
    }
  }
  
  // 第二步：为每个符号构建表项
  for symbol = 0; symbol < probabilities.length(); symbol = symbol + 1 {
    let prob = probabilities[symbol]
    if prob > 0 {
      let start_pos = cumulative[symbol]
      
      // 计算该符号需要的位数（log2(prob)）
      let mut bits_needed = 0
      let mut temp_prob = prob
      while temp_prob > 1 {
        temp_prob = temp_prob >> 1
        bits_needed = bits_needed + 1
      }
      
      // 计算基础状态
      let base_state = start_pos
      
      // 为该符号的所有状态填充表项
      for state_offset = 0; state_offset < prob; state_offset = state_offset + 1 {
        let current_state = start_pos + state_offset
        if current_state < table_size {
          // 计算新状态：基础状态加上当前偏移的一半（用于下次解码）
          let new_state_base = base_state + (state_offset >> bits_needed)
          
          table[current_state] = {
            symbol: symbol.to_byte(),
            num_bits: bits_needed.to_byte(),
            new_state: new_state_base
          }
        }
      }
    }
  }
  
  Ok({
    table_log: table_log,
    table: table
  })
}

/// 创建FSE解码器
pub fn create_fse_decoder(table: FSETable, initial_state: Int) -> FSEDecoder {
  {
    table: table,
    state: initial_state,
    bit_buffer: 0,
    bit_count: 0,
    data_offset: 0
  }
}

/// 从位流中读取指定数量的位
fn read_bits_fse(decoder: FSEDecoder, data: Bytes, num_bits: Int) -> (FSEDecoder, Int) {
  let decoder = decoder
  
  // 确保缓冲区有足够的位
  while decoder.bit_count < num_bits && decoder.data_offset < data.length() {
    let byte_val = data[decoder.data_offset].to_int()
    decoder.bit_buffer = decoder.bit_buffer | (byte_val << decoder.bit_count)
    decoder.bit_count = decoder.bit_count + 8
    decoder.data_offset = decoder.data_offset + 1
  }
  
  if decoder.bit_count < num_bits {
    return (decoder, 0)  // 数据不足
  }
  
  // 提取位
  let mask = (1 << num_bits) - 1
  let result = decoder.bit_buffer & mask
  decoder.bit_buffer = decoder.bit_buffer >> num_bits
  decoder.bit_count = decoder.bit_count - num_bits
  
  (decoder, result)
}

/// 解码单个FSE符号
pub fn decode_fse_symbol(decoder: FSEDecoder, data: Bytes) -> (FSEDecoder, Int) {
  if decoder.state >= decoder.table.table.length() {
    return (decoder, -1)  // 无效状态
  }
  
  let entry = decoder.table.table[decoder.state]
  let symbol = entry.symbol.to_int()
  let num_bits = entry.num_bits.to_int()
  
  // 读取需要的位数
  let (new_decoder, bits) = read_bits_fse(decoder, data, num_bits)
  
  if num_bits > 0 && bits < 0 {
    return (new_decoder, -1)  // 读取失败
  }
  
  // 更新状态：新状态 = 基础状态 + 读取的位作为偏移
  let final_decoder = new_decoder
  let table_mask = (1 << decoder.table.table_log) - 1
  final_decoder.state = (entry.new_state + bits) & table_mask
  
  (final_decoder, symbol)
}

/// 解码FSE压缩的数据序列
pub fn decode_fse_sequence(data: Bytes, offset: Int, size: Int, table: FSETable) -> Result[Array[Int], String] {
  if offset + size > data.length() {
    return Err("数据超出范围")
  }
  
  let mut decoder = create_fse_decoder(table, 0)
  decoder.data_offset = offset
  
  let output: Array[Int] = []
  let end_offset = offset + size
  
  // 初始化状态（从数据流末尾读取）
  if size >= 2 {
    let state_bytes = data[end_offset - 2].to_int() | (data[end_offset - 1].to_int() << 8)
    decoder.state = state_bytes & ((1 << table.table_log) - 1)
    decoder.data_offset = end_offset - 2
  }
  
  // 从后向前解码
  while decoder.data_offset > offset {
    let (new_decoder, symbol) = decode_fse_symbol(decoder, data)
    decoder = new_decoder
    
    if symbol < 0 {
      break
    }
    
    output.push(symbol)
  }
  
  // 反转输出（因为是从后向前解码的）
  let reversed: Array[Int] = []
  for i = output.length() - 1; i >= 0; i = i - 1 {
    reversed.push(output[i])
  }
  
  Ok(reversed)
}

/// 验证FSE表的有效性
pub fn validate_fse_table(table: FSETable) -> Bool {
  if table.table_log == 0 || table.table_log > 12 {
    return false
  }
  
  let expected_size = 1 << table.table_log
  if table.table.length() != expected_size {
    return false
  }
  
  // 检查所有表项的有效性
  for i = 0; i < table.table.length(); i = i + 1 {
    let entry = table.table[i]
    if entry.num_bits.to_int() > table.table_log {
      return false
    }
    if entry.new_state >= table.table.length() {
      return false
    }
  }
  
  true
}

/// 创建预定义的FSE表（用于字面量长度等）
/// 基于 ZSTD 规范的预定义分布
pub fn create_predefined_fse_table(table_type: String) -> Result[FSETable, String] {
  match table_type {
    "literal_lengths" => {
      // ZSTD 预定义的字面量长度分布 (table_log = 6, 64个条目)
      let probabilities: Array[Int] = Array::make(36, 0)
      // 基于 ZSTD 规范的预定义分布
      probabilities[0] = 4   // LL_Code 0
      probabilities[1] = 3   // LL_Code 1
      probabilities[2] = 2   // LL_Code 2
      probabilities[3] = 2   // LL_Code 3
      probabilities[4] = 2   // LL_Code 4
      probabilities[5] = 2   // LL_Code 5
      probabilities[6] = 2   // LL_Code 6
      probabilities[7] = 2   // LL_Code 7
      probabilities[8] = 2   // LL_Code 8
      probabilities[9] = 2   // LL_Code 9
      probabilities[10] = 2  // LL_Code 10
      probabilities[11] = 1  // LL_Code 11
      probabilities[12] = 1  // LL_Code 12
      probabilities[13] = 1  // LL_Code 13
      probabilities[14] = 1  // LL_Code 14
      probabilities[15] = 1  // LL_Code 15
      probabilities[16] = 1  // LL_Code 16
      probabilities[17] = 1  // LL_Code 17
      probabilities[18] = 1  // LL_Code 18
      probabilities[19] = 1  // LL_Code 19
      probabilities[20] = 1  // LL_Code 20
      probabilities[21] = 1  // LL_Code 21
      probabilities[22] = 1  // LL_Code 22
      probabilities[23] = 1  // LL_Code 23
      probabilities[24] = 1  // LL_Code 24
      probabilities[25] = 1  // LL_Code 25
      probabilities[26] = 1  // LL_Code 26
      probabilities[27] = 1  // LL_Code 27
      probabilities[28] = 1  // LL_Code 28
      probabilities[29] = 1  // LL_Code 29
      probabilities[30] = 1  // LL_Code 30
      probabilities[31] = 1  // LL_Code 31
      probabilities[32] = 1  // LL_Code 32
      probabilities[33] = 1  // LL_Code 33
      probabilities[34] = 1  // LL_Code 34
      probabilities[35] = 1  // LL_Code 35
      
      build_fse_table(probabilities, 6)
    }
    "offsets" => {
      // ZSTD 预定义的偏移量分布 (table_log = 5, 32个条目)
      let probabilities: Array[Int] = Array::make(29, 0)
      probabilities[0] = 1   // OF_Code 0
      probabilities[1] = 1   // OF_Code 1
      probabilities[2] = 1   // OF_Code 2
      probabilities[3] = 1   // OF_Code 3
      probabilities[4] = 1   // OF_Code 4
      probabilities[5] = 1   // OF_Code 5
      probabilities[6] = 1   // OF_Code 6
      probabilities[7] = 1   // OF_Code 7
      probabilities[8] = 1   // OF_Code 8
      probabilities[9] = 1   // OF_Code 9
      probabilities[10] = 1  // OF_Code 10
      probabilities[11] = 1  // OF_Code 11
      probabilities[12] = 1  // OF_Code 12
      probabilities[13] = 1  // OF_Code 13
      probabilities[14] = 1  // OF_Code 14
      probabilities[15] = 1  // OF_Code 15
      probabilities[16] = 1  // OF_Code 16
      probabilities[17] = 1  // OF_Code 17
      probabilities[18] = 1  // OF_Code 18
      probabilities[19] = 1  // OF_Code 19
      probabilities[20] = 1  // OF_Code 20
      probabilities[21] = 1  // OF_Code 21
      probabilities[22] = 1  // OF_Code 22
      probabilities[23] = 1  // OF_Code 23
      probabilities[24] = 1  // OF_Code 24
      probabilities[25] = 1  // OF_Code 25
      probabilities[26] = 1  // OF_Code 26
      probabilities[27] = 1  // OF_Code 27
      probabilities[28] = 1  // OF_Code 28
      
      build_fse_table(probabilities, 5)
    }
    "match_lengths" => {
      // ZSTD 预定义的匹配长度分布 (table_log = 6, 64个条目)
      let probabilities: Array[Int] = Array::make(53, 0)
      probabilities[0] = 1   // ML_Code 0
      probabilities[1] = 4   // ML_Code 1
      probabilities[2] = 3   // ML_Code 2
      probabilities[3] = 2   // ML_Code 3
      probabilities[4] = 2   // ML_Code 4
      probabilities[5] = 2   // ML_Code 5
      probabilities[6] = 2   // ML_Code 6
      probabilities[7] = 2   // ML_Code 7
      probabilities[8] = 2   // ML_Code 8
      probabilities[9] = 1   // ML_Code 9
      probabilities[10] = 1  // ML_Code 10
      probabilities[11] = 1  // ML_Code 11
      probabilities[12] = 1  // ML_Code 12
      probabilities[13] = 1  // ML_Code 13
      probabilities[14] = 1  // ML_Code 14
      probabilities[15] = 1  // ML_Code 15
      probabilities[16] = 1  // ML_Code 16
      probabilities[17] = 1  // ML_Code 17
      probabilities[18] = 1  // ML_Code 18
      probabilities[19] = 1  // ML_Code 19
      probabilities[20] = 1  // ML_Code 20
      probabilities[21] = 1  // ML_Code 21
      probabilities[22] = 1  // ML_Code 22
      probabilities[23] = 1  // ML_Code 23
      probabilities[24] = 1  // ML_Code 24
      probabilities[25] = 1  // ML_Code 25
      probabilities[26] = 1  // ML_Code 26
      probabilities[27] = 1  // ML_Code 27
      probabilities[28] = 1  // ML_Code 28
      probabilities[29] = 1  // ML_Code 29
      probabilities[30] = 1  // ML_Code 30
      probabilities[31] = 1  // ML_Code 31
      probabilities[32] = 1  // ML_Code 32
      probabilities[33] = 1  // ML_Code 33
      probabilities[34] = 1  // ML_Code 34
      probabilities[35] = 1  // ML_Code 35
      probabilities[36] = 1  // ML_Code 36
      probabilities[37] = 1  // ML_Code 37
      probabilities[38] = 1  // ML_Code 38
      probabilities[39] = 1  // ML_Code 39
      probabilities[40] = 1  // ML_Code 40
      probabilities[41] = 1  // ML_Code 41
      probabilities[42] = 1  // ML_Code 42
      probabilities[43] = 1  // ML_Code 43
      probabilities[44] = 1  // ML_Code 44
      probabilities[45] = 1  // ML_Code 45
      probabilities[46] = 1  // ML_Code 46
      probabilities[47] = 1  // ML_Code 47
      probabilities[48] = 1  // ML_Code 48
      probabilities[49] = 1  // ML_Code 49
      probabilities[50] = 1  // ML_Code 50
      probabilities[51] = 1  // ML_Code 51
      probabilities[52] = 1  // ML_Code 52
      
      build_fse_table(probabilities, 6)
    }
    _ => Err("未知的FSE表类型: " + table_type)
  }
}

/// 打印FSE表信息（用于调试）
pub fn print_fse_table_info(table: FSETable) -> String {
  "FSE表: table_log=" + table.table_log.to_string() + 
  ", table_size=" + table.table.length().to_string()
}
