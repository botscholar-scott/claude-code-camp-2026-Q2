# 03 · The Prompt Builder (Python)

The Prompt Builder is the object that turns a **context** plus a **tool catalog**
into the exact JSON payload an LLM API expects.

Steps 01 and 02 built the two halves of an API call and deliberately kept them
apart: a `Context` is the conversation, a `Registry` is the capability set, and
neither knows about the other. **This is the step where they meet.**

It arrives with a second object, the **Backend** — the thing that owns the
provider-specific shape of that payload, its endpoint, and its headers. A backend
serializes; it does not send. Nothing in this step makes a network call.

This is the Python port of `week1_baseline/ruby/03_prompt_builder`, built on top
of [step 02](../02_the_registry/README.md). The deliberate differences are listed
under [Divergences from the Ruby port](#divergences-from-the-ruby-port).

**Step 03 is additive over step 02** for everything except three edits that reach
into classes earlier steps own: `Registry.tool` gains `required=`, `Tool` gains a
`required` field, and `Task` gains `max_output_tokens`. Step 02's tree is
untouched and remains a valid frozen snapshot.

## Setup

Runs on the repo-root `.venv`, currently **Python 3.14.5**:

```bash
python3 -m venv .venv                                                 # at the repo root
.venv/bin/pip install -r week1_baseline/python/03_prompt_builder/requirements.txt
```

`requirements.txt` is unchanged from steps 00–02 (`PyYAML` and `python-dotenv`,
both still needed by `Config`). Everything new in this step is pure standard
library.

Steps 00–02 advertise a **3.11+** floor. This step drops that claim rather than
repeating it: there is no `pyproject.toml`, no `python_requires`, no CI and no
consumer installing this anywhere, so a supported-version floor is documentation
for a distribution story that does not exist. The one place it cost something —
`Registry.tool` using `TypeVar` instead of the cleaner PEP 695 generic syntax —
is fixed here; see [Type parameters](#type-parameters).

## New Files

| File | Purpose |
|------|---------|
| `boukensha/prompt_builder.py` | **new** — `PromptBuilder` |
| `boukensha/backends/base.py` | **new** — `Backend` ABC, `ModelInfo`, `UsageUnit` |
| `boukensha/backends/anthropic.py` | **new** — `AnthropicBackend` and the model table |
| `boukensha/backends/__init__.py` | **new** — `backend_for()`, the provider seam |
| `boukensha/errors.py` | edited — `UnsupportedModelError`, `UnsupportedProviderError` |
| `boukensha/tool.py` | edited — the `required` field and its validation |
| `boukensha/registry.py` | edited — `required=` on `tool()` |
| `boukensha/tasks/base.py` | edited — `max_output_tokens` + `DEFAULT_MAX_OUTPUT_TOKENS` |
| `boukensha/__init__.py` | edited — exports the above |
| `examples/example.py` | rewritten — builds a real payload and prints it |

`config.py`, `context.py`, `message.py`, `_repr.py`, `tasks/player.py`,
`prompts/` and `requirements.txt` are **byte-identical to step 02**.

## How It Works

```
Context   ─┐
           ├─→  PromptBuilder  ─→  Backend  ─→  {"model": …, "system": …,
Catalog   ─┘                                     "max_tokens": …, "tools": […],
                                                 "messages": […]}
```

The builder knows *what* goes into a call. The backend knows *what shape* one
provider wants it in. Swapping providers changes the backend and nothing else.

## Why only Anthropic

The Ruby step ships five backends — Anthropic, OpenAI, Gemini, Ollama and
OllamaCloud — and opens with the case for provider independence. The ladder does
not sustain it:

- `12_context/lib/boukensha/models.rb`, the step-12 model table, contains
  **only three entries, all Claude** (`claude-opus-4-8`, `claude-sonnet-4-6`,
  `claude-haiku-4-5`).
- `12_context/lib/boukensha/backends/gemini.rb` has three of its five models
  commented out, and the only live replacement commented out too.
- This repo's own `.boukensha/settings.yaml` fixture is `provider: anthropic`.

So five backends at step 03 become effectively one by step 12. Porting the other
four would ship four code paths nobody here will ever run.

**This port ships the Anthropic backend only, and keeps the seam.**
`backends/base.py` defines the contract, `backends/anthropic.py` is the single
implementation, and `backend_for()` rejects anything else by name. Adding OpenAI
in week 2 costs **one new file and one row in `_BACKENDS`**; nothing else moves.

The ABC is not speculative — all five reference implementations were read during
design and validated against its shape. See
[ADR 0006](../../../docs/adr/0006-port-ships-only-the-anthropic-backend.md).

---

## `boukensha.PromptBuilder`

| Member | Description |
|---|---|
| `PromptBuilder(context, backend, *, tools)` | Joins a context and a tool catalog to a backend |
| `to_messages()` | The conversation in the backend's message shape |
| `to_tools()` | The catalog in the backend's tool-definition shape |
| `to_api_payload(*, max_output_tokens=None)` | The complete request body for one call |
| `headers(api_key)` | The request headers, given the credential |
| `url` | The endpoint the payload is posted to |

```python
ctx = Context(task=player, system=player.system_prompt)
registry = Registry()
backend = backend_for(player)

builder = PromptBuilder(ctx, backend, tools=registry.tools)
```

### It takes the catalog, not the `Registry`

`tools` is a `Mapping[str, Tool]`. The builder reads `name`, `description`,
`parameters` and `required`; it never calls `dispatch` and never imports
`Registry`. That is a narrower dependency, it is testable with a bare dict, and
it makes step 05's tools-disabled turn fall out for free:

```python
PromptBuilder(ctx, backend, tools={})     # no tools offered this turn
```

The Ruby needs `tools: tools.nil? ? to_tools(context.tools) : tools` in **all
five** of its backends to express that. Here it is not a special case at all —
which is the wart [ADR 0004](../../../docs/adr/0004-registry-owns-the-tool-catalog.md)
predicted this design would avoid.

### The catalog is a live view, not a snapshot

`tools` is **not copied**. `registry.tools` is a `MappingProxyType` over the live
dict, so a builder constructed before registration still sees tools registered
afterwards:

```python
>>> builder = PromptBuilder(ctx, backend, tools=registry.tools)
>>> len(builder.to_tools())
2
>>> @registry.tool("flee", description="Run away")
... def flee(): ...
>>> len(builder.to_tools())
3
```

That matters for step 07's `RunDSL`, where registration happens inside a block. A
defensive copy would silently freeze the catalog.

---

## `boukensha.AnthropicBackend`

| Member | Description |
|---|---|
| `AnthropicBackend(*, model)` | Validates the model against `MODELS`; takes **no credential** |
| `MODELS` | model id → `ModelInfo`. The table below |
| `model` | The validated model id |
| `model_info` | The `ModelInfo` for that model |
| `context_window` | The model's total token ceiling for one call |
| `input_cost_per_million` / `output_cost_per_million` | Dollars per million tokens |
| `estimate_cost(*, input_tokens, output_tokens)` | Dollars for a call of that size — a `float`, never `None` |
| `USAGE_UNIT` | `UsageUnit.TOKENS`. A property of the provider, not the model |
| `API_KEY_ENV` | `"ANTHROPIC_API_KEY"` — the *name* of the variable, not its value |
| `to_messages(context)` / `to_tools(tools)` / `to_payload(…)` | The serializers |
| `headers(api_key)` / `url` | The request metadata |

### The model table

**Static tutorial data, accurate as of 2026-07-25.** It is not fetched, it does
not refresh, and it will go stale. That is fine for a teaching ladder and is the
same choice the Ruby makes — its README date-stamps its own table to June 16,
2026.

| Model | Context window | $/M input | $/M output |
|---|---:|---:|---:|
| `claude-opus-5` | 1,000,000 | 5.00 | 25.00 |
| `claude-sonnet-5` | 1,000,000 | 3.00 | 15.00 |
| `claude-fable-5` | 1,000,000 | 10.00 | 50.00 |
| `claude-opus-4-8` | 1,000,000 | 5.00 | 25.00 |
| `claude-sonnet-4-6` | 1,000,000 | 3.00 | 15.00 |
| `claude-haiku-4-5` | 200,000 | 1.00 | 5.00 |
| `claude-haiku-4-5-20251001` | 200,000 | 1.00 | 5.00 |

The Ruby's four Anthropic rows were checked and are **accurate**; what the table
lacked was the models released since, so a settings file naming a current model
had to edit the library to work. The last four rows above are the Ruby's,
unchanged. The first three are new.

**Why `claude-sonnet-5` is listed at 3.00 / 15.00 and not its introductory
2.00 / 10.00:** the introductory rate expires **2026-08-31**, and a static
`cost_per_million` cannot express a price with an end date. One entry is enough
to show why the table is documentation rather than an authority — check current
pricing before you bill anyone against it.

`advertised_context_window` and `usage_level` are **not ported**. Both are Ollama
Cloud's alone, and `advertised_context_window` is read by nothing in twelve
steps.

### `estimate_cost` returns a `float`, never `None`

```python
>>> backend.estimate_cost(input_tokens=1_000_000, output_tokens=1_000_000)
6.0
```

Ruby guards with `return nil unless input_token_cost_per_million && …` because
Ollama Cloud's pricing is plan-based and its rows carry `input: nil, output: nil`.
Every Anthropic price is known, so the guard has nothing to catch and the
`float | None` never reaches step 06's logger.

---

## Credentials

**The backend holds no credential.** There is no `api_key` field, and nothing
anywhere in the library reads `os.environ`:

```python
backend = AnthropicBackend(model="claude-haiku-4-5")   # complete, valid, keyless
builder.to_api_payload()                               # works
builder.url                                            # works
builder.headers("sk-ant-…")["x-api-key"]               # 'sk-ant-…'
```

The Ruby writes `Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"), model:)`,
and `ENV.fetch` raises when the variable is unset — so **the step that sends
nothing cannot run without an Anthropic account.** The key is used by exactly one
of the backend's five members. Here it arrives at that one call:
`headers(api_key)`.

`API_KEY_ENV` stays on the class as the *name* of the variable, so step 04's
`Client` knows what to fetch. See
[ADR 0007](../../../docs/adr/0007-backend-holds-no-credentials.md).

```bash
# no key in the environment, and a config dir with no .env either
TMP=$(mktemp -d); cp .boukensha/settings.yaml "$TMP/"; cp -r .boukensha/prompts "$TMP/"
env -u ANTHROPIC_API_KEY BOUKENSHA_DIR="$TMP" ./week1_baseline/bin/python/03_prompt_builder
# exit 0 — full payload printed, header line reads `x-api-key: ***`
```

(`env -u` on its own is not enough to prove it: this repo's `.boukensha/.env`
defines `ANTHROPIC_API_KEY` and `Config.load()` loads it.)

---

## Optional tool parameters

`Registry.tool` gains one keyword:

```python
@registry.tool(
    "look_at",
    description="Look at something, or at the room",
    parameters={
        "target": {"type": "string", "description": "…Omit entirely to describe the current room."},
        "preposition": {"type": "string", "description": "Preposition: in, at, north… (optional)"},
    },
    required=[],
)
def look_at(target=None, preposition=None): ...
```

| `required=` | Meaning |
|---|---|
| omitted (`None`) | **all** parameters are required — the Ruby's only behaviour |
| `[]` | none are required |
| `["direction"]` | exactly those |

Omitting it reproduces the Ruby exactly, so this is purely additive and every
existing call site keeps its behaviour.

### The bug this fixes

The Ruby hardcodes every parameter as mandatory:

```ruby
required: tool.parameters.keys.map(&:to_s)   # all of them, always
```

There is no way to declare an optional parameter. At step 03 that is harmless —
`look` has none and `move` has one required one. By step 10 the tools contradict
themselves:

```ruby
# 10_standard_tool_library/lib/boukensha/tools/mud.rb:137
parameters: {
  target:      { type: "string", description: "…Omit entirely to describe the current room." },
  preposition: { type: "string", description: "Preposition: in, at, north… (optional)" }
} do |target: nil, preposition: nil|
```

The description tells the model both arguments are optional; the schema tells the
API both are mandatory. **The schema wins.** The same defect affects
`file_system.rb`'s `list` and `grep`, and `mud.rb`'s `attack`, `say` and `msg`.

This step owns schema serialization, so this is where it gets fixed.

A name in `required=` that is not in `parameters` is caught at registration:

```python
>>> @registry.tool("bad", description="…", parameters={"a": {}}, required=["b"])
... def bad(a=None): ...
ValueError: tool 'bad' marks unknown parameter(s) required: b
```

That is a startup error instead of a schema the provider rejects mid-run.

**Rejected: deriving `required` from the handler signature** — a parameter with a
default is optional, so `inspect.signature` could infer the whole thing. Rejected
because its failure mode is a *silently wrong* `required`, which is the same
class of bug being fixed, and it has real edge cases (`**kwargs`, positional-only
parameters, a parameter in `parameters` but absent from the signature).
`required` is a standard JSON Schema keyword; writing it is less clever and more
obvious.

### Type parameters

`Registry.tool` is generic in the decorated function's type, so a type checker
sees `move` keep its own signature after decoration:

```python
def tool[F: Callable[..., Any]](self, name, *, description, …) -> Callable[[F], F]:
```

Step 02 writes the same thing the older way — a module-level
`F = TypeVar("F", bound=Callable[..., Any])` — and
[ADR 0005](../../../docs/adr/0005-tools-register-via-decorator.md) justified that
choice by "keeping the floor at Python 3.11+". There is no such floor: nothing in
this repo declares a supported version, and the only interpreter the tree has
ever run on is the repo-root venv. The PEP 695 form scopes the type parameter to
the method that uses it and drops both the module-level binding and the `TypeVar`
import.

Step 02's `registry.py` is **not** edited — it stays the frozen snapshot it is
documented to be — so this is a visible difference between the two trees.

---

## `max_output_tokens`

It is now a **task setting**, with a default:

```yaml
tasks:
  player:
    provider: anthropic
    model: claude-haiku-4-5
    max_output_tokens: 4096      # optional; defaults to 16000
```

```python
>>> builder.to_api_payload()["max_tokens"]
16000
>>> builder.to_api_payload(max_output_tokens=512)["max_tokens"]      # per-call override
512
```

Resolution happens in **one place**, `PromptBuilder.to_api_payload`: the explicit
argument wins, then the task's setting, then `DEFAULT_MAX_OUTPUT_TOKENS`. Ruby
hardcodes `1024` in the builder *and* in every backend's `to_payload` — six
copies of one number.

**Why 16000 and not 1024.** 1024 predates the current models. On `claude-opus-5`
thinking is on by default and `max_tokens` caps thinking *plus* response text
together, so a 1024 ceiling truncates mid-answer on a model this table now
offers. Anthropic's guidance for non-streaming requests is around 16000. The
fixture's `claude-haiku-4-5` survives 1024 fine — this is about the models the
table makes available, not the one it runs today.

The root `.boukensha/settings.yaml` is **not** edited. The default applies, and
that fixture is shared with the Ruby tree.

---

## Payload shapes

### System prompt

Anthropic takes the system prompt as a **top-level `system` field**, not as a
message with `role: "system"`. It comes straight from `context.system`, which
step 00's prompt resolution filled in.

### Message roles

| `Role` | Serializes as |
|---|---|
| `USER` | `{"role": "user", "content": …}` |
| `ASSISTANT` | `{"role": "assistant", "content": …}` |
| `TOOL_RESULT` | a **`user`** message carrying a `tool_result` block |

### Tool results

`tool_result` is a pseudo-role — no provider has it. Anthropic wants it as a
`user` message whose `content` is a *list* holding one block:

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01X",
      "content": "A damp stone corridor stretches north."
    }
  ]
}
```

`tool_use_id` pairs the result to the call that requested it. The pairing must be
exact or the API rejects the request.

### Tool definitions

```json
{
  "name": "move",
  "description": "Move the player in a direction (north, south, east, west, up, down)",
  "input_schema": {
    "type": "object",
    "properties": {"direction": {"type": "string", "description": "The direction to move"}},
    "required": ["direction"]
  }
}
```

`properties` is `tool.parameters` passed **straight through** — which is why the
per-argument `description` restored at step 02 matters. It is the only thing
telling the model what an argument means.

---

## Errors

```
BoukenshaError
├── UnknownToolError            (step 02)
├── UnsupportedModelError       (new — Ruby has this)
└── UnsupportedProviderError    (new — Ruby raises a bare ArgumentError)
```

```python
>>> AnthropicBackend(model="claude-opus-9")
UnsupportedModelError: AnthropicBackend does not support model 'claude-opus-9'. Supported models: claude-fable-5, claude-haiku-4-5, claude-haiku-4-5-20251001, claude-opus-4-8, claude-opus-5, claude-sonnet-4-6, claude-sonnet-5

