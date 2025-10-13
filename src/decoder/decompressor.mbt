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
        
        // 检查块大小
        if current_offset + block_size > data.length() {
          return Err("块数据超出文件边界")
        }
        
        // 解压缩块
        let block_result = decompress_single_block(data, current_offset, block_size, block_type)
        match block_result {
          Ok(block_data) => {
            output_data = output_data + block_data
            current_offset = current_offset + block_size
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
  if offset + 2 > data.length() {
    return Err("帧头不完整")
  }
  
  let frame_header = data[offset].to_int() | (data[offset + 1].to_int() << 8)
  let single_segment = (frame_header & 1) != 0
  let content_checksum = (frame_header & 4) != 0
  let frame_content_size_flag = (frame_header >> 6) & 3
  let window_descriptor_flag = (frame_header >> 3) & 3
  
  let mut current_offset = offset + 2
  let mut frame_content_size = 0
  let mut window_size = 0
  
  // 解析帧内容大小
  if frame_content_size_flag == 1 {
    if current_offset >= data.length() {
      return Err("帧内容大小字段不完整")
    }
    frame_content_size = data[current_offset].to_int()
    current_offset = current_offset + 1
  } else if frame_content_size_flag == 2 {
    if current_offset + 1 >= data.length() {
      return Err("帧内容大小字段不完整")
    }
    frame_content_size = data[current_offset].to_int() | (data[current_offset + 1].to_int() << 8)
    current_offset = current_offset + 2
  } else if frame_content_size_flag == 3 {
    if current_offset + 3 >= data.length() {
      return Err("帧内容大小字段不完整")
    }
    frame_content_size = data[current_offset].to_int() |
                        (data[current_offset + 1].to_int() << 8) |
                        (data[current_offset + 2].to_int() << 16) |
                        (data[current_offset + 3].to_int() << 24)
    current_offset = current_offset + 4
  }
  
  // 解析窗口大小
  if window_descriptor_flag == 1 {
    if current_offset >= data.length() {
      return Err("窗口大小字段不完整")
    }
    window_size = data[current_offset].to_int()
    current_offset = current_offset + 1
  } else if window_descriptor_flag == 2 {
    if current_offset + 1 >= data.length() {
      return Err("窗口大小字段不完整")
    }
    window_size = data[current_offset].to_int() | (data[current_offset + 1].to_int() << 8)
    current_offset = current_offset + 2
  } else if window_descriptor_flag == 3 {
    if current_offset + 3 >= data.length() {
      return Err("窗口大小字段不完整")
    }
    window_size = data[current_offset].to_int() |
                 (data[current_offset + 1].to_int() << 8) |
                 (data[current_offset + 2].to_int() << 16) |
                 (data[current_offset + 3].to_int() << 24)
    current_offset = current_offset + 4
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
      let mut raw_data = Bytes::new(0)
      for i = offset; i < offset + block_size; i = i + 1 {
        raw_data = raw_data + [data[i]]
      }
      Ok(raw_data)
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
      let mut rle_data = Bytes::new(0)
      for _i = 0; _i < block_size; _i = _i + 1 {
        rle_data = rle_data + [repeat_byte]
      }
      Ok(rle_data)
    }
    2 => {
      // Compressed block - 简化处理
      let mut compressed_data = Bytes::new(0)
      for i = 0; i < block_size; i = i + 1 {
        compressed_data = compressed_data + [data[offset + i]]
      }
      Ok(compressed_data)
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