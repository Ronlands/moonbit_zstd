/// 把字面量区编码进块内容。
///
/// 编码顺序：
/// 1. 先检查是否适合 RLE literals
/// 2. 再尝试 Huffman
/// 3. 最后回退到 Raw literals
fn encode_literals_section(literals: Array[Byte], output: Array[Byte]) -> Unit {
  encode_literals_with_huffman(literals, output, true)
}

/// 以“RLE -> Huffman -> Raw”的顺序编码字面量区。
fn encode_literals_with_huffman(literals: Array[Byte], output: Array[Byte], use_huffman: Bool) -> Unit {
  let size = literals.length()

  // 第 1 步：空字面量区直接写空头。
  if size == 0 {
    output.push(b'\x00')
    return
  }

  // 第 2 步：检查是否整段字面量都相同，以便走 RLE 路径。
  let first = literals[0]
  let mut all_same = true
  for i = 1; i < size; i = i + 1 {
    if literals[i] != first {
      all_same = false
      break
    }
  }

  // 第 3 步：满足严格同字节条件时，直接写 RLE literals。
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

  // 第 4 步：在字面量足够大时尝试 Huffman，且只在更小的时候采用。
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

  // 第 5 步：其余情况统一退回 Raw literals。
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

/// 调用 entropy 模块尝试 Huffman 编码。
fn try_huffman_encode(literals: Array[Byte]) -> Result[Bytes, @zstd_core.ZSTDError] {
  match @zstd_entropy.huffman_encode(literals) {
    Ok(v) => Ok(v)
    Err(msg) => Err(@zstd_core.message_error(msg))
  }
}

/// 把 Huffman 编码结果写成字面量区负载。
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

/// 以压缩块形式压缩输入数据。
///
/// 步骤：
/// 1. 先生成 LZ77 序列与字面量区
/// 2. 再把它们编码为块负载
/// 3. 最后补齐帧头和块头
pub fn compress_as_compressed_block(data: Bytes, config: CompressionConfig) -> Result[Bytes, @zstd_core.ZSTDError] {
  let min_match = config.min_match
  let window_size = 1 << config.window_log

  // 第 1 步：根据窗口配置生成 LZ77 序列。
  let (sequences, literals) = generate_sequences(data, min_match, window_size)

  if sequences.length() == 0 {
    return Err(@zstd_core.message_error("No compression benefit - fallback to raw block"))
  }

  // 第 2 步：先写帧头，再构造压缩块负载。
  let output: Array[Byte] = []
  write_zstd_magic(output)
  write_frame_header_descriptor(output, data.length())

  let block_content = match build_predefined_compressed_block_payload_from_sequences(sequences, literals) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }

  // 第 3 步：写块头并拼接块负载。
  let block_size = block_content.length()
  write_block_header(output, true, 2, block_size)
  append_bytes_to_output(output, block_content)

  Ok(Bytes::from_array(output))
}

/// 计算当前数据内部的最长匹配长度。
fn calculate_match_length_in_data(data: Bytes, pos: Int, match_pos: Int) -> Int {
  let mut length = 0
  let max_length = (data.length() - pos).min(131072)

  while length < max_length &&
        match_pos + length < pos &&
        pos + length < data.length() &&
        data[match_pos + length] == data[pos + length] {
    length = length + 1
  }

  length
}

/// 估算压缩收益，判断是否值得写压缩块。
fn should_use_compressed_block(
  data: Bytes,
  sequences: Array[LZSequence],
  literals: Array[Byte]
) -> Bool {
  let literal_size = literals.length()
  let sequence_size = sequences.length() * 6
  let estimated_compressed_size = literal_size + sequence_size + 20
  estimated_compressed_size < (data.length() * 95 / 100)
}

// ============================================================================
// FSE 压缩模式实现
// ============================================================================

/// 统计符号频率。
fn count_frequencies(symbols: Array[Int], max_symbol: Int) -> Array[Int] {
  let freqs = Array::make(max_symbol + 1, 0)
  for i = 0; i < symbols.length(); i = i + 1 {
    let sym = symbols[i]
    if sym >= 0 && sym <= max_symbol {
      freqs[sym] = freqs[sym] + 1
    }
  }
  freqs
}

