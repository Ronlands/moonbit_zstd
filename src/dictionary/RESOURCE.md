# Dictionary 模块资源

## 1. 模块定位

- 路径：`src/dictionary`
- 主文件：`src/dictionary/dictionary.mbt`
- 职责：字典对象、字典解析/保存、Cover 算法构建、字典收益统计。

## 2. 核心类型索引

- `DictionaryType`
- `Dictionary`
- `DictionaryBenefitStats`

## 3. 类型与字段说明

### 3.1 `DictionaryType`

- 取值：`Raw`、`Formatted`
- 语义：
  - `Raw`：原始字典
  - `Formatted`：带 ZSTD 字典头格式的字典

### 3.2 `Dictionary`

- 字段：
  - `dict_type`
  - `dict_id`
  - `content`
- 单位与口径：
  - `dict_id` 使用 `UInt`
  - `content.length()` 为字典大小，单位字节

### 3.3 `DictionaryBenefitStats`

- 字段：
  - `original_size`：原始数据大小，字节
  - `dict_size`：字典大小，字节
  - `compressed_size_without_dict`：无字典压缩大小，字节
  - `compressed_size_with_dict`：有字典压缩大小，字节
  - `saved_bytes`：节省字节数，字节
  - `compression_ratio_without`：无字典压缩比，`x`
  - `compression_ratio_with`：有字典压缩比，`x`
  - `benefit_percentage`：收益百分比，`%`

## 4. 解析与保存规则

### 4.1 ZSTD 格式字典

- 魔数：`0xEC30A437`
- 前 4 字节：字典魔数
- 后 4 字节：字典 ID
- 其余内容：字典正文

### 4.2 字典校验

- `dict_id` 必须在 `[32768, 0x7FFFFFFF]`
- 字典内容不能为空
- 字典大小建议不超过 `2MB`

## 5. 字典 ID 规则

- 生成函数：`generate_dictionary_id`
- 规则：
  - 仅哈希前 `1KB` 内容
  - 结果通过 `hash + 32768U` 避开保留区
  - 如果越界，则回退到 `32768U`

## 6. Cover 算法口径

- 入口：`build_dictionary_with_cover(samples, target_size, ngram_size)`
- `ngram_size` 有效范围会被夹到 `[4, 16]`
- 核心步骤：
  1. 抽取所有 `n-gram`
  2. 统计频率
  3. 计算得分
  4. 按得分降序贪心选入字典
- 得分公式：
  - `score = (count - 1) * ngram_size`
- 含义：第一次出现需要占用字典空间，因此收益从第二次出现开始计算。

## 7. 收益统计口径

### 7.1 简化收益

- 方法：`calculate_dictionary_benefit`
- 公式：
  - `benefit = (without_dict_size - with_dict_size) / without_dict_size`
- 返回值：`Double`
- 范围：无收益或负收益时返回 `0.0`

### 7.2 详细收益

- 方法：`calculate_dictionary_benefit_detailed`
- 公式：
  - `saved_bytes = compressed_size_without_dict - compressed_size_with_dict`
  - `compression_ratio_without = original_size / compressed_size_without_dict`
  - `compression_ratio_with = original_size / compressed_size_with_dict`
  - `benefit_percentage = saved_bytes / compressed_size_without_dict * 100`
- 精度：
  - 存储为 `Double`
  - `format_benefit_stats` 展示时通过 `format_double` 做指定位数文本化
- 取整说明：
  - `format_double` 当前通过乘法、转 `Int`、再回转 `Double` 的方式处理，本质更接近截断式格式化，不是严格四舍五入。

## 8. 注意事项

- 本模块的 `Dictionary` 与 `core` 模块中的 `Dictionary` 不是同一个定义。
- 字典收益必须基于“实际压缩结果”理解，不能把估算值写成真实收益。
