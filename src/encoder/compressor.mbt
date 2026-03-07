/// ZSTD Compressor - LZ77 + Entropy Coding
///
/// 支持功能：
/// - ✅ Raw 块（无压缩）
/// - ✅ RLE 块（重复数据压缩，可达 2000% 压缩率）
/// - ✅ 压缩级别 1-22（可配置窗口大小和搜索深度）
/// - ⏳ Compressed 块（LZ77 + FSE/Huffman，待完善）

/// Hash table size for LZ77 matching (64K buckets)
let hash_table_size : Int = 65536

/// Frame content size thresholds for FCS field size selection
let fcs_threshold_1byte : Int = 256      // < 256: 1-byte FCS
let fcs_threshold_2byte : Int = 65792    // < 65792: 2-byte FCS, else 4-byte FCS

/// Default window size (64KB)
let default_window_size : Int = 65536

/// Write ZSTD magic number (0xFD2FB528 in little-endian)
fn write_zstd_magic(output: Array[Byte]) -> Unit {
  output.push(0x28)
  output.push(0xB5)
  output.push(0x2F)
  output.push(0xFD)
}

/// Write 32-bit dictionary ID in little-endian format
fn write_dict_id(output: Array[Byte], dict_id: UInt) -> Unit {
  output.push((dict_id & 0xFFU).to_byte())
  output.push(((dict_id >> 8) & 0xFFU).to_byte())
  output.push(((dict_id >> 16) & 0xFFU).to_byte())
  output.push(((dict_id >> 24) & 0xFFU).to_byte())
}

/// Write frame header descriptor and content size based on data length
fn write_frame_header_descriptor(output: Array[Byte], data_length: Int) -> Unit {
  if data_length < fcs_threshold_1byte {
    // FCS_Field_Size = 0 (1 byte), Single_Segment = 1
    output.push(0x20)
    output.push(data_length.to_byte())
  } else if data_length < fcs_threshold_2byte {
    // FCS_Field_Size = 1 (2 bytes), Single_Segment = 1
    output.push(0x60)
    let size_minus_256 = data_length - fcs_threshold_1byte
    output.push((size_minus_256 & 0xFF).to_byte())
    output.push(((size_minus_256 >> 8) & 0xFF).to_byte())
  } else {
    // FCS_Field_Size = 2 (4 bytes), Single_Segment = 1
    output.push(0xA0)
    output.push((data_length & 0xFF).to_byte())
    output.push(((data_length >> 8) & 0xFF).to_byte())
    output.push(((data_length >> 16) & 0xFF).to_byte())
    output.push(((data_length >> 24) & 0xFF).to_byte())
  }
}

