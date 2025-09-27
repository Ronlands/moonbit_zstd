/// Bit stream reader for ZSTD decompression
/// Handles bit-level reading operations required for entropy decoding

/// Bit stream reader
pub struct BitStream {
  data : Array[Int]
  pos : Int
  bit_pos : Int
  bits : Int
} derive(Show)

/// Create a new bit stream from bytes
pub fn new_bitstream(data : Bytes) -> BitStream {
  let data_array = data.to_array().map(fn(b) { b.to_int() })
  { data: data_array, pos: 0, bit_pos: 0, bits: 0 }
}

/// Read a single bit
pub fn read_bit(stream : BitStream) -> (BitStream, Int) {
  if stream.bit_pos == 0 {
    // Load next byte
    let new_bits = if stream.pos < stream.data.length() {
      stream.data[stream.pos]
    } else {
      0
    }
    let new_stream = { 
      data: stream.data, 
      pos: stream.pos + 1, 
      bit_pos: 8, 
      bits: new_bits 
    }
    (new_stream, new_bits & 1)
  } else {
    let bit = (stream.bits >> (stream.bit_pos - 1)) & 1
    let new_stream = { 
      data: stream.data, 
      pos: stream.pos, 
      bit_pos: stream.bit_pos - 1, 
      bits: stream.bits 
    }
    (new_stream, bit)
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
      stream.data[stream.pos]
    } else {
      0
    }
    let new_stream = { 
      data: stream.data, 
      pos: stream.pos + 1, 
      bit_pos: 0, 
      bits: 0 
    }
    (new_stream, byte)
  } else {
    // Unaligned read - read 8 bits
    let (new_stream, bits) = read_bits(stream, 8)
    (new_stream, bits)
  }
}

/// Check if we have reached the end of the stream
pub fn is_eof(stream : BitStream) -> Bool {
  stream.pos >= stream.data.length()
}

/// Read multiple bytes from the stream
pub fn read_bytes(stream : BitStream, num_bytes : Int) -> (BitStream, Bytes) {
  let mut result : Array[Byte] = []
  let mut current_stream = stream
  
  for i = 0; i < num_bytes; i = i + 1 {
    let (new_stream, byte) = read_byte(current_stream)
    result = result + [byte.to_byte()]
    current_stream = new_stream
  }
  
  (current_stream, Bytes::from_array(result))
}

/// Read little-endian integer of specified bytes
pub fn read_le_int(stream : BitStream, num_bytes : Int) -> (BitStream, Int) {
  let mut result = 0
  let mut current_stream = stream
  
  for i = 0; i < num_bytes; i = i + 1 {
    let (new_stream, byte) = read_byte(current_stream)
    result = result | (byte << (i * 8))
    current_stream = new_stream
  }
  
  (current_stream, result)
}

/// Peek at next byte without advancing the stream
pub fn peek_byte(stream : BitStream) -> Int {
  if stream.bit_pos == 0 && stream.pos < stream.data.length() {
    stream.data[stream.pos]
  } else {
    0
  }
}

/// Skip bytes in the stream
pub fn skip_bytes(stream : BitStream, num_bytes : Int) -> BitStream {
  { 
    data: stream.data, 
    pos: stream.pos + num_bytes, 
    bit_pos: 0, 
    bits: 0 
  }
}

/// Get current position in bytes
pub fn get_position(stream : BitStream) -> Int {
  stream.pos
}