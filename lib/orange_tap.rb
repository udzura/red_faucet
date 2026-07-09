# frozen_string_literal: true

require_relative "orange_tap/version"
require_relative "orange_tap/event"
require_relative "orange_tap/pending_span"
require_relative "orange_tap/otel_converter"
require_relative "orange_tap/config"
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

  def trace_method(method_obj)
    default_registry.register(method_obj)
  end

  def untrace_method(method_obj)
    default_registry.unregister(method_obj)
  end

  def trace_all_instance_methods(klass)
    default_registry.register_all_instance_methods(klass)
  end

  def open(&block)
    tape = new
    tape.open
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
