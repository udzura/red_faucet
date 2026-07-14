#!/usr/bin/env ruby
# frozen_string_literal: true

# Sinatra demo: enable OrangeTap's "trace all application methods" mode and
# record ONE OTLP/JSON trace per HTTP request, using before/after filters to
# open and stop a session around each request.
#
# It is self-driving: a handful of in-process requests are issued via
# Rack::MockRequest, so no server or `curl` is needed. Just run:
#
#   ruby examples/sinatra_trace_all_demo.rb
#
# The first run installs sinatra (and its rack dependency) via bundler/inline.

require "bundler/inline"
gemfile do
  source "https://rubygems.org"
  gem "sinatra", require: "sinatra/base"
end

require_relative "../lib/orange_tap"
require "json"
require "tmpdir"

# --- application (domain) code --------------------------------------------
# These are the methods we actually care about seeing in the trace. Nothing
# here is registered with trace_method: the "trace all" mode picks them up
# automatically because they are non-builtin Ruby methods.

module Pricing
  PRICES = { "coffee" => 400, "tea" => 350, "cake" => 500 }.freeze

  def self.price_for(item)
    PRICES.fetch(item, 0) # Hash#fetch is a C method -> excluded from the trace
  end
end

class Order
  MENUS = { 1 => %w[coffee cake], 2 => %w[tea tea coffee] }.freeze

  def initialize(id)
    @items = MENUS.fetch(id, [])
  end

  def total
    @items.sum { |item| Pricing.price_for(item) }
  end

  def summary
    "#{@items.size} item(s), #{total} yen"
  end
end

class Greeter
  def greet(name)
    "Hello, #{normalize(name)}!"
  end

  def normalize(name)
    name.to_s.strip.empty? ? "world" : name.strip
  end
end

# --- OrangeTap configuration ----------------------------------------------
OUTPUT_DIR = Dir.mktmpdir("orange_tap_sinatra")
OrangeTap.config.output_dir = OUTPUT_DIR
OrangeTap.config.trace_all_app_methods = true

# --- Sinatra app ----------------------------------------------------------
class DemoApp < Sinatra::Base
  # One OrangeTap session per request. In trace_all_app_methods mode every
  # non-builtin Ruby call between `before` and `after` is captured -- your
  # domain code AND gem code (Sinatra itself), since gems are traced. C methods
  # and the standard library are excluded automatically.
  before do
    @tape = OrangeTap.new
    @tape.open("#{request.request_method} #{request.path_info}")
  end

  after do
    path = @tape.stop
    # Surface the trace file so the driver below can report / read it.
    response.headers["X-Trace-Path"] = path
  end

  get "/" do
    Greeter.new.greet(params["name"])
  end

  get "/orders/:id" do
    Order.new(params["id"].to_i).summary
  end
end

# --- drive a few requests in-process --------------------------------------
DOMAIN = %w[Greeter Order Pricing].freeze

def domain_spans(names)
  names.select { |n| DOMAIN.any? { |d| n.start_with?("#{d}#", "#{d}.") } }
end

def span_names(path)
  document = JSON.parse(File.read(path))
  document.fetch("resourceSpans").flat_map do |rs|
    rs.fetch("scopeSpans").flat_map { |ss| ss.fetch("spans") }
  end.map { |s| s["name"] }
end

mock = Rack::MockRequest.new(DemoApp)
requests = ["/", "/?name=Alice", "/orders/1", "/orders/2"]

puts "Traces written under: #{OUTPUT_DIR}\n\n"

requests.each do |path|
  response = mock.get(path)
  trace_path = response["X-Trace-Path"]
  names = span_names(trace_path)

  puts "GET #{path}"
  puts "  -> #{response.status} #{response.body.strip.inspect}"
  puts "  trace: #{trace_path}"
  puts "  spans: #{names.size} total, #{domain_spans(names.uniq).sort.join(', ')} (domain)"
  puts
end

puts "Each request produced its own OTLP/JSON file (open one to see the full,"
puts "framework-inclusive span tree)."
