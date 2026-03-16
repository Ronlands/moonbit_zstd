/// ZSTD decompressor

/// Decompressor structure
pub struct Decompressor {
  window_size : Int
  context : @zstd_core.DecompressionContext
  dictionary : Bytes  // Preloaded dictionary content
}

/// Create new decompressor
pub fn new_decompressor() -> @zstd_core.DecompressionContext {
  @zstd_core.make_decompression_context()
}

/// Create decompressor with specific window size
pub fn create_decompressor(window_size : Int) -> Decompressor {
  let context = @zstd_core.make_decompression_context()
  Decompressor::{ 
    window_size: window_size, 
    context: context,
    dictionary: Bytes::new(0)
  }
}

/// Create decompressor with dictionary
pub fn create_decompressor_with_dict(window_size : Int, dictionary: Bytes) -> Decompressor {
  let context = @zstd_core.make_decompression_context()
  Decompressor::{ 
    window_size: window_size, 
    context: context,
    dictionary: dictionary
  }
}

/// Decompress ZSTD data - Real implementation
/// Supports concatenated frames per RFC 8878.
pub fn decompress(data : Bytes) -> @zstd_core.ZSTDResult[Bytes] {
  if data.length() < 4 {
    return Err(@zstd_core.parse_error("Data too short: need at least 4 bytes, got " + data.length().to_string()))
  }

  let all_output: Array[Byte] = []
  let mut pos = 0

  while pos < data.length() {
    // Check for ZSTD magic at current position
    if pos + 4 > data.length() { break }
    let magic = (data[pos + 3].to_int() << 24) | (data[pos + 2].to_int() << 16) |
                (data[pos + 1].to_int() << 8) | data[pos].to_int()
    if magic != @zstd_core.ZSTD_MAGIC_NUMBER_INT { break }

    // Slice the remaining data from pos
    let remaining: Array[Byte] = []
    for i = pos; i < data.length(); i = i + 1 {
      remaining.push(data[i])
    }
    let frame_data = Bytes::from_array(remaining)

    // Validate frame structure
    let analysis = analyze_file(frame_data)
    if !analysis.is_valid {
      return Err(@zstd_core.message_error(analysis.error_message))
    }

    // Decompress this frame
    let result = decompress_zstd_data(frame_data)
    match result {
      Ok(decompressed) => {
        for i = 0; i < decompressed.length(); i = i + 1 {
          all_output.push(decompressed[i])
        }
        // Advance past this frame
        let frame_size = calculate_frame_size(frame_data)
        if frame_size <= 0 { break }
        pos = pos + frame_size
      }
      Err(e) => return Err(@zstd_core.message_error(e))
    }
  }

  Ok(Bytes::from_array(all_output))
}

/// Decompress with global output size limit (prevents decompression bomb bypass)
pub fn decompress_with_limit(data: Bytes, max_output: Int) -> @zstd_core.ZSTDResult[Bytes] {
  if data.length() < 4 {
    return Err(@zstd_core.parse_error("Data too short"))
  }

  let all_output: Array[Byte] = []
  let mut pos = 0

  while pos < data.length() {
    if pos + 4 > data.length() { break }
    let magic = (data[pos + 3].to_int() << 24) | (data[pos + 2].to_int() << 16) |
                (data[pos + 1].to_int() << 8) | data[pos].to_int()
    if magic != @zstd_core.ZSTD_MAGIC_NUMBER_INT { break }

    let remaining: Array[Byte] = []
    for i = pos; i < data.length(); i = i + 1 {
      remaining.push(data[i])
    }
    let frame_data = Bytes::from_array(remaining)

    let analysis = analyze_file(frame_data)
    if !analysis.is_valid {
      return Err(@zstd_core.message_error(analysis.error_message))
    }

    let result = decompress_zstd_data(frame_data)
    match result {
      Ok(decompressed) => {
        if all_output.length() + decompressed.length() > max_output {
          return Err(@zstd_core.message_error("Cumulative output exceeds limit"))
        }
        for i = 0; i < decompressed.length(); i = i + 1 {
          all_output.push(decompressed[i])
        }
        let frame_size = calculate_frame_size(frame_data)
        if frame_size <= 0 { break }
        pos = pos + frame_size
      }
      Err(e) => return Err(@zstd_core.message_error(e))
    }
  }

  Ok(Bytes::from_array(all_output))
}

