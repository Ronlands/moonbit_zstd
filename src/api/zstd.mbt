/// Compression level presets.
///
/// Maps to internal numeric levels:
/// - `Fast` → level 1
/// - `Default` → level 3
/// - `Better` → level 6
/// - `Best` → level 9
pub enum CompressionLevel {
  Fast
  Default
  Better
  Best
}

/// Result of analyzing a ZSTD compressed file's structure.
///
/// Contains frame header information, block metadata, and validation status.
pub struct ZSTDFileAnalysis {
  is_valid: Bool
  error_message: String
  magic_number: UInt
  single_segment: Bool
  content_checksum: Bool
  window_size: UInt
  total_blocks: Int
  file_size: Int
  first_block_type: String
  first_block_size: Int
  last_block: Bool
}

/// Result of data integrity analysis.
pub struct DataIntegrityAnalysis {
  truncation_indicators: Int
  data_density: Double
  structure_consistency: Double
  entropy_level: Double
}

/// Sliding window decoder context for streaming decompression.
///
/// Maintains internal state across multiple `decompress_with_sliding_window` calls.
pub struct SlidingWindowDecoder {
  mut context: @zstd_decoder.DecoderContext
  window_size: Int
}

/// 流式压缩器上下文。
///
/// 这是 API 层对 encoder 流式压缩状态的轻量包装，
/// 对外暴露 `create / write / flush / finish / reset` 生命周期接口。
pub struct StreamingCompressor {
  context: @zstd_encoder.StreamingCompressor
}

/// 流式压缩统计结果。
///
/// 这是 API 层对 encoder 统计快照的映射版本，便于调用方直接读取。
pub struct StreamingCompressionStats {
  total_input_size: Int
  total_output_size: Int
  emitted_block_count: Int
  raw_block_count: Int
  rle_block_count: Int
  compressed_block_count: Int
  flush_count: Int
  auto_flush_count: Int
  pending_size: Int
  history_size: Int
  window_size: Int
  checksum_enabled: Bool
  current_checksum: UInt
  final_checksum: UInt
  header_written: Bool
  finished: Bool
}

/// Entry decoded from this project's lightweight path archive format.
///
/// The archive format is intentionally private to this project. It exists to
/// make file and directory compression tests convenient; it is not tar/zip.
pub struct PathArchiveEntry {
  path: String
  is_dir: Bool
  data: Bytes
}

priv struct PathArchiveBuildEntry {
  path: String
  is_dir: Bool
  data: Bytes
}

/// 创建流式压缩器。
///
/// 说明：
/// - `level` 会按 encoder 规则约束到 `[1, 22]`
/// - 该接口默认不写 checksum
pub fn create_streaming_compressor(level: Int) -> StreamingCompressor {
  let config = @zstd_encoder.create_config_with_level(level)
  let context = @zstd_encoder.new_streaming_compressor(config, false)
  StreamingCompressor::{ context }
}

/// 创建可选 checksum 的流式压缩器。
pub fn create_streaming_compressor_with_checksum(level: Int, with_checksum: Bool) -> StreamingCompressor {
  let config = @zstd_encoder.create_config_with_level(level)
  let context = @zstd_encoder.new_streaming_compressor(config, with_checksum)
  StreamingCompressor::{ context }
}

/// 写入一个流式压缩 chunk。
///
/// 返回值只包含本次新增产出的字节，可直接顺序拼接到最终输出流。
pub fn write_streaming_chunk(
  compressor: StreamingCompressor,
  chunk: Bytes
) -> Result[Bytes, @zstd_core.ZSTDError] {
  @zstd_encoder.write_streaming_chunk(compressor.context, chunk)
}

/// 强制把当前待处理数据落成一个非最后块。
pub fn flush_streaming_compressor(compressor: StreamingCompressor) -> Result[Bytes, @zstd_core.ZSTDError] {
  @zstd_encoder.flush_streaming_compressor(compressor.context)
}

/// 结束当前流式压缩帧并返回最后字节序列。
pub fn finish_streaming_compressor(compressor: StreamingCompressor) -> Result[Bytes, @zstd_core.ZSTDError] {
  @zstd_encoder.finish_streaming_compressor(compressor.context)
}

/// 重置流式压缩器内部状态。
pub fn reset_streaming_compressor(compressor: StreamingCompressor) -> Unit {
  @zstd_encoder.reset_streaming_compressor(compressor.context)
}

/// 获取流式压缩统计快照。
pub fn get_streaming_compressor_stats(compressor: StreamingCompressor) -> StreamingCompressionStats {
  let stats = @zstd_encoder.get_streaming_compression_stats(compressor.context)
  StreamingCompressionStats::{
    total_input_size: stats.total_input_size,
    total_output_size: stats.total_output_size,
    emitted_block_count: stats.emitted_block_count,
    raw_block_count: stats.raw_block_count,
    rle_block_count: stats.rle_block_count,
    compressed_block_count: stats.compressed_block_count,
    flush_count: stats.flush_count,
    auto_flush_count: stats.auto_flush_count,
    pending_size: stats.pending_size,
    history_size: stats.history_size,
    window_size: stats.window_size,
    checksum_enabled: stats.checksum_enabled,
    current_checksum: stats.current_checksum,
    final_checksum: stats.final_checksum,
    header_written: stats.header_written,
    finished: stats.finished,
  }
}

/// 格式化流式压缩统计信息。
pub fn format_streaming_compressor_stats(stats: StreamingCompressionStats) -> String {
  "流式压缩统计:\n" +
  "  输入字节: " + stats.total_input_size.to_string() + "\n" +
  "  输出字节: " + stats.total_output_size.to_string() + "\n" +
  "  已发块数: " + stats.emitted_block_count.to_string() +
  " (raw=" + stats.raw_block_count.to_string() +
  ", rle=" + stats.rle_block_count.to_string() +
  ", compressed=" + stats.compressed_block_count.to_string() + ")\n" +
  "  flush 次数: " + stats.flush_count.to_string() +
  " (自动=" + stats.auto_flush_count.to_string() + ")\n" +
  "  pending 字节: " + stats.pending_size.to_string() + "\n" +
  "  历史窗口字节: " + stats.history_size.to_string() + "/" + stats.window_size.to_string() + "\n" +
  "  checksum 开启: " + (if stats.checksum_enabled { "是" } else { "否" }) + "\n" +
  "  当前 checksum: " + stats.current_checksum.to_string() + "\n" +
  "  最终 checksum: " + stats.final_checksum.to_string() + "\n" +
  "  帧头已写: " + (if stats.header_written { "是" } else { "否" }) + "\n" +
  "  已完成: " + (if stats.finished { "是" } else { "否" })
}

