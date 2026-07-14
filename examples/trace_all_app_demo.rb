#!/usr/bin/env ruby
# frozen_string_literal: true

# "Trace all application methods" mode: instead of registering methods one by
# one, flip a single config flag and every non-builtin Ruby method call is
# captured automatically. Built-ins are excluded by definition path — Ruby
# core internals and the standard library are dropped, and C methods
# (String#upcase, Array#each, ...) never fire the :call hook at all. Your
# application code (and gems) is traced.
#
#   ruby -Ilib examples/trace_all_app_demo.rb

require "orange_tap"
require "json"

class Order
  def initialize(items)
    @items = items
  end

  def total
    # Enumerable#sum + the block call into C methods (Array iteration, Integer
    # addition): those are NOT traced. Pricing.price_for IS (app code).
    @items.sum { |item| Pricing.price_for(item) }
  end

  def checkout
    amount = total
    label = describe        # app method, traced
    Receipt.new(amount).print(label)
    amount
  end

  # Defined with define_method: the per-method `trace_method` API cannot target
  # this (its ISeq is a :block), but the global app hook captures it fine.
  define_method(:describe) do
    "order of #{@items.size} item(s)"
  end
end

module Pricing
  PRICES = { "coffee" => 400, "tea" => 350, "cake" => 500 }.freeze

  def self.price_for(item)
    PRICES.fetch(item, 0)   # Hash#fetch is a C method -> not traced
  end
end

class Receipt
  def initialize(amount)
    @amount = amount
  end

  def print(label)
    puts "#{label}: #{@amount} yen"   # Kernel#puts is C -> not traced
  end
end

# No OrangeTap.trace_method calls needed: just enable the mode.
OrangeTap.config.trace_all_app_methods = true

path = nil
# Avoid YJIT compile overhead in this example by running the code multiple times
3.times do
  path = OrangeTap.open("DummyController#dummy") do
    order = Order.new(%w[coffee cake tea coffee])
    order.checkout
  end
end

puts "\nOTLP/JSON written to: #{path}\n\n"

document = JSON.parse(File.read(path))
spans = document.fetch("resourceSpans").flat_map do |rs|
  rs.fetch("scopeSpans").flat_map { |ss| ss.fetch("spans") }
end

# App methods (Order#total, Order#checkout, Order#describe, Pricing.price_for,
# Receipt#initialize, Receipt#print) show up automatically; built-ins such as
# String#upcase, Hash#fetch, and Kernel#puts do not.
puts "Captured span names:"
spans.map { |s| s["name"] }.uniq.sort.each { |name| puts "  - #{name}" }

puts "\nFull document:\n\n"
puts JSON.pretty_generate(document)
