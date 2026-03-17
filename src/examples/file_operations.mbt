/// File Compression and Decompression Operations
/// 文件压缩和解压缩综合测试

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

fn test_text_compression() -> Unit {
  println("\n测试 1: 文本数据压缩")
  println(@zstd_test.repeat_string("-", 40))
  
  let text = "The quick brown fox jumps over the lazy dog. Hello, MoonBit ZSTD!"
  let original = @encoding/utf8.encode(text)
  let compressed = match @zstd.compress(original) {
    Ok(c) => c
    Err(e) => { println("压缩失败: \{e}"); return }
  }
  let decompressed = @zstd.decompress(compressed)
  
  println("原始数据大小: \{original.length()} 字节")
  println("压缩后大小: \{compressed.length()} 字节")
  println("压缩比: \{compressed.length().to_double() / original.length().to_double()}")
  println("解压后大小: \{decompressed.length()} 字节")
  
  if original == decompressed {
    println("✓ 数据完整性验证: 通过")
  } else {
    println("✗ 数据完整性验证: 失败")
  }
}

fn test_binary_compression() -> Unit {
  println("\n测试 2: 二进制数据压缩")
  println(@zstd_test.repeat_string("-", 40))
  
  let original = create_binary_data(1000)
  let compressed = match @zstd.compress(original) {
    Ok(c) => c
    Err(e) => { println("压缩失败: \{e}"); return }
  }
  let decompressed = @zstd.decompress(compressed)
  
  let savings = if compressed.length() < original.length() {
    ((original.length() - compressed.length()) * 100 / original.length()).to_double() / 100.0
  } else {
    -((compressed.length() - original.length()) * 100 / original.length()).to_double() / 100.0
  }
  
  println("原始数据: \{original.length()} 字节")
  println("压缩后: \{compressed.length()} 字节")
  println("节省空间: \{(savings * 100.0).to_int()}%")
  
  if original == decompressed {
    println("✓ 往返验证: 成功")
  } else {
    println("✗ 往返验证: 失败")
  }
}

fn test_large_data_compression() -> Unit {
  println("\n测试 3: 大数据压缩")
  println(@zstd_test.repeat_string("-", 40))
  
  let original = create_binary_data(10000)
  let compressed = match @zstd.compress(original) {
    Ok(c) => c
    Err(e) => { println("压缩失败: \{e}"); return }
  }
  let decompressed = @zstd.decompress(compressed)
  
  let ratio = original.length().to_double() / compressed.length().to_double()
  
  println("原始数据: \{original.length()} 字节 (~\{original.length() / 1024}KB)")
  println("压缩后: \{compressed.length()} 字节 (~\{compressed.length() / 1024}KB)")
  println("压缩比: \{ratio}:1")
  
  if original == decompressed {
    println("✓ 大小验证: 通过")
  } else {
    println("✗ 大小验证: 失败")
  }
}

fn test_compression_round_trip() -> Unit {
  println("\n测试 4: 完整往返测试")
  println(@zstd_test.repeat_string("-", 40))
  
  let tests = [
    ("空文件", Bytes::new(0)),
    ("小文件", @encoding/utf8.encode("Small")),
    ("中等文件", create_binary_data(500)),
    ("特殊字符", @encoding/utf8.encode("😀🎉✓✗→"))
  ]
  
  let mut passed = 0
  for i = 0; i < tests.length(); i = i + 1 {
    let (name, data) = tests[i]
    let compressed = match @zstd.compress(data) {
      Ok(c) => c
      Err(_) => { println("  \{name}: 压缩失败"); continue }
    }
    let decompressed = @zstd.decompress(compressed)
    
    if data == decompressed {
      println("  \{name}: ✓")
      passed = passed + 1
    } else {
      println("  \{name}: ✗")
    }
  }
  
  println("\n往返测试通过率: \{passed}/\{tests.length()}")
}

fn create_binary_data(size: Int) -> Bytes {
  let arr: Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    arr.push(((i * 7 + 13) % 256).to_byte())
  }
  Bytes::from_array(arr)
}


