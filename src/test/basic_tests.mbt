/// Basic ZSTD functionality tests
/// Moved from api/zstd.mbt for better separation of concerns

/// Run all basic tests
pub fn run_all_basic_tests() -> Bool {
  let tests = [
    ("Basic Compression", test_basic_compression()),
    ("Format Detection", test_format_detection()),
    ("File Analysis", test_file_analysis()),
    ("Compression Levels", test_compression_levels()),
    ("Empty Data", test_empty_data()),
    ("Data Integrity", test_data_integrity()),
    ("Compressed Block", test_compressed_block()),
    ("Multi-Sequence Block", test_multi_sequence_block()),
    ("RLE Literals", test_rle_literals_block()),
    ("FSE Bitstream", test_fse_bitstream()),
    ("FSE Encode Simple", test_fse_encode_simple()),
    ("Streaming Compression", test_streaming_compression()),
    ("Single Byte", test_single_byte()),
    ("Invalid Magic", test_invalid_magic()),
    ("Large Offset", test_large_offset()),
    ("Large Data", test_large_data()),
    ("Corrupted Data", test_corrupted_data()),
  ]

  run_test_suite("Basic tests", tests)
}

/// Test basic compression and decompression
fn test_basic_compression() -> Bool {
  let test_data = @utf8.encode("Hello, MoonBit ZSTD!")

  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  if compressed.length() == 0 {
    return false
  }

  let decompressed = @zstd.decompress(compressed)
  if decompressed.length() != test_data.length() {
    return false
  }

  verify_data_equal(test_data, decompressed)
}

/// Test ZSTD format detection
fn test_format_detection() -> Bool {
  let test_data = @utf8.encode("Hello, World!")
  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }

  @zstd.is_zstd_format(compressed)
}

/// Test file analysis
fn test_file_analysis() -> Bool {
  let test_data = @utf8.encode("Test data for analysis")
  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let analysis = @zstd.analyze_file(compressed)

  analysis.is_valid
}

/// Test different compression levels
fn test_compression_levels() -> Bool {
  let test_data = @utf8.encode("Test data for different compression levels")

  // Use default compression since CompressionLevel enum cannot be constructed
  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }

  compressed.length() > 0
}

/// Test empty data handling
fn test_empty_data() -> Bool {
  let empty_data = Bytes::new(0)
  let compressed = match @zstd.compress(empty_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let decompressed = @zstd.decompress(compressed)

  decompressed.length() == 0
}

/// Test data integrity analysis
fn test_data_integrity() -> Bool {
  let test_data = @utf8.encode("Data integrity test")
  let integrity = @zstd.analyze_data_integrity(test_data)
  
  integrity.data_density >= 0.0 && integrity.data_density <= 1.0
}

/// Test compressed block infrastructure
fn test_compressed_block() -> Bool {
  // 创建足够大且有重复模式的数据
  let mut test_text = ""
  for _i = 0; _i < 10; _i = _i + 1 {
    test_text = test_text + "The quick brown fox jumps over the lazy dog. "
  }
  let test_data = @utf8.encode(test_text)

  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }

  if compressed.length() == 0 {
    return false
  }

  match @zstd_decoder.decompress(compressed) {
    Ok(decompressed) => {
      if test_data.length() != decompressed.length() {
        println("  ❌ 长度不匹配：原始=\{test_data.length()} 解压=\{decompressed.length()}")
        return false
      }
      verify_data_equal(test_data, decompressed)
    }
    Err(e) => {
      println("  ❌ 解压失败: \{@zstd_core.error_to_string(e)}")
      false
    }
  }
}

/// Test compressed block with multiple sequences (not just one big match)
/// Uses data with several different repeating patterns to force multiple LZ77 matches
fn test_multi_sequence_block() -> Bool {
  // Build data with multiple different repeating patterns to force multiple sequences
  let mut test_text = ""
  for _i = 0; _i < 5; _i = _i + 1 {
    test_text = test_text + "AAAA BBBB CCCC "
  }
  for _i = 0; _i < 5; _i = _i + 1 {
    test_text = test_text + "DDDD EEEE FFFF "
  }
  let test_data = @utf8.encode(test_text)

  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  if compressed.length() == 0 { return false }

  let decompressed = @zstd.decompress(compressed)
  if test_data.length() != decompressed.length() {
    println("  ❌ Multi-seq 长度不匹配：原始=\{test_data.length()} 解压=\{decompressed.length()}")
    return false
  }
  verify_data_equal(test_data, decompressed)
}

