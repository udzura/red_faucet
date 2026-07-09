# Ruby メソッドトレーシング Gem "OrangeTap" 実装プラン

## 1. 目的

Rubyプロセス内のメソッド呼び出し（call/return）を `TracePoint` でフックし、
同一プロセス内のバックグラウンドスレッドで非同期に Span へ組み立て、
OpenTelemetry(OTel) 形式の JSON ファイルとして出力する Pure Ruby gem を作成する。

**中央デーモンプロセス・共有メモリ・プロセス間通信は一切使用しない。**

- 対象OS: 制約なし（Pure Ruby 実装）。
- 対象Ruby: MRI (CRuby) 4.0 系を主対象として開発・テストする。
  `TracePoint#enable(target:)` は 2.6+、`Data.define` は 3.2+ で利用可能なため、
  gemspec の `required_ruby_version` は `>= 3.2.0` とする（＝ 3.2 以降で動作するが、
  CI での検証は 4.0 系を主とする）。C レベル `trace_func` の既知バグ回避のため
  意図的に Ruby レベル `TracePoint` を採用する点は README に明記する。

---

## 2. この改訂で確定した設計判断（旧「残課題」の解決）

精査の結果、旧 DESIGN.md の前提のうち **「既存の payload→OTel 変換実装をそのまま流用する」
が実態と食い違っていた**ため、以下を確定した。

1. **OTel 変換は自己完結の内蔵 Writer とする（Vivarium 非依存）。**
   - Vivarium の `OtelExporter`（`lib/vivarium/otel_exporter.rb`）は「1 Span → 1 OTel Span」の
     変換器ではなく、**BPF イベントストリーム全体 + meta を受け取り、Span 組み立て（CALL/RETURN
     スタック管理）を内部でやり直す**構造で、`ev.ktime_ns / ev.tid / ev.trace_hi` や
     `Vivarium.synth_span_id`、BPF ペイロードのバイナリデコード等に密結合している。
     OrangeTap の Worker と役割が重複し、そのままでは呼び出せない。
   - よって **OTLP/JSON の出力フォーマット規約のみを踏襲**し、OrangeTap 内に
     `OrangeTap::OtelConverter` を新規実装する。`vivarium` gem への依存は持たない
     （Pure Ruby・OS 非依存という目的と矛盾するため）。
   - 将来の差し替えのため、`OrangeTap.config.otel_converter` で変換器を注入できる
     アダプタ継ぎ目（seam）を用意する（デフォルトは `OrangeTap::OtelConverter`）。

2. **Span 階層はセッションroot + スレッド + メソッドの3層とする（Vivarium と同型）。**
   - 1 セッション = 1 トレース（`trace_id` はセッションごとに 1 個生成）。
   - `session root span` を 1 個、`thread span`（tid ごと）を 0..N 個、その配下に
     `method span` を配置する。トップレベルのメソッドはそのスレッドの thread span を親とし、
     `parent` の付かない孤立 root が複数生じないようにする。

3. **gem 名は `orange_tap`（末尾アンダースコアなし）に統一する。**
   - 現状スキャフォールドは `orange_tap_` になっており、実装前に rename する（§8）。

4. **時刻は「セッション開始時の壁時計 unix ns」でアンカーして OTLP の絶対時刻に変換する。**
   - フック内では `Process.clock_gettime(CLOCK_MONOTONIC, :nanosecond)` のみを記録し（安価・単調）、
     セッション開始時に一度だけ `CLOCK_MONOTONIC` と `CLOCK_REALTIME`（＝壁時計 unix ns）を
     同時取得してアンカーとする。OTLP 出力時に
     `unix_ns = start_unix_ns + (mono_ns - start_mono_ns)` で換算する。
     （旧 DESIGN は monotonic ns をそのまま出力する想定で、OTel の絶対時刻が不正になる欠陥があった。）

5. **スレッドをまたぐ非同期処理（`Thread.new`/`Fiber`/`Ractor`）の親子関係追跡は本バージョンではスコープ外。**
   - `thread_id` 単位のスタックで完結させる。将来 `Thread.current[:orange_tap_parent_span_id]`
     等での伝播を検討（§9）。

