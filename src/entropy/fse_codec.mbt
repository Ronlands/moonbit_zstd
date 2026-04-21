// ============================================================================
// 位流实现
// ============================================================================

/// 位流结构 - 用于 tANS 编码输出
pub struct BitStream {
  buffer: Array[Byte]
  mut bit_container: UInt64
  mut bit_pos: Int
}

/// 创建新的位流
pub fn create_bitstream() -> BitStream {
  BitStream::{
    buffer: [],
    bit_container: 0UL,
    bit_pos: 0
  }
}

/// 添加位到位流
pub fn add_bits(stream: BitStream, value: UInt64, nb_bits: Int) -> Unit {
  if nb_bits <= 0 || nb_bits > 64 {
    return
  }

  // 第 1 步：先把新增位拼进当前 64 位容器。
  let mask = if nb_bits >= 64 { 0xFFFFFFFFFFFFFFFFUL } else { (1UL << nb_bits) - 1UL }
  let masked_value = value & mask
  stream.bit_container = stream.bit_container | (masked_value << stream.bit_pos)
  stream.bit_pos = stream.bit_pos + nb_bits

  // 第 2 步：只要容器里已经凑够 1 个完整字节，就立刻刷到输出缓冲区。
  while stream.bit_pos >= 8 {
    stream.buffer.push((stream.bit_container & 0xFFUL).to_byte())
    stream.bit_container = stream.bit_container >> 8
    stream.bit_pos = stream.bit_pos - 8
  }
}

/// 刷新位流（将容器中积累的完整字节输出到缓冲区）
pub fn flush_bits(stream: BitStream) -> Unit {
  while stream.bit_pos >= 8 {
    stream.buffer.push((stream.bit_container & 0xFFUL).to_byte())
    stream.bit_container = stream.bit_container >> 8
    stream.bit_pos = stream.bit_pos - 8
  }
}

/// 关闭位流：添加 padding bit（1）并刷新所有剩余位
pub fn close_bitstream(stream: BitStream) -> Unit {
  add_bits(stream, 1UL, 1)
  if stream.bit_pos > 0 {
    stream.buffer.push((stream.bit_container & 0xFFUL).to_byte())
    stream.bit_container = 0UL
    stream.bit_pos = 0
  }
}

/// 获取位流输出的字节
pub fn get_bytes(stream: BitStream) -> Bytes {
  Bytes::from_array(stream.buffer)
}

/// 获取位流当前位置（用于调试）
pub fn get_bitstream_pos(stream: BitStream) -> Int {
  stream.bit_pos
}

/// 获取位流缓冲区长度（用于调试）
pub fn get_buffer_length(stream: BitStream) -> Int {
  stream.buffer.length()
}

// ============================================================================
// FSE 编码表
// ============================================================================

/// 符号转换结构 - 用于 tANS 状态转换
pub struct SymbolTransform {
  delta_nb_bits: Int
  delta_find_state: Int
}

/// FSE 编码表（用于编码）
pub struct FSECTable {
  symbol_tt: Array[SymbolTransform]
  state_table: Array[UInt16]
  symbol_table: Array[Int]
  table_log: Int
  normalized: Array[Int]
  max_symbol: Int
}

/// FSE 解码表项
priv struct FSEDecodeEntry {
  symbol: Int
  nb_bits: Int
  new_state_base: Int
}