>>> backend_for(replace(player, provider="openai"))
UnsupportedProviderError: unsupported provider 'openai' for task 'player'. Supported providers: anthropic
```

Both are the same kind of failure — *settings.yaml names something we do not
support* — so both live in one catchable family. Ruby's flat
`UnsupportedModelError < StandardError` plus an inline `ArgumentError` splits
them for no reason.

`Task.from_settings` still raises plain `ValueError` for a **missing** provider or
model. Absent and unknown are genuinely different failures.

---

## `backend_for()` — the provider seam

```python
backend = backend_for(player)      # provider -> class, model -> validated
```

It reads nothing from the environment and takes no credential. Its whole job is
one dict:

```python
_BACKENDS: Mapping[str, type[Backend]] = {"anthropic": AnthropicBackend}
```

The Ruby writes this as a `case provider` in the example — and then copies it
into steps 04, 05, and `lib/boukensha.rb` at steps 07, 09, 10, 11 and 12. **Seven
places.** Step 12 carries a *second* case statement beside it mapping provider to
environment variable name. Both belong to the seam: `backend_for()` owns
provider→class, and `Backend.API_KEY_ENV` owns the variable name.

`Task.provider` stays a plain `str` rather than becoming an enum. The registry of
valid providers *is* that dict, so the check belongs with the knowledge rather
than in a one-member enum three lines earlier in the example.

---

## Considerations

**The conversation is stateless.** The API remembers nothing between calls. Every
turn replays the *entire* history — which is why `to_api_payload()` grows without
bound, and why step 12 needs compaction.

**Tool results are `user` messages.** Counterintuitive, and correct: from the
API's point of view the tool result is something *given to* the model, and the
only role that gives things to the model is `user`.

**The model only ever sees schemas, never handlers.** `to_tools()` serializes
`name`, `description` and `input_schema`. The `handler` never leaves the process.
The model asks for a tool by name; step 05's agent loop is what actually calls it.

**Context window ≠ max output tokens.** `context_window` is the model's total
ceiling for one call, input and output together — a fact about the model, looked
up, never configured. `max_output_tokens` caps only the response. Step 12's README
retracts a `budget=8192` that was exactly this confusion.

**`to_messages()` and `to_tools()` get their first caller here.** They are public
in the Ruby from step 03 through step 12 and `grep` finds **zero** callers —
`Client` uses only `to_api_payload`, `headers` and `url`. Worse, they are broken:
`PromptBuilder#to_messages` calls `@backend.to_messages(@context.messages)` with
one argument, but OpenAI, Ollama and OllamaCloud define
`to_messages(system, messages)`, so it raises `ArgumentError` on three of the five
backends. Nobody notices, because nobody calls it. Anthropic-only dissolves the
inconsistency — there is one signature — and the example prints both methods,
which is the clearest demonstration of what this step actually does.