/// Compress data with a numeric compression level (1-22).
///
/// Higher levels produce smaller output at the cost of speed.
/// Level is clamped to `[1, 22]`.
///
/// # Example
///
/// ```moonbit no-check
/// let compressed = @zstd.compress_with_level_int(data, 9)
/// ```
pub fn compress_with_level_int(data: Bytes, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_advanced(data, CompressionMethod::Auto, level)
}

/// Compress using a Raw block (no compression, just ZSTD frame wrapping).
pub fn compress_as_raw(data: Bytes, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_advanced(data, CompressionMethod::Raw, level)
}

/// Compress using an RLE block (ideal for highly repetitive data).
pub fn compress_as_rle(data: Bytes, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_advanced(data, CompressionMethod::RLE, level)
}

/// Compress using a Compressed block (LZ77 + FSE entropy coding).
///
/// Produces the best compression ratio for most data.
pub fn compress_as_compressed(data: Bytes, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  compress_advanced(data, CompressionMethod::Compressed, level)
}

/// Compress data using default settings (level 2, auto block type selection).
///
/// This is the simplest entry point. For more control, use
/// `compress_with_level_int` or `compress_advanced`.
///
/// # Example
///
/// ```moonbit no-check
/// let original = @utf8.encode("Hello, ZSTD!")
/// match @zstd.compress(original) {
///   Ok(compressed) => {
///     match @zstd.decompress(compressed) {
///       Ok(decompressed) => println("Decoded \{decompressed.length()} bytes")
///       Err(e) => println("Decompression failed: \{e}")
///     }
///   }
///   Err(e) => println("Compression failed: \{e}")
/// }
/// ```
pub fn compress(data: Bytes) -> Result[Bytes, @zstd_core.ZSTDError] {
  @zstd_encoder.compress(data)
}

/// Compress data with a `CompressionLevel` preset.
///
/// # Example
///
/// ```moonbit no-check
/// let compressed = @zstd.compress_with_level(data, CompressionLevel::Better)
/// ```
pub fn compress_with_level(data: Bytes, level: CompressionLevel) -> Result[Bytes, @zstd_core.ZSTDError] {
  let compression_level = match level {
    CompressionLevel::Fast => 1
    CompressionLevel::Default => 3
    CompressionLevel::Better => 6
    CompressionLevel::Best => 9
  }

  let config = @zstd_encoder.create_config_with_level(compression_level)
  @zstd_encoder.compress_data(data, config)
}

/// Compression method selection.
///
/// - `Auto` — automatically selects the best method based on data characteristics
/// - `Raw` — no compression, just ZSTD frame wrapping
/// - `RLE` — run-length encoding for highly repetitive data
/// - `Compressed` — LZ77 + FSE entropy coding for best ratio
pub enum CompressionMethod {
  Auto
  Raw
  RLE
  Compressed
} derive(Debug)

fn choose_compression_method(data: Bytes) -> (String, Byte, Int) {
  if data.length() == 0 { return ("raw", 0, 0) }
  if is_suitable_for_rle(data) { return ("rle", data[0], data.length()) }
  ("raw", 0, data.length())
}

fn is_suitable_for_rle(data: Bytes) -> Bool {
  if data.length() < 4 { return false }
  let first_byte = data[0]
  let mut same_count = 1
  for i = 1; i < data.length(); i = i + 1 {
    if data[i] == first_byte { same_count = same_count + 1 } else { break }
  }
  same_count.to_double() / data.length().to_double() > 0.75
}

/// Compress with full control over method and level.
///
/// # Parameters
///
/// - `data` — bytes to compress
/// - `mode` — compression method (`Auto`, `Raw`, `RLE`, or `Compressed`)
/// - `level` — numeric compression level (1-22, clamped)
///
/// # Example
///
/// ```moonbit no-check
/// let compressed = @zstd.compress_advanced(data, Compressed, 5)
/// ```
pub fn compress_advanced(data: Bytes, mode: CompressionMethod, level: Int) -> Result[Bytes, @zstd_core.ZSTDError] {
  let actual_level = if level < 1 { 2 } else if level > 22 { 22 } else { level }
  let config = @zstd_encoder.create_config_with_level(actual_level)

  match mode {
    CompressionMethod::Auto => {
      let (compression_type, _byte, _size) = choose_compression_method(data)
      if compression_type == "rle" {
        @zstd_encoder.compress_as_rle_block(data, config)
      } else {
        @zstd_encoder.compress_data(data, config)
      }
    }
    CompressionMethod::Raw => @zstd_encoder.compress_as_raw_block(data, config)
    CompressionMethod::RLE => @zstd_encoder.compress_as_rle_block(data, config)
    CompressionMethod::Compressed => @zstd_encoder.compress_as_compressed_block(data, config)
  }
}

fn normalize_archive_path(path: String) -> String {
  path.replace_all(old="\\", new="/")
}

fn path_basename(path: String) -> String {
  let normalized = normalize_archive_path(path).trim_end(chars="/").to_string()
  match normalized.rev_after("/") {
    Some(name) => name.to_string()
    None => normalized
  }
}

fn join_fs_path(base: String, name: String) -> String {
  if base.has_suffix("/") || base.has_suffix("\\") {
    base + name
  } else {
    base + "/" + name
  }
}

fn join_archive_path(base: String, name: String) -> String {
  let clean_name = normalize_archive_path(name)
  if base.length() == 0 {
    clean_name
  } else {
    base + "/" + clean_name
  }
}

fn is_safe_archive_path(path: String) -> Bool {
  let normalized = normalize_archive_path(path)
  if normalized.length() == 0 || normalized.has_prefix("/") {
    return false
  }

  let parts = normalized.split("/").map(fn(part) { part.to_string() }).collect()
  for i = 0; i < parts.length(); i = i + 1 {
    let part = parts[i]
    if part.length() == 0 || part == "." || part == ".." || part.contains(":") {
      return false
    }
  }
  true
}

fn write_u32_archive(output: Array[Byte], value: Int) -> Unit {
  output.push((value & 0xFF).to_byte())
  output.push(((value >> 8) & 0xFF).to_byte())
  output.push(((value >> 16) & 0xFF).to_byte())
  output.push(((value >> 24) & 0xFF).to_byte())
}

