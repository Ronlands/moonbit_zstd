/// ZSTD Compressor - Main Compression Logic

pub struct Compressor {
  level: Int
  hash_table: Array[Int]
  window_size: Int
}

pub struct CompressionConfig {
  level: Int
  window_log: Int
  min_match: Int
  search_depth: Int
}

pub struct CompressionContext {
  config: CompressionConfig
}

/// Create new compressor
pub fn new_compressor() -> Compressor {
  let hash_table = Array::make(hash_table_size, -1)
  Compressor::{
    level: 1,
    hash_table: hash_table,
    window_size: default_window_size
  }
}

pub fn create_default_config() -> CompressionConfig {
  CompressionConfig::{ level: 3, window_log: 17, min_match: 4, search_depth: 12 }
}

pub fn create_config_with_level(level: Int) -> CompressionConfig {
  let clamped_level = level.max(1).min(22)
  let (window_log, min_match, search_depth) = match clamped_level {
    1 => (16, 4, 4)
    2 => (16, 4, 8)
    3 => (17, 4, 12)
    4 | 5 => (17, 4, 16)
    6 | 7 => (18, 4, 24)
    8 | 9 => (18, 4, 32)
    10 | 11 | 12 => (19, 3, 48)
    13 | 14 | 15 => (19, 3, 64)
    16 | 17 | 18 => (20, 3, 96)
    _ => (20, 3, 128)
  }
  CompressionConfig::{ level: clamped_level, window_log, min_match, search_depth }
}

pub fn create_compression_context(config: CompressionConfig) -> CompressionContext {
  CompressionContext::{ config }
}

/// Check if RLE compression would be beneficial
fn is_rle_beneficial(data: Bytes) -> Bool {
  if data.length() < 4 {
    return false
  }

  let first_byte = data[0]
  let mut same_count = 0
  let sample_size = data.length().min(100)

  for i = 0; i < sample_size; i = i + 1 {
    if data[i] == first_byte {
      same_count = same_count + 1
    }
  }

  (same_count * 10) > (sample_size * 8)
}

/// Check if should try compressed block
fn should_try_compressed_block(data: Bytes) -> Bool {
  data.length() >= 64
}

/// Compress empty data
fn compress_empty_frame() -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []

  write_zstd_magic(output)
  output.push(0x20)
  output.push(0x00)
  output.push(0x01)
  output.push(0x00)
  output.push(0x00)

  Ok(Bytes::from_array(output))
}

/// Compress as raw block
pub fn compress_as_raw_block(data: Bytes, _config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE

  write_zstd_magic(output)
  write_frame_header_descriptor(output, data.length())

  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())

    write_block_header(output, is_last, 0, chunk_size)

    for i = 0; i < chunk_size; i = i + 1 {
      output.push(data[pos + i])
    }
    pos = pos + chunk_size
  }

  Ok(Bytes::from_array(output))
}

/// Compress as RLE block
pub fn compress_as_rle_block(data: Bytes, _config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }

  let first_byte = data[0]
  let mut all_same = true
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] != first_byte {
      all_same = false
      break
    }
  }

  if !all_same {
    return compress_as_raw_block(data, _config)
  }

  let output: Array[Byte] = []

  write_zstd_magic(output)
  write_frame_header_descriptor(output, data.length())

  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE
  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    write_block_header(output, is_last, 1, chunk_size)
    output.push(first_byte)
    pos = pos + chunk_size
  }

  Ok(Bytes::from_array(output))
}

/// Compress as compressed block
pub fn compress_as_compressed_block(data: Bytes, config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  let min_match = config.min_match
  let window_size = 1 << config.window_log

  let (sequences, literals) = generate_sequences(data, min_match, window_size)

  if sequences.length() == 0 {
    return Err(@zstd_core.message_error("No compression benefit"))
  }

  let output: Array[Byte] = []
  write_zstd_magic(output)
  write_frame_header_descriptor(output, data.length())

  let block_content: Array[Byte] = []
  encode_literals_section(literals, block_content)

  let num_sequences = sequences.length()
  write_sequence_count(block_content, num_sequences)

  if num_sequences > 0 {
    if num_sequences == 1 {
      encode_single_sequence_direct(sequences[0], block_content)
    } else {
      block_content.push(0x00)
      match encode_sequences_predefined_fse(sequences, block_content) {
        Ok(_) => ()
        Err(e) => return Err(@zstd_core.message_error("Failed to encode sequences: \{e}"))
      }
    }
  }

  write_block_header(output, true, 2, block_content.length())
  for i = 0; i < block_content.length(); i = i + 1 {
    output.push(block_content[i])
  }

  Ok(Bytes::from_array(output))
}

