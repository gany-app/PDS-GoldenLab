#!/usr/bin/env bash
# Read-only preflight for the isolated PDS Model Gateway and LibreChat wiring.
# Prints paths, hashes and environment variable names only; never prints secret values.
set -euo pipefail
umask 077

CANDIDATE_UNIT=pds-bridge-v01-m5-stage.service
LEGACY_UNIT=pds-bridge-v003-mcp.service
GATEWAY_PORT=4001

fail() { printf 'PDS_M7_GATEWAY_AUDIT_FAILED: %s\n' "$1" >&2; exit 1; }

[[ $(id -u) -eq 0 ]] || fail 'run with sudo'
for command_name in docker systemctl python3 ss df awk sha256sum mktemp rm; do
  command -v "$command_name" >/dev/null || fail "missing $command_name"
done
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose plugin is unavailable'
systemctl is-active --quiet "$CANDIDATE_UNIT" || fail 'M6 candidate service is not active'
systemctl is-active --quiet "$LEGACY_UNIT" || fail 'v0.03 service is not active'

mapfile -t LIBRECHAT_IDS < <(docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | \
  awk 'tolower($0) ~ /librechat/ {print $1}')
[[ ${#LIBRECHAT_IDS[@]} -eq 1 ]] || fail "expected one running LibreChat container; found ${#LIBRECHAT_IDS[@]}"
LIBRECHAT_ID="${LIBRECHAT_IDS[0]}"
INSPECT_FILE="$(mktemp /tmp/pds-m7-librechat-inspect-XXXXXXXX.json)"
trap 'rm -f -- "$INSPECT_FILE"' EXIT
docker inspect "$LIBRECHAT_ID" >"$INSPECT_FILE"

PORT_STATUS=free
if ss -H -ltn | awk -v port=":$GATEWAY_PORT" '$4 ~ port"$" {found=1} END {exit !found}'; then
  PORT_STATUS=in-use
fi

DOCKER_VERSION="$(docker version --format '{{.Server.Version}}')"
COMPOSE_VERSION="$(docker compose version --short)"
MEM_AVAILABLE_KIB="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
ROOT_AVAILABLE_KIB="$(df -Pk / | awk 'NR==2 {print $4}')"

printf 'PDS_M7_GATEWAY_AUDIT_BEGIN\n'
printf 'docker.version=%s\ncompose.version=%s\n' "$DOCKER_VERSION" "$COMPOSE_VERSION"
printf 'host.memoryAvailableKiB=%s\nhost.rootAvailableKiB=%s\n' "$MEM_AVAILABLE_KIB" "$ROOT_AVAILABLE_KIB"
printf 'gateway.port=%s\ngateway.portStatus=%s\n' "$GATEWAY_PORT" "$PORT_STATUS"

python3 - "$INSPECT_FILE" <<'PY'
import hashlib, json, os, pathlib, re, sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())[0]
config = data.get("Config") or {}
state = data.get("State") or {}
labels = config.get("Labels") or {}
networks = sorted((data.get("NetworkSettings") or {}).get("Networks", {}).keys())
mounts = data.get("Mounts") or []

print("librechat.container=" + str(data.get("Name", "")).lstrip("/"))
print("librechat.image=" + str(config.get("Image", "unknown")))
print("librechat.status=" + str(state.get("Status", "unknown")))
print("librechat.networks=" + (",".join(networks) if networks else "NONE"))
print("librechat.composeProject=" + str(labels.get("com.docker.compose.project", "NONE")))
print("librechat.composeWorkingDir=" + str(labels.get("com.docker.compose.project.working_dir", "NONE")))
print("librechat.composeConfigFiles=" + str(labels.get("com.docker.compose.project.config_files", "NONE")))

yaml_mounts = []
for mount in mounts:
    source = str(mount.get("Source", ""))
    destination = str(mount.get("Destination", ""))
    if destination.endswith(("librechat.yaml", "librechat.yml")) or source.endswith(("librechat.yaml", "librechat.yml")):
        yaml_mounts.append((source, destination))
if not yaml_mounts:
    print("librechat.yamlMount=NONE")
    workdir = pathlib.Path(str(labels.get("com.docker.compose.project.working_dir", "")))
    candidates = [workdir / "librechat.yaml", workdir / "librechat.yml"]
    candidate = next((path for path in candidates if path.is_file()), None)
    if candidate:
        print(f"librechat.yamlCandidate.source={candidate}")
        print(f"librechat.yamlCandidate.sha256={hashlib.sha256(candidate.read_bytes()).hexdigest()}")
else:
    for index, (source, destination) in enumerate(yaml_mounts, 1):
        print(f"librechat.yamlMount{index}.source={source}")
        print(f"librechat.yamlMount{index}.destination={destination}")
        path = pathlib.Path(source)
        if path.is_file():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            print(f"librechat.yamlMount{index}.sha256={digest}")

secretish = re.compile(r"(?:API|KEY|TOKEN|SECRET|PASSWORD|ENDPOINT|BASE_URL|BASEURL)", re.I)
names = []
for item in config.get("Env") or []:
    name = item.split("=", 1)[0]
    if secretish.search(name):
        names.append(name)
print("librechat.sensitiveEnvNames=" + (",".join(sorted(set(names))) if names else "NONE"))
PY

if docker ps -a --format '{{.Names}}' | awk 'tolower($0) ~ /pds.*model.*gateway|litellm/ {found=1} END {exit !found}'; then
  printf 'gateway.existingContainer=FOUND\n'
else
  printf 'gateway.existingContainer=NONE\n'
fi
printf 'candidateService=active\nv003Service=active\nchanges=NONE\n'
printf 'PDS_M7_GATEWAY_AUDIT_END\n'
