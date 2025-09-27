/// 流式操作示例
/// 展示如何使用 ZSTD 库进行流式压缩和解压缩

/// 流式解压缩示例
pub fn streaming_decompression_example() -> Unit {
  println("=== 流式解压缩示例 ===")
  
  // 创建解压器
  let decompressor = @api.create_decompressor()
  println("✅ 创建解压器成功")
  
  // 模拟多个数据块
  let chunks = [
    b"(\xb5/\xfd\x00\x00\x15\x00\x00\x00\x00",  // 第一个块
    b"More data here",                          // 第二个块
    b"Final chunk"                              // 最后一个块
  ]
  
  let mut current_decompressor = decompressor
  let mut total_processed = 0
  
  // 处理每个数据块
  for i = 0; i < chunks.length(); i = i + 1 {
    let chunk = chunks[i]
    println("处理块 " + (i + 1).to_string() + " (大小: " + chunk.length().to_string() + " 字节)")
    
    let (new_decompressor, result) = @api.decompress_with_decompressor(current_decompressor, chunk)
    current_decompressor = new_decompressor
    total_processed = total_processed + result.length()
    
    println("  块处理完成，输出大小: " + result.length().to_string() + " 字节")
  }
  
  println("总计处理: " + total_processed.to_string() + " 字节")
}

/// 模拟大文件处理
pub fn large_file_processing_example() -> Unit {
  println("\n=== 大文件处理示例 ===")
  
  // 模拟一个大文件的多个块
  let file_chunks = generate_sample_chunks(5)
  
  println("模拟处理大文件 (" + file_chunks.length().to_string() + " 个块)")
  
  let decompressor = @api.create_decompressor()
  let mut current_decompressor = decompressor
  let mut processed_chunks = 0
  let mut total_input_size = 0
  let mut total_output_size = 0
  
  for chunk in file_chunks {
    // 分析每个块
    let analysis = @api.analyze_zstd_file(chunk)
    
    if analysis.is_valid {
      println("✅ 块 " + (processed_chunks + 1).to_string() + ": " + 
              analysis.first_block_type + " 块 (" + 
              chunk.length().to_string() + " 字节)")
      
      // 解压缩块
      let (new_decompressor, result) = @api.decompress_with_decompressor(current_decompressor, chunk)
      current_decompressor = new_decompressor
      
      total_input_size = total_input_size + chunk.length()
      total_output_size = total_output_size + result.length()
    } else {
      println("❌ 块 " + (processed_chunks + 1).to_string() + ": 无效 ZSTD 数据")
    }
    
    processed_chunks = processed_chunks + 1
  }
  
  println("处理完成:")
  println("  - 处理块数: " + processed_chunks.to_string())
  println("  - 输入总大小: " + total_input_size.to_string() + " 字节")
  println("  - 输出总大小: " + total_output_size.to_string() + " 字节")
  
  if total_input_size > 0 {
    let ratio = @api.get_compression_ratio(total_output_size, total_input_size)
    println("  - 压缩率: " + ratio.to_string() + "%")
  }
}

/// 错误处理示例
pub fn error_handling_example() -> Unit {
  println("\n=== 错误处理示例 ===")
  
  let test_cases = [
    ("有效 ZSTD 数据", b"(\xb5/\xfd\x00\x00\x15\x00\x00\x00\x00"),
    ("无效魔数", b"INVALID\x00\x00\x15\x00\x00\x00\x00"),
    ("数据太短", b"(\xb5"),
    ("空数据", b"")
  ]
  
  let decompressor = @api.create_decompressor()
  
  for case in test_cases {
    let (description, data) = case
    println("测试: " + description)
    
    // 验证文件
    let (is_valid, message) = @api.validate_zstd_file(data)
    if is_valid {
      println("  ✅ 验证通过: " + message)
      
      // 尝试解压缩
      let (_, result) = @api.decompress_with_decompressor(decompressor, data)
      println("  📤 解压缩输出: " + result.length().to_string() + " 字节")
    } else {
      println("  ❌ 验证失败: " + message)
    }
  }
}

/// 生成示例数据块
fn generate_sample_chunks(count: Int) -> Array[Bytes] {
  let mut chunks: Array[Bytes] = []
  
  for i = 0; i < count; i = i + 1 {
    // 创建不同类型的示例块
    let chunk = match i % 3 {
      0 => b"(\xb5/\xfd\x00\x00\x15\x00\x00\x00\x00"  // 类型 0
      1 => b"(\xb5/\xfd\xa4\x00\x00\x10\x00\x02\x00"  // 类型 1
      2 => b"(\xb5/\xfd\x00\x00\x85\x00\x00hHello"     // 类型 2
      _ => b"(\xb5/\xfd\x00\x00\x15\x00\x00\x00\x00"  // 默认
    }
    chunks = chunks + [chunk]
  }
  
  chunks
}

/// 性能监控示例
pub fn performance_monitoring_example() -> Unit {
  println("\n=== 性能监控示例 ===")
  
  let test_data = b"(\xb5/\xfd\x00\x00\x15\x00\x00\x00\x00"
  let iterations = 100
  
  println("执行 " + iterations.to_string() + " 次解压缩操作...")
  
  let mut successful_operations = 0
  let mut total_input_bytes = 0
  let mut total_output_bytes = 0
  
  for i = 0; i < iterations; i = i + 1 {
    let analysis = @api.analyze_zstd_file(test_data)
    if analysis.is_valid {
      let result = @api.decompress(test_data)
      successful_operations = successful_operations + 1
      total_input_bytes = total_input_bytes + test_data.length()
      total_output_bytes = total_output_bytes + result.length()
    }
  }
  
  println("性能统计:")
  println("  - 成功操作: " + successful_operations.to_string() + "/" + iterations.to_string())
  println("  - 总输入: " + total_input_bytes.to_string() + " 字节")
  println("  - 总输出: " + total_output_bytes.to_string() + " 字节")
  println("  - 平均输入大小: " + (total_input_bytes / successful_operations).to_string() + " 字节")
  println("  - 平均输出大小: " + (total_output_bytes / successful_operations).to_string() + " 字节")
}

/// 运行所有流式示例
pub fn run_streaming_examples() -> Unit {
  println("🌊 MoonBit ZSTD 流式操作示例")
  println("================================")
  
  streaming_decompression_example()
  large_file_processing_example()
  error_handling_example()
  performance_monitoring_example()
  
  println("\n✨ 流式示例演示完成！")
}