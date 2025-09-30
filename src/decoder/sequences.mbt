/// ZSTD序列解码器模块 - 简化版本
/// 处理压缩序列的解析和执行

/// 序列信息
pub struct Sequence {
  literal_length: Int       // 字面量长度
  match_length: Int         // 匹配长度  
  offset: Int               // 偏移量
}

/// 序列头信息
pub struct SequenceHeader {
  num_sequences: Int        // 序列数量
  ll_mode: Int             // 字面量长度模式
  of_mode: Int             // 偏移量模式
  ml_mode: Int             // 匹配长度模式
  header_size: Int         // 头部大小
}

/// 解析序列头 - 简化版本
pub fn parse_sequence_header(data: Bytes, offset: Int) -> Result[(SequenceHeader, Int), String] {
  if offset >= data.length() {
    return Err("数据不足以读取序列头")
  }
  
  let mut current_offset = offset
  
  // 读取序列数量
  let first_byte = data[current_offset].to_int()
  current_offset = current_offset + 1
  
  let num_sequences = if first_byte == 0 {
    0
  } else if first_byte < 127 {
    first_byte
  } else if first_byte == 255 {
    if current_offset + 1 >= data.length() {
      return Err("数据不足以读取扩展序列数量")
    }
    let low = data[current_offset].to_int()
    let high = data[current_offset + 1].to_int()
    current_offset = current_offset + 2
    low + (high << 8) + 0x7F00
  } else {
    if current_offset >= data.length() {
      return Err("数据不足以读取扩展序列数量")
    }
    let second_byte = data[current_offset].to_int()
    current_offset = current_offset + 1
    ((first_byte - 128) << 8) + second_byte
  }
  
  if num_sequences == 0 {
    let header = SequenceHeader::{
      num_sequences: 0,
      ll_mode: 0,
      of_mode: 0,
      ml_mode: 0,
      header_size: current_offset - offset
    }
    return Ok((header, current_offset - offset))
  }
  
  // 读取模式字节
  if current_offset >= data.length() {
    return Err("数据不足以读取模式字节")
  }
  
  let mode_byte = data[current_offset].to_int()
  current_offset = current_offset + 1
  
  let ll_mode = (mode_byte >> 6) & 3
  let of_mode = (mode_byte >> 4) & 3
  let ml_mode = (mode_byte >> 2) & 3
  
  let header = SequenceHeader::{
    num_sequences: num_sequences,
    ll_mode: ll_mode,
    of_mode: of_mode,
    ml_mode: ml_mode,
    header_size: current_offset - offset
  }
  
  Ok((header, current_offset - offset))
}

/// 简化的序列解码 - 不使用FSE
pub fn decode_sequences_simple(_data: Bytes, _offset: Int, header: SequenceHeader) -> Result[Array[Sequence], String] {
  let mut sequences: Array[Sequence] = []
  
  if header.num_sequences == 0 {
    return Ok(sequences)
  }
  
  // 创建简单的测试序列
  for i = 0; i < header.num_sequences; i = i + 1 {
    let sequence = Sequence::{
      literal_length: 4,
      match_length: 4, 
      offset: 1
    }
    sequences = sequences + [sequence]
  }
  
  Ok(sequences)
}

