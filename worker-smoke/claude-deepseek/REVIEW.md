# M7 Claude Code + DeepSeek：Solo 产物独立审查

日期：2026-09-25  
原始产物：`claude-l2-review.tar.gz`（SHA-256 `cfc01bc2888c602c76a1a2a2d2d832b541440be7925bf0ac048d59012442ff53`）  
阶段：**审查已完成，待修复严格 JSON 边界问题；原始 5 个源码文件将以独立交付提交，不在本报告中冒充已上传。**

## 原始交付清单

`validate_config.py`、`test_validate_config.py`、`README.md`、`fixtures/valid.json`、`fixtures/invalid.json`。

包内只有五个预期的常规文件，无符号链接或路径穿越。实际源文件的 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| validate_config.py | `c82dbd5c2eab3f4ecbd06ca62dfa996827a7b721b6b1f3f62a17aeb62558bfe6` |
| test_validate_config.py | `3ccc2391e4c0d7e1a73d22271bab36d63d040bde578a4bd7a3e6fb5192db426f` |
| README.md | `9188ead2af19a15bcd822f3630a079aa036051ec723ed293ee02f3b644312e3e` |
| fixtures/valid.json | `bfdb7d7b18df74718d4589f6ddecf2230b061ee465b4bb636aecdbf2db50d777` |
| fixtures/invalid.json | `d0b94419fcc88ee0ce22b82974a99697d6467590e5d3e070a2e8fe7e77f6960d` |

## 已独立验证的功能

- 将原始 tar.gz 安全展开至独立审查目录后，重新运行原样交付的 `python3 -B -m unittest discover -p 'test_*.py' -v`，**54/54 通过**。
- `valid.json`：退出 0，`valid=true`，错误 0；`invalid.json`：退出 1，`valid=false`，收集 20 个错误；不存在文件：退出 2。
- 源码按照 `path,code` 排序错误，正确排除 bool 作为整数，支持重复 ID、跨表引用、多个错误聚合及命令行统一 JSON。
- 静态检查：运行代码仅依赖 Python 标准库和本地文件读取；测试中的 subprocess 仅调用本地 Python 校验程序，未发现网络请求、Git push 或读取 PDS 凭据的代码。静态检查不代替操作系统级隔离。

## 待修复：不符合严格 JSON 语法的数字常量

Python 标准库的 `json.loads` 默认接受非标准的 `NaN`、`Infinity` 与 `-Infinity`。原始校验器直接使用默认解析器，因此以下非法 JSON 被作为有效配置处理，退出码为 **0**：

```json
{"workers":[],"model_profiles":[],"extra":NaN}
```

原任务规定文件 JSON 格式错误退出码必须为 **2**。建议使用 `parse_constant` 拒绝非标准常量，并补充三组非法数字的 CLI 回归测试。已有的 54 项测试未覆盖这一边界；该缺陷属于补充审查发现，**不能因 54 项全部通过就宣称严格 JSON 合规**。

第二项非阻断说明：重复 JSON object 字段名在 Python 默认解析中采用后一个值。是否拒绝重复字段应由 PDS 配置规范另行明确，当前不擅自扩大 Worker 原任务要求。

## 交付与发布边界

- 现有 Solo 自动验收已通过，审查发现一项需修复的解析边界；修复及对应测试通过之前，PR 保持 Draft。
- 原始源码作为 Worker 原产物保存；如需审查员补丁，应另开一个修复 commit，不静默篡改原始测评结果。
- 该工具是**简化任务的测试原型**，不是 v0.1 已实现的完整 Worker Ladder Schema v3 校验器，不能直接替换 PDS 的正式 `loadWorkerLadderConfig()`。
- Flash Max 是否被上游实际接受，目前只有配置意图，没有网关请求参数证据。
