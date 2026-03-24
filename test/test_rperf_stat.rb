require_relative "test_helper"

class TestRperfStat < Test::Unit::TestCase
  include RperfTestHelper

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
end
