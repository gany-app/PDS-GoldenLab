#!/usr/bin/env bash
# One bounded retry of the existing M5 acceptance Task and SSE inspection.
set -euo pipefail
umask 077
TASK_ID=16fc0bf0-9a9e-4bc4-ab24-c090d8e04c6f
FIX_COMMIT=e55166fcdd62513b7ddbf424a28c4885393f90b3
FIX_DIR=/opt/pds-bridge/candidates/v0.1-m5-exit-code-fix
UNIT=pds-bridge-v01-m5-stage.service
INSPECT_SHA256=90129f6f5eaaa4cafc5f300366d0ffad8475e3906917c43c6673b448ff2994a1
INSPECT_URL=https://raw.githubusercontent.com/gany-app/PDS-GoldenLab/0ab16394f292039b576afbf8989511b3d6eee9b2/scripts/pds-bridge/inspect-m5-task-on-pds.sh
INSPECT_FILE="$(mktemp /tmp/pds-m5-inspect-fixed-XXXXXXXX.sh)"
trap 'rm -f "$INSPECT_FILE"' EXIT
fail() { printf 'M5_RETRY_FAILED: %s\n' "$1" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || fail 'run with sudo'
systemctl is-active --quiet "$UNIT" || fail 'M5 service is not active'
systemctl is-active --quiet pds-bridge-v003-mcp.service || fail 'v0.03 service is not active'
grep -Fqx "WorkingDirectory=$FIX_DIR" "/etc/systemd/system/$UNIT" || fail 'M5 is not using the fixed candidate'
[[ $(git -c "safe.directory=$FIX_DIR" -C "$FIX_DIR" rev-parse HEAD) == "$FIX_COMMIT" ]] || fail 'fixed commit mismatch'
wget -qO "$INSPECT_FILE" "$INSPECT_URL" || fail 'could not fetch pinned inspector'
echo "$INSPECT_SHA256  $INSPECT_FILE" | sha256sum -c - >/dev/null || fail 'inspector checksum mismatch'

cd /opt/pds-bridge/librechat-v003
docker compose exec -T -w /app -e "PDS_M5_TASK_ID=$TASK_ID" api node - <<'NODE'
const fs=require('fs');
const {Client}=require('@modelcontextprotocol/sdk/client/index.js');
const {StreamableHTTPClientTransport}=require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const {extractEnvVariable}=require('librechat-data-provider');
let client;
function data(result) {
  if (result.isError) throw Error('MCP tool rejected the request');
  const part=result.content?.find(item=>item.type==='text');
  if (!part?.text) throw Error('MCP tool returned no content');
  return JSON.parse(part.text);
}
(async()=>{
  const taskId=process.env.PDS_M5_TASK_ID;
  const config=require('js-yaml').load(fs.readFileSync('/app/librechat.yaml','utf8'));
  const entry=config?.mcpServers?.['pds-bridge-m5'];
  if (!entry?.url || !entry.headers) throw Error('M5 MCP entry unavailable');
  const headers=Object.fromEntries(Object.entries(entry.headers).map(([key,value])=>[key,extractEnvVariable(value)]));
  client=new Client({name:'pds-m5-retry-acceptance',version:'0.1'},{capabilities:{}});
  await client.connect(new StreamableHTTPClientTransport(new URL(entry.url),{requestInit:{headers}}),{timeout:15000});
  const timeline=data(await client.callTool({name:'get_task',arguments:{taskId}},undefined,{timeout:15000}));
  const task=timeline.task;
  const last=timeline.attempts?.at(-1);
  if (task?.taskId!==taskId || task.state!=='BLOCKED' || task.stateVersion!==4 ||
      last?.state!=='INTERRUPTED' || last.failureCode!=='EXECUTION_ERROR' ||
      last.failureMessage!=='unknown failure code: 1') {
    throw Error('Task timeline changed; no retry issued');
  }
  const retried=data(await client.callTool({name:'retry_task',arguments:{
    taskId,expectedStateVersion:4,
    reason:'M5 分类缺陷已修复并通过回归测试；恢复原验收任务，保留首次失败证据'
  }},undefined,{timeout:15000}));
  if (retried.taskId!==taskId || retried.state!=='READY') throw Error('retry_task returned unexpected state');
  console.log('PDS_M5_RETRY_REPORT_BEGIN');
  console.log('taskId='+taskId);
  console.log('state='+retried.state);
  console.log('stateVersion='+retried.stateVersion);
  console.log('PDS_M5_RETRY_REPORT_END');
})().catch(error=>{console.error('M5_RETRY_FAILED: '+error.message.replace(/Bearer\s+\S+/gi,'Bearer [REDACTED]'));process.exitCode=1})
  .finally(async()=>{try{await client?.close()}catch{}});
NODE

# The existing pinned inspector waits on Task SSE and prints a redacted result.
bash "$INSPECT_FILE" "$TASK_ID"