6. **Worker 例外は `Thread#value` の標準動作（再送出）に委ねる。**
   - ただし `stop` は「TracePoint の disable → Queue close → `Thread#value`」の順で行い、
     Worker が途中で例外を投げても **TracePoint は必ず先に disable 済み**になるようにする
     （フックのリークを防ぐ）。

7. **並行セッションの二重フックオーバーヘッドは v1 では許容し、README に明記する。**
   - 各セッションが独立した TracePoint 群を持つため、同一メソッドを複数セッションが対象にすると
     そのメソッドに複数 TracePoint が enable される。v1 はシンプルさを優先し許容する。

---

## 3. アーキテクチャ全体像

```
┌──────────────────────────────────────────────────────────────┐
│  監視対象 Rubyプロセス（1プロセス内で完結・中央デーモンなし）             │
│                                                                │
│  OrangeTap.trace_method(method_obj)   ← 静的登録: 対象メソッドのISeq  │
│       │                                                        │
│  tape = OrangeTap.open  /  OrangeTap.open do ... end           │
│       │  (open時にアンカー時刻取得 → trace_id生成 → Worker起動)        │
│       ▼                                                        │
│  TracePoint(:call,:return).enable(target: iseq)  ×対象ISeq個数    │
│       │  フック内: Event(Data) を1個生成し Queue へ push するのみ       │
│       ▼                                                        │
│  Thread::Queue（セッション専用・スレッドセーフFIFO）                   │
│       ▼                                                        │
│  Worker スレッド（セッション専用）                                    │
│    - tid 単位で CALL/RETURN スタック管理 → PendingSpan 生成          │
│    - Queue#close で終了 → dangling span を強制クローズ               │
│    - session root / thread / method の3層 Span を OtelConverter へ  │
│    - OTLP/JSON を1ファイルに書き出し、そのパスを run の戻り値に          │
│       ▼                                                        │
│  tape.stop / open{...} の戻り値 = 出力JSONファイルパス(String)        │
└──────────────────────────────────────────────────────────────┘
```

**設計の核心：** `open` のたびにセッション専用の `Queue` と `Worker` スレッドを新規生成する。
これにより「どのイベントがどのセッションに属するか」のタグ付け（旧設計の `session_id`）が不要になり、
**Queue インスタンス自体がセッション境界**を表す。`stop` は `Queue#close` を終端シグナルにし、
`Thread#value` で Worker の完了（Span 確定・JSON 書き出し完了）を待って戻り値（パス）を得る。

---

## 4. コンポーネント詳細

### 4.1 Event（軽量・イミュータブル） — `lib/orange_tap/event.rb`

```ruby
module OrangeTap
  # フック内で1個だけ生成する軽量イベント。tp.binding / tp.parameters は取得しない。
  # defined_class は Module 参照をそのまま持ち、文字列化は Worker 側で行う（フックを軽く保つ）。
  Event = Data.define(:type, :thread_id, :method_id, :defined_class, :timestamp_ns)
  # type: :call | :return
end
```

- `timestamp_ns` は `Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)`。
- `thread_id` は `Thread.current.object_id`（C レベル・安価。生存中スレッドの識別には十分）。

### 4.2 対象メソッド登録 — `lib/orange_tap/method_registry.rb`

公開 API（`OrangeTap` トップレベルに委譲メソッドを置く）:

```ruby
OrangeTap.trace_method(SomeClass.instance_method(:foo))  # インスタンスメソッド(UnboundMethod)
OrangeTap.trace_method(SomeClass.method(:bar))           # クラス/特異メソッド(Method)
OrangeTap.trace_method(obj.method(:baz))                 # 特定オブジェクトの特異メソッド(Method)
OrangeTap.trace_all_instance_methods(SomeClass)          # klass.instance_methods(false) を一括
OrangeTap.untrace_method(SomeClass.instance_method(:foo))
```

要点:

- 引数は `Method` / `UnboundMethod` を **1 個直接**受け取る（`(klass, name)` 2 引数にしない）。
  これにより特異メソッドも統一 I/F で登録できる。いずれでもなければ `ArgumentError`。
