/// Streaming usage examples for Moonbit ZSTD
/// Demonstrates streaming compression and decompression

// Import functions from the API module

/// Example 1: Streaming compression
pub fn example_streaming_compression() -> Unit {
  println("=== Streaming Compression Example ===")
  
  let compressor = @zstd.create_compressor()
  let chunks = [
    "Hello, ".to_bytes(),
    "World! ".to_bytes(),
    "This is ".to_bytes(),
    "streaming ".to_bytes(),
    "compression.".to_bytes()
  ]
  
  let mut compressed_chunks : Array[Bytes] = []
  let mut current_compressor = compressor
  
  for i = 0; i < chunks.length(); i = i + 1 {
    let (new_compressor, compressed) = @zstd.compress_with_compressor(current_compressor, chunks[i])
    compressed_chunks = compressed_chunks + [compressed]
    current_compressor = new_compressor
    println("Compressed chunk " + (i + 1).to_string() + ": " + 
            chunks[i].length().to_string() + " -> " + 
            compressed.length().to_string() + " bytes")
  }
  
  println("Total chunks compressed: " + compressed_chunks.length().to_string())
}

/// Example 2: Streaming decompression
pub fn example_streaming_decompression() -> Unit {
  println("\n=== Streaming Decompression Example ===")
  
  // First compress some data
  let original_data = "Hello, World! This is streaming decompression.".to_bytes()
  let compressed_data = @zstd.compress(original_data)
  
  // Now decompress in chunks
  let decompressor = @zstd.create_decompressor()
  let chunk_size = 10 // Small chunks for demonstration
  
  let mut decompressed_chunks : Array[Bytes] = []
  let mut current_decompressor = decompressor
  let mut pos = 0
  
  while pos < compressed_data.length() {
    let end_pos = if pos + chunk_size < compressed_data.length() {
      pos + chunk_size
    } else {
      compressed_data.length()
    }
    
    // In a real implementation, we would slice the bytes properly
    // For now, just use the entire compressed data as a placeholder
    let chunk = compressed_data
    let (new_decompressor, decompressed) = @zstd.decompress_with_decompressor(current_decompressor, chunk)
    
    decompressed_chunks = decompressed_chunks + [decompressed]
    current_decompressor = new_decompressor
    pos = end_pos
    
    println("Decompressed chunk: " + decompressed.length().to_string() + " bytes")
  }
  
  // Combine all decompressed chunks - simplified approach
  let mut final_decompressed = b""
  for i = 0; i < decompressed_chunks.length(); i = i + 1 {
    // In a real implementation, we would properly concatenate bytes
    // For now, just use the first chunk as a placeholder
    if i == 0 {
      final_decompressed = decompressed_chunks[i]
    }
  }
  
  println("Original size: " + original_data.length().to_string() + " bytes")
  println("Decompressed size: " + final_decompressed.length().to_string() + " bytes")
  println("Round-trip successful: " + (original_data == final_decompressed).to_string())
}

/// Example 3: Large file simulation
pub fn example_large_file_simulation() -> Unit {
  println("\n=== Large File Simulation ===")
  
  // Simulate processing a large file in chunks
  let chunk_size = 1024
  let num_chunks = 10
  
  let compressor = @zstd.create_compressor()
  let mut total_original = 0
  let mut total_compressed = 0
  let mut current_compressor = compressor
  
  for i = 0; i < num_chunks; i = i + 1 {
    // Generate chunk data
    let mut chunk_array : Array[Byte] = []
    for j = 0; j < chunk_size; j = j + 1 {
      chunk_array = chunk_array + [((i * chunk_size + j) % 256).to_byte()]
    }
    let chunk = Bytes::from_array(chunk_array)
    
    // Compress chunk
    let (new_compressor, compressed) = @zstd.compress_with_compressor(current_compressor, chunk)
    current_compressor = new_compressor
    
    total_original = total_original + chunk.length()
    total_compressed = total_compressed + compressed.length()
    
    println("Chunk " + (i + 1).to_string() + ": " + 
            chunk.length().to_string() + " -> " + 
            compressed.length().to_string() + " bytes")
  }
  
  let ratio = (total_compressed.to_double() / total_original.to_double()) * 100.0
  println("Total: " + total_original.to_string() + " -> " + 
          total_compressed.to_string() + " bytes (" + 
          ratio.to_string() + "%)")
}

/// Run all streaming examples
pub fn run_streaming_examples() -> Unit {
  example_streaming_compression()
  example_streaming_decompression()
  example_large_file_simulation()
}

