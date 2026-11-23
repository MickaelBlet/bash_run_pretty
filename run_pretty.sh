#!/usr/bin/env bash

# EPOCHREALTIME is a Bash builtin variable shellcheck cannot see assigned.
# shellcheck disable=SC2154

# ------------------------------------------------------------------------------
# run_pretty  –  Run any command with a live rolling window + spinner
#
# Usage:
#   source run_pretty.sh
#   run_pretty [--title "Title"] [--max-lines N] [--min-lines N]
#              [--max-output N] [--hide-cmd] [--print-output]
#              [--no-elapsed] [--spinner SPINNER]
#              [--spinner-interval SECONDS] [--pty] [--term-title]
#              command [args...]
#
#   --max-lines caps the rolling window height (0 = fit the terminal).
#   --min-lines sets the floor for that window on short terminals.
#   --max-output caps how many lines are retained for the final dump
#   (0 = keep everything).
#   --hide-cmd hides the command line under the title.
#   --print-output also prints the captured output on success.
#   An elapsed timer (docker buildx style) is shown by default on the right of
#   the title plus the final status line; --no-elapsed disables it.
#   --pty runs the command under a pseudo-terminal (via `script`) so programs
#   that buffer or colourize only on a TTY behave as if interactive.
#   --term-title shows the spinner and current state in the terminal window
#   title while running (the previous title is restored on exit).
#
# Spinners: loading (default), loading2, upload, download, check, check2,
#           check3, wait
#
# Examples:
#   run_pretty git clone https://github.com/org/repo
#   run_pretty --title "Building image"  docker build -t myapp .
#   run_pretty --title "Installing deps" --max-lines 10 npm install
#   run_pretty --title "Secret sauce" --hide-cmd ./sensitive_script.sh
#   run_pretty --max-output 500 ./verbose_script.sh  # cap failure dump to last 500 lines
#   run_pretty --spinner upload --spinner-interval 0.03 ./deploy.sh
#   run_pretty --pty --title "Tests" pytest   # force coloured/interactive output
#
# ------------------------------------------------------------------------------
# Parallel tasks  –  rp_add / rp_run / rp_reset
#
#   rp_add [--title "Title"] [--hide-cmd] [--print-output] [--pty]
#          [--max-output N] [--spinner SPINNER] command [args...]
#   rp_run [--jobs N] [--fail-fast] [--max-lines N] [--min-lines N]
#          [--no-elapsed] [--spinner-interval SECONDS] [--term-title]
#   rp_reset
#
#   rp_add registers a task (nothing runs yet); rp_run runs every registered
#   task concurrently, shows one block per task (title, spinner, elapsed and
#   the last --max-lines output lines of running tasks, default 3), then
#   prints a summary and clears the registry. rp_reset clears it manually.
#
#   --jobs N caps how many tasks run at once (0 = all, the default).
#   --fail-fast cancels running and queued tasks on the first failure.
#   Returns 0 if every task succeeded, otherwise the exit code of the first
#   task that failed (130 on Ctrl-C).
#
# Example:
#   rp_add --title "Build" make
#   rp_add --title "Lint"  npm run lint
#   rp_add --title "Tests" --pty pytest
#   rp_run --jobs 2
# ------------------------------------------------------------------------------

# ==============================================================================
# Shared state
# ==============================================================================
_RP_RET=""       # scratch return slot for fork-free helpers
_RP_VIS=0        # visible-char count from _rp_truncate_ansi_visible
_RP_FRAMES=()    # spinner frames filled by _rp_spinner_frames
_RP_OUT=()       # captured output in display order
_RP_CURSOR_ROW=1 # cursor row filled by _rp_term_probe
_RP_O_SHIFT=0    # number of arguments consumed by _rp_parse_opts
_RP_O_DASHDASH="false"
declare -gA _RP_O=()

# Bash < 5.3 can drop a byte when `read -t` times out while input arrives,
# so _rp_read_timed falls back to a byte-wise reader there.
_RP_READ_COMPAT="false"
if [[ "${BASH_VERSINFO[0]}" -lt 5 \
   || ( "${BASH_VERSINFO[0]}" -eq 5 && "${BASH_VERSINFO[1]}" -lt 3 ) ]]; then
    _RP_READ_COMPAT="true"
fi
_RP_SLEEP_FD=""  # never-written FIFO used as a timed sleep by the fallback
_RP_READ_CARRY="" # \r held back by the fallback for the next read

_RP_BOLD=""
_RP_DIM=""
_RP_CYAN=""
_RP_GREEN=""
_RP_RED=""
_RP_RESET=""
_RP_ERASE_LINE=""
_RP_CURSOR_UP=""

# Task registry (rp_add), indexed by task id. argv lives in _RP_T_ARGV_<id>.
_RP_T_TITLE=()
_RP_T_CMD=()
_RP_T_HIDE_CMD=()
_RP_T_PRINT=()
_RP_T_PTY=()
_RP_T_MAX_OUTPUT=()
_RP_T_SPINNER=()

# ==============================================================================
# Shared helpers
# ==============================================================================

# Fill _RP_FRAMES with the frames of spinner ${1}; return 1 if unknown.
_rp_spinner_frames() {
    case "${1}" in
        "loading")
            _RP_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') ;;
        "loading2")
            _RP_FRAMES=('⢄' '⢂' '⢁' '⡁' '⡈' '⡐' '⡠') ;;
        "upload")
            _RP_FRAMES=(
                '⣷' '⣶' '⣮' '⣦' '⣥' '⣤' '⣔' '⣌' '⣄' '⣂' '⣁' '⣀' '⡠' '⡐' '⡈' '⡀' '⠄' '⠂' '⠁' '⢁' '⠡' '⠑' '⠉' '⡉' '⠍' '⠋' '⢋' '⠫' '⠛' '⡛' '⠟' '⢟' '⠿' '⡿' '⣿'
                '⣾' '⣶' '⣵' '⣴' '⣬' '⣤' '⣢' '⣡' '⣠' '⣐' '⣈' '⣀' '⢄' '⢂' '⢁' '⢀' '⠠' '⠐' '⠈' '⡈' '⠌' '⠊' '⠉' '⢉' '⠩' '⠙' '⡙' '⠝' '⠛' '⢛' '⠻' '⡻' '⠿' '⢿' '⣿'
            ) ;;
        "download")
            _RP_FRAMES=(
                '⡿' '⠿' '⢟' '⠟' '⡛' '⠛' '⠫' '⢋' '⠋' '⠍' '⡉' '⠉' '⠑' '⠡' '⢁' '⠁' '⠂' '⠄' '⡀' '⡈' '⡐' '⡠' '⣀' '⣁' '⣂' '⣄' '⣌' '⣔' '⣤' '⣥' '⣦' '⣮' '⣶' '⣷' '⣿'
                '⢿' '⠿' '⡻' '⠻' '⢛' '⠛' '⠝' '⡙' '⠙' '⠩' '⢉' '⠉' '⠊' '⠌' '⡈' '⠈' '⠐' '⠠' '⢀' '⢁' '⢂' '⢄' '⣀' '⣈' '⣐' '⣠' '⣡' '⣢' '⣤' '⣬' '⣴' '⣵' '⣶' '⣾' '⣿'
            ) ;;
        "check")
            _RP_FRAMES=('⠉' '⠒' '⠤' '⣀' '⠤' '⠒') ;;
        "check2")
            _RP_FRAMES=('⡇' '⡎' '⡜' '⡸' '⢸' '⢱' '⢣' '⢇') ;;
        "check3")
            _RP_FRAMES=('⡇' '⡇' '⢸' '⢸') ;;
        "wait")
            _RP_FRAMES=('●' ' ') ;;
        *)
            return 1 ;;
    esac
}

