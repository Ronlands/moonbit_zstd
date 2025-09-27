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
} derive(Eq)

/// Error constructors
pub fn invalid_data_error() -> ZSTDError { InvalidData }
pub fn invalid_magic_number_error() -> ZSTDError { InvalidMagicNumber }
pub fn invalid_frame_header_error() -> ZSTDError { InvalidFrameHeader }
pub fn unknown_block_type_error() -> ZSTDError { UnknownBlockType }
pub fn insufficient_data_error() -> ZSTDError { InsufficientData }
pub fn compression_error() -> ZSTDError { CompressionError }
pub fn decompression_error() -> ZSTDError { DecompressionError }

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

/// Decompression context
pub struct DecompressionContext {
  window_buffer: Bytes
  dictionary: Bytes
  window_size: Int
  window_pos: Int
  frame_content_size: Int
} derive(Default)

/// Create new decompression context with parameters
pub fn make_decompression_context_with_params(
  window_buffer: Bytes,
  dictionary: Bytes,
  window_size: Int,
  window_pos: Int,
  frame_content_size: Int
) -> DecompressionContext {
  { window_buffer, dictionary, window_size, window_pos, frame_content_size }
}

/// Create new decompression context with defaults
pub fn make_decompression_context() -> DecompressionContext {
  {
    window_buffer: b"",
    dictionary: b"",
    window_size: 65536,
    window_pos: 0,
    frame_content_size: 0
  }
}

/// Block type enumeration
pub enum BlockType {
  Raw
  RLE
  Compressed
  Reserved
} derive(Eq)

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

/// ZSTD magic number constant
pub const ZSTD_MAGIC_NUMBER : UInt = 0xFD2FB528U

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
  }
}