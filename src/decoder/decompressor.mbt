/// ZSTD decompressor module
/// Simplified implementation using analyzer functionality

/// Decompressor structure
pub struct Decompressor {
  window_size : Int
  context : @zstd_core.DecompressionContext
}

/// Create new decompressor
pub fn new_decompressor() -> @zstd_core.DecompressionContext {
  @zstd_core.make_decompression_context()
}

/// Create decompressor with specific window size
pub fn create_decompressor(window_size : Int) -> Decompressor {
  let context = @zstd_core.make_decompression_context()
  { window_size: window_size, context: context }
}

/// Decompress ZSTD data - Real implementation
pub fn decompress(data : Bytes) -> @zstd_core.ZSTDResult[Bytes] {
  // Basic validation
  if data.length() < 4 {
    return Err(@zstd_core.invalid_data_error())
  }

  // Check if it's a valid ZSTD file using analyzer
  let analysis = analyze_file(data)
  if !analysis.is_valid {
    return Err(@zstd_core.decompression_error())
  }
  
  // 实现真正的解压缩逻辑
  let decompression_result = decompress_zstd_data(data)
  match decompression_result {
    Ok(decompressed_data) => Ok(decompressed_data)
    Err(_error_msg) => Err(@zstd_core.decompression_error())
  }
}

/// 真正的 ZSTD 解压缩实现
pub fn decompress_zstd_data(data: Bytes) -> Result[Bytes, String] {
  let mut current_offset = 4  // 跳过魔数
  
  // 解析帧头
  let frame_result = parse_frame_header_for_decompressor(data, current_offset)
  match frame_result {
    Ok((_frame_header, header_size)) => {
      current_offset = current_offset + header_size
      
      // 解压缩块
      let mut output_data = Bytes::new(0)
      
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
          return Err("块数据超出文件边界")
        }
        
        // 解压缩块（传递block_size作为解压后的大小）
        let block_result = decompress_single_block(data, current_offset, block_size, block_type)
        match block_result {
          Ok(block_data) => {
            output_data = output_data + block_data
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
      
      Ok(output_data)
    }
    Err(error_msg) => Err(error_msg)
  }
}

/// 解析帧头用于解压缩
fn parse_frame_header_for_decompressor(data: Bytes, offset: Int) -> Result[(@zstd_core.FrameHeader, Int), String] {
  if offset + 1 > data.length() {
    return Err("帧头不完整")
  }
  
  // 读取Frame_Header_Descriptor (1字节)
  let descriptor = data[offset].to_int()
  
  // 解析Frame_Header_Descriptor各个字段
  let frame_content_size_flag = (descriptor >> 6) & 3  // Bits 7-6
  let single_segment = ((descriptor >> 5) & 1) != 0    // Bit 5
  let content_checksum = ((descriptor >> 2) & 1) != 0  // Bit 2
  let dict_id_flag = descriptor & 3                     // Bits 1-0
  
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
  if frame_content_size_flag == 1 {
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
    // 8字节Frame_Content_Size，但MoonBit的Int可能只有32位，这里简化处理
    frame_content_size = data[current_offset].to_int() |
                        (data[current_offset + 1].to_int() << 8) |
                        (data[current_offset + 2].to_int() << 16) |
                        (data[current_offset + 3].to_int() << 24)
    // 忽略高4字节
    current_offset = current_offset + 8
  } else {
    // frame_content_size_flag == 0
    // 如果single_segment=1，FCS从Window_Size推导；否则未知
    if single_segment {
      // FCS will be set when we know it
      frame_content_size = 0
    }
  }
  
  // 如果是single_segment模式，window_size等于frame_content_size
  if single_segment && frame_content_size > 0 {
    window_size = frame_content_size
  }
  
  let frame_header_struct = @zstd_core.make_frame_header(@zstd_core.zstd_frame_type(), 0, frame_content_size, single_segment, content_checksum, window_size)
  Ok((frame_header_struct, current_offset - offset))
}

/// 解压缩单个块
fn decompress_single_block(data: Bytes, offset: Int, block_size: Int, block_type: Int) -> Result[Bytes, String] {
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
      // Compressed block - 使用真正的解压缩实现
      decompress_compressed_block(data, offset, block_size)
    }
    3 => {
      // Reserved block type
      Err("保留块类型")
    }
    _ => {
      Err("未知块类型: " + block_type.to_string())
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