require_relative "test_helper"

class TestRperfOutput < Test::Unit::TestCase
  include RperfTestHelper

  # --- PProf ---

  def test_pprof_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.pb.gz")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      content = File.binread(path)
      decompressed = Zlib::GzipReader.new(StringIO.new(content)).read
      assert_equal 0x0a, decompressed.getbyte(0),
        "First field should be sample_type (field 1, length-delimited)"
    end
  end

  # --- Text ---

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

  # --- Collapsed ---

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

  # --- aggregate: false + output formats ---

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
end
