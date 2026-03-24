require "test-unit"
require "rperf"
require "tempfile"
require "zlib"

module RperfTestHelper
  def teardown
    Rperf.stop rescue nil
  end

  private

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
