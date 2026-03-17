/// Performance Benchmark for ZSTD

struct BenchmarkResult {
  name: String
  data_size: Int
  compressed_size: Int
  compression_ratio: Double
}

fn format_size(bytes: Int) -> String {
  if bytes < 1024 { "\{bytes}B" }
  else if bytes < 1024 * 1024 { "\{bytes / 1024}KB" }
  else { "\{bytes / (1024 * 1024)}MB" }
}

pub fn run_benchmark(name: String, data: Bytes, level: Int) -> Result[BenchmarkResult, String] {
  let config = @encoder.create_config_with_level(level)

  match @encoder.compress_data(data, config) {
    Ok(compressed) => {
      match @decoder.decompress_zstd_data(compressed) {
        Ok(_decompressed) => {
          let ratio = data.length().to_double() / compressed.length().to_double()
          Ok(BenchmarkResult::{
            name,
            data_size: data.length(),
            compressed_size: compressed.length(),
            compression_ratio: ratio
          })
        }
        Err(e) => Err(e)
      }
    }
    Err(e) => Err(e)
  }
}

pub fn print_result(r: BenchmarkResult) -> Unit {
  println("\{r.name}:")
  println("  原始大小: \{format_size(r.data_size)}")
  println("  压缩大小: \{format_size(r.compressed_size)}")
  println("  压缩率: \{r.compression_ratio}x")
}

pub fn run_all_benchmarks() -> Unit {
  println("=== ZSTD 性能基准测试 ===\n")

  let text_1kb = Bytes::make(1024, 0x41)
  match run_benchmark("1KB 文本", text_1kb, 3) {
    Ok(r) => print_result(r)
    Err(e) => println("错误: \{e}")
  }

  let repeat_10kb = Bytes::make(10240, 0x42)
  match run_benchmark("10KB 重复", repeat_10kb, 3) {
    Ok(r) => print_result(r)
    Err(e) => println("错误: \{e}")
  }

  let mixed_100kb = generate_mixed_data(102400)
  match run_benchmark("100KB 混合", mixed_100kb, 3) {
    Ok(r) => print_result(r)
    Err(e) => println("错误: \{e}")
  }

  println("\n测试完成")
}

fn generate_mixed_data(size: Int) -> Bytes {
  let arr: Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    arr.push(((i * 7 + 13) % 256).to_byte())
  }
  Bytes::from_array(arr)
}
