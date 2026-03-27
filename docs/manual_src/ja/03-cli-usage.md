# CLI の使い方

rperf は perf ライクなコマンドラインインターフェースを提供し、5 つの主要サブコマンドがあります: `record`、`stat`、`exec`、`report`、`diff`。

## rperf stat

[`rperf stat`](#index:rperf stat) は性能の概要を最も手軽に確認する方法です。コマンドを [wall](#index:wall mode) モードのプロファイリングで実行し、サマリーを stderr に出力します。

```bash
rperf stat ruby my_app.rb
```

### 例: CPU バウンドなプログラム

シンプルなフィボナッチ計算:

```ruby
# fib.rb
def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end
fib(35)
```

`rperf stat` の実行:

```bash
rperf stat ruby fib.rb
```

```
 Performance stats for 'ruby fib.rb':

           744.4 ms   user
            32.0 ms   sys
           491.0 ms   real

           481.0 ms 100.0%  CPU execution
            12.0 ms         [Ruby] GC time (9 count: 6 minor, 3 major)
         154,468            [Ruby] allocated objects
          66,596            [Ruby] freed objects
              25 MB         [OS] peak memory (maxrss)
              31            [OS] context switches (10 voluntary, 21 involuntary)
               0 MB         [OS] disk I/O (0 MB read, 0 MB write)

  481 samples / 481 triggers, 0.1% profiler overhead
```

出力の意味:

- **user/sys/real**: 標準的な時間計測（`time` コマンドと同様）
- **時間の内訳**: wall time がどこで費やされたか — CPU 実行、GVL ブロック（I/O/sleep）、GVL 待ち（競合）、GC marking、GC sweeping
- **Ruby の統計**: GC 回数、割り当て済み/解放済みオブジェクト、YJIT 比率（有効な場合）
- **OS の統計**: ピークメモリ、コンテキストスイッチ、ディスク I/O

`--report` を使用すると、フラットおよびキュムレイティブな上位 50 関数テーブルが出力に追加されます。

### 例: CPU と I/O の混合

```ruby
# mixed.rb
def cpu_work(n)
  sum = 0
  n.times { |i| sum += i * i }
  sum
end

def io_work
  sleep(0.05)
end

5.times do
  cpu_work(500_000)
  io_work
end
```

`rperf stat` の実行:

```bash
rperf stat ruby mixed.rb
```

`stat` は常に wall モードを使用するため、CPU と I/O の間の時間配分が確認できます。`[Ruby] GVL blocked` の行は sleep/I/O に費やされた時間を示し、`CPU execution` は計算時間を示します。

### stat のオプション

```bash
rperf stat [options] command [args...]
```

| オプション | 説明 |
|--------|-------------|
| `-o PATH` | プロファイルをファイルにも保存 (デフォルト: なし) |
| `-f HZ` | サンプリング周波数 (Hz) (デフォルト: 1000) |
| `-m MODE` | `cpu` または `wall` (デフォルト: `wall`) |
| `--report` | フラット/キュムレイティブなプロファイルテーブルを出力に含める |
| `-v` | 追加のサンプリング統計を出力 |

## rperf exec

[`rperf exec`](#index:rperf exec) はコマンドをプロファイリング付きで実行し、完全な性能レポートを stderr に出力します。`rperf stat --report` と同等です。デフォルトで [wall](#index:wall mode) モードを使用し、ファイルには保存しません。

```bash
rperf exec ruby my_app.rb
```

`stat` が表示するすべて（時間計測、時間内訳、GC/メモリ/OS 統計）に加えて、フラットおよびキュムレイティブな上位 50 関数テーブルが出力されます。

### exec のオプション

```bash
rperf exec [options] command [args...]
```

| オプション | 説明 |
|--------|-------------|
| `-o PATH` | プロファイルをファイルにも保存 (デフォルト: なし) |
| `-f HZ` | サンプリング周波数 (Hz) (デフォルト: 1000) |
| `-m MODE` | `cpu` または `wall` (デフォルト: `wall`) |
| `-v` | 追加のサンプリング統計を出力 |

## rperf record

[`rperf record`](#index:rperf record) はコマンドをプロファイルし、結果をファイルに保存します。詳細な分析のためにプロファイルをキャプチャする主要な方法です。

```bash
rperf record ruby my_app.rb
```

デフォルトでは、CPU モードの pprof 形式で `rperf.data` に保存します。

### 例: プロファイルの記録

```bash
rperf record ruby fib.rb
```

これにより `rperf.data` が作成されます。その後 `rperf report` や他の pprof 互換ツールで分析できます。

### プロファイリングモードの選択

rperf は 2 つのプロファイリングモードをサポートしています:

- **[cpu](#index:cpu mode)** (デフォルト): スレッドごとの CPU 時間を計測します。CPU サイクルを消費する関数を見つけるのに最適です。sleep、I/O、GVL 待ちの時間は無視されます。
- **[wall](#index:wall mode)**: ウォールクロック時間を計測します。I/O、sleep、GVL 競合を含む、wall time の使われ方を見つけるのに最適です。

```bash
# CPU モード (デフォルト)
rperf record ruby my_app.rb

# wall モード
rperf record -m wall ruby my_app.rb
```

### 出力形式の選択

rperf はファイル拡張子から形式を自動検出します:

```bash
# pprof 形式 (デフォルト)
rperf record -o profile.pb.gz ruby my_app.rb

# collapsed stacks (FlameGraph / speedscope 向け)
rperf record -o profile.collapsed ruby my_app.rb

# 人間が読めるテキスト
rperf record -o profile.txt ruby my_app.rb
```

形式を明示的に指定することもできます:

```bash
rperf record --format text -o profile.dat ruby my_app.rb
```

### 例: テキスト出力

```bash
rperf record -o profile.txt ruby fib.rb
```

テキスト出力は以下のようになります:

```
Total: 509.5ms (cpu)
Samples: 509, Frequency: 1000Hz

 Flat:
           509.5 ms 100.0%  Object#fib (fib.rb)

 Cumulative:
           509.5 ms 100.0%  Object#fib (fib.rb)
           509.5 ms 100.0%  <main> (fib.rb)
```

### 例: wall モードのテキスト出力

```bash
rperf record -m wall -o wall_profile.txt ruby mixed.rb
```

```
Total: 311.8ms (wall)
Samples: 80, Frequency: 1000Hz

 Flat:
           250.6 ms  80.4%  [GVL blocked] (<GVL>)
            44.1 ms  14.1%  Object#cpu_work (mixed.rb)
            13.9 ms   4.5%  Integer#times (<internal:numeric>)
             3.2 ms   1.0%  Kernel#sleep (<C method>)
             0.0 ms   0.0%  [GVL wait] (<GVL>)

 Cumulative:
           311.8 ms 100.0%  Integer#times (<internal:numeric>)
           311.8 ms 100.0%  block in <main> (mixed.rb)
           311.8 ms 100.0%  <main> (mixed.rb)
           253.8 ms  81.4%  Kernel#sleep (<C method>)
           253.8 ms  81.4%  Object#io_work (mixed.rb)
           250.6 ms  80.4%  [GVL blocked] (<GVL>)
            58.0 ms  18.6%  Object#cpu_work (mixed.rb)
             0.0 ms   0.0%  [GVL wait] (<GVL>)
```

wall モードでは、`[GVL blocked]` が支配的なコストとして表示されます。これは `io_work` 内の sleep 時間です。`cpu_work` の CPU 時間は明確に分離されています。

### Verbose 出力

`-v` フラグはプロファイリング中にサンプリング統計を stderr に出力します:

```bash
rperf record -v ruby my_app.rb
```

```
[rperf] mode=cpu frequency=1000Hz
[rperf] sampling: 98 calls, 0.11ms total, 1.1us/call avg
[rperf] samples recorded: 904
[rperf] top 10 by flat:
[rperf]       53.4ms  50.1%  Object#cpu_work (-e)
[rperf]       17.0ms  15.9%  Integer#times (<internal:numeric>)
...
```

### record のオプション

```bash
rperf record [options] command [args...]
```

| オプション | 説明 |
|--------|-------------|
| `-o PATH` | 出力ファイル (デフォルト: `rperf.data`) |
| `-f HZ` | サンプリング周波数 (Hz) (デフォルト: 1000) |
| `-m MODE` | `cpu` または `wall` (デフォルト: `cpu`) |
| `--format FMT` | `pprof`、`collapsed`、または `text` (デフォルト: 拡張子から自動検出) |
| `-p, --print` | テキストプロファイルを stdout に出力 (`--format=text --output=/dev/stdout` と同等) |
| `-v` | サンプリング統計を stderr に出力 |

## rperf report

[`rperf report`](#index:rperf report) は pprof プロファイルを分析用に開きます。`go tool pprof` をラップしており、Go のインストールが必要です。

```bash
# インタラクティブな Web UI を開く (デフォルト)
rperf report

# 特定のファイルを開く
rperf report profile.pb.gz

# 上位の関数を出力
rperf report --top

# pprof テキストサマリーを出力
rperf report --text
```

### 例: top とテキスト出力

先ほど記録した `fib.rb` のプロファイルを使用:

```bash
rperf report --top rperf.data
```

```
Type: cpu
Showing nodes accounting for 577.31ms, 100% of 577.31ms total
      flat  flat%   sum%        cum   cum%
  577.31ms   100%   100%   577.31ms   100%  Object#fib
         0     0%   100%   577.31ms   100%  <main>
```

デフォルト動作（`--top` や `--text` なし）では、フレームグラフ、上位関数ビュー、コールグラフの可視化を備えたインタラクティブな Web UI がブラウザで開きます。これは [pprof](#cite:ren2010) を利用しています。

### report のオプション

| オプション | 説明 |
|--------|-------------|
| `--top` | フラットタイムによる上位の関数を出力 |
| `--text` | pprof テキストサマリーを出力 |
| (デフォルト) | ブラウザでインタラクティブな Web UI を開く |

## rperf diff

[`rperf diff`](#index:rperf diff) は 2 つの pprof プロファイルを比較し、差分（target - base）を表示します。最適化の効果を測定するのに便利です。

```bash
# ブラウザで差分を開く
rperf diff before.pb.gz after.pb.gz

# 差分による上位の関数を出力
rperf diff --top before.pb.gz after.pb.gz

# テキスト差分を出力
rperf diff --text before.pb.gz after.pb.gz
```

### ワークフロー例

```bash
# ベースラインをプロファイル
rperf record -o before.pb.gz ruby my_app.rb

# 最適化を実施...

# 再度プロファイル
rperf record -o after.pb.gz ruby my_app.rb

# 比較
rperf diff before.pb.gz after.pb.gz
```

## rperf help

`rperf help` はプロファイリングモード、出力形式、合成フレーム、診断のヒントを含む完全なリファレンスドキュメントを出力します。

```bash
rperf help
```

人間が読むのにも AI による分析にも適した詳細なドキュメントが出力されます。
