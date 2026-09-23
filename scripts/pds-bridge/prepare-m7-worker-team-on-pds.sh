#!/usr/bin/env bash
# PDS-Bridge v0.1 M7: install MISSING Agy / Claude Code under the existing
# pdsbridge service identity, and inventory all six CLI binaries.
# Does NOT edit Bridge config, add keys, log in, restart services, or call models.
set -euo pipefail
umask 077

UNIT=pds-bridge-v01-m5-stage.service
LEGACY=pds-bridge-v003-mcp.service
UNIT_FILE=/etc/systemd/system/$UNIT
RUN_USER=""
RUN_HOME=""
RUN_PATH=""
TMP_AGY=""
TMP_CLAUDE=""
cleanup() { [[ -z "$TMP_AGY" ]] || rm -f -- "$TMP_AGY"; [[ -z "$TMP_CLAUDE" ]] || rm -f -- "$TMP_CLAUDE"; }
trap cleanup EXIT
fail() { printf 'PDS_M7_WORKER_PREPARE_FAILED: %s\n' "$1" >&2; exit 1; }
section() { printf '\n===== %s =====\n' "$1"; }

[[ "$(id -u)" -eq 0 ]] || fail "run with sudo"
for c in systemctl runuser getent sed bash curl sha256sum mktemp; do
  command -v "$c" >/dev/null 2>&1 || fail "missing required command: $c"
done
[[ -f "$UNIT_FILE" ]] || fail "candidate unit file missing"
systemctl is-active --quiet "$UNIT" || fail "v0.1 candidate is not active"
systemctl is-active --quiet "$LEGACY" || fail "v0.03 service is not active"
RUN_USER="$(systemctl show -P User "$UNIT")"
[[ -n "$RUN_USER" && "$RUN_USER" != root ]] || fail "unexpected candidate runtime account"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
RUN_PATH="$(sed -n 's/^Environment=PATH=//p' "$UNIT_FILE" | head -n 1)"
[[ -n "$RUN_HOME" && -d "$RUN_HOME" && -n "$RUN_PATH" ]] || fail "runtime home or PATH not found"
[[ -w "$RUN_HOME" ]] || [[ "$(stat -c '%U' "$RUN_HOME")" == "$RUN_USER" ]] || fail "runtime home is not writable by its owner"

# Match the service's identity and explicit PATH, with no root credentials inherited.
runtime() {
  runuser -u "$RUN_USER" -- env -i \
    HOME="$RUN_HOME" USER="$RUN_USER" LOGNAME="$RUN_USER" \
    XDG_CONFIG_HOME="$RUN_HOME/.config" PATH="$RUN_PATH" "$@"
}
runtime_command() { runtime bash -c 'command -v "$1" 2>/dev/null || true' bash "$1"; }
one_line() { tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-200; }

section "PDS M7 WORKER CLI PREPARATION"
printf 'runtimeUser=%s\nruntimeHome=%s\n' "$RUN_USER" "$RUN_HOME"
printf 'candidateService=active\nv003Service=active\n'
section "PRE-INSTALL INVENTORY"
for name in agy claude opencode qwen codex kiro-cli; do
  path="$(runtime_command "$name")"
  if [[ -n "$path" ]]; then
    printf '%s.path=%s\n' "$name" "$path"
  else
    printf '%s.path=MISSING\n' "$name"
  fi
done

# The two official vendor installers are downloaded from their HTTPS origins.
# Execute only as the unprivileged PDS runtime user; do not pipe downloads to root bash.
# Existing installations are left completely untouched.
if [[ -z "$(runtime_command agy)" ]]; then
  section "INSTALL MISSING AGY"
  if [[ -e "$RUN_HOME/.local/bin/agy" ]]; then
    fail "agy exists in runtime home but is absent from service PATH; manual PATH review needed"
  fi
  TMP_AGY="$(mktemp /tmp/pds-m7-agy-installer-XXXXXXXX.sh)"
  curl --fail --silent --show-error --location --max-time 120 \
    https://antigravity.google/cli/install.sh -o "$TMP_AGY" \
    || fail "could not download official Agy installer"
  printf 'agy.installer.sha256=%s\n' "$(sha256sum "$TMP_AGY" | cut -d' ' -f1)"
  runtime bash -s -- --skip-path --skip-aliases < "$TMP_AGY" \
    || fail "Agy official installer failed; no Bridge services changed"
  [[ -n "$(runtime_command agy)" ]] \
    || fail "Agy installed but not visible in service PATH; inspect before changing the unit"
  echo "agy.install=INSTALLED"
else
  echo "agy.install=ALREADY_PRESENT"
fi

