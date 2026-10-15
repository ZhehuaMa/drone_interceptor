#!/usr/bin/env bash
# Internal container entry point; called by run_scenario.sh.
set -eo pipefail
source /opt/ros/humble/setup.bash
scenario=${1:?scenario required}
shift
run="/out/${INTERCEPTOR_RUN_NAME:?run directory required}"
workspace="/out/${INTERCEPTOR_WORKSPACE:?workspace required}"
export ROS_LOG_DIR="$run/roslogs" OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
export CMAKE_BUILD_PARALLEL_LEVEL=4 PYTHONDONTWRITEBYTECODE=1
mkdir -p "$workspace" "$run/stage/prototype" "$run/stage/config"
cd "$workspace"
colcon --log-base "$workspace/log" build \
    --base-paths /src/quadrotor_msgs /src/drone_interceptor \
    --packages-select quadrotor_msgs drone_interceptor --executor sequential \
    --build-base "$workspace/build" --install-base "$workspace/install" \
    --cmake-args -DCMAKE_BUILD_TYPE=Release 2>&1 | tee "$run/build.log"
source "$workspace/install/setup.bash"
cp /src/drone_interceptor/prototype/ros2_sim_node.py "$run/stage/prototype/"
cp /src/drone_interceptor/config/relative_imm_ukf_params.yaml "$run/stage/config/"
launch_arguments=(use_simulation:=true)
case "$scenario" in
    radar*) launch_arguments+=(use_radar:=true) ;;
    *) launch_arguments+=(use_radar:=false) ;;
esac
while [[ $# -gt 0 && "$1" == *:=* ]]; do
    launch_arguments+=("$1")
    shift
done
node_pid=
cleanup() {
    [[ -n "$node_pid" ]] || return 0
    kill -INT -- "-$node_pid" 2>/dev/null || true
    for ((attempt=0; attempt<20; attempt++)); do
        kill -0 -- "-$node_pid" 2>/dev/null || break
        sleep 0.25
    done
    kill -KILL -- "-$node_pid" 2>/dev/null || true
    wait "$node_pid" 2>/dev/null || true
    node_pid=
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
setsid ros2 launch drone_interceptor launch_relative_imm_ukf.py \
    "${launch_arguments[@]}" > "$run/node.log" 2>&1 &
node_pid=$!
sleep 3
set +e
timeout --signal=TERM --kill-after=5s 90 \
    python3 "$run/stage/prototype/ros2_sim_node.py" --scenario "$scenario" "$@" \
    > "$run/simulator.log" 2>&1
sim_result=$?
set -e
node_alive=true
kill -0 -- "-$node_pid" 2>/dev/null || node_alive=false
cleanup
if [[ "$sim_result" -ne 0 ]]; then
    printf 'Simulator failed with exit %s; inspect %s/simulator.log\n' "$sim_result" "$run" >&2
    exit "$sim_result"
fi
if ! "$node_alive"; then
    printf 'ROS launch group exited before the simulator completed; inspect %s/node.log\n' "$run" >&2
    exit 1
fi
# A zero simulator process status alone does not establish interception.
python3 - "$run/stage/prototype" <<'PY'
from pathlib import Path
import sys

summaries = list(Path(sys.argv[1]).glob('ros2_sim_*_summary.txt'))
if len(summaries) != 1:
    raise SystemExit('Expected exactly one fresh scenario summary')
text = summaries[0].read_text()
print(text, end='')
fields = dict(line.split(': ', 1) for line in text.splitlines() if ': ' in line)
if fields.get('Intercepted') != 'True' or fields.get('NaN commands') != '0':
    raise SystemExit('Scenario failed: requires Intercepted=True and NaN commands=0')
PY
