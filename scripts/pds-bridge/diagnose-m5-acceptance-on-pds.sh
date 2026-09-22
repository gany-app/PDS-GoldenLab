#!/usr/bin/env bash
# Read only the persisted acceptance evidence for the original M5 Task.
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
python3 - <<'PY'
import json, pathlib, re, sqlite3

db=pathlib.Path('/var/lib/pds-bridge/runtime-v01-stage.db')
task_id='16fc0bf0-9a9e-4bc4-ab24-c090d8e04c6f'
con=sqlite3.connect(f'file:{db}?mode=ro', uri=True)
con.row_factory=sqlite3.Row

def safe(value, limit=1500):
    text=str(value or 'NONE')
    text=re.sub(r'Bearer\s+\S+','Bearer [REDACTED]',text,flags=re.I)
    text=re.sub(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{16,})\b','[REDACTED]',text)
    return text[:limit]

task=con.execute('SELECT state,state_version,repository,base_branch FROM tasks WHERE task_id=?',(task_id,)).fetchone()
if not task or task['state']!='FAILED':
    raise SystemExit('M5_ACCEPT_DIAG_FAILED: expected original Task in FAILED state')
contract=con.execute('SELECT title,what_text,acceptance_criteria_json FROM task_contracts WHERE task_id=? ORDER BY revision DESC LIMIT 1',(task_id,)).fetchone()
acceptances=con.execute('SELECT attempt_id,result,summary,criteria_results_json FROM acceptances WHERE task_id=? ORDER BY created_at,acceptance_id',(task_id,)).fetchall()
artifacts=con.execute('SELECT attempt_id,artifact_type,status,branch,commit_sha,pull_request_number,pull_request_url,detail_json FROM git_artifacts WHERE task_id=? ORDER BY created_at,git_artifact_id',(task_id,)).fetchall()
verifications=con.execute("SELECT attempt_id,payload_json FROM task_events WHERE task_id=? AND event_type='M5_VERIFICATION' ORDER BY event_id",(task_id,)).fetchall()

print('PDS_M5_ACCEPT_DIAG_BEGIN')
print('taskId='+task_id)
print('state='+task['state'])
print('stateVersion='+str(task['state_version']))
print('repository='+task['repository'])
print('baseBranch='+task['base_branch'])
print('title='+safe(contract['title']))
print('goal='+safe(contract['what_text']))
print('criteria='+safe(contract['acceptance_criteria_json'],3000))
for index,row in enumerate(acceptances,1):
    print(f'acceptance{index}.attemptId='+str(row['attempt_id']))
    print(f'acceptance{index}.result='+row['result'])
    print(f'acceptance{index}.summary='+safe(row['summary'],2500))
    criteria=json.loads(row['criteria_results_json'])
    print(f'acceptance{index}.findings='+safe(json.dumps([item.get('findings') for item in criteria if isinstance(item,dict)],ensure_ascii=False),2500))
for index,row in enumerate(artifacts,1):
    detail=json.loads(row['detail_json'])
    print('artifact'+str(index)+'='+safe(json.dumps({
        'attemptId':row['attempt_id'],'type':row['artifact_type'],'status':row['status'],
        'branch':row['branch'],'commit':row['commit_sha'],
        'prNumber':row['pull_request_number'],'prUrl':row['pull_request_url'],
        'changedFiles':detail.get('changedFiles')},ensure_ascii=False),1000))
for index,row in enumerate(verifications,1):
    payload=json.loads(row['payload_json'])
    print('verification'+str(index)+'='+safe(json.dumps({
        'attemptId':row['attempt_id'],'passed':payload.get('passed'),
        'changedFiles':payload.get('workspace',{}).get('changedFiles'),
        'commands':payload.get('commands')},ensure_ascii=False),1000))
print('PDS_M5_ACCEPT_DIAG_END')
con.close()
PY
