#!/usr/bin/env bash
# Compatibility entry point using the same isolated runner and strict verdict.
set -e
directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $# -eq 0 ]]; then
    set -- nominal
fi
exec bash "$directory/run_scenario.sh" "$@"
