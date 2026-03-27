# Ruby API

rperf はプログラマティックなプロファイリングのための Ruby API を提供します。特定のコードセクションをプロファイルしたり、テストスイートにプロファイリングを統合したり、カスタムプロファイリングワークフローを構築したりする場合に便利です。

## 基本的な使い方

### ブロック形式（推奨）

rperf を使用する最もシンプルな方法は、[`Rperf.start`](#index:Rperf.start) のブロック形式です。ブロックをプロファイルし、プロファイリングデータを返します:

```ruby
require "rperf"

data = Rperf.start(output: "profile.pb.gz", frequency: 1000, mode: :cpu) do
  # プロファイルしたいコード
end
```

`output:` を指定すると、ブロックの終了時にプロファイルが自動的にファイルに書き込まれます。このメソッドは、さらなる処理のために生データのハッシュも返します。

### 例: フィボナッチ関数のプロファイリング

```ruby
require "rperf"

def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end

data = Rperf.start(frequency: 1000, mode: :cpu) do
  fib(33)
end

Rperf.save("profile.txt", data)
```

実行すると以下のような出力が得られます:

```
Total: 192.7ms (cpu)
Samples: 192, Frequency: 1000Hz

Flat:
     192.7ms 100.0%  Object#fib (example.rb)

Cumulative:
     192.7ms 100.0%  Object#fib (example.rb)
     192.7ms 100.0%  block in <main> (example.rb)
     192.7ms 100.0%  Rperf.start (lib/rperf.rb)
     192.7ms 100.0%  <main> (example.rb)
```

### 手動での開始/停止

ブロック形式が使いにくい場合は、手動でプロファイリングを開始・停止できます:

```ruby
require "rperf"

Rperf.start(frequency: 1000, mode: :wall)

# ... プロファイルしたいコード ...

data = Rperf.stop
```

[`Rperf.stop`](#index:Rperf.stop) はデータハッシュを返します。プロファイラが動作していなかった場合は `nil` を返します。

## Rperf.start のパラメータ

| パラメータ | 型 | デフォルト | 説明 |
|-----------|------|---------|-------------|
| `frequency:` | Integer | 1000 | サンプリング周波数 (Hz) |
| `mode:` | Symbol | `:cpu` | `:cpu` または `:wall` |
| `output:` | String | `nil` | 停止時に書き込むファイルパス |
| `verbose:` | Boolean | `false` | 統計を stderr に出力 |
| `format:` | Symbol | `nil` | `:pprof`、`:collapsed`、`:text`、または `nil`（output 拡張子から自動検出） |
| `signal:` | Integer/Boolean | `nil` | Linux のみ: `nil` = タイマーシグナル（デフォルト）、`false` = nanosleep スレッド、正の整数 = 特定の RT シグナル番号 |
| `aggregate:` | Boolean | `true` | 同一スタックをプロファイリング中に集約してメモリを削減。`false` は生のサンプルごとのデータを返す |
| `defer:` | Boolean | `false` | タイマーを一時停止した状態で開始。特定のセクションのサンプリングを有効にするには [`Rperf.profile`](#index:Rperf.profile) ブロックを使用 |

## Rperf.stop の戻り値

`Rperf.stop` はプロファイラが動作していなかった場合は `nil` を返します。それ以外の場合は Hash を返します:

```ruby
{
  mode: :cpu,               # または :wall
  frequency: 1000,
  sampling_count: 1234,     # タイマーコールバックの回数
  sampling_time_ns: 56789,  # サンプリングに費やした合計時間（オーバーヘッド）
  trigger_count: 1234,      # タイマートリガーの回数
  detected_thread_count: 4, # プロファイリング中に検出されたスレッド数
  start_time_ns: 17740...,  # CLOCK_REALTIME エポック（ナノ秒）
  duration_ns: 10000000,    # プロファイリング時間（ナノ秒）
  unique_frames: 42,        # ユニークフレーム数（aggregate: true の場合のみ）
  unique_stacks: 120,       # ユニークスタック数（aggregate: true の場合のみ）
  samples: [                          # [frames, weight, thread_seq, label_set_id] の配列
    [frames, weight, seq, lsi],       #   frames: [[path, label], ...] 最深部が先頭
    ...                               #   weight: Integer（ナノ秒）
  ],                                  #   seq: Integer（スレッド連番、1 始まり）
                                      #   lsi: Integer（ラベルセット ID、0 = ラベルなし）
  label_sets: [{}, {request: "abc"}], # ラベルセットテーブル（index = label_set_id、ラベル使用時に存在）
}
```

各サンプルには以下が含まれます:
- **frames**: `[path, label]` ペアの配列、最深部が先頭（リーフフレームがインデックス 0）
- **weight**: このサンプルに帰属する時間（ナノ秒）
- **thread_seq**: スレッド連番（1 始まり、プロファイリングセッションごとに割り当て）
- **label_set_id**: ラベルセット ID（0 = ラベルなし）。`label_sets` 配列へのインデックス

`aggregate: true`（デフォルト）の場合、同一スタックはマージされ、重みが合計されます。`samples` 配列にはユニークな `(stack, thread_seq, label_set_id)` の組み合わせごとに 1 エントリが含まれます。`aggregate: false` の場合は、すべての生サンプルが個別に返されます。

## Rperf.save

[`Rperf.save`](#index:Rperf.save) はプロファイリングデータをサポートされている任意の形式でファイルに書き込みます:

```ruby
Rperf.save("profile.pb.gz", data)        # pprof 形式
Rperf.save("profile.collapsed", data)    # collapsed stacks
Rperf.save("profile.txt", data)          # テキストレポート
```

形式はファイル拡張子から自動検出されます。`format:` キーワードでオーバーライドできます:

```ruby
Rperf.save("output.dat", data, format: :text)
```

## Rperf.snapshot

[`Rperf.snapshot`](#index:Rperf.snapshot) は停止せずに現在のプロファイリングデータを返します。集約モード（デフォルト）でのみ動作します。プロファイリング中でない場合は `nil` を返します。

```ruby
Rperf.start(frequency: 1000)
# ... 処理 ...
snap = Rperf.snapshot
Rperf.save("snap.pb.gz", snap)
# ... さらに処理（プロファイリングは継続） ...
data = Rperf.stop
```

`clear: true` を指定すると、スナップショット取得後に集約データがリセットされます。これにより、各スナップショットが前回のクリア以降の期間のみをカバーするインターバルベースのプロファイリングが可能になります:

```ruby
Rperf.start(frequency: 1000)
loop do
  sleep 10
  snap = Rperf.snapshot(clear: true)
  Rperf.save("profile-#{Time.now.to_i}.pb.gz", snap)
end
```

## サンプルラベル

[`Rperf.label`](#index:Rperf.label) は現在のスレッドのサンプルにキーバリューラベルを付与します。ラベルは [pprof](#index:pprof) のサンプルラベルに表示され、コンテキストごとのフィルタリング（例: リクエストごとのプロファイリング）が可能になります。プロファイリングが動作していない場合、`label` は暗黙的に無視されます。無条件に呼び出しても安全です（例: Rack ミドルウェアから）。

### ブロック形式

ブロックを使用すると、ブロックの終了時にラベルが自動的に復元されます。例外が発生した場合も同様です:

```ruby
Rperf.label(request: "abc-123", endpoint: "/api/users") do
  handle_request   # 内部のサンプルにこれらのラベルが付く
end
# ここでラベルは以前の状態に復元される
```

### ブロックなし

ブロックなしの場合、ラベルは変更されるまで現在のスレッドに残ります:

```ruby
Rperf.label(request: "abc-123")
# このスレッドの以降のすべてのサンプルに request="abc-123" が付く
```

### マージと削除

新しいラベルは既存のラベルとマージされます。値を `nil` に設定するとキーが削除されます:

```ruby
Rperf.label(request: "abc")
Rperf.label(phase: "db")       # phase を追加、request は保持
Rperf.labels                   #=> {request: "abc", phase: "db"}
Rperf.label(request: nil)      # request を削除
Rperf.labels                   #=> {phase: "db"}
```

### ネストされたブロック

各ブロックはスコープを作成します。終了時に、ブロック内で何が起こったかに関係なく、ブロック前の状態にラベルが復元されます:

```ruby
Rperf.label(request: "abc") do
  Rperf.label(phase: "db") do
    Rperf.labels  #=> {request: "abc", phase: "db"}
  end
  Rperf.labels    #=> {request: "abc"}
end
Rperf.labels      #=> {}
```

### pprof でのラベルによるフィルタリング

ラベルは pprof のサンプルラベルに書き込まれます。`go tool pprof` でフィルタリングできます:

```bash
# 特定のラベル値でフィルタ
go tool pprof -tagfocus=request=abc-123 profile.pb.gz

# スタックルートでラベルごとにグループ化（「どのリクエストが遅い？」）
go tool pprof -tagroot=request profile.pb.gz

# スタックリーフでラベルごとにグループ化（「この関数を呼んでいるのは誰？」）
go tool pprof -tagleaf=request profile.pb.gz

# 特定のラベル値を除外
go tool pprof -tagignore=request=healthcheck profile.pb.gz
```

### ラベルの読み取り

[`Rperf.labels`](#index:Rperf.labels) は現在のスレッドのラベルを Hash として返します:

```ruby
Rperf.labels  #=> {request: "abc", phase: "db"}
```

ラベルが設定されていない場合は空の Hash を返します。

## 遅延開始と Rperf.profile

### なぜ遅延するのか？

通常、`Rperf.start` はサンプリングタイマーを即座に開始します。タイマーティックごとにスタックトレースをキャプチャするためにアプリケーションが中断されます。これがプロファイリングのオーバーヘッドです。長時間実行されるサーバーでは、すべてのコードに対して常にこのコストを払いたくないかもしれません。特定のエンドポイント、ジョブ、またはコードパスのみを対象にしたい場合があります。

`defer: true` はこの問題を解決します。プロファイラのインフラストラクチャ（バッファ、フック、ワーカースレッド）をセットアップしますが、**タイマーは開始しません**。タイマーは [`Rperf.profile`](#index:Rperf.profile) ブロック内でのみ発火します。ブロックの外ではオーバーヘッドはゼロです。シグナルも、割り込みも、スタックキャプチャもありません。

```
start(defer: false)     start(defer: true)
┌─────────────────┐     ┌─────────────────┐
│ start            │     │ start            │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │     │                  │  ← タイマー非発火
│ ▓ sampling ▓▓▓▓ │     │ ┌──profile──┐   │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │     │ │▓▓sampling▓│   │  ← タイマー有効
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │     │ └───────────┘   │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │     │                  │  ← タイマー非発火
│ stop             │     │ stop             │
└─────────────────┘     └─────────────────┘
```

これは[フレームワーク統合](#index:Framework Integration)と組み合わせると特に便利です。ミドルウェアが各リクエスト/ジョブを `profile` ブロックでラップするため、実際のリクエスト処理のみがサンプリングされます。

### Rperf.profile

[`Rperf.profile`](#index:Rperf.profile) はブロックの間タイマーを有効化し、オプションでラベルを適用します。タイマー制御とラベル割り当てを 1 つの呼び出しで組み合わせます。

```ruby
require "rperf"

Rperf.start(defer: true, mode: :wall)

# ここでタイマーが有効化され、サンプルに endpoint="/users" ラベルが付く
Rperf.profile(endpoint: "/users") do
  handle_request
end
# タイマー一時停止 — オーバーヘッドゼロ

Rperf.profile(endpoint: "/health") do
  check_health
end

data = Rperf.stop
Rperf.save("profile.pb.gz", data)
```

### ネスト

`profile` ブロックはネストできます。タイマーは最も外側のブロックが終了するまで有効です。ラベルは [`Rperf.label`](#index:Rperf.label) と同様にマージされます:

```ruby
Rperf.profile(endpoint: "/users") do
  Rperf.profile(phase: "db") do
    # {endpoint: "/users", phase: "db"} でサンプリング
    query_db
  end
  # {endpoint: "/users"} でサンプリング
  render_response
end
# タイマー再び一時停止
```

### Rperf.label との組み合わせ

`profile` はタイマーを制御し、`label` はタグのみを追加します。両方を一緒に使用できます:

```ruby
Rperf.start(defer: true, mode: :wall)

Rperf.profile(endpoint: "/users") do
  Rperf.label(phase: "auth") do
    authenticate     # サンプリングされ、endpoint + phase のラベル付き
  end
  Rperf.label(phase: "db") do
    query_db         # サンプリングされ、endpoint + phase のラベル付き
  end
end
```

### defer なしの場合

`profile` は通常の（非遅延）start でも動作します。この場合、タイマーは既に動作しており、`profile` はラベルの適用のみを行います。ブロック付きの `Rperf.label` と同等です:

```ruby
Rperf.start(mode: :wall)
Rperf.profile(endpoint: "/users") do
  handle_request   # サンプリングされる（タイマーは既に動作中）
end
```

### エラー処理

`profile` はプロファイリングが開始されていない場合は `RuntimeError` を、ブロックが与えられない場合は `ArgumentError` を発生させます。ブロック内で例外が発生しても、ラベルとタイマーの状態は適切に復元されます。

## 実践的な例

### Web リクエストハンドラのプロファイリング

```ruby
require "rperf"

class ApplicationController
  def profile_action
    data = Rperf.start(mode: :wall) do
      # 典型的なリクエストのシミュレーション
      users = User.where(active: true).limit(100)
      result = users.map { |u| serialize_user(u) }
      render json: result
    end

    Rperf.save("request_profile.txt", data)
  end
end
```

ここで wall モードを使用すると、CPU 時間だけでなくデータベース I/O や GVL 競合も捕捉できます。

### CPU プロファイルと wall プロファイルの比較

```ruby
require "rperf"

def workload
  # CPU と I/O の混合
  100.times do
    compute_something
    sleep(0.001)
  end
end

# CPU プロファイル: CPU サイクルの使われ方を表示
cpu_data = Rperf.start(mode: :cpu) { workload }
Rperf.save("cpu.txt", cpu_data)

# wall プロファイル: wall time の使われ方を表示
wall_data = Rperf.start(mode: :wall) { workload }
Rperf.save("wall.txt", wall_data)
```

CPU プロファイルは `compute_something` に集中し、wall プロファイルは `sleep` 呼び出しを `[GVL blocked]` 時間として表示します。

### サンプルの処理

サンプルデータをプログラマティックに処理できます。デフォルトでは、サンプルは集約されます（同一スタックがマージ）:

```ruby
require "rperf"

data = Rperf.start(mode: :cpu) { workload }
# data[:aggregated_samples] に集約されたエントリが含まれる（ユニークスタックごとに 1 つ）

# 最もホットな関数を見つける
flat = Hash.new(0)
data[:aggregated_samples].each do |frames, weight, thread_seq|
  leaf_label = frames.first&.last  # frames[0] がリーフ
  flat[leaf_label] += weight
end

top = flat.sort_by { |_, w| -w }.first(5)
top.each do |label, weight_ns|
  puts "#{label}: #{weight_ns / 1_000_000.0}ms"
end
```

生の（非集約の）サンプルごとのデータを取得するには、`aggregate: false` を渡します。各タイマーティックが個別のエントリを生成します:

```ruby
data = Rperf.start(mode: :cpu, aggregate: false) { workload }
# data[:raw_samples] にタイマーサンプルごとに 1 エントリが含まれる
data[:raw_samples].each do |frames, weight, thread_seq|
  puts "thread=#{thread_seq} weight=#{weight}ns depth=#{frames.size}"
end
```

### FlameGraph 用の collapsed stacks の生成

```ruby
require "rperf"

data = Rperf.start(mode: :cpu) { workload }
Rperf.save("profile.collapsed", data)
```

collapsed 形式はユニークスタックごとに 1 行で、Brendan Gregg の [FlameGraph](#cite:gregg2016) ツールや speedscope と互換性があります:

```
frame1;frame2;...;leaf weight_ns
```

フレームグラフの SVG を生成できます:

```bash
flamegraph.pl profile.collapsed > flamegraph.svg
```

または `.collapsed` ファイルを [speedscope](https://www.speedscope.app/) で直接開くことができます。
