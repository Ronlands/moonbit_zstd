# 项目协作索引

## 1. 使用说明

- 本文件面向多种 AI 工具，目标是提供轻量导航，不承载大段字段说明。
- 进入本仓库后，优先先读本文件，再按需跳转到对应 `RESOURCE.md` 或 `CODE-TYPE.md`。
- 本项目是 `MoonBit` 的 `ZSTD / RFC 8878` 算法实现库，不是典型业务系统，文档组织以“模块 / 类型 / 协议结构 / 配置 / 统计口径”为主，而不是传统 `Entity / VO / DTO` 模板。
- 现有 `README.md`、`STREAMING_API.md` 中个别示例可能与源码有漂移，分析和修改时以 `src/` 下源码为准。
- 当前环境是 Windows / PowerShell，优先使用 Windows 可执行命令与 `rg` 检索。

## 2. 根文档索引

- 代码规范：`CODE-TYPE.md`
- 源码总索引：`src/RESOURCE.md`
- 模块资源：
  - `src/api/RESOURCE.md`
  - `src/core/RESOURCE.md`
  - `src/decoder/RESOURCE.md`
  - `src/encoder/RESOURCE.md`
  - `src/entropy/RESOURCE.md`
  - `src/dictionary/RESOURCE.md`
  - `src/cmd/RESOURCE.md`
  - `src/examples/RESOURCE.md`
  - `src/test/RESOURCE.md`
  - `src/benchmark/RESOURCE.md`
  - `src/test-data/RESOURCE.md`

## 3. 模块地图

- `src/api`：对外高层 API，压缩、解压、格式分析、完整性分析、估算。
- `src/core`：核心类型、常量、错误模型、字节流读取、窗口基础模型。
- `src/decoder`：帧头解析、块解压、滑动窗口、文件分析、带字典解压。
- `src/encoder`：压缩器、LZ77、帧头/块头写出、带字典压缩。
- `src/entropy`：FSE / Huffman / 序列表与相关公式。
- `src/dictionary`：字典对象、Cover 算法、收益统计、字典格式读写。
- `src/cmd`：演示与测试总入口。
- `src/examples`：示例场景。
- `src/test`：测试套件与测试工具。
- `src/benchmark`：基准测试结果对象与输出逻辑。
- `src/test-data`：金标样本、错误样本与文本压缩样本。

## 4. 推荐阅读顺序

1. `src/RESOURCE.md`
2. `CODE-TYPE.md`
3. `src/api/RESOURCE.md`
4. `src/core/RESOURCE.md`
5. `src/encoder/RESOURCE.md`
6. `src/decoder/RESOURCE.md`
7. `src/entropy/RESOURCE.md`
8. `src/dictionary/RESOURCE.md`

## 5. 通用工具能力索引

说明：项目中没有真实的 `base/tool` 目录，不要假设存在公共工具层。当前项目的“通用工具能力”分散在以下文件中。

- `src/core/bitstream.mbt`
  - `new_bitstream`：创建字节流上下文。
  - `read_bytes` / `read_byte`：按顺序读取字节。
  - `read_le_int`：按小端读取整数。
  - `skip_bytes`：移动读取位置。
- `src/core/errors.mbt`
  - `create_error_context`：创建带位置与操作信息的错误上下文。
  - `create_contextual_error`：构造带严重级别的错误对象。
  - `format_error`：格式化完整错误信息。
  - `validate_*`：魔数、帧描述符、块头、窗口大小、历史引用校验。
- `src/entropy/sequence_tables.mbt`
  - `decode_ll` / `decode_ml` / `decode_of`：按 RFC 表解码序列字段。
  - `encode_ll` / `encode_ml` / `encode_of`：把数值回映射到编码表。
  - `get_ll_bits` / `get_ml_bits` / `get_of_bits`：查询扩展 bit 数。
- `src/encoder/compressor.mbt`
  - `write_u16_le` / `write_u32_le`：小端写数值。
  - `write_block_header`：写 24-bit 块头。
  - `write_frame_header_descriptor*`：写帧头描述符与 FCS。
  - `write_sequence_count`：写变长序列计数。
  - `calculate_checksum`：简化版校验和计算。
- `src/test/test_utils.mbt`
  - `repeat_string`：拼接测试展示字符串。
  - `verify_data_equal`：比较字节序列。
  - `run_test_suite`：输出测试套件统计结果。

## 6. 术语与口径

- `Frame`：ZSTD 帧。
- `Block`：帧内块，块头固定 3 字节。
- `single_segment`：单段帧。为 `true` 时，通常 `window_size == frame_content_size`。
- `window_size`：滑动窗口大小，单位字节。
- `frame_content_size`：帧解压后的内容大小，单位字节。
- `block_size`：块头里的大小字段。对 `RLE` 块表示解压后长度，对 `Raw` / `Compressed` 块表示块数据长度。
- `compression_ratio`：本项目未来统一要求表示 `original_size / compressed_size`，值越大越好，展示为 `x`。
- `benefit_percentage`：字典收益百分比，统一表示节省量相对于“无字典压缩大小”的占比。
- `heuristic metric`：启发式指标，不等价于严格统计模型或标准协议字段。
- `dict_id` / `dictionary_id`：字典 ID。项目中需避开保留范围。
- 本项目当前没有“周 / 月 / 自然周 / 自然月”类业务口径；如果未来新增时间统计字段，必须显式写清是自然周期还是滚动周期。

## 7. 快速检查命令

```powershell
moon run src/cmd
rg --files src
rg "^pub (struct|enum|type|fn)" src
rg "CompressionConfig|ZSTDFileAnalysis|DictionaryBenefitStats" src
rg "131072|134217728|32768|window_size|checksum" src
rg --files src/test-data
```

说明：

- `moon run src/cmd`：运行演示与测试总入口。
- `rg --files src`：快速查看源码文件分布。
- `rg "^pub (struct|enum|type|fn)" src`：快速扫描公开类型与 API。
- `rg "131072|134217728|32768|window_size|checksum" src`：快速定位关键阈值与协议约束。

## 8. 修改约束

- 修改实现前，先查看对应模块 `RESOURCE.md`。
- 新增类型、字段、统计结果、协议公式时，要同步更新对应模块 `RESOURCE.md`。
- 新增通用约束、命名规范、注释规范时，要同步更新 `CODE-TYPE.md`。
- 不要在根 `AGENTS.md` 里堆叠字段级细节，避免上下文膨胀。

## 9. 可忽略目录

- `_build/`
- `.mooncakes/`
- `.git/`
- `.claude/`

## 10. 入口文件

- 模块定义：`moon.mod.json`
- 总源码根：`src/`
- 对外 API：`src/api/zstd.mbt`
- 压缩主实现：`src/encoder/compressor.mbt`
- 解压主实现：`src/decoder/decompressor.mbt`
- 帧头解析：`src/decoder/frame.mbt`
- 文件分析：`src/decoder/analyzer.mbt`
- 序列表：`src/entropy/sequence_tables.mbt`
