# 05 · The Agent Loop (Python)

The Agent Loop is where the ladder becomes an agent. Everything before this was
parts: a `Context` nobody advanced, a `Registry` nobody dispatched from, a
`PromptBuilder` whose payload was posted exactly once.

```
send the history  →  read the reply  →  dispatch the tools it asked for
      ↑                                              │
      └──────────────────────────────────────────────┘
                until the model stops, or the ceiling hits
```

This is the Python port of `week1_baseline/ruby/05_agent_loop`, built on top of
[step 04](../04_api_client/README.md). The deliberate differences are listed
under [Divergences from the Ruby port](#divergences-from-the-ruby-port).

**What this agent is for shapes the decisions below.** BOUKENSHA is a Player
Journey Agent for tbaMUD: a player hands it a goal — *"find the torch and bring
it back to the entry hall"* — and the loop drives their character through the
world to achieve it. Three consequences run through this step:

- **MUD failures are not exceptions.** *"You can't go that way."* is a string the
  MUD returns and the model reads. What actually *raises* is either the model's
  own mistake or an infrastructure failure, and those want opposite handling.
- **The loop spends real money on behalf of an unattended player.** A bounded run
  is the product requirement, not defensive programming.
- **When the ceiling hits, the character is somewhere.** Telling the player where
  they ended up is worth more than telling them a limit was reached.

**Step 05 is additive over step 04** apart from `Message.content` widening beyond
`str` — which step 04's README and plan both recorded in advance as the one thing
this step would have to change. Step 04's tree is untouched and remains a valid
frozen snapshot.

## Setup

Runs on the repo-root `.venv`, currently **Python 3.14.5**:

```bash
python3 -m venv .venv                                             # at the repo root
.venv/bin/pip install -r week1_baseline/python/05_agent_loop/requirements.txt
```

`requirements.txt` is **unchanged** from steps 00–04 (`PyYAML` and
`python-dotenv`, both still needed by `Config`). Everything in this step is pure
standard library.

**This step cannot run without an API key**, and it makes *several* calls rather
than step 04's one.

## New Files

| File | Purpose |
|------|---------|
| `boukensha/agent.py` | **new** — `Agent`, the loop, the ceiling, the wind-down call |
| `boukensha/content.py` | **new** — `TextBlock`, `ToolUseBlock`, `ContentBlock` |
| `boukensha/reply.py` | **new** — `StopReason`, `Reply` |
| `boukensha/logging.py` | **new** — `AgentLogger` protocol, `NullLogger` |
| `boukensha/message.py` | edited — `content` widened; `is_error` added |
| `boukensha/context.py` | edited — `add_message` signature; docstrings |
| `boukensha/backends/base.py` | edited — `parse_response` joins the contract |
| `boukensha/backends/anthropic.py` | edited — `parse_response`; block and `is_error` serialization |
| `boukensha/tasks/base.py` | edited — `max_iterations` |
| `boukensha/errors.py` | edited — docstring only, no code change |
| `boukensha/prompt_builder.py` | edited — docstring only, no code change |
| `boukensha/client.py` | edited — docstring only, no code change |
| `boukensha/__init__.py` | edited — exports the new names |
| `examples/example.py` | rewritten — runs the loop, with its own `PrintLogger` |

`_repr.py`, `registry.py`, `tool.py`, `config.py`, `tasks/player.py`,
`backends/__init__.py`, `prompts/` and `requirements.txt` are **byte-identical to
step 04**.

`prompt_builder.py` and `client.py` stop being byte-identical for the sake of one
docstring line each, and `errors.py` for one paragraph. That is the same kind of
break step 04 made with `config.py`, and it is deliberate: leaving docstrings
that contradict the glossary is worse than the diff.

---

## `boukensha.Agent`

| Member | Description |
|---|---|
| `Agent(context, registry, backend, client, *, max_iterations=None, max_output_tokens=None, logger=None)` | Wires the loop. Both `PromptBuilder`s are derived |
| `run()` | Works the goal and returns the model's final text |

```python
agent = Agent(ctx, registry, backend, client, logger=PrintLogger())
answer = agent.run()
```

**There is no `PromptBuilder` line.** Ruby's `Agent.new(context:, registry:,
builder:, client:)` takes a builder and then calls `@builder.parse_response(…)` —
a method that exists only to delegate to the backend. Parsing is the *inbound*
direction and needs neither a context nor a tool catalog, so it never belonged on
the builder. Taking the **backend** instead means the agent constructs both of
its builders itself:

```python
self._tools_builder = PromptBuilder(context, backend, tools=registry.tools)
self._bare_builder  = PromptBuilder(context, backend, tools={})
```

The second one is the tools-disabled wind-down call — **the forward check
[ADR 0009](../../../docs/adr/0009-client-transports-payloads.md) asserted but
could not run.** It now passes: no `tools=` parameter was added to `Client.call`,
`to_api_payload`, or `to_payload`. Ruby threads one through all three layers to
support this single call site.

**The `Context` is borrowed, not owned.** The agent appends to it and never
replaces it, so a caller can hydrate a context from disk, run, and write it back.
That matters for the knowledge layer noted under [Out of scope](#out-of-scope).

---

## The normalized shape

The loop never inspects a provider response. `Backend.parse_response` turns one
into a `Reply`:

```python
@dataclass(frozen=True, slots=True)
class Reply:
    stop_reason: StopReason
    content: tuple[ContentBlock, ...]
    raw_stop_reason: str

    @property
    def text(self) -> str: ...                        # every TextBlock, joined
    @property
    def tool_uses(self) -> tuple[ToolUseBlock, ...]: ...
