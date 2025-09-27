/// Core types and constants for ZSTD implementation
/// Following RFC 8878 specification

/// ZSTD magic number (4 bytes) - RFC 8878
pub const ZSTD_MAGIC_NUMBER : UInt = 0xFD2FB528U

/// Maximum window size (1MB) - RFC 8878 limit  
pub const ZSTD_WINDOWLOG_MAX : Int = 23
pub const ZSTD_WINDOWSIZE_MAX : Int = 1 << 23  // 8MB

/// Maximum block size (128KB)
pub const ZSTD_BLOCKSIZE_MAX : Int = 131072

/// Minimum match length
pub const ZSTD_MINMATCH_LENGTH : Int = 3

/// Maximum match distance
pub const ZSTD_MAX_DISTANCE : Int = 1 << 17

/// FSE constants
pub const FSE_MAX_TABLELOG : Int = 12
pub const FSE_DEFAULT_TABLELOG : Int = 6

/// Huffman constants
pub const HUFFMAN_MAX_TABLELOG : Int = 11

/// Literal length codes
pub const LITERAL_LENGTH_CODE_COUNT : Int = 36

/// Match length codes  
pub const MATCH_LENGTH_CODE_COUNT : Int = 53

/// Offset codes
pub const OFFSET_CODE_COUNT : Int = 32

/// Frame header types
pub enum FrameType {
  ZSTD_frame
  SkippableFrame
} derive(Show)

/// Block types
pub enum BlockType {
  Raw
  RLE  
  Compressed
  Reserved
} derive(Show)

/// Sequence types for FSE
pub enum SequenceType {
  LiteralLength
  MatchLength
  Offset
} derive(Show)

/// ZSTD frame header
pub struct FrameHeader {
  frame_type : FrameType
  window_size : Int
  dict_id : Int
  frame_content_size : Int
  single_segment : Bool
  checksum_flag : Bool
} derive(Show)

/// ZSTD block header
pub struct BlockHeader {
  block_type : BlockType
  block_size : Int
  last_block : Bool
} derive(Show)

/// Sequence command
pub struct Sequence {
  literal_length : Int
  match_length : Int
  offset : Int
} derive(Show)

/// FSE table entry
pub struct FSETableEntry {
  symbol : Int
  baseline : Int
  nb_bits : Int
} derive(Show)

/// Huffman table entry
pub struct HuffmanTableEntry {
  symbol : Int
  code : Int
  bits : Int
} derive(Show)

/// Compression parameters
pub struct CompressionParams {
  level : Int
  window_log : Int
  hash_log : Int
  chain_log : Int
  search_log : Int
  min_match : Int
  target_length : Int
  strategy : Int
} derive(Show)

/// Decompression context
pub struct DecompressionContext {
  window_buffer : Bytes
  dictionary : Bytes
  window_size : Int
  window_pos : Int
  frame_content_size : Int
} derive(Show)

/// Compression context
pub struct CompressionContext {
  params : CompressionParams
  hash_table : Array[Int]
  chain_table : Array[Int]
  sequence_buffer : Array[Sequence]
  literals_buffer : Bytes
} derive(Show)

/// Literals section header types
pub enum LiteralsType {
  Raw
  RLE  
  Compressed
  Treeless
} derive(Show)

/// Literals section header
pub struct LiteralsHeader {
  literals_type : LiteralsType
  size_format : Int
  regenerated_size : Int
  compressed_size : Int
} derive(Show)

/// FSE state for sequence decoding
pub struct FSEState {
  state : Int
  table_log : Int
  table : Array[FSETableEntry]
} derive(Show)

/// Huffman decoder state
pub struct HuffmanState {
  state : Int
  table : Array[HuffmanTableEntry]
  table_log : Int
} derive(Show)

/// Error types for ZSTD operations
pub enum ZSTDError {
  InvalidMagicNumber
  InvalidFrameHeader
  InvalidBlockHeader
  InvalidData
  BufferTooSmall
  UnknownBlockType
  CorruptedData
  UnsupportedVersion
} derive(Show)

// ZSTD Result type is Result[T, ZSTDError] - using built-in Result type

