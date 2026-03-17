/// LZ77 Hash Table and Pattern Matching

pub struct Match {
  offset: Int
  length: Int
}

pub struct Sequence {
  literal_length: Int
  match_length: Int
  offset: Int
}

/// Hash a 4-byte sequence for pattern matching
pub fn hash_bytes(data: Bytes, pos: Int) -> Int {
  if pos + 3 >= data.length() {
    return 0
  }

  let b0 = data[pos].to_int() & 0xFF
  let b1 = data[pos + 1].to_int() & 0xFF
  let b2 = data[pos + 2].to_int() & 0xFF
  let b3 = data[pos + 3].to_int() & 0xFF

  let hash = ((b0 << 12) ^ (b1 << 8) ^ (b2 << 4) ^ b3) * 506832829
  (hash >> 16) & 0xFFFF
}

/// Find match at given position using hash table
pub fn find_match(data: Bytes, pos: Int, hash_table: Array[Int], min_match: Int, window_size: Int) -> Match {
  let data_len = data.length()
  if pos + min_match > data_len {
    return Match::{ offset: 0, length: 0 }
  }

  let hash = hash_bytes(data, pos)
  let match_pos = hash_table[hash]

  if match_pos == -1 || match_pos >= pos {
    return Match::{ offset: 0, length: 0 }
  }

  let offset = pos - match_pos
  if offset > window_size {
    return Match::{ offset: 0, length: 0 }
  }

  let mut i = 0
  while i < min_match && pos + i < data_len {
    let match_idx = match_pos + (i % offset)
    if match_idx >= data_len || data[match_idx] != data[pos + i] {
      return Match::{ offset: 0, length: 0 }
    }
    i = i + 1
  }

  let mut match_length = min_match
  let max_match = (data_len - pos).min(131072)

  while match_length < max_match && pos + match_length < data_len {
    let match_idx = match_pos + (match_length % offset)
    if match_idx >= data_len || data[match_idx] != data[pos + match_length] {
      break
    }
    match_length = match_length + 1
  }

  Match::{ offset: offset, length: match_length }
}

/// Generate sequences using greedy LZ77 matching with repeat offset optimization
pub fn generate_sequences(data: Bytes, min_match: Int, window_size: Int) -> (Array[Sequence], Array[Byte]) {
  let sequences: Array[Sequence] = []
  let literals: Array[Byte] = []
  let hash_table = Array::make(hash_table_size, -1)

  let mut pos = 0
  let mut literal_start = 0
  let mut rep0 = 1
  let mut rep1 = 4
  let mut rep2 = 8

  while pos < data.length() {
    let match_result = find_match(data, pos, hash_table, min_match, window_size)

    if match_result.length >= min_match {
      let literal_length = pos - literal_start
      for i = literal_start; i < pos; i = i + 1 {
        literals.push(data[i])
      }

      let offset = match_result.offset
      let encoded_offset = if offset == rep0 {
        -1
      } else if offset == rep1 {
        -2
      } else if offset == rep2 {
        -3
      } else {
        rep2 = rep1
        rep1 = rep0
        rep0 = offset
        offset
      }

      sequences.push(Sequence::{
        literal_length,
        match_length: match_result.length,
        offset: encoded_offset,
      })

      let mut i = pos
      while i < pos + match_result.length && i + 3 < data.length() {
        let hash = hash_bytes(data, i)
        hash_table[hash] = i
        i = i + 1
      }

      pos = pos + match_result.length
      literal_start = pos
    } else {
      if pos + 3 < data.length() {
        let hash = hash_bytes(data, pos)
        hash_table[hash] = pos
      }
      pos = pos + 1
    }
  }

  for i = literal_start; i < data.length(); i = i + 1 {
    literals.push(data[i])
  }

  (sequences, literals)
}