/// Compress block content as raw
fn compress_block_content_raw(data: Bytes) -> Result[(Int, Bytes), @zstd_core.ZSTDError] {
  Ok((0, data))
}

/// Compress block content as RLE
fn compress_block_content_rle(data: Bytes) -> Result[(Int, Bytes), @zstd_core.ZSTDError] {
  let output: Array[Byte] = []
  output.push(data[0])
  Ok((1, Bytes::from_array(output)))
}

/// Compress block content as compressed
fn compress_block_content_compressed(data: Bytes, config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  let min_match = config.min_match
  let window_size = 1 << config.window_log
  let (sequences, literals) = generate_sequences(data, min_match, window_size)

  if sequences.length() == 0 {
    return Err(@zstd_core.message_error("No sequences"))
  }

  let output: Array[Byte] = []
  encode_literals_section(literals, output)
  write_sequence_count(output, sequences.length())

  if sequences.length() > 0 {
    let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(sequences)
    if should_use_compressed_fse(ll_symbols, ml_symbols, of_symbols) {
      output.push(0x01)
      match encode_sequences_compressed_fse(sequences, output) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else {
      output.push(0x00)
      match encode_sequences_predefined_fse(sequences, output) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
  }
  Ok(Bytes::from_array(output))
}

/// Compress data
pub fn compress_data(data: Bytes, config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_data_with_checksum(data, config, false)
}

/// Compress data with optional checksum
pub fn compress_data_with_checksum(data: Bytes, config: CompressionConfig, with_checksum: Bool) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 { return compress_empty_frame() }

  if data.length() > max_block_size {
    return compress_multi_block_with_checksum(data, config, with_checksum)
  }

  let result = if is_rle_beneficial(data) {
    compress_as_rle_block(data, config)
  } else if should_try_compressed_block(data) {
    match compress_as_compressed_block(data, config) {
      Ok(compressed) => {
        if compressed.length() < data.length() + 12 {
          Ok(compressed)
        } else {
          compress_as_raw_block(data, config)
        }
      }
      Err(_) => compress_as_raw_block(data, config)
    }
  } else {
    compress_as_raw_block(data, config)
  }

  match result {
    Ok(compressed) => {
      if with_checksum {
        let output: Array[Byte] = []
        for i = 0; i < compressed.length(); i = i + 1 {
          output.push(compressed[i])
        }
        write_checksum(output, calculate_checksum(data))
        Ok(Bytes::from_array(output))
      } else {
        Ok(compressed)
      }
    }
    Err(e) => Err(e)
  }
}

/// Compress large data as multiple blocks
fn compress_multi_block_with_checksum(data: Bytes, config: CompressionConfig, with_checksum: Bool) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []

  write_zstd_magic(output)
  write_frame_header_descriptor_with_checksum(output, data.length(), with_checksum)

  let mut offset = 0
  while offset < data.length() {
    let block_size = (data.length() - offset).min(max_block_size)

    let block_bytes: Array[Byte] = []
    for i = 0; i < block_size; i = i + 1 {
      block_bytes.push(data[offset + i])
    }
    let block_data = Bytes::from_array(block_bytes)
    let is_last = offset + block_size >= data.length()

    let block_result = if is_rle_beneficial(block_data) {
      compress_block_content_rle(block_data)
    } else if should_try_compressed_block(block_data) {
      match compress_block_content_compressed(block_data, config) {
        Ok(compressed) => {
          if compressed.length() < block_size {
            Ok((2, compressed))
          } else {
            compress_block_content_raw(block_data)
          }
        }
        Err(_) => compress_block_content_raw(block_data)
      }
    } else {
      compress_block_content_raw(block_data)
    }

    match block_result {
      Ok((block_type, block_content)) => {
        write_block_header(output, is_last, block_type, block_content.length())
        for i = 0; i < block_content.length(); i = i + 1 {
          output.push(block_content[i])
        }
      }
      Err(e) => return Err(e)
    }

    offset = offset + block_size
  }

  if with_checksum {
    write_checksum(output, calculate_checksum(data))
  }

  Ok(Bytes::from_array(output))
}

/// Estimate compressed size
pub fn estimate_compressed_size(data: Bytes, _config: CompressionConfig) -> Int {
  if data.length() == 0 {
    return 10
  }

  if is_rle_beneficial(data) {
    return 10 + (data.length() / 128000) * 4
  }

  let mut unique_bytes = 0
  let byte_counts = Array::make(256, 0)
  let sample_size = data.length().min(1000)

  for i = 0; i < sample_size; i = i + 1 {
    let b = data[i].to_int() & 0xFF
    if byte_counts[b] == 0 {
      unique_bytes = unique_bytes + 1
    }
    byte_counts[b] = byte_counts[b] + 1
  }

  let entropy_ratio = unique_bytes.to_double() / 256.0
  let compression_ratio = if entropy_ratio < 0.1 {
    0.3
  } else if entropy_ratio < 0.3 {
    0.5
  } else if entropy_ratio < 0.6 {
    0.7
  } else {
    0.95
  }

  let estimated = (data.length().to_double() * compression_ratio).to_int()
  estimated + 12
}

