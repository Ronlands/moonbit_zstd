/// RFC 8878 content checksum helpers.
///
/// ZSTD stores the low 32 bits of `XXH64(decoded_data, seed=0)` in little-endian
/// order when `Content_Checksum_Flag` is set.

let xxh64_prime1 : UInt64 = 0x9E3779B185EBCA87UL
let xxh64_prime2 : UInt64 = 0xC2B2AE3D27D4EB4FUL
let xxh64_prime3 : UInt64 = 0x165667B19E3779F9UL
let xxh64_prime4 : UInt64 = 0x85EBCA77C2B2AE63UL
let xxh64_prime5 : UInt64 = 0x27D4EB2F165667C5UL
let xxh64_seed : UInt64 = 0UL

pub struct XXH64State {
  seed: UInt64
  mut total_len: Int
  mut v1: UInt64
  mut v2: UInt64
  mut v3: UInt64
  mut v4: UInt64
  mut mem: Array[Byte]
}

fn xxh64_rotl(value: UInt64, count: Int) -> UInt64 {
  (value << count) | (value >> (64 - count))
}

fn xxh64_read_u32_from_array(data: Array[Byte], offset: Int) -> UInt {
  data[offset].to_uint() |
  (data[offset + 1].to_uint() << 8) |
  (data[offset + 2].to_uint() << 16) |
  (data[offset + 3].to_uint() << 24)
}

fn xxh64_read_u64(data: Bytes, offset: Int) -> UInt64 {
  data[offset].to_uint64() |
  (data[offset + 1].to_uint64() << 8) |
  (data[offset + 2].to_uint64() << 16) |
  (data[offset + 3].to_uint64() << 24) |
  (data[offset + 4].to_uint64() << 32) |
  (data[offset + 5].to_uint64() << 40) |
  (data[offset + 6].to_uint64() << 48) |
  (data[offset + 7].to_uint64() << 56)
}

fn xxh64_read_u64_from_array(data: Array[Byte], offset: Int) -> UInt64 {
  data[offset].to_uint64() |
  (data[offset + 1].to_uint64() << 8) |
  (data[offset + 2].to_uint64() << 16) |
  (data[offset + 3].to_uint64() << 24) |
  (data[offset + 4].to_uint64() << 32) |
  (data[offset + 5].to_uint64() << 40) |
  (data[offset + 6].to_uint64() << 48) |
  (data[offset + 7].to_uint64() << 56)
}

fn xxh64_round(acc: UInt64, input: UInt64) -> UInt64 {
  let acc = acc + input * xxh64_prime2
  let acc = xxh64_rotl(acc, 31)
  acc * xxh64_prime1
}

fn xxh64_merge_round(acc: UInt64, value: UInt64) -> UInt64 {
  let acc = acc ^ xxh64_round(0UL, value)
  acc * xxh64_prime1 + xxh64_prime4
}

fn xxh64_avalanche(hash: UInt64) -> UInt64 {
  let hash = hash ^ (hash >> 33)
  let hash = hash * xxh64_prime2
  let hash = hash ^ (hash >> 29)
  let hash = hash * xxh64_prime3
  hash ^ (hash >> 32)
}

fn xxh64_low32(hash: UInt64) -> UInt {
  (hash & 0xFFUL).to_byte().to_uint() |
  (((hash >> 8) & 0xFFUL).to_byte().to_uint() << 8) |
  (((hash >> 16) & 0xFFUL).to_byte().to_uint() << 16) |
  (((hash >> 24) & 0xFFUL).to_byte().to_uint() << 24)
}

pub fn new_xxh64_state() -> XXH64State {
  let mem: Array[Byte] = []
  XXH64State::{
    seed: xxh64_seed,
    total_len: 0,
    v1: xxh64_seed + xxh64_prime1 + xxh64_prime2,
    v2: xxh64_seed + xxh64_prime2,
    v3: xxh64_seed,
    v4: xxh64_seed - xxh64_prime1,
    mem: mem,
  }
}

