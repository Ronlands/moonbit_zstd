/// Compatibility tests for ZSTD implementation
/// Tests compatibility with RFC 8878 specification

import api::zstd

/// Test frame header format
pub fn test_frame_header_format() -> Bool {
  let original = "Test data".to_bytes()
  let compressed = zstd::compress(original)
  
  // Check magic number
  if compressed.length() < 4 {
    return false
  }
  
  // Check ZSTD magic number (little-endian)
  let magic = (compressed[3].to_int() << 24) |
              (compressed[2].to_int() << 16) |
              (compressed[1].to_int() << 8) |
              compressed[0].to_int()
  
  magic == 0xFD2FB528
}

/// Test round-trip compression
pub fn test_round_trip() -> Bool {
  let test_cases = [
    "Hello, World!",
    "The quick brown fox jumps over the lazy dog",
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit",
    "ZSTD compression test data with various characters: !@#$%^&*()",
    ""
  ]
  
  let mut passed = 0
  for i = 0; i < test_cases.length(); i = i + 1 {
    let original = test_cases[i].to_bytes()
    let compressed = zstd::compress(original)
    let decompressed = zstd::decompress(compressed)
    
    if original == decompressed {
      passed = passed + 1
    }
  }
  
  passed == test_cases.length()
}

/// Test compression with different data patterns
pub fn test_data_patterns() -> Bool {
  let patterns = [
    "A".repeat(100), // Repeated character
    "AB".repeat(50), // Repeated pattern
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ", // Alphabet
    "0123456789", // Numbers
    "!@#$%^&*()_+-=[]{}|;':\",./<>?" // Special characters
  ]
  
  let mut passed = 0
  for i = 0; i < patterns.length(); i = i + 1 {
    let original = patterns[i].to_bytes()
    let compressed = zstd::compress(original)
    let decompressed = zstd::decompress(compressed)
    
    if original == decompressed {
      passed = passed + 1
    }
  }
  
  passed == patterns.length()
}

/// Test edge cases
pub fn test_edge_cases() -> Bool {
  let edge_cases = [
    b"", // Empty data
    b"\x00", // Single null byte
    b"\xFF", // Single 0xFF byte
    b"\x00\xFF\x00\xFF", // Alternating bytes
  ]
  
  let mut passed = 0
  for i = 0; i < edge_cases.length(); i = i + 1 {
    let original = edge_cases[i]
    let compressed = zstd::compress(original)
    let decompressed = zstd::decompress(compressed)
    
    if original == decompressed {
      passed = passed + 1
    }
  }
  
  passed == edge_cases.length()
}

/// Test compression efficiency
pub fn test_compression_efficiency() -> Bool {
  // Test with highly compressible data
  let original = "AAAAA".repeat(100).to_bytes()
  let compressed = zstd::compress(original)
  
  // Compressed size should be significantly smaller
  compressed.length() < original.length()
}

/// Test streaming functionality
pub fn test_streaming() -> Bool {
  let original = "This is a streaming test with multiple chunks of data.".to_bytes()
  
  let compressor = zstd::create_compressor()
  let (new_compressor, compressed) = zstd::compress_with_compressor(compressor, original)
  
  let decompressor = zstd::create_decompressor()  
  let (new_decompressor, decompressed) = zstd::decompress_with_decompressor(decompressor, compressed)
  
  original == decompressed
}

/// Test different data sizes
pub fn test_different_sizes() -> Bool {
  let test_sizes = [0, 1, 10, 100, 1000, 10000]
  let mut passed = 0
  
  for i = 0; i < test_sizes.length(); i = i + 1 {
    let size = test_sizes[i]
    let mut data : Array[Byte] = []
    
    for j = 0; j < size; j = j + 1 {
      data = data + [(j % 256).to_byte()]
    }
    
    let original = Bytes::from_array(data)
    let compressed = zstd::compress(original)
    let decompressed = zstd::decompress(compressed)
    
    if original == decompressed {
      passed = passed + 1
    }
  }
  
  passed == test_sizes.length()
}

/// Test binary data
pub fn test_binary_data() -> Bool {
  let mut binary_data : Array[Byte] = []
  for i = 0; i < 256; i = i + 1 {
    binary_data = binary_data + [i.to_byte()]
  }
  
  let original = Bytes::from_array(binary_data)
  let compressed = zstd::compress(original)
  let decompressed = zstd::decompress(compressed)
  
  original == decompressed
}

/// Run all compatibility tests
pub fn run_compatibility_tests() -> Bool {
  let tests = [
    test_frame_header_format,
    test_round_trip,
    test_data_patterns,
    test_edge_cases,
    test_compression_efficiency,
    test_streaming,
    test_different_sizes,
    test_binary_data
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
  
  println("Compatibility tests: " + passed.to_string() + " passed, " + failed.to_string() + " failed")
  failed == 0
}