fn read_u32_archive(data: Bytes, offset: Int) -> Int {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

fn append_bytes(output: Array[Byte], data: Bytes) -> Unit {
  for i = 0; i < data.length(); i = i + 1 {
    output.push(data[i])
  }
}

fn append_zeroes(output: Array[Byte], count: Int) -> Unit {
  for _i = 0; _i < count; _i = _i + 1 {
    output.push((0).to_byte())
  }
}

fn write_tar_string_field(
  header: Array[Byte],
  offset: Int,
  field_len: Int,
  value: String
) -> Result[Unit, @zstd_core.ZSTDError] {
  let bytes = @utf8.encode(value)
  if bytes.length() > field_len {
    return Err(@zstd_core.message_error("Tar path field is too long: " + value))
  }
  for i = 0; i < bytes.length(); i = i + 1 {
    header[offset + i] = bytes[i]
  }
  Ok(())
}

fn write_tar_octal_field(header: Array[Byte], offset: Int, field_len: Int, value: Int) -> Unit {
  let mut v = value
  let mut pos = offset + field_len - 2
  while pos >= offset {
    header[pos] = (48 + (v & 7)).to_byte()
    v = v >> 3
    pos = pos - 1
  }
  header[offset + field_len - 1] = (0).to_byte()
}

fn write_tar_checksum_field(header: Array[Byte], checksum: Int) -> Unit {
  let mut v = checksum
  let mut pos = 153
  while pos >= 148 {
    header[pos] = (48 + (v & 7)).to_byte()
    v = v >> 3
    pos = pos - 1
  }
  header[154] = (0).to_byte()
  header[155] = b' '
}

fn make_tar_header(entry: PathArchiveBuildEntry) -> Result[Bytes, @zstd_core.ZSTDError] {
  let header: Array[Byte] = Array::make(512, (0).to_byte())
  let tar_path = if entry.is_dir && !entry.path.has_suffix("/") {
    entry.path + "/"
  } else {
    entry.path
  }
  if !is_safe_archive_path(tar_path.trim_end(chars="/").to_string()) {
    return Err(@zstd_core.message_error("Unsafe tar path: " + entry.path))
  }

  match write_tar_string_field(header, 0, 100, tar_path) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  write_tar_octal_field(header, 100, 8, if entry.is_dir { 493 } else { 420 })
  write_tar_octal_field(header, 108, 8, 0)
  write_tar_octal_field(header, 116, 8, 0)
  write_tar_octal_field(header, 124, 12, if entry.is_dir { 0 } else { entry.data.length() })
  write_tar_octal_field(header, 136, 12, 0)
  for i = 148; i < 156; i = i + 1 {
    header[i] = b' '
  }
  header[156] = if entry.is_dir { b'5' } else { b'0' }
  match write_tar_string_field(header, 257, 6, "ustar") {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match write_tar_string_field(header, 263, 2, "00") {
    Ok(_) => ()
    Err(e) => return Err(e)
  }

  let mut checksum = 0
  for i = 0; i < header.length(); i = i + 1 {
    checksum = checksum + header[i].to_int()
  }
  write_tar_checksum_field(header, checksum)
  Ok(Bytes::from_array(header))
}

fn encode_tar_archive(entries: Array[PathArchiveBuildEntry]) -> Result[Bytes, @zstd_core.ZSTDError] {
  let output: Array[Byte] = []
  for i = 0; i < entries.length(); i = i + 1 {
    let entry = entries[i]
    match make_tar_header(entry) {
      Ok(header) => append_bytes(output, header)
      Err(e) => return Err(e)
    }
    if !entry.is_dir {
      append_bytes(output, entry.data)
      let padding = (512 - (entry.data.length() % 512)) % 512
      append_zeroes(output, padding)
    }
  }
  append_zeroes(output, 1024)
  Ok(Bytes::from_array(output))
}

fn is_zero_tar_block(data: Bytes, offset: Int) -> Bool {
  if offset + 512 > data.length() {
    return false
  }
  for i = 0; i < 512; i = i + 1 {
    if data[offset + i] != 0 {
      return false
    }
  }
  true
}

fn read_tar_string(data: Bytes, offset: Int, field_len: Int) -> String {
  let output: Array[Byte] = []
  let mut i = 0
  while i < field_len && data[offset + i] != 0 {
    output.push(data[offset + i])
    i = i + 1
  }
  @utf8.decode_lossy(Bytes::from_array(output))
}

fn read_tar_octal(data: Bytes, offset: Int, field_len: Int) -> Int {
  let mut value = 0
  for i = 0; i < field_len; i = i + 1 {
    let byte = data[offset + i].to_int()
    if byte >= 48 && byte <= 55 {
      value = (value << 3) + (byte - 48)
    }
  }
  value
}

fn decode_tar_to_dir(tar_data: Bytes, output_dir: String) -> Result[Array[PathArchiveEntry], @zstd_core.ZSTDError] raise {
  if @fs.path_exists(output_dir) {
    if !@fs.is_dir(output_dir) {
      return Err(@zstd_core.message_error("Output path is not a directory: " + output_dir))
    }
  } else {
    @fs.create_dir(output_dir)
  }

  let entries: Array[PathArchiveEntry] = []
  let mut offset = 0
  while offset + 512 <= tar_data.length() {
    if is_zero_tar_block(tar_data, offset) {
      return Ok(entries)
    }

    let raw_name = read_tar_string(tar_data, offset, 100)
    let typeflag = tar_data[offset + 156]
    let size = read_tar_octal(tar_data, offset + 124, 12)
    if size < 0 || offset + 512 + size > tar_data.length() {
      return Err(@zstd_core.message_error("Invalid tar entry size"))
    }

    let is_dir = typeflag == b'5'
    let is_file = typeflag == b'0' || typeflag == 0
    if !is_dir && !is_file {
      return Err(@zstd_core.message_error("Unsupported tar entry type"))
    }

    let entry_path = if raw_name.has_suffix("/") {
      raw_name.trim_end(chars="/").to_string()
    } else {
      raw_name
    }
    if !is_safe_archive_path(entry_path) {
      return Err(@zstd_core.message_error("Unsafe tar path: " + entry_path))
    }

    let target_path = join_fs_path(output_dir, entry_path)
    if is_dir {
      if @fs.path_exists(target_path) {
        if !@fs.is_dir(target_path) {
          return Err(@zstd_core.message_error("Tar directory target is not a directory: " + target_path))
        }
      } else {
        @fs.create_dir(target_path)
      }
      entries.push(PathArchiveEntry::{ path: entry_path, is_dir: true, data: Bytes::new(0) })
    } else {
      let file_data: Array[Byte] = []
      for i = 0; i < size; i = i + 1 {
        file_data.push(tar_data[offset + 512 + i])
      }
      let bytes = Bytes::from_array(file_data)
      @fs.write_bytes_to_file(target_path, bytes)
      entries.push(PathArchiveEntry::{ path: entry_path, is_dir: false, data: bytes })
    }

    offset = offset + 512 + size + ((512 - (size % 512)) % 512)
  }

  Err(@zstd_core.message_error("Tar archive is missing end marker"))
}

fn collect_path_archive_entries(
  fs_path: String,
  archive_path: String,
  entries: Array[PathArchiveBuildEntry]
) -> Result[Unit, @zstd_core.ZSTDError] raise {
  if @fs.is_dir(fs_path) {
    entries.push(PathArchiveBuildEntry::{ path: archive_path, is_dir: true, data: Bytes::new(0) })
    let children = @fs.read_dir(fs_path)
    for i = 0; i < children.length(); i = i + 1 {
      let child_name = children[i]
      if child_name != "." && child_name != ".." {
        let child_fs_path = join_fs_path(fs_path, child_name)
        let child_archive_path = join_archive_path(archive_path, child_name)
        match collect_path_archive_entries(child_fs_path, child_archive_path, entries) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
    }
    Ok(())
  } else if @fs.is_file(fs_path) {
    let content = @fs.read_file_to_bytes(fs_path)
    entries.push(PathArchiveBuildEntry::{ path: archive_path, is_dir: false, data: content })
    Ok(())
  } else {
    Err(@zstd_core.message_error("Path is neither file nor directory: " + fs_path))
  }
}

fn encode_path_archive(entries: Array[PathArchiveBuildEntry]) -> Bytes {
  let output: Array[Byte] = []

  // Magic: "MBZAR1\0\1"
  output.push(b'M')
  output.push(b'B')
  output.push(b'Z')
  output.push(b'A')
  output.push(b'R')
  output.push(b'1')
  output.push((0).to_byte())
  output.push((1).to_byte())
  write_u32_archive(output, entries.length())

  for i = 0; i < entries.length(); i = i + 1 {
    let entry = entries[i]
    let path_bytes = @utf8.encode(entry.path)
    output.push((if entry.is_dir { 1 } else { 0 }).to_byte())
    write_u32_archive(output, path_bytes.length())
    write_u32_archive(output, if entry.is_dir { 0 } else { entry.data.length() })
    for j = 0; j < path_bytes.length(); j = j + 1 {
      output.push(path_bytes[j])
    }
    if !entry.is_dir {
      for j = 0; j < entry.data.length(); j = j + 1 {
        output.push(entry.data[j])
      }
    }
  }

  Bytes::from_array(output)
}

/// Pack a file or directory path into this project's lightweight archive bytes.
///
/// Directories are walked recursively. Paths inside the archive are normalized
/// to `/` separators and rooted at the input path's basename.
pub fn pack_path(path: String) -> Result[Bytes, @zstd_core.ZSTDError] {
  if !@fs.path_exists(path) {
    return Err(@zstd_core.message_error("Path does not exist: " + path))
  }

  try {
    let entries: Array[PathArchiveBuildEntry] = []
    match collect_path_archive_entries(path, path_basename(path), entries) {
      Ok(_) => Ok(encode_path_archive(entries))
      Err(e) => Err(e)
    }
  } catch {
    _ => Err(@zstd_core.message_error("Failed to pack path: " + path))
  }
}

/// Pack a file or directory path, then compress the archive bytes as ZSTD data.
pub fn compress_path(path: String) -> Result[Bytes, @zstd_core.ZSTDError] {
  match pack_path(path) {
    Ok(archive) => compress(archive)
    Err(e) => Err(e)
  }
}

/// Pack and compress a file or directory path, then write the ZSTD bytes to a file.
pub fn compress_path_to_file(path: String, output_path: String) -> Result[Unit, @zstd_core.ZSTDError] {
  match compress_path(path) {
    Ok(compressed) => {
      try {
        @fs.write_bytes_to_file(output_path, compressed)
        Ok(())
      } catch {
        _ => Err(@zstd_core.message_error("Failed to write compressed path output: " + output_path))
      }
    }
    Err(e) => Err(e)
  }
}

/// Pack a file or directory path into a POSIX ustar archive byte stream.
///
/// This is the compatibility path for external tools: compress the returned
/// bytes with ZSTD and name the output `.tar.zst`.
pub fn pack_path_as_tar(path: String) -> Result[Bytes, @zstd_core.ZSTDError] {
  if !@fs.path_exists(path) {
    return Err(@zstd_core.message_error("Path does not exist: " + path))
  }

  try {
    let entries: Array[PathArchiveBuildEntry] = []
    match collect_path_archive_entries(path, path_basename(path), entries) {
      Ok(_) => encode_tar_archive(entries)
      Err(e) => Err(e)
    }
  } catch {
    _ => Err(@zstd_core.message_error("Failed to pack tar path: " + path))
  }
}

/// Pack a file or directory as POSIX ustar, compress it, and write `.tar.zst`.
pub fn compress_path_to_tar_zst_file(path: String, output_path: String) -> Result[Unit, @zstd_core.ZSTDError] {
  match pack_path_as_tar(path) {
    Ok(tar_bytes) => {
      match compress(tar_bytes) {
        Ok(compressed) => {
          try {
            @fs.write_bytes_to_file(output_path, compressed)
            Ok(())
          } catch {
            _ => Err(@zstd_core.message_error("Failed to write tar.zst output: " + output_path))
          }
        }
        Err(e) => Err(e)
      }
    }
    Err(e) => Err(e)
  }
}

/// Read a `.tar.zst` file, decompress it, and extract the tar entries.
pub fn decompress_tar_zst_file_to_dir(
  compressed_path: String,
  output_dir: String
) -> Result[Array[PathArchiveEntry], @zstd_core.ZSTDError] {
  try {
    let compressed = @fs.read_file_to_bytes(compressed_path)
    let tar_data = match decompress(compressed) {
      Ok(bytes) => bytes
      Err(e) => return Err(e)
    }
    decode_tar_to_dir(tar_data, output_dir)
  } catch {
    _ => Err(@zstd_core.message_error("Failed to extract tar.zst: " + compressed_path))
  }
}

fn validate_path_archive_magic(data: Bytes) -> Bool {
  data.length() >= 12 &&
  data[0] == b'M' &&
  data[1] == b'B' &&
  data[2] == b'Z' &&
  data[3] == b'A' &&
  data[4] == b'R' &&
  data[5] == b'1' &&
  data[6] == 0x00 &&
  data[7] == 0x01
}

fn decode_path_archive(data: Bytes) -> Result[Array[PathArchiveEntry], @zstd_core.ZSTDError] {
  if !validate_path_archive_magic(data) {
    return Err(@zstd_core.message_error("Invalid path archive magic"))
  }

  let entry_count = read_u32_archive(data, 8)
  if entry_count < 0 {
    return Err(@zstd_core.message_error("Invalid path archive entry count"))
  }

  let entries: Array[PathArchiveEntry] = []
  let mut offset = 12
  for _i = 0; _i < entry_count; _i = _i + 1 {
    if offset + 9 > data.length() {
      return Err(@zstd_core.message_error("Truncated path archive entry header"))
    }

    let entry_type = data[offset].to_int()
    let is_dir = entry_type == 1
    if entry_type != 0 && entry_type != 1 {
      return Err(@zstd_core.message_error("Invalid path archive entry type"))
    }
    let path_len = read_u32_archive(data, offset + 1)
    let data_len = read_u32_archive(data, offset + 5)
    if path_len < 0 || data_len < 0 {
      return Err(@zstd_core.message_error("Invalid path archive entry size"))
    }
    offset = offset + 9

    if offset + path_len + data_len > data.length() {
      return Err(@zstd_core.message_error("Truncated path archive entry data"))
    }

    let path_bytes: Array[Byte] = []
    for j = 0; j < path_len; j = j + 1 {
      path_bytes.push(data[offset + j])
    }
    let entry_path = @utf8.decode_lossy(Bytes::from_array(path_bytes))
    offset = offset + path_len

    let entry_data: Array[Byte] = []
    if !is_dir {
      for j = 0; j < data_len; j = j + 1 {
        entry_data.push(data[offset + j])
      }
    } else if data_len != 0 {
      return Err(@zstd_core.message_error("Directory archive entry must not contain data"))
    }
    offset = offset + data_len

    entries.push(PathArchiveEntry::{
      path: entry_path,
      is_dir: is_dir,
      data: Bytes::from_array(entry_data),
    })
  }

  if offset != data.length() {
    return Err(@zstd_core.message_error("Trailing bytes after path archive"))
  }

  Ok(entries)
}

/// Decompress ZSTD bytes produced by `compress_path` and decode archive entries.
pub fn decompress_path_archive(compressed: Bytes) -> Result[Array[PathArchiveEntry], @zstd_core.ZSTDError] {
  match decompress(compressed) {
    Ok(archive) => decode_path_archive(archive)
    Err(e) => Err(e)
  }
}

/// Read a path archive `.zst` file, decode it, and write its entries under `output_dir`.
///
/// The extracted tree preserves archive paths under `output_dir`. Archive paths
/// are validated to reject absolute paths, drive prefixes, and `..` segments.
pub fn decompress_path_archive_file_to_dir(
  compressed_path: String,
  output_dir: String
) -> Result[Array[PathArchiveEntry], @zstd_core.ZSTDError] {
  try {
    if @fs.path_exists(output_dir) {
      if !@fs.is_dir(output_dir) {
        return Err(@zstd_core.message_error("Output path is not a directory: " + output_dir))
      }
    } else {
      @fs.create_dir(output_dir)
    }

    let compressed = @fs.read_file_to_bytes(compressed_path)
    let entries = match decompress_path_archive(compressed) {
      Ok(items) => items
      Err(e) => return Err(e)
    }

    for i = 0; i < entries.length(); i = i + 1 {
      let entry = entries[i]
      if !is_safe_archive_path(entry.path) {
        return Err(@zstd_core.message_error("Unsafe archive path: " + entry.path))
      }

      let target_path = join_fs_path(output_dir, entry.path)
      if entry.is_dir {
        if @fs.path_exists(target_path) {
          if !@fs.is_dir(target_path) {
            return Err(@zstd_core.message_error("Archive directory target is not a directory: " + target_path))
          }
        } else {
          @fs.create_dir(target_path)
        }
      } else {
        @fs.write_bytes_to_file(target_path, entry.data)
      }
    }

    Ok(entries)
  } catch {
    _ => Err(@zstd_core.message_error("Failed to extract path archive: " + compressed_path))
  }
}

/// Decompress a ZSTD-compressed frame.
///
/// Supports concatenated frames and returns structured errors for invalid input.
///
/// # Example
///
/// ```moonbit no-check
/// match @zstd.decompress(compressed) {
///   Ok(original) => println("Decoded \{original.length()} bytes")
///   Err(e) => println("Decompression failed: \{e}")
/// }
/// ```
pub fn decompress(data: Bytes) -> Result[Bytes, @zstd_core.ZSTDError] {
  if data.length() < 4 {
    return Err(@zstd_core.parse_error("Data too short: need at least 4 bytes, got " + data.length().to_string()))
  }

  let magic = (data[3].to_int() << 24) | (data[2].to_int() << 16) | (data[1].to_int() << 8) | data[0].to_int()
  if magic != @zstd_core.ZSTD_MAGIC_NUMBER_INT {
    return Err(@zstd_core.invalid_magic_number_error())
  }

  let max_output_size = 134217728 // 128MB global limit
  @zstd_decoder.decompress_with_limit(data, max_output_size)
}

/// Analyze the structure of a ZSTD compressed file.
///
/// Returns frame header info, block type, block size, and validation status
/// without performing full decompression.
pub fn analyze_file(data: Bytes) -> ZSTDFileAnalysis {
  analyze_file_detailed(data)
}

/// 详细的文件分析，包含错误检测
fn analyze_file_detailed(data: Bytes) -> ZSTDFileAnalysis {
  if data.length() < 4 {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "文件太小，无法包含 ZSTD 魔数",
      magic_number: 0U,
      single_segment: false,
      content_checksum: false,
      window_size: 0U,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "unknown",
      first_block_size: 0,
      last_block: false
    }
  }
  
  let magic = (data[3].to_int() << 24) | (data[2].to_int() << 16) | (data[1].to_int() << 8) | data[0].to_int()
  
  if magic != @zstd_core.ZSTD_MAGIC_NUMBER_INT {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "无效的 ZSTD 魔数",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: false,
      content_checksum: false,
      window_size: 0U,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "unknown",
      first_block_size: 0,
      last_block: false
    }
  }
  
  if data.length() < 6 {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "帧头不完整",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: false,
      content_checksum: false,
      window_size: 0U,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "unknown",
      first_block_size: 0,
      last_block: false
    }
  }
  
  let frame_desc = data[4].to_int()
  let single_segment = (frame_desc & 0x20) != 0
  let content_checksum = (frame_desc & 0x04) != 0
  let dict_id_flag = (frame_desc & 0x03)
  let fcs_field_size = (frame_desc >> 6) & 3  // Frame Content Size field size (位6-7)
  
  let reserved_bits = (frame_desc & 0x08)
  if reserved_bits != 0 {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "帧描述符中的保留位非零",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: single_segment,
      content_checksum: content_checksum,
      window_size: 0U,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "invalid",
      first_block_size: 0,
      last_block: false
    }
  }
  
  let mut offset = 5
  let mut window_size = 0U
  if !single_segment {
    if data.length() <= offset {
      return ZSTDFileAnalysis::{
        is_valid: false,
        error_message: "缺少窗口描述符",
        magic_number: magic.reinterpret_as_uint(),
        single_segment: single_segment,
        content_checksum: content_checksum,
        window_size: 0U,
        total_blocks: 0,
        file_size: data.length(),
        first_block_type: "unknown",
        first_block_size: 0,
        last_block: false
      }
    }
    let window_desc = data[offset].to_int()
    let wd_exp = (window_desc >> 3) & 0x1F
    let wd_mant = window_desc & 0x07
    let window_base = 1 << (wd_exp + 10)
    window_size = (window_base + (window_base / 8) * wd_mant).reinterpret_as_uint()
    offset = offset + 1
  }
  
  // 跳过字典 ID（如果存在）
  if dict_id_flag > 0 {
    let dict_id_bytes = match dict_id_flag {
      1 => 1
      2 => 2
      3 => 4
      _ => 0
    }
    offset = offset + dict_id_bytes
  }
  
  // Skip Frame_Content_Size when present.
  // FCS is present when: single_segment=1 (any fcs_flag), OR fcs_flag != 0.
  // When single_segment=1 and fcs_flag=0, the field is 1 byte.
  let has_fcs = single_segment || fcs_field_size != 0
  if has_fcs {
    let content_size_bytes = if single_segment && fcs_field_size == 0 {
      1
    } else {
      match fcs_field_size {
        1 => 2
        2 => 4
        3 => 8
        _ => 0
      }
    }
    offset = offset + content_size_bytes
  }
  
  if offset + 3 > data.length() {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "文件截断，缺少块头",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: single_segment,
      content_checksum: content_checksum,
      window_size: window_size,
      total_blocks: 0,
      file_size: data.length(),
      first_block_type: "missing",
      first_block_size: 0,
      last_block: false
    }
  }
  
  let block_header = data[offset].to_int() | 
                    (data[offset + 1].to_int() << 8) | 
                    (data[offset + 2].to_int() << 16)
  
  let last_block = (block_header & 0x01) != 0
  let block_type = (block_header >> 1) & 0x03
  let block_size = block_header >> 3
  
  if block_size > @zstd_core.ZSTD_MAX_BLOCK_SIZE {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: "块大小超过最大限制",
      magic_number: magic.reinterpret_as_uint(),
      single_segment: single_segment,
      content_checksum: content_checksum,
      window_size: window_size,
      total_blocks: 1,
      file_size: data.length(),
      first_block_type: "oversized",
      first_block_size: block_size,
      last_block: last_block
    }
  }
  
  // 验证块数据完整性（考虑不同块类型的实际大小）
  if block_size == @zstd_core.ZSTD_MAX_BLOCK_SIZE && block_type != 1 {
    // RLE 块即使 block_size 是 128K，实际数据也只有 1 字节
    // 只对非 RLE 块进行 128K 数据完整性检查
    if data.length() < offset + 3 + block_size {
      return ZSTDFileAnalysis::{
        is_valid: false,
        error_message: "128K块数据不完整",
        magic_number: magic.reinterpret_as_uint(),
        single_segment: single_segment,
        content_checksum: content_checksum,
        window_size: window_size,
        total_blocks: 1,
        file_size: data.length(),
        first_block_type: "incomplete_128k",
        first_block_size: block_size,
        last_block: last_block
      }
    }
  }
  
  let error_patterns = detect_error_patterns(data, offset)
  if error_patterns.length() > 0 {
    return ZSTDFileAnalysis::{
      is_valid: false,
      error_message: error_patterns,
      magic_number: magic.reinterpret_as_uint(),
      single_segment: single_segment,
      content_checksum: content_checksum,
      window_size: window_size,
      total_blocks: 1,
      file_size: data.length(),
      first_block_type: "error",
      first_block_size: block_size,
      last_block: last_block
    }
  }
  
  let first_block_type_str = match block_type {
    0 => "raw"
    1 => "rle"
    2 => "compressed"
    3 => "reserved"
    _ => "unknown"
  }
  
  ZSTDFileAnalysis::{
    is_valid: true,
    error_message: "",
    magic_number: magic.reinterpret_as_uint(),
    single_segment: single_segment,
    content_checksum: content_checksum,
    window_size: window_size,
    total_blocks: 1,
    file_size: data.length(),
    first_block_type: first_block_type_str,
    first_block_size: block_size,
    last_block: last_block
  }
}