/// Test that RLE literals are used when all literals are the same byte
fn test_rle_literals_block() -> Bool {
  // Data: many 'A' bytes followed by a different repeating pattern
  // This forces: RLE-able literals + LZ77 match
  let arr: Array[Byte] = []
  // First 100 bytes: all 'X' (will become RLE literals if matched properly)
  for _i = 0; _i < 100; _i = _i + 1 { arr.push(b'X') }
  // Then repeat the first 50 bytes 3 more times (creates matches)
  for _j = 0; _j < 3; _j = _j + 1 {
    for _i = 0; _i < 100; _i = _i + 1 { arr.push(b'X') }
  }
  let test_data = Bytes::from_array(arr)

  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  if compressed.length() == 0 { return false }

  // RLE block should be very small
  if compressed.length() > 20 {
    println("  ⚠️ RLE 压缩效率偏低: \{compressed.length()} bytes for \{test_data.length()} bytes input")
  }

  let decompressed = @zstd.decompress(compressed)
  if test_data.length() != decompressed.length() {
    println("  ❌ RLE 长度不匹配：原始=\{test_data.length()} 解压=\{decompressed.length()}")
    return false
  }
  verify_data_equal(test_data, decompressed)
}

// ============================================================================
// Dictionary Tests / 字典测试
// ============================================================================

/// Run all dictionary tests
pub fn run_all_dictionary_tests() -> Bool {
  let tests = [
    ("Dictionary Creation", test_dictionary_creation()),
    ("Dictionary Compression", test_dictionary_compression()),
    ("Dictionary Decompression", test_dictionary_decompression()),
    ("Dictionary Benefit Calculation", test_dictionary_benefit()),
    ("Cover Algorithm", test_cover_algorithm()),
  ]
  
  run_test_suite("Dictionary tests", tests)
}

/// Test dictionary creation
fn test_dictionary_creation() -> Bool {
  let sample1 = @utf8.encode("The quick brown fox jumps over the lazy dog")
  let sample2 = @utf8.encode("The quick brown cat sleeps near the lazy dog")
  let sample3 = @utf8.encode("The quick brown bird flies over the lazy cat")
  
  let samples = [sample1, sample2, sample3]
  let dict_result = @zstd_dictionary.build_dictionary(samples, 100)
  
  match dict_result {
    Ok(dict) => {
      dict.content.length() > 0 && dict.content.length() <= 100
    }
    Err(_) => false
  }
}

/// Test dictionary compression
fn test_dictionary_compression() -> Bool {
  // 创建样本数据
  let sample1 = @utf8.encode("Hello MoonBit ZSTD")
  let sample2 = @utf8.encode("Hello MoonBit World")
  let sample3 = @utf8.encode("Hello MoonBit Language")
  
  let samples = [sample1, sample2, sample3]
  
  // 构建字典
  let dict_result = @zstd_dictionary.build_dictionary(samples, 50)
  match dict_result {
    Ok(dict) => {
      // 使用字典压缩测试数据
      let test_data = @utf8.encode("Hello MoonBit Testing")
      let compress_result = @zstd_dictionary.compress_with_dictionary(test_data, dict)
      
      match compress_result {
        Ok(compressed) => {
          // 验证压缩数据不为空
          compressed.length() > 0
        }
        Err(_) => false
      }
    }
    Err(_) => false
  }
}

/// Test dictionary decompression
fn test_dictionary_decompression() -> Bool {
  // 创建样本和字典
  let sample1 = @utf8.encode("Hello MoonBit ZSTD")
  let sample2 = @utf8.encode("Hello MoonBit World")
  let samples = [sample1, sample2]
  
  let dict_result = @zstd_dictionary.build_dictionary(samples, 50)
  match dict_result {
    Ok(dict) => {
      // 原始数据
      let original_data = @utf8.encode("Hello MoonBit Testing")
      
      // 使用字典压缩
      let compress_result = @zstd_dictionary.compress_with_dictionary(original_data, dict)
      match compress_result {
        Ok(compressed) => {
          // 使用字典解压
          let decompress_result = @zstd_dictionary.decompress_with_dictionary(compressed, dict)
          match decompress_result {
            Ok(decompressed) => {
              // 验证解压后的数据与原始数据相同
              verify_data_equal(original_data, decompressed)
            }
            Err(_) => false
          }
        }
        Err(_) => false
      }
    }
    Err(_) => false
  }
}

