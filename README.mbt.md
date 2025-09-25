# Moonbit ZSTD

A pure Moonbit implementation of Zstandard (ZSTD) compression algorithm following RFC 8878.

## Overview

This library provides a complete implementation of the ZSTD compression algorithm in pure Moonbit, ensuring compatibility with the RFC 8878 specification. It includes both compression and decompression capabilities, with support for streaming operations.

## Features

- **RFC 8878 Compliant**: Strict adherence to the ZSTD specification
- **High Performance**: Optimized for speed and memory efficiency  
- **Pure Moonbit**: No external dependencies
- **Complete Implementation**: Both compression and decompression
- **Streaming Support**: Handle large data efficiently
- **Entropy Coding**: FSE and Huffman encoding/decoding
- **Block Types**: Support for Raw, RLE, and Compressed blocks

## Architecture

The library is organized into several modules:

### Core Modules
- `core/types.mbt` - Core data types and constants
- `core/bitstream.mbt` - Bit-level stream operations

### Entropy Coding
- `entropy/fse.mbt` - Finite State Entropy (FSE) implementation
- `entropy/huffman.mbt` - Huffman coding implementation

### Decoder
- `decoder/frame.mbt` - Frame format parsing
- `decoder/block.mbt` - Block decoding
- `decoder/decompressor.mbt` - Main decompressor

### Encoder
- `encoder/compressor.mbt` - Main compressor

### API
- `api/zstd.mbt` - High-level API functions

## Quick Start

```moonbit
import moonbit_zstd

// Basic compression
let original = "Hello, World!".to_bytes()
let compressed = moonbit_zstd::compress(original)
let decompressed = moonbit_zstd::decompress(compressed)

// Streaming compression
let compressor = moonbit_zstd::create_compressor()
let (new_compressor, compressed) = moonbit_zstd::compress_with_compressor(compressor, data)
```

## API Reference

### High-level Functions

- `compress(data: Bytes) -> Bytes` - Compress data
- `decompress(data: Bytes) -> Bytes` - Decompress data
- `get_compression_ratio(original: Int, compressed: Int) -> Double` - Calculate compression ratio
- `is_zstd_data(data: Bytes) -> Bool` - Check if data is ZSTD compressed

### Streaming API

- `create_compressor() -> Compressor` - Create compressor for streaming
- `create_decompressor() -> Decompressor` - Create decompressor for streaming
- `compress_with_compressor(compressor: Compressor, data: Bytes) -> (Compressor, Bytes)`
- `decompress_with_decompressor(decompressor: Decompressor, data: Bytes) -> (Decompressor, Bytes)`

## Implementation Details

### Frame Format
The implementation follows the ZSTD frame format specification:
- Magic number: 0x2D_52_28_B5
- Frame header with window size, dictionary ID, content size
- Block headers with type and size information

### Block Types
- **Raw**: Uncompressed data
- **RLE**: Run-length encoded data  
- **Compressed**: Entropy-coded data with sequences

### Entropy Coding
- **FSE**: Finite State Entropy for sequence encoding
- **Huffman**: Huffman coding for literal encoding

### Sequence Execution
The decoder executes sequences to reconstruct the original data:
- Copy literals directly
- Copy matches from the sliding window
- Maintain decompression context

## Testing

The library includes comprehensive tests:
- Basic functionality tests
- Compatibility tests with RFC 8878
- Round-trip compression tests
- Edge case handling

Run tests with:
```moonbit
import tests::basic_tests::{run_basic_tests}
import tests::compatibility_tests::{run_compatibility_tests}

run_basic_tests()
run_compatibility_tests()
```

## Examples

See the `examples/` directory for usage examples:
- `basic_usage.mbt` - Basic compression/decompression
- `streaming_usage.mbt` - Streaming operations

## Performance

The implementation is optimized for:
- Fast decompression (primary use case)
- Memory efficiency
- Streaming support for large data

## License

Apache-2.0

## Contributing

This is a reference implementation following RFC 8878. Contributions are welcome for:
- Performance optimizations
- Additional test cases
- Documentation improvements