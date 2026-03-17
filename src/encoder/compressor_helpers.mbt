/// Frame and Block Header Writing Utilities

/// Hash table size for LZ77 matching (64K buckets)
pub let hash_table_size : Int = 65536

/// Maximum block size (128KB)
pub let max_block_size : Int = 131072

/// Frame content size thresholds for FCS field size selection
pub let fcs_threshold_1byte : Int = 256
pub let fcs_threshold_2byte : Int = 65792

/// Default window size (64KB)
pub let default_window_size : Int = 65536

/// Helper: Write 16-bit value in little-endian
pub fn write_u16_le(output: Array[Byte], value: Int) -> Unit {
  output.push((value & 0xFF).to_byte())
  output.push(((value >> 8) & 0xFF).to_byte())
}

/// Helper: Write 32-bit value in little-endian
pub fn write_u32_le(output: Array[Byte], value: UInt) -> Unit {
  output.push((value & 0xFFU).to_byte())
  output.push(((value >> 8) & 0xFFU).to_byte())
  output.push(((value >> 16) & 0xFFU).to_byte())
  output.push(((value >> 24) & 0xFFU).to_byte())
}

/// Helper: Write 24-bit block header (last_block | block_type | block_size)
pub fn write_block_header(output: Array[Byte], last_block: Bool, block_type: Int, block_size: Int) -> Unit {
  let last = if last_block { 0x01 } else { 0x00 }
  let header = last | (block_type << 1) | (block_size << 3)
  output.push((header & 0xFF).to_byte())
  output.push(((header >> 8) & 0xFF).to_byte())
  output.push(((header >> 16) & 0xFF).to_byte())
}

/// Helper: Write sequence count header (variable-length encoding)
pub fn write_sequence_count(output: Array[Byte], count: Int) -> Unit {
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
pub fn calculate_checksum(data: Bytes) -> UInt {
  let mut hash = 0x9E3779B1U
  for i = 0; i < data.length(); i = i + 1 {
    hash = hash + data[i].to_uint()
    hash = hash * 0x85EBCA77U
    hash = hash ^ (hash >> 13)
  }
  hash
}

/// Write 32-bit checksum in little-endian
pub fn write_checksum(output: Array[Byte], checksum: UInt) -> Unit {
  write_u32_le(output, checksum)
}

/// Write ZSTD magic number (0xFD2FB528 in little-endian)
pub fn write_zstd_magic(output: Array[Byte]) -> Unit {
  output.push(0x28)
  output.push(0xB5)
  output.push(0x2F)
  output.push(0xFD)
}

/// Write 32-bit dictionary ID in little-endian format
pub fn write_dict_id(output: Array[Byte], dict_id: UInt) -> Unit {
  write_u32_le(output, dict_id)
}

/// Write frame header descriptor and content size with optional checksum
pub fn write_frame_header_descriptor_with_checksum(output: Array[Byte], data_length: Int, with_checksum: Bool) -> Unit {
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
pub fn write_frame_header_descriptor(output: Array[Byte], data_length: Int) -> Unit {
  write_frame_header_descriptor_with_checksum(output, data_length, false)
}

/// Write frame content size for dictionary frames (updates FHD byte if needed)
pub fn write_frame_content_size_with_dict(output: Array[Byte], data_length: Int, fhd_index: Int) -> Unit {
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