/// 构建 FSE 解码表。
///
/// 步骤：
/// 1. 先把符号按照官方 spread 规则分布到状态空间
/// 2. 再计算每个符号的累积位置
/// 3. 最后为每个状态构建解码项
fn build_fse_dtable(normalized: Array[Int], table_log: Int) -> Array[FSEDecodeEntry] {
  let max_symbol = normalized.length() - 1
  let table_size = 1 << table_log
  let dtable: Array[FSEDecodeEntry] = Array::make(table_size, FSEDecodeEntry::{ symbol: 0, nb_bits: 0, new_state_base: 0 })

  let table_symbol: Array[Int] = Array::make(table_size, 0)
  let mut high_threshold = table_size - 1
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    if normalized[symbol] == -1 {
      table_symbol[high_threshold] = symbol
      high_threshold = high_threshold - 1
    }
  }

  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  let mut position = 0
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    let freq = normalized[symbol]
    if freq <= 0 { continue }
    for _i = 0; _i < freq; _i = _i + 1 {
      table_symbol[position] = symbol
      position = (position + step) & mask
      while position > high_threshold { position = (position + step) & mask }
    }
  }

  let cumul: Array[Int] = Array::make(max_symbol + 2, 0)
  for s = 0; s <= max_symbol; s = s + 1 {
    let norm = if s < normalized.length() { normalized[s] } else { 0 }
    if norm == -1 {
      cumul[s + 1] = cumul[s] + 1
    } else if norm > 0 {
      cumul[s + 1] = cumul[s] + norm
    } else {
      cumul[s + 1] = cumul[s]
    }
  }

  let state_table: Array[UInt16] = Array::make(table_size, 0)
  let cumul_copy: Array[Int] = Array::make(max_symbol + 1, 0)
  for s = 0; s <= max_symbol; s = s + 1 {
    cumul_copy[s] = cumul[s]
  }

  for u = 0; u < table_size; u = u + 1 {
    let s = table_symbol[u]
    let idx = cumul_copy[s]
    cumul_copy[s] = idx + 1
    if idx < state_table.length() {
      state_table[idx] = (table_size + u).to_uint16()
    }
  }

  let symbol_next: Array[Int] = Array::make(normalized.length(), 0)

  for u = 0; u < table_size; u = u + 1 {
    let symbol = table_symbol[u]
    let occurrence = symbol_next[symbol]
    symbol_next[symbol] = occurrence + 1
    let norm = normalized[symbol]
    let base_freq = if norm == -1 { 1 } else { norm }
    let next_state = base_freq + occurrence
    let nb_bits = (table_log - highbit32(next_state)).max(0)
    let new_state_base = (next_state << nb_bits) - table_size

    dtable[u] = FSEDecodeEntry::{
      symbol: symbol,
      nb_bits: nb_bits,
      new_state_base: new_state_base
    }
  }

  dtable
}

/// 根据当前状态获取对应的 FSE 解码表项。
fn get_fse_decode_entry(
  state: Int,
  dtable: Array[FSEDecodeEntry],
  table_log: Int
) -> Result[FSEDecodeEntry, String] {
  let table_size = 1 << table_log
  let normalized_state = if state < table_size {
    state + table_size
  } else if state >= table_size * 2 {
    (state % table_size) + table_size
  } else {
    state
  }
  let u = normalized_state - table_size

  if u < 0 || u >= dtable.length() {
    Err("State out of bounds error: state=\{state}, normalized=\{normalized_state}, u=\{u}, table_size=\{table_size}")
  } else {
    Ok(dtable[u])
  }
}

/// 旧的 FSE 编码表（兼容性）
pub struct FSEEncodeTable {
  state_table: Array[Int]
  symbol_table: Array[Int]
  num_bits_table: Array[Int]
  next_state_table: Array[Array[Int]]
  table_log: Int
  normalized_counts: Array[Int]
  max_symbol: Int
}

// ============================================================================
// 辅助函数
// ============================================================================

/// 计算最高位位置 (log2)
fn highbit32(v: Int) -> Int {
  if v <= 0 { return 0 }
  31 - v.clz()
}

/// 构建符号转换表。
pub fn build_symbol_transform_table(
  normalized: Array[Int],
  table_log: Int,
  max_symbol: Int
) -> Array[SymbolTransform] {
  let table_size = 1 << table_log
  let symbol_tt: Array[SymbolTransform] = []
  let cumul: Array[Int] = [0]
  for s = 0; s <= max_symbol; s = s + 1 {
    let norm = normalized[s]
    if norm == -1 {
      cumul.push(cumul[s] + 1)
    } else if norm >= 1 {
      cumul.push(cumul[s] + norm)
    } else {
      cumul.push(cumul[s])
    }
  }

  let mut total = 0
  for s = 0; s <= max_symbol; s = s + 1 {
    let norm = normalized[s]

    if norm == 0 {
      symbol_tt.push(SymbolTransform::{
        delta_nb_bits: ((table_log + 1) << 16) - table_size,
        delta_find_state: table_size
      })
    } else if norm == -1 || norm == 1 {
      symbol_tt.push(SymbolTransform::{
        delta_nb_bits: (table_log << 16) - table_size,
        delta_find_state: total - 1
      })
      total = total + 1
    } else {
      let max_bits_out = table_log - highbit32(norm - 1)
      let min_state_plus = norm << max_bits_out
      symbol_tt.push(SymbolTransform::{
        delta_nb_bits: (max_bits_out << 16) - min_state_plus,
        delta_find_state: total - norm
      })
      total = total + norm
    }
  }

  symbol_tt
}

