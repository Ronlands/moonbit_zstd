/// ZSTD frame format decoder
/// Handles frame header parsing and validation according to RFC 8878

/// Parse ZSTD frame header according to RFC 8878 - Improved version
pub fn parse_frame_header(data : Bytes) -> @core.ZSTDResult[(@core.FrameHeader, Int)] {
  if data.length() < 5 {
    return Err(@core.invalid_frame_header_error())
  }
  
  // Check magic number (little-endian)
  let magic = (data[3].to_int() << 24) |
              (data[2].to_int() << 16) |
              (data[1].to_int() << 8) |
              data[0].to_int()
  
  if magic.reinterpret_as_uint() != @core.ZSTD_MAGIC_NUMBER {
    return Err(@core.invalid_magic_number_error())
  }
  
  // Parse Frame Header Descriptor (FHD) at offset 4
  let fhd = data[4].to_int()
  let mut offset = 5
  
  // Parse Frame Header Descriptor fields
  let single_segment = (fhd & 0x20) != 0
  let checksum_flag = (fhd & 0x04) != 0
  let dict_id_flag = fhd & 0x03
  let fcs_flag = (fhd >> 6) & 0x03
  
  // Parse dictionary ID if present
  let mut dict_id = 0
  if dict_id_flag == 1 {
    if offset >= data.length() { return Err(@core.invalid_frame_header_error()) }
    dict_id = data[offset].to_int()
    offset = offset + 1
  } else if dict_id_flag == 2 {
    if offset + 1 >= data.length() { return Err(@core.invalid_frame_header_error()) }
    dict_id = data[offset].to_int() | (data[offset + 1].to_int() << 8)
    offset = offset + 2
  } else if dict_id_flag == 3 {
    if offset + 3 >= data.length() { return Err(@core.invalid_frame_header_error()) }
    dict_id = data[offset].to_int() | (data[offset + 1].to_int() << 8) | 
              (data[offset + 2].to_int() << 16) | (data[offset + 3].to_int() << 24)
    offset = offset + 4
  }
  
  // Parse Frame Content Size if present
  let mut frame_content_size = 0
  if !single_segment || fcs_flag > 0 {
    if fcs_flag == 1 {
      if offset + 1 >= data.length() { return Err(@core.invalid_frame_header_error()) }
      frame_content_size = data[offset].to_int() | (data[offset + 1].to_int() << 8)
      offset = offset + 2
    } else if fcs_flag == 2 {
      if offset + 3 >= data.length() { return Err(@core.invalid_frame_header_error()) }
      frame_content_size = data[offset].to_int() | (data[offset + 1].to_int() << 8) | 
                          (data[offset + 2].to_int() << 16) | (data[offset + 3].to_int() << 24)
      offset = offset + 4
    } else if fcs_flag == 3 {
      if offset + 7 >= data.length() { return Err(@core.invalid_frame_header_error()) }
      // 8-byte field, but we'll truncate to Int for simplicity
      frame_content_size = data[offset].to_int() | (data[offset + 1].to_int() << 8) | 
                          (data[offset + 2].to_int() << 16) | (data[offset + 3].to_int() << 24)
      offset = offset + 8
    }
  }
  
  // Window Size (only if not single segment)
  let window_size = if single_segment { frame_content_size } else { 65536 }
  
  // Create frame header
  let header = @core.make_frame_header(
    @core.zstd_frame_type(),
    dict_id,
    frame_content_size,
    single_segment,
    checksum_flag,
    window_size
  )
  
  Ok((header, offset))  // Return header and actual bytes consumed
}

/// Simple version for backward compatibility
pub fn parse_frame_header_simple(data : Bytes) -> (Int, Int) {
  match parse_frame_header(data) {
    Ok((header, bytes_read)) => (header.frame_content_size, bytes_read)
    Err(_) => (0, 4)
  }
}

/// Validate frame header
pub fn validate_frame_header(header : @core.FrameHeader) -> Bool {
  header.window_size > 0 && header.window_size <= (1 << 31)
}