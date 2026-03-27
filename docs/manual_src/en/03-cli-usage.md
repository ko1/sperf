# CLI Usage

rperf provides a perf-like command-line interface with five main subcommands: `record`, `stat`, `exec`, `report`, and `diff`.

## rperf stat

[`rperf stat`](#index:rperf stat) is the quickest way to get a performance overview. It runs your command with [wall](#index:wall mode)-mode profiling and prints a summary to stderr.

```bash
rperf stat ruby my_app.rb
```

### Example: CPU-bound program

Here is a simple Fibonacci computation:

```ruby
# fib.rb
def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end
fib(35)
```

Running `rperf stat`:

```bash
rperf stat ruby fib.rb
```

```
 Performance stats for 'ruby fib.rb':

           744.4 ms   user
            32.0 ms   sys
           491.0 ms   real

           481.0 ms 100.0%  CPU execution
            12.0 ms         [Ruby] GC time (9 count: 6 minor, 3 major)
         154,468            [Ruby] allocated objects
          66,596            [Ruby] freed objects
              25 MB         [OS] peak memory (maxrss)
              31            [OS] context switches (10 voluntary, 21 involuntary)
               0 MB         [OS] disk I/O (0 MB read, 0 MB write)

  481 samples / 481 triggers, 0.1% profiler overhead
```

The output tells you:

- **user/sys/real**: Standard timing (like the `time` command)
- **Time breakdown**: Where wall time was spent — CPU execution, GVL blocked (I/O/sleep), GVL wait (contention), GC marking, GC sweeping
- **Ruby stats**: GC count, allocated/freed objects, YJIT ratio (if enabled)
- **OS stats**: Peak memory, context switches, disk I/O

Use `--report` to add flat and cumulative top-50 function tables to the output.

### Example: Mixed CPU and I/O

```ruby
# mixed.rb
def cpu_work(n)
  sum = 0
  n.times { |i| sum += i * i }
  sum
end

def io_work
  sleep(0.05)
end

5.times do
  cpu_work(500_000)
  io_work
end
```

Running `rperf stat`:

```bash
rperf stat ruby mixed.rb
```

Because `stat` always uses wall mode, you can see how time is divided between CPU and I/O. The `[Ruby] GVL blocked` line shows time spent sleeping/in I/O, while `CPU execution` shows compute time.

### stat options

```bash
rperf stat [options] command [args...]
```

| Option | Description |
|--------|-------------|
| `-o PATH` | Also save profile to file (default: none) |
| `-f HZ` | Sampling frequency in Hz (default: 1000) |
| `-m MODE` | `cpu` or `wall` (default: `wall`) |
| `--report` | Include flat/cumulative profile tables in output |
| `-v` | Print additional sampling statistics |

## rperf exec

[`rperf exec`](#index:rperf exec) runs a command with profiling and prints a full performance report to stderr — equivalent to `rperf stat --report`. It uses [wall](#index:wall mode) mode by default and does not save to a file.

```bash
rperf exec ruby my_app.rb
```

This prints everything `stat` shows (timing, time breakdown, GC/memory/OS stats) plus flat and cumulative top-50 function tables.

### exec options

```bash
rperf exec [options] command [args...]
```

| Option | Description |
|--------|-------------|
| `-o PATH` | Also save profile to file (default: none) |
| `-f HZ` | Sampling frequency in Hz (default: 1000) |
| `-m MODE` | `cpu` or `wall` (default: `wall`) |
| `-v` | Print additional sampling statistics |

## rperf record

[`rperf record`](#index:rperf record) profiles a command and saves the result to a file. This is the primary way to capture profiles for detailed analysis.

```bash
rperf record ruby my_app.rb
```

By default, it saves to `rperf.data` in pprof format with CPU mode.

### Example: Recording a profile

```bash
rperf record ruby fib.rb
```

This creates `rperf.data`. You can then analyze it with `rperf report` or other pprof-compatible tools.

### Choosing a profiling mode

rperf supports two profiling modes:

- **[cpu](#index:cpu mode)** (default): Measures per-thread CPU time. Best for finding functions that consume CPU cycles. Ignores time spent sleeping, in I/O, or waiting for the GVL.
- **[wall](#index:wall mode)**: Measures wall-clock time. Best for finding where wall time goes, including I/O, sleep, and GVL contention.

```bash
# CPU mode (default)
rperf record ruby my_app.rb

# Wall mode
rperf record -m wall ruby my_app.rb
```

### Choosing an output format

rperf auto-detects the format from the file extension:

```bash
# pprof format (default)
rperf record -o profile.pb.gz ruby my_app.rb

# Collapsed stacks (for FlameGraph / speedscope)
rperf record -o profile.collapsed ruby my_app.rb

# Human-readable text
rperf record -o profile.txt ruby my_app.rb
```

You can also force the format explicitly:

```bash
rperf record --format text -o profile.dat ruby my_app.rb
```

### Example: Text output

```bash
rperf record -o profile.txt ruby fib.rb
```

The text output looks like this:

```
Total: 509.5ms (cpu)
Samples: 509, Frequency: 1000Hz

 Flat:
           509.5 ms 100.0%  Object#fib (fib.rb)

 Cumulative:
           509.5 ms 100.0%  Object#fib (fib.rb)
           509.5 ms 100.0%  <main> (fib.rb)
```

### Example: Wall mode text output

```bash
rperf record -m wall -o wall_profile.txt ruby mixed.rb
```

```
Total: 311.8ms (wall)
Samples: 80, Frequency: 1000Hz

 Flat:
           250.6 ms  80.4%  [GVL blocked] (<GVL>)
            44.1 ms  14.1%  Object#cpu_work (mixed.rb)
            13.9 ms   4.5%  Integer#times (<internal:numeric>)
             3.2 ms   1.0%  Kernel#sleep (<C method>)
             0.0 ms   0.0%  [GVL wait] (<GVL>)

 Cumulative:
           311.8 ms 100.0%  Integer#times (<internal:numeric>)
           311.8 ms 100.0%  block in <main> (mixed.rb)
           311.8 ms 100.0%  <main> (mixed.rb)
           253.8 ms  81.4%  Kernel#sleep (<C method>)
           253.8 ms  81.4%  Object#io_work (mixed.rb)
           250.6 ms  80.4%  [GVL blocked] (<GVL>)
            58.0 ms  18.6%  Object#cpu_work (mixed.rb)
             0.0 ms   0.0%  [GVL wait] (<GVL>)
```

In wall mode, `[GVL blocked]` appears as the dominant cost — this is the sleep time in `io_work`. The CPU time for `cpu_work` is clearly separated.

### Verbose output

The `-v` flag prints sampling statistics to stderr during profiling:

```bash
rperf record -v ruby my_app.rb
```

```
[rperf] mode=cpu frequency=1000Hz
[rperf] sampling: 98 calls, 0.11ms total, 1.1us/call avg
[rperf] samples recorded: 904
[rperf] top 10 by flat:
[rperf]       53.4ms  50.1%  Object#cpu_work (-e)
[rperf]       17.0ms  15.9%  Integer#times (<internal:numeric>)
...
```

### record options

```bash
rperf record [options] command [args...]
```

| Option | Description |
|--------|-------------|
| `-o PATH` | Output file (default: `rperf.data`) |
| `-f HZ` | Sampling frequency in Hz (default: 1000) |
| `-m MODE` | `cpu` or `wall` (default: `cpu`) |
| `--format FMT` | `pprof`, `collapsed`, or `text` (default: auto from extension) |
| `-p, --print` | Print text profile to stdout (same as `--format=text --output=/dev/stdout`) |
| `-v` | Print sampling statistics to stderr |

## rperf report

[`rperf report`](#index:rperf report) opens a pprof profile for analysis. It wraps `go tool pprof` and requires Go to be installed.

```bash
# Open interactive web UI (default)
rperf report

# Open a specific file
rperf report profile.pb.gz

# Print top functions
rperf report --top

# Print pprof text summary
rperf report --text
```

### Example: Top and text output

Using the `fib.rb` profile recorded earlier:

```bash
rperf report --top rperf.data
```

```
Type: cpu
Showing nodes accounting for 577.31ms, 100% of 577.31ms total
      flat  flat%   sum%        cum   cum%
  577.31ms   100%   100%   577.31ms   100%  Object#fib
         0     0%   100%   577.31ms   100%  <main>
```

The default behavior (without `--top` or `--text`) opens an interactive web UI in your browser with flame graphs, top function views, and call graph visualizations powered by [pprof](#cite:ren2010).

### report options

| Option | Description |
|--------|-------------|
| `--top` | Print top functions by flat time |
| `--text` | Print pprof text summary |
| (default) | Open interactive web UI in browser |

## rperf diff

[`rperf diff`](#index:rperf diff) compares two pprof profiles, showing the difference (target - base). This is useful for measuring the impact of optimizations.

```bash
# Open diff in browser
rperf diff before.pb.gz after.pb.gz

# Print top functions by diff
rperf diff --top before.pb.gz after.pb.gz

# Print text diff
rperf diff --text before.pb.gz after.pb.gz
```

### Workflow example

```bash
# Profile the baseline
rperf record -o before.pb.gz ruby my_app.rb

# Make your optimization changes...

# Profile again
rperf record -o after.pb.gz ruby my_app.rb

# Compare
rperf diff before.pb.gz after.pb.gz
```

## rperf help

`rperf help` prints the full reference documentation, including profiling modes, output formats, synthetic frames, and diagnostic tips.

```bash
rperf help
```

This outputs detailed documentation suitable for both human reading and AI-assisted analysis.
