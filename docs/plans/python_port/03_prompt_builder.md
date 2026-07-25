# Plan — Port `week1_baseline/ruby/03_prompt_builder` to Python

**Target:** `week1_baseline/python/03_prompt_builder`
**Source of truth:** `week1_baseline/ruby/03_prompt_builder` (README + `prompt_builder.rb` + 6 backend files)
**Predecessor:** `docs/plans/python_port/02_the_registry`, ADR 0001–0005
**Status:** agreed via grilling session; ready to implement.

---

## 1. Goal

Add the **PromptBuilder** — the object that turns a `Context` plus a tool catalog
into the exact JSON payload an LLM API expects — and the **Backend** that owns
the provider-specific shape of that payload.

This is **not** a translation exercise. The Python tree is a deliverable that
gets significantly extended in week 2, so it is written as idiomatic Python and
is permitted to diverge from the Ruby where Python has a better answer. Every
divergence is deliberate and recorded (§8).

Step 03 makes two structural decisions the Ruby does not: **only the Anthropic
backend is ported** (§2.1, §3 decision 2), and **the backend holds no
credentials** (§2.6, §3 decision 15). Both get ADRs (§6.4, §6.5).

### Starting state — read this first

`week1_baseline/python/03_prompt_builder` **already exists** as an untracked
copy of `week1_baseline/python/02_the_registry`. This plan does not create the
tree from scratch; it adds to and modifies that copy. §4 marks every file
KEEP / NEW / EDIT / REWRITE.

**Confirm the starting state before writing anything:**

```bash
diff -rqx __pycache__ \
  week1_baseline/python/02_the_registry \
  week1_baseline/python/03_prompt_builder
```

This should report **no differences**. If it reports any, stop and reconcile
before proceeding — the plan's EDIT instructions assume a clean step-02 base.

`week1_baseline/bin/python/03_prompt_builder` **does not exist** and must be
created (§5.9). `bin/python/` currently holds only `00_config`,
`01_struct_skeleton`, and `02_the_registry`.

**Step 03 is additive over step 02** for everything except three edits that
reach into classes earlier steps own: `Registry.tool` gains `required=`,
`Tool` gains a `required` field, and `Task` gains `max_output_tokens`. Step 02's
tree is untouched and remains a valid frozen snapshot.

### Reference material

| Path | Role |
|---|---|
| `ruby/03_prompt_builder/lib/boukensha/prompt_builder.rb` | the 28 lines this step is named for |
| `ruby/03_prompt_builder/lib/boukensha/backends/base.rb` | model table machinery, cost accessors |
| `ruby/03_prompt_builder/lib/boukensha/backends/anthropic.rb` | the only backend we port |
| `ruby/03_prompt_builder/lib/boukensha/backends/{openai,gemini,ollama,ollama_cloud}.rb` | **not ported** — read for the contract, see §2.1 |
| `ruby/03_prompt_builder/examples/example.rb` | the behaviour the example must reproduce |
| `ruby/03_prompt_builder/README.md` | the spec — but see §2.2, §2.3, §2.5 |
| `ruby/03_prompt_builder/lib/boukensha/errors.rb` | adds `UnsupportedModelError` |
| `ruby/03_prompt_builder/lib/boukensha/config.rb` | adds `PROMPTS_DIR` — **already in our step 00** |
| `ruby/03_prompt_builder/lib/boukensha/tasks/*.rb` | listed as "New Files" — **already in our step 00** |
| `week1_baseline/python/02_the_registry/**` | the direct predecessor |
| `docs/adr/0001-python-port-parsed-dataclasses.md` | frozen-dataclass precedent |
| `docs/adr/0002-python-port-fixes-known-limitations.md` | fix-don't-carry precedent |
| `docs/adr/0004-registry-owns-the-tool-catalog.md` | why the builder takes tools separately |
| `CONTEXT.md` | glossary this step extends |

Forward references consulted during design:

| Path | What it told us |
|---|---|
| `ruby/04_api_client/lib/boukensha/client.rb` | `Client.new(builder)`, then `builder.url` / `builder.headers` / `builder.to_api_payload(max_output_tokens:)` — the only consumers of the builder in the whole ladder |
| `ruby/05_agent_loop/lib/boukensha/backends/anthropic.rb` | adds `parse_response`; adds the `tools.nil? ?` ternary our design never needs |
| `ruby/05_agent_loop/lib/boukensha/agent.rb` | `wrap_up` calls `@client.call(tools: [])` — the one caller wanting a narrowed tool set |
| `ruby/06_the_logger/lib/boukensha/logger.rb` | the only reader of `usage_unit`, `usage_level`, `estimate_cost` |
| `ruby/10_standard_tool_library/lib/boukensha/tools/{file_system,mud}.rb` | five tools with optional parameters — the evidence for §2.4 |
| `ruby/12_context/lib/boukensha/models.rb` | a second, contradictory model table (§2.7) |
| `ruby/12_context/lib/boukensha.rb` | `case backend` for the class **and** a second `case backend` for the env var — both duplicated across steps 07/09/10/11/12 |

---

## 2. Upstream findings, and what we do about them

### 2.1 The multi-backend step converges on one backend

Step 03's README opens with the case for provider independence and ships five
backends. The ladder does not sustain it:

- `12_context/lib/boukensha/models.rb` — the step-12 model table — contains
  **only three entries, all Claude** (`claude-opus-4-8`, `claude-sonnet-4-6`,
  `claude-haiku-4-5`).
- `12_context/lib/boukensha/backends/gemini.rb` has three of its five models
  commented out and the only live replacement commented out too.
- The repo's own `.boukensha/settings.yaml` fixture is `provider: anthropic`.

So the author ships five backends at step 03 and is effectively down to one by
step 12. This port ships **the Anthropic backend only**, and keeps the seam —
`backends/base.py` defines the contract, `backends/anthropic.py` is the single
implementation, and `backend_for()` rejects anything else by name. Adding
OpenAI in week 2 is one new file plus one registry row; nothing else moves.