/// 按 ZSTD 标准方式构建状态表。
fn build_state_table(normalized: Array[Int], table_log: Int) -> (Array[UInt16], Array[Int]) {
  let table_size = 1 << table_log
  let state_table: Array[UInt16] = Array::make(table_size, 0)
  let symbol_table: Array[Int] = Array::make(table_size, 0)

  let table_symbol: Array[Int] = Array::make(table_size, 0)
  let mut high_threshold = table_size - 1
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    if normalized[symbol] == -1 {
      table_symbol[high_threshold] = symbol
      high_threshold = high_threshold - 1
    }
  }

  let step = (table_size >> 1) + (table_size >> 3) + 3
  let mask = table_size - 1
  let mut position = 0
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    let freq = normalized[symbol]
    if freq <= 0 { continue }
    for _i = 0; _i < freq; _i = _i + 1 {
      table_symbol[position] = symbol
      position = (position + step) & mask
      while position > high_threshold { position = (position + step) & mask }
    }
  }

  let cumul: Array[Int] = Array::make(normalized.length() + 1, 0)
  for s = 1; s <= normalized.length(); s = s + 1 {
    let norm = if s - 1 < normalized.length() { normalized[s - 1] } else { 0 }
    cumul[s] = cumul[s - 1] + (if norm == -1 { 1 } else if norm > 0 { norm } else { 0 })
  }

  for u = 0; u < table_size; u = u + 1 {
    let s = table_symbol[u]
    let idx = cumul[s]
    cumul[s] = idx + 1
    if idx < state_table.length() {
      state_table[idx] = (table_size + u).to_uint16()
    }
  }

  for u = 0; u < table_size; u = u + 1 {
    symbol_table[u] = table_symbol[u]
  }

  (state_table, symbol_table)
}

/// 构建完整的 FSE 编码表。
pub fn build_fse_ctable(
  normalized: Array[Int],
  max_symbol: Int,
  table_log: Int
) -> Result[FSECTable, String] {
  if table_log < 5 || table_log > 12 {
    return Err("table_log must be between 5 and 12")
  }

  let symbol_tt = build_symbol_transform_table(normalized, table_log, max_symbol)
  let (state_table, symbol_table) = build_state_table(normalized, table_log)

  Ok(FSECTable::{
    symbol_tt: symbol_tt,
    state_table: state_table,
    symbol_table: symbol_table,
    table_log: table_log,
    normalized: normalized,
    max_symbol: max_symbol
  })
}

/// 统计符号频率
pub fn count_symbols(data: Array[Int], max_symbol: Int) -> Array[Int] {
  let counts = Array::make(max_symbol + 1, 0)
  for i = 0; i < data.length(); i = i + 1 {
    let symbol = data[i]
    if symbol >= 0 && symbol <= max_symbol {
      counts[symbol] = counts[symbol] + 1
    }
  }
  counts
}

/// 归一化频率到 2^tableLog
pub fn normalize_counts(counts: Array[Int], table_log: Int) -> Array[Int] {
  let table_size = 1 << table_log
  let mut total = 0

  for i = 0; i < counts.length(); i = i + 1 {
    if counts[i] == -1 {
      total = total + 1
    } else if counts[i] > 0 {
      total = total + counts[i]
    }
  }

  if total == 0 {
    return Array::make(counts.length(), 0)
  }

  let normalized: Array[Int] = []
  let mut distributed = 0

  for i = 0; i < counts.length(); i = i + 1 {
    if counts[i] == 0 {
      normalized.push(0)
    } else if counts[i] == -1 {
      normalized.push(-1)
      distributed = distributed + 1
    } else {
      let norm = (counts[i] * table_size) / total
      let final_norm = if norm == 0 && counts[i] > 0 { 1 } else { norm }
      normalized.push(final_norm)
      distributed = distributed + final_norm
    }
  }

  let remaining = table_size - distributed
  if remaining != 0 {
    let mut max_idx = -1
    let mut max_norm = 0
    for i = 0; i < normalized.length(); i = i + 1 {
      if normalized[i] > max_norm {
        max_norm = normalized[i]
        max_idx = i
      }
    }
    if max_idx >= 0 {
      normalized[max_idx] = normalized[max_idx] + remaining
    }
  }

  normalized
}

