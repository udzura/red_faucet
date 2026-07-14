# frozen_string_literal: true

require "tmpdir"

module OrangeTap
  class Config
    attr_accessor :output_dir, :service_name, :otel_converter, :trace_c_methods

    def initialize
      @output_dir = File.join(Dir.tmpdir, "orange_tap")
      @service_name = "orange_tap"
      @otel_converter = OrangeTap::OtelConverter
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
