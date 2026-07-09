# frozen_string_literal: true

require "securerandom"

module OrangeTap
  # Controls a single recording session's lifecycle. Each #open call creates
  # a dedicated Queue and Worker Thread; there is no session_id, because the
  # Queue instance itself is what scopes events to this session. This also
  # makes concurrent sessions (multiple Session instances open at once) work
  # without any cross-session bookkeeping: each has its own Queue, Thread,
  # and TracePoint set.
  class Session
    def initialize(registry: OrangeTap.default_registry, config: OrangeTap.config)
      @registry = registry
      @config = config
      @queue = nil
      @worker_thread = nil
      @tracepoint_targets = nil
    end

    def open
      raise AlreadyOpenError if @queue

      # Anchor monotonic time to wall-clock time once, at session start, so
      # OtelConverter can later translate CLOCK_MONOTONIC-based timestamps
      # (cheap, used inside the hot hook) into absolute OTLP unix ns.
      start_mono_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      start_unix_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      trace_id = SecureRandom.hex(16)

      @queue = Thread::Queue.new

      # One TracePoint per target ISeq: whether a single TracePoint can
      # safely enable(target:) more than one ISeq is version-dependent, so
      # each ISeq gets its own TracePoint instance to enable/disable.
      @tracepoint_targets = @registry.targets.map { |iseq| [build_tracepoint(@queue), iseq] }

      ctx = Worker::Context.new(
        queue: @queue, config: @config, trace_id: trace_id,
        start_mono_ns: start_mono_ns, start_unix_ns: start_unix_ns
      )
      @worker_thread = Thread.new(ctx) { |worker_ctx| Worker.new(worker_ctx).run }

      @tracepoint_targets.each { |tp, iseq| tp.enable(target: iseq) }
      self
    end

    def stop
      raise NotOpenError unless @queue

      # Disable hooks before closing the queue / waiting on the worker, so
      # that even if the worker raises, tracing has already stopped and
      # cannot leak into whatever runs next.
      @tracepoint_targets.each { |tp, _iseq| tp.disable }
      @queue.close
      path = @worker_thread.value
      @queue = nil
      @tracepoint_targets = nil
      @worker_thread = nil
      path
    end

    private

    def build_tracepoint(queue)
      TracePoint.new(:call, :return) do |tp|
        # Hook body stays minimal: push a single Event built from cheap
        # primitives only. No tp.binding, no tp.parameters, no string work.
        queue << Event.new(
          type: tp.event,
          thread_id: Thread.current.object_id,
          method_id: tp.method_id,
          defined_class: tp.defined_class,
          timestamp_ns: Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        )
      end
    end
  end
end
