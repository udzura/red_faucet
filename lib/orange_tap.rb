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

  # A batteries-included wrapper around a single session, meant for the
  # common "measure this block once" case (e.g. a Rails around_action):
  #
  #   OrangeTap.record("checkout", trace_all_app_methods: true,
  #                    on_output: ->(path) { Rails.logger.info(path) }) { do_work }
  #
  # It handles the two things every caller otherwise has to re-implement by
  # hand around #open:
  #
  # * config_overrides are applied for the duration of the block and restored
  #   afterwards, even on error. OrangeTap.config is a process-global
  #   singleton, so a leaked `trace_all_app_methods = true` would keep every
  #   later session in the heaviest mode; this guarantees it is reset.
  # * on_output is called with the written JSON path in the ensure, so the
  #   path is delivered on BOTH success and failure. (Block form #open cannot
  #   return the path when the block raises.) The trace file is written either
  #   way, since the worker drains on stop.
  #
  # Returns the output path on success; re-raises the original error on
  # failure (an on_output that raises is swallowed so it never masks it).
  def record(name = nil, on_output: nil, **config_overrides)
    previous = config_overrides.to_h { |key, _| [key, config.public_send(key)] }
    config_overrides.each { |key, value| config.public_send("#{key}=", value) }

    tape = new
    tape.open(name)
    path = nil
    begin
      yield
      path = tape.stop
    rescue Exception # rubocop:disable Lint/RescueException
      path = begin
        tape.stop
      rescue StandardError
        nil
      end
      raise
    ensure
      previous.each { |key, value| config.public_send("#{key}=", value) }
      begin
        on_output&.call(path)
      rescue StandardError
        nil
      end
    end
    path
  end
end