fn xxh64_process_stripe_from_array(state: XXH64State, data: Array[Byte], offset: Int) -> Unit {
  state.v1 = xxh64_round(state.v1, xxh64_read_u64_from_array(data, offset))
  state.v2 = xxh64_round(state.v2, xxh64_read_u64_from_array(data, offset + 8))
  state.v3 = xxh64_round(state.v3, xxh64_read_u64_from_array(data, offset + 16))
  state.v4 = xxh64_round(state.v4, xxh64_read_u64_from_array(data, offset + 24))
}

fn xxh64_process_stripe_from_bytes(state: XXH64State, data: Bytes, offset: Int) -> Unit {
  state.v1 = xxh64_round(state.v1, xxh64_read_u64(data, offset))
  state.v2 = xxh64_round(state.v2, xxh64_read_u64(data, offset + 8))
  state.v3 = xxh64_round(state.v3, xxh64_read_u64(data, offset + 16))
  state.v4 = xxh64_round(state.v4, xxh64_read_u64(data, offset + 24))
}

pub fn update_xxh64_state(state: XXH64State, data: Bytes) -> Unit {
  if data.length() == 0 {
    return
  }

  state.total_len = state.total_len + data.length()
  let mut offset = 0

  if state.mem.length() + data.length() < 32 {
    for i = 0; i < data.length(); i = i + 1 {
      state.mem.push(data[i])
    }
    return
  }

  if state.mem.length() > 0 {
    let needed = 32 - state.mem.length()
    for i = 0; i < needed; i = i + 1 {
      state.mem.push(data[i])
    }
    xxh64_process_stripe_from_array(state, state.mem, 0)
    state.mem = []
    offset = needed
  }

  while offset + 32 <= data.length() {
    xxh64_process_stripe_from_bytes(state, data, offset)
    offset = offset + 32
  }

  while offset < data.length() {
    state.mem.push(data[offset])
    offset = offset + 1
  }
}

fn xxh64_digest_from_tail(input_hash: UInt64, tail: Array[Byte], total_len: Int) -> UInt64 {
  let mut hash = input_hash
  hash = hash + total_len.to_uint64()
  let mut offset = 0

  while offset + 8 <= tail.length() {
    let k1 = xxh64_round(0UL, xxh64_read_u64_from_array(tail, offset))
    hash = hash ^ k1
    hash = xxh64_rotl(hash, 27) * xxh64_prime1 + xxh64_prime4
    offset = offset + 8
  }

  if offset + 4 <= tail.length() {
    hash = hash ^ (xxh64_read_u32_from_array(tail, offset).to_uint64() * xxh64_prime1)
    hash = xxh64_rotl(hash, 23) * xxh64_prime2 + xxh64_prime3
    offset = offset + 4
  }

  while offset < tail.length() {
    hash = hash ^ (tail[offset].to_uint64() * xxh64_prime5)
    hash = xxh64_rotl(hash, 11) * xxh64_prime1
    offset = offset + 1
  }

  xxh64_avalanche(hash)
}

pub fn xxh64_state_digest_low32(state: XXH64State) -> UInt {
  let hash = if state.total_len >= 32 {
    let mut hash = xxh64_rotl(state.v1, 1) +
                   xxh64_rotl(state.v2, 7) +
                   xxh64_rotl(state.v3, 12) +
                   xxh64_rotl(state.v4, 18)
    hash = xxh64_merge_round(hash, state.v1)
    hash = xxh64_merge_round(hash, state.v2)
    hash = xxh64_merge_round(hash, state.v3)
    xxh64_merge_round(hash, state.v4)
  } else {
    state.seed + xxh64_prime5
  }

  xxh64_low32(xxh64_digest_from_tail(hash, state.mem, state.total_len))
}

pub fn zstd_content_checksum(data: Bytes) -> UInt {
  let state = new_xxh64_state()
  update_xxh64_state(state, data)
  xxh64_state_digest_low32(state)
}
