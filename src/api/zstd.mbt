/// High-level ZSTD API
/// Provides simple compression and decompression functions

/// ZSTD 文件分析结果 - API 层定义
pub struct ZSTDFileAnalysis {
  is_valid: Bool
  error_message: String
  magic_number: UInt
  single_segment: Bool
  content_checksum: Bool
  frame_content_size: Int
  window_size: Int
  total_blocks: Int
  file_size: Int
  first_block_type: String
  first_block_size: Int
  last_block: Bool
}

/// 从decoder模块的分析结果转换为API层的结构体
fn convert_analysis_result(decoder_result: @decoder.ZSTDFileAnalysis) -> ZSTDFileAnalysis {
  // 使用accessor函数来获取字段值
  {
    is_valid: @decoder.get_is_valid(decoder_result),
    error_message: @decoder.get_error_message(decoder_result),
    magic_number: @decoder.get_magic_number(decoder_result),
    single_segment: @decoder.get_single_segment(decoder_result),
    content_checksum: @decoder.get_content_checksum(decoder_result),
    frame_content_size: @decoder.get_frame_content_size(decoder_result),
    window_size: @decoder.get_window_size(decoder_result),
    total_blocks: @decoder.get_total_blocks(decoder_result),
    file_size: @decoder.get_file_size(decoder_result),
    first_block_type: @decoder.get_first_block_type(decoder_result),
    first_block_size: @decoder.get_first_block_size(decoder_result),
    last_block: @decoder.get_last_block(decoder_result)
  }
}

/// Decompress data using ZSTD
pub fn decompress(data : Bytes) -> Bytes {
  let result = @decoder.decompress(data)
  match result {
    Ok(decompressed) => decompressed
    Err(_) => data // Return original data if decompression fails
  }
}

/// Create a new decompressor for streaming decompression  
pub fn create_decompressor() -> @decoder.Decompressor {
  @decoder.create_decompressor(65536)
}

/// Decompress data with a decompressor (for streaming)
pub fn decompress_with_decompressor(decomp : @decoder.Decompressor, data : Bytes) -> (@decoder.Decompressor, Bytes) {
  let result = @decoder.decompress_with_decompressor(decomp.context, data)
  match result {
    Ok((_new_context, decompressed)) => {
      let new_decomp = @decoder.create_decompressor(decomp.window_size)
      (new_decomp, decompressed)
    }
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
  @decoder.is_zstd_file(data)
}

/// 分析 ZSTD 文件结构和有效性
/// 这是一个高级API函数，用于验证和分析ZSTD文件
pub fn analyze_zstd_file(data : Bytes) -> ZSTDFileAnalysis {
  let decoder_result = @decoder.analyze_file(data)
  convert_analysis_result(decoder_result)
}

/// 验证ZSTD文件完整性（高级API）
pub fn validate_zstd_file(data : Bytes) -> (Bool, String) {
  @decoder.validate_file(data)
}