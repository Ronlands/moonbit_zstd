/// ZSTD Compressor - LZ77 + Entropy Coding

/// Hash table size for LZ77 matching (64K buckets)
let hash_table_size : Int = 65536

/// Maximum block size (128KB)
let max_block_size : Int = 131072

/// Streaming block size (128KB)
let streaming_block_size : Int = max_block_size

/// 单序列直写路径当前变长编码可承载的最大基础值。
///
/// 这里对应当前实现中的三段式编码：
/// - 1 字节
/// - 2 字节
/// - 3 字节（`0xFF + u16`）
///
/// 对 `LL / (OF-1) / (ML-3)` 来说，可直接表示的最大值为：
/// `0x7F00 + 0xFFFF = 98047`
let single_sequence_varint_max : Int = 0x7F00 + 0xFFFF

/// Streaming checksum seed
let checksum_seed : UInt = 0x9E3779B1U

/// Frame content size thresholds for FCS field size selection
let fcs_threshold_1byte : Int = 256      // < 256: 1-byte FCS
let fcs_threshold_2byte : Int = 65792    // < 65792: 2-byte FCS, else 4-byte FCS

/// Default window size (64KB)
let default_window_size : Int = 65536

/// Helper: Write 16-bit value in little-endian
fn write_u16_le(output: Array[Byte], value: Int) -> Unit {
  output.push((value & 0xFF).to_byte())
  output.push(((value >> 8) & 0xFF).to_byte())
}

/// Helper: Write 32-bit value in little-endian
fn write_u32_le(output: Array[Byte], value: UInt) -> Unit {
  output.push((value & 0xFFU).to_byte())
  output.push(((value >> 8) & 0xFFU).to_byte())
  output.push(((value >> 16) & 0xFFU).to_byte())
  output.push(((value >> 24) & 0xFFU).to_byte())
}

/// Helper: Write 24-bit block header (last_block | block_type | block_size)
fn write_block_header(output: Array[Byte], last_block: Bool, block_type: Int, block_size: Int) -> Unit {
  let last = if last_block { 0x01 } else { 0x00 }
  let header = last | (block_type << 1) | (block_size << 3)
  output.push((header & 0xFF).to_byte())
  output.push(((header >> 8) & 0xFF).to_byte())
  output.push(((header >> 16) & 0xFF).to_byte())
}

/// Helper: Write sequence count header (variable-length encoding)
fn write_sequence_count(output: Array[Byte], count: Int) -> Unit {
  if count < 128 {
    output.push(count.to_byte())
  } else if count < 32768 {
    output.push(((count >> 8) + 128).to_byte())
    output.push((count & 0xFF).to_byte())
  } else {
    output.push(0xFF)
    output.push((count & 0xFF).to_byte())
    output.push(((count >> 8) & 0xFF).to_byte())
  }
}

/// Simple XXH32-like checksum
fn calculate_checksum(data: Bytes) -> UInt {
  let mut hash = checksum_seed
  for i = 0; i < data.length(); i = i + 1 {
    hash = hash + data[i].to_uint()
    hash = hash * 0x85EBCA77U
    hash = hash ^ (hash >> 13)
  }
  hash
}

/// Write 32-bit checksum in little-endian
fn write_checksum(output: Array[Byte], checksum: UInt) -> Unit {
  write_u32_le(output, checksum)
}

/// Write ZSTD magic number (0xFD2FB528 in little-endian)
fn write_zstd_magic(output: Array[Byte]) -> Unit {
  output.push(0x28)
  output.push(0xB5)
  output.push(0x2F)
  output.push(0xFD)
}

/// Write 32-bit dictionary ID in little-endian format
fn write_dict_id(output: Array[Byte], dict_id: UInt) -> Unit {
  write_u32_le(output, dict_id)
}

/// Write frame header descriptor and content size with optional checksum
fn write_frame_header_descriptor_with_checksum(output: Array[Byte], data_length: Int, with_checksum: Bool) -> Unit {
  let checksum_flag = if with_checksum { 0x04 } else { 0x00 }
  if data_length < fcs_threshold_1byte {
    output.push((0x20 | checksum_flag).to_byte())
    output.push(data_length.to_byte())
  } else if data_length < fcs_threshold_2byte {
    output.push((0x60 | checksum_flag).to_byte())
    write_u16_le(output, data_length - fcs_threshold_1byte)
  } else {
    output.push((0xA0 | checksum_flag).to_byte())
    write_u32_le(output, data_length.reinterpret_as_uint())
  }
}

