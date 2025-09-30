/// ZSTD 字典和窗口缓冲区管理模块
/// 实现字典加载、窗口缓冲区管理和历史数据访问

/// 字典类型
pub enum DictionaryType {
  None          // 无字典
  Raw           // 原始字典
  Formatted     // 格式化字典
}

/// 字典信息
pub struct Dictionary {
  dict_type: DictionaryType
  dict_id: UInt             // 字典ID
  data: Bytes               // 字典数据
  size: Int                 // 字典大小
}

/// 窗口缓冲区
/// 用于存储最近解压缩的数据，支持回溯引用
pub struct WindowBuffer {
  buffer: Array[Byte]   // 环形缓冲区
  capacity: Int         // 缓冲区容量
  mut position: Int         // 当前写入位置
  mut size: Int             // 当前有效数据大小
  dictionary: Dictionary    // 关联的字典
}

/// 创建空字典
pub fn create_empty_dictionary() -> Dictionary {
  {
    dict_type: None,
    dict_id: 0,
    data: Bytes::from_array([]),
    size: 0
  }
}

/// 从数据创建原始字典
pub fn create_raw_dictionary(data: Bytes) -> Dictionary {
  {
    dict_type: Raw,
    dict_id: 0,
    data: data,
    size: data.length()
  }
}

/// 解析格式化字典
/// 格式化字典包含魔数、字典ID和压缩数据
pub fn parse_formatted_dictionary(data: Bytes) -> Result[Dictionary, String] {
  if data.length() < 8 {
    return Err("字典数据太短")
  }
  
  // 检查魔数 (0xEC30A437)
  let magic = data[0].to_uint() |
              (data[1].to_uint() << 8) |
              (data[2].to_uint() << 16) |
              (data[3].to_uint() << 24)
  
  if magic != 0xEC30A437 {
    return Err("无效的字典魔数")
  }
  
  // 读取字典ID
  let dict_id = data[4].to_uint() |
                (data[5].to_uint() << 8) |
                (data[6].to_uint() << 16) |
                (data[7].to_uint() << 24)
  
  // 提取字典内容（跳过8字节头部）
  let dict_content_size = data.length() - 8
  let dict_content: Array[Byte] = []
  for i = 8; i < data.length(); i = i + 1 {
    dict_content.push(data[i])
  }
  
  Ok({
    dict_type: Formatted,
    dict_id: dict_id,
    data: Bytes::from_array(dict_content),
    size: dict_content_size
  })
}

/// 创建窗口缓冲区
pub fn create_window_buffer(capacity: Int, dictionary: Dictionary) -> WindowBuffer {
  let actual_capacity = capacity.max(1024)  // 最小1KB
  
  {
    buffer: Array::make(actual_capacity, 0),
    capacity: actual_capacity,
    position: 0,
    size: 0,
    dictionary: dictionary
  }
}

/// 向窗口缓冲区写入数据
pub fn write_to_window(window: WindowBuffer, data: Bytes) -> Unit {
  for i = 0; i < data.length(); i = i + 1 {
    window.buffer[window.position] = data[i]
    window.position = (window.position + 1) % window.capacity
    
    if window.size < window.capacity {
      window.size = window.size + 1
    }
  }
}

/// 从窗口缓冲区读取历史数据
/// offset: 相对于当前位置的偏移量（1表示前一个字节）
/// length: 要读取的字节数
pub fn read_from_window(window: WindowBuffer, offset: Int, length: Int) -> Result[Bytes, String] {
  if offset <= 0 || length <= 0 {
    return Err("无效的偏移量或长度")
  }
  
  if offset > window.size + window.dictionary.size {
    return Err("偏移量超出可用历史数据范围")
  }
  
  let result: Array[Byte] = []
  
  for i = 0; i < length; i = i + 1 {
    let byte_offset = offset + i
    let byte_val = get_historical_byte(window, byte_offset)
    match byte_val {
      Ok(b) => result.push(b)
      Err(e) => return Err(e)
    }
  }
  
  Ok(Bytes::from_array(result))
}

