#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-run overhead comparison benchmarks.
# Interleaves configs within each round so all configs experience
# similar system conditions. Saves raw data to data/overhead_raw.tsv.

ITERATIONS = Integer(ENV.fetch("ITERATIONS", "10"))
FREQUENCY = 1000
SCRIPT = File.join(__dir__, "scripts", "ratio_1.rb")
OUTPUT_DIR = File.join(__dir__, "data")
RAW_FILE = File.join(OUTPUT_DIR, "overhead_raw.tsv")
TMP_OUT = File.join(__dir__, "tmp", "overhead_out")

CONFIGS = [
  { profiler: "none",     mode: "wall" },
  { profiler: "rperf",    mode: "cpu"  },
  { profiler: "rperf",    mode: "wall" },
  { profiler: "stackprof", mode: "cpu"  },
  { profiler: "stackprof", mode: "wall" },
  { profiler: "vernier",  mode: "wall" },
  { profiler: "pf2",      mode: "cpu"  },
  { profiler: "pf2",      mode: "wall" },
]

Dir.mkdir(OUTPUT_DIR) unless Dir.exist?(OUTPUT_DIR)
Dir.mkdir(File.dirname(TMP_OUT)) unless Dir.exist?(File.dirname(TMP_OUT))

profrun = File.join(__dir__, "profrun.rb")

File.open(RAW_FILE, "w") do |f|
  f.puts "profiler\tmode\titeration\telapsed_ms\tsampling_count\tsampling_time_ns"

  ITERATIONS.times do |i|
    $stderr.puts "=== Round #{i + 1}/#{ITERATIONS} ==="

    CONFIGS.each do |cfg|
      prof = cfg[:profiler]
      mode = cfg[:mode]

      args = ["ruby", profrun, "-P", prof, "-m", mode, "-F", FREQUENCY.to_s]
      args += ["-o", TMP_OUT] unless prof == "none"
      args << SCRIPT

      output = IO.popen(args, err: [:child, :out], &:read)
      status = $?

      elapsed = nil
      sampling_count = nil
      sampling_time_ns = nil

      output.each_line do |line|
        case line.strip
        when /\Aelapsed_ms=(.+)/
          elapsed = $1
        when /\Asampling_count=(.+)/
          sampling_count = $1
        when /\Asampling_time_ns=(.+)/
          sampling_time_ns = $1
        end
      end

      unless status.success?
        $stderr.puts "  #{prof} #{mode}: FAILED (exit #{status.exitstatus})"
        f.puts "#{prof}\t#{mode}\t#{i+1}\tFAILED\t\t"
        next
      end

      $stderr.puts "  #{prof} #{mode}: #{elapsed}ms"
      f.puts "#{prof}\t#{mode}\t#{i+1}\t#{elapsed}\t#{sampling_count}\t#{sampling_time_ns}"
    end
  end
end

$stderr.puts "\nRaw data saved to #{RAW_FILE}"

# Print summary (median)
$stderr.puts "\n=== Summary (median of #{ITERATIONS} runs) ==="
$stderr.puts "%-12s %-5s %10s %15s %18s" % ["Profiler", "Mode", "Elapsed", "SamplingCount", "SamplingTimeNs"]

CONFIGS.each do |cfg|
  prof = cfg[:profiler]
  mode = cfg[:mode]

  values = []
  counts = []
  times = []

  File.readlines(RAW_FILE).each do |line|
    cols = line.strip.split("\t")
    next unless cols[0] == prof && cols[1] == mode && cols[3] != "FAILED" && cols[3] != "elapsed_ms"
    values << cols[3].to_f
    counts << cols[4].to_f if cols[4] && !cols[4].empty?
    times << cols[5].to_f if cols[5] && !cols[5].empty?
  end

  next if values.empty?
  median = values.sort[values.size / 2]
  median_count = counts.empty? ? "-" : counts.sort[counts.size / 2].to_i.to_s
  median_time = times.empty? ? "-" : times.sort[times.size / 2].to_i.to_s

  $stderr.puts "%-12s %-5s %10.1fms %15s %18s" % [prof, mode, median, median_count, median_time]
end
