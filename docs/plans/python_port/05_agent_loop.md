# Plan — Port `week1_baseline/ruby/05_agent_loop` to Python

**Target:** `week1_baseline/python/05_agent_loop`
**Source of truth:** `week1_baseline/ruby/05_agent_loop` (README + `agent.rb` + `examples/example.rb`)
**Predecessor:** `docs/plans/python_port/04_api_client.md`, ADR 0001–0009
**Status:** agreed via grilling session; ready to implement.

---

## 1. Goal

Add the **Agent** — the loop that turns a player's goal into work. It sends the
conversation to the model, reads back what the model wants to do, dispatches
tools through the `Registry`, feeds the results into the `Context`, and repeats
until the model says it is done or the loop hits its ceiling.

Steps 00–04 built the parts and never joined them: a `Context` nobody advanced,
a `Registry` nobody dispatched from, a `PromptBuilder` whose payload was posted
exactly once. This is the step where the ladder becomes an agent.

### What this agent is actually for

BOUKENSHA is a **Player Journey Agent for tbaMUD**. A player hands it a goal —
*"find the torch and bring it back to the entry hall"* — and the loop drives the
player's character through the world to achieve it. That domain shapes several
decisions in this plan in ways a generic tool-calling agent would not:

- **MUD failures are not exceptions.** *"You can't go that way."* is a string the
  MUD returns and the model reads. Almost nothing a MUD tool does raises, so
  what *does* raise is either the model's own mistake or an infrastructure
  failure — and those want opposite handling (§2.3, ADR 0010).
- **The loop spends real money on behalf of an unattended player.** A bounded
  run is not defensive programming, it is the product requirement (§5.1).
- **When the ceiling hits, the character is somewhere.** Mid-dungeon, torch lit
  or not, carrying whatever it picked up. Telling the player where they ended up
  is worth more than telling them a limit was reached (§5.1, wind-down).

The real MUD connection is **not** in this step and that deferral is correct —
see §2.7.

Like steps 03 and 04 this is **not** a translation exercise. The Python tree is a
deliverable that gets extended in week 2, so it is written as idiomatic Python
and is permitted to diverge from the Ruby where Python has a better answer. Every
divergence is deliberate and recorded (§8).

### Starting state — read this first

`week1_baseline/python/05_agent_loop` **already exists** as an untracked copy of
`week1_baseline/python/04_api_client`. This plan does not create the tree from
scratch; it adds to and modifies that copy. §4 marks every file
KEEP / NEW / EDIT.

**Confirm the starting state before writing anything:**

```bash
diff -rqx __pycache__ \
  week1_baseline/python/04_api_client \
  week1_baseline/python/05_agent_loop
```

This should report **no differences**. Verified clean at the time of writing.

**`week1_baseline/bin/python/05_agent_loop` already exists** and already points
at this step's directory. Nothing to create, nothing to `chmod`. Verified.

**Python version:** the tree runs on 3.14. PEP 695 syntax is already in use
(`Registry.tool[F: Callable[..., Any]]`), so the `type` statement used for
`ContentBlock` in §5.2 is available.

### Reference material

| Source | What it gives us |
|---|---|
| `ruby/05_agent_loop/lib/boukensha/agent.rb` | the loop, the ceiling, the wind-down call |
| `ruby/05_agent_loop/README.md` | the normalized-shape rationale, the "considerations" list |
| `ruby/05_agent_loop/examples/example.rb` | the example's tools and prompt |
| `ruby/08_the_repl_loop/lib/boukensha/agent.rb` | where the logger lands one step later |
| `ruby/12_context/lib/boukensha/agent.rb` | the end state: `turn_end`, token budgets, compaction |
| `ruby/10_standard_tool_library/lib/boukensha/tools/mud.rb` | where the real MUD arrives (20.4K, five steps later) |
| `.boukensha/prompts/player/system.md` | the prompt that **actually runs** (override is on) |

---

## 2. Upstream findings, and what we do about them

### 2.1 `LoopError` is defined, rescued, and never raised

`errors.rb` gains `class LoopError < StandardError; end` at step 05. From step 08
onward, `repl.rb` rescues it:

```ruby
rescue LoopError => e
  output("\n[error] #{e.message}")
```

A grep across **all twelve Ruby steps** finds no `raise LoopError` anywhere. The
REPL has an error branch for a condition that cannot occur, in four separate
steps. The design clearly *intended* the ceiling to raise; the wind-down call was
built instead and the vestige was never removed.

