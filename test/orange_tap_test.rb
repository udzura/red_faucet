# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"

class Sample
  def self.reset_calls!
    @calls = []
  end

  def self.calls
    @calls ||= []
  end

  def instance_method_a
    self.class.calls << :instance_method_a
    "a"
  end

  def not_traced_method
    self.class.calls << :not_traced_method
    "untraced"
  end

  # Calls a C-implemented method (String#upcase) so that, when both are
  # registered, the C span nests directly under this Ruby span.
  def calls_c_method
    self.class.calls << :calls_c_method
    "z".upcase
  end

  def self.class_method_b
    calls << :class_method_b
    "b"
  end

  def recursive(depth)
    self.class.calls << :"recursive_#{depth}"
    return depth if depth <= 0

    recursive(depth - 1)
  end

  # Defined with `def`, not define_method/a block, so its ISeq is a plain
  # :method-type ISeq that TracePoint#enable(target:) can target. Used to
  # simulate a call that is still in progress when a session stops.
  def blocking(entered, release)
    self.class.calls << :blocking
    entered << true
    release.pop
    1
  end

  # Calls a core-internal Ruby method (Array#last, defined at
  # "<internal:array>") and a C method (String#upcase). Used to verify that
  # trace_all_app_methods mode excludes both kinds of built-in.
  def uses_builtins
    [1, 2, 3].last
    "z".upcase
  end

  # define_method-defined: cannot be targeted by TracePoint#enable(target:),
  # but is still captured by the global :call hook in trace_all_app_methods
  # mode.
  define_method(:defined_via_dm) { 42 }
end