/// 构建 FSE 编码表（完整状态机实现）。
pub fn build_fse_encode_table(counts: Array[Int], table_log: Int) -> FSEEncodeTable {
  let normalized = normalize_counts(counts, table_log)
  let table_size = 1 << table_log
  let max_symbol = counts.length() - 1
  let symbol_table: Array[Int] = Array::make(table_size, 0)

  let mut position = 0
  for symbol = 0; symbol < normalized.length(); symbol = symbol + 1 {
    let count = normalized[symbol]
    for _j = 0; _j < count; _j = _j + 1 {
      if position < table_size {
        symbol_table[position] = symbol
        position = position + 1
      }
    }
  }

  let num_bits_table: Array[Int] = Array::make(max_symbol + 1, 0)
  for symbol = 0; symbol <= max_symbol; symbol = symbol + 1 {
    let count = normalized[symbol]
    if count > 0 {
      let log2_count = 31 - count.clz()
      let bits = (table_log - log2_count).max(0).min(table_log - 1)
      num_bits_table[symbol] = bits
    }
  }

  let next_state_table: Array[Array[Int]] = []
  for symbol = 0; symbol <= max_symbol; symbol = symbol + 1 {
    let num_bits = num_bits_table[symbol]
    let max_bits_value = if num_bits <= 10 { 1 << num_bits } else { 1024 }
    let state_transitions: Array[Int] = Array::make(max_bits_value, 0)

    for bits_val = 0; bits_val < max_bits_value; bits_val = bits_val + 1 {
      let next_state = (normalized[symbol] + bits_val) % table_size
      state_transitions[bits_val] = next_state
    }

    next_state_table.push(state_transitions)
  }

  FSEEncodeTable::{
    state_table: [],
    symbol_table: symbol_table,
    num_bits_table: num_bits_table,
    next_state_table: next_state_table,
    table_log: table_log,
    normalized_counts: normalized,
    max_symbol: max_symbol
  }
}

/// 使用 FSE 状态机编码符号序列（完整实现）
pub fn fse_encode_symbols(symbols: Array[Int], table: FSEEncodeTable) -> Bytes {
  if symbols.length() == 0 {
    return Bytes::from_array([])
  }

  let bit_buffer: Array[Int] = []
  let table_size = 1 << table.table_log
  let mut state = table_size

  for i = 0; i < symbols.length(); i = i + 1 {
    let symbol = symbols[i]
    if symbol < 0 || symbol > table.max_symbol {
      continue
    }

    let num_bits = table.num_bits_table[symbol]
    while state < table.normalized_counts[symbol] {
      bit_buffer.push(state & 1)
      state = state >> 1
    }

    let bits_value = state % (1 << num_bits)
    for bit_idx = 0; bit_idx < num_bits; bit_idx = bit_idx + 1 {
      let bit = (bits_value >> bit_idx) & 1
      bit_buffer.push(bit)
    }

    let next_state_idx = bits_value.min(table.next_state_table[symbol].length() - 1)
    state = table.next_state_table[symbol][next_state_idx]
  }

  let final_state_bits = table.table_log
  for bit_idx = 0; bit_idx < final_state_bits; bit_idx = bit_idx + 1 {
    let bit = (state >> bit_idx) & 1
    bit_buffer.push(bit)
  }

  let output: Array[Byte] = []
  let mut byte_val = 0
  let mut bit_count = 0

  for i = 0; i < bit_buffer.length(); i = i + 1 {
    let bit = bit_buffer[i]
    byte_val = byte_val | (bit << bit_count)
    bit_count = bit_count + 1

    if bit_count == 8 {
      output.push(byte_val.to_byte())
      byte_val = 0
      bit_count = 0
    }
  }

  if bit_count > 0 {
    output.push(byte_val.to_byte())
  }

  Bytes::from_array(output)
}

/// 序列化 FSE 表头（兼容解码器格式）
pub fn serialize_fse_table(normalized_counts: Array[Int], table_log: Int) -> Bytes {
  let output: Array[Byte] = []
  let accuracy_byte = (table_log - 5) & 0x0F
  output.push(accuracy_byte.to_byte())

  let mut i = 0
  while i < normalized_counts.length() {
    let count = normalized_counts[i]
    let mut repeat_count = 1

    while i + repeat_count < normalized_counts.length() &&
          normalized_counts[i + repeat_count] == count &&
          repeat_count < 127 {
      repeat_count = repeat_count + 1
    }

    if repeat_count >= 3 {
      output.push((128 + repeat_count).to_byte())
      output.push(count.to_byte())
      i = i + repeat_count
    } else {
      for _j = 0; _j < repeat_count; _j = _j + 1 {
        if count < 128 {
          output.push(count.to_byte())
        } else {
          let high = count / 128
          let low = count % 128
          output.push(high.to_byte())
          output.push(low.to_byte())
        }
      }
      i = i + repeat_count
    }
  }

  Bytes::from_array(output)
}

// ============================================================================
// tANS 编码
// ============================================================================

/// 初始化 FSE 编码状态
pub fn init_fse_cstate(table: FSECTable) -> UInt64 {
  (1 << table.table_log).to_uint64()
}

