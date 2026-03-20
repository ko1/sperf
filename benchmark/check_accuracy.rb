#!/usr/bin/env ruby
# frozen_string_literal: true

# Sperf accuracy benchmark runner

require "json"
require "open3"
require "etc"
require "optparse"

# Parse options
scenario_file = File.join(__dir__, "scenarios_mixed.json")
tolerance = 0.20
profiling_mode = :cpu
profiler = "sperf"
frequency = 1000
cpu_load = false
verbose = false

parser = OptionParser.new do |opts|
  opts.banner = "Usage: check_accuracy.rb [options] [scenario_ids...]"
  opts.separator ""
  opts.separator "Examples:"
  opts.separator "  ruby check_accuracy.rb                        # all scenarios, sperf, cpu mode"
  opts.separator "  ruby check_accuracy.rb 0                      # scenario #0 only"
  opts.separator "  ruby check_accuracy.rb 0-4                    # scenarios #0 through #4"
  opts.separator "  ruby check_accuracy.rb -P stackprof -m wall   # stackprof, wall mode"
  opts.separator ""

  opts.on("-f", "--file FILE", "Scenario file (default: scenarios_mixed.json)") do |v|
    scenario_file = File.join(__dir__, v)
  end
  opts.on("-m", "--mode MODE", "Profiling mode: cpu or wall (default: cpu)") do |v|
    profiling_mode = v.to_sym
  end
  opts.on("-t", "--tolerance PCT", Integer, "Pass tolerance in % (default: 20)") do |v|
    tolerance = v / 100.0
  end
  opts.on("-F", "--frequency HZ", Integer, "Sampling frequency in Hz (default: 1000)") do |v|
    frequency = v
  end
  opts.on("-P", "--profiler NAME", "Profiler: sperf, stackprof, vernier, pf2 (default: sperf)") do |v|
    profiler = v
  end
  opts.on("-l", "--load", "Run under CPU load (all cores busy)") do
    cpu_load = true
  end
  opts.on("-v", "--verbose", "Show per-method detail and raw output for all scenarios") do
    verbose = true
  end
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end
parser.parse!(ARGV)
args = ARGV

scenarios = JSON.parse(File.read(scenario_file))

# Detect scenario type
ratio_mode = scenarios.first&.dig("type") == "ratio"

unless ratio_mode
  # Pick expected_ms key based on mode
  expected_key = "expected_#{profiling_mode}_ms"

  # Validate that the scenario file has the expected key
  unless scenarios.first&.key?(expected_key)
    # Fallback: legacy format with "expected_ms"
    if scenarios.first&.key?("expected_ms")
      expected_key = "expected_ms"
    else
      abort "Scenario file missing '#{expected_key}' (mode: #{profiling_mode})"
    end
  end
end

# Detect all method name prefixes used across scenarios
if ratio_mode
  all_prefixes = scenarios.flat_map { |s| s["call_counts"].keys.map { |name| name[/\A[a-z]+/] } }.uniq
else
  all_prefixes = scenarios.flat_map { |s| s["calls"].map { |name, _| name[/\A[a-z]+/] } }.uniq
end
method_prefix_re = all_prefixes.join("|")

# Parse arguments to select scenarios
selected =
  if args.empty?
    scenarios
  else
    ids = []
    args.each do |arg|
      if arg.include?("-")
        lo, hi = arg.split("-", 2).map(&:to_i)
        ids.concat((lo..hi).to_a)
      else
        ids << arg.to_i
      end
    end
    ids.map { |i| scenarios[i] || (abort "Scenario ##{i} not found") }
  end

$current_frequency = frequency

