/// ZSTD字典支持模块
/// 实现字典压缩和解压功能

/// 字典类型
pub enum DictionaryType {
  Raw         // 原始字典
  Formatted   // ZSTD格式字典
}

/// 字典信息
pub struct Dictionary {
  dict_type: DictionaryType   // 字典类型
  dict_id: UInt              // 字典ID (统一使用UInt)
  content: Bytes             // 字典内容
}

/// 创建原始字典
pub fn create_raw_dictionary(content: Bytes, dict_id: UInt) -> Dictionary {
  {
    dict_type: Raw,
    dict_id: dict_id,
    content: content
  }
}

/// 解析ZSTD格式字典
pub fn parse_zstd_dictionary(data: Bytes) -> Result[Dictionary, String] {
  if data.length() < 8 {
    return Err("字典数据太短")
  }
  
  // 检查魔数 (0xEC30A437 = ZSTD字典魔数)
  let magic = data[0].to_uint() |
              (data[1].to_uint() << 8) |
              (data[2].to_uint() << 16) |
              (data[3].to_uint() << 24)
  
  if magic != 0xEC30A437U {
    return Err("无效的字典魔数")
  }
  
  // 读取字典ID
  let dict_id = data[4].to_uint() |
                (data[5].to_uint() << 8) |
                (data[6].to_uint() << 16) |
                (data[7].to_uint() << 24)
  
  // 剩余部分是字典内容
  let content = if data.length() > 8 {
    // 提取字典内容
    let content_array: Array[Byte] = []
    for i = 8; i < data.length(); i = i + 1 {
      content_array.push(data[i])
    }
    Bytes::from_array(content_array)
  } else {
    Bytes::new(0)
  }
  
  let dictionary = {
    dict_type: Formatted,
    dict_id: dict_id,
    content: content
  }
  
  Ok(dictionary)
}

/// 使用字典进行解压缩
pub fn decompress_with_dictionary(compressed_data: Bytes, dictionary: Dictionary) -> Result[Bytes, String] {
  // 检查字典ID是否匹配
  let frame_result = @decoder.parse_frame_header(compressed_data)
  let frame_dict_id = match frame_result {
    Ok((frame_header, _)) => frame_header.dict_id.reinterpret_as_uint()
    Err(err) => return Err("无法解析帧头: " + @zstd_core.error_to_string(err))
  }
  
  // 验证字典ID匹配（0表示不使用字典）
  if frame_dict_id != 0U && frame_dict_id != dictionary.dict_id {
    return Err("字典ID不匹配: 期望 " + dictionary.dict_id.to_string() + ", 实际 " + frame_dict_id.to_string())
  }
  
  // Note: Full dictionary decompression requires preloading dictionary content into the decompression window
  let decompression_result = @decoder.decompress_zstd_data(compressed_data)
  match decompression_result {
    Ok(decompressed) => Ok(decompressed)
    Err(err_msg) => Err("解压缩失败: " + err_msg)
  }
}

/// 使用字典进行压缩（基础实现）
pub fn compress_with_dictionary(data: Bytes, _dictionary: Dictionary) -> Result[Bytes, String] {
  // Simplified implementation. Full version would:
  // 1. Preload dictionary content into compression window
  // 2. Use dictionary for matching during compression
  // 3. Write dictionary ID in frame header
  
  let config = @encoder.create_default_config()
  @encoder.compress_data(data, config)
}

/// 构建字典（简化实现，未来可优化为 Cover 算法）
pub fn build_dictionary(samples: Array[Bytes], target_size: Int) -> Result[Dictionary, String] {
  if samples.length() == 0 {
    return Err("没有样本数据")
  }
  
  if target_size <= 0 {
    return Err("目标大小必须大于0")
  }
  
  // 计算总样本大小
  let mut total_size = 0
  for i = 0; i < samples.length(); i = i + 1 {
    total_size = total_size + samples[i].length()
  }
  
  // 构建组合数据
  let combined_data: Array[Byte] = []
  
  // 合并样本（优化：避免嵌套循环）
  for i = 0; i < samples.length(); i = i + 1 {
    let sample = samples[i]
    for j = 0; j < sample.length(); j = j + 1 {
      if combined_data.length() < target_size {
        combined_data.push(sample[j])
      } else {
        break
      }
    }
    if combined_data.length() >= target_size {
      break
    }
  }
  
  let dict_content = Bytes::from_array(combined_data)
  let dict_id = generate_dictionary_id(dict_content)
  
  Ok(create_raw_dictionary(dict_content, dict_id))
}

