require "rperf/version"
require "zlib"
require "stringio"

begin
  # gem install
  require "rperf.so"
rescue LoadError
  # local development
  require 'rbconfig'
  require_relative "../tmp/#{RbConfig::CONFIG['arch']}/rperf/#{RbConfig::CONFIG['RUBY_PROGRAM_VERSION']}/rperf.so"
end

module Rperf

  @verbose = false
  @output = nil
  @stat = false
  @stat_start_mono = nil

  # Starts profiling.
  # format: :pprof, :collapsed, or :text. nil = auto-detect from output extension
  #   .collapsed → collapsed stacks (FlameGraph / speedscope compatible)
  #   .txt       → text report (human/AI readable flat + cumulative table)
  #   otherwise (.pb.gz etc) → pprof protobuf (gzip compressed)
  def self.start(frequency: 1000, mode: :cpu, output: nil, verbose: false, format: nil, stat: false, signal: nil, aggregate: true)
    raise ArgumentError, "frequency must be a positive integer (got #{frequency.inspect})" unless frequency.is_a?(Integer) && frequency > 0
    raise ArgumentError, "frequency must be <= 10000 (10KHz), got #{frequency}" if frequency > 10_000
    raise ArgumentError, "mode must be :cpu or :wall, got #{mode.inspect}" unless %i[cpu wall].include?(mode)
    c_mode = mode == :cpu ? 0 : 1
    c_signal = signal.nil? ? -1 : (signal ? signal.to_i : 0)
    if c_signal > 0
      uncatchable = [Signal.list["KILL"], Signal.list["STOP"]].compact
      if uncatchable.include?(c_signal)
        name = Signal.signame(c_signal) rescue c_signal.to_s
        raise ArgumentError, "signal #{c_signal} (#{name}) cannot be caught; use a different signal"
      end
    end
    @verbose = verbose || ENV["RPERF_VERBOSE"] == "1"
    @output = output
    @format = format
    @stat = stat
    @stat_start_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC) if @stat
    _c_start(frequency, c_mode, aggregate, c_signal)

    if block_given?
      begin
        yield
      ensure
        return stop
      end
    end
  end

  def self.stop
    data = _c_stop
    return unless data

    # When aggregate: false, C extension returns :raw_samples but not
    # :aggregated_samples.  Build aggregated view so encoders always work.
    if data[:raw_samples] && !data[:aggregated_samples]
      merged = {}
      data[:raw_samples].each do |frames, weight, thread_seq|
        key = [frames, thread_seq || 0]
        if merged.key?(key)
          merged[key] += weight
        else
          merged[key] = weight
        end
      end
      data[:aggregated_samples] = merged.map { |(frames, ts), w| [frames, w, ts] }
    end

    print_stats(data) if @verbose
    print_stat(data) if @stat

    if @output
      write_data(@output, data, @format)
      @output = nil
      @format = nil
    end

    data
  end

  # Saves profiling data to a file.
  # format: :pprof, :collapsed, or :text. nil = auto-detect from path extension
  #   .collapsed → collapsed stacks (FlameGraph / speedscope compatible)
  #   .txt       → text report (human/AI readable flat + cumulative table)
  #   otherwise (.pb.gz etc) → pprof protobuf (gzip compressed)
  def self.save(path, data, format: nil)
    write_data(path, data, format)
  end

  def self.write_data(path, data, format)
    fmt = detect_format(path, format)
    case fmt
    when :collapsed
      File.write(path, Collapsed.encode(data))
    when :text
      File.write(path, Text.encode(data))
    else
      File.binwrite(path, gzip(PProf.encode(data)))
    end
  end
  private_class_method :write_data

  def self.detect_format(path, format)
    return format.to_sym if format
    case path.to_s
    when /\.collapsed\z/ then :collapsed
    when /\.txt\z/       then :text
    else :pprof
    end
  end
  private_class_method :detect_format

  def self.gzip(data)
    io = StringIO.new
    io.set_encoding("ASCII-8BIT")
    gz = Zlib::GzipWriter.new(io)
    gz.write(data)
    gz.close
    io.string
  end

  def self.print_stats(data)
    count = data[:sampling_count] || 0
    total_ns = data[:sampling_time_ns] || 0
    sample_count = data[:sampling_count] || 0
    mode = data[:mode] || :cpu
    frequency = data[:frequency] || 0

    total_ms = total_ns / 1_000_000.0
    avg_us = count > 0 ? total_ns / count / 1000.0 : 0.0

    $stderr.puts "[rperf] mode=#{mode} frequency=#{frequency}Hz"
    $stderr.puts "[rperf] sampling: #{count} calls, #{format("%.2f", total_ms)}ms total, #{format("%.1f", avg_us)}us/call avg"
    $stderr.puts "[rperf] samples recorded: #{sample_count}"

    print_top(data)
  end

  TOP_N = 10

  # Compute flat and cumulative weight tables from raw samples.
  # Returns { flat: Hash, cum: Hash, total_weight: Integer }
  def self.compute_flat_cum(samples_raw)
    flat = Hash.new(0)
    cum = Hash.new(0)
    total_weight = 0

    samples_raw.each do |frames, weight|
      total_weight += weight
      seen = {}

      frames.each_with_index do |frame, i|
        path, label = frame
        key = [label, path]

        flat[key] += weight if i == 0  # leaf = first element (deepest frame)

        unless seen[key]
          cum[key] += weight
          seen[key] = true
        end
      end
    end

    { flat: flat, cum: cum, total_weight: total_weight }
  end
  private_class_method :compute_flat_cum

  # Samples from C are now [[path_str, label_str], ...], weight]
  def self.print_top(data)
    samples_raw = data[:aggregated_samples]
    return if !samples_raw || samples_raw.empty?

    result = compute_flat_cum(samples_raw)
    return if result[:cum].empty?

    print_top_table("flat", result[:flat], result[:total_weight])
    print_top_table("cum", result[:cum], result[:total_weight])
  end

  def self.print_top_table(kind, table, total_weight)
    top = table.sort_by { |_, w| -w }.first(TOP_N)
    $stderr.puts "[rperf] top #{top.size} by #{kind}:"
    top.each do |key, weight|
      label, path = key
      ms = weight / 1_000_000.0
      pct = total_weight > 0 ? weight * 100.0 / total_weight : 0.0
      loc = path.empty? ? "" : " (#{path})"
      $stderr.puts format("[rperf]   %8.1fms %5.1f%%  %s%s", ms, pct, label, loc)
    end
  end

  # Column formatters for stat output
  STAT_PCT_LINE  = ->(val, unit, pct, label) {
    format("  %14s %-2s %5.1f%%  %s", val, unit, pct, label)
  }
  STAT_LINE = ->(val, unit, label) {
    format("  %14s %-2s         %s", val, unit, label)
  }
  private_constant :STAT_PCT_LINE, :STAT_LINE

  def self.print_stat(data)
    samples_raw = data[:aggregated_samples] || []
    real_ns = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @stat_start_mono) * 1_000_000_000).to_i
    times = Process.times
    user_ns = (times.utime * 1_000_000_000).to_i
    sys_ns = (times.stime * 1_000_000_000).to_i

    command = ENV["RPERF_STAT_COMMAND"] || "(unknown)"

    $stderr.puts
    $stderr.puts " Performance stats for '#{command}':"
    $stderr.puts
    $stderr.puts format("  %14s ms   user", format_ms(user_ns))
    $stderr.puts format("  %14s ms   sys", format_ms(sys_ns))
    $stderr.puts format("  %14s ms   real", format_ms(real_ns))

    if samples_raw.size > 0
      breakdown, total_weight = compute_stat_breakdown(samples_raw)
      print_stat_breakdown(breakdown, total_weight)
      print_stat_runtime_info(data)
      print_stat_system_info
      print_stat_report(data) if ENV["RPERF_STAT_REPORT"] == "1"
      print_stat_footer(samples_raw, real_ns, data)
    end

    $stderr.puts
  end

  def self.compute_stat_breakdown(samples_raw)
    breakdown = Hash.new(0)
    total_weight = 0

    samples_raw.each do |frames, weight|
      total_weight += weight
      leaf_label = frames.first&.last || ""
      category = case leaf_label
                 when "[GVL blocked]" then :gvl_blocked
                 when "[GVL wait]"    then :gvl_wait
                 when "[GC marking]"  then :gc_marking
                 when "[GC sweeping]" then :gc_sweeping
                 else :cpu_execution
                 end
      breakdown[category] += weight
    end

    [breakdown, total_weight]
  end
  private_class_method :compute_stat_breakdown

  def self.print_stat_breakdown(breakdown, total_weight)
    $stderr.puts

    [
      [:cpu_execution, "CPU execution"],
      [:gvl_blocked,   "[Ruby] GVL blocked (I/O, sleep)"],
      [:gvl_wait,      "[Ruby] GVL wait (contention)"],
      [:gc_marking,    "[Ruby] GC marking"],
      [:gc_sweeping,   "[Ruby] GC sweeping"],
    ].each do |key, label|
      w = breakdown[key]
      next if w == 0
      pct = total_weight > 0 ? w * 100.0 / total_weight : 0.0
      $stderr.puts STAT_PCT_LINE.call(format_ms(w), "ms", pct, label)
    end
  end
  private_class_method :print_stat_breakdown

  def self.print_stat_runtime_info(data)
    thread_count = data[:detected_thread_count] || 0
    $stderr.puts STAT_LINE.call(format_integer(thread_count), "  ", "[Ruby] detected threads") if thread_count > 0
    gc = GC.stat
    $stderr.puts STAT_LINE.call(format_ms(gc[:time] * 1_000_000), "ms",
                                "[Ruby] GC time (%s count: %s minor, %s major)" % [
                                  format_integer(gc[:count]),
                                  format_integer(gc[:minor_gc_count]),
                                  format_integer(gc[:major_gc_count])])
    $stderr.puts STAT_LINE.call(format_integer(gc[:total_allocated_objects]), "  ", "[Ruby] allocated objects")
    $stderr.puts STAT_LINE.call(format_integer(gc[:total_freed_objects]), "  ", "[Ruby] freed objects")
    if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
      yjit = RubyVM::YJIT.runtime_stats
      if yjit[:ratio_in_yjit]
        $stderr.puts STAT_LINE.call(format("%.1f%%", yjit[:ratio_in_yjit] * 100), "  ", "[Ruby] YJIT code execution ratio")
      end
    end
  end
  private_class_method :print_stat_runtime_info

  def self.print_stat_system_info
    sys_stats = get_system_stats
    maxrss_kb = sys_stats[:maxrss_kb]
    if maxrss_kb
      $stderr.puts STAT_LINE.call(format_integer((maxrss_kb / 1024.0).round), "MB", "[OS] peak memory (maxrss)")
    end
    if sys_stats[:ctx_voluntary]
      $stderr.puts STAT_LINE.call(
        format_integer(sys_stats[:ctx_voluntary] + sys_stats[:ctx_involuntary]), "  ",
        "[OS] context switches (%s voluntary, %s involuntary)" % [
          format_integer(sys_stats[:ctx_voluntary]),
          format_integer(sys_stats[:ctx_involuntary])])
    end
    if sys_stats[:io_read_bytes]
      r = sys_stats[:io_read_bytes]
      w = sys_stats[:io_write_bytes]
      $stderr.puts STAT_LINE.call(
        format_integer(((r + w) / 1024.0 / 1024.0).round), "MB",
        "[OS] disk I/O (%s MB read, %s MB write)" % [
          format_integer((r / 1024.0 / 1024.0).round),
          format_integer((w / 1024.0 / 1024.0).round)])
    end
  end
  private_class_method :print_stat_system_info


  def self.print_stat_report(data)
    $stderr.puts
    $stderr.puts Text.encode(data, header: false)
  end
  private_class_method :print_stat_report

  def self.print_stat_footer(samples_raw, real_ns, data)
    triggers = data[:trigger_count] || 0
    overhead_pct = real_ns > 0 ? (data[:sampling_time_ns] || 0) * 100.0 / real_ns : 0.0
    $stderr.puts
    samples = data[:sampling_count] || samples_raw.size
    $stderr.puts format("  %d samples / %d triggers, %.1f%% profiler overhead",
                        samples, triggers, overhead_pct)
  end
  private_class_method :print_stat_footer

  def self.format_integer(n)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end
  private_class_method :format_integer

  # Format nanoseconds as ms with 1 decimal place and comma-separated integer part.
  # Example: 5_609_200_000 → "5,609.2"
  def self.format_ms(ns)
    ms = ns / 1_000_000.0
    int_part = ms.truncate
    frac = format(".%d", ((ms - int_part).abs * 10).round % 10)
    int_str = int_part.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    "#{int_str}#{frac}"
  end
  private_class_method :format_ms

  # Collect system-level stats. Returns a hash; missing keys are omitted.
  def self.get_system_stats
    stats = {}

    if File.readable?("/proc/self/status")
      # Linux: parse /proc/self/status
      File.read("/proc/self/status").each_line do |line|
        case line
        when /\AVmHWM:\s+(\d+)\s+kB/
          stats[:maxrss_kb] = $1.to_i
        when /\Avoluntary_ctxt_switches:\s+(\d+)/
          stats[:ctx_voluntary] = $1.to_i
        when /\Anonvoluntary_ctxt_switches:\s+(\d+)/
          stats[:ctx_involuntary] = $1.to_i
        end
      end
    else
      # macOS/BSD: ps reports RSS in KB
      rss = `ps -o rss= -p #{$$}`.strip.to_i rescue nil
      stats[:maxrss_kb] = rss if rss && rss > 0
    end

    if File.readable?("/proc/self/io")
      # Linux: parse /proc/self/io
      File.read("/proc/self/io").each_line do |line|
        case line
        when /\Aread_bytes:\s+(\d+)/
          stats[:io_read_bytes] = $1.to_i
        when /\Awrite_bytes:\s+(\d+)/
          stats[:io_write_bytes] = $1.to_i
        end
      end
    end

    stats
  end
  private_class_method :get_system_stats

  # ENV-based auto-start for CLI usage
  if ENV["RPERF_ENABLED"] == "1"
    _rperf_mode_str = ENV["RPERF_MODE"] || "cpu"
    unless %w[cpu wall].include?(_rperf_mode_str)
      raise ArgumentError, "RPERF_MODE must be 'cpu' or 'wall', got: #{_rperf_mode_str.inspect}"
    end
    _rperf_mode = _rperf_mode_str == "wall" ? :wall : :cpu
    _rperf_format = ENV["RPERF_FORMAT"] ? ENV["RPERF_FORMAT"].to_sym : nil
    _rperf_stat = ENV["RPERF_STAT"] == "1"
    _rperf_signal = case ENV["RPERF_SIGNAL"]
                    when nil then nil
                    when "false" then false
                    else ENV["RPERF_SIGNAL"].to_i
                    end
    _rperf_aggregate = ENV["RPERF_AGGREGATE"] != "0"
    _rperf_start_opts = { frequency: (ENV["RPERF_FREQUENCY"] || 1000).to_i, mode: _rperf_mode,
                          output: _rperf_stat ? ENV["RPERF_OUTPUT"] : (ENV["RPERF_OUTPUT"] || "rperf.data"),
                          verbose: ENV["RPERF_VERBOSE"] == "1",
                          format: _rperf_format,
                          stat: _rperf_stat,
                          aggregate: _rperf_aggregate }
    _rperf_start_opts[:signal] = _rperf_signal unless _rperf_signal.nil?
    start(**_rperf_start_opts)
    at_exit { stop }
  end

  # Text report encoder — human/AI readable flat + cumulative top-N table.
  module Text
    module_function

    def encode(data, top_n: 50, header: true)
      samples_raw = data[:aggregated_samples]
      mode = data[:mode] || :cpu
      frequency = data[:frequency] || 0

      return "No samples recorded.\n" if !samples_raw || samples_raw.empty?

      result = Rperf.send(:compute_flat_cum, samples_raw)

      out = String.new
      if header
        total_ms = result[:total_weight] / 1_000_000.0
        out << "Total: #{"%.1f" % total_ms}ms (#{mode})\n"
        sample_count = data[:sampling_count] || samples_raw.size
        out << "Samples: #{sample_count}, Frequency: #{frequency}Hz\n"
        out << "\n"
      end
      out << format_table("Flat", result[:flat], result[:total_weight], top_n)
      out << "\n"
      out << format_table("Cumulative", result[:cum], result[:total_weight], top_n)
      out
    end

    def format_table(title, table, total_weight, top_n)
      sorted = table.sort_by { |_, w| -w }.first(top_n)
      out = String.new
      out << " #{title}:\n"
      sorted.each do |key, weight|
        label, path = key
        pct = total_weight > 0 ? weight * 100.0 / total_weight : 0.0
        loc = path.empty? ? "" : " (#{path})"
        out << format("  %14s ms %5.1f%%  %s%s\n", Rperf.send(:format_ms, weight), pct, label, loc)
      end
      out
    end
  end

  # Collapsed stacks encoder for FlameGraph / speedscope.
  # Output: one line per unique stack, "frame1;frame2;...;leafN weight\n"
  module Collapsed
    module_function

    def encode(data)
      samples = data[:aggregated_samples]
      return "" if !samples || samples.empty?
      merged = Hash.new(0)
      samples.each do |frames, weight|
        key = frames.reverse.map { |_, label| label }.join(";")
        merged[key] += weight
      end
      merged.map { |stack, weight| "#{stack} #{weight}" }.join("\n") + "\n"
    end
  end

  # Hand-written protobuf encoder for pprof profile format.
  # Only runs once at stop time, so performance is not critical.
  #
  # Samples from C are: [[[path_str, label_str], ...], weight]
  # This encoder builds its own string table for pprof output.
  module PProf
    module_function

    def encode(data)
      samples_raw = data[:aggregated_samples]
      frequency = data[:frequency]
      interval_ns = 1_000_000_000 / frequency
      mode = data[:mode] || :cpu

      # Build string table: index 0 must be ""
      string_table = [""]
      string_index = { "" => 0 }

      intern = ->(s) {
        string_index[s] ||= begin
          idx = string_table.size
          string_table << s
          idx
        end
      }

      # Convert string frames to index frames and merge identical stacks per thread
      merged = Hash.new(0)
      thread_seq_key = intern.("thread_seq")
      samples_raw.each do |frames, weight, thread_seq|
        key = [frames.map { |path, label| [intern.(path), intern.(label)] }, thread_seq || 0]
        merged[key] += weight
      end
      merged = merged.to_a

      # Build location/function tables
      locations, functions = build_tables(merged.map { |(frames, _), w| [frames, w] })

      # Intern type label and unit
      type_label = mode == :wall ? "wall" : "cpu"
      type_idx = intern.(type_label)
      ns_idx = intern.("nanoseconds")

      # Encode Profile message
      buf = "".b

      # field 1: sample_type (repeated ValueType)
      buf << encode_message(1, encode_value_type(type_idx, ns_idx))

      # field 2: sample (repeated Sample) with thread_seq label
      merged.each do |(frames, thread_seq), weight|
        sample_buf = "".b
        loc_ids = frames.map { |f| locations[f] }
        sample_buf << encode_packed_uint64(1, loc_ids)
        sample_buf << encode_packed_int64(2, [weight])
        if thread_seq && thread_seq > 0
          label_buf = "".b
          label_buf << encode_int64(1, thread_seq_key)  # key
          label_buf << encode_int64(3, thread_seq)       # num
          sample_buf << encode_message(3, label_buf)
        end
        buf << encode_message(2, sample_buf)
      end

      # field 4: location (repeated Location)
      locations.each do |frame, loc_id|
        loc_buf = "".b
        loc_buf << encode_uint64(1, loc_id)
        line_buf = "".b
        func_id = functions[frame]
        line_buf << encode_uint64(1, func_id)
        loc_buf << encode_message(4, line_buf)
        buf << encode_message(4, loc_buf)
      end

      # field 5: function (repeated Function)
      functions.each do |frame, func_id|
        func_buf = "".b
        func_buf << encode_uint64(1, func_id)
        func_buf << encode_int64(2, frame[1])    # name (label_idx)
        func_buf << encode_int64(4, frame[0])    # filename (path_idx)
        buf << encode_message(5, func_buf)
      end

      # Intern comment and doc_url strings before encoding string_table
      comment_indices = [
        intern.("rperf #{Rperf::VERSION}"),
        intern.("mode: #{mode}"),
        intern.("frequency: #{frequency}Hz"),
        intern.("ruby: #{RUBY_DESCRIPTION}"),
      ]
      doc_url_idx = intern.("https://ko1.github.io/rperf/help.html")

      # field 6: string_table (repeated string)
      string_table.each do |s|
        buf << encode_bytes(6, s.encode("UTF-8", invalid: :replace, undef: :replace))
      end

      # field 9: time_nanos (int64)
      if data[:start_time_ns]
        buf << encode_int64(9, data[:start_time_ns])
      end

      # field 10: duration_nanos (int64)
      if data[:duration_ns]
        buf << encode_int64(10, data[:duration_ns])
      end

      # field 11: period_type (ValueType)
      buf << encode_message(11, encode_value_type(type_idx, ns_idx))

      # field 12: period (int64)
      buf << encode_int64(12, interval_ns)

      # field 13: comment (repeated int64 = string_table index)
      comment_indices.each { |idx| buf << encode_int64(13, idx) }

      # field 15: doc_url (int64 = string_table index)
      buf << encode_int64(15, doc_url_idx)

      buf
    end

    def build_tables(merged)
      locations = {}
      functions = {}
      next_id = 1

      merged.each do |frames, _weight|
        frames.each do |frame|
          unless locations.key?(frame)
            locations[frame] = next_id
            functions[frame] = next_id
            next_id += 1
          end
        end
      end

      [locations, functions]
    end

    # --- Protobuf encoding helpers ---

    def encode_varint(value)
      value = value & 0xFFFFFFFF_FFFFFFFF if value < 0
      buf = "".b
      loop do
        byte = value & 0x7F
        value >>= 7
        if value > 0
          buf << (byte | 0x80).chr
        else
          buf << byte.chr
          break
        end
      end
      buf
    end

    def encode_uint64(field, value)
      encode_varint((field << 3) | 0) + encode_varint(value)
    end

    def encode_int64(field, value)
      encode_varint((field << 3) | 0) + encode_varint(value < 0 ? value + (1 << 64) : value)
    end

    def encode_bytes(field, data)
      data = data.b if data.respond_to?(:b)
      encode_varint((field << 3) | 2) + encode_varint(data.bytesize) + data
    end

    def encode_message(field, data)
      encode_bytes(field, data)
    end

    def encode_value_type(type_idx, unit_idx)
      encode_int64(1, type_idx) + encode_int64(2, unit_idx)
    end

    def encode_packed_uint64(field, values)
      inner = values.map { |v| encode_varint(v) }.join
      encode_bytes(field, inner)
    end

    def encode_packed_int64(field, values)
      inner = values.map { |v| encode_varint(v < 0 ? v + (1 << 64) : v) }.join
      encode_bytes(field, inner)
    end
  end
end
