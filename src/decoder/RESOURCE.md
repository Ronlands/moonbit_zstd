# Decoder 模块资源

## 1. 模块定位

- 路径：`src/decoder`
- 关键文件：`frame.mbt`、`decompressor.mbt`、`block.mbt`、`analyzer.mbt`、`dictionary.mbt`
- 职责：帧头解析、块解压、滑动窗口管理、文件分析、字典解压支持。

## 2. 核心类型索引

- `Decompressor`
- `DecoderContext`
- `ZSTDFileAnalysis`
- `FSETableEntry`
- `FSETable`
- `FSEDecoder`
- `HuffmanTable`
- `HuffmanDecoder`
- `HuffmanWeights`

## 3. 类型与字段说明

### 3.1 `Decompressor`

- 字段：
  - `window_size`：窗口大小，单位字节。
  - `context`：底层解压上下文。
  - `dictionary`：预加载字典内容。
- 用途：承载带窗口或带字典的解压状态。

### 3.2 `DecoderContext`

- 字段：
  - `window`：`@zstd_core.WindowBuffer`
  - `window_size`：窗口大小，单位字节
  - `total_decoded`：累计解码字节数
- 用途：跨块维护滑动窗口。
- 限制：累计输出受 `128MB` 限制。

### 3.3 `ZSTDFileAnalysis`

- 字段：
  - `is_valid`
  - `error_message`
  - `magic_number`
  - `single_segment`
  - `content_checksum`
  - `frame_content_size`
  - `window_size`
  - `total_blocks`
  - `file_size`
  - `first_block_type`
  - `first_block_size`
  - `last_block`
- 说明：这是 `decoder/analyzer.mbt` 中更完整的分析结果对象，比 `api` 模块版本多 `frame_content_size`。

## 4. 帧头解析口径

- 文件：`frame.mbt`
- 字段顺序：
  1. Magic
  2. FHD
  3. `Window_Descriptor`，仅非单段帧存在
  4. `Dictionary_ID`
  5. `Frame_Content_Size`
- 关键规则：
  - `reserved bit` 必须为 `0`
  - `single_segment = true` 时，若 `fcs_flag = 0`，则 `FCS` 长度为 1 字节
  - `fcs_flag = 1` 时，实际 `frame_content_size = 读取值 + 256`
  - `fcs_flag = 3` 时，当前实现仅读取低 4 字节语义，高 4 字节跳过

### 4.1 窗口大小公式

- 非单段帧公式：
  - `exponent = wd >> 3`
  - `mantissa = wd & 7`
  - `window_log = exponent + 10`
  - `window_base = 1 << window_log`
  - `window_add = (window_base / 8) * mantissa`
  - `window_size = window_base + window_add`
- 单段帧公式：
  - `window_size = frame_content_size`

## 5. 解压流程口径

- `decompress`：支持按帧串联解压，符合拼接帧场景。
- `decompress_with_limit`：在累计输出层面施加上限，防止解压炸弹绕过。
- 全局输出限制：`134217728` 字节，即 `128MB`。
- `calculate_frame_size`：用于从串联流中定位当前帧结束位置。

## 6. 块处理口径

- 块头大小固定 `3` 字节。
- `block_type`：
  - `0 = Raw`
  - `1 = RLE`
  - `2 = Compressed`
  - `3 = Reserved`
- 对 `RLE` 块：
  - `block_size` 表示解压后长度
  - 实际压缩数据大小固定为 `1` 字节
- 对 `Raw` / `Compressed` 块：
  - `block_size` 视为块数据长度

## 7. 分析器口径

- 文件：`analyzer.mbt`
- 支持识别 `Skippable Frame`。
- 可跳过帧规则：
  - magic 处于 `0x184D2A50 ~ 0x184D2A5F`
  - `frame_size` 为用户数据长度
  - `total_frame_size = 8 + frame_size`
- 分析器会尝试发现：
  - 保留位错误
  - 超大块
  - 截断块
  - 序列计数异常
  - FSE 保留位异常
  - Huffman 状态截断

## 8. 字典解压口径

- `decompress_zstd_data_with_dict`：把字典内容作为初始窗口前缀。
- 返回结果会在最终阶段剔除字典前缀，只返回真实解压数据。

## 9. 注意事项

- `decoder` 中既有真正解压逻辑，也有分析器和启发式错误检测，阅读时注意区分“协议真逻辑”和“静态检测逻辑”。
- 本模块和 `api` 模块都存在 `ZSTDFileAnalysis`，修改文档时必须区分版本。
