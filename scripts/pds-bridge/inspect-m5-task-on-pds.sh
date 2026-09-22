#!/usr/bin/env bash
# Read-only M5 task and event-replay inspection from the running LibreChat API container.
set -euo pipefail
[[ $# -eq 1 && "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
  printf 'Usage: sudo bash inspect-m5-task-on-pds.sh <task-uuid>\n' >&2; exit 2;
}
cd /opt/pds-bridge/librechat-v003
docker compose exec -T -w /app -e "PDS_M5_TASK_ID=$1" api node - <<'NODE'
const fs = require('fs');
const {Client} = require('@modelcontextprotocol/sdk/client/index.js');
const {StreamableHTTPClientTransport} = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
const {extractEnvVariable} = require('librechat-data-provider');
const taskId = process.env.PDS_M5_TASK_ID;
let client, stage='connect';
const watchdog = setTimeout(()=>{console.error('M5_INSPECT_FAILED: timeout at '+stage);process.exit(1)},430000);

function decoded(result) {
  if (result.isError) throw Error('MCP tool returned an error');
  const text=result.content?.find(part=>part.type==='text')?.text;
  if (!text) throw Error('MCP tool returned no text');
  return JSON.parse(text);
}
async function replay(url,headers,cursor,useHeader) {
  const endpoint=new URL(url); endpoint.pathname='/events';
  endpoint.searchParams.set('taskId',taskId);
  if (!useHeader) endpoint.searchParams.set('after',String(cursor));
  const controller=new AbortController();
  const timeout=setTimeout(()=>controller.abort(),4000);
  try {
    const response=await fetch(endpoint,{headers:useHeader ? {...headers,'Last-Event-ID':String(cursor)}:headers,
      signal:controller.signal});
    if (!response.ok || !response.headers.get('content-type')?.includes('text/event-stream')) {
      throw Error('SSE endpoint unavailable');
    }
    const reader=response.body.getReader();
    let buffer='';
    while (!controller.signal.aborted && buffer.length<20000) {
      const {value,done}=await reader.read();
      if (done) break;
      buffer+=new TextDecoder().decode(value);
      if (buffer.includes('id: '+String(cursor+1)+'\n')) break;
      if (buffer.includes(': connected\n\n') && cursor===0) break;
    }
    await reader.cancel().catch(()=>{});
    return buffer;
  } finally {clearTimeout(timeout);controller.abort()}
}
async function waitForNotification(url,headers,cursor) {
  const endpoint=new URL(url); endpoint.pathname='/events';
  endpoint.searchParams.set('taskId',taskId);
  endpoint.searchParams.set('after',String(cursor));
  const controller=new AbortController();
  const timeout=setTimeout(()=>controller.abort(),360000);
  let reader;
  try {
    const response=await fetch(endpoint,{headers,signal:controller.signal});
    if (!response.ok || !response.headers.get('content-type')?.includes('text/event-stream')) {
      throw Error('SSE endpoint unavailable');
    }
    reader=response.body.getReader();
    const decoder=new TextDecoder();
    let buffer='';
    while (!controller.signal.aborted) {
      const {value,done}=await reader.read();
      if (done) throw Error('SSE closed before a Task notification');
      buffer+=decoder.decode(value,{stream:true});
      let boundary;
      while ((boundary=buffer.indexOf('\n\n'))>=0) {
        const frame=buffer.slice(0,boundary);
        buffer=buffer.slice(boundary+2);
        if (/^event: TASK_(COMPLETED|FAILED|BLOCKED|WAITING_HUMAN|CANCELLED)$/m.test(frame)) return true;
      }
      if (buffer.length>20000) throw Error('SSE frame too large');
    }
    return false;
  } catch(error) {
    if (controller.signal.aborted) return false;
    throw error;
  } finally {
    clearTimeout(timeout); controller.abort();
    await reader?.cancel().catch(()=>{});
  }
}
(async()=>{
  let config;
  try { config=require('js-yaml').load(fs.readFileSync('/app/librechat.yaml','utf8')) }
  catch { throw Error('mounted YAML unavailable') }
  const entry=config?.mcpServers?.['pds-bridge-m5'];
  if (!entry) throw Error('M5 MCP entry unavailable');
  const headers=Object.fromEntries(Object.entries(entry.headers||{}).map(([key,value])=>[key,extractEnvVariable(value)]));
  client=new Client({name:'pds-m5-inspection',version:'0.1'},{capabilities:{}});
  await client.connect(new StreamableHTTPClientTransport(new URL(entry.url),{requestInit:{headers}}),{timeout:15000});
  stage='get_task';
  let timeline=decoded(await client.callTool({name:'get_task',arguments:{taskId}},undefined,{timeout:15000}));
  if (timeline.task?.taskId!==taskId) throw Error('Task ID mismatch');
  stage='get_task_events';
  let events=decoded(await client.callTool({name:'get_task_events',arguments:{taskId,afterEventId:0,limit:500}},undefined,{timeout:15000}));
  if (!Array.isArray(events) || events.some(item=>item.taskId!==taskId)) throw Error('Event mismatch');
  let notification=events.filter(item=>item.toState===timeline.task.state &&
    ['COMPLETED','FAILED','BLOCKED','WAITING_HUMAN','CANCELLED'].includes(item.toState)).at(-1);
  if (!notification) {
    stage='await SSE notification';
    console.log('M5_INSPECT_WAITING: task='+timeline.task.state+'; waiting on SSE for at most 6 minutes');
    await waitForNotification(entry.url,headers,events.at(-1)?.eventId||0);
    stage='refresh Task timeline';
    timeline=decoded(await client.callTool({name:'get_task',arguments:{taskId}},undefined,{timeout:15000}));
    events=decoded(await client.callTool({name:'get_task_events',arguments:{taskId,afterEventId:0,limit:500}},undefined,{timeout:15000}));
    if (!Array.isArray(events) || events.some(item=>item.taskId!==taskId)) throw Error('Event mismatch');
    notification=events.filter(item=>item.toState===timeline.task.state &&
      ['COMPLETED','FAILED','BLOCKED','WAITING_HUMAN','CANCELLED'].includes(item.toState)).at(-1);
  }
  stage='SSE replay';
  let replayResult='PENDING_NO_NOTIFICATION';
  if (notification) {
    const cursor=notification.eventId-1;
    const first=await replay(entry.url,headers,cursor,false);
    const second=await replay(entry.url,headers,cursor,true);
    const expected='id: '+notification.eventId+'\n';
    if (!first.includes(expected) || !second.includes(expected)) throw Error('SSE replay cursor mismatch');
    replayResult='PASS_QUERY_AND_LAST_EVENT_ID';
  } else {
    const first=await replay(entry.url,headers,0,false);
    if (!first.includes(': connected')) throw Error('SSE connection unavailable');
  }
  console.log('PDS_M5_TASK_INSPECTION_BEGIN');
  console.log('taskId='+taskId);
  console.log('state='+timeline.task.state);
  console.log('stateVersion='+timeline.task.stateVersion);
  console.log('contractLevel='+(timeline.contracts?.at(-1)?.minimumLevel||'NONE'));
  console.log('attempts='+JSON.stringify((timeline.attempts||[]).map(a=>({workerId:a.workerId,
    state:a.state,profileId:a.modelProfileId,failureClass:a.failureClass}))));
  console.log('eventTypes='+JSON.stringify(events.map(e=>e.eventType)));
  console.log('notification='+(notification?.toState||'NONE'));
  console.log('sseReplay='+replayResult);
  console.log('PDS_M5_TASK_INSPECTION_END');
})().catch(error=>{
  console.error('M5_INSPECT_FAILED: '+stage+' ('+(error.name||'error')+')');
  process.exitCode=1;
}).finally(async()=>{clearTimeout(watchdog);try{await client?.close()}catch{}});
NODE
