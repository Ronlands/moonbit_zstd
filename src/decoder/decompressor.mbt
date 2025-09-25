/// Main ZSTD decompressor implementation
/// Provides high-level decompression API

import core::types::{DecompressionContext}
import decoder::frame::{parse_frame_header, validate_frame_header}
import decoder::block::{decode_block}

/// ZSTD decompressor
pub struct Decompressor {
  context : DecompressionContext
}

/// Create new decompressor
pub fn new_decompressor() -> Decompressor {
  Decompressor {
    context: DecompressionContext {
      window: Bytes::new()
      window_size: 0
      window_pos: 0
    }
  }
}

/// Decompress data
pub fn decompress(data : Bytes) -> Bytes {
  let decompressor = new_decompressor()
  let (_, result) = decompress_with_context(decompressor, data)
  result
}

/// Decompress data with context (for streaming)
pub fn decompress_with_context(
  decompressor : Decompressor, 
  data : Bytes
) -> (Decompressor, Bytes) {
  let mut pos = 0
  let mut output = Bytes::new()
  let mut context = decompressor.context
  
  while pos < data.length() {
    // Parse frame header
    let remaining_data = data.slice(pos, data.length())
    let (frame_header, header_size) = parse_frame_header(remaining_data)
    
    if not(validate_frame_header(frame_header)) {
      abort("Invalid frame header")
    }
    
    pos = pos + header_size
    
    // Process blocks in frame
    let mut block_pos = pos
    let mut frame_output = Bytes::new()
    
    while block_pos < data.length() {
      let block_data = data.slice(block_pos, data.length())
      let (new_context, block_output, block_size) = decode_block(block_data, context)
      
      context = new_context
      frame_output = frame_output.append_all(block_output)
      block_pos = block_pos + block_size + 3 // +3 for block header
      
      // Check if this was the last block
      if block_pos >= data.length() {
        break
      }
    }
    
    output = output.append_all(frame_output)
    pos = block_pos
  }
  
  let new_decompressor = Decompressor {
    context: context
  }
  
  (new_decompressor, output)
}

/// Decompress streaming data
pub fn decompress_streaming(
  decompressor : Decompressor, 
  data : Bytes
) -> (Decompressor, Bytes) {
  decompress_with_context(decompressor, data)
}

/// Reset decompressor context
pub fn reset_decompressor(decompressor : Decompressor) -> Decompressor {
  Decompressor {
    context: DecompressionContext {
      window: Bytes::new()
      window_size: 0
      window_pos: 0
    }
  }
}
