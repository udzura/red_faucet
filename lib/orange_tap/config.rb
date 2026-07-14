# frozen_string_literal: true

require "tmpdir"

module OrangeTap
  class Config
    attr_accessor :output_dir, :service_name, :otel_converter, :trace_c_methods, :trace_all_app_methods

    def initialize
      @output_dir = File.join(Dir.tmpdir, "orange_tap")
      @service_name = "orange_tap"
      @otel_converter = OrangeTap::OtelConverter
      # Opt-in "trace everything" mode. When true, a session installs a single
      # global :call/:return TracePoint that records every non-builtin Ruby
      # method call in the process, instead of the per-method registry hooks.
      # Built-ins are excluded by definition path (core internals + stdlib);
      # gems ARE traced, and C methods are always excluded (:call never fires
      # for them). This fires on every Ruby call process-wide, so it is heavy;
      # see BuiltinFilter and README. It supersedes explicit trace_method
      # registration when enabled.
      @trace_all_app_methods = false
      # Opt-in flag for tracing C-implemented methods. When false (default),
      # registering a C method raises UntraceableMethodError, as before. When
      # true, C methods are traced via a single global :c_call/:c_return
      # TracePoint per session, filtered by [owner, name] inside the hook.
      # This trades away the "zero overhead for unregistered methods"
      # guarantee for every C call in the process. See TODO-c-support.md.
      @trace_c_methods = false
    end
  end
end