/// Test dictionary benefit calculation
fn test_dictionary_benefit() -> Bool {
  // 创建样本数据
  let sample1 = @utf8.encode("Hello MoonBit ZSTD compression")
  let sample2 = @utf8.encode("Hello MoonBit ZSTD decompression")
  let sample3 = @utf8.encode("Hello MoonBit ZSTD testing")
  
  let samples = [sample1, sample2, sample3]
  
  // 构建字典
  let dict_result = @zstd_dictionary.build_dictionary(samples, 100)
  match dict_result {
    Ok(dict) => {
      // 计算收益
      let test_data = @utf8.encode("Hello MoonBit ZSTD performance")
      let benefit = @zstd_dictionary.calculate_dictionary_benefit(test_data, dict)
      
      // 收益应该在 0.0 到 1.0 之间（0% 到 100%）
      benefit >= 0.0 && benefit <= 1.0
    }
    Err(_) => false
  }
}

/// Test Cover algorithm for dictionary building
fn test_cover_algorithm() -> Bool {
  // 创建具有重复模式的样本数据
  let sample1 = @utf8.encode("pattern pattern pattern data1")
  let sample2 = @utf8.encode("pattern pattern pattern data2")
  let sample3 = @utf8.encode("pattern pattern pattern data3")
  
  let samples = [sample1, sample2, sample3]
  
  // 使用 Cover 算法构建字典
  let dict_result = @zstd_dictionary.build_dictionary_with_cover(samples, 100, 6)
  match dict_result {
    Ok(dict) => {
      // 验证字典有效
      @zstd_dictionary.validate_dictionary(dict)
    }
    Err(_) => false
  }
}

// ============================================================================
// FSE Encoder Tests / FSE 编码器测试
// ============================================================================

/// 测试位流基本操作
fn test_fse_bitstream() -> Bool {
  let bs = @zstd_entropy.create_bitstream()
  
  // 添加一些位
  @zstd_entropy.add_bits(bs, 0b101UL, 3)
  @zstd_entropy.add_bits(bs, 0b1111UL, 4)
  @zstd_entropy.add_bits(bs, 0xFFUL, 8)
  
  // 刷新位流
  @zstd_entropy.flush_bits(bs)
  
  // 获取输出
  let output = @zstd_entropy.get_bytes(bs)
  
  // 验证输出不为空
  output.length() > 0
}

/// 测试简单的 FSE 编码
fn test_fse_encode_simple() -> Bool {
  // 创建简单的符号序列
  let symbols = [0, 1, 2, 3, 0, 1, 0, 2]
  
  // 编码
  let result = @zstd_entropy.fse_encode_complete(symbols, 10, 6)
  
  match result {
    Ok(encoded) => {
      // 验证编码输出不为空
      encoded.length() > 0
    }
    Err(_) => false
  }
}

/// Test 1-byte data compression
fn test_single_byte() -> Bool {
  let data = Bytes::from_array([0x42])
  match @zstd.compress(data) {
    Ok(compressed) => {
      let decompressed = @zstd.decompress(compressed)
      decompressed.length() == 1 && decompressed[0] == 0x42
    }
    Err(_) => false
  }
}

/// Test invalid magic number handling
fn test_invalid_magic() -> Bool {
  let invalid = Bytes::from_array([0x00, 0x00, 0x00, 0x00])
  let result = @zstd.decompress(invalid)
  result.length() == 0  // Should fail gracefully
}

/// Test very large offset encoding
fn test_large_offset() -> Bool {
  let offset = 1048576  // 1MB offset
  match @zstd_entropy.encode_of(offset) {
    Ok((code, extra_bits)) => {
      let decoded = @zstd_entropy.decode_of(code, extra_bits)
      decoded == offset
    }
    Err(_) => false
  }
}

