/// Performance Benchmark for ZSTD

struct BenchmarkResult {
  name: String
  data_size: Int
  compressed_size: Int
  compression_time_ms: Int
  decompression_time_ms: Int
  compression_ratio: Double
}

// FFI: 获取当前时间戳（毫秒）
extern "js" fn now_ms() -> Double =
  #| () => Date.now()

fn get_time_ms() -> Int {
  now_ms().to_int()
}

fn format_size(bytes: Int) -> String {
  if bytes < 1024 { "\{bytes}B" }
  else if bytes < 1024 * 1024 { "\{bytes / 1024}KB" }
  else { "\{bytes / (1024 * 1024)}MB" }
}

pub fn run_benchmark(name: String, data: Bytes, level: Int) -> Result[BenchmarkResult, String] {
  let config = @compressor.create_config_with_level(level)

  let start = get_time_ms()
  let compressed = @compressor.compress_data(data, config)?
  let compress_time = get_time_ms() - start

  let start2 = get_time_ms()
  let _decompressed = @decompressor.decompress_data(compressed)?
  let decompress_time = get_time_ms() - start2

  let ratio = data.length().to_double() / compressed.length().to_double()

  Ok(BenchmarkResult::{
    name,
    data_size: data.length(),
    compressed_size: compressed.length(),
    compression_time_ms: compress_time,
    decompression_time_ms: decompress_time,
    compression_ratio: ratio
  })
}

pub fn print_result(r: BenchmarkResult) -> Unit {
  println("\{r.name}:")
  println("  原始大小: \{format_size(r.data_size)}")
  println("  压缩大小: \{format_size(r.compressed_size)}")
  println("  压缩率: \{r.compression_ratio}x")
  if r.compression_time_ms > 0 {
    let speed_mb = r.data_size / (r.compression_time_ms * 1024)
    println("  压缩速度: \{speed_mb} MB/s")
  }
  if r.decompression_time_ms > 0 {
    let speed_mb = r.data_size / (r.decompression_time_ms * 1024)
    println("  解压速度: \{speed_mb} MB/s")
  }
}

pub fn run_all_benchmarks() -> Unit {
  println("=== ZSTD 性能基准测试 ===\n")

  // 1KB 文本
  let text_1kb = Bytes::make(1024, 0x41)
  match run_benchmark("1KB 文本", text_1kb, 3) {
    Ok(r) => print_result(r)
    Err(e) => println("错误: \{e}")
  }

  // 10KB 重复数据
  let repeat_10kb = Bytes::make(10240, 0x42)
  match run_benchmark("10KB 重复", repeat_10kb, 3) {
    Ok(r) => print_result(r)
    Err(e) => println("错误: \{e}")
  }

  // 100KB 混合数据
  let mixed_100kb = generate_mixed_data(102400)
  match run_benchmark("100KB 混合", mixed_100kb, 3) {
    Ok(r) => print_result(r)
    Err(e) => println("错误: \{e}")
  }

  // 1MB 数据
  let data_1mb = generate_mixed_data(1024 * 1024)
  match run_benchmark("1MB 混合", data_1mb, 3) {
    Ok(r) => print_result(r)
    Err(e) => println("错误: \{e}")
  }

  // JSON 模拟数据
  let json_data = generate_json_like_data(50000)
  match run_benchmark("50KB JSON", json_data, 3) {
    Ok(r) => print_result(r)
    Err(e) => println("错误: \{e}")
  }

  // 高熵数据（难压缩）
  let high_entropy = generate_high_entropy_data(10240)
  match run_benchmark("10KB 高熵", high_entropy, 3) {
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

fn generate_json_like_data(size: Int) -> Bytes {
  let arr: Array[Byte] = []
  let pattern = b"{\"key\":\"value\",\"num\":123}"
  let pattern_len = pattern.length()
  for i = 0; i < size; i = i + 1 {
    arr.push(pattern[i % pattern_len])
  }
  Bytes::from_array(arr)
}

fn generate_high_entropy_data(size: Int) -> Bytes {
  let arr: Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    arr.push(((i * 31 + i * i * 17 + 97) % 256).to_byte())
  }
  Bytes::from_array(arr)
}
