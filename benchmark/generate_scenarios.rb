#!/usr/bin/env ruby
# frozen_string_literal: true

# Unified scenario generator for sperf accuracy benchmarks.
#
# Usage:
#   ruby generate_scenarios.rb                        # default: mixed, 10 scenarios
#   ruby generate_scenarios.rb -p rw -n 10            # rw only, 10 scenarios
#   ruby generate_scenarios.rb -p cw -n 3             # cw only, 3 scenarios
#   ruby generate_scenarios.rb -p csleep -n 3         # csleep only, 3 scenarios
#   ruby generate_scenarios.rb -p cwait -n 3           # cwait (GVL-free nanosleep) only
#   ruby generate_scenarios.rb -p mixed -n 10         # rw/cw/csleep/cwait mixed
#   ruby generate_scenarios.rb -o scenarios_foo.json  # custom output file
#   ruby generate_scenarios.rb -s 12345               # custom seed

require "json"

METHOD_RANGE = 1..1000
CALLS_RANGE = 50..150
TIME_RANGE_USEC = 10_000..100_000  # 10ms - 100ms

MIXED_PREFIXES = %w[rw cw csleep cwait].freeze

# Parse arguments
args = ARGV.dup
prefix_type = "mixed"
num_scenarios = 10
output_file = nil
seed = 20260320

while (idx = args.index { |a| a.start_with?("-") })
  flag = args.delete_at(idx)
  case flag
  when "-p" then prefix_type = args.delete_at(idx)
  when "-n" then num_scenarios = args.delete_at(idx).to_i
  when "-o" then output_file = args.delete_at(idx)
  when "-s" then seed = args.delete_at(idx).to_i
  else abort "Unknown flag: #{flag}"
  end
end

output_file ||= "scenarios_#{prefix_type}.json"
output_path = File.join(__dir__, output_file)

srand(seed)

RATIO_NUM_METHODS = 10
RATIO_TOTAL_CALLS = 4_000_000

scenarios = num_scenarios.times.map do |i|
  if prefix_type == "ratio"
    # Ratio scenario: 10 random rw methods, 100k total calls with random distribution
    methods = Array.new(RATIO_NUM_METHODS) { "rw#{rand(METHOD_RANGE)}" }.uniq
    # Ensure we have exactly RATIO_NUM_METHODS unique methods
    while methods.size < RATIO_NUM_METHODS
      methods << "rw#{rand(METHOD_RANGE)}"
      methods.uniq!
    end

    # Random weights -> counts that sum to RATIO_TOTAL_CALLS
    weights = methods.map { rand(1..100) }
    total_weight = weights.sum.to_f
    call_counts = {}
    assigned = 0
    methods.each_with_index do |m, j|
      if j == methods.size - 1
        call_counts[m] = RATIO_TOTAL_CALLS - assigned
      else
        c = (weights[j] / total_weight * RATIO_TOTAL_CALLS).round
        call_counts[m] = c
        assigned += c
      end
    end

    total = call_counts.values.sum.to_f
    expected_ratio = {}
    call_counts.each { |m, c| expected_ratio[m] = c / total }

    {
      "id" => i,
      "type" => "ratio",
      "call_counts" => call_counts,
      "expected_ratio" => expected_ratio,
    }
  else
    num_calls = rand(CALLS_RANGE)
    calls = num_calls.times.map do
      prefix = prefix_type == "mixed" ? MIXED_PREFIXES.sample : prefix_type
      method_id = rand(METHOD_RANGE)
      usec = rand(TIME_RANGE_USEC)
      ["#{prefix}#{method_id}", usec]
    end

    # Repeat some calls to test accumulation of same-method samples.
    # Pick ~30% of calls and repeat each 3-10 times.
    repeats = calls.sample([1, (num_calls * 0.3).ceil].max)
    repeats.each do |call|
      rand(3..10).times { calls << call.dup }
    end
    calls.shuffle!

    # CPU mode: rw/cw burn CPU time, csleep does not
    expected_cpu_ms = Hash.new(0.0)
    # Wall mode: all methods contribute their full duration
    expected_wall_ms = Hash.new(0.0)

    calls.each do |name, usec|
      ms = usec / 1000.0
      is_sleep = name.start_with?("csleep") || name.start_with?("cwait")
      expected_cpu_ms[name] += is_sleep ? 0.0 : ms
      expected_wall_ms[name] += ms
    end

    {
      "id" => i,
      "calls" => calls,
      "expected_cpu_ms" => expected_cpu_ms,
      "expected_wall_ms" => expected_wall_ms,
    }
  end
end

File.write(output_path, JSON.pretty_generate(scenarios))
puts "Generated #{scenarios.size} #{prefix_type} scenarios to #{output_file}"

# Generate workload scripts in scripts/
scripts_dir = File.join(__dir__, "scripts")
Dir.mkdir(scripts_dir) unless Dir.exist?(scripts_dir)

scenarios.each do |scenario|
  id = scenario["id"]
  script_name = "#{prefix_type}_#{id}.rb"
  script_path = File.join(scripts_dir, script_name)

  if scenario["type"] == "ratio"
    # Ratio scenario: use send + loop (too many calls to enumerate)
    lines = []
    lines << "srand(#{seed})"
    lines << "call_counts = #{scenario["call_counts"].inspect}"
    lines << "calls = []"
    lines << 'call_counts.each { |name, count| count.times { calls << name } }'
    lines << "calls.shuffle!"
    lines << 'calls.each { |name| SperfWorkload.send(name, 0) }'
    File.write(script_path, lines.join("\n") + "\n")
  else
    # Normal scenario: enumerate method calls directly
    lines = scenario["calls"].map { |name, usec| "SperfWorkload.#{name}(#{usec})" }
    File.write(script_path, lines.join("\n") + "\n")
  end
end

puts "Generated #{scenarios.size} scripts to scripts/"