/// 获取历史数据中的单个字节
/// offset: 相对于当前位置的偏移量（1表示前一个字节）
fn get_historical_byte(window: WindowBuffer, offset: Int) -> Result[Byte, String] {
  if offset <= 0 {
    return Err("无效的偏移量")
  }
  
  // 首先检查窗口缓冲区
  if offset <= window.size {
    let buffer_pos = if window.position >= offset {
      window.position - offset
    } else {
      window.capacity - (offset - window.position)
    }
    return Ok(window.buffer[buffer_pos])
  }
  
  // 如果窗口缓冲区中没有，检查字典
  let dict_offset = offset - window.size
  if dict_offset <= window.dictionary.size {
    let dict_pos = window.dictionary.size - dict_offset
    return Ok(window.dictionary.data[dict_pos])
  }
  
  Err("偏移量超出历史数据范围")
}

/// 复制匹配数据到窗口缓冲区
/// 这是ZSTD解压缩中的核心操作，用于处理重复序列
pub fn copy_match(window: WindowBuffer, offset: Int, length: Int) -> Result[Bytes, String] {
  if offset <= 0 || length <= 0 {
    return Err("无效的匹配参数")
  }
  
  let copied_data: Array[Byte] = []
  
  // 逐字节复制，支持重叠复制
  for i = 0; i < length; i = i + 1 {
    let byte_result = get_historical_byte(window, offset)
    match byte_result {
      Ok(byte_val) => {
        copied_data.push(byte_val)
        // 将复制的字节也写入窗口缓冲区
        window.buffer[window.position] = byte_val
        window.position = (window.position + 1) % window.capacity
        
        if window.size < window.capacity {
          window.size = window.size + 1
        }
      }
      Err(e) => return Err(e)
    }
  }
  
  Ok(Bytes::from_array(copied_data))
}

/// 获取窗口缓冲区的当前状态信息
pub fn get_window_info(window: WindowBuffer) -> String {
  "WindowBuffer: capacity=" + window.capacity.to_string() + 
  ", size=" + window.size.to_string() + 
  ", position=" + window.position.to_string() +
  ", dict_size=" + window.dictionary.size.to_string()
}

/// 重置窗口缓冲区
pub fn reset_window(window: WindowBuffer) -> Unit {
  window.position = 0
  window.size = 0
  // 清空缓冲区
  for i = 0; i < window.capacity; i = i + 1 {
    window.buffer[i] = 0
  }
}

/// 检查字典是否有效
pub fn validate_dictionary(dict: Dictionary) -> Bool {
  match dict.dict_type {
    None => true
    Raw => dict.data.length() == dict.size
    Formatted => {
      dict.data.length() == dict.size && dict.dict_id != 0
    }
  }
}

/// 计算窗口大小
/// 根据帧描述符计算所需的窗口大小
pub fn calculate_window_size(window_descriptor: Byte) -> Int {
  let exponent = (window_descriptor.to_int() >> 3) & 0x0F
  let mantissa = window_descriptor.to_int() & 0x07
  
  if exponent == 0 {
    // 单段模式，使用内容大小作为窗口大小
    return 1024  // 默认最小窗口大小
  }
  
  // 计算窗口大小：(8 + mantissa) << (exponent + 10)
  let base = 8 + mantissa
  let shift = exponent + 10
  base << shift
}

/// 预加载字典到窗口缓冲区
/// 在开始解压缩之前，将字典内容预加载到窗口缓冲区
pub fn preload_dictionary(window: WindowBuffer) -> Unit {
  if window.dictionary.size > 0 {
    // 将字典数据复制到窗口缓冲区的末尾
    let dict_data = window.dictionary.data
    let copy_size = dict_data.length().min(window.capacity)
    
    // 从字典末尾开始复制（最近的数据）
    let start_pos = dict_data.length() - copy_size
    for i = 0; i < copy_size; i = i + 1 {
      window.buffer[i] = dict_data[start_pos + i]
    }
    
    window.size = copy_size
    window.position = copy_size % window.capacity
  }
}

/// 获取可用的历史数据总量
pub fn get_available_history_size(window: WindowBuffer) -> Int {
  window.size + window.dictionary.size
}