/// 用指定符号初始化 FSE 编码状态
pub fn init_fse_cstate_with_symbol(table: FSECTable, symbol: Int) -> UInt64 {
  let table_size = 1 << table.table_log
  if symbol < 0 || symbol >= table.symbol_tt.length() {
    return table_size.to_uint64()
  }

  let transform = table.symbol_tt[symbol]
  let delta_nb_bits = transform.delta_nb_bits
  let nb_bits_out = ((delta_nb_bits + (1 << 15)) >> 16) & 0xFFFF
  let mut state_value = (nb_bits_out << 16) - delta_nb_bits
  let table_idx = (state_value >> nb_bits_out) + transform.delta_find_state

  if table_idx >= 0 && table_idx < table.state_table.length() {
    state_value = table.state_table[table_idx].to_int()
  } else {
    state_value = table_size + transform.delta_find_state
  }

  state_value.to_uint64()
}

/// 使用 FSECTable 解码 FSE 序列。
pub fn decode_fse_sequences_with_tables(
  data: Bytes,
  offset: Int,
  num_sequences: Int,
  ll_table: FSECTable,
  of_table: FSECTable,
  ml_table: FSECTable
) -> Result[Array[Sequence], String] {
  if num_sequences == 0 {
    return Ok([])
  }

  // 第 1 步：先准备反向位流读取器。
  let fse_data_len = data.length() - offset
  if fse_data_len < 1 {
    return Err("FSE data too short")
  }

  let temp_bs = BitstreamReader::{
    data: data,
    offset: 0,
    bit_container: 0UL,
    bit_pos: 0,
    end_offset: offset,
    reload_failed: false,
  }

  if fse_data_len >= 8 {
    temp_bs.offset = offset + fse_data_len - 8

    let mut container = 0UL
    for i = 0; i < 8; i = i + 1 {
      let byte_val = data[temp_bs.offset + i].to_uint64()
      container = container | (byte_val << (i * 8))
    }
    temp_bs.bit_container = container
    temp_bs.bit_pos = 0
  }

  // 第 2 步：从位流末尾读取三类初始状态。
  let (bs1, ll_state_raw) = read_bits_uint64(temp_bs, 6)
  let mut ll_state = ll_state_raw + 64UL
  let (bs2, of_state_raw) = read_bits_uint64(bs1, 5)
  let mut of_state = of_state_raw + 32UL
  let (bs3, ml_state_raw) = read_bits_uint64(bs2, 6)
  let mut ml_state = ml_state_raw + 64UL
  let mut current_bs = bs3

  // 第 3 步：逐个状态解码符号，再读取额外位，最终恢复序列三元组。
  let temp_sequences: Array[Sequence] = Array::make(num_sequences, @zstd_core.make_sequence(0, 0, 0))
  for seq_idx = (num_sequences - 1); seq_idx >= 0; seq_idx = seq_idx - 1 {
    let (ll_symbol, new_ll_state, ll_nb_bits) = decode_symbol_from_state(ll_state, ll_table)
    let (of_symbol, new_of_state, of_nb_bits) = decode_symbol_from_state(of_state, of_table)
    let (ml_symbol, new_ml_state, ml_nb_bits) = decode_symbol_from_state(ml_state, ml_table)

    let (bs_ll, ll_extra) = if ll_nb_bits > 0 { read_bits_uint64(current_bs, ll_nb_bits) } else { (current_bs, 0UL) }
    let (bs_of, of_extra) = if of_nb_bits > 0 { read_bits_uint64(bs_ll, of_nb_bits) } else { (bs_ll, 0UL) }
    let (bs_ml, ml_extra) = if ml_nb_bits > 0 { read_bits_uint64(bs_of, ml_nb_bits) } else { (bs_of, 0UL) }
    current_bs = bs_ml

    let final_ll = decode_ll(ll_symbol, ll_extra.to_int())
    let final_of = decode_of(of_symbol, of_extra.to_int())
    let final_ml = decode_ml(ml_symbol, ml_extra.to_int())

    let seq = make_sequence(final_ll, final_ml, final_of)
    temp_sequences[num_sequences - 1 - seq_idx] = seq

    ll_state = new_ll_state
    of_state = new_of_state
    ml_state = new_ml_state
  }

  Ok(temp_sequences)
}