The ABC is not speculative: five reference implementations exist to validate its
shape against, and they were read during design. ADR 0006 records this.

### 2.2 `PromptBuilder#to_messages` is dead **and** broken

```ruby
def to_messages
  @backend.to_messages(@context.messages)   # one argument
end
```

Anthropic and Gemini define `to_messages(messages)`. OpenAI, Ollama, and
OllamaCloud define `to_messages(system, messages)` — they prepend the system
message themselves. So `builder.to_messages` raises `ArgumentError` on three of
the five backends.

It is never caught, because **it is never called**. `grep`ing all twelve steps
finds zero callers of `PromptBuilder#to_messages` or `#to_tools`; `Client` uses
only `to_api_payload`, `headers`, and `url`. The bug is latent from step 03
through step 12 while sitting in the README's public API table.

The Anthropic-only cut dissolves the inconsistency — there is no second
signature to disagree with. We keep both methods public (decision 8) and give
them a caller: the example prints them, which is the clearest demonstration of
what this step actually does.

### 2.3 Every tool parameter is advertised as required

```ruby
input_schema: {
  type: "object",
  properties: tool.parameters,
  required: tool.parameters.keys.map(&:to_s)   # all of them, always
}
```

There is no way to declare an optional parameter. At step 03 this is harmless —
`look` has no parameters and `move` has one required one. At step 10 it is
actively wrong, and the tools contradict themselves:

```ruby
# 10_standard_tool_library/lib/boukensha/tools/mud.rb:137
parameters: {
  target:      { type: "string", description: "…Omit entirely to describe the current room." },
  preposition: { type: "string", description: "Preposition: in, at, north… (optional)" }
} do |target: nil, preposition: nil|
```

The description tells the model both arguments are optional; the schema tells
the API both are mandatory. The schema wins. The same defect affects
`file_system.rb`'s `list` (`path: "."`) and `grep` (`path: "."`, `glob: "*"`),
and `mud.rb`'s `attack` (`style: "kill"`), `say` (`mode: "say"`) and `msg`.

We fix it here, because this step owns schema serialization. `Registry.tool`
gains an explicit `required=` (decision 6); omitting it reproduces the Ruby's
behaviour exactly (decision 7), so this is purely additive.

**Rejected: deriving `required` from the handler signature** via
`inspect.signature` — a parameter with a default is optional. DRY, and every
Ruby call site already carries the information in its block signature. Rejected
because it is reflection: ~10 lines with edge cases (`**kwargs`, positional-only
parameters, a parameter declared in `parameters` but absent from the signature),
and its failure mode is a *silently wrong* `required`, which is the same class of
bug being fixed. `required` is a standard JSON Schema keyword; writing it is
less clever and more obvious.

### 2.4 `estimate_cost` returns `nil` only because of Ollama Cloud

`Backends::Base#estimate_cost` guards on missing prices:

```ruby
return nil unless input_token_cost_per_million && output_token_cost_per_million
```

The only models with `cost_per_million: { input: nil, output: nil }` are Ollama
Cloud's, whose pricing is plan-based rather than per-token. With Anthropic-only,
every price is known, so `estimate_cost` returns a plain `float` and the guard
disappears. Same for `usage_level`, which is Ollama-Cloud-only, and `usage_unit`,
which is `:tokens` for every Anthropic model — a property of the provider, not of
the model, so it becomes a class attribute (decision 5).

### 2.5 Dead and contradictory model metadata

- **`advertised_context_window`** on `minimax-m3:cloud` is set to `1_000_000`
  and read by nothing in twelve steps. Dead key.
- **Step 12 contradicts step 03.** `12_context/lib/boukensha/models.rb` puts
  `claude-sonnet-4-6` at a 200,000-token context window; every backend table
  from step 03 onward says `1_000_000`. Two tables, one model, different
  answers, and `Models::TABLE` is the one the agent actually uses for
  compaction thresholds. Evidence that the model table belongs on the backend
  that owns the models — which is where ours stays.

### 2.6 The step that sends nothing requires a credential

```ruby
Boukensha::Backends::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"), model: model)
```

`ENV.fetch` raises when unset, so the step-03 example cannot run without an
Anthropic account — for a step that makes **no network call**. The key is used
by exactly one member, `headers`; `to_messages`, `to_tools`, `to_api_payload`
and `url` never touch it.

Making it an optional constructor argument would fix runnability at the cost of a
partially-valid object — whether the backend works depends on which method you
call. Instead the credential leaves the backend entirely: `headers(api_key)`
takes it at the one call that needs it (decision 15). The backend is a
serializer, always fully constructed, and reads nothing from the environment.
ADR 0007 records this.

### 2.7 Provider→class and provider→env-var are duplicated seven times

The example's `case provider` reappears in steps 04, 05, and in
`lib/boukensha.rb` at steps 07, 09, 10, 11 and 12. Step 12 carries a **second**
case statement beside it mapping provider to environment variable. Both belong
to the seam: `backend_for()` owns provider→class, and `API_KEY_ENV` on the
backend class owns the variable name.

### 2.8 Prices are dated tutorial data

Step 03's README dates its prices to **June 16, 2026**. Checked against current
reference data, the Ruby's Anthropic table is **accurate** — `claude-sonnet-4-6`
at 1M/$3/$15, `claude-opus-4-8` at 1M/$5/$25, `claude-haiku-4-5` at 200K/$1/$5
all match. What it lacks is the models released since.

We extend it (decision 4) rather than correct it. The README date-stamps the
table and says plainly that it is static tutorial data. One entry proves the
point: `claude-sonnet-5`'s introductory rate expires **2026-08-31**, and a
static `cost_per_million` cannot express a price with an end date.

---

## 3. Decisions

