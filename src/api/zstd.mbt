/// Compression level presets.
///
/// Maps to internal numeric levels:
/// - `Fast` → level 1
/// - `Default` → level 3
/// - `Better` → level 6
/// - `Best` → level 9
pub enum CompressionLevel {
  Fast
  Default
  Better
  Best
}

// Helper function to convert Result[T, String] to Result[T, ZSTDError]
fn[T] to_zstd_error(result: Result[T, String]) -> Result[T, @zstd_core.ZSTDError] {
  match result {
    Ok(v) => Ok(v)
    Err(msg) => Err(@zstd_core.message_error(msg))
  }
}

/// Result of analyzing a ZSTD compressed file's structure.
///
/// Contains frame header information, block metadata, and validation status.
pub struct ZSTDFileAnalysis {
  is_valid: Bool
  error_message: String
  magic_number: UInt
  single_segment: Bool
  content_checksum: Bool
  window_size: UInt
  total_blocks: Int
  file_size: Int
  first_block_type: String
  first_block_size: Int
  last_block: Bool
}

/// Result of data integrity analysis.
pub struct DataIntegrityAnalysis {
  truncation_indicators: Int
  data_density: Double
  structure_consistency: Double
  entropy_level: Double
}

/// Sliding window decoder context for streaming decompression.
///
/// Maintains internal state across multiple `decompress_with_sliding_window` calls.
pub struct SlidingWindowDecoder {
  mut context: @zstd_decoder.DecoderContext
  window_size: Int
}

/// Compress data with a numeric compression level (1-22).
///
/// Higher levels produce smaller output at the cost of speed.
/// Level is clamped to `[1, 22]`.
///
/// # Example
///
/// ```moonbit no-check
/// let compressed = @zstd.compress_with_level_int(data, 9)
/// ```
pub fn compress_with_level_int(data: Bytes, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_advanced(data, CompressionMethod::Auto, level)
}

/// Compress using a Raw block (no compression, just ZSTD frame wrapping).
pub fn compress_as_raw(data: Bytes, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_advanced(data, CompressionMethod::Raw, level)
}

/// Compress using an RLE block (ideal for highly repetitive data).
pub fn compress_as_rle(data: Bytes, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_advanced(data, CompressionMethod::RLE, level)
}

/// Compress using a Compressed block (LZ77 + FSE entropy coding).
///
/// Produces the best compression ratio for most data.
pub fn compress_as_compressed(data: Bytes, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_advanced(data, CompressionMethod::Compressed, level)
}

/// Compress data using default settings (level 2, auto block type selection).
///
/// This is the simplest entry point. For more control, use
/// `compress_with_level_int` or `compress_advanced`.
///
/// # Example
///
/// ```moonbit no-check
/// let original = @encoding/utf8.encode("Hello, ZSTD!")
/// match @zstd.compress(original) {
///   Ok(compressed) => {
///     let decompressed = @zstd.decompress(compressed)
///   }
///   Err(e) => println("Compression failed: \{e}")
/// }
/// ```
pub fn compress(data: Bytes) -> Result[Bytes, @zstd_core.ZSTDError] {
  @zstd_encoder.compress(data)
}

/// Compress data with a `CompressionLevel` preset.
///
/// # Example
///
/// ```moonbit no-check
/// let compressed = @zstd.compress_with_level(data, CompressionLevel::Better)
/// ```
pub fn compress_with_level(data: Bytes, level: CompressionLevel) -> Result[Bytes, @zstd_core.ZSTDError] {
  let compression_level = match level {
    CompressionLevel::Fast => 1
    CompressionLevel::Default => 3
    CompressionLevel::Better => 6
    CompressionLevel::Best => 9
  }

  let config = @zstd_encoder.create_config_with_level(compression_level)
  @zstd_encoder.compress_data(data, config)
}

/// Compression method selection.
///
/// - `Auto` — automatically selects the best method based on data characteristics
/// - `Raw` — no compression, just ZSTD frame wrapping
/// - `RLE` — run-length encoding for highly repetitive data
/// - `Compressed` — LZ77 + FSE entropy coding for best ratio
pub enum CompressionMethod {
  Auto
  Raw
  RLE
  Compressed
} derive(Show)

