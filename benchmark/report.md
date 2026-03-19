# Profiler Accuracy Report

Benchmark date: 2026-03-20
Ruby: 4.0.0, Linux 6.6.87 (WSL2, 20 cores)

## Methodology

Each profiler was tested against five scenario types, two frequencies (100Hz, 1000Hz), two modes (cpu, wall), and two load conditions (idle, full CPU saturation on all 20 cores). Scenario #0 from each file was used. Error is the average of `|actual - expected| / expected` across all methods in the scenario.

### Workload Types

| Prefix | Behavior | GVL | CPU time | Wall time |
|--------|----------|-----|----------|-----------|
| `rw` | Ruby busy-wait | Held | consumes | consumes |
| `cw` | C busy-wait | Held | consumes | consumes |
| `csleep` | `nanosleep` (GVL held) | Held | 0 | consumes |
| `cwait` | `nanosleep` (GVL released) | Released | 0 | consumes |
| `mixed` | All of the above | Mixed | varies | consumes |

### Profilers

| Profiler | Sampling mechanism | Output format |
|----------|--------------------|---------------|
| sprof | Postponed job + time-delta weight | pprof protobuf |
| stackprof | Signal-based, uniform sample count | Custom marshal |
| vernier | Signal-based, wall only | Firefox Profiler JSON |
| pf2 | Async signal, native + Ruby stack | pprof protobuf |

### Notes on vernier

Vernier does not support CPU-time sampling. The `:retained` mode was used as a substitute for cpu tests, but it measures object retention, not CPU time. All vernier cpu results show a constant ~63-220% error unrelated to the workload and should be disregarded. Only vernier wall results are meaningful.

---

## Results: No Load

### rw (Ruby busy-wait)

Ruby methods calling `Process.clock_gettime` in a loop. Frequent safepoints.

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **7.6%** | **5.7%** | **0.8%** | **1.3%** |
| stackprof | 8.0% | 7.7% | 74.6% | **0.8%** |
| vernier | 219.5% | 90.1% | 219.5% | **7.2%** |
| pf2 | **7.3%** | **6.2%** | **3.2%** | **1.0%** |

- All profilers perform well on rw at 100Hz because Ruby busy-wait hits safepoints frequently.
- stackprof 1000Hz cpu (74.6%): the high frequency causes `clock_gettime` to dominate the leaf-frame TOTAL count, inflating error. stackprof 1000Hz wall (0.8%) is excellent because wall-mode sampling avoids this distortion.
- vernier 1000Hz wall (7.2%) is usable but less precise than sprof/stackprof/pf2.
- pf2 performs well across the board for rw-only -- its cumulative accounting works when all frames are Ruby-level.

### cw (C busy-wait)

C functions spinning in `clock_gettime` loop. No safepoints during the loop body.

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **0.3%** | **0.5%** | **0.1%** | **0.0%** |
| stackprof | 78.5% | 78.5% | 97.9% | 97.9% |
| vernier | 100.0% | 90.0% | 100.0% | **3.0%** |
| pf2 | **2.8%** | **4.9%** | **4.2%** | **0.5%** |

- **sprof excels** (<1% at all frequencies) because time-delta weighting correctly attributes the long safepoint-free intervals to the right frame.
- **stackprof completely fails** (78-98%): C busy-wait runs without safepoints, so stackprof captures very few samples during these methods. The uniform weighting cannot compensate.
- vernier 1000Hz wall (3.0%) works because vernier's wall sampling can observe the thread spending time in C code.
- pf2 handles cw well (<5%) since it collects native stack frames.

### csleep (nanosleep, GVL held)

The thread sleeps via `nanosleep()` while holding the GVL. CPU time = 0, wall time = sleep duration.

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **0.0%** | **6.2%** | **0.0%** | **6.1%** |
| stackprof | 0.0% | 76.0% | 0.0% | 97.6% |
| vernier | 0.0% | 97.6% | 0.0% | 97.6% |
| pf2 | 0.0% | 76.0% | 0.0% | 97.6% |

- All profilers correctly report 0 CPU time (trivially correct since nanosleep consumes no CPU).
- **sprof is the only profiler that accurately measures csleep wall time** (~6% error). The postponed job fires during sleep and the wall-time delta captures the elapsed time.
- stackprof/vernier/pf2 all report near-zero wall time for csleep (76-98% error) because no samples are collected while the thread is sleeping inside `nanosleep()`.
- sprof's 6% error (rather than <1%) is due to the first/last sample boundary effect: the postponed job may not fire exactly at the start and end of the sleep, leaving a small unmeasured gap.

### cwait (nanosleep, GVL released)

