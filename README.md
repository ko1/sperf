<p align="center">
  <img src="docs/logo.svg" alt="sperf logo" width="260">
</p>

# sperf

A safepoint-based sampling performance profiler for Ruby. Uses actual time deltas as sample weights to correct safepoint bias.

- Requires Ruby >= 3.4.0
- Output: pprof protobuf, collapsed stacks, or text report
- Modes: CPU time (per-thread) and wall time (with GVL/GC tracking)
- [Online manual](https://ko1.github.io/sperf/)

## Quick Start

```bash
gem install sperf

# Performance summary (wall mode, prints to stderr)
sperf stat ruby app.rb

# Profile to file
sperf record ruby app.rb                              # → sperf.data (pprof, cpu mode)
sperf record -m wall -o profile.pb.gz ruby server.rb   # wall mode, custom output

# View results (report/diff require Go: https://go.dev/dl/)
sperf report                      # open sperf.data in browser
sperf report --top profile.pb.gz  # print top functions to terminal

# Compare two profiles
sperf diff before.pb.gz after.pb.gz        # open diff in browser
sperf diff --top before.pb.gz after.pb.gz  # print diff to terminal
```

### Ruby API

```ruby
require "sperf"

# Block form — profiles and saves to file
Sperf.start(output: "profile.pb.gz", frequency: 500, mode: :cpu) do
  # code to profile
end

# Manual start/stop
Sperf.start(frequency: 1000, mode: :wall)
# ...
data = Sperf.stop
Sperf.save("profile.pb.gz", data)
```

### Environment Variables

Profile without code changes (e.g., Rails):

```bash
SPERF_ENABLED=1 SPERF_MODE=wall SPERF_OUTPUT=profile.pb.gz ruby app.rb
```

Run `sperf help` for full documentation, or see the [online manual](https://ko1.github.io/sperf/).

## Subcommands

Inspired by Linux `perf` — familiar subcommand interface for profiling workflows.

| Command | Description |
|---------|-------------|
| `sperf record` | Profile a command and save to file |
| `sperf stat` | Profile a command and print summary to stderr |
| `sperf report` | Open pprof profile with `go tool pprof` (requires Go) |
| `sperf diff` | Compare two pprof profiles (requires Go) |
| `sperf help` | Show full reference documentation |

## How It Works

### The Problem

Ruby's sampling profilers collect stack traces at **safepoints**, not at the exact timer tick. Traditional profilers assign equal weight to every sample, so if a safepoint is delayed 5ms, that delay is invisible.

### The Solution

sperf uses **time deltas as sample weights**:

```
Timer (signal or thread)         VM thread (postponed job)
────────────────────────         ────────────────────────
  every 1/frequency sec:          at next safepoint:
    rb_postponed_job_trigger()  →   sperf_sample_job()
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

sperf hooks GVL and GC events to attribute non-CPU time:

| Frame | Meaning |
|-------|---------|
| `[GVL blocked]` | Off-GVL time (I/O, sleep, C extension releasing GVL) |
| `[GVL wait]` | Waiting to reacquire the GVL (contention) |
| `[GC marking]` | Time in GC mark phase |
| `[GC sweeping]` | Time in GC sweep phase |

## Pros & Cons

### Pros

- **Safepoint-based, but accurate**: Unlike signal-based profilers (e.g., stackprof), sperf samples at safepoints. Safepoint sampling is safer — no async-signal-safety constraints, so backtraces and VM state (GC phase, GVL ownership) can be inspected reliably. The downside is less precise sampling timing, but sperf compensates by using actual time deltas as sample weights — so the profiling results faithfully reflect where time is actually spent.
- **GVL & GC visibility** (wall mode): Attributes off-GVL time, GVL contention, and GC phases to the responsible call stacks with synthetic frames.
- **Low overhead**: No extra thread on Linux (signal-based timer). Sampling overhead is ~1-5 us per sample.
- **pprof compatible**: Output works with `go tool pprof`, speedscope, and other standard tools.
- **No code changes required**: Profile any Ruby program via CLI (`sperf stat ruby app.rb`) or environment variables (`SPERF_ENABLED=1`).
- **perf-like CLI**: Familiar subcommand interface — `record`, `stat`, `report`, `diff` — inspired by Linux perf.

### Cons

- **Method-level only**: Profiles at the method level, not the line level. You can see which method is slow, but not which line within it.
- **Ruby >= 3.4.0**: Requires recent Ruby for the internal APIs used (postponed jobs, thread event hooks).
- **POSIX only**: Linux, macOS, etc. No Windows support.
- **Safepoint sampling**: Cannot sample inside C extensions or during long-running C calls that don't reach a safepoint. Time spent there is attributed to the next sample.

## Output Formats

| Format | Extension | Use case |
|--------|-----------|----------|
| pprof (default) | `.pb.gz` | `sperf report`, `go tool pprof`, speedscope |
| collapsed | `.collapsed` | FlameGraph (`flamegraph.pl`), speedscope |
| text | `.txt` | Human/AI-readable flat + cumulative report |

Format is auto-detected from extension, or set explicitly with `--format`.

## License

MIT