Agreed one at a time in the grilling session.

| # | Decision | Choice |
|---|---|---|
| 1 | How the builder gets tools | `PromptBuilder(context, backend, *, tools: Mapping[str, Tool])` — the **catalog**, not the `Registry`. Live view, never copied |
| 2 | Backend scope | **Anthropic only**, seam kept: `base.py` ABC + `anthropic.py` + `backend_for()` |
| 3 | Backend class names | `Backend` / `AnthropicBackend` — avoids colliding with the SDK's `Anthropic` at step 04 |
| 4 | Model table contents | Ruby's four **plus** `claude-opus-5`, `claude-sonnet-5`, `claude-fable-5` |
| 5 | Model entry shape | frozen `ModelInfo(context_window, input_cost_per_million, output_cost_per_million)`; `USAGE_UNIT` a class attribute; `usage_level` dropped; `estimate_cost -> float` |
| 6 | Optional tool parameters | explicit `required=` on `Registry.tool`; `Tool.required` normalised to a tuple |
| 7 | Omitted `required=` | means **all** parameters required — Ruby-compatible; `required=[]` means none |
| 8 | Public surface | `to_messages`, `to_tools`, `to_api_payload`, `headers`, `url` — the Ruby's names |
| 9 | Backend construction | `backend_for(task)` — maps provider→class, passes the model, reads nothing |
| 10 | `max_output_tokens` | becomes a **task setting**, pulling step 05's `DEFAULT_MAX_OUTPUT_TOKENS` forward |
| 11 | Its default | **16000**, not the Ruby's 1024 |
| 12 | `provider` typing | stays a `str`; the factory rejects unknown values |
| 13 | Errors | `UnsupportedModelError` **and** `UnsupportedProviderError`, both under `BoukenshaError` |
| 14 | Credentials | **not on the backend**; `headers(api_key)` takes the key. `API_KEY_ENV` is a class attribute for step 04 |
| 15 | ADRs | **0006** (Anthropic-only) and **0007** (no credentials on the backend) |
| 16 | Tests | **none** — example-only, hand-verified, recorded in the ADRs |

Three calls made without a separate question, flagged and accepted:

- **`Backend` is a plain ABC.** `MODELS` is a declared `ClassVar`; there is no
  `__init_subclass__` enforcement. With one subclass the guard protects against
  a mistake nobody can currently make; it is a four-line additive change when
  the second backend lands.
- **Payloads are `dict[str, Any]`, not `TypedDict`.** They are JSON-bound and
  handed straight to `json.dumps`; a `TypedDict` would have to model unions the
  serializer already guarantees.
- **`url` is a property; `headers` is a method**, because it now takes an
  argument.

**Python floor stays 3.11+.** `StrEnum` (already used by `Role`) and `Self` both
require it; nothing in this step raises it further.

---

## 4. File tree

Everything below `week1_baseline/python/03_prompt_builder/` already exists as a
copy of `02_the_registry`. Marks are relative to that copy.

```
week1_baseline/python/03_prompt_builder/
  README.md                     REWRITE  step-03 README (§6.1)
  requirements.txt              KEEP     PyYAML, python-dotenv — nothing new
  prompts/system.md             KEEP     unchanged
  boukensha/
    __init__.py                 EDIT     export PromptBuilder, Backend, AnthropicBackend,
                                         backend_for, ModelInfo, and the two new errors
    config.py                   KEEP     byte-identical to steps 00–02
    _repr.py                    KEEP     byte-identical
    message.py                  KEEP     byte-identical — Role.TOOL_RESULT already exists
    context.py                  KEEP     byte-identical
    registry.py                 EDIT     `required=` on `tool()` (§5.5)
    tool.py                     EDIT     `required` field + validation (§5.4)
    errors.py                   EDIT     UnsupportedModelError, UnsupportedProviderError (§5.6)
    prompt_builder.py           NEW      PromptBuilder (§5.1)
    backends/
      __init__.py               NEW      backend_for + re-exports (§5.3)
      base.py                   NEW      Backend ABC, ModelInfo, UsageUnit (§5.2)
      anthropic.py              NEW      AnthropicBackend (§5.2)
    tasks/
      __init__.py               KEEP     empty
      base.py                   EDIT     max_output_tokens + DEFAULT (§5.7)
      player.py                 KEEP     byte-identical
  examples/example.py           REWRITE  step-03 example (§5.8)

Outside the step directory:
week1_baseline/bin/python/03_prompt_builder        NEW   launcher (§5.9)
CONTEXT.md                                          EDIT  4 new terms, 1 extended (§6.2)
docs/adr/0006-port-ships-only-the-anthropic-backend.md   NEW (§6.4)
docs/adr/0007-backend-holds-no-credentials.md            NEW (§6.5)
docs/plans/python_port/03_prompt_builder.md              NEW  this file
```

**Untouched:** everything under `week1_baseline/ruby/`, every earlier Python
step, `week1_baseline/bin/ruby/`, ADRs 0001–0005, and **the root `.boukensha/`
fixture** — `max_output_tokens` has a default, so the fixture needs no key and
the shared file stays as the Ruby tree left it.

---

## 5. Design

### 5.1 `boukensha/prompt_builder.py`

```python
class PromptBuilder:
    def __init__(
        self,
        context: Context,
        backend: Backend,
        *,
        tools: Mapping[str, Tool],
    ) -> None:
        self._context = context
        self._backend = backend
        self._tools = tools          # NOT copied — see below

    def to_messages(self) -> list[dict[str, Any]]: ...
    def to_tools(self) -> list[dict[str, Any]]: ...
    def to_api_payload(self, *, max_output_tokens: int | None = None) -> dict[str, Any]: ...
    def headers(self, api_key: str) -> Mapping[str, str]: ...

    @property
    def url(self) -> str: ...
```