```

which is what lets `run()` carry a single branch:

```python
if reply.stop_reason is not StopReason.TOOL_USE:
    return reply.text
self._handle_tool_calls(reply)
```

Ruby's normalized shape is a hash of raw hashes, and every site that touches it
re-derives meaning from `b["type"]` — `parse_response`, `extract_text`,
`handle_tool_calls`, and each backend's private `assistant_message`. Two frozen
dataclasses name the shapes once, for **both** directions:

```python
TextBlock(text="Let me look around.")
ToolUseBlock(id="toolu_01…", name="move", input={"direction": "north"})
```

`ToolUseBlock.input` is copied and wrapped in a `MappingProxyType` in
`__post_init__` — frozen with a mutable mapping inside is not frozen, the same
reasoning `Tool.parameters` already uses.

Anthropic's `content` array **is** the wire format as well as the normalized
shape, so this backend needs no inverse conversion. Ruby's other four each carry
a private `assistant_message` to rebuild a provider-specific assistant turn; only
one is ported ([ADR 0006](../../../docs/adr/0006-port-ships-only-the-anthropic-backend.md)).

### Why truncation is not "done"

Ruby collapses six stop reasons into two:

```ruby
stop_reason = response["stop_reason"] == "tool_use" ? "tool_use" : "end_turn"
```

Anthropic returns `end_turn`, `max_tokens`, `stop_sequence`, `tool_use`,
`pause_turn` and `refusal`. Folding five into `end_turn` has one consequence that
matters: **a reply cut off at the token ceiling is indistinguishable from one the
model chose to end**, and `agent.rb:40-44` then returns the partial text as the
final answer. If that truncated reply also carried `tool_use` blocks, they are
silently dropped.

```python
class StopReason(StrEnum):
    TOOL_USE = "tool_use"      # the loop's only continuation branch
    END_TURN = "end_turn"      # the model chose to stop
    MAX_TOKENS = "max_tokens"  # truncated — NOT the same as finished
    OTHER = "other"            # refusal, pause_turn, stop_sequence, anything new

    @classmethod
    def _missing_(cls, value): return cls.OTHER
