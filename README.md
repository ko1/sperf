<p align="center">
  <img src="docs/logo.svg" alt="rperf logo" width="260">
</p>

<h1 align="center">rperf</h1>

<p align="center">
  <strong>Know where your Ruby spends its time — accurately.</strong><br>
  A sampling profiler that corrects safepoint bias using real time deltas.
</p>

<p align="center">
  <a href="https://rubygems.org/gems/rperf"><img src="https://img.shields.io/gem/v/rperf.svg" alt="Gem Version"></a>
  <img src="https://img.shields.io/badge/Ruby-%3E%3D%203.4.0-cc342d" alt="Ruby >= 3.4.0">
  <a href="https://ko1.github.io/rperf/docs/manual/"><img src="https://img.shields.io/badge/docs-manual-blue" alt="Manual"></a>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center">
  pprof / collapsed stacks / text report &nbsp;·&nbsp; CPU mode & wall mode (GVL + GC tracking)
</p>

<p align="center">
  <a href='https://ko1.github.io/rperf/'>Web site</a>,
  <a href='https://ko1.github.io/rperf/docs/manual/'>Online manual</a>,
  <a href='https://github.com/ko1/rperf'>GitHub repository</a>
</p>

## See It in Action

```bash
$ gem install rperf
$ rperf exec ruby fib.rb

 Performance stats for 'ruby fib.rb':

         2,326.0 ms   user
            64.5 ms   sys
         2,035.5 ms   real

         2,034.2 ms 100.0%  CPU execution
               1            [Ruby] detected threads
             7.0 ms         [Ruby] GC time (7 count: 5 minor, 2 major)
         106,078            [Ruby] allocated objects
              22 MB         [OS] peak memory (maxrss)

 Flat:
         2,034.2 ms 100.0%  Object#fibonacci (fib.rb)

 Cumulative:
         2,034.2 ms 100.0%  Object#fibonacci (fib.rb)
         2,034.2 ms 100.0%  <main> (fib.rb)

  2034 samples / 2034 triggers, 0.1% profiler overhead
```

## Quick Start

```bash
# Performance summary (wall mode, prints to stderr)
rperf stat ruby app.rb

# Record a pprof profile to file
rperf record ruby app.rb                              # → rperf.data (cpu mode)
rperf record -m wall -o profile.pb.gz ruby server.rb   # wall mode, custom output

# View results (report/diff require Go: https://go.dev/dl/)
rperf report                      # open rperf.data in browser
rperf report --top profile.pb.gz  # print top functions to terminal

# Compare two profiles
rperf diff before.pb.gz after.pb.gz        # open diff in browser
rperf diff --top before.pb.gz after.pb.gz  # print diff to terminal
```

### Ruby API

```ruby
require "rperf"

# Block form — profiles and saves to file
Rperf.start(output: "profile.pb.gz", frequency: 500, mode: :cpu) do
  # code to profile
end

# Manual start/stop
Rperf.start(frequency: 1000, mode: :wall)
# ...
data = Rperf.stop
Rperf.save("profile.pb.gz", data)
```

### Environment Variables

Profile without code changes (e.g., Rails):

```bash
RPERF_ENABLED=1 RPERF_MODE=wall RPERF_OUTPUT=profile.pb.gz ruby app.rb
```

Run `rperf help` for full documentation, or see the [online manual](https://ko1.github.io/rperf/).

## Subcommands

Inspired by Linux `perf` — familiar subcommand interface for profiling workflows.

| Command | Description |
|---------|-------------|
| `rperf record` | Profile a command and save to file |
| `rperf stat` | Profile a command and print summary to stderr |
| `rperf exec` | Profile a command and print full report to stderr |
| `rperf report` | Open pprof profile with `go tool pprof` (requires Go) |
| `rperf diff` | Compare two pprof profiles (requires Go) |
| `rperf help` | Show full reference documentation |

## How It Works

### The Challenge: Safepoint Sampling

Most Ruby profilers (e.g., stackprof) use signal handlers to capture stack traces at the exact moment the timer fires. rperf takes a different approach — it samples at **safepoints** (VM checkpoints), which is safer (no async-signal-safety concerns, reliable access to VM state) but means the sample timing can be delayed. Without correction, this delay would skew the results.

### The Fix: Weight = Real Time

rperf uses **actual elapsed time as sample weights** — so delayed samples carry proportionally more weight, and the profile matches reality:

```
Timer (signal or thread)         VM thread (postponed job)
────────────────────────         ────────────────────────
  every 1/frequency sec:          at next safepoint:
    rb_postponed_job_trigger()  →   rperf_sample_job()
                                      time_now = read_clock()
                                      weight = time_now - prev_time
                                      record(backtrace, weight)
```

On Linux, the timer uses `timer_create` + signal delivery (no extra thread).
On other platforms, a dedicated pthread with `nanosleep` is used.

If a safepoint is delayed, the sample carries proportionally more weight. The total weight equals the total time, accurately distributed across call stacks.

### Modes

| Mode | Clock | What it measures |
|------|-------|------------------|
| `cpu` (default) | `CLOCK_THREAD_CPUTIME_ID` | CPU time consumed (excludes sleep/I/O) |
| `wall` | `CLOCK_MONOTONIC` | Real elapsed time (includes everything) |

Use `cpu` to find what consumes CPU. Use `wall` to find what makes things slow (I/O, GVL contention, GC).

### Synthetic Frames (wall mode)

rperf hooks GVL and GC events to attribute non-CPU time:

| Frame | Meaning |
|-------|---------|
| `[GVL blocked]` | Off-GVL time (I/O, sleep, C extension releasing GVL) |
| `[GVL wait]` | Waiting to reacquire the GVL (contention) |
| `[GC marking]` | Time in GC mark phase |
| `[GC sweeping]` | Time in GC sweep phase |

## Why rperf?

- **Accurate despite safepoints** — Safepoint sampling is *safer* (no async-signal-safety issues), but normally *inaccurate*. rperf compensates with real time-delta weights, so profiles faithfully reflect where time is actually spent.
- **See the whole picture** (wall mode) — GVL contention, off-GVL I/O, GC marking/sweeping — all attributed to the call stacks responsible, via synthetic frames.
- **Low overhead** — Signal-based timer on Linux (no extra thread). ~1–5 µs per sample.
- **pprof compatible** — Works with `go tool pprof`, speedscope, and other standard tools out of the box.
- **Zero code changes** — Profile any Ruby program via CLI or environment variables. Drop-in for Rails, too.
- **`perf`-like CLI** — `record`, `stat`, `report`, `diff` — if you know Linux perf, you already know rperf.

### Limitations

- **Method-level only** — no line-level granularity.
- **Ruby >= 3.4.0** — uses recent VM internals (postponed jobs, thread event hooks).
- **POSIX only** — Linux, macOS. No Windows.
- **No fork support** — profiling does not follow fork(2) child processes.


## Output Formats

| Format | Extension | Use case |
|--------|-----------|----------|
| pprof (default) | `.pb.gz` | `rperf report`, `go tool pprof`, speedscope |
| collapsed | `.collapsed` | FlameGraph (`flamegraph.pl`), speedscope |
| text | `.txt` | Human/AI-readable flat + cumulative report |

Format is auto-detected from extension, or set explicitly with `--format`.

## License

MIT