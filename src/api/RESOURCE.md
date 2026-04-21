# API 模块资源

## 1. 模块定位

- 路径：`src/api`
- 主文件：`src/api/zstd.mbt`
- 职责：对外暴露高层压缩、解压、格式分析、完整性分析与压缩估算接口。

## 2. 核心类型索引

- `CompressionLevel`
- `CompressionMethod`
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

### 3.4 `DataIntegrityAnalysis`

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

### 3.5 `SlidingWindowDecoder`

- 字段：
  - `context`：底层 `@zstd_decoder.DecoderContext`
  - `window_size`：窗口大小，单位字节
- 用途：流式解压上下文承载对象。

## 4. 公开方法口径

- `compress`：默认压缩入口。
- `compress_with_level_int(data, level)`：数值级别压缩，`level` 会被约束到 `[1, 22]`，但当前实现中低于 1 的输入会落到 `2`。
- `compress_with_level(data, level_enum)`：使用枚举档位压缩。
- `compress_advanced(data, mode, level)`：显式指定方法和级别。
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
