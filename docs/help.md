# rperf - safepoint-based sampling performance profiler for Ruby

## OVERVIEW

rperf profiles Ruby programs by sampling at safepoints and using actual
time deltas (nanoseconds) as weights to correct safepoint bias.
POSIX systems (Linux, macOS). Requires Ruby >= 3.4.0.

## CLI USAGE

    rperf record [options] command [args...]
    rperf stat [options] command [args...]
    rperf exec [options] command [args...]
    rperf report [options] [file]
    rperf help

### record: Profile and save to file.

    -o, --output PATH       Output file (default: rperf.data)
    -f, --frequency HZ      Sampling frequency in Hz (default: 1000)
    -m, --mode MODE         cpu or wall (default: cpu)
    --format FORMAT         pprof, collapsed, or text (default: auto from extension)
    -p, --print             Print text profile to stdout
                            (same as --format=text --output=/dev/stdout)
    --signal VALUE          Timer signal (Linux only): signal number, or 'false'
                            for nanosleep thread (default: auto)
    -v, --verbose           Print sampling statistics to stderr

### stat: Run command and print performance summary to stderr.

Uses wall mode by default. No file output by default.

    -o, --output PATH       Also save profile to file (default: none)
    -f, --frequency HZ      Sampling frequency in Hz (default: 1000)
    -m, --mode MODE         cpu or wall (default: wall)
    --report                Include flat/cumulative profile tables in output
    --signal VALUE          Timer signal (Linux only): signal number, or 'false'
                            for nanosleep thread (default: auto)
    -v, --verbose           Print additional sampling statistics

Shows: user/sys/real time, time breakdown (CPU execution, GVL blocked,
GVL wait, GC marking, GC sweeping), GC/memory/OS stats, and profiler overhead.
Use --report to add flat and cumulative top-50 function tables.

### exec: Run command and print full profile report to stderr.

Like `stat --report`. Uses wall mode by default. No file output by default.

    -o, --output PATH       Also save profile to file (default: none)
    -f, --frequency HZ      Sampling frequency in Hz (default: 1000)
    -m, --mode MODE         cpu or wall (default: wall)
    --signal VALUE          Timer signal (Linux only): signal number, or 'false'
                            for nanosleep thread (default: auto)
    -v, --verbose           Print additional sampling statistics

Shows: user/sys/real time, time breakdown, GC/memory/OS stats, profiler overhead,
and flat/cumulative top-50 function tables.

### report: Open pprof profile with go tool pprof. Requires Go.

    --top                   Print top functions by flat time
    --text                  Print text report

Default (no flag): opens interactive web UI in browser.
Default file: rperf.data

### diff: Compare two pprof profiles (target - base). Requires Go.

    --top                   Print top functions by diff
    --text                  Print text diff report

Default (no flag): opens diff in browser.

### Examples

    rperf record ruby app.rb
    rperf record -o profile.pb.gz ruby app.rb
    rperf record -m wall -f 500 -o profile.pb.gz ruby server.rb
    rperf record -o profile.collapsed ruby app.rb
    rperf record -o profile.txt ruby app.rb
    rperf record -p ruby app.rb
    rperf stat ruby app.rb
    rperf stat --report ruby app.rb
    rperf stat -o profile.pb.gz ruby app.rb
    rperf exec ruby app.rb
    rperf exec -m cpu ruby app.rb
    rperf report
    rperf report --top profile.pb.gz
    rperf diff before.pb.gz after.pb.gz
    rperf diff --top before.pb.gz after.pb.gz

## RUBY API

```ruby
require "rperf"

# Block form (recommended) — profiles the block and writes to file
Rperf.start(output: "profile.pb.gz", frequency: 500, mode: :cpu) do
  # code to profile
end

# Manual start/stop — returns data hash for programmatic use
Rperf.start(frequency: 1000, mode: :wall)
# ... code to profile ...
data = Rperf.stop

# Save data to file later
Rperf.save("profile.pb.gz", data)
Rperf.save("profile.collapsed", data)
Rperf.save("profile.txt", data)
```

### Rperf.start parameters

    frequency:  Sampling frequency in Hz (Integer, default: 1000)
    mode:       :cpu or :wall (Symbol, default: :cpu)
    output:     File path to write on stop (String or nil)
    verbose:    Print statistics to stderr (true/false, default: false)
    format:     :pprof, :collapsed, :text, or nil for auto-detect (Symbol or nil)

### Rperf.stop return value

nil if profiler was not running; otherwise a Hash:

```ruby
{ mode: :cpu,                      # or :wall
  frequency: 500,
  sampling_count: 1234,
  sampling_time_ns: 56789,
  detected_thread_count: 4,        # threads seen during profiling
  start_time_ns: 17740...,         # CLOCK_REALTIME epoch nanos
  duration_ns: 10000000,           # profiling duration in nanos
  aggregated_samples: [            # when aggregate: true (default)
    [frames, weight, seq],         #   frames: [[path, label], ...] deepest-first
    ...                            #   weight: Integer (nanoseconds, merged per unique stack)
  ],                               #   seq: Integer (thread sequence, 1-based)
  # --- OR ---
  raw_samples: [           # when aggregate: false
    [frames, weight, seq], #   one entry per timer sample (not merged)
    ...
  ] }
```

### Rperf.save(path, data, format: nil)

Writes data to path. format: :pprof, :collapsed, or :text.
nil auto-detects from extension.

## PROFILING MODES

- **cpu** — Measures per-thread CPU time via Linux thread clock.
  Use for: finding functions that consume CPU cycles.
  Ignores time spent sleeping, in I/O, or waiting for GVL.

- **wall** — Measures wall-clock time (CLOCK_MONOTONIC).
  Use for: finding where wall time goes, including I/O, sleep, GVL
  contention, and off-CPU waits.
  Includes synthetic frames (see below).

