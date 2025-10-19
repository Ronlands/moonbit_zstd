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

/// Number of additional bits to read for Literal Length codes
let ll_bits : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 2, 2, 3, 3,
  4, 6, 7, 8, 9,10,11,12,
  13,14,15,16
]

// ============================================================================
// Match Length Tables
// ============================================================================

/// Baseline values for Match Length codes (0-52)
let ml_base : Array[Int] = [
  3,  4,  5,    6,     7,     8,     9,    10,
  11, 12, 13,   14,    15,    16,    17,    18,
  19, 20, 21,   22,    23,    24,    25,    26,
  27, 28, 29,   30,    31,    32,    33,    34,
  35, 37, 39,   41,    43,    47,    51,    59,
  67, 83, 99, 0x83, 0x103, 0x203, 0x403, 0x803,
  0x1003, 0x2003, 0x4003, 0x8003, 0x10003
]

/// Number of additional bits to read for Match Length codes
let ml_bits : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 2, 2, 3, 3,
  4, 4, 5, 7, 8, 9,10,11,
  12,13,14,15,16
]

// ============================================================================
// Offset Tables
// ============================================================================

/// Baseline values for Offset codes (0-31)
let of_base : Array[Int] = [
  0,        1,       1,       5,     0xD,     0x1D,     0x3D,     0x7D,
  0xFD,   0x1FD,   0x3FD,   0x7FD,   0xFFD,   0x1FFD,   0x3FFD,   0x7FFD,
  0xFFFD, 0x1FFFD, 0x3FFFD, 0x7FFFD, 0xFFFFD, 0x1FFFFD, 0x3FFFFD, 0x7FFFFD,
  0xFFFFFD, 0x1FFFFFD, 0x3FFFFFD, 0x7FFFFFD, 0xFFFFFFD, 0x1FFFFFFD, 0x3FFFFFFD, 0x7FFFFFFD
]

/// Number of additional bits to read for Offset codes
let of_bits : Array[Int] = [
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
    // matchLength = mlBase + MINMATCH
    ml_base[code] + extra_bits + 3
  }
}

/// Decode Offset from code (FSE symbol)
pub fn decode_of(code: Int, extra_bits: Int) -> Int {
  if code < 0 || code >= of_base.length() {
    1
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
  // mlBase = matchLength - MINMATCH(3)
  let ml_base_value = (match_length - 3).max(0)
  
  // Find the largest code where ml_base[code] <= ml_base_value
  let mut code = 0
  for i = 0; i < ml_base.length(); i = i + 1 {
    if ml_base[i] <= ml_base_value {
      code = i
    } else {
      break
    }
  }
  let extra_bits = ml_base_value - ml_base[code]
  (code, extra_bits)
}

/// Encode Offset to code (finds the matching code for a given offset value)
pub fn encode_of(offset: Int) -> (Int, Int) {
  if offset <= 0 {
    return (0, 0)
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
  (code, extra_bits)
}