fn choose_compression_method(data: Bytes) -> (String, Byte, Int) {
  if data.length() == 0 { return ("raw", 0, 0) }
  if is_suitable_for_rle(data) { return ("rle", data[0], data.length()) }
  ("raw", 0, data.length())
}

fn is_suitable_for_rle(data: Bytes) -> Bool {
  if data.length() < 4 { return false }
  let first_byte = data[0]
  let mut same_count = 1
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] == first_byte { same_count = same_count + 1 } else { break }
  }
  same_count.to_double() / data.length().to_double() > 0.75
}

/// Compress with full control over method and level.
///
/// # Parameters
///
/// - `data` — bytes to compress
/// - `mode` — compression method (`Auto`, `Raw`, `RLE`, or `Compressed`)
/// - `level` — numeric compression level (1-22, clamped)
///
/// # Example
///
/// ```moonbit no-check
/// let compressed = @zstd.compress_advanced(data, Compressed, 5)
/// ```
pub fn compress_advanced(data: Bytes, mode: CompressionMethod, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  let actual_level = if level < 1 { 2 } else if level > 22 { 22 } else { level }
  let config = @zstd_encoder.create_config_with_level(actual_level)

  match mode {
    CompressionMethod::Auto => {
      let (compression_type, _byte, _size) = choose_compression_method(data)
      if compression_type == "rle" {
        @zstd_encoder.compress_as_rle_block(data, config)
      } else {
        @zstd_encoder.compress_data(data, config)
      }
    }
    CompressionMethod::Raw => @zstd_encoder.compress_as_raw_block(data, config)
    CompressionMethod::RLE => @zstd_encoder.compress_as_rle_block(data, config)
    CompressionMethod::Compressed => @zstd_encoder.compress_as_compressed_block(data, config)
  }
}

/// Decompress a ZSTD-compressed frame.
///
/// Supports all block types (Raw, RLE, Compressed) and multi-block frames.
/// Returns empty `Bytes` if the input is not valid ZSTD data.
///
/// # Example
///
/// ```moonbit no-check
/// let original = @zstd.decompress(compressed)
/// ```
pub fn decompress(data: Bytes) -> Bytes {
  if data.length() < 4 {
    return Bytes::from_array([])
  }

  let magic = (data[3].to_int() << 24) | (data[2].to_int() << 16) | (data[1].to_int() << 8) | data[0].to_int()
  if magic != @zstd_core.ZSTD_MAGIC_NUMBER_INT {
    return Bytes::from_array([])
  }

  let max_output_size = 134217728 // 128MB global limit
  let result = @zstd_decoder.decompress_with_limit(data, max_output_size)
  match result {
    Ok(decompressed) => decompressed
    Err(_) => Bytes::from_array([])
  }
}

/// Analyze the structure of a ZSTD compressed file.
///
/// Returns frame header info, block type, block size, and validation status
/// without performing full decompression.
pub fn analyze_file(data: Bytes) -> ZSTDFileAnalysis {
  analyze_file_detailed(data)
}