```

Three named members, not six: `REFUSAL`, `PAUSE_TURN` and `STOP_SEQUENCE` have no
caller in this step and would be speculative. `_missing_` means an unrecognised
value — including a **missing** `stop_reason`, which arrives as `""` — ends the
run rather than crashing it, and naming one of them later is purely additive.
`raw_stop_reason` keeps the wire string verbatim for step 06's logger, because
`OTHER` is lossy and the log should not be.

A `MAX_TOKENS` reply is not `TOOL_USE`, so its `tool_use` blocks are **not
dispatched**: the run ends and `stop_reason` says why. Ruby dispatches nothing
here either, but only because its ternary has already relabelled the reply
`end_turn`.

### What is dropped on parse

A content block whose `type` is neither `text` nor `tool_use` is **silently
dropped**, keeping `ContentBlock` a closed union. Today that means Anthropic
`thinking` blocks; nothing here enables thinking, so nothing is currently lost.
Named so it is not rediscovered: turning thinking on means extending the union
*and* preserving the blocks on replay, which is not a one-line change.

---

## What the loop catches, and what it deliberately does not

Ruby dispatches unguarded, so anything a handler raises kills the run. Step 02 of
this port already committed to fixing that — but **"catch everything" is the
wrong reading of the promise in this domain.**

In a MUD, the things that look like failure are ordinary strings: *"You can't go
that way."*, *"There is no such thing here."* They never raise. What raises
splits in two:

| Raises | Can the model recover? | Handling |
|---|---|---|
| `UnknownToolError` — invented a tool name | **Yes**, it reads the error and picks a real tool | caught → `is_error` result |
| `TypeError` — called `move(dir=…)` not `move(direction=…)` | **Yes**, it reads the error and fixes the keyword | caught → `is_error` result |
| `ConnectionResetError`, socket timeout — the MUD dropped | **No** | propagates |
| A bug in our tool code | **No** | propagates |

Handing back the second kind as a tool result is actively harmful: the agent
issues another two dozen commands into a dead socket, pays for every one, and
hands the player a confident summary of a session that never happened. A silent
wrong answer at full price is worse than a traceback.

```python
try:
    return str(self._registry.dispatch(name, args)), False
except (UnknownToolError, TypeError) as exc:
    return f"{type(exc).__name__}: {exc}", True
```

The caught message becomes a `tool_result` with `"is_error": true`, which the
model reads on the next iteration.

**The known cost, stated plainly.** A `TypeError` raised *inside* a handler is a
genuine bug, and at the call site it is **indistinguishable** from a `TypeError`
raised by binding the wrong keywords — the handler frame is one level down and
Python does not separate them. Catching `TypeError` swallows that narrow class of
bug: it becomes a tool result the model works around, and the run continues.
Accepted, not hidden. See
[ADR 0010](../../../docs/adr/0010-agent-catches-model-mistakes.md).

`Registry` is unchanged and still raises. **Recoverability is a policy of the
loop, not of the catalog.**

---

## The ceiling, and the wind-down call

`max_iterations` defaults to **25** and is read from `tasks.player.max_iterations`
when settings name it. `0` disables it, as in Ruby.

**A limit is a trigger threshold, not a hard cap.** On reaching it the agent
stops starting new work and makes exactly one terminal call — tools disabled, 400
output tokens — asking for a summary:

> You have reached your action limit. Do not call any more tools. Briefly
> summarize what you accomplished, what is still unfinished, and the single next
> action you would take.

It runs **outside** the counted loop: it never re-checks the limit, so it cannot
re-trigger, and it does not increment the counter. If that call fails, a
deterministic sentence is returned instead — `except ApiError` is exactly the
single-`except` case step 04's `ApiError` docstring predicted, and the reason
`ApiError` is one class rather than a hierarchy.

This is the piece that is easy to read as mere politeness and is not. When the
ceiling hits, the character is mid-dungeon, torch lit or not, carrying whatever
it picked up. The summary is the only thing that tells the player where they
ended up — and it is already a distillation of the run, produced once, for free.

**`LoopError` is not ported.** Ruby's `errors.rb` declares it at this step and in
six later ones, and `repl.rb` rescues it in five of them (08–12):

```ruby
rescue LoopError => e
  output("\n[error] #{e.message}")
```

A grep across **all twelve Ruby steps** finds no `raise LoopError` anywhere. The
design clearly intended the ceiling to raise; the wind-down call was built
instead and the vestige was never removed. A class that cannot be raised is not
worth porting, and `errors.py`'s docstring — which used to predict *"step 05 adds
two more"* — now records the grep.

---

## Progress reporting

`agent.py` **never calls `print`.** Ruby writes to stdout from inside `run` and
`handle_tool_calls`, then unpicks it at step 08 by injecting a logger; step 06 of
this ladder *is* that logger, so the seam is one rung away rather than three. And
a library package that writes to stdout unbidden cannot be driven by step 08's
REPL or step 11's TUI.

```python
class AgentLogger(Protocol):
    def iteration(self, *, n: int, limit: int) -> None: ...
    def tool_call(self, *, name: str, args: Mapping[str, Any]) -> None: ...
    def tool_result(self, *, name: str, result: str, is_error: bool) -> None: ...
    def limit_reached(self, *, kind: str, n: int, limit: int) -> None: ...
