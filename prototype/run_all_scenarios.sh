#!/usr/bin/env bash
# Run each scenario in a fresh container and retain every failed result.
set -eo pipefail
directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
vision=(nominal maneuvering crossing dropout noise wrong_w)
radar=(radar_relay radar_maneuver radar_falsepos radar_far radar_only radar_close radar_reintercept radar_overbound)
common=()
vision_only=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vision-only) vision_only=true; shift ;;
        --backend|--image|--artifacts-dir)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
            if [[ "$1" == --backend && "$2" != amd64 && "$2" != arm64 ]]; then
                printf 'Unsupported backend: %s\n' "$2" >&2
                exit 2
            fi
            common+=("$1" "$2"); shift 2 ;;
        --help|-h)
            printf 'Usage: run_all_scenarios.sh [--vision-only] [--backend amd64|arm64] [--image IMAGE] [--artifacts-dir PATH]\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
scenarios=("${vision[@]}")
if ! "$vision_only"; then
    scenarios+=("${radar[@]}")
fi
passed=0
failed=0
for scenario in "${scenarios[@]}"; do
    extra=()
    if [[ "$scenario" == radar_reintercept ]]; then
        extra+=(radar_reintercept_enable:=true)
    fi
    if bash "$directory/run_scenario.sh" "${common[@]}" "$scenario" "${extra[@]}"; then
        printf 'PASS %s\n' "$scenario"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$scenario" >&2
        failed=$((failed + 1))
    fi
done
printf 'PASS=%s FAIL=%s\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
