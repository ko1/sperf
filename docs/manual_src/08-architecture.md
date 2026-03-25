# Architecture Overview

This chapter describes rperf's high-level architecture and the core data structures that underpin profiling. Understanding these internals helps you interpret edge cases in profiling results and appreciate the design trade-offs.

## System diagram

rperf consists of a C extension and a Ruby wrapper:

```mermaid
graph TD
    subgraph "C Extension (ext/rperf/rperf.c)"
        Timer["Timer<br/>(signal or pthread_cond_timedwait)"]
        PJ["rb_postponed_job_trigger"]
        Sample["Sample callback<br/>(rperf_sample_job)"]
        ThreadHook["Thread event hook<br/>(SUSPENDED/READY/RESUMED/EXITED)"]
        GCHook["GC event hook<br/>(ENTER/EXIT/START/END_MARK/END_SWEEP)"]
        BufA["Sample buffer A"]
        BufB["Sample buffer B"]
        Worker["Worker thread<br/>(timer + aggregation)"]
        FrameTable["Frame table<br/>(VALUE → frame_id)"]
        AggTable["Aggregation table<br/>(stack → weight)"]
    end

    subgraph "Ruby (lib/rperf.rb)"
        API["Rperf.start / Rperf.stop"]
        Encoders["Encoders<br/>(PProf / Collapsed / Text)"]
        StatOut["stat output"]
    end

    Timer -->|triggers| PJ
    PJ -->|at safepoint| Sample
    Sample -->|writes| BufA
    ThreadHook -->|writes| BufA
    GCHook -->|writes| BufA
    BufA -->|swap when full| BufB
    BufB -->|aggregated by| Worker
    Worker -->|inserts| FrameTable
    Worker -->|inserts| AggTable
    API -->|calls| Sample
    AggTable -->|read at stop| Encoders
    FrameTable -->|resolved at stop| Encoders
    Encoders --> StatOut
```

The C extension handles all performance-critical operations: timer management, sample recording, and aggregation. The Ruby layer provides the user-facing API, output encoding, and statistics formatting.

## Global profiler state

rperf uses a single global `rperf_profiler_t` struct. Only one profiling session can be active at a time ([single session](#index:single session) limitation). The struct holds:

- Timer configuration (frequency, mode, signal number)
- Double-buffered sample storage (two sample buffers + frame pools, swapped when full)
- Frame table (VALUE → uint32 frame_id, deduplicates frame references)
- Aggregation table (unique stack → accumulated weight)
- Worker thread handle (unified timer + aggregation thread)
- Thread-specific key for per-thread data
- GC phase tracking state
- Sampling overhead counters

## Per-thread data

Each thread gets a `rperf_thread_data_t` struct stored via Ruby's thread-specific data API (`rb_internal_thread_specific_set`). This tracks:

- `prev_time_ns`: Previous time reading (for computing weight)
- `prev_wall_ns`: Previous wall time reading
- `suspended_at_ns`: Wall timestamp when thread was suspended
- `ready_at_ns`: Wall timestamp when thread became ready
- `suspended_frame_start`/`depth`: Saved backtrace from SUSPENDED event
- `label_set_id`: Current label set ID (0 = no labels)

Thread data is created lazily on first encounter and freed on the `EXITED` event or at profiler stop.

## GC safety

Frame VALUEs must be protected from garbage collection. rperf wraps the profiler struct in a `TypedData` object with a custom `dmark` function that marks three regions:

1. **Both frame pools** (active and standby buffers)
2. **Frame table keys** (unique frame VALUEs, excluding synthetic frame slots)

The frame table keys array starts at 4,096 entries and grows by 2× when full. Growth allocates a new array, copies existing data, and swaps the pointer atomically (`memory_order_release`). The old array is kept alive until `stop` to prevent use-after-free if GC's mark phase is reading it concurrently. The `dmark` function loads the keys pointer with `memory_order_acquire` and the count with `memory_order_acquire` to ensure a consistent view.

## Fork safety

rperf registers a `pthread_atfork` child handler that silently stops profiling in the forked child process ([fork safety](#index:fork safety)):

- Clears the timer/signal state
- Removes event hooks
- Frees sample buffers, frame table, and aggregation table

The parent process continues profiling unaffected. The child can start a fresh profiling session if needed.

## Known limitations

### Running EC race

There is a known race condition in the Ruby VM where `rb_postponed_job_trigger` from the timer thread may set the interrupt flag on the wrong thread's execution context. This happens when a new thread's native thread starts before acquiring the GVL. The result is that timer samples may miss threads doing C busy-wait, with their CPU time leaking into the next SUSPENDED event's stack.

This is a Ruby VM bug, not a rperf bug, and affects all postponed-job-based profilers.

### Single session

Only one profiling session can be active at a time due to the global profiler state. Calling `Rperf.start` while already profiling is not supported.

### Method-level granularity

rperf profiles at the method level, not the line level. Frame labels use `rb_profile_frame_full_label` for qualified names (e.g., `Integer#times`, `MyClass#method_name`). Line numbers are not included.