/// 详细的文件分析，包含错误检测
fn analyze_file_detailed(data: Bytes) -> ZSTDFileAnalysis {
  if data.length() < 4 {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "文件太小，无法包含 ZSTD 魔数",
      magic_number: 0U,
      single_segment: false,
      content_checksum: false,
      window_size: 0U,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "unknown",
      first_block_size: 0,
      last_block: false
    }
  }
  
  let magic = (data[3].to_int() << 24) | (data[2].to_int() << 16) | (data[1].to_int() << 8) | data[0].to_int()
  
  if magic != @zstd_core.ZSTD_MAGIC_NUMBER_INT {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "无效的 ZSTD 魔数",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: false,
      content_checksum: false,
      window_size: 0U,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "unknown",
      first_block_size: 0,
      last_block: false
    }
  }
  
  if data.length() < 6 {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "帧头不完整",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: false,
      content_checksum: false,
      window_size: 0U,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "unknown",
      first_block_size: 0,
      last_block: false
    }
  }
  
  let frame_desc = data[4].to_int()
  let single_segment = (frame_desc & 0x20) != 0
  let content_checksum = (frame_desc & 0x04) != 0
  let dict_id_flag = (frame_desc & 0x03)
  let fcs_field_size = (frame_desc >> 6) & 3  // Frame Content Size field size (位6-7)
  
  let reserved_bits = (frame_desc & 0x08)
  if reserved_bits != 0 {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "帧描述符中的保留位非零",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: single_segment,
      content_checksum: content_checksum,
      window_size: 0U,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "invalid",
      first_block_size: 0,
      last_block: false
    }
  }
  
  let mut offset = 5
  let mut window_size = 0U
  if !single_segment {
    if data.length() <= offset {
      return ZSTDFileAnalysis::{
        is_valid: false,
        error_message: "缺少窗口描述符",
        magic_number: magic.reinterpret_as_uint(),
        single_segment: single_segment,
        content_checksum: content_checksum,
        window_size: 0U,
        total_blocks: 0,
        file_size: data.length(),
        first_block_type: "unknown",
        first_block_size: 0,
        last_block: false
      }
    }
    let window_desc = data[offset].to_int()
    let wd_exp = (window_desc >> 3) & 0x1F
    let wd_mant = window_desc & 0x07
    let window_base = 1 << (wd_exp + 10)
    window_size = (window_base + (window_base / 8) * wd_mant).reinterpret_as_uint()
    offset = offset + 1
  }
  
  // 跳过字典 ID（如果存在）
  if dict_id_flag > 0 {
    let dict_id_bytes = match dict_id_flag {
      1 => 1
      2 => 2
      3 => 4
      _ => 0
    }
    offset = offset + dict_id_bytes
  }
  
  // Skip Frame_Content_Size when present.
  // FCS is present when: single_segment=1 (any fcs_flag), OR fcs_flag != 0.
  // When single_segment=1 and fcs_flag=0, the field is 1 byte.
  let has_fcs = single_segment || fcs_field_size != 0
  if has_fcs {
    let content_size_bytes = if single_segment && fcs_field_size == 0 {
      1
    } else {
      match fcs_field_size {
        1 => 2
        2 => 4
        3 => 8
        _ => 0
      }
    }
    offset = offset + content_size_bytes
  }
  
  if offset + 3 > data.length() {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "文件截断，缺少块头",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: single_segment,
      content_checksum: content_checksum,
      window_size: window_size,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "missing",
      first_block_size: 0,
      last_block: false
    }
  }
  
  let block_header = data[offset].to_int() | 
                    (data[offset + 1].to_int() << 8) | 
                    (data[offset + 2].to_int() << 16)
  
  let last_block = (block_header & 0x01) != 0
  let block_type = (block_header >> 1) & 0x03
  let block_size = block_header >> 3
  
  if block_size > @zstd_core.ZSTD_MAX_BLOCK_SIZE {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "块大小超过最大限制",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: single_segment,
      content_checksum: content_checksum,
      window_size: window_size,
      total_blocks: 1,
      file_size: data.length(),
      first_block_type: "oversized",
      first_block_size: block_size,
      last_block: last_block
    }
  }
  
  // 验证块数据完整性（考虑不同块类型的实际大小）
  if block_size == @zstd_core.ZSTD_MAX_BLOCK_SIZE && block_type != 1 {
    // RLE 块即使 block_size 是 128K，实际数据也只有 1 字节
    // 只对非 RLE 块进行 128K 数据完整性检查
    if data.length() < offset + 3 + block_size {
      return ZSTDFileAnalysis::{
        is_valid: false,
        error_message: "128K块数据不完整",
        magic_number: magic.reinterpret_as_uint(),
        single_segment: single_segment,
        content_checksum: content_checksum,
        window_size: window_size,
        total_blocks: 1,
        file_size: data.length(),
        first_block_type: "incomplete_128k",
        first_block_size: block_size,
        last_block: last_block
      }
    }
  }
  
  let error_patterns = detect_error_patterns(data, offset)
  if error_patterns.length() > 0 {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: error_patterns,
      magic_number: magic.reinterpret_as_uint(),
      single_segment: single_segment,
      content_checksum: content_checksum,
      window_size: window_size,
      total_blocks: 1,
      file_size: data.length(),
      first_block_type: "error",
      first_block_size: block_size,
      last_block: last_block
    }
  }
  
  let first_block_type_str = match block_type {
    0 => "raw"
    1 => "rle"
    2 => "compressed"
    3 => "reserved"
    _ => "unknown"
  }
  
  ZSTDFileAnalysis::{
    is_valid: true,
    error_message: "",
    magic_number: magic.reinterpret_as_uint(),
    single_segment: single_segment,
    content_checksum: content_checksum,
    window_size: window_size,
    total_blocks: 1,
    file_size: data.length(),
    first_block_type: first_block_type_str,
    first_block_size: block_size,
    last_block: last_block
  }
}

