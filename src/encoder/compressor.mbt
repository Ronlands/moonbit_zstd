/// ZSTD compressor implementation
/// Provides compression functionality

import core::types::{CompressionParams, CompressionContext, Sequence}
import core::bitstream::{BitStream, new_bitstream}

/// ZSTD compressor
pub struct Compressor {
  context : CompressionContext
  params : CompressionParams
}

/// Create new compressor with default parameters
pub fn new_compressor() -> Compressor {
  let params = CompressionParams {
    level: 3
    window_log: 22
    hash_log: 20
    chain_log: 20
    search_log: 6
    min_match: 3
    target_length: 0
    strategy: 0
  }
  
  Compressor {
    context: CompressionContext {
      params: params
      hash_table: Array::new()
      chain_table: Array::new()
    }
    params: params
  }
}

/// Create compressor with custom parameters
pub fn new_compressor_with_params(params : CompressionParams) -> Compressor {
  Compressor {
    context: CompressionContext {
      params: params
      hash_table: Array::new()
      chain_table: Array::new()
    }
    params: params
  }
}

/// Compress data
pub fn compress(data : Bytes) -> Bytes {
  let compressor = new_compressor()
  compress_with_context(compressor, data)
}

/// Compress data with context (for streaming)
pub fn compress_with_context(compressor : Compressor, data : Bytes) -> Bytes {
  // Generate frame header
  let frame_header = generate_frame_header(compressor.params, data.length())
  
  // Find sequences in data
  let sequences = find_sequences(data, compressor.params)
  
  // Generate literals
  let literals = extract_literals(data, sequences)
  
  // Build entropy tables
  let literal_frequencies = build_literal_frequencies(literals)
  let sequence_frequencies = build_sequence_frequencies(sequences)
  
  // Encode literals
  let encoded_literals = encode_literals(literals, literal_frequencies)
  
  // Encode sequences
  let encoded_sequences = encode_sequences(sequences, sequence_frequencies)
  
  // Build compressed blocks
  let blocks = build_compressed_blocks(encoded_literals, encoded_sequences)
  
  // Combine frame header and blocks
  let mut result = frame_header
  for i = 0; i < blocks.length(); i = i + 1 {
    result = result.append_all(blocks[i])
  }
  
  result
}

/// Generate frame header
fn generate_frame_header(params : CompressionParams, content_size : Int) -> Bytes {
  let mut header = Bytes::new()
  
  // Magic number
  header = header.append(0x28.to_byte())
  header = header.append(0xB5.to_byte())
  header = header.append(0x2F.to_byte())
  header = header.append(0xFD.to_byte())
  
  // Frame descriptor
  let single_segment = true // Simplified
  let checksum_flag = false
  let content_size_flag = if content_size > 0 { 1 } else { 0 }
  
  let descriptor = (if single_segment { 0x80 } else { 0x00 }) |
                   (if checksum_flag { 0x40 } else { 0x00 }) |
                   content_size_flag
  
  header = header.append(descriptor.to_byte())
  
  // Window descriptor (if not single segment)
  if not(single_segment) {
    let window_log = params.window_log
    let window_descriptor = ((window_log - 10) << 3) | 0x07
    header = header.append(window_descriptor.to_byte())
  }
  
  // Content size (if specified)
  if content_size_flag == 1 {
    header = header.append(content_size.to_byte())
  } else if content_size_flag == 2 {
    header = header.append((content_size >> 8).to_byte())
    header = header.append(content_size.to_byte())
  } else if content_size_flag == 3 {
    header = header.append((content_size >> 24).to_byte())
    header = header.append((content_size >> 16).to_byte())
    header = header.append((content_size >> 8).to_byte())
    header = header.append(content_size.to_byte())
  }
  
  header
}

/// Find sequences in data using LZ77-style matching
fn find_sequences(data : Bytes, params : CompressionParams) -> Array[Sequence] {
  let mut sequences = Array::new()
  let mut pos = 0
  
  while pos < data.length() {
    let (literal_length, match_length, offset) = find_best_match(data, pos, params)
    
    sequences = sequences.append(Sequence {
      literal_length: literal_length
      match_length: match_length
      offset: offset
    })
    
    pos = pos + literal_length + match_length
  }
  
  sequences
}

