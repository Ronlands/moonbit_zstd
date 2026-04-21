# Encoder 模块资源

## 1. 模块定位

- 路径：`src/encoder`
- 主文件：`src/encoder/compressor.mbt`
- 职责：压缩配置、LZ77 匹配、帧头/块头写出、带字典压缩。

## 2. 核心类型索引

- `Compressor`
- `CompressionConfig`
- `CompressionContext`

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

### 3.3 `CompressionContext`

- 字段：
  - `config`
- 用途：封装压缩配置，便于后续扩展上下文。

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