# Parse options shared by run_pretty / rp_add / rp_run.
#   _rp_parse_opts <caller> <allowed option names> args...
# Results go in _RP_O[<name>] (flags: "true"/"false", values: "" if unset),
# _RP_O_SHIFT (arguments consumed) and _RP_O_DASHDASH (whether `--` was seen).
# Parsing stops at the first argument that is not an allowed option.
_rp_parse_opts() {
    local caller="${1}"
    local allowed=" ${2} "
    shift 2

    _RP_O=(
        ["title"]=""
        ["hide-cmd"]="false"
        ["print-output"]="false"
        ["no-elapsed"]="false"
        ["pty"]="false"
        ["fail-fast"]="false"
        ["term-title"]="false"
        ["max-lines"]=""
        ["min-lines"]=""
        ["max-output"]=""
        ["jobs"]=""
        ["spinner"]="loading"
        ["spinner-interval"]="0.10"
    )
    _RP_O_SHIFT=0
    _RP_O_DASHDASH="false"

    local prefix="$0: line ${BASH_LINENO[1]}: ${caller}"
    local name
    local value
    while [[ $# -gt 0 ]]; do
        if [[ "${1}" == "--" ]]; then
            _RP_O_SHIFT=$(( _RP_O_SHIFT + 1 ))
            _RP_O_DASHDASH="true"
            break
        fi
        if [[ "${1}" != "--"* ]]; then
            break
        fi
        name="${1#--}"
        name="${name%%=*}"
        if [[ "${allowed}" != *" ${name} "* ]]; then
            break
        fi

        case "${name}" in
            "hide-cmd"|"print-output"|"no-elapsed"|"pty"|"fail-fast"|"term-title")
                _RP_O[${name}]="true"
                shift
                _RP_O_SHIFT=$(( _RP_O_SHIFT + 1 ))
                continue ;;
        esac

        if [[ "${1}" == *=* ]]; then
            value="${1#*=}"
            shift
            _RP_O_SHIFT=$(( _RP_O_SHIFT + 1 ))
        else
            if [[ $# -le 1 ]]; then
                echo "${prefix}: '--${name}' option require a argument" >&2
                return 1
            fi
            value="${2}"
            shift 2
            _RP_O_SHIFT=$(( _RP_O_SHIFT + 2 ))
        fi

        case "${name}" in
            "max-lines"|"min-lines"|"max-output"|"jobs")
                if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
                    echo "${prefix}: '--${name}' expects a non-negative integer, got '${value}'" >&2
                    return 1
                fi ;;
            "spinner-interval")
                if [[ ! "${value}" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                    echo "${prefix}: '--${name}' expects a number of seconds, got '${value}'" >&2
                    return 1
                fi ;;
            "spinner")
                if ! _rp_spinner_frames "${value}"; then
                    echo "${prefix}: unknown spinner_name '${value}' (Choose: loading, loading2, upload, download, check, check2, check3, wait)" >&2
                    return 1
                fi ;;
        esac
        _RP_O[${name}]="${value}"
    done
    return 0
}

# Fill LINES / COLUMNS (if unset) and _RP_CURSOR_ROW for TTY ${1}=="true".
_rp_term_probe() {
    local is_tty="${1}"
    _RP_CURSOR_ROW=1
    if [[ "${is_tty}" == "true" ]]; then
        # Terminal size via cursor-position-report (no external `tput`):
        # save cursor, jump to far corner, report position, restore.
        # `-t` so a terminal that never answers the report falls back to
        # defaults instead of hanging the call forever.
        if [[ -z "${LINES:-}" || -z "${COLUMNS:-}" ]]; then
            local size_report=()
            printf '\0337\033[9999;9999H\033[6n\0338' > "/dev/tty"
            IFS='[;' read -rsd R -t 0.5 -a size_report < "/dev/tty" 2> "/dev/null" || true
            if [[ -z "${LINES:-}"   && "${size_report[1]:-}" =~ ^[0-9]+$ ]]; then
                LINES="${size_report[1]}"
            fi
            if [[ -z "${COLUMNS:-}" && "${size_report[2]:-}" =~ ^[0-9]+$ ]]; then
                COLUMNS="${size_report[2]}"
            fi
        fi
        local cursor_report=()
        printf '\033[6n' > "/dev/tty"
        IFS='[;' read -rsd R -t 0.5 -a cursor_report < "/dev/tty" 2> "/dev/null" || true
        if [[ "${cursor_report[1]:-}" =~ ^[0-9]+$ ]]; then
            _RP_CURSOR_ROW="${cursor_report[1]}"
        fi
    fi
    if [[ -z "${LINES:-}" ]]; then
        LINES=7
    fi
    if [[ -z "${COLUMNS:-}" ]]; then
        COLUMNS=80
    fi
}

# Rows available below the cursor, floored at ${1} (min lines) → _RP_RET.
_rp_available_lines() {
    local min_lines="${1}"
    local available=$(( LINES - _RP_CURSOR_ROW - 1 ))
    if [[ "${available}" -lt "${min_lines}" ]]; then
        available="${min_lines}"
    fi
    if [[ "$(( LINES - 3 ))" -lt "${min_lines}" ]]; then
        available="$(( LINES - 3 ))"
    fi
    _RP_RET="${available}"
}

# Set the _RP_<COLOUR> globals (empty when ${1} != "true").
_rp_set_colors() {
    _RP_BOLD=""
    _RP_DIM=""
    _RP_CYAN=""
    _RP_GREEN=""
    _RP_RED=""
    _RP_RESET=""
    _RP_ERASE_LINE=""
    _RP_CURSOR_UP=""
    if [[ "${1}" == "true" ]]; then
        _RP_BOLD=$'\033[1m'
        _RP_DIM=$'\033[2m'
        _RP_CYAN=$'\033[36m'
        _RP_GREEN=$'\033[32m'
        _RP_RED=$'\033[31m'
        _RP_RESET=$'\033[0m'
        _RP_ERASE_LINE=$'\033[2K'
        _RP_CURSOR_UP=$'\033[1A'
    fi
}

# Current time in µs → variable named ${1}, fork-free. Uses EPOCHREALTIME
# (Bash 5+), else /proc/uptime (Linux, 10 ms resolution), else SECONDS (1 s).
_rp_now_us() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        printf -v "${1}" '%s' "${EPOCHREALTIME/[.,]/}"
    elif [[ -r /proc/uptime ]]; then
        local uptime=""
        local _rest=""
        read -r uptime _rest < /proc/uptime
        printf -v "${1}" '%s' "$(( 10#${uptime/./} * 10000 ))"
    else
        printf -v "${1}" '%s' "$(( SECONDS * 1000000 ))"
    fi
}

# Open the FIFO the Bash < 5.3 read fallback sleeps on (no-op otherwise).
_rp_sleep_fd_init() {
    if [[ "${_RP_READ_COMPAT}" == "false" || -n "${_RP_SLEEP_FD}" ]]; then
        return 0
    fi
    local sleep_dir
    sleep_dir="$(mktemp -d "${TMPDIR:-/tmp}/rp_sleep.XXXXXX")" || return 1
    if ! mkfifo "${sleep_dir}/sleep"; then
        rm -rf "${sleep_dir}"
        return 1
    fi
    exec {_RP_SLEEP_FD}<>"${sleep_dir}/sleep"
    rm -rf "${sleep_dir}"
}

# `IFS= read -r -t ${2} -u ${1} ${3}` with the same status codes (0 line,
# > 128 timeout with partial input kept, 1 EOF). On Bash < 5.3 input is read
# byte-wise only once `read -t 0` reports it, and the wait happens on
# _RP_SLEEP_FD, so a timeout never races incoming data. There, a partial
# line is also returned before each \r (the \r starts the next read), so
# progress meters stay live without showing an empty line. With ${4}
# = "record", input is written in whole lines (the rp_run mux), so a line is
# read at once as soon as one is pending.
_rp_read_timed() {
    if [[ "${_RP_READ_COMPAT}" == "false" || -z "${_RP_SLEEP_FD}" ]]; then
        IFS= read -r -t "${2}" -u "${1}" "${3}"
        return
    fi
    local fd="${1}"
    local _RP_RET=""
    local buffer="${_RP_READ_CARRY}"
    local char=""
    local waited=0
    _RP_READ_CARRY=""
    _rp_interval_us "${2}"
    local max_waits=$(( _RP_RET / 10000 ))
    while :; do
        if IFS= read -r -t 0 -u "${fd}"; then
            if [[ "${4:-}" == "record" ]]; then
                IFS= read -r -t 1 -u "${fd}" "${3}"
                return
            fi
            if ! IFS= read -r -N 1 -u "${fd}" char; then
                printf -v "${3}" '%s' "${buffer}"
                return 1
            fi
            if [[ "${char}" == $'\n' ]]; then
                printf -v "${3}" '%s' "${buffer}"
                return 0
            fi
            if [[ "${char}" == $'\r' && -n "${buffer}" ]]; then
                _RP_READ_CARRY="${char}"
                printf -v "${3}" '%s' "${buffer}"
                return 142
            fi
            buffer+="${char}"
            if [[ ${#buffer} -ge 4096 ]]; then
                printf -v "${3}" '%s' "${buffer}"
                return 142
            fi
            continue
        fi
        if [[ ${waited} -ge ${max_waits} ]]; then
            printf -v "${3}" '%s' "${buffer}"
            return 142
        fi
        read -r -t 0.01 -u "${_RP_SLEEP_FD}" || true
        waited=$(( waited + 1 ))
    done
}

# Elapsed time between ${1} and ${2} (default now), in µs, as "12.3s".
_rp_fmt_elapsed() {
    local start_us="${1}"
    local end_us="${2:-}"
    if [[ -z "${end_us}" ]]; then
        _rp_now_us end_us
    fi
    local tenths=$(( (end_us - start_us) / 100000 ))
    _RP_RET="$(( tenths / 10 )).$(( tenths % 10 ))s"
}

# Seconds ("0.10") → integer microseconds, builtin only → _RP_RET.
_rp_interval_us() {
    local interval="${1}"
    local interval_int="${interval%%.*}"
    local interval_frac=""
    if [[ "${interval}" == *.* ]]; then
        interval_frac="${interval#*.}"
    fi
    if [[ ! "${interval_int}" =~ ^[0-9]+$ ]]; then
        interval_int=0
    fi
    interval_frac="${interval_frac}000000"
    interval_frac="${interval_frac:0:6}"
    local result=$(( 10#0${interval_int} * 1000000 + 10#0${interval_frac} ))
    if [[ ${result} -lt 1 ]]; then
        result=1
    fi
    _RP_RET="${result}"
}

# Collapse whitespace runs of ${1} into single spaces → _RP_RET.
_rp_normalize_cmd() {
    local text="${1//[$' \t\n\r\v\f']/ }"
    while [[ "${text}" == *"  "* ]]; do
        text="${text//  / }"
    done
    _RP_RET="${text}"
}

# Append ${2} to the in-progress line ${1}, honouring \r → _RP_RET.
_rp_feed_cr() {
    local current="${1}"
    local data="${2}"

    # Strip out cursor show/hide sequences injected by the PTY commands
    data="${data//$'\033'[?25h/}"
    data="${data//$'\033'[?25l/}"

    while [[ "${data}" == *$'\r'* ]]; do
        current=""
        data="${data#*$'\r'}"
    done
    _RP_RET="${current}${data}"
}

# Re-apply colour ${2} after any embedded ANSI reset in ${1} → _RP_RET.
_rp_replace_reset() {
    local escape=$'\033'
    _RP_RET="${1//${escape}[0m/${escape}[0m${2}}"
}

# Clip ${1} to ${2} visible chars, keeping CSI sequences → _RP_RET, _RP_VIS.
_rp_truncate_ansi_visible() {
    local rest="${1}"
    local max_visible="${2}"
    local out=""
    local visible=0
    local escape=$'\033'
    local csi

    if [[ ${max_visible} -le 0 ]]; then
        _RP_RET=""
        _RP_VIS=0
        return 0
    fi

    while [[ -n "${rest}" ]]; do
        if [[ "${rest:0:1}" == "${escape}" && "${rest:1:1}" == "[" && "${rest:2}" =~ ^[0-9\;\?]*[A-Za-z] ]]; then
            csi="${escape}[${BASH_REMATCH[0]}"
            out+="${csi}"
            rest="${rest:${#csi}}"
            continue
        fi

        if [[ ${visible} -ge ${max_visible} ]]; then
            break
        fi

        out+="${rest:0:1}"
        rest="${rest:1}"
        visible=$(( visible + 1 ))
    done

    _RP_RET="${out}"
    _RP_VIS="${visible}"
}

# Terminal window title (--term-title): save, set and restore via xterm
# control sequences, written straight to the controlling terminal.
_rp_term_title_push() {
    printf '\033[22;0t' > "/dev/tty" 2> "/dev/null" || true
}

_rp_term_title_pop() {
    printf '\033[23;0t' > "/dev/tty" 2> "/dev/null" || true
}

# Remove ANSI CSI sequences and control characters from ${1} → _RP_RET.
_rp_strip_ansi() {
    local text="${1}"
    local clean=""
    local rest
    while [[ "${text}" == *$'\e['* ]]; do
        clean+="${text%%$'\e['*}"
        rest="${text#*$'\e['}"
        text="${rest#*[@-~]}"
    done
    clean+="${text}"
    _RP_RET="${clean//[[:cntrl:]]/}"
}

# Set the window title to ${1} (ANSI and controls removed).
_rp_term_title_set() {
    _rp_strip_ansi "${1}"
    printf '\033]0;%s\007' "${_RP_RET}" > "/dev/tty" 2> "/dev/null" || true
}

# Status line "<glyph> <text><suffix>      <right>" clipped to the terminal.
#   _rp_title_line <glyph> <color> <text> <suffix> <right> <right color>
_rp_title_line() {
    local glyph="${1}"
    local color="${2}"
    local text="${3}"
    local suffix="${4}"
    local right="${5}"
    local right_color="${6}"
    local columns="${COLUMNS:-80}"
    local right_width=0
    if [[ -n "${right}" ]]; then
        right_width=$(( ${#right} + 1 ))
    fi

    _rp_replace_reset "${text}" "${color}${_RP_BOLD}"
    _rp_truncate_ansi_visible "${_RP_RET}" $(( columns - 2 - ${#suffix} - right_width ))

    local suffix_text=""
    if [[ -n "${suffix}" ]]; then
        suffix_text="${color}${suffix}${_RP_RESET}"
    fi

    if [[ -n "${right}" ]]; then
        local padding=$(( columns - 2 - _RP_VIS - ${#suffix} - right_width ))
        if [[ ${padding} -lt 1 ]]; then
            padding=1
        fi
        printf '%s%s%s%s %s%s%s%*s%s%s%s\n' \
            "${_RP_ERASE_LINE}" "${color}" "${glyph}" "${_RP_BOLD}" "${_RP_RET}" "${_RP_RESET}" \
            "${suffix_text}" "$(( padding + 1 ))" "" "${right_color}" "${right}" "${_RP_RESET}"
    else
        printf '%s%s%s%s %s%s%s\n' \
            "${_RP_ERASE_LINE}" "${color}" "${glyph}" "${_RP_BOLD}" "${_RP_RET}" "${_RP_RESET}" \
            "${suffix_text}"
    fi
}

# Print array ${2} as a tree under a coloured connector (└╴ on the last line).
_rp_dump_tree() {
    local color="${1}"
    local tree_ref="${2}[@]"
    local -a tree_lines=("${!tree_ref+"${!tree_ref}"}")
    local count=${#tree_lines[@]}
    local i
    for (( i = 0; i < count; i++ )); do
        if [[ ${i} -eq $(( count - 1 )) ]]; then
            printf '%s└╴%s%s\n' "${color}" "${_RP_RESET}" "${tree_lines[${i}]}"
        else
            printf '%s│ %s%s\n' "${color}" "${_RP_RESET}" "${tree_lines[${i}]}"
        fi
    done
}

# Print the command line as a tree branch: ├╴ if more follows, else └╴.
#   _rp_cmd_branch <color> <cmd> <has more: true|false>
_rp_cmd_branch() {
    local connector="└╴"
    if [[ "${3}" == "true" ]]; then
        connector="├╴"
    fi
    printf '%s%s%s%s%s%s\n' "${1}" "${connector}" "${_RP_RESET}" "${_RP_DIM}" "${2}" "${_RP_RESET}"
}

# Send signal ${2} to the process group of ${1}, falling back to the pid.
_rp_kill_tree() {
    local pid="${1}"
    local sig="${2}"
    if [[ -z "${pid}" ]]; then
        return 0
    fi
    kill "-${sig}" -- "-${pid}" 2>/dev/null \
        || kill "-${sig}" "${pid}" 2>/dev/null \
        || true
}

# ==============================================================================
# run_pretty
# ==============================================================================
run_pretty() {
    _rp_parse_opts "${FUNCNAME[0]}" \
        "title hide-cmd print-output no-elapsed pty term-title max-lines min-lines max-output spinner spinner-interval" \
        "${@}" || return 1
    shift "${_RP_O_SHIFT}"

    if [[ $# -eq 0 ]]; then
        echo "$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}: run_pretty: no command provided" >&2
        return 1
    fi

    local hide_cmd="${_RP_O[hide-cmd]}"
    local max_lines="${_RP_O[max-lines]:-0}"
    local max_output="${_RP_O[max-output]:-0}"
    local min_lines="${_RP_O[min-lines]:-5}"
    local print_output="${_RP_O[print-output]}"
    local spinner_interval="${_RP_O[spinner-interval]}"
    local title="${_RP_O[title]}"
    local use_pty="${_RP_O[pty]}"
    local term_title="${_RP_O[term-title]}"
    local term_title_active="false"
    local show_elapsed="true"
    if [[ "${_RP_O[no-elapsed]}" == "true" ]]; then
        show_elapsed="false"
    fi

    local _RP_RET=""     # scratch return slot for fork-free helpers
    local _RP_VIS=0      # visible-char count from _rp_truncate_ansi_visible
    local -a _RP_OUT=()  # captured output in display order

    _rp_spinner_frames "${_RP_O[spinner]}"
    local -a spinner_frames=("${_RP_FRAMES[@]}")

    # Expand literal \033 or \e escape sequences in the title into real ANSI codes
    printf -v title '%b' "${title}"

    local is_tty="false"
    if [[ -t 1 ]]; then
        is_tty="true"
    fi

    _rp_term_probe "${is_tty}"
    _rp_available_lines "${min_lines}"
    local available="${_RP_RET}"
    if [[ "${max_lines}" -eq 0 ]]; then
        max_lines="${available}"
    fi
    if [[ "${max_lines}" -gt "${available}" ]]; then
        max_lines="${available}"
    fi

    _rp_set_colors "${is_tty}"

    # -- Output buffers --------------------------------------------------------
    local current_line=""  # current line being built up (not yet committed to the ring)
    local start_us
    _rp_now_us start_us
    local -a ring=()
    local -a all_output=()
    local ring_head=0
    local ring_count=0
    local all_head=0
    local all_count=0

    _rp_single_all_push() {
        if [[ "${max_output}" -eq 0 ]]; then
            all_output+=("${1}")
        else
            all_output[${all_head}]="${1}"
            all_head=$(( (all_head + 1) % max_output ))
            if [[ ${all_count} -lt ${max_output} ]]; then
                all_count=$(( all_count + 1 ))
            fi
        fi
    }

    _rp_single_ring_push() {
        ring[${ring_head}]="${1}"
        ring_head=$(( (ring_head + 1) % max_lines ))
        if [[ ${ring_count} -lt ${max_lines} ]]; then
            ring_count=$(( ring_count + 1 ))
        fi
    }

    _rp_single_commit() {
        _rp_single_all_push "${current_line}"
        _rp_single_ring_push "${current_line}"
        current_line=""
    }

    _rp_single_feed() {
        _rp_feed_cr "${current_line}" "${1}"
        current_line="${_RP_RET}"
    }

    local _rp_interrupted=0
    local _rp_child_pid=""

    _rp_single_cleanup() {
        if [[ "${is_tty}" == "true" ]]; then
            printf '\033[?25h'
        fi
        if [[ "${term_title_active}" == "true" ]]; then
            _rp_term_title_pop
            term_title_active="false"
        fi
        return 0
    }

    _rp_single_on_int() {
        _rp_interrupted=1
        _rp_kill_tree "${_rp_child_pid:-}" INT
        _rp_single_cleanup
    }

    _rp_single_on_term() {
        _rp_kill_tree "${_rp_child_pid:-}" TERM
        _rp_single_cleanup
    }

    trap _rp_single_cleanup RETURN
    trap _rp_single_on_int INT
    trap _rp_single_on_term TERM

    if [[ "${is_tty}" == "true" ]]; then
        printf '\033[?25l'
        if [[ "${term_title}" == "true" ]]; then
            _rp_term_title_push
            term_title_active="true"
        fi
    fi

    # -- Launch command via coproc (stdout+stderr → read fd) -------------------
    if [[ "${use_pty}" == "true" ]]; then
        local quoted_cmd
        printf -v quoted_cmd '%q ' "${@}"
        coproc _RP { script -qefc "${quoted_cmd}" "/dev/null"; }
    else
        coproc _RP { "${@}" 2>&1; }
    fi

    # _RP_PID / _RP are set by the `coproc _RP { ... }` above.
    local cmd_pid="${_RP_PID}"
    local cmd_fd
    local cmd_str="${*}"
    _rp_child_pid="${cmd_pid}"
    exec {cmd_fd}<&"${_RP[0]}"-

    if [[ -z "${title}" ]]; then
        title="${*}"
        cmd_str=""
    fi
    if [[ "${hide_cmd}" == "true" ]]; then
        cmd_str=""
    fi
    _rp_normalize_cmd "${cmd_str}"
    cmd_str="${_RP_RET}"

    # -- Display helpers -------------------------------------------------------
    local lines_printed=0

    _rp_single_elapsed() {
        _RP_RET=""
        if [[ "${show_elapsed}" == "true" ]]; then
            _rp_fmt_elapsed "${start_us}"
        fi
    }

    _rp_single_erase() {
        local remaining="${lines_printed}"
        while [[ $(( remaining-- )) -gt 0 ]]; do
            printf '%s' "${_RP_CURSOR_UP}${_RP_ERASE_LINE}"
        done
        lines_printed=0
    }

    _rp_single_draw() {
        local spinner="${1}"
        local start
        local columns=${COLUMNS:-80}
        local previous=${lines_printed}
        local remaining=${lines_printed}

        while [[ $(( remaining-- )) -gt 0 ]]; do
            printf '%s' "${_RP_CURSOR_UP}"
        done
        lines_printed=0

        if [[ ${ring_count} -lt ${max_lines} ]]; then
            start=0
        else
            start=${ring_head}
        fi

        _rp_single_elapsed
        if [[ "${term_title_active}" == "true" ]]; then
            _rp_term_title_set "${spinner} ${title} ${_RP_RET}"
        fi
        _rp_title_line "${spinner}" "${_RP_CYAN}" "${title}" "" "${_RP_RET}" "${_RP_CYAN}"
        lines_printed=$(( lines_printed + 1 ))
        if [[ -n "${cmd_str}" ]]; then
            _rp_truncate_ansi_visible "${cmd_str}" $(( columns - 2 ))
            printf '%s%s└╴%s%s\n' "${_RP_ERASE_LINE}" "${_RP_CYAN}" "${_RP_RESET}" "${_RP_RET}"
            lines_printed=$(( lines_printed + 1 ))
        fi

        local show_cur=0
        if [[ -n "${current_line}" ]]; then
            show_cur=1
        fi
        local budget=$(( max_lines - show_cur ))
        if [[ ${budget} -lt 0 ]]; then
            budget=0
        fi
        local show_ring=${ring_count}
        if [[ ${show_ring} -gt ${budget} ]]; then
            show_ring=${budget}
        fi

        local i
        for (( i = ring_count - show_ring; i < ring_count; i++ )); do
            _rp_truncate_ansi_visible "${ring[( (start + i) % max_lines )]}" $(( columns - 2 ))
            printf '%s%s  %s%s\n' "${_RP_ERASE_LINE}" "${_RP_DIM}" "${_RP_RET}" "${_RP_RESET}"
            lines_printed=$(( lines_printed + 1 ))
        done

        if [[ ${show_cur} -ne 0 ]]; then
            _rp_truncate_ansi_visible "${current_line}" $(( columns - 2 ))
            printf '%s%s  %s%s\n' "${_RP_ERASE_LINE}" "${_RP_DIM}" "${_RP_RET}" "${_RP_RESET}"
            lines_printed=$(( lines_printed + 1 ))
        fi

        if [[ ${previous} -gt ${lines_printed} ]]; then
            local extra=$(( previous - lines_printed ))
            remaining=${extra}
            while [[ $(( remaining-- )) -gt 0 ]]; do
                printf '%s\n' "${_RP_ERASE_LINE}"
            done
            remaining=${extra}
            while [[ $(( remaining-- )) -gt 0 ]]; do
                printf '%s' "${_RP_CURSOR_UP}"
            done
        fi
    }

    # Flatten the (possibly ring-buffered) capture into _RP_OUT in order.
    _rp_single_collect() {
        _RP_OUT=()
        if [[ ${max_output} -eq 0 ]]; then
            _RP_OUT=("${all_output[@]+"${all_output[@]}"}")
        else
            local start=$(( all_count < max_output ? 0 : all_head ))
            local i
            for (( i = 0; i < all_count; i++ )); do
                _RP_OUT+=("${all_output[( (start + i) % max_output )]}")
            done
        fi
    }

    # -- Read loop -------------------------------------------------------------
    local frame=0
    local line=""
    local read_status=0

    if [[ "${is_tty}" == "true" ]]; then
        local now_us
        local last_draw_us
        _rp_interval_us "${spinner_interval}"
        local spin_us="${_RP_RET}"
        _rp_now_us last_draw_us
        _rp_sleep_fd_init || true
        _RP_READ_CARRY=""

        while :; do
            _rp_read_timed "${cmd_fd}" "${spinner_interval}" line && read_status=0 || read_status=${?}
            if [[ ${read_status} -eq 0 ]]; then
                _rp_single_feed "${line%$'\r'}"
                _rp_single_commit
            elif [[ ${read_status} -gt 128 ]]; then
                _rp_single_feed "${line}"
            elif ! kill -0 "${cmd_pid}" 2>/dev/null; then
                if [[ -n "${line}" ]]; then
                    _rp_single_feed "${line%$'\r'}"
                fi
                if [[ -n "${current_line}" ]]; then
                    _rp_single_commit
                fi
                break
            fi
            _rp_now_us now_us
            if [[ $(( now_us - last_draw_us )) -ge ${spin_us} ]]; then
                _rp_single_draw "${spinner_frames[${frame}]}"
                frame=$(( (frame + 1) % ${#spinner_frames[@]} ))
                last_draw_us=${now_us}
            fi
        done

        line=""
        while IFS= read -r -u "${cmd_fd}" line; do
            _rp_single_feed "${line%$'\r'}"
            _rp_single_commit
        done
        if [[ -n "${line}" ]]; then
            _rp_single_feed "${line%$'\r'}"
        fi
        if [[ -n "${current_line}" ]]; then
            _rp_single_commit
        fi
    else
        while IFS= read -r -u "${cmd_fd}" line; do
            _rp_single_all_push "${line}"
            printf "%s\n" "${line}"
        done
    fi
    exec {cmd_fd}<&-

    local exit_code=0
    wait "${cmd_pid}" 2>/dev/null || exit_code=${?}

    if [[ ${_rp_interrupted} -ne 0 ]]; then
        exit_code=130
    fi

    # -- Final render ----------------------------------------------------------
    _rp_single_erase
    _rp_single_collect
    local out_count=${#_RP_OUT[@]}
    local has_output="false"
    if [[ ${out_count} -gt 0 ]]; then
        has_output="true"
    fi

    if [[ "${exit_code}" == "0" ]]; then
        if [[ "${is_tty}" == "true" ]]; then
            _rp_single_elapsed
            _rp_title_line "●" "${_RP_GREEN}" "${title}" "" "${_RP_RET}" "${_RP_GREEN}"
            if [[ "${print_output}" == "true" ]]; then
                if [[ -n "${cmd_str}" ]]; then
                    _rp_cmd_branch "${_RP_GREEN}" "${cmd_str}" "${has_output}"
                fi
                _rp_dump_tree "${_RP_GREEN}" _RP_OUT
            fi
        else
            if [[ "${show_elapsed}" == "true" ]]; then
                _rp_fmt_elapsed "${start_us}"
                printf "OK: %s (%s)\n" "${title}" "${_RP_RET}"
            else
                printf "OK: %s\n" "${title}"
            fi
            if [[ "${print_output}" == "true" ]]; then
                printf '%s\n' "${_RP_OUT[@]+"${_RP_OUT[@]}"}"
            fi
        fi
    else
        if [[ "${is_tty}" == "true" ]]; then
            _rp_single_elapsed
            _rp_title_line "●" "${_RP_RED}" "${title}" " failed (exit ${exit_code})" "${_RP_RET}" "${_RP_DIM}"
            if [[ -n "${cmd_str}" ]]; then
                _rp_cmd_branch "${_RP_RED}" "${cmd_str}" "${has_output}"
            fi
            _rp_dump_tree "${_RP_RED}" _RP_OUT
        else
            if [[ "${show_elapsed}" == "true" ]]; then
                _rp_fmt_elapsed "${start_us}"
                printf "FAILED: %s (exit %s) (%s)\n" "${title}" "${exit_code}" "${_RP_RET}"
            else
                printf "FAILED: %s (exit %s)\n" "${title}" "${exit_code}"
            fi
        fi
    fi

    _rp_single_cleanup
    trap - RETURN INT TERM
    return "${exit_code}"
}

# ==============================================================================
# Parallel tasks: rp_add / rp_reset / rp_run
# ==============================================================================

# Register a task for the next rp_run.
rp_add() {
    _rp_parse_opts "${FUNCNAME[0]}" \
        "title hide-cmd print-output pty max-output spinner" \
        "${@}" || return 1
    shift "${_RP_O_SHIFT}"

    local prefix="$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}"
    if [[ $# -eq 0 ]]; then
        echo "${prefix}: no command provided" >&2
        return 1
    fi
    if [[ "${_RP_O_DASHDASH}" == "false" && "${1}" == "--"* ]]; then
        echo "${prefix}: unknown option '${1}' (use '--' before a command starting with '--')" >&2
        return 1
    fi

    local id="${#_RP_T_TITLE[@]}"
    local title
    printf -v title '%b' "${_RP_O[title]}"
    local cmd_str="${*}"
    if [[ -z "${title}" ]]; then
        title="${*}"
        cmd_str=""
    fi
    if [[ "${_RP_O[hide-cmd]}" == "true" ]]; then
        cmd_str=""
    fi
    _rp_normalize_cmd "${cmd_str}"

    _RP_T_TITLE+=("${title}")
    _RP_T_CMD+=("${_RP_RET}")
    _RP_T_HIDE_CMD+=("${_RP_O[hide-cmd]}")
    _RP_T_PRINT+=("${_RP_O[print-output]}")
    _RP_T_PTY+=("${_RP_O[pty]}")
    _RP_T_MAX_OUTPUT+=("${_RP_O[max-output]:-0}")
    _RP_T_SPINNER+=("${_RP_O[spinner]}")

    declare -ga "_RP_T_ARGV_${id}"
    # No namerefs (Bash 4.3+): safe eval, only ${id} (an integer) is expanded.
    eval "_RP_T_ARGV_${id}=(\"\${@}\")"
}

# Clear the task registry.
rp_reset() {
    local i
    for (( i = 0; i < ${#_RP_T_TITLE[@]}; i++ )); do
        unset "_RP_T_ARGV_${i}"
    done
    _RP_T_TITLE=()
    _RP_T_CMD=()
    _RP_T_HIDE_CMD=()
    _RP_T_PRINT=()
    _RP_T_PTY=()
    _RP_T_MAX_OUTPUT=()
    _RP_T_SPINNER=()
}

# -- Task side (runs in a background job, stdout = shared mux pipe) ------------

# Write one tagged record "<id>\037<kind>\037<data>", split into chunks small
# enough that each record is a single write(2) (< PIPE_BUF, and under musl's
# 1024-byte stdio buffer), so concurrent writers never interleave.
_rp_tag_emit() {
    local id="${1}"
    local kind="${2}"
    local data="${3}"
    local chunk_size=1000
    while [[ ${#data} -gt ${chunk_size} ]]; do
        printf '%s\037P\037%s\n' "${id}" "${data:0:${chunk_size}}"
        data="${data:${chunk_size}}"
    done
    printf '%s\037%s\037%s\n' "${id}" "${kind}" "${data}"
}

# Tag every line of stdin for task ${1}: L = complete line, P = partial line
# flushed after a short pause (keeps \r progress meters live).
_rp_tag() {
    local id="${1}"
    local line=""
    local read_status=0
    local LC_ALL=C
    _RP_READ_CARRY=""
    while :; do
        line=""
        _rp_read_timed 0 0.05 line && read_status=0 || read_status=${?}
        if [[ ${read_status} -eq 0 ]]; then
            _rp_tag_emit "${id}" "L" "${line}"
        elif [[ ${read_status} -gt 128 ]]; then
            if [[ -n "${line}" ]]; then
                _rp_tag_emit "${id}" "P" "${line}"
            fi
        else
            if [[ -n "${line}" ]]; then
                _rp_tag_emit "${id}" "L" "${line}"
            fi
            break
        fi
    done
}

# Run task ${1}, then write its exit record and exit with its status.
_rp_task_body() {
    local id="${1}"
    local argv_ref="_RP_T_ARGV_${id}[@]"
    local -a task_argv=("${!argv_ref}")
    local status=0
    set +e
    trap - INT TERM
    if [[ "${_RP_T_PTY[${id}]}" == "true" ]]; then
        local quoted_cmd
        printf -v quoted_cmd '%q ' "${task_argv[@]}"
        script -qefc "${quoted_cmd}" "/dev/null" < "/dev/null" 2>&1 | _rp_tag "${id}"
        status="${PIPESTATUS[0]}"
    else
        "${task_argv[@]}" < "/dev/null" 2>&1 | _rp_tag "${id}"
        status="${PIPESTATUS[0]}"
    fi
    printf '%s\037X\037%s\n' "${id}" "${status}"
    exit "${status}"
}

# -- Runner side ---------------------------------------------------------------
# Runtime state of rp_run, indexed by task id. Per-task buffers live in
# _RP_S_RING_<id> (last lines shown live), _RP_S_OUT_<id> (captured output)
# and _RP_S_SPIN_<id> (spinner frames).
_RP_S_STATE=()   # queued | running | ok | failed | cancelled | skipped
_RP_S_PID=()
_RP_S_CODE=()
_RP_S_START=()
_RP_S_END=()
_RP_S_CUR=()     # in-progress line (not yet committed)
_RP_S_RHEAD=()
_RP_S_RCOUNT=()
_RP_S_OHEAD=()
_RP_S_OCOUNT=()
_RP_S_TASKS=0
_RP_S_JOBS=0
_RP_S_NEXT=0
_RP_S_RUNNING=0
_RP_S_DONE=0
_RP_S_CLOSED="false"
_RP_S_FIRST_FAIL=""
_RP_S_SIGNAL=""
_RP_S_IS_TTY="false"
_RP_S_WINDOW=3
_RP_S_BUDGET=1
_RP_S_ELAPSED="true"
_RP_S_FRAME=0
_RP_S_PRINTED=0
_RP_S_MUX_FD=""
_RP_S_TERM_TITLE="false"  # window title is ours (pushed, to be restored)
_RP_S_RUN_START=0

# Store a line in task ${1}'s captured output (capped by --max-output).
_rp_par_out_push() {
    local id="${1}"
    local cap="${_RP_T_MAX_OUTPUT[${id}]}"
    if [[ ${cap} -eq 0 ]]; then
        eval "_RP_S_OUT_${id}+=(\"\${2}\")"
    else
        printf -v "_RP_S_OUT_${id}[${_RP_S_OHEAD[${id}]}]" '%s' "${2}"
        _RP_S_OHEAD[id]=$(( (_RP_S_OHEAD[id] + 1) % cap ))
        if [[ ${_RP_S_OCOUNT[${id}]} -lt ${cap} ]]; then
            _RP_S_OCOUNT[id]=$(( _RP_S_OCOUNT[id] + 1 ))
        fi
    fi
}

# Commit task ${1}'s in-progress line to its output and live window.
_rp_par_commit() {
    local id="${1}"
    local line="${_RP_S_CUR[${id}]}"
    _RP_S_CUR[id]=""
    _rp_par_out_push "${id}" "${line}"
    if [[ "${_RP_S_IS_TTY}" == "false" ]]; then
        printf '[%s] %s\n' "${_RP_T_TITLE[${id}]}" "${line}"
        return 0
    fi
    if [[ ${_RP_S_WINDOW} -gt 0 ]]; then
        printf -v "_RP_S_RING_${id}[${_RP_S_RHEAD[${id}]}]" '%s' "${line}"
        _RP_S_RHEAD[id]=$(( (_RP_S_RHEAD[id] + 1) % _RP_S_WINDOW ))
        if [[ ${_RP_S_RCOUNT[${id}]} -lt ${_RP_S_WINDOW} ]]; then
            _RP_S_RCOUNT[id]=$(( _RP_S_RCOUNT[id] + 1 ))
        fi
    fi
}

# Append data to task ${1}'s in-progress line.
_rp_par_feed() {
    local id="${1}"
    if [[ "${_RP_S_IS_TTY}" == "true" ]]; then
        _rp_feed_cr "${_RP_S_CUR[${id}]}" "${2}"
        _RP_S_CUR[id]="${_RP_RET}"
    else
        _RP_S_CUR[id]+="${2}"
    fi
}

# Flatten task ${1}'s captured output into _RP_OUT in order.
_rp_par_collect() {
    local id="${1}"
    local out_ref="_RP_S_OUT_${id}[@]"
    local cap="${_RP_T_MAX_OUTPUT[${id}]}"
    _RP_OUT=()
    if [[ ${cap} -eq 0 ]]; then
        _RP_OUT=("${!out_ref+"${!out_ref}"}")
    else
        local count="${_RP_S_OCOUNT[${id}]}"
        local start=$(( count < cap ? 0 : _RP_S_OHEAD[id] ))
        local i
        for (( i = 0; i < count; i++ )); do
            out_ref="_RP_S_OUT_${id}[$(( (start + i) % cap ))]"
            _RP_OUT+=("${!out_ref}")
        done
    fi
}

# Print the non-TTY summary line of finished task ${1}.
_rp_par_plain_status() {
    local id="${1}"
    local title="${_RP_T_TITLE[${id}]}"
    local elapsed=""
    if [[ "${_RP_S_ELAPSED}" == "true" ]]; then
        _rp_fmt_elapsed "${_RP_S_START[${id}]}" "${_RP_S_END[${id}]}"
        elapsed=" (${_RP_RET})"
    fi
    case "${_RP_S_STATE[${id}]}" in
        "ok")
            printf 'OK: %s%s\n' "${title}" "${elapsed}"
            if [[ "${_RP_T_PRINT[${id}]}" == "true" ]]; then
                _rp_par_collect "${id}"
                printf '%s\n' "${_RP_OUT[@]+"${_RP_OUT[@]}"}"
            fi ;;
        "failed")
            printf 'FAILED: %s (exit %s)%s\n' "${title}" "${_RP_S_CODE[${id}]}" "${elapsed}" ;;
        "cancelled")
            printf 'CANCELLED: %s%s\n' "${title}" "${elapsed}" ;;
        "skipped")
            printf 'SKIPPED: %s\n' "${title}" ;;
    esac
}

# Start task ${1} as its own background job (own process group under set -m).
_rp_par_launch() {
    local id="${1}"
    _RP_S_STATE[id]="running"
    _rp_now_us "_RP_S_START[${id}]"
    _rp_task_body "${id}" >&"${_RP_S_MUX_FD}" 2>&1 {_RP_S_MUX_FD}>&- &
    _RP_S_PID[id]="${!}"
    _RP_S_RUNNING=$(( _RP_S_RUNNING + 1 ))
}

# Launch queued tasks while a job slot is free.
_rp_par_fill() {
    while [[ "${_RP_S_CLOSED}" == "false" \
          && ${_RP_S_RUNNING} -lt ${_RP_S_JOBS} \
          && ${_RP_S_NEXT} -lt ${_RP_S_TASKS} ]]; do
        _rp_par_launch "${_RP_S_NEXT}"
        _RP_S_NEXT=$(( _RP_S_NEXT + 1 ))
    done
}

# Mark running task ${1} finished with ${2} (empty = take it from `wait`) and
# state ${3} (default: ok/failed from the code).
_rp_par_finish() {
    local id="${1}"
    local code="${2}"
    local state="${3:-}"
    if [[ "${_RP_S_STATE[${id}]}" != "running" ]]; then
        return 0
    fi
    if [[ -z "${code}" ]]; then
        wait "${_RP_S_PID[${id}]}" 2>/dev/null && code=0 || code=${?}
    else
        wait "${_RP_S_PID[${id}]}" 2>/dev/null || true
    fi
    if [[ -n "${_RP_S_CUR[${id}]}" ]]; then
        _rp_par_commit "${id}"
    fi
    if [[ -z "${state}" ]]; then
        state="ok"
        if [[ "${code}" != "0" ]]; then
            state="failed"
        fi
    fi
    _rp_now_us "_RP_S_END[${id}]"
    _RP_S_CODE[id]="${code}"
    _RP_S_STATE[id]="${state}"
    _RP_S_RUNNING=$(( _RP_S_RUNNING - 1 ))
    _RP_S_DONE=$(( _RP_S_DONE + 1 ))
    if [[ "${state}" == "failed" && -z "${_RP_S_FIRST_FAIL}" ]]; then
        _RP_S_FIRST_FAIL="${code}"
    fi
    if [[ "${_RP_S_IS_TTY}" == "false" ]]; then
        _rp_par_plain_status "${id}"
    fi
}

# Cancel every running task and skip every queued one.
_rp_par_cancel_all() {
    local id
    _RP_S_CLOSED="true"
    for (( id = 0; id < _RP_S_TASKS; id++ )); do
        if [[ "${_RP_S_STATE[${id}]}" == "running" ]]; then
            _rp_kill_tree "${_RP_S_PID[${id}]}" TERM
        fi
    done
    for (( id = 0; id < _RP_S_TASKS; id++ )); do
        if [[ "${_RP_S_STATE[${id}]}" == "running" ]]; then
            _rp_par_finish "${id}" "" "cancelled"
        elif [[ "${_RP_S_STATE[${id}]}" == "queued" ]]; then
            _RP_S_STATE[id]="skipped"
            _RP_S_DONE=$(( _RP_S_DONE + 1 ))
            if [[ "${_RP_S_IS_TTY}" == "false" ]]; then
                _rp_par_plain_status "${id}"
            fi
        fi
    done
}

# Dispatch one record read from the mux pipe.
_rp_par_record() {
    local record="${1}"
    local id="${record%%$'\037'*}"
    if [[ ! "${id}" =~ ^[0-9]+$ || ${id} -ge ${_RP_S_TASKS} ]]; then
        return 0
    fi
    local rest="${record#*$'\037'}"
    local kind="${rest%%$'\037'*}"
    local data="${rest#*$'\037'}"
    case "${kind}" in
        "L")
            if [[ "${_RP_S_IS_TTY}" == "true" ]]; then
                data="${data%$'\r'}"
            fi
            _rp_par_feed "${id}" "${data}"
            _rp_par_commit "${id}" ;;
        "P")
            _rp_par_feed "${id}" "${data}" ;;
        "X")
            _rp_par_finish "${id}" "${data}"
            if [[ "${_RP_S_STATE[${id}]}" == "failed" && "${_RP_O_FAIL_FAST}" == "true" ]]; then
                _rp_par_cancel_all
            fi
            _rp_par_fill ;;
    esac
}

# Detect running tasks that died without an exit record (e.g. SIGKILL).
_rp_par_reap_lost() {
    local id
    for (( id = 0; id < _RP_S_TASKS; id++ )); do
        if [[ "${_RP_S_STATE[${id}]}" == "running" ]]; then
            if ! kill -0 "${_RP_S_PID[${id}]}" 2>/dev/null; then
                _rp_par_finish "${id}" ""
                if [[ "${_RP_S_STATE[${id}]}" == "failed" && "${_RP_O_FAIL_FAST}" == "true" ]]; then
                    _rp_par_cancel_all
                fi
            fi
        fi
    done
    _rp_par_fill
}

# Status line of task ${1}.
_rp_par_task_line() {
    local id="${1}"
    local glyph="●"
    local color="${_RP_GREEN}"
    local suffix=""
    local right=""
    local right_color="${_RP_DIM}"
    local state="${_RP_S_STATE[${id}]}"

    if [[ "${_RP_S_ELAPSED}" == "true" ]]; then
        if [[ "${state}" == "running" ]]; then
            _rp_fmt_elapsed "${_RP_S_START[${id}]}"
            right="${_RP_RET}"
        elif [[ -n "${_RP_S_END[${id}]}" ]]; then
            _rp_fmt_elapsed "${_RP_S_START[${id}]}" "${_RP_S_END[${id}]}"
            right="${_RP_RET}"
        fi
    fi

    case "${state}" in
        "running")
            local spin_ref="_RP_S_SPIN_${id}[@]"
            local -a spin_frames=("${!spin_ref}")
            glyph="${spin_frames[$(( _RP_S_FRAME % ${#spin_frames[@]} ))]}"
            color="${_RP_CYAN}"
            right_color="${_RP_CYAN}" ;;
        "ok")
            right_color="${_RP_GREEN}" ;;
        "failed")
            color="${_RP_RED}"
            suffix=" failed (exit ${_RP_S_CODE[${id}]})" ;;
        "cancelled")
            color="${_RP_RED}"
            suffix=" cancelled" ;;
        "skipped")
            glyph="◌"
            color="${_RP_DIM}"
            suffix=" skipped" ;;
        "queued")
            glyph="◌"
            color="${_RP_DIM}"
            right="queued" ;;
    esac
    _rp_title_line "${glyph}" "${color}" "${_RP_T_TITLE[${id}]}" "${suffix}" "${right}" "${right_color}"
}

# Last ${2} live lines (ring + in-progress line) of task ${1}; returns the
# number of rows printed in _RP_RET.
_rp_par_task_window() {
    local id="${1}"
    local rows="${2}"
    local columns="${COLUMNS:-80}"
    local ring_ref
    local count="${_RP_S_RCOUNT[${id}]}"
    local start=0
    if [[ ${count} -ge ${_RP_S_WINDOW} ]]; then
        start="${_RP_S_RHEAD[${id}]}"
    fi
    local current="${_RP_S_CUR[${id}]}"
    local show_cur=0
    if [[ -n "${current}" ]]; then
        show_cur=1
    fi
    local budget=$(( rows - show_cur ))
    if [[ ${budget} -lt 0 ]]; then
        budget=0
        show_cur=${rows}
    fi
    local show_ring=${count}
    if [[ ${show_ring} -gt ${budget} ]]; then
        show_ring=${budget}
    fi
    local printed=0
    local i
    for (( i = count - show_ring; i < count; i++ )); do
        ring_ref="_RP_S_RING_${id}[$(( (start + i) % _RP_S_WINDOW ))]"
        _rp_truncate_ansi_visible "${!ring_ref}" $(( columns - 4 ))
        printf '%s%s    %s%s\n' "${_RP_ERASE_LINE}" "${_RP_DIM}" "${_RP_RET}" "${_RP_RESET}"
        printed=$(( printed + 1 ))
    done
    if [[ ${show_cur} -gt 0 ]]; then
        _rp_truncate_ansi_visible "${current}" $(( columns - 4 ))
        printf '%s%s    %s%s\n' "${_RP_ERASE_LINE}" "${_RP_DIM}" "${_RP_RET}" "${_RP_RESET}"
        printed=$(( printed + 1 ))
    fi
    _RP_RET="${printed}"
}

# Redraw the whole live block in place.
_rp_par_draw() {
    local previous="${_RP_S_PRINTED}"
    local remaining="${_RP_S_PRINTED}"
    local printed=0
    local id
    while [[ $(( remaining-- )) -gt 0 ]]; do
        printf '%s' "${_RP_CURSOR_UP}"
    done

    if [[ ${_RP_S_TASKS} -le ${_RP_S_BUDGET} ]]; then
        # Every task gets a status line; running ones share the rest.
        local per_task=0
        if [[ ${_RP_S_RUNNING} -gt 0 ]]; then
            per_task=$(( (_RP_S_BUDGET - _RP_S_TASKS) / _RP_S_RUNNING ))
        fi
        if [[ ${per_task} -gt ${_RP_S_WINDOW} ]]; then
            per_task=${_RP_S_WINDOW}
        fi
        for (( id = 0; id < _RP_S_TASKS; id++ )); do
            _rp_par_task_line "${id}"
            printed=$(( printed + 1 ))
            if [[ "${_RP_S_STATE[${id}]}" == "running" && ${per_task} -gt 0 ]]; then
                _rp_par_task_window "${id}" "${per_task}"
                printed=$(( printed + _RP_RET ))
            fi
        done
    else
        # Too many tasks for the terminal: running tasks + one summary line.
        local shown=0
        for (( id = 0; id < _RP_S_TASKS; id++ )); do
            if [[ "${_RP_S_STATE[${id}]}" == "running" && ${shown} -lt $(( _RP_S_BUDGET - 1 )) ]]; then
                _rp_par_task_line "${id}"
                shown=$(( shown + 1 ))
            fi
        done
        _rp_par_counts
        printf '%s%s◌ %s%s\n' "${_RP_ERASE_LINE}" "${_RP_DIM}" "${_RP_RET}" "${_RP_RESET}"
        printed=$(( shown + 1 ))
    fi

    if [[ ${previous} -gt ${printed} ]]; then
        local extra=$(( previous - printed ))
        remaining=${extra}
        while [[ $(( remaining-- )) -gt 0 ]]; do
            printf '%s\n' "${_RP_ERASE_LINE}"
        done
        remaining=${extra}
        while [[ $(( remaining-- )) -gt 0 ]]; do
            printf '%s' "${_RP_CURSOR_UP}"
        done
    fi
    _RP_S_PRINTED=${printed}
    if [[ "${_RP_S_TERM_TITLE}" == "true" ]]; then
        _rp_par_term_title
    fi
}

# "2 running · 3 ok · 1 failed …" (non-zero states only) → _RP_RET.
_rp_par_counts() {
    local state
    local id
    local text=""
    for state in running queued ok failed cancelled skipped; do
        local count=0
        for (( id = 0; id < _RP_S_TASKS; id++ )); do
            if [[ "${_RP_S_STATE[${id}]}" == "${state}" ]]; then
                count=$(( count + 1 ))
            fi
        done
        if [[ ${count} -gt 0 ]]; then
            if [[ -n "${text}" ]]; then
                text+=" · "
            fi
            text+="${count} ${state}"
        fi
    done
    _RP_RET="${text}"
}

# Erase the live block.
_rp_par_erase() {
    local remaining="${_RP_S_PRINTED}"
    while [[ $(( remaining-- )) -gt 0 ]]; do
        printf '%s' "${_RP_CURSOR_UP}${_RP_ERASE_LINE}"
    done
    _RP_S_PRINTED=0
}

# Final per-task report on a TTY.
_rp_par_render_final() {
    local id
    local state
    local cmd
    local has_output
    for (( id = 0; id < _RP_S_TASKS; id++ )); do
        state="${_RP_S_STATE[${id}]}"
        cmd="${_RP_T_CMD[${id}]}"
        _rp_par_task_line "${id}"
        _rp_par_collect "${id}"
        has_output="false"
        if [[ ${#_RP_OUT[@]} -gt 0 ]]; then
            has_output="true"
        fi
        if [[ "${state}" == "ok" && "${_RP_T_PRINT[${id}]}" == "true" ]]; then
            if [[ -n "${cmd}" ]]; then
                _rp_cmd_branch "${_RP_GREEN}" "${cmd}" "${has_output}"
            fi
            _rp_dump_tree "${_RP_GREEN}" _RP_OUT
        elif [[ "${state}" == "failed" || "${state}" == "cancelled" ]]; then
            if [[ -n "${cmd}" ]]; then
                _rp_cmd_branch "${_RP_RED}" "${cmd}" "${has_output}"
            fi
            _rp_dump_tree "${_RP_RED}" _RP_OUT
        fi
    done
}

_rp_par_cleanup() {
    if [[ "${_RP_S_IS_TTY}" == "true" ]]; then
        printf '\033[?25h'
    fi
    if [[ "${_RP_S_TERM_TITLE}" == "true" ]]; then
        _rp_term_title_pop
        _RP_S_TERM_TITLE="false"
    fi
    return 0
}

# Window title for --term-title: spinner, running count, first running task.
_rp_par_term_title() {
    local id
    local first=""
    for (( id = 0; id < _RP_S_TASKS; id++ )); do
        if [[ "${_RP_S_STATE[${id}]}" == "running" ]]; then
            first="${id}"
            break
        fi
    done
    local text="${_RP_S_DONE}/${_RP_S_TASKS} done"
    local glyph="●"
    if [[ -n "${first}" ]]; then
        local spin_ref="_RP_S_SPIN_${first}[@]"
        local -a spin_frames=("${!spin_ref}")
        glyph="${spin_frames[$(( _RP_S_FRAME % ${#spin_frames[@]} ))]}"
        text+=" · ${_RP_T_TITLE[${first}]}"
        if [[ ${_RP_S_RUNNING} -gt 1 ]]; then
            text+=" (+$(( _RP_S_RUNNING - 1 )))"
        fi
    fi
    if [[ "${_RP_S_ELAPSED}" == "true" ]]; then
        _rp_fmt_elapsed "${_RP_S_RUN_START}"
        text+=" ${_RP_RET}"
    fi
    _rp_term_title_set "${glyph} ${text}"
}

_rp_par_on_signal() {
    local id
    _RP_S_SIGNAL="${1}"
    for (( id = 0; id < _RP_S_TASKS; id++ )); do
        if [[ "${_RP_S_STATE[${id}]}" == "running" ]]; then
            _rp_kill_tree "${_RP_S_PID[${id}]}" TERM
        fi
    done
}

_RP_O_FAIL_FAST="false"

# Run every task registered with rp_add.
rp_run() {
    _rp_parse_opts "${FUNCNAME[0]}" \
        "jobs fail-fast max-lines min-lines no-elapsed spinner-interval term-title" \
        "${@}" || return 1
    shift "${_RP_O_SHIFT}"

    local prefix="$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}"
    if [[ $# -gt 0 ]]; then
        echo "${prefix}: unexpected argument '${1}'" >&2
        return 1
    fi
    if [[ ${#_RP_T_TITLE[@]} -eq 0 ]]; then
        echo "${prefix}: no task registered (use rp_add first)" >&2
        return 1
    fi

    local _RP_RET=""
    local _RP_VIS=0
    local -a _RP_OUT=()
    local spinner_interval="${_RP_O[spinner-interval]}"
    local min_lines="${_RP_O[min-lines]:-5}"
    local start_us
    _rp_now_us start_us
    local id

    # -- Runtime state ---------------------------------------------------------
    _RP_O_FAIL_FAST="${_RP_O[fail-fast]}"
    _RP_S_TASKS="${#_RP_T_TITLE[@]}"
    _RP_S_JOBS="${_RP_O[jobs]:-0}"
    if [[ ${_RP_S_JOBS} -eq 0 ]]; then
        _RP_S_JOBS="${_RP_S_TASKS}"
    fi
    _RP_S_WINDOW="${_RP_O[max-lines]:-3}"
    _RP_S_ELAPSED="true"
    if [[ "${_RP_O[no-elapsed]}" == "true" ]]; then
        _RP_S_ELAPSED="false"
    fi
    _RP_S_IS_TTY="false"
    if [[ -t 1 ]]; then
        _RP_S_IS_TTY="true"
    fi
    _RP_S_STATE=()
    _RP_S_PID=()
    _RP_S_CODE=()
    _RP_S_START=()
    _RP_S_END=()
    _RP_S_CUR=()
    _RP_S_RHEAD=()
    _RP_S_RCOUNT=()
    _RP_S_OHEAD=()
    _RP_S_OCOUNT=()
    _RP_S_NEXT=0
    _RP_S_RUNNING=0
    _RP_S_DONE=0
    _RP_S_CLOSED="false"
    _RP_S_FIRST_FAIL=""
    _RP_S_SIGNAL=""
    _RP_S_FRAME=0
    _RP_S_PRINTED=0
    for (( id = 0; id < _RP_S_TASKS; id++ )); do
        _RP_S_STATE[id]="queued"
        _RP_S_PID[id]=""
        _RP_S_CODE[id]=""
        _RP_S_START[id]=""
        _RP_S_END[id]=""
        _RP_S_CUR[id]=""
        _RP_S_RHEAD[id]=0
        _RP_S_RCOUNT[id]=0
        _RP_S_OHEAD[id]=0
        _RP_S_OCOUNT[id]=0
        declare -ga "_RP_S_RING_${id}"
        declare -ga "_RP_S_OUT_${id}"
        declare -ga "_RP_S_SPIN_${id}"
        # No namerefs (Bash 4.3+): safe eval, only ${id} (an integer) is expanded.
        eval "_RP_S_RING_${id}=()"
        eval "_RP_S_OUT_${id}=()"
        _rp_spinner_frames "${_RP_T_SPINNER[${id}]}"
        eval "_RP_S_SPIN_${id}=(\"\${_RP_FRAMES[@]}\")"
    done

    _rp_set_colors "${_RP_S_IS_TTY}"
    _rp_term_probe "${_RP_S_IS_TTY}"
    _rp_available_lines "${min_lines}"
    _RP_S_BUDGET="${_RP_RET}"
    if [[ ${_RP_S_BUDGET} -lt 1 ]]; then
        _RP_S_BUDGET=1
    fi

    # -- Shared mux pipe: opened read-write so it never reports EOF, then
    # unlinked right away (the fd keeps it alive).
    _rp_sleep_fd_init || return 1
    local mux_dir
    mux_dir="$(mktemp -d "${TMPDIR:-/tmp}/rp_run.XXXXXX")" || return 1
    if ! mkfifo "${mux_dir}/mux"; then
        rm -rf "${mux_dir}"
        return 1
    fi
    exec {_RP_S_MUX_FD}<>"${mux_dir}/mux"
    rm -rf "${mux_dir}"

    local saved_traps
    saved_traps="$(trap -p INT TERM)"
    local had_monitor="false"
    if [[ "${-}" == *m* ]]; then
        had_monitor="true"
    fi

    trap '_rp_par_on_signal INT' INT
    trap '_rp_par_on_signal TERM' TERM
    # Job control gives each task its own process group so it can be killed
    # as a whole (command, pty and tagger).
    set -m

    _RP_S_RUN_START="${start_us}"
    _RP_S_TERM_TITLE="false"
    if [[ "${_RP_S_IS_TTY}" == "true" ]]; then
        printf '\033[?25l'
        if [[ "${_RP_O[term-title]}" == "true" ]]; then
            _rp_term_title_push
            _RP_S_TERM_TITLE="true"
        fi
    fi

    # -- Main loop -------------------------------------------------------------
    _rp_interval_us "${spinner_interval}"
    local spin_us="${_RP_RET}"
    local last_draw_us
    _rp_now_us last_draw_us
    local now_us
    local record=""
    local pending=""
    local read_status=0

    _rp_par_fill
    if [[ "${_RP_S_IS_TTY}" == "true" ]]; then
        _rp_par_draw
    fi
    while [[ ${_RP_S_DONE} -lt ${_RP_S_TASKS} ]]; do
        record=""
        _rp_read_timed "${_RP_S_MUX_FD}" "${spinner_interval}" record "record" && read_status=0 || read_status=${?}
        if [[ -n "${_RP_S_SIGNAL}" ]]; then
            _rp_par_cancel_all
            break
        fi
        if [[ ${read_status} -eq 0 ]]; then
            _rp_par_record "${pending}${record}"
            pending=""
        elif [[ ${read_status} -gt 128 ]]; then
            pending+="${record}"
            _rp_par_reap_lost
        else
            _rp_par_cancel_all
            break
        fi
        if [[ "${_RP_S_IS_TTY}" == "true" ]]; then
            _rp_now_us now_us
            if [[ $(( now_us - last_draw_us )) -ge ${spin_us} ]]; then
                _RP_S_FRAME=$(( _RP_S_FRAME + 1 ))
                _rp_par_draw
                last_draw_us=${now_us}
            fi
        fi
    done

    # Drain records still buffered (late output of finished tasks).
    while IFS= read -r -t 0 -u "${_RP_S_MUX_FD}" && _rp_read_timed "${_RP_S_MUX_FD}" 0.05 record "record"; do
        _rp_par_record "${record}"
    done
    for (( id = 0; id < _RP_S_TASKS; id++ )); do
        if [[ -n "${_RP_S_CUR[${id}]}" ]]; then
            _rp_par_commit "${id}"
        fi
    done
    exec {_RP_S_MUX_FD}<&-

    if [[ "${had_monitor}" == "false" ]]; then
        set +m
    fi
    trap - INT TERM
    if [[ -n "${saved_traps}" ]]; then
        eval "${saved_traps}"
    fi

    # -- Final render ----------------------------------------------------------
    local exit_code="${_RP_S_FIRST_FAIL:-0}"
    if [[ "${_RP_S_SIGNAL}" == "INT" ]]; then
        exit_code=130
    elif [[ "${_RP_S_SIGNAL}" == "TERM" ]]; then
        exit_code=143
    fi

    _rp_par_counts
    local counts="${_RP_RET}"
    local total=""
    if [[ "${_RP_S_ELAPSED}" == "true" ]]; then
        _rp_fmt_elapsed "${start_us}"
        total="${_RP_RET}"
    fi

    if [[ "${_RP_S_IS_TTY}" == "true" ]]; then
        _rp_par_erase
        _rp_par_render_final
        local summary_color="${_RP_GREEN}"
        if [[ "${exit_code}" != "0" ]]; then
            summary_color="${_RP_RED}"
            _rp_title_line "●" "${summary_color}" "${counts}" "" "${total}" "${summary_color}"
        fi
        _rp_par_cleanup
    else
        if [[ -n "${total}" ]]; then
            printf 'SUMMARY: %s (%s)\n' "${counts}" "${total}"
        else
            printf 'SUMMARY: %s\n' "${counts}"
        fi
    fi

    for (( id = 0; id < _RP_S_TASKS; id++ )); do
        unset "_RP_S_RING_${id}"
        unset "_RP_S_OUT_${id}"
        unset "_RP_S_SPIN_${id}"
    done
    rp_reset
    return "${exit_code}"
}
