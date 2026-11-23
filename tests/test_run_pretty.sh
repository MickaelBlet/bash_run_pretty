#!/usr/bin/env bash
#
# Test suite for run_pretty.sh — one test per condition/branch in the function.
# Pure-bash (no bats). Run: bash tests/test_run_pretty.sh
#
# Tests run with stdout NOT a tty (output is captured), so they exercise the
# non-tty code paths. Each test asserts on exit code and/or captured output.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/../run_pretty.sh
source "${ROOT_DIR}/run_pretty.sh"

pass=0
fail=0

# assert_eq <name> <expected> <actual>
assert_eq() {
    local name="${1}" exp="${2}" act="${3}"
    if [[ "${exp}" == "${act}" ]]; then
        printf 'ok   - %s\n' "${name}"
        pass=$(( pass + 1 ))
    else
        printf 'FAIL - %s\n      expected: %q\n      actual:   %q\n' "${name}" "${exp}" "${act}"
        fail=$(( fail + 1 ))
    fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    local name="${1}" needle="${2}" hay="${3}"
    if [[ "${hay}" == *"${needle}"* ]]; then
        printf 'ok   - %s\n' "${name}"
        pass=$(( pass + 1 ))
    else
        printf 'FAIL - %s\n      missing: %q\n      in:      %q\n' "${name}" "${needle}" "${hay}"
        fail=$(( fail + 1 ))
    fi
}

# assert_not_contains <name> <needle> <haystack>
assert_not_contains() {
    local name="${1}" needle="${2}" hay="${3}"
    if [[ "${hay}" != *"${needle}"* ]]; then
        printf 'ok   - %s\n' "${name}"
        pass=$(( pass + 1 ))
    else
        printf 'FAIL - %s\n      unexpected: %q\n      in:         %q\n' "${name}" "${needle}" "${hay}"
        fail=$(( fail + 1 ))
    fi
}

# run_pretty always sees a non-tty stdout here because $() captures it.
out=""; ec=0
cap() { out="$(run_pretty "${@}" 2>&1)"; ec=$?; }

# --------------------------------------------------------------------------
# Argument validation / error conditions
# --------------------------------------------------------------------------

# no command provided
cap --title "x"
assert_eq "no command -> exit 1" "1" "${ec}"
assert_contains "no command -> message" "no command provided" "${out}"

# --title requires argument
cap --title
assert_eq "--title missing arg -> exit 1" "1" "${ec}"
assert_contains "--title missing arg -> message" "'--title' option require a argument" "${out}"

# --max-lines requires argument
cap --max-lines
assert_eq "--max-lines missing arg -> exit 1" "1" "${ec}"
assert_contains "--max-lines missing arg -> message" "'--max-lines' option require a argument" "${out}"

# --min-lines requires argument
cap --min-lines
assert_eq "--min-lines missing arg -> exit 1" "1" "${ec}"
assert_contains "--min-lines missing arg -> message" "'--min-lines' option require a argument" "${out}"

# --max-output requires argument
cap --max-output
assert_eq "--max-output missing arg -> exit 1" "1" "${ec}"
assert_contains "--max-output missing arg -> message" "'--max-output' option require a argument" "${out}"

# --spinner requires argument
cap --spinner
assert_eq "--spinner missing arg -> exit 1" "1" "${ec}"
assert_contains "--spinner missing arg -> message" "'--spinner' option require a argument" "${out}"

# --spinner-interval requires argument
cap --spinner-interval
assert_eq "--spinner-interval missing arg -> exit 1" "1" "${ec}"
assert_contains "--spinner-interval missing arg -> message" "'--spinner-interval' option require a argument" "${out}"

# unknown spinner name
cap --spinner bogus true
assert_eq "unknown spinner -> exit 1" "1" "${ec}"
assert_contains "unknown spinner -> message" "unknown spinner_name 'bogus'" "${out}"

