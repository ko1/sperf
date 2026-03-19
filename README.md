# sprof

A safepoint-based sampling profiler for Ruby that uses actual time deltas as sample weights to correct safepoint bias. Outputs [pprof](https://github.com/google/pprof) format.

## The Problem with Safepoint-Based Sampling

Ruby's sampling profilers can only inspect thread state at **safepoints** -- points where the VM is in a consistent state (e.g., between bytecode instructions, at method calls). A timer fires at regular intervals, but the actual stack trace is collected at the next safepoint, not at the exact moment the timer fires. This introduces **safepoint bias**: code that executes long stretches without hitting a safepoint (e.g., C extensions, tight native loops) is underrepresented, while code near frequent safepoints is overrepresented.

Traditional sampling profilers assign equal weight (1 sample = 1 interval) to every sample regardless of when the safepoint actually occurred. If the timer fires at T=0 but the safepoint arrives at T=5ms, the 5ms delay is invisible -- the sample is counted the same as one collected instantly.

## How sprof Solves This

sprof uses **time deltas as sample weights** instead of counting samples uniformly.

### Sampling Architecture

```
Timer thread (pthread)           VM thread (postponed job)
─────────────────────           ────────────────────────
  every 1/frequency sec:          at next safepoint:
    rb_postponed_job_trigger()  →   sprof_sample_job()
                                      for each Ruby thread:
                                        time_now = read_clock()
                                        weight = time_now - prev_time
                                        prev_time = time_now
                                        record(backtrace, weight)
```

1. A **timer thread** (native pthread) fires `rb_postponed_job_trigger()` at the configured frequency (default: 100 Hz)
2. At the next safepoint, the VM executes the **sampling callback** as a postponed job
3. For each live Ruby thread, the callback:
   - Reads the current clock value (CPU time or wall time, depending on mode)
   - Computes `weight = current_time - previous_time` (nanoseconds elapsed since last sample)
   - Captures the stack trace via `rb_profile_thread_frames()`
   - Stores the sample with the computed weight

The key insight: **the weight is not the timer interval, but the actual time elapsed**. If a safepoint is delayed by 5ms, the sample carries 5ms of weight. If two safepoints are close together, the sample carries a small weight. The total weight across all samples equals the total time spent, accurately distributed across the observed call stacks.

### Clock Sources

| Mode | Clock | Scope | What it measures |
|------|-------|-------|------------------|
| `:cpu` (default) | `clock_gettime(thread_cputime_id)` | Per-thread | CPU time consumed by the thread (excludes sleep, I/O wait) |
| `:wall` | `clock_gettime(CLOCK_MONOTONIC)` | Global | Real elapsed time (includes sleep, I/O wait, scheduling delays) |

In **cpu mode**, per-thread CPU clocks are read via the Linux kernel ABI (`~tid << 3 | 6`), allowing sprof to read another thread's CPU time without signals. In **wall mode**, a single `CLOCK_MONOTONIC` read is shared across all threads for the same sampling tick.

### Per-Thread State

Each Ruby thread has a `prev_cpu_ns` value stored via `rb_internal_thread_specific_key`. The first sample for a new thread initializes this value and is skipped (no delta yet). Thread exit is handled by a `RUBY_INTERNAL_THREAD_EVENT_EXITED` hook that frees the per-thread data.

### Output

At stop time, the collected samples (stack + weight pairs) are:
1. Merged by identical stack traces (weights summed)
2. Encoded into [pprof protobuf format](https://github.com/google/pprof/blob/main/proto/profile.proto) using a hand-written encoder (no protobuf dependency)
3. Gzip-compressed and written to a `.pb.gz` file

The output is directly viewable with `go tool pprof`.

## Installation

```bash
gem install sprof
```

Requires Ruby >= 4.0.0 (Linux only; uses Linux-specific thread CPU clock ABI).

## Usage

### Ruby API

```ruby
require "sprof"

# Block form
Sprof.profile(output: "profile.pb.gz", frequency: 100, mode: :cpu) do
  # code to profile
end

# Manual start/stop
Sprof.start(frequency: 100, mode: :wall)
# ... code to profile ...
Sprof.save("profile.pb.gz")
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `frequency:` | `100` | Sampling frequency in Hz (1-1000000) |
| `mode:` | `:cpu` | `:cpu` for CPU time, `:wall` for wall time |
| `output:` | `"sprof.data"` | Output file path (block form only) |

### CLI

```bash
# Profile any Ruby command
sprof exec ruby my_app.rb
sprof -o profile.pb.gz -f 100 exec ruby my_app.rb

# View results
go tool pprof -http=:8080 profile.pb.gz
go tool pprof -top profile.pb.gz
go tool pprof -flamegraph profile.pb.gz > flame.html
```

| Flag | Default | Description |
|------|---------|-------------|
| `-o PATH` | `sprof.data` | Output file |
| `-f HZ` | `100` | Sampling frequency |

### Environment Variables

For use without code changes (e.g., profiling Rails):

```bash
SPROF_ENABLED=1 SPROF_MODE=wall SPROF_FREQUENCY=100 SPROF_OUTPUT=profile.pb.gz ruby app.rb
```

| Variable | Default | Description |
|----------|---------|-------------|
| `SPROF_ENABLED` | - | Set to `"1"` to enable |
| `SPROF_MODE` | `"cpu"` | `"cpu"` or `"wall"` |
| `SPROF_FREQUENCY` | `100` | Sampling frequency in Hz |
| `SPROF_OUTPUT` | `"sprof.data"` | Output file path |

## When to Use cpu vs wall Mode

- **cpu mode**: Use when you want to find what code is consuming CPU cycles. Sleep, I/O waits, mutex contention, and GVL waits are excluded. Results are stable regardless of system load.
- **wall mode**: Use when you want to find what code is slow from the user's perspective. Includes sleep, I/O, blocking calls, and scheduling delays. Results may vary under system load.

## License

MIT