if [[ -z "$(runtime_command claude)" ]]; then
  section "INSTALL MISSING CLAUDE CODE"
  if [[ -e "$RUN_HOME/.local/bin/claude" ]]; then
    fail "claude exists in runtime home but is absent from service PATH; manual PATH review needed"
  fi
  TMP_CLAUDE="$(mktemp /tmp/pds-m7-claude-installer-XXXXXXXX.sh)"
  if curl --fail --silent --show-error --location --max-time 120 \
    https://claude.ai/install.sh -o "$TMP_CLAUDE"; then
    printf 'claude.installer.sha256=%s\n' "$(sha256sum "$TMP_CLAUDE" | cut -d' ' -f1)"
    runtime bash -s < "$TMP_CLAUDE" \
      || fail "Claude Code official installer failed; inspect before retrying; services unchanged"
    echo "claude.installMethod=native"
  else
    echo "claude.nativeInstaller=UNAVAILABLE"
    echo "claude.fallback=official-npm-package (npm installation is deprecated upstream)"
    command -v npm >/dev/null 2>&1 || fail "npm missing; cannot use official package fallback"
    runtime npm --version >/dev/null 2>&1 || fail "npm unavailable to runtime account"
    NPM_PREFIX="$RUN_HOME/.local"
    if [[ -e "$NPM_PREFIX" ]]; then
      [[ -d "$NPM_PREFIX" && "$(stat -c %U "$NPM_PREFIX")" == "$RUN_USER" ]] \
        || fail "runtime npm prefix exists but is not owned by runtime user"
    else
      runtime mkdir -p "$NPM_PREFIX" || fail "runtime account cannot create npm prefix"
    fi
    NPM_REGISTRY=https://registry.npmjs.org
    CLAUDE_PACKAGE=@anthropic-ai/claude-code
    CLAUDE_VERSION="$(runtime npm view --registry="$NPM_REGISTRY" "$CLAUDE_PACKAGE" version 2>/dev/null | tail -n 1 || true)"
    [[ "$CLAUDE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] \
      || fail "cannot determine a valid version from official npm registry; stop here"
    printf 'claude.resolvedPackage=%s@%s\n' "$CLAUDE_PACKAGE" "$CLAUDE_VERSION"
    NPM_LOG="$(mktemp /tmp/pds-m7-claude-npm-XXXXXXXX.log)"
    if ! runtime npm install --global --prefix "$NPM_PREFIX" \
      --registry="$NPM_REGISTRY" --no-audit --no-fund \
      "$CLAUDE_PACKAGE@$CLAUDE_VERSION" > "$NPM_LOG" 2>&1; then
      printf 'claude.npmLog=%s (root-only; do not paste raw log without redaction)\n' "$NPM_LOG" >&2
      fail "npm fallback failed; services unchanged"
    fi
    printf 'claude.npmLog=%s (root-only)\n' "$NPM_LOG"
    echo "claude.installMethod=npm-fallback"
  fi
  CLAUDE_PATH="$(runtime_command claude)"
  [[ -n "$CLAUDE_PATH" && -x "$CLAUDE_PATH" ]] \
    || fail "Claude Code installed but not executable via service PATH; inspect before changing the unit"
  echo "claude.install=INSTALLED"
else
  echo "claude.install=ALREADY_PRESENT"
fi

section "POST-INSTALL INVENTORY"
for name in agy opencode qwen claude codex kiro-cli; do
  path="$(runtime_command "$name")"
  if [[ -z "$path" ]]; then
    printf '%s.status=MISSING\n' "$name"
    continue
  fi
  printf '%s.status=INSTALLED\n%s.path=%s\n' "$name" "$name" "$path"
  version="$(runtime "$path" --version 2>&1 | head -n 2 | one_line || true)"
  printf '%s.version=%s\n' "$name" "$version"
done

section "EXISTING NATIVE AUTH (NON-INTERACTIVE, OUTPUT SUPPRESSED)"
codex="$(runtime_command codex)"
kiro="$(runtime_command kiro-cli)"
if [[ -n "$codex" ]]; then
  if runtime "$codex" login status >/dev/null 2>&1; then
    echo "codex.auth=PASS"
  else
    echo "codex.auth=NEEDS_REVIEW"
  fi
fi
if [[ -n "$kiro" ]]; then
  if runtime "$kiro" whoami >/dev/null 2>&1; then
    echo "kiro.auth=PASS"
  else
    echo "kiro.auth=NEEDS_REVIEW"
  fi
fi
echo "agy.auth=NOT_TESTED"
echo "claude.auth=NOT_TESTED"
echo "opencode.auth=NOT_TESTED"
echo "qwen.auth=NOT_TESTED"

section "ACTIVE WORKER REGISTRY (NO SECRET VALUES)"
LADDER=/etc/pds-bridge/m5-stage/m5-stage-worker-ladder.json
if [[ -f "$LADDER" ]]; then
  python3 - "$LADDER" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    doc=json.load(handle)
print("ladder.revision=" + str(doc.get("configRevisionId", "UNKNOWN")))
models={x.get("profileId"): x for x in doc.get("modelProfiles", [])}
for x in doc.get("workers", []):
    profile=models.get(x.get("defaultModelProfileId"), {})
    print("worker=" + " | ".join([
        str(x.get("workerId", "?")), "level=" + str(x.get("level", "?")),
        "enabled=" + str(x.get("enabled", "?")),
        "adapter=" + str(x.get("adapter", "?")),
        "profile=" + str(x.get("defaultModelProfileId", "?")),
        "provider=" + str(profile.get("provider", "?")),
        "model=" + str(profile.get("model", "?")),
        "git_write=" + str(x.get("permissions", {}).get("git_write", False)),
        "github_write=" + str(x.get("permissions", {}).get("github_write", False))
    ]))
PY
else
  echo "workerLadder=MISSING_OR_MOVED"
fi
if command -v pds-bridge >/dev/null 2>&1; then
  echo "--- pds-bridge worker list ---"
  pds-bridge worker list 2>&1 || echo "workerList=NEEDS_REVIEW"
fi

section "M6 SERVICE AND EVIDENCE"
systemctl is-active --quiet "$UNIT" && echo "candidateService=active" || echo "candidateService=NOT_ACTIVE"
systemctl is-active --quiet "$LEGACY" && echo "v003Service=active" || echo "v003Service=NOT_ACTIVE"
M6=/var/backups/pds-bridge/m6-operations-OjyrR0xU
[[ -d "$M6" ]] && echo "m6.evidence=PRESENT" || echo "m6.evidence=NOT_FOUND"

section "PDS M7 WORKER PREPARATION DONE"
echo "No Bridge config or service changed; no API keys requested, displayed or saved."
echo "NEXT: native Agy sign-in and provider-specific key setup require separate verification."
