/// Basic tests for ZSTD implementation
/// Tests compression and decompression functionality

import api::zstd

/// Test basic compression and decompression
pub fn test_basic_compression() -> Bool {
  let original = "Hello, World!".to_bytes()
  let compressed = zstd::compress(original)
  let decompressed = zstd::decompress(compressed)
  
  // Check that decompressed data matches original
  original == decompressed
}

/// Test compression ratio
pub fn test_compression_ratio() -> Bool {
  let original = "Hello, World!".to_bytes()
  let compressed = zstd::compress(original)
  let ratio = zstd::get_compression_ratio(original.length(), compressed.length())
  
  // Compression ratio should be reasonable (not negative)
  ratio >= 0.0
}

/// Test ZSTD data detection
pub fn test_zstd_detection() -> Bool {
  let original = "Hello, World!".to_bytes()
  let compressed = zstd::compress(original)
  
  // Compressed data should be detected as ZSTD
  zstd::is_zstd_data(compressed)
}

/// Test with empty data
pub fn test_empty_data() -> Bool {
  let original = b""
  let compressed = zstd::compress(original)
  let decompressed = zstd::decompress(compressed)
  
  original == decompressed
}

/// Test with repeated data (should compress well)
pub fn test_repeated_data() -> Bool {
  let original = "AAAAA".to_bytes()
  let compressed = zstd::compress(original)
  let decompressed = zstd::decompress(compressed)
  
  original == decompressed
}

/// Test with large data
pub fn test_large_data() -> Bool {
  let mut data_array : Array[Byte] = []
  for i = 0; i < 1000; i = i + 1 {
    data_array = data_array + [(i % 256).to_byte()]
  }
  let original = Bytes::from_array(data_array)
  
  let compressed = zstd::compress(original)
  let decompressed = zstd::decompress(compressed)
  
  original == decompressed
}

/// Run all basic tests
pub fn run_basic_tests() -> Bool {
  let tests = [
    test_basic_compression,
    test_compression_ratio,
    test_zstd_detection,
    test_empty_data,
    test_repeated_data,
    test_large_data
  ]
  
  let mut passed = 0
  let mut failed = 0
  
  for i = 0; i < tests.length(); i = i + 1 {
    if tests[i]() {
      passed = passed + 1
    } else {
      failed = failed + 1
    }
  }
  
  println("Basic tests: " + passed.to_string() + " passed, " + failed.to_string() + " failed")
  failed == 0
}

