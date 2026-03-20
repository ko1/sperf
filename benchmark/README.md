# Sperf Accuracy Benchmark

A benchmark suite for quantitatively verifying sperf's profiling accuracy.
It profiles workloads with known execution times and compares the output against expected values.
Accuracy comparisons with other profilers (stackprof, vernier, pf2) are also supported.

## Purpose

- Verify that CPU time / wall time reported by sperf matches actual time consumed
- Check accuracy across workload types: Ruby busy-wait, C busy-wait, sleep, GVL-released sleep
- Confirm that wall mode is affected by CPU contention while cpu mode is not
- Compare accuracy against other profilers under identical conditions

## Workload Methods

Each method type is defined with numbers 1 through 1000 (1000 methods each).
Different numbers appear as distinct functions in profiler output, allowing per-function accuracy verification.

| Prefix | Defined in | Behavior | GVL | CPU time | Wall time |
|--------|-----------|----------|-----|----------|-----------|
| `rw`   | `lib/sperf_workload_methods.rb` | Ruby busy-wait (`CLOCK_THREAD_CPUTIME_ID`) | Held | usec consumed | usec consumed |
| `cw`   | `ext/sperf_workload/sperf_workload.c` | C busy-wait (`CLOCK_THREAD_CPUTIME_ID`) | Held | usec consumed | usec consumed |
| `csleep` | same | `nanosleep` (GVL held) | Held | 0 | usec consumed |
| `cwait` | same | `nanosleep` (`rb_thread_call_without_gvl`) | Released | 0 | usec consumed |

## Tools

### generate_scenarios.rb -- Scenario Generator

Generates random workload call sequences, their expected values as JSON, and executable scripts in `scripts/`.

```bash
ruby generate_scenarios.rb                        # mixed (rw/cw/csleep/cwait), 10 scenarios
ruby generate_scenarios.rb -p rw -n 10            # rw only
ruby generate_scenarios.rb -p cw -n 10            # cw only
ruby generate_scenarios.rb -p csleep -n 10         # csleep only
ruby generate_scenarios.rb -p cwait -n 10          # cwait only
ruby generate_scenarios.rb -p mixed -n 10         # all types mixed
ruby generate_scenarios.rb -p ratio -n 10          # call-ratio scenarios
ruby generate_scenarios.rb -s 12345               # custom seed
ruby generate_scenarios.rb -o my_scenarios.json   # custom output filename
```

Each invocation produces:
- A JSON scenario file (e.g., `scenarios_rw.json`) with expected values
- Executable Ruby scripts in `scripts/` (e.g., `scripts/rw_0.rb` through `scripts/rw_9.rb`)

The scripts in `scripts/` are `.gitignore`d and regenerated from the JSON files.

#### Time-accuracy scenarios (rw, cw, csleep, cwait, mixed)

```json
{
  "id": 0,
  "calls": [["rw815", 72240], ["csleep42", 50000], ...],
  "expected_cpu_ms":  { "rw815": 72.24, "csleep42": 0.0, ... },
  "expected_wall_ms": { "rw815": 72.24, "csleep42": 50.0, ... }
}
```

- Some calls are repeated (approximately 30% of methods are called 3-10 times each) to test accumulation
- `expected_*_ms` values are summed across duplicate calls to the same method
- Fixed seed ensures reproducibility

#### Ratio scenarios

10 randomly selected `rw` methods are called with argument 0 (immediate return), totaling 4,000,000 calls distributed in random proportions. Each call takes ~0.5us, so the signal is purely statistical.

```json
{
  "id": 0,
  "type": "ratio",
  "call_counts": { "rw953": 17100, "rw650": 15368, ... },
  "expected_ratio": { "rw953": 0.171, "rw650": 0.1537, ... }
}
```

- The checker converts profiler output values to ratios and compares against `expected_ratio`
- This tests whether the profiler correctly reflects **relative call frequency** rather than absolute time

### profrun.rb -- Profiler Runner

