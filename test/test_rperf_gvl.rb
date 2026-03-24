require_relative "test_helper"

class TestRperfGvl < Test::Unit::TestCase
  include RperfTestHelper

  def test_gvl_blocked_frames_wall_mode
    Rperf.start(frequency: 100, mode: :wall)

    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    labels = data[:aggregated_samples].flat_map { |frames, _| frames.map { |_, label| label } }
    has_blocked = labels.include?("[GVL blocked]")
    has_wait = labels.include?("[GVL wait]")

    assert has_blocked || has_wait,
      "Wall mode with sleep should produce [GVL blocked] or [GVL wait] samples"
  end

  def test_gvl_events_cpu_mode_no_synthetic
    Rperf.start(frequency: 100, mode: :cpu)

    threads = 4.times.map do
      Thread.new { 20.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    labels = data[:aggregated_samples].flat_map { |frames, _| frames.map { |_, label| label } }
    refute labels.include?("[GVL blocked]"),
      "CPU mode should NOT produce [GVL blocked] samples"
    refute labels.include?("[GVL wait]"),
      "CPU mode should NOT produce [GVL wait] samples"
  end

  def test_gvl_wait_weight_positive
    Rperf.start(frequency: 100, mode: :wall)

    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.001 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    gvl_samples = data[:aggregated_samples].select { |frames, _|
      frames.any? { |_, label| label == "[GVL blocked]" || label == "[GVL wait]" }
    }

    gvl_samples.each do |_, weight|
      assert_operator weight, :>, 0, "GVL sample weight should be positive"
    end
  end
end
