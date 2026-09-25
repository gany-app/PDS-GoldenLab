#!/usr/bin/env bash
# M7 Claude Code + DeepSeek: one trusted Solo task in a fresh workspace.
# inspect = read-only, run = paid headless test, verify = independent local tests.
set -Eeuo pipefail
umask 077
USER_NAME=pdsbridge
USER_HOME=/var/lib/pds-bridge
ROOT="$USER_HOME/solo-workspaces/claude-deepseek"
WORK="$ROOT/json-validator"
EVIDENCE="$ROOT/.json-validator-evidence"
LAUNCHER="$USER_HOME/.local/bin/pds-claude-standard-official"
CREDENTIAL="$USER_HOME/.config/pds-bridge-l2/claude-deepseek.env"
fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
inspect() {
  [[ "$(id -un)" == "$USER_NAME" && "$HOME" == "$USER_HOME" ]] || fail 'run as pdsbridge with HOME=/var/lib/pds-bridge'
  [[ -d "$ROOT" && ! -L "$ROOT" ]] || fail 'Solo parent is missing or a symlink'
  [[ -x "$LAUNCHER" && ! -L "$LAUNCHER" ]] || fail 'official launcher is missing or symlinked'
  [[ -f "$CREDENTIAL" && ! -L "$CREDENTIAL" ]] || fail 'credential file is missing or symlinked'
  command -v python3 >/dev/null || fail 'python3 missing'
  command -v timeout >/dev/null || fail 'timeout missing'
  printf 'runtimeUser=%s\nworkspace=%s\n' "$(id -un)" "$WORK"
  printf 'claudeVersion='; "$LAUNCHER" --version
  python3 --version
  if [[ -e "$WORK" || -L "$WORK" ]]; then
    echo 'workspace=EXISTS; run will refuse overwrite'
  else
    echo 'workspace=ABSENT; ready'
  fi
  echo 'CLI permissions are not OS-level credential isolation.'
}
write_prompt() {
cat > "$EVIDENCE/task.md" <<'PROMPT'
# PDS-Bridge M7 · Claude Code + DeepSeek Flash L2 Solo 验收

你是独立 L2 Coding Worker。只使用当前已配置的 Claude Code + DeepSeek Flash；不得调用其他 AI、切换模型或使用 Codex。

唯一允许修改的目录：/var/lib/pds-bridge/solo-workspaces/claude-deepseek/json-validator。不要触碰其他工作区、凭据、系统配置或 CLI 配置；不要安装依赖、执行 Git 命令、提交或创建 PR。

使用 Python 标准库交付五项产物：
1. validate_config.py
2. fixtures/valid.json：至少 3 个虚构 Worker、2 个虚构模型配置
3. fixtures/invalid.json：至少包含重复 ID、非法等级、无效超时、无效并发数及不存在的模型引用
4. test_validate_config.py：至少 15 项 unittest
5. README.md：配置规范、用法、输出示例、退出码与测试说明

规范如下：
- 顶层必须为对象，workers 和 model_profiles 必须是数组，每个元素必须是对象。
- Worker 必填 id、level、model_profile、timeout_seconds、concurrency_limit；id 唯一，level 仅 L1/L2/L3。
- timeout_seconds 为 1..3600 的整数，concurrency_limit 为 1..8 的整数；bool 与小数都不合法。
- model_profiles 各项必填唯一 id、非空 provider、非空 model；worker.model_profile 必须引用已有模型 ID。
- 所有必填字符串必须非空且不能只有空格。额外字段允许存在。
- 尽可能聚合独立错误，每条至少包含 path、code、message，按 (path,code) 稳定排序。
- CLI 仅向 stdout 输出 JSON，至少含 valid(bool)、errors(array)；合法退出 0、校验失败退出 1、文件不可读/不存在/JSON 语法错误退出 2；不得出现未经处理的异常。

必须亲自用 Bash 工具执行以下三条预批准的精确命令。不要添加分号、echo、重定向或额外参数：
python3 -B -m unittest discover -p 'test_*.py' -v
python3 -B validate_config.py fixtures/valid.json
python3 -B validate_config.py fixtures/invalid.json

invalid.json 返回 1 是预期结果，不要因此把任务判失败。若需要未批准的 Bash 命令，停止并如实报告，不得修改权限或绕过拒绝；阅读和编辑文件使用 Read/Write/Edit/Glob/Grep。

报告只能基于真实工具输出：实际模型、产物、测试数量及结果、两组配置的 JSON 摘要与退出码、修复过程和未完成事项。你自己的完成声明不等于独立验收通过。
PROMPT
chmod 600 "$EVIDENCE/task.md"
}
run() {
  inspect
  [[ ! -e "$WORK" && ! -L "$WORK" ]] || fail 'workspace exists; refusing overwrite'
  [[ ! -e "$EVIDENCE" && ! -L "$EVIDENCE" ]] || fail 'evidence exists; refusing overwrite'
  printf 'One paid API task: 40 turns max, CLI-estimated $2 max, 20-minute timeout.\nType RUN to approve: '
  local approval
  IFS= read -r approval
  [[ "$approval" == RUN ]] || fail 'not approved; no changes'
  install -d -m 0700 "$WORK" "$EVIDENCE"
  write_prompt
  local rc=0
  if (cd "$WORK" && timeout --signal=TERM --kill-after=20s 20m "$LAUNCHER" \
      --tools Read,Write,Edit,Glob,Grep,Bash \
      --allowedTools Read Write Edit Glob Grep \
        "Bash(python3 -B -m unittest discover -p 'test_*.py' -v)" \
        'Bash(python3 -B validate_config.py fixtures/valid.json)' \
        'Bash(python3 -B validate_config.py fixtures/invalid.json)' \
      --permission-mode dontAsk --max-turns 40 --max-budget-usd 2.00 \
      -p --output-format json "$(cat "$EVIDENCE/task.md")" \
      >"$EVIDENCE/result.json" 2>"$EVIDENCE/stderr.log"); then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$rc" >"$EVIDENCE/runner-exit-code.txt"
  printf 'launcherExit=%s\nresultFile=%s\nstderrFile=%s\n' \
    "$rc" "$EVIDENCE/result.json" "$EVIDENCE/stderr.log"
  python3 - "$EVIDENCE/result.json" <<'PY'
import json, pathlib, sys
try:
    d = json.loads(pathlib.Path(sys.argv[1]).read_text())
except (OSError, ValueError):
    print('resultJson=INVALID_OR_EMPTY; inspect private log')
else:
    print('terminalReason=', d.get('terminal_reason'),
          'isError=', d.get('is_error'), 'turns=', d.get('num_turns'))
    print('cliEstimatedUSD=', d.get('total_cost_usd'),
          '(not actual provider billing)')
    print('permissionDenials=', len(d.get('permission_denials') or []))
    print('models=', ','.join(sorted((d.get('modelUsage') or {}).keys())))
PY
  printf 'Next: run verify; do not count model self-report as Solo PASS.\n'
  [[ "$rc" -eq 0 ]] || exit "$rc"
}
verify() {
  [[ "$(id -un)" == "$USER_NAME" && "$HOME" == "$USER_HOME" ]] || fail 'run as pdsbridge'
  [[ -d "$WORK" && ! -L "$WORK" && -d "$EVIDENCE" ]] || fail 'run has not created workspace/evidence'
  local f
  for f in validate_config.py fixtures/valid.json fixtures/invalid.json test_validate_config.py README.md; do
    [[ -f "$WORK/$f" && ! -L "$WORK/$f" ]] || fail "missing/symlinked artifact: $f"
  done
  local report tests_rc valid_rc invalid_rc malformed_rc missing_rc
  report="$(mktemp -d "$EVIDENCE/verify.XXXXXXXX")"
  cd "$WORK"
  if python3 -B -m unittest discover -p 'test_*.py' -v >"$report/unittest.log" 2>&1; then tests_rc=0; else tests_rc=$?; fi
  if python3 -B validate_config.py fixtures/valid.json >"$report/valid.json" 2>"$report/valid.err"; then valid_rc=0; else valid_rc=$?; fi
  if python3 -B validate_config.py fixtures/invalid.json >"$report/invalid.json" 2>"$report/invalid.err"; then invalid_rc=0; else invalid_rc=$?; fi
  printf '{invalid_json:' > "$report/malformed-input.json"
  if python3 -B validate_config.py "$report/malformed-input.json" >"$report/malformed.json" 2>"$report/malformed.err"; then malformed_rc=0; else malformed_rc=$?; fi
  if python3 -B validate_config.py "$report/missing-input.json" >"$report/missing.json" 2>"$report/missing.err"; then missing_rc=0; else missing_rc=$?; fi
  printf 'evidenceDir=%s\n' "$report"
  python3 - "$report" "$tests_rc" "$valid_rc" "$invalid_rc" "$malformed_rc" "$missing_rc" <<'PY'
import json, pathlib, re, sys
p = pathlib.Path(sys.argv[1])
tests_rc, valid_rc, invalid_rc, malformed_rc, missing_rc = map(int, sys.argv[2:])
log = (p/'unittest.log').read_text(errors='replace')
m = re.search(r'Ran (\d+) tests?', log)
count = int(m.group(1)) if m else -1
print(f'unittestExit={tests_rc} unittestCount={count}')
print(f'validExit={valid_rc} invalidExit={invalid_rc} malformedExit={malformed_rc} missingExit={missing_rc}')
checks = [tests_rc == 0, count >= 15, valid_rc == 0, invalid_rc == 1,
          malformed_rc == 2, missing_rc == 2]
try:
    good = json.loads((p/'valid.json').read_text())
    bad = json.loads((p/'invalid.json').read_text())
    errors = bad['errors']
    paths = [(e['path'], e['code']) for e in errors]
    print('validFlag=', good.get('valid'), 'invalidFlag=', bad.get('valid'),
          'invalidErrors=', len(errors))
    checks.extend([good.get('valid') is True, good.get('errors') == [],
                   bad.get('valid') is False, isinstance(errors, list),
                   len(errors) >= 4, paths == sorted(paths)])
except (OSError, ValueError, KeyError, TypeError) as exc:
    print('JSON parse/shape failure:', str(exc)); checks.append(False)
print('INDEPENDENT_CHECK=' + ('PASS' if all(checks) else 'FAIL'))
if not all(checks):
    print('Inspect private evidence logs; do not claim Solo PASS.')
    raise SystemExit(1)
PY
}
[[ "$#" -eq 1 ]] || { echo 'Usage: script {inspect|run|verify}' >&2; exit 2; }
case "$1" in
  inspect) inspect ;;
  run) run ;;
  verify) verify ;;
  *) echo 'Usage: script {inspect|run|verify}' >&2; exit 2 ;;
esac