/// Write frame content size for dictionary frames (updates FHD byte if needed)
fn write_frame_content_size_with_dict(output: Array[Byte], data_length: Int, fhd_index: Int) -> Unit {
  if data_length < fcs_threshold_1byte {
    // FCS_flag=0: FHD = 0x23, 1-byte FCS
    output.push(data_length.to_byte())
  } else if data_length < fcs_threshold_2byte {
    // FCS_flag=1: FHD = 0x63, 2-byte FCS (value - 256)
    output[fhd_index] = 0x63
    let size_minus_256 = data_length - fcs_threshold_1byte
    output.push((size_minus_256 & 0xFF).to_byte())
    output.push(((size_minus_256 >> 8) & 0xFF).to_byte())
  } else {
    // FCS_flag=2: FHD = 0xA3, 4-byte FCS
    output[fhd_index] = 0xA3
    output.push((data_length & 0xFF).to_byte())
    output.push(((data_length >> 8) & 0xFF).to_byte())
    output.push(((data_length >> 16) & 0xFF).to_byte())
    output.push(((data_length >> 24) & 0xFF).to_byte())
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

priv struct Sequence {
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
  
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  let b3 = data[pos + 3].to_int()
  
  // Simple hash function
  let hash = (b0 * 31 + b1) * 31 + b2 * 31 + b3
  hash & 0xFFFF  // 65536 buckets
}

/// Find match at given position using hash table
fn find_match(data: Bytes, pos: Int, hash_table: Array[Int], min_match: Int, window_size: Int) -> Match {
  if pos + min_match > data.length() {
    return Match::{ offset: 0, length: 0 }
  }

  let hash = hash_bytes(data, pos)
  let match_pos = hash_table[hash]

  if match_pos == -1 || match_pos >= pos {
    return Match::{ offset: 0, length: 0 }
  }

  let offset = pos - match_pos
  // ZSTD window size limit
  if offset > window_size {
    return Match::{ offset: 0, length: 0 }
  }

  // ZSTD allows match length > offset (overlapping copy)
  let mut match_length = 0
  let max_match = (data.length() - pos).min(131072)

  while match_length < max_match &&
        pos + match_length < data.length() &&
        data[match_pos + (match_length % offset)] == data[pos + match_length] {
    match_length = match_length + 1
  }

  if match_length >= min_match {
    Match::{ offset: offset, length: match_length }
  } else {
    Match::{ offset: 0, length: 0 }
  }
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

/// Generate sequences using greedy LZ77 matching (multi-sequence)
fn generate_sequences(data: Bytes, min_match: Int, window_size: Int) -> (Array[Sequence], Array[Byte]) {
  let sequences: Array[Sequence] = []
  let literals: Array[Byte] = []
  let hash_table = Array::make(hash_table_size, -1)

  let mut pos = 0
  let mut literal_start = 0

  while pos < data.length() {
    let match_result = find_match(data, pos, hash_table, min_match, window_size)

    if match_result.length >= min_match {
      let literal_length = pos - literal_start
      for i = literal_start; i < pos; i = i + 1 {
        literals.push(data[i])
      }

      sequences.push(Sequence::{
        literal_length,
        match_length: match_result.length,
        offset: match_result.offset,
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
pub fn compress_data(data: Bytes, config: CompressionConfig) -> Result[Bytes, String] {
  if data.length() == 0 { return compress_empty_frame() }
  if is_rle_beneficial(data) {
    return compress_as_rle_block(data, config)
  }

  if should_try_compressed_block(data) {
    match compress_as_compressed_block(data, config) {
      Ok(compressed) => {
        // 只在压缩后更小时才使用压缩块
        if compressed.length() < data.length() + 12 {
          return Ok(compressed)
        }
        // 压缩后反而更大，回退到 Raw 块
        return compress_as_raw_block(data, config)
      }
      Err(_) => {
        return compress_as_raw_block(data, config)
      }
    }
  }

  compress_as_raw_block(data, config)
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

/// Compress as RLE (Run Length Encoding) block
pub fn compress_as_rle_block(data: Bytes, _config: CompressionConfig) -> Result[Bytes, String] {
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
    let last_flag = if is_last { 1 } else { 0 }
    let block_header = last_flag | (1 << 1) | (chunk_size << 3)
    output.push((block_header & 0xFF).to_byte())
    output.push(((block_header >> 8) & 0xFF).to_byte())
    output.push(((block_header >> 16) & 0xFF).to_byte())
    // RLE block payload: single byte to repeat
    output.push(first_byte)
    pos = pos + chunk_size
  }
  
  Ok(Bytes::from_array(output))
}

/// Compress as raw (uncompressed) block.
/// Splits data into multiple blocks when it exceeds 128KB (ZSTD_MAX_BLOCK_SIZE).
pub fn compress_as_raw_block(data: Bytes, _config: CompressionConfig) -> Result[Bytes, String] {
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

    let last_flag = if is_last { 1 } else { 0 }
    let block_header = last_flag | (0 << 1) | (chunk_size << 3)
    output.push((block_header & 0xFF).to_byte())
    output.push(((block_header >> 8) & 0xFF).to_byte())
    output.push(((block_header >> 16) & 0xFF).to_byte())

    for i = 0; i < chunk_size; i = i + 1 {
      output.push(data[pos + i])
    }
    pos = pos + chunk_size
  }
  
  Ok(Bytes::from_array(output))
}

/// Compress empty data
fn compress_empty_frame() -> Result[Bytes, String] {
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
    let b = data[i].to_int()
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
  match compress_data(data, config) {
    Ok(compressed) => Ok(compressed)
    Err(e) => Err(@zstd_core.message_error(e))
  }
}

/// Compress with context
pub fn compress_with_context(comp : Compressor, data : Bytes) -> @zstd_core.ZSTDResult[(Compressor, Bytes)] {
  let config = create_config_with_level(comp.level)
  match compress_data(data, config) {
    Ok(compressed) => Ok((comp, compressed))
    Err(e) => Err(@zstd_core.message_error(e))
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
) -> Result[Bytes, String] {
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

/// Compress with dictionary ID in frame header
fn compress_with_dict_id(
  data: Bytes, 
  _config: CompressionConfig,
  dict_id: UInt
) -> Result[Bytes, String] {
  if data.length() == 0 {
    return compress_empty_frame()
  }
  
  // Check if data is RLE beneficial
  if is_rle_beneficial(data) {
    return compress_as_rle_block_with_dict(data, dict_id)
  }
  
  // Use raw block with dictionary ID
  compress_as_raw_block_with_dict(data, dict_id)
}

/// Compress as raw block with dictionary ID.
/// Splits data into multiple blocks when it exceeds 128KB.
fn compress_as_raw_block_with_dict(data: Bytes, dict_id: UInt) -> Result[Bytes, String] {
  let output: Array[Byte] = []
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header Descriptor with Dictionary_ID_Flag=3 (4 bytes)
  let fhd: Byte = 0x23  // Single_Segment=1, Dictionary_ID_Flag=3
  output.push(fhd)

  // Dictionary ID (4 bytes, little-endian)
  write_dict_id(output, dict_id)

  // Frame Content Size
  write_frame_content_size_with_dict(output, data.length(), 4)

  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    let last_flag = if is_last { 1 } else { 0 }
    let block_header = last_flag | (0 << 1) | (chunk_size << 3)
    output.push((block_header & 0xFF).to_byte())
    output.push(((block_header >> 8) & 0xFF).to_byte())
    output.push(((block_header >> 16) & 0xFF).to_byte())
    for i = 0; i < chunk_size; i = i + 1 {
      output.push(data[pos + i])
    }
    pos = pos + chunk_size
  }
  
  Ok(Bytes::from_array(output))
}

/// Encode literals section into block content
/// Automatically selects the best type: RLE (type=1) if all same byte, Raw (type=0) otherwise
fn encode_literals_section(literals: Array[Byte], output: Array[Byte]) -> Unit {
  let size = literals.length()

  if size == 0 {
    // Empty literals: Raw with size=0
    output.push(b'\x00')
    return
  }

  // Check if all literals are the same byte → use RLE (type=1)
  let first = literals[0]
  let mut all_same = true
  for i = 1; i < size; i = i + 1 {
    if literals[i] != first {
      all_same = false
      break
    }
  }

  if all_same {
    // RLE Literals (type=1): header + 1 byte
    // Same header format as Raw but type bits = 01
    if size < 32 {
      output.push(((size << 3) | 0x01).to_byte())
    } else if size < 4096 {
      output.push((((size & 0xF) << 4) | 0x05).to_byte()) // [size_low:4][01][01]
      output.push(((size >> 4) & 0xFF).to_byte())
    } else {
      output.push((((size & 0xF) << 4) | 0x0D).to_byte()) // [size_low:4][11][01]
      output.push(((size >> 4) & 0xFF).to_byte())
      output.push(((size >> 12) & 0xFF).to_byte())
    }
    output.push(first) // Single byte to repeat
    return
  }

  // Raw Literals (type=0): header + all literal bytes
  if size < 32 {
    output.push((size << 3).to_byte())
  } else if size < 4096 {
    output.push((((size & 0xF) << 4) | 0x04).to_byte())
    output.push(((size >> 4) & 0xFF).to_byte())
  } else {
    output.push((((size & 0xF) << 4) | 0x0C).to_byte())
    output.push(((size >> 4) & 0xFF).to_byte())
    output.push(((size >> 12) & 0xFF).to_byte())
  }
  for i = 0; i < size; i = i + 1 {
    output.push(literals[i])
  }
}

/// Compress as compressed block (with LZ77 sequences)
pub fn compress_as_compressed_block(data: Bytes, config: CompressionConfig) -> Result[Bytes, String] {
  let min_match = config.min_match
  let window_size = 1 << config.window_log

  let (sequences, literals) = generate_sequences(data, min_match, window_size)

  if sequences.length() == 0 {
    return Err("No compression benefit - fallback to raw block")
  }

  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header Descriptor and Content Size
  write_frame_header_descriptor(output, data.length())

  // Build block content: Literals_Section + Sequences_Section
  let block_content: Array[Byte] = []

  // --- Literals Section ---
  encode_literals_section(literals, block_content)

  // --- Sequences Section ---
  let num_sequences = sequences.length()
  // Sequence count header
  if num_sequences < 128 {
    block_content.push(num_sequences.to_byte())
  } else if num_sequences < 32768 {
    block_content.push(((num_sequences >> 8) + 128).to_byte())
    block_content.push((num_sequences & 0xFF).to_byte())
  } else {
    block_content.push(0xFF)
    block_content.push((num_sequences & 0xFF).to_byte())
    block_content.push(((num_sequences >> 8) & 0xFF).to_byte())
  }

  if num_sequences > 0 {
    // Compression modes byte: LL=Predefined(0), OF=Predefined(0), ML=Predefined(0)
    block_content.push(0x00)

    match encode_sequences_predefined_fse(sequences, block_content) {
      Ok(_) => ()
      Err(e) => return Err("Failed to encode sequences: \{e}")
    }
  }

  // Block Header: Last_Block=1, Block_Type=Compressed(2), Block_Size
  let block_size = block_content.length()
  let block_header = 0x01 | (2 << 1) | (block_size << 3)
  output.push((block_header & 0xFF).to_byte())
  output.push(((block_header >> 8) & 0xFF).to_byte())
  output.push(((block_header >> 16) & 0xFF).to_byte())

  for i = 0; i < block_content.length(); i = i + 1 {
    output.push(block_content[i])
  }

  Ok(Bytes::from_array(output))
}

// (Huffman literals encoding reserved for future implementation)

// ============================================================================
// Dictionary Matching Implementation / 字典匹配实现
// ============================================================================

/// Compress data with dictionary matching
/// 使用字典进行压缩，预加载字典内容到哈希表以提高压缩比
fn compress_with_dictionary_matching(
  data: Bytes,
  config: CompressionConfig,
  dictionary: Bytes,
  dict_id: UInt
) -> Result[Bytes, String] {
  // 创建哈希表并预加载字典内容
  let hash_table = Array::make(hash_table_size, -1)

  // 将字典内容预加载到哈希表
  // 这样 LZ77 压缩器就能找到数据和字典内容的匹配
  preload_dictionary_to_hash_table(dictionary, hash_table)

  // 计算窗口大小
  let window_size = 1 << config.window_log

  // 使用预加载了字典的哈希表进行 LZ77 压缩
  let sequences_result = generate_sequences_with_dict(data, dictionary, hash_table, config.min_match, window_size)
  
  match sequences_result {
    Ok((sequences, literals)) => {
      // 如果找到了足够的匹配，使用压缩块
      if sequences.length() > 0 && should_use_compressed_block(data, sequences, literals) {
        // 使用完整的 Compressed 块（带字典 ID）
        compress_as_compressed_block_with_dict(data, sequences, literals, dict_id)
      } else {
        // 降级到 RLE 或 Raw 块
        compress_with_dict_id(data, config, dict_id)
      }
    }
    Err(_) => compress_with_dict_id(data, config, dict_id)
  }
}

/// Preload dictionary content into hash table
/// 将字典内容预加载到哈希表，使 LZ77 能找到字典匹配
fn preload_dictionary_to_hash_table(dictionary: Bytes, hash_table: Array[Int]) -> Unit {
  // 遍历字典，将所有 4 字节序列添加到哈希表
  // 使用负数位置表示来自字典的内容
  let dict_len = dictionary.length()
  
  let mut pos = 0
  while pos + 3 < dict_len {
    let hash = hash_bytes(dictionary, pos)
    // 使用负数偏移表示字典位置：-(pos + 1)
    // 这样可以与数据位置（非负）区分
    hash_table[hash] = -(pos + 1)
    pos = pos + 1
  }
}

/// Generate sequences with dictionary support
/// 使用字典增强的 LZ77 序列生成
fn generate_sequences_with_dict(
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
    // 尝试找到匹配（包括字典匹配）
    let match_result = find_match_with_dict(data, dictionary, pos, hash_table, min_match, window_size)
    
    if match_result.length >= min_match {
      // 找到匹配！
      let literal_length = pos - literal_start
      
      // 添加匹配前的字面量
      for i = literal_start; i < pos; i = i + 1 {
        literals.push(data[i])
      }
      
      // 添加序列
      sequences.push(Sequence::{
        literal_length: literal_length,
        match_length: match_result.length,
        offset: match_result.offset
      })
      
      // 更新哈希表（只添加数据中的位置）
      let mut i = pos
      while i < pos + match_result.length && i + 3 < data.length() {
        let hash = hash_bytes(data, i)
        hash_table[hash] = i
        i = i + 1
      }
      
      pos = pos + match_result.length
      literal_start = pos
    } else {
      // 没有找到匹配，更新哈希表
      if pos + 3 < data.length() {
        let hash = hash_bytes(data, pos)
        hash_table[hash] = pos
      }
      pos = pos + 1
    }
  }
  
  // 添加剩余字面量
  for i = literal_start; i < data.length(); i = i + 1 {
    literals.push(data[i])
  }
  
  Ok((sequences, literals))
}

/// Find match with dictionary support
/// 在数据和字典中查找匹配
fn find_match_with_dict(
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

  // 没有匹配
  if match_pos == -1 || match_pos >= pos {
    return Match::{ offset: 0, length: 0 }
  }

  // 区分字典匹配和数据匹配
  if match_pos < 0 {
    // 字典匹配（负数位置）
    let dict_pos = -match_pos - 1
    let match_length = calculate_match_length_from_dict(data, dictionary, pos, dict_pos)

    if match_length >= min_match {
      // 字典匹配的偏移 = 字典长度 - 匹配位置 + 当前输出位置
      // 简化：使用数据开始到当前位置的距离
      let offset = pos + (dictionary.length() - dict_pos)
      Match::{ offset: offset, length: match_length }
    } else {
      Match::{ offset: 0, length: 0 }
    }
  } else {
    // 数据内部匹配
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

/// Calculate match length from dictionary
/// 计算从字典到数据的匹配长度
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
/// 计算数据内部的匹配长度
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

/// Determine if compressed block should be used
/// 判断是否应该使用压缩块
fn should_use_compressed_block(
  data: Bytes,
  sequences: Array[Sequence],
  literals: Array[Byte]
) -> Bool {
  // 估算压缩后的大小
  let literal_size = literals.length()
  let sequence_size = sequences.length() * 6  // 每个序列约 6 字节
  let estimated_compressed_size = literal_size + sequence_size + 20  // 加上头部
  
  // 如果压缩后小于原始数据的 95%，则使用压缩块
  estimated_compressed_size < (data.length() * 95 / 100)
}

// ============================================================================
// Compressed Block Implementation / Compressed 块实现
// ============================================================================









/// 获取预定义的 Literal Lengths 归一化频率

/// 获取预定义的 LL 权重表
fn get_predefined_ll_weights_compressor() -> Array[Int] {
  [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1
  ]
}

/// 获取预定义的 ML 权重表
fn get_predefined_ml_weights_compressor() -> Array[Int] {
  [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1
  ]
}

/// 获取预定义的 OF 权重表
fn get_predefined_of_weights_compressor() -> Array[Int] {
  [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
  ]
}

/// 编码 Literal Length 为符号（使用 RFC 8878 标准表）
fn encode_ll_symbol(ll: Int) -> Int {
  let (code, _) = @zstd_entropy.encode_ll(ll)
  code
}

/// 编码 Match Length 为符号（使用 RFC 8878 标准表）
fn encode_ml_symbol(ml: Int) -> Int {
  let (code, _) = @zstd_entropy.encode_ml(ml)
  code
}

/// 编码 Offset 为符号（使用 RFC 8878 标准表）
fn encode_of_symbol(offset: Int) -> Int {
  let (code, _) = @zstd_entropy.encode_of(offset)
  code
}

/// 提取序列符号（用于 FSE 编码）
fn extract_sequence_symbols(sequences: Array[Sequence]) -> (Array[Int], Array[Int], Array[Int]) {
  let ll_symbols: Array[Int] = []
  let ml_symbols: Array[Int] = []
  let of_symbols: Array[Int] = []

  for i = 0; i < sequences.length(); i = i + 1 {
    let seq = sequences[i]
    ll_symbols.push(encode_ll_symbol(seq.literal_length))
    ml_symbols.push(encode_ml_symbol(seq.match_length))
    of_symbols.push(encode_of_symbol(seq.offset))
  }

  (ll_symbols, ml_symbols, of_symbols)
}

/// Encode sequences using predefined FSE tables
/// Matches official ZSTD_encodeSequences_body order exactly
fn encode_sequences_predefined_fse(sequences: Array[Sequence], output: Array[Byte]) -> Result[Unit, String] {
  if sequences.length() == 0 {
    return Ok(())
  }

  let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(sequences)

  let ll_predefined = @zstd_entropy.normalize_counts(get_predefined_ll_weights_compressor(), 6)
  let ml_predefined = @zstd_entropy.normalize_counts(get_predefined_ml_weights_compressor(), 6)
  let of_predefined = @zstd_entropy.normalize_counts(get_predefined_of_weights_compressor(), 5)

  let ll_table = match @zstd_entropy.build_fse_ctable(ll_predefined, ll_predefined.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err("Failed to build LL FSE table: \{e}")
  }
  let ml_table = match @zstd_entropy.build_fse_ctable(ml_predefined, ml_predefined.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err("Failed to build ML FSE table: \{e}")
  }
  let of_table = match @zstd_entropy.build_fse_ctable(of_predefined, of_predefined.length() - 1, 5) {
    Ok(t) => t
    Err(e) => return Err("Failed to build OF FSE table: \{e}")
  }

  let bitstream = @zstd_entropy.create_bitstream()
  let last_idx = sequences.length() - 1

  // Step 1: Init states with seqN-1 (last sequence) symbols
  let mut ll_state = @zstd_entropy.init_fse_cstate_with_symbol(ll_table, ll_symbols[last_idx])
  let mut ml_state = @zstd_entropy.init_fse_cstate_with_symbol(ml_table, ml_symbols[last_idx])
  let mut of_state = @zstd_entropy.init_fse_cstate_with_symbol(of_table, of_symbols[last_idx])

  // Step 2: Write seqN-1 (last sequence) extras BEFORE the loop: LL, ML, OF
  let last_seq = sequences[last_idx]

  let (_, last_ll_extra) = @zstd_entropy.encode_ll(last_seq.literal_length)
  let last_ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[last_idx])
  if last_ll_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ll_extra.to_uint64(), last_ll_nbits)
  }

  let (_, last_ml_extra) = @zstd_entropy.encode_ml(last_seq.match_length)
  let last_ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[last_idx])
  if last_ml_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ml_extra.to_uint64(), last_ml_nbits)
  }

  let (_, last_of_extra) = @zstd_entropy.encode_of(last_seq.offset)
  let last_of_nbits = @zstd_entropy.get_of_bits(of_symbols[last_idx])
  if last_of_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_of_extra.to_uint64(), last_of_nbits)
  }

  @zstd_entropy.flush_bits(bitstream)

  // Step 3: Loop from N-2 down to 0 — encode state transitions + extras
  let mut n = last_idx - 1
  while n >= 0 {
    let seq = sequences[n]

    // State transitions: OF → ML → LL so decoder reads LL → ML → OF (RFC 8878 order)
    of_state = @zstd_entropy.encode_symbol_fse(of_state, of_symbols[n], of_table, bitstream)
    ml_state = @zstd_entropy.encode_symbol_fse(ml_state, ml_symbols[n], ml_table, bitstream)
    ll_state = @zstd_entropy.encode_symbol_fse(ll_state, ll_symbols[n], ll_table, bitstream)

    // Extra bits: LL, ML, OF (official order)
    let (_, ll_extra) = @zstd_entropy.encode_ll(seq.literal_length)
    let ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[n])
    if ll_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ll_extra.to_uint64(), ll_nbits)
    }

    let (_, ml_extra) = @zstd_entropy.encode_ml(seq.match_length)
    let ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[n])
    if ml_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ml_extra.to_uint64(), ml_nbits)
    }

    let (_, of_extra) = @zstd_entropy.encode_of(seq.offset)
    let of_nbits = @zstd_entropy.get_of_bits(of_symbols[n])
    if of_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, of_extra.to_uint64(), of_nbits)
    }

    @zstd_entropy.flush_bits(bitstream)
    n = n - 1
  }

  // Step 4: Flush final states: ML → OF → LL (official order)
  @zstd_entropy.flush_final_state(bitstream, ml_state, 6)
  @zstd_entropy.flush_final_state(bitstream, of_state, 5)
  @zstd_entropy.flush_final_state(bitstream, ll_state, 6)

  // Step 5: Close bitstream (padding bit)
  @zstd_entropy.close_bitstream(bitstream)

  let encoded = @zstd_entropy.get_bytes(bitstream)
  for i = 0; i < encoded.length(); i = i + 1 {
    output.push(encoded[i])
  }

  Ok(())
}

