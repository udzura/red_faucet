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
end

class OrangeTapTest < Test::Unit::TestCase
  def setup
    Sample.reset_calls!
    OrangeTap.default_registry.unregister(Sample.instance_method(:instance_method_a))
    OrangeTap.default_registry.unregister(Sample.instance_method(:not_traced_method))
    OrangeTap.default_registry.unregister(Sample.method(:class_method_b))
    OrangeTap.default_registry.unregister(Sample.instance_method(:recursive))
    OrangeTap.default_registry.unregister(Sample.instance_method(:blocking))
    @tmpdir = Dir.mktmpdir("orange_tap_test")
    OrangeTap.config.output_dir = @tmpdir
  end

  def teardown
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
