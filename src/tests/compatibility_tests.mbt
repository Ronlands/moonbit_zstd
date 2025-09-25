/// Compatibility tests for ZSTD implementation
/// Tests compatibility with RFC 8878 specification

// Import functions from the API module

/// Test frame header format
pub fn test_frame_header_format() -> Bool {
  let original = "Test data".to_bytes()
  let compressed = @zstd.compress(original)
  
  // Check magic number
  if compressed.length() < 4 {
    return false
  }
  
  let magic = (compressed[0].to_int() << 24).lor(
              (compressed[1].to_int() << 16)).lor(
              (compressed[2].to_int() << 8)).lor(
              compressed[3].to_int())
  
  magic == 0x2D_52_28_B5
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
    let compressed = @zstd.compress(original)
    let decompressed = @zstd.decompress(compressed)
    
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
    let compressed = @zstd.compress(original)
    let decompressed = @zstd.decompress(compressed)
    
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
    let compressed = @zstd.compress(original)
    let decompressed = @zstd.decompress(compressed)
    
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
  let compressed = @zstd.compress(original)
  
  // Compressed size should be significantly smaller
  compressed.length() < original.length()
}

/// Run all compatibility tests
pub fn run_compatibility_tests() -> Bool {
  let tests = [
    test_frame_header_format,
    test_round_trip,
    test_data_patterns,
    test_edge_cases,
    test_compression_efficiency
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

