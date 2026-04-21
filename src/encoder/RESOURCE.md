# Encoder 模块资源

## 1. 模块定位

- 路径：`src/encoder`
- 主文件：`src/encoder/compressor.mbt`
- 职责：压缩配置、LZ77 匹配、帧头/块头写出、带字典压缩。

## 2. 核心类型索引

- `Compressor`
- `LZSequence`（私有）
- `CompressionConfig`
- `CompressionContext`
- `StreamingCompressor`
- `StreamingCompressionStats`

## 3. 类型与字段说明

### 3.1 `Compressor`

- 字段：
  - `level`：压缩级别
  - `hash_table`：LZ77 匹配哈希表
  - `window_size`：窗口大小，单位字节

### 3.2 `CompressionConfig`

- 字段：
  - `level`：压缩级别，范围 `1..22`
  - `window_log`：窗口指数，窗口大小为 `2 ^ window_log`
  - `min_match`：最小匹配长度，单位字节
  - `search_depth`：搜索深度，越大通常压缩率更高但更慢
- 用途：统一描述压缩强度与 LZ77 搜索参数。

### 3.2.1 `LZSequence`（私有）

- 字段：
  - `literal_length`
  - `match_length`
  - `offset`
- 说明：
  - 这是 encoder 内部使用的私有序列对象。
  - 本次已从原先同名的 `Sequence` 重命名为 `LZSequence`，用于避免与 `core.Sequence` / `entropy.Sequence` 产生同名漂移。

### 3.3 `CompressionContext`

- 字段：
  - `config`
- 用途：封装压缩配置，便于后续扩展上下文。

### 3.4 `StreamingCompressor`

- 字段：
  - `config`
  - `with_checksum`
  - `pending`
  - `history_window`
  - `header_written`
  - `finished`
  - `total_input_size`
  - `total_output_size`
  - `emitted_block_count`
  - `raw_block_count`
  - `rle_block_count`
  - `compressed_block_count`
  - `flush_count`
  - `auto_flush_count`
  - `checksum_state`
  - `final_checksum`
- 用途：最小可用的流式压缩状态机。
- 生命周期：
  - `new_streaming_compressor`
  - `write_streaming_chunk`
  - `flush_streaming_compressor`
  - `finish_streaming_compressor`
  - `reset_streaming_compressor`
- 当前语义：
  - 支持边写边产出完整 ZSTD 帧字节流
  - 不预写 `Frame_Content_Size`
  - 支持基于同帧历史窗口的跨 chunk LZ77 继承
  - 历史复用使用“安全前缀复用 + 单序列直写”保守策略
  - 内部自动落块粒度当前为 `64KB`
  - 当单序列直写超出当前编码能力时，会自动拆成多序列再走预定义 FSE

### 3.5 `StreamingCompressionStats`

- 语义：流式压缩运行态快照。
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

## 4. 关键常量

- `hash_table_size = 65536`
- `max_block_size = 131072`
- `fcs_threshold_1byte = 256`
- `fcs_threshold_2byte = 65792`
- `default_window_size = 65536`

## 5. 压缩级别映射

- `create_config_with_level(level)` 会先将输入约束到 `1..22`。
- 映射关系：
  - `1 -> (16, 4, 4)`
  - `2 -> (16, 4, 8)`
  - `3 -> (17, 4, 12)`
  - `4-5 -> (17, 4, 16)`
  - `6-7 -> (18, 4, 24)`
  - `8-9 -> (18, 4, 32)`
  - `10-12 -> (19, 3, 48)`
  - `13-15 -> (19, 3, 64)`
  - `16-18 -> (20, 3, 96)`
  - `19-22 -> (20, 3, 128)`
- 口径：
  - `window_size = 1 << window_log`

## 6. 协议写出规则

### 6.1 小端写入工具

- `write_u16_le`：写 16 bit 小端整数。
- `write_u32_le`：写 32 bit 小端整数。

### 6.2 块头写入

- `write_block_header(output, last_block, block_type, block_size)`
- 24 bit 结构：`last_block | block_type | block_size`

### 6.3 序列计数写入

- `count < 128`：1 字节
- `count < 32768`：2 字节
- 否则：3 字节，首字节固定 `0xFF`

### 6.4 Frame Content Size 写入

- `data_length < 256`
  - FHD 使用 1-byte FCS 方案
- `data_length < 65792`
  - FHD 使用 2-byte FCS 方案
  - 写入值为 `data_length - 256`
- 否则
  - 使用 4-byte FCS

### 6.5 流式帧头写入

- 流式压缩器当前使用：
  - 非 `single_segment`
  - 不预写 `Frame_Content_Size`
  - 写入 `Window_Descriptor`
- 原因：
  - 流式场景下写入开始时通常未知总输入长度
  - 该策略允许边接收输入边产出合法帧

### 6.6 流式落块策略

- 普通一次性压缩仍以 `128KB` 为最大块大小。
- 流式压缩器当前内部自动落块粒度为 `64KB`。
- 原因：
  - 当前历史复用路径依赖单序列直写
  - 单序列直写超限时会自动拆成多序列
  - 但当前为优先保证稳定性，流式路径仍维持 `64KB` 粒度

## 7. 校验和口径

- `calculate_checksum` 当前是 `Simple XXH32-like checksum`
- 说明：
  - 它是近似风格实现，不应在文档里宣称为完整官方 `XXH32`。

## 8. LZ77 相关口径

- 哈希匹配通过 4 字节序列做分桶。
- 匹配偏移不得超过当前窗口大小。
- 单次匹配最大长度上限受 `131072` 约束。
- `min_match` 默认随级别变化，`3` 或 `4`。

## 9. 字典压缩说明

- 带字典压缩会把字典内容参与模式匹配。
- 帧头中会写入字典 ID。

## 10. 注意事项

- 本模块内含较多协议 helper，项目没有独立 `base/tool` 目录时，应把这些 helper 视为“局部协议工具”，而不是抽象成全局工具层。
- 当前流式压缩器优先保证“协议正确性和生命周期可用性”，后续若需要更高压缩率，应继续补跨 chunk 的匹配状态继承。
- 当前已经有基础跨 chunk 历史继承，但还不是完整通用增量解析器；若继续演进，应优先补完整的流式序列生成和更标准的单序列大值编码路径。
