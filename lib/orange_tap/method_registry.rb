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
    # "Foo::Bar.baz" -> class/singleton method; "Foo::Bar#baz" -> instance method.
    # The class-path side never contains "." or "#", so a greedy match up to
    # the last separator is unambiguous.
    CLASS_METHOD_NOTATION = /\A(.+)\.([^.#]+)\z/
    INSTANCE_METHOD_NOTATION = /\A(.+)#([^.#]+)\z/

    def initialize
      @entries = {}
      @mutex = Mutex.new
    end

    def register(*method_objs)
      method_objs.each { |m| register_one(m) }
      nil
    end

    def unregister(*method_objs)
      method_objs.each { |m| unregister_one(m) }
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

    def register_one(method_obj)
      method_obj = resolve(method_obj)
      iseq = RubyVM::InstructionSequence.of(method_obj)
      raise OrangeTap::UntraceableMethodError, method_obj.inspect unless iseq

      @mutex.synchronize { @entries[key_for(method_obj)] = iseq }
    end

    def unregister_one(method_obj)
      method_obj = resolve(method_obj)
      @mutex.synchronize { @entries.delete(key_for(method_obj)) }
    end

    # Accepts a Method/UnboundMethod as-is, or a notation String ("Foo.bar"
    # for a class/singleton method, "Foo#bar" for an instance method) that is
    # resolved to one via Object.const_get + #method/#instance_method.
    def resolve(method_obj)
      return method_obj if method_obj.is_a?(Method) || method_obj.is_a?(UnboundMethod)

      unless method_obj.is_a?(String)
        raise ArgumentError,
              "Method / UnboundMethod、または 'Foo.bar' / 'Foo#bar' 形式の文字列を渡してください: " \
              "#{method_obj.inspect}"
      end

      if (m = CLASS_METHOD_NOTATION.match(method_obj))
        Object.const_get(m[1]).method(m[2].to_sym)
      elsif (m = INSTANCE_METHOD_NOTATION.match(method_obj))
        Object.const_get(m[1]).instance_method(m[2].to_sym)
      else
        raise ArgumentError,
              "'Foo.bar'（クラス/特異メソッド）または 'Foo#bar'（インスタンスメソッド）形式で指定してください: " \
              "#{method_obj.inspect}"
      end
    end

    def key_for(method_obj)
      [method_obj.owner, method_obj.name]
    end
  end
end