- ISeq は `RubyVM::InstructionSequence.of(method_obj)` で取得。取得できない
  （C 実装メソッド等）場合は `OrangeTap::UntraceableMethodError`。
- **登録キーはメソッドとしての同一性で作る**（Method/UnboundMethod は呼び出しごとに別オブジェクト）。
  キー = `[method_obj.owner, method_obj.name]`。
  - インスタンスメソッド: owner はクラス/モジュール。
  - クラスメソッド: owner は `#<Class:SomeClass>`（特異クラス）。
  - 特定オブジェクトの特異メソッド: owner はそのオブジェクトの特異クラス（オブジェクトごとに別）。
  いずれも `[owner, name]` で一意に識別・解除できる。
- レジストリは `{ key => iseq }` を保持。`untrace_method` は同じキーで削除。重複登録は upsert で吸収。
- `OrangeTap.default_registry` はプロセスグローバル。登録・解除は `Mutex` で保護する。
  `open` 時に `targets`（＝ ISeq の配列）のスナップショットを取り、以後そのセッションは固定。

```ruby
module OrangeTap
  class MethodRegistry
    def initialize
      @entries = {}          # [owner, name] => iseq
      @mutex = Mutex.new
    end

    def register(method_obj)
      unless method_obj.is_a?(Method) || method_obj.is_a?(UnboundMethod)
        raise ArgumentError, "Method / UnboundMethod を渡してください: #{method_obj.inspect}"
      end
      iseq = RubyVM::InstructionSequence.of(method_obj)
      raise OrangeTap::UntraceableMethodError, method_obj.inspect unless iseq
      @mutex.synchronize { @entries[key_for(method_obj)] = iseq }
    end

    def unregister(method_obj)
      @mutex.synchronize { @entries.delete(key_for(method_obj)) }
    end

    def register_all_instance_methods(klass)
      klass.instance_methods(false).each { |m| register(klass.instance_method(m)) }
    end

    def targets  # ISeq のスナップショット
      @mutex.synchronize { @entries.values.dup }
    end

    private

    def key_for(m) = [m.owner, m.name]
  end
end
```

### 4.3 セッション制御 — `lib/orange_tap/session.rb` と `lib/orange_tap.rb`

公開 API:

```ruby
# ブロック形式（内部でインスタンス形式を利用するシンタックスシュガー）
path = OrangeTap.open do
  # この区間の CALL/RETURN が1セッションとして記録される
end
# => 出力JSONファイルパス(String)

# インスタンス形式
tape = OrangeTap.new     # OrangeTap.new は Session.new を返すモジュールメソッド
tape.open
# ...
path = tape.stop         # => 出力JSONファイルパス(String)
```

トップレベル（`lib/orange_tap.rb`）:

```ruby
module OrangeTap
  class Error < StandardError; end
  class AlreadyOpenError < Error; end
  class NotOpenError < Error; end
  class UntraceableMethodError < Error; end

  module_function

  def new(**opts) = Session.new(**opts)                 # tape = OrangeTap.new
  def default_registry = (@default_registry ||= MethodRegistry.new)
  def config = (@config ||= Config.new)

  def trace_method(m)              = default_registry.register(m)
  def untrace_method(m)            = default_registry.unregister(m)
  def trace_all_instance_methods(k)= default_registry.register_all_instance_methods(k)

  def open(&block)
    tape = new
    tape.open
    return tape unless block
    begin
      block.call
      tape.stop                    # 正常時: パスを返す
    rescue Exception => e          # 異常時: 後始末してから元例外を再送出
      tape.stop rescue nil         # TracePoint の disable を必ず実行（パスは失われてよい）
      raise e
    end
  end
end
```

`Session`:

