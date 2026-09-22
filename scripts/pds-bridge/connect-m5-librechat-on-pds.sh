#!/usr/bin/env bash
# Keep v0.03 online while exposing the already-staged M5 candidate as a second MCP server.
set -euo pipefail
umask 077

STAGE_DIR=/opt/pds-bridge/candidates/v0.1-m5-stage
STAGE_CONFIG_DIR=/etc/pds-bridge/m5-stage
STAGE_CONFIG="$STAGE_CONFIG_DIR/m5-stage-runtime.json"
SOURCE_COMMIT=ca75bba895f259417244f829e3ff1a65dc5409e8
LEGACY_ENV=/etc/pds-bridge/v003.env
LEGACY_UNIT=pds-bridge-v003-mcp.service
STAGE_UNIT=pds-bridge-v01-m5-stage.service
STAGE_PORT=8791
LIBRECHAT_DIR=/opt/pds-bridge/librechat-v003
LIBRECHAT_CONFIG="$LIBRECHAT_DIR/librechat.yaml"
BACKUP_DIR=""
YAML_CHANGED=0

fail() { printf 'M5_CONNECT_FAILED: %s\n' "$1" >&2; exit 1; }
restore_yaml_on_error() {
  local result=$?
  trap - ERR
  if (( YAML_CHANGED )); then
    cat "$BACKUP_DIR/librechat.yaml" > "$LIBRECHAT_CONFIG" || true
    (cd "$LIBRECHAT_DIR" && docker compose restart api >/dev/null) || true
    printf 'M5_CONNECT_ROLLBACK: restored LibreChat configuration from %s\n' "$BACKUP_DIR" >&2
  fi
  printf 'M5_CONNECT_FAILED: step failed (exit %s); v0.03 was not replaced\n' "$result" >&2
  exit "$result"
}
trap restore_yaml_on_error ERR

[[ $(id -u) -eq 0 ]] || fail 'run with sudo'
for name in git python3 docker curl systemctl chown; do
  command -v "$name" >/dev/null || fail "missing command: $name"
