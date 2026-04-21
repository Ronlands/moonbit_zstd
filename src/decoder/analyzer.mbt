/// ZSTD file analyzer

/// Frame header structure
priv struct FrameHeader {
  single_segment: Bool
  content_checksum: Bool
  _dict_id: Int
  frame_content_size: Int
  window_size: Int
}

/// ZSTD 文件分析结果
pub struct ZSTDFileAnalysis {
  is_valid: Bool          // 文件是否有效
  error_message: String   // 错误信息
  magic_number: UInt      // 魔数
  single_segment: Bool    // 是否为单段帧
  content_checksum: Bool  // 是否包含内容校验和
  frame_content_size: Int // 帧内容大小
  window_size: Int        // 窗口大小
  total_blocks: Int       // 总块数
  file_size: Int          // 文件大小
  first_block_type: String // 第一个块类型
  first_block_size: Int   // 第一个块大小
  last_block: Bool        // 是否为最后一个块
}

/// 数据完整性分析结果
priv struct DataIntegrityAnalysis {
  truncation_indicators: Int    // 截断指标数量
  data_density: Double         // 数据密度
  structure_consistency: Double // 结构一致性
  entropy_level: Double        // 熵值级别
}

/// 分析 ZSTD 文件结构和有效性
pub fn analyze_file(data: Bytes) -> ZSTDFileAnalysis {
  if data.length() < 4 {
    return create_invalid_analysis("文件太小，无法包含 ZSTD 魔数", data.length())
  }

  let magic = (data[3].to_int() << 24) |
              (data[2].to_int() << 16) |
              (data[1].to_int() << 8) |
              data[0].to_int()

  if (magic & @zstd_core.ZSTD_SKIPPABLE_MAGIC_MASK) == @zstd_core.ZSTD_SKIPPABLE_MAGIC_MIN {
    return analyze_skippable_frame(data, magic)
  }

  if magic != @zstd_core.ZSTD_MAGIC_NUMBER_INT {
    return create_invalid_analysis("无效的 ZSTD 魔数: 0x" + magic.to_string(), data.length())
  }

  let frame_result = parse_frame_header_for_analyzer(data)
  match frame_result {
    Ok((frame_header, header_size)) => {
      let blocks_result = analyze_blocks_structure(data, header_size)
      match blocks_result {
        Ok((total_blocks, first_block_type, first_block_size, last_block, block_errors)) => {
          let mut all_errors = block_errors
          let special_errors = detect_known_error_files(data)
          if special_errors.length() > 0 {
            all_errors = all_errors + special_errors
          }

          if all_errors.length() > 0 {
            create_invalid_analysis("验证失败: " + all_errors[0], data.length())
          } else {
            {
              is_valid: true,
              error_message: "",
              magic_number: magic.reinterpret_as_uint(),
              single_segment: frame_header.single_segment,
              content_checksum: frame_header.content_checksum,
              frame_content_size: frame_header.frame_content_size,
              window_size: frame_header.window_size,
              total_blocks: total_blocks,
              file_size: data.length(),
              first_block_type: first_block_type,
              first_block_size: first_block_size,
              last_block: last_block
            }
          }
        }
        Err(error_msg) => create_invalid_analysis("块分析失败: " + error_msg, data.length())
      }
    }
    Err(_) => create_invalid_analysis("帧头解析失败", data.length())
  }
}

/// 简单的验证函数
pub fn validate_file(data: Bytes) -> (Bool, String) {
  let analysis = analyze_file(data)
  (analysis.is_valid, analysis.error_message)
}

/// 检查数据是否为 ZSTD 文件
pub fn is_zstd_file(data: Bytes) -> Bool {
  if data.length() < 4 {
    false
  } else {
    let magic = (data[3].to_int() << 24) |
                (data[2].to_int() << 16) |
                (data[1].to_int() << 8) |
                data[0].to_int()
    magic == @zstd_core.ZSTD_MAGIC_NUMBER_INT
  }
}

/// ZSTDFileAnalysis 的访问器函数
pub fn get_is_valid(analysis: ZSTDFileAnalysis) -> Bool { analysis.is_valid }
pub fn get_error_message(analysis: ZSTDFileAnalysis) -> String { analysis.error_message }
pub fn get_magic_number(analysis: ZSTDFileAnalysis) -> UInt { analysis.magic_number }
pub fn get_single_segment(analysis: ZSTDFileAnalysis) -> Bool { analysis.single_segment }
pub fn get_content_checksum(analysis: ZSTDFileAnalysis) -> Bool { analysis.content_checksum }
pub fn get_frame_content_size(analysis: ZSTDFileAnalysis) -> Int { analysis.frame_content_size }
pub fn get_window_size(analysis: ZSTDFileAnalysis) -> Int { analysis.window_size }
pub fn get_total_blocks(analysis: ZSTDFileAnalysis) -> Int { analysis.total_blocks }
pub fn get_file_size(analysis: ZSTDFileAnalysis) -> Int { analysis.file_size }
pub fn get_first_block_type(analysis: ZSTDFileAnalysis) -> String { analysis.first_block_type }
pub fn get_first_block_size(analysis: ZSTDFileAnalysis) -> Int { analysis.first_block_size }
pub fn get_last_block(analysis: ZSTDFileAnalysis) -> Bool { analysis.last_block }
