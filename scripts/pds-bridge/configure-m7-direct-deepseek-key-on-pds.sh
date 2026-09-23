#!/usr/bin/env bash
# PDS-Bridge v0.1 / M7: Direct DeepSeek official API credential preflight.
# Interactively captures one official API key, validates /models, and stores it
# in a restricted NON-GIT file readable by the existing pdsbridge runtime.
# DOES NOT change Bridge/CLI configuration, restart services, or invoke a model.
set -euo pipefail
set +x
umask 077

UNIT=pds-bridge-v01-m5-stage.service
LEGACY=pds-bridge-v003-mcp.service
RUNTIME=pdsbridge
SECRETS_DIR=/etc/pds-bridge/secrets
KEY_FILE="$SECRETS_DIR/deepseek-official.env"
TMP_KEY=""

fail() { printf 'PDS_M7_DEEPSEEK_FAILED: %s\n' "$1" >&2; exit 1; }
cleanup() { [[ -z "$TMP_KEY" ]] || rm -f -- "$TMP_KEY"; }
trap cleanup EXIT

[[ $(id -u) -eq 0 ]] || fail "run with sudo"
for cmd in systemctl getent stat python3 install mktemp runuser; do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing $cmd"
done
[[ "$(systemctl show -P User "$UNIT" 2>/dev/null)" == "$RUNTIME" ]] \
  || fail "candidate service runtime user differs from pdsbridge"
systemctl is-active --quiet "$UNIT" || fail "v0.1 candidate service not active"
systemctl is-active --quiet "$LEGACY" || fail "v0.03 service not active"
[[ -d /etc/pds-bridge ]] || fail "existing Bridge configuration directory missing"

printf 'PDS_M7_DIRECT_DEEPSEEK_BEGIN\n'
printf 'candidateService=active\nv003Service=active\n'
printf 'runtimeUser=%s\n' "$RUNTIME"
printf 'apiEndpoint=https://api.deepseek.com\n'
printf 'keyValuesPrinted=NO\n'

