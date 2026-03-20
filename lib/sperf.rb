require "sperf.so"
require "zlib"
require "stringio"

module Sperf
  VERSION = "0.1.0"

  @verbose = false
  @output = nil
  @stat = false
  @stat_start_mono = nil
  STAT_TOP_N = 5
  SYNTHETIC_LABELS = %w[[GVL\ blocked] [GVL\ wait] [GC\ marking] [GC\ sweeping]].freeze

  # Starts profiling.
  # format: :pprof, :collapsed, or :text. nil = auto-detect from output extension
  #   .collapsed → collapsed stacks (FlameGraph / speedscope compatible)
  #   .txt       → text report (human/AI readable flat + cumulative table)
  #   otherwise (.pb.gz etc) → pprof protobuf (gzip compressed)
  def self.start(frequency: 1000, mode: :cpu, output: nil, verbose: false, format: nil, stat: false)
    @verbose = verbose || ENV["SPERF_VERBOSE"] == "1"
    @output = output
    @format = format
    @stat = stat
    @stat_start_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC) if @stat
    _c_start(frequency: frequency, mode: mode)

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

    print_stats(data) if @verbose
    print_stat(data) if @stat

    if @output
      fmt = detect_format(@output, @format)
      case fmt
      when :collapsed
        File.write(@output, Collapsed.encode(data))
      when :text
        File.write(@output, Text.encode(data))
      else
        File.binwrite(@output, gzip(PProf.encode(data)))
      end
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
    samples = data[:samples]&.size || 0
    mode = data[:mode] || :cpu
    frequency = data[:frequency] || 0

    total_ms = total_ns / 1_000_000.0
    avg_us = count > 0 ? total_ns / count / 1000.0 : 0.0

    $stderr.puts "[sperf] mode=#{mode} frequency=#{frequency}Hz"
    $stderr.puts "[sperf] sampling: #{count} calls, #{format("%.2f", total_ms)}ms total, #{format("%.1f", avg_us)}us/call avg"
    $stderr.puts "[sperf] samples recorded: #{samples}"

    print_top(data)
  end

  TOP_N = 10

  # Samples from C are now [[path_str, label_str], ...], weight]
  def self.print_top(data)
    samples_raw = data[:samples]
    return if !samples_raw || samples_raw.empty?

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

    return if cum.empty?

    print_top_table("flat", flat, total_weight)
    print_top_table("cum", cum, total_weight)
  end

  def self.print_top_table(kind, table, total_weight)
    top = table.sort_by { |_, w| -w }.first(TOP_N)
    $stderr.puts "[sperf] top #{top.size} by #{kind}:"
    top.each do |key, weight|
      label, path = key
      ms = weight / 1_000_000.0
      pct = total_weight > 0 ? weight * 100.0 / total_weight : 0.0
      loc = path.empty? ? "" : " (#{path})"
      $stderr.puts format("[sperf]   %8.1fms %5.1f%%  %s%s", ms, pct, label, loc)
    end
  end

  def self.print_stat(data)
    samples_raw = data[:samples] || []
    real_ns = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @stat_start_mono) * 1_000_000_000).to_i
    times = Process.times
    user_ns = (times.utime * 1_000_000_000).to_i
    sys_ns = (times.stime * 1_000_000_000).to_i

    command = ENV["SPERF_STAT_COMMAND"] || "(unknown)"

    $stderr.puts
    $stderr.puts " Performance stats for '#{command}':"
    $stderr.puts

    # user / sys / real
    $stderr.puts format("  %14s ms   user", format_ms(user_ns))
    $stderr.puts format("  %14s ms   sys", format_ms(sys_ns))
    $stderr.puts format("  %14s ms   real", format_ms(real_ns))

    # Time breakdown from samples
    if samples_raw.size > 0
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

      $stderr.puts

      [
        [:cpu_execution, "CPU execution"],
        [:gvl_blocked,   "GVL blocked (I/O, sleep)"],
        [:gvl_wait,      "GVL wait (contention)"],
        [:gc_marking,    "GC marking"],
        [:gc_sweeping,   "GC sweeping"],
      ].each do |key, label|
        w = breakdown[key]
        next if w == 0
        pct = total_weight > 0 ? w * 100.0 / total_weight : 0.0
        $stderr.puts format("  %14s ms %5.1f%%   %s", format_ms(w), pct, label)
      end

      # GC statistics (cumulative since process start)
      gc = GC.stat
      $stderr.puts format("  %14s ms           GC time (%s count: %s minor, %s major)",
                          format_ms(gc[:time] * 1_000_000),
                          format_integer(gc[:count]),
                          format_integer(gc[:minor_gc_count]),
                          format_integer(gc[:major_gc_count]))
      $stderr.puts format("  %14s              allocated objects", format_integer(gc[:total_allocated_objects]))
      $stderr.puts format("  %14s              freed objects", format_integer(gc[:total_freed_objects]))

      # Top N by flat
      flat = Hash.new(0)
      samples_raw.each do |frames, weight|
        frames.each_with_index do |frame, i|
          if i == 0
            _, label = frame
            next if SYNTHETIC_LABELS.include?(label)
            flat[[label, frame[0]]] += weight
          end
        end
      end

      unless flat.empty?
        top = flat.sort_by { |_, w| -w }.first(STAT_TOP_N)
        $stderr.puts
        $stderr.puts " Top #{top.size} by flat:"
        top.each do |key, weight|
          label, path = key
          pct = total_weight > 0 ? weight * 100.0 / total_weight : 0.0
          loc = path.empty? ? "" : " (#{path})"
          $stderr.puts format("  %14s ms %5.1f%%   %s%s", format_ms(weight), pct, label, loc)
        end
      end

    end

    # Footer
    if samples_raw.size > 0
      unique_stacks = samples_raw.map { |frames, _| frames }.uniq.size
      overhead_pct = real_ns > 0 ? (data[:sampling_time_ns] || 0) * 100.0 / real_ns : 0.0
      $stderr.puts
      $stderr.puts format("  %d samples (%d unique stacks), %.1f%% profiler overhead",
                          samples_raw.size, unique_stacks, overhead_pct)
    end

    $stderr.puts
  end

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

  # ENV-based auto-start for CLI usage
  if ENV["SPERF_ENABLED"] == "1"
    _sperf_mode_str = ENV["SPERF_MODE"] || "cpu"
    unless %w[cpu wall].include?(_sperf_mode_str)
      raise ArgumentError, "SPERF_MODE must be 'cpu' or 'wall', got: #{_sperf_mode_str.inspect}"
    end
    _sperf_mode = _sperf_mode_str == "wall" ? :wall : :cpu
    _sperf_format = ENV["SPERF_FORMAT"] ? ENV["SPERF_FORMAT"].to_sym : nil
    _sperf_stat = ENV["SPERF_STAT"] == "1"
    start(frequency: (ENV["SPERF_FREQUENCY"] || 1000).to_i, mode: _sperf_mode,
          output: _sperf_stat ? ENV["SPERF_OUTPUT"] : (ENV["SPERF_OUTPUT"] || "sperf.data"),
          verbose: ENV["SPERF_VERBOSE"] == "1",
          format: _sperf_format,
          stat: _sperf_stat)
    at_exit { stop }
  end

  # Text report encoder — human/AI readable flat + cumulative top-N table.
  module Text
    module_function

    def encode(data, top_n: 50)
      samples_raw = data[:samples]
      mode = data[:mode] || :cpu
      frequency = data[:frequency] || 0

      return "No samples recorded.\n" if !samples_raw || samples_raw.empty?

      flat = Hash.new(0)
      cum = Hash.new(0)
      total_weight = 0

      samples_raw.each do |frames, weight|
        total_weight += weight
        seen = {}

        frames.each_with_index do |frame, i|
          path, label = frame
          key = [label, path]
          flat[key] += weight if i == 0

          unless seen[key]
            cum[key] += weight
            seen[key] = true
          end
        end
      end

      out = String.new
      total_ms = total_weight / 1_000_000.0
      out << "Total: #{"%.1f" % total_ms}ms (#{mode})\n"
      out << "Samples: #{samples_raw.size}, Frequency: #{frequency}Hz\n"
      out << "\n"
      out << format_table("Flat", flat, total_weight, top_n)
      out << "\n"
      out << format_table("Cumulative", cum, total_weight, top_n)
      out
    end

    def format_table(title, table, total_weight, top_n)
      sorted = table.sort_by { |_, w| -w }.first(top_n)
      out = String.new
      out << "#{title}:\n"
      sorted.each do |key, weight|
        label, path = key
        ms = weight / 1_000_000.0
        pct = total_weight > 0 ? weight * 100.0 / total_weight : 0.0
        loc = path.empty? ? "" : " (#{path})"
        out << ("  %8.1fms %5.1f%%  %s%s\n" % [ms, pct, label, loc])
      end
      out
    end
  end

  # Collapsed stacks encoder for FlameGraph / speedscope.
  # Output: one line per unique stack, "frame1;frame2;...;leafN weight\n"
  module Collapsed
    module_function

    def encode(data)
      merged = Hash.new(0)
      data[:samples].each do |frames, weight|
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
      samples_raw = data[:samples]
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

      # Convert string frames to index frames and merge identical stacks
      merged = Hash.new(0)
      samples_raw.each do |frames, weight|
        key = frames.map { |path, label| [intern.(path), intern.(label)] }
        merged[key] += weight
      end
      merged = merged.to_a

      # Build location/function tables
      locations, functions = build_tables(merged)

      # Intern type label and unit
      type_label = mode == :wall ? "wall" : "cpu"
      type_idx = intern.(type_label)
      ns_idx = intern.("nanoseconds")

      # Encode Profile message
      buf = "".b

      # field 1: sample_type (repeated ValueType)
      buf << encode_message(1, encode_value_type(type_idx, ns_idx))

      # field 2: sample (repeated Sample)
      merged.each do |frames, weight|
        sample_buf = "".b
        loc_ids = frames.map { |f| locations[f] }
        sample_buf << encode_packed_uint64(1, loc_ids)
        sample_buf << encode_packed_int64(2, [weight])
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

      # field 6: string_table (repeated string)
      string_table.each do |s|
        buf << encode_bytes(6, s.encode("UTF-8"))
      end

      # field 11: period_type (ValueType)
      buf << encode_message(11, encode_value_type(type_idx, ns_idx))

      # field 12: period (int64)
      buf << encode_int64(12, interval_ns)

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
