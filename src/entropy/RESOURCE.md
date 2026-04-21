# Entropy 模块资源

## 1. 模块定位

- 路径：`src/entropy`
- 关键文件：`fse.mbt`、`huffman.mbt`、`sequence_tables.mbt`
- 职责：FSE、Huffman 和 ZSTD 序列字段映射表。

## 2. 核心类型索引

- `Sequence`
- `FSETable`
- `FSEState`
- `BitStream`
- `SymbolTransform`
- `FSECTable`
- `FSEEncodeTable`
- `HuffmanTable`
- `HuffmanNode`
- `HuffmanWeights`
- `HuffmanTreeNode`
- `HuffmanCode`
- `HuffmanEncodeTable`
- `HuffmanBitWriter`
- `HuffmanBitReader`

## 3. 序列表资源

- 文件：`sequence_tables.mbt`
- 表：
  - `ll_base` / `ll_bits`
  - `ml_base` / `ml_bits`
  - `of_base` / `of_bits`
- 作用：把序列编码中的符号码映射为实际 `Literal Length`、`Match Length`、`Offset`。

## 4. 公式口径

### 4.1 Literal Length

- `decode_ll(code, extra_bits) = ll_base[code] + extra_bits`
- `get_ll_bits(code)`：返回对应附加 bit 数。
- `encode_ll(literal_length)`：寻找满足 `ll_base[code] <= literal_length` 的最大 `code`。

### 4.2 Match Length

- `decode_ml(code, extra_bits) = ml_base[code] + extra_bits`
- 说明：当前实现中 `ml_base` 已包含最终 `matchLength`，不再额外加 `MINMATCH`。
- `encode_ml(match_length)`：寻找满足 `ml_base[code] <= match_length` 的最大 `code`。

### 4.3 Offset

- `decode_of(code, extra_bits) = of_base[code] + extra_bits`
- `encode_of(offset)` 要求 `offset >= 1`
- 特殊语义：
  - `of_code = 0` 可作为重复偏移相关特殊值
  - `of_code = 1` 可能表示重复偏移场景

## 5. FSE 相关说明

- `FSETable`：FSE 解码表。
- `FSEState`：FSE 状态机状态。
- `FSEEncodeTable` / `FSECTable`：编码侧表结构。
- 用途：序列区段状态转移与熵解码。

## 6. Huffman 相关说明

- `HuffmanWeights`：Huffman 权重。
- `HuffmanTable`：解码表。
- `HuffmanEncodeTable`：编码表。
- `HuffmanBitWriter` / `HuffmanBitReader`：位流写入与读取工具。

## 7. 统计与精度说明

- 本模块主要是协议公式和整数表，不涉及业务统计精度问题。
- 若输出压缩率或编码率，必须在调用方说明公式，不在本模块默认定义。

## 8. 注意事项

- 本模块的核心价值在“表与公式”，不是在对象字段数量。
- 修改任何表值或公式前，必须先确认 RFC 与现有测试样本。
