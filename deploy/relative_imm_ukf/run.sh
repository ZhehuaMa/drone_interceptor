#!/usr/bin/env bash
# 二进制启动器：使用板上预装的 ROS 2 Humble，不依赖源码工作区环境。
# 进程被绑定到 CPU_LIST（默认 4-7，即已 isolcpus 隔离的 Cortex-A72 大核）。
set -euo pipefail
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
env_file="${DI_ENV_FILE:-/etc/drone_interceptor/runtime.env}"
if [[ -f "$env_file" ]]; then
    set -a
    # 此文件由 root 管理，使用 Bash 的 KEY=value 格式。
    source "$env_file"
    set +a
fi

export LD_LIBRARY_PATH="$release_dir/runtime/lib:/opt/ros/humble/lib:/opt/ros/humble/lib/aarch64-linux-gnu"
export AMENT_PREFIX_PATH="$release_dir/runtime:/opt/ros/humble"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}"
export ROS_DISTRO=humble
export ROS_VERSION=2
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
export ROS_LOG_DIR="${ROS_LOG_DIR:-/var/log/drone_interceptor}"

config="${DI_CONFIG:-/etc/drone_interceptor/relative_imm_ukf_params.yaml}"
[[ -r "$config" ]] || { echo "无法读取参数文件：$config" >&2; exit 1; }

cpu_list="${CPU_LIST:-4-7}"
command -v taskset >/dev/null || { echo "缺少 taskset（util-linux）。" >&2; exit 1; }

# launch_relative_imm_ukf.py 的三个启动参数在此以环境变量覆盖，语义完全一致。
exec taskset -c "$cpu_list" "$release_dir/bin/interceptor_node_relative_imm_ukf" \
    --ros-args \
    -r __node:=interceptor_node_relative_imm_ukf \
    --params-file "$config" \
    -p "use_simulation:=${USE_SIMULATION:-false}" \
    -p "radar.enable:=${USE_RADAR:-false}" \
    -p "radar.reintercept_enable:=${RADAR_REINTERCEPT:-false}" \
    --log-level "${LOG_LEVEL:-INFO}" \
    "$@"