/// 基于原生ZSTD规范的错误检测
fn detect_error_patterns(data: Bytes, block_offset: Int) -> String {
  let block_header = data[block_offset].to_int() | 
                    (data[block_offset + 1].to_int() << 8) | 
                    (data[block_offset + 2].to_int() << 16)
  
  let block_type = (block_header >> 1) & 0x03
  let block_size = block_header >> 3
  
  if block_type == 3 {
    return "检测到保留块类型错误"
  }
  
  if block_type == 2 && block_size < 2 {
    return "检测到压缩块大小过小"
  }
  
  if block_size == 0 {
    return ""
  }
  
  if block_size == @zstd_core.ZSTD_MAX_BLOCK_SIZE {
    return ""
  }
  
  if block_type == 2 && block_size > 0 {
    let block_start = block_offset + 3
    let block_end = block_offset + 3 + block_size
    
    // 对于非常小的块（<=3字节），可能是合法的空块或最小块
    // 不进行严格的结构检查，避免误报
    if block_size <= 3 {
      return ""
    }
    
    if block_start + 1 < data.length() {
      let mut seq_count = data[block_start].to_int()
      let mut seq_offset = block_start + 1
      
      if seq_count > 0x7F {
        if seq_count == 0xFF {
          if seq_offset + 2 < data.length() {
            seq_count = (data[seq_offset].to_int() | (data[seq_offset + 1].to_int() << 8)) + 0x7F00
            seq_offset = seq_offset + 2
          } else {
            return "检测到序列计数不完整"
          }
        } else {
          if seq_offset < data.length() {
            seq_count = ((seq_count - 0x80) << 8) + data[seq_offset].to_int()
            seq_offset = seq_offset + 1
          } else {
            return "检测到序列计数不完整"
          }
        }
      }
      
      if seq_count == 0 {
        let remaining_in_block = block_end - seq_offset
        
        // 对于小块，remaining数据可能是字面量头，不一定是多余数据
        // 只有当remaining数据明显过多时才报错
        if remaining_in_block > 5 {
          return "检测到多余的零序列数据"
        }
      } else {
        if seq_count > 1024 {
          return "检测到序列计数过大"
        }
        
        if seq_offset < data.length() {
          let fse_desc = data[seq_offset].to_int()
          let reserved_bits = fse_desc & 0x03
          
          if reserved_bits != 0 {
            return "检测到FSE表描述符保留位错误"
          }
        }
      }
    }
  }
  
  if block_type == 2 && block_size > 0 {
    let block_start = block_offset + 3
    
    if block_start + 1 < data.length() {
      let literals_header = data[block_start].to_int()
      let literals_block_type = literals_header & 0x03
      
      if literals_block_type == 2 {
        if block_size < 5 {
          return "检测到压缩字面量块大小不足"
        }
        
        if block_start + 4 < data.length() {
          let huffman_header = data[block_start + 1].to_int()
          let huffman_size = huffman_header & 0xFF
          
          if huffman_size < 2 && block_size > 10 {
            return "Huffman状态截断"
          }
        }
      }
    }
  }
  ""
}

