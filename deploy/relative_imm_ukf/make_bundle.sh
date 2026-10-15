#!/usr/bin/env bash
# Package existing ARM64 output; compilation may use the x86_64 cross compiler.
# This collector still needs an ARM execution environment (uname/ldd below).
# It collects and validates files; it does not compile them.
set -euo pipefail
export LC_ALL=C

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
install_dir=""
quadrotor_prefix=""
ros_prefix="/opt/ros/humble"
out_dir="$PWD"
version=""

usage() {
    cat <<'EOF'
用法：bash make_bundle.sh --install-dir <colcon install 根目录> \
                         --quadrotor-prefix <quadrotor_msgs 安装前缀> \
                         [--ros-prefix <ROS 2 安装前缀>] \
                         [--out <输出目录>] [--version <版本号>]

示例：
  bash make_bundle.sh \
    --install-dir /root/di_stage/install \
    --quadrotor-prefix /home/hzhy/workspace/fpv_ws/install/quadrotor_msgs \
    --ros-prefix /opt/ros/humble \
    --out /root
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) install_dir="${2:?}"; shift 2 ;;
        --quadrotor-prefix) quadrotor_prefix="${2:?}"; shift 2 ;;
        --ros-prefix) ros_prefix="${2:?}"; shift 2 ;;
        --out) out_dir="${2:?}"; shift 2 ;;
        --version) version="${2:?}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
done

fail() { echo "错误：$*" >&2; exit 1; }
[[ -n "$install_dir" ]] || { usage >&2; fail "缺少 --install-dir。"; }
[[ -n "$quadrotor_prefix" ]] || { usage >&2; fail "缺少 --quadrotor-prefix。"; }

binary="$install_dir/drone_interceptor/lib/drone_interceptor/interceptor_node_relative_imm_ukf"
share_dir="$install_dir/drone_interceptor/share/drone_interceptor"
[[ -x "$binary" ]] || fail "找不到可执行程序：$binary"
[[ -d "$share_dir/config" ]] || fail "找不到参数目录：$share_dir/config"
[[ -d "$quadrotor_prefix/lib" ]] || fail "找不到 quadrotor_msgs 库目录：$quadrotor_prefix/lib"
[[ -d "$ros_prefix/lib" ]] || fail "找不到 ROS 运行库目录：$ros_prefix/lib"
[[ "$(uname -m)" == aarch64 ]] || fail "请在 aarch64 开发板上运行本脚本（需校验二进制依赖）。"

binary_sha="$(sha256sum "$binary" | cut -d' ' -f1)"
if [[ -z "$version" ]]; then
    version="$(date +%Y%m%d)-${binary_sha:0:12}-ros-preinstalled"
fi
name="drone_interceptor-ubuntu22.04-arm64-$version"
work="$(mktemp -d /var/tmp/di-bundle.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
bundle="$work/$name"

mkdir -p "$bundle"/{bin,config,runtime/lib,runtime/share/drone_interceptor,licenses}

install -m 0755 "$binary" "$bundle/bin/interceptor_node_relative_imm_ukf"
install -m 0644 "$share_dir/config/relative_imm_ukf_params.yaml" "$bundle/config/relative_imm_ukf_params.yaml"
install -m 0644 "$script_dir/runtime.env" "$bundle/config/runtime.env"
install -m 0755 "$script_dir/run.sh" "$bundle/run.sh"
install -m 0755 "$script_dir/install.sh" "$bundle/install.sh"
install -m 0644 "$script_dir/drone-interceptor.service" "$bundle/drone-interceptor.service"
install -m 0644 "$script_dir/README.md" "$bundle/README.md"
# 保留 launch 文件作为参数语义参考，运行时不使用（服务直接起二进制）。
if [[ -f "$share_dir/launch/launch_relative_imm_ukf.py" ]]; then
    install -D -m 0644 "$share_dir/launch/launch_relative_imm_ukf.py" \
        "$bundle/reference/launch_relative_imm_ukf.py"
fi

install -m 0644 "$share_dir/package.xml" "$bundle/runtime/share/drone_interceptor/package.xml"
mkdir -p "$bundle/runtime/share/ament_index/resource_index/packages"
: > "$bundle/runtime/share/ament_index/resource_index/packages/drone_interceptor"

