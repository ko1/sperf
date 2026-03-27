# 出力形式

rperf は 3 つの出力形式をサポートしています。形式はファイル拡張子から自動検出されるか、`--format` フラグ（CLI）または `format:` パラメータ（API）で明示的に設定できます。

## pprof (デフォルト)

[pprof](#index:pprof) 形式は gzip 圧縮された Protocol Buffers バイナリです。これは Go の pprof ツールで使用される標準形式で、rperf のデフォルト出力です。

**拡張子の規約**: `.pb.gz`

**表示方法**:

```bash
# インタラクティブな Web UI（Go が必要）
rperf report profile.pb.gz

# 上位の関数
rperf report --top profile.pb.gz

# テキストレポート
rperf report --text profile.pb.gz

# go tool pprof を直接使用する場合
go tool pprof -http=:8080 profile.pb.gz
go tool pprof -top profile.pb.gz
```

[speedscope](https://www.speedscope.app/) の Web インターフェースから pprof ファイルをインポートすることもできます。

**利点**: 幅広いツールエコシステムでサポートされている標準形式。2 つのプロファイル間の差分比較が可能。フレームグラフ、コールグラフ、ソースアノテーション付きのインタラクティブな探索。

### 埋め込みメタデータ

rperf は各 pprof プロファイルに以下のメタデータを埋め込みます:

| フィールド | 説明 |
|-------|-------------|
| `comment` | rperf バージョン、プロファイリングモード、周波数、Ruby バージョン |
| `time_nanos` | プロファイル収集開始時刻（エポックナノ秒） |
| `duration_nanos` | プロファイル期間（ナノ秒） |
| `doc_url` | rperf ドキュメントへのリンク |

コメントの表示: `go tool pprof -comments profile.pb.gz`

### サンプルラベル

各サンプルには `thread_seq` 数値ラベルが付きます。これはプロファイリングセッション中に rperf が各スレッドを初めて検出したときに割り当てられるスレッド連番（1 始まり）です。[`Rperf.label`](#index:Rperf.label) を使用すると、カスタムのキーバリュー文字列ラベルもサンプルに付与されます。

```bash
# スレッドごとにフレームグラフをグループ化
go tool pprof -tagroot=thread_seq profile.pb.gz

# カスタムラベルでフィルタ
go tool pprof -tagfocus=request=abc-123 profile.pb.gz

# ルートでラベルごとにグループ化（「どのリクエストが遅い？」）
go tool pprof -tagroot=request profile.pb.gz

# リーフでラベルごとにグループ化（「この関数を呼んでいるのは誰？」）
go tool pprof -tagleaf=request profile.pb.gz

# ラベルで除外
go tool pprof -tagignore=request=healthcheck profile.pb.gz
```

## Collapsed stacks

[collapsed stacks](#index:collapsed stacks) 形式は、ユニークなスタックトレースごとに 1 行のプレーンテキスト形式です。各行にはセミコロン区切りのスタック（ボトムからトップ）の後にスペースとナノ秒単位の重みが続きます。

**拡張子の規約**: `.collapsed`

**形式**:

```
bottom_frame;...;top_frame weight_ns
```

**出力例**:

```
<main>;Integer#times;block in <main>;Object#cpu_work;Integer#times;Object#cpu_work 53419170
<main>;Integer#times;block in <main>;Object#cpu_work;Integer#times 16962309
<main>;Integer#times;block in <main>;Object#io_work;Kernel#sleep 2335151
```

**使用方法**:

```bash
# FlameGraph SVG を生成
rperf record -o profile.collapsed ruby my_app.rb
flamegraph.pl profile.collapsed > flamegraph.svg

# speedscope で開く（.collapsed ファイルをドラッグ＆ドロップ）
# macOS: open https://www.speedscope.app/
# Linux: xdg-open https://www.speedscope.app/
```

**利点**: シンプルなテキスト形式で、コマンドラインツールで処理しやすい。Brendan Gregg の [FlameGraph](#cite:gregg2016) ツールや speedscope と互換性があります。

### collapsed stacks のプログラマティックなパース

```ruby
File.readlines("profile.collapsed").each do |line|
  stack, weight = line.rpartition(" ").then { |s, _, w| [s, w.to_i] }
  frames = stack.split(";")
  # frames[0] がボトム（main）、frames[-1] がリーフ（ホット）
  puts "#{frames.last}: #{weight / 1_000_000.0}ms"
end
```

## テキストレポート

テキスト形式は、フラットおよびキュムレイティブな上位 N テーブルを含む人間が読める（AI にも読める）レポートです。

**拡張子の規約**: `.txt`

**出力例**:

```
Total: 509.5ms (cpu)
Samples: 509, Frequency: 1000Hz

 Flat:
           509.5 ms 100.0%  Object#fib (fib.rb)

 Cumulative:
           509.5 ms 100.0%  Object#fib (fib.rb)
           509.5 ms 100.0%  <main> (fib.rb)
```

**セクション**:

- **ヘッダー**: プロファイルされた合計時間、サンプル数、周波数
- **フラットテーブル**: セルフタイム（関数がリーフ/最深部フレームだった時間）でソートされた関数
- **キュムレイティブテーブル**: トータルタイム（関数がスタックのどこかに出現した時間）でソートされた関数

**利点**: ツール不要 — `cat` で読める。テーブルごとにデフォルトで上位 50 エントリ。クイック分析、イシューレポートでの共有、AI アシスタントへの入力に適しています。

## 形式の比較

| 機能 | pprof | collapsed | text |
|---------|-------|-----------|------|
| ファイルサイズ | 小 (バイナリ + gzip) | 中 (テキスト) | 小 (テキスト) |
| フレームグラフ | あり (pprof Web UI) | あり (flamegraph.pl) | なし |
| コールグラフ | あり | なし | なし |
| 差分比較 | あり (`rperf diff`) | なし | なし |
| ツール不要 | いいえ (Go 必要) | いいえ (flamegraph.pl 必要) | はい |
| プログラマティックなパース | 複雑 (protobuf) | シンプル | シンプル |
| AI フレンドリー | いいえ | はい | はい |

## 自動検出ルール

| ファイル拡張子 | 形式 |
|----------------|--------|
| `.collapsed` | Collapsed stacks |
| `.txt` | テキストレポート |
| その他 | pprof |

デフォルトの出力ファイル（`rperf.data`）は pprof 形式を使用します。