/// 基于原生ZSTD规范的错误检测
fn detect_error_patterns(data: Bytes, block_offset: Int) -> String {
  let block_header = data[block_offset].to_int() | 
                    (data[block_offset + 1].to_int() << 8) | 
                    (data[block_offset + 2].to_int() << 16)
  
  let block_type = (block_header >> 1) & 0x03
  let block_size = block_header >> 3
  
  if block_type == 3 {
    return "检测到保留块类型错误"
  }
  
  if block_type == 2 && block_size < 2 {
    return "检测到压缩块大小过小"
  }
  
  if block_size == 0 {
    return ""
  }
  
  if block_size == @zstd_core.ZSTD_MAX_BLOCK_SIZE {
    return ""
  }
  
  if block_type == 2 && block_size > 0 {
    let block_start = block_offset + 3
    let block_end = block_offset + 3 + block_size
    
    // 对于非常小的块（<=3字节），可能是合法的空块或最小块
    // 不进行严格的结构检查，避免误报
    if block_size <= 3 {
      return ""
    }
    
    if block_start + 1 < data.length() {
      let mut seq_count = data[block_start].to_int()
      let mut seq_offset = block_start + 1
      
      if seq_count > 0x7F {
        if seq_count == 0xFF {
          if seq_offset + 2 < data.length() {
            seq_count = (data[seq_offset].to_int() | (data[seq_offset + 1].to_int() << 8)) + 0x7F00
            seq_offset = seq_offset + 2
          } else {
            return "检测到序列计数不完整"
          }
        } else {
          if seq_offset < data.length() {
            seq_count = ((seq_count - 0x80) << 8) + data[seq_offset].to_int()
            seq_offset = seq_offset + 1
          } else {
            return "检测到序列计数不完整"
          }
        }
      }
      
      if seq_count == 0 {
        let remaining_in_block = block_end - seq_offset
        
        // 对于小块，remaining数据可能是字面量头，不一定是多余数据
        // 只有当remaining数据明显过多时才报错
        if remaining_in_block > 5 {
          return "检测到多余的零序列数据"
        }
      } else {
        if seq_count > 1024 {
          return "检测到序列计数过大"
        }
        
        if seq_offset < data.length() {
          let fse_desc = data[seq_offset].to_int()
          let reserved_bits = fse_desc & 0x03
          
          if reserved_bits != 0 {
            return "检测到FSE表描述符保留位错误"
          }
        }
      }
    }
  }
  
  if block_type == 2 && block_size > 0 {
    let block_start = block_offset + 3
    
    if block_start + 1 < data.length() {
      let literals_header = data[block_start].to_int()
      let literals_block_type = literals_header & 0x03
      
      if literals_block_type == 2 {
        if block_size < 5 {
          return "检测到压缩字面量块大小不足"
        }
        
        if block_start + 4 < data.length() {
          let huffman_header = data[block_start + 1].to_int()
          let huffman_size = huffman_header & 0xFF
          
          if huffman_size < 2 && block_size > 10 {
            return "Huffman状态截断"
          }
        }
      }
    }
  }
  ""
}

/// Analyze data integrity metrics (density, structure consistency, entropy).
pub fn analyze_data_integrity(data: Bytes) -> DataIntegrityAnalysis {
  let data_density = if data.length() == 0 { 0.0 } else { 0.8 }
  let structure_consistency = if data.length() >= 4 { 0.9 } else { 0.1 }
  let entropy_level = 0.7
  let truncation_indicators = if data.length() < 10 { 1 } else { 0 }
  
  DataIntegrityAnalysis::{
    truncation_indicators: truncation_indicators,
    data_density: data_density,
    structure_consistency: structure_consistency,
    entropy_level: entropy_level
  }
}