**What we do:** do not port it. Record the grep as the reason. Correct the stale
line in our own `errors.py` which predicts *"step 05 adds two more"* errors —
step 05 adds none.

### 2.2 The stop-reason collapse hides truncation

```ruby
stop_reason = response["stop_reason"] == "tool_use" ? "tool_use" : "end_turn"
```

Anthropic returns six stop reasons: `end_turn`, `max_tokens`, `stop_sequence`,
`tool_use`, `pause_turn`, `refusal`. Ruby folds five into one. The consequence
that matters: a reply cut off at the token ceiling is indistinguishable from one
the model chose to end, and `agent.rb:40-44` then returns the partial text as the
final answer. If that truncated reply also contained `tool_use` blocks, they are
silently dropped.

**What we do:** a `StopReason` enum with the three members the loop and README
can justify, plus `OTHER` via `_missing_` so an unrecognised value never crashes.
The raw wire string is kept alongside for step 06's logger (§5.3).

### 2.3 A tool that raises kills the run

Ruby's `handle_tool_calls` calls `@registry.dispatch(name, args)` unguarded.
Anything the handler raises propagates out of `Agent#run`.

Our step 02 already committed to fixing this. `registry.py` ships this docstring
today:

> Exceptions from the handler propagate uncaught, which matches the Ruby.
> Turning a tool failure into a tool *result* the model can read is the agent
> loop's job, not the registry's.

But "catch everything" is the wrong reading of that promise **in this domain**.
In a MUD, the things that look like failure — *"You can't go that way."*,
*"There is no such thing here."* — are ordinary strings the MUD returns; they
never raise. What actually raises splits cleanly in two:

| Raises | Can the model recover? |
|---|---|
| `UnknownToolError` — model invented a tool name | **Yes.** It reads the error and picks a real tool. |
| `TypeError` — model called `move(dir=…)` not `move(direction=…)` | **Yes.** It reads the error and fixes the keyword. |
| `ConnectionResetError`, socket timeout — the MUD dropped | **No.** |
| A bug in our tool code | **No.** |

Handing back the second kind as a tool result is actively harmful: the agent
issues another twenty-four commands into a dead socket, spends real money doing
it, and gives the player a confident summary of a session that never happened.

**What we do:** catch `UnknownToolError` and `TypeError`; let everything else
propagate. ADR 0010.

**Known cost, documented not hidden:** a `TypeError` raised *inside* a handler is
a genuine bug and is indistinguishable at the call site from a `TypeError` raised
by calling the handler with wrong keywords. Catching `TypeError` swallows that
narrow class of bug. Accepted; named in the README.

### 2.4 `Message.content` cannot hold what the loop must store

`agent.rb:96` does `@context.add_message(:assistant, content)` where `content` is
the **list of blocks** from the parsed response. Anthropic requires the
assistant's `tool_use` block to appear in the history before its matching
`tool_result`, so this is not optional.

Our `Message.content` is typed `str`. Step 04's plan and README both recorded
this as the one thing step 05 would have to widen, so it is expected rather than
discovered.

**What we do:** typed frozen content blocks and a widened `Message.content`
(§5.2). Ruby's `Context` is untyped, so it stores raw hashes and every backend
re-derives meaning from `b["type"]`; ours names the two shapes once.

### 2.5 The `tools:` ternary — already answered, never written

From step 05, every Ruby backend carries:

```ruby
tools: tools.nil? ? to_tools(context.tools) : tools
```

threaded up through `PromptBuilder#to_api_payload` and `Client#call`. Three
layers of plumbing to support one call site: the wind-down call that offers no
tools.

ADR 0004 (registry owns the catalog) and ADR 0009 (client transports payloads)
already removed the need. Our wind-down builder is `PromptBuilder(ctx, backend,
tools={})`. **No `tools=` parameter is added anywhere in this step.** This is the
forward-check ADR 0009 asserted but could not run; it now passes.

### 2.6 Presentation is welded into the loop

`agent.rb` calls `puts` from inside `run` and `handle_tool_calls`. Ruby fixes this
at step 08, where `Agent.new(…, logger:)` calls `@logger.iteration(n:, max:)` and
`@logger.limit_reached(kind:, n:, max:)`.

