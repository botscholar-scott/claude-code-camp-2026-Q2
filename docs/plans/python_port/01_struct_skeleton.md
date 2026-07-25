# Plan — Port `week1_baseline/ruby/01_struct_skeleton` to Python

**Target:** `week1_baseline/python/01_struct_skeleton`
**Source of truth:** `week1_baseline/ruby/01_struct_skeleton` (README + 8 source files)
**Predecessor:** `docs/plans/python_port/00_config` (step 00 plan), ADR 0001, ADR 0002
**Status:** agreed via grilling session; ready to implement.

---

## 1. Goal

Add the three data structures that every later step passes around — `Tool`,
`Message`, `Context` — to the Python port, on top of the configuration work from
step 00.

This is **not** a translation exercise. The Python tree is a deliverable that
gets significantly extended in week 2, so it is written as idiomatic Python and
is permitted to diverge from the Ruby where Python has a better answer. Every
divergence is deliberate and recorded (§8).

### Starting state — read this first

`week1_baseline/python/01_struct_skeleton` **already exists** as an untracked,
**exact byte-copy of `week1_baseline/python/00_config`** (verified with
`diff -rq`: no differences). This plan does not create the tree from scratch; it
adds to and modifies that copy. §4 marks every file KEEP / NEW / EDIT / REWRITE.

The port work is confined to that directory. Four files outside it are in scope,
each from a decision in §3: the launcher, `CONTEXT.md`, one ADR, and this plan.

### Reference material

| Path | Role |
|---|---|
| `week1_baseline/ruby/01_struct_skeleton/README.md` | the spec — but see §2, it contradicts the code |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha/tool.rb` | `Tool` behaviour to reproduce |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha/message.rb` | `Message` behaviour to reproduce |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha/context.rb` | `Context` behaviour to reproduce |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha.rb` | require order → Python export list |
| `week1_baseline/ruby/01_struct_skeleton/examples/example.rb` | output the example must mirror |
| `week1_baseline/ruby/01_struct_skeleton/lib/boukensha/config.rb` | **do not port** — see §2.3 |
| `week1_baseline/python/00_config/**` | the direct predecessor; step 01 is additive over it |
| `week1_baseline/bin/python/00_config` | launcher convention to copy |
| `.boukensha/` (repo root) | live fixture — language-agnostic, shared with Ruby, **not modified** |
| `docs/adr/0001-python-port-parsed-dataclasses.md` | why Config/Task are frozen dataclasses |
| `docs/adr/0002-python-port-fixes-known-limitations.md` | why the port fixes defects rather than carrying them |
| `CONTEXT.md` | glossary this step extends |

Forward references consulted during design, to check the shape ages well:

| Path | What it told us |
|---|---|
| `ruby/02_the_registry/lib/boukensha/registry.rb` | `dispatch` calls `tool.block.call(**args)`; `Registry` writes through `context.register_tool` |
| `ruby/03_prompt_builder/lib/boukensha/backends/anthropic.rb` | `role == :tool_result` maps to an API `role: "user"` + `tool_result` content block; `tool.parameters` becomes `input_schema.properties` |
| `ruby/03_prompt_builder/examples/example.rb` | restores `default_prompts_dir: Config::PROMPTS_DIR` — proof step 01's deletion was accidental |
| `ruby/05_agent_loop/lib/boukensha/agent.rb` | reads `context.task.max_iterations(task_settings)` — the class-plus-settings dance our instance-holding design removes |
| `ruby/10_standard_tool_library/lib/boukensha/context.rb` | `Context` gains `working_dir` and `clear_messages!` — confirms `Context` is mutable long-term |
| `ruby/11_tui/lib/boukensha/tui.rb` | the only external consumer of `context.tool_count` |
| `ruby/12_context/lib/boukensha/context.rb` | `task` is **removed**; `context_window`, `current_tokens`, `turn_tokens`, `compaction_threshold` and mutators arrive |
| `ruby/12_context/README.md` | **explicitly retracts `token_budget`** — see §2.1 |

`/Users/scott/src/GITROOT/omenking/claude-code-camp-2026-Q2/week1_baseline/python/01_struct_skeleton`
was consulted **only** to confirm one point of fact — that his port also follows
the Ruby code rather than the Ruby README on `Context`'s fields (no
`token_budget`). No code or design from it is copied or referenced; this port
took a different, more Pythonic approach at step 00 and continues it.

