# 02 · The Tool Registry (Python)

The Tool Registry is how Boukensha manages what capabilities the agent can use.

It has two jobs:

1. storing tools
2. dispatching tools when asked

This is the Python port of `week1_baseline/ruby/02_the_registry`, built on top of
[step 01](../01_struct_skeleton/README.md). It reproduces the same behaviour but
is written as idiomatic Python; the deliberate differences are listed under
[Divergences from the Ruby port](#divergences-from-the-ruby-port).

**Step 02 is the first step that is not purely additive.** It *removes* the tool
table from `Context`. Step 01 is untouched and remains a valid frozen snapshot of
the old design — see [Why the tools moved](#why-the-tools-moved).

## Why the tools moved

In the Ruby, `Registry.new(context)` takes a context and writes tools *through*
it: the table lives on `Context`, and the registry is a thin façade over it. The
step's own README says this is wrong:

> We now register tools with the Registry but our code still has direct
> registration and tools in context. This likely should have been reworked.
>
> Checking the final baseline example, we did correct the issue.
> **The context should have reference to tools[] its currently using, and the
> full table of tools registered should live on the Registry.**
>
> We'll correct this manually in a future step and we will leave things place.

The correction never lands. `registry.rb` is byte-identical from step 02 through
step 12, and `context.rb` still owns `@tools` at step 12. So it is a defect the
author named, whose fix he specified, and which nobody implemented.

[ADR 0002](../../../docs/adr/0002-python-port-fixes-known-limitations.md) commits
this port to fixing known limitations rather than carrying them forward, and the
step named for the Registry is the cheapest possible place to change this shape.
So here **`Registry` owns the only tool table** and `Context` has none. The full
provenance and the rejected alternatives are in
[ADR 0004](../../../docs/adr/0004-registry-owns-the-tool-catalog.md).

## Setup

Requires **Python 3.11+**. Nothing in this step raises the floor.

```bash
python3 -m venv .venv                                                 # at the repo root
.venv/bin/pip install -r week1_baseline/python/02_the_registry/requirements.txt
```

`requirements.txt` is unchanged from steps 00/01 (`PyYAML` and `python-dotenv`,
both still needed by `Config`). Everything new in this step is pure standard
library.

## Code Changes

`config.py`, `tool.py`, `message.py`, `_repr.py`, `tasks/`, `prompts/` and
`requirements.txt` are **byte-identical to step 01**.

| File | Purpose |
|------|---------|
| `boukensha/registry.py` | **new** — `Registry` |
| `boukensha/errors.py` | **new** — `BoukenshaError`, `UnknownToolError` |
| `boukensha/context.py` | edited — **all tool state removed** |
| `boukensha/__init__.py` | edited — exports `Registry`, `BoukenshaError`, `UnknownToolError` |
| `examples/example.py` | rewritten — registers two tools, dispatches two, catches one unknown name |

`Tool` needs no change at all. Its `handler` field was named for exactly this
moment: `dispatch` calls `tool.handler(**args)`.

## How It Works

The agent NEVER calls a tool directly. It emits a structured request — a name and
a set of arguments — and the Registry looks the tool up and runs it.

```
Agent:    "Hey registry, call move with direction='north'"
Registry: "looking up 'move' in the tool table"
Registry: "found it — calling the handler with the provided args"
Registry: "here's the result"
Agent:    "thanks buddy"
Registry: "that's why you pay me the big tokens"
```

---

## `boukensha.Registry`

| Member | Description |
|---|---|
| `Registry()` | Takes no arguments. The table lives here, so there is nothing to pass in. |
| `tools` | The registered tools, keyed by name, in registration order. Read-only. |
| `tool(name, *, description, parameters=None)` | Decorator factory — registers the function it decorates |
| `dispatch(name, args=None)` | Looks a tool up by name and calls its handler with `args` as keywords |

`Registry` holds no reference to a `Context`, and `Context` holds none to a
`Registry`. They are orthogonal — a context is the conversation, a registry is
the capability set — and the caller composes them:

```python
ctx = Context(task=player, system=player.system_prompt)
registry = Registry()
```

Step 03's `PromptBuilder` takes both, and step 05's `Agent(context=…, registry=…)`
already has that shape in the Ruby.

### Registering a tool

Ruby attaches the handler with a trailing block. Python has no block, so the
handler arrives as the decorated function:

```python
@registry.tool(
    "move",
    description="Move the player in a direction (north, south, east, west, up, down)",
    parameters={"direction": {"type": "string", "description": "The direction to move"}},
)
def move(direction):
    return f"You move {direction} into a torch-lit corridor."
```

The decorator **returns the function unchanged**, so `move` stays a plain
callable you can invoke and test directly:

```python
>>> move("north")
'You move north into a torch-lit corridor.'
```

Ruby's `registry.tool(...)` returns the `Tool` instead. Ours is reachable as
`registry.tools["move"]` when it is wanted. The reasoning, including why there is
no `handler=` keyword alternative, is in
[ADR 0005](../../../docs/adr/0005-tools-register-via-decorator.md).

`parameters` is optional and defaults to `None`, not `{}` — no mutable default.
A tool with no arguments just omits it:

```python
@registry.tool("look", description="Look around the current room")
def look():
    return "A torch-lit corridor."
```

Per-argument `description` strings are worth writing. Step 03's backends pass
`parameters` straight through as `input_schema.properties`, so that string is how
the model learns what the argument means. (Ruby's step-02 example drops the inner
`description` its own step-01 example had; this port keeps it.)

### `tools` is read-only

`tools` is a `MappingProxyType` built once in `__init__` — the same pattern
`Context` used at step 01 for the table that now lives here:

```python
>>> registry.tools["x"] = some_tool
TypeError: 'mappingproxy' object does not support item assignment
```

There is no `tool_names()` method. `list(registry.tools)` and
`len(registry.tools)` say it in the language the reader already knows, which is
the same call step 01 made for `turn_count` / `tool_count`.

### Dispatch

```python
>>> registry.dispatch("shout", {"message": "dragon spotted"})
'DRAGON SPOTTED'
>>> registry.dispatch("look")
'A torch-lit corridor.'
```

`args` is optional. There is no key translation: Ruby does
`args.transform_keys(&:to_sym)` because its blocks want symbols, and Python
kwargs are already strings.

---

## Errors

```
BoukenshaError
└── UnknownToolError
```

`BoukenshaError` is a base class Ruby does not have. It costs one line, lets a
caller write `except BoukenshaError`, and the ladder shows it will be wanted —
step 03 adds an unsupported-model error and step 05 adds two more. Retrofitting a
base once those are in use would change their MRO.

`UnknownToolError` is raised when `dispatch` is given a name that has no
registered tool. A harness needs explicit error boundaries; an unrecognised tool
name should never silently fail.

```python
>>> registry.dispatch("flee")
UnknownToolError: No tool registered as 'flee'
```

It is deliberately **not** a `KeyError` subclass, even though a failed lookup is
the obvious reading and `except KeyError` would then work. `KeyError.__str__`
returns the *repr* of its argument, so the message would print wrapped in a
second set of quotes:

```
# if it subclassed KeyError
UnknownToolError caught: "No tool registered as 'flee'"

# as written
UnknownToolError caught: No tool registered as 'flee'
```

**Duplicate registration is a plain `ValueError`**, not a Boukensha error. It is
a programmer error at startup — you took a name that was already taken — and
`ValueError` is precisely that. Step 01 raised the same error from
`Context.register_tool`; only the owner moved.

```python
>>> @registry.tool("move", description="…")
... def move_again(direction): ...
ValueError: a tool named 'move' is already registered
```

Note that this fires when the decorator is *applied*, at `def` time — so a
collision surfaces at import, not at dispatch. Step 10 merges three tool
libraries into one registry, which is exactly where you want that.

---

## What `Context` lost

`Context` no longer has `_tools`, `tools`, or `register_tool`, and its repr no
longer counts tools:

```python
>>> ctx.tools
AttributeError: 'Context' object has no attribute 'tools'
>>> ctx.register_tool
AttributeError: 'Context' object has no attribute 'register_tool'
>>> ctx
Context(task='player', turns=0)
```

What remains is `task`, `system`, `messages`, and `add_message`.

The tool count is `len(registry.tools)` — which is what step 11's TUI will read
in place of the Ruby's `context.tool_count`.

[ADR 0003](../../../docs/adr/0003-context-is-the-mutable-object.md) describes the
old shape and is **not** edited: it stays exactly true of
`week1_baseline/python/01_struct_skeleton`, which is a frozen, self-contained
tree. Only its Status line now points at ADR 0004. Most of 0003 — the
frozen/mutable split, and everything about `messages` — still stands unchanged.

## A note on `token_budget`

The Ruby step-02 README shows `Context: #<Context turns=0 tools=2 budget=8192>`.
As at step 01, **`budget` is not implemented at any step**, and step 12's README
retracts the idea outright — `8192` was the *output* `max_tokens` mistaken for
the context window. The Ruby README also drops the `task=` its own code prints.

A real run of `./week1_baseline/bin/ruby/02_the_registry` prints
`#<Context task=player turns=0 tools=2>`. Neither README line is what the code
does; ours below is generated from an actual run.

## Considerations

**Unknown arguments raise `TypeError` from Python itself.** Nothing is guarded,
which matches the Ruby:

```python
>>> registry.dispatch("move", {"drection": "north"})
TypeError: move() got an unexpected keyword argument 'drection'. Did you mean 'direction'?
```

**Handler exceptions propagate uncaught**, also as in Ruby. Turning a tool
failure into a tool *result* the model can read is step 05's `handle_tool_calls`;
the registry's job is to dispatch, not to recover.

**Ruby's string→symbol translation has no Python analogue.** Its
`## Considerations` section makes the string-key/symbol-key gotcha visible as a
lesson. In Python there is nothing to make visible: `handler(**args)` takes
string keys, which is what the API returns.

## Run Example

```bash
./week1_baseline/bin/python/02_the_registry
```

Actual output against this repo's `.boukensha/` fixture:

```
=== Boukensha Step 2: The Tool Registry ===

Config:   Config(dir='/Users/scott/src/GITROOT/botscholar-scott/claude-code-camp-2026-Q2/.boukensha', tasks=['player'])
Context:  Context(task='player', turns=0)
Tools:
  Tool(name='move', description='Move the player in a direction (north, s…', params=['direction'])
  Tool(name='shout', description='Shout a message so everyone in the zone …', params=['message'])

Dispatching 'shout' with message='dragon spotted'...
Result: DRAGON SPOTTED

Dispatching 'move' with direction='north'...
Result: You move north into a torch-lit corridor.

UnknownToolError caught: No tool registered as 'flee'
```

Compare with `./week1_baseline/bin/ruby/02_the_registry`:

```
=== BOUKENSHA Step 2: Tool Registry ===

Config:  #<Boukensha::Config dir=/Users/…/.boukensha tasks=player>
Context: #<Context task=player turns=0 tools=2>
Tools:
  #<Tool name=move description=Move the player in a direction (north, so params=[:direction]>
  #<Tool name=shout description=Shout a message so everyone in the zone c params=[:message]>

Dispatching 'shout' with message='dragon spotted'...
Result: DRAGON SPOTTED

Dispatching 'move' with direction='north'...
Result: You move north into a torch-lit corridor.

UnknownToolError caught: No tool registered as 'flee'
```

Both dispatch results are identical, both list `move` then `shout` in
registration order, and both catch the unknown name rather than dying on it. The
one substantive difference is the context line: no `tools=2`, because this
context does not own any.

The `Context` here is **inert** — it is built and printed to show step 01's work
carrying forward and to make the repr change visible, but nothing in step 02
touches it. The context carries the conversation, the registry carries the
capabilities, and step 03 is where they meet.

## Divergences from the Ruby port

Steps 00 and 01's divergences all still apply. These are the rows step 02 adds.

| # | Ruby | This port | Why |
|---|---|---|---|
| 1 | `Context` owns `@tools`; `Registry` writes through it | `Registry` owns the only tool table; `Context` has none | the author flagged this defect and specified the fix but never shipped it; ADR 0002 fixes rather than carries |
| 2 | `Registry.new(context)` | `Registry()` | with the table here, the argument has nothing to do |
| 3 | `Context#register_tool` | deleted; registration is `Registry.tool` | one owner, one path |
| 4 | `#<Context … tools=2>` | `Context(task='player', turns=0)` | an object that does not own tools should not count them |
| 5 | trailing block attaches the handler | decorator factory | Python has no blocks; a `lambda` cannot hold step 10's multi-line closures |
| 6 | `registry.tool` returns the `Tool` | returns the handler unchanged | the decorated name stays a callable you can invoke and test |
| 7 | `UnknownToolError < StandardError`, flat | `BoukenshaError` base, `UnknownToolError` under it | three more errors join by step 05; retrofitting a base later changes the MRO |
| 8 | `name.to_s` in `tool` and `dispatch` | no coercion | Ruby coerces because symbols; Python names are already `str` |
| 9 | `args.transform_keys(&:to_sym)` | `handler(**args)` | recorded at step 01 (row 14); Python kwargs are already strings |
| 10 | `tool_names` (author's personal fork, step 10 only) | not ported | `list(registry.tools)`; consistent with step 01's `turn_count` / `tool_count` |
| 11 | step 02's example drops the per-argument `description` | restored | it becomes `input_schema.properties`; it is how the model reads the argument |
| 12 | README run path `./week1_baseline/bin/01_the_registry` | correct Python path | the Ruby README's path is missing `ruby/` and carries step 01's number |

Rows 1–4 are one decision seen from four angles;
[ADR 0004](../../../docs/adr/0004-registry-owns-the-tool-catalog.md) is the
single record.