/// Analyze data integrity metrics (density, structure consistency, entropy).
pub fn analyze_data_integrity(data: Bytes) -> DataIntegrityAnalysis {
  let file_size = data.length()
  if file_size == 0 {
    return DataIntegrityAnalysis::{
      truncation_indicators: 0,
      data_density: 0.0,
      structure_consistency: 0.0,
      entropy_level: 0.0
    }
  }

  let mut truncation_indicators = 0
  let mut non_zero_bytes = 0
  let byte_counts: Array[Int] = Array::make(256, 0)

  for i = 0; i < file_size; i = i + 1 {
    let byte_val = data[i].to_int()
    byte_counts[byte_val] = byte_counts[byte_val] + 1
    if byte_val != 0 {
      non_zero_bytes = non_zero_bytes + 1
    }
  }

  if file_size >= 8 {
    let tail_start = file_size - 8
    let mut tail_zeros = 0
    for i = tail_start; i < file_size; i = i + 1 {
      if data[i].to_int() == 0 {
        tail_zeros = tail_zeros + 1
      }
    }
    if tail_zeros > 6 {
      truncation_indicators = truncation_indicators + 1
    }
  }

  let mut structure_consistency = 0.0
  if is_zstd_format(data) {
    let analysis = analyze_file_detailed(data)
    let decompressed = decompress(data)
    let decode_success = is_integrity_decode_success(analysis, decompressed)

    if !decode_success {
      truncation_indicators = truncation_indicators + 1
    }
    if !analysis.is_valid && is_likely_truncation_error(analysis.error_message) {
      truncation_indicators = truncation_indicators + 1
    }
    if analysis.first_block_type == "missing" || analysis.first_block_type == "incomplete_128k" {
      truncation_indicators = truncation_indicators + 1
    }

    structure_consistency = calculate_integrity_structure_consistency(analysis, decode_success)
  }

  let data_density = non_zero_bytes.to_double() / file_size.to_double()
  let entropy_level = calculate_integrity_entropy(byte_counts, file_size)

  DataIntegrityAnalysis::{
    truncation_indicators: truncation_indicators,
    data_density: data_density,
    structure_consistency: structure_consistency,
    entropy_level: entropy_level
  }
}