## OUTPUT FORMATS

### pprof (default)

Gzip-compressed protobuf. Standard pprof format.
Extension convention: `.pb.gz`
View with: `go tool pprof`, pprof-rs, or speedscope (via import).

Embedded metadata:

    comment         rperf version, mode, frequency, Ruby version
    time_nanos      profile collection start time (epoch nanoseconds)
    duration_nanos  profile duration (nanoseconds)
    doc_url         link to this documentation

Sample labels:

    thread_seq      thread sequence number (1-based, assigned per profiling session)

View comments: `go tool pprof -comments profile.pb.gz`

Group by thread: `go tool pprof -tagroot=thread_seq profile.pb.gz`

### collapsed

Plain text. One line per unique stack: `frame1;frame2;...;leaf weight`
Frames are semicolon-separated, bottom-to-top. Weight in nanoseconds.
Extension convention: `.collapsed`
Compatible with: FlameGraph (flamegraph.pl), speedscope.

### text

Human/AI-readable report. Shows total time, then flat and cumulative
top-N tables sorted by weight descending. No parsing needed.
Extension convention: `.txt`

Example output:

    Total: 1523.4ms (cpu)
    Samples: 4820, Frequency: 500Hz

     Flat:
               820.3 ms  53.8%  Array#each (app/models/user.rb)
               312.1 ms  20.5%  JSON.parse (lib/json/parser.rb)
               ...

     Cumulative:
             1,401.2 ms  92.0%  UsersController#index (app/controllers/users_controller.rb)
               ...

### Format auto-detection

Format is auto-detected from the output file extension:

    .collapsed → collapsed
    .txt       → text
    anything else → pprof

The `--format` flag (CLI) or `format:` parameter (API) overrides auto-detect.

## SYNTHETIC FRAMES

In wall mode, rperf adds synthetic frames that represent non-CPU time:

- **[GVL blocked]** — Time the thread spent off-GVL (I/O, sleep, C extension
  releasing GVL). Attributed to the stack at SUSPENDED.
- **[GVL wait]** — Time the thread spent waiting to reacquire the GVL after
  becoming ready. Indicates GVL contention. Same stack.

In both modes, GC time is tracked:

- **[GC marking]** — Time spent in GC marking phase (wall time).
- **[GC sweeping]** — Time spent in GC sweeping phase (wall time).

These always appear as the leaf (deepest) frame in a sample.

## INTERPRETING RESULTS

Weight unit is always nanoseconds regardless of mode.

- **Flat time**: weight attributed directly to a function (it was the leaf).
- **Cumulative time**: weight for all samples where the function appears
  anywhere in the stack.

High flat time → the function itself is expensive.
High cum but low flat → the function calls expensive children.

To convert: 1,000,000 ns = 1 ms, 1,000,000,000 ns = 1 s.

## DIAGNOSING COMMON PERFORMANCE PROBLEMS

**Problem: high CPU usage**
- Mode: cpu
- Look for: functions with high flat cpu time.
- Action: optimize the hot function or call it less.

**Problem: slow request / high latency**
- Mode: wall
- Look for: functions with high cum wall time.
- If [GVL blocked] is dominant → I/O or sleep is the bottleneck.
- If [GVL wait] is dominant → GVL contention; reduce GVL-holding work
  or move work to Ractors / child processes.

**Problem: GC pauses**
- Mode: cpu or wall
- Look for: [GC marking] and [GC sweeping] samples.
- High [GC marking] → too many live objects; reduce allocations.
- High [GC sweeping] → too many short-lived objects; reuse or pool.

**Problem: multithreaded app slower than expected**
- Mode: wall
- Look for: [GVL wait] time across threads.
- High [GVL wait] means threads are serialized on the GVL.

## READING COLLAPSED STACKS PROGRAMMATICALLY

Each line: `bottom_frame;...;top_frame weight_ns`

```ruby
File.readlines("profile.collapsed").each do |line|
  stack, weight = line.rpartition(" ").then { |s, _, w| [s, w.to_i] }
  frames = stack.split(";")
  # frames[0] is bottom (main), frames[-1] is leaf (hot)
end
```

## READING PPROF PROGRAMMATICALLY

Decompress + parse protobuf:

```ruby
require "zlib"; require "stringio"
raw = Zlib::GzipReader.new(StringIO.new(File.binread("profile.pb.gz"))).read
# raw is a protobuf binary; use google-protobuf gem or pprof tooling.
```

Or convert to text with pprof CLI:

    go tool pprof -text profile.pb.gz
    go tool pprof -top profile.pb.gz
    go tool pprof -flame profile.pb.gz

## ENVIRONMENT VARIABLES

Used internally by the CLI to pass options to the auto-started profiler:

    RPERF_ENABLED=1       Enable auto-start on require
    RPERF_OUTPUT=path     Output file path
    RPERF_FREQUENCY=hz    Sampling frequency
    RPERF_MODE=cpu|wall   Profiling mode
    RPERF_FORMAT=fmt      pprof, collapsed, or text
    RPERF_VERBOSE=1       Print statistics
    RPERF_SIGNAL=N|false  Timer signal number or 'false' for nanosleep (Linux only)
    RPERF_STAT=1          Enable stat mode (used by rperf stat)
    RPERF_STAT_REPORT=1   Include profile tables in stat output

## TIPS

- Default frequency (1000 Hz) works well for most cases; overhead is < 0.2%.
- For long-running production profiling, lower frequency (100-500) reduces overhead further.
- Profile representative workloads, not micro-benchmarks.
- Compare cpu and wall profiles to distinguish CPU-bound from I/O-bound.
- The verbose flag (-v) shows sampling overhead and top functions on stderr.
