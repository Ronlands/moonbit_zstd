/// Core types for ZSTD implementation
/// Basic type definitions used across all modules

/// ZSTD error types
pub enum ZSTDError {
  InvalidData
  InvalidMagicNumber
  InvalidFrameHeader
  UnknownBlockType
  InsufficientData
  CompressionError
  DecompressionError
  Message(String)  // Generic error with custom message
  ParseError(String)  // Parsing errors
  ValidationError(String)  // Validation errors
} derive(Eq)

/// Error constructors
pub fn invalid_data_error() -> ZSTDError { InvalidData }
pub fn invalid_magic_number_error() -> ZSTDError { InvalidMagicNumber }
pub fn invalid_frame_header_error() -> ZSTDError { InvalidFrameHeader }
pub fn unknown_block_type_error() -> ZSTDError { UnknownBlockType }
pub fn insufficient_data_error() -> ZSTDError { InsufficientData }
pub fn compression_error() -> ZSTDError { CompressionError }
pub fn decompression_error() -> ZSTDError { DecompressionError }
pub fn message_error(msg: String) -> ZSTDError { Message(msg) }
pub fn parse_error(msg: String) -> ZSTDError { ParseError(msg) }
pub fn validation_error(msg: String) -> ZSTDError { ValidationError(msg) }

/// ZSTD result type
pub typealias Result[T, ZSTDError] as ZSTDResult[T]

/// Frame type enumeration
pub enum FrameType {
  ZSTD_frame
  Skippable_frame
}

/// Implement Default for FrameType - Default to ZSTD_frame
impl Default for FrameType with default() { ZSTD_frame }

/// FrameType constructors
pub fn zstd_frame_type() -> FrameType { ZSTD_frame }
pub fn skippable_frame_type() -> FrameType { Skippable_frame }

/// Frame header structure
pub struct FrameHeader {
  frame_type: FrameType
  dict_id: Int
  frame_content_size: Int
  single_segment: Bool
  checksum_flag: Bool
  window_size: Int
} derive(Default)

/// Create new frame header
pub fn make_frame_header(
  frame_type: FrameType,
  dict_id: Int,
  frame_content_size: Int,
  single_segment: Bool,
  checksum_flag: Bool,
  window_size: Int
) -> FrameHeader {
  { frame_type, dict_id, frame_content_size, single_segment, checksum_flag, window_size }
}

/// Decompression context with Huffman tree storage
pub struct DecompressionContext {
  window_buffer: Bytes
  dictionary: Bytes
  window_size: Int
  window_pos: Int
  frame_content_size: Int
  last_huffman_tree: Option[HuffmanTreeRef]  // 保存上一个 Huffman 树（用于未来扩展）
} derive(Default)

/// Huffman 树引用（用于 Treeless 模式）
pub struct HuffmanTreeRef {
  // 存储 Huffman 权重，以便重建树
  weights: Array[Int]
  max_symbol: Int
}

/// Create Huffman tree reference
pub fn create_huffman_tree_ref(weights: Array[Int], max_symbol: Int) -> HuffmanTreeRef {
  { weights, max_symbol }
}

/// Create new decompression context with parameters
pub fn make_decompression_context_with_params(
  window_buffer: Bytes,
  dictionary: Bytes,
  window_size: Int,
  window_pos: Int,
  frame_content_size: Int
) -> DecompressionContext {
  { 
    window_buffer, 
    dictionary, 
    window_size, 
    window_pos, 
    frame_content_size,
    last_huffman_tree: None
  }
}

/// Create new decompression context with defaults
pub fn make_decompression_context() -> DecompressionContext {
  {
    window_buffer: b"",
    dictionary: b"",
    window_size: 65536,
    window_pos: 0,
    frame_content_size: 0,
    last_huffman_tree: None
  }
}

/// Block type enumeration
pub enum BlockType {
  Raw
  RLE
  Compressed
  Reserved
} derive(Eq)

/// Implement Default for BlockType - Default to Raw
impl Default for BlockType with default() { Raw }

/// BlockType constructors
pub fn raw_block_type() -> BlockType { Raw }
pub fn rle_block_type() -> BlockType { RLE }
pub fn compressed_block_type() -> BlockType { Compressed }
pub fn reserved_block_type() -> BlockType { Reserved }

/// Literals type enumeration
pub enum LiteralsType {
  Raw
  RLE
  Compressed
  Treeless
} derive(Eq)

