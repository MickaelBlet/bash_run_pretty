#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# examples/demos.sh  –  A tour of run_pretty features
#
#   bash examples/demos.sh           # run every demo
#   bash examples/demos.sh 3 5       # run only demos 3 and 5
# ------------------------------------------------------------------------------

# SC2016: single-quoted bodies below are `bash -c` scripts; expansion is meant
# to happen in the inner shell, not here.
# shellcheck disable=SC2016

set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../run_pretty.sh"

# -- Demo registry -------------------------------------------------------------
demo_1_success() {
    # Basic success: rolling window + spinner, no output kept after.
    run_pretty --title "Counting up" \
        bash -c 'for i in $(seq 1 30); do echo "line $i"; sleep 0.05; done'
}

demo_2_print_output() {
    # Keep and print the captured output on success (--print-output), capped to last 8 lines.
    run_pretty --print-output --max-output 8 --title "Print last 8 lines" \
        bash -c 'seq 1 40'
}

demo_3_failure() {
    # Non-zero exit: full output is dumped and exit code surfaced.
    run_pretty --max-lines 5 --title "Intentional failure" \
        bash -c 'echo prepping; echo working; echo "uh oh" >&2; exit 17'
}

demo_4_carriage_return() {
    # \r progress meter collapses onto a single live line.
    run_pretty --spinner-interval 0.5 --spinner wait --title "Downloading" \
        bash -c 'for i in $(seq 0 100); do printf "\rprogress: %d%%" "$i"; sleep 0.02; done; echo'
}

demo_5_spinners() {
    # Show every spinner style back to back.
    local s
    for s in loading loading2 upload download check check2 check3; do
        run_pretty --spinner "$s" --title "Spinner: $s" \
            bash -c 'sleep 1.5'
    done
}

demo_6_hidden_cmd() {
    # --no-cmd hides the command line (e.g. secrets in args).
    run_pretty --hide-cmd --title "Secret sauce" \
        bash -c 'echo "doing private things"; sleep 1'
}

demo_7_colored_output() {
    # ANSI-colored, recursive listing through the rolling window.
    run_pretty --spinner download --title "Listing /etc" \
        bash -c 'ls -laR --color=always /etc 2>/dev/null | head -200; sleep 1'
}

demo_8_slow_spinner() {
    # Custom spinner interval (--spinner-interval): slow, deliberate frames.
    run_pretty --spinner check --spinner-interval 0.2 --title "Slow heartbeat" \
        bash -c 'sleep 3'
}

demo_9_git_clone() {
    # Simulate `git clone --progress`: phased counters that redraw via \r,
    # each phase committing a final line just like real git.
    run_pretty --spinner wait --title "Cloning into 'repo'" \
        bash -c '
            echo "Cloning into '\''repo'\''..."
            for p in 0 14 33 58 79 100; do
                printf "\rremote: Counting objects: %d%% (%d/4231)" "$p" $((p*4231/100))
                sleep 0.12
            done
            printf "\rremote: Counting objects: 100%% (4231/4231), done.\n"
            for p in 0 21 47 70 100; do
                printf "\rremote: Compressing objects: %d%% (%d/1873)" "$p" $((p*1873/100))
                sleep 0.12
            done
            printf "\rremote: Compressing objects: 100%% (1873/1873), done.\n"
            for p in 0 8 19 34 52 68 81 94 100; do
                printf "\rReceiving objects: %d%% (%d/4231), %.2f MiB | %d.0 MiB/s" \
                    "$p" $((p*4231/100)) "$(awk "BEGIN{print $p*0.124}")" $((RANDOM%6+4))
                sleep 0.1
            done
            printf "\rReceiving objects: 100%% (4231/4231), 12.41 MiB | 6.0 MiB/s, done.\n"
            for p in 0 25 51 77 100; do
                printf "\rResolving deltas: %d%% (%d/2510)" "$p" $((p*2510/100))
                sleep 0.1
            done
            printf "\rResolving deltas: 100%% (2510/2510), done.\n"
        '
}

demo_10_scp() {
    # Simulate `scp`: a single live line "file  NN%  size  speed  ETA" that
    # rewrites itself via \r, then a final committed 100% line.
    run_pretty --spinner upload --title "scp release.tar.gz server:/srv" \
        bash -c '
            total=248
            for p in 0 6 13 24 38 49 61 73 85 96 100; do
                done_mb=$(awk "BEGIN{printf \"%.1f\", $total*$p/100}")
                eta=$(( (100-p)*9/100 ))
                printf "\rrelease.tar.gz  %3d%%  %6sMB  %d.%dMB/s  %02d:%02d" \
                    "$p" "$done_mb" $((RANDOM%5+8)) $((RANDOM%9)) $((eta/60)) $((eta%60))
                sleep 0.18
            done
            printf "\rrelease.tar.gz  100%%   248.0MB  11.4MB/s  00:00\n"
        '
}