/// 从状态解码单个符号（优化版本）
fn decode_symbol_from_state(state: UInt64, table: FSECTable) -> (Int, UInt64, Int) {
  let state_int = state.to_int()
  for s = 0; s <= table.max_symbol && s < table.symbol_tt.length(); s = s + 1 {
    let transform = table.symbol_tt[s]
    let sum = state_int + transform.delta_nb_bits
    let nb_bits_out = sum >> 16
    let state_idx = (state_int >> nb_bits_out) + transform.delta_find_state

    if state_idx >= 0 && state_idx < table.state_table.length() &&
       table.state_table[state_idx].to_int() == state_int {
      let new_state = (1 << table.table_log).to_uint64()
      return (s, new_state, nb_bits_out)
    }
  }

  (0, state, 0)
}

/// 更新 FSE 状态 (不输出 bits，用于解码)
pub fn update_fse_state(
  state: UInt64,
  symbol: Int,
  table: FSECTable
) -> UInt64 {
  if symbol < 0 || symbol > table.max_symbol {
    return state
  }

  let transform = table.symbol_tt[symbol]
  let state_int = state.to_int()
  let sum = state_int + transform.delta_nb_bits
  let nb_bits_out = sum >> 16
  let base_state = state_int >> nb_bits_out
  let state_idx = base_state + transform.delta_find_state

  let new_state = if state_idx >= 0 && state_idx < table.state_table.length() {
    table.state_table[state_idx].to_int()
  } else {
    1 << table.table_log
  }

  new_state.to_uint64()
}

/// 编码单个符号（tANS 核心算法）。
pub fn encode_symbol_fse(
  state: UInt64,
  symbol: Int,
  table: FSECTable,
  bitstream: BitStream
) -> UInt64 {
  if symbol < 0 || symbol > table.max_symbol {
    println("    ⚠️ 符号超出范围: \{symbol}")
    return state
  }

  // 第 1 步：根据符号查出该符号的状态转移参数。
  let transform = table.symbol_tt[symbol]
  let state_int = state.to_int()
  let sum = state_int + transform.delta_nb_bits
  let nb_bits_out = sum >> 16

  // 第 2 步：把当前状态需要吐出的低位写进位流。
  if nb_bits_out > 0 {
    let mask = if nb_bits_out >= 64 { 0xFFFFFFFFFFFFFFFFUL } else { (1UL << nb_bits_out) - 1UL }
    let bits_to_output = state & mask
    add_bits(bitstream, bits_to_output, nb_bits_out)
  }

  // 第 3 步：根据高位部分查表得到新状态。
  let base_state = state_int >> nb_bits_out
  let state_idx = base_state + transform.delta_find_state
  let new_state = if state_idx >= 0 && state_idx < table.state_table.length() {
    table.state_table[state_idx].to_int()
  } else {
    1 << table.table_log
  }

  new_state.to_uint64()
}

/// 编码符号序列（tANS 完整实现）。
pub fn fse_encode_sequence(
  symbols: Array[Int],
  table: FSECTable,
  bitstream: BitStream
) -> Result[UInt64, String] {
  if symbols.length() == 0 {
    return Ok(init_fse_cstate(table))
  }

  // 第 1 步：初始化状态机。
  let mut state = init_fse_cstate(table)
  // 第 2 步：按倒序写入符号，匹配解码侧的反向位流读取方式。
  let mut i = symbols.length() - 1
  while i >= 0 {
    state = encode_symbol_fse(state, symbols[i], table, bitstream)
    i = i - 1
  }

  Ok(state)
}

/// 刷新最终状态到位流
pub fn flush_final_state(bitstream: BitStream, state: UInt64, table_log: Int) -> Unit {
  let table_size = 1UL << table_log
  let normalized_state = state - table_size
  add_bits(bitstream, normalized_state, table_log)
}

/// 完整 FSE 编码器实现（tANS 版本）。
pub fn fse_encode_complete_tans(symbols: Array[Int], max_symbol: Int, table_log: Int) -> Result[Bytes, String] {
  if symbols.length() == 0 {
    return Err("Empty symbol sequence")
  }

  // 第 1 步：统计频率、归一化并构建编码表。
  let counts = count_symbols(symbols, max_symbol)
  let normalized = normalize_counts(counts, table_log)
  let table_result = build_fse_ctable(normalized, max_symbol, table_log)
  let table = match table_result {
    Ok(t) => t
    Err(e) => return Err(e)
  }

  let table_header = serialize_fse_table(normalized, table_log)
  // 第 2 步：编码符号流，并把最终状态补到末尾。
  let bitstream = create_bitstream()
  let final_state = match fse_encode_sequence(symbols, table, bitstream) {
    Ok(s) => s
    Err(e) => return Err(e)
  }

  flush_final_state(bitstream, final_state, table_log)
  flush_bits(bitstream)

  // 第 3 步：把表头和编码后的位流合并成最终结果。
  let encoded_data = get_bytes(bitstream)
  let result: Array[Byte] = []
  for i = 0; i < table_header.length(); i = i + 1 {
    result.push(table_header[i])
  }
  for i = 0; i < encoded_data.length(); i = i + 1 {
    result.push(encoded_data[i])
  }

  Ok(Bytes::from_array(result))
}

