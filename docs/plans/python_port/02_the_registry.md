# Plan — Port `week1_baseline/ruby/02_the_registry` to Python

**Target:** `week1_baseline/python/02_the_registry`
**Source of truth:** `week1_baseline/ruby/02_the_registry` (README + 2 new source files)
**Predecessor:** `docs/plans/python_port/01_struct_skeleton`, ADR 0001, ADR 0002, ADR 0003
**Status:** agreed via grilling session; ready to implement.

---

## 1. Goal

Add the tool **Registry** — the object that stores what the agent can do and
runs a tool when the agent asks for it by name — plus the error boundary for an
unrecognised tool name.

This is **not** a translation exercise. The Python tree is a deliverable that
gets significantly extended in week 2, so it is written as idiomatic Python and
is permitted to diverge from the Ruby where Python has a better answer. Every
divergence is deliberate and recorded (§8).

Step 02 makes the single largest structural divergence of the port so far: the
tool table moves off `Context` and onto `Registry`. §2 is the evidence for that;
read it before §3.

### Starting state — read this first

`week1_baseline/python/02_the_registry` **already exists** as an untracked,
**exact byte-copy of `week1_baseline/python/01_struct_skeleton`** (verified with
`diff -rq`: only `__pycache__` differs). This plan does not create the tree from
scratch; it adds to and modifies that copy. §4 marks every file
KEEP / NEW / EDIT / REWRITE.

`week1_baseline/bin/python/02_the_registry` **also already exists**, is correct,
and needs only an executable-bit check. It is the step-01 launcher with the one
path changed.

**Step 02 is the first non-additive step.** Steps 00→01 and every Ruby step are
purely additive over their predecessor. This one *deletes* code from
`context.py`. `week1_baseline/python/01_struct_skeleton` is untouched and remains
a valid frozen snapshot of the old design — which is exactly what ADR 0003 goes
on describing (§6.4).

### Reference material

| Path | Role |
|---|---|
| `week1_baseline/ruby/02_the_registry/lib/boukensha/registry.rb` | the 20 lines this step is named for |
| `week1_baseline/ruby/02_the_registry/lib/boukensha/errors.rb` | `UnknownToolError` |
| `week1_baseline/ruby/02_the_registry/examples/example.rb` | the behaviour the example must reproduce |
| `week1_baseline/ruby/02_the_registry/README.md` | the spec — but see §2.3 and §2.4, it contradicts the code twice |
| `week1_baseline/ruby/02_the_registry/lib/boukensha/context.rb` | **unchanged from step 01** — no delta to port |
| `week1_baseline/python/01_struct_skeleton/**` | the direct predecessor |
| `week1_baseline/bin/python/02_the_registry` | launcher — already present and correct |
| `docs/adr/0003-context-is-the-mutable-object.md` | the ADR this step partially supersedes |
| `CONTEXT.md` | glossary this step both extends **and corrects** |

Forward references consulted during design:

| Path | What it told us |
|---|---|
| `ruby/03_prompt_builder/lib/boukensha/prompt_builder.rb` | `PromptBuilder.new(context, backend)`, reaching `@context.messages` and `@context.tools` — the call site our §3 decision 1 changes |
| `ruby/05_agent_loop/lib/boukensha/backends/*.rb` | `tools: tools.nil? ? to_tools(context.tools) : tools` — the ternary our design deletes (§2.2) |
| `ruby/05_agent_loop/lib/boukensha/agent.rb` | `Agent.new(context:, registry:, …)` already takes **both** objects; `wrap_up` calls `@client.call(tools: [])` |
| `ruby/07_the_run_dsl/lib/boukensha/run_dsl.rb` | `RunDSL#tool` forwards straight to `@registry.tool` — a decorator at the registry surfaces cleanly here |
| `ruby/07,09,10/lib/boukensha.rb` | `registry = Registry.new(ctx)` — the construction order our design flips |
| `ruby/10_standard_tool_library/lib/boukensha/tools/file_system.rb` | `register(registry, working_dir:)` takes the **registry only**; handlers are multi-line closures over `root`/`resolve` |
| `ruby/11_tui/lib/boukensha/tui.rb` | the only reader of `context.tool_count` |
| `ruby/12_context/lib/boukensha/context.rb` | `Context` keeps `@tools` to the very end — the flagged fix never lands (§2.1) |

---

## 2. Upstream findings, and what we do about them

### 2.1 The tool-ownership defect: flagged by the author, never fixed

This is the finding that shapes the whole step, and it needed provenance work
because two upstream repos disagree.