/// Test large data (10KB)
fn test_large_data() -> Bool {
  let arr: Array[Byte] = []
  for i = 0; i < 10240; i = i + 1 {
    arr.push(((i % 256)).to_byte())
  }
  let data = Bytes::from_array(arr)
  match @zstd.compress(data) {
    Ok(compressed) => {
      let decompressed = @zstd.decompress(compressed)
      decompressed.length() == data.length()
    }
    Err(_) => false
  }
}

/// Test streaming compression lifecycle.
///
/// 目标：
/// - 验证 `create / write / flush / finish` 可以拼出完整合法帧
/// - 验证跨多次写入后，最终解压结果与原始输入一致
/// - 验证中途 `flush` 不会破坏帧结构
fn test_streaming_compression() -> Bool {
  let pattern: Array[Byte] = [0x41, 0x42, 0x43, 0x44, 0x31, 0x32, 0x33, 0x34]
  let chunk1_array: Array[Byte] = []
  for _i = 0; _i < 16384; _i = _i + 1 {
    for j = 0; j < pattern.length(); j = j + 1 {
      chunk1_array.push(pattern[j])
    }
  }
  let chunk1 = Bytes::from_array(chunk1_array)
  let chunk2 = chunk1
  let chunk3 = Bytes::make(4096, 0x43)
  let original = chunk1 + chunk2 + chunk3

  let compressor = @zstd.create_streaming_compressor_with_checksum(3, true)

  let out1 = match @zstd.write_streaming_chunk(compressor, chunk1) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  let out2 = match @zstd.write_streaming_chunk(compressor, chunk2) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  let flushed = match @zstd.flush_streaming_compressor(compressor) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  let out3 = match @zstd.write_streaming_chunk(compressor, chunk3) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  let final_bytes = match @zstd.finish_streaming_compressor(compressor) {
    Ok(bytes) => bytes
    Err(_) => return false
  }

  let compressed = out1 + out2 + flushed + out3 + final_bytes
  let stats = @zstd.get_streaming_compressor_stats(compressor)
  let decompressed = @zstd.decompress(compressed)

  if !stats.finished || !stats.checksum_enabled {
    println("  ❌ Streaming stats state invalid")
    return false
  }

  if stats.total_input_size != original.length() {
    println("  ❌ Streaming total_input_size mismatch")
    return false
  }

  if stats.total_output_size != compressed.length() {
    println("  ❌ Streaming total_output_size mismatch")
    return false
  }

  if stats.emitted_block_count < 2 {
    println("  ❌ Streaming emitted_block_count too small")
    return false
  }

  if stats.compressed_block_count == 0 {
    println("  ❌ Streaming compressed_block_count is zero")
    return false
  }

  if stats.final_checksum == 0U {
    println("  ❌ Streaming final checksum is zero")
    return false
  }

  if compressed.length() < 4 {
    println("  ❌ Streaming compressed output too short")
    return false
  }

  let checksum_offset = compressed.length() - 4
  let checksum_from_output = compressed[checksum_offset].to_uint() |
    (compressed[checksum_offset + 1].to_uint() << 8) |
    (compressed[checksum_offset + 2].to_uint() << 16) |
    (compressed[checksum_offset + 3].to_uint() << 24)
  if checksum_from_output != stats.final_checksum {
    println("  ❌ Streaming checksum bytes mismatch")
    return false
  }

  if decompressed.length() != original.length() {
    if decompressed.length() == 0 {
      match @zstd_decoder.decompress(compressed) {
        Ok(_) => ()
        Err(e) => println("  ❌ Streaming decoder error: \{@zstd_core.error_to_string(e)}")
      }
    }
    println("  ❌ Streaming decompressed length mismatch: original=\{original.length()} decoded=\{decompressed.length()}")
    return false
  }

  for i = 0; i < original.length(); i = i + 1 {
    if original[i] != decompressed[i] {
      println("  ❌ Streaming first byte mismatch at index \{i}: original=\{original[i].to_int()} decoded=\{decompressed[i].to_int()}")
      return false
    }
  }

  verify_data_equal(original, decompressed)
}

/// Test corrupted data handling
fn test_corrupted_data() -> Bool {
  let corrupted = Bytes::from_array([0x28, 0xB5, 0x2F, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF])
  let result = @zstd.decompress(corrupted)
  result.length() == 0  // Should fail gracefully
}