- **Takes the catalog, not the `Registry`** (decision 1). The builder reads
  `tool.name`, `tool.description`, `tool.parameters` and `tool.required`; it
  never calls `dispatch` and never imports `Registry`. Narrower dependency,
  testable with a bare dict, and step 05's tools-disabled turn is
  `PromptBuilder(ctx, backend, tools={})` with no new parameter and no
  `tools.nil? ?` ternary — the wart ADR 0004 predicted we would avoid.
- **`tools` must not be copied.** `registry.tools` is a `MappingProxyType` over
  the live dict, so a builder constructed before registration still sees later
  tools. That matters for step 07's `RunDSL`, where registration happens inside
  a block. A defensive copy would silently freeze the catalog.
- **`max_output_tokens` resolution lives here, once:**

  ```python
  if max_output_tokens is None:
      task = self._context.task
      max_output_tokens = (
          DEFAULT_MAX_OUTPUT_TOKENS if task is None else task.max_output_tokens
      )
  ```

  `Context.task` is `Task | None`, hence the guard. The backend's `to_payload`
  takes `max_output_tokens` as a **required** keyword `int`, so the Ruby's
  duplicated `1024` literal (in the builder *and* every backend) becomes one
  constant with one resolution point. Step 04's `Client.call()` needs no
  argument; step 05's `wrap_up` keeps the per-call override.
- **`headers(api_key)` is a method**, forwarding to the backend (decision 14).

### 5.2 `boukensha/backends/base.py` and `anthropic.py`

```python
# base.py
DEFAULT_ANTHROPIC_VERSION = "2023-06-01"


class UsageUnit(StrEnum):
    TOKENS = "tokens"


@dataclass(frozen=True, slots=True)
class ModelInfo:
    context_window: int
    input_cost_per_million: float
    output_cost_per_million: float


class Backend(ABC):
    MODELS: ClassVar[Mapping[str, ModelInfo]]
    USAGE_UNIT: ClassVar[UsageUnit] = UsageUnit.TOKENS
    API_KEY_ENV: ClassVar[str | None] = None

    def __init__(self, *, model: str) -> None:
        self.model = self._validate_model(model)

    @classmethod
    def _validate_model(cls, model: str) -> str:
        if model not in cls.MODELS:
            supported = ", ".join(sorted(cls.MODELS))
            raise UnsupportedModelError(
                f"{cls.__name__} does not support model {model!r}. "
                f"Supported models: {supported}"
            )
        return model

    @property
    def model_info(self) -> ModelInfo: ...
    @property
    def context_window(self) -> int: ...
    @property
    def input_cost_per_million(self) -> float: ...
    @property
    def output_cost_per_million(self) -> float: ...

    def estimate_cost(self, *, input_tokens: int, output_tokens: int) -> float:
        return (
            input_tokens * self.input_cost_per_million
            + output_tokens * self.output_cost_per_million
        ) / 1_000_000

    @abstractmethod
    def to_messages(self, context: Context) -> list[dict[str, Any]]: ...
    @abstractmethod
    def to_tools(self, tools: Mapping[str, Tool]) -> list[dict[str, Any]]: ...
    @abstractmethod
    def to_payload(
        self, context: Context, tools: Mapping[str, Tool], *, max_output_tokens: int
    ) -> dict[str, Any]: ...
    @abstractmethod
    def headers(self, api_key: str) -> Mapping[str, str]: ...
    @property
    @abstractmethod
    def url(self) -> str: ...
```

- **`estimate_cost` returns `float`, never `None`** (§2.4). No guard.
- **`USAGE_UNIT` is a class attribute** — it describes the provider, which is
  why every Anthropic row in the Ruby repeats the same value. `usage_level` is
  not ported; it returns with Ollama Cloud.
- **`API_KEY_ENV`** is the only credential-adjacent thing on the class: the
  *name* of the variable, not its value. Step 04 reads it to know what to fetch.
- Ruby's `const_get(:MODELS)` metaprogramming becomes a declared `ClassVar`.
  A subclass that forgets it fails with `AttributeError` at construction rather
  than Ruby's `NotImplementedError`; see §3 for why there is no
  `__init_subclass__` guard.

```python
# anthropic.py
class AnthropicBackend(Backend):
    BASE_URL = "https://api.anthropic.com/v1/messages"
    API_KEY_ENV = "ANTHROPIC_API_KEY"
    MODELS = {
        "claude-opus-5":             ModelInfo(1_000_000,  5.0, 25.0),
        "claude-sonnet-5":           ModelInfo(1_000_000,  3.0, 15.0),
        "claude-fable-5":            ModelInfo(1_000_000, 10.0, 50.0),
        "claude-opus-4-8":           ModelInfo(1_000_000,  5.0, 25.0),
        "claude-sonnet-4-6":         ModelInfo(1_000_000,  3.0, 15.0),
        "claude-haiku-4-5":          ModelInfo(  200_000,  1.0,  5.0),
        "claude-haiku-4-5-20251001": ModelInfo(  200_000,  1.0,  5.0),
    }
```

Serialization, mirroring the Ruby exactly:

| Input | Output |
|---|---|
| `Role.TOOL_RESULT` message | `{"role": "user", "content": [{"type": "tool_result", "tool_use_id": …, "content": …}]}` |
| any other message | `{"role": role.value, "content": content}` |
| a tool | `{"name": …, "description": …, "input_schema": {"type": "object", "properties": …, "required": [...]}}` |
| the payload | `{"model", "system", "max_tokens", "tools", "messages"}` |
| headers | `Content-Type`, `x-api-key`, `anthropic-version` |

`required` comes from `tool.required` (§5.4), not from `list(tool.parameters)`.
`properties` passes `tool.parameters` straight through, which is why the
per-argument `description` restored at step 02 matters — it is the only thing
telling the model what an argument means.