fn calculate_integrity_structure_consistency(
  analysis: ZSTDFileAnalysis,
  decode_success: Bool
) -> Double {
  // 可解码则给满分，后续如有其他指标再做调整
  if decode_success {
    return 1.0
  }

  // 结构一致性是启发式评分
  let mut score = 0.35

  // 能解析出帧级信息，则加分
  if analysis.first_block_type != "unknown" ||
     analysis.window_size > 0U ||
     analysis.single_segment ||
     analysis.content_checksum {
    score = score + 0.10
  }

  // 当前轻量分析通过，说明帧头和首块结构至少自洽。
  if analysis.is_valid {
    score = score + 0.20
  }

  // 下面这些扣分项区分“疑似截断”和“明确结构错误”。
  if is_likely_truncation_error(analysis.error_message) {
    score = score - 0.15
  }

  if analysis.first_block_type == "missing" || analysis.first_block_type == "incomplete_128k" {
    score = score - 0.10
  } else if analysis.first_block_type == "oversized" {
    score = score - 0.25
  } else if analysis.first_block_type == "invalid" || analysis.first_block_type == "error" {
    score = score - 0.30
  }

  clamp_integrity_score(score)
}

fn is_integrity_decode_success(
  analysis: ZSTDFileAnalysis,
  decompressed: Result[Bytes, @zstd_core.ZSTDError]
) -> Bool {
  match decompressed {
    Ok(bytes) => bytes.length() > 0 ||
      (analysis.is_valid && analysis.last_block && analysis.first_block_size == 0)
    Err(_) => false
  }
}