/// Write frame header descriptor and content size based on data length
fn write_frame_header_descriptor(output: Array[Byte], data_length: Int) -> Unit {
  write_frame_header_descriptor_with_checksum(output, data_length, false)
}

/// Write frame content size for dictionary frames (updates FHD byte if needed)
fn write_frame_content_size_with_dict(output: Array[Byte], data_length: Int, fhd_index: Int) -> Unit {
  if data_length < fcs_threshold_1byte {
    output.push(data_length.to_byte())
  } else if data_length < fcs_threshold_2byte {
    output[fhd_index] = 0x63
    write_u16_le(output, data_length - fcs_threshold_1byte)
  } else {
    output[fhd_index] = 0xA3
    write_u32_le(output, data_length.reinterpret_as_uint())
  }
}

pub struct Compressor {
  level: Int
  hash_table: Array[Int]
  window_size: Int
}

priv struct Match {
  offset: Int
  length: Int
}

priv struct LZSequence {
  literal_length: Int
  match_length: Int
  offset: Int
}

pub struct CompressionConfig {
  level: Int         // 1-22
  window_log: Int    // Window = 2^window_log (controls LZ77 match distance limit)
  min_match: Int     // Min match length for LZ77
  search_depth: Int  // Search depth (quality vs speed)
}

pub struct CompressionContext {
  config: CompressionConfig
}

// ============================================================================
// Hash Table Implementation / 哈希表实现
// ============================================================================

/// Hash a 4-byte sequence for pattern matching
fn hash_bytes(data: Bytes, pos: Int) -> Int {
  if pos + 3 >= data.length() {
    return 0
  }

  let b0 = data[pos].to_int() & 0xFF
  let b1 = data[pos + 1].to_int() & 0xFF
  let b2 = data[pos + 2].to_int() & 0xFF
  let b3 = data[pos + 3].to_int() & 0xFF

  // Improved hash: better distribution using bit shifts and XOR
  let hash = ((b0 << 12) ^ (b1 << 8) ^ (b2 << 4) ^ b3) * 506832829
  (hash >> 16) & 0xFFFF
}

/// Find match at given position using hash table (optimized)
fn find_match(data: Bytes, pos: Int, hash_table: Array[Int], min_match: Int, window_size: Int) -> Match {
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

  // Early exit: check min_match bytes first
  let mut i = 0
  while i < min_match && pos + i < data_len {
    if data[match_pos + (i % offset)] != data[pos + i] {
      return Match::{ offset: 0, length: 0 }
    }
    i = i + 1
  }

  let mut match_length = min_match
  let max_match = (data_len - pos).min(131072)

  while match_length < max_match &&
        pos + match_length < data_len &&
        data[match_pos + (match_length % offset)] == data[pos + match_length] {
    match_length = match_length + 1
  }

  Match::{ offset: offset, length: match_length }
}

// ============================================================================
// Compressor Creation / 压缩器创建
// ============================================================================

/// Create new compressor
pub fn new_compressor() -> Compressor {
  let hash_table = Array::make(hash_table_size, -1)
  Compressor::{
    level: 1,
    hash_table: hash_table,
    window_size: default_window_size  // 64KB default window - must match decoder
  }
}

pub fn create_default_config() -> CompressionConfig {
  CompressionConfig::{ level: 3, window_log: 17, min_match: 4, search_depth: 12 }
}

pub fn create_config_with_level(level: Int) -> CompressionConfig {
  let clamped_level = level.max(1).min(22)
  let (window_log, min_match, search_depth) = match clamped_level {
    1 => (16, 4, 4)           // Fast
    2 => (16, 4, 8)
    3 => (17, 4, 12)          // Default
    4 | 5 => (17, 4, 16)
    6 | 7 => (18, 4, 24)      // Better
    8 | 9 => (18, 4, 32)
    10 | 11 | 12 => (19, 3, 48)  // Much better
    13 | 14 | 15 => (19, 3, 64)
    16 | 17 | 18 => (20, 3, 96)  // Ultra
    _ => (20, 3, 128)
  }
  CompressionConfig::{ level: clamped_level, window_log, min_match, search_depth }
}

pub fn create_compression_context(config: CompressionConfig) -> CompressionContext {
  CompressionContext::{ config }
}

// ============================================================================
// LZ77 Compression / LZ77 压缩
// ============================================================================

