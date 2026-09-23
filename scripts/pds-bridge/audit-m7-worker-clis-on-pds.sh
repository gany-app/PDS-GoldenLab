#!/usr/bin/env bash
# Read-only M7 CLI inventory. Does not install, upgrade, authenticate or print secrets.
set -euo pipefail
umask 077

UNIT=pds-bridge-v01-m5-stage.service
UNIT_FILE=/etc/systemd/system/$UNIT

fail() { printf 'PDS_M7_CLI_AUDIT_FAILED: %s\n' "$1" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || fail 'run with sudo'
for command_name in systemctl runuser getent bash sed; do
  command -v "$command_name" >/dev/null || fail "missing $command_name"
done
[[ -f "$UNIT_FILE" ]] || fail 'M6 candidate service is not installed'
systemctl is-active --quiet "$UNIT" || fail 'M6 candidate service is not active'

RUNTIME_USER="$(systemctl show -P User "$UNIT")"
RUNTIME_HOME="$(getent passwd "$RUNTIME_USER" | cut -d: -f6)"
RUNTIME_PATH="$(sed -n 's/^Environment=PATH=//p' "$UNIT_FILE")"
[[ -n "$RUNTIME_USER" && "$RUNTIME_USER" != root && -d "$RUNTIME_HOME" && -n "$RUNTIME_PATH" ]] || \
  fail 'runtime identity, home or PATH is invalid'

runtime() {
  runuser -u "$RUNTIME_USER" -- env HOME="$RUNTIME_HOME" PATH="$RUNTIME_PATH" \
    XDG_CONFIG_HOME="$RUNTIME_HOME/.config" "$@"
}

find_runtime_command() {
  runtime bash -c 'command -v "$1" 2>/dev/null || true' _ "$1"
}

one_line() {
  tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-180
}

probe() {
  local id="$1" command_name="$2" version_arg="$3" help_mode="$4" binary version help
  binary="$(find_runtime_command "$command_name")"
  if [[ -z "$binary" ]]; then
    printf '%s.status=MISSING\n' "$id"
    return
  fi
  version="$(runtime "$binary" "$version_arg" 2>&1 | head -n 1 | one_line || true)"
  case "$help_mode" in
    opencode) help="$(runtime "$binary" run --help 2>&1 || true)" ;;
    qwen) help="$(runtime "$binary" --help 2>&1 || true)" ;;
    codex) help="$(runtime "$binary" exec --help 2>&1 || true)" ;;
    kiro) help="$(runtime "$binary" chat --help 2>&1 || true)" ;;
    *) fail 'unknown probe mode' ;;
  esac
  printf '%s.status=INSTALLED\n%s.path=%s\n%s.version=%s\n' "$id" "$id" "$binary" "$id" "${version:-unknown}"
  case "$help_mode" in
    opencode)
      [[ "$help" == *'--format'* && "$help" == *'--dir'* ]] && printf '%s.headless=PASS\n' "$id" || printf '%s.headless=FAIL\n' "$id"
      ;;
    qwen)
      [[ "$help" == *'--output-format'* && "$help" == *'stream-json'* ]] && printf '%s.headless=PASS\n' "$id" || printf '%s.headless=FAIL\n' "$id"
      ;;
    codex)
      [[ "$help" == *'--json'* ]] && printf '%s.headless=PASS\n' "$id" || printf '%s.headless=FAIL\n' "$id"
      if runtime "$binary" login status >/dev/null 2>&1; then printf '%s.auth=PASS\n' "$id"; else printf '%s.auth=NEEDS_LOGIN\n' "$id"; fi
      ;;
    kiro)
      [[ "$help" == *'--no-interactive'* && "$help" == *'--output-format'* ]] && printf '%s.headless=PASS\n' "$id" || printf '%s.headless=FAIL\n' "$id"
      if runtime "$binary" whoami >/dev/null 2>&1; then printf '%s.auth=PASS\n' "$id"; else printf '%s.auth=NEEDS_LOGIN\n' "$id"; fi
      ;;
  esac
}

printf 'PDS_M7_CLI_AUDIT_BEGIN\nruntimeUser=%s\nruntimeHome=%s\n' "$RUNTIME_USER" "$RUNTIME_HOME"
probe opencode opencode --version opencode
probe qwen qwen --version qwen
probe codex codex --version codex
probe kiro kiro-cli --version kiro
printf 'candidateService=active\nv003Service=%s\n' "$(systemctl is-active pds-bridge-v003-mcp.service || true)"
printf 'PDS_M7_CLI_AUDIT_END\n'
