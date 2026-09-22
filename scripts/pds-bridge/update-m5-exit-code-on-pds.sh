#!/usr/bin/env bash
# Install the tested M5 failure-classification fix without changing v0.03 or LibreChat.
set -euo pipefail
umask 077

OLD_COMMIT=ca75bba895f259417244f829e3ff1a65dc5409e8
FIX_COMMIT=e55166fcdd62513b7ddbf424a28c4885393f90b3
OLD_DIR=/opt/pds-bridge/candidates/v0.1-m5-stage
FIX_DIR=/opt/pds-bridge/candidates/v0.1-m5-exit-code-fix
LIVE_DIR=/opt/pds-bridge/candidates/v0.03
DB=/var/lib/pds-bridge/runtime-v01-stage.db
UNIT=pds-bridge-v01-m5-stage.service
LEGACY_UNIT=pds-bridge-v003-mcp.service
UNIT_FILE=/etc/systemd/system/$UNIT
BACKUP=""
ROLLBACK=0

fail() { printf 'M5_FIX_FAILED: %s\n' "$1" >&2; exit 1; }
as_source() { if [[ "$SOURCE_OWNER" == root ]]; then "$@"; else runuser -u "$SOURCE_OWNER" -- env HOME="$SOURCE_HOME" "$@"; fi; }
on_exit() {
  local result=$?
  if (( ROLLBACK )); then
    printf 'M5_FIX_ROLLBACK: restoring old M5 service unit; backup=%s\n' "$BACKUP" >&2
    cp -a "$BACKUP/$UNIT" "$UNIT_FILE" || true
    systemctl daemon-reload || true
    systemctl start "$UNIT" || true
    systemctl is-active --quiet "$UNIT" || printf 'M5_FIX_ROLLBACK_FAILED: inspect %s\n' "$UNIT" >&2
  fi
  if (( result != 0 )); then printf 'M5_FIX_FAILED: exit=%s; v0.03 not modified\n' "$result" >&2; fi
}
trap on_exit EXIT

[[ $(id -u) -eq 0 ]] || fail 'run with sudo'
for cmd in git npm python3 runuser systemctl curl; do command -v "$cmd" >/dev/null || fail "missing $cmd"; done
[[ -f "$UNIT_FILE" && -f "$DB" && -d "$OLD_DIR/.git" && -d "$LIVE_DIR/.git" ]] || fail 'expected M5 and v0.03 installation missing'
systemctl is-active --quiet "$LEGACY_UNIT" || fail 'v0.03 is not active'
systemctl is-active --quiet "$UNIT" || fail 'M5 is not active'
RUNTIME_USER="$(systemctl show -P User "$UNIT")"
[[ -n "$RUNTIME_USER" && "$RUNTIME_USER" != root ]] || fail 'M5 runtime user missing'
RUNTIME_GROUP="$(id -gn "$RUNTIME_USER")"
SOURCE_OWNER="$(stat -c %U "$LIVE_DIR")"
SOURCE_HOME="$(getent passwd "$SOURCE_OWNER" | cut -d: -f6)"
[[ -d "$SOURCE_HOME" ]] || fail 'Git source account home missing'
[[ $(git -c "safe.directory=$OLD_DIR" -C "$OLD_DIR" rev-parse HEAD) == "$OLD_COMMIT" ]] || fail 'old M5 source is not the expected pinned commit'
[[ -z $(git --no-optional-locks -c "safe.directory=$OLD_DIR" -C "$OLD_DIR" status --porcelain) ]] || fail 'old M5 source has local changes'
grep -Fqx "WorkingDirectory=$OLD_DIR" "$UNIT_FILE" || fail 'M5 unit working directory changed'
grep -Fqx "User=$RUNTIME_USER" "$UNIT_FILE" || fail 'M5 unit user changed'
grep -Fqx 'Environment=PDS_BRIDGE_M5_CONFIG=/etc/pds-bridge/m5-stage/m5-stage-runtime.json' "$UNIT_FILE" || fail 'M5 config changed'
[[ $(python3 -c 'import json; print(json.load(open("/etc/pds-bridge/m5-stage/m5-stage-runtime.json"))["databasePath"])') == "$DB" ]] || fail 'M5 database path changed'
[[ ! -e "$FIX_DIR" ]] || fail 'new candidate directory already exists; inspect it before rerunning'

