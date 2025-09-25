/// Finite State Entropy (FSE) decoder implementation
/// Used for decoding sequence distributions (Literal Lengths, Match Lengths, Offsets)

import core::types::{SequenceType, FSETableEntry}
import core::bitstream::{BitStream, read_bits, read_bit}

/// FSE decoder state
pub struct FSEDecoder {
  table : Array[FSETableEntry]
  state : Int
  table_size : Int
}

/// Create FSE decoder from table
pub fn new_fse_decoder(table : Array[FSETableEntry]) -> FSEDecoder {
  FSEDecoder {
    table: table
    state: 0
    table_size: table.length()
  }
}

/// Decode next symbol from FSE stream
pub fn decode_symbol(decoder : FSEDecoder, stream : BitStream) -> (FSEDecoder, BitStream, Int) {
  let entry = decoder.table[decoder.state]
  let symbol = entry.symbol
  let baseline = entry.baseline
  let nb_bits = entry.nb_bits
  
  // Read additional bits if needed
  let (new_stream, additional_bits) = if nb_bits > 0 {
    read_bits(stream, nb_bits)
  } else {
    (stream, 0)
  }
  
  let value = baseline + additional_bits
  
  // Update state
  let new_state = (decoder.state >> nb_bits) + value
  let new_decoder = FSEDecoder {
    table: decoder.table
    state: new_state
    table_size: decoder.table_size
  }
  
  (new_decoder, new_stream, symbol)
}

/// Build FSE table from normalized distribution
pub fn build_fse_table(normalized_dist : Array[Int], table_size : Int) -> Array[FSETableEntry] {
  let mut table = Array::new()
  
  // Initialize table
  for i = 0; i < table_size; i = i + 1 {
    table = table.append(FSETableEntry {
      symbol: 0
      baseline: 0
      nb_bits: 0
    })
  }
  
  // Build table using FSE algorithm
  let mut position = 0
  let mut step = table_size >> 1
  let mut mask = table_size - 1
  
  for i = 0; i < normalized_dist.length(); i = i + 1 {
    let symbol = i
    let count = normalized_dist[i]
    
    if count > 0 {
      for j = 0; j < count; j = j + 1 {
        let entry = FSETableEntry {
          symbol: symbol
          baseline: position
          nb_bits: 0
        }
        table = table.set(position, entry)
        position = (position + step) & mask
      }
    }
  }
  
  // Calculate nb_bits for each entry
  for i = 0; i < table_size; i = i + 1 {
    let entry = table[i]
    let next_entry = table[(i + 1) & mask]
    let nb_bits = if next_entry.baseline > entry.baseline {
      // Calculate number of bits needed
      let diff = next_entry.baseline - entry.baseline
      let mut bits = 0
      let mut temp = diff
      while temp > 1 {
        temp = temp >> 1
        bits = bits + 1
      }
      bits
    } else {
      0
    }
    
    let updated_entry = FSETableEntry {
      symbol: entry.symbol
      baseline: entry.baseline
      nb_bits: nb_bits
    }
    table = table.set(i, updated_entry)
  }
  
  table
}

/// Normalize distribution for FSE
pub fn normalize_distribution(dist : Array[Int], target_sum : Int) -> Array[Int] {
  let mut total = 0
  for i = 0; i < dist.length(); i = i + 1 {
    total = total + dist[i]
  }
  
  if total == 0 {
    // Uniform distribution
    let uniform = target_sum / dist.length()
    let mut result = Array::new()
    for i = 0; i < dist.length(); i = i + 1 {
      result = result.append(uniform)
    }
    result
  } else {
    let mut result = Array::new()
    let mut remaining = target_sum
    
    for i = 0; i < dist.length() - 1; i = i + 1 {
      let normalized = (dist[i] * target_sum) / total
      result = result.append(normalized)
      remaining = remaining - normalized
    }
    
    // Last entry gets remaining
    result = result.append(remaining)
    result
  }
}
