# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"

module OrangeTap
  # Runs on a dedicated Thread created by Session#open. Drains the session's
  # Queue, reconstructs a 3-layer span tree (session root / per-thread /
  # per-method) from CALL/RETURN pairs, and writes a single OTLP/JSON file.
  #
  # The Queue instance itself is the session boundary: there is no session_id
  # tag on Event, because a Worker only ever drains events produced by the
  # TracePoints of the Session that spawned it.
  class Worker
    Context = Data.define(:queue, :config, :trace_id, :start_mono_ns, :start_unix_ns)

    def initialize(ctx)
      @ctx = ctx
      @stacks = Hash.new { |h, k| h[k] = [] } # thread_id => [PendingSpan, ...]
      @thread_spans = {}                       # thread_id => PendingSpan
      @completed = []                          # confirmed method-layer spans
      @session_span = nil
    end

    # Returns the full path of the written JSON file. Session#stop receives
    # this via Thread#value.
    def run
      @session_span = new_session_span

      loop do
        event = @ctx.queue.pop
        break if event.nil? # Queue#close makes pop return nil once drained

        case event.type
        when :call then on_call(event)
        when :return then on_return(event)
        end
      end

      finalize_dangling_spans
      write_json
    end

    private

    def on_call(event)
      thread_span = thread_span_for(event.thread_id)
      stack = @stacks[event.thread_id]
      parent_id = stack.empty? ? thread_span.span_id : stack.last.span_id

      span = PendingSpan.new(
        span_id: SecureRandom.hex(8),
        parent_span_id: parent_id,
        name: method_name(event.defined_class, event.method_id),
        thread_id: event.thread_id,
        start_mono_ns: event.timestamp_ns
      )
      stack.push(span)
    end

    def on_return(event)
      span = @stacks[event.thread_id].pop
      return unless span # RETURN with no matching CALL is silently ignored

      span.end_mono_ns = event.timestamp_ns
      @completed << span
    end

    # Any CALL still on a stack when the queue closes never got its RETURN
    # (e.g. session stopped mid-call). Force-close it as incomplete so it is
    # still represented in the output rather than silently dropped.
    def finalize_dangling_spans
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      @stacks.each_value do |stack|
        while (span = stack.pop)
          span.end_mono_ns ||= now
          span.incomplete = true
          @completed << span
        end
      end
    end

    def thread_span_for(thread_id)
      @thread_spans[thread_id] ||= PendingSpan.new(
        span_id: SecureRandom.hex(8),
        parent_span_id: @session_span.span_id,
        name: "tid=#{thread_id}",
        thread_id: thread_id,
        start_mono_ns: @ctx.start_mono_ns
      )
    end

    def new_session_span
      PendingSpan.new(
        span_id: SecureRandom.hex(8),
        parent_span_id: nil,
        name: "orange_tap session",
        thread_id: nil,
        start_mono_ns: @ctx.start_mono_ns
      )
    end

    # Class/singleton methods render as "Owner.method"; instance methods as
    # "Owner#method". defined_class for a singleton method is the singleton
    # class itself, whose #inspect is "#<Class:Owner>".
    def method_name(defined_class, method_id)
      if defined_class.respond_to?(:singleton_class?) && defined_class.singleton_class?
        owner = defined_class.inspect[/\A#<Class:(.+)>\z/, 1] || defined_class.inspect
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
      document = @ctx.config.otel_converter.build_document(
        spans: spans,
        trace_id: @ctx.trace_id,
        start_mono_ns: @ctx.start_mono_ns,
        start_unix_ns: @ctx.start_unix_ns,
        service_name: @ctx.config.service_name
      )

      FileUtils.mkdir_p(@ctx.config.output_dir)
      path = File.join(@ctx.config.output_dir, "orange_tap-#{@ctx.trace_id}.json")
      File.write(path, JSON.generate(document))
      path
    end
  end
end
