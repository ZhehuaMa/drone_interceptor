# drone_interceptor IMM-UKF 节点 · 开发板部署包

目标平台：RK3576 开发板，Ubuntu 22.04 ARM64，PREEMPT_RT 内核，已预装 ROS 2 Humble。
部署内容：节点 `interceptor_node_relative_imm_ukf` 的预编译二进制。systemd 服务通过 `run.sh`
直接启动该二进制，运行开关与 `launch/launch_relative_imm_ukf.py` 对应。服务开机自启，进程绑定 **CPU 4-7**（内核 `isolcpus=4-7`
隔离出来的 Cortex-A72 大核）。

包内不含 ROS 2 核心运行库，只随包携带 `quadrotor_msgs` 和 `vision_msgs` 的运行时库。
这样新板即使没有安装 `ros-humble-vision-msgs`，也能运行检测框订阅。

## 安装

```bash
tar xzf drone_interceptor-ubuntu22.04-arm64-<版本>.tar.gz
cd drone_interceptor-ubuntu22.04-arm64-<版本>

sudo bash install.sh --check   # 只做环境与完整性检查，不改系统
sudo bash install.sh           # 安装 + 启动 + 开机自启 + 校验绑核
```

Every installation or upgrade replaces both
`/etc/drone_interceptor/relative_imm_ukf_params.yaml` and
`/etc/drone_interceptor/runtime.env` with the package copies. This also replaces
local tuning and runtime switches; files are not merged. For example, a local
`USE_RADAR=true` is replaced by the packaged `USE_RADAR` value.

The installer backs up existing files under
`/var/tmp/drone-interceptor-backup.<suffix>/config/` and prints that backup
directory. It stops the previous service before replacing configuration. If
deployment fails, it restores the previous files before restarting the previous
release. Files absent before installation are removed during rollback.

安装成功的判据（脚本内部已逐条断言，任一条不满足即回滚）：

- 服务处于 active 且 `NRestarts == 0`（启动后 5 秒内没有崩溃重启）
- `systemctl is-enabled drone-interceptor` 为 enabled（上电自启）
- 主进程 `taskset -pc <PID>` 输出为 `4-7`

## 安装后的文件布局

| 路径 | 说明 |
|------|------|
| `/opt/drone_interceptor-binary/releases/<版本>/` | 本次发布的只读内容 |
| `/opt/drone_interceptor-binary/current` | 指向当前发布的符号链接，服务只读它 |
| `/etc/drone_interceptor/relative_imm_ukf_params.yaml` | Runtime parameters; replaced with the package copy on every installation or upgrade |
| `/etc/drone_interceptor/runtime.env` | Runtime switches (CPU affinity, simulation/radar, logging); replaced with the package copy on every installation or upgrade |
| `/etc/systemd/system/drone-interceptor.service` | 服务单元 |
| `/var/log/drone_interceptor/` | ROS 日志目录 |

## 运行开关（`/etc/drone_interceptor/runtime.env`）

对应 launch 文件的启动参数，改完执行 `sudo systemctl restart drone-interceptor`：

| 变量 | 默认 | 对应 launch 参数 |
|------|------|------------------|
| `CPU_LIST` | `4-7` | —（绑核列表，taskset 语法） |
| `USE_SIMULATION` | `false` | `use_simulation` |
| `USE_RADAR` | `false` | `use_radar`（`radar.enable`） |
| `RADAR_REINTERCEPT` | `false` | `radar_reintercept_enable` |
| `ROS_DOMAIN_ID` | `0` | — |
| `LOG_LEVEL` | `INFO` | `--log-level` |
| `DI_CONFIG` | `/etc/drone_interceptor/relative_imm_ukf_params.yaml` | 参数文件路径 |

真实飞行必须确认 `USE_SIMULATION=false`；雷达中继默认关闭，需要中制导时才置 `USE_RADAR=true`
（同时要有 `/fpv/radar/target`、`/fpv/radar/interceptor` 的发布者）。

## 常用运维命令

```bash
systemctl status drone-interceptor
journalctl -u drone-interceptor -f
taskset -pc "$(systemctl show drone-interceptor -p MainPID --value)"   # 期望 4-7
sudo systemctl restart drone-interceptor
sudo systemctl disable --now drone-interceptor                          # 停止并取消自启
```

话题自检（需先 `source /opt/ros/humble/setup.bash`）：

