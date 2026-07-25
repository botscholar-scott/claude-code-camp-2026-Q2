# 0003 — `Context` is the mutable object; `Tool` and `Message` are frozen

**Status:** accepted; the tool-collection clauses are superseded by
[ADR 0004](0004-registry-owns-the-tool-catalog.md) from step 02 onward.
The frozen/mutable split and everything about `messages` still stand.
**Date:** 2026-07-25
**Applies to:** `week1_baseline/python/01_struct_skeleton` and later steps

## Context

[ADR 0001](0001-python-port-parsed-dataclasses.md) made `Config`, `Mud`, and
`Task` frozen dataclasses. Step 01 adds three more records — `Tool`, `Message`,
`Context` — and they do not all want the same treatment.

Reading forward through the Ruby ladder settles it:

- `lib/boukensha/tool.rb` and `lib/boukensha/message.rb` are **byte-identical
  from step 01 through step 12**. Nothing ever mutates a tool or a message; they
  are constructed, read, and thrown away. That is what an immutable value object
  looks like.
- `lib/boukensha/context.rb` is the opposite. It mutates from the very first
  step (`register_tool`, `add_message`), gains `working_dir` and
  `clear_messages!` at step 10, and at step 12 gains `compact_messages!`,
  `update_tokens`, `reset_turn_tokens`, `add_turn_tokens` and a writable
  `current_tokens` — while `task` is removed. `Context` *is* the accumulating
  state of a run.

Ruby's `Context` also hands out its collections directly (`attr_reader :messages,
:tools`), so every caller can reach past whatever the class wanted to guarantee.
`register_tool` is `@tools[tool.name] = tool` — a silent overwrite. Step 10
merges three tool libraries (`file_system`, `shell`, `mud`) into one context,
which is exactly where a silent overwrite turns into an agent-behaviour mystery.

## Decision

Split the mutability boundary along that line.

1. **`Tool` and `Message` are `@dataclass(frozen=True, slots=True)`.**
   `Tool.__post_init__` re-wraps `parameters` as a `MappingProxyType` over a copy,
   so the frozen record has no mutable hole. `Message.__post_init__` coerces
   `role` through the `Role` `StrEnum`, so an invalid role raises at the call
   site.
2. **`Context` is a plain mutable class that encapsulates its collections.**
   `tools` is exposed as a `MappingProxyType` built once in `__init__`; `messages`
   is typed `Sequence[Message]`. Mutation goes through `register_tool` and
   `add_message`, and `register_tool` raises `ValueError` on a duplicate name.

**Rejected: a frozen `Context` whose mutators return new instances.** Every later
step holds one long-lived context and mutates it in place — the agent loop, the
REPL's `/clear`, step 12's compaction. A persistent `Context` would force
rebinding through the whole call graph and leave stale references anywhere a
reference had been handed out.

## Consequences

- The frozen/mutable split is a stated boundary, not an inconsistency with
  ADR 0001. The rule is: value objects are frozen, the one object holding run
  state is not.
- Encapsulating the collections is what buys `register_tool`'s duplicate check.
  Ruby's exposed hash cannot have one.
- `Message` is hashable and safely shareable. `Tool` is **not** hashable — its
  `parameters` mapping proxy wraps a dict — but it is immutable, which is what was
  wanted. Nothing in the ladder puts a `Tool` in a set or uses one as a dict key;
  contexts key tools by `tool.name`.
- **The read-only guarantee is asymmetric, on purpose.** `ctx.tools["x"] = t`
  raises `TypeError`; `ctx.messages.append(m)` succeeds. Python has no zero-copy
  read-only list view, and a defensive `tuple()` copy on every access would be
  paid once per turn by the agent loop for no real gain. `messages` is read-only
  by type, not by enforcement. Returning the live list also means step 12's
  compaction can rebind `self._messages` without invalidating anything.
- `Context.task` and `Context.system` stay public, mutable attributes. Nothing in
  the ladder reassigns them, but freezing them would mean freezing `Context`.
- `Role` being a `StrEnum` rather than a bare `Enum` means members *are* strings.
  No conversion is needed at any boundary — interpolation, `json.dumps`, and
  comparison against `"tool_result"` all work unchanged.

## Verification

There is no test suite at this step (the example is the safety net), so the
hand-checks were run and their real output recorded here:

```
duplicate tool name       ValueError: a tool named 'move' is already registered on this context
bad role                  ValueError: 'assistnat' is not a valid Role
frozen Tool               FrozenInstanceError: cannot assign to field 'name'
frozen Message            FrozenInstanceError: cannot assign to field 'content'
ctx.tools["x"] = move     TypeError: 'mappingproxy' object does not support item assignment
tool.parameters[k] = {}   TypeError: 'mappingproxy' object does not support item assignment
ctx.messages.append(m)    allowed — the documented asymmetry above
hash(Message(...))        ok
hash(Tool(...))           TypeError: unhashable type: 'dict'   (accepted, see above)
```

Truncation, ellipsis-only-when-cut, and the omitted `tool_use_id`:

```
Tool("t", "x" * 200, {}, f)   ->  40 x's then a U+2026 ellipsis
Tool("t", "short", {}, f)     ->  description='short'   — no ellipsis
Message("user", "y" * 60)     ->  60 y's, no ellipsis   — nothing was cut
Message("user", "y" * 61)     ->  60 y's then a U+2026 ellipsis
Message("tool_result", "You move north into a torch-lit corridor.", tool_use_id="toolu_01X")
  -> Message(role='tool_result', tool_use_id='toolu_01X', content='You move north into a torch-lit corridor.')
```

And the step is still self-contained, the check ADR 0002 established:

```
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/01_struct_skeleton
ValueError: tasks.player is missing from settings.yaml
```
