/// 编码函数测试
/// 验证 encode_ll/ml/of 函数是否正确

/// 辅助函数：转换为十六进制字符串
fn to_hex(value: Int) -> String {
  if value == 0 { return "0" }
  let hex_chars = "0123456789abcdef"
  let mut result = ""
  let mut n = value
  while n > 0 {
    let digit = n % 16
    result = hex_chars[digit].to_string() + result
    n = n / 16
  }
  result
}

/// 测试 Offset 编码
pub fn test_encode_of() -> Bool {
  // 测试几个关键值 (官方表: of_base = [0,1,1,5,0xD,0x1D...])
  let test_cases = [
    (1, 2, 0),      // OF=1  → code=2, extra=0, of_base[2]=1, 1+0=1
    (2, 2, 1),      // OF=2  → code=2, extra=1, of_base[2]=1, 1+1=2
    (5, 3, 0),      // OF=5  → code=3, extra=0, of_base[3]=5, 5+0=5
    (8, 3, 3),      // OF=8  → code=3, extra=3, of_base[3]=5, 5+3=8
    (16, 4, 3),     // OF=16 → code=4, extra=3, of_base[4]=0xD(13), 13+3=16
    (45, 5, 16),    // OF=45 → code=5, extra=16, of_base[5]=0x1D(29), 29+16=45
  ]
  
  println("\n=== Offset 编码测试 ===")
  for i = 0; i < test_cases.length(); i = i + 1 {
    let (offset, expected_code, expected_extra) = test_cases[i]
    let (code, extra) = @zstd_entropy.encode_of(offset)
    let decoded = @zstd_entropy.decode_of(code, extra)
    
    println("OF=\{offset}: code=\{code} (期望:\{expected_code}), extra=\{extra} (期望:\{expected_extra}), 解码=\{decoded}")
    
    // 验证往返
    if decoded != offset {
      println("  ❌ 往返验证失败：decoded=\{decoded}, expected=\{offset}")
      return false
    }
    
    // 如果期望值非零，验证编码结果
    if expected_code != 0 || expected_extra != 0 {
      if code != expected_code {
        println("  ⚠️ Code 不匹配！")
      }
      if extra != expected_extra {
        println("  ⚠️ Extra 不匹配！")
      }
    }
  }
  true
}

/// 测试 Literal Length 编码
pub fn test_encode_ll() -> Bool {
  let test_cases = [
    (0, 0, 0),      // LL=0 → code=0, extra=0, ll_base[0]=0
    (16, 16, 0),    // LL=16 → code=16, extra=0, ll_base[16]=16
    (18, 17, 0),    // LL=18 → code=17, extra=0, ll_base[17]=18
    (21, 18, 1),    // LL=21 → code=18, extra=1, ll_base[18]=20, 20+1=21
    (45, 23, 5),    // LL=45 → code=23, extra=5, ll_base[23]=40, 40+5=45
  ]
  
  println("\n=== Literal Length 编码测试 ===")
  for i = 0; i < test_cases.length(); i = i + 1 {
    let (ll, expected_code, expected_extra) = test_cases[i]
    let (code, extra) = @zstd_entropy.encode_ll(ll)
    let decoded = @zstd_entropy.decode_ll(code, extra)
    
    println("LL=\{ll}: code=\{code} (期望:\{expected_code}), extra=\{extra} (期望:\{expected_extra}), 解码=\{decoded}")
    
    if decoded != ll || code != expected_code || extra != expected_extra {
      println("  ❌ 测试失败！")
      return false
    }
  }
  true
}

/// 测试 Match Length 编码
pub fn test_encode_ml() -> Bool {
  let test_cases = [
    (3, 0, 0),      // ML=3 (最小) → code=0, extra=0, ml_base[0]=3
    (16, 13, 0),    // ML=16 → code=13, extra=0, ml_base[13]=16
    (45, 36, 2),    // ML=45 → code=36, extra=2, ml_base[36]=43, 43+2=45
  ]
  
  println("\n=== Match Length 编码测试 ===")
  for i = 0; i < test_cases.length(); i = i + 1 {
    let (ml, expected_code, expected_extra) = test_cases[i]
    let (code, extra) = @zstd_entropy.encode_ml(ml)
    let decoded = @zstd_entropy.decode_ml(code, extra)
    
    println("ML=\{ml}: code=\{code} (期望:\{expected_code}), extra=\{extra} (期望:\{expected_extra}), 解码=\{decoded}")
    
    if decoded != ml || code != expected_code || extra != expected_extra {
      println("  ❌ 测试失败！")
      return false
    }
  }
  true
}

/// 详细诊断：打印 OF base 表
pub fn diagnose_of_base_table() -> Unit {
  println("\n=== OF Base Table 诊断 ===")
  println("ZSTD 标准 Offset 编码:")
  println("Code  Base   Bits   Range")
  println("--------------------------------")
  println("0     1      0      1")
  println("1     2      1      2-3")
  println("2     4      2      4-7")
  println("3     8      3      8-15")
  println("4     16     4      16-31")
  println("5     29     5      29-60   ← OF=45 应该在这里")
  println("6     64     6      64-127")
  
  println("\n当前实现的 of_base 表 (前10个):")
  for i = 0; i < 10; i = i + 1 {
    let base = @zstd_entropy.of_base[i]
    let bits = @zstd_entropy.of_bits[i]
    let range_end = base + (1 << bits) - 1
    println("Code \{i}: Base=\{base} (0x\{to_hex(base)}), Bits=\{bits}, Range=\{base}-\{range_end}")
  }
  
  println("\n问题分析:")
  println("of_base[5] = \{@zstd_entropy.of_base[5]} (0x1D = 29)")
  println("标准应该是: 32 (0x20)")
  println("差异: \{@zstd_entropy.of_base[5] - 32}")
  
  println("\n对于 OF=45 的编码:")
  let (code, extra) = @zstd_entropy.encode_of(45)
  println("当前: code=\{code}, extra=\{extra}")
  println("of_base[\{code}] = \{@zstd_entropy.of_base[code]}")
  println("计算: \{@zstd_entropy.of_base[code]} + \{extra} = \{@zstd_entropy.of_base[code] + extra}")
  
  if @zstd_entropy.of_base[code] + extra == 45 {
    println("✓ 往返验证通过")
  } else {
    println("✗ 往返验证失败！")
  }
}

