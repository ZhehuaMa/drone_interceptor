# Build and test with the development images

## Current simulation entry points (2026-10-15)

The existing scenario scripts now start isolated ROS 2 Humble containers. Their default is
`drone-tracker-rk3576:humble-amd64-rknn2.3.2`. They compile the real `quadrotor_msgs` source
and the enabled C++ node before running the simulator. This default produces native x86_64
simulation binaries. It does not produce an ARM64 deployment bundle.

From this repository, run:

```bash
bash prototype/run_scenario.sh nominal
bash prototype/run_all_scenarios.sh --vision-only
bash prototype/run_all_scenarios.sh
# Explicit ARM64 image fallback; outputs use a separate cache.
bash prototype/run_scenario.sh --backend arm64 nominal
```

Use `--artifacts-dir /absolute/external/path` to choose the output root. The default is
`/tmp/nickluo-interceptor-scenarios`. Each backend and immutable image ID has its own build workspace, and each
scenario gets a fresh result directory. Preserve results before the operating system cleans
`/tmp`. Sources are mounted read-only, and the simulator's unchanged script and configuration
are staged into the result directory so its CSV and summary never overwrite source files.

`run_one.sh` delegates to the same runner. Existing leading `launch_arg:=value` overrides
and subsequent simulator arguments remain supported. For example:

```bash
bash prototype/run_scenario.sh radar_reintercept radar_reintercept_enable:=true
```

The runner returns success only when the simulator process succeeds, the fresh summary says
`Intercepted: True`, and `NaN commands: 0`. NaN means an invalid numeric command. A missing
summary, timeout, or failed interception returns a nonzero status. The simulator has a
90-second process limit. The complete suite retains all fourteen existing scenarios,
including the currently failing `radar_only` scenario. It does not change acceptance thresholds.

Use `--image IMAGE` only with an image matching the selected backend; architecture mismatch
is rejected. Build or test failure never triggers an automatic backend switch. ARM64 execution
on the current x86_64 host still uses QEMU, an ARM instruction emulator, and can retain its
known ROS discovery limitations. No physical devices or host network are mounted.

The historical ARM64-image instructions below remain a supported fallback. ARM64 output can also be built in the default x86_64 image.
The former NMPC (model-predictive controller) variants have been removed. Their sources remain in Git history.

## Current native and ARM64 build capabilities

An ARM64 container is not required for the enabled `interceptor_node_relative_imm_ukf`. The default x86_64 image builds native x86_64 simulation binaries or cross-compiles the same node for ARM64. These are separate outputs; use separate build/install directories and build the actual `quadrotor_msgs` source for each architecture.

The only application target is `interceptor_node_relative_imm_ukf`. It needs Eigen and the ROS dependencies already in the image. The former NMPC targets and their generated solver integration have been removed from `CMakeLists.txt`. The current build needs no acados, blasfeo, hpipm, or solver code generation.

### Native compile without running scenarios

```bash
# Run on the development host. The source mounts are read-only.
mkdir -p /tmp/drone_interceptor-native
docker run --rm --network none --platform linux/amd64 \
  --user "$(id -u):$(id -g)" \
  -v /home/mzh/nickluo/drone_interceptor:/src/drone_interceptor:ro \
  -v /home/mzh/nickluo/quadrotor_msgs:/src/quadrotor_msgs:ro \
  -v /tmp/drone_interceptor-native:/out \
  drone-tracker-rk3576:humble-amd64-rknn2.3.2 bash -lc '
    set -eo pipefail
    source /opt/ros/humble/setup.bash
    mkdir -p /out/ws/src
    ln -sfn /src/drone_interceptor /out/ws/src/drone_interceptor
    ln -sfn /src/quadrotor_msgs /out/ws/src/quadrotor_msgs
    cd /out/ws
    CMAKE_BUILD_PARALLEL_LEVEL=4 colcon --log-base /out/ws/log build \
      --packages-up-to drone_interceptor --executor sequential \
      --build-base /out/ws/build --install-base /out/ws/install \
      --cmake-args -DCMAKE_BUILD_TYPE=Release
    source /out/ws/install/setup.bash
    file /out/ws/install/drone_interceptor/lib/drone_interceptor/*
  '
```

