# MoonBit ZSTD

基于 `MoonBit` 实现的 `Zstandard (ZSTD)` 压缩库，目标对齐 `RFC 8878`。

## 概述

- 纯 `MoonBit` 实现，不依赖 C 库。
- 支持压缩、解压、文件结构分析、字典压缩与基础基准测试。
- 支持最小可用的流式压缩生命周期：`create / write / flush / finish / reset`。
- 覆盖 `Raw`、`RLE`、`Compressed` 三类块。
- 包含 FSE、Huffman、序列表和滑动窗口等核心实现。

## 快速开始

```powershell
moon run src/cmd
```

说明：该命令会运行当前仓库里的演示与测试入口。

## 文档入口

- 协作索引：`AGENTS.md`
- 代码规范：`CODE-TYPE.md`
- 源码总索引：`src/RESOURCE.md`
- API 说明：`src/api/RESOURCE.md`
- Core 说明：`src/core/RESOURCE.md`
- Encoder 说明：`src/encoder/RESOURCE.md`
- Decoder 说明：`src/decoder/RESOURCE.md`
- Entropy 说明：`src/entropy/RESOURCE.md`
- Dictionary 说明：`src/dictionary/RESOURCE.md`

## 主要能力

### 压缩

- 默认压缩入口：`@zstd.compress`
- 数值级别压缩：`@zstd.compress_with_level_int`
- 枚举级别压缩：`@zstd.compress_with_level`
- 显式方法压缩：`@zstd.compress_advanced`
- 最小流式压缩接口：`@zstd.create_streaming_compressor`、`@zstd.write_streaming_chunk`、`@zstd.finish_streaming_compressor`
- 流式统计接口：`@zstd.get_streaming_compressor_stats`、`@zstd.format_streaming_compressor_stats`
- 指定块策略：`Raw` / `RLE` / `Compressed`
- 多块压缩
- 可选内容校验和
- 带字典压缩

### 解压

- 高层解压入口：`@zstd.decompress`
- 底层 `Result` 风格解压：`@zstd_decoder.decompress` / `decompress_with_limit`
- 拼接帧解压
- 带字典解压
- 滑动窗口支持

### 分析

- `@zstd.analyze_file`：轻量结构分析
- `@zstd.is_zstd_format`：魔数快速判断
- `@zstd.analyze_data_integrity`：启发式完整性分析
- `@zstd.estimate_compressed_size`：粗略压缩估算

### 字典

- 原始字典与 ZSTD 格式字典解析
- Cover 算法构建字典
- 字典收益统计

## 基本用法

### 1. 压缩与解压

```moonbit
let original = @encoding/utf8.encode("Hello, ZSTD!")

match @zstd.compress(original) {
  Ok(compressed) => {
    let decompressed = @zstd.decompress(compressed)
    println("compressed size = \{compressed.length()}")
    println("decompressed size = \{decompressed.length()}")
  }
  Err(e) => println("compression failed: \{e}")
}
```

### 2. 指定压缩级别

```moonbit
let compressed = @zstd.compress_with_level_int(data, 9)

let compressed2 = @zstd.compress_with_level(
  data,
  CompressionLevel::Better,
)
```

当前 `CompressionLevel` 映射：

- `Fast -> 1`
- `Default -> 3`
- `Better -> 6`
- `Best -> 9`

### 3. 指定压缩方法

```moonbit
let compressed = @zstd.compress_advanced(data, CompressionMethod::Compressed, 5)
```

可选方法：

- `Auto`
- `Raw`
- `RLE`
- `Compressed`

### 3.1 流式压缩

```moonbit
let compressor = @zstd.create_streaming_compressor(3)
let part1 = @zstd.write_streaming_chunk(compressor, chunk1)?
let part2 = @zstd.write_streaming_chunk(compressor, chunk2)?
let tail = @zstd.finish_streaming_compressor(compressor)?

let compressed = part1 + part2 + tail
```

说明：

- 当前是最小可用版流式压缩器。
- 支持 `write / flush / finish / reset` 生命周期。
- 支持基于同帧历史窗口的跨 chunk LZ77 继承。
- 当前流式路径维持 `64KB` 自动落块粒度。
- 当单序列直写超出当前变长编码上限时，会自动拆成多序列再走预定义 FSE。
- 当前历史复用优先走“安全前缀复用 + 单序列直写”路径，不是完整通用增量 LZ77 解析器。

### 3.2 流式统计

```moonbit
let stats = @zstd.get_streaming_compressor_stats(compressor)
println(@zstd.format_streaming_compressor_stats(stats))
```

### 4. 文件结构分析

```moonbit
let analysis = @zstd.analyze_file(data)
println("valid = \{analysis.is_valid}")
println("blocks = \{analysis.total_blocks}")
println("first block type = \{analysis.first_block_type}")
```

### 5. 字典压缩

```moonbit
let dict = @zstd_dictionary.create_raw_dictionary(dict_bytes, 0x12345678U)

match @zstd_dictionary.compress_with_dictionary(data, dict) {
  Ok(compressed) => {
    match @zstd_dictionary.decompress_with_dictionary(compressed, dict) {
      Ok(restored) => println("ok: \{restored.length()}")
      Err(e) => println("decompress failed: \{e}")
    }
  }
  Err(e) => println("compress failed: \{e}")
}
```

## 关键实现口径

- 最大块大小：`131072` 字节
- 高层解压全局输出限制：`128MB`
- `compression_ratio` 统一按 `original_size / compressed_size` 理解，值越大越好，展示为 `x`
- `DataIntegrityAnalysis` 当前是启发式分析结果，不是严格统计模型
- 校验和实现当前为简化版 `XXH32-like`，不是完整官方 `XXH32`
- 流式压缩帧当前使用非 `single_segment` 头部，不预写 `Frame_Content_Size`
- 流式压缩器当前按 `64KB` 粒度自动落块，并暴露输入/输出、块类型分布、checksum、history/pending 统计

## 项目结构

```text
src/
├── api/          # 对外高层 API
├── core/         # 核心类型、错误、常量、bitstream
├── encoder/      # 压缩主实现
├── decoder/      # 解压主实现、帧头解析、分析器
├── entropy/      # FSE / Huffman / 序列表
├── dictionary/   # 字典构建、字典收益、字典格式
├── cmd/          # 演示与测试总入口
├── examples/     # 示例
├── test/         # 测试套件
├── benchmark/    # 基准测试
└── test-data/    # 金标样本与错误样本
```

## 当前源码入口

- 对外 API：`src/api/zstd.mbt`
- 压缩主实现：`src/encoder/compressor.mbt`
- 解压主实现：`src/decoder/decompressor.mbt`
- 帧头解析：`src/decoder/frame.mbt`
- 文件分析：`src/decoder/analyzer.mbt`
- 序列表：`src/entropy/sequence_tables.mbt`

## 常用检查命令

```powershell
moon run src/cmd
rg --files src
rg "^pub (struct|enum|type|fn)" src
rg "CompressionConfig|ZSTDFileAnalysis|DictionaryBenefitStats" src
```

## 注意事项

- 以 `src/` 下源码与 `RESOURCE.md` 为准，不以旧文档片段为准。
- `@zstd.decompress` 是高层便捷接口，失败时返回空字节串；如果要拿到错误，使用 decoder 层 `Result` 风格接口。
- 当前仓库文档已按模块拆分，新增类型、字段、公式或统计结果时，应同步更新对应 `RESOURCE.md`。

## License

`Apache-2.0`