/// 生成字典ID
/// 使用简单哈希算法，避免保留范围 (1-32767为保留)
fn generate_dictionary_id(content: Bytes) -> UInt {
  let mut hash = 0U
  let limit = content.length().min(1024) // 优化：只哈希前1KB
  
  for i = 0; i < limit; i = i + 1 {
    hash = (hash * 31U + content[i].to_uint()) & 0x7FFFFFFFU
  }
  
  // 确保ID不在保留范围 (1-32767)
  let id = hash + 32768U
  if id < 32768U || id > 0x7FFFFFFFU {
    32768U  // 回退到最小有效ID
  } else {
    id
  }
}

/// 保存字典到ZSTD格式
pub fn save_zstd_dictionary(dictionary: Dictionary) -> Bytes {
  let output: Array[Byte] = []
  
  // 写入魔数 (0xEC30A437)
  let magic = 0xEC30A437U
  output.push((magic & 0xFFU).to_byte())
  output.push(((magic >> 8) & 0xFFU).to_byte())
  output.push(((magic >> 16) & 0xFFU).to_byte())
  output.push(((magic >> 24) & 0xFFU).to_byte())
  
  // 写入字典ID
  let dict_id = dictionary.dict_id
  output.push((dict_id & 0xFFU).to_byte())
  output.push(((dict_id >> 8) & 0xFFU).to_byte())
  output.push(((dict_id >> 16) & 0xFFU).to_byte())
  output.push(((dict_id >> 24) & 0xFFU).to_byte())
  
  // 写入字典内容（优化：批量操作）
  for i = 0; i < dictionary.content.length(); i = i + 1 {
    output.push(dictionary.content[i])
  }
  
  Bytes::from_array(output)
}

/// 验证字典有效性
pub fn validate_dictionary(dictionary: Dictionary) -> Bool {
  // 检查字典ID是否在有效范围 (>=32768, 避免保留范围)
  if dictionary.dict_id < 32768U || dictionary.dict_id > 0x7FFFFFFFU {
    return false
  }
  
  // 检查内容是否为空
  if dictionary.content.length() == 0 {
    return false
  }
  
  // 检查内容大小是否合理 (ZSTD建议字典不超过2MB)
  let max_dict_size = 2 * 1024 * 1024
  if dictionary.content.length() > max_dict_size {
    return false
  }
  
  true
}

/// 计算字典压缩收益（基于估算，非实际压缩测试）
pub fn calculate_dictionary_benefit(data: Bytes, dictionary: Dictionary) -> Double {
  let config = @encoder.create_default_config()
  let without_dict_size = @encoder.estimate_compressed_size(data, config)
  
  // 简化估算：基于字典大小和数据相似度
  let dict_ratio = dictionary.content.length().to_double() / data.length().to_double()
  let benefit_factor = dict_ratio * 0.3
  let estimated_benefit = if benefit_factor < 0.5 { benefit_factor } else { 0.5 }  // 最多50%收益
  
  let with_dict_size = (without_dict_size.to_double() * (1.0 - estimated_benefit)).to_int()
  let benefit = (without_dict_size - with_dict_size).to_double() / without_dict_size.to_double()
  
  if benefit > 0.0 { benefit } else { 0.0 }
}

/// 获取字典统计信息
pub fn get_dictionary_stats(dictionary: Dictionary) -> String {
  let dict_type_str = match dictionary.dict_type {
    Raw => "原始"
    Formatted => "ZSTD格式"
  }
  
  let size_kb = dictionary.content.length().to_double() / 1024.0
  
  "字典统计:\n" +
  "  类型: " + dict_type_str + "\n" +
  "  ID: " + dictionary.dict_id.to_string() + "\n" +
  "  大小: " + dictionary.content.length().to_string() + " 字节 (" + 
    size_kb.to_string() + " KB)\n" +
  "  有效: " + (if validate_dictionary(dictionary) { "是" } else { "否" })
}

/// 合并多个字典
pub fn merge_dictionaries(dictionaries: Array[Dictionary], target_size: Int) -> Result[Dictionary, String] {
  if dictionaries.length() == 0 {
    return Err("没有字典可合并")
  }
  
  if dictionaries.length() == 1 {
    return Ok(dictionaries[0])
  }
  
  if target_size <= 0 {
    return Err("目标大小必须大于0")
  }
  
  let combined_content: Array[Byte] = []
  
  // 合并字典内容
  for i = 0; i < dictionaries.length(); i = i + 1 {
    let dict = dictionaries[i]
    for j = 0; j < dict.content.length(); j = j + 1 {
      if combined_content.length() < target_size {
        combined_content.push(dict.content[j])
      } else {
        break
      }
    }
    if combined_content.length() >= target_size {
      break
    }
  }
  
  let final_content = Bytes::from_array(combined_content)
  let new_dict_id = generate_dictionary_id(final_content)
  
  Ok(create_raw_dictionary(final_content, new_dict_id))
}


