# frozen_string_literal: true

module OrangeTap
  # Self-contained OTLP/JSON writer. Follows the wire format conventions of
  # OTLP/JSON (resourceSpans -> scopeSpans -> spans, 32-hex traceId, 16-hex
  # spanId, string-encoded nanosecond timestamps) but does not depend on any
  # external gem: PendingSpan already carries hex-encoded span_id/parent_span_id
  # (see Worker), so no int-to-hex conversion is needed here.
  #
  # Pluggable via Config#otel_converter so callers can swap in their own
  # converter (e.g. to stream spans elsewhere) without touching Worker.
  module OtelConverter
    SPAN_KIND_INTERNAL = 1

    module_function

    # spans: Array<PendingSpan> holding monotonic-ns timestamps.
    # Returns a Hash ready for JSON.generate.
    def build_document(spans:, trace_id:, start_mono_ns:, start_unix_ns:, service_name:)
      to_unix = ->(mono_ns) { (start_unix_ns.to_i + (mono_ns.to_i - start_mono_ns.to_i)).to_s }

      {
        resourceSpans: [
          {
            resource: { attributes: [str_attr("service.name", service_name)] },
            scopeSpans: [
              {
                scope: { name: service_name, version: OrangeTap::VERSION },
                spans: spans.map { |s| span_hash(s, trace_id, to_unix) }
              }
            ]
          }
        ]
      }
    end

    def span_hash(span, trace_id, to_unix)
      attributes = []
      attributes << int_attr("thread.id", span.thread_id) if span.thread_id
      attributes << bool_attr("orange_tap.incomplete", true) if span.incomplete

      hash = {
        traceId: trace_id,
        spanId: span.span_id,
        name: span.name,
        kind: SPAN_KIND_INTERNAL,
        startTimeUnixNano: to_unix.call(span.start_mono_ns),
        endTimeUnixNano: to_unix.call(span.end_mono_ns),
        attributes: attributes
      }
      hash[:parentSpanId] = span.parent_span_id if span.parent_span_id
      hash
    end

    def str_attr(key, value)
      { key: key, value: { stringValue: value.to_s } }
    end

    def int_attr(key, value)
      { key: key, value: { intValue: value.to_i.to_s } }
    end

    def bool_attr(key, value)
      { key: key, value: { boolValue: !!value } }
    end
  end
end
