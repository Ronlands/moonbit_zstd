/// 解析序列区，并根据当前块格式选择合适的解码路径。
///
/// 当前实现兼容两种一序列表示：
/// - 仓库历史上的旧直写格式
/// - 标准 RFC 序列段格式
fn parse_sequences_section(
  data: Bytes,
  offset: Int,
  size: Int,
  context: BlockContext
) -> Result[Array[@zstd_core.Sequence], String] {
  // 第 1 步：先只读取序列个数。
  // 这样可以在不提前吃掉 modes 字节的情况下，决定后续分支。
  let count_result = parse_sequence_count(data, offset)
  match count_result {
    Err(e) => Err(e)
    Ok((num_sequences, _count_size)) => {
      // 第 2 步：一序列时先尝试旧直写兼容路径。
      // 如果旧格式失败，再回退到标准 RFC 路径。
      if num_sequences == 1 {
        match decode_legacy_single_sequence_section(data, offset, size) {
          Ok(seqs) => Ok(seqs)
          Err(_) => decode_standard_sequence_section(data, offset, size, context)
        }
      // 第 3 步：多序列或零序列时，直接走标准路径。
      } else {
        decode_standard_sequence_section(data, offset, size, context)
      }
    }
  }
}

/// 只解析序列个数，不解析后续 modes 和表头。
fn parse_sequence_count(data: Bytes, offset: Int) -> Result[(Int, Int), String] {
  if offset >= data.length() {
    return Err("Insufficient sequence header data")
  }

  let first_byte = data[offset].to_int()
  let mut current_offset = offset + 1

  // 按 RFC 8878 的 1/2/3 字节变长格式读取序列个数。
  let num_sequences = if first_byte < 128 {
    first_byte
  } else if first_byte == 255 {
    if current_offset + 1 >= data.length() {
      return Err("Insufficient sequence count data")
    }
    let count = data[current_offset].to_int() | (data[current_offset + 1].to_int() << 8)
    current_offset = current_offset + 2
    count + 0x7F00
  } else {
    if current_offset >= data.length() {
      return Err("Insufficient sequence count data")
    }
    let count = ((first_byte - 128) << 8) + data[current_offset].to_int()
    current_offset = current_offset + 1
    count
  }

  Ok((num_sequences, current_offset - offset))
}

/// 按标准 RFC 方式解析并解码序列区。
fn decode_standard_sequence_section(
  data: Bytes,
  offset: Int,
  size: Int,
  context: BlockContext
) -> Result[Array[@zstd_core.Sequence], String] {
  // 第 1 步：完整解析标准头部，包括序列个数和 modes 字节。
  let standard_header_result = parse_sequence_header_standard(data, offset)
  match standard_header_result {
    Ok((header, header_size)) => {
      // 第 2 步：先做长度守卫，避免越界解析。
      if size < header_size {
        return Err("Insufficient sequence data: block size smaller than header")
      }

      // 第 3 步：零序列时要求头后不再有额外数据。
      if header.num_sequences == 0 {
        if size > header_size {
          let extra_bytes = size - header_size
          return Err("Extraneous zero sequence data: found " + extra_bytes.to_string() +
                    " extra bytes after zero sequence header")
        }
        return Ok([])
      }

      // 第 4 步：对非零序列，进入 FSE/RLE/Repeat 等正式解码流程。
      decode_sequences_simple(data, offset + header_size, header, offset + size, context)
    }
    Err(e) => Err(e)
  }
}

