# Moonbit ZSTD Build Guide

## Prerequisites

- Moonbit compiler and runtime
- Git (for version control)

## Building the Project

### 1. Clone the Repository
```bash
git clone <repository-url>
cd moonbit_zstd
```

### 2. Build the Library
```bash
# Build the main library
moon build

# Build with tests
moon test

# Build examples
moon run examples
```

### 3. Run Tests
```bash
# Run basic tests
moon run tests::basic_tests

# Run compatibility tests  
moon run tests::compatibility_tests

# Run all tests
moon test
```

### 4. Run Examples
```bash
# Run basic usage examples
moon run examples::basic_usage

# Run streaming examples
moon run examples::streaming_usage

# Run main demo
moon run cmd::main
```

## Development Workflow

### 1. Make Changes
Edit the source files in `src/` directory

### 2. Test Changes
```bash
moon test
```

### 3. Run Examples
```bash
moon run cmd::main
```

### 4. Check Linting
```bash
moon check
```

## Project Structure

```
moonbit_zstd/
├── src/                    # Source code
│   ├── core/              # Core types and utilities
│   ├── entropy/           # Entropy coding
│   ├── decoder/           # Decompression
│   ├── encoder/           # Compression
│   ├── api/               # Public API
│   ├── tests/             # Test suites
│   ├── examples/          # Usage examples
│   └── cmd/               # Main programs
├── README.md              # Project overview
├── README.mbt.md         # Technical documentation
├── ARCHITECTURE.md       # Architecture details
├── BUILD.md              # This file
└── moon.mod.json         # Module configuration
```

## API Usage

### Basic Usage
```moonbit
import moonbit_zstd

// Compress data
let original = "Hello, World!".to_bytes()
let compressed = moonbit_zstd::compress(original)

// Decompress data
let decompressed = moonbit_zstd::decompress(compressed)
```

### Streaming Usage
```moonbit
import moonbit_zstd

// Create compressor
let compressor = moonbit_zstd::create_compressor()

// Compress in chunks
let (new_compressor, compressed) = moonbit_zstd::compress_with_compressor(compressor, data)

// Create decompressor
let decompressor = moonbit_zstd::create_decompressor()

// Decompress in chunks
let (new_decompressor, decompressed) = moonbit_zstd::decompress_with_decompressor(decompressor, compressed)
```

## Performance Testing

### Benchmark Compression
```moonbit
import moonbit_zstd

let data = generate_test_data(1024 * 1024) // 1MB
let start_time = get_current_time()
let compressed = moonbit_zstd::compress(data)
let compression_time = get_current_time() - start_time

let start_time = get_current_time()
let decompressed = moonbit_zstd::decompress(compressed)
let decompression_time = get_current_time() - start_time
```

## Troubleshooting

### Common Issues

1. **Build Errors**: Check Moonbit version compatibility
2. **Test Failures**: Verify test data and expected outputs
3. **Memory Issues**: Check for proper context management
4. **Performance Issues**: Profile compression/decompression functions

### Debug Mode

Enable debug output by setting environment variables:
```bash
export MOONBIT_DEBUG=1
moon run cmd::main
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Run full test suite
5. Submit pull request

## License

Apache-2.0 - See LICENSE file for details

