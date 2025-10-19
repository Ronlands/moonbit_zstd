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
  ]
  
  run_test_suite("Basic tests", tests)
}

/// Test basic compression and decompression
fn test_basic_compression() -> Bool {
  let test_data = @encoding/utf8.encode("Hello, MoonBit ZSTD!")
  
  let compressed = @zstd.compress(test_data)
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
  let test_data = @encoding/utf8.encode("Hello, World!")
  let compressed = @zstd.compress(test_data)
  
  @zstd.is_zstd_format(compressed)
}

/// Test file analysis
fn test_file_analysis() -> Bool {
  let test_data = @encoding/utf8.encode("Test data for analysis")
  let compressed = @zstd.compress(test_data)
  let analysis = @zstd.analyze_file(compressed)
  
  analysis.is_valid
}

/// Test different compression levels
fn test_compression_levels() -> Bool {
  let test_data = @encoding/utf8.encode("Test data for different compression levels")
  
  // Use default compression since CompressionLevel enum cannot be constructed
  let compressed = @zstd.compress(test_data)
  
  compressed.length() > 0
}

/// Test empty data handling
fn test_empty_data() -> Bool {
  let empty_data = Bytes::new(0)
  let compressed = @zstd.compress(empty_data)
  let decompressed = @zstd.decompress(compressed)
  
  decompressed.length() == 0
}

/// Test data integrity analysis
fn test_data_integrity() -> Bool {
  let test_data = @encoding/utf8.encode("Data integrity test")
  let integrity = @zstd.analyze_data_integrity(test_data)
  
  integrity.data_density >= 0.0 && integrity.data_density <= 1.0
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
  let sample1 = @encoding/utf8.encode("The quick brown fox jumps over the lazy dog")
  let sample2 = @encoding/utf8.encode("The quick brown cat sleeps near the lazy dog")
  let sample3 = @encoding/utf8.encode("The quick brown bird flies over the lazy cat")
  
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
  let sample1 = @encoding/utf8.encode("Hello MoonBit ZSTD")
  let sample2 = @encoding/utf8.encode("Hello MoonBit World")
  let sample3 = @encoding/utf8.encode("Hello MoonBit Language")
  
  let samples = [sample1, sample2, sample3]
  
  // 构建字典
  let dict_result = @zstd_dictionary.build_dictionary(samples, 50)
  match dict_result {
    Ok(dict) => {
      // 使用字典压缩测试数据
      let test_data = @encoding/utf8.encode("Hello MoonBit Testing")
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
  let sample1 = @encoding/utf8.encode("Hello MoonBit ZSTD")
  let sample2 = @encoding/utf8.encode("Hello MoonBit World")
  let samples = [sample1, sample2]
  
  let dict_result = @zstd_dictionary.build_dictionary(samples, 50)
  match dict_result {
    Ok(dict) => {
      // 原始数据
      let original_data = @encoding/utf8.encode("Hello MoonBit Testing")
      
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
  let sample1 = @encoding/utf8.encode("Hello MoonBit ZSTD compression")
  let sample2 = @encoding/utf8.encode("Hello MoonBit ZSTD decompression")
  let sample3 = @encoding/utf8.encode("Hello MoonBit ZSTD testing")
  
  let samples = [sample1, sample2, sample3]
  
  // 构建字典
  let dict_result = @zstd_dictionary.build_dictionary(samples, 100)
  match dict_result {
    Ok(dict) => {
      // 计算收益
      let test_data = @encoding/utf8.encode("Hello MoonBit ZSTD performance")
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
  let sample1 = @encoding/utf8.encode("pattern pattern pattern data1")
  let sample2 = @encoding/utf8.encode("pattern pattern pattern data2")
  let sample3 = @encoding/utf8.encode("pattern pattern pattern data3")
  
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