## Run Example

```bash
./week1_baseline/bin/python/03_prompt_builder
```

Actual output against this repo's `.boukensha/` fixture:

```
=== Boukensha Step 3: The Prompt Builder ===

Config:         Config(dir='/Users/scott/src/GITROOT/botscholar-scott/claude-code-camp-2026-Q2/.boukensha', tasks=['player'])
Provider:       anthropic
Model:          claude-haiku-4-5
Context window: 200,000 tokens
URL:            https://api.anthropic.com/v1/messages

Headers (x-api-key redacted):
  Content-Type: application/json
  x-api-key: ***
  anthropic-version: 2023-06-01

to_messages():
[
  {
    "role": "user",
    "content": "I just arrived in the dungeon. What's around me, and can you move north?"
  },
  {
    "role": "assistant",
    "content": "Let me take a look around first."
  },
  {
    "role": "user",
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "toolu_01X",
        "content": "A damp stone corridor stretches north. Torches flicker on the walls."
      }
    ]
  }
]

to_tools():
[
  {
    "name": "look",
    "description": "Look around the current room for details",
    "input_schema": {
      "type": "object",
      "properties": {},
      "required": []
    }
  },
  {
    "name": "move",
    "description": "Move the player in a direction (north, south, east, west, up, down)",
    "input_schema": {
      "type": "object",
      "properties": {
        "direction": {
          "type": "string",
          "description": "The direction to move"
        }
      },
      "required": [
        "direction"
      ]
    }
  }
]

to_api_payload():
{
  "model": "claude-haiku-4-5",
  "system": "You are a MUD Journey Player Agent. You are playing the MUD on behalf of the player, and the player will issue you goals to complete.\nUse the tools available to you to help the player explore, fight, and interact with the world.",
  "max_tokens": 16000,
  "tools": [
    {
      "name": "look",
      "description": "Look around the current room for details",
      "input_schema": {
        "type": "object",
        "properties": {},
        "required": []
      }
    },
    {
      "name": "move",
      "description": "Move the player in a direction (north, south, east, west, up, down)",
      "input_schema": {
        "type": "object",
        "properties": {
          "direction": {
            "type": "string",
            "description": "The direction to move"
          }
        },
        "required": [
          "direction"
        ]
      }
    }
  ],
  "messages": [
    {
      "role": "user",
      "content": "I just arrived in the dungeon. What's around me, and can you move north?"
    },
    {
      "role": "assistant",
      "content": "Let me take a look around first."
    },
    {
      "role": "user",
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "toolu_01X",
          "content": "A damp stone corridor stretches north. Torches flicker on the walls."
        }
      ]
    }
  ]
}
```

