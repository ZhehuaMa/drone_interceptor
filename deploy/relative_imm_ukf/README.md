# drone_interceptor IMM-UKF 节点 · 开发板部署包

目标平台：RK3576 开发板，Ubuntu 22.04 ARM64，PREEMPT_RT 内核，已预装 ROS 2 Humble。
部署内容：`launch/launch_relative_imm_ukf.py` 所启动的节点 `interceptor_node_relative_imm_ukf`
的预编译二进制，以 systemd 服务方式开机自启，进程绑定 **CPU 4-7**（内核 `isolcpus=4-7`
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

安装成功的判据（脚本内部已逐条断言，任一条不满足即回滚）：

- 服务处于 active 且 `NRestarts == 0`（启动后 5 秒内没有崩溃重启）
- `systemctl is-enabled drone-interceptor` 为 enabled（上电自启）
- 主进程 `taskset -pc <PID>` 输出为 `4-7`

## 安装后的文件布局

| 路径 | 说明 |
|------|------|
| `/opt/drone_interceptor-binary/releases/<版本>/` | 本次发布的只读内容 |
| `/opt/drone_interceptor-binary/current` | 指向当前发布的符号链接，服务只读它 |
| `/etc/drone_interceptor/relative_imm_ukf_params.yaml` | 运行参数（首次安装写入，之后升级**不覆盖**） |
| `/etc/drone_interceptor/runtime.env` | 运行开关（CPU 绑核、仿真/雷达开关、日志等级） |
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
ros2 topic hz /fpv/control_command       # 需外部有 IMU/bbox 输入才会发布
```

订阅：`/mavros/imu/data`、`/fpv/target_bbox`、`/fpv/odom`、`/fpv/tracker_trigger`、
`/fpv/mission_start`（启用雷达时还有 `/fpv/radar/target`、`/fpv/radar/interceptor`）。
发布：`/fpv/control_command`、`/fpv/mission_state`。

**进程存活 ≠ 功能验收。** 必须用真实 IMU/检测/里程计数据确认 `/fpv/mission_state` 流转与
`/fpv/control_command` 输出合理，才算部署通过。

## 回滚

旧版本仍保留在 `/opt/drone_interceptor-binary/releases/` 下：

```bash
sudo systemctl stop drone-interceptor
sudo ln -sfn releases/<旧版本> /opt/drone_interceptor-binary/current
sudo systemctl start drone-interceptor
```

## 重新生成部署包（维护者）

二进制必须在与目标板同规格的 aarch64 机器上编译。板上内存有限（约 4 GB 且无 swap），
编译 `interceptor_node_relative_imm_ukf.cpp` 可能被 OOM 杀掉，必要时先加 swap。

```bash
# 板上，已有 colcon install 产物后：
bash deploy/relative_imm_ukf/make_bundle.sh \
  --install-dir /path/to/install \
  --quadrotor-prefix /home/hzhy/workspace/fpv_ws/install/quadrotor_msgs \
  --out /root
```

脚本会收集二进制、参数、`quadrotor_msgs` 与 `vision_msgs` 运行时库，生成 `SHA256SUMS`、`manifest.json`，
做一次 `ldd` 自检，然后输出 `.tar.gz` 与 `.sha256`。
