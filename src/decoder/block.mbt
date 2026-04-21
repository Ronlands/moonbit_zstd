/// ZSTD Block Decompression

// ============================================================================
// Decoder Context for Sliding Window Management
// ============================================================================

/// Decoder context for maintaining sliding window across blocks
pub struct DecoderContext {
  window: @zstd_core.WindowBuffer  // 滑动窗口
  window_size: Int                 // 窗口大小
  mut total_decoded: Int          // 总共解码的字节数
}

/// 确保权重数组具有正确的长度，用0填充缺失的元素
fn ensure_weights_length(weights: Array[Int], expected_length: Int) -> Array[Int] {
  if weights.length() >= expected_length {
    // 如果已经够长，返回前expected_length个元素
    let result: Array[Int] = []
    for i = 0; i < expected_length; i = i + 1 {
      result.push(weights[i])
    }
    result
  } else {
    // 如果太短，用0填充
    let result = weights
    for _i = weights.length(); _i < expected_length; _i = _i + 1 {
      result.push(0)
    }
    result
  }
}

/// Create new decoder context
pub fn create_decoder_context(window_size: Int) -> DecoderContext {
  let window = create_window(window_size.max(1024))
  DecoderContext::{
    window: window,
    window_size: window_size,
    total_decoded: 0
  }
}

/// Add decoded data to sliding window
fn add_decoded_data_to_window(ctx: DecoderContext, data: Bytes) -> Result[Unit, String] {
  let max_output_size = 134217728 // 128MB limit

  if data.length() > max_output_size {
    return Err("Input data exceeds 128MB limit")
  }

  if ctx.total_decoded + data.length() > max_output_size {
    return Err("Cumulative output exceeds 128MB limit")
  }

  let _ = @zstd_core.get_window_buffer(ctx.window)

  for i = 0; i < data.length(); i = i + 1 {
    add_to_window(ctx.window, data[i])
  }

  ctx.total_decoded = ctx.total_decoded + data.length()
  Ok(())
}

/// 预加载历史数据到解码上下文窗口。
///
/// 用途：
/// - 为同帧后续块提供历史引用基础
/// - 为带字典解压把字典内容预热到窗口中
pub fn preload_history_into_context(ctx: DecoderContext, data: Bytes) -> Result[Unit, String] {
  add_decoded_data_to_window(ctx, data)
}

/// Get current window buffer
fn get_decoder_window(ctx: DecoderContext) -> @zstd_core.WindowBuffer {
  ctx.window
}

// ============================================================================
// Block Header Parsing
// ============================================================================

/// Parse block header from data
fn parse_block_header(data: Bytes, offset: Int) -> Result[(@zstd_core.BlockHeader, Int), String] {
  if offset + 3 > data.length() {
    return Err("Insufficient data for block header")
  }
  
  let header_bytes = data[offset].to_int() | 
                    (data[offset + 1].to_int() << 8) |
                    (data[offset + 2].to_int() << 16)
  
  let last_block = (header_bytes & 1) == 1
  let block_type_int = (header_bytes >> 1) & 3
  let block_size = header_bytes >> 3
  
  let block_type = match block_type_int {
    0 => @zstd_core.raw_block_type()
    1 => @zstd_core.rle_block_type()
    2 => @zstd_core.compressed_block_type()
    _ => @zstd_core.reserved_block_type()
  }
  
  let header = @zstd_core.make_block_header(block_type, block_size, last_block)
  
  Ok((header, 3))
}

// ============================================================================
// Raw Block Decompression
// ============================================================================

/// Decompress a raw block
fn decompress_raw_block(data: Bytes, offset: Int, size: Int) -> Result[Bytes, String] {
  if offset + size > data.length() {
    return Err("Insufficient data for raw block")
  }
  
  let mut result: Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    result = result + [data[offset + i]]
  }
  
  Ok(Bytes::from_array(result))
}

// ============================================================================
// RLE Block Decompression
// ============================================================================

