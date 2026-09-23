#!/usr/bin/env bash
# Install one pinned Qwen Code release for the PDS runtime user.
# Does not restart services, configure providers, authenticate, or touch agy.
set -euo pipefail
umask 077

QWEN_VERSION=0.24.4
QWEN_PACKAGE=@qwen-code/qwen-code
NPM_REGISTRY=https://registry.npmjs.org
CANDIDATE_UNIT=pds-bridge-v01-m5-stage.service
LEGACY_UNIT=pds-bridge-v003-mcp.service
UNIT_FILE=/etc/systemd/system/$CANDIDATE_UNIT
INSTALLED_BY_SCRIPT=0

fail() { printf 'PDS_M7_QWEN_INSTALL_FAILED: %s\n' "$1" >&2; exit 1; }

on_exit() {
  local result=$?
  if (( result != 0 && INSTALLED_BY_SCRIPT )); then
    runuser -u "$RUNTIME_USER" -- env HOME="$RUNTIME_HOME" PATH="$RUNTIME_PATH" \
      npm uninstall --global --prefix "$LOCAL_PREFIX" "$QWEN_PACKAGE" >/dev/null 2>&1 || true
    printf 'PDS_M7_QWEN_ROLLBACK: removed incomplete Qwen installation\n' >&2
  fi
  if (( result != 0 )); then
    printf 'PDS_M7_QWEN_INSTALL_FAILED: exit=%s; services were not modified\n' "$result" >&2
  fi
}
trap on_exit EXIT

[[ $(id -u) -eq 0 ]] || fail 'run with sudo'
for command_name in systemctl runuser getent npm node bash sed stat; do
  command -v "$command_name" >/dev/null || fail "missing $command_name"
done
[[ -f "$UNIT_FILE" ]] || fail 'M6 candidate service is not installed'
systemctl is-active --quiet "$CANDIDATE_UNIT" || fail 'M6 candidate service is not active'
systemctl is-active --quiet "$LEGACY_UNIT" || fail 'v0.03 service is not active'

RUNTIME_USER="$(systemctl show -P User "$CANDIDATE_UNIT")"
RUNTIME_HOME="$(getent passwd "$RUNTIME_USER" | cut -d: -f6)"
RUNTIME_PATH="$(sed -n 's/^Environment=PATH=//p' "$UNIT_FILE")"
[[ -n "$RUNTIME_USER" && "$RUNTIME_USER" != root && -d "$RUNTIME_HOME" && -n "$RUNTIME_PATH" ]] || \
  fail 'runtime identity, home or PATH is invalid'

LOCAL_PREFIX="$RUNTIME_HOME/.local"
if [[ ! -d "$LOCAL_PREFIX" ]]; then
  install -d -o "$RUNTIME_USER" -g "$(id -gn "$RUNTIME_USER")" -m 0750 "$LOCAL_PREFIX"
fi
[[ $(stat -c %U "$LOCAL_PREFIX") == "$RUNTIME_USER" ]] || fail 'runtime .local is not owned by runtime user'

runtime() {
  runuser -u "$RUNTIME_USER" -- env HOME="$RUNTIME_HOME" PATH="$RUNTIME_PATH" \
    XDG_CONFIG_HOME="$RUNTIME_HOME/.config" "$@"
}

QWEN_PATH="$(runtime bash -c 'command -v qwen 2>/dev/null || true')"
if [[ -n "$QWEN_PATH" ]]; then
  EXISTING_VERSION="$(runtime "$QWEN_PATH" --version 2>/dev/null | head -n 1 | tr -d '\r')"
  [[ "$EXISTING_VERSION" == "$QWEN_VERSION" ]] || \
    fail "qwen already exists at $QWEN_PATH with version $EXISTING_VERSION; refusing to replace it"
else
  PUBLISHED_VERSION="$(runtime npm view --registry="$NPM_REGISTRY" "$QWEN_PACKAGE@$QWEN_VERSION" version 2>/dev/null || true)"
  [[ "$PUBLISHED_VERSION" == "$QWEN_VERSION" ]] || fail 'pinned Qwen release is unavailable from the official npm registry'
  runtime npm install --global --prefix "$LOCAL_PREFIX" --registry="$NPM_REGISTRY" \
    --no-audit --no-fund "$QWEN_PACKAGE@$QWEN_VERSION" >/tmp/pds-m7-qwen-npm.log 2>&1 || \
    fail 'npm install failed; inspect /tmp/pds-m7-qwen-npm.log'
  INSTALLED_BY_SCRIPT=1
  QWEN_PATH="$(runtime bash -c 'command -v qwen 2>/dev/null || true')"
fi

EXPECTED_PATH="$LOCAL_PREFIX/bin/qwen"
[[ -n "$QWEN_PATH" && "$QWEN_PATH" == "$EXPECTED_PATH" && -x "$QWEN_PATH" ]] || \
  fail "qwen is not available at the isolated runtime path $EXPECTED_PATH"
INSTALLED_VERSION="$(runtime "$QWEN_PATH" --version 2>/dev/null | head -n 1 | tr -d '\r')"
[[ "$INSTALLED_VERSION" == "$QWEN_VERSION" ]] || fail "installed version mismatch: $INSTALLED_VERSION"
QWEN_HELP="$(runtime "$QWEN_PATH" --help 2>&1 || true)"
[[ "$QWEN_HELP" == *'--output-format'* && "$QWEN_HELP" == *'stream-json'* ]] || \
  fail 'installed qwen lacks the required headless stream-json interface'

systemctl is-active --quiet "$CANDIDATE_UNIT" || fail 'M6 candidate service stopped unexpectedly'
systemctl is-active --quiet "$LEGACY_UNIT" || fail 'v0.03 service stopped unexpectedly'
INSTALLED_BY_SCRIPT=0

printf 'PDS_M7_QWEN_INSTALL_BEGIN\n'
printf 'runtimeUser=%s\nversion=%s\npath=%s\nheadless=PASS\nauth=PENDING_PROVIDER_CONFIGURATION\n' \
  "$RUNTIME_USER" "$INSTALLED_VERSION" "$QWEN_PATH"
printf 'candidateService=active\nv003Service=active\nagy=UNTOUCHED\n'
printf 'PDS_M7_QWEN_INSTALL_END\n'
