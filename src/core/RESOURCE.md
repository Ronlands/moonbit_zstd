# Core 模块资源

## 1. 模块定位

- 路径：`src/core`
- 主文件：`types.mbt`、`errors.mbt`、`bitstream.mbt`
- 职责：核心类型、常量、错误模型、字节流工具、窗口基础模型。

## 2. 核心类型索引

- `ZSTDError`
- `ZSTDResult[T]`
- `FrameType`
- `FrameHeader`
- `DecompressionContext`
- `HuffmanTreeRef`
- `BlockType`
- `LiteralsType`
- `Sequence`
- `SequenceMode`
- `BlockHeader`
- `LiteralsHeader`
- `LiteralsSectionInfo`
- `SequencesSectionInfo`
- `DictionaryType`
- `Dictionary`
- `WindowBuffer`
- `ErrorSeverity`
- `ErrorContext`
- `ContextualError`
- `RecoveryStrategy`
- `ErrorStats`
- `BitStream`

## 3. 关键类型说明

### 3.1 `FrameHeader`

- 字段：
  - `frame_type`：帧类型，普通帧或可跳过帧。
  - `dict_id`：字典 ID。
  - `frame_content_size`：解压后内容大小，单位字节。
  - `single_segment`：是否单段帧。
  - `checksum_flag`：是否带内容校验和。
  - `window_size`：窗口大小，单位字节。
- 来源：帧头解析阶段生成。
- 使用：解压前的协议约束与窗口初始化。
- 口径：
  - `single_segment = true` 时，通常 `window_size = frame_content_size`。

### 3.2 `Sequence`

- 字段：
  - `literal_length`
  - `match_length`
  - `offset`
- 语义：序列解码后的三元组，服务于回溯复制。
- 单位：均为字节。

### 3.3 `BlockHeader`

- 字段：
  - `block_type`
  - `block_size`
  - `last_block`
- 口径：
  - 块头固定 3 字节。
  - `block_size` 来自块头高 21 bit。

### 3.4 `LiteralsHeader`

- 字段：
  - `literals_type`
  - `size`
  - `regenerated_size`
  - `streams_count`
- 用途：描述字面量段头部信息。

### 3.5 `LiteralsSectionInfo`

- 字段：
  - `literals_type`
  - `regenerated_size`
  - `compressed_size`
  - `num_streams`
- 口径：
  - `regenerated_size`：解码后字面量长度。
  - `compressed_size`：压缩区段占用长度。

### 3.6 `SequencesSectionInfo`

- 字段：
  - `num_sequences`
  - `ll_mode`
  - `ml_mode`
  - `of_mode`
- 用途：描述序列区段编码模式。

### 3.7 `Dictionary`

- 字段：
  - `dict_type`
  - `dict_id`
  - `data`
  - `size`
- 说明：这是 `core` 层统一字典模型，与 `src/dictionary` 中的对外字典对象不是同一个定义。

### 3.8 `WindowBuffer`

- 字段：
  - `buffer`：循环缓冲区内容。
  - `capacity`：容量，单位字节。
  - `position`：当前写入位置。
  - `size`：当前有效大小。
  - `dictionary`：关联字典对象。
- 用途：解压历史引用和滑动窗口承载。

### 3.9 `ErrorContext`

- 字段：
  - `location`：错误位置。
  - `operation`：当前操作。
  - `data_offset`：数据偏移量，单位字节。
  - `additional_info`：附加信息。

### 3.10 `ContextualError`

- 字段：
  - `error`
  - `severity`
  - `context`
  - `timestamp`
- 注意：`timestamp` 实际上是基于上下文计算出的简单哈希标识，不是真实时间戳。

### 3.11 `ErrorStats`

- 字段：
  - `error_count`
  - `fatal_count`
  - `total_count`
- 统计口径：
  - 每调用一次 `update_error_stats`，`total_count + 1`
  - 严重级别为 `Error` 时，`error_count + 1`
  - 严重级别为 `Fatal` 时，`fatal_count + 1`

### 3.12 `BitStream`

- 字段：
  - `data`
  - `position`
- 用途：顺序读取字节流。

## 4. 常量口径

- `ZSTD_MAGIC_NUMBER = 0xFD2FB528U`
- `ZSTD_MAX_BLOCK_SIZE = 131072`
- `ZSTD_BLOCK_HEADER_SIZE = 3`
- `ZSTD_MAGIC_NUMBER_SIZE = 4`
- `ZSTD_SKIPPABLE_MAGIC_MIN = 0x184D2A50`
- `ZSTD_SKIPPABLE_MAGIC_MAX = 0x184D2A5F`

## 5. 通用工具方法说明

- `bitstream.mbt`
  - `new_bitstream`：初始化读取上下文。
  - `read_bytes`：读取指定数量字节，不足时返回空字节串。
  - `read_byte`：读取单字节，不足时返回 `0x00`。
  - `read_le_int`：按小端读取整数。
  - `skip_bytes`：跳过若干字节。
- `errors.mbt`
  - `validate_magic_number`：校验魔数。
  - `validate_frame_descriptor`：校验帧描述符保留位与版本位。
  - `validate_block_header`：校验块大小与块类型。
  - `validate_window_size`：校验窗口大小是否处于 `1KB ~ 128MB`。
  - `validate_history_reference`：校验历史引用偏移。

## 6. 注意事项

- 本模块定义了多个跨模块共享对象，任何字段语义调整都要同步更新下游模块文档。
- `Dictionary`、`Sequence` 等名字在其他模块也存在，评审时要带路径区分。
