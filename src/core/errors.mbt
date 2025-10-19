/// ZSTD 错误处理和验证机制模块
/// 提供统一的错误类型、验证函数和错误恢复机制

// 使用现有的简单 ZSTDError 类型（在 types.mbt 中定义）

/// 错误严重程度
pub enum ErrorSeverity {
  Error      // 错误，需要停止当前操作
  Fatal      // 致命错误，需要终止整个解压缩过程
}

/// 错误上下文信息
pub struct ErrorContext {
  location: String      // 错误发生的位置
  operation: String     // 正在执行的操作
  data_offset: Int      // 数据偏移量
  additional_info: String // 附加信息
}

/// 带上下文的错误
pub struct ContextualError {
  error: ZSTDError
  severity: ErrorSeverity
  context: ErrorContext
  timestamp: Int        // 错误发生时间（简化为整数）
}

/// 创建错误上下文
pub fn create_error_context(location: String, operation: String, offset: Int, info: String) -> ErrorContext {
  ErrorContext::{
    location: location,
    operation: operation,
    data_offset: offset,
    additional_info: info
  }
}

/// 创建带上下文的错误
pub fn create_contextual_error(error: ZSTDError, severity: ErrorSeverity, context: ErrorContext) -> ContextualError {
  ContextualError::{
    error: error,
    severity: severity,
    context: context,
    timestamp: 0  // 简化处理，实际应该使用当前时间
  }
}

/// 将ZSTD错误转换为字符串
pub fn zstd_error_to_string(error: ZSTDError) -> String {
  error_to_string(error)
}

/// 获取错误严重程度字符串
pub fn severity_to_string(severity: ErrorSeverity) -> String {
  match severity {
    Error => "错误"
    Fatal => "致命错误"
  }
}

/// 格式化完整的错误信息
pub fn format_error(error: ContextualError) -> String {
  let error_msg = zstd_error_to_string(error.error)
  let severity_msg = severity_to_string(error.severity)
  
  "[" + severity_msg + "] " + error_msg + 
  "\n  位置: " + error.context.location +
  "\n  操作: " + error.context.operation +
  "\n  偏移: " + error.context.data_offset.to_string() +
  (if error.context.additional_info.length() > 0 {
    "\n  详情: " + error.context.additional_info
  } else {
    ""
  })
}

/// 验证ZSTD魔数
pub fn validate_magic_number(data: Bytes, offset: Int) -> Result[Unit, ContextualError] {
  if offset + 4 > data.length() {
    let context = create_error_context("validate_magic_number", "读取魔数", offset, "数据长度不足")
    let error = create_contextual_error(
      insufficient_data_error(),
      Fatal,
      context
    )
    return Err(error)
  }
  
  let magic = data[offset].to_uint() |
              (data[offset + 1].to_uint() << 8) |
              (data[offset + 2].to_uint() << 16) |
              (data[offset + 3].to_uint() << 24)
  
  if magic != ZSTD_MAGIC_NUMBER {
    let context = create_error_context("validate_magic_number", "验证魔数", offset, "")
    let error = create_contextual_error(
      invalid_magic_number_error(),
      Fatal,
      context
    )
    return Err(error)
  }
  
  Ok(())
}

/// 验证帧描述符
pub fn validate_frame_descriptor(descriptor: Byte) -> Result[Unit, ContextualError] {
  let desc_int = descriptor.to_int()
  
  // 检查版本号（位0）
  let version = desc_int & 0x03
  if version != 0 {
    let context = create_error_context("validate_frame_descriptor", "检查版本", 0, "不支持的版本")
    let error = create_contextual_error(
      invalid_frame_header_error(),
      Fatal,
      context
    )
    return Err(error)
  }
  
  // 检查保留位（位1）
  if (desc_int & 0x02) != 0 {
    let context = create_error_context("validate_frame_descriptor", "检查保留位", 0, "保留位必须为0")
    let error = create_contextual_error(
      invalid_frame_header_error(),
      Error,
      context
    )
    return Err(error)
  }
  
  Ok(())
}

