# frozen_string_literal: true

module OrangeTap
  # Holds the set of methods to be traced, keyed by [owner, name] rather than
  # by Method/UnboundMethod object identity. Method/UnboundMethod instances
  # are freshly allocated on every `obj.method(:foo)` call, so identity-based
  # bookkeeping would make untrace_method impossible to use correctly. Using
  # owner (the singleton class for class/singleton methods) + name gives a
  # stable identity for instance methods, class methods, and singleton
  # methods on a specific object alike.
  class MethodRegistry
    def initialize
      @entries = {}
      @mutex = Mutex.new
    end

    def register(method_obj)
      unless method_obj.is_a?(Method) || method_obj.is_a?(UnboundMethod)
        raise ArgumentError, "Method または UnboundMethod を渡してください: #{method_obj.inspect}"
      end

      iseq = RubyVM::InstructionSequence.of(method_obj)
      raise OrangeTap::UntraceableMethodError, method_obj.inspect unless iseq

      @mutex.synchronize { @entries[key_for(method_obj)] = iseq }
      nil
    end

    def unregister(method_obj)
      @mutex.synchronize { @entries.delete(key_for(method_obj)) }
      nil
    end

    def register_all_instance_methods(klass)
      klass.instance_methods(false).each { |m| register(klass.instance_method(m)) }
      nil
    end

    # Snapshot of currently registered ISeqs, taken once per Session#open.
    def targets
      @mutex.synchronize { @entries.values.dup }
    end

    private

    def key_for(method_obj)
      [method_obj.owner, method_obj.name]
    end
  end
end