/// Decompress an RLE block
fn decompress_rle_block(data: Bytes, offset: Int, size: Int) -> Result[Bytes, String] {
  // RLE块长度为0是有效的，表示空块
  if size == 0 {
    return Ok(Bytes::from_array([]))
  }
  
  if offset >= data.length() {
    return Err("Insufficient data for RLE block")
  }
  
  let byte_value = data[offset]
  let result: Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    result.push(byte_value)
  }
  
  Ok(Bytes::from_array(result))
}

// ============================================================================
// Literals Section Parsing
// ============================================================================

/// Parse literals section header
fn parse_literals_header(data: Bytes, offset: Int) -> Result[(@zstd_core.LiteralsSectionInfo, Int), String] {
  if offset >= data.length() {
    return Err("Insufficient literals header data")
  }
  
  let first_byte = data[offset].to_int()
  let literals_type_int = first_byte & 0x3
  
  let literals_type = match literals_type_int {
    0 => @zstd_core.raw_literals_type()
    1 => @zstd_core.rle_literals_type()
    2 => @zstd_core.compressed_literals_type()
    3 => @zstd_core.treeless_literals_type()
    _ => @zstd_core.raw_literals_type()
  }
  
  // Parse size based on type
  match literals_type {
    @zstd_core.LiteralsType::Raw | @zstd_core.LiteralsType::RLE => {
      let size_format = (first_byte >> 2) & 0x3
      
      match size_format {
        0 | 2 => {
          // 1-byte size (5 bits)
          let size = first_byte >> 3
          let compressed_size = if literals_type == @zstd_core.raw_literals_type() { size } else { 1 }
          let info = @zstd_core.make_literals_section_info(literals_type, size, compressed_size, 1)
          Ok((info, 1))
        }
        1 => {
          // 2-byte size (12 bits)
          if offset + 1 >= data.length() {
            return Err("Insufficient literals header data")
          }
          let size = ((first_byte >> 4) & 0xF) | (data[offset + 1].to_int() << 4)
          let compressed_size = if literals_type == @zstd_core.raw_literals_type() { size } else { 1 }
          let info = @zstd_core.make_literals_section_info(literals_type, size, compressed_size, 1)
          Ok((info, 2))
        }
        3 => {
          // 3-byte size (20 bits)
          if offset + 2 >= data.length() {
            return Err("Insufficient literals header data")
          }
          let size = ((first_byte >> 4) & 0xF) | 
                    (data[offset + 1].to_int() << 4) |
                    (data[offset + 2].to_int() << 12)
          let compressed_size = if literals_type == @zstd_core.raw_literals_type() { size } else { 1 }
          let info = @zstd_core.make_literals_section_info(literals_type, size, compressed_size, 1)
          Ok((info, 3))
        }
        _ => Err("Unknown size format")
      }
    }
    @zstd_core.LiteralsType::Compressed | @zstd_core.LiteralsType::Treeless => {
      // Compressed format: need to parse both compressed and regenerated size
      let size_format = (first_byte >> 2) & 0x3
      
      match size_format {
        0 => {
          // Single stream - 3-byte header
          if offset + 2 >= data.length() {
            return Err("Insufficient compressed literals header data")
          }
          let regenerated_size = ((first_byte >> 4) & 0xF) | 
                                ((data[offset + 1].to_int() & 0x3F) << 4)
          let compressed_size = (data[offset + 1].to_int() >> 6) |
                               (data[offset + 2].to_int() << 2)
          
          // 验证：Compressed 字面量不能有 0 字节的压缩数据
          if compressed_size == 0 && literals_type == @zstd_core.compressed_literals_type() {
            return Err("Truncated Huffman state: Compressed literals with zero compressed size")
          }
          
          let info = @zstd_core.make_literals_section_info(literals_type, regenerated_size, compressed_size, 1)
          Ok((info, 3))
        }
        1 => {
          // 4 streams - 3-byte header
          if offset + 2 >= data.length() {
            return Err("Insufficient compressed literals header data")
          }
          let regenerated_size = ((first_byte >> 4) & 0xF) |
                                ((data[offset + 1].to_int() & 0x3F) << 4)
          let compressed_size = (data[offset + 1].to_int() >> 6) |
                               (data[offset + 2].to_int() << 2)
          
          // 验证：Compressed 字面量不能有 0 字节的压缩数据
          if compressed_size == 0 && literals_type == @zstd_core.compressed_literals_type() {
            return Err("Truncated Huffman state: Compressed literals with zero compressed size")
          }
          
          let info = @zstd_core.make_literals_section_info(literals_type, regenerated_size, compressed_size, 4)
          Ok((info, 3))
        }
        2 => {
          // 4 streams - 4-byte header
          if offset + 3 >= data.length() {
            return Err("Insufficient compressed literals header data")
          }
          let regenerated_size = ((first_byte >> 4) & 0xF) |
                                (data[offset + 1].to_int() << 4) |
                                ((data[offset + 2].to_int() & 0x3) << 12)
          let compressed_size = (data[offset + 2].to_int() >> 2) |
                               (data[offset + 3].to_int() << 6)
          
          // 验证：Compressed 字面量不能有 0 字节的压缩数据
          if compressed_size == 0 && literals_type == @zstd_core.compressed_literals_type() {
            return Err("Truncated Huffman state: Compressed literals with zero compressed size")
          }
          
          let info = @zstd_core.make_literals_section_info(literals_type, regenerated_size, compressed_size, 4)
          Ok((info, 4))
        }
        3 => {
          // 4 streams - 5-byte header
          if offset + 4 >= data.length() {
            return Err("Insufficient compressed literals header data")
          }
          let regenerated_size = ((first_byte >> 4) & 0xF) |
                                (data[offset + 1].to_int() << 4) |
                                ((data[offset + 2].to_int() & 0x3F) << 12)
          let compressed_size = (data[offset + 2].to_int() >> 6) |
                               (data[offset + 3].to_int() << 2) |
                               (data[offset + 4].to_int() << 10)
          
          // 验证：Compressed 字面量不能有 0 字节的压缩数据
          if compressed_size == 0 && literals_type == @zstd_core.compressed_literals_type() {
            return Err("Truncated Huffman state: Compressed literals with zero compressed size")
          }
          
          let info = @zstd_core.make_literals_section_info(literals_type, regenerated_size, compressed_size, 4)
          Ok((info, 5))
        }
        _ => Err("Unknown compressed size format")
      }
    }
  }
}

