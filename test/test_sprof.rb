require "test-unit"
require "sprof"
require "tempfile"
require "zlib"

class TestSprof < Test::Unit::TestCase
  def teardown
    # Ensure profiler is stopped after each test
    Sprof.stop rescue nil
  end

  def test_start_stop
    Sprof.start(frequency: 100)
    # Do some work
    1_000_000.times { 1 + 1 }
    data = Sprof.stop

    assert_kind_of Hash, data
    assert_include data, :samples
    assert_include data, :frequency
    assert_equal 100, data[:frequency]
  end

  def test_cpu_bound_weight
    Sprof.start(frequency: 1000)
    10_000_000.times { 1 + 1 }
    data = Sprof.stop

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
      Sprof.profile(output: path, frequency: 500) do
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
    Sprof.start(frequency: 1000)

    threads = 4.times.map do
      Thread.new { 5_000_000.times { 1 + 1 } }
    end
    threads.each(&:join)

    data = Sprof.stop
    assert_not_nil data
    assert_operator data[:samples].size, :>, 0, "Should have samples from threads"
  end

  def test_double_start_raises
    Sprof.start(frequency: 100)
    assert_raise(RuntimeError) { Sprof.start(frequency: 100) }
    Sprof.stop
  end

  def test_stop_without_start_returns_nil
    assert_nil Sprof.stop
  end

  def test_restart_clears_thread_state
    # First session
    Sprof.start(frequency: 1000)
    1_000_000.times { 1 + 1 }
    data1 = Sprof.stop

    # Sleep to create a gap between sessions
    sleep 0.2

    # Second session - weights should NOT include the 200ms gap
    Sprof.start(frequency: 1000)
    1_000_000.times { 1 + 1 }
    data2 = Sprof.stop

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
    Sprof.start(frequency: 1000)

    threads = 4.times.map do
      Thread.new { 10_000_000.times { 1 + 1 } }
    end
    threads.each(&:join)

    data = Sprof.stop
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
    Sprof.start(frequency: 1000)

    threads = 8.times.map do
      Thread.new do
        deep_recurse(100) { 20_000_000.times { 1 + 1 } }
      end
    end
    threads.each(&:join)

    data = Sprof.stop
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
    Sprof.start(frequency: 1000)

    deep_recurse(200) { 5_000_000.times { 1 + 1 } }

    data = Sprof.stop
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
    Sprof.start(frequency: 1000)

    20.times do
      threads = 4.times.map do
        Thread.new { 500_000.times { 1 + 1 } }
      end
      threads.each(&:join)
    end

    data = Sprof.stop
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
    Sprof.start(frequency: 1000)
    5_000_000.times { 1 + 1 }
    data1 = Sprof.stop

    sleep 0.2

    # Session 2 - surviving worker thread must not carry stale state
    Sprof.start(frequency: 1000)
    5_000_000.times { 1 + 1 }
    data2 = Sprof.stop

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
      Sprof.start(frequency: 1000)
      1_000_000.times { 1 + 1 }
      data = Sprof.stop

      assert_not_nil data, "Cycle #{cycle}: stop should return data"
      assert_operator data[:samples].size, :>, 0, "Cycle #{cycle}: should have samples"
    end
  end

  def test_pprof_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.pb.gz")
      Sprof.profile(output: path, frequency: 500) do
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
