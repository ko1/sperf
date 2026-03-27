# フレームワーク統合

rperf は、Web フレームワークやジョブプロセッサからのコンテキストで自動的にプロファイルおよびラベル付けするオプションの統合機能を提供します。これらは [`Rperf.profile`](#index:Rperf.profile) を使用し、タイマーの有効化とラベルの設定を同時に行います。`start(defer: true)` とシームレスに連携し、ミドルウェアを通過するリクエスト/ジョブのみがサンプリングされます。プロファイリングの開始は別途行ってください（例: イニシャライザで）。

## Rack ミドルウェア

`Rperf::RackMiddleware` は各リクエストをプロファイルし、エンドポイント（`METHOD /path`）でラベル付けします。

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

その後、エンドポイントでプロファイルをフィルタリング:

```bash
go tool pprof -tagfocus=endpoint="GET /api/users" tmp/profile.pb.gz
go tool pprof -tagroot=endpoint tmp/profile.pb.gz   # エンドポイントごとにグループ化
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

### ラベルキーのカスタマイズ

デフォルトではミドルウェアはラベルキー `:endpoint` を使用します。変更できます:

```ruby
use Rperf::RackMiddleware, label_key: :route
```

## Active Job

`Rperf::ActiveJobMiddleware` は各ジョブをプロファイルし、クラス名（例: `SendEmailJob`）でラベル付けします。任意の Active Job バックエンド（Sidekiq、GoodJob、Solid Queue など）で動作します。

```ruby
require "rperf/active_job"
```

イニシャライザでプロファイリングを開始し、ベースジョブクラスにインクルードします:

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

すべてのサブクラスが自動的にラベルを継承します:

```ruby
class SendEmailJob < ApplicationJob
  def perform(user)
    # ここのサンプルに job="SendEmailJob" が付く
  end
end
```

ジョブでフィルタリング:

```bash
go tool pprof -tagfocus=job=SendEmailJob profile.pb.gz
go tool pprof -tagroot=job profile.pb.gz   # ジョブクラスごとにグループ化
```

## Sidekiq

`Rperf::SidekiqMiddleware` は各ジョブをプロファイルし、ワーカークラス名でラベル付けします。Active Job ベースのワーカーとプレーンな Sidekiq ワーカーの両方をカバーします。

```ruby
require "rperf/sidekiq"
```

Sidekiq のサーバーミドルウェアとして登録します:

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
> Active Job と Sidekiq を併用する場合は、どちらか一方を選んでください。両方を使用するとラベルが重複します。Sidekiq ミドルウェアの方がより汎用的です（非 Active Job ワーカーもカバー）。

## Rperf.profile によるオンデマンドプロファイリング

特定のエンドポイントやジョブのみをプロファイルし、他の部分ではオーバーヘッドをゼロにしたい場合は、[`Rperf.start(defer: true)`](#index:Rperf.start) と [`Rperf.profile`](#index:Rperf.profile) を使用します:

```ruby
# config/initializers/rperf.rb
require "rperf"

Rperf.start(defer: true, mode: :wall, frequency: 99)

# プロファイルを定期的にエクスポート
Thread.new do
  loop do
    sleep 60
    snap = Rperf.snapshot(clear: true)
    Rperf.save("tmp/profile-#{Time.now.to_i}.pb.gz", snap) if snap
  end
end
```

その後、特定のコードパスを `profile` でラップします:

```ruby
class UsersController < ApplicationController
  def index
    Rperf.profile(endpoint: "GET /users") do
      @users = User.all
    end
  end
end
```

`profile` ブロックのみがサンプリングされます。他のリクエストやバックグラウンド処理にはタイマーのオーバーヘッドがゼロです。

## Rails の完全な設定例

Web とジョブの両方をプロファイリングする典型的な Rails 設定:

```ruby
# config/initializers/rperf.rb
require "rperf/rack"
require "rperf/sidekiq"

Rperf.start(defer: true, mode: :wall, frequency: 99)

# Web リクエストにラベル付け
Rails.application.config.middleware.use Rperf::RackMiddleware

# Sidekiq ジョブにラベル付け
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end

# プロファイルを定期的にエクスポート
Thread.new do
  loop do
    sleep 60
    snap = Rperf.snapshot(clear: true)
    Rperf.save("tmp/profile-#{Time.now.to_i}.pb.gz", snap) if snap
  end
end
```

エンドポイントとジョブ間の時間の使われ方を比較:

```bash
go tool pprof -tagroot=endpoint tmp/profile-*.pb.gz   # Web の内訳
go tool pprof -tagroot=job tmp/profile-*.pb.gz         # ジョブの内訳
```
