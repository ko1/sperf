require "rperf"

class Rperf::Middleware
  def initialize(app, label_key: :endpoint)
    @app = app
    @label_key = label_key
  end

  def call(env)
    endpoint = "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}"
    Rperf.label(@label_key => endpoint) do
      @app.call(env)
    end
  end
end