/// 按标准 RFC 结构解析序列头。
fn parse_sequence_header_standard(data: Bytes, offset: Int) -> Result[(@zstd_core.SequencesSectionInfo, Int), String] {
  if offset >= data.length() {
    return Err("Insufficient sequence header data")
  }

  let first_byte = data[offset].to_int()
  let mut current_offset = offset + 1

  // 第 1 步：先解析序列个数。
  let num_sequences = if first_byte < 128 {
    first_byte
  } else if first_byte == 255 {
    if current_offset + 1 >= data.length() {
      return Err("Insufficient sequence count data")
    }
    let count = data[current_offset].to_int() | (data[current_offset + 1].to_int() << 8)
    current_offset = current_offset + 2
    count + 0x7F00
  } else {
    if current_offset >= data.length() {
      return Err("Insufficient sequence count data")
    }
    let count = ((first_byte - 128) << 8) + data[current_offset].to_int()
    current_offset = current_offset + 1
    count
  }

  // 第 2 步：零序列没有 modes 字节，直接返回默认模式。
  if num_sequences == 0 {
    let info = @zstd_core.make_sequences_section_info(
      num_sequences,
      @zstd_core.predefined_mode(),
      @zstd_core.predefined_mode(),
      @zstd_core.predefined_mode()
    )
    return Ok((info, current_offset - offset))
  }

  // 第 3 步：非零序列必须有 modes 字节。
  if current_offset >= data.length() {
    return Err("Insufficient sequence modes data: current_offset=\{current_offset}, data.length=\{data.length()}, offset=\{offset}")
  }

  // 第 4 步：拆出 LL / OF / ML 三种模式。
  let modes_byte = data[current_offset].to_int()
  current_offset = current_offset + 1

  let ll_mode_val = (modes_byte >> 6) & 0x3
  let of_mode_val = (modes_byte >> 4) & 0x3
  let ml_mode_val = (modes_byte >> 2) & 0x3

  let ll_mode = match ll_mode_val {
    0 => @zstd_core.predefined_mode()
    1 => @zstd_core.rle_mode()
    2 => @zstd_core.fse_compressed_mode()
    3 => @zstd_core.repeat_mode()
    _ => @zstd_core.predefined_mode()
  }

  let of_mode = match of_mode_val {
    0 => @zstd_core.predefined_mode()
    1 => @zstd_core.rle_mode()
    2 => @zstd_core.fse_compressed_mode()
    3 => @zstd_core.repeat_mode()
    _ => @zstd_core.predefined_mode()
  }

  let ml_mode = match ml_mode_val {
    0 => @zstd_core.predefined_mode()
    1 => @zstd_core.rle_mode()
    2 => @zstd_core.fse_compressed_mode()
    3 => @zstd_core.repeat_mode()
    _ => @zstd_core.predefined_mode()
  }

  let info = @zstd_core.make_sequences_section_info(num_sequences, ll_mode, ml_mode, of_mode)
  Ok((info, current_offset - offset))
}

/// 解析历史兼容的一序列头。
///
/// 这个格式只允许 `num_sequences == 1`，且不包含标准 modes 字节。
fn parse_sequence_header_legacy(data: Bytes, offset: Int) -> Result[(@zstd_core.SequencesSectionInfo, Int), String] {
  if offset >= data.length() {
    return Err("Insufficient legacy sequence header data")
  }

  let first_byte = data[offset].to_int()
  let mut current_offset = offset + 1

  // 旧格式仍沿用相同的变长个数编码，但只接受值 1。
  let num_sequences = if first_byte < 128 {
    first_byte
  } else if first_byte == 255 {
    if current_offset + 1 >= data.length() {
      return Err("Insufficient legacy sequence count data")
    }
    let count = data[current_offset].to_int() | (data[current_offset + 1].to_int() << 8)
    current_offset = current_offset + 2
    count + 0x7F00
  } else {
    if current_offset >= data.length() {
      return Err("Insufficient legacy sequence count data")
    }
    let count = ((first_byte - 128) << 8) + data[current_offset].to_int()
    current_offset = current_offset + 1
    count
  }

  if num_sequences != 1 {
    return Err("Legacy single-sequence format only supports one sequence")
  }

  let info = @zstd_core.make_sequences_section_info(
    1,
    @zstd_core.predefined_mode(),
    @zstd_core.predefined_mode(),
    @zstd_core.predefined_mode()
  )
  Ok((info, current_offset - offset))
}

