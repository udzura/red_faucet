# Cメソッド対応 TODO（グローバル有効化＋フック内フィルタ方式）

## 背景

現状、`MethodRegistry#register`は`RubyVM::InstructionSequence.of(method_obj)`が
`nil`を返すメソッド（Cレベル実装のメソッド）を`OrangeTap::UntraceableMethodError`で
拒否する。これは`TracePoint#enable(target: iseq)`によるスコープ限定がISeqに依存して
おり、ISeqを持たないCメソッドには原理的に使えないため（`:c_call`/`:c_return`イベント
でも同様。`enable(target:)`は常に`ArgumentError: specified target is not supported`）。

一方、`target:`を付けずグローバルに`TracePoint.new(:c_call, :c_return).enable`すれば
Cメソッド呼び出し自体は捕捉できる。ただしフック内で対象メソッドかどうかを都度判定する
必要があり、「未対象メソッドはフックオーバーヘッドゼロ」という現行の設計原則
（DESIGN.md §4.2, §7）を崩す。この対応は**デフォルトでは無効・明示オプトイン**として
追加することを前提に、変更箇所を洗い出す。

## 方針概要

- 既存の`target:`スコープ方式（ISeq限定・低オーバーヘッド）はそのまま維持する。
- Cメソッドは「オプトインの別経路」として追加する。デフォルト動作
  （Cメソッド登録 = `UntraceableMethodError`）は変えない。
- 1セッションにつき、Cメソッド用のグローバル`TracePoint(:c_call, :c_return)`を
  **高々1個**追加で持ち、フック内で登録済み`[owner, name]`集合との照合を行う。

## 変更が必要な箇所

### 1. `lib/orange_tap/config.rb`

- Cメソッド対応をオプトインするフラグを追加する（例: `trace_c_methods`、デフォルト
  `false`）。もしくは`trace_method`とは別の明示APIにするかは「未決事項」参照。

### 2. `lib/orange_tap/method_registry.rb`

- `register_one`: `RubyVM::InstructionSequence.of`が`nil`を返した場合、現状は即座に
  `UntraceableMethodError`だが、opt-inが有効なら例外にせず`@c_entries`
  （`Set<[owner, name]>`）に登録する分岐を追加する。
- `targets`（既存、ISeqの配列を返す）とは別に、Cメソッド用の`c_targets`
  （`[owner, name]`の集合）を返すアクセサを追加する。
- `unregister_one`も両方の格納先（`@entries` / `@c_entries`）から削除できるようにする。
- `key_for`は`method_obj.owner` / `method_obj.name`ベースで既にCメソッドにも通用する
  ため変更不要。

### 3. `lib/orange_tap/session.rb`

- `open`: `@registry.targets`によるISeqベースの`TracePoint`群構築は現状通り。
- `@registry.c_targets`が空でなければ、追加でグローバル`TracePoint(:c_call, :c_return)`
  を1個構築し、`target:`を指定せず`enable`する。
  - フック内では`[tp.defined_class, tp.method_id]`が`c_targets`集合に含まれる場合のみ
    `Event`を`queue`にpushする（含まれなければ何もしない）。
- `stop`: このグローバル`TracePoint`も他の`TracePoint`と同様に必ず`disable`する。
  実装上は`@tracepoint_targets`に`[tp, nil]`（iseqなし）として混在させ、
  `enable`時に`iseq.nil?`なら`tp.enable`（グローバル）、そうでなければ
  `tp.enable(target: iseq)`と分岐させるのが単純。

### 4. `lib/orange_tap/event.rb` / `lib/orange_tap/worker.rb`

- フック内で`tp.event`が`:c_call`/`:c_return`の場合は`:call`/`:return`に正規化して
  `Event#type`に詰める（Worker側の`case event.type`をシンプルに保つため）。
- `Worker#on_call` / `#on_return` / `#method_name`は`defined_class` /
  `method_id`ベースで判定しており、呼び出し元がRubyコードかCコードかを区別しない
  ため、**これ自体の変更は不要**と見込まれる。

### 5. ドキュメント

- README / DESIGN.mdに、Cメソッド対応がオプトインであること、有効化すると
  「登録の有無に関わらずプロセス内の全Cメソッド呼び出しにフックが発火し、その都度
  フィルタ判定が入る」という性能上のトレードオフを明記する。

## 既知のトレードオフ・リスク

- グローバル`:c_call`/`:c_return`は、登録有無に関係なく**プロセス内の全C呼び出し**
  （`Array#each`, `Hash#[]`, `Integer#+`など極めて高頻度なものを含む）に対して発火する。
  「未対象メソッドはオーバーヘッドゼロ」という原則が、Cメソッドを1つでも登録した瞬間に
  グローバルに崩れる。デフォルト無効・明示opt-inとするのはこのため。
- 並行セッション（DESIGN.md §2-7で許容している「同一メソッドの二重フック」）の場合、
  Cメソッド対応セッションが複数同時に開くと、グローバルフックがセッション数だけ重複し、
  ISeq方式より相対的に重いコストが積み重なる。README等に注意書きが必要。
- 特定オブジェクトの特異メソッドとしてのCメソッド（レアケース）が実際に存在し得るか、
  存在する場合`tp.defined_class`ベースの照合で正しく拾えるかは要確認。

## テスト観点（実装時に追加）

1. デフォルト（opt-in無効）ではCメソッド登録が従来通り`UntraceableMethodError`になる
   （既存テストの回帰確認）。
2. opt-in有効時、登録したCメソッドの呼び出しが`:call`/`:return`相当のSpanとして
   出力される。
3. opt-in有効時でも、**登録していない**Cメソッド呼び出しはフィルタされてSpan化
   されない（グローバルフックがノイズを拾わないことの確認）。
4. 並行セッションでそれぞれ独立してフィルタが効く（他セッションの登録内容が混ざらない）。
5. Ruby側メソッド（ISeq方式）とCメソッド（グローバル方式）を同時に登録した場合、
   両方が同じSpanツリーに正しくネストされる。

## 未決事項（要検討）

- 有効化のAPIを`config`フラグにするか、`OrangeTap.trace_method`とは別の明示メソッド
  （例: `OrangeTap.trace_c_method`）にするか。後者の方が「性能特性が違う経路」で
  あることを呼び出し側コードで明示できる利点がある。
- 特定オブジェクトの特異Cメソッドの扱い（上記リスク参照）。
- グローバルフックのフィルタ判定コスト自体（Hash/Setのlookup）が、対象Cメソッドの
  呼び出し頻度によっては無視できない可能性があり、ベンチマークが必要。
