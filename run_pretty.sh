#!/usr/bin/env bash

# EPOCHREALTIME is a Bash builtin variable shellcheck cannot see assigned.
# shellcheck disable=SC2154

# ------------------------------------------------------------------------------
# run_pretty  –  Run any command with a live rolling window + spinner
#
# Usage:
#   source run_pretty.sh
#   run_pretty [--title "Title"] [--max-lines N] [--min-lines N]
#              [--max-output N] [--no-cmd] [--print-output]
#              [--no-elapsed] [--spinner SPINNER]
#              [--spinner-interval SECONDS] [--pty] command [args...]
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
#
# Spinners: loading (default), loading2, upload, download, check, check2, check3
#
# Examples:
#   run_pretty git clone https://github.com/org/repo
#   run_pretty --title "Building image"  docker build -t myapp .
#   run_pretty --title "Installing deps" --max-lines 10 npm install
#   run_pretty --title "Secret sauce" --hide-cmd ./sensitive_script.sh
#   run_pretty --max-output 500 ./verbose_script.sh  # cap failure dump to last 500 lines
#   run_pretty --spinner upload --spinner-interval 0.03 ./deploy.sh
#   run_pretty --pty --title "Tests" pytest   # force coloured/interactive output
# ------------------------------------------------------------------------------

