# 在 `drone-tracker-rk3576` 容器里编译本仓库

验证日期：2026-09-24
验证镜像：`drone-tracker-rk3576:humble-arm64-rknn2.3.2`（host/image 均为 arm64，架构一致，无需 QEMU）

## 结论

本仓库当前**能**在该镜像里编译通过，唯一缺失的依赖是 `quadrotor_msgs`（提供
`ControlCommand` 消息类型的 ROS2 包，`CMakeLists.txt:22 find_package(quadrotor_msgs REQUIRED)`
用到）。

- `Eigen3`（`libeigen3-dev`）镜像里已装好，不缺。
- `rosdep install --simulate` 报错 `Cannot locate rosdep definition for [quadrotor_msgs]`——
  它不在 ROS 官方索引里，`apt`/`rosdep` 装不了，只能把源码放进 workspace 一起编。
- **acados / blasfeo / hpipm 这次没有验证**：`CMakeLists.txt` 里 NMPC 相关的两个
  target（quaternion / DQ 变体）当前整段被注释掉了，只有 `interceptor_node_relative_imm_ukf`
  这一个 target 是激活的（该 target 只链接 `libm`，不需要 acados）。如果以后取消注释启用
  NMPC 变体，acados/blasfeo/hpipm 需要额外装进镜像，本文档的验证结论不覆盖这部分。

## 依赖来源

`quadrotor_msgs` 源码仓库：`~/projects/nickluo/quadrotor_msgs`（本地路径，已是
`ament_cmake` 格式的 ROS2 包，含 `ControlCommand.msg` 等消息定义，字段
`control_mode` / `BODY_RATES` / `collective_thrust` / `bodyrates.{x,y,z}` 与本仓库
代码里的用法（见 `src/interceptor_node_relative_imm_ukf.cpp`）完全对得上）。

## 编译方法：把 `quadrotor_msgs` 挂载进容器一起编

不需要改镜像本身（不用往镜像里装系统包）。做法是把 `quadrotor_msgs` 源码目录挂载到
workspace 的 `src/` 下，`colcon build` 时当作 workspace 内的普通包，先编 `quadrotor_msgs`
生成它的 `quadrotor_msgsConfig.cmake`，再编 `drone_interceptor`。

```bash
docker run --rm \
  -v ~/projects/nickluo/quadrotor_msgs:/work/ros2_ws/src/quadrotor_msgs:ro \
  -v <本仓库路径>:/work/ros2_ws/src/drone_interceptor:ro \
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
   换成真实的 `~/projects/nickluo/quadrotor_msgs` 源码重跑一遍，结果一致：两个包都
   编译通过。
