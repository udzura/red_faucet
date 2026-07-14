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

    def open(session_name = nil)
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
      # each ISeq gets its own TracePoint instance to enable/disable. Entries
      # are [tracepoint, iseq]; a nil iseq marks the global C-method hook,
      # which is enabled without a target.
      @tracepoint_targets = @registry.targets.map { |iseq| [build_tracepoint(@queue), iseq] }

      # Opt-in: a single global :c_call/:c_return TracePoint for any registered
      # C methods, filtered inside the hook. Only added when there is at least
      # one C method to trace, so the default path keeps zero C-call overhead.
      c_targets = @registry.c_targets
      @tracepoint_targets << [build_c_tracepoint(@queue, c_targets), nil] unless c_targets.empty?

      ctx = Worker::Context.new(
        queue: @queue, config: @config, trace_id: trace_id,
        start_mono_ns: start_mono_ns, start_unix_ns: start_unix_ns,
        session_name: session_name
      )
      @worker_thread = Thread.new(ctx) { |worker_ctx| Worker.new(worker_ctx).run }

      @tracepoint_targets.each { |tp, iseq| iseq ? tp.enable(target: iseq) : tp.enable }
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

    # Global hook for C methods. Fires on EVERY C call in the process, so the
    # first thing it does is filter by [owner, name]; unregistered calls exit
    # immediately. :c_call/:c_return are normalized to :call/:return so the
    # Worker's event handling stays uniform. (TracePoint suppresses its own
    # re-entry, so the C calls made inside this hook do not recurse.)
    def build_c_tracepoint(queue, c_targets)
      TracePoint.new(:c_call, :c_return) do |tp|
        next unless c_targets.include?([tp.defined_class, tp.method_id])

        queue << Event.new(
          type: tp.event == :c_call ? :call : :return,
          thread_id: Thread.current.object_id,
          method_id: tp.method_id,
          defined_class: tp.defined_class,
          timestamp_ns: Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        )
      end
    end
  end
end
