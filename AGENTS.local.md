# drone_interceptor 远程开发机约定

- 先读取 `/home/mzh/nickluo/AGENTS.local.md`。
- 本仓库为 `/home/mzh/nickluo/drone_interceptor`；共享消息源码为 `/home/mzh/nickluo/quadrotor_msgs`。
- Follow `docs/DOCKER_BUILD.md` for the enabled IMM-UKF node. Default to the x86_64 image for native simulation or genuine ARM64 cross-compilation. Build real messages for the same target. Use the ARM64 image only as an explicit fallback.
- Keep new outputs outside source in separate native/cross/fallback directories. Preserve historical evidence under `/home/mzh/nickluo-validation-20261015/drone_interceptor/`. Only ARM execution needs QEMU on this host; native x86_64 compilation and simulation run directly.
- 当前 CMake 未启用 NMPC 变体。本文不表示 acados 或 AirSim 已验证，也不表示已验证真实飞控闭环。

## Current scenario workflow (2026-10-15)

- `prototype/run_scenario.sh`, `run_one.sh`, and `run_all_scenarios.sh` now default to the amd64 development image and ROS 2 Humble. Read the current section in `docs/DOCKER_BUILD.md` before using the historical workstation examples.
- `--backend arm64` explicitly selects the preserved ARM64 image. Cache and result directories are separated by backend. There is no automatic retry through another backend after a failure.
- These runners build native binaries for the selected image architecture. The amd64 mode is software simulation, not an ARM64 release build. Source repositories are read-only; output defaults to `/tmp/nickluo-interceptor-scenarios` or the external `--artifacts-dir` path.
- Each scenario must report `Intercepted: True` and `NaN commands: 0`, and its simulator process must succeed. Keep failed cases visible; zero process status alone is not a pass.