/// 归一化符号频率，使总和收敛到 `2^accuracy_log`。
fn normalize_frequencies(freqs: Array[Int], accuracy_log: Int) -> Array[Int] {
  let target = 1 << accuracy_log
  let mut total = 0

  // 第 1 步：先计算原始总频率。
  for i = 0; i < freqs.length(); i = i + 1 {
    total = total + freqs[i]
  }

  if total == 0 { return freqs }

  // 第 2 步：按比例缩放到目标范围，并确保非零项至少为 1。
  let normalized = Array::make(freqs.length(), 0)
  let mut sum = 0

  for i = 0; i < freqs.length(); i = i + 1 {
    if freqs[i] > 0 {
      let norm = (freqs[i] * target / total).max(1)
      normalized[i] = norm
      sum = sum + norm
    }
  }

  // 第 3 步：通过增减最大项把总和精确拉回 target。
  while sum > target {
    let mut max_idx = 0
    for i = 0; i < normalized.length(); i = i + 1 {
      if normalized[i] > normalized[max_idx] {
        max_idx = i
      }
    }
    normalized[max_idx] = normalized[max_idx] - 1
    sum = sum - 1
  }

  while sum < target {
    let mut max_idx = 0
    for i = 0; i < normalized.length(); i = i + 1 {
      if normalized[i] > normalized[max_idx] {
        max_idx = i
      }
    }
    normalized[max_idx] = normalized[max_idx] + 1
    sum = sum + 1
  }

  normalized
}

/// 以简化格式序列化 FSE 表。
fn serialize_fse_table(normalized: Array[Int], accuracy_log: Int, output: Array[Byte]) -> Unit {
  output.push(accuracy_log.to_byte())

  let mut i = 0
  while i < normalized.length() {
    let freq = normalized[i]
    if freq > 0 {
      if freq == 1 {
        output.push((i | 0x80).to_byte())
      } else {
        output.push(i.to_byte())
        output.push(freq.to_byte())
      }
    }
    i = i + 1
  }
  output.push(0xFF)
}

/// 判断是否值得写自定义 FSE 表。
fn should_use_compressed_fse(ll_symbols: Array[Int], ml_symbols: Array[Int], of_symbols: Array[Int]) -> Bool {
  let total = ll_symbols.length()
  if total < 64 { return false }

  let ll_freqs = count_frequencies(ll_symbols, 35)
  let ml_freqs = count_frequencies(ml_symbols, 52)
  let of_freqs = count_frequencies(of_symbols, 31)

  let mut ll_unique = 0
  let mut ml_unique = 0
  let mut of_unique = 0

  for i = 0; i < ll_freqs.length(); i = i + 1 {
    if ll_freqs[i] > 0 { ll_unique = ll_unique + 1 }
  }
  for i = 0; i < ml_freqs.length(); i = i + 1 {
    if ml_freqs[i] > 0 { ml_unique = ml_unique + 1 }
  }
  for i = 0; i < of_freqs.length(); i = i + 1 {
    if of_freqs[i] > 0 { of_unique = of_unique + 1 }
  }

  (ll_unique > 4 && ll_unique < 20) || (ml_unique > 4 && ml_unique < 20) || (of_unique > 3 && of_unique < 15)
}

