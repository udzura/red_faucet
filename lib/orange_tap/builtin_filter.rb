# frozen_string_literal: true

require "rbconfig"

module OrangeTap
  # Classifies a source path (as given by TracePoint#path, i.e. the definition
  # file of the called method) into "application code" vs "built-in", for the
  # trace_all_app_methods mode.
  #
  # C-implemented methods never reach here: TracePoint(:call) does not fire for
  # them, so they are excluded upstream. What remains to filter out are the
  # Ruby-implemented built-ins, which are identified purely by path prefix:
  #
  #   - "<...>"            core internals (e.g. "<internal:array>")
  #   - rubylibdir/arch   the Ruby standard library
  #   - OrangeTap itself  so the tracer never traces its own code
  #
  # Gems (Gem.path) are intentionally NOT excluded: application-owned gem calls
  # are considered part of the app for this mode.
  class BuiltinFilter
    def initialize
      @excluded_prefixes = [
        RbConfig::CONFIG["rubylibdir"],
        RbConfig::CONFIG["rubyarchdir"],
        # lib/orange_tap/builtin_filter.rb -> lib/orange_tap -> lib
        File.expand_path("..", __dir__)
      ].compact
      @cache = {}
      @mutex = Mutex.new
    end

    # True when `path` looks like application (or gem) code that should be
    # traced; false for core internals, the standard library, and OrangeTap's
    # own source. Decisions are memoized per path.
    def app_method?(path)
      return false if path.nil? || path.empty?
      return @cache[path] if @cache.key?(path)

      @mutex.synchronize do
        # Re-check inside the lock: another thread may have filled it in.
        return @cache[path] if @cache.key?(path)

        @cache[path] = compute(path)
      end
    end

    private

    def compute(path)
      return false if path.start_with?("<") # "<internal:...>", "<compiled>", etc.

      @excluded_prefixes.none? { |prefix| path.start_with?(prefix) }
    end
  end
end
