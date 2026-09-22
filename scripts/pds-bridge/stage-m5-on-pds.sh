#!/usr/bin/env bash
# One-run M5 candidate bootstrap and HTTP smoke. Does not change the v0.03 service.
set -euo pipefail
umask 077

SOURCE_COMMIT="ca75bba895f259417244f829e3ff1a65dc5409e8"
LIVE_DIR="/opt/pds-bridge/candidates/v0.03"
STAGE_DIR="/opt/pds-bridge/candidates/v0.1-m5-stage"
STAGE_CONFIG_DIR="/etc/pds-bridge/m5-stage"
LIVE_CONFIG="/etc/pds-bridge/v003.json"
STAGE_PORT="8791"
SMOKE_PID=""

cleanup() {
  if [[ -n "$SMOKE_PID" ]]; then kill "$SMOKE_PID" 2>/dev/null || true; wait "$SMOKE_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

fail() { printf 'M5_STAGE_FAILED: %s\n' "$1" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || fail "run as root so the candidate can read the existing PDS configuration"
[[ -f "$LIVE_CONFIG" && ( -d "$LIVE_DIR/.git" || -f "$LIVE_DIR/.git" ) ]] || fail "v0.03 config or checkout missing"
command -v git >/dev/null && command -v npm >/dev/null && command -v python3 >/dev/null && command -v curl >/dev/null && command -v runuser >/dev/null || fail "git, npm, python3, curl and runuser are required"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "script source commit is not pinned"
SOURCE_OWNER="$(stat -c %U "$LIVE_DIR")"
id "$SOURCE_OWNER" >/dev/null 2>&1 || fail "v0.03 checkout owner is not a local account"
SOURCE_GROUP="$(id -gn "$SOURCE_OWNER")"
as_source_owner() {
  if [[ "$SOURCE_OWNER" == root ]]; then "$@"; else runuser -u "$SOURCE_OWNER" -- "$@"; fi
}

# The deployed checkout may contain root-owned Git metadata from prior maintenance.
# Inspect it as root without refreshing its index; trust only this path for this call.
LIVE_STATUS="$(git --no-optional-locks -c "safe.directory=$LIVE_DIR" -C "$LIVE_DIR" status --porcelain | wc -l | tr -d ' ')"
LIVE_HEAD="$(git -c "safe.directory=$LIVE_DIR" -C "$LIVE_DIR" rev-parse HEAD)"
LIVE_REMOTE="$(git -c "safe.directory=$LIVE_DIR" -C "$LIVE_DIR" remote get-url origin)" || fail "v0.03 origin missing"
LIVE_SERVICE="$(systemctl is-active pds-bridge-v003-mcp.service 2>/dev/null || true)"
[[ "$LIVE_SERVICE" == active ]] || fail "v0.03 service must remain active for isolated candidate staging"

if [[ ! -d "$STAGE_DIR/.git" ]]; then
  [[ ! -e "$STAGE_DIR" || -d "$STAGE_DIR" && -z "$(ls -A "$STAGE_DIR")" ]] || fail "candidate directory already exists and is not an empty Git checkout"
  # Local clone opens the source via its .git path in a child Git process.
  git -c "safe.directory=$LIVE_DIR" -c "safe.directory=$LIVE_DIR/.git" \
    clone -q --no-hardlinks "$LIVE_DIR" "$STAGE_DIR" || fail "local isolated clone failed"
  git -C "$STAGE_DIR" remote set-url origin "$LIVE_REMOTE"
else
  [[ -z "$(git --no-optional-locks -c "safe.directory=$STAGE_DIR" -C "$STAGE_DIR" status --porcelain)" ]] || fail "candidate checkout has local changes"
fi
chown -R "$SOURCE_OWNER:$SOURCE_GROUP" "$STAGE_DIR"
[[ -z "$(as_source_owner git -C "$STAGE_DIR" status --porcelain)" ]] || fail "candidate checkout has local changes"
as_source_owner git -C "$STAGE_DIR" fetch -q origin v0.1 2>/dev/null || fail "candidate fetch failed; check GitHub credentials for the repository owner"
as_source_owner git -C "$STAGE_DIR" merge-base --is-ancestor "$SOURCE_COMMIT" FETCH_HEAD || fail "pinned code commit is not on the v0.1 branch"
as_source_owner git -C "$STAGE_DIR" checkout -q --detach "$SOURCE_COMMIT"
[[ "$(as_source_owner git -C "$STAGE_DIR" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "candidate source SHA mismatch"

cd "$STAGE_DIR"
as_source_owner npm ci --no-audit --no-fund > /tmp/pds-m5-stage-npm.log 2>&1 || fail "npm ci failed (details: /tmp/pds-m5-stage-npm.log)"
as_source_owner npm run check > /tmp/pds-m5-stage-check.log 2>&1 || fail "npm run check failed (details: /tmp/pds-m5-stage-check.log)"

install -d -m 0700 "$STAGE_CONFIG_DIR"
python3 - "$LIVE_CONFIG" "$STAGE_CONFIG_DIR" <<'PY'
import json, pathlib, sys
legacy_path = pathlib.Path(sys.argv[1]); config_dir = pathlib.Path(sys.argv[2])
config = json.loads(legacy_path.read_text())
cto = (config.get('roles') or {}).get('cto') or {}
if not cto.get('enabled', True) or cto.get('kind') != 'codex-cli':
    raise SystemExit('M5_STAGE_FAILED: enabled Codex CTO missing')
projects = [p for p in config.get('projects', []) if p.get('enabled', True)]
workers = [w for w in config.get('workers', []) if w.get('enabled', True)]
adapters = {a['adapterId']: a for a in config.get('adapters', []) if a.get('enabled', True)}
if not projects or not workers:
    raise SystemExit('M5_STAGE_FAILED: no enabled project or Worker')
vocabulary = {'inspect','code_edit','frontend','shell','test','git_inspect',
              'debug','long_context','architecture_sensitive_code','core_refactor'}
models = []; ladder_workers = []; defaults = []
for worker in workers:
    adapter = adapters.get(worker['adapter'])
    if not adapter or adapter['kind'] not in ('agy-cli', 'opencode-cli'):
        raise SystemExit('M5_STAGE_FAILED: Worker adapter is not supported')
    level = worker['maxTaskLevel']
    if level != {'fast':'L1','standard':'L2','expert':'L3'}[worker['workerClass']]:
        raise SystemExit('M5_STAGE_FAILED: Worker class and level mismatch')
    capabilities = list(dict.fromkeys('git_inspect' if c == 'git' else c for c in worker['capabilities']))
    if not capabilities or set(capabilities) - vocabulary:
        raise SystemExit('M5_STAGE_FAILED: Worker capabilities need manual mapping')
    model = worker.get('modelProfile') or adapter.get('model') or 'cli-default'
    if model == 'cli-default': defaults.append(worker['workerId'])
    profile_id = 'stage-' + worker['workerId']
    models.append({'profileId':profile_id, 'provider':adapter['kind'], 'model':model,
                   'speedClass':worker.get('speedClass','medium').upper().replace('MEDIUM','NORMAL'),
                   'costClass':worker.get('costClass','medium').upper(), 'contextClass':'NORMAL',
                   'toolCalling':True, 'enabled':True})
    perms = worker['permissions']
    ladder_workers.append({'workerId':worker['workerId'], 'displayName':worker['workerId'],
        'adapter':worker['adapter'], 'level':level, 'workerClass':worker['workerClass'],
        'capabilities':capabilities,
        'permissions':{'filesystem_read':perms['read'], 'filesystem_write':perms['write'],
          'shell':perms['shell'], 'network':perms['network'], 'git_read':True,
          'git_write':False, 'github_write':False}, 'supportedModelProfiles':[profile_id],
        'defaultModelProfileId':profile_id, 'enabled':True, 'priority':100,
        'timeoutSeconds':1800, 'concurrencyLimit':worker.get('maxConcurrency',1)})
ladder = {'version':1, 'configRevisionId':'pds-m5-stage-1', 'ctoAdapterId':cto['adapterId'],
          'adapters':[{'adapterId':a['adapterId'],'kind':a['kind'], 'enabled':True,
                       'command':a.get('command',a['kind'].split('-')[0])} for a in adapters.values()
                      if a['adapterId'] in {w['adapter'] for w in ladder_workers}],
          'modelProfiles':models, 'workers':ladder_workers}
(config_dir/'m5-stage-worker-ladder.json').write_text(json.dumps(ladder,indent=2)+'\n')
stage = {'version':1, 'legacyConfigPath':str(legacy_path),
         'workerLadderPath':str(config_dir/'m5-stage-worker-ladder.json'),
         'databasePath':'/var/lib/pds-bridge/runtime-v01-stage.db',
         'workspaceRoot':'/srv/pds-bridge/workspaces/m5-stage',
         'verificationCommands':{p['projectId']:[{'name':'git diff check','command':'git',
           'args':['diff','--check']}] for p in projects}}
(config_dir/'m5-stage-runtime.json').write_text(json.dumps(stage,indent=2)+'\n')
(config_dir/'m5-stage-report.json').write_text(json.dumps({
    'projectIds':[p['projectId'] for p in projects], 'workerIds':[w['workerId'] for w in workers],
    'modelSelectorsUnpinned':defaults, 'verification':'git diff --check (stage only)'},indent=2)+'\n')
PY

[[ -z "$(curl --noproxy '*' -fsS --max-time 1 "http://127.0.0.1:${STAGE_PORT}/healthz" 2>/dev/null || true)" ]] || fail "stage port already serves a process"
PDS_BRIDGE_M5_CONFIG="$STAGE_CONFIG_DIR/m5-stage-runtime.json" PDS_MCP_HOST=127.0.0.1 PDS_MCP_PORT="$STAGE_PORT" \
  node --no-warnings --experimental-strip-types src/mcp/http-main.ts > /tmp/pds-m5-stage-http.log 2>&1 &
SMOKE_PID="$!"
HEALTH=""
for _ in {1..50}; do
  HEALTH="$(curl --noproxy '*' -fsS --max-time 1 "http://127.0.0.1:${STAGE_PORT}/healthz" 2>/dev/null || true)"
  [[ -n "$HEALTH" ]] && break
  kill -0 "$SMOKE_PID" 2>/dev/null || fail "candidate HTTP process exited (details: /tmp/pds-m5-stage-http.log)"
  sleep 0.2
done
[[ "$HEALTH" == '{"status":"ready"}' ]] || fail "candidate /healthz did not report ready"

printf 'PDS_M5_STAGE_REPORT_BEGIN\n'
printf 'sourceCommit=%s\nlegacyHead=%s\nlegacyModifiedFiles=%s\nlegacyService=%s\n' "$SOURCE_COMMIT" "$LIVE_HEAD" "$LIVE_STATUS" "$LIVE_SERVICE"
printf 'tests=PASS\nhttpHealth=ready\n'
cat "$STAGE_CONFIG_DIR/m5-stage-report.json"
printf 'PDS_M5_STAGE_REPORT_END\n'