/// 解码历史兼容的一序列区。
fn decode_legacy_single_sequence_section(
  data: Bytes,
  offset: Int,
  size: Int
) -> Result[Array[@zstd_core.Sequence], String] {
  // 第 1 步：先解析旧格式头。
  let header_result = parse_sequence_header_legacy(data, offset)
  match header_result {
    Ok((_header, header_size)) => {
      // 第 2 步：验证总长度至少能覆盖旧格式头。
      if size < header_size {
        return Err("Insufficient legacy sequence data: block size smaller than header")
      }

      // 第 3 步：按旧直写规则读出唯一一个序列。
      match decode_single_sequence_direct(data, offset + header_size) {
        Ok((seqs, consumed_size)) => {
          // 第 4 步：旧格式要求头部和负载长度精确匹配。
          if header_size + consumed_size != size {
            return Err("Legacy single-sequence payload size mismatch")
          }
          Ok(seqs)
        }
        Err(e) => Err(e)
      }
    }
    Err(e) => Err(e)
  }
}

/// 直接读取旧格式的一序列编码。
///
/// 这里不是标准 RFC 序列段，而是仓库历史上的兼容格式。
/// 因此读取规则是：
/// 1. 读 `LL`
/// 2. 读 `OF`
/// 3. 读 `ML`
fn decode_single_sequence_direct(data: Bytes, offset: Int) -> Result[(Array[@zstd_core.Sequence], Int), String] {
  let mut pos = offset

  // 第 1 步：读取字面量长度 LL。
  if pos >= data.length() { return Err("Insufficient data for LL") }
  let ll_byte = data[pos].to_int()
  pos = pos + 1
  let literal_length = if ll_byte < 128 {
    ll_byte
  } else if ll_byte < 255 {
    if pos >= data.length() { return Err("Insufficient data for LL") }
    ((ll_byte - 128) << 8) + data[pos].to_int() + { pos = pos + 1; 0 }
  } else {
    if pos + 1 >= data.length() { return Err("Insufficient data for LL") }
    let v = data[pos].to_int() | (data[pos + 1].to_int() << 8)
    pos = pos + 2
    v + 0x7F00
  }
  let max_value = 16777216
  if literal_length < 0 || literal_length >= max_value {
    return Err("LL out of bounds")
  }

  // 第 2 步：读取偏移量 OF。
  if pos >= data.length() { return Err("Insufficient data for OF") }
  let of_byte = data[pos].to_int()
  pos = pos + 1
  let offset_value = if of_byte < 128 {
    of_byte + 1
  } else if of_byte < 255 {
    if pos >= data.length() { return Err("Insufficient data for OF") }
    ((of_byte - 128) << 8) + data[pos].to_int() + 1 + { pos = pos + 1; 0 }
  } else {
    if pos + 1 >= data.length() { return Err("Insufficient data for OF") }
    let v = data[pos].to_int() | (data[pos + 1].to_int() << 8)
    pos = pos + 2
    v + 0x7F01
  }
  if offset_value < 1 || offset_value >= max_value {
    return Err("OF out of bounds")
  }

  // 第 3 步：读取匹配长度 ML。
  if pos >= data.length() { return Err("Insufficient data for ML") }
  let ml_byte = data[pos].to_int()
  let match_length = if ml_byte < 128 {
    pos = pos + 1
    ml_byte + 3
  } else if ml_byte < 255 {
    if pos + 1 >= data.length() { return Err("Insufficient data for ML") }
    let value = ((ml_byte - 128) << 8) + data[pos + 1].to_int() + 3
    pos = pos + 2
    value
  } else {
    if pos + 2 >= data.length() { return Err("Insufficient data for ML") }
    let value = (data[pos + 1].to_int() | (data[pos + 2].to_int() << 8)) + 0x7F03
    pos = pos + 3
    value
  }
  if match_length < 3 || match_length >= max_value {
    return Err("ML out of bounds")
  }

  // 第 4 步：做整数上界保护，避免后续执行序列时溢出。
  if match_length > 2147483647 - offset_value {
    return Err("Integer overflow: ML + OF exceeds Int max")
  }
  if literal_length > 2147483647 - match_length - offset_value {
    return Err("Integer overflow: LL + ML + OF exceeds Int max")
  }

  // 第 5 步：返回单个核心序列，以及本次一共消耗的字节数。
  Ok(([@zstd_core.make_sequence(literal_length, match_length, offset_value)], pos - offset))
}