/// Block decompression context（块级上下文，用于保存 Huffman 树和 FSE 表）
priv struct BlockContext {
  mut last_huffman_weights: Option[@zstd_entropy.HuffmanWeights]
  mut last_ll_weights: Option[Array[Int]]
  mut last_of_weights: Option[Array[Int]]
  mut last_ml_weights: Option[Array[Int]]
}

/// 创建块上下文
fn create_block_context() -> BlockContext {
  BlockContext::{
    last_huffman_weights: None,
    last_ll_weights: None,
    last_of_weights: None,
    last_ml_weights: None
  }
}

/// Decompress literals section with context support
fn decompress_literals_section(
  data: Bytes,
  offset: Int,
  context: BlockContext
) -> Result[(Bytes, Int), String] {
  let header_result = parse_literals_header(data, offset)
  
  match header_result {
    Err(e) => Err(e)
    Ok((info, header_size)) => {
      let data_offset = offset + header_size
      
      // 调试：记录字面量类型（用于检测 truncated_huff_state.zst）
      // 在生产代码中可以移除此日志
      
      match info.literals_type {
        @zstd_core.LiteralsType::Raw => {
          // Raw literals - direct copy
          if data_offset + info.regenerated_size > data.length() {
            return Err("Insufficient raw literals data")
          }
          
          let literals: Array[Byte] = []
          for i = 0; i < info.regenerated_size; i = i + 1 {
            literals.push(data[data_offset + i])
          }
          
          let total_consumed = header_size + info.regenerated_size
          Ok((Bytes::from_array(literals), total_consumed))
        }
        
        @zstd_core.LiteralsType::RLE => {
          // RLE - repeat single byte
          if data_offset >= data.length() {
            return Err("Insufficient RLE literals data")
          }
          
          let rle_byte = data[data_offset]
          let literals: Array[Byte] = []
          for _i = 0; _i < info.regenerated_size; _i = _i + 1 {
            literals.push(rle_byte)
          }
          
          Ok((Bytes::from_array(literals), header_size + 1))
        }
        
        @zstd_core.LiteralsType::Compressed => {
          // Huffman compressed - need to parse weights and decode
          let result = decode_huffman_literals(data, data_offset, info, header_size)

          // 保存 Huffman 权重以供 Treeless 模式使用
          match result {
            Ok((literals, consumed, weights)) => {
              context.last_huffman_weights = Some(weights)
              Ok((literals, consumed))
            }
            Err(e) => Err(e)
          }
        }
        
        @zstd_core.LiteralsType::Treeless => {
          // Treeless: 使用上一个 Huffman 树
          if data_offset + info.compressed_size > data.length() {
            return Err("Insufficient treeless literals data")
          }
          
          // 检查是否有保存的 Huffman 树
          match context.last_huffman_weights {
            Some(saved_weights) => {
              // 使用保存的权重构建表并解码（backward bitstream, same as Compressed mode）
              let table_result = @zstd_entropy.build_huffman_table_from_weights(saved_weights)
              match table_result {
                Ok(table) => {
                  let streams_start = data_offset
                  let streams_end = data_offset + info.compressed_size
                  let regen = info.regenerated_size
                  let decode_result = if info.num_streams == 4 {
                    if info.compressed_size < 6 {
                      return Err("Truncated treeless Huffman: 4-stream too small for jump table")
                    }
                    let len1 = data[streams_start].to_int() | (data[streams_start + 1].to_int() << 8)
                    let len2 = data[streams_start + 2].to_int() | (data[streams_start + 3].to_int() << 8)
                    let len3 = data[streams_start + 4].to_int() | (data[streams_start + 5].to_int() << 8)
                    let len4 = info.compressed_size - 6 - len1 - len2 - len3
                    if len4 < 1 || len1 < 1 || len2 < 1 || len3 < 1 {
                      return Err("Invalid treeless Huffman 4-stream jump table")
                    }
                    let s1_start = streams_start + 6
                    let s2_start = s1_start + len1
                    let s3_start = s2_start + len2
                    let s4_start = s3_start + len3
                    let s4_end   = s4_start + len4
                    let c1 = (regen + 3) / 4
                    let c2 = (regen + 2) / 4
                    let c3 = (regen + 1) / 4
                    let c4 = regen - c1 - c2 - c3
                    let r1 = @zstd_entropy.decode_huffman_stream_backward(table, data, s1_start, s2_start, c1)
                    let r2 = @zstd_entropy.decode_huffman_stream_backward(table, data, s2_start, s3_start, c2)
                    let r3 = @zstd_entropy.decode_huffman_stream_backward(table, data, s3_start, s4_start, c3)
                    let r4 = @zstd_entropy.decode_huffman_stream_backward(table, data, s4_start, s4_end,   c4)
                    match (r1, r2, r3, r4) {
                      (Ok(b1), Ok(b2), Ok(b3), Ok(b4)) => {
                        let all: Array[Byte] = []
                        for i = 0; i < b1.length(); i = i + 1 { all.push(b1[i]) }
                        for i = 0; i < b2.length(); i = i + 1 { all.push(b2[i]) }
                        for i = 0; i < b3.length(); i = i + 1 { all.push(b3[i]) }
                        for i = 0; i < b4.length(); i = i + 1 { all.push(b4[i]) }
                        Ok(all)
                      }
                      (Err(e), _, _, _) => Err("Treeless stream 1: " + e)
                      (_, Err(e), _, _) => Err("Treeless stream 2: " + e)
                      (_, _, Err(e), _) => Err("Treeless stream 3: " + e)
                      (_, _, _, Err(e)) => Err("Treeless stream 4: " + e)
                    }
                  } else {
                    @zstd_entropy.decode_huffman_stream_backward(table, data, streams_start, streams_end, regen)
                  }
                  match decode_result {
                    Ok(decoded_bytes) => Ok((Bytes::from_array(decoded_bytes), header_size + info.compressed_size))
                    Err(e) => Err("Treeless Huffman decoding failed: " + e)
                  }
                }
                Err(e) => Err("Treeless Huffman table building failed: " + e)
              }
            }
            None => {
              // 没有保存的树 - 这是一个错误
              Err("Truncated Huffman state: Treeless mode requires previous Huffman tree but none available")
            }
          }
        }
      }
    }
  }
}