/// Generate sequences using greedy LZ77 matching with repeat offset optimization
fn generate_sequences(data: Bytes, min_match: Int, window_size: Int) -> (Array[LZSequence], Array[Byte]) {
  let sequences: Array[LZSequence] = []
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
        -1  // Special marker for rep[0]
      } else if offset == rep1 {
        -2  // Special marker for rep[1]
      } else if offset == rep2 {
        -3  // Special marker for rep[2]
      } else {
        rep2 = rep1
        rep1 = rep0
        rep0 = offset
        offset
      }

      sequences.push(LZSequence::{
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

/// 压缩数据 - 支持 Raw / RLE / Compressed 三种块类型
/// 说明：
/// - Raw 块：无压缩，直接存储原始数据
/// - RLE 块：对重复数据进行压缩，可达 2000% 压缩率
/// - Compressed 块：LZ77 + FSE/Huffman 高级压缩
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

/// Compress large data as multiple blocks with optional checksum
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

    let block_result = if is_uniform_byte_sequence(block_data) {
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

  build_compressed_block_payload_from_sequences(sequences, literals)
}

/// 解析序列的实际 offset。
///
/// 单序列直写路径需要把 `rep` 标记先还原为真实 offset，
/// 这样才能判断当前值是否会超出直写编码的承载上限。
fn resolve_sequence_offset_for_direct_encoding(seq: LZSequence) -> Int {
  if seq.offset == -1 {
    1
  } else if seq.offset == -2 {
    4
  } else if seq.offset == -3 {
    8
  } else {
    seq.offset
  }
}

/// 判断单序列是否能被当前旧直写编码稳定承载。
fn can_encode_single_sequence_direct(seq: LZSequence) -> Bool {
  let ll = seq.literal_length
  let ml_minus_3 = seq.match_length - 3
  let of = resolve_sequence_offset_for_direct_encoding(seq)
  let of_minus_1 = of - 1

  ll >= 0 &&
  seq.match_length >= 3 &&
  of >= 1 &&
  ll <= single_sequence_varint_max &&
  ml_minus_3 >= 0 && ml_minus_3 <= single_sequence_varint_max &&
  of_minus_1 >= 0 && of_minus_1 <= single_sequence_varint_max
}

/// 标准一序列编码。
///
/// RFC 8878 并没有“单序列不写 modes byte”的规则，
/// 因此当旧直写表示力不够时，编码侧应回退到标准序列段表示。
/// 这里使用最保守的 `Predefined_Mode`。
fn encode_single_sequence_standard(seq: LZSequence, output: Array[Byte]) -> Result[Unit, @zstd_core.ZSTDError] {
  output.push(0x00)
  encode_sequences_predefined_fse([seq], output)
}

/// 从序列和字面量构建压缩块负载。
///
/// 这个 helper 统一了三类调用方：
/// - 普通压缩块
/// - 带字典匹配的压缩块
/// - 流式压缩中带历史窗口的压缩块
fn build_compressed_block_payload_from_sequences(
  sequences: Array[LZSequence],
  literals: Array[Byte]
) -> Result[Bytes, @zstd_core.ZSTDError] {
  if sequences.length() == 0 {
    return Err(@zstd_core.message_error("No compression benefit - fallback to raw block"))
  }

  let output: Array[Byte] = []

  encode_literals_section(literals, output)

  let num_sequences = sequences.length()
  write_sequence_count(output, num_sequences)

  if num_sequences > 0 {
    if num_sequences == 1 {
      let seq = sequences[0]
      if can_encode_single_sequence_direct(seq) {
        encode_single_sequence_direct(seq, output)
      } else {
        match encode_single_sequence_standard(seq, output) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    } else {
      let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(sequences)

      // Decide whether to use compressed FSE mode
      if should_use_compressed_fse(ll_symbols, ml_symbols, of_symbols) {
        output.push(0x01)  // Compressed mode flag
        match encode_sequences_compressed_fse(sequences, output) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      } else {
        output.push(0x00)  // Predefined mode
        match encode_sequences_predefined_fse(sequences, output) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    }
  }

  Ok(Bytes::from_array(output))
}

/// 从序列和字面量构建保守版压缩块负载。
///
/// 只使用：
/// - 单序列直写
/// - 多序列预定义 FSE
///
/// 不启用自定义压缩 FSE 表，便于在历史窗口压缩场景下优先保证稳定性。
fn build_predefined_compressed_block_payload_from_sequences(
  sequences: Array[LZSequence],
  literals: Array[Byte]
) -> Result[Bytes, @zstd_core.ZSTDError] {
  if sequences.length() == 0 {
    return Err(@zstd_core.message_error("No compression benefit - fallback to raw block"))
  }

  let output: Array[Byte] = []
  encode_literals_section(literals, output)

  let num_sequences = sequences.length()
  write_sequence_count(output, num_sequences)

  if num_sequences > 0 {
    if num_sequences == 1 {
      let seq = sequences[0]
      if can_encode_single_sequence_direct(seq) {
        encode_single_sequence_direct(seq, output)
      } else {
        match encode_single_sequence_standard(seq, output) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
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

/// 判断是否应该尝试 Compressed block
fn should_try_compressed_block(data: Bytes) -> Bool {
  // 数据足够大且有一定的重复模式
  data.length() >= 64
}

/// Check if RLE compression would be beneficial
fn is_rle_beneficial(data: Bytes) -> Bool {
  if data.length() < 4 {
    return false
  }
  
  // Sample the data to check for repetition
  let first_byte = data[0]
  let mut same_count = 0
  let sample_size = data.length().min(100)
  
  for i = 0; i < sample_size; i = i + 1 {
    if data[i] == first_byte {
      same_count = same_count + 1
    }
  }
  
  // If more than 80% are the same, use RLE
  (same_count * 10) > (sample_size * 8)
}

/// 检查整个字节序列是否都由同一个字节组成。
///
/// 说明：
/// - 这是 RLE 块合法性的严格条件
/// - 与 `is_rle_beneficial` 不同，这里不使用抽样启发式
/// - 只有全量相同字节时，才能安全写成标准 RLE 块
fn is_uniform_byte_sequence(data: Bytes) -> Bool {
  if data.length() == 0 {
    return false
  }

  let first_byte = data[0]
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] != first_byte {
      return false
    }
  }

  true
}

/// Compress as RLE (Run Length Encoding) block
pub fn compress_as_rle_block(data: Bytes, _config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }
  
  // Check if all bytes are the same
  let first_byte = data[0]
  let mut all_same = true
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] != first_byte {
      all_same = false
      break
    }
  }
  
  if !all_same {
    // Fall back to raw block if not all bytes are the same
    return compress_as_raw_block(data, _config)
  }
  
  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header Descriptor and Content Size
  write_frame_header_descriptor(output, data.length())

  // Block Header: Last_Block=1, Block_Type=RLE(1), Block_Size (decompressed size ≤ 128KB per chunk)
  // Splits into multiple RLE blocks if data exceeds ZSTD_MAX_BLOCK_SIZE.
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE
  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    write_block_header(output, is_last, 1, chunk_size)
    // RLE block payload: single byte to repeat
    output.push(first_byte)
    pos = pos + chunk_size
  }
  
  Ok(Bytes::from_array(output))
}

/// Compress as raw (uncompressed) block.
/// Splits data into multiple blocks when it exceeds 128KB (ZSTD_MAX_BLOCK_SIZE).
pub fn compress_as_raw_block(data: Bytes, _config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header Descriptor and Content Size
  write_frame_header_descriptor(output, data.length())

  // Emit one or more Raw blocks, each ≤ max_block bytes
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

/// Compress empty data
fn compress_empty_frame() -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header: Single segment, no checksum, FCS=0
  output.push(0x20)
  output.push(0x00)  // Content size = 0
  
  // Empty last block
  output.push(0x01)
  output.push(0x00)
  output.push(0x00)
  
  Ok(Bytes::from_array(output))
}

/// 估算压缩大小
pub fn estimate_compressed_size(data: Bytes, _config: CompressionConfig) -> Int {
  if data.length() == 0 {
    return 10  // Empty frame overhead
  }

  // Check for RLE (highly compressible)
  if is_rle_beneficial(data) {
    return 10 + (data.length() / 128000) * 4  // RLE block overhead
  }

  // Analyze data entropy
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

  // Estimate based on entropy
  let entropy_ratio = unique_bytes.to_double() / 256.0
  let compression_ratio = if entropy_ratio < 0.1 {
    0.3  // Low entropy, good compression
  } else if entropy_ratio < 0.3 {
    0.5  // Medium-low entropy
  } else if entropy_ratio < 0.6 {
    0.7  // Medium entropy
  } else {
    0.95  // High entropy, poor compression
  }

  let estimated = (data.length().to_double() * compression_ratio).to_int()
  estimated + 12  // Add frame header overhead
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

// ============================================================================
// Dictionary Compression Support / 字典压缩支持
// ============================================================================

/// Compress data with dictionary
pub fn compress_data_with_dict(
  data: Bytes,
  config: CompressionConfig,
  dictionary: Bytes,  // 用于在压缩时进行字典匹配
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }
  
  // ✅ 字典匹配实现：将字典内容预加载到哈希表
  // 这可以显著提高相似数据的压缩比
  if dictionary.length() > 0 {
    return compress_with_dictionary_matching(data, config, dictionary, dict_id)
  }

  compress_with_dict_id(data, config, dict_id)
}

