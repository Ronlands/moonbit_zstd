/// Main program entry point for Moonbit ZSTD
/// 使用 @fs 库测试文件读取功能

/// Main function
fn main {
  println("🚀 MoonBit ZSTD 项目 - 文件系统测试")
  println("📁 使用 moonbitlang/x/fs 库")
  println(repeat_string("=", 50))
  
  // 1. 测试基本文件系统功能
  test_basic_fs_operations()
  
  println("")
  println("✨ 文件系统测试完成！")
}

/// 测试基本文件系统操作
fn test_basic_fs_operations() -> Unit {
  println("🔍 基本文件系统操作测试:")
  
  // 测试当前目录
  let current_exists = @fs.path_exists(".")
  println("   当前目录 (.): " + bool_status(current_exists))
  
  // 测试父目录
  let parent_exists = @fs.path_exists("..")
  println("   父目录 (..): " + bool_status(parent_exists))
  
  // 测试一个简单的文件读取
  let test_file = "../zstd/tests/golden-decompression/empty-block.zst"
  if @fs.path_exists(test_file) {
    println("   ✅ 找到测试文件: " + test_file)
    
    try {
      let file_data = @fs.read_file_to_bytes(test_file)
      println("   📊 文件大小: " + file_data.length().to_string() + " 字节")
      
      // 验证 ZSTD 魔数
      if file_data.length() >= 4 {
        let magic = file_data[0].to_int() |
                   (file_data[1].to_int() << 8) |
                   (file_data[2].to_int() << 16) |
                   (file_data[3].to_int() << 24)
        
        if magic == 0xFD2FB528 {
          println("   🎯 ZSTD 魔数验证: ✅")
        } else {
          println("   🎯 ZSTD 魔数验证: ❌ (0x" + magic.to_string() + ")")
        }
      }
    } catch {
      err => println("   ❌ 读取失败: " + err.to_string())
    }
  } else {
    println("   ❌ 测试文件不存在: " + test_file)
  }
}

/// 格式化布尔值状态
fn bool_status(value : Bool) -> String {
  if value { "✅" } else { "❌" }
}

/// 重复字符串
fn repeat_string(s : String, n : Int) -> String {
  let mut result = ""
  for i = 0; i < n; i = i + 1 {
    result = result + s
  }
  result
}
