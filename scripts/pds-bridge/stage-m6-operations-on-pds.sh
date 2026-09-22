#!/usr/bin/env bash
# Install and exercise M6 operations on the isolated v0.1 candidate only.
set -euo pipefail
umask 077

# Filled with the reviewed private v0.1 commit before publishing this script.
M6_COMMIT=972fa8156b991a5d464ff286d0183d7be4715547
OLD_COMMIT=515f8c06fc0ef30ba95e877716b1015f4136f7c9
OLD_DIR=/opt/pds-bridge/candidates/v0.1-m5-review-evidence
NEW_DIR=/opt/pds-bridge/candidates/v0.1-m6-operations
LIVE_DIR=/opt/pds-bridge/candidates/v0.03
DB=/var/lib/pds-bridge/runtime-v01-stage.db
CONFIG=/etc/pds-bridge/m5-stage/m5-stage-runtime.json
UNIT=pds-bridge-v01-m5-stage.service
LEGACY_UNIT=pds-bridge-v003-mcp.service
UNIT_FILE=/etc/systemd/system/$UNIT
BACKUP=""
ROLLBACK=0
WRAPPER_CREATED=0

fail() { printf 'PDS_M6_STAGE_FAILED: %s\n' "$1" >&2; exit 1; }
as_source() { if [[ "$SOURCE_OWNER" == root ]]; then "$@"; else runuser -u "$SOURCE_OWNER" -- env HOME="$SOURCE_HOME" "$@"; fi; }
on_exit() {
  local result=$?
  if (( ROLLBACK )); then
    printf 'PDS_M6_ROLLBACK: restoring old M5 candidate; backup=%s\n' "$BACKUP" >&2
    systemctl stop "$UNIT" || true
    cp -a "$BACKUP/$UNIT" "$UNIT_FILE" || true
    systemctl daemon-reload || true
    systemctl start "$UNIT" || true
    systemctl is-active --quiet "$UNIT" || printf 'PDS_M6_ROLLBACK_FAILED: inspect %s\n' "$UNIT" >&2
  fi
  if (( result != 0 && WRAPPER_CREATED )); then rm -f /usr/local/bin/pds-bridge; fi
  if (( result != 0 )); then printf 'PDS_M6_STAGE_FAILED: exit=%s; v0.03 not modified\n' "$result" >&2; fi
}
trap on_exit EXIT