Runs a workload script under a specified profiler and outputs stats to stdout. Used by `check_accuracy.rb` internally, and can be used directly for overhead measurement.

```bash
ruby profrun.rb [options] SCRIPT
```

| Option | Default | Description |
|--------|---------|-------------|
| `-P, --profiler NAME` | `sperf` | Profiler: `sperf`, `stackprof`, `vernier`, `pf2`, `none` |
| `-m, --mode MODE` | `cpu` | Profiling mode: `cpu` or `wall` |
| `-F, --frequency HZ` | `1000` | Sampling frequency in Hz |
| `-o, --output FILE` | (none) | Profiler output file path |

Output to stdout (key=value format):
- `elapsed_ms=<time>` — total elapsed time (all profilers)
- `sampling_count=<count>` — number of sampling callbacks (sperf only)
- `sampling_time_ns=<ns>` — total time spent in sampling callbacks (sperf only)

Examples:
```bash
ruby profrun.rb scripts/rw_0.rb                           # sperf, cpu, 1000Hz, no output
ruby profrun.rb -P stackprof -m wall -o out.dump scripts/rw_0.rb  # stackprof, wall, save output
ruby profrun.rb -P none scripts/ratio_1.rb                # baseline (no profiler)
```

### check_accuracy.rb -- Accuracy Runner

Runs scenarios via `profrun.rb` and compares profiler output against expected values, reporting PASS/FAIL.

```bash
ruby check_accuracy.rb                                    # sperf, scenarios_mixed.json, cpu mode
ruby check_accuracy.rb -f scenarios_rw.json               # specify scenario file
ruby check_accuracy.rb -m wall                            # wall mode
ruby check_accuracy.rb -m cpu -t 5                        # set tolerance to 5%
ruby check_accuracy.rb -F 10000                           # sampling frequency 10kHz
ruby check_accuracy.rb -l                                 # run under CPU load
ruby check_accuracy.rb -P stackprof -m cpu                # use stackprof
ruby check_accuracy.rb -P vernier -m wall                 # use vernier
ruby check_accuracy.rb -P pf2 -m wall                    # use pf2
ruby check_accuracy.rb -v                                 # verbose: show per-method detail and raw output
ruby check_accuracy.rb -f scenarios_ratio.json            # call-ratio test
ruby check_accuracy.rb -f scenarios_rw.json -m wall -l    # combined options
ruby check_accuracy.rb 0                                  # scenario #0 only
ruby check_accuracy.rb 0-4                                # scenarios #0 through #4
ruby check_accuracy.rb --help                             # show all options
```

| Option | Default | Description |
|--------|---------|-------------|
| `-f, --file FILE` | `scenarios_mixed.json` | Scenario file |
| `-m, --mode MODE` | `cpu` | Profiling mode (`cpu` / `wall`) |
| `-t, --tolerance PCT` | `20` | Pass tolerance (%) |
| `-F, --frequency HZ` | `1000` | Sampling frequency in Hz |
| `-P, --profiler NAME` | `sperf` | Profiler (`sperf` / `stackprof` / `vernier` / `pf2`) |
| `-l, --load` | off | Spawn CPU-hogging processes on all cores |
| `-v, --verbose` | off | Show per-method detail and raw profiler output for all scenarios |
| `-h, --help` | | Show help |

