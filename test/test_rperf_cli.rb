require_relative "test_helper"

class TestRperfCli < Test::Unit::TestCase
  include RperfTestHelper

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

  def test_cli_frequency_zero
    exe = File.expand_path("../exe/rperf", __dir__)
    output = IO.popen([RbConfig.ruby, exe, "stat", "-f", "0", "true"], err: [:child, :out], &:read)
    refute_equal 0, $?.exitstatus, "rperf with frequency 0 should fail"
    assert_include output, "frequency must be a positive integer"
  end
end