---

## 2. Upstream inconsistencies found, and what we do about them

Three discrepancies in the Ruby step were confirmed by reading the code and
running it. They shape §3, so they come first.

### 2.1 `token_budget` is documented but never implemented — and is later retracted

`ruby/01_struct_skeleton/README.md` lists `token_budget` in the `Context` table
("How many tokens the run is allowed to consume") and every printed example shows
`budget=8192`:

```
#<Context turns=2 tools=1 budget=8192>
```

But `context.rb` has no such field, at step 01 or at **any** step 01–12. A real
run of `./week1_baseline/bin/ruby/01_struct_skeleton` prints:

```
Context:  #<Context task=player turns=2 tools=1>
```

`budget=8192` appears only in the step 01 and step 02 READMEs. Step 12's README
then retracts the idea outright:

> Previously `token_budget` (8,192) was displayed as the limit — that was the
> *output* `max_tokens`, not the context window. And the cumulative session token
> sum was shown as usage, which grew without bound even after `/clear`. Both are
> fixed.

So `token_budget` is not merely unimplemented — it is a **documented modelling
error**, superseded at step 12 by `context_window` (200,000) plus
`current_tokens`. Porting it would mean knowingly importing a defect, which is
exactly what ADR 0002 refuses to do. **We do not port it.** No ADR is needed:
upstream already recorded the correction, so we are following it, not deciding
anything new. It is noted in the step README and the divergence table (§8) so a
future reader diffing the Ruby README against our code has an explanation.

### 2.2 The README's `Context` table omits `task`; the code has it

Inverse of 2.1. The README lists `system`, `messages`, `tools`, `token_budget`.
The code has `task`, `system`, `messages`, `tools`. `task` is live from step 01
through step 11 and is **removed** at step 12. We follow the code (§3, decision 1)
and hold `task`, knowing it is transient.

### 2.3 Step 01 deleted `prompts/` and `PROMPTS_DIR`; step 03 puts them back

`ruby/00_config` ships `prompts/system.md` and defines
`Config::PROMPTS_DIR`. `ruby/01_struct_skeleton` **deletes both**, and its
example drops the `default_prompts_dir:` argument, so the system prompt resolves
from the user's override directory only. `ruby/03_prompt_builder/examples/example.rb`
passes `default_prompts_dir: Boukensha::Config::PROMPTS_DIR` again.

That round trip makes it an accidental regression, not a lesson. `CONTEXT.md`
also defines a **Step** as "a self-contained, runnable tree"; without the shipped
default, a fresh `BOUKENSHA_DIR` yields no system prompt at all. **We keep both.**
Consequence: `config.py`, `tasks/base.py`, `tasks/player.py`, `prompts/system.md`
and `requirements.txt` are **byte-identical to step 00**, and step 01's diff over
step 00 is purely additive.

### 2.4 Out of scope, but recorded: `bin/ruby/00_config` is broken

Found while checking the launcher convention.

```bash
$ ./week1_baseline/bin/ruby/00_config
cd: ./week1_baseline/bin/ruby/../ruby/00_config: Not a directory
Could not locate Gemfile
```

It is missing one `..`. `bin/ruby/01_struct_skeleton` already has the correct
`../../ruby/...`. One-character fix, but it is a pre-existing Ruby-side bug and
touching it would put a stray Ruby edit in an otherwise purely-additive Python
diff. **Not fixed here** — see §10.

---

## 3. Decisions

Agreed one at a time in the grilling session.

