fn concat_bytes(left: Bytes, right: Bytes) -> Bytes {
  let out: Array[Byte] = []
  for i = 0; i < left.length(); i = i + 1 {
    out.push(left[i])
  }
  for i = 0; i < right.length(); i = i + 1 {
    out.push(right[i])
  }
  Bytes::from_array(out)
}

fn round_trip_with_api(data: Bytes) -> Bool {
  let compressed = match @zstd.compress(data) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  match @zstd.decompress(compressed) {
    Ok(decoded) => verify_data_equal(data, decoded)
    Err(_) => false
  }
}

fn test_public_decompress_result_contract() -> Bool {
  let empty = Bytes::new(0)
  let empty_frame = match @zstd.compress(empty) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  let empty_ok = match @zstd.decompress(empty_frame) {
    Ok(decoded) => decoded.length() == 0
    Err(_) => false
  }

  let invalid_magic = match @zstd.decompress(Bytes::from_array([0x00, 0x01, 0x02, 0x03])) {
    Err(_) => true
    Ok(_) => false
  }

  let truncated = match @zstd.decompress(Bytes::from_array([0x28, 0xB5, 0x2F, 0xFD, 0x20])) {
    Err(_) => true
    Ok(_) => false
  }

  let missing_block_header = match @zstd.decompress(Bytes::from_array([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00])) {
    Err(_) => true
    Ok(_) => false
  }

  let missing_last_block = match @zstd.decompress(Bytes::from_array([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00, 0x00, 0x00, 0x00])) {
    Err(_) => true
    Ok(_) => false
  }

  let reserved_bit = match @zstd.decompress(Bytes::from_array([0x28, 0xB5, 0x2F, 0xFD, 0x28, 0x00, 0x01, 0x00, 0x00])) {
    Err(_) => true
    Ok(_) => false
  }

  empty_ok && invalid_magic && truncated && missing_block_header && missing_last_block && reserved_bit
}

fn test_trailing_garbage_rejected() -> Bool {
  let frame = match @zstd.compress(@utf8.encode("abc")) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  let garbage = Bytes::from_array([0x99, 0x88, 0x77])
  match @zstd.decompress(concat_bytes(frame, garbage)) {
    Err(_) => true
    Ok(_) => false
  }
}

fn test_release_round_trips() -> Bool {
  let raw_ok = round_trip_with_api(@utf8.encode("raw block input"))
  let rle_ok = round_trip_with_api(Bytes::make(256, 0x41))

  let large = Bytes::make(200000, 0x42)
  let multiblock_ok = round_trip_with_api(large)

  let left = @utf8.encode("left")
  let right = @utf8.encode("right")
  let left_frame = match @zstd.compress(left) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  let right_frame = match @zstd.compress(right) {
    Ok(bytes) => bytes
    Err(_) => return false
  }
  let concat_ok = match @zstd.decompress(concat_bytes(left_frame, right_frame)) {
    Ok(decoded) => verify_data_equal(@utf8.encode("leftright"), decoded)
    Err(_) => false
  }

  let mut compressed_text = ""
  for _i = 0; _i < 10; _i = _i + 1 {
    compressed_text = compressed_text + "AAAA BBBB CCCC "
  }
  let compressed_subset_ok = round_trip_with_api(@utf8.encode(compressed_text))

  raw_ok && rle_ok && multiblock_ok && concat_ok && compressed_subset_ok
}

test "release public decompress contract" {
  inspect(test_public_decompress_result_contract(), content="true")
}

test "release trailing garbage is rejected" {
  inspect(test_trailing_garbage_rejected(), content="true")
}

test "release round trips" {
  inspect(test_release_round_trips(), content="true")
}

test "existing boolean suites" {
  inspect(run_all_basic_tests(), content="true")
  inspect(run_all_compatibility_tests(), content="true")
  inspect(run_all_dictionary_tests(), content="true")
  inspect(run_all_noncompliance_tests(), content="true")
}
