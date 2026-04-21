# Examples 模块资源

## 1. 模块定位

- 路径：`src/examples`
- 职责：提供 API 使用演示、兼容性示例、文件操作示例。

## 2. 文件索引

- `basic_demos.mbt`：基础压缩、文件分析、完整性分析、格式检测、压缩级别、Huffman 演示。
- `advanced_compression.mbt`：压缩方法与不同模式比较。
- `file_operations.mbt`：文件压缩相关示例。
- `official_compatibility.mbt`：与官方工具交互的兼容性示例。
- `rfc_demos.mbt`：RFC 与金标样本演示。

## 3. 模块对象说明

- 本模块无核心实体定义。
- 重点是“示例场景”，不是协议模型。

## 4. 统计口径提醒

- 本模块中某些 demo 打印的“压缩比”口径并不完全统一。
- 后续新增示例时，统一要求：
  - `compression_ratio = original_size / compressed_size`
  - 若输出百分比，必须显式标为“压缩后占原始大小百分比”或类似语义。

## 5. 使用建议

- 对外写文档或讲解优先引用本模块示例。
- 如果示例输出口径与正式规范冲突，以 `CODE-TYPE.md` 为准并同步修正示例。