/// 使用标准序列段格式解码序列。
fn decode_sequences_simple(
  data: Bytes,
  offset: Int,
  header: @zstd_core.SequencesSectionInfo,
  data_end: Int,
  context: BlockContext
) -> Result[Array[@zstd_core.Sequence], String] {
  // 第 1 步：零序列快速返回。
  if header.num_sequences == 0 {
    return Ok([])
  }

  let current_offset = offset

  // 第 2 步：按模式分别准备 LL / OF / ML 的权重表。
  let ll_weights_result = get_sequence_weights(data, current_offset, header.ll_mode, "LL", context)
  let of_weights_result = get_sequence_weights(data, current_offset, header.of_mode, "OF", context)
  let ml_weights_result = get_sequence_weights(data, current_offset, header.ml_mode, "ML", context)

  let (ll_weights, current_offset_after_ll) = match ll_weights_result {
    Ok((w, s)) => {
      context.last_ll_weights = Some(w)
      (@zstd_entropy.normalize_counts(ensure_weights_length(w, 36), 6), current_offset + s)
    }
    Err(_) => (@zstd_entropy.normalize_counts(get_predefined_ll_weights(), 6), current_offset)
  }

  let (of_weights, current_offset_after_of) = match of_weights_result {
    Ok((w, s)) => {
      context.last_of_weights = Some(w)
      (@zstd_entropy.normalize_counts(ensure_weights_length(w, 32), 5), current_offset_after_ll + s)
    }
    Err(_) => (@zstd_entropy.normalize_counts(get_predefined_of_weights(), 5), current_offset_after_ll)
  }

  let (ml_weights, final_offset) = match ml_weights_result {
    Ok((w, s)) => {
      context.last_ml_weights = Some(w)
      (@zstd_entropy.normalize_counts(ensure_weights_length(w, 53), 6), current_offset_after_of + s)
    }
    Err(_) => (@zstd_entropy.normalize_counts(get_predefined_ml_weights(), 6), current_offset_after_of)
  }

  // 第 3 步：构造边界受限的数据视图，避免 FSE 误吃到校验和或后续帧。
  let prev_offsets = [1, 4, 8]
  let effective_end = data_end.min(data.length())
  let bounded_arr: Array[Byte] = []
  for i = 0; i < effective_end; i = i + 1 {
    bounded_arr.push(data[i])
  }
  let bounded_data = Bytes::from_array(bounded_arr)
  // 第 4 步：调用 entropy 层的 FSE 解码器，得到序列数组。
  let sequences_result = @zstd_entropy.decode_fse_sequences(
    bounded_data,
    final_offset,
    header.num_sequences,
    ll_weights,
    ml_weights,
    of_weights,
    prev_offsets
  )

  // 第 5 步：对解码出的序列做数值合理性校验，再转换成 core.Sequence。
  match sequences_result {
    Ok(sequences) => {
      let mut has_invalid_sequence = false
      for i = 0; i < sequences.length(); i = i + 1 {
        let seq = sequences[i]
        if seq.literal_length < 0 || seq.match_length < 0 || seq.offset <= 0 {
          has_invalid_sequence = true
        } else if seq.literal_length > @zstd_core.ZSTD_MAX_BLOCK_SIZE ||
                  seq.match_length > @zstd_core.ZSTD_MAX_BLOCK_SIZE ||
                  seq.offset > 0x1000000 {
          has_invalid_sequence = true
        }
      }

      if has_invalid_sequence {
        return Err("Data corruption detected: FSE decoded invalid sequence values")
      }

      let core_sequences: Array[@zstd_core.Sequence] = []
      for i = 0; i < sequences.length(); i = i + 1 {
        let seq = sequences[i]
        core_sequences.push(@zstd_core.make_sequence(seq.literal_length, seq.match_length, seq.offset))
      }
      Ok(core_sequences)
    }
    Err(e) => Err("FSE sequence decoding failed: " + e)
  }
}