demo_11_pty() {
    # --pty allocates a pseudo-terminal so the command thinks it is talking to a
    # real TTY. Tools that gate behaviour on isatty() (colors, progress bars,
    # interactive prompts) then behave as they would in a normal terminal.
    # Here the inner script reports whether stdout is a TTY: without --pty it
    # prints "stdout is a pipe", with --pty it prints "stdout is a TTY".
    run_pretty --pty --spinner loading2 --title "Inside a PTY" \
        bash -c '
            if [ -t 1 ]; then echo "stdout is a TTY"; else echo "stdout is a pipe"; fi
            ls --color=auto -dlR /etc /tmp /usr 2>/dev/null
        '
}

demo_12_no_elapsed() {
    # --no-elapsed disables the live timer (docker buildx style) shown on the
    # right of the title, and the total on the final status line.
    run_pretty --no-elapsed --title "Building image" \
        bash -c 'for s in pulling extracting linking finalizing; do echo "$s..."; sleep 0.8; done'
}

demo_13_min_lines() {
    # --min-lines reserves a fixed window height: the block stays 5 lines tall
    # from the start, padded with blanks, instead of growing as output trickles in.
    run_pretty --min-lines 10 --print-output --max-output 10 --title "Reserved 10-line window" \
        bash -c 'for i in $(seq 1 1000); do echo "line $i"; sleep 0.001; done'
}

demo_14_parallel() {
    # rp_add registers tasks, rp_run runs them concurrently (2 at a time here):
    # one block per task, live output under running ones, failures dumped.
    rp_add --title "Build" \
        bash -c 'for f in main util net db ui; do echo "gcc -c $f.c"; sleep 0.4; done'
    rp_add --title "Lint" \
        bash -c 'for f in a b c; do echo "checking $f.c"; sleep 0.5; done; echo "c.c:12: unused variable" >&2; exit 1'
    rp_add --title "Unit tests" --spinner check2 \
        bash -c 'for t in parse eval io net; do echo "test_$t ... ok"; sleep 0.6; done'
    rp_add --title "Docs" --spinner wait \
        bash -c 'echo "rendering"; sleep 1.2'
    rp_run --jobs 2
}

demo_15_parallel_progress() {
    # \r progress meters stay live in parallel; --pty and --print-output per task.
    local name
    for name in alpha beta gamma; do
        rp_add --title "Downloading ${name}.tar.gz" --print-output --max-output 5 --spinner download \
            bash -c 'for i in $(seq 0 5 100); do printf "%3d%%\n" "$i"; sleep 0.$((RANDOM % 9 + 1)); done; echo " done"'
    done
    rp_add --title "Inside a PTY" --pty --print-output --max-output 5 \
        bash -c 'if [ -t 1 ]; then echo "stdout is a TTY"; else echo "stdout is a pipe"; fi'
    rp_run --max-lines 5 --min-lines 15
}

demo_16_term_title() {
    # --term-title mirrors the spinner and state in the terminal window/tab
    # title (watch it while switching tabs); the old title is restored after.
    run_pretty --term-title --title "Building image" \
        bash -c 'for s in pulling extracting linking finalizing; do echo "$s..."; sleep 1; done'
    rp_add --title "Build" \
        bash -c 'for f in main util net; do echo "gcc -c $f.c"; sleep 1; done'
    rp_add --title "Tests" --spinner check2 \
        bash -c 'for t in parse eval io net; do echo "test_$t ... ok"; sleep 1; done'
    rp_run --term-title
}

# -- Runner --------------------------------------------------------------------
demos=(demo_1_success demo_2_print_output demo_3_failure demo_4_carriage_return
       demo_5_spinners demo_6_hidden_cmd demo_7_colored_output demo_8_slow_spinner
       demo_9_git_clone demo_10_scp demo_11_pty demo_12_no_elapsed demo_13_min_lines
       demo_14_parallel demo_15_parallel_progress demo_16_term_title)

run_one() {
    local n="$1" fn="${demos[$1 - 1]:-}"
    [[ -z "$fn" ]] && { echo "no demo $n" >&2; return; }
    printf '\n=== Demo %s: %s ===\n' "$n" "${fn#demo_*_}"
    "$fn" && echo "→ exit 0" || echo "→ exit $?"
}

if (( $# )); then
    for n in "$@"; do run_one "$n"; done
else
    for (( n = 1; n <= ${#demos[@]}; n++ )); do run_one "$n"; done
fi