| Repo | Commit | Ownership note in step-02 README? | `tool_names` on `Registry` at step 10? |
|---|---|---|---|
| `ExamProCo/claude-code-camp-2026-Q2` (course canon) | `ea92f4d` 2026-07-13, Andrew Brown | **no** | no |
| `omenking/claude-code-camp-2026-Q2` (author's personal fork) | `7387182` 2026-07-13, Andrew Brown, *"bring over ruby code for 03_prompt_builder"* | **yes** | yes |
| ours | `ec7db92` 2026-07-25, Scott Rankin, *"clarification from the videos…"* | **yes** — restored by hand from the course videos | no |

Our copy started byte-identical to ExamProCo and therefore lacked the note; it was
added back at `ec7db92`, before implementation, to match what Andrew says on the
video for this step. So the ownership note is in our tree on purpose, and the
provenance below is about where it did and did not reach upstream.

The personal fork's README ends with a `## Considerations` section the course
repo has never contained:

> We now register tools with the Registry but our code still has direct
> registration and tools in context. This likely should have been reworked.
>
> Checking the final baseline example, we did correct the issue.
> **The context should have reference to tools[] its currently using, and the
> full table of tools registered should live on the Registry.**
>
> We'll correct this manually in a future step and we will leave things place.

The same fork also carries an abandoned mid-word comment, `# This isn'`, directly
above `Context#register_tool` — the same thought, started and dropped.

Three facts about that note:

1. **It is the author's own writing**, added while he was working through step 03,
   and he restates it on video. It is not a third-party opinion.
2. **It never reached the course repo.** ExamProCo's step-02 README has no such
   section at any commit (`git log -S "full table of tools registered"` returns
   nothing).
3. **The stated correction never lands anywhere.** `registry.rb` is byte-identical
   (`7eccb51c…`) from step 02 through step 12 in ExamProCo; the personal fork
   diverges only at step 10 by adding `tool_names`, which still reads
   `@context.tools.keys`. `context.rb` owns `@tools` at step 12 in **both** repos
   and in both language ports. The claim "checking the final baseline example, we
   did correct the issue" is not borne out by any code in either repo.

So: a defect the author named, whose fix he specified, and which nobody
implemented. ADR 0002 already commits this port to fixing known limitations
rather than carrying them forward, and step 02 — the step named for the Registry
— is the cheapest possible place to change this shape. **We implement it**
(§3 decision 1), and go one step further than the note (§2.2).

### 2.2 Going further than the note: `Context` holds no tools at all

The note asks for a *split*: the catalog on the `Registry`, and on the `Context` a
reference to "tools[] its currently using". We implement the first half and
decline the second, because the subset has no consumer yet and one access path is
better than two.

The evidence that "tools currently in use" is a real concept: from step 05 every
backend carries

```ruby
tools: tools.nil? ? to_tools(context.tools) : tools
```

and its one real caller is `Agent#wrap_up`, which sends `@client.call(tools: [])`
to disable tools for the wind-down turn. That ternary exists **only because**
tools live on the context but sometimes need overriding.

If tools never live on the context, the branch is never written. `to_payload`
takes tools explicitly, `wrap_up` passes `{}`, and the override stops being a
special case. Dropping the `Context.tools` accessor **removes** a downstream wart
rather than creating one.

The reversibility argument settles it: adding `Context.tools` later is additive
and non-breaking; removing it later breaks every call site. Start without it and
let step 03 earn it back if it wants it. It is recorded as an open door in
ADR 0004, not as a rejected idea.

### 2.3 The README's expected output is not what the code prints

Step 02's README shows

```
Context: #<Context turns=0 tools=2 budget=8192>
```

A real run of `./week1_baseline/bin/ruby/02_the_registry` prints

```
Context: #<Context task=player turns=0 tools=2>
```

`budget=8192` is the same phantom field step 01's plan §2.1 tracked down: never
implemented at any step, and explicitly retracted by step 12's README as output
`max_tokens` mistaken for the context window. The README also drops the `task=`
the code actually has. Both are already-settled matters; noted here only so a
reader diffing the Ruby README against our output has the explanation.

### 2.4 The README's run command is wrong twice

```sh
./week1_baseline/bin/01_the_registry
```

The real path is `./week1_baseline/bin/ruby/02_the_registry` — the README's
version is missing the `ruby/` segment *and* carries step 01's number. Our README
uses the correct Python path; we do not reproduce the typo.

### 2.5 Two `## Considerations` sections

The personal fork's README has two sections with that heading — one on symbol/
string key translation, one on tool ownership (§2.1) — and so does our Ruby copy
since `ec7db92` restored the second from the video.
Our README will have neither as a duplicate heading: the key-translation point is
moot in Python (§8 row 3, already recorded at step 01) and the ownership point is
now a decision with an ADR behind it, not a caveat.

---

## 3. Decisions

Agreed one at a time in the grilling session.

| # | Decision | Choice |
|---|---|---|
| 1 | Who owns the tool table | **`Registry`**. `Context` has no tools at all — no `_tools`, no `tools`, no `register_tool` (§2.1, §2.2) |
| 2 | `Context` ↔ `Registry` wiring | **no link in either direction.** Two orthogonal objects, composed at the call site |
| 3 | `Registry` constructor | `Registry()` — takes no arguments |
| 4 | Handler attachment | **decorator factory only**; returns the function unchanged |
| 5 | What `Registry.tool` returns | the **original function**, not the `Tool` (Ruby returns the tool) |
| 6 | Error base class | **`BoukenshaError(Exception)`** — three more errors join it by step 05 |
| 7 | Unknown tool | `UnknownToolError(BoukenshaError)`. **Not** a `KeyError` subclass — see §5.2 |
| 8 | Duplicate registration | stays a bare **`ValueError`**, moved from `Context` to `Registry` |
| 9 | `Registry.tools` exposure | read-only `MappingProxyType`, built once in `__init__` |
| 10 | `tool_names()` | **not ported** — `len()`/`list()` on `registry.tools`; consistent with step 01 decision 18 |
| 11 | `name` coercion | none. Ruby's `name.to_s` exists for symbols; Python names are already `str` |
| 12 | Handler exceptions | propagate uncaught, as in Ruby. Turning them into tool results is step 05's problem |
| 13 | Example content | mirrors the Ruby — `move`, `shout`, one unknown `flee` |
| 14 | Per-argument `description` | **restored** in the example's `parameters` (§5.6) |
| 15 | Tests | **none** — example-only, hand-verified, recorded in ADR 0004 |
| 16 | ADRs | **0004** (ownership) + **0005** (decorator); ADR 0003 gets a Status note, its body untouched |
| 17 | Glossary | **Context** narrowed; **Registry**, **Dispatch**, **Catalog** added |

**Python floor stays 3.11+.** Nothing in this step raises it; `TypeVar` is used
rather than 3.12's `def tool[F: …]` generic syntax.

---

## 4. File tree

Everything below `week1_baseline/python/02_the_registry/` already exists as a
byte-copy of `01_struct_skeleton`. Marks are relative to that copy.

```
week1_baseline/python/02_the_registry/
  README.md                     REWRITE  step-02 README (§6.1)
  requirements.txt              KEEP     PyYAML, python-dotenv — unchanged
  prompts/system.md             KEEP     unchanged
  boukensha/
    __init__.py                 EDIT     export Registry, BoukenshaError, UnknownToolError
    config.py                   KEEP     byte-identical to steps 00/01
    tool.py                     KEEP     byte-identical to step 01
    message.py                  KEEP     byte-identical to step 01
    _repr.py                    KEEP     byte-identical to step 01
    context.py                  EDIT     remove all tool state (§5.3) — the non-additive change
    errors.py                   NEW      BoukenshaError, UnknownToolError (§5.2)
    registry.py                 NEW      Registry (§5.1)
    tasks/
      __init__.py               KEEP     empty
      base.py                   KEEP     byte-identical to steps 00/01
      player.py                 KEEP     byte-identical to steps 00/01
  examples/example.py           REWRITE  step-02 example (§5.6)

Outside the step directory:
week1_baseline/bin/python/02_the_registry      EXISTS  verify `chmod +x` only (§5.7)
CONTEXT.md                                     EDIT    1 corrected + 3 new terms (§6.2)
docs/adr/0003-context-is-the-mutable-object.md EDIT    Status line only (§6.4)
docs/adr/0004-registry-owns-the-tool-catalog.md NEW    (§6.5)
docs/adr/0005-tools-register-via-decorator.md  NEW     (§6.6)
docs/plans/python_port/02_the_registry         NEW     this file
```

**Untouched:** everything under `week1_baseline/ruby/`,
`week1_baseline/python/00_config/`, `week1_baseline/python/01_struct_skeleton/`,
`week1_baseline/bin/ruby/`, the root `.boukensha/` fixture, ADR 0001, ADR 0002,
and ADR 0003's body.

---

## 5. Design

### 5.1 `boukensha/registry.py`

```python
F = TypeVar("F", bound=Callable[..., Any])


class Registry:
    def __init__(self) -> None:
        self._tools: dict[str, Tool] = {}
        self._tools_view: Mapping[str, Tool] = MappingProxyType(self._tools)

    @property
    def tools(self) -> Mapping[str, Tool]: ...

    def tool(
        self,
        name: str,
        *,
        description: str,
        parameters: Mapping[str, Any] | None = None,
    ) -> Callable[[F], F]: ...

    def dispatch(self, name: str, args: Mapping[str, Any] | None = None) -> Any: ...
```

- **`Registry()` takes no arguments** (decision 3). Ruby's `Registry.new(context)`
  exists only because the context held the dict; with the dict here, the argument
  has nothing to do. The registry is independently constructible and testable.
- **No reference to `Context` in either direction** (decision 2). The two objects
  are orthogonal: `Context` is the conversation, `Registry` is the capability set.
  The caller composes them — the example today, `Boukensha.run` at step 07, and
  `Agent(context=…, registry=…)` at step 05, which already takes both.
- **`tools` is a `MappingProxyType` built once in `__init__`**, the same pattern
  `Context` used at step 01: enforcement is real and per-access cost is zero.
- **`tool` is a decorator factory** (decision 4):

  ```python
  def tool(self, name, *, description, parameters=None):
      def register(handler: F) -> F:
          if name in self._tools:
              raise ValueError(f"a tool named {name!r} is already registered")
          self._tools[name] = Tool(name, description, parameters or {}, handler)
          return handler
      return register
  ```

  It **returns the handler unchanged** (decision 5), so the decorated name stays
  bound to a plain callable that can be invoked and tested directly. Ruby returns
  the `Tool`; ours is reachable as `registry.tools[name]` when wanted. Note the
  duplicate check fires when the decorator is *applied* — at `def` time — so a
  collision surfaces at import/registration, not at dispatch.
- **`parameters` defaults to `None`, not `{}`** — no mutable default. `Tool`'s
  `__post_init__` copies and proxies it anyway, so `parameters or {}` is safe.
- **`dispatch`**:

  ```python
  def dispatch(self, name, args=None):
      tool = self._tools.get(name)
      if tool is None:
          raise UnknownToolError(f"No tool registered as {name!r}")
      return tool.handler(**(args or {}))
  ```

  No `str(name)` coercion (decision 11). No `transform_keys` — Python kwargs are
  already strings, which was recorded as a divergence at step 01 (§8 row 3).
  Arguments the handler does not accept raise `TypeError` from Python itself;
  we add no guard, matching Ruby (decision 12), and note it in the README.
- **No `tool_names()`** (decision 10). `list(registry.tools)` says it in the
  language the reader already knows. The personal fork adds it at step 10; the
  course repo never does.

### 5.2 `boukensha/errors.py`

```python
class BoukenshaError(Exception):
    """Base class for every error this package raises."""


class UnknownToolError(BoukenshaError):
    """Dispatched a tool name that has no registered tool."""
```

- **A base class, which Ruby does not have** (decision 6). It costs one line and
  is standard Python (`requests.RequestException`, `httpx.HTTPError`), and the
  ladder proves it will be wanted: step 03 adds `UnsupportedModelError`, step 05
  adds `ApiError` and `LoopError`. Retrofitting a base after those classes are in
  use changes their MRO; adding it now costs nothing.
- **`UnknownToolError` is deliberately *not* a `KeyError` subclass** (decision 7).
  A failed lookup is the obvious reading, and `except KeyError` would then work —
  but `KeyError.__str__` returns the `repr` of its argument, so
  `str(UnknownToolError("No tool registered as 'flee'"))` would render *with outer
  quotes* and the example would print

  ```
  UnknownToolError caught: "No tool registered as 'flee'"
  ```

  Verified behaviour, not speculation. The convenience is not worth a mangled
  error message on the one line this step exists to demonstrate.
- **Duplicate registration stays a bare `ValueError`** (decision 8), moved from
  `Context` to `Registry`. It is a programmer error at startup — you passed a name
  that is already taken — and `ValueError` is precisely that. It keeps step 01's
  contract unchanged and avoids a third exception class nothing in the ladder
  catches. Revisit if step 10's three-library merge wants to catch it specifically.

### 5.3 `boukensha/context.py` — the non-additive edit

Delete, with nothing added:

| Removed | Was |
|---|---|
| `self._tools` | `dict[str, Tool]` |
| `self._tools_view` | the `MappingProxyType` |
| `tools` property | the read-only accessor |
| `register_tool` | plus its duplicate-name `ValueError` → now `Registry`'s |
| `from .tool import Tool` | no longer referenced |
| `tools=` in `__repr__` | see below |

What remains is `task`, `system`, `_messages`, the `messages` property,
`add_message`, and `__repr__`. `MappingProxyType` and `Mapping` imports go too.

The repr loses its tool count:

```
Context(task='player', turns=0)
```

That is a visible divergence from Ruby's `#<Context task=player turns=0 tools=2>`
and it is the honest one: an object that does not own tools should not report how
many there are. The tool count is `len(registry.tools)`, which is what step 11's
TUI will read in place of `context.tool_count`.

The class docstring needs rewriting — it currently opens "Everything Boukensha
needs to make an API call. Nothing lives outside it," which §6.2 also corrects in
the glossary. It becomes the conversation half of the pair, with a pointer to
`Registry` for the capability half and to ADR 0004 for why.

### 5.4 `boukensha/__init__.py`

```python
"""Boukensha — step 2: the tool registry."""

from .config import Config, Mud
from .context import Context
from .errors import BoukenshaError, UnknownToolError
from .message import Message, Role
from .registry import Registry
from .tasks.base import Task
from .tasks.player import Player
from .tool import Tool

__all__ = [
    "BoukenshaError", "Config", "Context", "Message", "Mud", "Player",
    "Registry", "Role", "Task", "Tool", "UnknownToolError",
]
```

No import cycle: `registry` imports `errors` and `tool`; `context` now imports
only `message` (and `Task` under `TYPE_CHECKING`). Neither imports the other —
which is decision 2 visible at the module level, not just the class level.

### 5.5 What `Tool` and `Message` do *not* need

Both are byte-identical to step 01. `Tool.handler` was named for exactly this
moment (step 01 decision 6): `dispatch` calls `tool.handler(**args)` and the
Ruby-ism `block` never appears.

### 5.6 `examples/example.py`

Mirrors the Ruby's behaviour (decision 13) — two tools registered, two dispatched,
one unknown name caught — with the composition order flipped, since the registry
no longer needs a context to exist:

```python
config = Config.load()
player = Player.from_config(config)

ctx = Context(task=player, system=player.system_prompt)
registry = Registry()


@registry.tool(
    "move",
    description="Move the player in a direction (north, south, east, west, up, down)",
    parameters={"direction": {"type": "string", "description": "The direction to move"}},
)
def move(direction):
    return f"You move {direction} into a torch-lit corridor."


@registry.tool(
    "shout",
    description="Shout a message so everyone in the zone can hear it",
    parameters={"message": {"type": "string", "description": "What to shout"}},
)
def shout(message):
    return message.upper()


print("=== Boukensha Step 2: The Tool Registry ===")
print()
print(f"Config:   {config!r}")
print(f"Context:  {ctx!r}")
print("Tools:")
for tool in registry.tools.values():
    print(f"  {tool!r}")
print()

print("Dispatching 'shout' with message='dragon spotted'...")
print(f"Result: {registry.dispatch('shout', {'message': 'dragon spotted'})}")
print()

print("Dispatching 'move' with direction='north'...")
print(f"Result: {registry.dispatch('move', {'direction': 'north'})}")
print()

try:
    registry.dispatch("flee")
except UnknownToolError as error:
    print(f"UnknownToolError caught: {error}")
```

Three notes:

- **`Context` is inert this step** and that is deliberate. It is constructed and
  printed to show step 01's work carrying forward and to make the repr change
  visible, but nothing in step 02 touches it. The README says so explicitly:
  the `Context` carries the conversation, the `Registry` carries the
  capabilities, and step 03 is where they meet.
- **The per-argument `description` is restored** (decision 14). Ruby's step 02
  example dropped the inner `description` that its own step 01 example had.
  Step 03's backends pass `parameters` straight through as
  `input_schema.properties`, so that string is how the model learns what the
  argument means — dropping it is a regression, not a simplification.
- Keeps step 01's `sys.path` insert and `BOUKENSHA_DIR` `setdefault`; the
  `REPO_ROOT` hop count is unchanged.

### 5.7 `week1_baseline/bin/python/02_the_registry`

Already present and correct. Confirm it is executable; create nothing.

---

## 6. Documentation to write

### 6.1 `week1_baseline/python/02_the_registry/README.md`

Follows the Ruby step-02 README's structure (intro → New Files → How It Works →
API tables → Expected Output → Considerations → Run Example), plus:

- **Setup** — unchanged from steps 00/01.
- **Why the tools moved** — the §2.1 finding in three or four sentences, quoting
  the author's own note, and pointing at ADR 0004. This is the headline of the
  step and a reader diffing against the Ruby will hit it immediately.
- **`Registry` table** — `tools`, `tool(...)`, `dispatch(...)`.
- **Registering a tool** — the decorator, and the note that it returns the
  function unchanged so `move("north")` still works.
- **Errors** — `BoukenshaError` / `UnknownToolError`, and why duplicate
  registration is a plain `ValueError`.
- **What `Context` lost** — one short paragraph, pointing at ADR 0003's Status
  note so a reader of step 01 is not confused.
- **A note on `token_budget`** — carried from step 01's README; the Ruby step-02
  README shows `budget=8192` too (§2.3).
- **Considerations** — that unknown kwargs raise `TypeError` from Python, and
  that Ruby's string→symbol translation has no Python analogue.
- **Expected output** — ***generated from an actual run, not hand-written.***
  Steps 00 and 01 both learned this; the Ruby README of this very step is wrong
  about its own output (§2.3).
- **Divergences** — the §8 table.
- **Run Example** — `./week1_baseline/bin/python/02_the_registry`, not the Ruby
  README's broken path (§2.4).