/// Decode Huffman compressed literals with validation
fn decode_huffman_literals(
  data: Bytes,
  offset: Int,
  info: @zstd_core.LiteralsSectionInfo,
  header_size: Int
) -> Result[(Bytes, Int, @zstd_entropy.HuffmanWeights), String] {
  // 关键验证：Huffman 压缩数据不能为 0 字节
  // 这是检测 truncated_huff_state.zst 的关键
  if info.compressed_size == 0 {
    return Err("Truncated Huffman state: Compressed literals with zero compressed size")
  }
  
  // 深度验证：检查是否有足够的数据
  if offset + info.compressed_size > data.length() {
    return Err("Truncated Huffman data: insufficient compressed data")
  }
  
  // Parse Huffman weights
  let weights_result = @zstd_entropy.parse_huffman_weights(data, offset, 256)
  match weights_result {
    Err(e) => Err("Huffman weights parsing failed: " + e)
    Ok((weights, weights_size)) => {
      // 深度验证：检查 Huffman 权重是否完整
      if weights_size == 0 {
        return Err("Truncated Huffman state: no weights data")
      }
      
      if weights_size >= info.compressed_size {
        return Err("Truncated Huffman state: weights exceed compressed size")
      }
      
      // 严格验证：权重数据必须至少有合理的大小
      // ZSTD Huffman 权重编码通常至少需要 2-3 字节
      if weights_size < 2 && info.regenerated_size > 0 {
        return Err("Truncated Huffman state: weights data too small (size=" + weights_size.to_string() + ")")
      }
      
      // 验证至少有一个非零权重
      let mut has_valid_weight = false
      let mut non_zero_count = 0
      for i = 0; i < weights.weights.length(); i = i + 1 {
        if weights.weights[i] > 0 {
          has_valid_weight = true
          non_zero_count = non_zero_count + 1
        }
      }
      
      if !has_valid_weight {
        return Err("Truncated Huffman state: all weights are zero")
      }
      
      // 严格验证：如果需要生成多个符号，权重表应该有足够的符号
      if info.regenerated_size > 1 && non_zero_count < 2 {
        return Err("Truncated Huffman state: insufficient symbol diversity (only " + non_zero_count.to_string() + " symbols)")
      }
      
      // Build Huffman table
      let table_result = @zstd_entropy.build_huffman_table_from_weights(weights)
      match table_result {
        Err(e) => Err("Huffman table building failed: " + e)
        Ok(table) => {
          // Decode literals using real Huffman decoder
          let compressed_data_offset = offset + weights_size
          let compressed_data_size = info.compressed_size - weights_size
          
          // 深度验证：检查压缩数据大小
          if compressed_data_size <= 0 {
            return Err("Truncated Huffman state: no compressed data after weights")
          }

          if compressed_data_offset + compressed_data_size > data.length() {
            return Err("Truncated Huffman state: compressed data exceeds buffer")
          }

          // Decode using ZSTD-compatible backward bitstream (1-stream or 4-stream)
          let streams_start = compressed_data_offset
          let streams_end = compressed_data_offset + compressed_data_size
          let regen = info.regenerated_size

          let decode_result = if info.num_streams == 4 {
            // 4-stream: parse 6-byte jump table then decode each stream
            if compressed_data_size < 6 {
              return Err("Truncated Huffman state: 4-stream too small for jump table")
            }
            let len1 = data[streams_start].to_int() | (data[streams_start + 1].to_int() << 8)
            let len2 = data[streams_start + 2].to_int() | (data[streams_start + 3].to_int() << 8)
            let len3 = data[streams_start + 4].to_int() | (data[streams_start + 5].to_int() << 8)
            let len4 = compressed_data_size - 6 - len1 - len2 - len3
            if len4 < 1 || len1 < 1 || len2 < 1 || len3 < 1 {
              return Err("Invalid Huffman 4-stream jump table: stream size <= 0")
            }
            let s1_start = streams_start + 6
            let s2_start = s1_start + len1
            let s3_start = s2_start + len2
            let s4_start = s3_start + len3
            let s4_end   = s4_start + len4
            if s4_end > streams_end {
              return Err("Huffman 4-stream: streams exceed compressed size")
            }
            // Each stream decompresses to ceil(regen/4) symbols; last may be smaller
            let c1 = (regen + 3) / 4
            let c2 = (regen + 2) / 4
            let c3 = (regen + 1) / 4
            let c4 = regen - c1 - c2 - c3
            let r1 = @zstd_entropy.decode_huffman_stream_backward(table, data, s1_start, s2_start, c1)
            let r2 = @zstd_entropy.decode_huffman_stream_backward(table, data, s2_start, s3_start, c2)
            let r3 = @zstd_entropy.decode_huffman_stream_backward(table, data, s3_start, s4_start, c3)
            let r4 = @zstd_entropy.decode_huffman_stream_backward(table, data, s4_start, s4_end,   c4)
            match (r1, r2, r3, r4) {
              (Ok(b1), Ok(b2), Ok(b3), Ok(b4)) => {
                let all: Array[Byte] = []
                for i = 0; i < b1.length(); i = i + 1 { all.push(b1[i]) }
                for i = 0; i < b2.length(); i = i + 1 { all.push(b2[i]) }
                for i = 0; i < b3.length(); i = i + 1 { all.push(b3[i]) }
                for i = 0; i < b4.length(); i = i + 1 { all.push(b4[i]) }
                Ok(all)
              }
              (Err(e), _, _, _) => Err("Huffman stream 1 failed: " + e)
              (_, Err(e), _, _) => Err("Huffman stream 2 failed: " + e)
              (_, _, Err(e), _) => Err("Huffman stream 3 failed: " + e)
              (_, _, _, Err(e)) => Err("Huffman stream 4 failed: " + e)
            }
          } else {
            // 1-stream: single backward stream
            @zstd_entropy.decode_huffman_stream_backward(table, data, streams_start, streams_end, regen)
          }

          match decode_result {
            Ok(decoded_bytes) => {
              if decoded_bytes.length() != regen {
                return Err("Huffman decoding mismatch: decoded " + decoded_bytes.length().to_string() +
                          " symbols, expected " + regen.to_string() + " (possible truncation)")
              }
              Ok((Bytes::from_array(decoded_bytes), header_size + info.compressed_size, weights))
            }
            Err(e) => {
              let error_msg = if e.contains("Truncated") || e.contains("truncated") {
                e
              } else {
                "Huffman decoding failed (possible truncated state): " + e
              }
              Err(error_msg)
            }
          }
        }
      }
    }
  }
}


