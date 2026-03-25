# Output Encoding

This chapter describes how rperf converts its internal aggregated data into output formats. Encoding runs once at stop time, so it is not performance-critical.

## From aggregated data to output

When `Rperf.stop` is called, the C extension returns the aggregated data to Ruby:

1. **Frame table**: An array of `[path, label]` string pairs, indexed by frame ID. Strings are resolved from raw VALUEs via `rb_profile_frame_full_label` and `rb_profile_frame_path`.
2. **Aggregation table**: An array of `[frame_ids, weight, thread_seq, label_set_id]` entries.
3. **Label sets**: An array of frozen Hashes mapping label keys to values.

The Ruby encoders (`Rperf::PProf`, `Rperf::Collapsed`, `Rperf::Text`) consume these arrays to produce the final output.

## pprof encoder

rperf encodes the [pprof](#cite:ren2010) protobuf format entirely in Ruby, with no protobuf gem dependency. The encoder in `Rperf::PProf.encode`:

1. Builds a string table (index 0 is always the empty string)
2. Converts string frames to index frames and merges identical stacks
3. Builds location and function tables
4. Encodes the Profile protobuf message field by field
5. Compresses the result with gzip

This hand-written encoder is simple (~100 lines) and handles only the subset of the pprof protobuf schema that rperf needs.

### Embedded metadata

Each pprof profile includes metadata as comments: rperf version, profiling mode, frequency, and Ruby version. The `time_nanos` and `duration_nanos` fields record when and how long the profile was collected.

### Thread sequence labels

Every sample carries a `thread_seq` numeric label — a 1-based thread sequence number assigned when rperf first sees each thread. This allows grouping flame graphs by thread in pprof tools.

## Sample labels

`Rperf.label` enables per-context annotation of samples. The implementation is split between Ruby and C to keep the hot path minimal:

1. **Ruby side**: Manages label sets as frozen Hash objects in an array (`@label_set_table`). A deduplication index (`@label_set_index`) maps each unique Hash to an integer ID. `Rperf.label(key: value)` merges the new labels with the current set, interns the result, and passes the integer ID to C.

2. **C side**: Each `rperf_thread_data_t` stores a `label_set_id` (integer). When a sample is recorded, the current thread's `label_set_id` is copied into the sample — a single integer, adding zero allocation overhead to the hot path. The aggregation table includes `label_set_id` in its hash key, so identical stacks with different labels remain separate entries.

3. **Encoding**: At encode time, the Ruby PProf encoder reads the `label_sets` array and writes each label as a pprof `Sample.Label` (key-value string pair). `go tool pprof -tagfocus` and `-tagroot` can filter and group by label.

## Collapsed stacks encoder

The collapsed stacks encoder produces one line per unique stack: frames joined by semicolons (bottom-to-top), followed by a space and the weight in nanoseconds. This format is consumed by FlameGraph tools and speedscope.

When label sets are present, labels are not included in the collapsed output — use pprof format for label-aware analysis.

## Text report encoder

The text report encoder produces a human-readable summary with:

- **Header**: Total profiled time, sample count, and frequency
- **Flat table**: Top 50 functions sorted by self time (the function was the leaf/deepest frame)
- **Cumulative table**: Top 50 functions sorted by total time (the function appeared anywhere in the stack)

This format requires no external tools and is suitable for quick analysis, issue reports, or AI-assisted analysis.
