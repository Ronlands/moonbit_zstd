/// Common test utilities
/// Shared helper functions for all test modules

/// Repeat a string n times
pub fn repeat_string(s: String, n: Int) -> String {
  let mut result = ""
  for _i = 0; _i < n; _i = _i + 1 {
    result = result + s
  }
  result
}

/// Verify two byte sequences are equal
pub fn verify_data_equal(a: Bytes, b: Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  
  let mut equal = true
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      equal = false
      break
    }
  }
  equal
}

/// Run a test suite and report results
pub fn run_test_suite(name: String, tests: Array[(String, Bool)]) -> Bool {
  let mut passed = 0
  let total = tests.length()
  for i = 0; i < tests.length(); i = i + 1 {
    if tests[i].1 {
      passed = passed + 1
    }
  }
  
  println("\{name} passed: \{passed}/\{total}")
  passed == total
}

