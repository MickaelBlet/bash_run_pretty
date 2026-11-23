#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# test_versions.sh  –  Run test_run_pretty.sh under several Bash versions
#
#   bash test_versions.sh                    # all supported versions
#   bash test_versions.sh 4.2 5.3            # only these versions
#   bash test_versions.sh --runs 3 --jobs 4  # repeat each 3 times, 4 at once
#
# Uses the official `bash:<version>` Docker images (pulled on first use).
# Options:
#   --runs N   run the suite N times per version (catches flaky races)
#   --jobs N   max concurrent containers (0 = all, default)
# ------------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=run_pretty.sh
source "${SCRIPT_DIR}/run_pretty.sh"

DEFAULT_VERSIONS=(4.2 4.3 4.4 5.0 5.1 5.2 5.3)

usage() {
    sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    local runs=1
    local jobs=0
    local -a versions=()

    while [[ ${#} -gt 0 ]]; do
        case "${1}" in
            --runs)
                runs="${2:?--runs needs a value}"
                shift 2 ;;
            --runs=*)
                runs="${1#*=}"
                shift ;;
            --jobs)
                jobs="${2:?--jobs needs a value}"
                shift 2 ;;
            --jobs=*)
                jobs="${1#*=}"
                shift ;;
            -h|--help)
                usage
                return 0 ;;
            -*)
                echo "unknown option: ${1}" >&2
                usage >&2
                return 2 ;;
            *)
                versions+=("${1}")
                shift ;;
        esac
    done

    if [[ ! "${runs}" =~ ^[1-9][0-9]*$ ]]; then
        echo "--runs must be a positive integer" >&2
        return 2
    fi
    if [[ ${#versions[@]} -eq 0 ]]; then
        versions=("${DEFAULT_VERSIONS[@]}")
    fi
    if ! command -v docker > /dev/null; then
        echo "docker is required" >&2
        return 1
    fi

    local version
    local run
    local title
    for version in "${versions[@]}"; do
        for (( run = 1; run <= runs; run++ )); do
            title="bash ${version}"
            if [[ ${runs} -gt 1 ]]; then
                title+=" #${run}"
            fi
            rp_add --title "${title}" --hide-cmd \
                docker run --rm -v "${SCRIPT_DIR}:/w:ro" -w /w \
                "bash:${version}" bash test_run_pretty.sh
        done
    done

    rp_run --jobs "${jobs}"
}

main "${@}"
