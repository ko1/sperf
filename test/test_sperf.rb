require "test-unit"
require "sperf"
require "tempfile"
require "zlib"

class TestSperf < Test::Unit::TestCase
  def teardown
    # Ensure profiler is stopped after each test
    Sperf.stop rescue nil
  end

  def test_start_stop
    Sperf.start(frequency: 100)
    # Do some work
    1_000_000.times { 1 + 1 }
    data = Sperf.stop

    assert_kind_of Hash, data
    assert_include data, :samples
    assert_include data, :frequency
    assert_equal 100, data[:frequency]
  end

  def test_cpu_bound_weight
    Sperf.start(frequency: 1000)
    10_000_000.times { 1 + 1 }
    data = Sperf.stop

    assert_not_nil data
    samples = data[:samples]

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
      Sperf.start(output: path, frequency: 500) do
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
    Sperf.start(frequency: 1000)

    threads = 4.times.map do
      Thread.new { 5_000_000.times { 1 + 1 } }
    end
    threads.each(&:join)

    data = Sperf.stop
    assert_not_nil data
    assert_operator data[:samples].size, :>, 0, "Should have samples from threads"
  end

  def test_double_start_raises
    Sperf.start(frequency: 100)
    assert_raise(RuntimeError) { Sperf.start(frequency: 100) }
    Sperf.stop
  end

  def test_stop_without_start_returns_nil
    assert_nil Sperf.stop
  end

  def test_restart_clears_thread_state
    # First session
    Sperf.start(frequency: 1000)
    1_000_000.times { 1 + 1 }
    data1 = Sperf.stop

    # Sleep to create a gap between sessions
    sleep 0.2

    # Second session - weights should NOT include the 200ms gap
    Sperf.start(frequency: 1000)
    1_000_000.times { 1 + 1 }
    data2 = Sperf.stop

    assert_not_nil data1
    assert_not_nil data2

    max_weight2 = data2[:samples].map { |_, w| w }.max || 0

    # The max weight in session 2 should be reasonable (< 100ms).
    # Without the fix, it would include the 200ms sleep gap.
    assert_operator max_weight2, :<, 100_000_000,
      "Max weight in second session (#{max_weight2}ns) should not include the gap between sessions"
  end

  # --- Boundary / realloc tests ---

  # Sample buffer initial capacity is 1024.
  # With 4 threads at 1000Hz, ~4000 samples/sec → crosses boundary in <1s.
  def test_sample_buffer_realloc
    Sperf.start(frequency: 1000)

    threads = 4.times.map do
      Thread.new { 10_000_000.times { 1 + 1 } }
    end
    threads.each(&:join)

    data = Sperf.stop
    assert_not_nil data
    samples = data[:samples]

    # Must have crossed initial capacity of 1024
    assert_operator samples.size, :>, 1024,
      "Expected >1024 samples to exercise realloc (got #{samples.size})"

    # Verify all samples have valid data
    assert_valid_samples(samples)
  end

  # Frame pool initial capacity is ~131K frames (1MB / 8 bytes per VALUE).
  # Use deep recursion + many threads to generate lots of frames quickly.
  def test_frame_pool_realloc
    Sperf.start(frequency: 1000)

    threads = 8.times.map do
      Thread.new do
        deep_recurse(100) { 20_000_000.times { 1 + 1 } }
      end
    end
    threads.each(&:join)

    data = Sperf.stop
    assert_not_nil data
    samples = data[:samples]

    # Calculate total frames stored
    total_frames = samples.sum { |frames, _| frames.size }
    initial_pool = 1024 * 1024 / 8  # ~131072

    assert_operator total_frames, :>, initial_pool,
      "Expected >#{initial_pool} total frames to exercise frame pool realloc (got #{total_frames})"

    # Verify early and late samples both have valid frame data
    assert_valid_samples(samples.first(10))
    assert_valid_samples(samples.last(10))
  end

  # Generate deep call stacks via recursion
  def test_deep_stack
    Sperf.start(frequency: 1000)

    deep_recurse(200) { 5_000_000.times { 1 + 1 } }

    data = Sperf.stop
    assert_not_nil data
    samples = data[:samples]
    assert_operator samples.size, :>, 0

    max_depth = samples.map { |frames, _| frames.size }.max
    assert_operator max_depth, :>=, 50,
      "Expected deep stacks (max depth #{max_depth})"

    assert_valid_samples(samples)
  end

  # Threads created and destroyed during profiling
  def test_thread_churn
    Sperf.start(frequency: 1000)

    20.times do
      threads = 4.times.map do
        Thread.new { 500_000.times { 1 + 1 } }
      end
      threads.each(&:join)
    end

    data = Sperf.stop
    assert_not_nil data
    assert_operator data[:samples].size, :>, 0
    assert_valid_samples(data[:samples])
  end

  # Restart with threads that survive across sessions
  def test_restart_with_surviving_thread
    worker_running = true
    worker = Thread.new do
      i = 0
      i += 1 while worker_running
    end

    # Session 1
    Sperf.start(frequency: 1000)
    5_000_000.times { 1 + 1 }
    data1 = Sperf.stop

    sleep 0.2

    # Session 2 - surviving worker thread must not carry stale state
    Sperf.start(frequency: 1000)
    5_000_000.times { 1 + 1 }
    data2 = Sperf.stop

    worker_running = false
    worker.join

    assert_not_nil data1
    assert_not_nil data2
    assert_operator data2[:samples].size, :>, 0

    max_weight2 = data2[:samples].map { |_, w| w }.max || 0
    assert_operator max_weight2, :<, 100_000_000,
      "Surviving thread's max weight (#{max_weight2}ns) should not include inter-session gap"
  end

  # Multiple start/stop cycles to check no resource leaks cause crashes
  def test_repeated_start_stop
    10.times do |cycle|
      Sperf.start(frequency: 1000)
      1_000_000.times { 1 + 1 }
      data = Sperf.stop

      assert_not_nil data, "Cycle #{cycle}: stop should return data"
      assert_operator data[:samples].size, :>, 0, "Cycle #{cycle}: should have samples"
    end
  end

  # --- GVL event tracking tests ---

  def test_gvl_blocked_frames_wall_mode
    Sperf.start(frequency: 100, mode: :wall)

    # sleep releases GVL → triggers SUSPENDED/READY/RESUMED
    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Sperf.stop
    assert_not_nil data

    labels = data[:samples].flat_map { |frames, _| frames.map { |_, label| label } }
    has_blocked = labels.include?("[GVL blocked]")
    has_wait = labels.include?("[GVL wait]")

    assert has_blocked || has_wait,
      "Wall mode with sleep should produce [GVL blocked] or [GVL wait] samples"
  end

  def test_gvl_events_cpu_mode_no_synthetic
    Sperf.start(frequency: 100, mode: :cpu)

    threads = 4.times.map do
      Thread.new { 20.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Sperf.stop
    assert_not_nil data

    labels = data[:samples].flat_map { |frames, _| frames.map { |_, label| label } }
    refute labels.include?("[GVL blocked]"),
      "CPU mode should NOT produce [GVL blocked] samples"
    refute labels.include?("[GVL wait]"),
      "CPU mode should NOT produce [GVL wait] samples"
  end

  def test_gvl_wait_weight_positive
    Sperf.start(frequency: 100, mode: :wall)

    # Multiple threads contending for GVL
    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.001 } }
    end
    threads.each(&:join)

    data = Sperf.stop
    assert_not_nil data

    gvl_samples = data[:samples].select { |frames, _|
      frames.any? { |_, label| label == "[GVL blocked]" || label == "[GVL wait]" }
    }

    gvl_samples.each do |_, weight|
      assert_operator weight, :>, 0, "GVL sample weight should be positive"
    end
  end

  # RESUMED must create thread_data so that a subsequent SUSPENDED can
  # record a sample. Without this, C busy-wait threads (no safepoints)
  # lose their entire CPU time because SUSPENDED sees is_first=1.
  def test_c_busy_wait_thread_captured_cpu
    begin
      $LOAD_PATH.unshift(File.expand_path("../benchmark/lib", __dir__))
      require "sperf_workload_methods"
    rescue LoadError
      omit "benchmark workload not built (cd benchmark && rake compile)"
    end

    Sperf.start(frequency: 1000, mode: :cpu)
    t = Thread.new { SperfWorkload.cw1(100_000) }  # 100ms C busy-wait
    t.join
    data = Sperf.stop

    total_weight = data[:samples].sum { |_, w| w }
    # cw1 holds GVL with no safepoints; only SUSPENDED captures it.
    # Should see ~100ms of CPU time.
    assert_operator total_weight, :>, 50_000_000,
      "C busy-wait thread should be captured (got #{"%.1f" % (total_weight / 1_000_000.0)}ms, expect ~100ms)"
  end

  def test_c_busy_wait_thread_captured_wall
    begin
      require "sperf_workload_methods"
    rescue LoadError
      omit "benchmark workload not built (cd benchmark && rake compile)"
    end

    Sperf.start(frequency: 1000, mode: :wall)
    t = Thread.new { SperfWorkload.cw1(100_000) }  # 100ms C busy-wait
    t.join
    data = Sperf.stop

    total_weight = data[:samples].sum { |_, w| w }
    assert_operator total_weight, :>, 50_000_000,
      "C busy-wait thread should be captured in wall mode (got #{"%.1f" % (total_weight / 1_000_000.0)}ms)"
  end

  def test_pprof_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.pb.gz")
      Sperf.start(output: path, frequency: 500) do
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
    exe = File.expand_path("../exe/sperf", __dir__)
    output = IO.popen([RbConfig.ruby, exe, "help"], &:read)

    assert_equal 0, $?.exitstatus, "sperf help should exit 0"
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

    Sperf.start(frequency: 500, mode: :wall, stat: true)
    5_000_000.times { 1 + 1 }
    data = Sperf.stop

    output = $stderr.string
    $stderr = old_stderr

    assert_not_nil data
    assert_include output, "Performance stats"
    assert_include output, "real"
    assert_include output, "CPU execution"
  end

  def test_print_stat
    data = {
      samples: [
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
    ENV["SPERF_STAT_COMMAND"] = "ruby test.rb"

    Sperf.instance_variable_set(:@stat_start_mono,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.2)
    Sperf.print_stat(data)

    output = $stderr.string
    $stderr = old_stderr
    ENV.delete("SPERF_STAT_COMMAND")

    assert_include output, "Performance stats for 'ruby test.rb'"
    assert_include output, "user"
    assert_include output, "sys"
    assert_include output, "real"
    assert_include output, "CPU execution"
    assert_include output, "GVL blocked"
    assert_include output, "GC marking"
    assert_include output, "GC time"
    assert_include output, "allocated objects"
    assert_include output, "freed objects"
    assert_include output, "Top"
    assert_include output, "samples"
    assert_include output, "unique stacks"
    assert_include output, "profiler overhead"
  end

  # --- Text format tests ---

  def test_text_encode
    data = {
      samples: [
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 1_000_000],
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 2_000_000],
        [[["/c.rb", "C#baz"]], 500_000],
      ],
      frequency: 100,
      mode: :cpu,
    }

    result = Sperf::Text.encode(data)

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
      Sperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path), "Output file should exist"
      content = File.read(path)

      assert_include content, "Total:"
      assert_include content, "Flat:"
      assert_include content, "Cumulative:"
      # Weight lines should have ms and %
      assert_match(/\d+\.\d+ms\s+\d+\.\d+%/, content)
    end
  end

  def test_save_text
    Dir.mktmpdir do |dir|
      data = Sperf.start(frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      path = File.join(dir, "report.dat")
      Sperf.save(path, data, format: :text)

      content = File.read(path)
      assert_include content, "Total:"
      assert_include content, "Flat:"
      assert_include content, "Cumulative:"
    end
  end

  def test_text_encode_empty
    data = { samples: [], frequency: 100, mode: :cpu }
    result = Sperf::Text.encode(data)
    assert_equal "No samples recorded.\n", result
  end

  # --- Collapsed stacks format tests ---

  def test_collapsed_encode
    data = {
      samples: [
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 1000],
        [[["/a.rb", "A#foo"], ["/b.rb", "B#bar"]], 2000],
        [[["/c.rb", "C#baz"]], 500],
      ],
      frequency: 100,
      mode: :cpu,
    }

    result = Sperf::Collapsed.encode(data)
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
      Sperf.start(output: path, frequency: 500) do
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
      data = Sperf.start(frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      path = File.join(dir, "test.txt")
      Sperf.save(path, data, format: :collapsed)

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
    Sperf.start(frequency: 100)

    rd, wr = IO.pipe
    pid = fork do
      rd.close
      # In child: profiling should be silently stopped
      result = Sperf.stop
      wr.puts(result.nil? ? "nil" : "not_nil")

      # Should be able to start a new session in child
      Sperf.start(frequency: 100)
      1_000_000.times { 1 + 1 }
      data = Sperf.stop
      wr.puts(data.nil? ? "no_data" : "has_data")
      wr.close
    end

    wr.close
    lines = rd.read.split("\n")
    rd.close
    _, status = Process.waitpid2(pid)

    assert status.success?, "Child process should exit successfully"
    assert_equal "nil", lines[0], "Sperf.stop in child should return nil"
    assert_equal "has_data", lines[1], "New profiling session in child should work"

    # Parent profiling should continue normally
    1_000_000.times { 1 + 1 }
    data = Sperf.stop
    assert_not_nil data, "Parent profiling should still work after fork"
    assert_operator data[:samples].size, :>, 0
  end

  private

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
