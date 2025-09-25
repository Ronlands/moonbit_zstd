/// Main program entry point for Moonbit ZSTD
/// Demonstrates the library functionality

import moonbit_zstd::{compress, decompress, get_compression_ratio, is_zstd_data}
import examples::basic_usage::{run_examples}
import examples::streaming_usage::{run_streaming_examples}
import tests::basic_tests::{run_basic_tests}
import tests::compatibility_tests::{run_compatibility_tests}

/// Main function
pub fn main() -> Unit {
  println("=== Moonbit ZSTD Library Demo ===")
  println("A pure Moonbit implementation of Zstandard compression")
  println("Following RFC 8878 specification")
  println("")
  
  // Run basic examples
  println("Running basic examples...")
  run_examples()
  
  println("\n" + "=".repeat(50))
  
  // Run streaming examples
  println("Running streaming examples...")
  run_streaming_examples()
  
  println("\n" + "=".repeat(50))
  
  // Run tests
  println("Running tests...")
  let basic_tests_passed = run_basic_tests()
  let compatibility_tests_passed = run_compatibility_tests()
  
  println("\n" + "=".repeat(50))
  println("Test Results:")
  println("Basic tests: " + (if basic_tests_passed { "PASSED" } else { "FAILED" }))
  println("Compatibility tests: " + (if compatibility_tests_passed { "PASSED" } else { "FAILED" }))
  
  if basic_tests_passed && compatibility_tests_passed {
    println("\n✅ All tests passed! ZSTD library is working correctly.")
  } else {
    println("\n❌ Some tests failed. Please check the implementation.")
  }
  
  println("\n=== Demo Complete ===")
}

/// Quick compression demo
pub fn quick_demo() -> Unit {
  println("=== Quick ZSTD Demo ===")
  
  let original = "Hello, World! This is ZSTD compression in Moonbit!".to_bytes()
  println("Original: " + original.to_string())
  println("Size: " + original.length().to_string() + " bytes")
  
  let compressed = compress(original)
  println("Compressed: " + compressed.length().to_string() + " bytes")
  
  let ratio = get_compression_ratio(original.length(), compressed.length())
  println("Compression ratio: " + ratio.to_string() + "%")
  
  let decompressed = decompress(compressed)
  println("Decompressed: " + decompressed.to_string())
  println("Round-trip successful: " + (original == decompressed).to_string())
}