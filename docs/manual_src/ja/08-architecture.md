# アーキテクチャ概要

この章では、rperf のハイレベルなアーキテクチャと、プロファイリングを支えるコアデータ構造を説明します。これらの内部構造を理解することで、プロファイリング結果のエッジケースの解釈や設計上のトレードオフの評価に役立ちます。

## システム図

rperf は C 拡張と Ruby ラッパーで構成されています:

```mermaid
graph TD
    subgraph "C 拡張 (ext/rperf/rperf.c)"
        Timer["タイマー<br/>(signal or pthread_cond_timedwait)"]
        PJ["rb_postponed_job_trigger"]
        Sample["サンプルコールバック<br/>(rperf_sample_job)"]
        ThreadHook["スレッドイベントフック<br/>(SUSPENDED/READY/RESUMED/EXITED)"]
        GCHook["GC イベントフック<br/>(ENTER/EXIT/START/END_MARK/END_SWEEP)"]
        BufA["サンプルバッファ A"]
        BufB["サンプルバッファ B"]
        Worker["ワーカースレッド<br/>(timer + aggregation)"]
        FrameTable["フレームテーブル<br/>(VALUE → frame_id)"]
        AggTable["集約テーブル<br/>(stack → weight)"]
    end

    subgraph "Ruby (lib/rperf.rb)"
        API["Rperf.start / Rperf.stop"]
        Encoders["エンコーダー<br/>(PProf / Collapsed / Text)"]
        StatOut["stat 出力"]
    end

    Timer -->|triggers| PJ
    PJ -->|at safepoint| Sample
    Sample -->|writes| BufA
    ThreadHook -->|writes| BufA
    GCHook -->|writes| BufA
    BufA -->|swap when full| BufB
    BufB -->|aggregated by| Worker
    Worker -->|inserts| FrameTable
    Worker -->|inserts| AggTable
    API -->|calls| Sample
    AggTable -->|read at stop| Encoders
    FrameTable -->|resolved at stop| Encoders
    Encoders --> StatOut
```

C 拡張はすべての性能重視の操作（タイマー管理、サンプル記録、集約）を処理します。Ruby レイヤーはユーザー向け API、出力エンコーディング、統計のフォーマットを提供します。

## グローバルプロファイラ状態

rperf は単一のグローバルな `rperf_profiler_t` 構造体を使用します。一度に 1 つのプロファイリングセッションのみ有効です（[単一セッション](#index:single session)制限）。この構造体は以下を保持します:

- タイマー設定（周波数、モード、シグナル番号）
- ダブルバッファリングされたサンプルストレージ（2 つのサンプルバッファ + フレームプール、満杯時にスワップ）
- フレームテーブル（VALUE → uint32 frame_id、フレーム参照の重複排除）
- 集約テーブル（ユニークスタック → 累積重み）
- ワーカースレッドハンドル（統合タイマー + 集約スレッド）
- スレッドごとのデータ用のスレッド固有キー
- GC フェーズ追跡状態
- サンプリングオーバーヘッドカウンター

## スレッドごとのデータ

各スレッドには Ruby のスレッド固有データ API（`rb_internal_thread_specific_set`）で格納される `rperf_thread_data_t` 構造体があります。以下を追跡します:

- `prev_time_ns`: 前回の時刻読み取り（重み計算用）
- `prev_wall_ns`: 前回の wall time 読み取り
- `suspended_at_ns`: スレッドがサスペンドされた wall タイムスタンプ
- `ready_at_ns`: スレッドが準備完了になった wall タイムスタンプ
- `suspended_frame_start`/`depth`: SUSPENDED イベントで保存されたバックトレース
- `label_set_id`: 現在のラベルセット ID（0 = ラベルなし）

スレッドデータは最初の検出時に遅延作成され、`EXITED` イベントまたはプロファイラ停止時に解放されます。

## GC 安全性

フレーム VALUE はガベージコレクションから保護する必要があります。rperf はプロファイラ構造体を `TypedData` オブジェクトでラップし、3 つの領域をマークするカスタム `dmark` 関数を持ちます:

1. **両方のフレームプール**（アクティブバッファとスタンバイバッファ）
2. **フレームテーブルキー**（ユニークフレーム VALUE、合成フレームスロットを除く）

フレームテーブルキー配列は 4,096 エントリから始まり、満杯時に 2 倍に拡張されます。拡張時は新しい配列を確保し、既存データをコピーし、ポインタをアトミックにスワップします（`memory_order_release`）。古い配列は `stop` まで保持され、GC の mark フェーズが同時にそれを読み取っている場合の use-after-free を防ぎます。`dmark` 関数はキーポインタを `memory_order_acquire` でロードし、カウントも `memory_order_acquire` でロードして一貫したビューを保証します。

## Fork 安全性

rperf は fork された子プロセスでプロファイリングを静かに停止する `pthread_atfork` 子ハンドラを登録します（[fork 安全性](#index:fork safety)）:

- タイマー/シグナル状態をクリア
- イベントフックを削除
- サンプルバッファ、フレームテーブル、集約テーブルを解放

親プロセスは影響を受けずにプロファイリングを継続します。子プロセスは必要に応じて新しいプロファイリングセッションを開始できます。

## 既知の制限事項

### Running EC レース

Ruby VM には、タイマースレッドからの `rb_postponed_job_trigger` が誤ったスレッドの実行コンテキストに割り込みフラグを設定してしまう既知のレース条件があります。これは、新しいスレッドのネイティブスレッドが GVL を取得する前に開始された場合に発生します。結果として、C のビジーウェイトを行っているスレッドのタイマーサンプルが欠落し、その CPU 時間が次の SUSPENDED イベントのスタックに漏れ出す可能性があります。

これは rperf のバグではなく Ruby VM のバグであり、すべての postponed job ベースのプロファイラに影響します。

### 単一セッション

グローバルプロファイラ状態のため、一度に 1 つのプロファイリングセッションのみ有効です。プロファイリング中に `Rperf.start` を呼び出すことはサポートされていません。

### メソッドレベルの粒度

rperf はメソッドレベルでプロファイルし、行レベルではありません。フレームラベルは修飾名（例: `Integer#times`、`MyClass#method_name`）に `rb_profile_frame_full_label` を使用します。行番号は含まれません。
