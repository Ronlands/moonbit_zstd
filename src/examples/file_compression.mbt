/// Comprehensive compression and decompression tests

pub fn test_file_compression() -> Unit {
  println("\n" + @zstd_test.repeat_string("=", 60))
  println("压缩和解压缩功能测试")
  println(@zstd_test.repeat_string("=", 60))
  
  test_text_compression()
  test_binary_compression()
  test_large_data_compression()
  test_compression_round_trip()
  
  println("\n" + @zstd_test.repeat_string("=", 60))
  println("压缩功能测试完成！")
  println(@zstd_test.repeat_string("=", 60))
}

/// Text data compression test
fn test_text_compression() -> Unit {
  println("\n测试 1: 文本数据压缩")
  println(@zstd_test.repeat_string("-", 40))
  
  let test_text = "Hello, MoonBit ZSTD!\nThis is a test for compression.\n测试中文内容。\n"
  let original_data = @encoding/utf8.encode(test_text)
  println("原始数据大小: \{original_data.length()} 字节")
  
  let compressed = @zstd.compress(original_data)
  println("压缩后大小: \{compressed.length()} 字节")
  println("压缩比: \{compressed.length().to_double() / original_data.length().to_double()}")
  
  let decompressed = @zstd.decompress(compressed)
  println("解压后大小: \{decompressed.length()} 字节")
  
  if original_data.length() == decompressed.length() {
    let mut all_match = true
    for i = 0; i < original_data.length(); i = i + 1 {
      if original_data[i] != decompressed[i] {
        all_match = false
        break
      }
    }
    if all_match {
      println("✓ 数据完整性验证: 通过")
    } else {
      println("✗ 数据完整性验证: 失败 (内容不匹配)")
    }
  } else {
    println("✗ 数据完整性验证: 失败 (大小不匹配)")
  }
}

/// Binary data compression test
fn test_binary_compression() -> Unit {
  println("\n测试 2: 二进制数据压缩")
  println(@zstd_test.repeat_string("-", 40))
  
  let binary_data : Array[Byte] = []
  for i = 0; i < 1000; i = i + 1 {
    binary_data.push((i % 256).to_byte())
  }
  let original = Bytes::from_array(binary_data)
  println("原始数据: \{original.length()} 字节")
  
  let compressed = @zstd.compress(original)
  println("压缩后: \{compressed.length()} 字节")
  println("节省空间: \{100.0 - (compressed.length().to_double() / original.length().to_double() * 100.0)}%")
  
  let decompressed = @zstd.decompress(compressed)
  
  if original == decompressed {
    println("✓ 往返验证: 成功")
  } else {
    println("✗ 往返验证: 失败")
  }
}

/// Large data compression test (~10KB)
fn test_large_data_compression() -> Unit {
  println("\n测试 3: 大数据压缩")
  println(@zstd_test.repeat_string("-", 40))
  
  let large_data : Array[Byte] = []
  let pattern = @encoding/utf8.encode("ABCDEFGHIJ")
  
  for _i = 0; _i < 1000; _i = _i + 1 {
    for j = 0; j < pattern.length(); j = j + 1 {
      large_data.push(pattern[j])
    }
  }
  
  let original = Bytes::from_array(large_data)
  println("原始数据: \{original.length()} 字节 (~\{original.length() / 1024}KB)")
  
  let compressed = @zstd.compress(original)
  println("压缩后: \{compressed.length()} 字节 (~\{compressed.length() / 1024}KB)")
  println("压缩比: \{original.length().to_double() / compressed.length().to_double()}:1")
  
  let decompressed = @zstd.decompress(compressed)
  
  if original.length() == decompressed.length() {
    println("✓ 大小验证: 通过")
  } else {
    println("✗ 大小验证: 失败")
  }
}

/// Round-trip validation test
fn test_compression_round_trip() -> Unit {
  println("\n测试 4: 完整往返测试")
  println(@zstd_test.repeat_string("-", 40))
  
  let test_cases = [
    ("空文件", Bytes::new(0)),
    ("小文件", @encoding/utf8.encode("Small")),
    ("中等文件", create_test_data(500)),
    ("特殊字符", @encoding/utf8.encode("Hello! 你好！🎉 \n\t\r")),
  ]
  
  let mut passed = 0
  let total = test_cases.length()
  
  for i = 0; i < test_cases.length(); i = i + 1 {
    let (name, data) = test_cases[i]
    
    let compressed = @zstd.compress(data)
    let decompressed = @zstd.decompress(compressed)
    
    if data == decompressed {
      println("  \{name}: ✓")
      passed = passed + 1
    } else {
      println("  \{name}: ✗ (数据不匹配)")
    }
  }
  
  println("\n往返测试通过率: \{passed}/\{total}")
}