```ruby
module OrangeTap
  class Session
    def initialize(registry: OrangeTap.default_registry, config: OrangeTap.config)
      @registry = registry
      @config = config
      @queue = nil
      @worker = nil
      @tracepoints = nil
    end

    def open
      raise AlreadyOpenError if @queue

      # セッション開始アンカー: monotonic と wall-clock を同時取得
      start_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      start_unix = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      trace_id = SecureRandom.hex(16)   # 16バイト = 32 hex

      @queue = Thread::Queue.new
      # 対象 ISeq ごとに TracePoint を1個生成（1 TP に複数 target を混ぜない）
      @tracepoints = @registry.targets.map { |iseq| build_tracepoint(iseq, @queue) }

      worker_ctx = Worker::Context.new(
        queue: @queue, config: @config, trace_id: trace_id,
        start_mono_ns: start_mono, start_unix_ns: start_unix
      )
      @worker = Thread.new(worker_ctx) { |ctx| Worker.new(ctx).run }

      @tracepoints.each(&:enable)   # target: は生成時に紐付け済み
      self
    end

    def stop
      raise NotOpenError unless @queue
      @tracepoints.each(&:disable)  # 1) 先にフックを止める（例外時もリークさせない）
      @queue.close                  # 2) Worker ループの終端シグナル
      path = @worker.value          # 3) Worker 完了を待ち、戻り値(パス)を得る（例外は再送出）
      @queue = nil
      path
    end

    private

    def build_tracepoint(iseq, queue)
      tp = TracePoint.new(:call, :return) do |t|
        # フック内は最小限: 数値/シンボル/Module参照のみで Event を1個作り push
        queue << Event.new(
          type: t.event,                                   # :call | :return
          thread_id: Thread.current.object_id,
          method_id: t.method_id,
          defined_class: t.defined_class,
          timestamp_ns: Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        )
      end
      tp.enable(target: iseq) { }   # 実際の有効化は open 内の each(&:enable) で行うため、
      tp.disable                    # ここでは target 紐付けのみ確定させて即 disable する
      tp
    end
  end
end
```

> 注: `TracePoint#enable(target:)` は「target を紐付けて有効化」する API。上記のように
> `enable(target:)`→`disable` で target を固定してから `open` で一括 enable する方式か、
> あるいは `@tracepoints` を `[tp, iseq]` の組で保持して `open`/`stop` で
> `tp.enable(target: iseq)` / `tp.disable` する方式のいずれか、実装時に安定する方を採用する
> （target 再指定の可否は Ruby バージョン依存の余地があるため、テストで確認する）。

設計ポイント:

- **二重 `open` は `AlreadyOpenError`、未 `open` の `stop` は `NotOpenError`。**（1 インスタンス 1 セッション）
- ブロック形式は例外時も `ensure` 相当で `stop`（＝ disable）を必ず実行。ただし例外時は
  正常なパスを返せないため、**元の例外をそのまま再送出**する（PROMPT 準拠）。
- **並行セッション**は各々独立した Queue/Thread/TracePoint 群を持つため干渉しない。
  グローバル可変状態は `default_registry` と `config` のみで、どちらも読み取りは open 時スナップショット。

### 4.4 Worker — `lib/orange_tap/worker.rb`

