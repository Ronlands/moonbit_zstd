/// Basic usage examples for Moonbit ZSTD
/// Demonstrates simple compression and decompression

// Using functions from the API module

/// Example 1: Basic compression and decompression
pub fn example_basic_compression() -> Unit {
  println("=== Basic Compression Example ===")
  
  let original_text = "Hello, World! This is a test of ZSTD compression."
  let original_data = original_text.to_bytes()
  
  println("Original data: " + original_text)
  println("Original size: " + original_data.length().to_string() + " bytes")
  
  // Compress the data
  let compressed_data = @zstd.compress(original_data)
  println("Compressed size: " + compressed_data.length().to_string() + " bytes")
  
  // Calculate compression ratio
  let ratio = @zstd.get_compression_ratio(original_data.length(), compressed_data.length())
  println("Compression ratio: " + ratio.to_string() + "%")
  
  // Decompress the data
  let decompressed_data = @zstd.decompress(compressed_data)
  let decompressed_text = decompressed_data.to_string()
  
  println("Decompressed data: " + decompressed_text)
  println("Round-trip successful: " + (original_data == decompressed_data).to_string())
}

/// Example 2: Compressing different types of data
pub fn example_data_types() -> Unit {
  println("\n=== Data Types Example ===")
  
  let test_cases = [
    ("Text", "The quick brown fox jumps over the lazy dog"),
    ("Numbers", "1234567890"),
    ("Repeated", "AAAAA"),
    ("Mixed", "Hello123!@#"),
    ("Empty", "")
  ]
  
  for i = 0; i < test_cases.length(); i = i + 1 {
    let (name, data) = test_cases[i]
    let original = data.to_bytes()
    let compressed = @zstd.compress(original)
    let decompressed = @zstd.decompress(compressed)
    let ratio = @zstd.get_compression_ratio(original.length(), compressed.length())
    
    println(name + ": " + original.length().to_string() + " -> " + 
            compressed.length().to_string() + " bytes (" + 
            ratio.to_string() + "%)")
    
    // Verify round-trip
    if original != decompressed {
      println("ERROR: Round-trip failed for " + name)
    }
  }
}

/// Example 3: Performance demonstration
pub fn example_performance() -> Unit {
  println("\n=== Performance Example ===")
  
  // Create a larger dataset
  let mut data_array : Array[Byte] = []
  for i = 0; i < 1000; i = i + 1 {
    data_array = data_array + [(i % 256).to_byte()]
  }
  let large_data = Bytes::from_array(data_array)
  
  println("Large data size: " + large_data.length().to_string() + " bytes")
  
  // Compress
  let compressed = @zstd.compress(large_data)
  println("Compressed size: " + compressed.length().to_string() + " bytes")
  
  let ratio = @zstd.get_compression_ratio(large_data.length(), compressed.length())
  println("Compression ratio: " + ratio.to_string() + "%")
  
  // Decompress
  let decompressed = @zstd.decompress(compressed)
  println("Decompression successful: " + (large_data == decompressed).to_string())
}

/// Run all examples
pub fn run_examples() -> Unit {
  example_basic_compression()
  example_data_types()
  example_performance()
}

