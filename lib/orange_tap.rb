# frozen_string_literal: true

require_relative "orange_tap/version"
require_relative "orange_tap/event"
require_relative "orange_tap/pending_span"
require_relative "orange_tap/otel_converter"
require_relative "orange_tap/config"
require_relative "orange_tap/builtin_filter"
require_relative "orange_tap/method_registry"
require_relative "orange_tap/worker"
require_relative "orange_tap/session"

module OrangeTap
  class Error < StandardError; end
  class AlreadyOpenError < Error; end
  class NotOpenError < Error; end
  class UntraceableMethodError < Error; end

  module_function

  # OrangeTap.new -> Session, so `tape = OrangeTap.new; tape.open; ...; tape.stop`
  # reads like constructing a recorder, while OrangeTap itself stays a module.
  def new(**opts)
    Session.new(**opts)
  end

  def default_registry
    @default_registry ||= MethodRegistry.new
  end

  def config
    @config ||= Config.new
  end

  # Accepts one or more Method/UnboundMethod objects, or notation strings
  # ("Foo.bar" for a class/singleton method, "Foo#bar" for an instance
  # method), and registers them all in a single call.
  def trace_method(*method_objs)
    default_registry.register(*method_objs)
  end

  def untrace_method(*method_objs)
    default_registry.unregister(*method_objs)
  end

  def trace_all_instance_methods(klass)
    default_registry.register_all_instance_methods(klass)
  end

  def open(name = nil, &block)
    tape = new
    tape.open(name)
    return tape unless block

    begin
      block.call
      tape.stop
    rescue Exception # rubocop:disable Lint/RescueException
      # Make sure TracePoints are disabled and the worker is drained even
      # when the block raises. The output path is unrecoverable here, so we
      # re-raise the original error instead of returning it.
      begin
        tape.stop
      rescue StandardError
        nil
      end
      raise
    end
  end
end
