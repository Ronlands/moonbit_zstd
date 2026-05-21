/// Basic ZSTD demonstrations
/// 基础功能演示

pub fn demo_basic_compression() -> Unit {
  println("\n1. 基本压缩和解压缩测试")
  println("   " + @zstd_test.repeat_string("-", 30))
  
  let test_data = @utf8.encode("Hello, ZSTD!")
  let original_size = test_data.length()
  
  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(e) => { println("压缩失败: \{e}"); return }
  }
  let compressed_size = compressed.length()
  let ratio = original_size.to_double() / compressed_size.to_double()
  
  let decompressed = match @zstd.decompress(compressed) {
    Ok(bytes) => bytes
    Err(e) => { println("解压失败: \{e}"); return }
  }
  let is_correct = test_data == decompressed
  let decompressed_size = decompressed.length()
  let correctness = if is_correct { "正确" } else { "错误" }
  
  println("   原始数据: \{original_size} 字节")
  println("   压缩后: \{compressed_size} 字节")
  println("   压缩比: \{ratio}x")
  println("   解压后: \{decompressed_size} 字节")
  println("   数据完整性: \{correctness}")
}

pub fn demo_file_analysis() -> Unit {
  println("\n2. ZSTD文件分析")
  println("   " + @zstd_test.repeat_string("-", 30))
  
  let test_data = @utf8.encode("Analysis test data")
  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(e) => { println("压缩失败: \{e}"); return }
  }
  let analysis = @zstd.analyze_file(compressed)
  let magic_str = format_magic_number(compressed)
  let file_size = compressed.length()
  
  println("   文件结构分析:")
  println("   - 文件有效性: \{analysis.is_valid}")
  println("   - 魔数: 0x\{magic_str}")
  println("   - 文件大小: \{file_size} 字节")
  println("   - 总块数: \{analysis.total_blocks}")
  println("   - 第一块类型: \{analysis.first_block_type}")
  println("   - 单段模式: \{analysis.single_segment}")
  println("   - 内容校验: \{analysis.content_checksum}")
}

pub fn demo_data_integrity() -> Unit {
  println("\n3. 数据完整性分析")
  println("   " + @zstd_test.repeat_string("-", 30))

  let valid_source = @utf8.encode("Integrity analysis sample " + @zstd_test.repeat_string("ABCD", 32))
  let valid_frame = match @zstd.compress(valid_source) {
    Ok(c) => c
    Err(e) => { println("压缩失败: \{e}"); return }
  }
  let truncated_frame = drop_last_bytes(valid_frame, 2)
  let non_zstd_data = create_test_data(64)

  let samples = [
    ("有效ZSTD帧", valid_frame),
    ("截断ZSTD帧", truncated_frame),
    ("非ZSTD数据", non_zstd_data)
  ]

  for i = 0; i < samples.length(); i = i + 1 {
    let (name, sample) = samples[i]
    let integrity = @zstd.analyze_data_integrity(sample)

    println("   样本: \{name} (\{sample.length()} 字节)")
    println("     ZSTD格式: " + (if @zstd.is_zstd_format(sample) { "是" } else { "否" }))
    println("     数据密度: \{integrity.data_density}")
    println("     结构一致性: \{integrity.structure_consistency}")
    println("     熵级别: \{integrity.entropy_level}")
    println("     截断指标: \{integrity.truncation_indicators}")
  }
}

pub fn demo_format_detection() -> Unit {
  println("\n4. 格式检测测试")
  println("   " + @zstd_test.repeat_string("-", 30))
  
  let test_data = @utf8.encode("Format test")
  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(e) => { println("压缩失败: \{e}"); return }
  }
  let non_zstd = @utf8.encode("Not ZSTD data")
  let empty = Bytes::new(0)
  
  let is_valid = @zstd.is_zstd_format(compressed)
  let is_invalid = @zstd.is_zstd_format(non_zstd)
  let is_empty = @zstd.is_zstd_format(empty)
  
  let valid_result = if is_valid { "正确识别" } else { "识别失败" }
  let invalid_result = if !is_invalid { "正确拒绝" } else { "错误接受" }
  let empty_result = if !is_empty { "正确拒绝" } else { "错误接受" }
  
  println("   有效ZSTD文件检测: \{valid_result}")
  println("   非ZSTD数据检测: \{invalid_result}")
  println("   空数据检测: \{empty_result}")
}

pub fn demo_compression_levels() -> Unit {
  println("\n5. 压缩级别比较")
  println("   " + @zstd_test.repeat_string("-", 30))
  
  let test_data = @utf8.encode("Compression level test data")
  let compressed = match @zstd.compress(test_data) {
    Ok(c) => c
    Err(e) => { println("压缩失败: \{e}"); return }
  }
  let compressed_size = compressed.length()
  let ratio = test_data.length().to_double() / compressed.length().to_double()
  
  println("   默认压缩:")
  println("     实际大小: \{compressed_size} 字节")
  println("     压缩比: \{ratio}x")
}

pub fn demo_huffman_encoding() -> Unit {
  println("\n6. Huffman 编码演示")
  println("   " + @zstd_test.repeat_string("-", 30))

  // 调用 Huffman 编码器的演示函数
  @zstd_entropy.demo_huffman_encoding()
}

pub fn print_summary() -> Unit {
  println("\nMoonBit ZSTD 库功能总结")
}

fn create_test_data(size: Int) -> Bytes {
  let data : Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    data.push((i % 256).to_byte())
  }
  Bytes::from_array(data)
}

fn format_magic_number(data: Bytes) -> String {
  if data.length() < 4 {
    return "00000000"
  }

  let mut result = ""
  for i = 3; i >= 0; i = i - 1 {
    let byte_val = data[i].to_int()
    if byte_val < 16 {
      result = result + "0"
    }
    result = result + to_upper_hex(byte_val)
  }
  result
}

fn to_upper_hex(value: Int) -> String {
  if value == 0 { return "0" }

  let hex_chars = "0123456789ABCDEF"
  let mut result = ""
  let mut n = value
  while n > 0 {
    let digit = n % 16
    result = hex_chars.code_unit_at(digit).to_int().unsafe_to_char().to_string() + result
    n = n / 16
  }
  result
}

fn drop_last_bytes(data: Bytes, count: Int) -> Bytes {
  let keep_size = (data.length() - count).max(0)
  let output : Array[Byte] = []
  for i = 0; i < keep_size; i = i + 1 {
    output.push(data[i])
  }
  Bytes::from_array(output)
}