# --------------------------------------------------------------------------
# Valid spinner names (each branch of the validation conditional)
# --------------------------------------------------------------------------
for sp in loading loading2 upload download check check2 check3 wait; do
    cap --spinner "${sp}" true
    assert_eq "valid spinner '${sp}' -> exit 0" "0" "${ec}"
done

# --------------------------------------------------------------------------
# Exit code propagation
# --------------------------------------------------------------------------
cap --title "ok" true
assert_eq "success exit 0" "0" "${ec}"
assert_contains "success non-tty -> OK line" "OK: ok" "${out}"

cap --title "boom" bash -c 'exit 7'
assert_eq "failure propagates exit 7" "7" "${ec}"
assert_contains "failure non-tty -> FAILED line" "FAILED: boom (exit 7)" "${out}"

# --------------------------------------------------------------------------
# --no-elapsed toggles the timer suffix
# --------------------------------------------------------------------------
cap --no-elapsed --title "noel" true
assert_eq "no-elapsed success exit 0" "0" "${ec}"
assert_eq "no-elapsed success -> plain OK" "OK: noel" "${out}"

cap --title "el" true
assert_contains "default elapsed -> has (Ns)" "OK: el (" "${out}"

cap --no-elapsed --title "noelf" bash -c 'exit 3'
assert_eq "no-elapsed failure -> plain FAILED" "FAILED: noelf (exit 3)" "${out}"

# --------------------------------------------------------------------------
# --print-output dumps captured output on success (non-tty)
# --------------------------------------------------------------------------
cap --print-output --no-elapsed --title "po" bash -c 'echo hello; echo world'
assert_contains "print-output success -> shows hello" "hello" "${out}"
assert_contains "print-output success -> shows world" "world" "${out}"

# non-tty always streams output live; the OK summary comes after it
cap --no-elapsed --title "nopo" bash -c 'echo streamed'
assert_eq "non-tty streams then summarizes" "$(printf 'streamed\nOK: nopo')" "${out}"

# --------------------------------------------------------------------------
# Default title falls back to the command string
# --------------------------------------------------------------------------
cap --no-elapsed true
assert_eq "default title = command -> OK: true" "OK: true" "${out}"

# --------------------------------------------------------------------------
# --title= and --spinner= inline (=value) forms
# --------------------------------------------------------------------------
cap --title=inlinetitle --no-elapsed true
assert_eq "--title= inline form" "OK: inlinetitle" "${out}"

cap --spinner=check --no-elapsed --title "sp" true
assert_eq "--spinner= inline form -> exit 0" "0" "${ec}"

# --------------------------------------------------------------------------
# -- terminates option parsing
# --------------------------------------------------------------------------
cap --no-elapsed -- echo afterdashdash
assert_eq "-- ends options -> exit 0" "0" "${ec}"
assert_contains "-- treats rest as command" "OK: echo afterdashdash" "${out}"

# --------------------------------------------------------------------------
# Non-tty path streams command output live (always printed regardless of flags)
# --------------------------------------------------------------------------
cap --no-elapsed --title "stream" bash -c 'echo line1; echo line2'
assert_contains "non-tty streams line1" "line1" "${out}"
assert_contains "non-tty streams line2" "line2" "${out}"

# --------------------------------------------------------------------------
# Title ANSI escape expansion (%b on the title)
# --------------------------------------------------------------------------
cap --no-elapsed --title 'a\tb' true
assert_contains "title \\t expanded to tab" "$(printf 'a\tb')" "${out}"

# --------------------------------------------------------------------------
# Numeric option validation
# --------------------------------------------------------------------------
cap --max-lines abc true
assert_eq "--max-lines non-numeric -> exit 1" "1" "${ec}"
assert_contains "--max-lines non-numeric -> message" "expects a non-negative integer" "${out}"

cap --spinner-interval fast true
assert_eq "--spinner-interval non-numeric -> exit 1" "1" "${ec}"