**`claude-sonnet-5` is listed at its standard `3.0 / 15.0`, not its introductory
`2.0 / 10.0`.** The intro rate expires 2026-08-31 and a static table cannot
express an end date; the README says so (§2.8).

### 5.3 `boukensha/backends/__init__.py`

```python
_BACKENDS: Mapping[str, type[Backend]] = {"anthropic": AnthropicBackend}


def backend_for(task: Task) -> Backend:
    backend_cls = _BACKENDS.get(task.provider)
    if backend_cls is None:
        supported = ", ".join(sorted(_BACKENDS))
        raise UnsupportedProviderError(
            f"unsupported provider {task.provider!r} for task {task.name!r}. "
            f"Supported providers: {supported}"
        )
    return backend_cls(model=task.model)
```

- Reads nothing from the environment and takes no credential (decision 14).
- `Task` is imported under `TYPE_CHECKING` only, so `backends` does not depend on
  `tasks` at runtime and there is no cycle.
- This is where an unknown provider is caught (decision 12). `Task.provider`
  stays a `str`: the registry of valid providers *is* this dict, so the check
  belongs with the knowledge rather than in a one-member enum three lines
  earlier in the example.

### 5.4 `boukensha/tool.py` — the `required` field

```python
@dataclass(frozen=True, slots=True, repr=False)
class Tool:
    name: str
    description: str
    parameters: Mapping[str, Any]
    handler: Callable[..., Any]
    required: Sequence[str] | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "parameters", MappingProxyType(dict(self.parameters)))
        required = (
            tuple(self.parameters) if self.required is None else tuple(self.required)
        )
        unknown = [name for name in required if name not in self.parameters]
        if unknown:
            raise ValueError(
                f"tool {self.name!r} marks unknown parameter(s) required: "
                f"{', '.join(sorted(unknown))}"
            )
        object.__setattr__(self, "required", required)
```

- `None` and `[]` stay distinguishable: `None` means "unspecified → all",
  `[]` means "explicitly none" (decision 7).
- After `__post_init__`, `Tool.required` is always a `tuple[str, ...]` — the
  backend never sees the sentinel.
- The unknown-name check is a free win: a typo in `required=` is a startup
  `ValueError` instead of a schema the API rejects at runtime.
- `__repr__` is unchanged. It already shows `params=[…]`; adding `required` to
  it would push the line past useful width for no gain.

### 5.5 `boukensha/registry.py` — `required=`

```python
def tool(
    self,
    name: str,
    *,
    description: str,
    parameters: Mapping[str, Any] | None = None,
    required: Sequence[str] | None = None,
) -> Callable[[F], F]:
    def register(handler: F) -> F:
        if name in self._tools:
            raise ValueError(f"a tool named {name!r} is already registered")
        self._tools[name] = Tool(name, description, parameters or {}, handler, required)
        return handler

    return register
```

One new keyword, defaulting to `None`. Every existing call site in steps 02–04
is unchanged and keeps its previous behaviour exactly.

### 5.6 `boukensha/errors.py`

```python
class UnsupportedModelError(BoukenshaError):
    """A backend was asked for a model it does not support."""


class UnsupportedProviderError(BoukenshaError):
    """settings.yaml names a provider this build has no backend for."""
```

```
BoukenshaError
├── UnknownToolError            (step 02)
├── UnsupportedModelError       (new — Ruby has this)
└── UnsupportedProviderError    (new — Ruby raises a bare ArgumentError)
```

Both are the same kind of failure — *settings.yaml names something we do not
support* — so both live in one catchable family. Ruby's flat
`UnsupportedModelError < StandardError` plus an inline `ArgumentError` splits
them for no reason. `Task.from_settings` keeps raising plain `ValueError` for a
**missing** provider or model; absent and unknown are genuinely different
failures.

### 5.7 `boukensha/tasks/base.py` — `max_output_tokens`

```python
DEFAULT_MAX_OUTPUT_TOKENS = 16_000


@dataclass(frozen=True, slots=True)
class Task:
    ...
    max_output_tokens: int = DEFAULT_MAX_OUTPUT_TOKENS
```

`from_settings` reads `tasks.<name>.max_output_tokens`, coerces with `int()`,
and falls back to the default when absent — the same shape as `Mud.port`.

**Why 16000 and not the Ruby's 1024** (decision 11): 1024 predates the current
models. On `claude-opus-5` thinking is on by default and `max_tokens` caps
thinking *plus* response text together, so a 1024 ceiling truncates mid-answer
on a model we just added to the table. Anthropic's guidance for non-streaming
requests is roughly 16000. The fixture's `claude-haiku-4-5` survives 1024, so
this is about the models the table now offers, not the one it runs today.

**Why it moves to settings at all:** step 05's `Tasks::Base` gains
`DEFAULT_MAX_OUTPUT_TOKENS` and step 12's config gains
`agent_max_output_tokens`, so the ladder puts it here eventually. ADR 0002
already licenses the port running ahead. A task that wants a tight cap now sets
one instead of editing the library.

The root `.boukensha/settings.yaml` is **not** edited — the default applies, and
the shared fixture stays as the Ruby tree left it. The README documents the key.

### 5.8 `examples/example.py`

Mirrors the Ruby's behaviour — the same two tools, the same three messages, the
same `toolu_01X` tool-use id — with the composition order the port requires:

```python
config = Config.load()
player = Player.from_config(config)

ctx = Context(task=player, system=player.system_prompt)
registry = Registry()


@registry.tool("look", description="Look around the current room for details")
def look():
    return "A damp stone corridor stretches north. Torches flicker on the walls."


@registry.tool(
    "move",
    description="Move the player in a direction (north, south, east, west, up, down)",
    parameters={"direction": {"type": "string", "description": "The direction to move"}},
)
def move(direction):
    return f"You move {direction} into a torch-lit corridor."


ctx.add_message("user", "I just arrived in the dungeon. What's around me, and can you move north?")
ctx.add_message("assistant", "Let me take a look around first.")
ctx.add_message(
    "tool_result",
    "A damp stone corridor stretches north. Torches flicker on the walls.",
    tool_use_id="toolu_01X",
)

backend = backend_for(player)
builder = PromptBuilder(ctx, backend, tools=registry.tools)
```

