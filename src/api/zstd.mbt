/// High-level ZSTD API
/// Provides simple compression and decompression functions

import decoder::decompressor::{decompress, decompress_with_context, new_decompressor, Decompressor}
import encoder::compressor::{compress, compress_with_context, new_compressor, Compressor}

/// Compress data using ZSTD
pub fn compress(data : Bytes) -> Bytes {
  compress(data)
}

/// Decompress data using ZSTD
pub fn decompress(data : Bytes) -> Bytes {
  decompress(data)
}

/// Create a new compressor for streaming compression
pub fn create_compressor() -> Compressor {
  new_compressor()
}

/// Create a new decompressor for streaming decompression
pub fn create_decompressor() -> Decompressor {
  new_decompressor()
}

/// Compress data with a compressor (for streaming)
pub fn compress_with_compressor(compressor : Compressor, data : Bytes) -> (Compressor, Bytes) {
  (compressor, compress_with_context(compressor, data))
}

/// Decompress data with a decompressor (for streaming)
pub fn decompress_with_decompressor(decompressor : Decompressor, data : Bytes) -> (Decompressor, Bytes) {
  decompress_with_context(decompressor, data)
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
    let magic = (data[0].to_int() << 24) | 
                (data[1].to_int() << 16) | 
                (data[2].to_int() << 8) | 
                data[3].to_int()
    magic == 0x2D_52_28_B5
  }
}
