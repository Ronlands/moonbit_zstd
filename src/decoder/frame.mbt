/// ZSTD frame format decoder
/// Handles frame header parsing and validation according to RFC 8878

import core::types::{FrameHeader, FrameType, ZSTD_MAGIC_NUMBER, ZSTDError, ZSTDResult}
import core::bitstream::{BitStream, new_bitstream, read_bytes, read_byte, read_le_int}

/// Parse ZSTD frame header according to RFC 8878
pub fn parse_frame_header(data : Bytes) -> ZSTDResult[(FrameHeader, Int)] {
  if data.length() < 4 {
    return Err(ZSTDError::InvalidFrameHeader)
  }
  
  let mut stream = new_bitstream(data)
  let (new_stream, magic_bytes) = read_bytes(stream, 4)
  stream = new_stream
  
  // Check magic number (little-endian)
  let magic = (magic_bytes[3].to_int() << 24) |
              (magic_bytes[2].to_int() << 16) |
              (magic_bytes[1].to_int() << 8) |
              magic_bytes[0].to_int()
  
  if magic.to_uint() != ZSTD_MAGIC_NUMBER {
    return Err(ZSTDError::InvalidMagicNumber)
  }
  
  // Parse Frame_Header_Descriptor
  let (new_stream2, fhd_byte) = read_byte(stream)
  stream = new_stream2
  let fhd = fhd_byte.to_int()
  
  // Extract fields from Frame_Header_Descriptor
  let frame_content_size_flag = (fhd >> 6) & 0x3
  let single_segment_flag = (fhd >> 5) & 0x1
  let unused_bit = (fhd >> 4) & 0x1
  let reserved_bit = (fhd >> 3) & 0x1
  let content_checksum_flag = (fhd >> 2) & 0x1
  let dictionary_id_flag = fhd & 0x3
  
  if unused_bit != 0 || reserved_bit != 0 {
    return Err(ZSTDError::InvalidFrameHeader)
  }
  
  let mut bytes_read = 5 // magic + FHD
  
  // Parse Dictionary_ID (if present)
  let mut dictionary_id = 0
  match dictionary_id_flag {
    0 => {} // No dictionary ID
    1 => {
      let (new_stream3, dict_bytes) = read_bytes(stream, 1)
      stream = new_stream3
      dictionary_id = dict_bytes[0].to_int()
      bytes_read = bytes_read + 1
    }
    2 => {
      let (new_stream3, dict_bytes) = read_bytes(stream, 2)
      stream = new_stream3
      dictionary_id = (dict_bytes[0].to_int()) | (dict_bytes[1].to_int() << 8)
      bytes_read = bytes_read + 2
    }
    3 => {
      let (new_stream3, dict_bytes) = read_bytes(stream, 4)
      stream = new_stream3
      dictionary_id = (dict_bytes[0].to_int()) | 
                     (dict_bytes[1].to_int() << 8) |
                     (dict_bytes[2].to_int() << 16) |
                     (dict_bytes[3].to_int() << 24)
      bytes_read = bytes_read + 4
    }
    _ => return Err(ZSTDError::InvalidFrameHeader)
  }
  
  // Parse Frame_Content_Size (if present)
  let mut frame_content_size = 0
  if single_segment_flag == 1 || frame_content_size_flag != 0 {
    let size_bytes = match frame_content_size_flag {
      0 => if single_segment_flag == 1 { 1 } else { 0 }
      1 => 2
      2 => 4
      3 => 8
      _ => return Err(ZSTDError::InvalidFrameHeader)
    }
    
    if size_bytes > 0 {
      let (new_stream3, size_bytes_data) = read_bytes(stream, size_bytes)
      stream = new_stream3
      
      // Parse little-endian size
      for i = 0; i < size_bytes; i = i + 1 {
        frame_content_size = frame_content_size | (size_bytes_data[i].to_int() << (i * 8))
      }
      bytes_read = bytes_read + size_bytes
    }
  }
  
  let window_size_result = calculate_window_size(fhd, frame_content_size, single_segment_flag == 1)
  let window_size = match window_size_result {
    Ok(size) => size
    Err(msg) => return Err(msg)
  }
  
  let header : FrameHeader = {
    frame_type: FrameType::ZSTD_frame,
    dict_id: dictionary_id,
    frame_content_size: frame_content_size,
    single_segment: single_segment_flag == 1,
    checksum_flag: content_checksum_flag == 1,
    window_size: window_size
  }
  
  Ok((header, bytes_read))
}

/// Calculate window size based on frame header
fn calculate_window_size(fhd : Int, frame_content_size : Int, single_segment : Bool) -> ZSTDResult[Int] {
  if single_segment {
    Ok(frame_content_size)
  } else {
    let window_log = (fhd >> 3) & 0x1F
    if window_log == 0 {
      Err(ZSTDError::InvalidFrameHeader)
    } else {
      Ok(1 << (window_log + 10)) // Window_Log ranges from 10 to 31
    }
  }
}

pub fn validate_frame_header(header : FrameHeader) -> Bool {
  header.window_size > 0 && header.window_size <= (1 << 31)
}

/// Simple version for backward compatibility
pub fn parse_frame_header_simple(data : Bytes) -> (Int, Int) {
  match parse_frame_header(data) {
    Ok((header, bytes_read)) => (header.frame_content_size, bytes_read)
    Err(_) => (0, 4)
  }
}

/// Parse skippable frame (RFC 8878)
pub fn parse_skippable_frame(data : Bytes) -> ZSTDResult[(Int, Int)] {
  if data.length() < 8 {
    return Err(ZSTDError::InvalidFrameHeader)
  }
  
  let stream = new_bitstream(data)
  let (stream2, magic_bytes) = read_bytes(stream, 4)
  
  // Check skippable frame magic (0x184D2A5X where X is 0-F)
  let magic = (magic_bytes[3].to_int() << 24) |
              (magic_bytes[2].to_int() << 16) |
              (magic_bytes[1].to_int() << 8) |
              magic_bytes[0].to_int()
  
  let magic_base = magic & 0xFFFFFFF0
  if magic_base != 0x184D2A50 {
    return Err(ZSTDError::InvalidMagicNumber)
  }
  
  // Read frame size (4 bytes, little-endian)
  let (_, frame_size) = read_le_int(stream2, 4)
  
  Ok((frame_size, 8)) // Return size and header length
}