| # | Decision | Choice |
|---|---|---|
| 1 | `Context` fields | `task`, `system`, `messages`, `tools`. **No `token_budget`** (§2.1) |
| 2 | `Context.task` holds | the resolved **`Task` instance**, not the class |
| 3 | `Context.system` | independent field, passed explicitly, never derived from `task` |
| 4 | Mutability boundary | `Tool`/`Message` frozen; `Context` mutable → **ADR 0003** |
| 5 | `Context` implementation | plain class, private collections, read-only accessors |
| 6 | `Tool`'s callable field | Ruby's `block` → **`handler`** |
| 7 | `Message.role` | **`StrEnum`**, coerced on construction → `ValueError` on a typo |
| 8 | `prompts/` + `PROMPTS_DIR` | **kept**; `config.py` and `tasks/` unchanged from step 00 (§2.3) |
| 9 | Module layout | `tool.py`, `message.py` (`Role` + `Message`), `context.py` |
| 10 | Repr style | Pythonic; `__repr__` only; truncate 40/60, ellipsis **only when cut** |
| 11 | Example content | mirrors the Ruby exactly — one `move` tool, two messages |
| 12 | Duplicate tool name | `register_tool` **raises `ValueError`** |
| 13 | Tests | **none** — hand-verified, checks recorded in ADR 0003 |
| 14 | Documentation | ADR 0003 + `CONTEXT.md` terms + step README. No ADR for `token_budget` (§2.1) |
| 15 | Glossary terms | Tool, Handler, Parameters, Message, Role, Tool result, Tool use id, Context, Turn |
| 16 | Broken Ruby launcher | recorded in out-of-scope, **not fixed** (§2.4) |
| 17 | Call style | `Tool`/`Message` dataclass defaults; `Context` `kw_only` |
| 18 | `turn_count` / `tool_count` | dropped in favour of `len()` — see §5.3 |

**Python floor stays 3.11+.** `slots=True` needs 3.10, `typing.Self` needs 3.11,
and decision 7's `enum.StrEnum` needs 3.11 — so `StrEnum` costs nothing.

---

## 4. File tree

Everything below `week1_baseline/python/01_struct_skeleton/` already exists as a
byte-copy of `00_config`. Marks are relative to that copy.

```
week1_baseline/python/01_struct_skeleton/
  README.md                     REWRITE  step-01 README (§6)
  requirements.txt              KEEP     PyYAML, python-dotenv — unchanged
  prompts/system.md             KEEP     unchanged (§2.3)
  boukensha/
    __init__.py                 EDIT     add Tool, Message, Role, Context exports
    config.py                   KEEP     byte-identical to step 00 (§2.3)
    tool.py                     NEW      Tool
    message.py                  NEW      Role, Message
    context.py                  NEW      Context
    _repr.py                    NEW      shared truncate() helper (§5.4)
    tasks/
      __init__.py               KEEP     empty
      base.py                   KEEP     byte-identical to step 00
      player.py                 KEEP     byte-identical to step 00
  examples/example.py           REWRITE  step-01 example (§5.6)

Outside the step directory:
week1_baseline/bin/python/01_struct_skeleton   NEW   launcher, chmod +x (§5.7)
CONTEXT.md                                    EDIT  9 glossary terms (§6.2)
docs/adr/0003-context-is-the-mutable-object.md NEW  (§6.3)
docs/plans/python_port/01_struct_skeleton     NEW   this file
```

**Untouched:** everything under `week1_baseline/ruby/`, `week1_baseline/python/00_config/`,
`week1_baseline/bin/ruby/`, `week1_baseline/bin/python/00_config`, the root
`.boukensha/` fixture, `docs/adr/0001`, `docs/adr/0002`, `.gitignore`.

---

## 5. Design

### 5.1 `boukensha/tool.py`

```python
@dataclass(frozen=True, slots=True, repr=False)
class Tool:
    name: str
    description: str
    parameters: Mapping[str, Any]
    handler: Callable[..., Any]

    def __post_init__(self) -> None: ...
    def __repr__(self) -> str: ...
```

- **`handler`, not `block`** (decision 6). "Block" is a Ruby language concept
  with no Python meaning; this port already ports behaviour rather than syntax
  (ADR 0001), and the rename joins the other Ruby-ism removals in §8.
  Step 02's `dispatch` becomes `tool.handler(**args)` — and note it loses Ruby's
  string-key-to-symbol `transform_keys` step entirely, since Python kwargs are
  already strings.
- `parameters` is the **JSON-Schema properties map**: `{"direction": {"type":
  "string", "description": "…"}}`. Confirmed by step 03's Anthropic backend,
  which passes it straight into `input_schema.properties` with
  `required: parameters.keys`. Typed `Mapping[str, Any]` rather than
  `Mapping[str, Mapping[str, Any]]` — the values are schema fragments and will
  gain non-mapping members (`enum`, `items`) later.
- `__post_init__` wraps `parameters` in a `MappingProxyType(dict(parameters))`
  via `object.__setattr__`, so a frozen `Tool` is genuinely immutable through the
  field rather than frozen-with-a-mutable-hole. Same treatment `Task.prompt_override`
  already gets in step 00, applied here in `__post_init__` because `Tool` has no
  factory method.
