# 0005 — Tools register via a decorator, and it returns the handler unchanged

**Status:** accepted
**Date:** 2026-07-25
**Applies to:** `week1_baseline/python/02_the_registry` and later steps

## Context

Ruby attaches a tool's handler with a trailing block:

```ruby
registry.tool("move",
  description: "Move the player in a direction",
  parameters: { direction: { type: "string" } }
) do |direction:|
  "You move #{direction} into a torch-lit corridor."
end
```

Python has no blocks, so the handler has to arrive some other way. Three
candidates:

1. a **decorator factory** — `registry.tool(...)` returns a decorator that
   registers the function it wraps;
2. a **`handler=` keyword** — `registry.tool("move", description=…, handler=fn)`;
3. **both**, dispatching on whether `handler` was passed.

The forcing constraint is downstream. Step 10's tool libraries register
multi-line closures over `root` and `resolve`:

```ruby
# ruby/10_standard_tool_library/lib/boukensha/tools/file_system.rb
registry.tool("read_file", description: …, parameters: …) do |path:|
  full = resolve.call(path)
  return "Error: file not found: #{path}" unless File.exist?(full)
  File.read(full)
end
```

A Python `lambda` is a single expression and cannot hold that. With a `handler=`
keyword the caller would have to write a `def` and then a separate registration
call — two statements where the Ruby is one, repeated once per tool across three
libraries.

## Decision

**Decorator factory only.**

```python
@registry.tool(
    "move",
    description="Move the player in a direction (north, south, east, west, up, down)",
    parameters={"direction": {"type": "string", "description": "The direction to move"}},
)
def move(direction):
    return f"You move {direction} into a torch-lit corridor."
```

`Registry.tool(name, *, description, parameters=None)` returns a one-argument
decorator that constructs the `Tool`, stores it, and **returns the handler
unchanged** — not the `Tool`, and not a wrapper. The decorated name stays bound
to a plain callable:

```python
>>> move("north")
'You move north into a torch-lit corridor.'
```

The `Tool` is reachable as `registry.tools["move"]` when it is wanted. Ruby's
`registry.tool(...)` returns the tool instead, but nothing in the Ruby ladder uses
that return value.

`parameters` defaults to `None`, not `{}` — no mutable default argument.
`Tool.__post_init__` copies and proxies whatever it is given, so `parameters or {}`
is safe.

**Rejected: dual-mode** (decorator *and* `handler=`). Two code paths and two
obvious ways to do the same thing, for a caller convenience no caller has asked
for. The keyword form can be added later without breaking the decorator form if a
call site ever wants it.

**Rejected: deriving `parameters` from the signature and type hints**,
FastAPI-style — reading `def move(direction: str)` into
`{"direction": {"type": "string"}}` automatically. Genuinely attractive, and this
decision is what makes it natural, since the decorator already sees the function.
But it is a large divergence from the Ruby with nothing in the ladder needing it,
it cannot infer the per-argument `description` the model actually reads, and it
would have to grow an escape hatch for anything non-trivial. Recorded so the idea
is not lost.

## Consequences

- **Registration is a side effect of applying the decorator**, so it happens at
  `def` time. A duplicate name raises `ValueError` at import, not at dispatch —
  which is what step 10's three-library merge wants.
- `RunDSL#tool` at step 07 forwards straight to `@registry.tool`, so it forwards
  the decorator unchanged; a decorator at the registry surface composes cleanly
  there.
- `Registry.tool` returns the function, not the `Tool` — a visible divergence from
  the Ruby, and the one that buys directly-callable, directly-testable handlers.
- The decorator is typed `Callable[[F], F]` with `F = TypeVar("F", bound=Callable[..., Any])`,
  so a type checker keeps the decorated function's own signature. This uses
  `TypeVar` rather than 3.12's `def tool[F: …]` syntax, which keeps the floor at
  **Python 3.11+**.
- Step 10's multi-line closures port as ordinary nested `def`s with the decorator
  applied — one statement, as in the Ruby.

## Verification

```
@r.tool("move", …) applied twice   ValueError: a tool named 'move' is already registered
move("north")                      'You move north into a torch-lit corridor.'   — the function, not the Tool
r.tools["move"]                    Tool(name='move', description='Move…', params=['direction'])
@r.tool("look", description=…)     registers with parameters={} — the argument is optional
r.dispatch("look")                 'A torch-lit corridor.'                        — handler called with no kwargs
```
