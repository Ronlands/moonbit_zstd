/// ZSTD decompressor implementation
/// Main entry point for ZSTD decompression according to RFC 8878

import core::types::{DecompressionContext, FrameHeader}
import decoder::frame::{parse_frame_header}
import decoder::block::{decode_block}

pub struct Decompressor {
  window_size : Int,
  context : DecompressionContext
}

pub fn new_decompressor() -> Decompressor {
  let context : DecompressionContext = {
    window_buffer: b"",
    dictionary: b"",
    window_size: 1 << 16 // Default 64KB window
  }
  
  {
    window_size: 1 << 16,
    context: context
  }
}

/// Main decompression function
pub fn decompress(data : Bytes) -> Result[Bytes, String] {
  let decompressor = new_decompressor()
  let result = decompress_with_context(decompressor, data)
  match result {
    Ok((_, decompressed)) => Ok(decompressed)
    Err(msg) => Err(msg)
  }
}

/// Decompress with decompressor context
pub fn decompress_with_context(
  decompressor : Decompressor, 
  data : Bytes
) -> Result[(Decompressor, Bytes), String] {
  
  if data.length() < 4 {
    return Err("Data too short for ZSTD frame")
  }
  
  // Parse frame header
  let frame_result = parse_frame_header(data)
  let (frame_header, header_size) = match frame_result {
    Ok(result) => result
    Err(msg) => return Err("Frame header error: " + msg)
  }
  
  let mut offset = header_size
  let mut output_data : Array[Byte] = []
  let mut current_context = decompressor.context
  
  // Decode blocks until we find the last block
  let mut last_block = false
  while !last_block && offset < data.length() {
    let block_result = decode_block(data, offset, current_context)
    let (new_context, block_data, bytes_consumed) = match block_result {
      Ok(result) => result
      Err(msg) => return Err("Block decoding error: " + msg)
    }
    
    // Append block data to output
    let block_array = block_data.to_array()
    output_data = output_data + block_array
    
    current_context = new_context
    offset = offset + bytes_consumed
    
    // Check if this was the last block (simplified check)
    // In real implementation, this would be determined from block header
    if offset >= data.length() - 4 {
      last_block = true
    }
  }
  
  // Handle content checksum if present
  if frame_header.checksum_flag && offset + 4 <= data.length() {
    // TODO: Verify checksum
    offset = offset + 4
  }
  
  let final_decompressor : Decompressor = {
    window_size: decompressor.window_size,
    context: current_context
  }
  
  let result_bytes = Bytes::from_array(output_data)
  Ok((final_decompressor, result_bytes))
}

/// Simple decompress function for backward compatibility
pub fn decompress_simple(data : Bytes) -> Bytes {
  match decompress(data) {
    Ok(result) => result
    Err(_) => data // Return original data if decompression fails
  }
}

pub fn reset_decompressor(decompressor : Decompressor) -> Decompressor {
  new_decompressor()
}