How it works:
1. Resolves the workload script from `scripts/` (e.g., `scripts/mixed_0.rb` for `scenarios_mixed.json` scenario #0)
2. Executes the script via `profrun.rb` with the specified profiler, mode, and frequency
3. Parses the output using the appropriate method (sperf/pf2: `go tool pprof`, stackprof: `stackprof --text`, vernier: Firefox Profiler JSON)
4. For time-accuracy scenarios: compares actual vs expected time per method
5. For ratio scenarios: converts profiler output to ratios and compares against expected call-frequency ratios
6. PASS if average error is within tolerance

## Included Scenario Files

| File | Contents | Count |
|------|----------|-------|
| `scenarios_rw.json` | Ruby busy-wait only | 10 |
| `scenarios_cw.json` | C busy-wait only | 10 |
| `scenarios_csleep.json` | nanosleep (GVL held) only | 10 |
| `scenarios_cwait.json` | nanosleep (GVL released) only | 10 |
| `scenarios_mixed.json` | All types mixed | 10 |
| `scenarios_ratio.json` | Call-ratio (10 methods, 4M calls, arg 0) | 10 |

## Expected Results

### sperf (normal, no load)

All scenarios pass in both modes. Typical error is 1-2%.

```
$ ruby check_accuracy.rb -m cpu
Scenario #0     PASS (0.3%)
...
Overall average error: 0.4%
PASS (< 20%)

$ ruby check_accuracy.rb -m wall
Scenario #0     PASS (0.8%)
...
Overall average error: 1.0%
PASS (< 20%)
```

### sperf (under CPU load)

With `-l`, all cores are saturated with busy processes. Results differ by mode:

- **cpu mode -> PASS**: CPU time is per-thread, unaffected by other processes
- **wall mode -> FAIL**: Wall time for busy-wait methods (rw/cw) inflates due to CPU contention

```
$ ruby check_accuracy.rb -f scenarios_rw.json -m cpu -t 5 -l 0
Scenario #0     PASS (1.9%)
PASS (< 5%)

$ ruby check_accuracy.rb -f scenarios_rw.json -m wall -t 5 -l 0
--- Scenario #0     FAIL (avg error: 22.9%) ---
  rw975       expected=  865.8ms  actual= 1154.6ms  error= 33.4%
  ...
FAIL (> 5%)
```

This is correct behavior for wall mode. Wall time measures real elapsed time including OS scheduler effects, so CPU contention causes busy-wait methods to take longer.

### Comparison with Other Profilers

Accuracy on mixed scenario #0 (tolerance 20%):

| Profiler | cpu mode | wall mode |
|----------|----------|-----------|
| **sperf** | PASS (0.2%) | PASS (0.8%) |
| stackprof | FAIL (38%) | FAIL (82%) |
| vernier | FAIL (64%) | FAIL (35%) |
| pf2 | FAIL (64%) | FAIL (48%) |

Profiler characteristics:

- **stackprof**: Signal-based (not safepoint-based), uniform sample count. Misses loops inside C functions (`cw`) because signals are deferred until the next safepoint.
- **vernier**: Accurate for rw/cw/cwait in wall mode (1-3% error), but cannot measure GVL-held sleep (`csleep`). No cpu-time mode (`:retained` is used as a substitute but serves a different purpose).
- **pf2**: pprof output shows flat=0 for all frames, reporting only cumulative values that include the native stack. Values tend to be inflated.

With rw-only scenarios, vernier wall mode achieves good accuracy:

```
$ ruby check_accuracy.rb -P vernier -m wall -f scenarios_rw.json 0
Scenario #0     PASS (1.5%)
```

### Call-Ratio Test

Tests whether profilers correctly reflect relative call frequency (not absolute time). 10 `rw` methods called 4M times total with arg 0.

```
$ ruby check_accuracy.rb -f scenarios_ratio.json -P vernier -m wall -F 10000 0
Scenario #0     PASS (6.5%)

$ ruby check_accuracy.rb -f scenarios_ratio.json -P sperf -m cpu -F 10000 0
--- Scenario #0     FAIL (avg error: 21.9%) ---
```

Uniform-weight profilers (vernier, stackprof) perform better here because tiny time deltas are noisy, while uniform counting (1 sample = 1 count) averages out cleanly. This is not a fundamental limitation of time-delta weighting -- with enough samples or longer runtime, sperf's ratios should converge as well, since accumulated time is proportional to call count when per-call time is uniform.

See `report.md` for detailed results and analysis.

## Prerequisites

- `go tool pprof` in PATH (required for parsing sperf and pf2 results)
- Benchmark C extension built via `rake compile`
- For other profilers: `gem install stackprof vernier pf2`
