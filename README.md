# MoonBit ZSTD

A pure MoonBit implementation of Zstandard (ZSTD) compression algorithm, fully compliant with RFC 8878.

纯 MoonBit 实现的 Zstandard (ZSTD) 压缩算法库，符合 RFC 8878 规范。

## Highlights / 亮点

- **Full Compression & Decompression** / **完整压缩与解压缩** — LZ77 + FSE entropy coding, not just raw/RLE
- **Official zstd Compatible** / **官方 zstd 兼容** — Output verified with `zstd -d` v1.5.7
- **21/21 Tests Passing** / **21/21 测试通过** — Including multi-sequence compressed blocks
- **Pure MoonBit** / **纯 MoonBit** — No C/FFI dependencies, runs on WASM

## Quick Start / 快速开始

```bash
moon run src/cmd    # Run demos + full test suite
```

### Basic Usage / 基本用法

```moonbit
// Compress and decompress
let original = @encoding/utf8.encode("Hello, ZSTD!")
let compressed = @zstd.compress(original)
let decompressed = @zstd.decompress(compressed)

// Compress with specific level (1-22)
let compressed = @zstd.compress_with_level_int(data, 9)

// Compress with specific method
let compressed = @zstd.compress_advanced(data, Auto, 3)

// Analyze ZSTD file structure
let analysis = @zstd.analyze_file(data)
```

## Features / 功能

### Compression / 压缩

| Block Type | Description                             | Compression Ratio |
| ---------- | --------------------------------------- | ----------------- |
| Raw        | Uncompressed storage                    | 1:1               |
| RLE        | Run-length encoding for repetitive data | Up to 20:1        |
| Compressed | LZ77 + FSE (tANS) entropy coding        | 3:1 ~ 7:1 typical |

- 22 compression levels with configurable window size (64KB~1MB) and search depth
- Automatic block type selection (Raw/RLE/Compressed)
- Greedy multi-sequence LZ77 matching with 64KB window
- Predefined FSE tables matching RFC 8878 Section 3.1.1.3.2.2
- RLE Literals (type=1) for all-same-byte literal sections
- **Byte-compatible with official `zstd -d`** (verified with v1.5.7)

### Decompression / 解压缩

- All block types: Raw, RLE, Compressed
- FSE (tANS) decoding with proper backward bitstream and reload
- Huffman literals decoding (Compressed + Treeless modes)
- Sliding window support with overlapping match copy
- Multi-block frame support
- Dictionary decompression support

### Entropy Coding / 熵编码

- **FSE (tANS)**: Full encoder + decoder with official spread algorithm (high-threshold placement for -1 probability symbols)
- **Huffman**: Encoder + decoder with canonical codes, weight serialization, tree building

### Dictionary / 字典

- Raw and ZSTD-format dictionary support
- Dictionary ID management
- Cover algorithm for dictionary building from samples
- Dictionary-enhanced LZ77 compression

## Test Results / 测试结果

```
Basic tests passed:         11/11
Compatibility tests passed:  5/5
Dictionary tests passed:     5/5
All tests passed! ✓
```

| Test Category               | Count  | Status         |
| --------------------------- | ------ | -------------- |
| Basic Compression           | 1      | Passed         |
| Format Detection            | 1      | Passed         |
| File Analysis               | 1      | Passed         |
| Compression Levels          | 1      | Passed         |
| Empty Data                  | 1      | Passed         |
| Data Integrity              | 1      | Passed         |
| Compressed Block (LZ77+FSE) | 1      | Passed         |
| Multi-Sequence Block        | 1      | Passed         |
| RLE Literals                | 1      | Passed         |
| FSE Bitstream               | 1      | Passed         |
| FSE Encode Simple           | 1      | Passed         |
| Compatibility tests         | 5      | Passed         |
| Dictionary tests            | 5      | Passed         |
| **Total**                   | **21** | **All Passed** |

### Official Tool Verification / 官方工具验证

```bash
# Our encoder output → official zstd decoder
zstd -d moonbit_compressed.zst -o output.txt    # ✓ 450 bytes, content matches
```

## Compression Benchmark / 压缩性能

Test data: `"The quick brown fox jumps over the lazy dog. "` repeated 10x (450 bytes)

| Method                    | Output Size | Ratio   |
| ------------------------- | ----------- | ------- |
| Raw Block                 | 460 bytes   | 0.98:1  |
| RLE Block (all-same data) | 10 bytes    | 20:1    |
| Compressed Block          | 64 bytes    | **7:1** |

## Project Structure / 项目结构