/// 按模式获取序列权重表。
fn get_sequence_weights(
  data: Bytes,
  offset: Int,
  mode: @zstd_core.SequenceMode,
  weight_type: String,
  context: BlockContext
) -> Result[(Array[Int], Int), String] {
  match mode {
    @zstd_core.SequenceMode::Predefined => {
      // 第 1 步：预定义模式直接返回固定权重表。
      let weights = match weight_type {
        "LL" => get_predefined_ll_weights()
        "ML" => get_predefined_ml_weights()
        "OF" => get_predefined_of_weights()
        _ => get_predefined_ll_weights()
      }
      Ok((weights, 0))
    }
    @zstd_core.SequenceMode::RLE => {
      // 第 2 步：RLE 模式只读取一个字节，并把它扩成整张权重表。
      if offset >= data.length() {
        return Err("RLE mode: insufficient data")
      }
      let rle_value = data[offset].to_int()
      let weights: Array[Int] = []
      for _i = 0; _i < 256; _i = _i + 1 {
        weights.push(rle_value)
      }
      Ok((weights, 1))
    }
    @zstd_core.SequenceMode::FSECompressed => {
      // 第 3 步：FSE 压缩模式要从当前偏移解析完整表头。
      let fse_result = @zstd_entropy.parse_fse_table_header(data, offset)
      match fse_result {
        Ok((weights, _table_log, size)) => Ok((weights, size))
        Err(e) => Err("FSE table parsing failed: " + e)
      }
    }
    @zstd_core.SequenceMode::Repeat => {
      // 第 4 步：Repeat 模式优先复用块上下文中记录的上一张表。
      let weights = match weight_type {
        "LL" => match context.last_ll_weights {
          Some(w) => w
          None => get_predefined_ll_weights()
        }
        "ML" => match context.last_ml_weights {
          Some(w) => w
          None => get_predefined_ml_weights()
        }
        "OF" => match context.last_of_weights {
          Some(w) => w
          None => get_predefined_of_weights()
        }
        _ => get_predefined_ll_weights()
      }
      Ok((weights, 0))
    }
  }
}

/// 获取预定义的 LL 权重表（与编码器一致）
fn get_predefined_ll_weights() -> Array[Int] {
  [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1
  ]
}

/// 获取预定义的 ML 权重表（与编码器一致）
fn get_predefined_ml_weights() -> Array[Int] {
  [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1
  ]
}

/// 获取预定义的 OF 权重表（与编码器一致）
fn get_predefined_of_weights() -> Array[Int] {
  [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
  ]
}

/// 使用解码上下文执行序列。
fn execute_sequences_with_literals_ctx(
  ctx: DecoderContext,
  literals: Bytes,
  sequences: Array[@zstd_core.Sequence]
) -> Result[Bytes, String] {
  // 第 1 步：拿到当前块共享的窗口上下文。
  let window = get_decoder_window(ctx)

  if sequences.length() == 0 {
    // 第 2 步：零序列时，所有字面量直接输出并写入窗口。
    for i = 0; i < literals.length(); i = i + 1 {
      add_to_window(window, literals[i])
    }
    return Ok(literals)
  }

  // 第 3 步：非零序列时，进入统一序列执行器。
  execute_sequences(literals, sequences, window)
}