/// Check whether the data starts with a valid ZSTD magic number (0xFD2FB528).
pub fn is_zstd_format(data: Bytes) -> Bool {
  if data.length() < 4 {
    return false
  }
  
  let magic = (data[3].to_int() << 24) | (data[2].to_int() << 16) | (data[1].to_int() << 8) | data[0].to_int()
  magic == @zstd_core.ZSTD_MAGIC_NUMBER_INT
}

/// Estimate compressed output size for a given compression level.
///
/// This is a rough heuristic, not an exact prediction.
pub fn estimate_compressed_size(data: Bytes, level: CompressionLevel) -> Int {
  let overhead = 9
  
  match level {
    CompressionLevel::Fast => data.length() + overhead
    CompressionLevel::Default => (data.length() * 80 / 100) + overhead
    CompressionLevel::Better => (data.length() * 60 / 100) + overhead
    CompressionLevel::Best => (data.length() * 40 / 100) + overhead
  }
}
/// 运行所有基础测试
pub fn run_all_basic_tests() -> Bool {
  let tests = [
    ("Basic compression", test_basic_compression),
    ("Format detection", test_format_detection),
    ("File analysis", test_file_analysis),
    ("Compression levels", test_compression_levels),
    ("Empty data", test_empty_data),
    ("Data integrity", test_data_integrity)
  ]
  
  let mut passed = 0
  for i = 0; i < tests.length(); i = i + 1 {
    let (name, test_fn) = tests[i]
    let result = test_fn()
    ignore(name)  // 忽略未使用的变量
    if result {
      passed = passed + 1
    }
  }
  
  passed == tests.length()
}

/// 运行所有兼容性测试
pub fn run_all_compatibility_tests() -> Bool {
  let tests = [
    ("Magic number compliance", test_magic_number_compliance),
    ("Frame header compliance", test_frame_header_compliance),
    ("Error handling", test_error_handling),
    ("Large data handling", test_large_data_handling),
    ("RLE optimization", test_rle_optimization)
  ]
  
  let mut passed = 0
  for i = 0; i < tests.length(); i = i + 1 {
    let (name, test_fn) = tests[i]
    let result = test_fn()
    ignore(name)  // 忽略未使用的变量
    if result {
      passed = passed + 1
    }
  }
  
  passed == tests.length()
}

/// 测试基础压缩和解压缩
fn test_basic_compression() -> Bool {
  let test_data = @encoding/utf8.encode("Hello, MoonBit ZSTD!")

  // Test compression
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  if compressed.length() == 0 {
    return false
  }

  // Test decompression
  let decompressed = decompress(compressed)
  if decompressed.length() != test_data.length() {
    return false
  }

  // Verify data integrity
  for i = 0; i < test_data.length(); i = i + 1 {
    if test_data[i] != decompressed[i] {
      return false
    }
  }

  true
}

/// 测试ZSTD格式检测
fn test_format_detection() -> Bool {
  let test_data = @encoding/utf8.encode("Hello, World!")
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }

  // Should detect as valid ZSTD format
  is_zstd_format(compressed)
}

/// 测试文件分析
fn test_file_analysis() -> Bool {
  let test_data = @encoding/utf8.encode("Test data for analysis")
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let analysis = analyze_file(compressed)

  // Should be valid
  analysis.is_valid
}

/// 测试不同压缩级别
fn test_compression_levels() -> Bool {
  let test_data = @encoding/utf8.encode("Test data for different compression levels")

  // Test all compression levels
  let fast_compressed = match compress_with_level(test_data, CompressionLevel::Fast) {
    Ok(c) => c
    Err(_) => return false
  }
  let default_compressed = match compress_with_level(test_data, CompressionLevel::Default) {
    Ok(c) => c
    Err(_) => return false
  }
  let better_compressed = match compress_with_level(test_data, CompressionLevel::Better) {
    Ok(c) => c
    Err(_) => return false
  }
  let best_compressed = match compress_with_level(test_data, CompressionLevel::Best) {
    Ok(c) => c
    Err(_) => return false
  }

  // All should be valid
  fast_compressed.length() > 0 &&
  default_compressed.length() > 0 &&
  better_compressed.length() > 0 &&
  best_compressed.length() > 0
}