Compare with `./week1_baseline/bin/ruby/03_prompt_builder` (which needs
`ANTHROPIC_API_KEY` set, or it dies before printing anything):

```
=== BOUKENSHA Step 3: Prompt Builder ===

Config: #<Boukensha::Config dir=/Users/…/.boukensha tasks=player>
Provider: anthropic
Model: claude-haiku-4-5
{
  "model": "claude-haiku-4-5",
  "system": "You are a MUD Journey Player Agent. …",
  "max_tokens": 1024,
  "tools": [ … ],
  "messages": [ … ]
}
```

The two payloads are **identical except for `max_tokens`** — same five keys in
the same order, same three messages, same two tool definitions with `look` at
`"required": []` and `move` at `"required": ["direction"]`, same
`tool_use_id: "toolu_01X"` on the `tool_result` block. 16000 against 1024 is
divergence row 13.

The Python run also prints the URL, the redacted headers, `to_messages()` and
`to_tools()`, which the Ruby example does not.

## Divergences from the Ruby port

Steps 00–02's divergences all still apply. These are the rows step 03 adds.

| # | Ruby | This port | Why |
|---|---|---|---|
| 1 | five backends (Anthropic, OpenAI, Gemini, Ollama, OllamaCloud) | **Anthropic only**, seam kept | four would never be run here; the ladder itself converges on Claude by step 12; ADR 0006 |
| 2 | `PromptBuilder.new(context, backend)`, reaching `@context.tools` | `PromptBuilder(context, backend, *, tools=…)` | ADR 0004 moved the catalog to `Registry`; the builder takes the catalog, not the registry |
| 3 | `Backends::Anthropic.new(api_key:, model:)` | `AnthropicBackend(model=…)`; `headers(api_key)` | a serializer needs no credential; step 03 sends nothing; ADR 0007 |
| 4 | `headers` is a no-arg method | `headers(api_key)` | follows from row 3 |
| 5 | class `Boukensha::Backends::Anthropic` | class `AnthropicBackend` | collides with the SDK's `Anthropic` at step 04 |
| 6 | `to_messages(messages)` / `to_messages(system, messages)` — inconsistent, and `ArgumentError` on 3 of 5 backends | one `to_messages(context)` | latent bug in all 12 Ruby steps; one backend, one signature |
| 7 | `required: tool.parameters.keys` — every parameter mandatory | explicit `required=`, defaulting to all | step 10 declares optional parameters the schema contradicts |
| 8 | model table entries are nested hashes | frozen `ModelInfo` dataclass | ADR 0001; typed, typo-catching |
| 9 | `usage_unit` on every model row | `USAGE_UNIT` class attribute | it describes the provider, not the model |
| 10 | `usage_level`, `advertised_context_window` | not ported | Ollama-Cloud-only and wholly unread |
| 11 | `estimate_cost` returns `nil` when prices are absent | returns `float` | only Ollama Cloud lacks prices |
| 12 | `1024` hardcoded in the builder **and** every backend | one `DEFAULT_MAX_OUTPUT_TOKENS`, resolved once | duplication; and 1024 truncates on `claude-opus-5` |
| 13 | `max_output_tokens` is a literal | a task setting, default **16000** | step 05 puts it on `Tasks::Base` anyway; ADR 0002 licenses running ahead |
| 14 | four Anthropic models, dated June 16 2026 | seven, incl. `claude-opus-5` / `claude-sonnet-5` / `claude-fable-5` | so a settings file naming a current model works without editing the library |
| 15 | `case provider` in the example, repeated in 7 files | `backend_for(task)` | one owner for provider→class |
| 16 | a second `case backend` mapping provider→env var | `API_KEY_ENV` on the backend class | one owner for provider→variable name |
| 17 | unknown provider raises bare `ArgumentError` | `UnsupportedProviderError(BoukenshaError)` | same failure kind as `UnsupportedModelError`; one catchable family |
| 18 | example prints only the payload | also prints `to_messages`, `to_tools`, url, redacted headers | gives the two dead methods a caller and shows the shapes the README describes in prose |