/// Calculate the total byte size of one ZSTD frame (header + all blocks + optional checksum).
fn calculate_frame_size(data: Bytes) -> Int {
  let mut offset = 4 // skip magic

  // Parse FHD
  if offset >= data.length() { return -1 }
  let fhd = data[offset].to_int()
  let single_segment = (fhd & 0x20) != 0
  let checksum_flag = (fhd & 0x04) != 0
  let dict_id_flag = fhd & 0x03
  let fcs_flag = (fhd >> 6) & 0x03
  offset = offset + 1

  // Window_Descriptor
  if !single_segment { offset = offset + 1 }

  // Dictionary_ID
  if dict_id_flag == 1 { offset = offset + 1 }
  else if dict_id_flag == 2 { offset = offset + 2 }
  else if dict_id_flag == 3 { offset = offset + 4 }

  // Frame_Content_Size
  if single_segment && fcs_flag == 0 { offset = offset + 1 }
  else if fcs_flag == 1 { offset = offset + 2 }
  else if fcs_flag == 2 { offset = offset + 4 }
  else if fcs_flag == 3 { offset = offset + 8 }

  // Walk blocks
  while offset + 3 <= data.length() {
    let bh = data[offset].to_int() | (data[offset + 1].to_int() << 8) | (data[offset + 2].to_int() << 16)
    let is_last = (bh & 1) != 0
    let block_type = (bh >> 1) & 3
    let block_size = (bh >> 3) & 0x1FFFFF
    let compressed_size = if block_type == 1 { 1 } else { block_size }
    offset = offset + 3 + compressed_size
    if is_last { break }
  }

  // Optional content checksum (4 bytes)
  if checksum_flag { offset = offset + 4 }

  offset
}

/// 真正的 ZSTD 解压缩实现（无字典）
pub fn decompress_zstd_data(data: Bytes) -> Result[Bytes, String] {
  decompress_zstd_data_with_dict(data, Bytes::new(0))
}

/// 真正的 ZSTD 解压缩实现（带字典）
pub fn decompress_zstd_data_with_dict(data: Bytes, dictionary: Bytes) -> Result[Bytes, String] {
  let mut current_offset = 4  // 跳过魔数
  
  // 解析帧头
  let frame_result = parse_frame_header_for_decompressor(data, current_offset)
  match frame_result {
    Ok((_frame_header, header_size)) => {
      current_offset = current_offset + header_size
      
      // 解压缩块
      // 如果有字典，将其作为初始窗口内容
      let mut output_data = if dictionary.length() > 0 {
        dictionary
      } else {
        Bytes::new(0)
      }
      let dict_size = dictionary.length()
      
      while current_offset + 3 <= data.length() {
        // 解析块头
        let block_header = data[current_offset].to_int() |
                          (data[current_offset + 1].to_int() << 8) |
                          (data[current_offset + 2].to_int() << 16)
        
        let is_last_block = (block_header & 1) != 0
        let block_type = (block_header >> 1) & 3
        let block_size = (block_header >> 3) & 0x1FFFFF
        
        current_offset = current_offset + 3
        
        // 计算实际压缩数据大小
        // 对于RLE块，block_size是解压后的大小，但压缩数据只有1字节
        // 对于Raw和Compressed块，block_size就是压缩数据大小
        let compressed_size = if block_type == 1 { 1 } else { block_size }
        
        // 检查块大小（使用压缩数据大小）
        if current_offset + compressed_size > data.length() {
          return Err("Block data exceeds file boundary")
        }
        
        // 解压缩块（传递block_size作为解压后的大小和当前窗口用于序列执行）
        let block_result = decompress_single_block_with_window(
          data, current_offset, block_size, block_type, output_data
        )
        match block_result {
          Ok(block_data) => {
            // 如果有字典，第一次追加时只保留新数据
            if dict_size > 0 && output_data.length() == dict_size {
              output_data = dictionary + block_data
            } else {
              output_data = output_data + block_data
            }
            // 更新偏移量使用压缩数据大小
            current_offset = current_offset + compressed_size
          }
          Err(error_msg) => {
            return Err(error_msg)
          }
        }
        
        if is_last_block {
          break
        }
      }
      
      // 如果使用了字典，移除字典部分只返回实际解压的数据
      if dict_size > 0 {
        let actual_data: Array[Byte] = []
        for i = dict_size; i < output_data.length(); i = i + 1 {
          actual_data.push(output_data[i])
        }
        Ok(Bytes::from_array(actual_data))
      } else {
        Ok(output_data)
      }
    }
    Err(error_msg) => Err(error_msg)
  }
}