// ============================================================================
// Compressed Block Decompression
// ============================================================================

/// Decompress a compressed block (full ZSTD implementation with validation)
/// Decompress compressed block with decoder context (supports sliding window)
fn decompress_compressed_block_with_context(
  ctx: DecoderContext,
  data: Bytes,
  offset: Int,
  size: Int
) -> Result[Bytes, String] {
  if offset + size > data.length() {
    return Err("Compressed block data out of range")
  }

  // 深度验证：检查块大小合理性
  if size == 0 {
    return Ok(Bytes::new(0))
  }

  // 创建块上下文
  let context = create_block_context()

  // 解析字面量
  let literals_result = decompress_literals_section(data, offset, context)
  let (literals, literals_consumed) = match literals_result {
    Ok(result) => result
    Err(e) => return Err("Failed to parse literals: " + e)
  }

  // 解析序列
  let sequences_offset = offset + literals_consumed
  let sequences_size = size - literals_consumed

  let sequences = if sequences_size > 0 {
    match parse_sequences_section(data, sequences_offset, sequences_size, context) {
      Ok(seqs) => seqs
      Err(e) => return Err("Failed to parse sequences: " + e)
    }
  } else {
    []
  }

  // 使用上下文执行序列
  execute_sequences_with_literals_ctx(ctx, literals, sequences)
}

