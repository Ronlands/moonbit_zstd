/// Sequence encoding/decoding tables from ZSTD RFC 8878
/// These tables define how to encode and decode sequence symbols

// ============================================================================
// Literal Length Tables
// ============================================================================

/// Baseline values for Literal Length codes (0-35)
let ll_base : Array[Int] = [
  0,    1,    2,     3,     4,     5,     6,      7,
  8,    9,   10,    11,    12,    13,    14,     15,
 16,   18,   20,    22,    24,    28,    32,     40,
 48,   64, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000,
 0x2000, 0x4000, 0x8000, 0x10000
]

/// Number of additional bits to read for Literal Length codes (0-35)
let ll_bits : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0,   // 0-7
  0, 0, 0, 0, 0, 0, 0, 0,   // 8-15
  1, 1, 1, 1, 2, 2, 3, 3,   // 16-23
  4, 6, 7, 8, 9, 10, 11, 12, // 24-31
  13, 14, 15, 16              // 32-35
]

// ============================================================================
// Match Length Tables
// ============================================================================

/// Baseline values for Match Length codes (0-52)
let ml_base : Array[Int] = [
  3,4,5,6,7,8,9,10,         // 0-7: 0 bits
 11,12,13,14,15,16,17,18,    // 8-15: 0 bits
 19,20,21,22,23,24,25,26,    // 16-23: 0 bits
 27,28,29,30,31,32,33,34,    // 24-31: 0 bits
 35,37,39,41,43,47,51,59,    // 32-39: 1-3 bits
 67,83,115,171,259,499,995,1987, // 40-47: 4-11 bits
3751,7925,16331,32763,65531       // 48-52: 12-16 bits
]

/// Number of additional bits to read for Match Length codes
let ml_bits : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0,  // 0-7
  0, 0, 0, 0, 0, 0, 0, 0,  // 8-15
  0, 0, 0, 0, 0, 0, 0, 0,  // 16-23
  0, 0, 0, 0, 0, 0, 0, 0,  // 24-31
  1, 1, 1, 1, 2, 2, 3, 3,  // 32-39
  4, 4, 5, 7, 8, 9,10,11,  // 40-47
 12,13,14,15,16               // 48-52
]

// ============================================================================
// Offset Tables
// ============================================================================

/// Baseline values for Offset codes (0-31)
/// 官方 ZSTD 库的 OF_base 表 (zstd_decompress_internal.h line 37-41)
/// 公式: OF_base[n] = (1 << n) + (1 << n) - 3 (for n >= 2)
pub let of_base : Array[Int] = [
  0,        1,       1,       5,     0xD,     0x1D,     0x3D,     0x7D,
  0xFD,   0x1FD,   0x3FD,   0x7FD,   0xFFD,   0x1FFD,   0x3FFD,   0x7FFD,
  0xFFFD, 0x1FFFD, 0x3FFFD, 0x7FFFD, 0xFFFFD, 0x1FFFFD, 0x3FFFFD, 0x7FFFFD,
  0xFFFFFD, 0x1FFFFFD, 0x3FFFFFD, 0x7FFFFFD, 0xFFFFFFD, 0x1FFFFFFD, 0x3FFFFFFD, 0x7FFFFFFF
]

/// Number of additional bits to read for Offset codes
pub let of_bits : Array[Int] = [
  0,  1,  2,  3,  4,  5,  6,  7,
  8,  9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23,
  24, 25, 26, 27, 28, 29, 30, 31
]

// ============================================================================
// Helper Functions
// ============================================================================

/// Decode Literal Length from code (FSE symbol)
pub fn decode_ll(code: Int, extra_bits: Int) -> Int {
  if code < 0 || code >= ll_base.length() {
    0
  } else {
    ll_base[code] + extra_bits
  }
}

/// Decode Match Length from code (FSE symbol)
pub fn decode_ml(code: Int, extra_bits: Int) -> Int {
  if code < 0 || code >= ml_base.length() {
    3  // MINMATCH
  } else {
    // ML_base 表已经包含了最终的 matchLength（包括 MINMATCH）
    // 官方: matchLength = ML_base[code] + extra_bits （不需要再加 MINMATCH）
    ml_base[code] + extra_bits
  }
}

/// Decode Offset from code (FSE symbol).
/// Returns the raw offset value: 0 for the special repeat sentinel (of_code=0),
/// 1 or 2 for repeat codes (of_code=1), or the copy distance for direct offsets (of_code>=2).
pub fn decode_of(code: Int, extra_bits: Int) -> Int {
  if code < 0 || code >= of_base.length() {
    0
  } else {
    of_base[code] + extra_bits
  }
}

/// Get number of extra bits for LL code
pub fn get_ll_bits(code: Int) -> Int {
  if code < 0 || code >= ll_bits.length() {
    0
  } else {
    ll_bits[code]
  }
}

/// Get number of extra bits for ML code
pub fn get_ml_bits(code: Int) -> Int {
  if code < 0 || code >= ml_bits.length() {
    0
  } else {
    ml_bits[code]
  }
}

/// Get number of extra bits for OF code
pub fn get_of_bits(code: Int) -> Int {
  if code < 0 || code >= of_bits.length() {
    0
  } else {
    of_bits[code]
  }
}

/// Encode Literal Length to code (finds the matching code for a given LL value)
pub fn encode_ll(literal_length: Int) -> (Int, Int) {
  // Find the largest code where ll_base[code] <= literal_length
  let mut code = 0
  for i = 0; i < ll_base.length(); i = i + 1 {
    if ll_base[i] <= literal_length {
      code = i
    } else {
      break
    }
  }
  let extra_bits = literal_length - ll_base[code]
  (code, extra_bits)
}

/// Encode Match Length to code (finds the matching code for a given ML value)
pub fn encode_ml(match_length: Int) -> (Int, Int) {
  // ML_base 表已经包含了最终的 matchLength（包括 MINMATCH）
  // 直接查找 ML_base[code] <= match_length 的最大 code
  if match_length < 3 {
    return (0, 0)
  }
  
  // Find the largest code where ml_base[code] <= match_length
  let mut code = 0
  for i = 0; i < ml_base.length(); i = i + 1 {
    if ml_base[i] <= match_length {
      code = i
    } else {
      break
    }
  }
  let extra_bits = match_length - ml_base[code]
  (code, extra_bits)
}

/// Encode Offset to code (finds the matching code for a given offset value)
/// Note: offset must be >= 1. Returns error for invalid offsets.
pub fn encode_of(offset: Int) -> Result[(Int, Int), String] {
  if offset < 1 {
    return Err("Invalid offset: must be >= 1")
  }

  // Find the largest code where of_base[code] <= offset
  let mut code = 0
  for i = 0; i < of_base.length(); i = i + 1 {
    if of_base[i] <= offset {
      code = i
    } else {
      break
    }
  }
  let extra_bits = offset - of_base[code]
  Ok((code, extra_bits))
}