### ARM64 release executable from the default image

```bash
mkdir -p /tmp/drone_interceptor-cross
docker run --rm --network none --platform linux/amd64 \
  --user "$(id -u):$(id -g)" \
  -v /home/mzh/nickluo/drone_interceptor:/src/drone_interceptor:ro \
  -v /home/mzh/nickluo/quadrotor_msgs:/src/quadrotor_msgs:ro \
  -v /tmp/drone_interceptor-cross:/out \
  drone-tracker-rk3576:humble-amd64-rknn2.3.2 bash -lc '
    set -eo pipefail
    source /opt/ros/humble/setup.bash
    cmake -S /src/quadrotor_msgs -B /out/build/quadrotor_msgs \
      -DCMAKE_TOOLCHAIN_FILE=/opt/toolchains/aarch64-humble.cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/out/install/quadrotor_msgs
    cmake --build /out/build/quadrotor_msgs -j4
    cmake --install /out/build/quadrotor_msgs
    cmake -S /src/drone_interceptor -B /out/build/drone_interceptor \
      -DCMAKE_TOOLCHAIN_FILE=/opt/toolchains/aarch64-humble.cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -Dquadrotor_msgs_DIR=/out/install/quadrotor_msgs/share/quadrotor_msgs/cmake \
      -DCMAKE_INSTALL_PREFIX=/out/install/drone_interceptor
    cmake --build /out/build/drone_interceptor -j4
    cmake --install /out/build/drone_interceptor
    file /out/install/drone_interceptor/lib/drone_interceptor/*
  '
```

The clean cross-build was independently run on 2026-10-15 with image ID `025d0aa88983`. Both the node and all generated message libraries are ELF ARM aarch64. The genuine ARM loader resolved every dependency, including the newly built message libraries. Evidence is in `/tmp/nickluo-submodule-image-audit-20261015/logs/`. This historical build predates the current CTest registration; it does not establish regression-test or ROS simulation results for the current source.

Current `CMakeLists.txt` registers two CTest regression executables when configured with `-DBUILD_TESTING=ON`: `guidance_limits_test` and `camera_pose_history_test`. They check guidance math, IMU attitude integration, and timestamped camera orientation lookup. The ROS graph regression in `test/relative_imm_ukf_topics_test.py` runs separately with Python `unittest` in a sourced ROS workspace. None of these checks replaces the ROS interception scenarios.

### Explicit ARM64-image fallback

For an explicit ARM64-image fallback, take the native recipe, change `--platform linux/amd64` to `--platform linux/arm64`, and select `drone-tracker-rk3576:humble-arm64-rknn2.3.2`. Use a separate host output directory such as `/tmp/drone_interceptor-arm64-image`. That compiler produces ARM64 output without the cross toolchain. On this x86_64 host its compiler and test programs run through QEMU, an ARM instruction emulator. A failed build or test is not a reason to switch architecture silently.

Native ROS scenario results remain distinct from cross-build results. The six native vision scenarios passed. `radar_only` still misses the interception criterion; the Python model's `wrong_wguess` auxiliary velocity-error criterion also remains unmet. ARM64-image ROS simulation on this x86 host has known emulated discovery failures. No test threshold was relaxed, and none of these checks establishes actual flight behavior.

## Historical ARM64-image validation — 2026-09-24

当前开发环境（2026-10-15）：`mzh:/home/mzh/nickluo/drone_interceptor`，Ubuntu 22.04.5 x86_64。ARM64 镜像已迁移，通过 QEMU AArch64 运行。下面 2026-09-24 的编译结果属于历史验证；远程机重新编译和测试的结果另行记录。

验证日期：2026-09-24
验证镜像：`drone-tracker-rk3576:humble-arm64-rknn2.3.2`（host/image 均为 arm64，架构一致，无需 QEMU）

## 结论

2026-09-24 验证时，本仓库**能**在该镜像里编译通过，唯一缺失的依赖是 `quadrotor_msgs`（提供
`ControlCommand` 消息类型的 ROS2 包，由 `find_package(quadrotor_msgs REQUIRED)` 引入）。