fn clamp_integrity_score(score: Double) -> Double {
  if score < 0.0 {
    0.0
  } else if score > 1.0 {
    1.0
  } else {
    score
  }
}

fn calculate_integrity_entropy(byte_counts: Array[Int], total_bytes: Int) -> Double {
  if total_bytes == 0 {
    return 0.0
  }

  let mut unique_bytes = 0
  let mut max_count = 0
  for i = 0; i < 256; i = i + 1 {
    if byte_counts[i] > 0 {
      unique_bytes = unique_bytes + 1
      if byte_counts[i] > max_count {
        max_count = byte_counts[i]
      }
    }
  }

  let diversity = unique_bytes.to_double() / 256.0
  let uniformity = 1.0 - (max_count.to_double() / total_bytes.to_double())
  (diversity + uniformity) / 2.0
}

fn is_likely_truncation_error(error_message: String) -> Bool {
  error_message.contains("截断") ||
  error_message.contains("缺少") ||
  error_message.contains("不完整")
}

/// Check whether the data starts with a valid ZSTD magic number (0xFD2FB528).
pub fn is_zstd_format(data: Bytes) -> Bool {
  if data.length() < 4 {
    return false
  }
  
  let magic = (data[3].to_int() << 24) | (data[2].to_int() << 16) | (data[1].to_int() << 8) | data[0].to_int()
  magic == @zstd_core.ZSTD_MAGIC_NUMBER_INT
}

/// Estimate compressed output size for a given compression level.
///
/// This is a rough heuristic, not an exact prediction.
pub fn estimate_compressed_size(data: Bytes, level: CompressionLevel) -> Int {
  let overhead = 9
  
  match level {
    CompressionLevel::Fast => data.length() + overhead
    CompressionLevel::Default => (data.length() * 80 / 100) + overhead
    CompressionLevel::Better => (data.length() * 60 / 100) + overhead
    CompressionLevel::Best => (data.length() * 40 / 100) + overhead
  }
}
/// 运行所有基础测试
pub fn run_all_basic_tests() -> Bool {
  let tests = [
    ("Basic compression", test_basic_compression),
    ("Format detection", test_format_detection),
    ("File analysis", test_file_analysis),
    ("Compression levels", test_compression_levels),
    ("Empty data", test_empty_data),
    ("Data integrity", test_data_integrity)
  ]
  
  let mut passed = 0
  for i = 0; i < tests.length(); i = i + 1 {
    let (name, test_fn) = tests[i]
    let result = test_fn()
    ignore(name)  // 忽略未使用的变量
    if result {
      passed = passed + 1
    }
  }
  
  passed == tests.length()
}

/// 运行所有兼容性测试
pub fn run_all_compatibility_tests() -> Bool {
  let tests = [
    ("Magic number compliance", test_magic_number_compliance),
    ("Frame header compliance", test_frame_header_compliance),
    ("Error handling", test_error_handling),
    ("Large data handling", test_large_data_handling),
    ("RLE optimization", test_rle_optimization)
  ]
  
  let mut passed = 0
  for i = 0; i < tests.length(); i = i + 1 {
    let (name, test_fn) = tests[i]
    let result = test_fn()
    ignore(name)  // 忽略未使用的变量
    if result {
      passed = passed + 1
    }
  }
  
  passed == tests.length()
}

