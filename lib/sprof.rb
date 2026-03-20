require "sprof.so"
require "zlib"
require "stringio"

module Sprof
  VERSION = "0.1.0"

  @verbose = false
  @output = nil

  def self.start(frequency: 100, mode: :cpu, output: nil, verbose: false)
    @verbose = verbose || ENV["SPROF_VERBOSE"] == "1"
    @output = output
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

    if @output
      encoded = PProf.encode(data)
      File.binwrite(@output, gzip(encoded))
      @output = nil
    end

    data
  end

  def self.save(path, data)
    encoded = PProf.encode(data)
    File.binwrite(path, gzip(encoded))
  end

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

    $stderr.puts "[sprof] mode=#{mode} frequency=#{frequency}Hz"
    $stderr.puts "[sprof] sampling: #{count} calls, #{format("%.2f", total_ms)}ms total, #{format("%.1f", avg_us)}us/call avg"
    $stderr.puts "[sprof] samples recorded: #{samples}"

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
    $stderr.puts "[sprof] top #{top.size} by #{kind}:"
    top.each do |key, weight|
      label, path = key
      ms = weight / 1_000_000.0
      pct = total_weight > 0 ? weight * 100.0 / total_weight : 0.0
      loc = path.empty? ? "" : " (#{path})"
      $stderr.puts format("[sprof]   %8.1fms %5.1f%%  %s%s", ms, pct, label, loc)
    end
  end

  # ENV-based auto-start for CLI usage
  if ENV["SPROF_ENABLED"] == "1"
    _sprof_mode_str = ENV["SPROF_MODE"] || "cpu"
    unless %w[cpu wall].include?(_sprof_mode_str)
      raise ArgumentError, "SPROF_MODE must be 'cpu' or 'wall', got: #{_sprof_mode_str.inspect}"
    end
    _sprof_mode = _sprof_mode_str == "wall" ? :wall : :cpu
    start(frequency: (ENV["SPROF_FREQUENCY"] || 100).to_i, mode: _sprof_mode,
          output: ENV["SPROF_OUTPUT"] || "sprof.data",
          verbose: ENV["SPROF_VERBOSE"] == "1")
    at_exit { stop }
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