Rows 1, 6, 9, 10 and 11 are one decision seen from five angles;
[ADR 0006](../../../docs/adr/0006-port-ships-only-the-anthropic-backend.md) is the
single record. Rows 3 and 4 are one decision;
[ADR 0007](../../../docs/adr/0007-backend-holds-no-credentials.md) is the record.

## Out of scope

- **Any HTTP.** `Client`, retries, timeouts and `ApiError` are step 04. This step
  produces a payload, headers and a URL, and posts nothing.
- **`parse_response`.** Step 05 adds it to every backend; it is the next abstract
  method to join `Backend`.
- **Streaming, prompt caching, `thinking`, and `output_config.effort`.** The
  payload is the five-key shape the Ruby builds.
- **Porting the other four backends.** ADR 0006. Noted for whoever adds them:
  Gemini's `functionResponse.name` and Ollama's `tool_name` are both given
  `msg.tool_use_id`, but both APIs match a result to its call by **function
  name** — so the Ruby's `"toolu_01X"` would not match anything. Ollama and
  OllamaCloud also drop `max_output_tokens` entirely, so the limit is silently
  ignored there.
- **Reconciling step 12's `Models::TABLE`** with the backend model tables. It
  puts `claude-sonnet-4-6` at a 200,000-token context window where every backend
  table from step 03 onward says 1,000,000 — two tables, one model, different
  answers, and `Models::TABLE` is the one the agent uses for compaction
  thresholds. A step-12 problem, recorded here so the contradiction is not
  rediscovered.
