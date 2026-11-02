# drone_interceptor — Local development environment

- Read `/home/mzh/nickluo/AGENTS.local.md` before building.
- The repository is at `/home/mzh/nickluo/drone_interceptor`. Shared `quadrotor_msgs` source is at `/home/mzh/nickluo/quadrotor_msgs`.

## Build environment

- Follow the current native or ARM64 cross-build recipe in `docs/DOCKER_BUILD.md` for the enabled IMM-UKF node. Both recipes mount the real message source read-only and build it for the same target architecture as the node.
- Default to `drone-tracker-rk3576:humble-amd64-rknn2.3.2` (`linux/amd64`) on this x86_64 host. It builds native x86_64 simulation binaries or cross-compiles ARM64 deployment binaries. For example, use the native recipe for host simulation and the cross-build recipe for an ARM64 release executable.
- Use `drone-tracker-rk3576:humble-arm64-rknn2.3.2` (`linux/arm64`) only as an explicit fallback. ARM64 programs run through QEMU, an ARM instruction emulator, on this host. Native x86_64 compilation and simulation run directly.
- Keep build, install, and log outputs outside the source tree in separate native, cross-build, and fallback directories. Preserve historical evidence under `/home/mzh/nickluo-validation-20261015/drone_interceptor/`.
- Physical target runtime validation requires the target board. The current CMake configuration contains no NMPC variants. These instructions do not establish acados, AirSim, or physical flight validation.

## Scenario workflow

- `prototype/run_scenario.sh`, `prototype/run_one.sh`, and `prototype/run_all_scenarios.sh` default to the amd64 development image and ROS 2 Humble. Read the current section in `docs/DOCKER_BUILD.md` before using historical workstation examples.
- `--backend arm64` explicitly selects the preserved ARM64 image. Cache and result directories are separated by backend. There is no automatic retry through another backend after a failure.
- These runners build native binaries for the selected image architecture. The amd64 mode is software simulation, not an ARM64 release build. Source repositories are read-only; output defaults to `/tmp/nickluo-interceptor-scenarios` or the external `--artifacts-dir` path.
- Each scenario must report `Intercepted: True` and `NaN commands: 0`, and its simulator process must succeed. Keep failed cases visible; zero process status alone is not a pass.