/// 使用自定义 FSE 表编码序列。
fn encode_sequences_compressed_fse(sequences: Array[LZSequence], output: Array[Byte]) -> Result[Unit, @zstd_core.ZSTDError] {
  if sequences.length() == 0 { return Ok(()) }

  // 第 1 步：抽取三类符号码流。
  let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(sequences)

  // 第 2 步：统计频率并归一化为 FSE 目标和。
  let ll_freqs = count_frequencies(ll_symbols, 35)
  let ml_freqs = count_frequencies(ml_symbols, 52)
  let of_freqs = count_frequencies(of_symbols, 31)

  let ll_norm = normalize_frequencies(ll_freqs, 6)
  let ml_norm = normalize_frequencies(ml_freqs, 6)
  let of_norm = normalize_frequencies(of_freqs, 5)

  // 第 3 步：把三张表序列化到块里，供解码器重建。
  serialize_fse_table(ll_norm, 6, output)
  serialize_fse_table(ml_norm, 6, output)
  serialize_fse_table(of_norm, 5, output)

  // 第 4 步：构建编码表，再按 tANS 顺序写状态和额外位。
  let ll_table = match @zstd_entropy.build_fse_ctable(ll_norm, ll_norm.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build LL FSE table: \{e}"))
  }
  let ml_table = match @zstd_entropy.build_fse_ctable(ml_norm, ml_norm.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build ML FSE table: \{e}"))
  }
  let of_table = match @zstd_entropy.build_fse_ctable(of_norm, of_norm.length() - 1, 5) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build OF FSE table: \{e}"))
  }

  let bitstream = @zstd_entropy.create_bitstream()
  let last_idx = sequences.length() - 1

  let mut ll_state = @zstd_entropy.init_fse_cstate_with_symbol(ll_table, ll_symbols[last_idx])
  let mut ml_state = @zstd_entropy.init_fse_cstate_with_symbol(ml_table, ml_symbols[last_idx])
  let mut of_state = @zstd_entropy.init_fse_cstate_with_symbol(of_table, of_symbols[last_idx])

  let last_seq = sequences[last_idx]
  let (_, last_ll_extra) = @zstd_entropy.encode_ll(last_seq.literal_length)
  let last_ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[last_idx])
  if last_ll_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ll_extra.to_uint64(), last_ll_nbits)
  }

  let (_, last_ml_extra) = @zstd_entropy.encode_ml(last_seq.match_length)
  let last_ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[last_idx])
  if last_ml_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ml_extra.to_uint64(), last_ml_nbits)
  }

  let (_, last_of_extra) = match @zstd_entropy.encode_of(last_seq.offset) {
    Ok(result) => result
    Err(e) => return Err(@zstd_core.message_error("Invalid offset in last sequence: \{e}"))
  }
  let last_of_nbits = @zstd_entropy.get_of_bits(of_symbols[last_idx])
  if last_of_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_of_extra.to_uint64(), last_of_nbits)
  }

  @zstd_entropy.flush_bits(bitstream)

  let mut n = last_idx - 1
  while n >= 0 {
    let seq = sequences[n]

    of_state = @zstd_entropy.encode_symbol_fse(of_state, of_symbols[n], of_table, bitstream)
    ml_state = @zstd_entropy.encode_symbol_fse(ml_state, ml_symbols[n], ml_table, bitstream)
    ll_state = @zstd_entropy.encode_symbol_fse(ll_state, ll_symbols[n], ll_table, bitstream)

    let (_, ll_extra) = @zstd_entropy.encode_ll(seq.literal_length)
    let ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[n])
    if ll_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ll_extra.to_uint64(), ll_nbits)
    }

    let (_, ml_extra) = @zstd_entropy.encode_ml(seq.match_length)
    let ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[n])
    if ml_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ml_extra.to_uint64(), ml_nbits)
    }

    let (_, of_extra) = match @zstd_entropy.encode_of(seq.offset) {
      Ok(result) => result
      Err(e) => return Err(@zstd_core.message_error("Invalid offset in sequence: \{e}"))
    }
    let of_nbits = @zstd_entropy.get_of_bits(of_symbols[n])
    if of_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, of_extra.to_uint64(), of_nbits)
    }

    @zstd_entropy.flush_bits(bitstream)
    n = n - 1
  }

  // 第 5 步：最后刷新状态并关闭位流。
  @zstd_entropy.flush_final_state(bitstream, ml_state, 6)
  @zstd_entropy.flush_final_state(bitstream, of_state, 5)
  @zstd_entropy.flush_final_state(bitstream, ll_state, 6)
  @zstd_entropy.close_bitstream(bitstream)

  let encoded = @zstd_entropy.get_bytes(bitstream)
  for i = 0; i < encoded.length(); i = i + 1 {
    output.push(encoded[i])
  }

  Ok(())
}

// ============================================================================
// 压缩块实现
// ============================================================================

/// 获取预定义的 LL 权重表
fn get_predefined_ll_weights_compressor() -> Array[Int] {
  [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1
  ]
}

/// 获取预定义的 ML 权重表
fn get_predefined_ml_weights_compressor() -> Array[Int] {
  [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1
  ]
}

/// 获取预定义的 OF 权重表
fn get_predefined_of_weights_compressor() -> Array[Int] {
  [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
  ]
}

/// 编码 Literal Length 为符号（使用 RFC 8878 标准表）
fn encode_ll_symbol(ll: Int) -> Int {
  let (code, _) = @zstd_entropy.encode_ll(ll)
  code
}

/// 编码 Match Length 为符号（使用 RFC 8878 标准表）
fn encode_ml_symbol(ml: Int) -> Int {
  let (code, _) = @zstd_entropy.encode_ml(ml)
  code
}

