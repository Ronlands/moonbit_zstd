/// Dictionary Compression Support

/// Preload dictionary content into hash table
fn preload_dictionary_to_hash_table(dictionary: Bytes, hash_table: Array[Int]) -> Unit {
  let dict_len = dictionary.length()

  let mut pos = 0
  while pos + 3 < dict_len {
    let hash = hash_bytes(dictionary, pos)
    hash_table[hash] = -(pos + 1)
    pos = pos + 1
  }
}

/// Calculate match length from dictionary
fn calculate_match_length_from_dict(
  data: Bytes,
  dictionary: Bytes,
  data_pos: Int,
  dict_pos: Int
) -> Int {
  let mut length = 0
  let max_length = (data.length() - data_pos).min(dictionary.length() - dict_pos).min(131072)

  while length < max_length &&
        dict_pos + length < dictionary.length() &&
        data_pos + length < data.length() &&
        dictionary[dict_pos + length] == data[data_pos + length] {
    length = length + 1
  }

  length
}

/// Calculate match length in data
fn calculate_match_length_in_data(data: Bytes, pos: Int, match_pos: Int) -> Int {
  let mut length = 0
  let max_length = (data.length() - pos).min(131072)

  while length < max_length &&
        match_pos + length < pos &&
        pos + length < data.length() &&
        data[match_pos + length] == data[pos + length] {
    length = length + 1
  }

  length
}

/// Find match with dictionary support
pub fn find_match_with_dict(
  data: Bytes,
  dictionary: Bytes,
  pos: Int,
  hash_table: Array[Int],
  min_match: Int,
  window_size: Int
) -> Match {
  if pos + min_match > data.length() {
    return Match::{ offset: 0, length: 0 }
  }

  let hash = hash_bytes(data, pos)
  let match_pos = hash_table[hash]

  if match_pos == -1 || match_pos >= pos {
    return Match::{ offset: 0, length: 0 }
  }

  if match_pos < 0 {
    let dict_pos = -match_pos - 1
    let match_length = calculate_match_length_from_dict(data, dictionary, pos, dict_pos)

    if match_length >= min_match {
      let offset = pos + (dictionary.length() - dict_pos)
      Match::{ offset: offset, length: match_length }
    } else {
      Match::{ offset: 0, length: 0 }
    }
  } else {
    let offset = pos - match_pos
    if offset > window_size {
      return Match::{ offset: 0, length: 0 }
    }

    let match_length = calculate_match_length_in_data(data, pos, match_pos)

    if match_length >= min_match {
      Match::{ offset: offset, length: match_length }
    } else {
      Match::{ offset: 0, length: 0 }
    }
  }
}

/// Generate sequences with dictionary support
pub fn generate_sequences_with_dict(
  data: Bytes,
  dictionary: Bytes,
  hash_table: Array[Int],
  min_match: Int,
  window_size: Int
) -> Result[(Array[Sequence], Array[Byte]), String] {
  let sequences: Array[Sequence] = []
  let literals: Array[Byte] = []

  let mut pos = 0
  let mut literal_start = 0

  while pos < data.length() {
    let match_result = find_match_with_dict(data, dictionary, pos, hash_table, min_match, window_size)

    if match_result.length >= min_match {
      let literal_length = pos - literal_start

      for i = literal_start; i < pos; i = i + 1 {
        literals.push(data[i])
      }

      sequences.push(Sequence::{
        literal_length: literal_length,
        match_length: match_result.length,
        offset: match_result.offset
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

  Ok((sequences, literals))
}

/// Determine if compressed block should be used
pub fn should_use_compressed_block(
  data: Bytes,
  sequences: Array[Sequence],
  literals: Array[Byte]
) -> Bool {
  let literal_size = literals.length()
  let sequence_size = sequences.length() * 6
  let estimated_compressed_size = literal_size + sequence_size + 20

  estimated_compressed_size < (data.length() * 95 / 100)
}
