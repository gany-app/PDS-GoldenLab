#!/usr/bin/env bash
# Upgrade only M5 and run a fresh bounded document Task through its LibreChat MCP.
set -euo pipefail
umask 077
BASE=https://raw.githubusercontent.com/gany-app/PDS-GoldenLab/955fac6e58a04b29946487fa8154e703a8ab905a/scripts/pds-bridge
STAGE_SHA=9c3e832f9cea0896106876a37fe0f7d52cac70d478c86752eeae6171f65efd7f
INSPECT_SHA=90129f6f5eaaa4cafc5f300366d0ffad8475e3906917c43c6673b448ff2994a1
STAGE="$(mktemp /tmp/pds-m5-review-update-XXXXXXXX.sh)"
INSPECT="$(mktemp /tmp/pds-m5-review-inspect-XXXXXXXX.sh)"
trap 'rm -f "$STAGE" "$INSPECT"' EXIT
fail() { printf 'M5_REVIEW_ACCEPT_FAILED: %s\n' "$1" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || fail 'run with sudo'
wget -qO "$STAGE" "$BASE/update-m5-review-evidence-on-pds.sh" || fail 'update download failed'
wget -qO "$INSPECT" "$BASE/inspect-m5-task-on-pds.sh" || fail 'inspector download failed'
echo "$STAGE_SHA  $STAGE" | sha256sum -c - >/dev/null || fail 'update checksum mismatch'
echo "$INSPECT_SHA  $INSPECT" | sha256sum -c - >/dev/null || fail 'inspector checksum mismatch'
bash "$STAGE"

cd /opt/pds-bridge/librechat-v003
SUBMISSION="$(docker compose exec -T -w /app api node - <<'NODE'
const fs=require('fs');
const {Client}=require('@modelcontextprotocol/sdk/client/index.js');
const {StreamableHTTPClientTransport}=require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const {extractEnvVariable}=require('librechat-data-provider');
let client;
function data(result) {
  if (result.isError) throw Error('submit_task rejected');
  const text=result.content?.find(part=>part.type==='text')?.text;
  if (!text) throw Error('submit_task returned no content');
  return JSON.parse(text);
}
(async()=>{
  const config=require('js-yaml').load(fs.readFileSync('/app/librechat.yaml','utf8'));
  const entry=config?.mcpServers?.['pds-bridge-m5'];
  if (!entry?.url || !entry.headers) throw Error('M5 MCP entry unavailable');
  const headers=Object.fromEntries(Object.entries(entry.headers).map(([key,value])=>[key,extractEnvVariable(value)]));
  client=new Client({name:'m5-review-evidence-acceptance',version:'0.1'},{capabilities:{}});
  await client.connect(new StreamableHTTPClientTransport(new URL(entry.url),{requestInit:{headers}}),{timeout:15000});
  const result=data(await client.callTool({name:'submit_task',arguments:{
    repository:'gany-app/PDS-GoldenLab',baseBranch:'v003',
    clientRequestId:'m5-review-evidence-smoke-20260922-01',
    humanRequest:'在 gany-app/PDS-GoldenLab 的 v003 基线上，新增 docs/m5-entry-smoke-v2.md。文件内容固定为一级标题「# M5 异步入口验收（复测）」、一个空行、正文「本文件用于复测 PDS-Bridge v0.1 M5 异步任务链路的执行、提交及验收。」。只更改该文件，不引入依赖。由 PDS 选择 Worker，Bridge 负责 Git 提交、推送和创建 PR；Worker 不自行提交或推送。'
  }},undefined,{timeout:15000}));
  if (!/^[0-9a-f-]{36}$/i.test(result.taskId)) throw Error('invalid Task ID');
  console.log('PDS_M5_NEW_TASK_BEGIN');
  console.log('taskId='+result.taskId);
  console.log('state='+result.state);
  console.log('deduplicated='+result.deduplicated);
  console.log('PDS_M5_NEW_TASK_END');
})().catch(error=>{console.error('M5_REVIEW_ACCEPT_FAILED: '+error.message.replace(/Bearer\s+\S+/gi,'Bearer [REDACTED]'));process.exitCode=1})
  .finally(async()=>{try{await client?.close()}catch{}});
NODE
)" || fail 'MCP submission failed after update; M5 remains running'
printf '%s\n' "$SUBMISSION"
TASK_ID="$(printf '%s\n' "$SUBMISSION" | sed -n 's/^taskId=//p')"
[[ "$TASK_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fail 'Task ID missing from submission'
bash "$INSPECT" "$TASK_ID"

# Print only the resulting PR and acceptance summary from the isolated database.
python3 - "$TASK_ID" <<'PY'
import re, sqlite3, sys
tid=sys.argv[1]
con=sqlite3.connect('file:/var/lib/pds-bridge/runtime-v01-stage.db?mode=ro',uri=True)
task=con.execute('SELECT state FROM tasks WHERE task_id=?',(tid,)).fetchone()
links=con.execute("SELECT pull_request_url FROM git_artifacts WHERE task_id=? AND artifact_type='PR' ORDER BY created_at DESC LIMIT 1",(tid,)).fetchone()
review=con.execute('SELECT result,summary FROM acceptances WHERE task_id=? ORDER BY created_at DESC LIMIT 1',(tid,)).fetchone()
print('PDS_M5_NEW_TASK_OUTCOME_BEGIN')
print('state='+(task[0] if task else 'UNKNOWN'))
url=links[0] if links else ''
print('prUrl='+(url if re.fullmatch(r'https://github\.com/gany-app/PDS-GoldenLab/pull/\d+',url) else 'NONE'))
print('acceptance='+(review[0] if review else 'NONE'))
summary=re.sub(r'[\r\n]+',' ',review[1])[:400] if review else 'NONE'
summary=re.sub(r'Bearer\s+\S+','Bearer [REDACTED]',summary,flags=re.I)
print('summary='+summary)
print('PDS_M5_NEW_TASK_OUTCOME_END')
con.close()
PY
