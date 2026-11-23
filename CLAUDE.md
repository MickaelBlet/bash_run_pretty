# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`run_pretty.sh` provides `run_pretty`, which wraps any command with a live rolling output window, a braille spinner, an elapsed timer, and a success/failure summary. On failure (or with `--print-output`), it replays the captured output as a tree. It also provides `rp_add` / `rp_run` / `rp_reset` to run several tasks in parallel with the same look.

## Usage

```bash
# Source and call
source run_pretty.sh
run_pretty [--title "Title"] [--max-lines N] [--min-lines N] [--max-output N] \
           [--hide-cmd] [--print-output] [--no-elapsed] \
           [--spinner SPINNER] [--spinner-interval SECS] [--pty] [--term-title] command [args...]
# Spinners: loading (default), loading2, upload, download, check, check2, check3, wait

# Parallel tasks: register, then run
rp_add [--title T] [--hide-cmd] [--print-output] [--pty] [--max-output N] \
       [--spinner SPINNER] command [args...]
rp_run [--jobs N] [--fail-fast] [--max-lines N] [--min-lines N] \
       [--no-elapsed] [--spinner-interval SECS] [--term-title]
rp_reset   # clear the registry (rp_run clears it when done)

# Demos / tests
bash demos.sh [N...]
bash test_run_pretty.sh
bash test_versions.sh [--runs N] [--jobs N] [VERSION...]   # Docker bash:<v> images, 4.2 → 5.3
```

Options (all accept `--opt VALUE` and `--opt=VALUE`):

- `--title` — header text (defaults to the command). Expands `\e`/`\033` escapes.
- `--max-lines N` — cap rolling window height (0 = fit the terminal).
- `--min-lines N` — floor for that window on short terminals (default 5).
- `--max-output N` — cap lines retained for the final dump (0 = keep everything).
- `--hide-cmd` — hide the command line under the title.
- `--print-output` — also print captured output on success.
- `--no-elapsed` — disable the docker-buildx-style elapsed timer.
- `--spinner` / `--spinner-interval` — choose spinner and frame interval.
- `--pty` — run under a pseudo-terminal (via `script`) so commands that buffer or colourize only on a TTY behave as if interactive.
- `--term-title` — show the spinner and current state in the terminal window title (previous title restored on exit; also accepted by `rp_run`).

`rp_run` options:

- `--jobs N` — max concurrent tasks (0 = all, default).
- `--fail-fast` — on first failure, cancel running tasks and skip queued ones.
- `--max-lines N` — live output lines per running task (default 3, 0 = status lines only); shrinks to fit the terminal.
- Returns 0, or the exit code of the first task to fail (130 on INT, 143 on TERM).

## Constraints

- Must run on Bash 4.2+: no namerefs (`local -n`, 4.3), no `EPOCHREALTIME` directly (use `_rp_now_us`), no bare `read -t` on data fds (use `_rp_read_timed`). Test with `bash test_versions.sh` (use `--runs 3` to catch races).
- All code must be valid under `set -euo pipefail`. Write it so it runs clean with strict mode (no unset-variable errors, no unguarded non-zero exits, no broken pipes).
- Use `[[ ... ]]` for all conditionals; never `[ ... ]`.
- Code must pass `shellcheck` with no warnings.
- Limit `(( ... ))` to `for` loops and arithmetic calculation only; do not use it for conditionals.
- Don't chain a bracket condition with `&&`/`||` operators (e.g. `[[ ... ]] && cmd`); use an `if` block instead.
- Prefer multi-line statements; don't use `;` to pack commands onto one line. The only exception is the inline condition keyword of `if`/`while`/`until`/`for` (e.g. `if ...; then`, `while ...; do`).
- Declare one variable per `local`; don't chain multiple declarations on one line (e.g. not `local a=1 b=2`).
- Prefer explicit, descriptive variable names over terse abbreviations (e.g. `column` not `col`). Loop counters may use `i`/`j`.

## How it works

- Launches the command via `coproc` with stdout+stderr merged into one read fd
- Main loop reads from the fd with `read -t <spinner_interval>` to animate frames between line arrivals; elapsed-time gating decides when to redraw
- Uses a ring buffer (array + head pointer) for the last `max_lines` shown lines, and a separate (optionally capped) ring for the full captured output
- Erases and redraws the display block each frame using ANSI cursor-up + erase-line; fork-free helpers write results into `_RP_RET`/`_RP_VIS` to avoid subshells on the hot path
- ANSI-aware truncation keeps colour codes while clipping to terminal width
- Terminal size/cursor row obtained via cursor-position-report (no `tput`)
- On failure, replays the full output as a tree under a coloured connector
- When not a TTY, output is streamed through plainly with an `OK:`/`FAILED:` summary
- `_rp_single_cleanup` (trapped on RETURN/INT/TERM) restores the cursor; INT/TERM also signal the child process group
- Shared helpers are top-level `_rp_*` functions (option parser `_rp_parse_opts`, ANSI truncation, title line, tree dump, terminal probe)

Parallel (`rp_run`):

- Tasks are registered in global `_RP_T_*` arrays (argv in `_RP_T_ARGV_<id>`); runtime state lives in `_RP_S_*` arrays indexed by task id, per-task buffers in `_RP_S_RING_<id>` / `_RP_S_OUT_<id>`
- Bash `read` waits on one fd only, so every task writes tagged records `id\037kind\037data` into one shared FIFO (opened read-write then unlinked): `L` full line, `P` partial line (flushed by `_rp_tag` after 50 ms so `\r` progress stays live), `X` exit code. Records are chunked under PIPE_BUF so concurrent writes never interleave
- `set -m` gives each task its own process group so cancel/INT/TERM kill the whole tree; tasks get `/dev/null` as stdin
- Non-TTY: lines streamed as `[title] line`, then `OK:`/`FAILED:`/`CANCELLED:`/`SKIPPED:` per task and a `SUMMARY:` line