class OrangeTapTest < Test::Unit::TestCase
  def setup
    Sample.reset_calls!
    OrangeTap.default_registry.unregister(Sample.instance_method(:instance_method_a))
    OrangeTap.default_registry.unregister(Sample.instance_method(:not_traced_method))
    OrangeTap.default_registry.unregister(Sample.method(:class_method_b))
    OrangeTap.default_registry.unregister(Sample.instance_method(:recursive))
    OrangeTap.default_registry.unregister(Sample.instance_method(:blocking))
    OrangeTap.default_registry.unregister(Sample.instance_method(:calls_c_method))
    # C-method opt-in is a global flag / registry; reset it and drop any C
    # entries so these tests don't leak into the ISeq-based ones.
    OrangeTap.config.trace_c_methods = false
    OrangeTap.config.trace_all_app_methods = false
    OrangeTap.untrace_method(String.instance_method(:upcase), Array.instance_method(:sort))
    @tmpdir = Dir.mktmpdir("orange_tap_test")
    OrangeTap.config.output_dir = @tmpdir
  end

  def teardown
    OrangeTap.config.trace_c_methods = false
    OrangeTap.config.trace_all_app_methods = false
    OrangeTap.untrace_method(String.instance_method(:upcase), Array.instance_method(:sort))
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def read_document(path)
    JSON.parse(File.read(path))
  end

  def all_spans(document)
    document.fetch("resourceSpans").flat_map do |rs|
      rs.fetch("scopeSpans").flat_map { |ss| ss.fetch("spans") }
    end
  end

  test "VERSION" do
    assert do
      ::OrangeTap.const_defined?(:VERSION)
    end
  end

  test "captures calls to a registered instance method" do
    OrangeTap.trace_method(Sample.instance_method(:instance_method_a))

    path = OrangeTap.open { Sample.new.instance_method_a }
    document = read_document(path)
    names = all_spans(document).map { |s| s["name"] }

    assert_include(names, "Sample#instance_method_a")
  end

  test "captures class (singleton) method calls" do
    OrangeTap.trace_method(Sample.method(:class_method_b))

    path = OrangeTap.open { Sample.class_method_b }
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "Sample.class_method_b")
  end

  test "captures singleton methods on a specific object" do
    obj = Sample.new
    def obj.greet
      "hi"
    end
    OrangeTap.trace_method(obj.method(:greet))

    path = OrangeTap.open { obj.greet }
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert(names.any? { |n| n.end_with?(".greet") })
  ensure
    OrangeTap.default_registry.unregister(obj.method(:greet)) if obj
  end

  test "does not capture unregistered methods" do
    OrangeTap.trace_method(Sample.instance_method(:instance_method_a))

    path = OrangeTap.open do
      sample = Sample.new
      sample.instance_method_a
      sample.not_traced_method
    end
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "Sample#instance_method_a")
    assert_not_include(names, "Sample#not_traced_method")
  end

  test "open returns a path to a valid OTLP JSON document" do
    OrangeTap.trace_method(Sample.instance_method(:instance_method_a))

    path = OrangeTap.open { Sample.new.instance_method_a }

    assert_kind_of(String, path)
    assert(File.exist?(path))
    document = read_document(path)
    assert(document.key?("resourceSpans"))
    spans = all_spans(document)
    assert(spans.all? { |s| s["traceId"].match?(/\A[0-9a-f]{32}\z/) })
    assert(spans.all? { |s| s["spanId"].match?(/\A[0-9a-f]{16}\z/) })
  end

  test "double open raises AlreadyOpenError" do
    tape = OrangeTap.new
    tape.open
    assert_raise(OrangeTap::AlreadyOpenError) { tape.open }
  ensure
    tape.stop
  end

  test "stop without open raises NotOpenError" do
    tape = OrangeTap.new
    assert_raise(OrangeTap::NotOpenError) { tape.stop }
  end

  test "TracePoints are disabled even when the block raises" do
    OrangeTap.trace_method(Sample.instance_method(:instance_method_a))

    assert_raise(RuntimeError) do
      OrangeTap.open do
        Sample.new.instance_method_a
        raise "boom"
      end
    end

    # A subsequent, unrelated call must not be captured by leftover hooks.
    path = OrangeTap.open { Sample.new.instance_method_a }
    names = all_spans(read_document(path)).map { |s| s["name"] }
    assert_equal(1, names.count("Sample#instance_method_a"))
  end

  test "nested recursive calls produce correctly nested spans" do
    OrangeTap.trace_method(Sample.instance_method(:recursive))

    path = OrangeTap.open { Sample.new.recursive(2) }
    spans = all_spans(read_document(path)).select { |s| s["name"] == "Sample#recursive" }

    assert_equal(3, spans.size)
    by_id = spans.each_with_object({}) { |s, h| h[s["spanId"]] = s }
    root = spans.find { |s| !by_id.key?(s["parentSpanId"]) }
    refute_nil(root)
    children = spans.select { |s| s["parentSpanId"] == root["spanId"] }
    assert_equal(1, children.size)
  end

  test "dangling calls without a matching return are marked incomplete" do
    OrangeTap.trace_method(Sample.instance_method(:blocking))

    entered = Queue.new
    release = Queue.new
    obj = Sample.new
    tape = OrangeTap.new
    tape.open
    caller_thread = Thread.new { obj.blocking(entered, release) }
    entered.pop
    path = tape.stop
    release << true
    caller_thread.join

    spans = all_spans(read_document(path)).select { |s| s["name"] == "Sample#blocking" }
    assert_equal(1, spans.size)
    incomplete_attr = spans.first["attributes"].find { |a| a["key"] == "orange_tap.incomplete" }
    refute_nil(incomplete_attr)
    assert_equal(true, incomplete_attr["value"]["boolValue"])
  end

  test "concurrent sessions do not interfere with each other" do
    OrangeTap.trace_method(Sample.instance_method(:instance_method_a))

    tape_a = OrangeTap.new
    tape_b = OrangeTap.new
    tape_a.open
    tape_b.open
    Sample.new.instance_method_a
    path_a = tape_a.stop
    path_b = tape_b.stop

    assert_not_equal(path_a, path_b)
    doc_a = read_document(path_a)
    doc_b = read_document(path_b)
    trace_id_a = all_spans(doc_a).first["traceId"]
    trace_id_b = all_spans(doc_b).first["traceId"]
    assert_not_equal(trace_id_a, trace_id_b)
  end

  test "trace_method rejects non-Method/UnboundMethod arguments" do
    assert_raise(ArgumentError) { OrangeTap.trace_method(:not_a_method) }
  end

  test "trace_method rejects methods without an ISeq" do
    assert_raise(OrangeTap::UntraceableMethodError) do
      OrangeTap.trace_method(String.instance_method(:upcase))
    end
  end

  test "opt-in: registered C method is captured as a span" do
    OrangeTap.config.trace_c_methods = true
    OrangeTap.trace_method(String.instance_method(:upcase))

    path = OrangeTap.open { "hi".upcase }
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "String#upcase")
  end

  test "opt-in: unregistered C methods are filtered out by the global hook" do
    OrangeTap.config.trace_c_methods = true
    OrangeTap.trace_method(String.instance_method(:upcase))

    path = OrangeTap.open do
      "hi".upcase       # registered -> captured
      "hi".downcase     # unregistered C call -> must be filtered
    end
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "String#upcase")
    assert_not_include(names, "String#downcase")
  end

  test "opt-in: Ruby (ISeq) and C methods nest in the same span tree" do
    OrangeTap.config.trace_c_methods = true
    OrangeTap.trace_method(
      Sample.instance_method(:calls_c_method),
      String.instance_method(:upcase)
    )

    path = OrangeTap.open { Sample.new.calls_c_method }
    spans = all_spans(read_document(path))

    outer = spans.find { |s| s["name"] == "Sample#calls_c_method" }
    inner = spans.find { |s| s["name"] == "String#upcase" }
    refute_nil(outer)
    refute_nil(inner)
    # The C span (upcase) is called inside the Ruby span, so it must be a
    # direct child of it.
    assert_equal(outer["spanId"], inner["parentSpanId"])
  end

  test "opt-in: singleton C method on a specific object is skipped with a warning" do
    OrangeTap.config.trace_c_methods = true
    str = +"hello"
    # Bind a C-implemented method into the object's singleton class: ISeq-less,
    # owner is the object's singleton class (attached_object is not a Module).
    str.singleton_class.send(:define_method, :c_singleton, String.instance_method(:upcase))

    warning = capture_warning { OrangeTap.trace_method(str.method(:c_singleton)) }

    assert_match(/singleton C method/, warning)
    assert(OrangeTap.default_registry.c_targets.empty?)
  end

  test "trace_all_app_methods: app methods are traced without explicit registration" do
    OrangeTap.config.trace_all_app_methods = true

    path = OrangeTap.open { Sample.new.instance_method_a }
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "Sample#instance_method_a")
  end

  test "trace_all_app_methods: built-in methods (C and core-internal) are excluded" do
    OrangeTap.config.trace_all_app_methods = true

    path = OrangeTap.open { Sample.new.uses_builtins }
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "Sample#uses_builtins")
    # String#upcase is C (never fires :call); Array#last is defined at
    # "<internal:array>" (fires :call, excluded by the "<" path rule).
    assert_not_include(names, "String#upcase")
    assert_not_include(names, "Array#last")
  end

  test "trace_all_app_methods: define_method-defined methods are traced" do
    OrangeTap.config.trace_all_app_methods = true

    path = OrangeTap.open { Sample.new.defined_via_dm }
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "Sample#defined_via_dm")
  end

  test "trace_all_app_methods: OrangeTap's own code is not traced and writes valid output" do
    OrangeTap.config.trace_all_app_methods = true

    path = OrangeTap.open { Sample.new.instance_method_a }
    document = read_document(path)
    names = all_spans(document).map { |s| s["name"] }

    assert(document.key?("resourceSpans"))
    assert(names.none? { |n| n.include?("OrangeTap") },
           "expected no OrangeTap-internal spans, got: #{names.inspect}")
  end

  test "trace_all_app_methods: nested calls produce correctly nested spans" do
    OrangeTap.config.trace_all_app_methods = true

    path = OrangeTap.open { Sample.new.recursive(2) }
    spans = all_spans(read_document(path)).select { |s| s["name"] == "Sample#recursive" }

    assert_equal(3, spans.size)
    by_id = spans.each_with_object({}) { |s, h| h[s["spanId"]] = s }
    root = spans.find { |s| !by_id.key?(s["parentSpanId"]) }
    refute_nil(root)
    assert_equal(1, spans.count { |s| s["parentSpanId"] == root["spanId"] })
  end

  test "trace_all_app_methods: supersedes explicit per-method registration" do
    # Register only instance_method_a, but the mode should capture others too.
    OrangeTap.trace_method(Sample.instance_method(:instance_method_a))
    OrangeTap.config.trace_all_app_methods = true

    path = OrangeTap.open do
      sample = Sample.new
      sample.instance_method_a
      sample.not_traced_method
    end
    names = all_spans(read_document(path)).map { |s| s["name"] }

    # not_traced_method was never registered, yet the global mode still traces
    # it, and instance_method_a is not double-counted.
    assert_include(names, "Sample#not_traced_method")
    assert_equal(1, names.count("Sample#instance_method_a"))
  ensure
    OrangeTap.untrace_method(Sample.instance_method(:instance_method_a))
  end

  def capture_warning
    original = $VERBOSE
    captured = +""
    mod = Module.new
    mod.define_method(:warn) { |msg, *_a, **_k| captured << msg.to_s }
    Warning.singleton_class.prepend(mod)
    yield
    captured
  ensure
    $VERBOSE = original
  end

  test "open uses the default root span name when none is given" do
    path = OrangeTap.open { nil }
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "orange_tap session")
  end

  test "open(name) overrides the root span name" do
    path = OrangeTap.open("my-span") { nil }
    document = read_document(path)
    spans = all_spans(document)
    root = spans.find { |s| !s.key?("parentSpanId") }

    refute_nil(root)
    assert_equal("my-span", root["name"])
  end

  test "instance form open(name) also overrides the root span name" do
    tape = OrangeTap.new
    tape.open("instance-span")
    path = tape.stop

    spans = all_spans(read_document(path))
    root = spans.find { |s| !s.key?("parentSpanId") }
    refute_nil(root)
    assert_equal("instance-span", root["name"])
  end

  test "trace_method accepts multiple arguments in one call" do
    OrangeTap.trace_method(
      Sample.instance_method(:instance_method_a),
      Sample.method(:class_method_b)
    )

    path = OrangeTap.open do
      Sample.new.instance_method_a
      Sample.class_method_b
    end
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "Sample#instance_method_a")
    assert_include(names, "Sample.class_method_b")
  end

  test "trace_method resolves 'Foo.bar' notation to a class/singleton method" do
    OrangeTap.trace_method("Sample.class_method_b")

    path = OrangeTap.open { Sample.class_method_b }
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "Sample.class_method_b")
  end

  test "trace_method resolves 'Foo#bar' notation to an instance method" do
    OrangeTap.trace_method("Sample#instance_method_a")

    path = OrangeTap.open { Sample.new.instance_method_a }
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_include(names, "Sample#instance_method_a")
  end

  test "trace_method rejects notation strings that match neither pattern" do
    assert_raise(ArgumentError) { OrangeTap.trace_method("not a notation") }
  end

  test "untrace_method accepts multiple arguments and notation strings" do
    OrangeTap.trace_method("Sample#instance_method_a", "Sample.class_method_b")
    OrangeTap.untrace_method("Sample#instance_method_a", "Sample.class_method_b")

    path = OrangeTap.open do
      Sample.new.instance_method_a
      Sample.class_method_b
    end
    names = all_spans(read_document(path)).map { |s| s["name"] }

    assert_not_include(names, "Sample#instance_method_a")
    assert_not_include(names, "Sample.class_method_b")
  end

  test "untrace_method identifies methods by owner+name, not object identity" do
    OrangeTap.trace_method(Sample.instance_method(:instance_method_a))
    # A freshly obtained Method/UnboundMethod object for the same method
    # must still be able to unregister the earlier registration.
    OrangeTap.untrace_method(Sample.instance_method(:instance_method_a))

    path = OrangeTap.open { Sample.new.instance_method_a }
    names = all_spans(read_document(path)).map { |s| s["name"] }
    assert_not_include(names, "Sample#instance_method_a")
  end
end
