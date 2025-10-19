/// Huffman Decoder Module - Unified Implementation
/// Combines basic and enhanced Huffman decoding algorithms
/// Based on ZSTD official library Huffman tree decoding

// ============================================================================
// Type Definitions
// ============================================================================

/// Huffman decode table entry
struct HuffmanEntry {
  symbol: Byte
  num_bits: Byte
  is_valid: Bool
}

/// Huffman decode table
pub struct HuffmanTable {
  table: Array[HuffmanEntry]
  table_log: Int
  max_bits: Int
  max_symbol: Int
}

/// Huffman decoder state
pub struct HuffmanDecoder {
  table: HuffmanTable
  mut bit_buffer: Int64
  mut bits_cached: Int
}

/// Huffman weights structure
pub struct HuffmanWeights {
  weights: Array[Int]
  count: Int
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Reverse bits in value
fn reverse_bits(value: Int, num_bits: Int) -> Int {
  let mut result = 0
  let mut v = value
  
  for _i = 0; _i < num_bits; _i = _i + 1 {
    result = (result << 1) | (v & 1)
    v = v >> 1
  }
  
  result
}

/// Calculate highest bit position

// ============================================================================
// Weight Parsing
// ============================================================================

/// Parse Huffman weights from compressed data
pub fn parse_huffman_weights(data: Bytes, offset: Int, max_size: Int) -> Result[(HuffmanWeights, Int), String] {
  if offset >= data.length() {
    return Err("Insufficient data to read Huffman weights")
  }
  
  let header_byte = data[offset].to_int()
  
  if header_byte < 128 {
    // FSE compressed weights
    parse_fse_compressed_weights(data, offset, header_byte, max_size)
  } else {
    // Direct weights
    parse_direct_weights(data, offset, header_byte - 127, max_size)
  }
}

/// Parse direct encoded Huffman weights
fn parse_direct_weights(data: Bytes, offset: Int, num_weights: Int, _max_size: Int) -> Result[(HuffmanWeights, Int), String] {
  let bytes_needed = (num_weights + 1) / 2
  
  if offset + bytes_needed > data.length() {
    return Err("Insufficient data for direct weights")
  }
  
  let weights: Array[Int] = Array::make(256, 0)
  let mut i = 0
  let mut byte_offset = offset + 1
  
  while i < num_weights {
    let byte_val = data[byte_offset].to_int()
    weights[i] = (byte_val >> 4) & 0xF
    i = i + 1
    
    if i < num_weights {
      weights[i] = byte_val & 0xF
      i = i + 1
    }
    
    byte_offset = byte_offset + 1
  }
  
  // Calculate last weight
  let mut weight_sum = 0
  for j = 0; j < num_weights; j = j + 1 {
    if weights[j] > 0 {
      weight_sum = weight_sum + (1 << (weights[j] - 1))
    }
  }
  
  // Find next power of 2
  let mut power_of_2 = 1
  while power_of_2 <= weight_sum {
    power_of_2 = power_of_2 * 2
  }
  
  // Calculate last weight
  let last_weight = power_of_2 - weight_sum
  if last_weight > 0 {
    let mut last_weight_log = 0
    let mut temp = last_weight
    while temp > 1 {
      temp = temp / 2
      last_weight_log = last_weight_log + 1
    }
    weights[num_weights] = last_weight_log + 1
  }
  
  let result = HuffmanWeights::{
    weights: weights,
    count: num_weights + 1
  }
  
  Ok((result, bytes_needed + 1))
}

/// Parse FSE compressed weights (simplified implementation)
fn parse_fse_compressed_weights(data: Bytes, offset: Int, compressed_size: Int, max_size: Int) -> Result[(HuffmanWeights, Int), String] {
  if offset + compressed_size > data.length() {
    return Err("FSE compressed weight data out of range")
  }
  
  let weights: Array[Int] = Array::make(max_size.min(256), 0)
  
  let mut current_offset = offset + 1
  let mut weight_count = 0
  
  // Simplified FSE decompression using basic bit operations
  while current_offset < offset + compressed_size && weight_count < weights.length() {
    if current_offset >= data.length() {
      break
    }
    
    let byte_val = data[current_offset].to_int()
    
    let weight1 = (byte_val >> 4) & 0xF
    let weight2 = byte_val & 0xF
    
    if weight_count < weights.length() && weight1 > 0 {
      weights[weight_count] = weight1
      weight_count = weight_count + 1
    }
    
    if weight_count < weights.length() && weight2 > 0 {
      weights[weight_count] = weight2  
      weight_count = weight_count + 1
    }
    
    current_offset = current_offset + 1
  }
  
  // Calculate last weight to ensure sum is power of 2
  if weight_count < weights.length() {
    let mut weight_sum = 0
    for i = 0; i < weight_count; i = i + 1 {
      if weights[i] > 0 {
        weight_sum = weight_sum + (1 << (weights[i] - 1))
      }
    }
    
    let mut power_of_2 = 1
    while power_of_2 <= weight_sum {
      power_of_2 = power_of_2 * 2
    }
    
    let last_weight = power_of_2 - weight_sum
    if last_weight > 0 && weight_count < weights.length() {
      let mut last_weight_log = 0
      let mut temp = last_weight
      while temp > 1 {
        temp = temp / 2
        last_weight_log = last_weight_log + 1
      }
      weights[weight_count] = last_weight_log + 1
      weight_count = weight_count + 1
    }
  }
  
  let result = HuffmanWeights::{
    weights: weights,
    count: weight_count
  }
  
  Ok((result, compressed_size + 1))
}

// ============================================================================
// Table Building
// ============================================================================

/// Build Huffman decode table from weights using enhanced algorithm
pub fn build_huffman_table(weights: Array[Int], max_symbol: Int) -> Result[HuffmanTable, String] {
  if max_symbol > 255 {
    return Err("Max symbol exceeds 255")
  }
  
  // Calculate weight statistics
  let weight_counts : Array[Int] = []
  for _i = 0; _i < 13; _i = _i + 1 {
    weight_counts.push(0)
  }
  
  let mut max_weight = 0
  
  for i = 0; i <= max_symbol; i = i + 1 {
    let weight = weights[i]
    if weight > 0 {
      if weight > 12 {
        return Err("Weight exceeds maximum of 12")
      }
      weight_counts[weight] = weight_counts[weight] + 1
      if weight > max_weight {
        max_weight = weight
      }
    }
  }
  
  // Calculate starting codes for each weight
  let rank_start : Array[Int] = []
  for _i = 0; _i < 13; _i = _i + 1 {
    rank_start.push(0)
  }
  
  let mut current_code = 0
  for weight = 1; weight <= max_weight; weight = weight + 1 {
    rank_start[weight] = current_code
    current_code = current_code + (weight_counts[weight] << (max_weight - weight))
  }
  
  if current_code != (1 << max_weight) {
    return Err("Weight sum incorrect")
  }
  
  // Assign codes to symbols
  let symbol_codes : Array[Int] = []
  let symbol_lengths : Array[Int] = []
  for _i = 0; _i < 256; _i = _i + 1 {
    symbol_codes.push(0)
    symbol_lengths.push(0)
  }
  
  for symbol = 0; symbol <= max_symbol; symbol = symbol + 1 {
    let weight = weights[symbol]
    if weight > 0 {
      let code = rank_start[weight]
      rank_start[weight] = rank_start[weight] + (1 << (max_weight - weight))
      
      symbol_codes[symbol] = reverse_bits(code, max_weight)
      symbol_lengths[symbol] = weight
    }
  }
  
  // Build fast lookup table
  let table_log = max_weight
  let table_size = 1 << table_log
  let table : Array[HuffmanEntry] = []
  
  for _i = 0; _i < table_size; _i = _i + 1 {
    table.push({ symbol: b'\x00', num_bits: b'\x00', is_valid: false })
  }
  
  // Fill table with replicated entries
  for symbol = 0; symbol <= max_symbol; symbol = symbol + 1 {
    let length = symbol_lengths[symbol]
    if length > 0 {
      let code = symbol_codes[symbol]
      let replicate_count = 1 << (table_log - length)
      
      for i = 0; i < replicate_count; i = i + 1 {
        let index = code + (i << length)
        if index < table_size {
          table[index] = {
            symbol: symbol.to_byte(),
            num_bits: length.to_byte(),
            is_valid: true
          }
        }
      }
    }
  }
  
  Ok(HuffmanTable::{
    table: table,
    table_log: table_log,
    max_bits: max_weight,
    max_symbol: max_symbol
  })
}

/// Build Huffman table from weights structure
pub fn build_huffman_table_from_weights(weights: HuffmanWeights) -> Result[HuffmanTable, String] {
  build_huffman_table(weights.weights, weights.count - 1)
}

// ============================================================================
// Decoding
// ============================================================================

/// Create Huffman decoder
pub fn create_huffman_decoder(table: HuffmanTable) -> HuffmanDecoder {
  HuffmanDecoder::{ table: table, bit_buffer: 0L, bits_cached: 0 }
}

/// Refill bit buffer
fn refill_huffman_bits(
  decoder_in: HuffmanDecoder,
  data: Bytes,
  offset_in: Int
) -> (HuffmanDecoder, Int) {
  let decoder = decoder_in
  let mut offset = offset_in
  
  while decoder.bits_cached < 56 && offset < data.length() {
    let byte_val = data[offset].to_int()
    decoder.bit_buffer = decoder.bit_buffer | (byte_val.to_int64() << decoder.bits_cached)
    decoder.bits_cached = decoder.bits_cached + 8
    offset = offset + 1
  }
  
  (decoder, offset)
}

/// Decode single Huffman symbol
pub fn decode_huffman_symbol(
  decoder_in: HuffmanDecoder,
  data: Bytes,
  offset_in: Int
) -> Result[(Byte, HuffmanDecoder, Int), String] {
  let mut decoder = decoder_in
  let mut offset = offset_in
  
  // Ensure sufficient bits
  if decoder.bits_cached < decoder.table.max_bits {
    let (new_decoder, new_offset) = refill_huffman_bits(decoder, data, offset)
    decoder = new_decoder
    offset = new_offset
  }
  
  if decoder.bits_cached < 1 {
    return Err("Bit stream exhausted")
  }
  
  // Table lookup
  let mask = (1L << decoder.table.table_log) - 1L
  let index = (decoder.bit_buffer & mask).to_int()
  
  if index >= decoder.table.table.length() {
    return Err("Index exceeds table range")
  }
  
  let entry = decoder.table.table[index]
  
  if !entry.is_valid {
    return Err("Invalid Huffman code")
  }
  
  let symbol = entry.symbol
  let num_bits = entry.num_bits.to_int()
  
  // Consume used bits
  decoder.bit_buffer = decoder.bit_buffer >> num_bits
  decoder.bits_cached = decoder.bits_cached - num_bits
  
  Ok((symbol, decoder, offset))
}

/// Decode Huffman stream in batch
pub fn decode_huffman_stream(
  table: HuffmanTable,
  data: Bytes,
  offset: Int,
  expected_count: Int
) -> Result[Bytes, String] {
  let mut decoder = create_huffman_decoder(table)
  let output : Array[Byte] = []
  let mut current_offset = offset
  
  while output.length() < expected_count && current_offset < data.length() {
    match decode_huffman_symbol(decoder, data, current_offset) {
      Ok((symbol, new_decoder, new_offset)) => {
        output.push(symbol)
        decoder = new_decoder
        current_offset = new_offset
      }
      Err(e) => {
        if output.length() < expected_count {
          return Err("Decode failed: " + e)
        } else {
          break
        }
      }
    }
  }
  
  if output.length() != expected_count {
    return Err(
      "Output size mismatch: expected " +
        expected_count.to_string() +
        ", actual " +
        output.length().to_string(),
    )
  }
  
  Ok(Bytes::from_array(output))
}

// ============================================================================
// Validation
// ============================================================================

/// Validate Huffman table
pub fn validate_huffman_table(table: HuffmanTable) -> Bool {
  if table.table_log < 1 || table.table_log > 12 {
    return false
  }
  
  if table.max_bits < 1 || table.max_bits > 12 {
    return false
  }
  
  let expected_size = 1 << table.table_log
  if table.table.length() != expected_size {
    return false
  }
  
  // Check for at least some valid entries
  let mut has_valid = false
  for i = 0; i < table.table.length(); i = i + 1 {
    if table.table[i].is_valid {
      has_valid = true
      break
    }
  }
  
  has_valid
}

/// Debug: Print Huffman table info
pub fn print_huffman_table_info(table: HuffmanTable) -> String {
  "Huffman table: table_log=" + table.table_log.to_string() + 
  ", max_symbol=" + table.max_symbol.to_string() + 
  ", table_size=" + table.table.length().to_string()
}
