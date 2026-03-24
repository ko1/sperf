require "test-unit"
require "rperf"
require "tempfile"
require "zlib"

class TestRperf < Test::Unit::TestCase
  def teardown
    # Ensure profiler is stopped after each test
    Rperf.stop rescue nil
  end

  def test_start_stop
    Rperf.start(frequency: 100)
    # Do some work
    1_000_000.times { 1 + 1 }
    data = Rperf.stop

    assert_kind_of Hash, data
    assert_include data, :aggregated_samples
    assert_include data, :frequency
    assert_equal 100, data[:frequency]
  end

  def test_cpu_bound_weight
    Rperf.start(frequency: 1000)
    10_000_000.times { 1 + 1 }
    data = Rperf.stop

    assert_not_nil data
    samples = data[:aggregated_samples]

    # Should have at least some samples
    assert_operator samples.size, :>, 0, "Expected at least 1 sample"

    # All weights should be positive
    samples.each do |frames, weight|
      assert_operator weight, :>, 0, "Weight should be positive"
    end
  end

  def test_profile_block
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.data")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path), "Output file should exist"
      content = File.binread(path)

      # Check gzip header (magic bytes)
      assert_equal "\x1f\x8b".b, content[0, 2], "Should be gzip format"

      # Should be decompressable
      decompressed = Zlib::GzipReader.new(StringIO.new(content)).read
      assert_operator decompressed.bytesize, :>, 0
    end
  end

  def test_multithread
    Rperf.start(frequency: 1000)

    threads = 4.times.map do
      Thread.new { 5_000_000.times { 1 + 1 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0, "Should have samples from threads"
  end

  def test_double_start_raises
    Rperf.start(frequency: 100)
    assert_raise(RuntimeError) { Rperf.start(frequency: 100) }
    Rperf.stop
  end

  def test_stop_without_start_returns_nil
    assert_nil Rperf.stop
  end

  def test_restart_clears_thread_state
    # First session
    Rperf.start(frequency: 1000, aggregate: false)
    1_000_000.times { 1 + 1 }
    data1 = Rperf.stop

    # Sleep to create a gap between sessions
    sleep 0.2

    # Second session - weights should NOT include the 200ms gap
    Rperf.start(frequency: 1000, aggregate: false)
    1_000_000.times { 1 + 1 }
    data2 = Rperf.stop

    assert_not_nil data1
    assert_not_nil data2

    # Check raw per-sample weights (not aggregated totals).
    # At 1000Hz each raw sample weight should be ~1ms.
    # Without proper thread state reset, the first sample would carry
    # the stale prev_cpu_ns from session 1, producing a huge weight.
    max_weight2 = data2[:raw_samples].map { |_, w| w }.max || 0

    assert_operator max_weight2, :<, 100_000_000,
      "Max weight in second session (#{max_weight2}ns) should not include the gap between sessions"
  end

  # --- Input validation tests ---

  def test_frequency_zero_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: 0) }
  end

  def test_frequency_negative_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: -1) }
  end

  def test_frequency_non_integer_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: 1.5) }
  end

  def test_signal_kill_raises
    assert_raise(ArgumentError) { Rperf.start(signal: 9) }  # SIGKILL
  end

  def test_signal_stop_raises
    assert_raise(ArgumentError) { Rperf.start(signal: 19) } # SIGSTOP
  end

  def test_signal_string_kill_raises
    assert_raise(ArgumentError) { Rperf.start(signal: "9") }  # string SIGKILL
  end

  def test_signal_false_ok
    data = Rperf.start(frequency: 500, signal: false) do
      5_000_000.times { 1 + 1 }
    end
    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
  end

  def test_cli_frequency_zero
    exe = File.expand_path("../exe/rperf", __dir__)
    output = IO.popen([RbConfig.ruby, exe, "stat", "-f", "0", "true"], err: [:child, :out], &:read)
    refute_equal 0, $?.exitstatus, "rperf with frequency 0 should fail"
    assert_include output, "frequency must be a positive integer"
  end

  # --- aggregate: false + output format tests ---

  def test_no_aggregate_has_both_keys
    data = Rperf.start(frequency: 500, aggregate: false) do
      5_000_000.times { 1 + 1 }
    end

    assert_not_nil data
    assert_include data, :raw_samples, "Should have raw_samples"
    assert_include data, :aggregated_samples, "Should have aggregated_samples built from raw"
    assert_operator data[:raw_samples].size, :>, 0
    assert_operator data[:aggregated_samples].size, :>, 0
  end

  def test_no_aggregate_pprof_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.pb.gz")
      Rperf.start(output: path, frequency: 500, aggregate: false) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path), "pprof output should be created with --no-aggregate"
      content = File.binread(path)
      assert_equal "\x1f\x8b".b, content[0, 2], "Should be gzip format"
    end
  end

  def test_no_aggregate_collapsed_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.collapsed")
      Rperf.start(output: path, frequency: 500, aggregate: false) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path)
      content = File.read(path)
      lines = content.strip.split("\n")
      assert_operator lines.size, :>, 0

      lines.each do |line|
        _stack, weight_str = line.rpartition(" ").then { |s, _, w| [s, w] }
        assert_operator weight_str.to_i, :>, 0
      end
    end
  end

  def test_no_aggregate_text_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.txt")
      Rperf.start(output: path, frequency: 500, aggregate: false) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path)
      content = File.read(path)
      assert_include content, "Total:"
      assert_include content, "Flat:"
    end
  end

  # --- Boundary / realloc tests ---

  # Sample buffer initial capacity is 1024.
  # With 4 threads at 5000Hz, ~20000 samples/sec → crosses boundary quickly.
  # After aggregation, data[:aggregated_samples] contains unique stacks (much fewer),
  # so we check sampling_count to verify buffer realloc was exercised.
  def test_sample_buffer_realloc
    duration = 1.0
    data = nil
    trials = []

    loop do
      Rperf.start(frequency: 5000)
      busy_wait(duration)
      data = Rperf.stop

      trials << "#{duration}s: samples=#{data[:aggregated_samples].size}, trigger_count=#{data[:trigger_count]}, sampling_count=#{data[:sampling_count]}"
      break if data[:sampling_count] > 1024

      duration *= 2
      assert_operator duration, :<=, 32,
        "Expected >1024 sampling_count to exercise realloc. Trials:\n#{trials.map { |t| "  #{t}" }.join("\n")}"
    end

    # Verify all samples have valid data
    assert_valid_samples(data[:aggregated_samples])
  end

  # Frame pool initial capacity is ~131K frames (1MB / 8 bytes per VALUE).
  # Use deep recursion to generate lots of frames quickly.
  # After aggregation, unique stacks are fewer, but frame pool realloc
  # is still exercised during sampling (before aggregation flushes).
  # We verify by checking sampling_count * depth > initial_pool.
  def test_frame_pool_realloc
    initial_pool = 1024 * 1024 / 8  # ~131072
    stack_depth = 300
    duration = 1.0
    data = nil
    trials = []

    loop do
      Rperf.start(frequency: 5000)
      deep_recurse(stack_depth) { busy_wait(duration) }
      data = Rperf.stop

      samples = data[:aggregated_samples]
      estimated_frames = data[:sampling_count] * stack_depth
      trials << "#{duration}s: samples=#{samples.size}, sampling_count=#{data[:sampling_count]}, estimated_frames=#{estimated_frames}"
      break if estimated_frames > initial_pool

      duration *= 2
      assert_operator duration, :<=, 32,
        "Expected >#{initial_pool} estimated frames to exercise frame pool realloc. Trials:\n#{trials.map { |t| "  #{t}" }.join("\n")}"
    end

    # Verify early and late samples both have valid frame data
    samples = data[:aggregated_samples]
    assert_valid_samples(samples.first(10))
    assert_valid_samples(samples.last(10))
  end

  # Generate deep call stacks via recursion
  def test_deep_stack
    Rperf.start(frequency: 1000)

    deep_recurse(200) { 5_000_000.times { 1 + 1 } }

    data = Rperf.stop
    assert_not_nil data
    samples = data[:aggregated_samples]
    assert_operator samples.size, :>, 0

    max_depth = samples.map { |frames, _| frames.size }.max
    assert_operator max_depth, :>=, 50,
      "Expected deep stacks (max depth #{max_depth})"

    assert_valid_samples(samples)
  end

  # Threads created and destroyed during profiling
  def test_thread_churn
    Rperf.start(frequency: 1000)

    20.times do
      threads = 4.times.map do
        Thread.new { cpu_work_with_gvl_yield(500_000) }
      end
      threads.each(&:join)
    end

    data = Rperf.stop
    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
    assert_valid_samples(data[:aggregated_samples])
  end

  # Restart with threads that survive across sessions
  def test_restart_with_surviving_thread
    worker_running = true
    worker = Thread.new do
      while worker_running
        500_000.times { 1 + 1 }
        sleep(0)
      end
    end

    # Session 1
    Rperf.start(frequency: 1000, aggregate: false)
    5_000_000.times { 1 + 1 }
    data1 = Rperf.stop

    sleep 0.2

    # Session 2 - surviving worker thread must not carry stale state
    Rperf.start(frequency: 1000, aggregate: false)
    5_000_000.times { 1 + 1 }
    data2 = Rperf.stop

    worker_running = false
    worker.join

    assert_not_nil data1
    assert_not_nil data2
    assert_operator data2[:raw_samples].size, :>, 0

    # Check raw per-sample weights. At 1000Hz each should be ~1ms.
    # Without proper cleanup, surviving thread's first sample would
    # include stale prev_cpu_ns from session 1.
    max_weight2 = data2[:raw_samples].map { |_, w| w }.max || 0
    assert_operator max_weight2, :<, 200_000_000,
      "Surviving thread's max weight (#{max_weight2}ns) should not include inter-session gap"
  end

  # Frame table starts at 4096 entries.  Deep stacks with recursion
  # generate many unique frames, exercising dynamic growth.
  def test_frame_table_growth
    Rperf.start(frequency: 1000)

    # Generate many unique call stacks via recursion
    deep_recurse(200) { busy_wait(2.0) }

    data = Rperf.stop
    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
    assert_valid_samples(data[:aggregated_samples])
  end

  # Multiple start/stop cycles to check no resource leaks cause crashes
  def test_repeated_start_stop
    10.times do |cycle|
      Rperf.start(frequency: 1000)
      1_000_000.times { 1 + 1 }
      data = Rperf.stop

      assert_not_nil data, "Cycle #{cycle}: stop should return data"
      assert_operator data[:aggregated_samples].size, :>, 0, "Cycle #{cycle}: should have samples"
    end
  end

  # --- GVL event tracking tests ---

  def test_gvl_blocked_frames_wall_mode
    Rperf.start(frequency: 100, mode: :wall)

    # sleep releases GVL → triggers SUSPENDED/READY/RESUMED
    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    labels = data[:aggregated_samples].flat_map { |frames, _| frames.map { |_, label| label } }
    has_blocked = labels.include?("[GVL blocked]")
    has_wait = labels.include?("[GVL wait]")

    assert has_blocked || has_wait,
      "Wall mode with sleep should produce [GVL blocked] or [GVL wait] samples"
  end

  def test_gvl_events_cpu_mode_no_synthetic
    Rperf.start(frequency: 100, mode: :cpu)

    threads = 4.times.map do
      Thread.new { 20.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    labels = data[:aggregated_samples].flat_map { |frames, _| frames.map { |_, label| label } }
    refute labels.include?("[GVL blocked]"),
      "CPU mode should NOT produce [GVL blocked] samples"
    refute labels.include?("[GVL wait]"),
      "CPU mode should NOT produce [GVL wait] samples"
  end

  def test_gvl_wait_weight_positive
    Rperf.start(frequency: 100, mode: :wall)

    # Multiple threads contending for GVL
    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.001 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    gvl_samples = data[:aggregated_samples].select { |frames, _|
      frames.any? { |_, label| label == "[GVL blocked]" || label == "[GVL wait]" }
    }

    gvl_samples.each do |_, weight|
      assert_operator weight, :>, 0, "GVL sample weight should be positive"
    end
  end

  def test_pprof_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.pb.gz")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      # Decompress and verify basic protobuf structure
      content = File.binread(path)
      decompressed = Zlib::GzipReader.new(StringIO.new(content)).read

      # The first byte should be a protobuf field tag
      # Field 1, wire type 2 (length-delimited) = (1 << 3) | 2 = 0x0a
      assert_equal 0x0a, decompressed.getbyte(0),
        "First field should be sample_type (field 1, length-delimited)"
    end
  end

  # --- CLI help subcommand test ---

  def test_cli_help_subcommand
    exe = File.expand_path("../exe/rperf", __dir__)
    output = IO.popen([RbConfig.ruby, exe, "help"], &:read)

    assert_equal 0, $?.exitstatus, "rperf help should exit 0"
    assert_include output, "OVERVIEW"
    assert_include output, "CLI USAGE"
    assert_include output, "RUBY API"
    assert_include output, "PROFILING MODES"
    assert_include output, "OUTPUT FORMATS"
    assert_include output, "SYNTHETIC FRAMES"
    assert_include output, "INTERPRETING RESULTS"
    assert_include output, "DIAGNOSING COMMON PERFORMANCE PROBLEMS"
  end

  # --- Stat output tests ---

  def test_stat_output
    old_stderr = $stderr
    $stderr = StringIO.new

    Rperf.start(frequency: 500, mode: :wall, stat: true)
    5_000_000.times { 1 + 1 }
    data = Rperf.stop

    output = $stderr.string
    $stderr = old_stderr

    assert_not_nil data
    assert_include output, "Performance stats"
    assert_include output, "real"
    assert_include output, "CPU execution"
  end

  def test_print_stat
    data = {
      aggregated_samples: [
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 100_000_000],
        [[["<GVL>", "[GVL blocked]"], ["/a.rb", "A#foo"]], 50_000_000],
        [[["<GC>", "[GC marking]"], ["/a.rb", "A#foo"]], 10_000_000],
      ],
      frequency: 100,
      mode: :wall,
      sampling_count: 100,
      sampling_time_ns: 500_000,
    }

    # Capture stderr output
    old_stderr = $stderr
    $stderr = StringIO.new
    ENV["RPERF_STAT_COMMAND"] = "ruby test.rb"

    Rperf.instance_variable_set(:@stat_start_mono,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.2)
    Rperf.print_stat(data)

    output = $stderr.string
    $stderr = old_stderr
    ENV.delete("RPERF_STAT_COMMAND")

    assert_include output, "Performance stats for 'ruby test.rb'"
    assert_include output, "user"
    assert_include output, "sys"
    assert_include output, "real"
    assert_include output, "CPU execution"
    assert_include output, "[Ruby] GVL blocked"
    assert_include output, "[Ruby] GC marking"
    assert_include output, "[Ruby] GC time"
    assert_include output, "[Ruby] allocated objects"
    assert_include output, "[Ruby] freed objects"
    assert_include output, "[OS] peak memory"
    assert_include output, "samples"
    assert_include output, "triggers"
    assert_include output, "profiler overhead"
  end

  # --- Text format tests ---

  def test_text_encode
    data = {
      aggregated_samples: [
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 1_000_000],
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 2_000_000],
        [[["/c.rb", "C#baz"]], 500_000],
      ],
      frequency: 100,
      mode: :cpu,
    }

    result = Rperf::Text.encode(data)

    assert_include result, "Total: 3.5ms (cpu)"
    assert_include result, "Samples: 3"
    assert_include result, "Frequency: 100Hz"
    assert_include result, "Flat:"
    assert_include result, "Cumulative:"
    assert_include result, "A#foo"
    assert_include result, "B#bar"
    assert_include result, "C#baz"
  end

  def test_text_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "profile.txt")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path), "Output file should exist"
      content = File.read(path)

      assert_include content, "Total:"
      assert_include content, "Flat:"
      assert_include content, "Cumulative:"
      # Weight lines should have ms and %
      assert_match(/[\d,]+\.\d+ ms\s+\d+\.\d+%/, content)
    end
  end

  def test_save_text
    Dir.mktmpdir do |dir|
      data = Rperf.start(frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      path = File.join(dir, "report.dat")
      Rperf.save(path, data, format: :text)

      content = File.read(path)
      assert_include content, "Total:"
      assert_include content, "Flat:"
      assert_include content, "Cumulative:"
    end
  end

  def test_text_encode_empty
    data = { aggregated_samples: [], frequency: 100, mode: :cpu }
    result = Rperf::Text.encode(data)
    assert_equal "No samples recorded.\n", result
  end

  # --- Collapsed stacks format tests ---

  def test_collapsed_encode
    data = {
      aggregated_samples: [
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 1000],
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 2000],
        [[["/c.rb", "C#baz"]], 500],
      ],
      frequency: 100,
      mode: :cpu,
    }

    result = Rperf::Collapsed.encode(data)
    lines = result.strip.split("\n")

    assert_equal 2, lines.size

    merged = {}
    lines.each do |line|
      stack, weight = line.rpartition(" ").then { |s, _, w| [s, w] }
      merged[stack] = weight.to_i
    end

    # frames are deepest-first, so reverse gives bottom→top: B#bar;A#foo
    assert_equal 3000, merged["B#bar;A#foo"]
    assert_equal 500, merged["C#baz"]
  end

  def test_collapsed_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.collapsed")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path), "Output file should exist"
      content = File.read(path)

      # Should NOT be gzip
      refute_equal "\x1f\x8b".b, content.b[0, 2], "Should not be gzip format"

      lines = content.strip.split("\n")
      assert_operator lines.size, :>, 0, "Should have at least one line"

      lines.each do |line|
        stack, weight_str = line.rpartition(" ").then { |s, _, w| [s, w] }
        assert_not_nil stack, "Line should have a stack"
        assert_not_nil weight_str, "Line should have a weight"
        weight = weight_str.to_i
        assert_operator weight, :>, 0, "Weight should be positive: #{line}"
      end
    end
  end

  def test_save_collapsed
    Dir.mktmpdir do |dir|
      # Collect some data
      data = Rperf.start(frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      path = File.join(dir, "test.txt")
      Rperf.save(path, data, format: :collapsed)

      content = File.read(path)
      lines = content.strip.split("\n")
      assert_operator lines.size, :>, 0

      lines.each do |line|
        _stack, weight_str = line.rpartition(" ").then { |s, _, w| [s, w] }
        weight = weight_str.to_i
        assert_operator weight, :>, 0, "Weight should be positive"
      end
    end
  end

  # --- Fork safety tests ---

  def test_fork_stops_profiling_in_child
    Rperf.start(frequency: 100)

    rd, wr = IO.pipe
    pid = fork do
      rd.close
      # In child: profiling should be silently stopped
      result = Rperf.stop
      wr.puts(result.nil? ? "nil" : "not_nil")

      # Should be able to start a new session in child
      Rperf.start(frequency: 100)
      1_000_000.times { 1 + 1 }
      data = Rperf.stop
      wr.puts(data.nil? ? "no_data" : "has_data")
      wr.close
    end

    wr.close
    lines = rd.read.split("\n")
    rd.close
    _, status = Process.waitpid2(pid)

    assert status.success?, "Child process should exit successfully"
    assert_equal "nil", lines[0], "Rperf.stop in child should return nil"
    assert_equal "has_data", lines[1], "New profiling session in child should work"

    # Parent profiling should continue normally
    1_000_000.times { 1 + 1 }
    data = Rperf.stop
    assert_not_nil data, "Parent profiling should still work after fork"
    assert_operator data[:aggregated_samples].size, :>, 0
  end

  private

  # CPU work that periodically releases the GVL via sleep(0).
  # This avoids the running_ec race in the Ruby VM where
  # rb_postponed_job_trigger notifications can be misdirected.
  def cpu_work_with_gvl_yield(n = 50_000_000)
    chunk = 500_000
    (n / chunk).times do
      chunk.times { 1 + 1 }
      sleep(0)
    end
  end

  def busy_wait(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end
  end

  def deep_recurse(depth, &block)
    if depth <= 0
      block.call
    else
      deep_recurse(depth - 1, &block)
    end
  end

  # Frames are now [path_str, label_str] (Ruby strings)
  def assert_valid_samples(samples)
    samples.each_with_index do |(frames, weight), i|
      assert_operator weight, :>, 0, "Sample #{i}: weight should be positive"
      assert_operator frames.size, :>, 0, "Sample #{i}: should have at least 1 frame"
      frames.each_with_index do |frame, j|
        assert_kind_of String, frame[0], "Sample #{i} frame #{j}: path should be String"
        assert_kind_of String, frame[1], "Sample #{i} frame #{j}: label should be String"
      end
    end
  end
end