/// 把 offset 映射成 OF 符号，并兼容 repeat offset 标记。
fn encode_of_symbol(offset: Int) -> Int {
  if offset == -1 {
    return 0
  } else if offset == -2 {
    return 1
  } else if offset == -3 {
    return 1
  }
  if offset < 1 {
    abort("Invalid offset: must be >= 1")
  }
  match @zstd_entropy.encode_of(offset) {
    Ok((code, _)) => code
    Err(e) => abort("encode_of failed: " + e)
  }
}

/// 提取序列符号（用于 FSE 编码）
fn extract_sequence_symbols(sequences: Array[LZSequence]) -> (Array[Int], Array[Int], Array[Int]) {
  let ll_symbols: Array[Int] = []
  let ml_symbols: Array[Int] = []
  let of_symbols: Array[Int] = []

  for i = 0; i < sequences.length(); i = i + 1 {
    let seq = sequences[i]
    ll_symbols.push(encode_ll_symbol(seq.literal_length))
    ml_symbols.push(encode_ml_symbol(seq.match_length))
    of_symbols.push(encode_of_symbol(seq.offset))
  }

  (ll_symbols, ml_symbols, of_symbols)
}

/// 按旧直写格式编码单个序列。
///
/// 大值单序列会转到标准序列段格式，这里主要保留兼容能力。
fn encode_single_sequence_direct(seq: LZSequence, output: Array[Byte]) -> Unit {
  // 第 1 步：做数值边界与溢出保护。
  let ll = seq.literal_length
  let ml = seq.match_length
  let max_value = 16777216
  if ll < 0 || ll >= max_value { abort("LL out of bounds") }
  if ml < 3 || ml >= max_value { abort("ML out of bounds") }

  // 第 2 步：把 repeat offset 标记还原成真实 offset。
  let of = if seq.offset == -1 {
    1
  } else if seq.offset == -2 {
    4
  } else if seq.offset == -3 {
    8
  } else {
    seq.offset
  }
  if of < 1 || of >= max_value { abort("OF out of bounds") }

  if ml > 2147483647 - of { abort("Integer overflow: ML + OF exceeds Int max") }
  if ll > 2147483647 - ml - of { abort("Integer overflow: LL + ML + OF exceeds Int max") }

  // 第 3 步：按旧直写顺序依次写 LL、OF、ML。
  if ll < 128 {
    output.push(ll.to_byte())
  } else if ll < 0x7F00 {
    output.push(((ll >> 8) + 128).to_byte())
    output.push((ll & 0xFF).to_byte())
  } else {
    output.push(0xFF)
    let adjusted = ll - 0x7F00
    output.push((adjusted & 0xFF).to_byte())
    output.push(((adjusted >> 8) & 0xFF).to_byte())
  }

  let of_minus_1 = of - 1
  if of_minus_1 < 128 {
    output.push(of_minus_1.to_byte())
  } else if of_minus_1 < 0x7F00 {
    output.push(((of_minus_1 >> 8) + 128).to_byte())
    output.push((of_minus_1 & 0xFF).to_byte())
  } else {
    output.push(0xFF)
    let adjusted = of_minus_1 - 0x7F00
    output.push((adjusted & 0xFF).to_byte())
    output.push(((adjusted >> 8) & 0xFF).to_byte())
  }

  let ml_minus_3 = ml - 3
  if ml_minus_3 < 128 {
    output.push(ml_minus_3.to_byte())
  } else if ml_minus_3 < 0x7F00 {
    output.push(((ml_minus_3 >> 8) + 128).to_byte())
    output.push((ml_minus_3 & 0xFF).to_byte())
  } else {
    output.push(0xFF)
    let adjusted = ml_minus_3 - 0x7F00
    output.push((adjusted & 0xFF).to_byte())
    output.push(((adjusted >> 8) & 0xFF).to_byte())
  }
}

