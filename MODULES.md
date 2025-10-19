# MoonBit ZSTD 模块结构

## 模块命名规范

所有模块别名统一使用 `zstd_` 前缀，保持命名一致性：

### 核心模块 (Core Modules)

- **`@zstd_core`** - 核心类型和错误处理
  - 路径: `Ronlands/moonbit_zstd/core`
  - 功能: Bitstream、错误类型、常量定义

- **`@zstd_encoder`** - 压缩编码器
  - 路径: `Ronlands/moonbit_zstd/encoder`
  - 功能: LZ77压缩、Raw/RLE/Compressed块编码

- **`@zstd_decoder`** - 解压解码器
  - 路径: `Ronlands/moonbit_zstd/decoder`
  - 功能: 帧解析、块解压、完整解码流程

- **`@zstd_entropy`** - 熵编码
  - 路径: `Ronlands/moonbit_zstd/entropy`
  - 功能: FSE、Huffman 编码/解码

### API 和工具模块 (API & Utility Modules)

- **`@zstd`** - 公共 API
  - 路径: `Ronlands/moonbit_zstd/api`
  - 功能: 高层压缩/解压接口、文件分析

- **`@zstd_test`** - 测试套件
  - 路径: `Ronlands/moonbit_zstd/test`
  - 功能: 基础测试、RFC兼容性测试

- **`@zstd_examples`** - 示例和演示
  - 路径: `Ronlands/moonbit_zstd/examples`
  - 功能: 使用示例、性能演示

- **`@zstd_dictionary`** - 字典管理
  - 路径: `Ronlands/moonbit_zstd/dictionary`
  - 功能: 字典构建（Cover算法）、字典压缩/解压

## 模块依赖关系

```
┌─────────────┐
│   cmd       │ (主程序入口)
└──────┬──────┘
       │
       ├──> @zstd_test
       └──> @zstd_examples
              │
              ├──> @zstd (API)
              │     │
              │     ├──> @zstd_encoder
              │     │     └──> @zstd_core
              │     │
              │     └──> @zstd_decoder
              │           ├──> @zstd_core
              │           └──> @zstd_entropy
              │
              ├──> @zstd_decoder
              └──> @zstd_core
```

## 主要 API

### 压缩 API

```moonbit
// 基础压缩（默认级别2）
let compressed = @zstd.compress(data)

// 指定级别（1-22）
let compressed = @zstd.compress_with_level_int(data, level)

// 指定方法和级别
let compressed = @zstd.compress_as_raw(data, level)      // Raw块
let compressed = @zstd.compress_as_rle(data, level)      // RLE块
let compressed = @zstd.compress_as_compressed(data, level) // Compressed块

// 带字典压缩
let compressed = @zstd_dictionary.compress_with_dictionary(data, dict)
```

### 解压 API

```moonbit
// 基础解压
let decompressed = @zstd.decompress(compressed)

// 带字典解压
let decompressed = @zstd_dictionary.decompress_with_dictionary(compressed, dict)
```

### 分析 API

```moonbit
// 检查是否为ZSTD格式
let is_valid = @zstd.is_zstd_format(data)

// 分析文件结构
let analysis = @zstd.analyze_file(data)

// 分析数据完整性
let integrity = @zstd.analyze_data_integrity(data)
```

## 压缩级别详情

| 级别 | 窗口大小 | 最小匹配 | 搜索深度 | 特点 |
|------|----------|----------|----------|------|
| 1-2  | 64KB     | 4        | 4-8      | Fast |
| 3-5  | 128KB    | 4        | 12-16    | Default |
| 6-9  | 256KB    | 4        | 24-32    | Better |
| 10-15| 512KB    | 3        | 48-64    | Much Better |
| 16-22| 1MB      | 3        | 96-128   | Ultra |

## 测试覆盖

 **Basic Tests (6/6)**
- 基础压缩/解压
- 格式检测
- 文件分析
- 压缩级别
- 空数据处理
- 数据完整性

 **Compatibility Tests (5/5)**
- 魔数验证
- 帧头格式
- 块类型支持
- 校验和
- 字节序处理

 **RFC 8878 兼容性: 100%**
- 完全兼容官方 ZSTD 规范
- 可解压官方工具生成的文件

