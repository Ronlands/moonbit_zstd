# Moonbit ZSTD Architecture

## Project Structure

```
moonbit_zstd/
├── src/
│   ├── core/                    # Core types and utilities
│   │   ├── types.mbt           # Core data types and constants
│   │   └── bitstream.mbt       # Bit-level stream operations
│   ├── entropy/                # Entropy coding implementations
│   │   ├── fse.mbt            # Finite State Entropy (FSE)
│   │   └── huffman.mbt        # Huffman coding
│   ├── decoder/               # Decompression components
│   │   ├── frame.mbt          # Frame format parsing
│   │   ├── block.mbt          # Block decoding
│   │   └── decompressor.mbt   # Main decompressor
│   ├── encoder/               # Compression components
│   │   └── compressor.mbt     # Main compressor
│   ├── api/                   # High-level API
│   │   └── zstd.mbt          # Public API functions
│   ├── tests/                 # Test suites
│   │   ├── basic_tests.mbt   # Basic functionality tests
│   │   └── compatibility_tests.mbt # RFC 8878 compliance tests
│   ├── examples/              # Usage examples
│   │   ├── basic_usage.mbt   # Basic compression examples
│   │   └── streaming_usage.mbt # Streaming examples
│   ├── cmd/main/              # Main program
│   │   └── main.mbt          # Entry point and demo
│   ├── moonbit_zstd.mbt      # Main library module
│   └── moon.pkg.json         # Package configuration
├── README.md                  # Project documentation
├── README.mbt.md             # Detailed technical documentation
├── ARCHITECTURE.md           # This file
└── moon.mod.json            # Module configuration
```

## Module Dependencies

```
moonbit_zstd.mbt
├── api/zstd.mbt
│   ├── decoder/decompressor.mbt
│   │   ├── decoder/frame.mbt
│   │   ├── decoder/block.mbt
│   │   └── core/types.mbt
│   └── encoder/compressor.mbt
│       └── core/types.mbt
├── core/types.mbt
├── core/bitstream.mbt
├── entropy/fse.mbt
├── entropy/huffman.mbt
└── cmd/main/main.mbt
```

## Key Components

### Core Layer
- **types.mbt**: Defines all core data structures (FrameHeader, BlockHeader, Sequence, etc.)
- **bitstream.mbt**: Provides bit-level reading operations for entropy decoding

### Entropy Coding Layer
- **fse.mbt**: Implements Finite State Entropy for sequence encoding/decoding
- **huffman.mbt**: Implements Huffman coding for literal encoding/decoding

### Decoder Layer
- **frame.mbt**: Parses ZSTD frame headers according to RFC 8878
- **block.mbt**: Decodes different block types (Raw, RLE, Compressed)
- **decompressor.mbt**: Main decompression logic with context management

### Encoder Layer
- **compressor.mbt**: Main compression logic with LZ77-style matching

### API Layer
- **zstd.mbt**: High-level API functions for easy usage

## Data Flow

### Compression Flow
```
Input Data → Compressor → Find Sequences → Build Entropy Tables → 
Encode Literals (Huffman) → Encode Sequences (FSE) → 
Build Compressed Blocks → Generate Frame Header → Output
```

### Decompression Flow
```
Input Data → Parse Frame Header → Parse Block Headers → 
Decode Literals (Huffman) → Decode Sequences (FSE) → 
Execute Sequences → Reconstruct Data → Output
```

## RFC 8878 Compliance

The implementation follows RFC 8878 specification:

1. **Frame Format**: Magic number, frame descriptor, window descriptor
2. **Block Types**: Raw, RLE, Compressed blocks
3. **Entropy Coding**: FSE for sequences, Huffman for literals
4. **Sequence Execution**: Proper handling of literal lengths, match lengths, and offsets

## Performance Considerations

- **Memory Management**: Efficient sliding window implementation
- **Bit Operations**: Optimized bit stream reading
- **Context Management**: Proper state handling for streaming
- **Algorithm Efficiency**: LZ77-style matching for compression

## Testing Strategy

- **Unit Tests**: Individual component testing
- **Integration Tests**: End-to-end compression/decompression
- **Compatibility Tests**: RFC 8878 compliance verification
- **Performance Tests**: Memory and speed benchmarks

## Extension Points

The modular architecture allows for:
- Custom compression parameters
- Additional entropy coding methods
- Specialized block types
- Performance optimizations
- Streaming enhancements

