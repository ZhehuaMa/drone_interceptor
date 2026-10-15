#!/usr/bin/env bash
# Build and test the real ROS node in an isolated development container.
set -eo pipefail
usage() {
    cat <<'HELP'
Usage: run_scenario.sh [OPTIONS] SCENARIO [launch_arg:=value ...] [simulator arguments ...]
  --backend amd64|arm64   Container architecture (default: amd64).
  --image IMAGE          Override the matching development image.
  --artifacts-dir PATH   External build and result directory.
  --help                 Show this help.
The amd64 backend builds native x86_64 simulation binaries.
The arm64 fallback builds ARM64 binaries and uses host emulation when needed.
A pass requires Intercepted=True and NaN commands=0, plus process success.
Sources are read-only. Results and build caches are outside the repositories.
HELP
}
backend=amd64
image=
artifacts=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backend|--image|--artifacts-dir)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
            case "$1" in
                --backend) backend=$2 ;;
                --image) image=$2 ;;
                --artifacts-dir) artifacts=$2 ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        --*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done
case "$backend" in
    amd64|arm64) ;;
    *) printf 'Unsupported backend: %s\n' "$backend" >&2; exit 2 ;;
esac
[[ $# -gt 0 && "$1" =~ ^[a-z][a-z0-9_]*$ ]] || { usage >&2; exit 2; }
scenario=$1
shift
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
messages=$(cd -- "$repo/../quadrotor_msgs" && pwd)
[[ -f "$messages/package.xml" ]] || { printf 'Missing adjacent quadrotor_msgs source\n' >&2; exit 1; }
image=${image:-drone-tracker-rk3576:humble-${backend}-rknn2.3.2}
artifacts=${artifacts:-${TMPDIR:-/tmp}/nickluo-interceptor-scenarios}
artifacts=$(realpath -m -- "$artifacts")
workspace=$(dirname -- "$repo")
case "$artifacts/" in
    "$workspace/"*) printf 'Artifacts must be outside the source workspace\n' >&2; exit 2 ;;
esac
mkdir -p -- "$artifacts/$backend"
metadata=$(docker image inspect "$image" --format '{{.Id}} {{.Os}}/{{.Architecture}}')
read -r image_id actual <<< "$metadata"
[[ "$actual" == "linux/$backend" ]] || {
    printf 'Image architecture %s does not match requested linux/%s\n' "$actual" "$backend" >&2
    exit 1
}
# Shared backend workspace cannot be built or used by concurrent scenarios.
exec 9>"$artifacts/$backend/.scenario.lock"
flock -n 9 || { printf 'Another %s scenario is using %s\n' "$backend" "$artifacts" >&2; exit 1; }
run=$(mktemp -d "$artifacts/$backend/${scenario}-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
run_name=${run##*/}
container_name="nickluo-interceptor-$backend-$run_name"
printf 'Backend: %s; image: %s (%s); results: %s\n' "$backend" "$image" "$image_id" "$run"
trap 'docker stop --time 5 "$container_name" >/dev/null 2>&1 || true; exit 130' INT
trap 'docker stop --time 5 "$container_name" >/dev/null 2>&1 || true; exit 143' TERM
set +e
docker run --rm --name "$container_name" --platform "linux/$backend" --network none \
    --mount "type=bind,src=$repo,dst=/src/drone_interceptor,readonly" \
    --mount "type=bind,src=$messages,dst=/src/quadrotor_msgs,readonly" \
    --mount "type=bind,src=$artifacts/$backend,dst=/out" \
    --env "INTERCEPTOR_RUN_NAME=$run_name" \
    --env "INTERCEPTOR_WORKSPACE=ws-${image_id#sha256:}" \
    --env "ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-137}" --env ROS_LOCALHOST_ONLY=1 \
    "$image_id" bash /src/drone_interceptor/prototype/run_scenario_in_container.sh \
    "$scenario" "$@" 2>&1 | tee "$run/console.log"
result=${PIPESTATUS[0]}
printf '%s\n' "$result" > "$run/exit-code"
exit "$result"
