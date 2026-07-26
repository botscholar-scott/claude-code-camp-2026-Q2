# 0011 — Progress reporting goes through an `AgentLogger` protocol

**Status:** accepted
**Date:** 2026-07-26
**Applies to:** `week1_baseline/python/05_agent_loop` and later steps

## Context

Ruby's step-05 `Agent` writes to stdout from inside the loop:

```ruby
puts "[iteration #{@iteration}/#{@max_iterations}]"          # agent.rb:35
puts "  tool call → #{name}(#{args})"                        # agent.rb:103
puts "  tool result → #{result.to_s[0..60]}"                 # agent.rb:105
```

Ruby unpicks this itself, three steps later. Step 08's `Agent` takes
`logger:` and calls `@logger.iteration(n:, max:)` and
`@logger.limit_reached(kind:, n:, max:)` instead. So the interim state is known
to be temporary *in the source of truth*.

Two things make inheriting it worse in Python than it was in Ruby:

1. **`agent.py` is library code inside an importable package.** A package that
   writes to stdout unbidden is a genuine Python smell — the caller has no way to
   turn it off short of redirecting `sys.stdout`.
2. **The consumer is one rung away, not three.** Step 06 of this ladder *is* the
   logger. Steps 08 (REPL) and 11 (TUI) then both need this output somewhere
   other than `print`.

The counter-argument is real and worth stating: defining an interface one step
before its implementation exists is textbook speculative generality. Four methods
and a null object is not free, and if step 06 wants a different vocabulary this
protocol changes.

## Decision

**An `AgentLogger` `Protocol` with a `NullLogger` default.**

```python
class AgentLogger(Protocol):
    def iteration(self, *, n: int, limit: int) -> None: ...
    def tool_call(self, *, name: str, args: Mapping[str, Any]) -> None: ...
    def tool_result(self, *, name: str, result: str, is_error: bool) -> None: ...
    def limit_reached(self, *, kind: str, n: int, limit: int) -> None: ...
```

1. `Agent(…, logger=None)` defaults to `NullLogger()`. **The package never calls
   `print`.**
2. A `Protocol`, not an ABC: an implementation neither subclasses nor imports
   anything. `examples/example.py`'s `PrintLogger` is a plain class.
3. **Method names and keyword shapes are taken from Ruby's step-08 logger** so
   step 06 converges on the real thing rather than inventing a second
   vocabulary. `max:` becomes `limit=` — `max` shadows a builtin.
4. `tool_result` carries `is_error` — the one field Ruby's has no need for,
   because Ruby never catches ([ADR 0010](0010-agent-catches-model-mistakes.md)).

**Rejected: `puts`-equivalent `print` in the loop, matching Ruby.** Keeps the
trees comparable and defers the decision. Rejected because it makes `boukensha`
a package that prints, and the fix is due one step later anyway — at which point
step 05's tree would be left holding a known defect for the sake of a shorter
diff.

**Rejected: the stdlib `logging` module.** The natural Python answer, and wrong
here: this output is a *user-facing transcript* of what the agent is doing, not
diagnostics. It goes to a TUI pane at step 11 and to a run file at step 06 — not
to a handler tree with levels and formatters. Structured method calls with named
fields are also what steps 06 and 11 actually want; `logger.info(f"…")` would
throw the fields away and make them re-parse a string. (The package's module is
named `boukensha/logging.py`; relative imports mean it does not shadow the
stdlib for anything.)

**Rejected: an `on_event(event)` callback taking one dataclass.** More extensible
and fewer methods to keep in sync. Rejected because it diverges from Ruby's
shape, which is the thing step 06 has to converge on.

## Consequences

- **`grep -rn "print(" boukensha/` returns nothing.** That is the check.
- **The example owns its own `PrintLogger`**, roughly the shape of Ruby's
  `puts` lines. The reader sees identical output from the two trees while the
  package stays quiet.
- **Step 06 implements this protocol** rather than inventing one. If it needs a
  method this does not have — token usage, cost, an end-of-run summary — the
  protocol grows, and `NullLogger` grows with it. `NullLogger`'s four methods are
  written out explicitly rather than as a `__getattr__` catch-all precisely so
  that a forgotten addition fails loudly.
- **Risk accepted:** if step 06 wants a materially different vocabulary, this
  protocol changes and this ADR is superseded. The mitigation is that the
  vocabulary is not invented here — it is copied from the Ruby step that already
  solved it.
- **`runtime_checkable`**, so `isinstance(logger, AgentLogger)` is available for
  a smoke check. It verifies method *names* only, never signatures; nothing in
  the library relies on it.

## Verification

```python
assert isinstance(NullLogger(), AgentLogger)     # True
assert isinstance(PrintLogger(), AgentLogger)    # True — never imports it
```

A full loop driven with the default logger produced **no output at all** and
returned its result; the same loop with the example's `PrintLogger` produced the
transcript in the step README.
