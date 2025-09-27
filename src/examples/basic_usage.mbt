/// 基础使用示例
/// 展示 MoonBit ZSTD 库的基本功能

/// 基础解压缩示例
pub fn basic_decompression_example() -> Unit {
  println("=== 基础解压缩示例 ===")
  
  // 示例 ZSTD 数据 (这里使用占位符)
  let sample_zstd_data = b"(\xb5/\xfd\x00\x00\x15\x00\x00\x00\x00"
  
  // 检查是否为 ZSTD 数据
  let is_zstd = @api.is_zstd_data(sample_zstd_data)
  println("是否为 ZSTD 数据: " + is_zstd.to_string())
  
  // 分析文件结构
  let analysis = @api.analyze_zstd_file(sample_zstd_data)
  if analysis.is_valid {
    println("✅ 文件分析成功:")
    println("  - 文件大小: " + analysis.file_size.to_string() + " 字节")
    println("  - 块数量: " + analysis.total_blocks.to_string())
    println("  - 首块类型: " + analysis.first_block_type)
    println("  - 单段模式: " + analysis.single_segment.to_string())
    println("  - 内容校验: " + analysis.content_checksum.to_string())
  } else {
    println("❌ 文件分析失败: " + analysis.error_message)
  }
  
  // 尝试解压缩
  let decompressed = @api.decompress(sample_zstd_data)
  println("解压缩结果长度: " + decompressed.length().to_string() + " 字节")
}

/// 文件验证示例
pub fn file_validation_example() -> Unit {
  println("\n=== 文件验证示例 ===")
  
  // 有效的 ZSTD 魔数
  let valid_zstd = b"(\xb5/\xfd\x00\x00\x15\x00\x00\x00\x00"
  let invalid_data = b"Not ZSTD data"
  
  println("验证有效 ZSTD 数据:")
  let (is_valid1, message1) = @api.validate_zstd_file(valid_zstd)
  println("  结果: " + is_valid1.to_string() + " - " + message1)
  
  println("验证无效数据:")
  let (is_valid2, message2) = @api.validate_zstd_file(invalid_data)
  println("  结果: " + is_valid2.to_string() + " - " + message2)
}

/// 压缩率计算示例
pub fn compression_ratio_example() -> Unit {
  println("\n=== 压缩率计算示例 ===")
  
  let original_size = 1000
  let compressed_size = 400
  
  let ratio = @api.get_compression_ratio(original_size, compressed_size)
  println("原始大小: " + original_size.to_string() + " 字节")
  println("压缩大小: " + compressed_size.to_string() + " 字节")
  println("压缩率: " + ratio.to_string() + "%")
  
  let space_saved = ((original_size - compressed_size).to_double() / original_size.to_double()) * 100.0
  println("节省空间: " + space_saved.to_string() + "%")
}

/// 运行所有基础示例
pub fn run_basic_examples() -> Unit {
  println("🚀 MoonBit ZSTD 基础使用示例")
  println("=================================")
  
  basic_decompression_example()
  file_validation_example()
  compression_ratio_example()
  
  println("\n✨ 基础示例演示完成！")
}