#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# make_gif.sh  –  Record a selection of demos.sh and render docs/demo.gif
#
#   bash make_gif.sh
#
# Requires: asciinema (pip install asciinema), agg (cargo install agg)
# ------------------------------------------------------------------------------

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

readonly DEMOS="1 3 4 9 14"
readonly COLUMNS_COUNT=80
readonly ROWS_COUNT=20
readonly CAST_FILE="docs/demo.cast"
readonly GIF_FILE="docs/demo.gif"
readonly PROMPT=$'\e[1;32m$\e[0m '

COLUMNS="${COLUMNS_COUNT}"

# Recorded inside asciinema: fake a prompt, "type" the command, then run it.
play() {
    local demo_command="bash demos.sh $DEMOS"
    local i
    printf '%s' "$PROMPT"
    sleep 0.5
    for (( i = 0; i < ${#demo_command}; i++ )); do
        printf '%s' "${demo_command:i:1}"
        sleep 0.04
    done
    sleep 0.4
    printf '\n'
    # shellcheck disable=SC2086  # DEMOS is meant to split into arguments
    bash demos.sh $DEMOS
    printf '%s' "$PROMPT"
    sleep 1
}

if [[ "${1:-}" == "--play" ]]; then
    play
    exit 0
fi

missing=0
for tool in asciinema agg; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "missing tool: $tool" >&2
        missing=1
    fi
done
if [[ "$missing" -ne 0 ]]; then
    echo "install with: pip install asciinema && cargo install agg" >&2
    exit 1
fi

mkdir -p docs

asciinema rec --quiet --overwrite \
    --cols "$COLUMNS_COUNT" --rows "$ROWS_COUNT" \
    --command "bash make_gif.sh --play" \
    "$CAST_FILE"

agg --theme monokai --font-size 16 --idle-time-limit 1.5 --speed 1.2 --last-frame-duration 4 \
    "$CAST_FILE" "$GIF_FILE"

rm -f "$CAST_FILE"

echo "wrote $GIF_FILE"