/// Implement Default for LiteralsType - Default to Raw
impl Default for LiteralsType with default() { Raw }

/// LiteralsType constructors
pub fn raw_literals_type() -> LiteralsType { Raw }
pub fn rle_literals_type() -> LiteralsType { RLE }
pub fn compressed_literals_type() -> LiteralsType { Compressed }
pub fn treeless_literals_type() -> LiteralsType { Treeless }

/// Sequence structure
pub struct Sequence {
  literal_length: Int
  match_length: Int
  offset: Int
} derive(Default)

/// Create new sequence
pub fn make_sequence(literal_length: Int, match_length: Int, offset: Int) -> Sequence {
  { literal_length, match_length, offset }
}

/// Accessor functions for Sequence
pub fn get_sequence_literal_length(seq: Sequence) -> Int { seq.literal_length }
pub fn get_sequence_offset(seq: Sequence) -> Int { seq.offset }
pub fn get_sequence_match_length(seq: Sequence) -> Int { seq.match_length }

/// Sequence mode enumeration
pub enum SequenceMode {
  Predefined       // Use predefined FSE table
  RLE              // RLE encoding
  FSECompressed    // FSE compressed
  Repeat           // Repeat previous table
} derive(Eq)

/// Implement Default for SequenceMode - Default to Predefined
impl Default for SequenceMode with default() { Predefined }

/// SequenceMode constructors
pub fn predefined_mode() -> SequenceMode { Predefined }
pub fn rle_mode() -> SequenceMode { RLE }
pub fn fse_compressed_mode() -> SequenceMode { FSECompressed }
pub fn repeat_mode() -> SequenceMode { Repeat }

/// Block header structure
pub struct BlockHeader {
  block_type: BlockType
  block_size: Int
  last_block: Bool
} derive(Default)

/// Create new block header
pub fn make_block_header(block_type: BlockType, block_size: Int, last_block: Bool) -> BlockHeader {
  { block_type, block_size, last_block }
}

/// Literals header structure
pub struct LiteralsHeader {
  literals_type: LiteralsType
  size: Int
  regenerated_size: Int
  streams_count: Int
} derive(Default)

/// Create new literals header
pub fn make_literals_header(
  literals_type: LiteralsType,
  size: Int,
  regenerated_size: Int,
  streams_count: Int
) -> LiteralsHeader {
  { literals_type, size, regenerated_size, streams_count }
}

/// Literals section info structure
pub struct LiteralsSectionInfo {
  literals_type: LiteralsType
  regenerated_size: Int
  compressed_size: Int
  num_streams: Int
} derive(Default)

/// Create new literals section info
pub fn make_literals_section_info(
  literals_type: LiteralsType,
  regenerated_size: Int,
  compressed_size: Int,
  num_streams: Int
) -> LiteralsSectionInfo {
  { literals_type, regenerated_size, compressed_size, num_streams }
}

/// Sequences section info structure
pub struct SequencesSectionInfo {
  num_sequences: Int
  ll_mode: SequenceMode
  ml_mode: SequenceMode
  of_mode: SequenceMode
} derive(Default)

/// Create new sequences section info
pub fn make_sequences_section_info(
  num_sequences: Int,
  ll_mode: SequenceMode,
  ml_mode: SequenceMode,
  of_mode: SequenceMode
) -> SequencesSectionInfo {
  { num_sequences, ll_mode, ml_mode, of_mode }
}

// ============================================================================
// ZSTD Format Constants
// ============================================================================

/// ZSTD magic number constant (RFC 8878)
pub const ZSTD_MAGIC_NUMBER : UInt = 0xFD2FB528U

/// ZSTD magic number as Int for comparison
pub const ZSTD_MAGIC_NUMBER_INT : Int = 0xFD2FB528

/// Skippable frame magic number range start
pub const ZSTD_SKIPPABLE_MAGIC_MIN : Int = 0x184D2A50

/// Skippable frame magic number range end  
pub const ZSTD_SKIPPABLE_MAGIC_MAX : Int = 0x184D2A5F

/// Skippable frame magic number mask
pub const ZSTD_SKIPPABLE_MAGIC_MASK : Int = 0xFFFFFFF0

/// Maximum block size (128 KB)
pub const ZSTD_MAX_BLOCK_SIZE : Int = 131072

/// Block header size (3 bytes)
pub const ZSTD_BLOCK_HEADER_SIZE : Int = 3

