#!/usr/bin/env bash
# 在 Ubuntu 22.04 ARM64 开发板（RK3576）上离线安装 drone_interceptor 的 IMM-UKF 节点。
# 不编译、不联网；安装后服务立即运行并开机自启，进程绑定 CPU 4-7。
set -euo pipefail
export LC_ALL=C

bundle_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
service_name=drone-interceptor
check_only=false

case "${1:-}" in
    --check) check_only=true ;;
    --help|-h)
        echo "用法：sudo bash install.sh [--check]"
        echo "默认安装、启动并启用开机自启；--check 仅检查，不修改系统。"
        exit 0 ;;
    "") ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "参数过多" >&2; exit 2; }

fail() { echo "错误：$*" >&2; exit 1; }

for cmd in sha256sum ldd uname getconf find sort cp mv install ln readlink mktemp systemctl \
           taskset cat cmp chown chmod mkdir rm sleep; do
    command -v "$cmd" >/dev/null || fail "缺少系统基础命令：$cmd"
done

# ---------- 环境检查 ----------
[[ "$(uname -m)" == aarch64 ]] || fail "仅支持 aarch64（ARM64）开发板。"
[[ -r /etc/os-release ]] || fail "无法识别操作系统。"
source /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 22.04 ]] || fail "仅支持 Ubuntu 22.04。"
[[ "$(getconf GNU_LIBC_VERSION)" == 'glibc 2.35' ]] || fail "需要 Ubuntu 22.04 的 glibc 2.35。"
[[ -f /opt/ros/humble/lib/librclcpp.so && -f /opt/ros/humble/lib/librmw_fastrtps_cpp.so ]] \
    || fail "请先安装与生产环境相同的 ROS 2 Humble 运行库（含 Fast DDS）。"
for pkg in nav_msgs sensor_msgs std_msgs geometry_msgs; do
    [[ -d "/opt/ros/humble/share/$pkg" ]] || fail "预装 ROS 缺少消息包：$pkg。"
done
[[ -e /lib/ld-linux-aarch64.so.1 ]] || fail "缺少 ARM64 系统动态加载器。"

# CPU 绑核目标必须真实存在，否则服务会在启动时被 systemd 拒绝。
cpu_list_default=4-7
online_cpus="$(cat /sys/devices/system/cpu/online 2>/dev/null || echo '')"
[[ -n "$online_cpus" ]] || fail "无法读取在线 CPU 列表。"
for core in 4 5 6 7; do
    [[ -d "/sys/devices/system/cpu/cpu$core" ]] || fail "开发板缺少 CPU$core，无法绑定 4-7。"
done
taskset -c "$cpu_list_default" true 2>/dev/null || fail "内核不允许绑定 CPU $cpu_list_default。"

# ---------- 包完整性与依赖检查 ----------
[[ -r "$bundle_dir/SHA256SUMS" ]] || fail "部署包缺少 SHA256SUMS。"
(cd "$bundle_dir" && sha256sum --check --strict --quiet SHA256SUMS) || fail "部署包校验失败。"

version="$(cat "$bundle_dir/VERSION")"
[[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]+$ ]] || fail "无效版本号。"
[[ -x "$bundle_dir/bin/interceptor_node_relative_imm_ukf" ]] || fail "缺少可执行程序。"
[[ -r "$bundle_dir/config/relative_imm_ukf_params.yaml" ]] || fail "缺少参数文件。"
[[ -r "$bundle_dir/config/runtime.env" ]] || fail "Missing runtime environment file."
[[ -f "$bundle_dir/runtime/lib/libvision_msgs__rosidl_typesupport_cpp.so" ]] \
    || fail "部署包缺少 vision_msgs 运行时库。"

# 同时检查随包携带的消息库，不能只检查主程序直接链接的库。
while IFS= read -r binary; do
    if ! output="$(LD_LIBRARY_PATH="$bundle_dir/runtime/lib:/opt/ros/humble/lib:/opt/ros/humble/lib/aarch64-linux-gnu" ldd "$binary" 2>&1)"; then
        fail "依赖检查失败：$binary：$output"
    fi
    if [[ "$output" == *'not found'* ]]; then
        fail "缺少动态库：$binary：$output"
    fi
done < <(find "$bundle_dir/bin" "$bundle_dir/runtime/lib" -type f | sort)

echo "通过：系统、文件校验、CPU 4-7 与二进制依赖检查（$version）。"
$check_only && exit 0

# ---------- 安装 ----------
[[ "$EUID" -eq 0 ]] || fail "请使用 sudo bash install.sh。"
[[ -d /run/systemd/system ]] || fail "目标系统须以 systemd 运行。"

base=/opt/drone_interceptor-binary
config_dir=/etc/drone_interceptor
unit="/etc/systemd/system/$service_name.service"

[[ ! -e "$base/current" || -L "$base/current" ]] || fail "$base/current 已存在且不是符号链接。"