/// 解析帧头用于解压缩
fn parse_frame_header_for_decompressor(data: Bytes, offset: Int) -> Result[(@zstd_core.FrameHeader, Int), String] {
  if offset + 1 > data.length() {
    return Err("Incomplete frame header")
  }
  
  // 读取Frame_Header_Descriptor (1字节)
  let descriptor = data[offset].to_int()
  
  // 解析Frame_Header_Descriptor各个字段
  let frame_content_size_flag = (descriptor >> 6) & 3  // Bits 7-6
  let single_segment = ((descriptor >> 5) & 1) != 0    // Bit 5
  let reserved_bit = (descriptor >> 3) & 1              // Bit 3
  let content_checksum = ((descriptor >> 2) & 1) != 0  // Bit 2
  let dict_id_flag = descriptor & 3                     // Bits 1-0
  
  // RFC 8878: reserved bit must be zero
  if reserved_bit != 0 {
    return Err("Unsupported frame parameter: reserved bit is set")
  }
  
  let mut current_offset = offset + 1
  let mut window_size = 0
  
  // 如果single_segment=0，读取Window_Descriptor
  if !single_segment {
    if current_offset >= data.length() {
      return Err("Window_Descriptor字段缺失")
    }
    let window_descriptor = data[current_offset].to_int()
    current_offset = current_offset + 1
    
    // 解码Window_Descriptor为实际窗口大小
    let exponent = window_descriptor >> 3
    let mantissa = window_descriptor & 7
    let window_log = exponent + 10
    let window_base = 1 << window_log
    let window_add = (window_base / 8) * mantissa
    window_size = window_base + window_add
  }
  
  // 读取Dictionary_ID (如果存在)
  if dict_id_flag == 1 {
    current_offset = current_offset + 1
  } else if dict_id_flag == 2 {
    current_offset = current_offset + 2
  } else if dict_id_flag == 3 {
    current_offset = current_offset + 4
  }
  
  // 读取Frame_Content_Size
  let mut frame_content_size = 0
  if frame_content_size_flag == 0 && single_segment {
    // Single_Segment=1 且 FCS_Flag=0 时，读取 1 字节
    if current_offset >= data.length() {
      return Err("Frame_Content_Size字段不完整")
    }
    frame_content_size = data[current_offset].to_int()
    current_offset = current_offset + 1
  } else if frame_content_size_flag == 1 {
    if current_offset + 1 >= data.length() {
      return Err("Frame_Content_Size字段不完整")
    }
    frame_content_size = data[current_offset].to_int() | (data[current_offset + 1].to_int() << 8)
    frame_content_size = frame_content_size + 256  // FCS_Field_Size=1时，实际值+256
    current_offset = current_offset + 2
  } else if frame_content_size_flag == 2 {
    if current_offset + 3 >= data.length() {
      return Err("Frame_Content_Size字段不完整")
    }
    frame_content_size = data[current_offset].to_int() |
                        (data[current_offset + 1].to_int() << 8) |
                        (data[current_offset + 2].to_int() << 16) |
                        (data[current_offset + 3].to_int() << 24)
    current_offset = current_offset + 4
  } else if frame_content_size_flag == 3 {
    if current_offset + 7 >= data.length() {
      return Err("Frame_Content_Size字段不完整")
    }
    // 8字节Frame_Content_Size：MoonBit Int 限制为32位，只读取低4字节
    // 这限制了对 >4GB 文件的支持，但对大多数用例足够
    frame_content_size = data[current_offset].to_int() |
                        (data[current_offset + 1].to_int() << 8) |
                        (data[current_offset + 2].to_int() << 16) |
                        (data[current_offset + 3].to_int() << 24)
    // 忽略高4字节
    current_offset = current_offset + 8
  }
  
  // 如果是single_segment模式，window_size等于frame_content_size
  if single_segment && frame_content_size > 0 {
    window_size = frame_content_size
  }
  
  let frame_header_struct = @zstd_core.make_frame_header(@zstd_core.zstd_frame_type(), 0, frame_content_size, single_segment, content_checksum, window_size)
  Ok((frame_header_struct, current_offset - offset))
}

/// 解压缩单个块（带窗口用于字典引用）
/// window 参数预留用于 Compressed 块中的字典引用
fn decompress_single_block_with_window(
  data: Bytes, 
  offset: Int, 
  block_size: Int, 
  block_type: Int,
  _window: Bytes  // 预留用于 Compressed 块解压缩时的字典引用
) -> Result[Bytes, String] {
  match block_type {
    0 => {
      // Raw block - 直接返回数据
      if offset + block_size > data.length() {
        return Err("Raw 块数据超出文件边界")
      }
      // 使用数组来构建Raw数据，更高效
      let raw_array : Array[Byte] = []
      for i = offset; i < offset + block_size; i = i + 1 {
        raw_array.push(data[i])
      }
      Ok(Bytes::from_array(raw_array))
    }
    1 => {
      // RLE block - 重复数据
      if block_size == 0 {
        return Ok(Bytes::new(0))
      }
      if offset >= data.length() {
        return Err("RLE 块数据超出文件边界")
      }
      let repeat_byte = data[offset]
      // 使用数组来构建RLE数据，更高效
      let rle_array : Array[Byte] = []
      for _i = 0; _i < block_size; _i = _i + 1 {
        rle_array.push(repeat_byte)
      }
      Ok(Bytes::from_array(rle_array))
    }
    2 => {
      // Compressed block - 使用真正的解压缩实现（暂不传递window，未来可增强）
      decompress_compressed_block(data, offset, block_size)
    }
    3 => {
      // Reserved block type
      Err("Reserved block type")
    }
    _ => {
      Err("Unknown block type: " + block_type.to_string())
    }
  }
}

/// Decompress with explicit decompressor context
pub fn decompress_with_decompressor(decomp : @zstd_core.DecompressionContext, data : Bytes) -> @zstd_core.ZSTDResult[(@zstd_core.DecompressionContext, Bytes)] {
  match decompress(data) {
    Ok(result) => Ok((decomp, result))
    Err(err) => Err(err)
  }
}

/// Reset decompressor
pub fn reset_decompressor(decompressor : Decompressor) -> Decompressor {
  create_decompressor(decompressor.window_size)
}