```

The default is `NullLogger`. Method names and keyword shapes are taken from
Ruby's **step-08** logger (`iteration(n:, max:)`, `limit_reached(kind:, n:,
max:)`) so step 06 converges on it rather than inventing a second vocabulary;
`max` becomes `limit` because `max` shadows a builtin.

`examples/example.py` supplies a small `PrintLogger` — a plain class that imports
nothing, since a `Protocol` is satisfied structurally. Not the stdlib `logging`
module: this is a user-facing transcript bound for a TUI pane and a run file, not
levelled diagnostics, and structured fields are what steps 06 and 11 want. See
[ADR 0011](../../../docs/adr/0011-agent-logger-protocol.md).

---

## Parallel tool calls

A reply may carry several `tool_use` blocks. The loop dispatches **all** of them
before the next API call, and appends **one `tool_result` message per block** —
Ruby parity.

Anthropic's tool-use guidance says to return all `tool_result` blocks in a
*single* user message, and warns that splitting them "silently trains Claude to
stop making parallel calls." Their multi-turn guidance separately says
consecutive same-role messages are combined into one turn. The two statements are
in tension, so rather than pick a reading, **this was measured** — both shapes
sent to `/v1/messages/count_tokens` with an identical conversation (a
three-command known-route batch: `south`, `south`, `look`, with their three
results):

```
merged (1 user message, 3 blocks) : 883
split  (3 user messages, 1 each)  : 883
delta: +0 tokens
```

Both accepted; identical rendering. **The split is cosmetic**, so Ruby parity
costs nothing and the batching warning does not apply to a shape our loop can
produce. *(Evidence quality: identical counts are strong evidence of identical
rendering, not proof — two renderings could in principle coincide. At 883 tokens
with a structural difference, convincing.)*

This matters because batching is genuinely valuable here. Once a route from A to
B has been explored one room at a time, the return trip can be fired as a single
multi-command batch. Against a 25-iteration ceiling, a six-room torch errand
costs 12 iterations hop-by-hop or 2 batched — **and the loop supports that for
free.**

**Note for step 10:** blind batching in a live world can drift. If the first
`south` returns *"The door is closed."*, later commands in the batch execute from
an unexpected room. The model sees all the results together and can re-orient
with a `look`, so this is a prompt-design concern for the real MUD tools, not a
constraint on this loop.

---

## Why the example is not playing the MUD

The example registers `read_file` and `list_directory` and asks the model to
summarise this step's README. **That contradicts the system prompt actually in
force**, and it is worth naming rather than inheriting silently:

| Prompt | Text |
|---|---|
| `.boukensha/prompts/player/system.md` (**what runs**) | "You are a MUD Journey Player Agent. You are playing the MUD on behalf of the player…" |
| `ruby/05_agent_loop/prompts/system.md` | "You are Boukensha, an autonomous player exploring a CircleMUD world." |
| `python/05_agent_loop/prompts/system.md` | "You are a MUD player assistant." |

`settings.yaml` sets `prompt_override.system: true` and the override file exists,
so the first is live for both trees and the shipped `prompts/system.md` is never
read. *(Editing it and seeing no change is expected — edit
`.boukensha/prompts/player/system.md`.)*

**The real MUD connection is correctly deferred, and stays deferred.**
`TCPSocket` appears in exactly three files across the whole Ruby ladder, all
`repl.rb`, at steps 10, 11 and 12; `tools/mud.rb` (20.4K) arrives at step 10.
Steps 05–09 never open a socket. `CONTEXT.md` defines a step as *"a
self-contained, runnable tree with its own README and example"* — an example
requiring a live tbaMUD on `:4000` would not be runnable standalone, and the MUD
is not even coherent before step 08's REPL holds a session.

So the filesystem tools are kept as-is: they give real, varied, unpredictable
output that forces a genuine multi-iteration run with no invented world, and they
keep the two trees comparable. What changes is that the mismatch is stated here.
Step 10 is where the tools stop lying about what the agent is.

*(This is the one place this port keeps Ruby's example where step 04 diverged
from it. At step 04 the filesystem handlers were **unreachable** — nothing
dispatched — so keeping `look`/`move` cost nothing. At step 05 they run, and
`look`/`move` returning a hardcoded sentence would produce a one-iteration run
that demonstrates nothing.)*

The handlers resolve paths against the step directory, the same as Ruby's
`base_dir`. **This is a demo, not a sandbox** — nothing stops
`../../../etc/passwd`.

---

## Run Example

```bash
./week1_baseline/bin/python/05_agent_loop
```

**This makes several real API calls and spends real money** — a few cents. It
needs `ANTHROPIC_API_KEY` in the environment or in the config dir's `.env`.

Actual output from a real run against this repo's `.boukensha/` fixture — **not
hand-written.** The model's behaviour varies between runs, so this is a snapshot,
and the number of iterations in particular is not stable.

```
=== Boukensha Step 5: The Agent Loop ===

