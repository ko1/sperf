# sperf

A safepoint-based sampling performance profiler for Ruby. Uses actual time deltas as sample weights to correct safepoint bias.

- Linux only, requires Ruby >= 4.0.0
- Output: pprof protobuf, collapsed stacks, or text report
- Modes: CPU time (per-thread) and wall time (with GVL/GC tracking)

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

Run `sperf help` for full documentation (all options, output interpretation, diagnostics guide).

## Subcommands

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
Timer thread (pthread)           VM thread (postponed job)
─────────────────────           ────────────────────────
  every 1/frequency sec:          at next safepoint:
    rb_postponed_job_trigger()  →   sperf_sample_job()
                                      time_now = read_clock()
                                      weight = time_now - prev_time
                                      record(backtrace, weight)
```

If a safepoint is delayed, the sample carries proportionally more weight. The total weight equals the total time, accurately distributed across call stacks.

### Modes

| Mode | Clock | What it measures |
|------|-------|------------------|
| `cpu` (default) | Per-thread CPU clock (Linux ABI) | CPU cycles consumed (excludes sleep/I/O) |
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

## Output Formats

| Format | Extension | Use case |
|--------|-----------|----------|
| pprof (default) | `.pb.gz` | `sperf report`, `go tool pprof`, speedscope |
| collapsed | `.collapsed` | FlameGraph (`flamegraph.pl`), speedscope |
| text | `.txt` | Human/AI-readable flat + cumulative report |

Format is auto-detected from extension, or set explicitly with `--format`.

## License

MIT
