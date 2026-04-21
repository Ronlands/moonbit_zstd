/// 在帧头中写入字典 ID，并选择最合适的块写出方式。
fn compress_with_dict_id(
  data: Bytes,
  _config: CompressionConfig,
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  // 第 1 步：空输入直接返回空帧。
  if data.length() == 0 {
    return compress_empty_frame()
  }

  // 第 2 步：如果整段数据高度重复，则优先走 RLE。
  if is_rle_beneficial(data) {
    return compress_as_rle_block_with_dict(data, dict_id)
  }

  // 第 3 步：其余情况直接走 Raw，并保留字典 ID 元信息。
  compress_as_raw_block_with_dict(data, dict_id)
}

/// 以 Raw 块形式写出带字典 ID 的帧。
///
/// 当输入超过 `128KB` 时，会自动拆成多个 Raw 块。
fn compress_as_raw_block_with_dict(data: Bytes, dict_id: UInt) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE

  // 第 1 步：写帧头与字典 ID。
  write_zstd_magic(output)
  let fhd: Byte = 0x23  // Single_Segment=1, Dictionary_ID_Flag=3
  output.push(fhd)
  write_dict_id(output, dict_id)
  write_frame_content_size_with_dict(output, data.length(), 4)

  // 第 2 步：按最大块大小循环写出 Raw 块。
  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    write_block_header(output, is_last, 0, chunk_size)
    for i = 0; i < chunk_size; i = i + 1 {
      output.push(data[pos + i])
    }
    pos = pos + chunk_size
  }

  Ok(Bytes::from_array(output))
}

/// 使用字典匹配方式压缩数据。
///
/// 核心思路：
/// 1. 先把字典预热到哈希表
/// 2. 再扫描当前数据生成带字典语义的 LZ77 序列
/// 3. 根据收益决定写压缩块还是回退到 Raw/RLE
fn compress_with_dictionary_matching(
  data: Bytes,
  config: CompressionConfig,
  dictionary: Bytes,
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  // 第 1 步：创建哈希表，并预加载字典内容。
  let hash_table = Array::make(hash_table_size, -1)
  preload_dictionary_to_hash_table(dictionary, hash_table)

  // 第 2 步：根据配置计算窗口大小上限。
  let window_size = 1 << config.window_log

  // 第 3 步：在“字典 + 当前输入”组合视图上生成序列。
  let sequences_result = generate_sequences_with_dict(data, dictionary, hash_table, config.min_match, window_size)

  match sequences_result {
    Ok((sequences, literals)) => {
      // 第 4 步：只有当序列收益足够时，才真正写 Compressed 块。
      if sequences.length() > 0 && should_use_compressed_block(data, sequences, literals) {
        compress_as_compressed_block_with_dict(data, sequences, literals, dict_id)
      } else {
        // 第 5 步：收益不足时回退，避免压缩后反而更大。
        compress_with_dict_id(data, config, dict_id)
      }
    }
    Err(_) => compress_with_dict_id(data, config, dict_id)
  }
}

/// 将字典内容预加载到哈希表。
fn preload_dictionary_to_hash_table(dictionary: Bytes, hash_table: Array[Int]) -> Unit {
  let dict_len = dictionary.length()

  // 用负数位置表示“命中字典”而不是“命中当前数据”。
  let mut pos = 0
  while pos + 3 < dict_len {
    let hash = hash_bytes(dictionary, pos)
    // 使用负数偏移表示字典位置：-(pos + 2)
    // 其中 -1 保留给“空槽位”，避免字典位置 0 与空值冲突。
    hash_table[hash] = -(pos + 2)
    pos = pos + 1
  }
}

/// 预加载流式历史窗口到哈希表。
///
/// 与普通字典预加载不同，这里保留每个 hash 的“最早出现位置”，
/// 这样在高度重复的历史窗口里更容易形成长匹配。
fn preload_streaming_history_to_hash_table(history: Bytes, hash_table: Array[Int]) -> Unit {
  let history_len = history.length()

  let mut pos = 0
  while pos + 3 < history_len {
    let hash = hash_bytes(history, pos)
    if hash_table[hash] == -1 {
      hash_table[hash] = -(pos + 2)
    }
    pos = pos + 1
  }
}

/// 生成带字典语义的 LZ77 序列。
fn generate_sequences_with_dict(
  data: Bytes,
  dictionary: Bytes,
  hash_table: Array[Int],
  min_match: Int,
  window_size: Int
) -> Result[(Array[LZSequence], Array[Byte]), String] {
  let sequences: Array[LZSequence] = []
  let literals: Array[Byte] = []

  let mut pos = 0
  let mut literal_start = 0

  // 从头扫描输入：每次要么产生一个匹配序列，要么把当前位置记为字面量。
  while pos < data.length() {
    // 第 1 步：查找当前位置的最佳匹配，匹配可能来自字典，也可能来自当前数据前缀。
    let match_result = find_match_with_dict(data, dictionary, pos, hash_table, min_match, window_size)

    if match_result.length >= min_match {
      // 第 2 步：把匹配前的区间固化为 literals。
      let literal_length = pos - literal_start
      for i = literal_start; i < pos; i = i + 1 {
        literals.push(data[i])
      }

      // 第 3 步：记录当前匹配序列。
      sequences.push(LZSequence::{
        literal_length: literal_length,
        match_length: match_result.length,
        offset: match_result.offset
      })

      // 第 4 步：把本次匹配覆盖到的数据位置继续写回哈希表。
      // 这样后续位置也可以命中刚刚写出的前缀。
      let mut i = pos
      while i < pos + match_result.length && i + 3 < data.length() {
        let hash = hash_bytes(data, i)
        hash_table[hash] = i
        i = i + 1
      }

      pos = pos + match_result.length
      literal_start = pos
    } else {
      // 第 5 步：没有匹配时，把当前位置写入哈希表，并继续向后扫描。
      if pos + 3 < data.length() {
        let hash = hash_bytes(data, pos)
        hash_table[hash] = pos
      }
      pos = pos + 1
    }
  }

  // 第 6 步：扫描结束后，把尾部未成序列的部分补进 literals。
  for i = literal_start; i < data.length(); i = i + 1 {
    literals.push(data[i])
  }

  Ok((sequences, literals))
}