```ruby
module OrangeTap
  class Worker
    Context = Data.define(:queue, :config, :trace_id, :start_mono_ns, :start_unix_ns)

    def initialize(ctx)
      @ctx = ctx
      @stacks = Hash.new { |h, k| h[k] = [] }  # thread_id => [PendingSpan,...]
      @thread_spans = {}                        # thread_id => PendingSpan(thread層)
      @completed = []                           # method層の確定 PendingSpan
      @session_span = nil
    end

    # 戻り値: 出力した JSON ファイルのフルパス（Session が Thread#value で受け取る）
    def run
      @session_span = new_session_span
      loop do
        ev = @ctx.queue.pop
        break if ev.nil?            # Queue#close で pop が nil を返したら終了
        case ev.type
        when :call   then on_call(ev)
        when :return then on_return(ev)
        end
      end
      finalize_dangling
      write_json
    end

    private

    def on_call(ev)
      ts = thread_span_for(ev.thread_id)
      stack = @stacks[ev.thread_id]
      parent_id = stack.empty? ? ts.span_id : stack.last.span_id
      span = PendingSpan.new(
        span_id: SecureRandom.hex(8),                 # 8バイト = 16 hex
        parent_span_id: parent_id,
        name: method_name(ev.defined_class, ev.method_id),
        thread_id: ev.thread_id,
        start_mono_ns: ev.timestamp_ns
      )
      stack.push(span)
    end

    def on_return(ev)
      span = @stacks[ev.thread_id].pop
      return unless span            # 対応 CALL が無い RETURN は無視（エラーにしない）
      span.end_mono_ns = ev.timestamp_ns
      @completed << span
    end

    def finalize_dangling
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      @stacks.each_value do |stack|
        while (span = stack.pop)
          span.end_mono_ns ||= now
          span.incomplete = true    # RETURN 未着を明示（OTel 属性に反映）
          @completed << span
        end
      end
    end

    def thread_span_for(tid)
      @thread_spans[tid] ||= PendingSpan.new(
        span_id: SecureRandom.hex(8),
        parent_span_id: @session_span.span_id,
        name: "tid=#{tid}",
        thread_id: tid,
        start_mono_ns: @ctx.start_mono_ns   # end は finalize 時に確定
      )
    end

    def new_session_span
      PendingSpan.new(
        span_id: SecureRandom.hex(8),
        parent_span_id: nil,                 # ルート（parentSpanId 省略）
        name: "orange_tap session",
        thread_id: nil,
        start_mono_ns: @ctx.start_mono_ns
      )
    end

    # クラスメソッド(特異クラス)は "Owner.method"、それ以外は "Owner#method"
    def method_name(defined_class, method_id)
      if defined_class.respond_to?(:singleton_class?) && defined_class.singleton_class?
        owner = defined_class.inspect[/#<Class:(.+)>/, 1] || defined_class.inspect
        "#{owner}.#{method_id}"
      else
        "#{defined_class}##{method_id}"
      end
    end

    def write_json
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      @session_span.end_mono_ns = now
      @thread_spans.each_value { |ts| ts.end_mono_ns ||= now }

      spans = [@session_span, *@thread_spans.values, *@completed]
      converter = @ctx.config.otel_converter        # 差し替え可能な継ぎ目
      document = converter.build_document(
        spans: spans,
        trace_id: @ctx.trace_id,
        start_mono_ns: @ctx.start_mono_ns,
        start_unix_ns: @ctx.start_unix_ns,
        service_name: @ctx.config.service_name
      )
      FileUtils.mkdir_p(@ctx.config.output_dir)
      path = File.join(@ctx.config.output_dir,
                       "orange_tap-#{Time.now.to_i}-#{SecureRandom.hex(4)}.json")
      File.write(path, JSON.generate(document))
      path
    end
  end
end
```

### 4.5 PendingSpan（中間表現） — `lib/orange_tap/pending_span.rb`

```ruby
module OrangeTap
  # モノトニック ns で保持する組み立て中の Span。OTLP への時刻換算は OtelConverter が行う。
  class PendingSpan
    attr_accessor :span_id, :parent_span_id, :name, :thread_id,
                  :start_mono_ns, :end_mono_ns, :incomplete
    def initialize(span_id:, parent_span_id:, name:, thread_id:, start_mono_ns:, end_mono_ns: nil)
      @span_id = span_id; @parent_span_id = parent_span_id; @name = name
      @thread_id = thread_id; @start_mono_ns = start_mono_ns; @end_mono_ns = end_mono_ns
      @incomplete = false
    end
  end
end
```

### 4.6 OtelConverter（自己完結の内蔵 Writer） — `lib/orange_tap/otel_converter.rb`

Vivarium の OTLP/JSON フォーマット規約（`resourceSpans → scopeSpans → spans`、`traceId`=32hex・
`spanId`=16hex、時刻は文字列 nano、属性は `{key,value:{stringValue|intValue|boolValue}}`）を踏襲した
**新規・自己完結実装**。`vivarium` gem には依存しない。差し替えられるよう `config.otel_converter`
で注入する（デフォルトが本モジュール）。

インターフェース（Worker から呼ばれる契約）:

