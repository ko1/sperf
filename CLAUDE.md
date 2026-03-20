# sperf - Development Guide

## Project Overview

sperf is a safepoint-based sampling performance profiler for Ruby. It uses actual time deltas (not uniform sample counts) as weights to correct safepoint bias.

- Linux only (uses Linux kernel ABI for per-thread CPU clocks)
- Requires Ruby >= 4.0.0
- Output: pprof protobuf, collapsed stacks, or text report

## Architecture

```
ext/sperf/sperf.c    -- C extension: timer thread, GVL/GC event hooks, sampling
lib/sperf.rb         -- Ruby API: start/stop, encoders (PProf, Collapsed, Text), stat output
exe/sperf            -- CLI: record, stat, report, diff, help subcommands
test/test_sperf.rb   -- Unit tests
benchmark/           -- Accuracy benchmark suite (see benchmark/README.md)
```

## Build & Test

```bash
rake compile          # Build C extension (use CCACHE_DISABLE=1 if ccache fails)
rake test             # Run unit tests
```

## CLI Subcommands

```bash
sperf record [options] command [args...]   # Profile and save to file
sperf stat [options] command [args...]     # Profile and print summary to stderr
sperf report [options] [file]              # Open pprof profile (requires Go)
sperf diff [options] base.pb.gz target.pb.gz  # Compare two profiles (requires Go)
sperf help                                 # Full reference documentation (AI-friendly)
```

## Benchmark

```bash
cd benchmark
rake compile          # Build benchmark workload C extension
ruby check_accuracy.rb                        # Default: sperf, mixed scenarios, cpu mode
ruby check_accuracy.rb -m wall                # Wall mode
ruby check_accuracy.rb -P stackprof -m cpu    # Compare with other profilers
ruby check_accuracy.rb -l -m wall             # Run under CPU load
```

See `benchmark/README.md` for full documentation.

## Key Design Decisions

- **Weight = time delta, not sample count**: Each sample's weight is `clock_now - clock_prev` in nanoseconds. This corrects for safepoint delays.
- **Current-thread-only sampling**: Timer-triggered postponed job samples only `rb_thread_current()` (the GVL holder). Combined with GVL event hooks, this gives complete thread coverage without iterating `Thread.list`.
- **GVL event tracking** (wall mode): Hooks SUSPENDED/READY/RESUMED thread events. SUSPENDED captures backtrace + normal sample. RESUMED records `[GVL blocked]` (off-GVL time) and `[GVL wait]` (GVL contention time) as synthetic frames reusing the saved stack.
- **GC phase tracking**: Hooks GC_ENTER/GC_EXIT events. Records `[GC marking]` and `[GC sweeping]` samples with wall time weight, attributed to the stack that triggered GC.
- **Deferred string resolution**: Sampling stores raw frame VALUEs in a pool. String resolution (`rb_profile_frame_full_label`, `rb_profile_frame_path`) happens at stop time, not during sampling. This keeps the hot path allocation-free.
- **No protobuf dependency**: pprof format is encoded with a hand-written encoder in `lib/sperf.rb` (`Sperf::PProf.encode`). String table is built in Ruby at encode time.
- **Multiple output formats**: pprof (gzip protobuf), collapsed stacks (FlameGraph/speedscope), text (human/AI-readable report). Format auto-detected from file extension.
- **Two clock modes**: cpu (`CLOCK_THREAD_CPUTIME_ID`) and wall (`CLOCK_MONOTONIC`).
- **Method-level profiling**: No line numbers. Frame labels use `rb_profile_frame_full_label` for qualified names (e.g., `Integer#times`).

## Coding Notes

- The C extension uses a single global `sperf_profiler_t`. Only one profiling session at a time.
- C extension exports `_c_start`/`_c_stop`; Ruby wraps them as `Sperf.start`/`Sperf.stop` with output/verbose/block support.
- Frame pool (`VALUE *frame_pool`, initial ~1MB) stores raw frame VALUEs from `rb_profile_thread_frames`. A TypedData wrapper with `dmark` using `rb_gc_mark_locations` keeps them alive across GC.
- `rb_profile_thread_frames` writes directly into the frame pool (no intermediate buffer).
- Sample buffer and frame pool both grow by 2x on demand via `realloc`.
- Per-thread data (`sperf_thread_data_t`) is created via `sperf_thread_data_create()` and tracks per-thread timing state.
- Thread exit cleanup is handled by `RUBY_INTERNAL_THREAD_EVENT_EXITED` hook. Stop cleans up all live threads' thread-specific data.
- GVL blocked/wait synthetic frames are only recorded in wall mode (CPU time doesn't advance while off-GVL).
- GC samples always use wall time regardless of mode.
- `stat` subcommand uses wall mode fixed, outputs user/sys/real + time breakdown + GC stats + top 5 flat.
- `report` and `diff` subcommands are thin wrappers around `go tool pprof`.
- Benchmark workload methods (rw/cw/csleep/cwait) are numbered 1-1000 to appear as distinct functions in profiler output.

## Known Issues

- **`running_ec` race in Ruby VM**: `rb_postponed_job_trigger` from the timer thread may set the interrupt flag on the wrong thread's ec when a new thread's native thread starts before acquiring the GVL (`thread_pthread.c:2256` calls `ruby_thread_set_native` before `thread_sched_wait_running_turn`). This causes timer samples to miss threads doing C busy-wait, with their CPU time leaking into the next SUSPENDED event's stack. Tracked as a Ruby VM bug.
