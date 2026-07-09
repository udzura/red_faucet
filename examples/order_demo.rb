#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal end-to-end example: define some classes, register the methods you
# want traced, wrap the code you want to observe in OrangeTap.open, and print
# the resulting OTLP/JSON file.
#
#   ruby -Ilib examples/order_demo.rb

require "orange_tap"
require "json"

class Order
  def initialize(items)
    @items = items
  end

  def total
    @items.sum { |item| Pricing.price_for(item) }
  end

  def checkout
    amount = total
    Receipt.new(amount).print
    amount
  end
end

module Pricing
  PRICES = { "coffee" => 400, "tea" => 350, "cake" => 500 }.freeze

  def self.price_for(item)
    PRICES.fetch(item, 0)
  end
end

class Receipt
  def initialize(amount)
    @amount = amount
  end

  def print
    puts "Total: #{@amount} yen"
  end
end

# Register the methods we care about in one call. "Foo#bar" resolves to an
# instance method, "Foo.bar" to a module/class (singleton) method.
OrangeTap.trace_method(
  "Order#total",
  "Order#checkout",
  "Pricing.price_for",
  "Receipt#print"
)

path = nil
# Avoid YJIT compile overhead in this example by running the code multiple times
3.times do
  path = OrangeTap.open do
    order = Order.new(%w[coffee cake tea coffee])
    order.checkout
  end
end

puts "\nOTLP/JSON written to: #{path}\n\n"
puts JSON.pretty_generate(JSON.parse(File.read(path)))