```ruby
module OrangeTap
  module OtelConverter
    SPAN_KIND_INTERNAL = 1
    module_function

    # spans: Array<PendingSpan>（session/thread/method 混在、mono ns 保持）
    # 戻り値: JSON.generate 可能な OTLP/JSON ドキュメント(Hash)
    def build_document(spans:, trace_id:, start_mono_ns:, start_unix_ns:, service_name:)
      to_unix = ->(mono) { (start_unix_ns + (mono.to_i - start_mono_ns.to_i)).to_s }
      otlp_spans = spans.map { |s| span_hash(s, trace_id, to_unix) }
      {
        resourceSpans: [{
          resource: { attributes: [str_attr("service.name", service_name)] },
          scopeSpans: [{
            scope: { name: service_name, version: OrangeTap::VERSION },
            spans: otlp_spans
          }]
        }]
      }
    end

    def span_hash(s, trace_id, to_unix)
      attrs = []
      attrs << int_attr("thread.id", s.thread_id) if s.thread_id
      attrs << bool_attr("orange_tap.incomplete", true) if s.incomplete
      h = {
        traceId: trace_id,
        spanId: s.span_id,
        name: s.name,
        kind: SPAN_KIND_INTERNAL,
        startTimeUnixNano: to_unix.call(s.start_mono_ns),
        endTimeUnixNano: to_unix.call(s.end_mono_ns),
        attributes: attrs
      }
      h[:parentSpanId] = s.parent_span_id if s.parent_span_id
      h
    end

    def str_attr(k, v)  = { key: k, value: { stringValue: v.to_s } }
    def int_attr(k, v)  = { key: k, value: { intValue: v.to_i.to_s } }
    def bool_attr(k, v) = { key: k, value: { boolValue: !!v } }
  end
end
```

> `trace_id`(32hex) / `span_id`(16hex) は `SecureRandom.hex` で最初から hex 文字列として
> 生成するため、Vivarium のような int→hex 変換（`synth_span_id`/`hex16`）は不要。

### 4.7 Config — `lib/orange_tap/config.rb`

```ruby
module OrangeTap
  class Config
    attr_accessor :output_dir, :service_name, :otel_converter
    def initialize
      @output_dir     = File.join(Dir.tmpdir, "orange_tap")  # 書き出し先（存在しなければ mkdir_p）
      @service_name   = "orange_tap"
      @otel_converter = OrangeTap::OtelConverter             # 差し替え可能な継ぎ目
    end
  end
end
```

- 出力ファイルの保持・削除は呼び出し側に委ねる（gem 側で自動削除しない）。

---

## 5. ディレクトリ構造（Pure Ruby / ext なし）

```
orange_tap/
├── orange_tap.gemspec
├── lib/
│   ├── orange_tap.rb                 # トップレベルAPI + require + 例外クラス
│   └── orange_tap/
│       ├── version.rb
│       ├── config.rb
│       ├── event.rb
│       ├── method_registry.rb
│       ├── session.rb
│       ├── worker.rb
│       ├── pending_span.rb
│       └── otel_converter.rb
├── sig/orange_tap.rbs
├── test/                             # 既存スキャフォールド(minitest)を踏襲
└── README.md
```

- 依存: 標準ライブラリのみ（`json`, `securerandom`, `tmpdir`, `fileutils`, `time`）。外部 gem 依存なし。

---

## 6. テスト計画（PROMPT 準拠、minitest）

1. `trace_method` で登録した対象メソッド呼び出しがイベントとして捕捉される。
2. インスタンスメソッド／クラス（特異）メソッド／特定オブジェクトの特異メソッドを
   `trace_method(obj.method(:foo))` 等で登録・捕捉できる。
3. 未登録メソッドは捕捉されない（`target:` で絞られている）。
4. `OrangeTap.open do...end` がパス(String)を返し、ファイルが実在し、妥当な JSON である
   （`resourceSpans` を含む OTLP 構造・`traceId`=32桁・`spanId`=16桁を検証）。
5. 二重 `open` → `AlreadyOpenError`。
6. 未 `open` の `stop` → `NotOpenError`。
7. ブロック内例外時も TracePoint が確実に disable される（後続テストに影響しない）。
8. 再帰・ネスト呼び出しで CALL/RETURN 対応付けが正しい（parent 関係の検証）。
9. RETURN 未着（強制終了）ケースで `orange_tap.incomplete=true` の Span が出力される。
10. 複数インスタンスの並行 `open` が互いに干渉しない（別ファイル・別 trace_id）。
11. `UntraceableMethodError`（C 実装メソッド登録時）と `ArgumentError`（非 Method 引数）。
12. `untrace_method` が別オブジェクト由来の同一メソッドでも解除できる（`[owner, name]` キー）。