# Source account already fetched v0.1 for the original isolated stage. Build
# in a fresh checkout; never run npm ci against the serving M5 checkout.
git -c "safe.directory=$OLD_DIR" -c "safe.directory=$OLD_DIR/.git" clone -q --no-hardlinks "$OLD_DIR" "$FIX_DIR" || fail 'isolated clone failed'
git -C "$FIX_DIR" remote set-url origin "$(git -c "safe.directory=$OLD_DIR" -C "$OLD_DIR" remote get-url origin)"
chown -R "$SOURCE_OWNER:$(id -gn "$SOURCE_OWNER")" "$FIX_DIR"
as_source git -C "$FIX_DIR" fetch -q origin v0.1 2>/dev/null || fail 'private v0.1 fetch failed for source account'
as_source git -C "$FIX_DIR" merge-base --is-ancestor "$FIX_COMMIT" FETCH_HEAD || fail 'pinned fix commit is not on v0.1'
as_source git -C "$FIX_DIR" checkout -q --detach "$FIX_COMMIT"
[[ $(as_source git -C "$FIX_DIR" rev-parse HEAD) == "$FIX_COMMIT" ]] || fail 'candidate checkout does not match pinned fix commit'
as_source npm --prefix "$FIX_DIR" ci --no-audit --no-fund >/tmp/pds-m5-fix-npm.log 2>&1 || fail 'npm ci failed; see /tmp/pds-m5-fix-npm.log'
as_source npm --prefix "$FIX_DIR" run check >/tmp/pds-m5-fix-check.log 2>&1 || fail 'tests failed; see /tmp/pds-m5-fix-check.log'
[[ -z $(as_source git -C "$FIX_DIR" status --porcelain) ]] || fail 'fixed checkout became dirty'
chown -R "$RUNTIME_USER:$RUNTIME_GROUP" "$FIX_DIR"

# Refuse maintenance during any in-progress or human-waiting Task. Verify
# again after stopping the service, before changing its unit or database.
check_tasks() {
  python3 - "$DB" <<'PY'
import sqlite3, sys
con=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro', uri=True)
active=con.execute("SELECT count(*) FROM tasks WHERE state NOT IN ('BLOCKED','COMPLETED','FAILED','CANCELLED')").fetchone()[0]
blocked=con.execute("SELECT state FROM tasks WHERE task_id='16fc0bf0-9a9e-4bc4-ab24-c090d8e04c6f'").fetchone()
con.close()
if active or blocked != ('BLOCKED',):
    raise SystemExit('M5_FIX_FAILED: Tasks changed or pending; active=%d; initial=%s' % (active, blocked))
PY
}
check_tasks
install -d -m 0700 /var/backups/pds-bridge
BACKUP="$(mktemp -d /var/backups/pds-bridge/m5-exit-code-XXXXXXXX)"
cp -a "$UNIT_FILE" "$BACKUP/$UNIT"
systemctl stop "$UNIT"
ROLLBACK=1
check_tasks
python3 - "$DB" "$BACKUP/m5.sqlite" <<'PY'
import sqlite3, sys
source=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro', uri=True)
backup=sqlite3.connect(sys.argv[2])
source.backup(backup)
assert backup.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
backup.close(); source.close()
PY
python3 - "$UNIT_FILE" "$OLD_DIR" "$FIX_DIR" <<'PY'
import os, pathlib, sys
unit=pathlib.Path(sys.argv[1]); old='WorkingDirectory='+sys.argv[2]; new='WorkingDirectory='+sys.argv[3]
content=unit.read_text()
assert content.splitlines().count(old)==1
temp=unit.with_name(unit.name+'.m5-fix-tmp')
temp.write_text(content.replace(old, new, 1))
os.chmod(temp, 0o644)
os.replace(temp,unit)
PY
systemctl daemon-reload
systemctl start "$UNIT"
HOST="$(sed -n 's/^Environment=PDS_MCP_HOST=//p' "$UNIT_FILE")"
PORT="$(sed -n 's/^Environment=PDS_MCP_PORT=//p' "$UNIT_FILE")"
[[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$PORT" == 8791 ]] || fail 'M5 bind address differs from expected'
READY=0
for _ in {1..50}; do
  if [[ $(curl --noproxy '*' -fsS --max-time 1 "http://$HOST:$PORT/healthz" 2>/dev/null || true) == '{"status":"ready"}' ]]; then READY=1; break; fi
  sleep 0.3
done
[[ "$READY" == 1 ]] || fail 'M5 did not become healthy'
systemctl is-active --quiet "$UNIT" || fail 'M5 stopped after health check'
systemctl is-active --quiet "$LEGACY_UNIT" || fail 'v0.03 stopped unexpectedly'
ROLLBACK=0
printf 'PDS_M5_FIX_REPORT_BEGIN\nfixCommit=%s\nM5=ready\nv003=active\noldTask=BLOCKED_PRESERVED\nbackup=%s\ntests=PASS\nPDS_M5_FIX_REPORT_END\n' "$FIX_COMMIT" "$BACKUP"