It then prints, in order: the config, provider, model, context window, the URL,
the **redacted** headers, `to_messages()`, `to_tools()`, and
`json.dumps(builder.to_api_payload(), indent=2)`.

Three notes:

- **The example reads `ANTHROPIC_API_KEY`, not the library.** One explicit
  `os.environ.get(AnthropicBackend.API_KEY_ENV)` at the point of use, and the
  example runs fine when it is absent — nothing here calls the API.
- **Headers are printed with the key redacted** (`x-api-key: ***`). The header
  *shape* is part of what this step teaches; the Ruby example sidesteps it by
  not printing headers at all, which loses that. Redaction makes it safe to
  paste a real run into a README.
- **`to_messages()` and `to_tools()` are printed**, giving the two "dead"
  methods (§2.2) their first caller in the whole ladder and showing the two
  shapes the Ruby README describes in prose.

### 5.9 `week1_baseline/bin/python/03_prompt_builder`

Does not exist; create it as a copy of `bin/python/02_the_registry` with the one
path changed, and `chmod +x`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."

# Use the repo-root virtualenv when there is one, otherwise the system python3.
PY="$REPO_ROOT/.venv/bin/python"
[ -x "$PY" ] || PY="python3"

cd "$SCRIPT_DIR/../../python/03_prompt_builder"
exec "$PY" examples/example.py
```

---

## 6. Documentation to write

### 6.1 `week1_baseline/python/03_prompt_builder/README.md`

Follows the Ruby step-03 README's structure (intro → New Files → How It Works →
API tables → per-shape sections → Considerations → Run Example), plus:

- **Setup** — unchanged from steps 00–02; `requirements.txt` is untouched and
  everything new here is standard library.
- **Why only Anthropic** — the §2.1 finding in a short section, pointing at
  ADR 0006, and stating plainly what adding a backend costs (one file, one
  registry row).
- **`PromptBuilder` table** — `to_messages`, `to_tools`, `to_api_payload`,
  `headers(api_key)`, `url`.
- **`AnthropicBackend` table** — `MODELS`, `context_window`,
  `input_cost_per_million`, `output_cost_per_million`, `estimate_cost`,
  `API_KEY_ENV`.
- **The model table**, reproduced with its **date stamp** and an explicit note
  that it is static tutorial data — including `claude-sonnet-5`'s introductory
  rate expiring 2026-08-31 as the worked example of why (§2.8).
- **Credentials** — the backend holds none; `headers(api_key)`; this step runs
  with no key set. Point at ADR 0007.
- **Optional tool parameters** — `required=`, what omitting it means, and the
  step-10 defect it fixes (§2.3) with the `mud.rb` quote.
- **`max_output_tokens`** — now a task setting; why 16000; the `claude-opus-5`
  thinking-shares-the-budget reason.
- **Per-shape sections** — the Ruby's System Prompt / Tool Results / Tool
  Definitions / Message Roles sections, cut down to the Anthropic column only,
  with the multi-provider comparison dropped rather than half-kept.
- **Considerations** — the conversation is stateless and the full history is
  replayed every turn; tool results are `user` messages on Anthropic and this is
  counterintuitive but correct; the model only ever sees schemas, never handlers.
- **Expected output** — ***generated from an actual run, not hand-written.***
  Steps 00–02 all learned this, and the Ruby README of this step is wrong about
  its own output in two earlier steps.
- **Divergences** — the §8 table.
- **Run Example** — `./week1_baseline/bin/python/03_prompt_builder`.

### 6.2 `CONTEXT.md`

No existing term becomes wrong. Four added, one extended, in the existing
definition-list style:

| Term | Substance |
|---|---|
| **Backend** | The provider-specific half of an API call: it knows one provider's payload shape, its endpoint, its headers, and which models it supports. It serializes; it does not send. |
| **Payload** | The plain data structure a provider's API expects for one call — the serialized form of a context, a tool set, and the call's limits. |
| **Prompt builder** | The object that joins a context and a tool catalog to a backend and produces a payload. It is the seam where conversation, capability, and provider meet. |
| **Context window** | A model's total token ceiling for one call — a fact about the model, looked up, never configured. Distinct from the **max output tokens** a single response may use. |

**Extended — Parameters.** Currently ends "Becomes the provider's
`input_schema.properties`." Add that a tool separately declares which of its
parameters are **required**; the rest are optional, and a tool that says nothing
requires all of them.

### 6.3 Note for the writer

**Context window** earns its place because step 12 turns `Context` into literal
context-window accounting (`context_window`, `current_tokens`,
`compaction_threshold`). Defining it now, while it is only a number on a
`ModelInfo`, means step 12 extends a term rather than introducing one — and it
draws the line against *max output tokens*, which §2.5 shows the upstream author
conflated (step 12's README retracts `budget=8192` as exactly that mistake).

### 6.4 `docs/adr/0006-port-ships-only-the-anthropic-backend.md`

Same format as 0001–0005 (Status / Date / Applies to / Context / Decision /
Consequences / Verification).

- **Context** — reproduce §2.1 **in full, not by reference**: the step-12
  `Models::TABLE` containing only three Claude entries, the commented-out Gemini
  models at step 12, and the `provider: anthropic` fixture. Plans are working
  documents superseded by the next step's; this is the durable record of why the
  port has one backend where the source has five. Add the user-side reason
  plainly: four of the five providers will never be run here, so porting them
  ships four untested code paths.
- **Decision** — `backends/base.py` defines the contract, `anthropic.py` is the
  only implementation, `backend_for()` rejects everything else by name. The ABC
  is validated against five reference implementations that were read during
  design and then deliberately not ported.
- **Rejected: no abstraction at all.** One concrete class, no ABC, no factory —
  purest YAGNI. Rejected because the seam is ~30 lines and its absence would put
  provider→class knowledge in the example, where the Ruby demonstrably copies it
  into seven files (§2.7).
- **Rejected: Anthropic + OpenAI**, on the grounds that two implementations are
  what actually proves an abstraction. Genuinely tempting; rejected because the
  second backend would be unrunnable here and would reintroduce the
  `to_messages` signature split (§2.2) that Anthropic-only dissolves.
- **Consequences** — the `to_messages(system, messages)` inconsistency and its
  latent `ArgumentError` are not inherited; `estimate_cost` loses its `None`
  branch; `usage_level` is not ported; adding a backend in week 2 is additive.
- **Verification** — record the §9 hand-checks with their real output, as
  0002–0005 do.

### 6.5 `docs/adr/0007-backend-holds-no-credentials.md`

- **Context** — §2.6. The Ruby's `ENV.fetch("ANTHROPIC_API_KEY")` makes a step
  that sends nothing unrunnable without an account, and the key is used by
  exactly one of five members.
- **Decision** — the backend is a serializer. No `api_key` field, no environment
  access anywhere in the library, `headers(api_key)` takes the credential at the
  call that needs it. `API_KEY_ENV` remains as the *name* of the variable so
  step 04 knows what to read.
- **Rejected: optional `api_key` on the constructor**, with `headers` raising
  when it is absent. Runs keyless, but produces a partially-valid object —
  whether the backend works depends on which method you call, and the null
  surfaces far from where it was allowed in.
- **Rejected: `backend_for` reading `os.environ`.** Convenient and removes the
  duplication of §2.7's second case statement, but it is a hidden dependency on
  global mutable state: invisible at the call site and untestable without
  monkeypatching. This was the initially-agreed design and was reversed during
  the session; record that, and that ADR 0001's "`Config.load()` is the only
  thing that touches the filesystem" is the same principle one level out.
- **Consequences** — step 03 runs on a bare checkout with no Anthropic account;
  `headers` is a method rather than a property; step 04's `Client` becomes the
  thing that holds the credential, and reads `AnthropicBackend.API_KEY_ENV` to
  find it; tests need no environment fixture.

---

## 7. Implementation order

1. Confirm the starting state with the `diff -rqx __pycache__` in §1. Stop if it
   reports anything.
2. `boukensha/errors.py` — the two new classes.
3. `boukensha/tool.py` — the `required` field and its validation.
4. `boukensha/registry.py` — the `required=` keyword.
5. `boukensha/tasks/base.py` — `DEFAULT_MAX_OUTPUT_TOKENS` and the field.
6. `boukensha/backends/base.py` — `ModelInfo`, `UsageUnit`, `Backend`.
7. `boukensha/backends/anthropic.py` — `AnthropicBackend` and the model table.
8. `boukensha/backends/__init__.py` — `backend_for`.
9. `boukensha/prompt_builder.py`.
10. `boukensha/__init__.py` — exports.
11. `examples/example.py`.
12. Create `week1_baseline/bin/python/03_prompt_builder`; `chmod +x`.
13. Run it; **capture the real output**.
14. Run the §9 hand-checks; capture the real error messages.
15. `README.md`, using the captured output from 13–14.
16. `CONTEXT.md` — four new terms, **Parameters** extended.
17. ADR 0006, ADR 0007 — with the §9 output pasted into their Verification
    sections.
18. Final `diff -rqx __pycache__` against step 02 to confirm nothing outside
    §4's NEW / EDIT / REWRITE list drifted.

---

## 8. Divergences from the Ruby port

Steps 00–02's divergences all still apply. These are the rows step 03 adds.

| # | Ruby | This port | Why |
|---|---|---|---|
| 1 | five backends (Anthropic, OpenAI, Gemini, Ollama, OllamaCloud) | **Anthropic only**, seam kept | four would never be run here; the ladder itself converges on Claude by step 12 (§2.1); ADR 0006 |
| 2 | `PromptBuilder.new(context, backend)`, reaching `@context.tools` | `PromptBuilder(context, backend, *, tools=…)` | ADR 0004 moved the catalog to `Registry`; the builder takes the catalog, not the registry |
| 3 | `Backends::Anthropic.new(api_key:, model:)` | `AnthropicBackend(model=…)`; `headers(api_key)` | a serializer needs no credential; step 03 sends nothing (§2.6); ADR 0007 |
| 4 | `headers` is a no-arg method | `headers(api_key)` | follows from row 3 |
| 5 | class `Boukensha::Backends::Anthropic` | class `AnthropicBackend` | collides with the SDK's `Anthropic` at step 04 |
| 6 | `to_messages(messages)` / `to_messages(system, messages)` — inconsistent, and `ArgumentError` on 3 of 5 backends | one `to_messages(context)` | latent bug in all 12 Ruby steps (§2.2); one backend, one signature |
| 7 | `required: tool.parameters.keys` — every parameter mandatory | explicit `required=`, defaulting to all | step 10 declares optional parameters the schema contradicts (§2.3) |
| 8 | model table entries are nested hashes | frozen `ModelInfo` dataclass | ADR 0001; typed, typo-catching |
| 9 | `usage_unit` on every model row | `USAGE_UNIT` class attribute | it describes the provider, not the model |
| 10 | `usage_level`, `advertised_context_window` | not ported | Ollama-Cloud-only and wholly unread (§2.4, §2.5) |
| 11 | `estimate_cost` returns `nil` when prices are absent | returns `float` | only Ollama Cloud lacks prices (§2.4) |
| 12 | `1024` hardcoded in the builder **and** every backend | one `DEFAULT_MAX_OUTPUT_TOKENS`, resolved once | duplication; and 1024 truncates on `claude-opus-5` |
| 13 | `max_output_tokens` is a literal | a task setting, default **16000** | step 05 puts it on `Tasks::Base` anyway; ADR 0002 licenses running ahead |
| 14 | four Anthropic models, dated June 16 2026 | seven, incl. `claude-opus-5` / `claude-sonnet-5` / `claude-fable-5` | so a settings file naming a current model works without editing the library (§2.8) |
| 15 | `case provider` in the example, repeated in 7 files | `backend_for(task)` | §2.7 |
| 16 | a second `case backend` mapping provider→env var | `API_KEY_ENV` on the backend class | §2.7 |
| 17 | unknown provider raises bare `ArgumentError` | `UnsupportedProviderError(BoukenshaError)` | same failure kind as `UnsupportedModelError`; one catchable family |
| 18 | example prints only the payload | also prints `to_messages`, `to_tools`, url, redacted headers | gives §2.2's dead methods a caller and shows the shapes the README describes in prose |

Rows 1, 6, 9, 10 and 11 are one decision seen from five angles; ADR 0006 is the
single record. Rows 3 and 4 are one decision; ADR 0007 is the record.

---

## 9. Verification

`examples/example.py` is the entire safety net (decision 16).

```bash
./week1_baseline/bin/python/03_prompt_builder   # new
./week1_baseline/bin/ruby/03_prompt_builder     # Ruby, for comparison
```

Check by eye against the Ruby run:

- `model`, `system`, `max_tokens`, `tools`, `messages` — the same five payload
  keys, in the same order
- the three messages serialize identically, and the `tool_result` becomes a
  `user` message carrying a `tool_result` block with `tool_use_id: "toolu_01X"`
- `look` serializes with `"properties": {}, "required": []`, `move` with
  `"required": ["direction"]`
- **`max_tokens` differs**: 16000 here, 1024 in the Ruby (divergence row 13)
- the script exits 0

Then the hand-checks the example cannot show. Capture the real messages for the
ADRs and the README:

```python
# unknown model -> UnsupportedModelError, listing what is supported
AnthropicBackend(model="claude-opus-9")

