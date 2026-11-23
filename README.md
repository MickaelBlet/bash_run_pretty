# run_pretty

Wrap any shell command with a live rolling output window, a braille spinner, an elapsed timer and a clean success/failure summary. Run several tasks in parallel with the same look.

![demo](docs/demo.gif)

## Features

- Live rolling window of the latest output lines, sized to the terminal
- Braille spinners and a docker-buildx-style elapsed timer
- On failure (or with `--print-output`), the captured output is replayed as a tree
- ANSI-aware truncation: colours are kept while lines are clipped to the terminal width
- `\r` progress bars stay live
- `--pty` mode for commands that only colourize or line-buffer on a TTY
- Optional terminal window title showing the spinner and state
- Plain streaming with `OK:` / `FAILED:` summaries when stdout is not a TTY
- Parallel tasks (`rp_add` / `rp_run`) with job limit and fail-fast
- Runs clean under `set -euo pipefail`

## Install

```bash
source run_pretty.sh
```

## Usage

```bash
run_pretty [options] command [args...]
```

```bash
run_pretty --title "Building" make -j8
run_pretty --print-output --max-output 20 ./run_tests.sh
```

All options accept `--opt VALUE` and `--opt=VALUE`.

| Option | Description |
| --- | --- |
| `--title T` | Header text (defaults to the command). Expands `\e` / `\033` escapes. |
| `--max-lines N` | Cap the rolling window height (`0` = fit the terminal). |
| `--min-lines N` | Floor for the window on short terminals (default `5`). |
| `--max-output N` | Cap lines retained for the final dump (`0` = keep everything). |
| `--hide-cmd` | Hide the command line under the title. |
| `--print-output` | Also print the captured output on success. |
| `--no-elapsed` | Disable the elapsed timer. |
| `--spinner S` | Spinner style (see below). |
| `--spinner-interval SECS` | Spinner frame interval. |
| `--pty` | Run under a pseudo-terminal (via `script`). |
| `--term-title` | Show the spinner and state in the terminal window title (restored on exit). |

The exit code of the wrapped command is returned.

### Spinners

`loading` (default), `loading2`, `upload`, `download`, `check`, `check2`, `check3`, `wait`

## Parallel tasks

Register tasks with `rp_add`, then run them with `rp_run`:

```bash
rp_add --title "Build" make
rp_add --title "Lint"  shellcheck ./*.sh
rp_add --title "Tests" --spinner check2 ./run_tests.sh
rp_run --jobs 2 --fail-fast
```

```bash
rp_add [--title T] [--hide-cmd] [--print-output] [--pty] [--max-output N] \
       [--spinner SPINNER] command [args...]
rp_run [--jobs N] [--fail-fast] [--max-lines N] [--min-lines N] \
       [--no-elapsed] [--spinner-interval SECS] [--term-title]
rp_reset   # clear the registry (rp_run clears it when done)
```

| `rp_run` option | Description |
| --- | --- |
| `--jobs N` | Max concurrent tasks (`0` = all, default). |
| `--fail-fast` | On first failure, cancel running tasks and skip queued ones. |
| `--max-lines N` | Live output lines per running task (default `3`, `0` = status lines only). |
| `--min-lines N` | Floor for the live window on short terminals. |
| `--no-elapsed` | Disable elapsed timers. |
| `--spinner-interval SECS` | Spinner frame interval. |
| `--term-title` | Show progress in the terminal window title. |

`rp_run` returns `0`, or the exit code of the first task to fail (`130` on INT, `143` on TERM).

## Demos and tests

```bash
bash demos.sh          # run every demo
bash demos.sh 3 14     # run only demos 3 and 14
bash test_run_pretty.sh
bash test_versions.sh [--runs N] [--jobs N] [VERSION...]   # suite on Bash 4.2 → 5.3 (Docker)
```

## Regenerating the GIF

Requires [asciinema](https://asciinema.org) and [agg](https://github.com/asciinema/agg).

```bash
bash make_gif.sh       # records demos 1 3 4 9 14 into docs/demo.gif
```

## Requirements

- Bash 4.2+ (tested on 4.2 → 5.3). On Bash < 5.3, timed reads use a byte-wise fallback to work around a `read -t` bug that drops input, so heavy parallel output is slower there.
- `script` (util-linux) for `--pty`
