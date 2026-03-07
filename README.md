# MoonBit ZSTD

Pure MoonBit implementation of Zstandard (ZSTD) compression algorithm following RFC 8878.

## Highlights

- **Full Compression & Decompression** — LZ77 + FSE entropy coding
- **Official zstd Compatible** — Output verified with `zstd -d` v1.5.6/v1.5.7
- **26/26 Tests Passing** — All test categories passing
- **Pure MoonBit** — No C/FFI dependencies, runs on WASM

## Quick Start

```bash
moon run src/cmd    # Run demos + full test suite
```

### Basic Usage

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

## Features

### Compression

| Block Type | Description                             | Compression Ratio |
| ---------- | --------------------------------------- | ----------------- |
| Raw        | Uncompressed storage                    | 1:1               |
| RLE        | Run-length encoding for repetitive data | Up to 20:1        |
| Compressed | LZ77 + FSE (tANS) entropy coding        | 3:1 ~ 7:1 typical |

- 22 compression levels with configurable window size and search depth
- Automatic block type selection (Raw/RLE/Compressed)
- Multi-sequence LZ77 matching
- Predefined FSE tables per RFC 8878
- RLE Literals optimization
- Byte-compatible with official `zstd -d`

### Decompression

- All block types: Raw, RLE, Compressed
- FSE (tANS) decoding with backward bitstream
- Huffman literals decoding
- Sliding window with overlapping match copy
- Multi-block frame support
- Dictionary support

### Entropy Coding

- **FSE (tANS)**: Encoder + decoder with official spread algorithm
- **Huffman**: Encoder + decoder with canonical codes

### Dictionary

- Raw and ZSTD-format dictionary support
- Dictionary ID management
- Cover algorithm for dictionary building
- Dictionary-enhanced compression

## Test Results

```
Basic tests passed:                      11/11
Compatibility tests passed:               5/5
Dictionary tests passed:                  5/5
Non-compliance & cross-compat tests:      7/7
All tests passed! ✓
```

| Test Category               | Count | Status |
| --------------------------- | ----- | ------ |
| Basic Compression           | 11    | Passed |
| Compatibility tests         | 5     | Passed |
| Dictionary tests            | 5     | Passed |
| Non-compliance & cross-compat | 7   | Passed |
| **Total**                   | **26** | **All Passed** |

### Official Tool Verification

```bash
# Our encoder output → official zstd decoder
zstd -d moonbit_compressed.zst -o output.txt    # ✓ Content matches
```

## Compression Benchmark

Test data: `"The quick brown fox jumps over the lazy dog. "` repeated 10x (450 bytes)

| Method                    | Output Size | Ratio   |
| ------------------------- | ----------- | ------- |
| Raw Block                 | 460 bytes   | 0.98:1  |
| RLE Block (all-same data) | 10 bytes    | 20:1    |
| Compressed Block          | 64 bytes    | **7:1** |

## Project Structure

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

## API Reference

### Compression

```moonbit
fn compress(data: Bytes) -> Bytes
fn compress_with_level(data: Bytes, level: CompressionLevel) -> Bytes
fn compress_with_level_int(data: Bytes, level: Int) -> Bytes
fn compress_advanced(data: Bytes, mode: CompressionMethod, level: Int) -> Bytes
fn compress_as_raw(data: Bytes, level: Int) -> Bytes
fn compress_as_rle(data: Bytes, level: Int) -> Bytes
fn compress_as_compressed(data: Bytes, level: Int) -> Bytes
```

### Decompression

```moonbit
fn decompress(data: Bytes) -> Bytes
fn decompress_with_sliding_window(decoder: SlidingWindowDecoder, data: Bytes) -> Result[Bytes, String]
fn create_sliding_window_decoder(window_size: Int) -> SlidingWindowDecoder
```

### Analysis

```moonbit
fn analyze_file(data: Bytes) -> ZSTDFileAnalysis
fn is_zstd_format(data: Bytes) -> Bool
fn analyze_data_integrity(data: Bytes) -> DataIntegrityAnalysis
```

### Dictionary

```moonbit
fn compress_with_dictionary(data: Bytes, dictionary: Dictionary) -> Result[Bytes, String]
fn decompress_with_dictionary(data: Bytes, dictionary: Dictionary) -> Result[Bytes, String]
fn build_dictionary_with_cover(samples: Array[Bytes], target_size: Int, ngram_size: Int) -> Result[Dictionary, String]
```

## Implementation Status

### Completed

- [x] Full compression: Raw + RLE + Compressed blocks
- [x] Full decompression: All block types
- [x] FSE (tANS) encoder/decoder
- [x] Huffman encoder/decoder
- [x] Dictionary compression and decompression
- [x] Official `zstd -d` compatibility
- [x] 22 compression levels
- [x] Multi-sequence LZ77
- [x] Repeat Offset optimization
- [x] Multi-block frame compression

### Future Work

- [ ] Huffman Literals compression in encoder
- [ ] FSE Compressed mode (custom tables)
- [ ] Performance optimization
- [ ] Content checksum support

## Technical Details

### ZSTD Bitstream Format

Standard ZSTD bitstream structure:

1. **Frame Header**: Magic (0xFD2FB528) + FHD + Frame Content Size
2. **Block Header**: Last_Block flag + Block_Type + Block_Size
3. **Compressed Block**:
   - Literals Section (Raw or RLE)
   - Sequences Section (FSE-encoded)

FSE bitstream encoding order:
- **Encoder**: init seqN-1, extras LL→ML→OF, states ML→OF→LL
- **Decoder**: read states LL→OF→ML, extras OF→ML→LL, update LL→OF→ML

## Contributing

Contributions welcome! Areas of interest:

- Performance optimization
- Huffman Literals compression
- Additional test cases
- Repeat Offset optimization

## License

[Apache-2.0](LICENSE)

## Acknowledgments

- [RFC 8878](https://www.rfc-editor.org/rfc/rfc8878.html) — ZSTD specification
- [Facebook ZSTD](https://github.com/facebook/zstd) — Reference implementation
- [MoonBit](https://www.moonbitlang.com/) — The language