/// Frame magic number size (4 bytes)
pub const ZSTD_MAGIC_NUMBER_SIZE : Int = 4

/// Convert error to string
pub fn error_to_string(error: ZSTDError) -> String {
  match error {
    ZSTDError::InvalidData => "Invalid data"
    ZSTDError::InvalidMagicNumber => "Invalid magic number"
    ZSTDError::InvalidFrameHeader => "Invalid frame header"
    ZSTDError::UnknownBlockType => "Unknown block type"
    ZSTDError::InsufficientData => "Insufficient data"
    ZSTDError::CompressionError => "Compression error"
    ZSTDError::DecompressionError => "Decompression error"
    ZSTDError::Message(msg) => msg
    ZSTDError::ParseError(msg) => "Parse error: " + msg
    ZSTDError::ValidationError(msg) => "Validation error: " + msg
  }
}

/// Convert string to ZSTDError (for backward compatibility)
pub fn string_to_error(msg: String) -> ZSTDError {
  Message(msg)
}

/// Convert Result[T, String] to Result[T, ZSTDError]
pub fn[T] result_from_string(result: Result[T, String]) -> Result[T, ZSTDError] {
  match result {
    Ok(value) => Ok(value)
    Err(msg) => Err(Message(msg))
  }
}

/// Convert Result[T, ZSTDError] to Result[T, String]
pub fn[T] result_to_string(result: Result[T, ZSTDError]) -> Result[T, String] {
  match result {
    Ok(value) => Ok(value)
    Err(error) => Err(error_to_string(error))
  }
}

// ============================================================================
// Dictionary Types - Unified Definition
// ============================================================================

/// Dictionary type enumeration
pub enum DictionaryType {
  None          // No dictionary
  Raw           // Raw dictionary
  Formatted     // Formatted ZSTD dictionary
} derive(Eq)

/// Dictionary information structure
pub struct Dictionary {
  dict_type: DictionaryType
  dict_id: UInt             // Dictionary ID
  data: Bytes               // Dictionary data
  size: Int                 // Dictionary size
}

/// Create empty dictionary
pub fn create_empty_dictionary() -> Dictionary {
  {
    dict_type: None,
    dict_id: 0U,
    data: Bytes::from_array([]),
    size: 0
  }
}

/// Create raw dictionary
pub fn create_raw_dictionary_from_data(data: Bytes, dict_id: UInt) -> Dictionary {
  {
    dict_type: Raw,
    dict_id: dict_id,
    data: data,
    size: data.length()
  }
}

/// Create formatted dictionary
pub fn create_formatted_dictionary(data: Bytes, dict_id: UInt) -> Dictionary {
  {
    dict_type: Formatted,
    dict_id: dict_id,
    data: data,
    size: data.length()
  }
}

// ============================================================================
// Window Buffer Type
// ============================================================================

/// Window buffer for decompression
/// Used to store recently decompressed data for backreference support
pub struct WindowBuffer {
  buffer: Array[Byte]       // Circular buffer
  capacity: Int             // Buffer capacity
  mut position: Int         // Current write position
  mut size: Int             // Current valid data size
  dictionary: Dictionary    // Associated dictionary
}

/// Create window buffer
pub fn create_window_buffer(capacity: Int, dictionary: Dictionary) -> WindowBuffer {
  let actual_capacity = capacity.max(1024)  // Minimum 1KB
  {
    buffer: Array::make(actual_capacity, 0),
    capacity: actual_capacity,
    position: 0,
    size: 0,
    dictionary: dictionary
  }
}

/// Window buffer accessor functions
pub fn get_window_position(window: WindowBuffer) -> Int { window.position }
pub fn get_window_size(window: WindowBuffer) -> Int { window.size }
pub fn get_window_capacity(window: WindowBuffer) -> Int { window.capacity }
pub fn get_window_buffer(window: WindowBuffer) -> Array[Byte] { window.buffer }
pub fn get_window_dictionary(window: WindowBuffer) -> Dictionary { window.dictionary }

/// Window buffer mutator functions
pub fn set_window_position(window: WindowBuffer, position: Int) -> Unit {
  window.position = position
}

pub fn set_window_size(window: WindowBuffer, size: Int) -> Unit {
  window.size = size
}

pub fn increment_window_position(window: WindowBuffer, capacity: Int) -> Unit {
  window.position = (window.position + 1) % capacity
}

pub fn increment_window_size(window: WindowBuffer) -> Unit {
  window.size = window.size + 1
}