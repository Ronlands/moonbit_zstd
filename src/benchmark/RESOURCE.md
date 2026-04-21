# Benchmark 模块资源

## 1. 模块定位

- 路径：`src/benchmark`
- 主文件：`src/benchmark/benchmark.mbt`
- 职责：对样本执行压缩与回解压校验，并输出压缩统计结果。

## 2. 核心类型

### 2.1 `BenchmarkResult`

- 字段：
  - `name`：样本名称
  - `data_size`：原始数据大小，字节
  - `compressed_size`：压缩后大小，字节
  - `compression_ratio`：压缩比，`x`

## 3. 统计口径

- 公式：`compression_ratio = data_size / compressed_size`
- 展示单位：
  - 大小：字节，打印时会格式化为 `B / KB / MB`
  - 比率：`x`

## 4. 运行口径

- `run_benchmark`：
  1. 生成压缩配置
  2. 压缩数据
  3. 立即回解压校验
  4. 生成基准结果对象
- `run_all_benchmarks`：当前覆盖 `1KB`、`10KB`、`100KB` 等样本。

## 5. 注意事项

- 本模块的 `BenchmarkResult` 当前未声明为 `pub struct`，但仍是重要结果对象，文档保留其口径说明供维护时参考。
