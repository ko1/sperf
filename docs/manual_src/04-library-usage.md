# Ruby API

rperf provides a Ruby API for programmatic profiling. This is useful when you want to profile specific sections of code, integrate profiling into test suites, or build custom profiling workflows.

## Basic usage

### Block form (recommended)

The simplest way to use rperf is with the block form of [`Rperf.start`](#index:Rperf.start). It profiles the block and returns the profiling data:

```ruby
require "rperf"

data = Rperf.start(output: "profile.pb.gz", frequency: 1000, mode: :cpu) do
  # code to profile
end
```

When `output:` is specified, the profile is automatically written to the file when the block finishes. The method also returns the raw data hash for further processing.

### Example: Profiling a Fibonacci function

```ruby
require "rperf"

def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end

data = Rperf.start(frequency: 1000, mode: :cpu) do
  fib(33)
end

Rperf.save("profile.txt", data)
```

Running this produces:

```
Total: 192.7ms (cpu)
Samples: 192, Frequency: 1000Hz

Flat:
     192.7ms 100.0%  Object#fib (example.rb)

Cumulative:
     192.7ms 100.0%  Object#fib (example.rb)
     192.7ms 100.0%  block in <main> (example.rb)
     192.7ms 100.0%  Rperf.start (lib/rperf.rb)
     192.7ms 100.0%  <main> (example.rb)
```

### Manual start/stop

For cases where block form is awkward, you can manually start and stop profiling:

```ruby
require "rperf"

Rperf.start(frequency: 1000, mode: :wall)

# ... code to profile ...

data = Rperf.stop
```

[`Rperf.stop`](#index:Rperf.stop) returns the data hash, or `nil` if the profiler was not running.

## Rperf.start parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `frequency:` | Integer | 1000 | Sampling frequency in Hz |
| `mode:` | Symbol | `:cpu` | `:cpu` or `:wall` |
| `output:` | String | `nil` | File path to write on stop |
| `verbose:` | Boolean | `false` | Print statistics to stderr |
| `format:` | Symbol | `nil` | `:pprof`, `:collapsed`, `:text`, or `nil` (auto-detect from output extension) |
| `signal:` | Integer/Boolean | `nil` | Linux only: `nil` = timer signal (default), `false` = nanosleep thread, positive integer = specific RT signal number |
| `aggregate:` | Boolean | `true` | Aggregate identical stacks during profiling to reduce memory. `false` returns raw per-sample data |

## Rperf.stop return value

`Rperf.stop` returns `nil` if the profiler was not running. Otherwise it returns a Hash:

```ruby
{
  mode: :cpu,               # or :wall
  frequency: 1000,
  sampling_count: 1234,     # number of timer callbacks
  sampling_time_ns: 56789,  # total time spent sampling (overhead)
  trigger_count: 1234,      # number of timer triggers
  detected_thread_count: 4, # threads seen during profiling
  start_time_ns: 17740...,  # CLOCK_REALTIME epoch nanos
  duration_ns: 10000000,    # profiling duration in nanos
  unique_frames: 42,        # unique frame count (aggregate: true only)
  unique_stacks: 120,       # unique stack count (aggregate: true only)
  samples: [                # Array of [frames, weight, thread_seq]
    [frames, weight, seq],  #   frames: [[path, label], ...] deepest-first
    ...                     #   weight: Integer (nanoseconds)
  ]                         #   seq: Integer (thread sequence, 1-based)
}
```

Each sample has:
- **frames**: An array of `[path, label]` pairs, ordered deepest-first (leaf frame at index 0)
- **weight**: Time in nanoseconds attributed to this sample
- **thread_seq**: Thread sequence number (1-based, assigned per profiling session)

When `aggregate: true` (default), identical stacks are merged and their weights summed. The `samples` array contains one entry per unique `(stack, thread_seq)` combination. When `aggregate: false`, every raw sample is returned individually.

## Rperf.save

[`Rperf.save`](#index:Rperf.save) writes profiling data to a file in any supported format:

```ruby
Rperf.save("profile.pb.gz", data)        # pprof format
Rperf.save("profile.collapsed", data)    # collapsed stacks
Rperf.save("profile.txt", data)          # text report
```

The format is auto-detected from the file extension. You can override it with the `format:` keyword:

```ruby
Rperf.save("output.dat", data, format: :text)
```

## Practical examples

### Profiling a web request handler

```ruby
require "rperf"

class ApplicationController
  def profile_action
    data = Rperf.start(mode: :wall) do
      # Simulate a typical request
      users = User.where(active: true).limit(100)
      result = users.map { |u| serialize_user(u) }
      render json: result
    end

    Rperf.save("request_profile.txt", data)
  end
end
```

Using wall mode here captures not just CPU time but also database I/O and any GVL contention.

### Comparing CPU and wall profiles

```ruby
require "rperf"

def workload
  # Mix of CPU and I/O
  100.times do
    compute_something
    sleep(0.001)
  end
end

# CPU profile: shows where CPU cycles go
cpu_data = Rperf.start(mode: :cpu) { workload }
Rperf.save("cpu.txt", cpu_data)

# Wall profile: shows where wall time goes
wall_data = Rperf.start(mode: :wall) { workload }
Rperf.save("wall.txt", wall_data)
```

The CPU profile will focus on `compute_something`, while the wall profile will show the `sleep` calls as `[GVL blocked]` time.

### Processing samples

You can work with the sample data programmatically. By default, samples are aggregated (identical stacks merged):

```ruby
require "rperf"

data = Rperf.start(mode: :cpu) { workload }
# data[:aggregated_samples] contains aggregated entries (one per unique stack)

# Find the hottest function
flat = Hash.new(0)
data[:aggregated_samples].each do |frames, weight, thread_seq|
  leaf_label = frames.first&.last  # frames[0] is the leaf
  flat[leaf_label] += weight
end

top = flat.sort_by { |_, w| -w }.first(5)
top.each do |label, weight_ns|
  puts "#{label}: #{weight_ns / 1_000_000.0}ms"
end
```

To get raw (non-aggregated) per-sample data, pass `aggregate: false`. Each timer tick produces a separate entry:

```ruby
data = Rperf.start(mode: :cpu, aggregate: false) { workload }
# data[:raw_samples] contains one entry per timer sample
data[:raw_samples].each do |frames, weight, thread_seq|
  puts "thread=#{thread_seq} weight=#{weight}ns depth=#{frames.size}"
end
```

### Generating collapsed stacks for FlameGraph

```ruby
require "rperf"

data = Rperf.start(mode: :cpu) { workload }
Rperf.save("profile.collapsed", data)
```

The collapsed format is one line per unique stack, compatible with Brendan Gregg's [FlameGraph](#cite:gregg2016) tools and speedscope:

```
frame1;frame2;...;leaf weight_ns
```

You can generate a flame graph SVG:

```bash
flamegraph.pl profile.collapsed > flamegraph.svg
```

Or open the `.collapsed` file directly in [speedscope](https://www.speedscope.app/).