/// Find best match at current position
fn find_best_match(data : Bytes, pos : Int, params : CompressionParams) -> (Int, Int, Int) {
  let mut best_length = 0
  let mut best_offset = 0
  
  // Search in previous data
  let search_start = if pos > params.window_log { pos - (1 << params.window_log) } else { 0 }
  
  for i = search_start; i < pos; i = i + 1 {
    let match_length = find_match_length(data, i, pos)
    if match_length > best_length && match_length >= params.min_match {
      best_length = match_length
      best_offset = pos - i
    }
  }
  
  if best_length > 0 {
    (0, best_length, best_offset)
  } else {
    (1, 0, 0)
  }
}

/// Find match length between two positions
fn find_match_length(data : Bytes, pos1 : Int, pos2 : Int) -> Int {
  let mut length = 0
  let max_length = data.length() - pos2
  
  while length < max_length && 
        pos1 + length < data.length() && 
        pos2 + length < data.length() &&
        data[pos1 + length] == data[pos2 + length] {
    length = length + 1
  }
  
  length
}

/// Extract literals from sequences
fn extract_literals(data : Bytes, sequences : Array[Sequence]) -> Bytes {
  let mut literals = Bytes::new()
  let mut pos = 0
  
  for i = 0; i < sequences.length(); i = i + 1 {
    let seq = sequences[i]
    
    // Copy literals
    for j = 0; j < seq.literal_length; j = j + 1 {
      if pos + j < data.length() {
        literals = literals.append(data[pos + j])
      }
    }
    
    pos = pos + seq.literal_length + seq.match_length
  }
  
  literals
}

/// Build literal frequencies for Huffman encoding
fn build_literal_frequencies(literals : Bytes) -> Array[Int] {
  let mut frequencies = Array::new()
  for i = 0; i < 256; i = i + 1 {
    frequencies = frequencies.append(0)
  }
  
  for i = 0; i < literals.length(); i = i + 1 {
    let byte = literals[i].to_int()
    frequencies = frequencies.set(byte, frequencies[byte] + 1)
  }
  
  frequencies
}

/// Build sequence frequencies for FSE encoding
fn build_sequence_frequencies(sequences : Array[Sequence]) -> (Array[Int], Array[Int], Array[Int]) {
  let mut literal_length_freq = Array::new()
  let mut match_length_freq = Array::new()
  let mut offset_freq = Array::new()
  
  // Initialize frequency arrays
  for i = 0; i < 256; i = i + 1 {
    literal_length_freq = literal_length_freq.append(0)
    match_length_freq = match_length_freq.append(0)
    offset_freq = offset_freq.append(0)
  }
  
  for i = 0; i < sequences.length(); i = i + 1 {
    let seq = sequences[i]
    
    // Count literal length
    if seq.literal_length < literal_length_freq.length() {
      literal_length_freq = literal_length_freq.set(seq.literal_length, literal_length_freq[seq.literal_length] + 1)
    }
    
    // Count match length
    if seq.match_length < match_length_freq.length() {
      match_length_freq = match_length_freq.set(seq.match_length, match_length_freq[seq.match_length] + 1)
    }
    
    // Count offset
    if seq.offset < offset_freq.length() {
      offset_freq = offset_freq.set(seq.offset, offset_freq[seq.offset] + 1)
    }
  }
  
  (literal_length_freq, match_length_freq, offset_freq)
}

/// Encode literals using Huffman
fn encode_literals(literals : Bytes, frequencies : Array[Int]) -> Bytes {
  // Simplified - would need full Huffman encoding
  literals
}

/// Encode sequences using FSE
fn encode_sequences(sequences : Array[Sequence], frequencies : (Array[Int], Array[Int], Array[Int])) -> Bytes {
  // Simplified - would need full FSE encoding
  let mut result = Bytes::new()
  for i = 0; i < sequences.length(); i = i + 1 {
    let seq = sequences[i]
    result = result.append(seq.literal_length.to_byte())
    result = result.append(seq.match_length.to_byte())
    result = result.append(seq.offset.to_byte())
  }
  result
}

/// Build compressed blocks
fn build_compressed_blocks(encoded_literals : Bytes, encoded_sequences : Bytes) -> Array[Bytes] {
  let mut blocks = Array::new()
  
  // Create block header
  let mut block = Bytes::new()
  block = block.append(0x02.to_byte()) // Compressed block, not last
  block = block.append(0x00.to_byte()) // Block size (simplified)
  block = block.append(0x00.to_byte())
  
  // Add encoded data
  block = block.append_all(encoded_literals)
  block = block.append_all(encoded_sequences)
  
  blocks = blocks.append(block)
  
  blocks
}
