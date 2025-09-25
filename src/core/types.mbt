/// Core types and constants for ZSTD implementation
/// Following RFC 8878 specification

/// ZSTD magic number (4 bytes)
pub const ZSTD_MAGIC_NUMBER : Int = 0x2D_52_28_B5

/// Maximum window size (1MB)
pub const ZSTD_WINDOWLOG_MAX : Int = 23

/// Maximum block size (128KB)
pub const ZSTD_BLOCKSIZE_MAX : Int = 131072

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
  window : Bytes
  window_size : Int
  window_pos : Int
} derive(Show)

/// Compression context
pub struct CompressionContext {
  params : CompressionParams
  hash_table : Array[Int]
  chain_table : Array[Int]
} derive(Show)