- `handler` is **required**, not optional. Every tool in every Ruby step is
  registered with a block, and step 02's `dispatch` calls it unconditionally.
- Construction is positional-or-keyword — the plain dataclass default, which is
  what Ruby's `Struct` gives (decision 17).

`__repr__` (decision 10):

```
Tool(name='move', description='Move the player in a direction (north, s…', params=['direction'])
```

`params=` — not `parameters=` — deliberately mirrors Ruby's `params=` label, and
is `list(self.parameters)`, matching Ruby's `parameters.keys`.

### 5.2 `boukensha/message.py`

```python
class Role(StrEnum):
    USER = "user"
    ASSISTANT = "assistant"
    TOOL_RESULT = "tool_result"


@dataclass(frozen=True, slots=True, repr=False)
class Message:
    role: Role
    content: str
    tool_use_id: str | None = None

    def __post_init__(self) -> None: ...
    def __repr__(self) -> str: ...
```

- `Role` lives here because it is `Message`'s vocabulary and nothing else owns it
  (decision 9).
- **`StrEnum`, coerced in `__post_init__`** (decision 7):
  `object.__setattr__(self, "role", Role(self.role))`. Ruby matches the role with
  `case msg.role when :tool_result`, so a typo'd symbol falls silently into `else`
  and ships a bogus role to the API. Coercing raises `ValueError` at the call
  site instead. Doing it in `__post_init__` rather than in `Context.add_message`
  means direct `Message("user", …)` construction is covered too, and
  `add_message` inherits the check for free.
- Because `StrEnum` subclasses `str`, no conversion is needed anywhere
  downstream: `f"{Role.USER}"` is `"user"`, `json.dumps` emits `"user"`, and
  step 03's backend can compare `msg.role == Role.TOOL_RESULT` or against the
  plain string `"tool_result"`. This is why `StrEnum` and not a bare `Enum`.
- `tool_use_id` defaults to `None`; it is only set on `TOOL_RESULT` messages.
  **Not validated** at this step — Ruby doesn't, and the pairing rule belongs to
  the backend that enforces it (step 03+).
- `role` and `content` stay positional (decision 17), matching
  `Message.new(role, content, tool_use_id)`.

`__repr__` (decision 10), omitting `tool_use_id` when `None`, mirroring Ruby's
conditional `id_tag`:

```
Message(role='user', content='Explore north and tell me what you find.')
Message(role='tool_result', tool_use_id='toolu_01X', content='You move north into a torch-lit corridor.')
```

`role='user'` — the `!r` of a `StrEnum` member renders as the value, so no
special-casing is needed.

### 5.3 `boukensha/context.py`

A **plain class, not a dataclass** (decision 5) — it is the one mutable object in
the package and its constructor takes no collections.

```python
class Context:
    def __init__(self, *, task: Task | None = None, system: str | None = None) -> None:
        self.task = task
        self.system = system
        self._messages: list[Message] = []
        self._tools: dict[str, Tool] = {}
        self._tools_view: Mapping[str, Tool] = MappingProxyType(self._tools)

    @property
    def messages(self) -> Sequence[Message]: ...
    @property
    def tools(self) -> Mapping[str, Tool]: ...

    def register_tool(self, tool: Tool) -> None: ...
    def add_message(self, role: Role | str, content: str, *,
                    tool_use_id: str | None = None) -> None: ...

    def __repr__(self) -> str: ...
```

- **`task` holds the resolved `Task` instance** (decision 2), i.e. what
  `Player.from_config(config)` returns. Ruby stores the *class* only because
  `Tasks::Base` is never instantiated; ADR 0001's whole point is that our `Task`
  is data. The payoff is visible at step 05, where Ruby needs
  `context.task.max_iterations(task_settings)` — threading the settings hash back
  in — and we need `context.task.max_iterations`, a plain field read. `Tool` is
  reachable as `context.task.provider` / `.model` / `.system_prompt` too.
- **`system` is an independent field**, never derived from `task.system_prompt`
  (decision 3). It looks redundant today, but it is the field that *survives*:
  step 12 removes `task` and keeps `system` as a required argument. Deriving it
  now would create a fallback that becomes dead code, and `context.system` is
  read-only in practice — step 03's `to_payload` consumes it, nothing rewrites it.
