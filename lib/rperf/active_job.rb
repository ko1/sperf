require "rperf"

module Rperf::ActiveJobMiddleware
  extend ActiveSupport::Concern

  included do
    around_perform do |job, block|
      Rperf.label(job: job.class.name) do
        block.call
      end
    end
  end
end