done
docker compose version >/dev/null 2>&1 || fail 'Docker Compose unavailable'
[[ -f "$STAGE_CONFIG" && -f "$LEGACY_ENV" && -f "$LIBRECHAT_CONFIG" ]] || fail 'run M5 stage first; stage config, v0.03 env or LibreChat config missing'
[[ -d "$STAGE_DIR/.git" ]] || fail 'M5 candidate checkout missing'
systemctl is-active --quiet "$LEGACY_UNIT" || fail 'v0.03 service is not active'
RUNTIME_USER="$(systemctl show -P User "$LEGACY_UNIT")"
[[ -n "$RUNTIME_USER" && "$RUNTIME_USER" != root ]] || fail 'v0.03 runtime account unavailable'
id "$RUNTIME_USER" >/dev/null || fail 'v0.03 runtime user missing'
RUNTIME_GROUP="$(id -gn "$RUNTIME_USER")"
RUNTIME_HOME="$(getent passwd "$RUNTIME_USER" | cut -d: -f6)"
[[ -n "$RUNTIME_HOME" && -d "$RUNTIME_HOME" ]] || fail 'runtime home missing'
[[ "$(git -c "safe.directory=$STAGE_DIR" -C "$STAGE_DIR" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail 'candidate source commit mismatch'
[[ -z "$(git --no-optional-locks -c "safe.directory=$STAGE_DIR" -C "$STAGE_DIR" status --porcelain)" ]] || fail 'candidate checkout has local changes'
[[ -n "$(sed -n 's/^PDS_MCP_BEARER_TOKEN=//p' "$LEGACY_ENV" | head -n 1)" ]] || fail 'v0.03 bearer token missing'

python3 - "$STAGE_CONFIG" <<'PY'
import json, pathlib, sys
config = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert config['legacyConfigPath'] == '/etc/pds-bridge/v003.json'
assert config['databasePath'] == '/var/lib/pds-bridge/runtime-v01-stage.db'
assert config['workspaceRoot'] == '/srv/pds-bridge/workspaces/m5-stage'
assert pathlib.Path(config['workerLadderPath']).is_file()
PY

DOCKER_GATEWAY="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
[[ "$DOCKER_GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Docker bridge gateway unavailable'
(cd "$LIBRECHAT_DIR" && [[ -n "$(docker compose ps --status running -q api)" ]]) || fail 'LibreChat API is not running'
python3 - "$LIBRECHAT_DIR" "$LIBRECHAT_CONFIG" <<'PY'
import json, pathlib, subprocess, sys
directory, filename = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).resolve()
api = subprocess.run(['docker','compose','ps','-q','api'], cwd=directory,
                     capture_output=True, text=True, check=True).stdout.strip()
if not api:
    raise SystemExit('M5_CONNECT_FAILED: LibreChat API container unavailable')
details = json.loads(subprocess.run(['docker','inspect',api], capture_output=True,
                                    text=True, check=True).stdout)[0]
mounts = [m for m in details['Mounts'] if m['Destination'] == '/app/librechat.yaml']
if len(mounts) != 1 or pathlib.Path(mounts[0]['Source']).resolve() != filename:
    raise SystemExit('M5_CONNECT_FAILED: mounted LibreChat YAML differs from expected file')
PY

# The stage smoke created SQLite as root. Transfer only the isolated candidate,
# its generated configuration and its dedicated database to the running account.
if ! systemctl is-active --quiet "$STAGE_UNIT"; then
  chown -R "$RUNTIME_USER:$RUNTIME_GROUP" "$STAGE_DIR"
  for suffix in '' -wal -shm; do
    db_file=/var/lib/pds-bridge/runtime-v01-stage.db$suffix
    if [[ -f "$db_file" ]]; then
      chown "$RUNTIME_USER:$RUNTIME_GROUP" "$db_file"
      chmod 0600 "$db_file"
    fi
  done
fi
install -d -m 0750 -o root -g "$RUNTIME_GROUP" "$STAGE_CONFIG_DIR"
for filename in m5-stage-worker-ladder.json m5-stage-runtime.json m5-stage-report.json; do
  chown "root:$RUNTIME_GROUP" "$STAGE_CONFIG_DIR/$filename"
  chmod 0640 "$STAGE_CONFIG_DIR/$filename"
done
install -d -m 0750 -o "$RUNTIME_USER" -g "$RUNTIME_GROUP" /srv/pds-bridge/workspaces/m5-stage

UNIT_FILE=/etc/systemd/system/$STAGE_UNIT
if [[ -e "$UNIT_FILE" ]]; then
  grep -Fqx "WorkingDirectory=$STAGE_DIR" "$UNIT_FILE" || fail 'existing M5 systemd unit has unexpected working directory'
  grep -Fqx "User=$RUNTIME_USER" "$UNIT_FILE" || fail 'existing M5 systemd unit has unexpected user'
  grep -Fqx "Environment=PDS_BRIDGE_M5_CONFIG=$STAGE_CONFIG" "$UNIT_FILE" || fail 'existing M5 systemd unit has unexpected config'
else
  cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=PDS-Bridge v0.1 M5 isolated candidate
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=$RUNTIME_USER
Group=$RUNTIME_GROUP
WorkingDirectory=$STAGE_DIR
Environment=HOME=$RUNTIME_HOME
Environment=PATH=$RUNTIME_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=PDS_BRIDGE_M5_CONFIG=$STAGE_CONFIG
Environment=PDS_MCP_HOST=$DOCKER_GATEWAY
Environment=PDS_MCP_PORT=$STAGE_PORT
Environment=PDS_MCP_ALLOW_REMOTE_BIND=1
EnvironmentFile=$LEGACY_ENV
ExecStart=/usr/bin/env npm run mcp:http
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
fi
systemctl daemon-reload
systemctl enable "$STAGE_UNIT" >/dev/null
if ! systemctl is-active --quiet "$STAGE_UNIT"; then systemctl start "$STAGE_UNIT"; fi
READY=0
for _ in {1..40}; do
  if [[ "$(curl --noproxy '*' -fsS --max-time 1 "http://$DOCKER_GATEWAY:$STAGE_PORT/healthz" 2>/dev/null || true)" == '{"status":"ready"}' ]]; then
    READY=1; break
  fi
  sleep 0.5
done
[[ "$READY" -eq 1 ]] || fail "M5 service did not become ready; inspect: journalctl -u $STAGE_UNIT -n 60"

install -d -m 0700 /var/backups/pds-bridge
BACKUP_DIR="$(mktemp -d "/var/backups/pds-bridge/m5-connect-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
cp -a "$LIBRECHAT_CONFIG" "$BACKUP_DIR/librechat.yaml"
YAML_CHANGED=1
python3 - "$LIBRECHAT_CONFIG" "$STAGE_PORT" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1]); port = sys.argv[2]
text = p.read_text()
matches = list(re.finditer(r'(?m)^mcpServers:\s*(?:#.*)?$', text))
if len(matches) != 1:
    raise SystemExit('M5_CONNECT_FAILED: expected exactly one top-level mcpServers block')
start = matches[0].end()
next_section = re.search(r'(?m)^[^\s#][^\n]*:', text[start:])
end = start + next_section.start() if next_section else len(text)
block = text[start:end]
url = f'http://host.docker.internal:{port}/mcp'
if re.search(r'(?m)^  pds-bridge-m5:', block):
    if url not in block:
        raise SystemExit('M5_CONNECT_FAILED: existing pds-bridge-m5 has a different URL')
    print('M5 MCP entry already present')
else:
    entry = ('  pds-bridge-m5:\n'
             '    type: streamable-http\n'
             f'    url: "{url}"\n'
             '    requiresOAuth: false\n'
             '    headers:\n'
             '      Authorization: "Bearer ${PDS_MCP_BEARER_TOKEN}"\n'
             '      X-PDS-Client: "librechat-m5-stage"\n'
             '    initTimeout: 15000\n'
             '    timeout: 420000\n'
             '    serverInstructions: true\n')
    updated = text[:end].rstrip('\n') + '\n' + entry + text[end:]
    # This file is mounted directly into the running API container. Keep the
    # inode so restarting the container sees the edited text.
    p.write_text(updated)
    print('M5 MCP entry added')
PY
(cd "$LIBRECHAT_DIR" && docker compose exec -T api node - <<'NODE'
const fs = require('fs');
try {
  const yaml = require('js-yaml').load(fs.readFileSync('/app/librechat.yaml','utf8'));
  const {configSchema} = require('librechat-data-provider');
  if (!configSchema.strict().safeParse(yaml).success) throw Error('schema');
  if (yaml.mcpServers?.['pds-bridge-m5']?.url !== 'http://host.docker.internal:8791/mcp') throw Error('URL');
  if (!yaml.mcpSettings?.allowedDomains?.includes('host.docker.internal')) throw Error('domain');
  if (!yaml.mcpServers?.['pds-bridge']) throw Error('v0.03 entry');
  console.log('LibreChat YAML and configuration schema: PASS; v0.03 and M5 both present');
} catch (_) { console.error('M5_CONNECT_FAILED: LibreChat configuration validation failed'); process.exit(1) }
NODE
)
(cd "$LIBRECHAT_DIR" && docker compose restart api >/dev/null)
for _ in {1..30}; do
  if (cd "$LIBRECHAT_DIR" && docker compose exec -T api node -e 'process.exit(require("fs").existsSync("/app/librechat.yaml")?0:1)' >/dev/null 2>&1); then break; fi
  sleep 2
done
(cd "$LIBRECHAT_DIR" && docker compose exec -T -w /app api node - <<'NODE'
const fs = require('fs');
const { extractEnvVariable } = require('librechat-data-provider');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StreamableHTTPClientTransport } = require('@modelcontextprotocol/sdk/client/streamableHttp.js');
let client;
(async()=>{
  const yaml = require('js-yaml').load(fs.readFileSync('/app/librechat.yaml','utf8'));
  const entry = yaml.mcpServers['pds-bridge-m5'];
  const headers = Object.fromEntries(Object.entries(entry.headers).map(([key,value])=>[key,extractEnvVariable(value)]));
  client = new Client({name:'pds-m5-readonly-acceptance',version:'0.1'}, {capabilities:{}});
  await client.connect(new StreamableHTTPClientTransport(new URL(entry.url),{requestInit:{headers}}),{timeout:15000});
  const listed=await client.listTools({},{timeout:15000});
  const names=new Set(listed.tools.map(tool=>tool.name));
  for (const name of ['submit_task','get_task','get_task_events','respond_to_human','bridge_status']) {
    if (!names.has(name)) throw Error('M5 tool missing: '+name);
  }
  if (names.has('advance_task') || names.has('submit_request')) throw Error('legacy synchronous tool exposed on M5');
  const status=await client.callTool({name:'bridge_status',arguments:{}},undefined,{timeout:15000});
  const value=JSON.parse(status.content.find(part=>part.type==='text').text);
  if (status.isError || value.status!=='ready' || value.databaseIntegrity!==true) throw Error('M5 bridge_status not ready');
  const eventsUrl=new URL(entry.url); eventsUrl.pathname='/events'; eventsUrl.search='after=0';
  const eventStream=await fetch(eventsUrl,{headers,signal:AbortSignal.timeout(5000)});
  if (eventStream.status!==200 || !eventStream.headers.get('content-type')?.includes('text/event-stream')) throw Error('SSE unavailable');
  await eventStream.body?.cancel();
  console.log('M5_READONLY_CHECK=PASS tools, SQLite integrity, authenticated SSE');
})().catch(error=>{
  const message=String(error.message).replace(/Bearer\s+\S+/gi,'Bearer [REDACTED]');
  console.error('M5_READONLY_CHECK=FAIL '+message.slice(0,300)); process.exitCode=1;
}).finally(async()=>{try{await client?.close()}catch{}});
NODE
)
[[ $(systemctl is-active "$LEGACY_UNIT") == active ]]
YAML_CHANGED=0
trap - ERR
printf 'PDS_M5_CONNECT_REPORT_BEGIN\n'
printf 'candidateService=%s\nlegacyService=active\nlibrechatMcp=pds-bridge-m5\nhttpPort=%s\n' "$STAGE_UNIT" "$STAGE_PORT"
printf 'backup=%s\nPDS_M5_CONNECT_REPORT_END\n' "$BACKUP_DIR"