/// ✅ FSE 编码器完整实现（兼容旧版本）
pub fn fse_encode_complete(symbols: Array[Int], max_symbol: Int, table_log: Int) -> Result[Bytes, String] {
  fse_encode_complete_tans(symbols, max_symbol, table_log)
}

/// 调试函数：测试 FSE 解码序列
pub fn debug_fse_decode_sequences(
  data: Bytes,
  offset: Int,
  num_sequences: Int,
  ll_weights: Array[Int],
  ml_weights: Array[Int],
  of_weights: Array[Int]
) -> Unit {
  println("🔍 FSE 调试: num_sequences=\{num_sequences}, offset=\{offset}")

  let ll_sample = if ll_weights.length() >= 6 { [ll_weights[0], ll_weights[1], ll_weights[2], ll_weights[3], ll_weights[4], ll_weights[5]] } else { [] }
  let of_sample = if of_weights.length() >= 6 { [of_weights[0], of_weights[1], of_weights[2], of_weights[3], of_weights[4], of_weights[5]] } else { [] }
  let ml_sample = if ml_weights.length() >= 6 { [ml_weights[0], ml_weights[1], ml_weights[2], ml_weights[3], ml_weights[4], ml_weights[5]] } else { [] }
  println("  LL权重 (前6): \{ll_sample}")
  println("  OF权重 (前6): \{of_sample}")
  println("  ML权重 (前6): \{ml_sample}")

  match decode_fse_sequences(data, offset, num_sequences, ll_weights, ml_weights, of_weights, [1, 4, 8]) {
    Ok(sequences) => {
      println("✅ FSE 解码成功: \{sequences.length()} 个序列")
      for i = 0; i < sequences.length(); i = i + 1 {
        let seq = sequences[i]
        println(
          "  序列\{i}: LL=\{@zstd_core.get_sequence_literal_length(seq)}, ML=\{@zstd_core.get_sequence_match_length(seq)}, OF=\{@zstd_core.get_sequence_offset(seq)}"
        )
      }
    }
    Err(e) => {
      println("❌ FSE 解码失败: \{e}")
    }
  }
}