```bash
ros2 node list | grep interceptor_node_relative_imm_ukf
ros2 topic hz /fpv/control_command       # 启动任务后，结合 IMU 与有效视觉或雷达输入检查控制输出
```

以下话题名以随包参数文件 `relative_imm_ukf_params.yaml` 为准；常规话题可通过 `topics.*` 修改，
雷达话题可通过 `radar.topic_target` 和 `radar.topic_interceptor` 修改，修改后需重启节点。

| 方向 | 话题 | 消息类型 | 用途 |
|------|------|----------|------|
| 订阅 | `/mavros/imu/data` | `sensor_msgs/msg/Imu` | 机体姿态、加速度和角速度 |
| 订阅 | `/fpv/target_bbox` | `vision_msgs/msg/Detection2D` | 视觉目标检测框 |
| 订阅 | `/fpv/gimbal` | `sensor_msgs/msg/Imu` | 相机到世界的姿态；`camera.use_gimbal=true` 时使用 |
| 订阅 | `/fpv/tracker_trigger` | `std_msgs/msg/Header` | `frame_id=MISSION` 启动任务；`OFF` 或 `DISMISS` 停止任务 |
| 订阅 | `/fpv/mission_start` | `std_msgs/msg/Bool` | 仿真用任务触发；`true` 启动，`false` 停止 |
| 订阅（仅启用雷达时） | `/fpv/radar/target` | `nav_msgs/msg/Odometry` | 雷达目标位置和速度 |
| 订阅（仅启用雷达时） | `/fpv/radar/interceptor` | `nav_msgs/msg/Odometry` | 雷达拦截机位置和速度 |
| 发布 | `/fpv/control_command` | `quadrotor_msgs/msg/ControlCommand` | 控制指令 |
| 发布 | `/fpv/mission_state` | `std_msgs/msg/Bool` | 任务是否活动 |

节点不再订阅 `/fpv/odom`。本机运动由 IMU 积分估计；可选雷达使用上表中的两路独立航迹。
直接运行二进制且未加载参数文件时，`topics.mission` 默认值为 `/fpv/mission_launch`；
部署包加载的参数文件将其设为 `/fpv/mission_start`。

**进程存活 ≠ 功能验收。** 必须用真实 IMU、检测框和云台姿态输入，并触发任务，确认
`/fpv/mission_state` 变化与 `/fpv/control_command` 输出合理。启用雷达时，还需验证两路雷达航迹及视觉接管。

## 回滚

The automatic failure rollback restores both the release and runtime files.
The manual commands below switch only the executable release. To restore a
previous deployment's configuration too, copy its files from the backup
directory printed by that installation while the service is stopped, then
start the service. Use backups from the deployment you are undoing.

旧版本仍保留在 `/opt/drone_interceptor-binary/releases/` 下：

```bash
sudo systemctl stop drone-interceptor
sudo ln -sfn releases/<旧版本> /opt/drone_interceptor-binary/current
sudo systemctl start drone-interceptor
```

## 重新生成部署包（维护者）

The executable must target ARM64 and compatible Ubuntu 22.04/ROS 2 Humble libraries. It does not have to be compiled on an aarch64 machine: the default x86_64 image has now cross-compiled this node and the real ARM64 message package successfully. See [current build commands](../../docs/DOCKER_BUILD.md).

Packaging remains a separate limitation. `make_bundle.sh` explicitly requires `uname -m` to report `aarch64` and uses native `ldd` to resolve ARM dependencies. Run it on a compatible ARM64 board or in a prepared ARM64 container with matching inputs. Direct packaging in the x86_64 image is currently unsupported. The newly cross-built installation has not been verified through this complete bundle/install procedure. The board-side command below is retained as a supported example; building on a roughly 4 GiB board can exhaust memory.

```bash
# 板上，已有 colcon install 产物后：
bash deploy/relative_imm_ukf/make_bundle.sh \
  --install-dir /path/to/install \
  --quadrotor-prefix /home/hzhy/workspace/fpv_ws/install/quadrotor_msgs \
  --out /root
```

脚本会收集二进制、参数、`quadrotor_msgs` 与 `vision_msgs` 运行时库，生成 `SHA256SUMS`、`manifest.json`，
做一次 `ldd` 自检，然后输出 `.tar.gz` 与 `.sha256`。