/// 在“当前数据 + 字典/历史前缀”中查找匹配。
fn find_match_with_dict(
  data: Bytes,
  dictionary: Bytes,
  pos: Int,
  hash_table: Array[Int],
  min_match: Int,
  window_size: Int
) -> Match {
  // 第 1 步：长度不够时，不可能形成最小匹配。
  if pos + min_match > data.length() {
    return Match::{ offset: 0, length: 0 }
  }

  let hash = hash_bytes(data, pos)
  let match_pos = hash_table[hash]

  // 第 2 步：空槽位或未来位置都不是合法匹配。
  if match_pos == -1 || match_pos >= pos {
    return Match::{ offset: 0, length: 0 }
  }

  // 第 3 步：负数位置表示字典/历史窗口，非负位置表示当前数据前缀。
  if match_pos < 0 {
    let dict_pos = -match_pos - 2
    let match_length = calculate_match_length_from_dict(data, dictionary, pos, dict_pos)

    if match_length >= min_match {
      // 第 4 步：命中字典时，按 ZSTD 规则把字典位置换算成 offset。
      let offset = pos + (dictionary.length() - dict_pos)
      if offset > window_size {
        return Match::{ offset: 0, length: 0 }
      }
      Match::{ offset: offset, length: match_length }
    } else {
      Match::{ offset: 0, length: 0 }
    }
  } else {
    // 第 5 步：命中当前数据前缀时，offset 就是当前位置与匹配位置的差。
    let offset = pos - match_pos
    if offset > window_size {
      return Match::{ offset: 0, length: 0 }
    }

    let match_length = calculate_match_length_in_data(data, pos, match_pos)

    if match_length >= min_match {
      Match::{ offset: offset, length: match_length }
    } else {
      Match::{ offset: 0, length: 0 }
    }
  }
}

/// 计算“字典位置 -> 当前数据位置”的最长匹配长度。
fn calculate_match_length_from_dict(
  data: Bytes,
  dictionary: Bytes,
  data_pos: Int,
  dict_pos: Int
) -> Int {
  let mut length = 0
  let max_length = (data.length() - data_pos).min(dictionary.length() - dict_pos).min(131072)

  while length < max_length &&
        dict_pos + length < dictionary.length() &&
        data_pos + length < data.length() &&
        dictionary[dict_pos + length] == data[data_pos + length] {
    length = length + 1
  }

  length
}

/// Compress as compressed block with dictionary ID
fn compress_as_compressed_block_with_dict(
  data: Bytes,
  sequences: Array[LZSequence],
  literals: Array[Byte],
  dict_id: UInt
) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header with Dictionary ID
  let fhd: Byte = 0x23
  output.push(fhd)

  // Dictionary ID (4 bytes, little-endian)
  write_dict_id(output, dict_id)

  // Frame Content Size
  write_frame_content_size_with_dict(output, data.length(), 4)

  let block_content = match build_predefined_compressed_block_payload_from_sequences(sequences, literals) {
    Ok(payload) => payload
    Err(e) => return Err(e)
  }

  // Block Header
  let block_size = block_content.length()
  write_block_header(output, true, 2, block_size)

  append_bytes_to_output(output, block_content)

  Ok(Bytes::from_array(output))
}

/// Compress as RLE block with dictionary ID
fn compress_as_rle_block_with_dict(data: Bytes, dict_id: UInt) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() == 0 {
    return compress_empty_frame()
  }

  let first_byte = data[0]
  let mut all_same = true
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] != first_byte {
      all_same = false
      break
    }
  }

  if !all_same {
    return compress_as_raw_block_with_dict(data, dict_id)
  }

  let output: Array[Byte] = []

  // ZSTD Magic Number
  write_zstd_magic(output)

  // Frame Header with Dictionary ID
  let fhd: Byte = 0x23
  output.push(fhd)

  // Dictionary ID
  write_dict_id(output, dict_id)

  // Frame Content Size
  write_frame_content_size_with_dict(output, data.length(), 4)

  // Emit one or more RLE blocks, each with decompressed size ≤ ZSTD_MAX_BLOCK_SIZE
  let max_block = @zstd_core.ZSTD_MAX_BLOCK_SIZE
  let mut pos = 0
  while pos < data.length() {
    let remaining = data.length() - pos
    let chunk_size = remaining.min(max_block)
    let is_last = (pos + chunk_size >= data.length())
    write_block_header(output, is_last, 1, chunk_size)
    output.push(first_byte)
    pos = pos + chunk_size
  }

  Ok(Bytes::from_array(output))
}