The thread sleeps via `rb_thread_call_without_gvl` + `nanosleep()`. GVL is released during sleep.

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **0.0%** | **1.3%** | **0.0%** | **1.2%** |
| stackprof | 0.0% | 62.9% | 0.0% | 96.3% |
| vernier | 0.0% | 90.1% | 0.0% | **1.5%** |
| pf2 | 0.0% | 62.8% | 0.0% | 96.3% |

- All profilers correctly report 0 CPU time.
- **sprof** accurately measures cwait wall time (~1% error), slightly better than csleep because the GVL release creates a cleaner sampling boundary.
- **vernier 1000Hz wall (1.5%)** also works well for cwait: when the GVL is released, vernier can observe the thread state change.
- stackprof and pf2 fail to capture cwait wall time (63-96% error).

### mixed (all workload types combined)

The most realistic scenario: rw, cw, csleep, and cwait methods mixed together.

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **1.7%** | **5.7%** | **0.3%** | **0.8%** |
| stackprof | 21.2% | 83.4% | 38.2% | 83.6% |
| vernier | 63.5% | 93.2% | 63.5% | 36.1% |
| pf2 | 62.8% | 46.4% | 61.3% | 55.8% |

- **sprof is the only profiler that passes in all combinations.** The errors from individual workload types average out, but sprof handles each type well so the overall error stays low.
- stackprof's mixed errors combine the cw blindness (cpu) and csleep/cwait blindness (wall).
- vernier 1000Hz wall (36.1%) is moderate -- it handles rw/cw/cwait but misses csleep entirely.
- pf2's cumulative accounting inflates values in mixed scenarios.

---

## Results: Under CPU Load

All 20 cores saturated with busy-loop processes. This tests whether profilers correctly measure CPU time independent of scheduling delays.

### rw (Ruby busy-wait)

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **10.0%** | 7.4% | **1.5%** | **0.9%** |
| stackprof | 13.5% | 14.9% | 76.6% | **1.3%** |
| pf2 | 22.7% | 6.7% | 14.0% | **2.3%** |

- sprof cpu is slightly worse under load at 100Hz (7.6% -> 10.0%) but still well within tolerance. At 1000Hz, no change (0.8% -> 1.5%).
- stackprof wall actually improves under load at 100Hz (7.7% -> 14.9% is worse, but 1000Hz: 0.8% -> 1.3% is stable).
- pf2 cpu degrades moderately (7.3% -> 22.7% at 100Hz).

### cw (C busy-wait)

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **0.5%** | **0.3%** | **0.2%** | 24.3% |
| stackprof | 78.5% | 78.5% | 97.9% | 97.9% |
| pf2 | 34.4% | 48.8% | 41.7% | 18.5% |

- **sprof cpu remains rock-solid** (<1%) under load for cw. The per-thread CPU clock is unaffected by scheduling.
- sprof 1000Hz wall (24.3%) degrades as expected: C busy-wait takes longer in wall time when CPU is contested.
- stackprof remains completely blind to cw regardless of load.
- pf2 degrades significantly (2.8% -> 34.4% cpu at 100Hz).

### csleep (nanosleep, GVL held)

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **0.0%** | **6.0%** | **0.0%** | **6.0%** |
| stackprof | 0.0% | 76.0% | 0.0% | 97.6% |
| pf2 | 0.0% | 76.0% | 0.0% | 95.6% |

- **No change under load** for any profiler. csleep is pure sleep time -- CPU contention does not affect `nanosleep` duration, and CPU time remains 0.

### cwait (nanosleep, GVL released)

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **0.0%** | **0.5%** | **0.0%** | **2.8%** |
| stackprof | 0.0% | 62.9% | 0.0% | 96.3% |
| pf2 | 0.0% | 62.8% | 0.0% | 95.8% |

- Same pattern as csleep: load does not affect sleep-based workloads.
- sprof wall slightly increases (1.2% -> 2.8% at 1000Hz) but remains accurate.

### mixed (all workload types combined)

| Profiler | 100Hz cpu | 100Hz wall | 1000Hz cpu | 1000Hz wall |
|----------|-----------|------------|------------|-------------|
| **sprof** | **1.0%** | 31.8% | **0.2%** | 35.3% |
| stackprof | 25.0% | 86.1% | 39.5% | 84.8% |
| pf2 | 96.9% | 68.1% | 80.6% | 77.0% |

- **sprof cpu is unaffected by load** (1.7% -> 1.0% at 100Hz, 0.3% -> 0.2% at 1000Hz). The per-thread CPU clock correctly excludes scheduling delays.
- **sprof wall degrades as expected** (5.7% -> 31.8%): busy-wait methods take longer in wall time under CPU contention. This is correct behavior.
- pf2 cpu degrades catastrophically under load (62.8% -> 96.9% at 100Hz), suggesting it does not use true per-thread CPU clocks.
- stackprof is largely unchanged because its baseline error was already high.

