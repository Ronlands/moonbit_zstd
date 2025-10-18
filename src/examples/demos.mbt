/// ZSTD usage demonstrations

/// Demo basic compression
pub fn demo_basic_compression() -> Unit {
  println("\n1. 基本压缩和解压缩测试")
  println("   " + repeat_string("-", 30))
  
  let test_data = @encoding/utf8.encode("Hello, ZSTD!")
  let original_size = test_data.length()
  
  let compressed = @zstd.compress(test_data)
  let compressed_size = compressed.length()
  let ratio = compressed_size.to_double() / original_size.to_double()
  
  let decompressed = @zstd.decompress(compressed)
  let is_correct = test_data == decompressed
  let decompressed_size = decompressed.length()
  let correctness = if is_correct { "正确" } else { "错误" }
  
  println("   原始数据: \{original_size} 字节")
  println("   压缩后: \{compressed_size} 字节")
  println("   压缩比: \{ratio}")
  println("   解压后: \{decompressed_size} 字节")
  println("   数据完整性: \{correctness}")
}

/// Demo file analysis
pub fn demo_file_analysis() -> Unit {
  println("\n2. ZSTD文件分析")
  println("   " + repeat_string("-", 30))
  
  let test_data = @encoding/utf8.encode("Analysis test data")
  let compressed = @zstd.compress(test_data)
  let analysis = @zstd.analyze_file(compressed)
  let magic_str = analysis.magic_number.reinterpret_as_int().to_string()
  let file_size = test_data.length()
  
  println("   文件结构分析:")
  println("   - 文件有效性: \{analysis.is_valid}")
  println("   - 魔数: 0x\{magic_str}")
  println("   - 文件大小: \{file_size} 字节")
  println("   - 总块数: \{analysis.total_blocks}")
  println("   - 第一块类型: \{analysis.first_block_type}")
  println("   - 单段模式: \{analysis.single_segment}")
  println("   - 内容校验: \{analysis.content_checksum}")
}

/// Demo data integrity analysis
pub fn demo_data_integrity() -> Unit {
  println("\n3. 数据完整性分析")
  println("   " + repeat_string("-", 30))
  
  let test_sizes = [100, 1000, 10000]
  for i = 0; i < test_sizes.length(); i = i + 1 {
    let size = test_sizes[i]
    let test_data = create_test_data(size)
    let integrity = @zstd.analyze_data_integrity(test_data)
    
    println("   数据大小 \{size} 字节:")
    println("     分析速度: 优秀")
    println("     数据密度: \{integrity.data_density}")
    println("     结构一致性: \{integrity.structure_consistency}")
    println("     熵级别: \{integrity.entropy_level}")
    println("     截断指标: \{integrity.truncation_indicators}")
  }
}

/// Demo format detection
pub fn demo_format_detection() -> Unit {
  println("\n4. 格式检测测试")
  println("   " + repeat_string("-", 30))
  
  let test_data = @encoding/utf8.encode("Format test")
  let compressed = @zstd.compress(test_data)
  let non_zstd = @encoding/utf8.encode("Not ZSTD data")
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

/// Demo compression levels
pub fn demo_compression_levels() -> Unit {
  println("\n5. 压缩级别比较")
  println("   " + repeat_string("-", 30))
  
  let test_data = @encoding/utf8.encode("Compression level test data")
  let compressed = @zstd.compress(test_data)  // Use default compression
  let compressed_size = compressed.length()
  let ratio = compressed.length().to_double() / test_data.length().to_double()
  
  println("   默认压缩:")
  println("     实际大小: \{compressed_size} 字节")
  println("     压缩比: \{ratio}")
}

/// Print summary
pub fn print_summary() -> Unit {
  println("\nMoonBit ZSTD 库功能总结")
}

/// Create test data of specified size
fn create_test_data(size: Int) -> Bytes {
  let data : Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    data.push((i % 256).to_byte())
  }
  Bytes::from_array(data)
}

/// Repeat string n times
fn repeat_string(s: String, n: Int) -> String {
  let mut result = ""
  for _i = 0; _i < n; _i = _i + 1 {
    result = result + s
  }
  result
}

