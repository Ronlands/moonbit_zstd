/// FSE (Finite State Entropy) Decoder Module - Unified Implementation
/// Combines basic and enhanced FSE decoding algorithms
/// Based on ZSTD official library FSE implementation

// ============================================================================
// Type Definitions
// ============================================================================

/// FSE table entry with baseline for state transitions
pub struct FSETableEntry {
  symbol: Int               // Symbol value
  num_bits: Int             // Number of bits to read
  baseline: Int             // Baseline value for new state calculation
}

/// FSE decode table
pub struct FSETable {
  table_log: Int            // Log2 of table size
  table: Array[FSETableEntry]  // Decode table
}

/// FSE decoder state
pub struct FSEDecoder {
  table: FSETable           // Decode table
  mut state: Int            // Current state
  mut bit_buffer: Int64     // Bit buffer
  mut bits_cached: Int      // Bits cached in buffer
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Calculate highest bit position
fn high_bit(value: Int) -> Int {
  if value <= 0 {
    return 0
  }
  
  let mut x = value
  let mut bits = 0
  
  if x >= (1 << 16) {
    x = x >> 16
    bits = bits + 16
  }
  if x >= (1 << 8) {
    x = x >> 8
    bits = bits + 8
  }
  if x >= (1 << 4) {
    x = x >> 4
    bits = bits + 4
  }
  if x >= (1 << 2) {
    x = x >> 2
    bits = bits + 2
  }
  if x >= (1 << 1) {
    bits = bits + 1
  }
  
  bits
}

// ============================================================================
// Table Building
// ============================================================================

/// Build FSE decode table from normalized counts
pub fn build_fse_table(
  normalized_counts: Array[Int],
  table_log: Int,
  max_symbol: Int
) -> Result[FSETable, String] {
  if table_log < 5 || table_log > 9 {
    return Err("Table log must be between 5-9")
  }
  
  let table_size = 1 << table_log
  let table : Array[FSETableEntry] = []
  
  // Initialize table
  for _i = 0; _i < table_size; _i = _i + 1 {
    table.push({ symbol: 0, num_bits: 0, baseline: 0 })
  }
  
  // Step 1: Allocate table positions
  let mut position = 0
  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  
  let symbol_starts : Array[Int] = []
  for _i = 0; _i < 256; _i = _i + 1 {
    symbol_starts.push(0)
  }
  
  for symbol = 0; symbol <= max_symbol; symbol = symbol + 1 {
    let count = normalized_counts[symbol]
    
    if count == -1 {
      // Low probability symbol
      table[position] = { symbol: symbol, num_bits: table_log, baseline: 0 }
      position = (position + step) & mask
    } else if count > 0 {
      symbol_starts[symbol] = position
      
      for _i = 0; _i < count; _i = _i + 1 {
        table[position] = { symbol: symbol, num_bits: 0, baseline: 0 }
        position = (position + step) & mask
      }
    }
  }
  
  // Step 2: Calculate bits and baseline
  for symbol = 0; symbol <= max_symbol; symbol = symbol + 1 {
    let count = normalized_counts[symbol]
    
    if count > 0 {
      let max_bits_out = table_log - high_bit(count)
      let min_state_plus = count << max_bits_out
      let start_pos = symbol_starts[symbol]
      
      for i = 0; i < count; i = i + 1 {
        let state_idx = start_pos + i
        if state_idx < table_size {
          let num_bits_out = if i < min_state_plus - count {
            max_bits_out - 1
          } else {
            max_bits_out
          }
          
          let baseline = if i < min_state_plus - count {
            (count << (max_bits_out - 1)) - min_state_plus + i
          } else {
            i - (min_state_plus - count)
          }
          
          table[state_idx] = {
            symbol: symbol,
            num_bits: num_bits_out,
            baseline: baseline
          }
        }
      }
    }
  }
  
  Ok(FSETable::{
    table_log: table_log,
    table: table
  })
}

/// Parse FSE header from compressed data
pub fn parse_fse_header(data: Bytes, offset: Int) -> Result[(Array[Int], Int, Int), String] {
  if offset >= data.length() {
    return Err("Insufficient data to read FSE header")
  }
  
  let mut current_offset = offset
  let mut bit_stream = 0
  let mut bit_count = 0
  let symbol_probabilities: Array[Int] = Array::make(256, 0)
  let mut max_symbol = 0
  
  // Read table log
  if current_offset >= data.length() {
    return Err("Cannot read table log")
  }
  
  let first_byte = data[current_offset].to_int()
  current_offset = current_offset + 1
  
  let table_log = (first_byte & 0xF) + 5
  if table_log > 12 {
    return Err("Table log out of range")
  }
  
  // Initialize bit stream
  bit_stream = first_byte >> 4
  bit_count = 4
  
  // Read more bytes into bit stream
  let bytes_to_read = (data.length() - current_offset).min(3)
  for i = 0; i < bytes_to_read; i = i + 1 {
    bit_stream = bit_stream | (data[current_offset + i].to_int() << bit_count)
    bit_count = bit_count + 8
  }
  current_offset = current_offset + bytes_to_read
  
  // Parse symbol probabilities
  let mut symbol = 0
  let mut remaining = 1 << table_log
  
  while symbol < 256 && remaining > 1 {
    // Read probability value
    let (new_bit_stream, new_bit_count, new_offset, prob) = read_fse_probability(
      data, bit_stream, bit_count, current_offset, remaining
    )
    
    bit_stream = new_bit_stream
    bit_count = new_bit_count
    current_offset = new_offset
    
    if prob < 0 {
      break
    }
    
    symbol_probabilities[symbol] = prob
    remaining = remaining - prob
    max_symbol = symbol
    symbol = symbol + 1
    
    // If probability is 0, skip consecutive zeros
    if prob == 0 {
      let (skip_bit_stream, skip_bit_count, skip_offset, skip_count) = read_fse_skip_count(
        data, bit_stream, bit_count, current_offset
      )
      bit_stream = skip_bit_stream
      bit_count = skip_bit_count
      current_offset = skip_offset
      symbol = symbol + skip_count
    }
  }
  
  // Assign remaining probability to last symbol
  if remaining > 0 && max_symbol < 255 {
    symbol_probabilities[max_symbol] = symbol_probabilities[max_symbol] + remaining
  }
  
  let bytes_consumed = current_offset - offset
  Ok((symbol_probabilities, table_log, bytes_consumed))
}

/// Read FSE probability value
fn read_fse_probability(data: Bytes, bit_stream: Int, bit_count: Int, offset: Int, remaining: Int) -> (Int, Int, Int, Int) {
  let mut bit_stream = bit_stream
  let mut bit_count = bit_count
  let mut offset = offset
  
  // Ensure sufficient bits
  while bit_count < 16 && offset < data.length() {
    bit_stream = bit_stream | (data[offset].to_int() << bit_count)
    bit_count = bit_count + 8
    offset = offset + 1
  }
  
  if bit_count < 2 {
    return (bit_stream, bit_count, offset, -1)
  }
  
  // Read probability value (simplified)
  let small_prob = bit_stream & 0x3
  bit_stream = bit_stream >> 2
  bit_count = bit_count - 2
  
  let prob = if small_prob < 3 {
    small_prob
  } else {
    // Read longer probability value
    if bit_count < 8 {
      return (bit_stream, bit_count, offset, -1)
    }
    let extended = bit_stream & 0xFF
    bit_stream = bit_stream >> 8
    bit_count = bit_count - 8
    extended.min(remaining)
  }
  
  (bit_stream, bit_count, offset, prob)
}

/// Read skip count for consecutive zeros
fn read_fse_skip_count(data: Bytes, bit_stream: Int, bit_count: Int, offset: Int) -> (Int, Int, Int, Int) {
  let mut bit_stream = bit_stream
  let mut bit_count = bit_count
  let mut offset = offset
  
  // Ensure sufficient bits
  while bit_count < 8 && offset < data.length() {
    bit_stream = bit_stream | (data[offset].to_int() << bit_count)
    bit_count = bit_count + 8
    offset = offset + 1
  }
  
  if bit_count < 2 {
    return (bit_stream, bit_count, offset, 1)
  }
  
  let skip_bits = bit_stream & 0x3
  bit_stream = bit_stream >> 2
  bit_count = bit_count - 2
  
  let skip_count = if skip_bits < 3 {
    skip_bits + 1
  } else {
    // Read longer skip count
    if bit_count < 8 {
      return (bit_stream, bit_count, offset, 1)
    }
    let extended = bit_stream & 0xFF
    bit_stream = bit_stream >> 8
    bit_count = bit_count - 8
    extended + 4
  }
  
  (bit_stream, bit_count, offset, skip_count)
}

// ============================================================================
// Decoding
// ============================================================================

/// Create FSE decoder
pub fn create_fse_decoder(
  table: FSETable,
  initial_state: Int
) -> FSEDecoder {
  FSEDecoder::{
    table: table,
    state: initial_state,
    bit_buffer: 0L,
    bits_cached: 0
  }
}

/// Refill bit buffer
fn refill_fse_bits(
  decoder_in : FSEDecoder,
  data : Bytes,
  offset_in : Int
) -> (FSEDecoder, Int) {
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

/// Decode single FSE symbol
pub fn decode_fse_symbol(
  decoder_in : FSEDecoder,
  data : Bytes,
  offset_in : Int
) -> Result[(Int, FSEDecoder, Int), String] {
  let mut decoder = decoder_in
  if decoder.state >= decoder.table.table.length() {
    return Err("Invalid FSE state")
  }
  
  let entry = decoder.table.table[decoder.state]
  let symbol = entry.symbol
  
  let mut offset = offset_in
  
  // Ensure sufficient bits
  if decoder.bits_cached < entry.num_bits {
    let (new_decoder, new_offset) = refill_fse_bits(decoder, data, offset)
    decoder = new_decoder
    offset = new_offset
  }
  
  if decoder.bits_cached < entry.num_bits {
    return Err("Bit stream exhausted")
  }
  
  // Read required bits
  let mask = (1L << entry.num_bits) - 1L
  let add = (decoder.bit_buffer & mask).to_int()
  
  // Update bit buffer
  decoder.bit_buffer = decoder.bit_buffer >> entry.num_bits
  decoder.bits_cached = decoder.bits_cached - entry.num_bits
  
  // Calculate new state
  let new_state = entry.baseline + add
  decoder.state = new_state
  
  Ok((symbol, decoder, offset))
}

/// Decode FSE sequence in batch
pub fn decode_fse_sequence(
  table : FSETable,
  data : Bytes,
  offset : Int,
  count : Int
) -> Result[Array[Int], String] {
  if offset + 2 > data.length() {
    return Err("Insufficient data to initialize FSE decoder")
  }
  
  // Read initial state
  let initial_state = data[offset].to_int() | (data[offset + 1].to_int() << 8)
  let state = initial_state & ((1 << table.table_log) - 1)
  
  let mut decoder = create_fse_decoder(table, state)
  let symbols : Array[Int] = []
  let mut current_offset = offset + 2
  
  for _i = 0; _i < count; _i = _i + 1 {
    match decode_fse_symbol(decoder, data, current_offset) {
      Ok((symbol, new_decoder, new_offset)) => {
        symbols.push(symbol)
        decoder = new_decoder
        current_offset = new_offset
      }
      Err(e) => return Err("Decode failed: " + e)
    }
  }
  
  Ok(symbols)
}

// ============================================================================
// Predefined Tables
// ============================================================================

/// Get predefined FSE table by mode
pub fn get_predefined_fse_table(mode: String) -> Result[FSETable, String] {
  match mode {
    "literal_lengths" => {
      let counts = [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1
      ]
      build_fse_table(counts, 6, 35)
    }
    "match_lengths" => {
      let counts = [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1, -1, -1
      ]
      build_fse_table(counts, 6, 52)
    }
    "offsets" => {
      let counts = [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
      ]
      build_fse_table(counts, 5, 28)
    }
    _ => Err("Unknown FSE table type")
  }
}

// ============================================================================
// Validation
// ============================================================================

/// Validate FSE table
pub fn validate_fse_table(table: FSETable) -> Bool {
  if table.table_log == 0 || table.table_log > 12 {
    return false
  }
  
  let expected_size = 1 << table.table_log
  if table.table.length() != expected_size {
    return false
  }
  
  // Check all entries validity
  for i = 0; i < table.table.length(); i = i + 1 {
    let entry = table.table[i]
    if entry.num_bits > table.table_log {
      return false
    }
    if entry.baseline >= table.table.length() {
      return false
    }
  }
  
  true
}

/// Debug: Print FSE table info
pub fn print_fse_table_info(table: FSETable) -> String {
  "FSE table: table_log=" + table.table_log.to_string() + 
  ", table_size=" + table.table.length().to_string()
}
