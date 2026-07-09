# frozen_string_literal: true

module OrangeTap
  # Mutable, in-progress span assembled by Worker while draining the queue.
  # Timestamps are kept in monotonic ns; OtelConverter is responsible for
  # anchoring them to wall-clock unix ns at output time.
  class PendingSpan
    attr_accessor :span_id, :parent_span_id, :name, :thread_id,
                  :start_mono_ns, :end_mono_ns, :incomplete

    def initialize(span_id:, parent_span_id:, name:, thread_id:, start_mono_ns:, end_mono_ns: nil)
      @span_id = span_id
      @parent_span_id = parent_span_id
      @name = name
      @thread_id = thread_id
      @start_mono_ns = start_mono_ns
      @end_mono_ns = end_mono_ns
      @incomplete = false
    end
  end
end