if [[ -e "$SECRETS_DIR" ]]; then
  [[ -d "$SECRETS_DIR" && "$(stat -c '%U:%G' "$SECRETS_DIR")" == "root:$RUNTIME" ]] \
    || fail "existing secrets directory owner/group differs from expected root:pdsbridge"
  mode="$(stat -c '%a' "$SECRETS_DIR")"
  [[ $((8#$mode & 0007)) -eq 0 ]] \
    || fail "existing secrets directory is accessible to other users; inspect manually"
else
  install -d -o root -g "$RUNTIME" -m 0750 "$SECRETS_DIR" \
    || fail "could not create restricted secrets directory"
fi

if [[ -e "$KEY_FILE" ]]; then
  [[ -f "$KEY_FILE" && ! -L "$KEY_FILE" ]] \
    || fail "existing key path is not a normal file; inspect manually"
  [[ "$(stat -c '%U:%G' "$KEY_FILE")" == "root:$RUNTIME" ]] \
    || fail "existing key file owner/group is unexpected; inspect manually"
  filemode="$(stat -c '%a' "$KEY_FILE")"
  [[ $((8#$filemode & 0007)) -eq 0 ]] \
    || fail "existing key file is accessible to other users; inspect manually"
  printf 'credential=EXISTING_REUSE_NO_OVERWRITE\n'
  TEST_FILE="$KEY_FILE"
else
  [[ -r /dev/tty ]] || fail "interactive terminal required for hidden API-key input"
  printf '\nPaste the official DeepSeek API key below. Input will be hidden.\n' >/dev/tty
  IFS= read -r -s -p 'DeepSeek API key: ' DS_KEY </dev/tty || fail "key input cancelled"
  printf '\n' >/dev/tty
  [[ "$DS_KEY" =~ ^[A-Za-z0-9._=-]{12,}$ ]] \
    || { unset DS_KEY; fail "unexpected key format; no key has been saved"; }
  TMP_KEY="$(mktemp "$SECRETS_DIR/.deepseek-official.XXXXXXXX")"
  printf 'DEEPSEEK_API_KEY=%s\n' "$DS_KEY" > "$TMP_KEY"
  unset DS_KEY
  chown root:"$RUNTIME" "$TMP_KEY"
  chmod 0640 "$TMP_KEY"
  TEST_FILE="$TMP_KEY"
  printf 'credential=NEW_PENDING_VALIDATION\n'
fi

# No credential in command arguments, child environment, URL, or printed output.
# The Python process reads the key directly from a protected file.
if ! python3 - "$TEST_FILE" <<'PY'
import json, pathlib, re, sys, urllib.error, urllib.request

path = pathlib.Path(sys.argv[1])
try:
    lines = path.read_text(encoding="utf-8").splitlines()
    pairs = [line.partition("=") for line in lines if line.startswith("DEEPSEEK_API_KEY=")]
    assert len(pairs) == 1, "expected exactly one DEEPSEEK_API_KEY"
    key = pairs[0][2].strip()
    assert re.fullmatch(r"[A-Za-z0-9._=-]{12,}", key), "unexpected API key format"
except (OSError, UnicodeError, AssertionError) as exc:
    print(f"credentialParse=FAIL ({type(exc).__name__})")
    sys.exit(1)

req = urllib.request.Request(
    "https://api.deepseek.com/models",
    headers={
        "Authorization": "Bearer " + key,
        "Accept": "application/json",
        "User-Agent": "PDS-Bridge-v01-M7-credential-check"
    },
    method="GET",
)
try:
    with urllib.request.urlopen(req, timeout=25) as res:
        payload = json.load(res)
except urllib.error.HTTPError as exc:
    print(f"officialApi.auth=HTTP_{exc.code}")
    sys.exit(1)
except (urllib.error.URLError, TimeoutError, ValueError, OSError) as exc:
    print(f"officialApi.auth=ERROR_{type(exc).__name__}")
    sys.exit(1)

models = sorted(str(x.get("id")) for x in payload.get("data", [])
                if isinstance(x, dict) and isinstance(x.get("id"), str))
print("officialApi.auth=PASS")
print("officialApi.modelIds=" + (",".join(models) if models else "NONE"))
print("officialApi.deepseekFlash=" + ("AVAILABLE" if "deepseek-flash" in models else "NOT_LISTED"))
if "deepseek-flash" not in models:
    sys.exit(2)
PY
then
  fail "official API validation failed; new key was NOT installed"
fi

if [[ -n "$TMP_KEY" ]]; then
  [[ ! -e "$KEY_FILE" ]] || fail "key appeared concurrently; refusing overwrite"
  mv -- "$TMP_KEY" "$KEY_FILE"
  TMP_KEY=""
  printf 'credential=INSTALLED_AFTER_VALIDATION\n'
fi

printf 'credential.path=%s\n' "$KEY_FILE"
printf 'credential.permissions=%s\n' "$(stat -c '%U:%G %a' "$KEY_FILE")"
# This only reports whether pdsbridge can read the key file, not the key.
if runuser -u "$RUNTIME" -- test -r "$KEY_FILE"; then
  echo "credential.runtimeReadable=YES"
else
  echo "credential.runtimeReadable=NO"
fi

printf '\n===== CURRENT CLI CONFIG FILE INVENTORY (NO CONTENTS) =====\n'
HOME_DIR="$(getent passwd "$RUNTIME" | cut -d: -f6)"
for relative in .config/opencode/opencode.json .config/opencode/opencode.jsonc .local/share/opencode/auth.json .qwen/settings.json .qwen/.env .claude/settings.json; do
  candidate="$HOME_DIR/$relative"
  if [[ -f "$candidate" ]]; then
    printf '%s=PRESENT\n' "$relative"
  else
    printf '%s=ABSENT\n' "$relative"
  fi
done

printf '\n===== ACTIVE LADDER SUMMARY (NO SECRETS) =====\n'
LADDER=/etc/pds-bridge/m5-stage/m5-stage-worker-ladder.json
if [[ -f "$LADDER" ]]; then
  python3 - "$LADDER" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
print("ladder.revision=" + str(data.get("configRevisionId", "UNKNOWN")))
for worker in data.get("workers", []):
    print("worker=" + str(worker.get("workerId")) + " level=" +
          str(worker.get("level")) + " enabled=" + str(worker.get("enabled")))
PY
else
  echo "ladder=NOT_FOUND"
fi
printf 'bridgeConfigChanged=NO\ncliConfigChanged=NO\nserviceRestarted=NO\n'
printf 'PDS_M7_DIRECT_DEEPSEEK_END\n'