copy_rosidl_package() {
    local pkg="$1"
    local prefix="$2"
    [[ -d "$prefix/share/$pkg" ]] || fail "找不到 $pkg share 目录：$prefix/share/$pkg"
    mkdir -p "$bundle/runtime/share/$pkg"
    install -m 0644 "$prefix/share/$pkg/package.xml" "$bundle/runtime/share/$pkg/package.xml"
    for subdir in msg srv action; do
        if [[ -d "$prefix/share/$pkg/$subdir" ]]; then
            mkdir -p "$bundle/runtime/share/$pkg/$subdir"
            cp -a "$prefix/share/$pkg/$subdir/." "$bundle/runtime/share/$pkg/$subdir/"
        fi
    done
    for lib in "$prefix"/lib/lib"$pkg"__rosidl_*.so; do
        [[ -f "$lib" ]] || fail "缺少 $pkg 运行时库：$prefix/lib/lib${pkg}__rosidl_*.so"
        install -m 0644 "$lib" "$bundle/runtime/lib/"
    done
    : > "$bundle/runtime/share/ament_index/resource_index/packages/$pkg"
    if [[ -f "$prefix/share/ament_index/resource_index/rosidl_interfaces/$pkg" ]]; then
        install -D -m 0644 "$prefix/share/ament_index/resource_index/rosidl_interfaces/$pkg" \
            "$bundle/runtime/share/ament_index/resource_index/rosidl_interfaces/$pkg"
    fi
}

# 自定义消息包和新板可能缺失的视觉消息包都随包携带。
copy_rosidl_package quadrotor_msgs "$quadrotor_prefix"
copy_rosidl_package vision_msgs "$ros_prefix"

cat > "$bundle/VERSION" <<EOF
$version
EOF

cat > "$bundle/licenses/README.txt" <<'EOF'
drone_interceptor：Apache-2.0（见源码仓库 package.xml）。
quadrotor_msgs 运行时库来自生产板已验收的构建，版权归原作者。
vision_msgs 运行时文件来自 ROS 2 Humble 发行包，用于支持未预装 vision_msgs 的新板。
ROS 2 Humble 核心运行库由开发板系统预装，未随包分发。
EOF

cat > "$bundle/manifest.json" <<EOF
{
  "package": "drone_interceptor",
  "entrypoint": "launch/launch_relative_imm_ukf.py 的等价二进制启动",
  "node": "interceptor_node_relative_imm_ukf",
  "release": "$version",
  "architecture": "aarch64",
  "os": "Ubuntu 22.04",
  "glibc": "2.35",
  "binary_sha256": "$binary_sha",
  "cpu_affinity": "4-7",
  "ros_runtime_included": false,
  "required_ros_prefix": "/opt/ros/humble",
  "bundled_rosidl_packages": [
    "quadrotor_msgs",
    "vision_msgs"
  ],
  "install_prefix": "/opt/drone_interceptor-binary",
  "config_dir": "/etc/drone_interceptor",
  "systemd_unit": "drone-interceptor.service"
}
EOF

(cd "$bundle" && find . -type f ! -name SHA256SUMS -printf '%P\0' | sort -z \
    | xargs -0 sha256sum > SHA256SUMS)
(cd "$bundle" && sha256sum --check --strict --quiet SHA256SUMS) || fail "自校验失败。"

# 依赖自检：主程序与随包库都必须能在目标环境解析。
while IFS= read -r f; do
    out="$(LD_LIBRARY_PATH="$bundle/runtime/lib:/opt/ros/humble/lib:/opt/ros/humble/lib/aarch64-linux-gnu" ldd "$f" 2>&1)" \
        || fail "依赖检查失败：$f"
    [[ "$out" != *'not found'* ]] || fail "缺少动态库：$f\n$out"
done < <(find "$bundle/bin" "$bundle/runtime/lib" -type f | sort)

mkdir -p "$out_dir"
tarball="$out_dir/$name.tar.gz"
tar -C "$work" --owner=0 --group=0 -czf "$tarball" "$name"
sha256sum "$tarball" > "$tarball.sha256"

echo "部署包：$tarball"
echo "校验文件：$tarball.sha256"
echo "解包后执行：sudo bash $name/install.sh"
