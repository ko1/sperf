# Quick Reference

## CLI cheat sheet

```bash
# Quick performance overview
rperf stat ruby my_app.rb

# Performance overview with profile tables
rperf stat --report ruby my_app.rb

# Full performance report (same as stat --report)
rperf exec ruby my_app.rb

# Record to default file (rperf.data, pprof format, cpu mode)
rperf record ruby my_app.rb

# Record with options
rperf record -m wall -f 500 -o profile.pb.gz ruby my_app.rb

# Record and print text profile to stdout
rperf record -p ruby my_app.rb

# Record to text format
rperf record -o profile.txt ruby my_app.rb

# Record to collapsed stacks
rperf record -o profile.collapsed ruby my_app.rb

# View profile in browser (requires Go)
rperf report

# Print top functions
rperf report --top profile.pb.gz

# Compare two profiles
rperf diff before.pb.gz after.pb.gz

# Full documentation
rperf help
```

## Ruby API cheat sheet

```ruby
require "rperf"

# Block form
data = Rperf.start(output: "profile.pb.gz", mode: :cpu) do
  # code to profile
end

# Manual form
Rperf.start(frequency: 1000, mode: :wall)
# ...
data = Rperf.stop

# Save to file
Rperf.save("profile.pb.gz", data)
Rperf.save("profile.collapsed", data)
Rperf.save("profile.txt", data)

# Snapshot (read data without stopping)
snap = Rperf.snapshot
Rperf.save("snap.pb.gz", snap)
snap = Rperf.snapshot(clear: true)  # reset after snapshot

# Labels (annotate samples with context)
Rperf.label(request: "abc") do
  # samples inside get request="abc" label
end
Rperf.labels       # get current labels

# Rack middleware (labels requests by endpoint)
require "rperf/middleware"
use Rperf::Middleware                    # Rails: config.middleware.use Rperf::Middleware
use Rperf::Middleware, label_key: :route # custom label key

# Active Job (labels jobs by class name)
require "rperf/active_job"
class ApplicationJob < ActiveJob::Base
  include Rperf::ActiveJobMiddleware
end

# Sidekiq (labels jobs by worker class name)
require "rperf/sidekiq"
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end
```

## Environment variables

These are used internally by the CLI to configure the auto-started profiler:

| Variable | Values | Description |
|----------|--------|-------------|
| `RPERF_ENABLED` | `1` | Enable auto-start on require |
| `RPERF_OUTPUT` | path | Output file path |
| `RPERF_FREQUENCY` | integer | Sampling frequency in Hz |
| `RPERF_MODE` | `cpu`, `wall` | Profiling mode |
| `RPERF_FORMAT` | `pprof`, `collapsed`, `text` | Output format |
| `RPERF_VERBOSE` | `1` | Print statistics to stderr |
| `RPERF_STAT` | `1` | Enable stat mode output |
| `RPERF_STAT_REPORT` | `1` | Include profile tables in stat output |
| `RPERF_STAT_COMMAND` | string | Command string shown in stat output header |
| `RPERF_AGGREGATE` | `0` | Disable sample aggregation (return raw samples) |

## Profiling mode comparison

| Aspect | cpu | wall |
|--------|-----|------|
| Clock | `CLOCK_THREAD_CPUTIME_ID` | `CLOCK_MONOTONIC` |
| I/O time | Not measured | `[GVL blocked]` |
| Sleep time | Not measured | `[GVL blocked]` |
| GVL contention | Not measured | `[GVL wait]` |
| GC time | `[GC marking]`, `[GC sweeping]` | `[GC marking]`, `[GC sweeping]` |
| Best for | CPU hotspots | Latency analysis |

## Output format comparison

| Extension | Format | Tooling required |
|-----------|--------|-----------------|
| `.pb.gz` (default) | pprof protobuf | Go (`rperf report`) |
| `.collapsed` | Collapsed stacks | flamegraph.pl or speedscope |
| `.txt` | Text report | None |

## Synthetic frames

| Frame | Mode | Meaning |
|-------|------|---------|
| `[GVL blocked]` | wall | Thread off-GVL (I/O, sleep, C ext) |
| `[GVL wait]` | wall | Thread waiting for GVL (contention) |
| `[GC marking]` | both | GC marking phase (wall time) |
| `[GC sweeping]` | both | GC sweeping phase (wall time) |
