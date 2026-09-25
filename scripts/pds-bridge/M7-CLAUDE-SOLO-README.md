# M7 Claude Code + DeepSeek Flash：L2 Solo 验收

此目录保存 **一次性、可审计的独立编码测试**。Claude Code 2.1.280 和 DeepSeek Anthropic 兼容配置已完成 API、真实 Write、限定 Bash 冒烟测试；本脚本用于下一步完整的 Python JSON Worker 配置校验器任务，不代表已通过 PDS-Bridge 联合 Golden Suite。

## 使用边界

- 唯一运行身份：`pdsbridge`（`HOME=/var/lib/pds-bridge`）。
- 已存在并通过工具测试的启动器：`~/.local/bin/pds-claude-standard-official`；不重新安装、不覆盖密钥。
- 创建**新的** `~/solo-workspaces/claude-deepseek/json-validator`，拒绝覆盖已有工作区或证据。
- 仅在键入 `RUN` 后才调用付费 API；最多 40 turns、20 分钟，CLI 自身预算上限为估算 2 美元，**并非 DeepSeek 实际费用的硬性保证**。
- 只预批准 Read/Write/Edit/Glob/Grep 和三条精确 Python Bash 命令。Claude 如果需要额外 Shell 命令，应停止并报告，不得绕过拒绝。参考：[Claude Code 权限说明](https://code.claude.com/docs/en/permissions)。
- Worker 不运行 Git、不接触密钥、不 push/PR；Bridge 最终负责 GitHub 交付。**CLI 权限不是操作系统级凭据隔离**，因此只在当前可信测试环境内使用。

## 在 PDS 上执行

先从本 PR 的 GitHub 分支或审核后的 commit 下载 `run-m7-claude-deepseek-solo.sh` 到你指定的审核目录。对脚本执行 `bash -n` 并阅读源码；**不要通过 curl 管道直接运行远程脚本**。

以下命令由已经切换到 `pdsbridge` 的终端执行：

`bash run-m7-claude-deepseek-solo.sh inspect`

检查现有环境，**不创建文件、不调用付费模型**。

`bash run-m7-claude-deepseek-solo.sh run`

显示预算与路径，输入 `RUN` 后在全新子工作区中执行完整 Solo 任务，并保存 JSON 结果和 stderr 到仅当前用户可读的证据目录。只执行一次；遇到中断不能自动覆盖重试。

`bash run-m7-claude-deepseek-solo.sh verify`

独立运行 unittest 和 valid/invalid/malformed/missing 四组 CLI 场景，检查测试数不少于 15、返回码以及 JSON 多错误聚合和排序。复验报告写入证据目录。

## 判定标准

`INDEPENDENT_CHECK=PASS` 表示脚本内的自动检查通过，**不等于完整 Solo 或 M7 Golden Suite 已通过**：还需审查实际代码与 CLI JSON 中的权限拒绝、实际模型、模型账单和工作区外访问情况。上游 Flash Max 档位仍需单独核验；仅设置 `CLAUDE_CODE_EFFORT_LEVEL=max` 不足以证明实际生效。

本次与 OpenCode Standard 采用同一份 Python JSON 配置校验需求，便于比较不同 CLI 在相近模型配置下的可靠性。