Config:             Config(dir='/Users/…/claude-code-camp-2026-Q2/.boukensha', tasks=['player'])
Model:              claude-haiku-4-5
Max iterations:     25
Max output tokens:  16000

[iteration 1/25]
  tool call   → read_file({'path': 'README.md'})
  tool result → # 05 · The Agent Loop (Python)  The Agent Loop is where the
[iteration 2/25]

=== FINAL RESPONSE ===
## Summary

This MUD player assistant framework, called **BOUKENSHA**, is a Python-based
agent loop that automates gameplay in a MUD (Multi-User Dungeon). Here's what it
can do:

### Core Functionality
- **Autonomous Goal Completion**: A player gives the agent a goal (e.g., "find
  the torch and bring it back to the entry hall"), and it automatically drives a
  character through the MUD to accomplish it
- **Iterative Agent Loop**: The agent sends conversation history to an AI model,
  reads the response, dispatches any tool calls the model requests, and repeats
  until complete or a limit is reached

### Key Features

1. **Multi-turn API Communication**: Manages back-and-forth with AI models
   (currently supports Anthropic's Claude) to drive decision-making in the game
   world

2. **Tool Dispatching**: Executes commands and actions the model requests,
   handling:
   - Parallel tool calls (multiple commands in a single iteration)
   - Model errors gracefully (catches invented tool names or wrong parameters
     and feeds them back as error results)
   - Infrastructure failures (propagates real connection issues rather than
     masking them)

3. **Smart Iteration Management**:
   - Configurable iteration limit (default 25 actions)
   - Wind-down mechanism: when approaching the limit, makes a final call asking
     the model to summarize what was accomplished
   - Doesn't count the wind-down call against the limit

[…]

This framework is designed as a **self-contained, runnable step** in a larger
ladder of development, serving as the foundation for more complex MUD
interaction features.

History: Context(task='player', turns=3)
```

*(The `[…]` marks the only edit: three more numbered points cut for length. The
line wrapping is the terminal's; nothing else is changed.)*

**Two iterations, one tool call.** The model reads the whole README in one go and
has everything it needs, so this run does not exercise parallel dispatch, an
error result, or the ceiling. Ruby's captured output is the same shape. That is
precisely why the offline checks below exist rather than being optional — the
example demonstrates that the loop *runs*, and almost nothing else.

`turns=3` is the user goal, the assistant's `tool_use`, and the `tool_result` —
`Context.__repr__` uses "turn" in the `CONTEXT.md` sense of *one message*, which
is not the sense `max_iterations` uses. See [Out of scope](#out-of-scope).

---

## Verification

The example is the safety net, as at every step ([no test suite is
shipped](#out-of-scope)). But the example cannot make the model hallucinate a
tool name, cannot make a socket drop, and — at 25 iterations against a
cooperative task — will not reach the ceiling. Every branch below would otherwise
ship on reasoning alone.

These were driven offline against a scripted stub client during implementation —
no network, no key. The stub is **not committed**; this is its real output.

| Scenario | Result |
|---|---|
| parallel tool calls in one reply | ✅ both dispatched, two `tool_result` messages |
| model invents a tool name | ✅ `is_error` result, run **continued** |
| model uses the wrong keyword | ✅ `is_error` result, run **continued** |
| tool raises `ConnectionResetError` | ✅ **propagated**, run stopped |
| `stop_reason: max_tokens` carrying a `tool_use` | ✅ returned partial text, dispatched nothing |
| ceiling reached | ✅ wind-down call: `tools: []`, `max_tokens: 400` |
| wind-down call raises `ApiError` | ✅ deterministic fallback sentence |
| wind-down returns blank text | ✅ same fallback |
| `max_iterations=0` | ✅ ceiling disabled, ran 31 calls |
| `max_iterations` from the task | ✅ read from `Task.max_iterations` |
| default logger | ✅ **no output at all** |
| unknown `stop_reason` / missing field | ✅ `StopReason.OTHER`, run ended |
| `thinking` block in `content` | ✅ dropped; other blocks preserved |
| `ToolUseBlock.input` mutation | ✅ `TypeError` — the proxy holds |
| a `str`-only history | ✅ payload byte-identical to step 04's |

```
--- happy path, parallel tool calls
    [iteration 1/25]
      call   -> look({})
      result -> A damp corridor.
      call   -> move({'direction': 'north'})
      result -> You move north.
    [iteration 2/25]
   result: Done.

--- model invents a tool name
      result ! UnknownToolError: No tool registered as 'teleport'
   result: Recovered.

--- model uses the wrong keyword
      result ! TypeError: move() got an unexpected keyword argument 'dir'
   result: Recovered.

--- infrastructure failure propagates
   propagated: ConnectionResetError the MUD dropped

--- max_tokens is not 'done'
   result: 'partial' | calls made: 1

--- ceiling triggers the wind-down call
    [max_iterations at 3/3]
   wind-down tools: [] max_tokens: 400
   wind-down last msg: You have reached your action limit. Do n …

--- wind-down call fails
   result: I reached my 2-action limit before finishing. Ask me to continue and I'll pick up from here.

--- max_iterations=0 disables the ceiling
   result: thirty | iterations: 31
```

The whole stub is a class with one method, which is
[ADR 0009](../../../docs/adr/0009-client-transports-payloads.md) paying off
again — `Agent` touches nothing else on a client:

```python
class Chatty:
    def call(self, payload):
        return self.script.pop(0)
```

### The measurement

The 883-vs-883 count above was run against `/v1/messages/count_tokens`, not
reasoned about. Both shapes were accepted.

### Inspection checks

```
grep -rn "print(" boukensha/                    → no hits
grep -rn "tools=" boukensha/**/*.py             → the two PromptBuilder
                                                  constructions in agent.py, one
                                                  repr f-string, and three
                                                  docstring mentions. No method
                                                  anywhere takes a tools=
grep -rn "class LoopError\|LoopError(" ../**/*.py → no hits in the Python tree
grep -rn "raise LoopError" ../../ruby/           → no hits in *any* Ruby step
```

The last one is the claim the decision rests on, so it was run rather than
inherited. `LoopError` is declared in seven Ruby steps' `errors.rb` and rescued
in five `repl.rb`s; it is raised in none. *(The string `LoopError` does appear in
this README and in `errors.py`'s docstring — both explaining its absence.)*

### Environment checks

Still self-contained, the check
[ADR 0002](../../../docs/adr/0002-python-port-fixes-known-limitations.md)
established:

```
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/05_agent_loop
ValueError: tasks.player is missing from settings.yaml
```

Step-00 behaviour, unchanged.

---

## Considerations

**The assistant message must be stored before the tool result.** Anthropic
requires the assistant's `tool_use` block to appear in the history before its
matching `tool_result`. `_handle_tool_calls` does this first, before dispatching
anything — get the order wrong and the API rejects the *next* request. This is
the whole reason `Message.content` had to widen beyond `str`.

**The agent has no way to stop itself.** The model signals it is done via
`stop_reason`. The loop watches for that and exits. The agent never decides
unilaterally to stop — which is exactly why the ceiling exists.

**The conversation is still stateless.** The API remembers nothing between calls,
so every iteration replays the entire history. A 25-iteration run re-sends a
growing transcript 25 times. That is what step 12's compaction is for.

**`max_output_tokens` still resolves in exactly one place.** `Agent` holds `None`
unless a caller passes one; `PromptBuilder.to_api_payload` resolves it from the
task. The wind-down call is the one place the agent passes a number, and it is a
deliberate cap on a deliberately short reply.

**`DEFAULT_MAX_ITERATIONS` lives on `Task`, not on `Agent`.** Ruby declares 25
twice — `Tasks::Base::DEFAULT_MAX_ITERATIONS` *and* `Agent::MAX_ITERATIONS` —
which is the same duplicated-default defect the `1024` `max_tokens` value had at
step 03. It is defined where the setting is read, and `agent.py` imports it.

**`is_error` only reaches the wire when true.** So every payload steps 03 and 04
produced is byte-identical, and the check above proves it.

---

## Divergences from the Ruby port

Steps 00–04's divergences all still apply. These are the rows step 05 adds.

| # | Ruby | This port | Why |
|---|---|---|---|
| 1 | `content` is a raw array of hashes | typed `TextBlock` / `ToolUseBlock` | one vocabulary for parse *and* serialize; ADR 0001's ethos |
| 2 | `stop_reason` collapsed to two values | `StopReason` enum + `raw_stop_reason` | truncation is not completion |
| 3 | `Agent.new(builder:, client:)` + `builder.parse_response` | takes the backend; both builders derived | the pass-through adds nothing, and parsing needs neither context nor tools |
| 4 | `tools:` threaded through three layers | **never written** | ADR 0004 + ADR 0009 — the forward check now passes |
| 5 | tool exceptions propagate | the model's own mistakes become results | ADR 0010 |
| 6 | `puts` from inside the loop | `AgentLogger` + `NullLogger` | ADR 0011 |
| 7 | `LoopError` defined in seven steps, rescued in five, never raised | not ported | grep across all twelve steps finds no `raise` |
| 8 | `Tasks::Base.max_iterations(settings)` class method | `Task.max_iterations` field | ADR 0001 predicted this field by name |
| 9 | `25` declared on both `Tasks::Base` and `Agent` | one `DEFAULT_MAX_ITERATIONS`, on `Task` | same defect the step-03 `1024` had |
| 10 | five backends implement `parse_response` | one does | ADR 0006 |
| 11 | wind-down directive says "for this turn" | says "your action limit" | "turn" means three different things here; see `CONTEXT.md` |
| 12 | example builds a backend with a five-arm `case` | `backend_for(player)` | established at step 03 |

Rows 3 and 4 are one decision, and it is
[ADR 0009](../../../docs/adr/0009-client-transports-payloads.md) coming due.

**Not a divergence:** the example's `read_file` / `list_directory` tools and its
prompt are Ruby's, ported. Step 04 kept `look`/`move` instead because nothing
dispatched there; here the handlers run, and hardcoded sentences would produce a
one-iteration run that demonstrates nothing.

---

## Out of scope

- **The real MUD connection.** Step 10 (`tools/mud.rb`, 20.4K) and step 08's REPL
  to hold a session. See [above](#why-the-example-is-not-playing-the-mud).
- **A knowledge / recall layer** — distilling durable lessons from past play
  (*"the mob in the east wing kills us"*). Nothing on the ladder does this; step
  12 is the nearest home, since compaction is already "summarise what happened
  into what is worth keeping," and step 06's run files are its raw material.
  **What step 05 must not do is foreclose it, and it doesn't:** `Agent` borrows a
  `Context` it did not create, so a future caller can hydrate one from disk, run,
  and write it back — and `Message` stays a frozen, serialisable record. The
  wind-down summary is already a distillation of exactly the right kind.
- **`disable_parallel_tool_use`.** The API can suppress multi-tool replies; we do
  not use it. The loop handles N ≥ 1 correctly either way, and constraining the
  model is a step-10 prompt-design question.
- **Resolving the "Turn" conflict.** `CONTEXT.md` says one message in the
  history; Ruby's `12_context` uses it for one goal→answer cycle; the domain
  means one command sent to the MUD. `CONTEXT.md` gains **Iteration** and
  **Wind-down**, which are uncontested; the conflict belongs with step 12's work
  and is cheap to defer, since `max_iterations` is correct under every reading.
- **The other four backends.**
  [ADR 0006](../../../docs/adr/0006-port-ships-only-the-anthropic-backend.md).
- **Token budgets, compaction, `turn_end` accounting.** Ruby's `12_context`
  `Agent` adds `max_turn_tokens`, `needs_compaction?` and usage accumulation.
  Step 12. Nothing here reads `response["usage"]` — step 06's logger is where it
  lands.
- **`thinking` blocks.** Dropped on parse. Turning thinking on means extending
  `ContentBlock` *and* preserving the blocks on replay.
- **Naming `REFUSAL`, `PAUSE_TURN`, `STOP_SEQUENCE`.** No caller at this step.
  `StopReason._missing_` makes adding one additive.
- **A test suite.** No test file, test directory, or test dependency is created by
  this step; the stub above was a throwaway. It binds every subsequent step to a
  convention and deserves its own ADR rather than arriving sideways.
