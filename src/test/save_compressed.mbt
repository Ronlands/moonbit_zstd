/// 保存压缩数据到文件，用官方 zstd 工具验证

/// 转换字节到十六进制字符串
fn byte_to_hex(byte: Int) -> String {
  let hex_chars = "0123456789abcdef"
  let high = (byte >> 4) & 0xF
  let low = byte & 0xF
  hex_chars.code_unit_at(high).to_string() + hex_chars.code_unit_at(low).to_string()
}

/// 保存字节数据到文件（生成 PowerShell 脚本到独立的 .ps1 文件）
pub fn save_bytes_to_file(data: Bytes, filename: String) -> Unit {
  println("正在生成文件: \{filename}")
  println("数据大小: \{data.length()} bytes")
  
  // 生成 PowerShell 脚本内容
  let mut script = "$bytes = [byte[]]@(\n"
  
  for i = 0; i < data.length(); i = i + 1 {
    if i > 0 {
      script = script + ","
    }
    if i % 16 == 0 {
      script = script + "\n  "
    }
    script = script + "0x" + byte_to_hex(data[i].to_int())
  }
  
  script = script + "\n)\n"
  script = script + "[System.IO.File]::WriteAllBytes('\{filename}', $bytes)\n"
  script = script + "Write-Host '✓ 文件已创建: \{filename}'\n"
  
  // 输出脚本内容，用户可以运行：
  // moon run src/test -g save_compressed > create_file.ps1
  // .\create_file.ps1
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
  println("1. 将上面的脚本保存到文件:")
  println("   moon run src/test -g save_compressed > create_file.ps1")
  println("2. 运行脚本生成二进制文件:")
  println("   .\\create_file.ps1")
  println("3. 运行官方工具解压:")
  println("   zstd -d \{filename} -o moonbit_output.txt")
  println("4. 检查解压后的文件:")
  println("   cat moonbit_output.txt")
  println("5. 应该看到: \{text} (重复 10 次)")
  println("\n" + "=".repeat(60))
  println("\n提示：请运行以下命令生成文件：")
  println("moon run src/test -g save_compressed > create_file.ps1")
  println(".\\create_file.ps1")
}

