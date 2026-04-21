# src 总览

## 1. 目录定位

- `src/` 是仓库源码根。
- 本目录本身只做源码入口与模块集合索引，不承载主要业务实体。
- 详细字段说明下沉到各子目录 `RESOURCE.md`。

## 2. 子模块索引

- `api/RESOURCE.md`：对外 API、分析结果、压缩方法与估算口径。
- `core/RESOURCE.md`：核心类型、错误、窗口、字节流、常量。
- `decoder/RESOURCE.md`：帧头解析、块解压、滑动窗口、分析器。
- `encoder/RESOURCE.md`：压缩配置、写帧规则、LZ77 相关口径。
- `entropy/RESOURCE.md`：FSE / Huffman / 序列表与公式。
- `dictionary/RESOURCE.md`：字典对象、Cover 算法、收益统计。
- `cmd/RESOURCE.md`：运行入口与执行顺序。
- `examples/RESOURCE.md`：示例场景索引。
- `test/RESOURCE.md`：测试分类与测试工具说明。
- `benchmark/RESOURCE.md`：基准对象与压缩比口径。
- `test-data/RESOURCE.md`：金标与错误样本资源索引。

## 3. 推荐阅读顺序

1. `api/RESOURCE.md`
2. `core/RESOURCE.md`
3. `encoder/RESOURCE.md`
4. `decoder/RESOURCE.md`
5. `entropy/RESOURCE.md`
6. `dictionary/RESOURCE.md`

## 4. 关键入口文件

- `moonbit_zstd.mbt`：源码根说明文件。
- `api/zstd.mbt`：对外 API 入口。
- `encoder/compressor.mbt`：压缩主实现。
- `encoder/compressor_streaming.mbt`：流式压缩状态机与统计输出。
- `encoder/compressor_dictionary.mbt`：带字典压缩与历史窗口匹配辅助。
- `encoder/compressor_entropy.mbt`：压缩块负载构建、字面量编码与 FSE/Huffman 编码辅助。
- `decoder/decompressor.mbt`：解压主实现。
- `decoder/frame.mbt`：帧头解析。
- `decoder/analyzer.mbt`：文件结构分析。
- `decoder/analyzer_structure.mbt`：分析器结构解析与块验证辅助。
- `decoder/analyzer_heuristics.mbt`：分析器启发式错误检测与完整性分析。
- `decoder/block_sequences.mbt`：块内序列解析、FSE 序列解码与序列执行。
- `entropy/fse_codec.mbt`：FSE 编码表、位流与完整 tANS 编码/解码辅助。
- `entropy/huffman_codec.mbt`：Huffman 编码表、位流与完整 Huffman codec 实现。
- `entropy/sequence_tables.mbt`：序列编码表。

## 5. 当前源码根对象说明

- `moonbit_zstd.mbt`
  - 作用：说明库总体定位。
  - 类型数量：无核心类型定义。
  - 修改建议：仅保留入口说明，不在这里堆积实现细节。

## 6. 模块级统一约束

- 以源码为准，不以旧文档为准。
- 字段级说明不写在本文件，统一写入对应模块 `RESOURCE.md`。
- 新增模块时，必须同时：
  - 在本文件追加索引
  - 在根 `AGENTS.md` 追加索引
  - 在模块根新增 `RESOURCE.md`
