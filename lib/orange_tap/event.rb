# frozen_string_literal: true

module OrangeTap
  # Lightweight, immutable event created inside the TracePoint hook. Only
  # numeric/symbol/Module references are captured here (no tp.binding,
  # no tp.parameters, no string building) so the hook body stays cheap.
  Event = Data.define(:type, :thread_id, :method_id, :defined_class, :timestamp_ns)
end