/// 执行序列数组，重建输出数据
/// 使用窗口缓冲区支持历史数据引用
pub fn execute_sequences_with_window(literals: Bytes, sequences: Array[Sequence], window: WindowBuffer) -> Result[Bytes, String] {
  let output: Array[Byte] = []
  let mut literal_pos = 0
  
  for i = 0; i < sequences.length(); i = i + 1 {
    let seq = sequences[i]
    
    // 1. 复制字面量到输出
    for j = 0; j < seq.literal_length; j = j + 1 {
      if literal_pos < literals.length() {
        output.push(literals[literal_pos])
        literal_pos = literal_pos + 1
      }
    }
    
    // 将字面量写入窗口缓冲区
    if seq.literal_length > 0 {
      let literal_chunk: Array[Byte] = []
      let chunk_start = literal_pos - seq.literal_length
      for k = 0; k < seq.literal_length; k = k + 1 {
        if chunk_start + k >= 0 && chunk_start + k < literals.length() {
          literal_chunk.push(literals[chunk_start + k])
        }
      }
      write_to_window(window, Bytes::from_array(literal_chunk))
    }
    
    // 2. 处理匹配序列
    if seq.offset > 0 && seq.match_length > 0 {
      // 从窗口缓冲区复制匹配数据
      let match_result = copy_match(window, seq.offset, seq.match_length)
      match match_result {
        Ok(match_data) => {
          // 将匹配数据添加到输出
          for m = 0; m < match_data.length(); m = m + 1 {
            output.push(match_data[m])
          }
        }
        Err(e) => return Err("匹配复制失败: " + e)
      }
    }
  }
  
  // 3. 复制剩余的字面量
  while literal_pos < literals.length() {
    output.push(literals[literal_pos])
    literal_pos = literal_pos + 1
  }
  
  // 将剩余字面量写入窗口缓冲区
  if literal_pos < literals.length() {
    let remaining_literals: Array[Byte] = []
    for r = literal_pos; r < literals.length(); r = r + 1 {
      remaining_literals.push(literals[r])
    }
    write_to_window(window, Bytes::from_array(remaining_literals))
  }
  
  Ok(Bytes::from_array(output))
}

/// 执行序列 - 简化版本（兼容性保留）
pub fn execute_sequences(literals: Bytes, sequences: Array[Sequence]) -> Result[Bytes, String] {
  let mut output: Array[Byte] = []
  
  // 先添加所有字面量
  for i = 0; i < literals.length(); i = i + 1 {
    output = output + [literals[i]]
  }
  
  // 简化的序列执行
  for i = 0; i < sequences.length(); i = i + 1 {
    let seq = sequences[i]
    
    // 简单的重复逻辑
    if seq.offset > 0 && seq.offset <= output.length() {
      let start_pos = output.length() - seq.offset
      for j = 0; j < seq.match_length; j = j + 1 {
        let byte_to_copy = output[start_pos + (j % seq.offset)]
        output = output + [byte_to_copy]
      }
    }
  }
  
  Ok(Bytes::from_array(output))
}

/// 解码字面量长度
fn decode_literal_length(code: Int) -> Int {
  if code < 16 {
    code
  } else {
    let extra_bits = (code - 16) / 4
    let base = 16 + ((code - 16) % 4) * (1 << extra_bits)
    base
  }
}

/// 解码匹配长度  
fn decode_match_length(code: Int) -> Int {
  let base_length = 3
  if code < 16 {
    base_length + code
  } else {
    let extra_bits = (code - 16) / 4
    let base = base_length + 16 + ((code - 16) % 4) * (1 << extra_bits)
    base
  }
}

/// 解码偏移量
fn decode_offset(code: Int, repeat_offsets: Array[Int]) -> Int {
  if code == 0 {
    repeat_offsets[0]
  } else if code == 1 {
    repeat_offsets[1] 
  } else if code == 2 {
    repeat_offsets[2]
  } else {
    1 << (code - 3)
  }
}

/// 验证序列的有效性
pub fn validate_sequence(seq: Sequence) -> Bool {
  seq.literal_length >= 0 && 
  seq.match_length >= 3 && 
  seq.offset > 0
}

/// 验证序列数组
pub fn validate_sequences(sequences: Array[Sequence]) -> Bool {
  for i = 0; i < sequences.length(); i = i + 1 {
    if !validate_sequence(sequences[i]) {
      return false
    }
  }
  true
}

/// 估算输出大小
pub fn estimate_output_size(literals_size: Int, sequences: Array[Sequence]) -> Int {
  let mut total_size = literals_size
  
  for i = 0; i < sequences.length(); i = i + 1 {
    let seq = sequences[i]
    total_size = total_size + seq.literal_length + seq.match_length
  }
  
  total_size
}