/// 验证块头
pub fn validate_block_header(header: UInt, max_block_size: Int) -> Result[Unit, ContextualError] {
  let block_size = (header & 0x1FFFFF).reinterpret_as_int()  // 低21位
  let block_type = (header >> 1) & 0x3           // 块类型
  
  if block_size > max_block_size {
    let context = create_error_context("validate_block_header", "检查块大小", 0, "块大小超出限制")
    let error = create_contextual_error(
      invalid_data_error(),
      Error,
      context
    )
    return Err(error)
  }
  
  if block_type > 3 {
    let context = create_error_context("validate_block_header", "检查块类型", 0, "未知块类型")
    let error = create_contextual_error(
      unknown_block_type_error(),
      Error,
      context
    )
    return Err(error)
  }
  
  Ok(())
}

/// 验证数据完整性（简化的CRC检查）
pub fn validate_data_integrity(data: Bytes, expected_checksum: UInt) -> Result[Unit, ContextualError] {
  // 简化的校验和计算
  let mut calculated_checksum = 0
  for i = 0; i < data.length(); i = i + 1 {
    calculated_checksum = calculated_checksum ^ data[i].to_uint().reinterpret_as_int()
  }
  
  let expected_int = expected_checksum.reinterpret_as_int()
  if calculated_checksum != expected_int {
    let context = create_error_context("validate_data_integrity", "校验和验证", 0, 
      "期望: " + expected_int.to_string() + ", 计算: " + calculated_checksum.to_string())
    let error = create_contextual_error(
      invalid_data_error(),
      Error,
      context
    )
    return Err(error)
  }
  
  Ok(())
}

/// 验证窗口大小
pub fn validate_window_size(size: Int) -> Result[Unit, ContextualError] {
  if size < 1024 || size > (1 << 27) {  // 1KB to 128MB
    let context = create_error_context("validate_window_size", "检查窗口大小", 0, 
      "有效范围: 1KB - 128MB")
    let error = create_contextual_error(
      invalid_data_error(),
      Error,
      context
    )
    return Err(error)
  }
  
  Ok(())
}

/// 验证历史引用
pub fn validate_history_reference(offset: Int, available_history: Int) -> Result[Unit, ContextualError] {
  if offset <= 0 || offset > available_history {
    let context = create_error_context("validate_history_reference", "检查历史引用", 0, "偏移量超出范围")
    let error = create_contextual_error(
      invalid_data_error(),
      Error,
      context
    )
    return Err(error)
  }
  
  Ok(())
}

/// 错误恢复策略
pub enum RecoveryStrategy {
  Skip        // 跳过错误继续处理
  Retry       // 重试操作
  Abort       // 终止处理
}

/// 根据错误类型确定恢复策略
pub fn determine_recovery_strategy(error: ZSTDError) -> RecoveryStrategy {
  match error {
    // 致命错误，必须终止
    InvalidMagicNumber | InvalidFrameHeader => Abort
    
    // 数据错误，通常需要终止
    InvalidData | InsufficientData => Abort
    
    // 解码错误，可能可以跳过
    DecompressionError => Skip
    
    // 压缩错误，可以重试
    CompressionError => Retry
    
    // 未知块类型，跳过处理
    UnknownBlockType => Skip
    
    // 带消息的错误，根据具体情况处理
    Message(_) => Abort
    ParseError(_) => Abort
    ValidationError(_) => Skip
  }
}

/// 应用错误恢复策略
pub fn apply_recovery_strategy(strategy: RecoveryStrategy, context: String) -> String {
  match strategy {
    Skip => "跳过错误，继续处理: " + context
    Retry => "重试操作: " + context
    Abort => "终止处理: " + context
  }
}

/// 错误统计信息
pub struct ErrorStats {
  mut error_count: Int
  mut fatal_count: Int
  mut total_count: Int
}

/// 创建错误统计
pub fn create_error_stats() -> ErrorStats {
  ErrorStats::{
    error_count: 0,
    fatal_count: 0,
    total_count: 0
  }
}

/// 更新错误统计
pub fn update_error_stats(stats: ErrorStats, severity: ErrorSeverity) -> Unit {
  stats.total_count = stats.total_count + 1
  match severity {
    Error => stats.error_count = stats.error_count + 1
    Fatal => stats.fatal_count = stats.fatal_count + 1
  }
}

/// 获取错误统计报告
pub fn get_error_stats_report(stats: ErrorStats) -> String {
  "错误统计: 总计 " + stats.total_count.to_string() + 
  " (错误: " + stats.error_count.to_string() +
  ", 致命: " + stats.fatal_count.to_string() + ")"
}
