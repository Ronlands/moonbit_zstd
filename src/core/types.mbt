/// Core types and constants for ZSTD implementation
/// Following RFC 8878 specification

/// ZSTD magic number (4 bytes)
pub const ZSTD_MAGIC_NUMBER : UInt32 = 0x2D_52_28_B5

/// Maximum window size (1MB)
pub const ZSTD_WINDOWLOG_MAX : Int = 23

/// Maximum block size (128KB)
pub const ZSTD_BLOCKSIZE_MAX : Int = 131072

/// Frame header types
pub enum FrameType {
  ZSTD_frame
  SkippableFrame
}

/// Block types
pub enum BlockType {
  Raw
  RLE  
  Compressed
  Reserved
}

/// Sequence types for FSE
pub enum SequenceType {
  LiteralLength
  MatchLength
  Offset
}

/// ZSTD frame header
pub struct FrameHeader {
  frame_type : FrameType
  window_size : Int
  dict_id : Int
  frame_content_size : Int
  single_segment : Bool
  checksum_flag : Bool
}

/// ZSTD block header
pub struct BlockHeader {
  block_type : BlockType
  block_size : Int
  last_block : Bool
}

/// Sequence command
pub struct Sequence {
  literal_length : Int
  match_length : Int
  offset : Int
}

/// FSE table entry
pub struct FSETableEntry {
  symbol : Int
  baseline : Int
  nb_bits : Int
}

/// Huffman table entry
pub struct HuffmanTableEntry {
  symbol : Int
  code : Int
  bits : Int
}

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
}

/// Decompression context
pub struct DecompressionContext {
  window : Bytes
  window_size : Int
  window_pos : Int
}

/// Compression context
pub struct CompressionContext {
  params : CompressionParams
  hash_table : Array[Int]
  chain_table : Array[Int]
}
