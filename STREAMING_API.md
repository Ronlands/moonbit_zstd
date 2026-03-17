# ZSTD 流式 API 文档

## 概述

moonbit_zstd 提供了高效的流式压缩和解压缩 API，适用于处理大文件和网络流。

## 基本用法

### 一次性压缩/解压缩

```moonbit
// 压缩
let data = b"Hello, ZSTD!"
let compressed = @zstd.compress(data)?
println("压缩率: \{data.length()}/\{compressed.length()}")

// 解压缩
let decompressed = @zstd.decompress(compressed)?
```

### 多块压缩（大数据）

对于超过 128KB 的数据，编码器自动使用多块模式：

```moonbit
let large_data = Bytes::make(1024 * 1024, 0x42)  // 1MB
let compressed = @zstd.compress(large_data)?
// 自动分割为多个 128KB 块
```

## 压缩配置

### 压缩级别

```moonbit
let config = @compressor.create_config_with_level(5)
let ctx = @compressor.create_compression_context(config)
let compressed = @compressor.compress_data(data, config)?
```

压缩级别范围：1-22
- 1-3: 快速（默认 3）
- 4-9: 平衡
- 10-18: 高压缩率
- 19-22: 最大压缩率

### 带校验和压缩

```moonbit
let compressed = @compressor.compress_data_with_checksum(data, config, true)?
```

## 字典压缩

### 使用预训练字典

```moonbit
// 创建字典
let dict_data = b"common patterns..."
let dict = @dictionary.create_dictionary(dict_data, 0x12345678U)?

// 压缩
let compressed = @compressor.compress_with_dictionary(data, config, dict)?

// 解压缩
let decompressed = @decompressor.decompress_with_dictionary(compressed, dict)?
```

## 错误处理

```moonbit
match @zstd.compress(data) {
  Ok(compressed) => println("成功: \{compressed.length()} 字节")
  Err(e) => println("错误: \{e}")
}
```

常见错误：
- "Invalid magic number": 不是有效的 ZSTD 数据
- "Truncated frame": 数据不完整
- "Dictionary mismatch": 字典 ID 不匹配

## 性能特性

### 内存使用

- 压缩器：~256KB（哈希表 + 缓冲区）
- 解压缩器：~128KB（窗口缓冲区）
- 字典：额外 64KB-128KB

### 块大小

- 默认块大小：128KB
- 最大块大小：128KB（RFC 8878 推荐）
- 小数据（<128KB）：单块压缩

## 高级用法

### 分析压缩数据

```moonbit
let info = @analyzer.analyze_frame(compressed)?
println("块数: \{info.num_blocks}")
println("原始大小: \{info.decompressed_size}")
```

### 自定义窗口大小

```moonbit
let config = @compressor.CompressionConfig::{
  level: 5,
  window_log: 18,  // 256KB 窗口
  min_match: 4,
  search_depth: 24
}
```

## 最佳实践

1. **选择合适的压缩级别**
   - 实时应用：级别 1-3
   - 存储：级别 5-9
   - 归档：级别 10+

2. **使用字典压缩小数据**
   - 对于 <1KB 的重复数据，字典可提升 2-5 倍压缩率

3. **批量处理**
   - 累积小数据到 128KB 再压缩，减少开销

4. **错误恢复**
   - 始终检查 Result 类型
   - 对损坏数据使用 try-catch

## 示例：文件压缩

```moonbit
fn compress_file(input_path: String, output_path: String) -> Result[Unit, String] {
  // 读取文件（实际应用中使用流式读取）
  let data = read_file(input_path)?

  // 压缩
  let config = @compressor.create_default_config()
  let compressed = @compressor.compress_data(data, config)?

  // 写入
  write_file(output_path, compressed)?
  Ok(())
}
```

## 示例：网络流

```moonbit
fn compress_stream(input_stream: Stream) -> Result[Stream, String] {
  let buffer = Buffer::new()
  let config = @compressor.create_default_config()

  while input_stream.has_data() {
    let chunk = input_stream.read(128 * 1024)?  // 128KB 块
    let compressed = @compressor.compress_data(chunk, config)?
    buffer.write(compressed)?
  }

  Ok(buffer.to_stream())
}
```

## 兼容性

- 完全兼容 RFC 8878 标准
- 可解压 zstd v1.5.6 生成的数据
- 生成的数据可被官方 zstd 工具解压

## 限制

- 最大帧大小：受内存限制
- 不支持 Skippable Frames（可通过 analyzer 检测）
- 字典大小：建议 <128KB

## 常见问题

### Q: 如何选择压缩级别？
A: 级别 1-3 适合实时应用，5-9 适合存储，10+ 适合归档。

### Q: 为什么压缩后反而变大？
A: 小数据或高熵数据可能无法压缩。使用字典或累积到更大块。

### Q: 如何处理大文件？
A: 使用 128KB 块分段压缩，自动处理多块模式。

### Q: 字典何时有用？
A: 对于 <1KB 的重复小数据，字典可提升 2-5 倍压缩率。

## 性能优化建议

1. **批量处理**: 累积小数据到 128KB 再压缩
2. **选择合适级别**: 不要盲目使用最高级别
3. **复用配置**: 创建一次配置对象，多次使用
4. **预分配缓冲区**: 减少内存分配开销

## 实际使用示例

### 文件压缩

```moonbit
fn compress_file(input: String, output: String) -> Result[Unit, String] {
  let data = read_file(input)?
  let config = @compressor.create_config_with_level(5)
  let compressed = @compressor.compress_data(data, config)?
  write_file(output, compressed)?
  Ok(())
}
```

### 网络流压缩

```moonbit
fn compress_network_stream(stream: NetworkStream) -> Result[Bytes, String] {
  let buffer: Array[Byte] = []
  let config = @compressor.create_default_config()

  while stream.available() {
    let chunk = stream.read(128 * 1024)?
    let compressed = @compressor.compress_data(chunk, config)?
    for i = 0; i < compressed.length(); i = i + 1 {
      buffer.push(compressed[i])
    }
  }

  Ok(Bytes::from_array(buffer))
}
```

### 错误处理最佳实践

```moonbit
fn safe_compress(data: Bytes) -> Result[Bytes, String] {
  // 验证输入
  if data.length() == 0 {
    return Err("Empty data")
  }

  // 压缩
  let config = @compressor.create_default_config()
  match @compressor.compress_data(data, config) {
    Ok(compressed) => {
      // 验证输出
      match @decompressor.decompress_data(compressed) {
        Ok(decompressed) => {
          if decompressed.length() == data.length() {
            Ok(compressed)
          } else {
            Err("Decompression size mismatch")
          }
        }
        Err(e) => Err("Verification failed: \{e}")
      }
    }
    Err(e) => Err("Compression failed: \{e}")
  }
}
```
