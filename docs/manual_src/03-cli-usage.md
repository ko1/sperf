# CLI Usage

sperf provides a perf-like command-line interface with four main subcommands: `record`, `stat`, `report`, and `diff`.

## sperf stat

`sperf stat` is the quickest way to get a performance overview. It runs your command with wall-mode profiling and prints a summary to stderr.

```bash
sperf stat ruby my_app.rb
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

Running `sperf stat`:

```bash
sperf stat ruby fib.rb
```

```
 Performance stats for 'ruby fib.rb':

           661.9 ms   user
            24.1 ms   sys
           602.8 ms   real

           590.1 ms 100.0%  CPU execution
             9.0 ms         [Ruby] GC time (8 count: 5 minor, 3 major)
          99,774            [Ruby] allocated objects
          49,270            [Ruby] freed objects
              18 MB         [OS] peak memory (maxrss)
              20            [OS] context switches (4 voluntary, 16 involuntary)
               0 MB         [OS] disk I/O (0 MB read, 0 MB write)

 Top 1 by flat:
           590.1 ms 100.0%  Object#fib (fib.rb)

  590 samples (16 unique stacks), 0.2% profiler overhead
```

The output tells you:

- **user/sys/real**: Standard timing (like the `time` command)
- **Time breakdown**: Where wall time was spent — CPU execution, GVL blocked (I/O/sleep), GVL wait (contention), GC marking, GC sweeping
- **Ruby stats**: GC count, allocated/freed objects, YJIT ratio (if enabled)
- **OS stats**: Peak memory, context switches, disk I/O
- **Top functions**: Hottest functions by flat time

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

Running `sperf stat`:

```bash
sperf stat ruby mixed.rb
```

Because `stat` always uses wall mode, you can see how time is divided between CPU and I/O. The `[Ruby] GVL blocked` line shows time spent sleeping/in I/O, while `CPU execution` shows compute time.

### stat options

```bash
sperf stat [options] command [args...]
```

| Option | Description |
|--------|-------------|
| `-o PATH` | Also save profile to file (default: none) |
| `-f HZ` | Sampling frequency in Hz (default: 1000) |
| `-v` | Print additional sampling statistics |

## sperf record

`sperf record` profiles a command and saves the result to a file. This is the primary way to capture profiles for detailed analysis.

```bash
sperf record ruby my_app.rb
```

By default, it saves to `sperf.data` in pprof format with CPU mode.

### Example: Recording a profile

```bash
sperf record ruby fib.rb
```

This creates `sperf.data`. You can then analyze it with `sperf report` or other pprof-compatible tools.

### Choosing a profiling mode

sperf supports two profiling modes:

- **cpu** (default): Measures per-thread CPU time. Best for finding functions that consume CPU cycles. Ignores time spent sleeping, in I/O, or waiting for the GVL.
- **wall**: Measures wall-clock time. Best for finding where wall time goes, including I/O, sleep, and GVL contention.

```bash
# CPU mode (default)
sperf record ruby my_app.rb

# Wall mode
sperf record -m wall ruby my_app.rb
```

### Choosing an output format

sperf auto-detects the format from the file extension:

```bash
# pprof format (default)
sperf record -o profile.pb.gz ruby my_app.rb

# Collapsed stacks (for FlameGraph / speedscope)
sperf record -o profile.collapsed ruby my_app.rb

# Human-readable text
sperf record -o profile.txt ruby my_app.rb
```

You can also force the format explicitly:

```bash
sperf record --format text -o profile.dat ruby my_app.rb
```

### Example: Text output

```bash
sperf record -o profile.txt ruby fib.rb
```

The text output looks like this:

```
Total: 509.5ms (cpu)
Samples: 509, Frequency: 1000Hz

Flat:
     509.5ms 100.0%  Object#fib (fib.rb)

Cumulative:
     509.5ms 100.0%  Object#fib (fib.rb)
     509.5ms 100.0%  <main> (fib.rb)
```

### Example: Wall mode text output

```bash
sperf record -m wall -o wall_profile.txt ruby mixed.rb
```

```
Total: 311.8ms (wall)
Samples: 80, Frequency: 1000Hz

Flat:
     250.6ms  80.4%  [GVL blocked] (<GVL>)
      44.1ms  14.1%  Object#cpu_work (mixed.rb)
      13.9ms   4.5%  Integer#times (<internal:numeric>)
       3.2ms   1.0%  Kernel#sleep (<C method>)
       0.0ms   0.0%  [GVL wait] (<GVL>)

Cumulative:
     311.8ms 100.0%  Integer#times (<internal:numeric>)
     311.8ms 100.0%  block in <main> (mixed.rb)
     311.8ms 100.0%  <main> (mixed.rb)
     253.8ms  81.4%  Kernel#sleep (<C method>)
     253.8ms  81.4%  Object#io_work (mixed.rb)
     250.6ms  80.4%  [GVL blocked] (<GVL>)
      58.0ms  18.6%  Object#cpu_work (mixed.rb)
       0.0ms   0.0%  [GVL wait] (<GVL>)
```

In wall mode, `[GVL blocked]` appears as the dominant cost — this is the sleep time in `io_work`. The CPU time for `cpu_work` is clearly separated.

### Verbose output

The `-v` flag prints sampling statistics to stderr during profiling:

```bash
sperf record -v ruby my_app.rb
```

```
[sperf] mode=cpu frequency=1000Hz
[sperf] sampling: 98 calls, 0.11ms total, 1.1us/call avg
[sperf] samples recorded: 904
[sperf] top 10 by flat:
[sperf]       53.4ms  50.1%  Object#cpu_work (-e)
[sperf]       17.0ms  15.9%  Integer#times (<internal:numeric>)
...
```

### record options

```bash
sperf record [options] command [args...]
```

| Option | Description |
|--------|-------------|
| `-o PATH` | Output file (default: `sperf.data`) |
| `-f HZ` | Sampling frequency in Hz (default: 1000) |
| `-m MODE` | `cpu` or `wall` (default: `cpu`) |
| `--format FMT` | `pprof`, `collapsed`, or `text` (default: auto from extension) |
| `-v` | Print sampling statistics to stderr |

## sperf report

`sperf report` opens a pprof profile for analysis. It wraps `go tool pprof` and requires Go to be installed.

```bash
# Open interactive web UI (default)
sperf report

# Open a specific file
sperf report profile.pb.gz

# Print top functions
sperf report --top

# Print text report
sperf report --text
```

### Example: Top and text output

Using the `fib.rb` profile recorded earlier:

```bash
sperf report --top sperf.data
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
| `--text` | Print text report |
| (default) | Open interactive web UI in browser |

## sperf diff

`sperf diff` compares two pprof profiles, showing the difference (target - base). This is useful for measuring the impact of optimizations.

```bash
# Open diff in browser
sperf diff before.pb.gz after.pb.gz

# Print top functions by diff
sperf diff --top before.pb.gz after.pb.gz

# Print text diff
sperf diff --text before.pb.gz after.pb.gz
```

### Workflow example

```bash
# Profile the baseline
sperf record -o before.pb.gz ruby my_app.rb

# Make your optimization changes...

# Profile again
sperf record -o after.pb.gz ruby my_app.rb

# Compare
sperf diff before.pb.gz after.pb.gz
```

## sperf help

`sperf help` prints the full reference documentation, including profiling modes, output formats, synthetic frames, and diagnostic tips.

```bash
sperf help
```

This outputs detailed documentation suitable for both human reading and AI-assisted analysis.
