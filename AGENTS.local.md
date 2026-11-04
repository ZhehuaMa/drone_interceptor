# drone_interceptor — Local development environment

- Read the [workspace-local instructions](../AGENTS.local.md) before building or testing.
- Use [docs/DOCKER_BUILD.md](docs/DOCKER_BUILD.md) for current image tags, toolchains, and commands. Keep version inventories and dated validation results out of this file.

## Build environment

- Use the documented Docker workflows. On this x86_64 host, prefer the native image for local compilation and simulation. Use its documented cross-build workflow to produce ARM64 deployment binaries.
- Select the ARM64 container only as an explicit fallback. ARM64 programs require QEMU, an ARM instruction emulator, on this host. A container's architecture and its compiler's output architecture can differ.
- Use the real `quadrotor_msgs` source from the sibling checkout `../quadrotor_msgs`; verify that it exists before building. Build its generated message libraries for the same output architecture as the node, including when cross-compiling.
- Mount both source checkouts read-only for container builds and scenarios. Keep build, install, log, and scenario outputs outside the shared source workspace. Separate native, cross-build, and emulated build directories and caches.
- Preserve the selected build or scenario architecture after a failure. Report the failure; do not automatically retry through another architecture.

## Scenarios and evidence

- Use the repository's scenario runners to exercise the real C++ ROS node. Consult the build guide and the runners' `--help` output for current entry points, options, and defaults.
- Require successful simulator and runner exit statuses, plus a fresh summary reporting `Intercepted: True` and `NaN commands: 0` (no invalid numeric commands). Keep failed cases visible; a zero process status alone is not a pass.
- Preserve required results in an explicitly retained external directory before cleaning temporary outputs or caches. Record the actual evidence location in a dated validation report; verify historical paths before relying on them.
- Report native simulation, cross-compilation, emulated execution, and target-board validation separately. Physical runtime validation requires the intended target board.
