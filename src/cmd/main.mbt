/// ZSTD MoonBit Implementation - Main Entry Point

fn init {}

fn main {
  println("MoonBit ZSTD Library Demo")
  println("==========================")
  
  run_demos()
  @zstd_examples.test_file_compression()
  
  // RFC 8878 Compliance: Official zstd tool compatibility
  @zstd_examples.test_user_official_file()
  
  // RFC 8878 Compliance: Batch test all official golden files
  @zstd_examples.test_all_golden_files()
  
  run_tests()
}

/// Run all demonstrations
fn run_demos() -> Unit {
  println("\n功能演示开始...")
  
  @zstd_examples.demo_basic_compression()
  @zstd_examples.demo_file_analysis()
  @zstd_examples.demo_data_integrity()
  @zstd_examples.demo_format_detection()
  @zstd_examples.demo_compression_levels()
  
  // 新增：压缩方法和级别演示
  @zstd_examples.demo_compression_methods()
  @zstd_examples.demo_compression_levels_advanced()
  @zstd_examples.demo_method_comparison()
  
  println("\n所有演示完成！")
  @zstd_examples.print_summary()
}

/// Run comprehensive test suite
fn run_tests() -> Unit {
  println("\n" + @zstd_test.repeat_string("=", 60))
  println("开始执行完整的 RFC 8878 兼容性测试")
  println(@zstd_test.repeat_string("=", 60))
  
  @zstd_test.run_official_test_suite()
  
  println("\n" + @zstd_test.repeat_string("=", 60))
  println("Running comprehensive test suite")
  println(@zstd_test.repeat_string("=", 60))
  
  let basic_tests_passed = @zstd_test.run_all_basic_tests()
  let compatibility_tests_passed = @zstd_test.run_all_compatibility_tests()
  let dictionary_tests_passed = @zstd_test.run_all_dictionary_tests()
  
  println("\nTest Results Summary:")
  println("Basic tests: " + (if basic_tests_passed { "PASSED" } else { "FAILED" }))
  println("Compatibility tests: " + (if compatibility_tests_passed { "PASSED" } else { "FAILED" }))
  println("Dictionary tests: " + (if dictionary_tests_passed { "PASSED" } else { "FAILED" }))
  
  if basic_tests_passed && compatibility_tests_passed && dictionary_tests_passed {
    println("\nAll tests passed! ZSTD implementation is working correctly.")
  } else {
    println("\nSome tests failed. Please check the implementation.")
  }
}

