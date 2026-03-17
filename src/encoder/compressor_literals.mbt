/// Literals Section Encoding

/// Encode literals section into block content
pub fn encode_literals_section(literals: Array[Byte], output: Array[Byte]) -> Unit {
  encode_literals_with_huffman(literals, output, true)
}

/// Enhanced literals encoding with Huffman support
fn encode_literals_with_huffman(literals: Array[Byte], output: Array[Byte], use_huffman: Bool) -> Unit {
  let size = literals.length()

  if size == 0 {
    output.push(b'\x00')
    return
  }

  // Check RLE
  let first = literals[0]
  let mut all_same = true
  for i = 1; i < size; i = i + 1 {
    if literals[i] != first {
      all_same = false
      break
    }
  }

  if all_same {
    if size < 32 {
      output.push(((size << 3) | 0x01).to_byte())
    } else if size < 4096 {
      output.push((((size & 0xF) << 4) | 0x05).to_byte())
      output.push(((size >> 4) & 0xFF).to_byte())
    } else {
      output.push((((size & 0xF) << 4) | 0x0D).to_byte())
      output.push(((size >> 4) & 0xFF).to_byte())
      output.push(((size >> 12) & 0xFF).to_byte())
    }
    output.push(first)
    return
  }

  // Try Huffman if enabled and beneficial
  if use_huffman && size >= 32 {
    match try_huffman_encode(literals) {
      Ok(huffman_data) => {
        if huffman_data.length() < size {
          write_huffman_literals(literals.length(), huffman_data, output)
          return
        }
      }
      Err(_) => ()
    }
  }

  // Fallback to Raw
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

fn try_huffman_encode(literals: Array[Byte]) -> Result[Bytes, @zstd_core.ZSTDError] {
  match @zstd_entropy.huffman_encode(literals) {
    Ok(v) => Ok(v)
    Err(msg) => Err(@zstd_core.message_error(msg))
  }
}

fn write_huffman_literals(regen_size: Int, compressed: Bytes, output: Array[Byte]) -> Unit {
  let comp_size = compressed.length()
  if regen_size < 32 && comp_size < 512 {
    output.push(((regen_size << 3) | 0x02).to_byte())
    output.push((comp_size << 2).to_byte())
  } else {
    output.push((((regen_size & 0xF) << 4) | 0x06).to_byte())
    output.push(((regen_size >> 4) & 0xFF).to_byte())
    output.push((comp_size & 0xFF).to_byte())
    output.push(((comp_size >> 8) & 0xFF).to_byte())
  }
  for i = 0; i < comp_size; i = i + 1 {
    output.push(compressed[i])
  }
}