Our step 06 *is* the logger, so the seam is one rung away. Separately, `agent.py`
is library code — a package that writes to stdout unbidden is a genuine Python
smell, and steps 08 (REPL) and 11 (TUI) both need the output somewhere other than
`print`.

**What we do:** an `AgentLogger` Protocol with a `NullLogger` default. ADR 0011.

### 2.7 The real MUD is correctly deferred — the stand-in is not

`TCPSocket` appears in exactly three files across the whole Ruby ladder, all of
them `repl.rb`, at steps 10, 11 and 12. `tools/mud.rb` (20.4K) arrives at step 10.
Steps 05–09 never open a socket.

That deferral is well-founded and we keep it. `CONTEXT.md` defines a **Step** as
"a self-contained, runnable tree with its own README and example" — an example
requiring a live tbaMUD on `:4000` would not be runnable standalone. The MUD also
needs step 08's REPL to hold a session before it is even coherent.

What is *not* well-founded is the choice of stand-in. Step 05's example uses
`read_file` / `list_directory` and asks the model to summarise its own README —
while every system prompt in play tells the model it is playing a MUD:

| Prompt | Text |
|---|---|
| `.boukensha/prompts/player/system.md` (**what runs**) | "You are a MUD Journey Player Agent. You are playing the MUD on behalf of the player…" |
| `ruby/05_agent_loop/prompts/system.md` | "You are Boukensha, an autonomous player exploring a CircleMUD world." |
| `python/05_agent_loop/prompts/system.md` | "You are a MUD player assistant." |

`settings.yaml` sets `prompt_override.system: true` and the override file exists,
so the first one is live for both trees. The step whose entire subject is the
agent loop demonstrates it with tools that contradict the agent's stated
identity.

**What we do:** port the example as-is (decision 9) — the filesystem tools give
real, varied output that forces a genuine multi-iteration run with no invented
world, and it keeps the two trees comparable. **The README names the mismatch**
rather than inheriting it silently, and points at step 10 for the real tools.

### 2.8 "Turn" means three different things