補足: TracePoint の非同期性のため、`stop`（＝ `Thread#value` で Worker 完了を待つ）後に
アサートする。フックは stop 内で必ず disable されるので、テスト間のフック残留は起きない。

---

## 7. README に明記する事項

- C レベル(`rb_add_event_hook`/`trace_func`)ではなく Ruby レベル `TracePoint` を採用した理由
  （Ruby 4.0 の C レベル `trace_func` 既知バグの回避）。
- 中央デーモンを持たず、プロセス内 Thread + Queue で完結する設計。複数プロセス横断の
  Trace 相関はスコープ外。
- `open`/`stop` ごとに専用 Queue/Thread を生成する設計思想（`session_id` タグ付けが不要になる理由）。
- スレッドをまたぐ非同期処理の親子関係追跡は非対応。
- 並行セッションが同一メソッドを対象にすると二重フックのオーバーヘッドが生じ得る点。
- Worker 内例外は `Thread#value` 経由で `stop` 呼び出し元に再送出される（ただし TracePoint は
  必ず先に disable 済み）。
- OTLP 変換は自己完結実装であり、`config.otel_converter` で差し替え可能なこと。

---

## 8. gem 名 rename（実装着手前の作業）

`orange_tap_` → `orange_tap` に統一する。対象:

- `orange_tap_.gemspec` → `orange_tap.gemspec`（`spec.name` / `require_relative` パス / TODO メタ情報の記入）
- `lib/orange_tap_.rb` → `lib/orange_tap.rb`
- `lib/orange_tap_/` → `lib/orange_tap/`（配下 `version.rb` 等）
- `sig/orange_tap_.rbs` → `sig/orange_tap.rbs`
- `test/orange_tap__test.rb` → `test/orange_tap_test.rb`、`test/test_helper.rb` の require 修正
- `Rakefile` / `bin/console` 等に `orange_tap_` 参照があれば修正
- モジュール名 `OrangeTap` は変更不要（既に一致）。

---

## 9. 実装時に判明した既知の制約

- **`define_method`/ブロックベースで定義したメソッドは `trace_method` の対象外。**
  `RubyVM::InstructionSequence.of` は取得できる（`nil` にならない）が、そのISeqは
  `:block` タイプであり、`TracePoint#enable(target:)` に渡すと
  `ArgumentError: can not enable any hooks` になる（Ruby 4.0.5 で確認）。
  現状は `UntraceableMethodError` 等で明示的に弾いておらず、`enable` 時に例外化するため、
  README にこの制約を明記し、対象は `def` で定義された通常のメソッドに限定する。
  ブロックベースメソッドの検出・早期エラー化は将来課題とする。

## 10. 将来課題（v1 スコープ外・明示的に先送り）

- `define_method`/ブロックベースメソッドを `register` 時点で検出し、
  `UntraceableMethodError` を送出する（現状は `open` 時の `enable` で初めて失敗する）。
- スレッド／Fiber／Ractor をまたぐ非同期処理の親子関係伝播
  （`Thread.current[:orange_tap_parent_span_id]` 等の context 伝播）。
- 並行セッションで同一メソッドを共有する場合の二重フック解消
  （registry をセッション間共有しフック内で振り分ける方式。ただし「どのセッションに属すか」の
  判定ロジックが再び必要になり、現行のシンプルさとのトレードオフ）。
- OTLP/HTTP エクスポート（現状はファイル出力のみ。`otel_converter` 差し替え or 別 exporter で拡張可）。
- code.filepath / code.lineno 等の属性付与（フックを軽く保つ方針との兼ね合いで v1 は見送り）。

---

## 11. 参考

- 既存実装（Vivarium）: `file:///Users/uchio.kondo/ghq/github.com/udzura/vivarium`
  - OTLP/JSON フォーマット規約の参照元は `lib/vivarium/otel_exporter.rb`
    （ただし前述の通り密結合のため**コードは流用せず、フォーマットのみ踏襲**）。
