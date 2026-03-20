#!/usr/bin/env ruby
# frozen_string_literal: true

# Profiler runner for sperf accuracy benchmarks.
#
# Runs a workload script under a specified profiler and outputs stats to stdout.
#
# Usage:
#   ruby profrun.rb [options] SCRIPT
#
# Options:
#   -P, --profiler NAME    sperf, stackprof, vernier, pf2, none (default: sperf)
#   -m, --mode MODE        cpu or wall (default: cpu)
#   -F, --frequency HZ     Sampling frequency (default: 1000)
#   -o, --output FILE      Profiler output file path (required for profilers that produce output)

require "optparse"

profiler = "sperf"
mode = :cpu
frequency = 1000
output_path = nil

parser = OptionParser.new do |opts|
  opts.banner = "Usage: profrun.rb [options] SCRIPT"
  opts.on("-P", "--profiler NAME", "Profiler: sperf, stackprof, vernier, pf2, none (default: sperf)") { |v| profiler = v }
  opts.on("-m", "--mode MODE", "Profiling mode: cpu or wall (default: cpu)") { |v| mode = v.to_sym }
  opts.on("-F", "--frequency HZ", Integer, "Sampling frequency in Hz (default: 1000)") { |v| frequency = v }
  opts.on("-o", "--output FILE", "Profiler output file path") { |v| output_path = v }
end
parser.parse!(ARGV)

script = ARGV.shift
abort "#{parser.help}\nError: SCRIPT argument is required" unless script
abort "Script not found: #{script}" unless File.exist?(script)

# Setup load path
$LOAD_PATH.unshift(File.join(__dir__, "..", "lib"))
$LOAD_PATH.unshift(File.join(__dir__, "lib"))

# Require workload methods
require "sperf_workload_methods"

# Start profiler
case profiler
when "sperf"
  require "sperf"
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Sperf.start(frequency: frequency, mode: mode)
when "stackprof"
  require "stackprof"
  sp_mode = mode == :wall ? :wall : :cpu
  interval_us = 1_000_000 / frequency
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  StackProf.start(mode: sp_mode, interval: interval_us, raw: true)
when "vernier"
  require "vernier"
  vn_mode = mode == :wall ? :wall : :retained
  interval_us = 1_000_000 / frequency
  # Vernier uses trace with a block; we'll use start/stop
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Vernier.start_profile(mode: vn_mode, interval: interval_us)
when "pf2"
  require "pf2"
  pf2_time_mode = mode == :wall ? :wall : :cpu
  pf2_interval_ms = [1, 1000 / frequency].max
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Pf2.profile(out: output_path, format: :pprof, time_mode: pf2_time_mode, interval_ms: pf2_interval_ms) do
    load script
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  puts "elapsed_ms=#{(elapsed * 1000).round(1)}"
when "none"
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
else
  abort "Unknown profiler: #{profiler}"
end

# Run workload (pf2 already ran it inside the block)
load script unless profiler == "pf2"

# Stop profiler and save output
case profiler
when "sperf"
  data = Sperf.stop
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  puts "elapsed_ms=#{(elapsed * 1000).round(1)}"
  puts "sampling_count=#{data[:sampling_count]}"
  puts "sampling_time_ns=#{data[:sampling_time_ns]}"
  if output_path
    encoded = Sperf::PProf.encode(data)
    File.binwrite(output_path, Sperf.gzip(encoded))
  end
when "stackprof"
  result = StackProf.stop
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  puts "elapsed_ms=#{(elapsed * 1000).round(1)}"
  if output_path
    results = StackProf.results
    File.binwrite(output_path, Marshal.dump(results))
  end
when "vernier"
  result = Vernier.stop_profile
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  puts "elapsed_ms=#{(elapsed * 1000).round(1)}"
  if output_path
    result.write(out: output_path)
  end
when "pf2"
  # already handled in the block above
when "none"
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  puts "elapsed_ms=#{(elapsed * 1000).round(1)}"
end
