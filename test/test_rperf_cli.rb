require_relative "test_helper"
require "open3"

class TestRperfCli < Test::Unit::TestCase
  include RperfTestHelper

  RPERF_EXE = File.expand_path("../exe/rperf", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)

  private

  def run_rperf(*args, env: {})
    cmd = [RbConfig.ruby, "-I", LIB_DIR, RPERF_EXE, *args]
    stdout, stderr, status = Open3.capture3(env, *cmd)
    [stdout, stderr, status]
  end

  # Run rperf with a short Ruby workload as the command
  def run_rperf_with_workload(*args, env: {})
    run_rperf(*args, RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }", env: env)
  end

  public

  # --- help subcommand ---

  def test_cli_help_subcommand
    stdout, _, status = run_rperf("help")
    assert_equal 0, status.exitstatus, "rperf help should exit 0"
    assert_include stdout, "OVERVIEW"
    assert_include stdout, "CLI USAGE"
    assert_include stdout, "RUBY API"
    assert_include stdout, "PROFILING MODES"
    assert_include stdout, "OUTPUT FORMATS"
    assert_include stdout, "SYNTHETIC FRAMES"
    assert_include stdout, "INTERPRETING RESULTS"
    assert_include stdout, "DIAGNOSING COMMON PERFORMANCE PROBLEMS"
  end

  # --- version ---

  def test_cli_version_short
    stdout, _, status = run_rperf("-v")
    assert_equal 0, status.exitstatus
    assert_match(/rperf \d+\.\d+\.\d+/, stdout)
  end

  def test_cli_version_long
    stdout, _, status = run_rperf("--version")
    assert_equal 0, status.exitstatus
    assert_match(/rperf \d+\.\d+\.\d+/, stdout)
  end

  # --- top-level help flag ---

  def test_cli_help_flag
    stdout, _, status = run_rperf("-h")
    assert_equal 0, status.exitstatus
    assert_include stdout, "Usage: rperf"
  end

  def test_cli_help_flag_long
    stdout, _, status = run_rperf("--help")
    assert_equal 0, status.exitstatus
    assert_include stdout, "Usage: rperf"
  end

  # --- unknown subcommand ---

  def test_cli_unknown_subcommand
    _, stderr, status = run_rperf("bogus")
    refute_equal 0, status.exitstatus
    assert_include stderr, "Unknown subcommand"
  end

  def test_cli_no_subcommand
    _, stderr, status = run_rperf
    refute_equal 0, status.exitstatus
    assert_include stderr, "Usage: rperf"
  end

  # --- error cases ---

  def test_cli_frequency_zero
    _, stderr, status = run_rperf("stat", "-f", "0", "true")
    refute_equal 0, status.exitstatus
    assert_include stderr, "frequency must be a positive integer"
  end

  def test_cli_frequency_too_high
    _, stderr, status = run_rperf("record", "-f", "99999", "true")
    refute_equal 0, status.exitstatus
    assert_include stderr, "frequency must be <= 10000"
  end

  def test_cli_record_no_command
    _, stderr, status = run_rperf("record")
    refute_equal 0, status.exitstatus
    assert_include stderr, "No command specified"
  end

  def test_cli_stat_no_command
    _, stderr, status = run_rperf("stat")
    refute_equal 0, status.exitstatus
    assert_include stderr, "No command specified"
  end

  def test_cli_record_invalid_option
    _, stderr, status = run_rperf("record", "--nonexistent", "true")
    refute_equal 0, status.exitstatus
    assert_include stderr, "invalid option"
  end

  # --- record subcommand ---

  def test_cli_record_basic
    Dir.mktmpdir do |dir|
      outfile = File.join(dir, "out.pb.gz")
      _, _, status = run_rperf("record", "-f", "100", "-o", outfile,
                               RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
      assert_equal 0, status.exitstatus, "rperf record should succeed"
      assert File.exist?(outfile), "Output file should be created"
      content = File.binread(outfile)
      assert_equal "\x1f\x8b".b, content[0, 2], "Should be gzip (pprof) format"
    end
  end

  def test_cli_record_mode_wall
    Dir.mktmpdir do |dir|
      outfile = File.join(dir, "out.pb.gz")
      _, _, status = run_rperf("record", "-f", "100", "-m", "wall", "-o", outfile,
                               RbConfig.ruby, "-e", "sleep 0.1")
      assert_equal 0, status.exitstatus
      assert File.exist?(outfile)
    end
  end

  def test_cli_record_print
    stdout, _, status = run_rperf("record", "-f", "100", "-p",
                                  RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
    assert_equal 0, status.exitstatus
    # -p outputs text profile to stdout
    assert_match(/Total:/, stdout)
  end

  def test_cli_record_format_collapsed
    Dir.mktmpdir do |dir|
      outfile = File.join(dir, "out.collapsed")
      _, _, status = run_rperf("record", "-f", "100", "--format", "collapsed", "-o", outfile,
                               RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
      assert_equal 0, status.exitstatus
      content = File.read(outfile)
      # Collapsed format: "stack1;stack2 weight\n"
      refute_equal "\x1f\x8b".b, content[0, 2], "Should NOT be gzip"
      assert_match(/\d+$/, content.lines.first.chomp) if content.size > 0
    end
  end

  def test_cli_record_verbose
    _, stderr, status = run_rperf("record", "-f", "100", "-v", "-o", File::NULL,
                                  RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
    assert_equal 0, status.exitstatus
    assert_include stderr, "[rperf]"
  end

  def test_cli_record_no_aggregate
    Dir.mktmpdir do |dir|
      outfile = File.join(dir, "out.pb.gz")
      _, _, status = run_rperf("record", "-f", "100", "--no-aggregate", "-o", outfile,
                               RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
      assert_equal 0, status.exitstatus
      assert File.exist?(outfile)
    end
  end

  def test_cli_record_signal_false
    Dir.mktmpdir do |dir|
      outfile = File.join(dir, "out.pb.gz")
      _, _, status = run_rperf("record", "-f", "100", "--signal", "false", "-o", outfile,
                               RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
      assert_equal 0, status.exitstatus
      assert File.exist?(outfile)
    end
  end

  def test_cli_record_help
    stdout, _, status = run_rperf("record", "-h")
    assert_equal 0, status.exitstatus
    assert_include stdout, "Usage: rperf record"
    assert_include stdout, "--output"
    assert_include stdout, "--frequency"
  end

  # --- stat subcommand ---

  def test_cli_stat_basic
    _, stderr, status = run_rperf("stat", "-f", "100",
                                  RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
    assert_include stderr, "real"
  end

  def test_cli_stat_mode_cpu
    _, stderr, status = run_rperf("stat", "-f", "100", "-m", "cpu",
                                  RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
  end

  def test_cli_stat_report
    _, stderr, status = run_rperf("stat", "-f", "100", "--report",
                                  RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
    # --report includes flat/cumulative tables
    assert_include stderr, "Flat"
    assert_include stderr, "Cumulative"
  end

  def test_cli_stat_with_output
    Dir.mktmpdir do |dir|
      outfile = File.join(dir, "stat_out.pb.gz")
      _, stderr, status = run_rperf("stat", "-f", "100", "-o", outfile,
                                    RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
      assert_equal 0, status.exitstatus
      assert_include stderr, "Performance stats"
      assert File.exist?(outfile), "stat with -o should write output file"
    end
  end

  def test_cli_stat_help
    stdout, _, status = run_rperf("stat", "-h")
    assert_equal 0, status.exitstatus
    assert_include stdout, "Usage: rperf stat"
    assert_include stdout, "--report"
  end

  # --- exec subcommand ---

  def test_cli_exec_basic
    _, stderr, status = run_rperf("exec", "-f", "100",
                                  RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
    assert_include stderr, "real"
    # exec always includes flat/cumulative tables (like stat --report)
    assert_include stderr, "Flat"
    assert_include stderr, "Cumulative"
  end

  def test_cli_exec_no_command
    _, stderr, status = run_rperf("exec")
    refute_equal 0, status.exitstatus
    assert_include stderr, "No command specified"
  end

  def test_cli_exec_help
    stdout, _, status = run_rperf("exec", "-h")
    assert_equal 0, status.exitstatus
    assert_include stdout, "Usage: rperf exec"
  end

  def test_cli_exec_mode_cpu
    _, stderr, status = run_rperf("exec", "-f", "100", "-m", "cpu",
                                  RbConfig.ruby, "-e", "5_000_000.times { 1 + 1 }")
    assert_equal 0, status.exitstatus
    assert_include stderr, "Performance stats"
    assert_include stderr, "Flat"
  end

  # --- ENV auto-start ---

  def test_cli_env_auto_start
    Dir.mktmpdir do |dir|
      outfile = File.join(dir, "env_out.pb.gz")
      env = {
        "RPERF_ENABLED" => "1",
        "RPERF_OUTPUT" => outfile,
        "RPERF_FREQUENCY" => "100",
        "RPERF_MODE" => "cpu",
      }
      _, _, status = Open3.capture3(env,
        RbConfig.ruby, "-I", LIB_DIR, "-rrperf", "-e", "5_000_000.times { 1 + 1 }")
      assert_equal 0, status.exitstatus
      assert File.exist?(outfile), "RPERF_ENABLED=1 should auto-start and write output"
    end
  end

  def test_cli_env_auto_start_wall_mode
    Dir.mktmpdir do |dir|
      outfile = File.join(dir, "env_wall.pb.gz")
      env = {
        "RPERF_ENABLED" => "1",
        "RPERF_OUTPUT" => outfile,
        "RPERF_FREQUENCY" => "100",
        "RPERF_MODE" => "wall",
      }
      _, _, status = Open3.capture3(env,
        RbConfig.ruby, "-I", LIB_DIR, "-rrperf", "-e", "sleep 0.05")
      assert_equal 0, status.exitstatus
      assert File.exist?(outfile)
    end
  end

  def test_cli_env_invalid_mode
    env = {
      "RPERF_ENABLED" => "1",
      "RPERF_MODE" => "invalid",
    }
    _, stderr, status = Open3.capture3(env,
      RbConfig.ruby, "-I", LIB_DIR, "-rrperf", "-e", "true")
    refute_equal 0, status.exitstatus
    assert_include stderr, "RPERF_MODE must be 'cpu' or 'wall'"
  end
end
