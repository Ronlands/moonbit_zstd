/// High-level ZSTD API
/// Provides simple compression and decompression functions

import encoder::compressor
import decoder::decompressor

/// Compress data using ZSTD
pub fn compress(data : Bytes) -> Bytes {
  let result = compressor::compress(data)
  match result {
    Ok(compressed) => compressed
    Err(_) => data // Return original data if compression fails
  }
}

/// Decompress data using ZSTD
pub fn decompress(data : Bytes) -> Bytes {
  let result = decompressor::decompress(data)
  match result {
    Ok(decompressed) => decompressed
    Err(_) => data // Return original data if decompression fails
  }
}

/// Create a new compressor for streaming compression
pub fn create_compressor() -> compressor::Compressor {
  compressor::new_compressor()
}

/// Create a new decompressor for streaming decompression  
pub fn create_decompressor() -> decompressor::Decompressor {
  decompressor::new_decompressor()
}

/// Compress data with a compressor (for streaming)
pub fn compress_with_compressor(comp : compressor::Compressor, data : Bytes) -> (compressor::Compressor, Bytes) {
  let result = compressor::compress_with_context(comp, data)
  match result {
    Ok((new_comp, compressed)) => (new_comp, compressed)
    Err(_) => (comp, data) // Return original data if compression fails
  }
}

/// Decompress data with a decompressor (for streaming)
pub fn decompress_with_decompressor(decomp : decompressor::Decompressor, data : Bytes) -> (decompressor::Decompressor, Bytes) {
  let result = decompressor::decompress_with_context(decomp, data)
  match result {
    Ok((new_decomp, decompressed)) => (new_decomp, decompressed)
    Err(_) => (decomp, data) // Return original data if decompression fails
  }
}

/// Get compression ratio
pub fn get_compression_ratio(original_size : Int, compressed_size : Int) -> Double {
  if original_size == 0 {
    0.0
  } else {
    (compressed_size.to_double() / original_size.to_double()) * 100.0
  }
}

/// Check if data appears to be ZSTD compressed
pub fn is_zstd_data(data : Bytes) -> Bool {
  if data.length() < 4 {
    false
  } else {
    // Check for ZSTD magic number (little-endian)
    let magic = (data[3].to_int() << 24) |
                (data[2].to_int() << 16) |
                (data[1].to_int() << 8) |
                data[0].to_int()
    magic == 0xFD2FB528
  }
}