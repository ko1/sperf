require_relative "test_helper"

class TestRperfFork < Test::Unit::TestCase
  include RperfTestHelper

  def test_fork_stops_profiling_in_child
    Rperf.start(frequency: 100)

    rd, wr = IO.pipe
    pid = fork do
      rd.close
      result = Rperf.stop
      wr.puts(result.nil? ? "nil" : "not_nil")

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

    1_000_000.times { 1 + 1 }
    data = Rperf.stop
    assert_not_nil data, "Parent profiling should still work after fork"
    assert_operator data[:aggregated_samples].size, :>, 0
  end

  def test_repeated_start_stop_then_fork_no_signal_death
    # Regression test: repeated start/stop cycles could leave a pending RT
    # signal that kills the process after fork (exit code 128+42).
    10.times do
      3.times do
        Rperf.start(frequency: 1000)
        200_000.times { 1 + 1 }
        Rperf.stop
      end

      rd, wr = IO.pipe
      pid = fork do
        rd.close
        result = Rperf.stop
        wr.puts(result.nil? ? "nil" : "non_nil")
        Rperf.start(frequency: 100)
        100_000.times { 1 + 1 }
        data = Rperf.stop
        wr.puts(data.nil? ? "no_data" : "has_data")
        wr.close
      end

      wr.close
      lines = rd.read.split("\n")
      rd.close
      _, status = Process.waitpid2(pid)

      assert status.success?, "Child killed by signal #{status.termsig} on iteration"
      assert_equal "nil", lines[0]
      assert_equal "has_data", lines[1]
    end
  end
end
