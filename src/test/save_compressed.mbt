/// 保存压缩数据到文件，用官方 zstd 工具验证

/// 保存字节数据到文件（生成 PowerShell 脚本）
pub fn save_bytes_to_file(data: Bytes, filename: String) -> Unit {
  println("正在生成文件: \{filename}")
  println("数据大小: \{data.length()} bytes")

  // Output each byte as a decimal value for PowerShell [byte[]]
  let mut script = "$bytes = [byte[]]@("
  for i = 0; i < data.length(); i = i + 1 {
    if i > 0 { script = script + "," }
    if i % 16 == 0 { script = script + "\n  " }
    script = script + data[i].to_int().to_string()
  }
  script = script + "\n)\n"
  script = script + "[System.IO.File]::WriteAllBytes('\{filename}', $bytes)\n"
  script = script + "Write-Host '文件已创建: \{filename}'\n"
  println(script)
}

/// 测试：保存压缩文件并用官方工具验证
pub fn test_save_and_verify() -> Unit {
  println("\n" + "=".repeat(60))
  println("保存压缩文件用于官方 zstd 工具验证")
  println("=".repeat(60))
  
  // 测试数据：450 字节重复文本
  let text = "The quick brown fox jumps over the lazy dog. "  // 45 bytes
  let data_bytes : Array[Byte] = []
  for _i = 0; _i < 10; _i = _i + 1 {
  for j = 0; j < text.length(); j = j + 1 {
    data_bytes.push(text.code_unit_at(j).to_byte())
  }
  }
  let original_data = Bytes::from_array(data_bytes)
  
  println("\n原始数据:")
  println("  大小: \{original_data.length()} bytes")
  println("  内容: \{text} (重复 10 次)")
  
  // 压缩
  let compressed = @zstd.compress(original_data)
  println("\n压缩后:")
  println("  大小: \{compressed.length()} bytes")
  println("  压缩比: \{original_data.length() * 100 / compressed.length()}%")
  
  // 保存到文件
  let filename = "moonbit_compressed.zst"
  save_bytes_to_file(compressed, filename)
  
  println("\n验证步骤:")
  println("1. 将上面输出的 PowerShell 脚本内容保存为 create_file.ps1")
  println("2. 运行脚本生成二进制文件:")
  println("   .\\create_file.ps1")
  println("3. 运行官方工具解压:")
  println("   zstd -d \{filename} -o moonbit_output.txt")
  println("4. 检查解压后的文件:")
  println("   cat moonbit_output.txt")
  println("5. 应该看到: \{text} (重复 10 次)")
  println("\n" + "=".repeat(60))
}