| Source | "Turn" means |
|---|---|
| `CONTEXT.md` (from step 00's README) | one message in the history |
| Ruby `12_context` (`turn_tokens`, `turn_end`) | one goal→answer cycle, containing N iterations |
| The domain (and the project owner) | one command the player sends to the MUD |

Ruby is internally consistent — `reset_turn_tokens` at the start of `run`,
`add_turn_tokens` after every call, `turn_end(reason:, iterations:, tokens:)`
reporting iterations as a *field of the turn*. It simply has no word for one MUD
command, and **"goal" does not appear anywhere in `12_context`.**

Our own tree is *not* consistent. `Context.__repr__` ships `turns={len(...)}`
(the glossary sense), while four docstrings in the same files use the word to
mean an API round-trip — including `context.py:36`, whose "replayed on every
turn" is only true if a turn is a round-trip, and `context.py:22`, which is
circular under the glossary definition.

**What we do:** defer the naming decision — it is cheap now (step 05 adds only
`max_iterations`, correct under every reading) and belongs with step 12's work.
Add **Iteration** to `CONTEXT.md`, which is uncontested. Correct the four
contradictory docstrings so the ambiguity stops spreading (§7). The plan, README
and the wind-down directive avoid "turn" as a load-bearing word.

### 2.9 `parse_response` on the builder is pure pass-through

```ruby
def parse_response(response)
  @backend.parse_response(response)
end
```

Ruby needs this only because its `Agent` holds a builder and not a backend.
`PromptBuilder` is our **outbound** seam — context + tools + backend → payload.
Parsing is inbound and needs neither context nor tools.

**What we do:** `Agent` takes the backend directly and calls
`backend.parse_response`. `PromptBuilder` gains nothing. As a bonus the `Agent`
can construct both of its builders itself, so the example never names one.

### 2.10 Splitting tool results across messages — measured, not assumed

Ruby appends one `:tool_result` message per block, which our backend renders as N
consecutive `user` messages. Anthropic's tool-use guidance says to return all
`tool_result` blocks in a **single** user message and warns that splitting them
"silently trains Claude to stop making parallel calls" — but their multi-turn
guidance separately says consecutive same-role messages are combined into one
turn. The two statements are in tension.

**Rather than pick on a reading, this was measured.** Both shapes were sent to
`/v1/messages/count_tokens` with an identical conversation — a three-command
known-route batch (`south`, `south`, `look`) with its three results:

```
merged (1 user message, 3 blocks) : 847
split  (3 user messages, 1 each)  : 847
delta: +0 tokens
```

Both accepted; identical rendering. **The split is cosmetic**, so Ruby parity
costs nothing and the batching warning does not apply to a shape our loop can
produce. (Evidence quality: identical token counts is strong evidence of
identical rendering, not proof — two renderings could in principle coincide. At
847 tokens with a structural difference, convincing.)

This matters because batching is genuinely valuable here: once a route from A to
B has been explored one room at a time, the return trip can be fired as a single
multi-command batch. Against a 25-iteration ceiling, a six-room torch errand
costs 12 iterations hop-by-hop or 2 batched. **The loop supports that for free** —
it dispatches every `tool_use` block in the reply and returns every result.

**Note for step 10:** blind batching in a live world can drift — if the first
`south` returns "The door is closed.", later commands in the batch execute from
an unexpected room. The model sees all results together and can re-orient with a
`look`, so this is a prompt-design concern for the real MUD tools, not a
constraint on this loop. Recorded in the README.

---

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Assistant content is **typed frozen blocks** (`TextBlock` / `ToolUseBlock`); `Message.content: str \| Sequence[ContentBlock]` | §2.4; one vocabulary for parse and serialize; consistent with ADR 0001 |
| 2 | `Agent(context, registry, backend, client, …)`; builds both `PromptBuilder`s itself; calls `backend.parse_response` | §2.9, §2.5; no pass-through method, no `tools=` parameter |
| 3 | `StopReason` StrEnum — `TOOL_USE`/`END_TURN`/`MAX_TOKENS`/`OTHER` + `_missing_`; `Reply` keeps `raw_stop_reason` | §2.2; three members is what the loop justifies, `OTHER` absorbs the rest |
| 4 | Tool results: **one message per block**, Ruby parity | §2.10; measured identical to the merged form |
| 5 | Catch `UnknownToolError` + `TypeError` → result with `is_error=True`; everything else propagates | §2.3; ADR 0010 |
| 6 | Ceiling → **wind-down call** (directive, tools disabled, 400-token cap, `ApiError` fallback) | §5.1; the player needs to know where their character ended up |
| 7 | `Task.max_iterations: int = 25` | ADR 0001 predicted this field by name |
| 8 | `AgentLogger` Protocol + `NullLogger` default | §2.6; ADR 0011 |
| 9 | Example: Ruby's filesystem tools verbatim; README names the prompt mismatch | §2.7 |
| 10 | `LoopError` **not** ported | §2.1 |
| 11 | `Agent.run() -> str` | Ruby returns a String; step 08's REPL does `output(result)` |

---

## 4. File tree

```
week1_baseline/python/05_agent_loop/
├── README.md                       REWRITE
├── requirements.txt                KEEP
├── prompts/system.md               KEEP
├── examples/example.py             REWRITE
└── boukensha/
    ├── __init__.py                 EDIT   (export the new names)
    ├── agent.py                    NEW    the loop
    ├── content.py                  NEW    TextBlock / ToolUseBlock / ContentBlock
    ├── reply.py                    NEW    StopReason / Reply
    ├── logging.py                  NEW    AgentLogger / NullLogger
    ├── message.py                  EDIT   content widened; is_error added
    ├── context.py                  EDIT   add_message signature; docstrings (§2.8)
    ├── errors.py                   EDIT   stale docstring only
    ├── prompt_builder.py           EDIT   docstring only (§2.8)
    ├── client.py                   EDIT   docstring only (§2.8)
    ├── registry.py                 KEEP
    ├── tool.py                     KEEP
    ├── config.py                   KEEP
    ├── _repr.py                    KEEP
    ├── tasks/
    │   ├── base.py                 EDIT   max_iterations field
    │   └── player.py               KEEP
    └── backends/
        ├── __init__.py             KEEP
        ├── base.py                 EDIT   parse_response joins the contract
        └── anthropic.py            EDIT   parse_response; block + is_error serialization
```

Also produced outside the tree:

```
docs/adr/0010-agent-catches-model-mistakes.md      NEW
docs/adr/0011-agent-logger-protocol.md             NEW
CONTEXT.md                                          EDIT   (add Iteration)
```

Note `prompt_builder.py` and `client.py` stop being byte-identical with step 04's
copies for the sake of a one-line docstring each. That is the same kind of break
step 04 made with `config.py`, and it is deliberate: leaving four docstrings that
contradict the glossary is worse than the diff.

---

## 5. Design

### 5.1 `boukensha/agent.py` — NEW

```python
"""The agent loop: where the player's goal becomes work."""

DEFAULT_MAX_ITERATIONS = 25

#: The wind-down call is deliberately short and cheap.
WRAP_UP_OUTPUT_TOKENS = 400

#: Sent to the model when the ceiling is reached. Ruby says "for this turn";
#: we avoid that word (§2.8) and say what the player actually cares about.
WRAP_UP_DIRECTIVE = (
    "You have reached your action limit. Do not call any more tools. "
    "Briefly summarize what you accomplished, what is still unfinished, "
    "and the single next action you would take."
)


class Agent:
    def __init__(
        self,
        context: Context,
        registry: Registry,
        backend: Backend,
        client: Client,
        *,
        max_iterations: int | None = None,
        max_output_tokens: int | None = None,
        logger: AgentLogger | None = None,
    ) -> None:
        self._context = context
        self._registry = registry
        self._backend = backend
        self._client = client
        self._logger = logger or NullLogger()

        # Both builders are derived, not injected: a PromptBuilder is fully
        # determined by (context, backend, tools), all of which we hold.
        # The bare one is step 05's tools-disabled wind-down call - the
        # forward-check ADR 0009 asserted (§2.5).
        self._tools_builder = PromptBuilder(context, backend, tools=registry.tools)
        self._bare_builder = PromptBuilder(context, backend, tools={})

        self._max_iterations = self._resolve_max_iterations(max_iterations)
        self._max_output_tokens = max_output_tokens
        self._iteration = 0
```

`_resolve_max_iterations`: the explicit argument wins, then `context.task
.max_iterations`, then `DEFAULT_MAX_ITERATIONS`. `0` disables the ceiling, as in
Ruby (`@max_iterations.positive? && …`).

`max_output_tokens` stays `None` unless given — `PromptBuilder.to_api_payload`
already resolves it from the task, and ADR 0009's whole point is that there is
exactly one resolution point.

```python
    def run(self) -> str:
        while True:
            # A limit is a *trigger threshold*, not a hard cap: on reaching it
            # we stop starting new work and make exactly one terminal
            # wind-down call instead of raising.
            if self._limit_reached():
                self._logger.limit_reached(
                    kind="max_iterations", n=self._iteration,
                    limit=self._max_iterations,
                )
                return self._wrap_up()

            self._iteration += 1
            self._logger.iteration(n=self._iteration, limit=self._max_iterations)

            reply = self._call(self._tools_builder)
            if reply.stop_reason is not StopReason.TOOL_USE:
                return reply.text
            self._handle_tool_calls(reply)
```

Note what falls out of decision 3: a `MAX_TOKENS` reply is not `TOOL_USE`, so any
`tool_use` blocks it carries are **not dispatched** — the run ends and the reply's
`stop_reason` says why. Ruby dispatches nothing here either, but only because it
has already relabelled the reply `end_turn`.

```python
    def _handle_tool_calls(self, reply: Reply) -> None:
        # The assistant's tool_use blocks MUST be in the history before their
        # tool_result, or the API rejects the next request.
        self._context.add_message(Role.ASSISTANT, reply.content)

        for block in reply.tool_uses:
            self._logger.tool_call(name=block.name, args=block.input)
            try:
                text, is_error = str(self._registry.dispatch(block.name, block.input)), False
            except (UnknownToolError, TypeError) as exc:
                # The model's own mistake - it can read this and retry.
                # Infrastructure failures are NOT caught: see ADR 0010.
                text, is_error = f"{type(exc).__name__}: {exc}", True
            self._logger.tool_result(name=block.name, result=text, is_error=is_error)
            self._context.add_message(
                Role.TOOL_RESULT, text, tool_use_id=block.id, is_error=is_error
            )
```

One `add_message` per block — decision 4, measured equivalent to the batched form
(§2.10).

```python
    def _wrap_up(self) -> str:
        """One final, tools-disabled call so the run ends in character.

        Runs *outside* the counted loop: it never re-checks the limit (so it
        cannot re-trigger) and does not increment the iteration counter.
        Falls back to a deterministic message if the call fails.
        """
        self._context.add_message(Role.USER, WRAP_UP_DIRECTIVE)
        try:
            reply = self._call(self._bare_builder,
                               max_output_tokens=WRAP_UP_OUTPUT_TOKENS)
        except ApiError:
            return self._fallback()
        return reply.text.strip() or self._fallback()
```

`except ApiError` is exactly the single-`except` case step 04's `errors.py`
docstring predicted — the reason `ApiError` is one class and not a hierarchy.

### 5.2 `boukensha/content.py` — NEW

Two frozen dataclasses and a union:

```python
@dataclass(frozen=True, slots=True, repr=False)
class TextBlock:
    text: str


@dataclass(frozen=True, slots=True, repr=False)
class ToolUseBlock:
    id: str
    name: str
    input: Mapping[str, Any]

    def __post_init__(self) -> None:
        # Frozen with a mutable mapping inside is not frozen - the same
        # copy-then-wrap `Tool.parameters` already does.
        object.__setattr__(self, "input", MappingProxyType(dict(self.input)))


type ContentBlock = TextBlock | ToolUseBlock
```

Both get a hand-written `__repr__` using `_repr.truncate`, matching `Message` and
`Tool`.

**Unknown block types are dropped on parse.** Anthropic can return `thinking`
blocks; we do not enable thinking, and dropping them keeps the union closed.
Named as a limitation in the README so it is not rediscovered when someone turns
thinking on.

### 5.3 `boukensha/reply.py` — NEW

```python
class StopReason(StrEnum):
    """Why the model stopped. A closed vocabulary with an open escape hatch."""

    TOOL_USE = "tool_use"      # the loop's only continuation branch
    END_TURN = "end_turn"      # the model chose to stop
    MAX_TOKENS = "max_tokens"  # truncated - NOT the same as finished
    OTHER = "other"            # refusal, pause_turn, stop_sequence, anything new

    @classmethod
    def _missing_(cls, value: object) -> "StopReason":
        # A value we have never seen ends the run rather than crashing it.
        return cls.OTHER


@dataclass(frozen=True, slots=True)
class Reply:
    stop_reason: StopReason
    content: tuple[ContentBlock, ...]
    #: The verbatim wire value. `OTHER` is lossy; this is not. Step 06 logs it.
    raw_stop_reason: str

    @property
    def text(self) -> str: ...        # "".join of TextBlock texts
    @property
    def tool_uses(self) -> tuple[ToolUseBlock, ...]: ...
```

Three named members, not six: `REFUSAL`, `PAUSE_TURN` and `STOP_SEQUENCE` have no
caller in this step and would be speculative. `_missing_` means adding one later
is additive.

### 5.4 `boukensha/logging.py` — NEW

```python
class AgentLogger(Protocol):
    def iteration(self, *, n: int, limit: int) -> None: ...
    def tool_call(self, *, name: str, args: Mapping[str, Any]) -> None: ...
    def tool_result(self, *, name: str, result: str, is_error: bool) -> None: ...
    def limit_reached(self, *, kind: str, n: int, limit: int) -> None: ...


class NullLogger:
    """The default. A library writes nothing to stdout unbidden."""
```

Method names and keyword shapes are taken from Ruby's step-08 logger
(`iteration(n:, max:)`, `limit_reached(kind:, n:, max:)`) so step 06 converges
rather than diverges. `max` → `limit` because `max` shadows a builtin.

`examples/example.py` supplies a small printing implementation; the package
itself never calls `print`. ADR 0011.

### 5.5 `boukensha/message.py` — EDIT

```python
role: Role
content: str | Sequence[ContentBlock]
tool_use_id: str | None = None
is_error: bool = False
```

`__post_init__` coerces a block sequence to a `tuple` — frozen with a list inside
is not frozen, the same reasoning as `Tool.parameters`. `is_error` is only
meaningful on `TOOL_RESULT`, exactly as `tool_use_id` already is; the class does
not enforce that, and the backend that builds the payload is where it matters.

### 5.6 `boukensha/context.py` — EDIT

`add_message` widens to accept blocks and an error flag:

```python
def add_message(
    self,
    role: Role | str,
    content: str | Sequence[ContentBlock],
    *,
    tool_use_id: str | None = None,
    is_error: bool = False,
) -> None:
```

No new methods (decision 4 removed the need for `add_tool_results`). Plus the
docstring corrections from §2.8 at lines 22, 36 and 39: "turn" → "iteration"
where an API round-trip is meant.

### 5.7 `boukensha/backends/base.py` — EDIT

`parse_response` joins the abstract contract — the next method after
`to_messages`, `to_tools`, `to_payload`, `headers`, `url`:

```python
@abstractmethod
def parse_response(self, response: Mapping[str, Any]) -> Reply:
    """Normalize this provider's response into the common `Reply` shape.

    The inverse direction of `to_messages`. Ruby's five backends each
    implement this plus a private `assistant_message` that rebuilds a
    provider-specific assistant turn from the normalized blocks; Anthropic's
    content array doubles as both shapes, so ours needs no inverse.
    """
```

### 5.8 `boukensha/backends/anthropic.py` — EDIT

Three changes.

**`parse_response`** — map wire blocks to typed ones, drop unknown types, and
build the `Reply`. `StopReason(raw)` routes anything unexpected (including a
missing field) to `OTHER` via `_missing_`.

**`to_messages`** — an assistant message whose content is a block sequence
serializes to a content list; a `str` still passes straight through:

```python
{"role": "assistant", "content": [self._to_wire(b) for b in message.content]}
```

**`is_error`** — added to the `tool_result` block only when set, so unaffected
payloads stay byte-identical to step 04's:

```python
block = {"type": "tool_result", "tool_use_id": …, "content": …}
if message.is_error:
    block["is_error"] = True
```

### 5.9 `boukensha/tasks/base.py` — EDIT

```python
#: Iterations the loop may run before winding down. Ruby's Tasks::Base gains
#: DEFAULT_MAX_ITERATIONS = 25 at this step; ADR 0001 predicted the field.
DEFAULT_MAX_ITERATIONS = 25
```

`max_iterations: int = DEFAULT_MAX_ITERATIONS` on the dataclass, read in
`from_settings` and coerced with `int()`, exactly as `max_output_tokens` already
is.

### 5.10 `boukensha/errors.py` — EDIT

Docstring only. The current text says the base class "will be wanted: step 03
adds an unsupported-model error and step 05 adds two more." Step 05 adds none —
`LoopError` is not ported (§2.1). Correct the sentence and cite the grep.

### 5.11 `examples/example.py` — REWRITE

Ruby's example, ported: `read_file` and `list_directory` scoped to the step
directory, the prompt asking for a README summary, and an `Agent` wired from the
pieces the example already builds.

```python
agent = Agent(ctx, registry, backend, client, logger=PrintLogger())
result = agent.run()
```

No `PromptBuilder` line — the Agent derives both (§2.9). `PrintLogger` lives in
the example, not the package (§2.6).

### 5.12 `README.md` — REWRITE

Sections carried from the established shape, plus these specific to step 05:

- **The normalized shape** — what `Reply` is and why the loop never sees a raw
  provider response.
- **Why truncation is not "done"** — §2.2.
- **What the loop catches, and what it deliberately does not** — §2.3, the
  `TypeError` caveat stated plainly.
- **Why the example is not playing the MUD** — §2.7, with the prompt table and
  the pointer to step 10.
- **Parallel tool calls** — the 847-vs-847 measurement, and the state-drift note
  for step 10's real tools (§2.10).
- **Divergence table** (§8) and **Out of scope** (§10).

---

## 6. ADRs

### 6.1 ADR 0010 — The agent loop catches the model's mistakes, not infrastructure failures

**Hard to reverse?** Yes — it defines what a tool author may assume about
exceptions, and step 10's MUD tools are written against it.
**Surprising?** Yes — the obvious reading of step 02's docstring is "catch
everything."
**A real trade-off?** Yes — recoverability for the rare hallucinated call, versus
an agent that keeps issuing commands into a dead MUD socket.

Records the four-row table from §2.3, the `TypeError` ambiguity, and the
rejected alternatives (`except Exception`; catching nothing).

### 6.2 ADR 0011 — Progress reporting goes through an AgentLogger protocol

**Hard to reverse?** Yes — step 06 implements this protocol, and steps 08 and 11
consume it.
**Surprising?** Yes — Ruby just calls `puts`, and defining an interface one step
before its implementation looks like speculative generality.
**A real trade-off?** Yes — YAGNI versus a library that writes to stdout unbidden
and a known consumer one rung away.

Records why the method shapes mirror Ruby's step-08 logger, and the risk
accepted: if step 06 needs a different vocabulary, this protocol changes.

---

## 7. `CONTEXT.md`

One term added. The **Turn** conflict (§2.8) is deliberately *not* resolved here.

```markdown
**Iteration**
: One model round-trip while the agent works: send the history, read the reply,
dispatch any tools it asked for. A single goal takes many. `max_iterations` caps
them; reaching the cap triggers a wind-down, not an error.
```

Four docstrings corrected so the ambiguity stops spreading: `context.py` lines
22, 36 and 39, and the "tools-disabled turn" phrasing in `prompt_builder.py:24`
and `client.py:106` → "wind-down call".

---

## 8. Divergence table (for the README)

| # | Ruby | Python | Why |
|---|---|---|---|
| 1 | `content` is a raw array of hashes | typed `TextBlock` / `ToolUseBlock` | one vocabulary for both directions; ADR 0001's ethos |
| 2 | `stop_reason` collapsed to two values | `StopReason` enum + raw string | truncation is not completion (§2.2) |
| 3 | `Agent.new(builder:, client:)` + `builder.parse_response` | takes the backend; builders derived | the pass-through adds nothing (§2.9) |
| 4 | `tools:` threaded through three layers | never written | ADR 0004 + ADR 0009 |
| 5 | tool exceptions propagate | model's mistakes become results | §2.3, ADR 0010 |
| 6 | `puts` from inside the loop | `AgentLogger` + `NullLogger` | §2.6, ADR 0011 |
| 7 | `LoopError` defined, never raised | not ported | §2.1 |
| 8 | `Tasks::Base.max_iterations(settings)` class method | `Task.max_iterations` field | ADR 0001 |
| 9 | `max_output_tokens` defaulted in two places | resolved once in `PromptBuilder` | step 03 |
| 10 | five backends implement `parse_response` | one does | ADR 0006 |

---

## 9. Verification

```bash
# 1. Starting state is a clean copy of step 04
diff -rqx __pycache__ week1_baseline/python/04_api_client \
                      week1_baseline/python/05_agent_loop

# 2. The step runs, loops, and returns
./week1_baseline/bin/python/05_agent_loop
```

Expect: several `[iteration n/25]` lines, at least one `tool call →` /
`tool result →` pair, and a final response. Spends a few cents.

Then confirm by inspection:

- `grep -rn "print(" week1_baseline/python/05_agent_loop/boukensha/` → no hits.
- `grep -rn "tools=" week1_baseline/python/05_agent_loop/boukensha/` → only the
  two `PromptBuilder` constructions in `agent.py`; no `tools=` parameter on any
  method.
- `grep -rn "LoopError" week1_baseline/python/` → no hits.
- A run whose model hallucinates a tool name should continue, not crash.

---

## 10. Out of scope

- **The real MUD connection.** Step 10 (`tools/mud.rb`, 20.4K) and the REPL that
  holds a session (step 08). §2.7.
- **A knowledge / recall layer** — distilling durable lessons from past play
  ("the mob in the east wing kills us"). Nothing on the ladder does this; step 12
  (`12_context`) is the nearest home, since compaction is already
  "summarise what happened into what is worth keeping," and step 06's run files
  are its raw material. **What step 05 must not do is foreclose it**, and it
  doesn't: `Agent` *borrows* a `Context` it did not create and does not own, so a
  future caller can hydrate one from disk, run, and write it back. `Message`
  stays a frozen, serialisable record. Worth noting that the wind-down summary is
  already a distillation — "reached the temple, found the lever, no torch, would
  search the entry passage next" — produced once per run for free, and a natural
  input to whatever step 12 builds.
- **`disable_parallel_tool_use`.** The API can suppress multi-tool replies; we do
  not use it. The loop handles N ≥ 1 correctly either way (§2.10), and
  constraining the model is a step-10 prompt-design question.
- **Resolving the "Turn" conflict.** §2.8, deferred to step 12.
- **The other four backends.** ADR 0006.
- **Token budgets, compaction, `turn_end` accounting.** Ruby's `12_context`
  `Agent` adds `max_turn_tokens`, `needs_compaction?` and usage accumulation.
  Step 12.
- **`thinking` blocks.** Dropped on parse (§5.2). Turning thinking on means
  extending the `ContentBlock` union and preserving the blocks on replay.
- **A test suite.** No test file, directory, or dependency is created by this
  step. It binds every subsequent step to a convention and deserves its own ADR
  rather than arriving sideways.