/// 测试基础压缩和解压缩
fn test_basic_compression() -> Bool {
  let test_data = @utf8.encode("Hello, MoonBit ZSTD!")

  // Test compression
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  if compressed.length() == 0 {
    return false
  }

  // Test decompression
  let decompressed = match decompress(compressed) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  if decompressed.length() != test_data.length() { return false }

  // Verify data integrity
  for i = 0; i < test_data.length(); i = i + 1 {
    if test_data[i] != decompressed[i] {
      return false
    }
  }

  true
}

/// 测试ZSTD格式检测
fn test_format_detection() -> Bool {
  let test_data = @utf8.encode("Hello, World!")
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }

  // Should detect as valid ZSTD format
  is_zstd_format(compressed)
}

/// 测试文件分析
fn test_file_analysis() -> Bool {
  let test_data = @utf8.encode("Test data for analysis")
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let analysis = analyze_file(compressed)

  // Should be valid
  analysis.is_valid
}

/// 测试不同压缩级别
fn test_compression_levels() -> Bool {
  let test_data = @utf8.encode("Test data for different compression levels")

  // Test all compression levels
  let fast_compressed = match compress_with_level(test_data, CompressionLevel::Fast) {
    Ok(c) => c
    Err(_) => return false
  }
  let default_compressed = match compress_with_level(test_data, CompressionLevel::Default) {
    Ok(c) => c
    Err(_) => return false
  }
  let better_compressed = match compress_with_level(test_data, CompressionLevel::Better) {
    Ok(c) => c
    Err(_) => return false
  }
  let best_compressed = match compress_with_level(test_data, CompressionLevel::Best) {
    Ok(c) => c
    Err(_) => return false
  }

  // All should be valid
  fast_compressed.length() > 0 &&
  default_compressed.length() > 0 &&
  better_compressed.length() > 0 &&
  best_compressed.length() > 0
}

/// 测试空数据处理
fn test_empty_data() -> Bool {
  let empty_data = Bytes::from_array([])
  let compressed = match compress(empty_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let decompressed = match decompress(compressed) {
    Ok(bytes) => bytes
    Err(_) => return false
  }

  // Should handle empty data gracefully
  decompressed.length() == 0
}

/// 测试数据完整性分析
fn test_data_integrity() -> Bool {
  let test_data = @utf8.encode("Data integrity test " + "ABCDABCDABCDABCD")
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }

  let truncated_arr: Array[Byte] = []
  for i = 0; i < compressed.length() - 2; i = i + 1 {
    truncated_arr.push(compressed[i])
  }
  let truncated = Bytes::from_array(truncated_arr)

  let integrity = analyze_data_integrity(compressed)
  let truncated_integrity = analyze_data_integrity(truncated)

  integrity.structure_consistency > truncated_integrity.structure_consistency &&
  truncated_integrity.truncation_indicators >= integrity.truncation_indicators &&
  integrity.data_density >= 0.0 && integrity.data_density <= 1.0 &&
  integrity.entropy_level >= 0.0 && integrity.entropy_level <= 1.0
}

/// 测试魔数兼容性
fn test_magic_number_compliance() -> Bool {
  let test_data = @utf8.encode("Magic number test")
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }

  if compressed.length() < 4 {
    return false
  }

  // Check magic number (little-endian)
  let magic = (compressed[3].to_int() << 24) |
              (compressed[2].to_int() << 16) |
              (compressed[1].to_int() << 8) |
              compressed[0].to_int()

  magic == @zstd_core.ZSTD_MAGIC_NUMBER_INT
}

/// 测试帧头格式兼容性
fn test_frame_header_compliance() -> Bool {
  let test_data = @utf8.encode("Frame header test")
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let analysis = analyze_file(compressed)

  // Should have valid frame header
  analysis.is_valid && analysis.magic_number == @zstd_core.ZSTD_MAGIC_NUMBER
}

/// 测试错误处理
fn test_error_handling() -> Bool {
  // Test with invalid data
  let invalid_data = Bytes::from_array([0x00, 0x01, 0x02, 0x03])
  let analysis = analyze_file(invalid_data)
  
  // Should detect invalid data
  !analysis.is_valid
}

/// 测试大数据处理
fn test_large_data_handling() -> Bool {
  // Create larger test data
  let large_data: Array[Byte] = []
  for i = 0; i < 1000; i = i + 1 {
    large_data.push((i % 256).to_byte())
  }
  
  let test_data = Bytes::from_array(large_data)
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let decompressed = match decompress(compressed) {
    Ok(bytes) => bytes
    Err(_) => return false
  }

  // Should handle large data correctly
  decompressed.length() == test_data.length()
}

/// 测试重复数据(RLE优化)
fn test_rle_optimization() -> Bool {
  // Create repeated data
  let repeated_data: Array[Byte] = []
  for _i = 0; _i < 100; _i = _i + 1 {
    repeated_data.push(0x41)  // 'A'
  }

  let test_data = Bytes::from_array(repeated_data)
  let compressed = match compress(test_data) {
    Ok(c) => c
    Err(_) => return false
  }
  let decompressed = match decompress(compressed) {
    Ok(bytes) => bytes
    Err(_) => return false
  }

  // Should compress and decompress repeated data correctly
  decompressed.length() == test_data.length()
}

// ============================================================================
// Sliding Window Decoder API
// ============================================================================

/// Create a sliding window decoder with the given window size.
///
/// The decoder maintains state for streaming decompression across
/// multiple calls to `decompress_with_sliding_window`.
pub fn create_sliding_window_decoder(window_size: Int) -> SlidingWindowDecoder {
  let context = @zstd_decoder.create_decoder_context(window_size)
  SlidingWindowDecoder::{
    context: context,
    window_size: window_size
  }
}

/// Decompress a ZSTD frame using a sliding window decoder.
///
/// The decoder context is updated in place, allowing match references
/// to span across multiple decompression calls.
pub fn decompress_with_sliding_window(
  decoder: SlidingWindowDecoder,
  data: Bytes
) -> Result[Bytes, @zstd_core.ZSTDError] {
  let frame_result = @zstd_decoder.parse_frame_header(data)
  match frame_result {
    Ok((_, header_size)) => {
      let current_offset = header_size
      let output: Array[Byte] = []

      let block_result = @zstd_decoder.decompress_block_with_context(decoder.context, data, current_offset)
      match block_result {
        Ok((block_data, _, _)) => {
          for i = 0; i < block_data.length(); i = i + 1 {
            output.push(block_data[i])
          }
          Ok(Bytes::from_array(output))
        }
        Err(e) => Err(@zstd_core.message_error("Block decompression failed: " + e))
      }
    }
    Err(e) => Err(e)
  }
}

/// Reset the sliding window decoder, clearing all internal state.
pub fn reset_sliding_window_decoder(decoder: SlidingWindowDecoder) -> Unit {
  // 重新创建上下文来重置状态
  let new_context = @zstd_decoder.create_decoder_context(decoder.window_size)
  decoder.context = new_context
}