/// Simple compress function
pub fn compress(data : Bytes) -> @zstd_core.ZSTDResult[Bytes] {
  let config = create_default_config()
  compress_data(data, config)
}

/// Compress with context
pub fn compress_with_context(comp : Compressor, data : Bytes) -> @zstd_core.ZSTDResult[(Compressor, Bytes)] {
  let config = create_config_with_level(comp.level)
  match compress_data(data, config) {
    Ok(compressed) => Ok((comp, compressed))
    Err(e) => Err(e)
  }
}

/// Compress data with dictionary
pub fn compress_data_with_dict(
  data: Bytes,
  config: CompressionConfig,
  dictionary: Bytes,
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }

  if dictionary.length() > 0 {
    return compress_with_dictionary_matching(data, config, dictionary, dict_id)
  }

  compress_with_dict_id(data, config, dict_id)
}

/// Compress with dictionary ID in frame header
fn compress_with_dict_id(
  data: Bytes,
  _config: CompressionConfig,
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }

  if is_rle_beneficial(data) {
    return compress_as_rle_block_with_dict(data, dict_id)
  }

  compress_as_raw_block_with_dict(data, dict_id)
}

/// Compress as raw block with dictionary ID
fn compress_as_raw_block_with_dict(data: Bytes, dict_id: UInt) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE

  write_zstd_magic(output)
  let fhd: Byte = 0x23
  output.push(fhd)
  write_dict_id(output, dict_id)
  write_frame_content_size_with_dict(output, data.length(), 4)

  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    write_block_header(output, is_last, 0, chunk_size)
    for i = 0; i < chunk_size; i = i + 1 {
      output.push(data[pos + i])
    }
    pos = pos + chunk_size
  }

  Ok(Bytes::from_array(output))
}

/// Compress as RLE block with dictionary ID
fn compress_as_rle_block_with_dict(data: Bytes, dict_id: UInt) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }

  let first_byte = data[0]
  let mut all_same = true
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] != first_byte {
      all_same = false
      break
    }
  }

  if !all_same {
    return compress_as_raw_block_with_dict(data, dict_id)
  }

  let output: Array[Byte] = []
  write_zstd_magic(output)
  let fhd: Byte = 0x23
  output.push(fhd)
  write_dict_id(output, dict_id)
  write_frame_content_size_with_dict(output, data.length(), 4)

  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE
  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    write_block_header(output, is_last, 1, chunk_size)
    output.push(first_byte)
    pos = pos + chunk_size
  }

  Ok(Bytes::from_array(output))
}

/// Compress with dictionary matching
fn compress_with_dictionary_matching(
  data: Bytes,
  config: CompressionConfig,
  dictionary: Bytes,
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  let hash_table = Array::make(hash_table_size, -1)
  preload_dictionary_to_hash_table(dictionary, hash_table)

  let window_size = 1 << config.window_log
  let sequences_result = generate_sequences_with_dict(data, dictionary, hash_table, config.min_match, window_size)

  match sequences_result {
    Ok((sequences, literals)) => {
      if sequences.length() > 0 && should_use_compressed_block(data, sequences, literals) {
        compress_as_compressed_block_with_dict(data, sequences, literals, dict_id)
      } else {
        compress_with_dict_id(data, config, dict_id)
      }
    }
    Err(_) => compress_with_dict_id(data, config, dict_id)
  }
}

/// Compress as compressed block with dictionary ID
fn compress_as_compressed_block_with_dict(
  data: Bytes,
  sequences: Array[Sequence],
  literals: Array[Byte],
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []

  write_zstd_magic(output)
  let fhd: Byte = 0x23
  output.push(fhd)
  write_dict_id(output, dict_id)
  write_frame_content_size_with_dict(output, data.length(), 4)

  let block_content: Array[Byte] = []
  encode_literals_section(literals, block_content)

  let num_sequences = sequences.length()
  write_sequence_count(block_content, num_sequences)

  if num_sequences > 0 {
    block_content.push(0x00)
    match encode_sequences_predefined_fse(sequences, block_content) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }

  write_block_header(output, true, 2, block_content.length())
  for i = 0; i < block_content.length(); i = i + 1 {
    output.push(block_content[i])
  }

  Ok(Bytes::from_array(output))
}