- `Eigen3`（`libeigen3-dev`）镜像里已装好，不缺。
- `rosdep install --simulate` 报错 `Cannot locate rosdep definition for [quadrotor_msgs]`——
  它不在 ROS 官方索引里，`apt`/`rosdep` 装不了，只能把源码放进 workspace 一起编。
- **acados / blasfeo / hpipm 当时没有验证**：验证时，`CMakeLists.txt` 中两个 NMPC（模型预测控制）
  变体（quaternion / DQ）的构建定义被整段注释，唯一启用的应用目标是
  `interceptor_node_relative_imm_ukf`。这些 NMPC 源码及构建定义现已删除，可从 Git 历史查阅。
  当前节点使用 Eigen、ROS 依赖和 `libm`，不需要 acados 或求解器代码生成。

## 依赖来源

`quadrotor_msgs` 源码仓库：`/home/mzh/nickluo/quadrotor_msgs`（本地路径，已是
`ament_cmake` 格式的 ROS2 包，含 `ControlCommand.msg` 等消息定义，字段
`control_mode` / `BODY_RATES` / `collective_thrust` / `bodyrates.{x,y,z}` 与本仓库
代码里的用法（见 `src/interceptor_node_relative_imm_ukf.cpp`）完全对得上）。

## 编译方法：把 `quadrotor_msgs` 挂载进容器一起编

不需要改镜像本身（不用往镜像里装系统包）。做法是把 `quadrotor_msgs` 源码目录挂载到
workspace 的 `src/` 下，`colcon build` 时当作 workspace 内的普通包，先编 `quadrotor_msgs`
生成它的 `quadrotor_msgsConfig.cmake`，再编 `drone_interceptor`。

```bash
docker run --rm --platform linux/arm64 \
  -v /home/mzh/nickluo/quadrotor_msgs:/work/ros2_ws/src/quadrotor_msgs:ro \
  -v /home/mzh/nickluo/drone_interceptor:/work/ros2_ws/src/drone_interceptor:ro \
  drone-tracker-rk3576:humble-arm64-rknn2.3.2 bash -lc '
    source /opt/ros/humble/setup.bash
    cd /work/ros2_ws
    colcon build --packages-select quadrotor_msgs
    source install/setup.bash
    colcon build --packages-select drone_interceptor
  '
```

验证结果：两步 `colcon build` 均 `Finished`，无 stderr 错误（仅有 docker overlay 挂载
导致的文件 mtime 早于当前时间的 `Clock skew detected` 警告，无关紧要，可忽略）。

### 用于 Dockerfile / CI 的等价写法

如果要固化进镜像构建流程（例如 CI 里没法用宿主机挂载），把上面的“挂载”换成
“克隆/复制源码进 `src/`”即可，效果等价：

```dockerfile
# colcon build 之前，把 quadrotor_msgs 源码放进 workspace src/
COPY quadrotor_msgs /work/ros2_ws/src/quadrotor_msgs
# 或者：RUN git clone <quadrotor_msgs 仓库地址> /work/ros2_ws/src/quadrotor_msgs

RUN . /opt/ros/humble/setup.sh && \
    cd /work/ros2_ws && \
    colcon build --packages-select quadrotor_msgs drone_interceptor
```

## 排查记录（供参考）

1. `rosdep install --from-paths src --ignore-src -r -y --simulate` 只报出一个无法解析的
   key：`quadrotor_msgs`。
2. 直接 `colcon build --packages-select drone_interceptor`（不挂载 `quadrotor_msgs`）失败：

   ```
   CMake Error at CMakeLists.txt:22 (find_package):
     Could not find a package configuration file provided by "quadrotor_msgs"
   ```

3. 先用一个按仓库实际用到字段手搭的 stub `quadrotor_msgs` 包验证可行性，确认能跑通后，
   换成当时本机真实的 `~/projects/nickluo/quadrotor_msgs` 源码重跑一遍，结果一致：两个包都
   编译通过。
