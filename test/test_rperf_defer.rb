require_relative "test_helper"

class TestRperfDefer < Test::Unit::TestCase
  include RperfTestHelper

  def test_defer_no_samples
    Rperf.start(frequency: 1000, defer: true)
    5_000_000.times { 1 + 1 }
    data = Rperf.stop

    assert_kind_of Hash, data
    # With defer and no profile block, timer never fires
    assert_equal 0, data[:aggregated_samples].size,
      "Should have no samples when deferred and no profile block used"
    assert_equal 0, data[:trigger_count],
      "Timer should never have fired"
  end

  def test_defer_profile_collects_samples
    Rperf.start(frequency: 1000, defer: true)

    Rperf.profile do
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    assert_operator data[:aggregated_samples].size, :>, 0,
      "Should have samples inside profile block"
    assert_operator data[:trigger_count], :>, 0,
      "Timer should have fired during profile block"
  end

  def test_defer_pauses_after_profile
    Rperf.start(frequency: 1000, defer: true)

    Rperf.profile do
      5_000_000.times { 1 + 1 }
    end

    # Take snapshot to capture trigger_count after profile block
    snap = Rperf.snapshot
    triggers_after_profile = snap[:trigger_count]

    # Do more work outside profile block
    5_000_000.times { 1 + 1 }

    data = Rperf.stop
    # trigger_count should not have increased after profile block exited
    assert_equal triggers_after_profile, data[:trigger_count],
      "Timer should not fire after profile block exits"
  end

  def test_nested_profile
    Rperf.start(frequency: 1000, defer: true)

    Rperf.profile do
      Rperf.profile do
        5_000_000.times { 1 + 1 }
      end
      # Timer should still be active here (refcount = 1)
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    assert_operator data[:aggregated_samples].size, :>, 0,
      "Nested profile should collect samples"
  end

  def test_profile_with_labels
    Rperf.start(frequency: 1000, defer: true)

    Rperf.profile(endpoint: "/users") do
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    assert_not_nil data[:label_sets]
    labeled = data[:aggregated_samples].select { |_, _, _, lsi| lsi && lsi > 0 }
    assert_operator labeled.size, :>, 0, "Should have labeled samples"
  end

  def test_profile_restores_labels
    Rperf.start(frequency: 1000, defer: true)

    Rperf.label(outer: "yes")
    Rperf.profile(inner: "yes") do
      assert_equal({ outer: "yes", inner: "yes" }, Rperf.labels)
    end
    assert_equal({ outer: "yes" }, Rperf.labels)
  end

  def test_profile_without_start_raises
    assert_raise(RuntimeError) do
      Rperf.profile { 1 + 1 }
    end
  end

  def test_profile_without_block_raises
    Rperf.start(frequency: 1000, defer: true)
    assert_raise(ArgumentError) do
      Rperf.profile
    end
  end

  def test_profile_without_defer
    # profile should work even without defer (labels apply, samples collected)
    Rperf.start(frequency: 1000)

    Rperf.profile(tag: "test") do
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    assert_operator data[:aggregated_samples].size, :>, 0,
      "Should have samples with non-deferred start"

    labeled = data[:aggregated_samples].select { |_, _, _, lsi| lsi && lsi > 0 }
    assert_operator labeled.size, :>, 0,
      "Should have labeled samples even without defer"
  end

  def test_profile_restores_labels_on_exception
    Rperf.start(frequency: 1000, defer: true)

    begin
      Rperf.profile(request: "abc") do
        raise "boom"
      end
    rescue RuntimeError
    end

    assert_equal({}, Rperf.labels, "Labels should be restored after exception")
  end

  def test_profile_refcount_recovers_after_exception
    Rperf.start(frequency: 1000, defer: true)

    begin
      Rperf.profile { raise "boom" }
    rescue RuntimeError
    end

    # refcount should be back to 0 (paused); a new profile block should work
    Rperf.profile do
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    assert_operator data[:aggregated_samples].size, :>, 0,
      "Profile should work after exception in previous profile block"
  end

  def test_defer_wall_mode
    Rperf.start(frequency: 1000, mode: :wall, defer: true)

    Rperf.profile(endpoint: "/test") do
      sleep 0.05
    end

    data = Rperf.stop
    assert_operator data[:aggregated_samples].size, :>, 0,
      "Wall mode defer should collect samples"
  end

  def test_sequential_profile_blocks
    Rperf.start(frequency: 1000, defer: true)

    Rperf.profile(phase: "first") do
      5_000_000.times { 1 + 1 }
    end

    snap = Rperf.snapshot
    samples_after_first = snap[:aggregated_samples].size

    # Gap: timer should be paused here
    5_000_000.times { 1 + 1 }

    Rperf.profile(phase: "second") do
      5_000_000.times { 1 + 1 }
    end

    data = Rperf.stop
    assert_operator data[:aggregated_samples].size, :>, samples_after_first,
      "Second profile block should add more samples"
  end

  def test_profile_multithread
    Rperf.start(frequency: 1000, mode: :wall, defer: true)

    threads = 2.times.map do |i|
      Thread.new do
        Rperf.profile(thread_name: "worker-#{i}") do
          5_000_000.times { 1 + 1 }
        end
      end
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_operator data[:aggregated_samples].size, :>, 0,
      "Multithread profile should collect samples"
    assert_not_nil data[:label_sets]
  end

  def test_snapshot_during_profile
    Rperf.start(frequency: 1000, defer: true)

    Rperf.profile do
      5_000_000.times { 1 + 1 }
      snap = Rperf.snapshot
      assert_not_nil snap
      assert_operator snap[:aggregated_samples].size, :>, 0,
        "Snapshot during profile should have samples"
    end
  end
end