/// 原始的 FSE 解码实现（回退用）
fn decode_fse_sequences_original(
  data: Bytes,
  offset: Int,
  num_sequences: Int,
  ll_weights: Array[Int],
  ml_weights: Array[Int],
  of_weights: Array[Int],
  prev_offsets: Array[Int]
) -> Result[Array[Sequence], String] {
  if num_sequences == 0 {
    return Ok([])
  }

  let ll_dtable = build_fse_dtable(ll_weights, 6)
  let ml_dtable = build_fse_dtable(ml_weights, 6)
  let of_dtable = build_fse_dtable(of_weights, 5)

  let fse_data_len = data.length() - offset
  if fse_data_len < 1 {
    return Err("FSE data too short")
  }

  let temp_bs = BitstreamReader::{
    data: data,
    offset: 0,
    bit_container: 0UL,
    bit_pos: 0,
    end_offset: offset,
    reload_failed: false,
  }

  if fse_data_len >= 8 {
    temp_bs.offset = offset + fse_data_len - 8
    let mut container = 0UL
    for i = 0; i < 8; i = i + 1 {
      let byte_val = data[temp_bs.offset + i].to_uint64()
      container = container | (byte_val << (i * 8))
    }
    temp_bs.bit_container = container

    let last_byte_idx = offset + fse_data_len - 1
    let last_byte = data[last_byte_idx].to_int()
    let bits_consumed_raw = if last_byte == 0 { 0 } else { 8 - highbit32(last_byte) }
    temp_bs.bit_pos = bits_consumed_raw
  } else {
    temp_bs.offset = offset
    let mut container = 0UL
    for i = 0; i < fse_data_len; i = i + 1 {
      let byte_val = data[offset + i].to_uint64()
      container = container | (byte_val << (i * 8))
    }
    temp_bs.bit_container = container

    let last_byte_idx = offset + fse_data_len - 1
    let last_byte = data[last_byte_idx].to_int()
    let bits_consumed_byte = if last_byte == 0 { 0 } else { 8 - highbit32(last_byte) }
    let extra_bits = (8 - fse_data_len) * 8
    let bits_consumed = bits_consumed_byte + extra_bits
    temp_bs.bit_pos = bits_consumed
  }

  let (bs1, ll_state_raw) = read_bits_uint64(temp_bs, 6)
  let (bs2, of_state_raw) = read_bits_uint64(bs1, 5)
  let (bs3, ml_state_raw) = read_bits_uint64(bs2, 6)
  let bs_after_ml_reload = bs3

  let ll_s = ll_state_raw + 64UL
  let of_s = of_state_raw + 32UL
  let ml_s = ml_state_raw + 64UL

  let mut current_bs = bs_after_ml_reload
  let mut ll_state = ll_s
  let mut of_state = of_s
  let mut ml_state = ml_s

  let sequences: Array[Sequence] = []
  for seq_idx = 0; seq_idx < num_sequences; seq_idx = seq_idx + 1 {
    let ll_entry_result = get_fse_decode_entry(ll_state.to_int(), ll_dtable, 6)
    let ml_entry_result = get_fse_decode_entry(ml_state.to_int(), ml_dtable, 6)
    let of_entry_result = get_fse_decode_entry(of_state.to_int(), of_dtable, 5)

    let (ll_entry, ml_entry, of_entry, ll_code, ml_code, of_code) = match (ll_entry_result, ml_entry_result, of_entry_result) {
      (Ok(ll_e), Ok(ml_e), Ok(of_e)) => {
        (ll_e, ml_e, of_e, ll_e.symbol, ml_e.symbol, of_e.symbol)
      }
      _ => return Err("FSE状态越界错误")
    }

    let mut final_of = decode_of(of_code, 0)
    let of_nb = get_of_bits(of_code)
    let (bs_a, of_ex) = if of_nb > 0 { read_bits_uint64(current_bs, of_nb) } else { (current_bs, 0UL) }
    final_of = final_of + of_ex.to_int()

    let mut final_ml = decode_ml(ml_code, 0)
    let ml_nb = get_ml_bits(ml_code)
    let (bs_b, ml_ex) = if ml_nb > 0 { read_bits_uint64(bs_a, ml_nb) } else { (bs_a, 0UL) }
    final_ml = final_ml + ml_ex.to_int()

    let bs_b_reloaded = reload_dstream(bs_b)
    let mut final_ll = decode_ll(ll_code, 0)
    let ll_nb = get_ll_bits(ll_code)
    let (bs_c, ll_ex) = if ll_nb > 0 { read_bits_uint64(bs_b_reloaded, ll_nb) } else { (bs_b_reloaded, 0UL) }
    final_ll = final_ll + ll_ex.to_int()

    if seq_idx < num_sequences - 1 {
      if bs_c.reload_failed {
        return Err("Bitstream exhausted before state transitions")
      }

      let (bs1, ll_st) = read_bits_uint64(bs_c, ll_entry.nb_bits)
      ll_state = (ll_entry.new_state_base + ll_st.to_int() + 64).to_uint64()

      let (bs2, ml_st) = read_bits_uint64(bs1, ml_entry.nb_bits)
      ml_state = (ml_entry.new_state_base + ml_st.to_int() + 64).to_uint64()

      let (bs3, of_st) = read_bits_uint64(bs2, of_entry.nb_bits)
      of_state = (of_entry.new_state_base + of_st.to_int() + 32).to_uint64()

      current_bs = reload_dstream(bs3)
    } else {
      current_bs = bs_c
    }

    let resolved_of = if of_nb >= 2 {
      let p0 = prev_offsets[0]
      let p1 = prev_offsets[1]
      prev_offsets[2] = p1
      prev_offsets[1] = p0
      prev_offsets[0] = final_of
      final_of
    } else {
      let ll0 = if final_ll == 0 { 1 } else { 0 }
      let c_code = final_of + ll0
      if c_code == 0 {
        prev_offsets[0]
      } else if c_code == 1 {
        let actual = prev_offsets[1]
        prev_offsets[1] = prev_offsets[0]
        prev_offsets[0] = actual
        actual
      } else if c_code == 2 {
        let actual = prev_offsets[2]
        prev_offsets[2] = prev_offsets[1]
        prev_offsets[1] = prev_offsets[0]
        prev_offsets[0] = actual
        actual
      } else {
        let actual = prev_offsets[0] - 1
        prev_offsets[2] = prev_offsets[1]
        prev_offsets[1] = prev_offsets[0]
        prev_offsets[0] = actual
        actual
      }
    }
    sequences.push(make_sequence(final_ll, final_ml, resolved_of))
  }

  Ok(sequences)
}
