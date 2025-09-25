/// Bit stream reader for ZSTD decompression
/// Handles bit-level reading operations required for entropy decoding

/// Bit stream reader
pub struct BitStream {
  data : Bytes
  pos : Int
  bit_pos : Int
  bits : UInt64
}

/// Create a new bit stream
pub fn new_bitstream(data : Bytes) -> BitStream {
  BitStream {
    data: data
    pos: 0
    bit_pos: 0
    bits: 0
  }
}

/// Read a single bit
pub fn read_bit(stream : BitStream) -> (BitStream, Int) {
  if stream.bit_pos == 0 {
    // Load next byte
    let new_bits = if stream.pos < stream.data.length() {
      stream.data[stream.pos].to_int().to_uint64()
    } else {
      0u64
    }
    let new_stream = BitStream {
      data: stream.data
      pos: stream.pos + 1
      bit_pos: 8
      bits: new_bits
    }
    (new_stream, (new_bits & 1u64).to_int())
  } else {
    let bit = (stream.bits >> (stream.bit_pos - 1)) & 1u64
    let new_stream = BitStream {
      data: stream.data
      pos: stream.pos
      bit_pos: stream.bit_pos - 1
      bits: stream.bits
    }
    (new_stream, bit.to_int())
  }
}

/// Read multiple bits (up to 32)
pub fn read_bits(stream : BitStream, num_bits : Int) -> (BitStream, Int) {
  if num_bits == 0 {
    (stream, 0)
  } else {
    let mut result = 0
    let mut current_stream = stream
    let mut remaining = num_bits
    
    while remaining > 0 {
      let (new_stream, bit) = read_bit(current_stream)
      result = (result << 1) | bit
      current_stream = new_stream
      remaining = remaining - 1
    }
    (current_stream, result)
  }
}

/// Read a byte from the stream
pub fn read_byte(stream : BitStream) -> (BitStream, Int) {
  if stream.bit_pos == 0 {
    // Aligned read
    let byte = if stream.pos < stream.data.length() {
      stream.data[stream.pos].to_int()
    } else {
      0
    }
    let new_stream = BitStream {
      data: stream.data
      pos: stream.pos + 1
      bit_pos: 0
      bits: 0
    }
    (new_stream, byte)
  } else {
    // Unaligned read - read 8 bits
    let (new_stream, bits) = read_bits(stream, 8)
    (new_stream, bits)
  }
}

/// Read multiple bytes
pub fn read_bytes(stream : BitStream, count : Int) -> (BitStream, Bytes) {
  let mut result = Bytes::new()
  let mut current_stream = stream
  
  for i = 0; i < count; i = i + 1 {
    let (new_stream, byte) = read_byte(current_stream)
    result = result.append(byte.to_byte())
    current_stream = new_stream
  }
  (current_stream, result)
}

/// Check if we have reached the end of the stream
pub fn is_eof(stream : BitStream) -> Bool {
  stream.pos >= stream.data.length()
}

/// Get current position in bytes
pub fn get_position(stream : BitStream) -> Int {
  stream.pos
}
