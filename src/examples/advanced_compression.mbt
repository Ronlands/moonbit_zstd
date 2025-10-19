/// Advanced Compression Methods and Levels
/// 高级压缩方法和级别演示

pub fn demo_compression_methods() -> Unit {
  println("\n" + @zstd_test.repeat_string("=", 60))
  println("压缩方法演示")
  println(@zstd_test.repeat_string("=", 60))
  
  let test_text = "Hello, MoonBit ZSTD! " + @zstd_test.repeat_string("A", 100)
  let test_data = @encoding/utf8.encode(test_text)
  
  println("\n1. 自动选择压缩方法（级别2）")
  println(@zstd_test.repeat_string("-", 40))
  let auto_compressed = @zstd.compress_with_level_int(test_data, 2)
  println("  原始大小: \{test_data.length()} 字节")
  println("  压缩后: \{auto_compressed.length()} 字节")
  println("  压缩比: \{test_data.length().to_double() / auto_compressed.length().to_double()}")
  
  println("\n2. Raw 块（无压缩）")
  println(@zstd_test.repeat_string("-", 40))
  let raw_compressed = @zstd.compress_as_raw(test_data, 2)
  println("  原始大小: \{test_data.length()} 字节")
  println("  压缩后: \{raw_compressed.length()} 字节")
  println("  压缩比: \{test_data.length().to_double() / raw_compressed.length().to_double()}")
  
  println("\n3. RLE 块（适合重复数据）")
  println(@zstd_test.repeat_string("-", 40))
  let rle_data = Bytes::from_array([0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41])
  let rle_compressed = @zstd.compress_as_rle(rle_data, 2)
  println("  原始大小: \{rle_data.length()} 字节")
  println("  压缩后: \{rle_compressed.length()} 字节")
  println("  压缩比: \{rle_data.length().to_double() / rle_compressed.length().to_double()}")
  
  println("\n4. Compressed 块（LZ77 + 熵编码）")
  println(@zstd_test.repeat_string("-", 40))
  let compressed_result = @zstd.compress_as_compressed(test_data, 5)
  println("  原始大小: \{test_data.length()} 字节")
  println("  压缩后: \{compressed_result.length()} 字节")
  println("  压缩比: \{test_data.length().to_double() / compressed_result.length().to_double()}")
  
  println("\n" + @zstd_test.repeat_string("=", 60))
}

pub fn demo_compression_levels_advanced() -> Unit {
  println("\n" + @zstd_test.repeat_string("=", 60))
  println("压缩级别详细演示")
  println(@zstd_test.repeat_string("=", 60))
  
  let test_text = "The quick brown fox jumps over the lazy dog. " + @zstd_test.repeat_string("Test", 50)
  let test_data = @encoding/utf8.encode(test_text)
  
  let levels = [1, 3, 5, 9, 15, 22]
  
  for i = 0; i < levels.length(); i = i + 1 {
    let level = levels[i]
    println("\n级别 \{level}:")
    println(@zstd_test.repeat_string("-", 40))
    
    let compressed = @zstd.compress_with_level_int(test_data, level)
    let decompressed = @zstd.decompress(compressed)
    
    let ratio_percent = (test_data.length().to_double() / compressed.length().to_double() * 100.0).to_int()
    let verify_result = if test_data == decompressed { "✓ 通过" } else { "✗ 失败" }
    println("  原始大小: \{test_data.length()} 字节")
    println("  压缩后: \{compressed.length()} 字节")
    println("  压缩比: \{ratio_percent}%")
    println("  解压验证: \{verify_result}")
  }
  
  println("\n" + @zstd_test.repeat_string("=", 60))
}

pub fn demo_method_comparison() -> Unit {
  println("\n" + @zstd_test.repeat_string("=", 60))
  println("压缩方法性能比较")
  println(@zstd_test.repeat_string("=", 60))
  
  let text_10_times = repeat_text("The quick brown fox jumps over the lazy dog. ", 10)
  let repeated_bytes = create_repeated_bytes(0x41, 200)
  let test_cases = [
    ("纯文本", @encoding/utf8.encode(text_10_times)),
    ("重复数据", repeated_bytes),
    ("随机数据", create_random_bytes(200))
  ]
  
  for i = 0; i < test_cases.length(); i = i + 1 {
    let (name, data) = test_cases[i]
    println("\n测试数据: \{name} (\{data.length()} 字节)")
    println(@zstd_test.repeat_string("-", 40))
    
    let auto_comp = @zstd.compress_with_level_int(data, 3)
    let auto_ratio = (data.length().to_double() / auto_comp.length().to_double() * 100.0).to_int()
    let auto_name = pad_right("Auto", 12)
    let auto_size = pad_left(auto_comp.length().to_string(), 4)
    println("  \{auto_name} -> \{auto_size} 字节 (比率: \{auto_ratio}%)")
    
    let raw_comp = @zstd.compress_as_raw(data, 3)
    let raw_ratio = (data.length().to_double() / raw_comp.length().to_double() * 100.0).to_int()
    let raw_name = pad_right("Raw", 12)
    let raw_size = pad_left(raw_comp.length().to_string(), 4)
    println("  \{raw_name} -> \{raw_size} 字节 (比率: \{raw_ratio}%)")
    
    let rle_comp = @zstd.compress_as_rle(data, 3)
    let rle_ratio = (data.length().to_double() / rle_comp.length().to_double() * 100.0).to_int()
    let rle_name = pad_right("RLE", 12)
    let rle_size = pad_left(rle_comp.length().to_string(), 4)
    println("  \{rle_name} -> \{rle_size} 字节 (比率: \{rle_ratio}%)")
    
    let comp_comp = @zstd.compress_as_compressed(data, 3)
    let comp_ratio = (data.length().to_double() / comp_comp.length().to_double() * 100.0).to_int()
    let comp_name = pad_right("Compressed", 12)
    let comp_size = pad_left(comp_comp.length().to_string(), 4)
    println("  \{comp_name} -> \{comp_size} 字节 (比率: \{comp_ratio}%)")
  }
  
  println("\n" + @zstd_test.repeat_string("=", 60))
}

fn create_random_bytes(size: Int) -> Bytes {
  let arr: Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    arr.push(((i * 17 + 13) % 256).to_byte())
  }
  Bytes::from_array(arr)
}

fn create_repeated_bytes(byte_val: Int, count: Int) -> Bytes {
  let arr: Array[Byte] = []
  for _i = 0; _i < count; _i = _i + 1 {
    arr.push(byte_val.to_byte())
  }
  Bytes::from_array(arr)
}

fn repeat_text(text: String, times: Int) -> String {
  let mut result = ""
  for _i = 0; _i < times; _i = _i + 1 {
    result = result + text
  }
  result
}

fn pad_right(s: String, width: Int) -> String {
  let len = s.length()
  if len >= width { return s }
  let mut result = s
  for _i = 0; _i < (width - len); _i = _i + 1 {
    result = result + " "
  }
  result
}

fn pad_left(s: String, width: Int) -> String {
  let len = s.length()
  if len >= width { return s }
  let mut result = ""
  for _i = 0; _i < (width - len); _i = _i + 1 {
    result = result + " "
  }
  result + s
}