- **`task` and `system` are public and mutable attributes**; only the
  *collections* are encapsulated. Nothing in the ladder reassigns them, but
  freezing them would mean freezing `Context`, which decision 4 rules out.
- **Read-only accessors** (decision 5). `tools` returns a `MappingProxyType`
  built **once in `__init__`**, so enforcement is real and per-access cost is
  zero. `messages` returns the live list typed `Sequence[Message]` — Python has
  no zero-copy read-only list view, and a defensive `tuple()` copy on every access
  would be paid once per turn by the agent loop for no real gain. The asymmetry
  (enforced for `tools`, type-level for `messages`) is deliberate; document it in
  a comment. Returning the live list also means step 12's
  `compact_messages!`-equivalent can rebind `self._messages` without invalidating
  anything.
- **`register_tool` raises `ValueError` on a duplicate name** (decision 12).
  Ruby's `@tools[tool.name] = tool` replaces silently. Nothing in the ladder ever
  re-registers a name, and step 10 merges three tool libraries
  (`file_system`, `shell`, `mud`) into one context — a collision there is a bug
  you want at startup, not one you debug from odd agent behaviour. Message:
  `f"a tool named {tool.name!r} is already registered on this context"`.
- **`add_message` accepts `Role | str`** and builds the `Message`, which coerces
  and validates in its own `__post_init__` (§5.2). Both return `None`, matching
  Ruby, where the return values (`Array#<<` and a hash assignment) are incidental.
- **No `turn_count` / `tool_count`** (decision 18). `len(ctx.messages)` and
  `len(ctx.tools)` are the Python spelling. `turn_count` has no external consumer
  anywhere in the ladder — step 11/12's `tui.rb` keeps its own counter — and
  `context.tool_count` has exactly one, `tui.rb`, which becomes `len(ctx.tools)`.

`__repr__` (decision 10):

```
Context(task='player', turns=2, tools=1)
```

`task=` renders `self.task.name` when a task is present and `None` otherwise —
the analogue of Ruby's safe-navigating `task&.task_name`. `turns` and `tools` are
`len()` of the two collections, matching Ruby's `turn_count` / `tool_count`
labels.

### 5.4 `boukensha/_repr.py`

```python
def truncate(text: str, limit: int) -> str:
    """Cut to `limit` characters, appending an ellipsis only when something was cut."""
```

A private four-line module, shared by `Tool.__repr__` (limit 40) and
`Message.__repr__` (limit 60). Ruby inlines the slice in both structs; one helper
is better than duplicating the boundary logic, and a leading-underscore module
does not disturb decision 9's Ruby-comparable file layout.

Two Ruby artifacts are **not** reproduced:

- Ruby's `[0..40]` / `[0..60]` are *inclusive* ranges, so they cut at 41 and 61
  characters. We cut at a round 40 and 60.
- Ruby's `Message#to_s` appends `"..."` **unconditionally**. The real step-01 run
  prints `content=Explore north and tell me what you find....` — four dots,
  because that string is 40 characters and was never truncated. We append `…`
  (U+2026) only when the text was actually cut.

### 5.5 `boukensha/__init__.py`

Mirrors `lib/boukensha.rb`'s require order, plus `Role`:

```python
"""Boukensha — step 1: the struct skeleton."""

from .config import Config, Mud
from .context import Context
from .message import Message, Role
from .tasks.base import Task
from .tasks.player import Player
from .tool import Tool

__all__ = ["Config", "Context", "Message", "Mud", "Player", "Role", "Task", "Tool"]
```

No import cycle: `context` imports `message` and `tool` (and `Task` under
`TYPE_CHECKING` only, for the annotation), none of which import `context`.

### 5.6 `examples/example.py`

Mirrors `examples/example.rb` (decision 11) — one tool, two messages. Keeps step
00's `sys.path` insert and `BOUKENSHA_DIR` `setdefault`; the `REPO_ROOT` hop
count is unchanged from step 00 (`example.py` → `examples` → `01_struct_skeleton`
→ `python` → `week1_baseline` → repo root).

The one structural difference from the Ruby: step 00's `Player.from_config`
replaces Ruby's three-line `config.tasks(:player)` + `Player.system_prompt(...)`
dance, and — per §2.3 — we pass the library default prompt directory, which the
Ruby step 01 example cannot.

