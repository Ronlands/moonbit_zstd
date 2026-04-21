# Test 模块资源

## 1. 模块定位

- 路径：`src/test`
- 职责：基础测试、兼容性测试、编码测试、金标测试、回归测试与测试工具。

## 2. 文件索引

- `basic_tests.mbt`：基础压缩/解压、格式检测、文件分析、空数据等测试。
  - 包含流式压缩生命周期测试，校验 `write / flush / finish`、统计快照与 checksum 输出。
- `compliance_tests.mbt`：魔数、帧头、块类型、校验和、字节序兼容性测试。
- `encoding_tests.mbt`：`LL / ML / OF` 编码与序列往返测试。
- `golden_tests.mbt`：官方样本与错误样本测试。
- `noncompliance_tests.mbt`：历史问题回归与交叉兼容测试。
- `save_compressed.mbt`：导出压缩结果给外部工具验证。
- `test_utils.mbt`：测试工具函数。

## 3. 测试工具说明

### 3.1 `repeat_string`

- 用途：构造展示字符串。

### 3.2 `verify_data_equal`

- 用途：比较两段 `Bytes` 是否逐字节相等。

### 3.3 `run_test_suite`

- 输入：测试套件名称和 `(测试名, 是否通过)` 数组。
- 输出：是否全部通过。
- 统计口径：
  - `passed`：通过项数量
  - `total`：总项数量
  - 返回值：`passed == total`

## 4. 重点回归主题

- FHD 保留位必须拒绝
- 拼接帧必须连续解码
- 损坏序列计数不能返回部分数据
- 编码器不能产生超出 `131072` 的块
- 非单段帧必须正确解析 `Window_Descriptor`
- 与官方 `zstd.exe` 输出的交叉兼容

## 5. 样本依赖

- 本模块大量依赖 `src/test-data/` 下资源。
- 详细资源分类见 `src/test-data/RESOURCE.md`。