# ==========================================================================
# Parallel tasks: rp_add / rp_run (non-tty)
# ==========================================================================

# rp_run with an empty registry
out="$(rp_run 2>&1)"; ec=$?
assert_eq "rp_run empty registry -> exit 1" "1" "${ec}"
assert_contains "rp_run empty registry -> message" "no task registered" "${out}"

# rp_run rejects positional arguments
out="$(rp_add true; rp_run extra 2>&1)"; ec=$?
assert_eq "rp_run extra arg -> exit 1" "1" "${ec}"
assert_contains "rp_run extra arg -> message" "unexpected argument 'extra'" "${out}"

# rp_add without command / with unknown option
out="$(rp_add --title x 2>&1)"; ec=$?
assert_eq "rp_add no command -> exit 1" "1" "${ec}"
assert_contains "rp_add no command -> message" "no command provided" "${out}"

out="$(rp_add --bogus true 2>&1)"; ec=$?
assert_eq "rp_add unknown option -> exit 1" "1" "${ec}"
assert_contains "rp_add unknown option -> message" "unknown option '--bogus'" "${out}"

out="$(rp_add --spinner nope true 2>&1)"; ec=$?
assert_eq "rp_add unknown spinner -> exit 1" "1" "${ec}"

# rp_run option validation
out="$(rp_add true; rp_run --jobs x 2>&1)"; ec=$?
assert_eq "rp_run --jobs non-numeric -> exit 1" "1" "${ec}"

# all tasks succeed
out="$(rp_add --title a true; rp_add --title b true; rp_run --no-elapsed 2>&1)"; ec=$?
assert_eq "parallel all ok -> exit 0" "0" "${ec}"
assert_contains "parallel all ok -> OK a" "OK: a" "${out}"
assert_contains "parallel all ok -> OK b" "OK: b" "${out}"
assert_contains "parallel all ok -> summary" "SUMMARY: 2 ok" "${out}"

# elapsed shown by default
out="$(rp_add --title a true; rp_run 2>&1)"
assert_contains "parallel elapsed default -> OK a (" "OK: a (" "${out}"

# one failure: its code is returned, other tasks still run to completion
out="$(rp_add --title bad bash -c 'exit 5'
       rp_add --title slow bash -c 'sleep 0.3; echo done-slow'
       rp_run --no-elapsed 2>&1)"; ec=$?
assert_eq "parallel failure -> exit 5" "5" "${ec}"
assert_contains "parallel failure -> FAILED line" "FAILED: bad (exit 5)" "${out}"
assert_contains "parallel failure -> others continue" "OK: slow" "${out}"
assert_contains "parallel failure -> output tagged" "[slow] done-slow" "${out}"
assert_contains "parallel failure -> summary" "SUMMARY: 1 ok · 1 failed" "${out}"

# first failure (chronologically) decides the exit code
out="$(rp_add --title late bash -c 'sleep 0.3; exit 9'
       rp_add --title early bash -c 'exit 4'
       rp_run --no-elapsed 2>&1)"; ec=$?
assert_eq "parallel first failure wins -> exit 4" "4" "${ec}"

# --fail-fast cancels running tasks and skips queued ones
out="$(rp_add --title boom bash -c 'sleep 0.1; exit 3'
       rp_add --title long sleep 5
       rp_add --title waiting true
       rp_run --jobs 2 --fail-fast --no-elapsed 2>&1)"; ec=$?
assert_eq "fail-fast -> exit 3" "3" "${ec}"
assert_contains "fail-fast -> cancelled" "CANCELLED: long" "${out}"
assert_contains "fail-fast -> skipped" "SKIPPED: waiting" "${out}"
assert_not_contains "fail-fast -> queued task never ran" "OK: waiting" "${out}"

# --jobs 1 runs tasks sequentially in registration order
out="$(rp_add --title one bash -c 'sleep 0.1; echo 1'
       rp_add --title two bash -c 'echo 2'
       rp_run --jobs 1 --no-elapsed 2>&1)"
