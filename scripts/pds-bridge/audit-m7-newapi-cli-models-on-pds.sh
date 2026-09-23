#!/usr/bin/env bash
# PDS-Bridge v0.1 / M7: read-only New API + CLI model configuration preflight.
# Public-safe script: no keys in source or output; prompts for a temporary token
# only to query GET /v1/models. Does not save token or change system state.
set -euo pipefail
set +x
umask 077

UNIT=pds-bridge-v01-m5-stage.service
LEGACY=pds-bridge-v003-mcp.service
fail() { printf 'M7_MODEL_PREFLIGHT_FAILED: %s\n' "$1" >&2; exit 1; }
section() { printf '\n===== %s =====\n' "$1"; }

[[ "$(id -u)" -eq 0 ]] || fail "run with sudo"
for c in systemctl runuser python3 getent sed; do
  command -v "$c" >/dev/null 2>&1 || fail "missing $c"
done

section "M7 NEW API / CLI MODEL PREFLIGHT"
printf 'timestamp=%s\n' "$(date -Is)"
for unit in "$UNIT" "$LEGACY"; do
  printf 'service.%s=%s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
done

USER_NAME="$(systemctl show -P User "$UNIT" 2>/dev/null || true)"
[[ -n "$USER_NAME" && "$USER_NAME" != root ]] || fail "candidate runtime account is unknown"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
UNIT_FILE="$(systemctl show -P FragmentPath "$UNIT" 2>/dev/null || true)"
[[ -n "$USER_HOME" && -d "$USER_HOME" && -f "$UNIT_FILE" ]] || fail "candidate runtime home/unit file missing"
RUN_PATH="$(sed -n 's/^Environment=PATH=//p' "$UNIT_FILE" | head -n 1)"
[[ -n "$RUN_PATH" ]] || fail "explicit runtime PATH missing"
printf 'runtime.user=%s\nruntime.home=%s\n' "$USER_NAME" "$USER_HOME"

runtime() {
  runuser -u "$USER_NAME" -- env -i \
    HOME="$USER_HOME" USER="$USER_NAME" LOGNAME="$USER_NAME" \
    XDG_CONFIG_HOME="$USER_HOME/.config" PATH="$RUN_PATH" "$@"
}

section "NEW API RUNNING CONTAINERS (NO ENV VALUES)"
if command -v docker >/dev/null 2>&1; then
  docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}' 2>/dev/null \
    | grep -Ei 'new.?api|one.?api' || echo "newApi.container=NOT_IDENTIFIED"
else
  echo "docker=NOT_INSTALLED"
fi

section "CLI VERSIONS UNDER BRIDGE RUNTIME ACCOUNT"
for cli in agy opencode qwen claude codex kiro-cli; do
  path="$(runtime bash -c 'command -v "$1" 2>/dev/null || true' _ "$cli")"
  if [[ -n "$path" ]]; then
    ver="$(runtime "$path" --version 2>&1 | head -n 1 | tr -d '\r' || true)"
    printf 'cli.%s=%s | %s\n' "$cli" "$path" "$ver"
  else
    printf 'cli.%s=MISSING\n' "$cli"
  fi
done

section "CLI CONFIG FILE INVENTORY (NO FILE CONTENTS)"
for relative in \
  .config/opencode/opencode.json \
  .config/opencode/opencode.jsonc \
  .local/share/opencode/auth.json \
  .qwen/settings.json \
  .qwen/.env \
  .claude/settings.json \
  .codex/config.toml \
  .kiro/settings.json; do
  if [[ -f "$USER_HOME/$relative" ]]; then
    printf 'config.%s=PRESENT\n' "$relative"
  else
    printf 'config.%s=ABSENT\n' "$relative"
  fi
done

section "BRIDGE WORKER REGISTRY SUMMARY"
if command -v pds-bridge >/dev/null 2>&1; then
  if ! pds-bridge worker list 2>/dev/null | python3 -c '
import json,sys
try:
 data=json.load(sys.stdin)
 if not isinstance(data,list): raise ValueError("list expected")
 for row in data:
  print("worker=%s enabled=%s health=%s availability=%s" % (
   row.get("worker_id","?"),row.get("enabled","?"),
   row.get("health","?"),row.get("availability","?")))
except Exception as ex:
 print("workerList=UNPARSEABLE_%s" % type(ex).__name__)
 sys.exit(1)
'; then
    echo "workerList=REVIEW_REQUIRED"
  fi
else
  echo "workerList=CLI_NOT_FOUND"
fi

section "NEW API ALIAS LIST (OPTIONAL, KEY NEVER SAVED)"
echo "Use a New API virtual key with permission to list models." >/dev/tty
echo "Endpoint should be your already-deployed New API OpenAI-compatible base URL." >/dev/tty
read -r -p 'New API base URL [http://127.0.0.1:4001/v1]: ' BASE_URL </dev/tty || fail "base URL input cancelled"
BASE_URL="$(printf '%s' "$BASE_URL" | tr -d '\r')"
[[ -n "$BASE_URL" ]] || BASE_URL='http://127.0.0.1:4001/v1'
case "$BASE_URL" in
  http://127.0.0.1:*|http://localhost:*|http://10.*|https://*) ;;
  *) fail "unexpected endpoint format; only loopback, private ZeroTier or HTTPS accepted" ;;
esac
BASE_URL="$(printf '%s' "$BASE_URL" | sed 's:/*$::')"
case "$BASE_URL" in
  */v1) ;;
  *) BASE_URL="$BASE_URL/v1" ;;
esac
printf 'newApi.baseUrl=%s\n' "$BASE_URL"
read -r -s -p 'New API virtual key (Enter to skip alias query): ' API_KEY </dev/tty || fail "key input cancelled"
printf '\n' >/dev/tty
if [[ -n "$API_KEY" ]]; then
  # FD 3 avoids putting the key in argv, child environment or any file.
  python3 - "$BASE_URL" 3<<<"$API_KEY" <<'PY'
import json, os, sys, urllib.error, urllib.request
base=sys.argv[1]
key=os.fdopen(3).read().strip()
if not key:
 print("newApi.aliasQuery=SKIPPED")
 sys.exit()
req=urllib.request.Request(
 base+"/models",
 headers={"Authorization":"Bearer "+key,"Accept":"application/json"},
 method="GET",
)
try:
 with urllib.request.urlopen(req,timeout=12) as res:
  data=json.load(res)
except urllib.error.HTTPError as exc:
 print("newApi.aliasQuery=HTTP_%s" % exc.code)
 sys.exit()
except (urllib.error.URLError,TimeoutError,OSError,ValueError) as exc:
 print("newApi.aliasQuery=ERROR_%s" % type(exc).__name__)
 sys.exit()
models=sorted({row["id"] for row in data.get("data",[])
               if isinstance(row,dict) and isinstance(row.get("id"),str)})
print("newApi.aliasQuery=PASS")
print("newApi.modelCount=%s" % len(models))
for model in models:
 print("newApi.alias=%s" % model)
PY
else
  echo "newApi.aliasQuery=SKIPPED"
fi
unset API_KEY

section "M7 PREFLIGHT END"
echo "readOnly=YES"
echo "secretsSaved=NO"
echo "cliConfigChanged=NO"
echo "bridgeConfigChanged=NO"
echo "servicesRestarted=NO"