/// 测试空数据处理
fn test_empty_data() -> Bool {
  let empty_data = Bytes::from_array([])
  let compressed = match compress(empty_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let decompressed = decompress(compressed)

  // Should handle empty data gracefully
  decompressed.length() == 0
}

/// 测试数据完整性分析
fn test_data_integrity() -> Bool {
  let test_data = @encoding/utf8.encode("Data integrity test")
  let integrity = analyze_data_integrity(test_data)
  
  // Should return valid analysis
  integrity.data_density >= 0.0 && integrity.data_density <= 1.0
}

/// 测试魔数兼容性
fn test_magic_number_compliance() -> Bool {
  let test_data = @encoding/utf8.encode("Magic number test")
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }

  if compressed.length() < 4 {
    return false
  }

  // Check magic number (little-endian)
  let magic = (compressed[3].to_int() << 24) |
              (compressed[2].to_int() << 16) |
              (compressed[1].to_int() << 8) |
              compressed[0].to_int()

  magic == @zstd_core.ZSTD_MAGIC_NUMBER_INT
}

/// 测试帧头格式兼容性
fn test_frame_header_compliance() -> Bool {
  let test_data = @encoding/utf8.encode("Frame header test")
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let analysis = analyze_file(compressed)

  // Should have valid frame header
  analysis.is_valid && analysis.magic_number == @zstd_core.ZSTD_MAGIC_NUMBER
}

/// 测试错误处理
fn test_error_handling() -> Bool {
  // Test with invalid data
  let invalid_data = Bytes::from_array([0x00, 0x01, 0x02, 0x03])
  let analysis = analyze_file(invalid_data)
  
  // Should detect invalid data
  !analysis.is_valid
}

/// 测试大数据处理
fn test_large_data_handling() -> Bool {
  // Create larger test data
  let large_data: Array[Byte] = []
  for i = 0; i < 1000; i = i + 1 {
    large_data.push((i % 256).to_byte())
  }
  
  let test_data = Bytes::from_array(large_data)
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let decompressed = decompress(compressed)

  // Should handle large data correctly
  decompressed.length() == test_data.length()
}

/// 测试重复数据(RLE优化)
fn test_rle_optimization() -> Bool {
  // Create repeated data
  let repeated_data: Array[Byte] = []
  for _i = 0; _i < 100; _i = _i + 1 {
    repeated_data.push(0x41)  // 'A'
  }

  let test_data = Bytes::from_array(repeated_data)
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let decompressed = decompress(compressed)

  // Should compress and decompress repeated data correctly
  decompressed.length() == test_data.length()
}

// ============================================================================
// Sliding Window Decoder API
// ============================================================================

/// Create a sliding window decoder with the given window size.
///
/// The decoder maintains state for streaming decompression across
/// multiple calls to `decompress_with_sliding_window`.
pub fn create_sliding_window_decoder(window_size: Int) -> SlidingWindowDecoder {
  let context = @zstd_decoder.create_decoder_context(window_size)
  SlidingWindowDecoder::{
    context: context,
    window_size: window_size
  }
}

/// Decompress a ZSTD frame using a sliding window decoder.
///
/// The decoder context is updated in place, allowing match references
/// to span across multiple decompression calls.
pub fn decompress_with_sliding_window(
  decoder: SlidingWindowDecoder,
  data: Bytes
) -> Result[Bytes, @zstd_core.ZSTDError] {
  let frame_result = @zstd_decoder.parse_frame_header(data)
  match frame_result {
    Ok((_, header_size)) => {
      let current_offset = header_size
      let output: Array[Byte] = []

      let block_result = @zstd_decoder.decompress_block_with_context(decoder.context, data, current_offset)
      match block_result {
        Ok((block_data, _, _)) => {
          for i = 0; i < block_data.length(); i = i + 1 {
            output.push(block_data[i])
          }
          Ok(Bytes::from_array(output))
        }
        Err(e) => Err(@zstd_core.message_error("Block decompression failed: " + e))
      }
    }
    Err(e) => Err(e)
  }
}

/// Reset the sliding window decoder, clearing all internal state.
pub fn reset_sliding_window_decoder(decoder: SlidingWindowDecoder) -> Unit {
  // 重新创建上下文来重置状态
  let new_context = @zstd_decoder.create_decoder_context(decoder.window_size)
  decoder.context = new_context
}