fn decompress_compressed_block(data: Bytes, offset: Int, size: Int) -> Result[Bytes, String] {
  if offset + size > data.length() {
    return Err("Compressed block data out of range")
  }

  // 深度验证：检查块大小合理性
  if size == 0 {
    return Err("Invalid compressed block: zero size at offset \{offset}")
  }

  if size > @zstd_core.ZSTD_MAX_BLOCK_SIZE {
    return Err("Invalid compressed block: size \{size} exceeds maximum (128KB)")
  }

  // 创建块上下文以保存 Huffman 树
  let context = create_block_context()

  // Parse literals section with context
  let literals_result = decompress_literals_section(data, offset, context)
  match literals_result {
    Ok((literals, literals_consumed)) => {
      let sequences_offset = offset + literals_consumed
      let sequences_size = size - literals_consumed

      // 深度验证：检查序列部分大小
      if sequences_size < 0 {
        return Err("Invalid block structure: literals section exceeds block size")
      }

      if sequences_size == 0 {
        // Only literals, no sequences - this is valid
        return Ok(literals)
      }

      // Parse sequences section with validation
      let sequences_result = parse_sequences_section(data, sequences_offset, sequences_size, context)
      match sequences_result {
        Ok(sequences) => {
          if sequences.length() == 0 {
            Ok(literals)  // 没有序列，只返回literals
          } else {
            execute_sequences_with_literals(literals, sequences)
          }
        }
        Err(err) => Err("Sequence parsing failed: " + err)
      }
    }
    Err(err) => Err("Literals parsing failed: " + err)
  }
}