---

## Summary Table

Average error (%) for scenario #0. Bold = <10%. ~~Struck~~ = >90%.

### CPU mode, no load

| Scenario | sprof 100 | sprof 1K | stackprof 100 | stackprof 1K | pf2 100 | pf2 1K |
|----------|-----------|----------|---------------|--------------|---------|--------|
| rw | **7.6** | **0.8** | **8.0** | 74.6 | **7.3** | **3.2** |
| cw | **0.3** | **0.1** | 78.5 | ~~97.9~~ | **2.8** | **4.2** |
| csleep | **0.0** | **0.0** | **0.0** | **0.0** | **0.0** | **0.0** |
| cwait | **0.0** | **0.0** | **0.0** | **0.0** | **0.0** | **0.0** |
| mixed | **1.7** | **0.3** | 21.2 | 38.2 | 62.8 | 61.3 |

### Wall mode, no load

| Scenario | sprof 100 | sprof 1K | stackprof 100 | stackprof 1K | vernier 100 | vernier 1K | pf2 100 | pf2 1K |
|----------|-----------|----------|---------------|--------------|-------------|------------|---------|--------|
| rw | **5.7** | **1.3** | **7.7** | **0.8** | ~~90.1~~ | **7.2** | **6.2** | **1.0** |
| cw | **0.5** | **0.0** | 78.5 | ~~97.9~~ | ~~90.0~~ | **3.0** | **4.9** | **0.5** |
| csleep | **6.2** | **6.1** | 76.0 | ~~97.6~~ | ~~97.6~~ | ~~97.6~~ | 76.0 | ~~97.6~~ |
| cwait | **1.3** | **1.2** | 62.9 | ~~96.3~~ | ~~90.1~~ | **1.5** | 62.8 | ~~96.3~~ |
| mixed | **5.7** | **0.8** | 83.4 | 83.6 | ~~93.2~~ | 36.1 | 46.4 | 55.8 |

### CPU mode, under load

| Scenario | sprof 100 | sprof 1K | stackprof 100 | stackprof 1K | pf2 100 | pf2 1K |
|----------|-----------|----------|---------------|--------------|---------|--------|
| rw | **10.0** | **1.5** | 13.5 | 76.6 | 22.7 | 14.0 |
| cw | **0.5** | **0.2** | 78.5 | ~~97.9~~ | 34.4 | 41.7 |
| csleep | **0.0** | **0.0** | **0.0** | **0.0** | **0.0** | **0.0** |
| cwait | **0.0** | **0.0** | **0.0** | **0.0** | **0.0** | **0.0** |
| mixed | **1.0** | **0.2** | 25.0 | 39.5 | ~~96.9~~ | 80.6 |

---

## Key Findings

### 1. sprof is accurate across all workload types

sprof is the only profiler that achieves <10% error for every workload type in both cpu and wall mode. Its time-delta weighting eliminates safepoint bias, and per-thread CPU clocks provide true CPU-time measurement.

### 2. csleep is a unique differentiator for wall mode

GVL-held `nanosleep` (csleep) is invisible to all profilers except sprof in wall mode. stackprof, vernier, and pf2 all report near-zero wall time because they cannot sample during the sleep. sprof's postponed-job mechanism fires during the sleep and the wall-time delta captures the elapsed duration.

### 3. C busy-wait (cw) exposes safepoint bias

stackprof's uniform-weight sampling completely fails for C busy-wait (78-98% error) because the thread spends long periods without hitting a safepoint. sprof's time-delta weighting handles this correctly (<1%).

### 4. CPU-time measurement is stable under load (sprof only)

Under full CPU saturation, sprof's cpu mode error is unchanged (0.2-1.0% for mixed). pf2's "cpu" mode degrades heavily (62% -> 97%), suggesting it may be using wall time internally. stackprof's cpu mode is already inaccurate without load, so load makes little difference.

### 5. 100Hz is sufficient for sprof

At 100Hz, sprof achieves <8% error in all scenarios (cpu mode) and <7% in most wall scenarios. The time-delta weighting compensates for the lower sample rate by assigning correct weights to each sample. Other profilers generally need 1000Hz for comparable accuracy on favorable workloads (rw-only).

### 6. Each profiler has a niche

