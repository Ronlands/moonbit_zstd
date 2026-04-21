# ZSTD 流式与分块 API 说明

## 概述

当前仓库已经具备以下与“流式/大数据处理”相关的能力：

- 一次性压缩与解压
- 大于 `128KB` 数据时自动多块压缩
- 拼接帧解压
- 带全局输出上限的安全解压
- 基于滑动窗口上下文的解压辅助接口
- 最小可用的流式压缩器对象
- 带字典压缩与解压

当前仓库已经提供最小可用的流式压缩生命周期接口，但仍然不是“完整高优化增量式压缩框架”。

因此，本文件以“当前真实存在的分块、滑窗和流式帧写出能力”为准。

## 流式压缩生命周期

当前高层 API 已支持：

- `@zstd.create_streaming_compressor(level)`
- `@zstd.create_streaming_compressor_with_checksum(level, with_checksum)`
- `@zstd.write_streaming_chunk(compressor, chunk)`
- `@zstd.flush_streaming_compressor(compressor)`
- `@zstd.finish_streaming_compressor(compressor)`
- `@zstd.reset_streaming_compressor(compressor)`

### 基本示例

```moonbit
let compressor = @zstd.create_streaming_compressor(3)

let out1 = @zstd.write_streaming_chunk(compressor, chunk1)?
let out2 = @zstd.write_streaming_chunk(compressor, chunk2)?
let flushed = @zstd.flush_streaming_compressor(compressor)?
let tail = @zstd.finish_streaming_compressor(compressor)?

let compressed = out1 + out2 + flushed + tail
```

### 当前实现特征

- 首次写入时输出帧头
- 写入过程中会在内部缓存达到 `128KB` 时自动落块
- `flush` 会强制把当前 pending 数据写成非最后块
- `finish` 会写出最后块并在需要时追加 checksum
- 返回值始终是“本次新增产出的字节”，适合顺序拼接或直接发送
- 可通过统计接口读取输入/输出大小、块分布、history/pending 和 checksum 状态
- 历史复用当前通过“预加载历史窗口 + 当前块持续建哈希”的方式生成真正的增量 LZ77 序列
- 当一序列块超出旧直写表示力时，编码侧会自动改走标准序列段格式

### 当前限制

- 当前仍未实现完整通用的网络流 / 背压抽象
- 当前仍保留旧的一序列直写解码兼容路径，但编码侧的大值一序列会优先使用标准序列段格式
- 当前没有异步 IO、网络流抽象或背压控制

### 统计接口

- `@zstd.get_streaming_compressor_stats(compressor)`
- `@zstd.format_streaming_compressor_stats(stats)`

统计字段包括：

- 输入字节数
- 输出字节数
- 已发块总数
- `raw / rle / compressed` 块分布
- `flush / auto_flush` 次数
- `pending / history` 大小
- 当前 checksum 与最终 checksum
- 是否已写帧头、是否已完成

## 一次性 API

### 压缩

```moonbit
match @zstd.compress(data) {
  Ok(compressed) => println("ok: \{compressed.length()}")
  Err(e) => println("compress failed: \{e}")
}
```

可选接口：

- `@zstd.compress`
- `@zstd.compress_with_level_int`
- `@zstd.compress_with_level`
- `@zstd.compress_advanced`

### 解压

```moonbit
let restored = @zstd.decompress(compressed)
```

说明：

- `@zstd.decompress` 是高层便捷接口。
- 失败时返回空 `Bytes`，不直接暴露错误。
- 如果需要拿到错误，请使用 decoder 层 `Result` 风格接口。

## 大数据与多块压缩

编码器会在数据超过最大块大小时自动切分为多个块。

- 最大块大小：`131072` 字节，即 `128KB`
- 对超大输入会自动走多块压缩路径

示例：

```moonbit
let large_data = Bytes::make(1024 * 1024, 0x42)
match @zstd.compress(large_data) {
  Ok(compressed) => println("compressed size = \{compressed.length()}")
  Err(e) => println("compress failed: \{e}")
}
```

说明：

- 不需要手工按 `128KB` 切块，默认压缩器会自动切分。
- 每个块会在 `RLE / Compressed / Raw` 路径间选择或回退。

## 带配置压缩

如果需要显式控制压缩参数，可直接使用 encoder 层接口。

```moonbit
let config = @zstd_encoder.create_config_with_level(5)
match @zstd_encoder.compress_data(data, config) {
  Ok(compressed) => println("ok: \{compressed.length()}")
  Err(e) => println("compress failed: \{e}")
}
```

常用配置函数：

- `@zstd_encoder.create_default_config()`
- `@zstd_encoder.create_config_with_level(level)`
- `@zstd_encoder.create_compression_context(config)`

当前级别范围：`1..22`

典型映射：

- `1-2`：更快
- `3-5`：默认与平衡
- `6-9`：更高压缩率
- `10-22`：更深搜索，更偏向压缩率

更细的 `window_log / min_match / search_depth` 对应关系见：`src/encoder/RESOURCE.md`

## 带校验和压缩

encoder 层提供可选内容校验和写出接口。

```moonbit
let config = @zstd_encoder.create_default_config()
match @zstd_encoder.compress_data_with_checksum(data, config, true) {
  Ok(compressed) => println("ok: \{compressed.length()}")
  Err(e) => println("compress failed: \{e}")
}
```