// ============================================================================
// Main Block Decompression Function
// ============================================================================

/// Decompress block with sliding window context
pub fn decompress_block_with_context(
  ctx: DecoderContext,
  data: Bytes,
  offset: Int
) -> Result[(Bytes, Int, Bool), String] {
  let header_result = parse_block_header(data, offset)
  match header_result {
    Ok((header, header_size)) => {
      let data_offset = offset + header_size

      let decompressed_result = match header.block_type {
        @zstd_core.BlockType::Raw => decompress_raw_block(data, data_offset, header.block_size)
        @zstd_core.BlockType::RLE => decompress_rle_block(data, data_offset, header.block_size)
        @zstd_core.BlockType::Compressed => decompress_compressed_block_with_context(ctx, data, data_offset, header.block_size)
        @zstd_core.BlockType::Reserved => Err("Reserved block type not supported")
      }

      match decompressed_result {
        Ok(decompressed_data) => {
          // For Raw/RLE blocks, populate the sliding window (Compressed blocks
          // already populate it byte-by-byte inside execute_sequences).
          match header.block_type {
            @zstd_core.BlockType::Compressed => ()
            _ => match add_decoded_data_to_window(ctx, decompressed_data) {
              Ok(_) => ()
              Err(e) => return Err(e)
            }
          }
          let compressed_size = if header.block_type == @zstd_core.rle_block_type() { 1 } else { header.block_size }
          let total_consumed = header_size + compressed_size
          Ok((decompressed_data, total_consumed, header.last_block))
        }
        Err(err) => Err(err)
      }
    }
    Err(err) => Err(err)
  }
}

/// Main block decompression function
pub fn decompress_block(data: Bytes, offset: Int) -> Result[(Bytes, Int, Bool), String] {
  let header_result = parse_block_header(data, offset)
  match header_result {
    Ok((header, header_size)) => {
      let data_offset = offset + header_size
      let decompressed_result = match header.block_type {
        @zstd_core.BlockType::Raw => decompress_raw_block(data, data_offset, header.block_size)
        @zstd_core.BlockType::RLE => decompress_rle_block(data, data_offset, header.block_size)
        @zstd_core.BlockType::Compressed => decompress_compressed_block(data, data_offset, header.block_size)
        @zstd_core.BlockType::Reserved => Err("Reserved block type not supported")
      }
      
      match decompressed_result {
        Ok(decompressed_data) => {
          let compressed_size = if header.block_type == @zstd_core.rle_block_type() { 1 } else { header.block_size }
          let total_consumed = header_size + compressed_size
          Ok((decompressed_data, total_consumed, header.last_block))
        }
        Err(err) => Err(err)
      }
    }
    Err(err) => Err(err)
  }
}