# unknown provider -> UnsupportedProviderError, from the factory
backend_for(replace(player, provider="openai"))

# both are catchable as one family
isinstance(UnsupportedModelError("x"), BoukenshaError)      # -> True
isinstance(UnsupportedProviderError("x"), BoukenshaError)   # -> True

# required= omitted -> every parameter required (Ruby-compatible)
registry.tools["move"].required          # -> ('direction',)

# required=[] -> none required
registry.tools["look_at"].required       # -> ()

# a typo in required= is caught at registration, not by the API
@registry.tool("bad", description="…", parameters={"a": {}}, required=["b"])
def bad(a=None): ...
# -> ValueError: tool 'bad' marks unknown parameter(s) required: b

# the catalog is a live view, not a snapshot
builder = PromptBuilder(ctx, backend, tools=registry.tools)
len(builder.to_tools())                  # -> 2
@registry.tool("flee", description="…")
def flee(): ...
len(builder.to_tools())                  # -> 3, without rebuilding the builder

# no credential is needed to serialize
builder.to_api_payload()                 # works with ANTHROPIC_API_KEY unset
builder.url                              # works
builder.headers("sk-ant-test")["x-api-key"]   # -> 'sk-ant-test'

# max_output_tokens comes from the task, and is overridable per call
builder.to_api_payload()["max_tokens"]                        # -> 16000
builder.to_api_payload(max_output_tokens=512)["max_tokens"]   # -> 512

