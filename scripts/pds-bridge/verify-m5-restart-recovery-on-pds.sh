#!/usr/bin/env bash
# Exercise active Task recovery on the isolated M5 candidate, leaving v0.03 online.
set -euo pipefail
umask 077
UNIT=pds-bridge-v01-m5-stage.service
LEGACY=pds-bridge-v003-mcp.service
DB=/var/lib/pds-bridge/runtime-v01-stage.db
FIX_DIR=/opt/pds-bridge/candidates/v0.1-m5-review-evidence
FIX_COMMIT=515f8c06fc0ef30ba95e877716b1015f4136f7c9
INSPECT_URL=https://raw.githubusercontent.com/gany-app/PDS-GoldenLab/dfd79b53c6e837ef41925134db281b35c6834d91/scripts/pds-bridge/inspect-m5-task-on-pds.sh
INSPECT_SHA=90129f6f5eaaa4cafc5f300366d0ffad8475e3906917c43c6673b448ff2994a1
INSPECT="$(mktemp /tmp/pds-m5-recovery-inspect-XXXXXXXX.sh)"
STOPPED=0
cleanup() {
  local result=$?
  if (( STOPPED )); then systemctl start "$UNIT" || printf 'M5_RECOVERY_FAILED: M5 restart failed\n' >&2; fi
  rm -f "$INSPECT"
  if (( result )); then printf 'M5_RECOVERY_FAILED: exit=%s; v0.03 was not changed\n' "$result" >&2; fi
}
trap cleanup EXIT
fail() { printf 'M5_RECOVERY_FAILED: %s\n' "$1" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || fail 'run with sudo'
systemctl is-active --quiet "$UNIT" || fail 'M5 service is not active'
systemctl is-active --quiet "$LEGACY" || fail 'v0.03 service is not active'
grep -Fqx "WorkingDirectory=$FIX_DIR" "/etc/systemd/system/$UNIT" || fail 'unexpected M5 service source'
[[ $(git -c "safe.directory=$FIX_DIR" -C "$FIX_DIR" rev-parse HEAD) == "$FIX_COMMIT" ]] || fail 'M5 commit mismatch'
python3 - "$DB" <<'PY'
import sqlite3,sys
con=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
n=con.execute("SELECT count(*) FROM tasks WHERE state NOT IN ('BLOCKED','COMPLETED','FAILED','CANCELLED')").fetchone()[0]
con.close()
if n: raise SystemExit('M5_RECOVERY_FAILED: unrelated active Tasks exist; no restart')
PY
wget -qO "$INSPECT" "$INSPECT_URL" || fail 'inspector download failed'
echo "$INSPECT_SHA  $INSPECT" | sha256sum -c - >/dev/null || fail 'inspector checksum mismatch'

cd /opt/pds-bridge/librechat-v003
SUBMISSION="$(docker compose exec -T -w /app api node - <<'NODE'
const fs=require('fs');
const {Client}=require('@modelcontextprotocol/sdk/client/index.js');
const {StreamableHTTPClientTransport}=require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const {extractEnvVariable}=require('librechat-data-provider');
let client;
(async()=>{
  const config=require('js-yaml').load(fs.readFileSync('/app/librechat.yaml','utf8'));
  const entry=config?.mcpServers?.['pds-bridge-m5'];
  if (!entry?.url || !entry.headers) throw Error('M5 MCP entry unavailable');
  const headers=Object.fromEntries(Object.entries(entry.headers).map(([key,value])=>[key,extractEnvVariable(value)]));
  client=new Client({name:'m5-restart-recovery',version:'0.1'},{capabilities:{}});
  await client.connect(new StreamableHTTPClientTransport(new URL(entry.url),{requestInit:{headers}}),{timeout:15000});
  const reply=await client.callTool({name:'submit_task',arguments:{
    repository:'gany-app/PDS-GoldenLab',baseBranch:'v003',
    clientRequestId:'m5-restart-smoke-20260922-01',
    humanRequest:'从 v003 新增 docs/m5-restart-smoke.md，一级标题固定为「# M5 运行中重启恢复验收」，下一段中文正文为「本文件验证 PDS-Bridge v0.1 M5 在任务进行中重启后能够恢复执行并完成验收。」。只修改此文件，不引入依赖。由 PDS 选择 Worker；Bridge 负责最终提交、推送和创建 PR。'
  }},undefined,{timeout:15000});
  if (reply.isError) throw Error('submit_task rejected');
  const result=JSON.parse(reply.content.find(part=>part.type==='text').text);
  if (!/^[0-9a-f-]{36}$/i.test(result.taskId) || result.deduplicated) throw Error('Task ID invalid or reused');
  console.log('taskId='+result.taskId);
})().catch(error=>{console.error('M5_RECOVERY_FAILED: '+error.message.replace(/Bearer\s+\S+/gi,'Bearer [REDACTED]'));process.exitCode=1})
  .finally(async()=>{try{await client?.close()}catch{}});
NODE
)" || fail 'task submission failed; no restart performed'
TASK_ID="$(printf '%s\n' "$SUBMISSION" | sed -n 's/^taskId=//p')"
[[ "$TASK_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fail 'Task ID missing'
printf 'PDS_M5_RECOVERY_SUBMISSION taskId=%s\n' "$TASK_ID"

# Planning is a long-running CTO stage. Do not interrupt a Worker or finalization.
STATE=""
for _ in {1..80}; do
  STATE="$(python3 - "$DB" "$TASK_ID" <<'PY'
import sqlite3,sys
con=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
row=con.execute('SELECT state FROM tasks WHERE task_id=?',(sys.argv[2],)).fetchone()
print(row[0] if row else 'MISSING')
con.close()
PY
)"
  [[ "$STATE" == PLANNING ]] && break
  [[ "$STATE" == RECEIVED ]] || break
  sleep 0.1
done
if [[ "$STATE" != PLANNING ]]; then
  printf 'M5_RECOVERY_SKIPPED: Task already %s; no service restart. Task remains traceable: %s\n' "$STATE" "$TASK_ID"
  bash "$INSPECT" "$TASK_ID"
  exit 0
fi

STOPPED=1
systemctl stop "$UNIT"
STATE_AT_STOP="$(python3 - "$DB" "$TASK_ID" <<'PY'
import sqlite3,sys
con=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
print(con.execute('SELECT state FROM tasks WHERE task_id=?',(sys.argv[2],)).fetchone()[0]);con.close()
PY
)"
install -d -m 0700 /var/backups/pds-bridge
BACKUP="$(mktemp -d /var/backups/pds-bridge/m5-recovery-XXXXXXXX)"
python3 - "$DB" "$BACKUP/m5.sqlite" <<'PY'
import sqlite3,sys
source=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
backup=sqlite3.connect(sys.argv[2]);source.backup(backup)
assert backup.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
backup.close();source.close()
PY
systemctl start "$UNIT"
HOST="$(sed -n 's/^Environment=PDS_MCP_HOST=//p' "/etc/systemd/system/$UNIT")"
PORT="$(sed -n 's/^Environment=PDS_MCP_PORT=//p' "/etc/systemd/system/$UNIT")"
[[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$PORT" == 8791 ]] || fail 'M5 bind address changed'
READY=0
for _ in {1..50}; do
  if [[ $(curl --noproxy '*' -fsS --max-time 1 "http://$HOST:$PORT/healthz" 2>/dev/null || true) == '{"status":"ready"}' ]]; then READY=1; break; fi
  sleep 0.3
done
[[ "$READY" == 1 ]] || fail 'M5 did not become ready after restart'
STOPPED=0
systemctl is-active --quiet "$LEGACY" || fail 'v0.03 stopped unexpectedly'
printf 'PDS_M5_RECOVERY_RESTART taskId=%s stateAtStop=%s backup=%s\n' "$TASK_ID" "$STATE_AT_STOP" "$BACKUP"
bash "$INSPECT" "$TASK_ID"
python3 - "$DB" "$TASK_ID" "$STATE_AT_STOP" <<'PY'
import sqlite3,sys
con=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
tid=sys.argv[2]
events=[row[0] for row in con.execute('SELECT event_type FROM task_events WHERE task_id=? ORDER BY event_id',(tid,))]
task=con.execute('SELECT state FROM tasks WHERE task_id=?',(tid,)).fetchone()[0]
prs=con.execute("SELECT pull_request_url FROM git_artifacts WHERE task_id=? AND artifact_type='PR'",(tid,)).fetchall()
print('PDS_M5_RECOVERY_REPORT_BEGIN')
print('taskId='+tid)
print('stateAtStop='+sys.argv[3])
print('state='+task)
print('recoveryRequired='+str('TASK_RECOVERY_REQUIRED' in events))
print('resumePlanning='+str('RESUME_CTO_PLANNING' in events))
print('prCount='+str(len(prs)))
print('prUrl='+(prs[0][0] if len(prs)==1 else 'NONE'))
print('PDS_M5_RECOVERY_REPORT_END')
con.close()
if sys.argv[3]!='PLANNING' or task!='COMPLETED' or 'TASK_RECOVERY_REQUIRED' not in events or 'RESUME_CTO_PLANNING' not in events or len(prs)!=1:
    raise SystemExit('M5_RECOVERY_FAILED: recovery gate did not fully pass; inspect report')
PY