run_pretty() {
    local hide_cmd="false"
    local max_lines=0
    local max_output=0
    local min_lines=5
    local print_output="false"
    local show_elapsed="true"
    local spinner_interval=0.10
    local spinner_name="loading"
    local title=""
    local use_pty="false"

    while [[ $# -gt 0 ]]; do
        case "${1}" in
            "--hide-cmd")
                hide_cmd="true"
                shift ;;
            "--print-output")
                print_output="true"
                shift ;;
            "--no-elapsed")
                show_elapsed="false"
                shift ;;
            "--pty")
                use_pty="true"
                shift ;;
            "--title")
                if [[ $# -le 1 ]]; then
                    echo "$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}: '--title' option require a argument" >&2
                    return 1
                fi
                title="${2}"
                shift 2 ;;
            "--title="*)
                title="${1#*=}"
                shift ;;
            "--max-lines")
                if [[ $# -le 1 ]]; then
                    echo "$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}: '--max-lines' option require a argument" >&2
                    return 1
                fi
                max_lines="${2}"
                shift 2 ;;
            "--max-lines="*)
                max_lines="${1#*=}"
                shift ;;
            "--min-lines")
                if [[ $# -le 1 ]]; then
                    echo "$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}: '--min-lines' option require a argument" >&2
                    return 1
                fi
                min_lines="${2}"
                shift 2 ;;
            "--min-lines="*)
                min_lines="${1#*=}"
                shift ;;
            "--max-output")
                if [[ $# -le 1 ]]; then
                    echo "$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}: '--max-output' option require a argument" >&2
                    return 1
                fi
                max_output="${2}"
                shift 2 ;;
            "--max-output="*)
                max_output="${1#*=}"
                shift ;;
            "--spinner")
                if [[ $# -le 1 ]]; then
                    echo "$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}: '--spinner' option require a argument" >&2
                    return 1
                fi
                spinner_name="${2}"
                shift 2 ;;
            "--spinner="*)
                spinner_name="${1#*=}"
                shift ;;
            "--spinner-interval")
                if [[ $# -le 1 ]]; then
                    echo "$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}: '--spinner-interval' option require a argument" >&2
                    return 1
                fi
                spinner_interval="${2}"
                shift 2 ;;
            "--spinner-interval="*)
                spinner_interval="${1#*=}"
                shift ;;
            "--")
                shift
                break ;;
            *)
                break ;;
        esac
    done

    if [[ $# -eq 0 ]]; then
        echo "$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}: run_pretty: no command provided" >&2
        return 1
    fi

    if [[ "${spinner_name}" != "loading"  \
       && "${spinner_name}" != "loading2" \
       && "${spinner_name}" != "upload"   \
       && "${spinner_name}" != "download" \
       && "${spinner_name}" != "check"    \
       && "${spinner_name}" != "check2"   \
       && "${spinner_name}" != "check3"   \
       && "${spinner_name}" != "wait" ]]; then
        echo "$0: line ${BASH_LINENO[0]}: ${FUNCNAME[0]}: unknown spinner_name '${spinner_name}' (Choose: loading, loading2, upload, download, check, check2, check3, wait)" >&2
        return 1
    fi

    # Spinner frame sets are reached indirectly via the nameref below (SC2034).
    # shellcheck disable=SC2034
    local spinner_loading_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    # shellcheck disable=SC2034
    local spinner_loading2_frames=('⢄' '⢂' '⢁' '⡁' '⡈' '⡐' '⡠')
    # shellcheck disable=SC2034
    local spinner_upload_frames=(
        '⣷' '⣶' '⣮' '⣦' '⣥' '⣤' '⣔' '⣌' '⣄' '⣂' '⣁' '⣀' '⡠' '⡐' '⡈' '⡀' '⠄' '⠂' '⠁' '⢁' '⠡' '⠑' '⠉' '⡉' '⠍' '⠋' '⢋' '⠫' '⠛' '⡛' '⠟' '⢟' '⠿' '⡿' '⣿'
        '⣾' '⣶' '⣵' '⣴' '⣬' '⣤' '⣢' '⣡' '⣠' '⣐' '⣈' '⣀' '⢄' '⢂' '⢁' '⢀' '⠠' '⠐' '⠈' '⡈' '⠌' '⠊' '⠉' '⢉' '⠩' '⠙' '⡙' '⠝' '⠛' '⢛' '⠻' '⡻' '⠿' '⢿' '⣿'
    )
    # shellcheck disable=SC2034
    local spinner_download_frames=(
        '⡿' '⠿' '⢟' '⠟' '⡛' '⠛' '⠫' '⢋' '⠋' '⠍' '⡉' '⠉' '⠑' '⠡' '⢁' '⠁' '⠂' '⠄' '⡀' '⡈' '⡐' '⡠' '⣀' '⣁' '⣂' '⣄' '⣌' '⣔' '⣤' '⣥' '⣦' '⣮' '⣶' '⣷' '⣿'
        '⢿' '⠿' '⡻' '⠻' '⢛' '⠛' '⠝' '⡙' '⠙' '⠩' '⢉' '⠉' '⠊' '⠌' '⡈' '⠈' '⠐' '⠠' '⢀' '⢁' '⢂' '⢄' '⣀' '⣈' '⣐' '⣠' '⣡' '⣢' '⣤' '⣬' '⣴' '⣵' '⣶' '⣾' '⣿'
    )
    # shellcheck disable=SC2034
    local spinner_check_frames=('⠉' '⠒' '⠤' '⣀' '⠤' '⠒')
    # shellcheck disable=SC2034
    local spinner_check2_frames=('⡇' '⡎' '⡜' '⡸' '⢸' '⢱' '⢣' '⢇')
    # shellcheck disable=SC2034
    local spinner_check3_frames=('⡇' '⡇' '⢸' '⢸')
    # shellcheck disable=SC2034
    local spinner_wait_frames=('●' ' ')

    # Expand literal \033 or \e escape sequences in the title into real ANSI codes
    printf -v title '%b' "${title}"

    local is_tty="false"
    if [[ -t 1 ]]; then
        is_tty="true"
    fi

    local cursor_row=1
    if [[ "${is_tty}" == "true" ]]; then
        # Terminal size via cursor-position-report (no external `tput`):
        # save cursor, jump to far corner, report position, restore.
        # `-t` so a terminal that never answers the report falls back to
        # defaults instead of hanging the call forever.
        if [[ -z "${LINES:-}" || -z "${COLUMNS:-}" ]]; then
            local _sz=()
            printf '\0337\033[9999;9999H\033[6n\0338' > "/dev/tty"
            IFS='[;' read -rsd R -t 0.5 -a _sz < "/dev/tty" 2> "/dev/null"
            if [[ -z "${LINES:-}"   && "${_sz[1]:-}" =~ ^[0-9]+$ ]]; then
                LINES="${_sz[1]}"
            fi
            if [[ -z "${COLUMNS:-}" && "${_sz[2]:-}" =~ ^[0-9]+$ ]]; then
                COLUMNS="${_sz[2]}"
            fi
        fi
        local _cpr_arr=()
        printf '\033[6n' > "/dev/tty"
        IFS='[;' read -rsd R -t 0.5 -a _cpr_arr < "/dev/tty" 2> "/dev/null"
        if [[ "${_cpr_arr[1]:-}" =~ ^[0-9]+$ ]]; then
            cursor_row="${_cpr_arr[1]}"
        fi
    fi
    if [[ -z "${LINES:-}" ]]; then
        LINES=7
    fi
    if [[ -z "${COLUMNS:-}" ]]; then
        COLUMNS=80
    fi

    local _available=$(( LINES - cursor_row - 1 ))
    if [[ "${_available}" -lt "${min_lines}" ]]; then
        _available="${min_lines}"
    fi
    if [[ "$(( LINES - 3 ))" -lt "${min_lines}" ]]; then
        _available="$(( LINES - 3 ))"
    fi

    if [[ "${max_lines}" -eq 0 ]]; then
        max_lines="${_available}"
    fi
    if [[ "${max_lines}" -gt "${_available}" ]]; then
        max_lines="${_available}"
    fi

    # -- Config ----------------------------------------------------------------
    local -n spinner_frames="spinner_${spinner_name}_frames"

    # -- ANSI helpers ----------------------------------------------------------
    local BOLD=''
    local DIM=''
    local CYAN=''
    local GREEN=''
    local RED=''
    local RESET=''
    local ERASE_LINE=''
    local CURSOR_UP=''
    if [[ "${is_tty}" == "true" ]]; then
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
        CYAN=$'\033[36m'
        GREEN=$'\033[32m'
        RED=$'\033[31m'
        RESET=$'\033[0m'
        ERASE_LINE=$'\033[2K'
        CURSOR_UP=$'\033[1A'
    fi

    # -- Output buffers --------------------------------------------------------
    local cur=""  # current line being built up (not yet committed to the ring)
    local start_us="${EPOCHREALTIME/\./}"
    local -a ring=()
    local -a all_output=()
    local ring_head=0
    local ring_count=0
    local all_head=0
    local all_count=0
    local _RP_RET=""   # scratch return slot for fork-free helpers
    local _RP_VIS=0    # visible-char count from _truncate_ansi_visible
    local -a _RP_OUT=() # captured output in display order (filled by _collect_output)

    # Elapsed time since launch as "12.3s".
    _fmt_elapsed() {
        local current_us="${EPOCHREALTIME/\./}"
        local tenths
        tenths=$(( (current_us - start_us) / 100000 ))
        _RP_RET="$(( tenths / 10 )).$(( tenths % 10 ))s"
    }

    _all_push() {
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

    local _rp_interrupted=0
    local _rp_child_pid=""

    _rp_cleanup() {
        if [[ "${is_tty}" == "true" ]]; then
            printf '\033[?25h'
        fi
        return 0
    }

    _rp_signal_child() {
        local sig="${1}"
        if [[ -z "${_rp_child_pid:-}" ]]; then
            return 0
        fi

        kill "-${sig}" -- "-${_rp_child_pid}" 2>/dev/null \
            || kill "-${sig}" "${_rp_child_pid}" 2>/dev/null \
            || true
    }

    _rp_on_int() {
        _rp_interrupted=1
        _rp_signal_child INT
        _rp_cleanup
    }

    _rp_on_term() {
        _rp_signal_child TERM
        _rp_cleanup
    }

    trap _rp_cleanup RETURN
    trap _rp_on_int INT
    trap _rp_on_term TERM

    if [[ "${is_tty}" == "true" ]]; then
        printf '\033[?25l'
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

    cmd_str="${cmd_str//[$' \t\n\r\v\f']/ }"

    while [[ "${cmd_str}" == *"  "* ]]; do
        cmd_str="${cmd_str//  / }"
    done

    # -- Ring buffer -----------------------------------------------------------
    _ring_push() {
        ring[${ring_head}]="${1}"
        ring_head=$(( (ring_head + 1) % max_lines ))
        if [[ ${ring_count} -lt ${max_lines} ]]; then
            ring_count=$(( ring_count + 1 ))
        fi
    }

    _commit() {
        _all_push "${cur}"
        _ring_push "${cur}"
        cur=""
    }

    _feed_cr() {
        local d="${1}"

        # Strip out cursor show/hide sequences injected by the PTY commands
        d="${d//$'\033'[?25h/}"
        d="${d//$'\033'[?25l/}"

        while [[ "${d}" == *$'\r'* ]]; do
            cur=""
            d="${d#*$'\r'}"
        done
        cur+="${d}"
    }

    # -- Display helpers -------------------------------------------------------
    local lines_printed=0

    # These helpers write their result into ${_RP_RET} instead of stdout, so callers
    # avoid a `$(...)` subshell fork on every line of every redraw (the hot path).
    _replace_reset() {
        local esc=$'\033'
        # Re-apply our colour after any embedded ANSI reset in the text.
        _RP_RET="${1//${esc}[0m/${esc}[0m${2}}"
    }

    _truncate_ansi_visible() {
        local rest="${1}"
        local max="${2}"
        local out=""
        local visible=0
        local esc=$'\033'
        local csi

        if [[ ${max} -le 0 ]]; then
            _RP_RET=""
            _RP_VIS=0
            return 0
        fi

        while [[ -n "${rest}" ]]; do
            if [[ "${rest:0:1}" == "${esc}" && "${rest:1:1}" == "[" && "${rest:2}" =~ ^[0-9\;\?]*[A-Za-z] ]]; then
                csi="${esc}[${BASH_REMATCH[0]}"
                out+="${csi}"
                rest="${rest:${#csi}}"
                continue
            fi

            if [[ ${visible} -ge ${max} ]]; then
                break
            fi

            out+="${rest:0:1}"
            rest="${rest:1}"
            visible=$(( visible + 1 ))
        done

        _RP_RET="${out}"
        _RP_VIS="${visible}"
    }

    _erase_display() {
        local n="${lines_printed}"
        while [[ $(( n-- )) -gt 0 ]]; do
            printf '%s' "${CURSOR_UP}${ERASE_LINE}"
        done
        lines_printed=0
    }

    # Title line "<glyph> <title>" with an optional right-aligned elapsed timer.
    _draw_title_line() {
        local glyph="${1}"
        local color="${2}"
        local txt="${3}"
        local cols="${COLUMNS:-80}"
        local right=""
        local rw=0
        if [[ "${show_elapsed}" == "true" ]]; then
            _fmt_elapsed
            right="${_RP_RET}"
            rw=$(( ${#right} + 2 ))
        fi
        _replace_reset "${txt}" "${color}${BOLD}"
        _truncate_ansi_visible "${_RP_RET}" $(( cols - 2 - rw ))
        if [[ "${show_elapsed}" == "true" ]]; then
            local pad=$(( cols - 2 - _RP_VIS - rw ))
            if [[ ${pad} -lt 1 ]]; then
                pad=1
            fi
            printf "${ERASE_LINE}${color}%s${BOLD} %s${RESET}%*s${color}%s${RESET}\n" \
                "${glyph}" "${_RP_RET}" "${pad}" "" " ${right}"
        else
            printf "${ERASE_LINE}${color}%s${BOLD} %s${RESET}\n" "${glyph}" "${_RP_RET}"
        fi
    }

    _draw_display() {
        local spinner="${1}"
        local start cols=${COLUMNS:-80}
        local prev=${lines_printed}
        local n=${lines_printed}

        while [[ $(( n-- )) -gt 0 ]]; do printf '%s' "${CURSOR_UP}"; done
        lines_printed=0

        if [[ ${ring_count} -lt ${max_lines} ]]; then start=0; else start=${ring_head}; fi

        if [[ -n "${cmd_str}" ]]; then
            _draw_title_line "${spinner}" "${CYAN}" "${title}"
            _truncate_ansi_visible "${cmd_str}" $(( cols - 2 ))
            printf "${ERASE_LINE}${CYAN}└╴${RESET}%s\n" "${_RP_RET}"
            lines_printed=$(( lines_printed + 2 ))
        else
            _draw_title_line "${spinner}" "${CYAN}" "${title}"
            lines_printed=$(( lines_printed + 1 ))
        fi

        local show_cur=0
        if [[ -n "${cur}" ]]; then
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
            _truncate_ansi_visible "${ring[( (start + i) % max_lines )]}" $(( cols - 2 ))
            printf "${ERASE_LINE}${DIM}  %s${RESET}\n" "${_RP_RET}"
            lines_printed=$(( lines_printed + 1 ))
        done

        if [[ ${show_cur} -ne 0 ]]; then
            _truncate_ansi_visible "${cur}" $(( cols - 2 ))
            printf "${ERASE_LINE}${DIM}  %s${RESET}\n" "${_RP_RET}"
            lines_printed=$(( lines_printed + 1 ))
        fi

        if [[ ${prev} -gt ${lines_printed} ]]; then
            local extra=$(( prev - lines_printed ))
            n=${extra}
            while [[ $(( n-- )) -gt 0 ]]; do printf '%s\n' "${ERASE_LINE}"; done
            n=${extra}
            while [[ $(( n-- )) -gt 0 ]]; do printf '%s' "${CURSOR_UP}"; done
        fi
    }

    # Flatten the (possibly ring-buffered) capture into _RP_OUT in order.
    _collect_output() {
        _RP_OUT=()
        if [[ ${max_output} -eq 0 ]]; then
            _RP_OUT=("${all_output[@]+"${all_output[@]}"}")
        else
            local start=$(( all_count < max_output ? 0 : all_head )) i
            for (( i = 0; i < all_count; i++ )); do
                _RP_OUT+=("${all_output[( (start + i) % max_output )]}")
            done
        fi
    }

    # Print _RP_OUT as a tree under a coloured connector (└╴ on the last line).
    _dump_tree() {
        local color="${1}"
        local n=${#_RP_OUT[@]}
        local i
        for (( i = 0; i < n; i++ )); do
            if [[ ${i} -eq $(( n - 1 )) ]]; then
                printf "${color}└╴${RESET}%s\n" "${_RP_OUT[${i}]}"
            else
                printf "${color}│ ${RESET}%s\n" "${_RP_OUT[${i}]}"
            fi
        done
    }

    # -- Read loop -------------------------------------------------------------
    local frame=0
    local line
    local rc=0

    if [[ "${is_tty}" == "true" ]]; then
        local _t
        local spin_us
        local now_us
        local last_draw_us
        # spinner_interval (e.g. "0.10") → integer microseconds, builtin only.
        local _si_int="${spinner_interval%%.*}" _si_frac=""
        if [[ "${spinner_interval}" == *.* ]]; then
            _si_frac="${spinner_interval#*.}"
        fi
        if [[ ! "${_si_int}" =~ ^[0-9]+$ ]]; then
            _si_int=0
        fi
        _si_frac="${_si_frac}000000"; _si_frac="${_si_frac:0:6}"
        spin_us=$(( 10#0${_si_int} * 1000000 + 10#0${_si_frac} ))
        if [[ ${spin_us} -lt 1 ]]; then
            spin_us=1
        fi
        _t="${EPOCHREALTIME}"; last_draw_us=$(( ${_t%.*} * 1000000 + 10#${_t#*.} ))

        while :; do
            IFS= read -r -t "${spinner_interval}" -u "${cmd_fd}" line && rc=0 || rc=${?}
            if [[ ${rc} -eq 0 ]]; then
                _feed_cr "${line%$'\r'}"
                _commit
            elif [[ ${rc} -gt 128 ]]; then
                _feed_cr "${line}"
            elif ! kill -0 "${cmd_pid}" 2>/dev/null; then
                if [[ -n "${line}" ]]; then
                    _feed_cr "${line%$'\r'}"
                fi
                if [[ -n "${cur}" ]]; then
                    _commit
                fi
                break
            fi
            _t="${EPOCHREALTIME}"; now_us=$(( ${_t%.*} * 1000000 + 10#${_t#*.} ))
            if [[ $(( now_us - last_draw_us )) -ge ${spin_us} ]]; then
                _draw_display "${spinner_frames[${frame}]}"
                frame=$(( (frame + 1) % ${#spinner_frames[@]} ))
                last_draw_us=${now_us}
            fi
        done

        while IFS= read -r -u "${cmd_fd}" line; do
            _feed_cr "${line%$'\r'}"
            _commit
        done
        if [[ -n "${line}" ]]; then
            _feed_cr "${line%$'\r'}"
        fi
        if [[ -n "${cur}" ]]; then
            _commit
        fi
    else
        while IFS= read -r -u "${cmd_fd}" line; do
            _all_push "${line}"
            printf "%s\n" "${line}"
        done
    fi

    local exit_code=0
    wait "${cmd_pid}" 2>/dev/null || exit_code=${?}

    if [[ ${_rp_interrupted} -ne 0 ]]; then
        exit_code=130
    fi

    # -- Final render ----------------------------------------------------------
    _erase_display
    _collect_output
    local out_count=${#_RP_OUT[@]}

    if [[ "${exit_code}" == "0" ]]; then
        if [[ "${is_tty}" == "true" ]]; then
            _draw_title_line "●" "${GREEN}" "${title}"
            local has_output="false"
            if [[ "${print_output}" == "true" && ${out_count} -gt 0 ]]; then
                has_output="true"
            fi
            if [[ "${print_output}" == "true" && -n "${cmd_str}" ]]; then
                if [[ "${has_output}" == "true" ]]; then
                    printf "${GREEN}├╴${RESET}${DIM}%s${RESET}\n" "${cmd_str}"
                else
                    printf "${GREEN}└╴${RESET}${DIM}%s${RESET}\n" "${cmd_str}"
                fi
            fi
            if [[ "${has_output}" == "true" ]]; then
                _dump_tree "${GREEN}"
            fi
        else
            if [[ "${show_elapsed}" == "true" ]]; then
                _fmt_elapsed; printf "OK: %s (%s)\n" "${title}" "${_RP_RET}"
            else
                printf "OK: %s\n" "${title}"
            fi
            if [[ "${print_output}" == "true" ]]; then
                printf '%s\n' "${_RP_OUT[@]+"${_RP_OUT[@]}"}"
            fi
        fi
    else
        if [[ "${is_tty}" == "true" ]]; then
            local _cols=${COLUMNS:-80}
            local _suffix=" failed (exit ${exit_code})"
            if [[ "${show_elapsed}" == "true" ]]; then
                _fmt_elapsed; local _el="${_RP_RET}" _elw=$(( ${#_RP_RET} + 1 ))
                _replace_reset "${title}" "${RED}${BOLD}"
                _truncate_ansi_visible "${_RP_RET}" $(( _cols - 2 - ${#_suffix} - _elw ))
                local _pad=$(( _cols - 2 - _RP_VIS - ${#_suffix} - _elw ))
                if [[ ${_pad} -lt 1 ]]; then
                    _pad=1
                fi
                printf "${RED}● ${BOLD}%s${RESET} ${RED}failed (exit %s)${RESET}%*s${DIM}%s${RESET}\n" \
                    "${_RP_RET}" "${exit_code}" "${_pad}" "" "${_el}"
            else
                _replace_reset "${title}" "${RED}${BOLD}"
                printf "${RED}● ${BOLD}%s${RESET} ${RED}failed (exit %s)${RESET}\n" "${_RP_RET}" "${exit_code}"
            fi
            if [[ -n "${cmd_str}" ]]; then
                if [[ ${out_count} -gt 0 ]]; then
                    printf "${RED}├╴${RESET}${DIM}%s${RESET}\n" "${cmd_str}"
                else
                    printf "${RED}└╴${RESET}${DIM}%s${RESET}\n" "${cmd_str}"
                fi
            fi
            _dump_tree "${RED}"
        else
            if [[ "${show_elapsed}" == "true" ]]; then
                _fmt_elapsed
                printf "FAILED: %s (exit %s) (%s)\n" "${title}" "${exit_code}" "${_RP_RET}"
            else
                printf "FAILED: %s (exit %s)\n" "${title}" "${exit_code}"
            fi
        fi
    fi

    _rp_cleanup
    trap - RETURN INT TERM
    return "${exit_code}"
}