```python
config = Config.load()
player = Player.from_config(config)

ctx = Context(task=player, system=player.system_prompt)

ctx.register_tool(
    Tool(
        "move",
        "Move the player in a direction (north, south, east, west, up, down)",
        {"direction": {"type": "string", "description": "The direction to move"}},
        lambda direction: f"You move {direction} into a torch-lit corridor.",
    )
)

ctx.add_message("user", "Explore north and tell me what you find.")
ctx.add_message("assistant", "Sure, let me head north and take a look.")

print("=== Boukensha Step 1: Struct Skeleton ===")
print()
print(f"Config:   {config!r}")
print(f"Context:  {ctx!r}")
print(f"Tool:     {ctx.tools['move']!r}")
print("Messages:")
for message in ctx.messages:
    print(f"  {message!r}")
```

Note the header string is `Step 1`, matching the Ruby's, not `Step 01`.

### 5.7 `week1_baseline/bin/python/01_struct_skeleton`

Byte-copy of `bin/python/00_config` with the one path changed, then `chmod +x`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."

# Use the repo-root virtualenv when there is one, otherwise the system python3.
PY="$REPO_ROOT/.venv/bin/python"
[ -x "$PY" ] || PY="python3"

cd "$SCRIPT_DIR/../../python/01_struct_skeleton"
exec "$PY" examples/example.py
```

### 5.8 `requirements.txt`

**Unchanged** — `PyYAML`, `python-dotenv`. The three new structs are pure standard
library (`dataclasses`, `enum`, `types`, `typing`, `collections.abc`); `Config`
still needs both dependencies.

---

## 6. Documentation to write

### 6.1 `week1_baseline/python/01_struct_skeleton/README.md`

Port of the Ruby step-01 README with Python names, keeping its structure
(intro → Design Considerations → Data Structures tables → Run Example), plus:

- **Setup** — same as step 00: 3.11+ floor, repo-root `.venv`, path updated to
  this step's `requirements.txt`.
- **Code Changes** table — the new and edited files only, noting explicitly that
  `config.py`, `tasks/`, and `prompts/` are unchanged from step 00.
- **Data Structures** — three tables mirroring the Ruby's, with `handler` in place
  of `block` and `Role` documented as the closed three-value set.
- **A note on `token_budget`** — the §2.1 finding, short: documented in the Ruby
  README, never implemented, retracted at step 12, deliberately not ported.
- **Mutability** — one paragraph: `Tool` and `Message` are frozen, `Context` is
  not, pointing at ADR 0003.
- **Run Example** — `./week1_baseline/bin/python/01_struct_skeleton`.
- **Expected output** — ***generated from an actual run, not hand-written.***
  Step 00 learned this the hard way: the Ruby step-00 README's sample block is
  stale because it shows the shipped default prompt while the repo fixture's
  override actually wins. Run it, paste what it prints.
- **Divergences from the Ruby port** — the §8 table, continuing step 00's
  numbering context (this step's rows are new; step 00's table stays in step 00's
  README).

### 6.2 `CONTEXT.md`

Nine terms, definitions only, in the existing definition-list style
(decision 15). No implementation detail, no Python syntax.

| Term | Substance of the definition |
|---|---|
| **Tool** | A capability the agent may invoke: a name, a description shown to the agent, a parameter schema, and the code that runs. |
| **Handler** | The callable a tool runs when invoked. Ruby calls this the tool's *block*. |
| **Parameters** | A tool's arguments, as a JSON-Schema properties map. Becomes the provider's `input_schema.properties`. |
| **Message** | One unit of conversation — who spoke, what was said, and for a tool result, which call it answers. |
| **Role** | Who is speaking in a message. Exactly three: `user`, `assistant`, `tool_result`. |
| **Tool result** | A **pseudo-role**. Not a provider role — backends translate it into a provider `user` message carrying a `tool_result` content block. |
| **Tool use id** | The identifier pairing a tool result to the tool call that requested it. The pairing must be exact or the provider rejects the call. |
| **Context** | Everything one API call needs: the system prompt, the full message history, the registered tools, and the task that owns them. Nothing the agent needs lives outside it. |
| **Turn** | One message in the history. A context's turn count is the length of its message history. |

Note for the writer: **Tool result** and **Tool use id** are the two that earn
their place — both are non-obvious and both are load-bearing at step 03. Keep
their definitions precise.

### 6.3 `docs/adr/0003-context-is-the-mutable-object.md`

Same format as ADR 0001/0002 (Status / Date / Applies to / Context / Decision /
Consequences).

- **Context** — ADR 0001 made `Config`, `Mud`, and `Task` frozen dataclasses. Step
  01 adds three more records, and they do not all want the same treatment.
  `tool.rb` and `message.rb` are **byte-identical from step 01 through step 12** —
  genuinely immutable value objects. `context.rb` is not: it mutates from the
  start (`register_tool`, `add_message`), gains `clear_messages!` at step 10, and
  at step 12 gains `compact_messages!`, `update_tokens`, `reset_turn_tokens`,
  `add_turn_tokens` and a writable `current_tokens`. `Context` *is* the
  accumulating state of a run.
- **Decision** — `Tool` and `Message` are `frozen=True, slots=True`. `Context` is
  a plain mutable class that encapsulates its collections: `tools` is exposed as a
  `MappingProxyType` built once, `messages` as a `Sequence`, and mutation goes
  through `register_tool` / `add_message`. Rejected: a frozen `Context` whose
  mutators return new instances — every later step holds one long-lived context
  and mutates it in place (the agent loop, the REPL's `/clear`, step 12's
  compaction), so a persistent `Context` would force rebinding through the whole
  call graph and leave stale references everywhere.
- **Consequences** — the frozen/mutable split is a stated boundary, not an
  inconsistency with ADR 0001; the value objects are hashable and safely shareable
  while the one mutable object is the one place run state lives; encapsulating the
  collections buys `register_tool`'s duplicate check, which Ruby's exposed hash
  cannot have; the asymmetry between real enforcement on `tools` and type-level
  on `messages` is accepted, since Python has no zero-copy read-only list view
  and a per-access copy would be paid once per turn by the agent loop.
- **Verification** — per decision 13 there is no test suite, so record the
  hand-checks here the way ADR 0002 does (the §9 list).

---

## 7. Implementation order

1. Confirm the starting state: `diff -rq week1_baseline/python/00_config week1_baseline/python/01_struct_skeleton`
   should report **no differences**. If it does not, stop and re-read §1.
2. `boukensha/_repr.py`.
3. `boukensha/tool.py` → `boukensha/message.py` → `boukensha/context.py`.
4. `boukensha/__init__.py` (add the four exports).
5. `examples/example.py`.
6. `week1_baseline/bin/python/01_struct_skeleton`, `chmod +x`.
7. Run it; **capture the real output**.
8. Run the §9 hand-checks; capture the real error messages.
9. `README.md`, using the captured output from steps 7–8.
10. `CONTEXT.md` additions, `docs/adr/0003`.
11. Final `diff -rq` against step 00 to confirm nothing outside §4's NEW/EDIT/REWRITE
    list drifted.

---

## 8. Divergences from the Ruby port

Step 00's divergences (ADR 0001/0002 — frozen dataclasses, `Config.load()`,
typed `mud`, `.yml` accepted, and so on) all still apply and are unchanged. These
are the rows step 01 adds.

| # | Ruby | This port | Why |
|---|---|---|---|
| 1 | `Context` documents `token_budget` (`budget=8192`) | field absent | never implemented at any step; step 12's README retracts it as output `max_tokens` mistaken for the context window (§2.1) |
| 2 | `Context#task` holds the task **class** | holds the resolved `Task` **instance** | ADR 0001 makes `Task` data; removes step 05's class-plus-settings-hash dance |
| 3 | `Tool` field `block` | `handler` | "block" is a Ruby language concept with no Python meaning |
| 4 | `role` is a bare symbol; a typo falls into `case`'s `else` | `Role(StrEnum)`, coerced on construction | a bad role raises `ValueError` at the call site instead of shipping to the API |
| 5 | `attr_reader :messages, :tools` hands out the live Array/Hash | read-only accessors; mutation via `register_tool` / `add_message` | makes the duplicate check in #6 possible at all |
| 6 | `register_tool` replaces silently | raises `ValueError` on a duplicate name | step 10 merges three tool libraries into one context; a collision is a startup bug, not an agent-behaviour mystery |
| 7 | `parameters` is a plain mutable Hash on a `Struct` | `MappingProxyType` on a frozen dataclass | frozen with a mutable hole is not frozen |
| 8 | `turn_count` / `tool_count` methods | `len(ctx.messages)` / `len(ctx.tools)` | Python spelling; `turn_count` has no consumer, `tool_count` has one (step 11's TUI) |
| 9 | `#<Tool …>` / `#<Message …>` / `#<Context …>` | `Tool(…)` / `Message(…)` / `Context(…)` | continues step 00's divergence #10; mixing the two styles in one program would be incoherent |
| 10 | `to_s` and `inspect` defined separately | `__repr__` only | Python's `__str__` falls back to `__repr__`, so one method covers both |
| 11 | truncates at 41 / 61 chars (inclusive ranges) | 40 / 60 | the Ruby counts are an inclusive-range artifact |
| 12 | `Message#to_s` always appends `"..."` | appends `…` only when text was cut | the Ruby prints `find....` for a 40-char string that was never truncated |
| 13 | step 01 deletes `prompts/` and `PROMPTS_DIR` | both kept | accidental regression — step 03 restores them; a step must be self-contained (§2.3) |
| 14 | `dispatch` does `args.transform_keys(&:to_sym)` before calling | `tool.handler(**args)` | Python kwargs are already strings; the Ruby symbol/string gotcha does not exist here |

Row 14 is forward-looking — it lands at step 02 — but is recorded now because it
is a consequence of the `handler` design, not of step 02's `Registry`.

---

## 9. Verification

`examples/example.py` is the entire safety net (decision 13 — no test suite).

```bash
./week1_baseline/bin/python/01_struct_skeleton   # new
./week1_baseline/bin/ruby/01_struct_skeleton    # Ruby, for comparison
```

Check by eye against the Ruby run:

- `Config(dir='…/.boukensha', tasks=['player'])` — resolves to the repo-root
  fixture, and **prints no password** (step 00's hand-written `__repr__`)
- `Context(task='player', turns=2, tools=1)` — the same three numbers the Ruby
  prints, and **no `budget=`**
- `Tool(name='move', description='…', params=['direction'])`
- two `Message(…)` lines, user then assistant, with **no spurious trailing dots**
  (the Ruby prints `find....`; we print `find.`)

Then the hand-checks for the behaviour the example cannot show. Capture the real
messages for ADR 0003 and the README:

```python
# duplicate tool name  -> ValueError, not a silent replace
ctx.register_tool(move); ctx.register_tool(move)

# bad role             -> ValueError at the call site, not a bogus API role
ctx.add_message("assistnat", "…")

# truncation boundary  -> ellipsis only when something was cut
Tool("t", "x" * 200, {}, lambda: None)   # description ends with …
Tool("t", "short", {}, lambda: None)     # description has no …

# read-only collections -> TypeError
ctx.tools["x"] = move

# frozen value objects  -> FrozenInstanceError
move.name = "other"

# tool_result message   -> tool_use_id shown; plain message -> omitted
Message("tool_result", "You move north …", tool_use_id="toolu_01X")
```

And confirm the step is still self-contained with an empty config dir, the check
ADR 0002 established:

```bash
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/01_struct_skeleton
# expect: ValueError "tasks.player is missing from settings.yaml" — the step-00
# behaviour, unchanged
```

---

## 10. Out of scope

- **`week1_baseline/bin/ruby/00_config` is broken** (§2.4):
  `cd "$(dirname "$0")/../ruby/00_config"` needs `../../ruby/00_config`, as
  `bin/ruby/01_struct_skeleton` already has. One character. Pre-existing Ruby-side
  bug; fix it in its own change so this one stays purely additive Python
  (decision 16).
- Any modification to `week1_baseline/ruby/`, to `week1_baseline/python/00_config/`,
  or to the root `.boukensha/` fixture.
- Amending ADR 0001 or ADR 0002. ADR 0003 states the frozen/mutable boundary as
  an extension, not a correction.
- A test suite, `pytest`, or any test-running convention (decision 13).
- Porting steps `02_the_registry` … `12_context`. In particular `Registry`,
  `UnknownToolError`, and `dispatch` are step 02's, even though §8 row 14 already
  anticipates them.
- Unifying the two launcher conventions, `pyproject.toml`, pinned dependency
  versions, or a lockfile.