puts "=== Sperf Accuracy Check ==="
puts "File: #{File.basename(scenario_file)}"
puts "Profiler: #{profiler}"
puts "Mode: #{profiling_mode}"
puts "Frequency: #{frequency}Hz"
puts "Tolerance: #{(tolerance * 100).to_i}%"
puts "Load: #{cpu_load ? "ON (#{Etc.nprocessors} cores)" : "off"}"
puts "Running #{selected.size} scenario(s) out of #{scenarios.size}"
puts

# Spawn CPU-hogging processes to simulate load
load_pids = []
if cpu_load
  Etc.nprocessors.times do
    load_pids << spawn("ruby", "-e", "loop {}", [:out, :err] => File::NULL)
  end
end

# Runner script path
PROFRUN = File.join(__dir__, "profrun.rb")

# Derive script path from scenario file and scenario id
def script_path_for(scenario_file, scenario_id)
  # scenarios_mixed.json -> mixed, scenarios_ratio.json -> ratio
  type = File.basename(scenario_file, ".json").sub(/\Ascenarios_/, "")
  File.join(__dir__, "scripts", "#{type}_#{scenario_id}.rb")
end

# --- Profiler-specific result parsing ---

def parse_results_pprof(output_path, method_re)
  pprof_out, _pprof_err, pprof_status = Open3.capture3(
    "go", "tool", "pprof", "-top", "-nodecount=0", "-nodefraction=0", output_path
  )
  return nil, pprof_out unless pprof_status.success?

  actual_ms = {}
  pprof_out.each_line do |line|
    if line =~ method_re
      val = $1.to_f
      unit = $2
      name = $3
      actual_ms[name] = case unit
                        when "s"  then val * 1000.0
                        when "ms" then val
                        when "us" then val / 1000.0
                        else val
                        end
    end
  end
  [actual_ms, pprof_out]
end

def parse_results_stackprof(output_path, _method_re)
  raw_out, _err, status = Open3.capture3("stackprof", "--text", output_path)
  return nil, raw_out unless status.success?

  # Parse stackprof --text output:
  #      TOTAL    (pct)     SAMPLES    (pct)     FRAME
  #        234  (59.2%)          12   (3.0%)     SperfWorkload.rw317
  # TOTAL = cumulative sample count for the frame (what we want).
  # interval is in microseconds (cpu) or microseconds (wall).
  # Extract interval from the header: Mode: cpu(1000)
  interval_us = 1_000_000 / $current_frequency
  if raw_out =~ /Mode:\s+\w+\((\d+)\)/
    interval_us = $1.to_i
  end

  actual_ms = {}
  raw_out.each_line do |line|
    if line =~ /^\s+(\d+)\s+\(\s*[\d.]+%\)\s+\d+\s+\(\s*[\d.]+%\)\s+SperfWorkload\.((#{$method_prefix_re_global})\d+)\s*$/
      total_samples = $1.to_i
      name = $2
      actual_ms[name] = total_samples * interval_us / 1000.0
    end
  end
  [actual_ms, raw_out]
end

def parse_results_vernier(output_path, _method_re)
  begin
    data = JSON.parse(File.read(output_path))
  rescue => e
    return nil, e.message
  end

  t = data["threads"][0]
  strings = t["stringArray"]
  func_table = t["funcTable"]
  frame_table = t["frameTable"]
  stack_table = t["stackTable"]
  samples = t["samples"]

  # Compute cumulative time per function by walking the full stack
  cum_time = Hash.new(0.0)
  samples["length"].times do |i|
    weight = samples["weight"][i]  # ms
    seen = {}
    idx = samples["stack"][i]
    while idx
      fi = stack_table["frame"][idx]
      funci = frame_table["func"][fi]
      name = strings[func_table["name"][funci]]
      # Strip "SperfWorkload." prefix if present
      short = name.sub(/\ASperfWorkload\./, "")
      unless seen[short]
        cum_time[short] += weight
        seen[short] = true
      end
      idx = stack_table["prefix"][idx]
    end
  end

  raw_out = cum_time.sort_by { |_, v| -v }.map { |n, v| "  #{n}: #{v.round(1)}ms" }.join("\n")
  [cum_time, raw_out]
end

# --- Main loop ---

all_errors = []
failures = []

# Build regex for pprof parsing based on method prefix
# Matches cum column (4th value column): flat flat% sum% CUM cum% name
pprof_method_re = /^\s*\S+\s+\S+\s+\S+\s+([\d.]+)(s|ms|us)\s+[\d.]+%\s+(?:SperfWorkload\.)?((#{method_prefix_re})\d+)\s*$/
# For stackprof (needs to be accessible from parse function)
$method_prefix_re_global = method_prefix_re

# Provide access to the prefix regex from stackprof parser
def method_prefix_re_global
  $method_prefix_re_global
end

selected.each do |scenario|
  scenario_id = scenario["id"]

  if ratio_mode
    expected_ratio = scenario["expected_ratio"]
    if verbose
      puts format("--- Scenario #%-4d  expected (ratio) ---", scenario_id)
      expected_ratio.sort_by { |_, v| -v }.each do |method, r|
        puts format("  %-20s  %6.2f%%  (%d calls)", method, r * 100, scenario["call_counts"][method])
      end
      puts
    end
  else
    expected_ms = scenario[expected_key]
    if verbose
      puts format("--- Scenario #%-4d  expected (%s) ---", scenario_id, expected_key)
      expected_ms.sort_by { |_, v| -v }.each do |method, exp|
        puts format("  %-20s  %7.1fms", method, exp)
      end
      puts
    end
  end

  output_ext = case profiler
               when "vernier" then ".json"
               when "stackprof" then ".dump"
               else ".pb.gz"
               end
  output_path = File.join(__dir__, "output_#{scenario_id}#{output_ext}")

  # Resolve workload script
  workload_script = script_path_for(scenario_file, scenario_id)
  unless File.exist?(workload_script)
    $stderr.puts "Scenario ##{scenario_id}: script not found: #{workload_script}"
    $stderr.puts "Run generate_scenarios.rb first to generate scripts/"
    failures << scenario_id
    next
  end

  ruby_bin = RbConfig.ruby

  # Run baseline (no profiler) if verbose
  if verbose
    bl_stdout, _, bl_status = Open3.capture3(
      ruby_bin, PROFRUN, "-P", "none", workload_script
    )
    if bl_status.success? && bl_stdout =~ /elapsed_ms=([\d.]+)/
      puts format("  baseline (no profiler): %.1fms", $1.to_f)
    end
  end

  # Execute via runner
  stdout, stderr, status = Open3.capture3(
    ruby_bin, PROFRUN,
    "-P", profiler, "-m", profiling_mode.to_s, "-F", frequency.to_s,
    "-o", output_path, workload_script
  )

  unless status.success?
    $stderr.puts "Scenario ##{scenario_id}: script failed: #{stderr}"
    failures << scenario_id
    next
  end

  # Parse stats from stdout
  stats = {}
  stdout.each_line do |line|
    if line.strip =~ /\A(\w+)=([\d.]+)\z/
      stats[$1] = $2
    end
  end

  if verbose
    elapsed = stats["elapsed_ms"]
    puts format("  elapsed: %sms", elapsed) if elapsed
    if stats["sampling_count"]
      sc = stats["sampling_count"].to_i
      st_ns = stats["sampling_time_ns"].to_i
      avg_us = sc > 0 ? st_ns / sc / 1000.0 : 0
      puts format("  sampling: %d calls, %.2fms total, %.1fus/call avg", sc, st_ns / 1_000_000.0, avg_us)
    end
  end

  # Parse results
  actual_ms, raw_out = case profiler
                       when "sperf", "pf2"
                         parse_results_pprof(output_path, pprof_method_re)
                       when "stackprof"
                         parse_results_stackprof(output_path, pprof_method_re)
                       when "vernier"
                         parse_results_vernier(output_path, pprof_method_re)
                       end

  unless actual_ms
    $stderr.puts "Scenario ##{scenario_id}: parse failed: #{raw_out}"
    failures << scenario_id
    File.delete(output_path) if File.exist?(output_path)
    next
  end

  # Compare
  if ratio_mode
    # Convert actual values to ratios
    actual_total = actual_ms.values.select { |v| expected_ratio.key?(actual_ms.key(v)) rescue false }.sum
    actual_total = 0.0
    expected_ratio.each_key { |m| actual_total += (actual_ms[m] || 0.0) }

    errors = []
    expected_ratio.each do |method, exp_r|
      act_r = actual_total > 0 ? (actual_ms[method] || 0.0) / actual_total : 0.0
      error = exp_r > 0 ? ((act_r - exp_r).abs / exp_r) : 0.0
      errors << error
    end
  else
    errors = []
    expected_ms.each do |method, exp|
      act = actual_ms[method] || 0.0
      error = exp > 0 ? ((act - exp).abs / exp) : 0.0
      errors << error
    end
  end

  avg_error = errors.empty? ? 0.0 : errors.sum / errors.size
  all_errors << avg_error
  pass = avg_error <= tolerance

  failures << scenario_id unless pass

  show_detail = !pass || verbose
  label = pass ? "PASS" : "FAIL"
  puts format("--- Scenario #%-4d  %s (avg error: %.1f%%) ---", scenario_id, label, avg_error * 100)

  if show_detail
    if ratio_mode
      actual_total = 0.0
      expected_ratio.each_key { |m| actual_total += (actual_ms[m] || 0.0) }

      expected_ratio.sort_by { |_, v| -v }.each do |method, exp_r|
        act_val = actual_ms[method] || 0.0
        act_r = actual_total > 0 ? act_val / actual_total : 0.0
        err = exp_r > 0 ? ((act_r - exp_r).abs / exp_r * 100) : 0.0
        puts format("  %-20s  expected=%6.2f%%  actual=%6.2f%%  error=%5.1f%%", method, exp_r * 100, act_r * 100, err)
      end
    else
      expected_ms.sort_by { |_, v| -v }.each do |method, exp|
        act = actual_ms[method] || 0.0
        err = exp > 0 ? ((act - exp).abs / exp * 100) : 0.0
        puts format("  %-20s  expected=%7.1fms  actual=%7.1fms  error=%5.1f%%", method, exp, act, err)
      end
    end
    puts
    puts "  raw output:"
    raw_out.to_s.each_line { |l| puts "    #{l}" }
    puts
  end

  # Cleanup profiler output
  File.delete(output_path) if File.exist?(output_path)
end

# Kill load processes
load_pids.each do |pid|
  Process.kill(:TERM, pid) rescue nil
  Process.wait(pid) rescue nil
end

# Summary
puts
puts "=" * 50
overall_avg = all_errors.empty? ? 0.0 : all_errors.sum / all_errors.size
puts format("Scenarios: %d total, %d passed, %d failed",
            selected.size, selected.size - failures.size, failures.size)
puts format("Overall average error: %.1f%%", overall_avg * 100)

unless failures.empty?
  puts "Failed scenarios: #{failures.join(", ")}"
end

tol_pct = (tolerance * 100).to_i
if failures.empty? && overall_avg <= tolerance
  puts "PASS (< #{tol_pct}%)"
else
  puts "FAIL (> #{tol_pct}%)"
  exit 1
end
