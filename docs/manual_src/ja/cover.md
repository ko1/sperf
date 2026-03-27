# rperf ガイド

![rperf logo](images/logo.svg)

Ruby 向けのセーフポイントベースのサンプリング性能プロファイラ。

rperf は、セーフポイントでサンプリングを行い、実際の時間差分を重みとして使用することでセーフポイントバイアスを補正する Ruby プログラムのプロファイラです。`perf` ライクな CLI、Ruby API を提供し、pprof、collapsed stacks、テキストレポート形式で出力します。

**主な特徴:**

- CPU モードとウォールクロックモード
- セーフポイントバイアスを補正する時間重み付きサンプリング
- GVL 競合と GC フェーズの追跡
- pprof、collapsed stacks、テキスト出力形式
- 低オーバーヘッド (デフォルト 1000 Hz でのサンプリングコールバックコスト < 0.2%)
- Ruby >= 3.4.0、POSIX システム (Linux, macOS) が必要
