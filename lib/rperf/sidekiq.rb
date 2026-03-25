require "rperf"

class Rperf::SidekiqMiddleware
  def call(_worker, job, _queue)
    Rperf.label(job: job["class"]) do
      yield
    end
  end
end
