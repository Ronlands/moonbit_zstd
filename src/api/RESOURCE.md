# API 模块资源

## 1. 模块定位

- 路径：`src/api`
- 主文件：`src/api/zstd.mbt`
- 职责：对外暴露高层压缩、解压、格式分析、完整性分析与压缩估算接口。

## 2. 核心类型索引

- `CompressionLevel`
- `CompressionMethod`
- `StreamingCompressor`
- `StreamingCompressionStats`
- `ZSTDFileAnalysis`
- `DataIntegrityAnalysis`
- `SlidingWindowDecoder`

## 3. 类型与字段说明

### 3.1 `CompressionLevel`

- 取值：`Fast`、`Default`、`Better`、`Best`
- 映射关系：
  - `Fast -> 1`
  - `Default -> 3`
  - `Better -> 6`
  - `Best -> 9`
- 用途：对外暴露有限档位，内部再映射到数值级别。

### 3.2 `CompressionMethod`

- 取值：`Auto`、`Raw`、`RLE`、`Compressed`
- 用途：指定块生成策略。
- 说明：
  - `Auto` 会先做轻量判断，再交给编码器在 `RLE / Compressed / Raw` 路径间选择或回退。
  - `Compressed` 表示进入 LZ77 + 熵编码路径。

### 3.3 `ZSTDFileAnalysis`

- 语义：对压缩数据做轻量结构分析，不执行完整解压。
- 字段：
  - `is_valid`：结构是否通过当前分析器校验。
  - `error_message`：失败时的错误描述。
  - `magic_number`：魔数，`UInt`。
  - `single_segment`：是否单段帧。
  - `content_checksum`：是否包含内容校验和标记。
  - `window_size`：窗口大小，单位字节。
  - `total_blocks`：当前分析出的块数。
  - `file_size`：输入大小，单位字节。
  - `first_block_type`：首块类型字符串。
  - `first_block_size`：首块大小，单位字节。
  - `last_block`：首块是否已标记为最后一块。
- 来源：`analyze_file` / `analyze_file_detailed`。
- 用法：用于快速判断数据是否像合法 ZSTD 帧，以及提取头部摘要。
- 注意：这是轻量分析结果，不等价于完整解码结果。

### 3.4 `StreamingCompressor`

- 语义：API 层对 encoder 流式压缩状态的包装对象。
- 字段：
  - `context`：底层 `@zstd_encoder.StreamingCompressor`
- 生命周期接口：
  - `create_streaming_compressor`
  - `create_streaming_compressor_with_checksum`
  - `write_streaming_chunk`
  - `flush_streaming_compressor`
  - `finish_streaming_compressor`
  - `reset_streaming_compressor`
  - `get_streaming_compressor_stats`
  - `format_streaming_compressor_stats`
- 返回口径：
  - `write / flush / finish` 的返回值都只包含“本次新增产出的字节”
  - 调用方需要按顺序拼接这些返回值，构成最终完整压缩帧
 - 当前实现口径：
  - 支持基于同帧历史窗口的跨 chunk LZ77 继承
  - 使用 `64KB` 内部自动落块粒度
  - 当单序列直写超限时，会自动拆成多序列后再编码
  - 历史复用优先走“安全前缀复用 + 单序列直写”

### 3.5 `StreamingCompressionStats`

- 字段：
  - `total_input_size`
  - `total_output_size`
  - `emitted_block_count`
  - `raw_block_count`
  - `rle_block_count`
  - `compressed_block_count`
  - `flush_count`
  - `auto_flush_count`
  - `pending_size`
  - `history_size`
  - `window_size`
  - `checksum_enabled`
  - `current_checksum`
  - `final_checksum`
  - `header_written`
  - `finished`
- 用途：流式压缩运行态快照。
- 统计口径：
  - `total_input_size`：累计写入字节数
  - `total_output_size`：累计已返回给调用方的压缩字节数
  - `emitted_block_count`：已写出的块总数
  - `raw / rle / compressed_block_count`：按块类型拆分的块数
  - `flush_count`：显式 `flush` 次数
  - `auto_flush_count`：因内部达到自动落块粒度而触发的次数
  - `pending_size`：当前待处理但尚未写出的输入字节数
  - `history_size`：当前保存在历史窗口中的可复用字节数
  - `current_checksum`：当前累计 checksum
  - `final_checksum`：`finish` 后写出的最终 checksum，未完成时通常为 `0`

### 3.6 `DataIntegrityAnalysis`

- 语义：对输入数据给出启发式完整性指标。
- 字段：
  - `truncation_indicators`：截断迹象数量。
  - `data_density`：数据密度，`Double`。
  - `structure_consistency`：结构一致性，`Double`。
  - `entropy_level`：熵级别，`Double`。
- 当前实现口径：
  - `data_density`：空数据返回 `0.0`，否则固定 `0.8`
  - `structure_consistency`：长度大于等于 4 返回 `0.9`，否则 `0.1`
  - `entropy_level`：固定 `0.7`
  - `truncation_indicators`：长度小于 10 返回 `1`，否则 `0`
- 结论：该对象当前属于启发式演示结果，不是严格统计模型，不能作为协议级真值使用。

### 3.7 `SlidingWindowDecoder`

- 字段：
  - `context`：底层 `@zstd_decoder.DecoderContext`
  - `window_size`：窗口大小，单位字节
- 用途：流式解压上下文承载对象。

## 4. 公开方法口径

- `compress`：默认压缩入口。
- `compress_with_level_int(data, level)`：数值级别压缩，`level` 会被约束到 `[1, 22]`，但当前实现中低于 1 的输入会落到 `2`。
- `compress_with_level(data, level_enum)`：使用枚举档位压缩。
- `compress_advanced(data, mode, level)`：显式指定方法和级别。
- `create_streaming_compressor(level)`：创建最小可用流式压缩器。
- `create_streaming_compressor_with_checksum(level, with_checksum)`：创建可选 checksum 的流式压缩器。
- `write_streaming_chunk(streamer, chunk)`：写入 chunk 并返回新增输出。
- `flush_streaming_compressor(streamer)`：强制把当前 pending 数据落块。
- `finish_streaming_compressor(streamer)`：结束帧并返回最后输出。
- `reset_streaming_compressor(streamer)`：重置内部状态。
- `decompress`：高层解压入口，失败时返回空字节串，不向外传播 `Result`。
- `analyze_file`：文件结构分析。
- `analyze_data_integrity`：启发式完整性分析。
- `estimate_compressed_size`：压缩结果估算。

## 5. 公式与统计口径

### 5.1 压缩结果估算

- 方法：`estimate_compressed_size`
- 统一口径：估算值，不是实际压缩结果。
- 公式：
  - `Fast = 原始长度 + 9`
  - `Default = 原始长度 * 80% + 9`
  - `Better = 原始长度 * 60% + 9`
  - `Best = 原始长度 * 40% + 9`
- `9` 表示粗略协议开销。

### 5.2 RLE 自动选择阈值

- 条件：首字节连续占比大于 `0.75`
- 用途：`Auto` 模式下判断是否走 `RLE`。

## 6. 注意事项

- 本模块里“分析”与“压缩/解压 API”混合在同一文件，阅读时注意区分职责。
- 文档和评审中要明确：`decompress` 返回空字节不等于“真实解压结果为空”，也可能是失败兜底。
- 当前流式压缩是最小可用版，主要解决“边写边产出合法帧”的能力，不等同于高优化增量压缩器。
- 当前流式压缩已经支持跨 chunk 历史继承，但仍是保守实现，目标优先是正确性和可观测性。
