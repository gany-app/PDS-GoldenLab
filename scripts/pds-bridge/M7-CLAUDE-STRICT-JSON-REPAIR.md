# M7 · Claude Code + DeepSeek Flash：严格 JSON 边界修复

你正在对自己已经完成的 PDS-Bridge L2 Solo 任务做**一处有范围限制的返工**，不是重新开发。你必须亲自修改现有文件、运行测试并据实汇报。当前运行的模型应为 deepseek-flash[1m]；不得切换模型、调用其他 AI。

## 唯一允许修改范围

仅能修改当前目录内的：
- `validate_config.py`
- `test_validate_config.py`
- `README.md`（只在必要时更新 JSON 语法说明）

不得修改 `fixtures/valid.json`、`fixtures/invalid.json`；不得操作其他工作区、系统配置、认证文件或任何 Git 仓库。不得安装软件或执行 Git push/PR。

## 已有问题和重现

现有 `load_document()` 使用 Python 默认 `json.loads(raw)`。Python 默认接受非标准 JSON 常量 `NaN`、`Infinity`、`-Infinity`，因此例如下面的配置错误地返回有效结果和退出码 0：

```
{"workers":[],"model_profiles":[],"extra":NaN}
```

原任务规定，**非法 JSON 语法必须返回退出码 2**，并继续通过现有统一 JSON 输出协议报告错误。因此这次不是修改 Worker 字段规则，而是修正 JSON 解析的严格性。

## 具体任务

1. 使用 Python 标准库 `json.loads` 的 `parse_constant` 参数显式拒绝 `NaN`、`Infinity`、`-Infinity`。建议回调抛出 `ValueError`，交由已有 `load_document()` 错误转换逻辑转成 `ConfigFileError("invalid_json_syntax", ...)`。
2. 在现有 `test_validate_config.py` 中增加至少三项实际 CLI 子进程测试，分别验证上述三个非法数值。把非标准数值放在一个**额外字段**中，确保整个文档其他部分合法、不能被现有字段校验碰巧挡住。每种输入都必须断言：
   - CLI 退出码为 2；
   - stdout 是唯一且可解析的 JSON 结果；
   - `valid=false`；
   - 首条错误 `code="invalid_json_syntax"`。
3. 不得降低原有 54 项测试的覆盖范围，不得改动原有测试预期来掩盖实现问题。
4. 如果 README 声称任何 JSON 语法都接受，请将文档调整为“拒绝 NaN、Infinity 和 -Infinity 等非标准数字”，否则保持原样。

## 真实执行

亲自使用 Bash 工具执行**下面这条精确命令**（不要附加分号或其他子命令）：

`python3 -B -m unittest discover -p 'test_*.py' -v`

其他测试通过已添加的单元测试覆盖；如果仍需额外 Shell 命令，应停止并报告权限限制，不得绕过或扩大权限。只使用 Read、Edit、Write、Glob、Grep 查看/修改文件。

## 最终报告

只根据真实工具结果说明：修改的文件、严格解析的实现要点、原有与新增测试的数量、最终测试是否全部通过、存在的限制。不能凭文字声称“已运行测试”。本轮禁止 Git push/PR，GitHub 交付由 PDS-Bridge 管理方在独立复验后进行。
