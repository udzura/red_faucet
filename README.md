# RedFaucet

RedFaucet hooks Ruby method calls (call/return) with `TracePoint`, assembles
them into OpenTelemetry-style spans on a background thread inside the same
process, and writes the result as an OTLP/JSON file. There is no central
daemon, no shared memory, and no inter-process communication of any kind —
tracing is entirely contained within the observed Ruby process.

## Design notes

### Why Ruby-level `TracePoint` instead of `rb_add_event_hook`

RedFaucet intentionally uses the Ruby-level `TracePoint` API rather than the
C-level `rb_add_event_hook`/`trace_func` mechanism. Ruby 4.0's C-level
`trace_func` has a known bug, so this gem avoids it by design and pays the
(small, and in practice dominated by the traced call itself) overhead of a
Ruby-level hook instead. Target methods are narrowed with
`TracePoint#enable(target: iseq)` so untargeted methods incur no hook
overhead at all.

### No central daemon — everything lives in one process's Thread + Queue

Earlier iterations of this idea used a shared-memory ring buffer and an XPC
daemon process. RedFaucet drops all of that: a session is just a
`Thread::Queue` plus a background `Thread` inside the same process that
called `RedFaucet.open`. Correlating traces across multiple OS processes is
explicitly out of scope for this gem.

### Why `open`/`stop` need no `session_id`

Each call to `open` creates a brand new `Queue` and worker `Thread` dedicated
to that session. Because a Worker only ever drains events pushed by the
TracePoints that same `Session` enabled, the `Queue` instance itself is what
scopes an event to a session — there is no `session_id` field anywhere, and
running multiple sessions concurrently (multiple `RedFaucet.new.open` calls
at once) works without any extra bookkeeping.

### What isn't tracked

- **Cross-thread/Fiber/Ractor causality.** Spans are grouped strictly by
  `thread_id`, so if a traced method spawns work on another thread
  (`Thread.new`, a Fiber, a Ractor), that work's spans are not linked back to
  the caller as parent/child. This is out of scope for the current version.
- **Methods defined via `define_method` or a block.** `trace_method` requires
  a `Method`/`UnboundMethod` backed by a `def`-defined instance sequence.
  Block-based method bodies (`define_method`, `define_singleton_method`) have
  an ISeq of type `:block`, which `TracePoint#enable(target:)` cannot target
  and raises `ArgumentError` — attempting to trace one will fail at `open`
  time, not at `trace_method` time.
- **Errors inside the Worker thread.** If the worker thread raises while
  assembling spans, `Session#stop` re-raises that error via `Thread#value`'s
  standard behavior. TracePoints are always disabled *before* the worker is
  waited on, so a worker crash never leaves hooks enabled.
- **Double-hook overhead across concurrent sessions.** If two sessions are
  open at once and both target the same method, that method gets two
  independent `TracePoint`s enabled on it. This is accepted for simplicity in
  the current version.

## Installation

```bash
bundle add red_faucet
```

Or, without Bundler:

```bash
gem install red_faucet
```

## Usage

```ruby
require "red_faucet"

class Worker
  def process(job)
    # ...
  end
end

RedFaucet.trace_method(Worker.instance_method(:process))

path = RedFaucet.open do
  Worker.new.process(job)
end
# => path to a written OTLP/JSON file
```

Or using the instance form:

```ruby
tape = RedFaucet.new
tape.open
# ...
path = tape.stop
```

Other registration entry points:

```ruby
RedFaucet.trace_method(SomeClass.method(:some_class_method))   # class/singleton method
RedFaucet.trace_method(some_object.method(:some_method))       # singleton method on one object
RedFaucet.trace_all_instance_methods(SomeClass)                # all instance methods at once
RedFaucet.untrace_method(SomeClass.instance_method(:some_method))
```

Output location is configurable:

```ruby
RedFaucet.config.output_dir = "/path/to/traces"
```

### Example

[`examples/order_demo.rb`](examples/order_demo.rb) is a runnable,
self-contained example. It defines a small `Order`/`Pricing`/`Receipt` set of
classes:

```ruby
class Order
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
  def self.price_for(item) = PRICES.fetch(item, 0)
end

class Receipt
  def print = puts "Total: #{@amount} yen"
end
```

traces a mix of instance and module methods, and wraps the call in
`RedFaucet.open`:

```ruby
RedFaucet.trace_method(Order.instance_method(:total))
RedFaucet.trace_method(Order.instance_method(:checkout))
RedFaucet.trace_method(Pricing.method(:price_for))
RedFaucet.trace_method(Receipt.instance_method(:print))

path = RedFaucet.open do
  Order.new(%w[coffee cake tea coffee]).checkout
end
```

Run it with:

```bash
bundle exec ruby -Ilib examples/order_demo.rb
```

This prints the OTLP/JSON file path and pretty-prints its contents. A sample
of that output is checked in at
[`examples/trace-example.json`](examples/trace-example.json).

Importing that JSON into Jaeger (all-in-one) as an OTLP trace renders the
following span tree, which matches the example's call graph exactly —
`red_faucet session` → `tid=...` → `Order#checkout` → `Order#total` →
`Pricing.price_for` ×4, plus `Receipt#print`:

![Example trace visualized in Jaeger](examples/jaeger-screenshot.png)

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then,
run `rake test` to run the tests. You can also run `bin/console` for an
interactive prompt that will allow you to experiment.

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/udzura/red_faucet. This project is intended to be a safe,
welcoming space for collaboration, and contributors are expected to adhere to
the [code of conduct](https://github.com/udzura/red_faucet/blob/main/CODE_OF_CONDUCT.md).

## Code of Conduct

Everyone interacting in the RedFaucet project's codebases, issue trackers,
chat rooms and mailing lists is expected to follow the
[code of conduct](https://github.com/udzura/red_faucet/blob/main/CODE_OF_CONDUCT.md).