/// Compress as compressed block with dictionary ID
fn compress_as_compressed_block_with_dict(
  data: Bytes,
  sequences: Array[Sequence],
  literals: Array[Byte],
  dict_id: UInt
) -> Result[Bytes, String] {
  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header with Dictionary ID
  let fhd: Byte = 0x23
  output.push(fhd)

  // Dictionary ID (4 bytes, little-endian)
  write_dict_id(output, dict_id)

  // Frame Content Size
  write_frame_content_size_with_dict(output, data.length(), 4)

  // Build block content: Literals_Section + Sequences_Section
  let block_content: Array[Byte] = []

  // Literals Section
  encode_literals_section(literals, block_content)

  // Sequences Section
  let num_sequences = sequences.length()
  if num_sequences < 128 {
    block_content.push(num_sequences.to_byte())
  } else if num_sequences < 32768 {
    block_content.push(((num_sequences >> 8) + 128).to_byte())
    block_content.push((num_sequences & 0xFF).to_byte())
  } else {
    block_content.push(0xFF)
    block_content.push((num_sequences & 0xFF).to_byte())
    block_content.push(((num_sequences >> 8) & 0xFF).to_byte())
  }

  if num_sequences > 0 {
    block_content.push(0x00)
    match encode_sequences_predefined_fse(sequences, block_content) {
      Ok(_) => ()
      Err(e) => return Err("Failed to encode sequences: \{e}")
    }
  }

  // Block Header
  let block_size = block_content.length()
  let block_header = 0x01 | (2 << 1) | (block_size << 3)
  output.push((block_header & 0xFF).to_byte())
  output.push(((block_header >> 8) & 0xFF).to_byte())
  output.push(((block_header >> 16) & 0xFF).to_byte())

  for i = 0; i < block_content.length(); i = i + 1 {
    output.push(block_content[i])
  }

  Ok(Bytes::from_array(output))
}

/// Compress as RLE block with dictionary ID
fn compress_as_rle_block_with_dict(data: Bytes, dict_id: UInt) -> Result[Bytes, String] {
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

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header with Dictionary ID
  let fhd: Byte = 0x23
  output.push(fhd)
  
  // Dictionary ID
  write_dict_id(output, dict_id)

  // Frame Content Size
  write_frame_content_size_with_dict(output, data.length(), 4)

  // Emit one or more RLE blocks, each with decompressed size ≤ ZSTD_MAX_BLOCK_SIZE
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE
  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    let last_flag = if is_last { 1 } else { 0 }
    let block_header = last_flag | (1 << 1) | (chunk_size << 3)
    output.push((block_header & 0xFF).to_byte())
    output.push(((block_header >> 8) & 0xFF).to_byte())
    output.push(((block_header >> 16) & 0xFF).to_byte())
    output.push(first_byte)
    pos = pos + chunk_size
  }
  
  Ok(Bytes::from_array(output))
}