# cost estimation is a float, never None
backend.estimate_cost(input_tokens=1_000_000, output_tokens=1_000_000)
```

And the two environment checks:

```bash
# the step runs with no credential — it sends nothing
env -u ANTHROPIC_API_KEY ./week1_baseline/bin/python/03_prompt_builder

# the step is still self-contained, the check ADR 0002 established
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/03_prompt_builder
# expect: ValueError "tasks.player is missing from settings.yaml" — the step-00
# behaviour, unchanged
```

---

## 10. Out of scope

- **Porting the OpenAI, Gemini, Ollama and OllamaCloud backends.** ADR 0006.
  Recorded for whoever adds them: Gemini's `functionResponse.name` and Ollama's
  `tool_name` are both given `msg.tool_use_id`, but both APIs match a result to
  its call by **function name** — so the Ruby's `"toolu_01X"` would not match
  anything. Ollama and OllamaCloud also drop `max_output_tokens` entirely (no
  `options.num_predict`), so the limit is silently ignored on those providers.
- **`parse_response`.** Step 05 adds it to every backend; it is the next
  abstract method to join `Backend`.
- **Any HTTP.** `Client`, retries, timeouts and `ApiError` are step 04. This step
  produces a payload, headers and a URL, and posts nothing.
- **The `tools.nil? ?` ternary.** It is never written here, by construction —
  `to_payload` takes tools explicitly and a narrowed turn passes `tools={}`.
- **Streaming, prompt caching, `thinking`, `output_config.effort`, and task
  budgets.** The payload is the five-key shape the Ruby builds. Anything richer
  is a later step's decision, and the model table is the place it would land.
- **Reconciling step 12's `Models::TABLE`** with the backend model tables
  (§2.5). It is a step-12 problem; recorded here so the contradiction is not
  rediscovered.
- **Editing the root `.boukensha/` fixture.** `max_output_tokens` has a default
  and the fixture is shared with the Ruby tree.
- **A test suite, `pytest`, or any test-running convention** (decision 16).
- **Deriving `required` from the handler signature.** Rejected with reasons in
  §2.3; recorded so the idea is not relitigated.
- **Modifying any earlier step's tree.** `Registry`, `Tool` and `Task` change in
  *this* step's copy only; `week1_baseline/python/02_the_registry` stays frozen.