注意：

- 当前 checksum 实现是简化版 `XXH32-like`。
- 不应在对外文档中宣称其为完整官方 `XXH32`。

## 安全解压与拼接帧

decoder 层提供带错误返回和带输出上限的解压接口。

```moonbit
match @zstd_decoder.decompress(data) {
  Ok(restored) => println("ok: \{restored.length()}")
  Err(e) => println("decompress failed: \{e}")
}
```

```moonbit
let max_output = 128 * 1024 * 1024
match @zstd_decoder.decompress_with_limit(data, max_output) {
  Ok(restored) => println("ok: \{restored.length()}")
  Err(e) => println("decompress failed: \{e}")
}
```

说明：

- `@zstd_decoder.decompress` 支持拼接帧解压。
- `@zstd_decoder.decompress_with_limit` 可限制累计输出大小。
- 高层 `@zstd.decompress` 内部也使用了 `128MB` 全局输出限制。

## 滑动窗口解压辅助接口

当前仓库对“流式解压”最接近的公开接口是 `SlidingWindowDecoder`。

### 创建滑窗解码器

```moonbit
let decoder = @zstd.create_sliding_window_decoder(65536)
```

### 使用滑窗解压

```moonbit
match @zstd.decompress_with_sliding_window(decoder, compressed_frame) {
  Ok(chunk) => println("decoded = \{chunk.length()}")
  Err(e) => println("decode failed: \{e}")
}
```

### 重置滑窗状态

```moonbit
@zstd.reset_sliding_window_decoder(decoder)
```

说明：

- `SlidingWindowDecoder` 内部持有 `DecoderContext`。
- `decompress_with_sliding_window` 会更新上下文，允许历史窗口跨调用保留。
- 当前实现仍要求传入的是合法 ZSTD 帧数据。
- 这更接近“带状态的解压辅助接口”，还不是完整的网络流增量解压框架。

## 字典压缩与解压

### 创建原始字典

```moonbit
let dict = @zstd_dictionary.create_raw_dictionary(dict_bytes, 0x12345678U)
```

### 解析 ZSTD 格式字典

```moonbit
match @zstd_dictionary.parse_zstd_dictionary(dict_file_bytes) {
  Ok(dict) => println("dict id = \{dict.dict_id}")
  Err(e) => println("parse failed: \{e}")
}
```

### 带字典压缩

```moonbit
match @zstd_dictionary.compress_with_dictionary(data, dict) {
  Ok(compressed) => println("ok: \{compressed.length()}")
  Err(e) => println("compress failed: \{e}")
}
```

### 带字典解压

```moonbit
match @zstd_dictionary.decompress_with_dictionary(compressed, dict) {
  Ok(restored) => println("ok: \{restored.length()}")
  Err(e) => println("decompress failed: \{e}")
}
```

### 构建字典

```moonbit
match @zstd_dictionary.build_dictionary_with_cover(samples, 8192, 6) {
  Ok(dict) => println("dict size = \{dict.content.length()}")
  Err(e) => println("build failed: \{e}")
}
```

说明：

- `build_dictionary_with_cover` 的 `ngram_size` 会被约束到 `[4, 16]`
- 字典 ID 会避开保留区，详细规则见 `src/dictionary/RESOURCE.md`

## 分析与估算接口

### 文件结构分析

```moonbit
let analysis = @zstd.analyze_file(compressed)
println("valid = \{analysis.is_valid}")
println("window = \{analysis.window_size}")
println("first block = \{analysis.first_block_type}")
```

### 完整性启发式分析

```moonbit
let integrity = @zstd.analyze_data_integrity(data)
println("density = \{integrity.data_density}")
println("entropy = \{integrity.entropy_level}")
```

### 压缩大小估算

```moonbit
let estimated = @zstd.estimate_compressed_size(data, CompressionLevel::Better)
println("estimated = \{estimated}")
```

注意：

- `analyze_data_integrity` 当前是启发式结果，不是严格统计模型。
- `estimate_compressed_size` 是粗略估算，不是实际压缩输出。

## 性能与内存口径

- 最大块大小：`128KB`
- 高层解压全局输出限制：`128MB`
- 窗口大小由帧头或配置决定
- `CompressionConfig.window_log` 满足：`window_size = 1 << window_log`
- 流式压缩器当前内部自动落块大小：`128KB`

## 当前限制

### 已支持

- 一次性压缩 / 解压
- 多块压缩
- 拼接帧解压
- 最小流式压缩生命周期
- 流式统计快照与 checksum 输出
- 带状态滑窗解压辅助
- 带字典压缩 / 解压

### 暂未提供统一高层接口

- 跨 chunk 的完整通用 LZ77 增量解析器
- 正式的异步或网络流抽象

## 推荐阅读

- `AGENTS.md`
- `CODE-TYPE.md`
- `src/api/RESOURCE.md`
- `src/encoder/RESOURCE.md`
- `src/decoder/RESOURCE.md`
- `src/dictionary/RESOURCE.md`

## 常用检查命令

```powershell
moon run src/cmd
rg "create_sliding_window_decoder|decompress_with_sliding_window|compress_data_with_checksum" src
rg "compress_with_dictionary|decompress_with_dictionary|build_dictionary_with_cover" src
```