/// 使用旧兼容模式执行序列。
fn execute_sequences_with_literals(literals: Bytes, sequences: Array[@zstd_core.Sequence]) -> Result[Bytes, String] {
  if sequences.length() == 0 {
    return Ok(literals)
  }

  // 旧模式没有外部上下文，因此这里创建一个临时窗口。
  let window = create_window(65536)
  execute_sequences(literals, sequences, window)
}

/// 创建临时窗口缓冲区。
fn create_window(capacity: Int) -> @zstd_core.WindowBuffer {
  let empty_dict = @zstd_core.create_empty_dictionary()
  @zstd_core.create_window_buffer(capacity, empty_dict)
}

/// 顺序执行所有序列，并同步维护窗口。
fn execute_sequences(
  literals: Bytes,
  sequences: Array[@zstd_core.Sequence],
  window: @zstd_core.WindowBuffer
) -> Result[Bytes, String] {
  let output: Array[Byte] = []
  let mut literal_pos = 0
  let mut sequence_index = 0

  // 逐条序列执行，每条序列都分成“字面量复制”和“历史匹配复制”两部分。
  while sequence_index < sequences.length() {
    let sequence = sequences[sequence_index]
    let literal_length = @zstd_core.get_sequence_literal_length(sequence)
    let match_length = @zstd_core.get_sequence_match_length(sequence)
    let offset = @zstd_core.get_sequence_offset(sequence)

    // 第 1 步：先消费当前序列对应的字面量区间。
    for i = 0; i < literal_length; i = i + 1 {
      if literal_pos + i < literals.length() {
        let byte = literals[literal_pos + i]
        output.push(byte)
        add_to_window(window, byte)
      }
    }
    literal_pos = literal_pos + literal_length

    // 第 2 步：再按 offset / match_length 从窗口回拷匹配数据。
    if match_length > 0 && offset > 0 {
      for _i = 0; _i < match_length; _i = _i + 1 {
        match copy_single_byte_from_window(window, offset) {
          Ok(byte) => {
            output.push(byte)
            add_to_window(window, byte)
          }
          Err(e) => return Err("Match reference out of window bounds: " + e)
        }
      }
    }

    sequence_index = sequence_index + 1
  }

  // 第 3 步：所有序列跑完后，把剩余尾部 literals 追加到输出。
  while literal_pos < literals.length() {
    let byte = literals[literal_pos]
    output.push(byte)
    add_to_window(window, byte)
    literal_pos = literal_pos + 1
  }

  Ok(Bytes::from_array(output))
}

/// 向窗口追加一个字节。
fn add_to_window(window: @zstd_core.WindowBuffer, byte: Byte) -> Unit {
  let capacity = @zstd_core.get_window_capacity(window)
  let position = @zstd_core.get_window_position(window)
  let buffer = @zstd_core.get_window_buffer(window)

  buffer[position] = byte
  @zstd_core.increment_window_position(window, capacity)
  @zstd_core.increment_window_size(window)
}

/// 从窗口按 offset 回读一个字节。
///
/// 采用逐字节回拷，是为了正确支持重叠匹配场景。
fn copy_single_byte_from_window(window: @zstd_core.WindowBuffer, offset: Int) -> Result[Byte, String] {
  let capacity = @zstd_core.get_window_capacity(window)
  let position = @zstd_core.get_window_position(window)
  let buffer = @zstd_core.get_window_buffer(window)

  let mut src_pos = (position - offset) % capacity
  if src_pos < 0 {
    src_pos = src_pos + capacity
  }
  if src_pos >= 0 && src_pos < buffer.length() {
    Ok(buffer[src_pos])
  } else {
    Err("Invalid window position")
  }
}