assert_eq "jobs 1 -> sequential order" \
    "$(printf '[one] 1\nOK: one\n[two] 2\nOK: two\nSUMMARY: 2 ok')" "${out}"

# tasks really run concurrently
start_ns=0
end_ns=0
_rp_now_us start_ns
out="$(rp_add sleep 0.5; rp_add sleep 0.5; rp_add sleep 0.5; rp_run 2>&1)"
_rp_now_us end_ns
elapsed_ms=$(( (end_ns - start_ns) / 1000 ))
assert_eq "parallel tasks overlap (< 1.2s)" "true" "$( [[ ${elapsed_ms} -lt 1200 ]] && echo true || echo false )"

# default title falls back to the command
out="$(rp_add echo hi; rp_run --no-elapsed 2>&1)"
assert_contains "parallel default title" "OK: echo hi" "${out}"

# partial lines (no trailing newline / \r progress) are reassembled
out="$(rp_add --title p bash -c 'printf a; sleep 0.2; printf b; sleep 0.2; printf "c\n"; printf tail'
       rp_run --no-elapsed 2>&1)"
assert_contains "partial lines reassembled" "[p] abc" "${out}"
assert_contains "trailing partial line kept" "[p] tail" "${out}"

# a very long line stays intact (chunked under PIPE_BUF, then rejoined)
long="$(printf 'x%.0s' $(seq 1 10000))"
out="$(rp_add --title big printf '%s\n' "${long}"
       rp_add --title noise bash -c 'yes noise | head -n 200'
       rp_run --no-elapsed 2>&1)"
assert_contains "long line intact" "[big] ${long}"$'\n' "${out}"

# --print-output and --max-output are per task
out="$(rp_add --title po --print-output --max-output 2 bash -c 'echo l1; echo l2; echo l3'
       rp_run --no-elapsed 2>&1)"
assert_contains "parallel print-output keeps last 2" "$(printf 'OK: po\nl2\nl3')" "${out}"

# rp_run clears the registry
out="$(rp_add true; rp_run >/dev/null 2>&1; rp_run 2>&1)"; ec=$?
assert_eq "registry cleared after rp_run" "1" "${ec}"

# rp_reset clears the registry
out="$(rp_add true; rp_reset; rp_run 2>&1)"; ec=$?
assert_eq "rp_reset clears registry" "1" "${ec}"

# works when the caller runs under strict mode
out="$(set -euo pipefail
       rp_add --title ok true
       rp_add --title ko bash -c 'exit 2'
       rp_run --no-elapsed || echo "rc=$?")"
assert_contains "strict mode caller survives failure" "rc=2" "${out}"

# argv is preserved exactly (spaces, quotes, globs)
out="$(rp_add --title argv printf '<%s>' 'a b' '*' '"q"'; rp_run --no-elapsed 2>&1)"
assert_contains "argv preserved" '[argv] <a b><*><"q">' "${out}"

# --------------------------------------------------------------------------
# --term-title: accepted, no-op (no OSC) when stdout is not a tty
# --------------------------------------------------------------------------
cap --term-title --no-elapsed --title "tt" true
assert_eq "--term-title non-tty -> plain OK" "OK: tt" "${out}"
assert_not_contains "--term-title non-tty -> no OSC" $'\e]' "${out}"

out="$(rp_add --title tt true; rp_run --term-title --no-elapsed 2>&1)"
assert_contains "rp_run --term-title accepted" "OK: tt" "${out}"
assert_not_contains "rp_run --term-title non-tty -> no OSC" $'\e]' "${out}"

# window title text is stripped of ANSI and controls
_RP_RET=""
_rp_strip_ansi $'⠋ \e[1;31mBuild\e[0m\tx'
assert_eq "_rp_strip_ansi removes CSI + controls" "⠋ Buildx" "${_RP_RET}"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]
