/// Basic bitstream operations for ZSTD
/// Simplified implementation for basic functionality
///
/// TODO: 性能优化
/// - [ ] 批量位读取（缓存机制）
/// - [ ] 减少边界检查
/// - [ ] 内联关键函数

/// BitStream structure
pub struct BitStream {
  data: Bytes
  position: Int
}

/// Create new bitstream
pub fn new_bitstream(data: Bytes) -> BitStream {
  BitStream::{ data: data, position: 0 }
}

/// Read bytes from stream
pub fn read_bytes(stream: BitStream, count: Int) -> (BitStream, Bytes) {
  let end_pos = stream.position + count
  if end_pos > stream.data.length() {
    // Return empty bytes if not enough data
    (stream, b"")
  } else {
    let mut result_bytes: Array[Byte] = []
    for i = stream.position; i < end_pos; i = i + 1 {
      result_bytes = result_bytes + [stream.data[i]]
    }
    let new_stream = BitStream::{ data: stream.data, position: end_pos }
    (new_stream, Bytes::from_array(result_bytes))
  }
}

/// Read single byte from stream
pub fn read_byte(stream: BitStream) -> (BitStream, Byte) {
  if stream.position >= stream.data.length() {
    (stream, b'\x00')
  } else {
    let byte_val = stream.data[stream.position]
    let new_stream = BitStream::{ data: stream.data, position: stream.position + 1 }
    (new_stream, byte_val)
  }
}

/// Read little-endian integer
pub fn read_le_int(stream: BitStream, bytes: Int) -> (BitStream, Int) {
  let (new_stream, data) = read_bytes(stream, bytes)
  let mut result = 0
  for i = 0; i < data.length() && i < bytes; i = i + 1 {
    result = result | (data[i].to_int() << (i * 8))
  }
  (new_stream, result)
}

/// Skip bytes in stream
pub fn skip_bytes(stream: BitStream, count: Int) -> BitStream {
  let new_pos = stream.position + count
  if new_pos > stream.data.length() {
    BitStream::{ data: stream.data, position: stream.data.length() }
  } else {
    BitStream::{ data: stream.data, position: new_pos }
  }
}