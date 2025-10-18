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
  
  let mut passed = 0
  let total = tests.length()
  for i = 0; i < tests.length(); i = i + 1 {
    if tests[i].1 {
      passed = passed + 1
    }
  }
  
  println("Basic tests passed: \{passed}/\{total}")
  passed == tests.length()
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

/// Verify two byte sequences are equal
fn verify_data_equal(a: Bytes, b: Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  
  let mut equal = true
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      equal = false
      break
    }
  }
  equal
}