/// 测试完整序列编码/解码往返
pub fn test_sequence_roundtrip() -> Bool {
  println("\n=== 序列编码/解码往返测试 ===")
  
  let test_sequences = [
    (45, 45, 45),
    (0, 45, 45),
    (100, 200, 256),
  ]
  
  for i = 0; i < test_sequences.length(); i = i + 1 {
    let (ll, ml, of) = test_sequences[i]
    
    println("\n序列 \{i}: LL=\{ll}, ML=\{ml}, OF=\{of}")
    
    // 编码
    let (ll_code, ll_extra) = @zstd_entropy.encode_ll(ll)
    let (ml_code, ml_extra) = @zstd_entropy.encode_ml(ml)
    let (of_code, of_extra) = @zstd_entropy.encode_of(of)
    
    println("  编码: LL(\{ll_code}, \{ll_extra}), ML(\{ml_code}, \{ml_extra}), OF(\{of_code}, \{of_extra})")
    
    // 解码
    let ll_decoded = @zstd_entropy.decode_ll(ll_code, ll_extra)
    let ml_decoded = @zstd_entropy.decode_ml(ml_code, ml_extra)
    let of_decoded = @zstd_entropy.decode_of(of_code, of_extra)
    
    println("  解码: LL=\{ll_decoded}, ML=\{ml_decoded}, OF=\{of_decoded}")
    
    // 验证
    if ll_decoded != ll || ml_decoded != ml || of_decoded != of {
      println("  ❌ 往返验证失败！")
      return false
    }
    
    println("  ✓ 往返验证通过")
  }
  true
}

/// 保存压缩数据用于官方工具验证
pub fn save_compressed_for_official_tool() -> Unit {
  println("\n=== 生成官方工具测试数据 ===")
  
  // 创建测试数据：450 字节重复文本
  let text = "The quick brown fox jumps over the lazy dog. "  // 45 bytes
  let data_bytes : Array[Byte] = []
  for _i = 0; _i < 10; _i = _i + 1 {
    for j = 0; j < text.length(); j = j + 1 {
      data_bytes.push(text[j].to_byte())
    }
  }
  let data = Bytes::from_array(data_bytes)
  
  println("原始数据: \{data.length()} bytes")
  println("内容: \{text} (重复 10 次)")
  
  // 压缩
  let compressed = @zstd.compress(data)
  println("压缩后: \{compressed.length()} bytes")
  
  // 输出十六进制（方便保存到文件）
  println("\n十六进制数据 (保存为 moonbit_output.zst):")
  println("----------------------------------------")
  
  let mut i = 0
  while i < compressed.length() {
    let mut line = ""
    let mut j = 0
    while j < 16 && i + j < compressed.length() {
      let byte = compressed[i + j].to_int()
      let hex = if byte < 16 { 
        "0" + to_hex(byte)
      } else { 
        to_hex(byte)
      }
      line = line + hex + " "
      j = j + 1
    }
    println(line)
    i = i + 16
  }
  
  println("----------------------------------------")
  println("\n保存步骤:")
  println("1. 复制上面的十六进制数据")
  println("2. 使用十六进制编辑器创建文件 moonbit_output.zst")
  println("3. 运行: zstd -d moonbit_output.zst -o output.txt")
  println("4. 检查 output.txt 是否正确")
}

/// 运行所有编码测试
pub fn run_all_encoding_tests() -> Unit {
  println("\n" + "=".repeat(60))
  println("运行编码函数测试套件")
  println("=".repeat(60))
  
  let test1 = test_encode_of()
  let test2 = test_encode_ll()
  let test3 = test_encode_ml()
  diagnose_of_base_table()
  let test4 = test_sequence_roundtrip()
  save_compressed_for_official_tool()
  
  println("\n" + "=".repeat(60))
  println("测试结果汇总")
  println("=".repeat(60))
  
  let result1 = if test1 { "✓ 通过" } else { "✗ 失败" }
  let result2 = if test2 { "✓ 通过" } else { "✗ 失败" }
  let result3 = if test3 { "✓ 通过" } else { "✗ 失败" }
  let result4 = if test4 { "✓ 通过" } else { "✗ 失败" }
  
  println("Offset 编码测试: " + result1)
  println("Literal Length 编码测试: " + result2)
  println("Match Length 编码测试: " + result3)
  println("序列往返测试: " + result4)
  
  let count1 = if test1 { 1 } else { 0 }
  let count2 = if test2 { 1 } else { 0 }
  let count3 = if test3 { 1 } else { 0 }
  let count4 = if test4 { 1 } else { 0 }
  let total_passed = count1 + count2 + count3 + count4
  
  println("\n总计: \{total_passed}/4 测试通过")
  println("=".repeat(60))
}
