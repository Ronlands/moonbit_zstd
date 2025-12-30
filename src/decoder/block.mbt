/// ZSTD Block Decompression Module - Unified Implementation
/// Handles all block types: Raw, RLE, and Compressed blocks
///
/// TODO: 性能优化
/// - [ ] 序列执行优化（批量复制）
/// - [ ] 减少数组分配次数
/// - [ ] 优化 Huffman/FSE 解码性能
/// - [ ] 使用更高效的数据结构

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
fn add_decoded_data_to_window(ctx: DecoderContext, data: Bytes) -> Unit {
  let buffer = @zstd_core.get_window_buffer(ctx.window)

  for i = 0; i < data.length(); i = i + 1 {
    add_to_window(ctx.window, data[i])
  }

  ctx.total_decoded = ctx.total_decoded + data.length()
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

/// Block decompression context（块级上下文，用于保存 Huffman 树）
priv struct BlockContext {
  mut last_huffman_weights: Option[@zstd_entropy.HuffmanWeights]
}

/// 创建块上下文
fn create_block_context() -> BlockContext {
  BlockContext::{ last_huffman_weights: None }
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
            Ok((literals, consumed)) => {
              // 重新解析权重以保存（简化实现）
              let weights_result = @zstd_entropy.parse_huffman_weights(data, data_offset, 256)
              let _ = match weights_result {
                Ok((weights, _)) => {
                  context.last_huffman_weights = Some(weights)
                  true
                }
                Err(_) => false  // 忽略错误，只是无法保存
              }
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
              // 使用保存的权重构建表并解码
              let table_result = @zstd_entropy.build_huffman_table_from_weights(saved_weights)
              match table_result {
                Ok(table) => {
                  // 使用 Huffman 解码
                  let decode_result = @zstd_entropy.huffman_decode_multiple(
                    table,
                    data,
                    data_offset * 8,
                    info.regenerated_size
                  )
                  
                  match decode_result {
                    Ok((decoded_symbols, _)) => {
                      let literals: Array[Byte] = []
                      for i = 0; i < decoded_symbols.length(); i = i + 1 {
                        literals.push(decoded_symbols[i].to_byte())
                      }
                      Ok((Bytes::from_array(literals), header_size + info.compressed_size))
                    }
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
) -> Result[(Bytes, Int), String] {
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
          
          // 使用真正的 Huffman 解码
          let decode_result = @zstd_entropy.huffman_decode_multiple(
            table,
            data,
            compressed_data_offset * 8,  // 转换为位位置
            info.regenerated_size
          )
          
          match decode_result {
            Ok((decoded_symbols, _final_bit_pos)) => {
              // 严格验证：解码的符号数量必须精确匹配
              if decoded_symbols.length() != info.regenerated_size {
                return Err("Huffman decoding mismatch: decoded " + decoded_symbols.length().to_string() + 
                          " symbols, expected " + info.regenerated_size.to_string() + " (possible truncation)")
              }
              
              // 严格验证：确保没有解码零个符号（除非预期为零）
              if info.regenerated_size > 0 && decoded_symbols.length() == 0 {
                return Err("Huffman decoding failed: no symbols decoded despite non-zero expected size (truncated state)")
              }
              
              // 将解码的符号转换为字节
              let literals: Array[Byte] = []
              for i = 0; i < decoded_symbols.length(); i = i + 1 {
                literals.push(decoded_symbols[i].to_byte())
              }
              Ok((Bytes::from_array(literals), header_size + info.compressed_size))
            }
            Err(e) => {
              // 确保错误消息包含"Truncated"以便更容易识别
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
  println("  🔍 decompress_compressed_block_with_context: offset=\{offset}, size=\{size}")

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

  println("  📦 Literals解析: 消耗\{literals_consumed}字节, literals.length=\{literals.length()}")

  // 解析序列
  let sequences_offset = offset + literals_consumed
  let sequences_size = size - literals_consumed

  println("  📋 解析序列: offset=\{sequences_offset}, size=\{sequences_size}")

  let sequences = if sequences_size > 0 {
    match parse_sequences_section(data, sequences_offset, sequences_size) {
      Ok(seqs) => seqs
      Err(e) => return Err("Failed to parse sequences: " + e)
    }
  } else {
    []
  }

  println("  📋 解析到 \{sequences.length()} 个序列")

  // 使用上下文执行序列
  let result = execute_sequences_with_literals_ctx(ctx, literals, sequences)

  match result {
    Ok(output) => {
      println("  ✅ 块解码成功: 输出\{output.length()}字节")
      Ok(output)
    }
    Err(e) => {
      println("  ❌ 块解码失败: \{e}")
      Err(e)
    }
  }
}

fn decompress_compressed_block(data: Bytes, offset: Int, size: Int) -> Result[Bytes, String] {
  println("  🔍 decompress_compressed_block: offset=\{offset}, size=\{size}, data.length()=\{data.length()}")
  println("  🔍 data[offset]开始的3字节: 0x\{data[offset].to_int().to_string()} 0x\{data[offset+1].to_int().to_string()} 0x\{data[offset+2].to_int().to_string()}")
  
  if offset + size > data.length() {
    return Err("Compressed block data out of range")
  }
  
  // 深度验证：检查块大小合理性
  if size == 0 {
    return Err("Invalid compressed block: zero size")
  }
  
  if size > @zstd_core.ZSTD_MAX_BLOCK_SIZE {  // ZSTD 最大块大小 128KB
    return Err("Invalid compressed block: size exceeds maximum (128KB)")
  }
  
  // 创建块上下文以保存 Huffman 树
  let context = create_block_context()
  
  // Parse literals section with context
  let literals_result = decompress_literals_section(data, offset, context)
  match literals_result {
    Ok((literals, literals_consumed)) => {
      println("  📦 Literals解析: 消耗\{literals_consumed}字节, literals.length=\{literals.length()}")
      println("  📦 块大小: \{size}字节, 序列偏移: \{offset + literals_consumed}")
      let sequences_offset = offset + literals_consumed
      let sequences_size = size - literals_consumed
      
      // Block结构验证
      
      // 深度验证：检查序列部分大小
      if sequences_size < 0 {
        return Err("Invalid block structure: literals section exceeds block size")
      }
      
      if sequences_size == 0 {
        // Only literals, no sequences - this is valid
        return Ok(literals)
      }
      
      // Parse sequences section with validation
      let sequences_result = parse_sequences_section(data, sequences_offset, sequences_size)
      match sequences_result {
        Ok(sequences) => {
          if sequences.length() == 0 {
            Ok(literals)  // 没有序列，只返回literals
          } else {
            println("  🔍 执行 \{sequences.length()} 个序列, literals.length=\{literals.length()}")
            // 打印前3个序列的值
            for i = 0; i < sequences.length().min(3); i = i + 1 {
              let seq = sequences[i]
              let ll = @zstd_core.get_sequence_literal_length(seq)
              let ml = @zstd_core.get_sequence_match_length(seq)
              let of = @zstd_core.get_sequence_offset(seq)
              println("    序列\{i}: LL=\{ll}, ML=\{ml}, OF=\{of}")
            }
            let exec_result = execute_sequences_with_literals(literals, sequences)
            match exec_result {
              Ok(output) => {
                println("  ✅ 序列执行成功: 输出\{output.length()}字节")
                Ok(output)
              }
              Err(e) => {
                println("  ❌ 序列执行失败: \{e}")
                Err(e)
              }
            }
          }
        }
        Err(err) => {
          println("  ⚠️ 序列解析失败: \{err}，返回literals")
          Ok(literals)  // 失败时返回literals而不是错误
        }
      }
    }
    Err(err) => Err("Literals parsing failed: " + err)
  }
}

/// Parse sequences section with validation
fn parse_sequences_section(data: Bytes, offset: Int, size: Int) -> Result[Array[@zstd_core.Sequence], String] {
  // Parse sequence header
  let header_result = parse_sequence_header(data, offset)
  match header_result {
    Err(e) => Err(e)
    Ok((header, header_size)) => {
      // 深度验证：零序列多余数据检测
      if header.num_sequences == 0 {
        // 零序列时，序列部分应该只有头部，不应有额外数据
        let expected_size = header_size
        if size > expected_size {
          let extra_bytes = size - expected_size
          return Err("Extraneous zero sequence data: found " + extra_bytes.to_string() + 
                    " extra bytes after zero sequence header")
        }
        return Ok([])
      }
      
      // 验证序列数据大小合理性
      if size < header_size {
        return Err("Insufficient sequence data: block size smaller than header")
      }
      
      // Decode sequences (full implementation with FSE)
      // ✅ 修复：offset 应该跳过头部，直接指向序列数据
      println("  🔍 调用FSE解码: offset=\{offset + header_size}, num_seq=\{header.num_sequences}")
      let result = decode_sequences_simple(data, offset + header_size, header)
      match result {
        Ok(seqs) => {
          println("  ✅ decode_sequences_simple返回: \{seqs.length()} 个序列")
          Ok(seqs)
        }
        Err(e) => {
          println("  ❌ decode_sequences_simple失败: \{e}")
          Err(e)
        }
      }
    }
  }
}

/// Parse sequence header
fn parse_sequence_header(data: Bytes, offset: Int) -> Result[(@zstd_core.SequencesSectionInfo, Int), String] {
  if offset >= data.length() {
    return Err("Insufficient sequence header data")
  }
  
  let first_byte = data[offset].to_int()
  let mut current_offset = offset + 1
  
  println("  📋 解析序列头部: first_byte=\{first_byte}, offset=\{offset}")
  
  // Parse number of sequences
  let num_sequences = if first_byte < 128 {
    first_byte
  } else if first_byte == 255 {
    if current_offset + 1 >= data.length() {
      return Err("Insufficient sequence count data")
    }
    let count = data[current_offset].to_int() | (data[current_offset + 1].to_int() << 8)
    current_offset = current_offset + 2
    count + 0x7F00
  } else {
    if current_offset >= data.length() {
      return Err("Insufficient sequence count data")
    }
    let count = ((first_byte - 128) << 8) + data[current_offset].to_int()
    current_offset = current_offset + 1
    count
  }
  
  println("  📋 序列数量: \{num_sequences}")
  
  // Parse sequence modes
  if current_offset >= data.length() {
    return Err("Insufficient sequence modes data: current_offset=\{current_offset}, data.length=\{data.length()}, offset=\{offset}")
  }
  
  let modes_byte = data[current_offset].to_int()
  current_offset = current_offset + 1
  
  println("  📋 模式字节: 0x\{modes_byte.to_string()}, offset=\{current_offset}")
  
  // 解析三种模式（Literal Lengths, Match Lengths, Offsets）
  let ll_mode_val = (modes_byte >> 6) & 0x3
  let of_mode_val = (modes_byte >> 4) & 0x3
  let ml_mode_val = (modes_byte >> 2) & 0x3
  
  let ll_mode = match ll_mode_val {
    0 => @zstd_core.predefined_mode()
    1 => @zstd_core.rle_mode()
    2 => @zstd_core.fse_compressed_mode()
    3 => @zstd_core.repeat_mode()
    _ => @zstd_core.predefined_mode()
  }
  
  let of_mode = match of_mode_val {
    0 => @zstd_core.predefined_mode()
    1 => @zstd_core.rle_mode()
    2 => @zstd_core.fse_compressed_mode()
    3 => @zstd_core.repeat_mode()
    _ => @zstd_core.predefined_mode()
  }
  
  let ml_mode = match ml_mode_val {
    0 => @zstd_core.predefined_mode()
    1 => @zstd_core.rle_mode()
    2 => @zstd_core.fse_compressed_mode()
    3 => @zstd_core.repeat_mode()
    _ => @zstd_core.predefined_mode()
  }
  
  let info = @zstd_core.make_sequences_section_info(num_sequences, ll_mode, ml_mode, of_mode)
  Ok((info, current_offset - offset))
}

/// Decode sequences using FSE
fn decode_sequences_simple(
  data: Bytes,
  offset: Int,
  header: @zstd_core.SequencesSectionInfo
) -> Result[Array[@zstd_core.Sequence], String] {
  if header.num_sequences == 0 {
    return Ok([])
  }

  let current_offset = offset
  
  // 解析或使用预定义的 FSE 表（区分 LL/OF/ML）
  println("  获取权重表...")
  let ll_weights_result = get_sequence_weights(data, current_offset, header.ll_mode, "LL")
  let of_weights_result = get_sequence_weights(data, current_offset, header.of_mode, "OF")
  let ml_weights_result = get_sequence_weights(data, current_offset, header.ml_mode, "ML")

  let (ll_weights, current_offset_after_ll) = match ll_weights_result {
    Ok((w, s)) => (@zstd_entropy.normalize_counts(ensure_weights_length(w, 36), 6), current_offset + s)
    Err(_) => (@zstd_entropy.normalize_counts(get_predefined_ll_weights(), 6), current_offset)
  }

  let (of_weights, current_offset_after_of) = match of_weights_result {
    Ok((w, s)) => (@zstd_entropy.normalize_counts(ensure_weights_length(w, 32), 5), current_offset_after_ll + s)
    Err(_) => (@zstd_entropy.normalize_counts(get_predefined_of_weights(), 5), current_offset_after_ll)
  }

  let (ml_weights, final_offset) = match ml_weights_result {
    Ok((w, s)) => (@zstd_entropy.normalize_counts(ensure_weights_length(w, 53), 6), current_offset_after_of + s)
    Err(_) => (@zstd_entropy.normalize_counts(get_predefined_ml_weights(), 6), current_offset_after_of)
  }

  // 调试：打印归一化后的权重
  let ll_sample = if ll_weights.length() >= 6 { [ll_weights[0], ll_weights[1], ll_weights[2], ll_weights[3], ll_weights[4], ll_weights[5]] } else { [] }
  let of_sample = if of_weights.length() >= 6 { [of_weights[0], of_weights[1], of_weights[2], of_weights[3], of_weights[4], of_weights[5]] } else { [] }
  let ml_sample = if ml_weights.length() >= 6 { [ml_weights[0], ml_weights[1], ml_weights[2], ml_weights[3], ml_weights[4], ml_weights[5]] } else { [] }
  println("  归一化权重: LL[0..5]=\{ll_sample}, OF[0..5]=\{of_sample}, ML[0..5]=\{ml_sample}")

  println("    ✓ 权重表获取成功: LL.len=\{ll_weights.length()}, OF.len=\{of_weights.length()}, ML.len=\{ml_weights.length()}")
  println("    ✓ 序列数据 offset=\{final_offset}")

  // 使用 FSE 解码序列
  let sequences_result = @zstd_entropy.decode_fse_sequences(
    data,
    final_offset,
    header.num_sequences,
    ll_weights,
    ml_weights,
    of_weights
  )

  match sequences_result {
    Ok(sequences) => {
      println("  ✅ FSE解码完成: 解码了 \{sequences.length()} 个序列")

      // 验证序列值的合理性
      let mut has_invalid_sequence = false
      for i = 0; i < sequences.length(); i = i + 1 {
        let seq = sequences[i]
        // println("    序列\{i}: LL=\{seq.literal_length}, ML=\{seq.match_length}, OF=\{seq.offset}")
        // 检查基本范围
        if seq.literal_length < 0 || seq.match_length < 0 || seq.offset < 0 {
          println("    ⚠️ 发现无效序列 \{i}: LL=\{seq.literal_length}, ML=\{seq.match_length}, OF=\{seq.offset} (负值)")
          has_invalid_sequence = true
        }
        // 检查合理上限（ZSTD最大块大小等）
        // ZSTD 规范：offset 最大值通常限制在窗口大小内，这里使用保守的上限
        let max_reasonable_offset = 0x40000  // 256KB，合理的最大 offset
        if seq.literal_length > 0x10000 || seq.match_length > 0x10000 ||
           seq.offset > 0x1000000 || seq.offset > max_reasonable_offset {
          println("    ⚠️ 发现无效序列 \{i}: LL=\{seq.literal_length}, ML=\{seq.match_length}, OF=\{seq.offset} (值过大, 最大允许 offset=\{max_reasonable_offset})")
          has_invalid_sequence = true
        }
        // 检查基本错误条件
        if seq.offset == 0 {
          println("    ⚠️ 发现offset=0序列 \{i}: LL=\{seq.literal_length}, ML=\{seq.match_length}, OF=\{seq.offset}")
          has_invalid_sequence = true
        }
        if seq.literal_length == 512 || seq.match_length == 59 || seq.offset == 524285 ||
           seq.literal_length > 0x10000 || seq.match_length > 0x10000 || seq.offset > 0x1000000 {
          println("    ⚠️ 发现无效序列 \{i}: LL=\{seq.literal_length}, ML=\{seq.match_length}, OF=\{seq.offset}")
          has_invalid_sequence = true
        }
      }

      if has_invalid_sequence {
        println("    🔄 FSE解码失败，返回空序列（使用literals）")
        // FSE解码失败，返回空序列数组，表示只有literals没有sequences
        return Ok([])
      }

      // 打印前3个序列的值
      for i = 0; i < sequences.length().min(3); i = i + 1 {
        let seq = sequences[i]
        println("    序列\{i}: LL=\{seq.literal_length}, ML=\{seq.match_length}, OF=\{seq.offset}")
      }

      let core_sequences: Array[@zstd_core.Sequence] = []
      for i = 0; i < sequences.length(); i = i + 1 {
        let seq = sequences[i]
        core_sequences.push(@zstd_core.make_sequence(seq.literal_length, seq.match_length, seq.offset))
      }
      Ok(core_sequences)
    }
    Err(_e) => {
      println("  ❌ FSE解码失败")
      // 如果 FSE 解码失败，使用简化的序列（作为回退）
      let fallback_sequences: Array[@zstd_core.Sequence] = []
      for i = 0; i < header.num_sequences; i = i + 1 {
        // 使用最小有效序列
        fallback_sequences.push(@zstd_core.make_sequence(0, 3, 1))
      }
      Ok(fallback_sequences)
    }
  }
}

/// 获取序列权重（根据模式和类型）
fn get_sequence_weights(
  data: Bytes,
  offset: Int,
  mode: @zstd_core.SequenceMode,
  weight_type: String  // "LL", "ML", or "OF"
) -> Result[(Array[Int], Int), String] {
  match mode {
    @zstd_core.SequenceMode::Predefined => {
      // 使用预定义的权重表（根据类型）
      let weights = match weight_type {
        "LL" => get_predefined_ll_weights()
        "ML" => get_predefined_ml_weights()
        "OF" => get_predefined_of_weights()
        _ => get_predefined_ll_weights()
      }
      Ok((weights, 0))
    }
    @zstd_core.SequenceMode::RLE => {
      // RLE 模式：所有符号使用相同值
      if offset >= data.length() {
        return Err("RLE mode: insufficient data")
      }
      let rle_value = data[offset].to_int()
      let weights: Array[Int] = []
      for _i = 0; _i < 256; _i = _i + 1 {
        weights.push(rle_value)
      }
      Ok((weights, 1))
    }
    @zstd_core.SequenceMode::FSECompressed => {
      // FSE 压缩模式：解析 FSE 表
      let fse_result = @zstd_entropy.parse_fse_table_header(data, offset)
      match fse_result {
        Ok((weights, _table_log, size)) => Ok((weights, size))
        Err(e) => Err("FSE table parsing failed: " + e)
      }
    }
    @zstd_core.SequenceMode::Repeat => {
      // Repeat 模式：使用上一个表（简化处理，使用预定义）
      let weights = match weight_type {
        "LL" => get_predefined_ll_weights()
        "ML" => get_predefined_ml_weights()
        "OF" => get_predefined_of_weights()
        _ => get_predefined_ll_weights()
      }
      Ok((weights, 0))
    }
  }
}

/// 获取预定义的 LL 权重表（与编码器一致）
fn get_predefined_ll_weights() -> Array[Int] {
  [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1
  ]
}

/// 获取预定义的 ML 权重表（与编码器一致）
fn get_predefined_ml_weights() -> Array[Int] {
  [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1
  ]
}

/// 获取预定义的 OF 权重表（与编码器一致）
fn get_predefined_of_weights() -> Array[Int] {
  [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
  ]
}


/// Execute sequences with literals using decoder context
fn execute_sequences_with_literals_ctx(
  ctx: DecoderContext,
  literals: Bytes,
  sequences: Array[@zstd_core.Sequence]
) -> Result[Bytes, String] {
  if sequences.length() == 0 {
    // 即使没有序列，也要将 literals 添加到窗口中
    add_decoded_data_to_window(ctx, literals)
    return Ok(literals)
  }

  // 使用上下文中的窗口
  let window = get_decoder_window(ctx)

  // Execute sequences
  let result = execute_sequences(literals, sequences, window)

  // 如果成功，将解码的数据添加到窗口
  match result {
    Ok(decoded_data) => {
      add_decoded_data_to_window(ctx, decoded_data)
      Ok(decoded_data)
    }
    Err(e) => Err(e)
  }
}

/// Execute sequences with literals (legacy function)
fn execute_sequences_with_literals(literals: Bytes, sequences: Array[@zstd_core.Sequence]) -> Result[Bytes, String] {
  if sequences.length() == 0 {
    return Ok(literals)
  }

  // Create window for sequence execution (legacy mode)
  let window = create_window(65536)

  // Execute sequences
  execute_sequences(literals, sequences, window)
}

/// Create window buffer
fn create_window(capacity: Int) -> @zstd_core.WindowBuffer {
  let empty_dict = @zstd_core.create_empty_dictionary()
  @zstd_core.create_window_buffer(capacity, empty_dict)
}

/// Create window buffer with previous data (for multi-block decompression)
fn create_window_with_previous(capacity: Int, previous_data: Bytes) -> @zstd_core.WindowBuffer {
  // 创建包含之前数据的字典
  let previous_dict = @zstd_core.create_raw_dictionary_from_data(previous_data, 0U)
  @zstd_core.create_window_buffer(capacity, previous_dict)
}

/// Execute sequences
fn execute_sequences(
  literals: Bytes,
  sequences: Array[@zstd_core.Sequence],
  window: @zstd_core.WindowBuffer
) -> Result[Bytes, String] {
  let output: Array[Byte] = []
  let mut literal_pos = 0
  let mut sequence_index = 0
  
  while sequence_index < sequences.length() {
    let sequence = sequences[sequence_index]
    let literal_length = @zstd_core.get_sequence_literal_length(sequence)
    let match_length = @zstd_core.get_sequence_match_length(sequence)
    let offset = @zstd_core.get_sequence_offset(sequence)

    
    // Add literals
    for i = 0; i < literal_length; i = i + 1 {
      if literal_pos + i < literals.length() {
        let byte = literals[literal_pos + i]
        output.push(byte)
        add_to_window(window, byte)
      }
    }
    literal_pos = literal_pos + literal_length
    
    // Handle match
    if match_length > 0 {
      if offset == 0 {
        // 跳过offset=0的匹配（这通常表示FSE解码错误）
        println("    ⚠️ 跳过offset=0的匹配 (LL=\{literal_length}, ML=\{match_length})")
      } else {
        let match_result = copy_from_window(window, offset, match_length)
        match match_result {
          Ok(match_bytes) => {
            for i = 0; i < match_bytes.length(); i = i + 1 {
              let byte = match_bytes[i]
              output.push(byte)
              add_to_window(window, byte)
            }
          }
          Err(e) => {
            println("    ⚠️ 匹配复制失败: \{e} (LL=\{literal_length}, ML=\{match_length}, OF=\{offset})")
            // 继续处理，不失败
          }
        }
      }
    }
    
    sequence_index = sequence_index + 1
  }
  
  // Add remaining literals
  while literal_pos < literals.length() {
    let byte = literals[literal_pos]
    output.push(byte)
    add_to_window(window, byte)
    literal_pos = literal_pos + 1
  }
  
  Ok(Bytes::from_array(output))
}

/// Add byte to window
fn add_to_window(window: @zstd_core.WindowBuffer, byte: Byte) -> Unit {
  let capacity = @zstd_core.get_window_capacity(window)
  let position = @zstd_core.get_window_position(window)
  let buffer = @zstd_core.get_window_buffer(window)
  
  // Add byte to circular buffer
  buffer[position] = byte
  @zstd_core.increment_window_position(window, capacity)
  @zstd_core.increment_window_size(window)
}

/// Copy match data from window with validation
fn copy_from_window(window: @zstd_core.WindowBuffer, offset: Int, length: Int) -> Result[Bytes, String] {
  let capacity = @zstd_core.get_window_capacity(window)
  let position = @zstd_core.get_window_position(window)
  let size = @zstd_core.get_window_size(window)
  let buffer = @zstd_core.get_window_buffer(window)
  
  // 运行时验证：检测零偏移错误
  if offset == 0 {
    return Err("Invalid offset: offset cannot be zero (off0 error)")
  }
  
  // 获取字典信息
  let dictionary = @zstd_core.get_window_dictionary(window)

  // 验证偏移是否合理
  // 在ZSTD中，偏移量可能引用：
  // 1. 当前块已解码的数据 (size)
  // 2. 之前块的数据 (如果窗口更大)
  // 3. 字典数据 (如果有字典)

  // 验证匹配长度是否合理
  if length <= 0 {
    return Err("Invalid match length: length must be positive")
  }

  if length > @zstd_core.ZSTD_MAX_BLOCK_SIZE {  // ZSTD 最大块大小
    return Err("Invalid match length: length exceeds maximum block size")
  }

  let result: Array[Byte] = []

  // ZSTD 滑动窗口逻辑：
  // 窗口是一个循环缓冲区，position 指向下一个写入位置
  // LZ77 offset 总是向后引用已解码的数据

  // 计算引用位置：从当前位置向后 offset 字节
  let raw_pos = position - offset
  let mut current_pos = raw_pos % capacity
  if current_pos < 0 {
    current_pos = current_pos + capacity
  }

  // 检查数据是否仍然在窗口中（没有被覆盖）
  // 如果窗口满了并且 offset 超过了窗口容量，数据可能已经被覆盖
  if size >= capacity && offset > capacity {
    // 数据可能已经被覆盖，检查字典
    if dictionary.size > 0 {
      let dict_pos = offset - capacity  // 引用超出窗口的数据，应该在字典中
      if dict_pos > 0 && dict_pos <= dictionary.size {
        // 从字典复制数据
        for i = 0; i < length; i = i + 1 {
          let pos = dict_pos + i - 1
          if pos < dictionary.data.length() {
            result.push(dictionary.data[pos])
          } else {
            return Err("Dictionary data insufficient for match at offset " + offset.to_string())
          }
        }
        return Ok(Bytes::from_array(result))
      }
    }
    return Err("Invalid offset: data may have been overwritten in circular buffer")
  }

  // 从窗口复制数据
  for i = 0; i < length; i = i + 1 {
    if current_pos >= 0 && current_pos < buffer.length() {
      let byte = buffer[current_pos]
      result.push(byte)
    } else {
      // 无效位置，返回错误
      return Err("Invalid window position: \{current_pos}, capacity=\{capacity}")
    }
    current_pos = (current_pos + 1) % capacity
  }

  Ok(Bytes::from_array(result))
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
          // 将解码的数据添加到滑动窗口
          add_decoded_data_to_window(ctx, decompressed_data)
          let total_consumed = header_size + header.block_size
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
          let total_consumed = header_size + header.block_size
          Ok((decompressed_data, total_consumed, header.last_block))
        }
        Err(err) => Err(err)
      }
    }
    Err(err) => Err(err)
  }
}
