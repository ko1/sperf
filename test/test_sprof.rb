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
    assert_include data, :string_table
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
end
