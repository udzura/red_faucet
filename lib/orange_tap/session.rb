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

      # Start the worker before building the TracePoints so its Thread can be
      # captured by the global app hook (which must skip the worker's own
      # calls). Tracing is not active yet, so nothing the worker does now is
      # recorded.
      ctx = Worker::Context.new(
        queue: @queue, config: @config, trace_id: trace_id,
        start_mono_ns: start_mono_ns, start_unix_ns: start_unix_ns,
        session_name: session_name
      )
      @worker_thread = Thread.new(ctx) { |worker_ctx| Worker.new(worker_ctx).run }

      # Entries are [tracepoint, iseq]; a nil iseq marks a global (targetless)
      # hook, which is enabled without a target: below.
      @tracepoint_targets = build_tracepoint_targets

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

    # Global "trace all app methods" mode supersedes per-method registration:
    # a single :call/:return hook records every non-builtin Ruby method call.
    # Otherwise, use the registry's per-ISeq hooks plus the optional global
    # C-method hook. One TracePoint per target ISeq: whether a single
    # TracePoint can safely enable(target:) more than one ISeq is
    # version-dependent, so each ISeq gets its own instance.
    def build_tracepoint_targets
      if @config.trace_all_app_methods
        return [[build_global_app_tracepoint(@queue, BuiltinFilter.new, @worker_thread), nil]]
      end

      targets = @registry.targets.map { |iseq| [build_tracepoint(@queue), iseq] }

      # Opt-in: a single global :c_call/:c_return TracePoint for any registered
      # C methods, filtered inside the hook. Only added when there is at least
      # one C method to trace, so the default path keeps zero C-call overhead.
      c_targets = @registry.c_targets
      targets << [build_c_tracepoint(@queue, c_targets), nil] unless c_targets.empty?
      targets
    end

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

    # Global hook for the trace_all_app_methods mode. Fires on EVERY Ruby
    # method call in the process (C methods never fire :call). Two cheap
    # guards run first: skip the worker's own thread (so its bookkeeping and
    # JSON writing are never traced, avoiding a feedback loop), and skip
    # built-in definition paths via the memoized filter. TracePoint suppresses
    # its own re-entry, so the Ruby calls in this body (filter.app_method?)
    # do not recurse.
    def build_global_app_tracepoint(queue, filter, worker_thread)
      TracePoint.new(:call, :return) do |tp|
        next if Thread.current == worker_thread
        next unless filter.app_method?(tp.path)

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
