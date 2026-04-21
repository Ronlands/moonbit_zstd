# Test-Data 资源索引

## 1. 目录定位

- 路径：`src/test-data`
- 职责：存放金标压缩样本、错误样本、文本样本与兼容性资源。

## 2. 子目录索引

- `golden-decompression/`
  - `block-128k.zst`
  - `empty-block.zst`
  - `rle-first-block.zst`
  - `zeroSeq_2B.zst`
- `golden-decompression-errors/`
  - `off0.bin.zst`
  - `truncated_huff_state.zst`
  - `zeroSeq_extraneous.zst`
- `golden-compression/`
  - `http/`
  - `huffman-compressed-larger/`
  - `large-literal-and-match-lengths/`
  - `PR-3517-block-splitter-corruption-test/`
- `text/`
  - `empty.txt.zst`
  - `json.txt.zst`
  - `long.txt.zst`
  - `numbers.txt.zst`
  - `random.txt.zst`
  - `repeated.txt.zst`
  - `short.txt.zst`
  - `single_char.txt.zst`
  - `special_chars.txt.zst`
  - `with_nulls.txt.zst`

## 3. 资源分类说明

### 3.1 `golden-decompression`

- 用途：验证解压器对合法样本的兼容性。
- 关注点：空块、RLE 首块、128K 边界块、零序列编码等。

### 3.2 `golden-decompression-errors`

- 用途：验证解压器对已知损坏样本的拒绝能力。
- 关注点：
  - 非法偏移
  - Huffman 状态截断
  - 零序列冗余数据

### 3.3 `golden-compression`

- 用途：验证编码器输出结构与复杂压缩场景。
- 关注点：
  - 大字面量与大匹配长度
  - 块切分边界
  - Huffman 压缩样本

### 3.4 `text`

- 用途：常见文本内容的压缩样本。
- 关注点：空文本、短文本、长文本、随机文本、重复文本、特殊字符文本。

## 4. 使用建议

- 新增样本时要按“合法样本 / 错误样本 / 文本样本 / 特殊回归样本”分类放置。
- 新增目录后要同步更新本文件与 `AGENTS.md` 索引。