mkdir -p "$config_dir" "$base/releases"
backup="$(mktemp -d "/var/tmp/$service_name-backup.XXXXXX")"
mkdir -p "$backup/config"
for config_file in relative_imm_ukf_params.yaml runtime.env; do
    if [[ -e "$config_dir/$config_file" || -L "$config_dir/$config_file" ]]; then
        [[ ! -d "$config_dir/$config_file" ]] || fail "Configuration path is a directory: $config_dir/$config_file"
        cp -a "$config_dir/$config_file" "$backup/config/$config_file"
    fi
done
old_link="$(readlink "$base/current" 2>/dev/null || true)"
old_active=false
old_enabled=false
systemctl is-active --quiet "$service_name" && old_active=true
systemctl is-enabled --quiet "$service_name" 2>/dev/null && old_enabled=true
if [[ -e "$unit" || -L "$unit" ]]; then
    cp -a "$unit" "$backup/$service_name.service"
fi

changed_service=false
changed_config=false
stage=""
rollback() {
    local status=$?
    trap - EXIT
    if [[ "$status" -ne 0 ]]; then
        echo "Deployment failed; restoring the previous service and runtime configuration. Backup: $backup" >&2
        if $changed_service; then
            systemctl stop "$service_name" || true
            systemctl disable "$service_name" >/dev/null 2>&1 || true
            rm -f "$unit"
            if [[ -e "$backup/$service_name.service" || -L "$backup/$service_name.service" ]]; then
                cp -a "$backup/$service_name.service" "$unit"
            fi
            rm -f "$base/current"
            if [[ -n "$old_link" ]]; then
                ln -s "$old_link" "$base/current"
            fi
        fi
        # Restore runtime files before restarting the previous release.
        if $changed_config; then
            for config_file in relative_imm_ukf_params.yaml runtime.env; do
                rm -f "$config_dir/$config_file"
                if [[ -e "$backup/config/$config_file" || -L "$backup/config/$config_file" ]]; then
                    cp -a "$backup/config/$config_file" "$config_dir/$config_file"
                fi
            done
        fi
        if $changed_service; then
            systemctl daemon-reload || true
            if $old_enabled; then systemctl enable "$service_name" || true; fi
            if $old_active; then systemctl start "$service_name" || true; fi
        fi
    fi
    if [[ -n "$stage" && -d "$stage" ]]; then rm -rf -- "$stage"; fi
    exit "$status"
}
trap rollback EXIT

release="$base/releases/$version"
if [[ -e "$release" ]]; then
    cmp -s "$bundle_dir/SHA256SUMS" "$release/SHA256SUMS" || fail "同名版本内容不同，拒绝覆盖：$release"
    (cd "$release" && sha256sum --check --strict --quiet SHA256SUMS) || fail "已安装版本校验失败。"
else
    stage="$(mktemp -d "$base/releases/.stage.XXXXXX")"
    cp -a "$bundle_dir/." "$stage/"
    chown -R root:root "$stage"
    chmod -R a+rX "$stage"
    (cd "$stage" && sha256sum --check --strict --quiet SHA256SUMS)
    mv "$stage" "$release"
    stage=""
fi

changed_service=true
# 换版前停旧进程，避免两个实例同时发布 /fpv/control_command。
if $old_active; then
    systemctl stop "$service_name"
else
    systemctl stop "$service_name" 2>/dev/null || true
fi
# Every installation replaces both runtime files with the validated package copies.
changed_config=true
install -m 0644 "$release/config/relative_imm_ukf_params.yaml" "$config_dir/relative_imm_ukf_params.yaml"
install -m 0644 "$release/config/runtime.env" "$config_dir/runtime.env"
ln -s "releases/$version" "$base/.current.$$"
mv -Tf "$base/.current.$$" "$base/current"
install -m 0644 "$release/$service_name.service" "$unit"
systemctl daemon-reload
systemctl reset-failed "$service_name" 2>/dev/null || true
systemctl enable "$service_name"
systemctl start "$service_name"
sleep 5

systemctl is-active --quiet "$service_name" || fail "服务未能持续运行，请查看 journalctl -u $service_name。"
[[ "$(systemctl show "$service_name" -p NRestarts --value)" == 0 ]] || fail "服务启动后发生重启，请检查日志。"
systemctl is-enabled --quiet "$service_name" || fail "开机自启未启用。"

# 核验实际亲和力，绑核失败等同部署失败。
main_pid="$(systemctl show "$service_name" -p MainPID --value)"
[[ "$main_pid" =~ ^[0-9]+$ && "$main_pid" -gt 0 ]] || fail "无法获取服务主进程 PID。"
affinity="$(taskset -pc "$main_pid" | awk -F': ' '{print $NF}')"
[[ "$affinity" == "4-7" ]] || fail "CPU 绑定不正确：期望 4-7，实际 $affinity。"

echo "部署成功：$release"
echo "服务已运行并启用开机自启；CPU 亲和力：$affinity"
echo "状态：systemctl status $service_name；日志：journalctl -u $service_name -f"
echo "参数：$config_dir/relative_imm_ukf_params.yaml；运行开关：$config_dir/runtime.env"
echo "Service and runtime configuration backup: $backup"
echo "请按 README.md 用真实话题数据核验；进程存活不等于功能验收通过。"
