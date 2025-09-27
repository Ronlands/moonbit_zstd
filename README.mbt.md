# Moonbit ZSTD

一个纯 Moonbit 实现的 Zstandard (ZSTD) 压缩算法库，严格遵循 RFC 8878 规范。

## 概览

本库提供了 ZSTD 压缩算法在纯 Moonbit 中的完整实现，确保与 RFC 8878 规范完全兼容。包含压缩和解压缩功能，支持流式操作。

## 特性

- **RFC 8878 兼容**: 严格遵循 ZSTD 规范
- **高性能**: 针对速度和内存效率进行优化  
- **纯 Moonbit**: 无外部依赖
- **完整实现**: 包含压缩和解压缩功能
- **流式支持**: 高效处理大型数据
- **熵编码**: FSE 和霍夫曼编解码
- **块类型支持**: Raw、RLE 和 Compressed 块类型
- **现代设计**: 利用 Moonbit 的类型安全和性能优势

## 架构

库组织成以下模块：

### 核心模块
- `core/types.mbt` - 核心数据类型和常量
- `core/bitstream.mbt` - 位级流操作

### 熵编码
- `entropy/fse.mbt` - 有限状态熵 (FSE) 实现
- `entropy/huffman.mbt` - 霍夫曼编码实现

### 解码器
- `decoder/frame.mbt` - 帧格式解析
- `decoder/block.mbt` - 块解码
- `decoder/decompressor.mbt` - 主解压器

### 编码器
- `encoder/compressor.mbt` - 主压缩器

### API
- `api/zstd.mbt` - 高级 API 函数

## 快速开始

```moonbit
import moonbit_zstd::api::zstd

// 基础压缩
let original = "Hello, World!".to_bytes()
let compressed = zstd::compress(original)
let decompressed = zstd::decompress(compressed)

// 流式压缩
let compressor = zstd::create_compressor()
let (new_compressor, compressed) = zstd::compress_with_compressor(compressor, data)
```

## API 参考

### 高级函数

- `compress(data: Bytes) -> Bytes` - 压缩数据
- `decompress(data: Bytes) -> Bytes` - 解压缩数据
- `get_compression_ratio(original: Int, compressed: Int) -> Double` - 计算压缩率
- `is_zstd_data(data: Bytes) -> Bool` - 检查数据是否为 ZSTD 压缩格式

### 流式 API

- `create_compressor() -> Compressor` - 创建流式压缩器
- `create_decompressor() -> Decompressor` - 创建流式解压器
- `compress_with_compressor(compressor: Compressor, data: Bytes) -> (Compressor, Bytes)`
- `decompress_with_decompressor(decompressor: Decompressor, data: Bytes) -> (Decompressor, Bytes)`

## 实现细节

### 帧格式
实现遵循 ZSTD 帧格式规范：
- Magic number: 0xFD2FB528 (RFC 8878)
- 帧头包含窗口大小、字典 ID、内容大小
- 块头包含类型和大小信息

### 块类型
- **Raw**: 未压缩数据
- **RLE**: 运行长度编码数据  
- **Compressed**: 使用序列的熵编码数据

### 熵编码
- **FSE**: 用于序列编码的有限状态熵
- **Huffman**: 用于字面量编码的霍夫曼编码

### 序列执行
解码器执行序列来重建原始数据：
- 直接复制字面量
- 从滑动窗口复制匹配
- 维护解压缩上下文

## 测试

库包含全面的测试：
- 基础功能测试
- RFC 8878 兼容性测试
- 往返压缩测试
- 边界情况处理

运行测试：
```bash
moon run ./src/cmd/main
```

或者直接在代码中：
```moonbit
import tests::basic_tests::{run_basic_tests}
import tests::compatibility_tests::{run_compatibility_tests}

run_basic_tests()
run_compatibility_tests()
```

## 示例

查看 `src/examples/` 目录的使用示例：
- `basic_usage.mbt` - 基础压缩/解压缩
- `streaming_usage.mbt` - 流式操作

## 性能

实现针对以下方面进行了优化：
- 快速解压缩（主要使用场景）
- 内存效率
- 大数据的流式支持

## 当前状态

这是一个功能完整的 ZSTD 实现，包含：

✅ **已实现**：
- RFC 8878 帧格式解析
- Raw 和 RLE 块类型的完整支持
- FSE (有限状态熵) 编解码框架
- 霍夫曼编码框架
- 基础压缩和解压缩 API
- 流式压缩/解压缩支持
- 全面的测试套件

🚧 **进行中**：
- 压缩块的完整熵解码实现
- 高级 LZ77 风格的匹配算法
- 性能优化

## 许可证

Apache-2.0

## 贡献

这是一个遵循 RFC 8878 的参考实现。欢迎为以下方面做出贡献：
- 性能优化
- 更多测试用例
- 文档改进
- 与官方 zstd 库的兼容性测试