/// 使用预定义 FSE 表编码序列。
fn encode_sequences_predefined_fse(sequences: Array[LZSequence], output: Array[Byte]) -> Result[Unit, @zstd_core.ZSTDError] {
  if sequences.length() == 0 {
    return Ok(())
  }

  // 第 1 步：准备符号流与三张预定义表。
  let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(sequences)

  let ll_predefined = @zstd_entropy.normalize_counts(get_predefined_ll_weights_compressor(), 6)
  let ml_predefined = @zstd_entropy.normalize_counts(get_predefined_ml_weights_compressor(), 6)
  let of_predefined = @zstd_entropy.normalize_counts(get_predefined_of_weights_compressor(), 5)

  // 第 2 步：构建编码表，供后续写位流使用。
  let ll_table = match @zstd_entropy.build_fse_ctable(ll_predefined, ll_predefined.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build LL FSE table: \{e}"))
  }
  let ml_table = match @zstd_entropy.build_fse_ctable(ml_predefined, ml_predefined.length() - 1, 6) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build ML FSE table: \{e}"))
  }
  let of_table = match @zstd_entropy.build_fse_ctable(of_predefined, of_predefined.length() - 1, 5) {
    Ok(t) => t
    Err(e) => return Err(@zstd_core.message_error("Failed to build OF FSE table: \{e}"))
  }

  // 第 3 步：按官方顺序写最后一个序列的额外位，再倒序处理其余序列。
  let bitstream = @zstd_entropy.create_bitstream()
  let last_idx = sequences.length() - 1

  let mut ll_state = @zstd_entropy.init_fse_cstate_with_symbol(ll_table, ll_symbols[last_idx])
  let mut ml_state = @zstd_entropy.init_fse_cstate_with_symbol(ml_table, ml_symbols[last_idx])
  let mut of_state = @zstd_entropy.init_fse_cstate_with_symbol(of_table, of_symbols[last_idx])

  let last_seq = sequences[last_idx]

  let (_, last_ll_extra) = @zstd_entropy.encode_ll(last_seq.literal_length)
  let last_ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[last_idx])
  if last_ll_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ll_extra.to_uint64(), last_ll_nbits)
  }

  let (_, last_ml_extra) = @zstd_entropy.encode_ml(last_seq.match_length)
  let last_ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[last_idx])
  if last_ml_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_ml_extra.to_uint64(), last_ml_nbits)
  }

  let (_, last_of_extra) = match @zstd_entropy.encode_of(last_seq.offset) {
    Ok(result) => result
    Err(e) => return Err(@zstd_core.message_error("Invalid offset in last sequence: \{e}"))
  }
  let last_of_nbits = @zstd_entropy.get_of_bits(of_symbols[last_idx])
  if last_of_nbits > 0 {
    @zstd_entropy.add_bits(bitstream, last_of_extra.to_uint64(), last_of_nbits)
  }

  @zstd_entropy.flush_bits(bitstream)

  let mut n = last_idx - 1
  while n >= 0 {
    let seq = sequences[n]

    of_state = @zstd_entropy.encode_symbol_fse(of_state, of_symbols[n], of_table, bitstream)
    ml_state = @zstd_entropy.encode_symbol_fse(ml_state, ml_symbols[n], ml_table, bitstream)
    ll_state = @zstd_entropy.encode_symbol_fse(ll_state, ll_symbols[n], ll_table, bitstream)

    let (_, ll_extra) = @zstd_entropy.encode_ll(seq.literal_length)
    let ll_nbits = @zstd_entropy.get_ll_bits(ll_symbols[n])
    if ll_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ll_extra.to_uint64(), ll_nbits)
    }

    let (_, ml_extra) = @zstd_entropy.encode_ml(seq.match_length)
    let ml_nbits = @zstd_entropy.get_ml_bits(ml_symbols[n])
    if ml_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, ml_extra.to_uint64(), ml_nbits)
    }

    let (_, of_extra) = match @zstd_entropy.encode_of(seq.offset) {
      Ok(result) => result
      Err(e) => return Err(@zstd_core.message_error("Invalid offset in sequence: \{e}"))
    }
    let of_nbits = @zstd_entropy.get_of_bits(of_symbols[n])
    if of_nbits > 0 {
      @zstd_entropy.add_bits(bitstream, of_extra.to_uint64(), of_nbits)
    }

    @zstd_entropy.flush_bits(bitstream)
    n = n - 1
  }

  // 第 4 步：刷新最终状态并关闭位流。
  @zstd_entropy.flush_final_state(bitstream, ml_state, 6)
  @zstd_entropy.flush_final_state(bitstream, of_state, 5)
  @zstd_entropy.flush_final_state(bitstream, ll_state, 6)
  @zstd_entropy.close_bitstream(bitstream)

  let encoded = @zstd_entropy.get_bytes(bitstream)
  for i = 0; i < encoded.length(); i = i + 1 {
    output.push(encoded[i])
  }

  Ok(())
}