### 6.2 `CONTEXT.md`

One existing term is now **wrong** and must be corrected, not merely extended.

**Corrected — Context.** Currently reads:

> Everything one API call needs: the system prompt, the full message history, the
> registered tools, and the task that owns them. Nothing the agent needs lives
> outside it.

Both sentences are false from step 02. It becomes the conversation half of the
pair: the system prompt, the message history, and the task that owns them. What
an API call needs is a **Context** *and* a **Registry**. Keep the name — step 12
turns `Context` into literal context-window accounting (`context_window`,
`current_tokens`, `compaction_threshold`), so it is the right long-term name; only
the definition narrows.

Three terms added, definitions only, in the existing definition-list style:

| Term | Substance |
|---|---|
| **Registry** | The catalog of tools the agent may use, and the thing that runs one when asked for it by name. Holds the only tool table; a context does not. |
| **Catalog** | The full set of registered tools. Distinct from the set offered on any one API call, which a caller may narrow. |
| **Dispatch** | Looking a tool up by name and running its handler with the arguments the agent supplied. Fails loudly on an unregistered name. |

**Turn** and the existing tool terms are unaffected.

### 6.3 Note for the writer

**Catalog** earns its place because it is the word that makes the *next*
conversation possible: when something eventually needs "the tools this call is
offering" as distinct from "everything registered," the vocabulary is already
there. Keep it in the glossary even though no code uses the word yet.

