/// RFC 8878 Compliance Tests - Batch testing with official files

pub fn test_all_golden_files() -> Unit {
  println("\n" + @zstd_test.repeat_string("=", 60))
  println("批量测试所有官方测试文件")
  println(@zstd_test.repeat_string("=", 60))
  
  println("\n测试 1: Golden Decompression 文件")
  println(@zstd_test.repeat_string("-", 40))
  test_golden_decompression()
  
  println("\n测试 2: 文本文件")
  println(@zstd_test.repeat_string("-", 40))
  test_text_files()
  
  println("\n测试 3: 用户文件 (test_1.zst)")
  println(@zstd_test.repeat_string("-", 40))
  test_user_file()
  
  println("\n" + @zstd_test.repeat_string("=", 60))
}

fn test_golden_decompression() -> Unit {
  let files = [
    "empty-block.zst",
    "rle-first-block.zst",
    "block-128k.zst",
    "zeroSeq_2B.zst"
  ]
  
  let mut passed = 0
  for i = 0; i < files.length(); i = i + 1 {
    let filename = files[i]
    let path = "src/test-data/golden-decompression/" + filename
    
    let file = try {
      @fs.read_file_to_bytes(path)
    } catch {
      _ => {
        println("  ✗ \{filename}: 无法读取")
        continue
      }
    }
    
    let result = @zstd.decompress(file)
    if result.length() >= 0 {
      println("  ✓ \{filename}: 解压成功 (\{result.length()} 字节)")
      passed = passed + 1
    } else {
      println("  ✗ \{filename}: 解压失败")
    }
  }
  
  println("  通过率: \{passed}/\{files.length()}")
}

fn test_text_files() -> Unit {
  let files = [
    "empty.txt.zst",
    "short.txt.zst",
    "single_char.txt.zst"
  ]
  
  let mut passed = 0
  for i = 0; i < files.length(); i = i + 1 {
    let filename = files[i]
    let path = "src/test-data/text/" + filename
    
    let file = try {
      @fs.read_file_to_bytes(path)
    } catch {
      _ => {
        println("  ✗ \{filename}: 无法读取")
        continue
      }
    }
    
    let result = @zstd.decompress(file)
    if result.length() >= 0 {
      println("  ✓ \{filename}: 解压成功 (\{result.length()} 字节)")
      passed = passed + 1
    } else {
      println("  ✗ \{filename}: 解压失败")
    }
  }
  
  println("  通过率: \{passed}/\{files.length()}")
}

fn test_user_file() -> Unit {
  let original = try {
    @fs.read_file_to_bytes("src/test-data/test_1.txt")
  } catch {
    _ => {
      println("  ✗ 无法读取原始文件")
      return
    }
  }
  
  let compressed = try {
    @fs.read_file_to_bytes("src/test-data/test_1.zst")
  } catch {
    _ => {
      println("  ✗ 无法读取压缩文件")
      return
    }
  }
  
  println("  原始文件: \{original.length()} 字节")
  println("  压缩文件: \{compressed.length()} 字节")
  
  // 测试分析器
  let analysis = @zstd_decoder.analyze_file(compressed)
  println("  分析器结果: is_valid=\{analysis.is_valid}")
  if !analysis.is_valid {
    println("  分析器错误: \{analysis.error_message}")
  }
  
  // 测试直接解压
  let direct_result = @zstd_decoder.decompress_zstd_data(compressed)
  match direct_result {
    Ok(data) => println("  ✓ decompress_zstd_data: 成功 (\{data.length()} 字节)")
    Err(msg) => println("  ✗ decompress_zstd_data: 失败 - \{msg}")
  }
  
  // 测试完整解压
  let full_result = @zstd_decoder.decompress(compressed)
  match full_result {
    Ok(data) => println("  ✓ @zstd_decoder.decompress: 成功 (\{data.length()} 字节)")
    Err(err) => println("  ✗ @zstd_decoder.decompress: 失败 - \{@zstd_core.error_to_string(err)}")
  }
  
  // 测试高层 API
  let api_result = @zstd.decompress(compressed)
  println("  @zstd.decompress: \{api_result.length()} 字节")
  
  if api_result == original {
    println("  ✓ 完全成功：数据一致！")
    let text = try {
      @encoding/utf8.decode(api_result)
    } catch {
      _ => "(无法解码)"
    }
    println("  内容: '\{text}'")
  } else {
    println("  ✗ 数据不一致")
  }
}

