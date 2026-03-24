require_relative "test_helper"

class TestRperfProfiler < Test::Unit::TestCase
  include RperfTestHelper

  def test_start_stop
    Rperf.start(frequency: 100)
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
    assert_operator samples.size, :>, 0, "Expected at least 1 sample"

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
      assert_equal "\x1f\x8b".b, content[0, 2], "Should be gzip format"

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
    Rperf.start(frequency: 1000, aggregate: false)
    1_000_000.times { 1 + 1 }
    data1 = Rperf.stop

    sleep 0.2

    Rperf.start(frequency: 1000, aggregate: false)
    1_000_000.times { 1 + 1 }
    data2 = Rperf.stop

    assert_not_nil data1
    assert_not_nil data2

    max_weight2 = data2[:raw_samples].map { |_, w| w }.max || 0
    assert_operator max_weight2, :<, 100_000_000,
      "Max weight in second session (#{max_weight2}ns) should not include the gap between sessions"
  end

  def test_repeated_start_stop
    10.times do |cycle|
      Rperf.start(frequency: 1000)
      1_000_000.times { 1 + 1 }
      data = Rperf.stop

      assert_not_nil data, "Cycle #{cycle}: stop should return data"
      assert_operator data[:aggregated_samples].size, :>, 0, "Cycle #{cycle}: should have samples"
    end
  end

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

    assert_valid_samples(data[:aggregated_samples])
  end

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

    samples = data[:aggregated_samples]
    assert_valid_samples(samples.first(10))
    assert_valid_samples(samples.last(10))
  end

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

  def test_restart_with_surviving_thread
    worker_running = true
    worker = Thread.new do
      while worker_running
        500_000.times { 1 + 1 }
        sleep(0)
      end
    end

    Rperf.start(frequency: 1000, aggregate: false)
    5_000_000.times { 1 + 1 }
    data1 = Rperf.stop

    sleep 0.2

    Rperf.start(frequency: 1000, aggregate: false)
    5_000_000.times { 1 + 1 }
    data2 = Rperf.stop

    worker_running = false
    worker.join

    assert_not_nil data1
    assert_not_nil data2
    assert_operator data2[:raw_samples].size, :>, 0

    max_weight2 = data2[:raw_samples].map { |_, w| w }.max || 0
    assert_operator max_weight2, :<, 200_000_000,
      "Surviving thread's max weight (#{max_weight2}ns) should not include inter-session gap"
  end

  def test_frame_table_growth
    Rperf.start(frequency: 1000)
    deep_recurse(200) { busy_wait(2.0) }
    data = Rperf.stop

    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
    assert_valid_samples(data[:aggregated_samples])
  end

  # --- Input validation ---

  def test_frequency_zero_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: 0) }
  end

  def test_frequency_negative_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: -1) }
  end

  def test_frequency_non_integer_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: 1.5) }
  end

  def test_frequency_too_high_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: 10_001) }
  end

  def test_signal_kill_raises
    assert_raise(ArgumentError) { Rperf.start(signal: 9) }
  end

  def test_signal_stop_raises
    assert_raise(ArgumentError) { Rperf.start(signal: 19) }
  end

  def test_signal_string_kill_raises
    assert_raise(ArgumentError) { Rperf.start(signal: "9") }
  end

  def test_signal_false_ok
    data = Rperf.start(frequency: 500, signal: false) do
      5_000_000.times { 1 + 1 }
    end
    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
  end
end
