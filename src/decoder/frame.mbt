/// ZSTD frame format decoder
/// Handles frame header parsing and validation

import core::types::{FrameHeader, FrameType, ZSTD_MAGIC_NUMBER}
import core::bitstream::{BitStream, new_bitstream, read_bits, read_byte, read_bytes}

/// Parse ZSTD frame header
pub fn parse_frame_header(data : Bytes) -> (FrameHeader, Int) {
  let stream = new_bitstream(data)
  let mut pos = 0
  
  // Read magic number
  let (stream1, magic_bytes) = read_bytes(stream, 4)
  let magic = (magic_bytes[0].to_int() << 24) | 
              (magic_bytes[1].to_int() << 16) | 
              (magic_bytes[2].to_int() << 8) | 
              magic_bytes[3].to_int()
  
  if magic == ZSTD_MAGIC_NUMBER.to_int() {
    // ZSTD frame
    let (stream2, frame_header) = parse_zstd_frame_header(stream1)
    (frame_header, 4)
  } else if (magic & 0xFFFFFFF0) == 0x184D2A50 {
    // Skippable frame
    let (stream2, frame_header) = parse_skippable_frame_header(stream1)
    (frame_header, 4)
  } else {
    // Invalid frame
    abort("Invalid ZSTD frame magic number")
  }
}

/// Parse ZSTD frame header
fn parse_zstd_frame_header(stream : BitStream) -> (BitStream, FrameHeader) {
  // Read frame descriptor
  let (stream1, descriptor) = read_byte(stream)
  
  let single_segment = (descriptor & 0x80) != 0
  let checksum_flag = (descriptor & 0x40) != 0
  let content_size_flag = descriptor & 0x03
  
  // Read window descriptor
  let (stream2, window_descriptor) = if single_segment {
    (stream1, 0)
  } else {
    read_byte(stream1)
  }
  
  let window_log = if single_segment {
    0
  } else {
    let base = (window_descriptor >> 3) + 10
    let mantissa = window_descriptor & 0x07
    if mantissa < 3 {
      base
    } else {
      base + (mantissa - 3)
    }
  }
  
  let window_size = if single_segment {
    0
  } else {
    1 << window_log
  }
  
  // Read dictionary ID
  let (stream3, dict_id) = if (descriptor & 0x04) != 0 {
    let (stream2, dict_id_byte) = read_byte(stream2)
    (stream2, dict_id_byte)
  } else {
    (stream2, 0)
  }
  
  // Read frame content size
  let (stream4, frame_content_size) = match content_size_flag {
    0 => (stream3, 0)
    1 => {
      let (stream3, size_byte) = read_byte(stream3)
      (stream3, size_byte)
    }
    2 => {
      let (stream3, size_bytes) = read_bytes(stream3, 2)
      let size = (size_bytes[0].to_int() << 8) | size_bytes[1].to_int()
      (stream3, size)
    }
    3 => {
      let (stream3, size_bytes) = read_bytes(stream3, 4)
      let size = (size_bytes[0].to_int() << 24) | 
                 (size_bytes[1].to_int() << 16) | 
                 (size_bytes[2].to_int() << 8) | 
                 size_bytes[3].to_int()
      (stream3, size)
    }
    _ => abort("Invalid content size flag")
  }
  
  let header = FrameHeader {
    frame_type: FrameType::ZSTD_frame
    window_size: window_size
    dict_id: dict_id
    frame_content_size: frame_content_size
    single_segment: single_segment
    checksum_flag: checksum_flag
  }
  
  (stream4, header)
}

/// Parse skippable frame header
fn parse_skippable_frame_header(stream : BitStream) -> (BitStream, FrameHeader) {
  // Read frame size
  let (stream1, size_bytes) = read_bytes(stream, 4)
  let frame_size = (size_bytes[0].to_int() << 24) | 
                   (size_bytes[1].to_int() << 16) | 
                   (size_bytes[2].to_int() << 8) | 
                   size_bytes[3].to_int()
  
  let header = FrameHeader {
    frame_type: FrameType::SkippableFrame
    window_size: 0
    dict_id: 0
    frame_content_size: frame_size
    single_segment: true
    checksum_flag: false
  }
  
  (stream1, header)
}

/// Validate frame header
pub fn validate_frame_header(header : FrameHeader) -> Bool {
  match header.frame_type {
    FrameType::ZSTD_frame => {
      // Validate window size
      if header.window_size > 0 {
        let window_log = 0
        let mut temp = header.window_size
        while temp > 1 {
          temp = temp >> 1
          window_log = window_log + 1
        }
        window_log >= 10 && window_log <= 23
      } else {
        true
      }
    }
    FrameType::SkippableFrame => {
      header.frame_content_size >= 0
    }
  }
}
