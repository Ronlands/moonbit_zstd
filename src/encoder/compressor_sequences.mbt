/// Sequence Encoding (FSE and Predefined Tables)

/// Get predefined LL weights
fn get_predefined_ll_weights_compressor() -> Array[Int] {
  [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1
  ]
}

/// Get predefined ML weights
fn get_predefined_ml_weights_compressor() -> Array[Int] {
  [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1
  ]
}

/// Get predefined OF weights
fn get_predefined_of_weights_compressor() -> Array[Int] {
  [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
  ]
}

/// Encode LL symbol
fn encode_ll_symbol(ll: Int) -> Int {
  let (code, _) = @zstd_entropy.encode_ll(ll)
  code
}

/// Encode ML symbol
fn encode_ml_symbol(ml: Int) -> Int {
  let (code, _) = @zstd_entropy.encode_ml(ml)
  code
}

/// Encode OF symbol with repeat offset support
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

/// Extract sequence symbols
pub fn extract_sequence_symbols(sequences: Array[Sequence]) -> (Array[Int], Array[Int], Array[Int]) {
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

/// Encode single sequence directly (RFC 8878: no FSE for single sequence)
pub fn encode_single_sequence_direct(seq: Sequence, output: Array[Byte]) -> Unit {
  let ll = seq.literal_length
  let ml = seq.match_length
  let max_value = 16777216
  if ll < 0 || ll >= max_value { abort("LL out of bounds") }
  if ml < 3 || ml >= max_value { abort("ML out of bounds") }

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

  // Encode LL
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

  // Encode OF (stored as offset-1)
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

  // Encode ML (stored as ml-3)
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

/// Encode sequences using predefined FSE tables
pub fn encode_sequences_predefined_fse(sequences: Array[Sequence], output: Array[Byte]) -> Result[Unit, @zstd_core.ZSTDError] {
  if sequences.length() == 0 {
    return Ok(())
  }

  let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(sequences)

  let ll_predefined = @zstd_entropy.normalize_counts(get_predefined_ll_weights_compressor(), 6)
  let ml_predefined = @zstd_entropy.normalize_counts(get_predefined_ml_weights_compressor(), 6)
  let of_predefined = @zstd_entropy.normalize_counts(get_predefined_of_weights_compressor(), 5)

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

/// Count symbol frequencies
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

/// Normalize frequencies to target sum
fn normalize_frequencies(freqs: Array[Int], accuracy_log: Int) -> Array[Int] {
  let target = 1 << accuracy_log
  let mut total = 0
  for i = 0; i < freqs.length(); i = i + 1 {
    total = total + freqs[i]
  }

  if total == 0 { return freqs }

  let normalized = Array::make(freqs.length(), 0)
  let mut sum = 0

  for i = 0; i < freqs.length(); i = i + 1 {
    if freqs[i] > 0 {
      let norm = (freqs[i] * target / total).max(1)
      normalized[i] = norm
      sum = sum + norm
    }
  }

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

/// Serialize FSE table
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

/// Check if custom FSE tables would be beneficial
pub fn should_use_compressed_fse(ll_symbols: Array[Int], ml_symbols: Array[Int], of_symbols: Array[Int]) -> Bool {
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

/// Encode sequences using compressed FSE mode
pub fn encode_sequences_compressed_fse(sequences: Array[Sequence], output: Array[Byte]) -> Result[Unit, @zstd_core.ZSTDError] {
  if sequences.length() == 0 { return Ok(()) }

  let (ll_symbols, ml_symbols, of_symbols) = extract_sequence_symbols(sequences)

  let ll_freqs = count_frequencies(ll_symbols, 35)
  let ml_freqs = count_frequencies(ml_symbols, 52)
  let of_freqs = count_frequencies(of_symbols, 31)

  let ll_norm = normalize_frequencies(ll_freqs, 6)
  let ml_norm = normalize_frequencies(ml_freqs, 6)
  let of_norm = normalize_frequencies(of_freqs, 5)

  serialize_fse_table(ll_norm, 6, output)
  serialize_fse_table(ml_norm, 6, output)
  serialize_fse_table(of_norm, 5, output)

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