```
src/
├── api/          # Public API (compress, decompress, analyze)
├── core/         # Core types (FrameHeader, BlockType, Sequence, etc.)
├── encoder/      # Compressor (LZ77 + FSE encoding)
├── decoder/      # Decompressor (block parsing, sequence execution)
├── entropy/      # FSE (tANS) + Huffman encoder/decoder
├── dictionary/   # Dictionary support (Cover algorithm, format parsing)
├── cmd/          # CLI entry point (demos + tests)
├── examples/     # Demo programs
├── test/         # Test suite (basic, compatibility, encoding, golden)
└── test-data/    # Golden test files from official ZSTD suite
```

## API Reference / API 参考

### Compression / 压缩

```moonbit
fn compress(data: Bytes) -> Bytes
fn compress_with_level(data: Bytes, level: CompressionLevel) -> Bytes
fn compress_with_level_int(data: Bytes, level: Int) -> Bytes
fn compress_advanced(data: Bytes, mode: CompressionMethod, level: Int) -> Bytes
fn compress_as_raw(data: Bytes, level: Int) -> Bytes
fn compress_as_rle(data: Bytes, level: Int) -> Bytes
fn compress_as_compressed(data: Bytes, level: Int) -> Bytes
```

### Decompression / 解压缩

```moonbit
fn decompress(data: Bytes) -> Bytes
fn decompress_with_sliding_window(decoder: SlidingWindowDecoder, data: Bytes) -> Result[Bytes, String]
fn create_sliding_window_decoder(window_size: Int) -> SlidingWindowDecoder
```

### Analysis / 分析

```moonbit
fn analyze_file(data: Bytes) -> ZSTDFileAnalysis
fn is_zstd_format(data: Bytes) -> Bool
fn analyze_data_integrity(data: Bytes) -> DataIntegrityAnalysis
```

### Dictionary / 字典

```moonbit
fn compress_with_dictionary(data: Bytes, dictionary: Dictionary) -> Result[Bytes, String]
fn decompress_with_dictionary(data: Bytes, dictionary: Dictionary) -> Result[Bytes, String]
fn build_dictionary_with_cover(samples: Array[Bytes], target_size: Int, ngram_size: Int) -> Result[Dictionary, String]
```

## Implementation Status / 实现状态

### Completed / 已完成

- [x] Full compression: Raw + RLE + Compressed blocks (LZ77 + FSE)
- [x] Full decompression: All block types with sliding window
- [x] FSE (tANS) encoder/decoder with official-compatible table spread
- [x] Huffman encoder/decoder
- [x] Dictionary compression and decompression
- [x] Official `zstd -d` compatibility for Compressed blocks
- [x] 22 compression levels
- [x] RLE Literals optimization
- [x] Multi-sequence LZ77 with greedy matching
- [x] Bitstream reload for large data

### Future Work / 未来工作

- [ ] Huffman Literals compression (type=2) in encoder — currently uses Raw/RLE literals
- [ ] Repeat Offset optimization (offset codes 1/2/3)
- [ ] Multi-block frame compression for data > 128KB
- [ ] FSE Compressed mode (custom tables) in addition to Predefined
- [ ] Performance optimization (batch copy, reduced allocations)
- [ ] Content checksum support

## Technical Details / 技术细节

### ZSTD Bitstream Format

The encoder produces a standard ZSTD bitstream:

1. **Frame Header**: Magic (0xFD2FB528) + FHD + Frame Content Size
2. **Block Header**: Last_Block flag + Block_Type (Raw/RLE/Compressed) + Block_Size
3. **Compressed Block**:
   - Literals Section (Raw or RLE literals)
   - Sequences Section:
     - Sequence count + compression modes byte (Predefined FSE)
     - FSE-encoded bitstream with padding bit marker

The FSE bitstream follows the official ZSTD encoding order:

- **Encoder**: init seqN-1, extras LL→ML→OF, states ML→OF→LL, final states ML→OF→LL
- **Decoder**: read states LL→OF→ML, extras OF→ML→(reload)→LL, update LL→OF→ML

## Contributing / 贡献

Contributions welcome! Areas where help is appreciated:

- Performance optimization
- Huffman Literals compression integration
- Additional test cases
- Repeat Offset optimization

## License / 许可证

[Apache-2.0](LICENSE)

## Acknowledgments / 致谢

- [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878.html) — ZSTD specification
- [Facebook ZSTD](https://github.com/facebook/zstd) — Reference implementation
- [MoonBit](https://www.moonbitlang.com/) — The language that made this possible
