# frozen_string_literal: true

require "tmpdir"

module OrangeTap
  class Config
    attr_accessor :output_dir, :service_name, :otel_converter

    def initialize
      @output_dir = File.join(Dir.tmpdir, "orange_tap")
      @service_name = "orange_tap"
      @otel_converter = OrangeTap::OtelConverter
    end
  end
end