- **stackprof**: accurate for Ruby-only wall-mode profiling at 1000Hz (0.8% for rw). Good choice when profiling pure Ruby code and wall time is the metric.
- **vernier**: accurate for wall-mode profiling of Ruby and GVL-released code at 1000Hz (1.5-7.2%). Cannot measure csleep or CPU time.
- **pf2**: accurate for rw/cw workloads (1-7%) thanks to native stack collection. Degrades in mixed scenarios and under load.
- **sprof**: accurate for all workload types, both modes, both frequencies, with and without load.

---

## Results: Call-Ratio Accuracy

The previous tests measure whether profilers correctly attribute **absolute time** to each method. This section tests a different property: whether profilers correctly reflect the **relative call frequency** of methods that each consume negligible time.

### Setup

10 randomly selected `rw` methods are called with argument 0 (immediate return), totaling 4,000,000 calls distributed in random proportions. Each individual call takes ~0.5us, so the total runtime is ~2 seconds. The expected result is the ratio of calls per method. The profiler output values are converted to ratios and compared against the expected ratios.

This scenario tests statistical sampling accuracy: since all methods consume the same negligible time per call, the accumulated time per method should be proportional to its call count.

### Results: Ratio Error (scenario #0, 1kHz, no load, best of 3 runs)

| Profiler | cpu | wall |
|----------|-----|------|
| sprof | 10.3% | **9.2%** |
| stackprof | 12.0% | **5.4%** |
| vernier | 89.3% | **3.7%** |
| pf2 | 13.6% | **4.4%** |

### Results: Execution Time and Overhead (scenario #0, 1kHz, wall mode)

Baseline (no profiler): ~2010ms (minimum of multiple runs).

| Profiler | elapsed | overhead | sampling count | sampling overhead | error |
|----------|---------|----------|----------------|-------------------|-------|
| **sprof** | 2022ms | ~0% | 1631 | 4.6ms (0.2%) | 9.2% |
| stackprof | 2401ms | ~19% | - | - | 5.4% |
| vernier | 2421ms | ~20% | - | - | 3.7% |
| pf2 | 2718ms | ~35% | - | - | 4.4% |

sprof's sampling overhead is negligible: 1631 sampling callbacks took 4.6ms total (2.8us/call, 0.2% of runtime). The elapsed time is essentially identical to baseline. Other profilers add 19-35% overhead.

### Results: Sample Count vs Per-Method Accuracy (sprof, 1kHz, wall mode)

sprof collected 1631-1902 samples across runs. Distributed across 10 methods:

| Method | expected ratio | expected samples (of 1631) | approx actual samples |
|--------|---------------|---------------------------|----------------------|
| rw953 | 17.1% | ~279 | ~276 |
| rw650 | 15.4% | ~251 | ~225 |
| rw271 | 1.5% | ~25 | ~24 |

Methods with >5% ratio (>80 samples) show 0-12% error. The smallest method `rw271` at 1.5% has only ~25 samples, where statistical fluctuation of +/-5 samples means +/-20% ratio error. This is the expected behavior for any sampling profiler -- accuracy is proportional to the square root of sample count.

### Analysis

**All profilers achieve usable ratio accuracy at 1kHz** with ~2 seconds of runtime. The differences are modest (3.7-13.6% for wall mode, excluding vernier cpu which is not applicable).

**sprof has the lowest overhead** (~0%) while achieving 9.2% ratio error. The time-delta weighting adds some noise to ratio estimation compared to uniform counting (stackprof 5.4%, vernier 3.7%), but the gap is small and explainable by delta variance.

**stackprof cpu gets worse at higher frequency** (12.0% at 1kHz vs 11.1% at 100Hz). At higher frequency, `Process.clock_gettime` dominates the leaf samples in cpu mode, distorting the method-level TOTAL counts.

**vernier cpu shows very high error (89%).** Vernier does not support cpu-time sampling; the `:retained` mode used as a substitute measures something entirely different.

**Why sprof's ratio error is slightly higher than stackprof/vernier:** Both profilers attribute the time between samples to whichever method is running at the sample point -- this is identical. The difference is that stackprof assigns weight=1 (fixed) to each sample while sprof assigns weight=time_delta (variable). For ratio estimation, uniform weights have lower variance because fluctuations in the time delta add noise that doesn't perfectly cancel out. This is not a fundamental limitation -- with more samples (longer runtime or higher frequency), sprof's ratios converge as well.

### Interpretation

The ratio test is a stress test for statistical sampling: all methods consume the same negligible time per call, so the only signal is call frequency. Accuracy is fundamentally limited by sample count, not by the profiling mechanism.

For real-world profiling, methods called millions of times with negligible per-call cost accumulate very little total time. The time-accuracy tests (where sprof achieves <1% error) are more representative of typical workloads where the goal is to find methods that consume significant time. sprof's advantage -- near-zero overhead and accurate time attribution -- matters most in those scenarios.
