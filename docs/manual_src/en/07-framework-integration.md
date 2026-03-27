# Framework Integration

rperf provides optional integrations that automatically profile and label samples with context from web frameworks and job processors. They use [`Rperf.profile`](#index:Rperf.profile), which both activates the timer and sets labels. This works seamlessly with `start(defer: true)` — only requests/jobs that pass through the middleware are sampled. Start profiling separately (e.g., in an initializer).

## Rack middleware

`Rperf::RackMiddleware` profiles each request and labels it with its endpoint (`METHOD /path`).

```ruby
require "rperf/rack"
```

### Rails

```ruby
# config/initializers/rperf.rb
require "rperf/rack"

Rperf.start(defer: true, mode: :wall, frequency: 99)

Rails.application.config.middleware.use Rperf::RackMiddleware

at_exit do
  data = Rperf.stop
  Rperf.save("tmp/profile.pb.gz", data) if data
end
```

Then filter the profile by endpoint:

```bash
go tool pprof -tagfocus=endpoint="GET /api/users" tmp/profile.pb.gz
go tool pprof -tagroot=endpoint tmp/profile.pb.gz   # group by endpoint
```

### Sinatra

```ruby
require "sinatra"
require "rperf/rack"

Rperf.start(defer: true, mode: :wall, frequency: 99)
use Rperf::RackMiddleware

at_exit do
  data = Rperf.stop
  Rperf.save("profile.pb.gz", data) if data
end

get "/hello" do
  "Hello, world!"
end
```

### Customizing the label key

By default the middleware uses the label key `:endpoint`. You can change it:

```ruby
use Rperf::RackMiddleware, label_key: :route
```

## Active Job

`Rperf::ActiveJobMiddleware` profiles each job and labels it with its class name (e.g., `SendEmailJob`). Works with any Active Job backend — Sidekiq, GoodJob, Solid Queue, etc.

```ruby
require "rperf/active_job"
```

Start profiling in an initializer, then include it in your base job class:

```ruby
# config/initializers/rperf.rb
Rperf.start(defer: true, mode: :wall, frequency: 99)
```

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  include Rperf::ActiveJobMiddleware
end
```

All subclasses inherit the label automatically:

```ruby
class SendEmailJob < ApplicationJob
  def perform(user)
    # samples here get job="SendEmailJob"
  end
end
```

Filter by job:

```bash
go tool pprof -tagfocus=job=SendEmailJob profile.pb.gz
go tool pprof -tagroot=job profile.pb.gz   # group by job class
```

## Sidekiq

`Rperf::SidekiqMiddleware` profiles each job and labels it with its worker class name. This covers both Active Job-backed workers and plain Sidekiq workers.

```ruby
require "rperf/sidekiq"
```

Register it as a Sidekiq server middleware:

```ruby
# config/initializers/sidekiq.rb
Rperf.start(defer: true, mode: :wall, frequency: 99)

Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end
```

> [!NOTE]
> If you use Active Job with Sidekiq, choose one or the other — using both will result in duplicate labels. The Sidekiq middleware is more general (covers non-Active Job workers too).

## On-demand profiling with Rperf.profile

If you want to profile only specific endpoints or jobs — with zero overhead elsewhere — use [`Rperf.start(defer: true)`](#index:Rperf.start) and [`Rperf.profile`](#index:Rperf.profile):

```ruby
# config/initializers/rperf.rb
require "rperf"

Rperf.start(defer: true, mode: :wall, frequency: 99)

# Export profiles periodically
Thread.new do
  loop do
    sleep 60
    snap = Rperf.snapshot(clear: true)
    Rperf.save("tmp/profile-#{Time.now.to_i}.pb.gz", snap) if snap
  end
end
```

Then wrap specific code paths with `profile`:

```ruby
class UsersController < ApplicationController
  def index
    Rperf.profile(endpoint: "GET /users") do
      @users = User.all
    end
  end
end
```

Only the `profile` blocks are sampled — other requests and background work have zero timer overhead.

## Full Rails example

A typical Rails setup with both web and job profiling:

```ruby
# config/initializers/rperf.rb
require "rperf/rack"
require "rperf/sidekiq"

Rperf.start(defer: true, mode: :wall, frequency: 99)

# Label web requests
Rails.application.config.middleware.use Rperf::RackMiddleware

# Label Sidekiq jobs
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end

# Export profiles periodically
Thread.new do
  loop do
    sleep 60
    snap = Rperf.snapshot(clear: true)
    Rperf.save("tmp/profile-#{Time.now.to_i}.pb.gz", snap) if snap
  end
end
```

Then compare where time goes across endpoints and jobs:

```bash
go tool pprof -tagroot=endpoint tmp/profile-*.pb.gz   # web breakdown
go tool pprof -tagroot=job tmp/profile-*.pb.gz         # job breakdown
```