### 6.4 `docs/adr/0003-context-is-the-mutable-object.md` — Status line only

Its Decision clause 2 says `Context` encapsulates its collections, exposes `tools`
as a `MappingProxyType`, and that `register_tool` raises on a duplicate name. From
step 02 that is no longer true — but it remains exactly true of
`week1_baseline/python/01_struct_skeleton`, which is a frozen, self-contained
tree. ADRs are records, not documentation: **the body is not edited.**

The Status line becomes:

```
**Status:** accepted; the tool-collection clauses are superseded by
[ADR 0004](0004-registry-owns-the-tool-catalog.md) from step 02 onward.
The frozen/mutable split and everything about `messages` still stand.
```

That last sentence matters — most of 0003 is still load-bearing.

### 6.5 `docs/adr/0004-registry-owns-the-tool-catalog.md`

Same format as 0001–0003 (Status / Date / Applies to / Context / Decision /
Consequences / Verification).

- **Context** — the §2.1 provenance **reproduced in full, not linked.** This ADR
  must stand alone: plans are working documents superseded by the next step's,
  while this is the durable record of why our tool ownership differs from *both*
  upstream repos. Do not replace any of it with a pointer to
  `docs/plans/python_port/02_the_registry`.

  Reproduce verbatim:

  - the three-row provenance table, with commit SHAs and dates — ExamProCo
    `ea92f4d` (2026-07-13, Andrew Brown) with no ownership note and no
    `tool_names`; `omenking` `7387182` (2026-07-13, Andrew Brown, *"bring over
    ruby code for 03_prompt_builder"*) with both; and ours, `ec7db92`
    (2026-07-25, Scott Rankin), where the note was restored by hand from the
    course video before implementation;
  - the author's `## Considerations` quote in full, including the
    "we did correct the issue" sentence, since the ADR's argument turns on that
    claim being false;
  - the abandoned `# This isn'` comment above `Context#register_tool` in the
    personal fork;
  - the three facts: his own writing, never reached the course repo
    (`git log -S "full table of tools registered"` on ExamProCo returns nothing),
    and the fix lands in neither repo — `registry.rb` is md5 `7eccb51c…` from
    step 02 through step 12 in ExamProCo, and `context.rb` still owns `@tools` at
    step 12 in both repos and both language ports.

  Then add the §2.2 evidence: the `tools.nil? ?` ternary and `wrap_up`'s
  `tools: []`.
- **Decision** — `Registry` owns the only tool table. `Context` holds no tools and
  the two objects hold no reference to each other; callers compose them.
- **Rejected: `Context` delegating to a `Registry` it holds.** Reachable two ways
  (`ctx.tools` and `registry.tools`) aliasing one dict, a property that adds no
  behaviour, and a `Context` that cannot be constructed without a `Registry` —
  coupling bought for nothing. Note the reversibility asymmetry: adding
  `Context.tools` later is non-breaking, removing it later is not.
- **Rejected: the author's literal split**, with a subset of in-play tools on the
  `Context`. Right idea, no consumer yet; `wrap_up` is the only caller that wants
  it and a parameter serves it. Recorded as an open door, not a closed one.
- **Consequences** — the ternary never gets written; `Agent(context=, registry=)`
  and `Tools::FileSystem.register(registry, …)` already match this shape;
  construction order flips at steps 07/09/10; `context.tool_count` becomes
  `len(registry.tools)` for step 11's TUI; step 03's `PromptBuilder` takes both
  objects; `Context.__repr__` loses `tools=`.
- **Verification** — per decision 15 there is no test suite, so record the §9
  hand-checks with their real output, as ADR 0002 and 0003 do.

### 6.6 `docs/adr/0005-tools-register-via-decorator.md`

- **Context** — Ruby attaches the handler with a trailing block. Python has no
  block. Three candidates: a decorator factory, a `handler=` keyword, or both.
  The forcing constraint is downstream: step 10's tool libraries register
  multi-line closures over `root`/`resolve`, and a Python `lambda` is
  single-expression, so a `handler=` keyword would force a `def` plus a separate
  registration call — two statements where the Ruby is one.
- **Decision** — decorator factory only. It returns the handler unchanged, so the
  decorated name stays a plain callable.
- **Rejected: dual-mode.** Two code paths and two obvious ways to do it, for
  caller convenience no caller has asked for.
- **Rejected: deriving `parameters` from the signature and type hints**,
  FastAPI-style. Genuinely attractive and made natural by this decision, but a
  large divergence with nothing needing it yet. Recorded so the idea is not lost.
- **Consequences** — registration is a side effect of applying the decorator, so
  collisions surface at `def` time; `RunDSL.tool` at step 07 forwards to it
  unchanged; `Registry.tool` returns the function, not the `Tool`, unlike Ruby.

---

## 7. Implementation order

1. Confirm the starting state:
   `diff -rqx __pycache__ week1_baseline/python/01_struct_skeleton week1_baseline/python/02_the_registry`
   should report **no differences**. If it does, stop and re-read §1. (`-x
   __pycache__` because `diff` walks the filesystem, not git's index — a tree
   that has been run has one and a tree that has not does not, which says
   nothing about drift. The directory is already gitignored.)
2. `boukensha/errors.py`.
3. `boukensha/registry.py`.
4. `boukensha/context.py` — the deletions in §5.3, plus the docstring rewrite.
5. `boukensha/__init__.py`.
6. `examples/example.py`.
7. Confirm `week1_baseline/bin/python/02_the_registry` is executable.
8. Run it; **capture the real output**.
9. Run the §9 hand-checks; capture the real error messages.
10. `README.md`, using the captured output from steps 8–9.
11. `CONTEXT.md` — the Context correction plus three new terms.
12. ADR 0003 Status line; ADR 0004; ADR 0005.
13. Final `diff -rqx __pycache__` against step 01 to confirm nothing outside
    §4's NEW / EDIT / REWRITE list drifted.

---

## 8. Divergences from the Ruby port

Steps 00 and 01's divergences all still apply. These are the rows step 02 adds.

| # | Ruby | This port | Why |
|---|---|---|---|
| 1 | `Context` owns `@tools`; `Registry` writes through it | `Registry` owns the only tool table; `Context` has none | the author flagged this defect and specified the fix but never shipped it (§2.1); ADR 0002 fixes rather than carries |
| 2 | `Registry.new(context)` | `Registry()` | with the table here, the argument has nothing to do |
| 3 | `Context#register_tool` | deleted; registration is `Registry.tool` | one owner, one path |
| 4 | `#<Context … tools=2>` | `Context(task='player', turns=0)` | an object that does not own tools should not count them |
| 5 | trailing block attaches the handler | decorator factory | Python has no blocks; a `lambda` cannot hold step 10's multi-line closures |
| 6 | `registry.tool` returns the `Tool` | returns the handler unchanged | the decorated name stays a callable you can invoke and test |
| 7 | `UnknownToolError < StandardError`, flat | `BoukenshaError` base, `UnknownToolError` under it | three more errors join by step 05; retrofitting a base later changes the MRO |
| 8 | `name.to_s` in `tool` and `dispatch` | no coercion | Ruby coerces because symbols; Python names are already `str` |
| 9 | `args.transform_keys(&:to_sym)` | `handler(**args)` | recorded at step 01 (row 14); Python kwargs are already strings |
| 10 | `tool_names` (personal fork, step 10 only) | not ported | `list(registry.tools)`; consistent with step 01 decision 18 |
| 11 | step 02's example drops the per-argument `description` | restored | it becomes `input_schema.properties`; it is how the model reads the argument |
| 12 | README run path `./week1_baseline/bin/01_the_registry` | correct Python path | missing `ruby/`, wrong step number (§2.4) |

Rows 1–4 are one decision seen from four angles; ADR 0004 is the single record.

---

## 9. Verification

`examples/example.py` is the entire safety net (decision 15).

```bash
./week1_baseline/bin/python/02_the_registry   # new
./week1_baseline/bin/ruby/02_the_registry     # Ruby, for comparison
```

The Ruby run prints, verified:

```
=== BOUKENSHA Step 2: Tool Registry ===

Config:  #<Boukensha::Config dir=…/.boukensha tasks=player>
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

Check by eye:

- both dispatch results match the Ruby exactly — `DRAGON SPOTTED` and
  `You move north into a torch-lit corridor.`
- `UnknownToolError caught: No tool registered as 'flee'` — **with no outer
  quotes**, the §5.2 check
- both tools listed, `move` then `shout` — insertion order, which `dict` preserves
- `Context(task='player', turns=0)` — **no `tools=`**, and no `budget=`
- the script exits 0; the unknown-tool path is caught, not fatal

Then the hand-checks the example cannot show. Capture the real messages for
ADR 0004 and the README:

```python
# duplicate name -> ValueError at decoration time, not at dispatch
@registry.tool("move", description="…")
def move_again(direction): ...

# the decorator returned the function, not the Tool
move("north")                      # -> "You move north into a torch-lit corridor."

# read-only catalog
registry.tools["x"] = some_tool    # -> TypeError

# unknown kwarg reaches the handler unguarded, as in Ruby
registry.dispatch("move", {"drection": "north"})   # -> TypeError

# no-args dispatch of a registered no-args tool
registry.dispatch("look")          # -> handler called with no kwargs

# Context really has lost them
ctx.register_tool                  # -> AttributeError
ctx.tools                          # -> AttributeError
```

And confirm the step is still self-contained, the check ADR 0002 established:

```bash
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/02_the_registry
# expect: ValueError "tasks.player is missing from settings.yaml" — the step-00
# behaviour, unchanged
```

---

## 10. Out of scope

- **`week1_baseline/bin/ruby/00_config` is broken** — carried from step 01's plan
  §2.4, still unfixed, still a pre-existing Ruby-side bug best fixed in its own
  change.
- Any modification to `week1_baseline/ruby/`, to `week1_baseline/python/00_config/`
  or `01_struct_skeleton/`, or to the root `.boukensha/` fixture. Earlier steps
  keep the old design on purpose; that is what a frozen snapshot is for.
- Editing the **body** of ADR 0001, 0002, or 0003. Only 0003's Status line changes.
- A test suite, `pytest`, or any test-running convention (decision 15).
- Deriving `parameters` from the handler signature and type hints. Recorded as a
  rejected-for-now alternative in ADR 0005.
- Giving `UnknownToolError` structured attributes (`.name`, `.available`) so a
  future agent can tell the model which tools *do* exist. Nothing consumes it yet;
  step 05 is where it would earn its place.
- Returning tool failures to the model as tool results rather than letting them
  propagate (decision 12) — step 05's `handle_tool_calls` is where that belongs.
- Porting steps `03_prompt_builder` … `12_context`. In particular `PromptBuilder`
  taking both a context and a registry is step 03's change, even though §2.2
  already anticipates it.