[[ $(id -u) -eq 0 ]] || fail 'run with sudo'
for cmd in git npm python3 runuser systemctl curl sha256sum; do command -v "$cmd" >/dev/null || fail "missing $cmd"; done
[[ -f "$UNIT_FILE" && -f "$DB" && -f "$CONFIG" && -d "$OLD_DIR/.git" && -d "$LIVE_DIR/.git" ]] || fail 'expected M5 and v0.03 installation missing'
[[ ! -e "$NEW_DIR" ]] || fail 'M6 candidate directory already exists; inspect previous attempt'
[[ ! -e /usr/local/bin/pds-bridge ]] || fail 'existing pds-bridge command requires manual inspection'
systemctl is-active --quiet "$LEGACY_UNIT" || fail 'v0.03 is not active'
systemctl is-active --quiet "$UNIT" || fail 'M5 is not active'
RUNTIME_USER="$(systemctl show -P User "$UNIT")"
[[ -n "$RUNTIME_USER" && "$RUNTIME_USER" != root ]] || fail 'M5 runtime user missing'
RUNTIME_GROUP="$(id -gn "$RUNTIME_USER")"
SOURCE_OWNER="$(stat -c %U "$LIVE_DIR")"
SOURCE_HOME="$(getent passwd "$SOURCE_OWNER" | cut -d: -f6)"
[[ -d "$SOURCE_HOME" ]] || fail 'Git source account home missing'
[[ $(git -c "safe.directory=$OLD_DIR" -C "$OLD_DIR" rev-parse HEAD) == "$OLD_COMMIT" ]] || fail 'M5 commit changed'
[[ -z $(git --no-optional-locks -c "safe.directory=$OLD_DIR" -C "$OLD_DIR" status --porcelain) ]] || fail 'M5 source is dirty'
grep -Fqx "WorkingDirectory=$OLD_DIR" "$UNIT_FILE" || fail 'M5 unit working directory changed'
[[ $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["databasePath"])' "$CONFIG") == "$DB" ]] || fail 'database path changed'

git -c "safe.directory=$OLD_DIR" -c "safe.directory=$OLD_DIR/.git" clone -q --no-hardlinks "$OLD_DIR" "$NEW_DIR" || fail 'isolated clone failed'
git -C "$NEW_DIR" remote set-url origin "$(git -c "safe.directory=$OLD_DIR" -C "$OLD_DIR" remote get-url origin)"
chown -R "$SOURCE_OWNER:$(id -gn "$SOURCE_OWNER")" "$NEW_DIR"
as_source git -C "$NEW_DIR" fetch -q origin v0.1 2>/dev/null || fail 'private v0.1 fetch failed for source account'
as_source git -C "$NEW_DIR" merge-base --is-ancestor "$M6_COMMIT" FETCH_HEAD || fail 'pinned commit not on v0.1'
as_source git -C "$NEW_DIR" checkout -q --detach "$M6_COMMIT"
[[ $(as_source git -C "$NEW_DIR" rev-parse HEAD) == "$M6_COMMIT" ]] || fail 'M6 checkout mismatch'
as_source npm --prefix "$NEW_DIR" ci --no-audit --no-fund >/tmp/pds-m6-npm.log 2>&1 || fail 'npm ci failed: /tmp/pds-m6-npm.log'
as_source npm --prefix "$NEW_DIR" run typecheck >/tmp/pds-m6-check.log 2>&1 || fail 'M6 typecheck failed: /tmp/pds-m6-check.log'
(cd "$NEW_DIR" && as_source node --no-warnings --experimental-strip-types --test --test-concurrency=2 tests/*.test.ts) >>/tmp/pds-m6-check.log 2>&1 || fail 'M6 tests failed: /tmp/pds-m6-check.log'
[[ -z $(as_source git -C "$NEW_DIR" status --porcelain) ]] || fail 'new checkout became dirty'
chown -R "$RUNTIME_USER:$RUNTIME_GROUP" "$NEW_DIR"

check_tasks() {
  python3 - "$DB" <<'PY'
import sqlite3, sys
with sqlite3.connect('file:'+sys.argv[1]+'?mode=ro', uri=True) as db:
    count=db.execute("SELECT count(*) FROM tasks WHERE state NOT IN ('BLOCKED','COMPLETED','FAILED','CANCELLED')").fetchone()[0]
if count: raise SystemExit('PDS_M6_STAGE_FAILED: pending or active Tasks='+str(count))
PY
}
check_tasks
install -d -m 0700 /var/backups/pds-bridge
BACKUP="$(mktemp -d /var/backups/pds-bridge/m6-operations-XXXXXXXX)"
cp -a "$UNIT_FILE" "$BACKUP/$UNIT"
python3 "$NEW_DIR/scripts/m6-backup.py" backup "$CONFIG" "$BACKUP/state" >"$BACKUP/backup-result.json"
python3 "$NEW_DIR/scripts/m6-backup.py" verify "$BACKUP/state" "$BACKUP/restored-state" >"$BACKUP/restore-result.json"
cmp "$BACKUP/state/runtime.sqlite" "$BACKUP/restored-state/runtime.sqlite" || fail 'SQLite Restore dry run differs'

# Exercise an actual failed upgrade after switching the unit while offline:
# rollback restores the previous service, then the normal upgrade proceeds.
systemctl stop "$UNIT"
ROLLBACK=1
check_tasks
python3 - "$UNIT_FILE" "$OLD_DIR" "$NEW_DIR" <<'PY'
import os, pathlib, sys
unit=pathlib.Path(sys.argv[1]); old='WorkingDirectory='+sys.argv[2]; new='WorkingDirectory='+sys.argv[3]
content=unit.read_text()
assert content.splitlines().count(old)==1
tmp=unit.with_name(unit.name+'.m6-tmp'); tmp.write_text(content.replace(old,new,1))
os.chmod(tmp,0o644); os.replace(tmp,unit)
PY
systemctl daemon-reload
# Fault injection: restore the prior unit, verify the stable M5 is serving.
cp -a "$BACKUP/$UNIT" "$UNIT_FILE"
systemctl daemon-reload
systemctl start "$UNIT"
ROLLBACK=0
systemctl is-active --quiet "$UNIT" || fail 'fault injection rollback did not restart M5'
grep -Fqx "WorkingDirectory=$OLD_DIR" "$UNIT_FILE" || fail 'fault injection rollback did not restore M5'
BACKUP_OLD_DB="$(sha256sum "$BACKUP/state/runtime.sqlite" | cut -d' ' -f1)"

check_tasks
systemctl stop "$UNIT"
ROLLBACK=1
check_tasks
# Explicit upgrade migration on a disposable clone of the real SQLite snapshot.
# The production database has the latest schema; migrating the clone proves
# the shipped migration path and prevents a live schema change during rehearsal.
cp "$BACKUP/state/runtime.sqlite" "$BACKUP/upgrade.sqlite"
node --no-warnings --experimental-strip-types --input-type=module - "$NEW_DIR" "$BACKUP/upgrade.sqlite" <<'JS'
const { SQLiteRuntimeDatabase } = await import(`file://${process.argv[2]}/src/store/sqlite-runtime-store.ts`);
const db=new SQLiteRuntimeDatabase(process.argv[3]);
if (db.schemaVersion !== 3 || db.db.prepare('PRAGMA integrity_check').get().integrity_check !== 'ok') process.exitCode=1;
db.close();
JS
python3 - "$UNIT_FILE" "$OLD_DIR" "$NEW_DIR" <<'PY'
import os, pathlib, sys
unit=pathlib.Path(sys.argv[1]); old='WorkingDirectory='+sys.argv[2]; new='WorkingDirectory='+sys.argv[3]
content=unit.read_text(); assert content.splitlines().count(old)==1
tmp=unit.with_name(unit.name+'.m6-tmp'); tmp.write_text(content.replace(old,new,1))
os.chmod(tmp,0o644); os.replace(tmp,unit)
PY
systemctl daemon-reload
systemctl start "$UNIT"
HOST="$(sed -n 's/^Environment=PDS_MCP_HOST=//p' "$UNIT_FILE")"
PORT="$(sed -n 's/^Environment=PDS_MCP_PORT=//p' "$UNIT_FILE")"
[[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$PORT" == 8791 ]] || fail 'candidate bind changed'
READY=0
for _ in {1..50}; do
  HEALTH="$(curl --noproxy '*' -fsS --max-time 1 "http://$HOST:$PORT/healthz" 2>/dev/null || true)"
  READINESS="$(curl --noproxy '*' -fsS --max-time 1 "http://$HOST:$PORT/readyz" 2>/dev/null || true)"
  if [[ "$HEALTH" == '{"status":"healthy"}' && "$READINESS" == '{"status":"ready"}' ]]; then READY=1; break; fi
  sleep 0.3
done
[[ "$READY" == 1 ]] || fail 'M6 not healthy and ready'
systemctl is-active --quiet "$UNIT" || fail 'M6 service stopped'
systemctl is-active --quiet "$LEGACY_UNIT" || fail 'v0.03 stopped unexpectedly'
if ! node --no-warnings --experimental-strip-types "$NEW_DIR/src/ops/cli.ts" \
  --config "$CONFIG" --url "http://$HOST:$PORT" doctor --deep >"$BACKUP/doctor-deep.json"; then
  python3 - "$BACKUP/doctor-deep.json" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1]))
    print('PDS_M6_DOCTOR_FAILED_CHECKS='+','.join(c['name'] for c in data['checks'] if c['status']=='FAIL'),file=sys.stderr)
except (OSError,ValueError,KeyError): print('PDS_M6_DOCTOR_FAILED: unreadable report',file=sys.stderr)
PY
  fail 'Doctor Deep failed; prior M5 service will be restored'
fi
[[ "$(python3 - "$DB" <<'PY'
import sqlite3,sys
with sqlite3.connect('file:'+sys.argv[1]+'?mode=ro', uri=True) as db:
    print(db.execute('PRAGMA integrity_check').fetchone()[0])
PY
)" == ok ]] || fail 'candidate DB integrity failed'
[[ -n "$BACKUP_OLD_DB" ]] || fail 'missing snapshot digest'
cat >/usr/local/bin/pds-bridge <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
source_dir="$(systemctl show -P WorkingDirectory pds-bridge-v01-m5-stage.service)"
[[ -n "$source_dir" && -f "$source_dir/src/ops/cli.ts" ]] || { echo 'PDS M6 candidate unavailable' >&2; exit 1; }
exec node --no-warnings --experimental-strip-types "$source_dir/src/ops/cli.ts" \
  --config /etc/pds-bridge/m5-stage/m5-stage-runtime.json "${@}"
WRAPPER
chmod 0755 /usr/local/bin/pds-bridge
WRAPPER_CREATED=1
node --no-warnings --experimental-strip-types "$NEW_DIR/src/ops/cli.ts" --config "$CONFIG" \
  --url "http://$HOST:$PORT" status >"$BACKUP/status.json" || fail 'status command unavailable'
ROLLBACK=0
printf 'PDS_M6_STAGE_REPORT_BEGIN\nsourceCommit=%s\nM6=ready\nv003=active\nhealth=healthy\nreadiness=ready\nbackup=%s\ndoctorDeep=PASS\nrestore=PASS\nupgradeMigration=PASS\ninjectedFailureRollback=PASS\nstatus=PASS\ntests=PASS\nPDS_M6_STAGE_REPORT_END\n' "$M6_COMMIT" "$BACKUP"
