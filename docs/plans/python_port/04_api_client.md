# Plan — Port `week1_baseline/ruby/04_api_client` to Python

**Target:** `week1_baseline/python/04_api_client`
**Source of truth:** `week1_baseline/ruby/04_api_client` (README + `client.rb` + `examples/example.rb`)
**Predecessor:** `docs/plans/python_port/03_prompt_builder.md`, ADR 0001–0007
**Status:** agreed via grilling session; ready to implement.

---

## 1. Goal

Add the **Client** — the object that takes the payload `PromptBuilder` assembles,
POSTs it, and returns the parsed response. One HTTP request, one response. No
tool loop; that is step 05.

Step 03 produced a payload, a URL, and a set of headers and posted nothing. Step
04 is where the seam those three members form gets its first caller, and where
the ladder first spends money.

Like step 03 this is **not** a translation exercise. The Python tree is a
deliverable that gets extended in week 2, so it is written as idiomatic Python
and is permitted to diverge from the Ruby where Python has a better answer.
Every divergence is deliberate and recorded (§8).

Step 04 makes three structural decisions the Ruby does not: **the `Client`
transports payloads rather than wrapping a `PromptBuilder`** (§2.6, decision 3),
**timeouts are not retried** (§2.3, decision 5), and **`Config` remains the only
reader of the environment** (§2.5, decision 2). The first two get ADRs (§6.4,
§6.5).

### Starting state — read this first

`week1_baseline/python/04_api_client` **already exists** as an untracked copy of
`week1_baseline/python/03_prompt_builder`. This plan does not create the tree
from scratch; it adds to and modifies that copy. §4 marks every file
KEEP / NEW / EDIT / REWRITE.

**Confirm the starting state before writing anything:**

```bash
diff -rqx __pycache__ \
  week1_baseline/python/03_prompt_builder \
  week1_baseline/python/04_api_client
```

This should report **no differences**. Verified clean at the time of writing. If
it reports any, stop and reconcile — the EDIT instructions assume a clean
step-03 base.

**`week1_baseline/bin/python/04_api_client` already exists** and already points
at this step's directory. Unlike step 03, there is nothing to create and nothing
to `chmod`. Verified.

**Step 04 is additive over step 03** for everything except two edits that reach
into classes earlier steps own: `Config` gains `require_secret()`, and
`AnthropicBackend`'s module docstring loses a claim it can never fulfil. Step
03's tree is untouched and remains a valid frozen snapshot.

Note that `config.py` **stops being byte-identical across steps 00–04**. The
step-03 plan marked it KEEP at every rung; step 04 breaks that streak. The
change is purely additive (one new method), so every earlier step's tree stays
valid, but it is a first and §4 calls it out.

### Reference material

| Path | Role |
|---|---|
| `ruby/04_api_client/lib/boukensha/client.rb` | the 78 lines this step is named for |
| `ruby/04_api_client/examples/example.rb` | the behaviour the example must reproduce |
| `ruby/04_api_client/README.md` | the spec — but see §2.8, §2.9 |
| `ruby/04_api_client/lib/boukensha/errors.rb` | adds `ApiError` |
| `week1_baseline/python/03_prompt_builder/**` | the direct predecessor |
| `docs/adr/0002-python-port-fixes-known-limitations.md` | fix-don't-carry precedent |
| `docs/adr/0006-port-ships-only-the-anthropic-backend.md` | why there is one backend to POST to |
| `docs/adr/0007-backend-holds-no-credentials.md` | why the key arrives at the call site |
| `CONTEXT.md` | glossary this step extends |

Forward references consulted during design:

| Path | What it told us |
|---|---|
| `ruby/05_agent_loop/lib/boukensha/agent.rb:16-25` | `Agent` takes **both** `builder:` and `client:` — the client's builder is redundant |
| `ruby/05_agent_loop/lib/boukensha/agent.rb:79` | `wrap_up` calls `@client.call(tools: [], max_output_tokens: 400)` — the only tools-narrowed call in the ladder |
| `ruby/05_agent_loop/lib/boukensha/agent.rb:96` | `add_message(:assistant, content)` where `content` is a **list of blocks** — our `Message.content: str` must widen at step 05 |
| `ruby/05_agent_loop/lib/boukensha/client.rb` | the *only* change from step 04 is `call(max_output_tokens:, tools: nil)` |
| `ruby/06_the_logger/lib/boukensha/client.rb` | byte-identical to step 05's. `Client` never changes again through step 12 |
| `ruby/06_the_logger/lib/boukensha/logger.rb` | the only reader of `usage_unit`, `estimate_cost` |
| `ruby/10_standard_tool_library/lib/boukensha/tools/file_system.rb` | where `read_file` / `list_directory` properly belong (§2.8) |

---

## 2. Upstream findings, and what we do about them

### 2.1 The retry list omits the one status that matters most

```ruby
RETRYABLE_STATUS_CODES = [408, 409, 429, 500, 502, 503, 504].freeze
```

Anthropic's documented retryable set is 408, 409, 429, and **≥ 500** — which
includes **529 `overloaded_error`**, the status returned when the API is at
capacity. It is the single most likely retryable failure in normal operation,
and Ruby's enumerated list treats it as fatal.

An enumerated list is also the wrong shape: it rots the moment a new 5xx
appears. We use a rule instead — `status in {408, 409, 429} or status >= 500` —
which covers 529 without naming it and needs no maintenance.

### 2.2 `retry-after` is ignored

```ruby
def retry_delay(attempt)
  BASE_RETRY_DELAY * (2**(attempt - 1))
end
```

0.5s, 1s, 2s — regardless of what the server asked for. On a 429 the API sends a
`retry-after` header in seconds. If it says 30, the Ruby retries three times
inside 3.5 seconds and then fails, having achieved nothing except three more
rejected requests.

We honour the header when present, clamped to `MAX_RETRY_DELAY` so a
pathological value can't wedge the process, and fall back to exponential backoff
when it's absent or unparseable.

### 2.3 No timeouts — which our own step-03 default turns into a billing bug

```ruby
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = uri.scheme == "https"
http.verify_mode = OpenSSL::SSL::VERIFY_PEER
```

No `open_timeout`, no `read_timeout`. `Net::HTTP` therefore inherits its 60s
default read timeout.

This is survivable in the Ruby only because `call(max_output_tokens: 1024)` caps
generation short enough to usually finish inside a minute. Our
`DEFAULT_MAX_OUTPUT_TOKENS` is **16000** (step-03 decision 11), so a long
generation will routinely exceed 60s. And `Net::ReadTimeout` is in
`TRANSIENT_ERRORS`, so the Ruby's response is to **retry** — re-running a
generation the server may already have completed and billed. Worst case for one
logical call is four billed generations, silently.

Two fixes, and they are separate:

- **An explicit timeout.** `DEFAULT_TIMEOUT = 600.0` — the same ten minutes the
  vendor SDKs default to, so the number is citable rather than invented, and it
  comfortably clears a 16000-token generation.
- **Timeouts are not retryable.** `urllib.request.urlopen(req, timeout=N)`
  applies a **single socket timeout** to both connect and read; urllib exposes
  no separate knobs, and because a non-streaming Messages call withholds the
  response until generation completes, a connect-phase timeout and a
  generation-phase timeout are not reliably distinguishable. So the choice is
  all-or-nothing, and at a 600s ceiling a timeout genuinely means the server
  held the request for ten minutes. The rule states cleanly: **retry only when
  we know the server didn't do the work.**

This is narrower than it sounds. Network blips do not surface as timeouts at a
600s ceiling — they surface as `ConnectionResetError`, `ConnectionRefusedError`,
or `socket.gaierror`, all of which stay retryable.

### 2.4 Certificate failures are retried four times

```ruby
TRANSIENT_ERRORS = [..., OpenSSL::SSL::SSLError, ...].freeze
```

A certificate verification failure will never succeed on retry. The Ruby retries
it three times with backoff before giving up — and then the README spends a
whole section telling you to fix your machine:

> **OpenSSL Certificate** … Net HTTP has rough edges like supplying the correct
> SSL certificate from your machine. … You will need to update the code based on
> your machines requirements.
> `ruby -e "require 'openssl'; puts OpenSSL::X509::DEFAULT_CERT_FILE"`

The code carries a commented-out `http.ca_file =` line and a note explaining
that the macOS-correct value breaks on Linux/WSL2 (`client.rb:30-33`).

**All of this evaporates in Python.** `urllib.request.urlopen` uses
`ssl.create_default_context()`, which loads the system trust store on every
supported platform without configuration. There is no `ca_file` line to write,
no platform note, and no README section. We record it as a divergence and move
on.

We also invert the classification: rather than a blocklist of transient errors,
we use an **allowlist** — only `ConnectionError` and `socket.gaierror` are
retryable. Everything else, certificate failures included, raises immediately.
An allowlist cannot accidentally admit a permanent failure.

### 2.5 `ApiError` is a string, and the request id is discarded

```ruby
class ApiError < StandardError; end
...
raise ApiError, "API request failed after #{attempts} attempt#{...} (#{response.code}): #{response.body}"
```

Everything is fused into one message. A caller wanting the status code back has
to parse prose. The raw JSON body is dumped in verbatim, so the useful sentence
inside it — `error.message` — is buried in punctuation.

Two things are dropped that cost nothing to keep:

- **`request-id`.** Every Anthropic response carries one
  (`req_011CSHoEeqs5C35K2UUqR7Fy`); it is the identifier Anthropic support asks
  for, and on a failure it is already sitting in `HTTPError.headers`.
- **`error.type`.** The error body is structured JSON —
  `{"error": {"type": "rate_limit_error", "message": "…"}}` — so the failure
  kind is machine-readable rather than something to regex out of a sentence.

`ApiError` becomes one class (step 05's `except ApiError` still catches
everything) carrying `status_code`, `error_type`, `request_id`, `attempts`, and
the raw `body`, with a `__str__` that composes the human sentence from the
parsed body and falls back to the raw text when it isn't JSON.

### 2.6 `Client` wraps the builder its only caller already holds

```ruby
Boukensha::Client.new(builder)
```

But step 05's `Agent` is constructed as:

```ruby
def initialize(context:, registry:, builder:, client:, ...)   # agent.rb:16-17
```

It holds **both**, and uses the builder directly for `@builder.parse_response`
(`agent.rb:38`). So the client's reference to the builder is redundant coupling —
the only caller that matters has one in hand already.

That redundancy has a cost, and it lands at step 05. `wrap_up` calls
`@client.call(tools: [], max_output_tokens: WRAP_UP_OUTPUT_TOKENS)`
(`agent.rb:79`). Under `Client(builder)`, a tools-narrowed call has to plumb
`tools=` down through `Client.call` → `to_api_payload` → `to_payload` —
reintroducing exactly the `tools.nil? ?` ternary the step-03 plan claimed we had
avoided by construction, and giving `max_output_tokens` a **second** resolution
point, undoing "one constant with one resolution point" from §5.1 of that plan.

So the `Client` takes the **backend** and a **payload**:

```python
Client(backend, *, api_key, timeout=DEFAULT_TIMEOUT).call(payload) -> dict
```

It never sees a `Context`, a `Registry`, or a tool. One dict in, one dict out.
It hides SSL, retries, backoff, `retry-after`, timeouts, JSON encode/decode, and
error wrapping — a narrow interface over real complexity. Step 05's `wrap_up`
becomes a second `PromptBuilder(ctx, backend, tools={})`, which is what the
step-03 plan promised: no ternary, no per-call override, no second `Client`.

ADR 0009 records this.

### 2.7 Step 03's example context cannot be sent

`03_prompt_builder/examples/example.rb:30-32` (and our Python port of it) builds:

```python
ctx.add_message("user", "I just arrived in the dungeon. What's around me, …")
ctx.add_message("assistant", "Let me take a look around first.")     # plain text, no tool_use
ctx.add_message("tool_result", "…", tool_use_id="toolu_01X")         # references nothing
```

Every `tool_result` must reference a `tool_use` block in the immediately
preceding assistant turn. `toolu_01X` was never emitted. Posting step 03's exact
`to_api_payload()` output returns:

```
HTTP 400   request-id: req_011CdPt61tRdqQSWdD6Nj475
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "messages.2.content.0: unexpected `tool_use_id` found in `tool_result` blocks: toolu_01X. Each `tool_result` block must have a corresponding `tool_use` block in the previous message."
  }
}
```

The backend is not at fault — `backends/anthropic.py`'s `to_messages` serializes
the `tool_result` correctly. The fixture data is invalid. It is latent in the
Ruby too, and invisible in step 03 because that step never posts.

**Step 04 is the step that exposes it**, so the message sequence has to change.
Ruby's switch to a single user message was forced, not stylistic. Our example
does the same (§5.6), keeping step 03's tools.

### 2.8 The step-04 example contradicts its own system prompt

Ruby's step-04 example swaps to `read_file` / `list_directory` and asks *"What
files are in the current directory?"* — while the system prompt actually in
force is the MUD one. The repo fixture sets `prompt_override.system: true`, so
the prompt comes from `.boukensha/prompts/player/system.md`:

> You are a MUD Journey Player Agent. You are playing the MUD on behalf of the
> player, and the player will issue you goals to complete. Use the tools
> available to you to help the player explore, fight, and interact with the
> world.

A MUD player agent handed filesystem tools. It *works* — verified, see §9.1 —
but it reads oddly, and the handlers are unreachable at this step since step 04
never dispatches. Filesystem tools arrive properly at step 10
(`10_standard_tool_library/lib/boukensha/tools/file_system.rb`).

We keep step 03's `look` / `move`, which match the prompt. Divergence row 14.

### 2.9 The README's captured output is stale

Ruby's step-04 README shows the model replying:

> "I don't have a function available to list directory contents. I can only read
> files if you provide me with the specific file path."

That run predates `list_directory`, which the current `example.rb` registers.
With both tools present the model calls `list_directory` without hesitation
(§9.1). The README also mislabels the command as
`ruby 03_api_client/examples/step3.rb` while the banner says *Step 4*.

The step-03 plan already noted that the Ruby READMEs are wrong about their own
output in two earlier steps. This is a third. Our README's expected output is
**generated from a real run**, and says so.

### 2.10 No vendor SDK — an external constraint, not a preference

The course explicitly forbids using a vendor SDK. This is not a design trade-off
we reasoned our way to; it is a constraint on the exercise.

Recording it as a constraint matters because the reasoning that *would* justify
it ("keeps the Backend seam load-bearing", "matches the Ruby's pedagogy") is
weaker than the constraint itself, and week 2 will make the SDK look tempting —
it ships retries, timeouts, request-id capture, typed exceptions, and a
streaming guard, all of which we are hand-rolling here. ADR 0008 leads with the
constraint so the question is closed rather than re-argued.

One consequence is immediate. `backends/anthropic.py` currently opens:

> Named `AnthropicBackend`, not `Anthropic`, because step 04 imports the SDK's
> `Anthropic` client into the same namespace.

That will never happen. The name is still right — it is a backend, not a vendor,
and a bare `Anthropic` invites exactly the confusion the constraint forbids —
but the stated reason has to go.

---

## 3. Decisions

Agreed one at a time in the grilling session.

| # | Decision | Choice |
|---|---|---|
| 1 | Transport | **stdlib `urllib.request` + `json`.** No vendor SDK — external course constraint (§2.10) |
| 2 | Credential | `Config.require_secret(name)`; `config.py` remains the only env reader; `Client(…, api_key=…)` required |
| 3 | Client shape | `Client(backend, *, api_key, timeout)` + `call(payload) -> dict`. Never sees a Context, Registry, or tool |
| 4 | Retryable statuses | `status in {408, 409, 429} or status >= 500` — a rule, not a list; covers 529 (§2.1) |
| 5 | Retryable errors | allowlist: `ConnectionError`, `socket.gaierror`. **Timeouts and certificate failures are not retryable** (§2.3, §2.4) |
| 6 | Backoff | `retry-after` honoured when present (clamped); otherwise exponential with **equal jitter** |
| 7 | Attempt count | `MAX_RETRIES = 3` → 4 attempts total. Ruby parity |
| 8 | Timeout | `DEFAULT_TIMEOUT = 600.0`, single socket timeout, constructor-overridable |
| 9 | `ApiError` | one class under `BoukenshaError` with `status_code` / `error_type` / `request_id` / `attempts` / `body` |
| 10 | Missing secret | plain `ValueError` — absent config is `ValueError`, unknown config is a `BoukenshaError` subclass (step-03 §5.6) |
| 11 | Return type | the parsed body as `dict`; headers discarded. `parse_response` stays step 05 |
| 12 | `max_output_tokens` | library default stays **16000**; the *example* passes `1024` explicitly, where Ruby's own default lives |
| 13 | Example spend | prints `usage` and `estimate_cost` — the latter's first caller in the whole ladder |
| 14 | Example fixture | keep `look` / `move`; collapse to one user turn (§2.7, §2.8) |
| 15 | ADRs | **0008** (no vendor SDKs) and **0009** (client transports payloads); **0007** amended |
| 16 | Tests | **none shipped.** Retry branches hand-verified against a throwaway stub; nothing committed (§9.2) |

Three calls made without a separate question, flagged and accepted:

- **The retry loop is inline in `Client`, not a `RetryPolicy` object.** Four
  module constants and two private helpers. A policy object would be a seam no
  caller has asked for.
- **`call()` does not validate the payload.** The backend built it; re-checking
  it here would duplicate knowledge that already lives in one place.
- **Success-path headers are discarded.** `request-id` survives only on the
  error path, where it is actionable. Nothing needs it on success until step
  06's logger, which reads `usage` from the body.

**Python floor stays 3.11+.** Nothing in this step raises it. Note `TimeoutError`
is the `socket.timeout` alias from 3.10 onward, which the error classification
relies on.

---

## 4. File tree

Everything below `week1_baseline/python/04_api_client/` already exists as a copy
of `03_prompt_builder`. Marks are relative to that copy.

```
week1_baseline/python/04_api_client/
  README.md                     REWRITE  step-04 README (§6.1)
  requirements.txt              KEEP     PyYAML, python-dotenv — nothing new, and
                                         nothing test-shaped (§9.4)
  prompts/system.md             KEEP     unchanged — and unused, see note below
  boukensha/
    __init__.py                 EDIT     export Client, ApiError (§5.4)
    config.py                   EDIT     + require_secret() (§5.3)  ← first change since step 00
    _repr.py                    KEEP     byte-identical
    message.py                  KEEP     byte-identical
    context.py                  KEEP     byte-identical
    registry.py                 KEEP     byte-identical
    tool.py                     KEEP     byte-identical
    errors.py                   EDIT     + ApiError (§5.2)
    prompt_builder.py           KEEP     byte-identical
    client.py                   NEW      the step (§5.1)
    backends/
      __init__.py               KEEP     byte-identical
      base.py                   KEEP     byte-identical
      anthropic.py              EDIT     module docstring only (§5.5)
    tasks/
      __init__.py               KEEP     empty
      base.py                   KEEP     byte-identical
      player.py                 KEEP     byte-identical
  examples/example.py           REWRITE  step-04 example (§5.6)

Outside the step directory:
week1_baseline/bin/python/04_api_client                KEEP  already exists, already correct
CONTEXT.md                                             EDIT  2 new terms (§6.2)
docs/adr/0007-backend-holds-no-credentials.md          EDIT  Consequences, one line (§6.3)
docs/adr/0008-no-vendor-sdks.md                        NEW   (§6.4)
docs/adr/0009-client-transports-payloads.md            NEW   (§6.5)
docs/plans/python_port/04_api_client.md                NEW   this file
```

**Untouched:** everything under `week1_baseline/ruby/`, every earlier Python
step, `week1_baseline/bin/ruby/`, ADRs 0001–0006, and **the root `.boukensha/`
fixture** — no new settings key is introduced, so the file shared with the Ruby
tree stays exactly as that tree left it.

**On `prompts/system.md`:** it is KEEP but it is also dead. The fixture sets
`prompt_override.system: true`, so `Task._read_prompt` resolves to
`.boukensha/prompts/player/system.md` and the step's shipped prompt is never
read. That was already true at step 03; it becomes visible at step 04 because
the prompt now reaches a model. The README notes it; the file stays so the step
remains self-contained when run against a config dir with no override.

---

## 5. Design

### 5.1 `boukensha/client.py`

```python
DEFAULT_TIMEOUT  = 600.0
MAX_RETRIES      = 3        # → 4 attempts, matching Ruby
BASE_RETRY_DELAY = 0.5
MAX_RETRY_DELAY  = 60.0

RETRYABLE_STATUSES = frozenset({408, 409, 429})
RETRYABLE_ERRORS   = (ConnectionError, socket.gaierror)


class Client:
    def __init__(
        self,
        backend: Backend,
        *,
        api_key: str,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> None: ...

    def call(self, payload: Mapping[str, Any]) -> dict[str, Any]: ...
```

**Shape.** Takes the backend for `url` and `headers(api_key)` and nothing else.
`call` takes a fully-built payload and returns the parsed body. See §2.6 and
ADR 0009.

**The credential is required.** `Client` reads no environment (ADR 0007). An
empty or missing `api_key` raises `ValueError` at construction, so a
misconfiguration fails at wiring time rather than as a 401 mid-run.

**Retry classification** — two private helpers, both pure functions of their
arguments:

```python
def _retryable_status(status: int) -> bool:
    return status in RETRYABLE_STATUSES or status >= 500
```

A rule rather than an enumeration: it covers 529 without naming it and does not
rot when a new 5xx appears (§2.1).

```python
def _retryable_error(reason: BaseException | None) -> bool:
    return isinstance(reason, RETRYABLE_ERRORS)
```

An **allowlist**. `TimeoutError` is deliberately absent — the server may have
generated and billed the response (§2.3). `ssl.SSLCertVerificationError` is
absent because a certificate failure never succeeds on retry (§2.4). Both
exclusions need a code comment naming the reason, or the next reader will
"fix" them.

**Backoff:**

```python
def _delay(self, attempt: int, retry_after: str | None) -> float:
    if retry_after is not None:
        try:
            return min(float(int(retry_after)), MAX_RETRY_DELAY)
        except ValueError:
            pass                       # HTTP-date form; fall through
    delay = min(BASE_RETRY_DELAY * 2 ** (attempt - 1), MAX_RETRY_DELAY)
    return delay / 2 + random.uniform(0, delay / 2)      # equal jitter
```

- A present `retry-after` is used **as-is**, clamped. No jitter is added: if the
  server asks for 30 seconds, 30 seconds is a floor, not a suggestion.
- Only the computed fallback gets jitter.
- `retry-after` may legally be an HTTP-date. Anthropic sends seconds; the date
  form falls through to backoff rather than adding a parser for a shape we will
  not receive.
- `MAX_RETRY_DELAY` stops a pathological header value from wedging the process.

**Exception ordering matters.** `urllib.error.HTTPError` subclasses
`URLError`, which subclasses `OSError`; `TimeoutError`, `ConnectionError`, and
`socket.gaierror` are all `OSError` too. So:

```python
try:
    with urllib.request.urlopen(request, timeout=self._timeout) as response:
        return self._decode(response.read(), attempt)
except urllib.error.HTTPError as e:        # MUST precede OSError
    ...
except OSError as e:                       # URLError, Timeout, Connection, gaierror, ssl
    reason = e.reason if isinstance(e, urllib.error.URLError) else e
    ...
```

Getting this order wrong swallows every HTTP status into the connection branch.

**The loop** runs `attempt` from 1 to `MAX_RETRIES + 1`. A retryable outcome on
attempts 1–3 sleeps and continues; attempt 4 raises. Non-retryable outcomes
raise immediately, at whatever attempt they occur.

**Body decoding.** `json.loads` on the success path too — a 2xx that isn't JSON
is an `ApiError`, not a `JSONDecodeError` escaping from the client.

### 5.2 `boukensha/errors.py`

```python
class ApiError(BoukenshaError):
    """A request to a provider's API failed."""

    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        error_type: str | None = None,
        request_id: str | None = None,
        attempts: int = 1,
        body: str | None = None,
    ) -> None: ...
```

```
BoukenshaError
├── UnknownToolError            (step 02)
├── UnsupportedModelError       (step 03)
├── UnsupportedProviderError    (step 03)
└── ApiError                    (new — Ruby has this, flat under StandardError)
```

One class, not a hierarchy. Step 05's `except ApiError` catches everything, and
no caller in twelve steps needs to distinguish "rejected" from "never arrived" —
the `status_code` field being `None` already says which happened.

`__str__` composes:

```
API request failed after 4 attempts (429 rate_limit_error):
Number of request tokens has exceeded your rate limit
[request-id: req_011CSHoEeqs5C35K2UUqR7Fy]
```

`error_type` and the human sentence come from parsing the JSON body; when the
body isn't JSON, both are `None` and the raw text is used. The parse must be
defensive — an error path that raises while constructing its own error message
is worse than the failure it was reporting.

### 5.3 `boukensha/config.py` — `require_secret`

```python
def require_secret(self, name: str) -> str:
    """The value of an environment variable that must be present.

    `Config.load()` has already run `load_dotenv()` on the config dir, so this
    reads through to whatever `.env` supplied. Keeping the read here rather than
    at the call site means the class that loaded the file is the class that
    hands back its values — and the error can name the file.
    """
    value = os.environ.get(name)
    if not value:
        raise ValueError(
            f"{name} is not set. Add it to {self.dir / '.env'} or export it."
        )
    return value
```

**Why this exists.** The obvious alternative is for the example to read
`os.environ` itself. That works, but it creates a temporal coupling through a
global:

```python
config  = Config.load()                        # side effect: load_dotenv()
api_key = os.environ["ANTHROPIC_API_KEY"]      # only works because of line 1
```

Reorder those and it silently reads an ambient key or raises. ADR 0001 already
committed to *"`Config.load()` is the only thing that touches the filesystem"* —
`.env` **is** the filesystem, so its values should come back through `Config`
rather than be left as a puddle in `os.environ` for callers to find.

`ValueError`, not a new error class: step-03 §5.6 set the rule that *absent*
config raises `ValueError` while *unknown* config raises a `BoukenshaError`
subclass. A missing key is absent (decision 10).

**Honesty note for the README.** This is a read-through, not a pure
frozen-data story: `load_dotenv()` mutates `os.environ`, so the value really
does transit a global. Making it pure means switching to `dotenv_values()` and
holding the mapping on `Config` — a change to step-00 semantics with its own
blast radius, deliberately out of scope (§10).

### 5.4 `boukensha/__init__.py`

Add `Client` and `ApiError` to the imports and to `__all__`, keeping both lists
alphabetised as they already are. Update the module docstring from
`"""Boukensha — step 3: the prompt builder."""` to step 4.

### 5.5 `boukensha/backends/anthropic.py`

**Docstring only.** Replace:

> Named `AnthropicBackend`, not `Anthropic`, because step 04 imports the SDK's
> `Anthropic` client into the same namespace.

with a reason that survives the no-SDK constraint (§2.10) — the class is a
*backend*, one of a family sharing a contract, and a bare `Anthropic` names a
vendor rather than a role. No code changes.

### 5.6 `examples/example.py`

Six-line diff from step 03's example, plus the new client block.

**Removed** — the two `add_message` calls that make the payload unsendable
(§2.7). **Reworded** — the user message, so the model has something to act on
with the tools it has:

```python
ctx.add_message("user", "I've just arrived in the dungeon. Look around, then head north.")
```

**Unchanged** — both tool registrations, byte for byte. That is the point: the
reader carries the identical fixture across the step boundary, and the only
visible change is that it now gets posted.

**Added:**

```python
api_key = config.require_secret(AnthropicBackend.API_KEY_ENV)
client  = Client(backend, api_key=api_key)

payload = builder.to_api_payload(max_output_tokens=1024)

print(f"Sending request to {builder.url}…")
response = client.call(payload)

print(json.dumps(response, indent=2))

usage = response["usage"]
cost  = backend.estimate_cost(
    input_tokens=usage["input_tokens"],
    output_tokens=usage["output_tokens"],
)
print(f"Stop reason: {response['stop_reason']}")
print(f"Usage:       {usage['input_tokens']} in, {usage['output_tokens']} out")
print(f"Cost:        ${cost:.6f}")
```

Three notes:

- **The `1024` is explicit and at the call site.** The library default stays
  16000 (step-03 decision 11 stands). Ruby's 1024 lives on `Client#call`, i.e.
  at the boundary of the call — putting ours in the example is *more* faithful
  to where Ruby has it than changing the constant would be, and it bounds a demo
  that now costs money. `max_tokens` is a ceiling, not a target: the real spend
  is ~$0.001 either way (§9.1).
- **`estimate_cost` gets its first caller in the ladder.** It has existed since
  step 03 with none. This mirrors what step 03 did for `to_messages` /
  `to_tools`. It ignores `cache_creation_input_tokens` and
  `cache_read_input_tokens`, which are 0 here because nothing enables caching —
  the README says so rather than leaving it as a silent inaccuracy.
- **The step prints `stop_reason` and stops.** The response will say `tool_use`
  (§9.1). Acting on it is step 05, and the README says so — the same handoff
  Ruby's README makes.

### 5.7 `week1_baseline/bin/python/04_api_client`

**No change.** It exists, it is executable, and it already points at
`../../python/04_api_client`. Verified.

---

## 6. Documentation to write

### 6.1 `week1_baseline/python/04_api_client/README.md`

Follows the Ruby step-04 README's structure (intro → New Files → Updated Files →
How It Works → API table → Considerations → Run Example), plus:

- **Setup** — unchanged from steps 00–03. `requirements.txt` is untouched;
  everything new here is standard library.
- **`Client` table** — `call(payload)`, and the constructor's three arguments.
- **No dependencies** — the Ruby's point, restated with the actual reason: it is
  a constraint on the exercise, not a preference (§2.10, ADR 0008). State
  plainly what we are hand-rolling that an SDK would provide, so the cost is
  visible.
- **Retry policy** — the status rule, `retry-after`, jitter, the attempt count.
  A short table is clearer than prose here.
- **Why timeouts are not retried** — §2.3 in a paragraph, with the billing
  consequence spelled out. This is the section that stops someone "fixing" the
  allowlist. Point at the code comment; point the code comment back here.
- **Certificates** — the Ruby's whole OpenSSL section replaced with one
  sentence: `ssl.create_default_context()` loads the system trust store, there
  is nothing to configure. Name what it replaces so a reader comparing trees
  isn't left looking for it.
- **Credentials** — `Config.require_secret`; the library reads no environment;
  this step, unlike step 03, genuinely cannot run without a key. Point at
  ADR 0007.
- **`ApiError`** — the five fields, and one worked example of the composed
  message.
- **Cost** — what a run actually costs, from the real numbers in §9.1, and the
  note that `estimate_cost` ignores cache token fields.
- **The system prompt actually in force** — the `prompt_override` indirection
  (§4). A reader editing `prompts/system.md` and seeing no change deserves to
  have been warned.
- **Expected output** — ***generated from an actual run, not hand-written.***
  Steps 00–03 all learned this, and the Ruby README of this step is wrong about
  its own output (§2.9). State that the model's reply varies between runs and
  that what's shown is a snapshot.
- **What step 05 does** — the response comes back with `stop_reason: "tool_use"`
  and `tool_use` blocks; handling them is the Agent Loop.
- **Divergences** — the §8 table.
- **Run Example** — `./week1_baseline/bin/python/04_api_client`.

### 6.2 `CONTEXT.md`

Two terms added, in the existing definition-list style. No existing term becomes
wrong.

| Term | Substance |
|---|---|
| **Client** | The object that performs one API call: it sends a payload to a provider's endpoint and returns the parsed response. It transports; it does not serialize. |
| **Attempt** | One HTTP request. A single call may make several — a retryable failure is retried — and only the last one's outcome is returned. |

**Client** deliberately completes the sentence **Backend** already starts
(*"It serializes; it does not send"*), so the two terms define each other by
contrast. **Attempt** earns its place because `ApiError.attempts` exposes the
count and the README's retry table depends on the distinction between a call and
a request.

*Not* added: **stop reason** and **usage**. Both appear in this step's output,
but they belong to the steps that consume them — 05 and 06 respectively — and
defining a term before anything acts on it is how glossaries rot.

### 6.3 `docs/adr/0007-backend-holds-no-credentials.md` — amendment

One line in **Consequences**. It currently reads:

> **Step 04's `Client` becomes the thing that holds the credential**, which is
> the right owner — it is the object that makes the request. It finds the
> variable name via `AnthropicBackend.API_KEY_ENV`.

The first sentence stands. The second does not: under decision 2 the *example*
finds the variable name via `API_KEY_ENV` and asks `Config.require_secret` for
its value, because a `Client` that reads `os.environ` would break the very
principle this ADR's Decision §5 establishes. Amend it to say so, and note that
the amendment strengthens rather than reverses the original decision.

### 6.4 `docs/adr/0008-no-vendor-sdks.md`

Same format as 0001–0007 (Status / Date / Applies to / Context / Decision /
Consequences / Verification).

- **Context** — lead with the constraint: the course forbids vendor SDKs. Say
  plainly that this is externally imposed, so the ADR is a record rather than an
  argument. Then state honestly what the constraint costs, because a future
  reader will want to know we knew: the vendor SDK ships retries with the
  correct status set, timeouts, `request-id` capture, typed exceptions, and a
  guard that refuses non-streaming requests it estimates will exceed ten
  minutes. We hand-roll the first four (§5.1, §5.2) and do not have the fifth.
- **Decision** — `urllib.request` + `json`, standard library only.
  `requirements.txt` stays PyYAML + python-dotenv.
- **Consequences** — the `Backend` seam stays load-bearing: `url`,
  `headers(api_key)`, and `to_api_payload()` get their first real caller, and
  §2.2 of the step-03 plan (public methods with no callers) does not recur here.
  `parse_response` at step 05 remains meaningful because the response is a plain
  dict rather than a typed SDK object. `AnthropicBackend` keeps its name but
  needs a new reason (§5.5). The retry, backoff, and error-classification logic
  is ours to get right, which is why §9.2 exists.
- **Rejected: the `anthropic` SDK.** Not rejected on merit — it is the better
  engineering answer for production Python, and the skill guidance for this
  ecosystem says to default to it. Rejected because the constraint forbids it.
  Recording the merit is the point: it stops the next reader assuming we hadn't
  considered it.
- **Rejected: `httpx` / `requests`.** Would abandon the no-libraries position
  while buying less than the SDK would — no retry policy, no request-id capture,
  no typed errors. Worst of both.
- **Verification** — `requirements.txt` unchanged; `grep` finds no third-party
  import in `client.py`; the live run in §9.1.

### 6.5 `docs/adr/0009-client-transports-payloads.md`

- **Context** — §2.6 **in full, not by reference**: the `Agent` constructor
  taking both `builder:` and `client:` (`agent.rb:16-17`), `parse_response`
  being called on the builder directly (`agent.rb:38`), and `wrap_up`'s
  `call(tools: [], …)` (`agent.rb:79`). Plans are working documents superseded
  by the next step's; this is the durable record.
- **Decision** — `Client(backend, *, api_key, timeout)` and
  `call(payload) -> dict`. The `Client` knows how to send bytes and recover from
  transport failure. It does not know what a conversation is.
- **Rejected: `Client(builder)`, matching Ruby.** Reads alike side by side, and
  keeps the divergence table shorter. Rejected because it forces `tools=`
  through three layers at step 05 to support one call site, and gives
  `max_output_tokens` a second resolution point — undoing a step-03 decision
  that was itself argued and recorded.
- **Rejected: `Client(builder)` with a no-argument `call()`.** Smallest step-04
  diff, but it defers the question to step 05 rather than answering it, and
  arrives there with nothing durable arguing either way.
- **Consequences** — step 05's tools-disabled turn is
  `PromptBuilder(ctx, backend, tools={})` with no new parameter anywhere; the
  `tools.nil? ?` ternary is never written; `max_output_tokens` keeps exactly one
  resolution point; `Client` is constructible in isolation from a stub backend
  and a dict, with no Context or Registry in sight.
- **Verification** — the §9.1 live run, plus the §9.2 stub checks, both of which
  construct a `Client` without ever building a `Context`.

---

## 7. Implementation order

1. Confirm the starting state with the `diff -rqx __pycache__` in §1. Stop if it
   reports anything.
2. `boukensha/errors.py` — `ApiError` and its `__str__`.
3. `boukensha/config.py` — `require_secret`.
4. `boukensha/client.py` — constants, `_retryable_status`, `_retryable_error`,
   `_delay`, `call`. Write the two "deliberately absent" comments as you write
   the allowlist, not afterwards.
5. `boukensha/backends/anthropic.py` — docstring.
6. `boukensha/__init__.py` — exports.
7. `examples/example.py`.
8. Run it against the live API; **capture the real output**.
9. Run the §9.2 stub checks; **capture the real output**. Delete the stub.
10. Run the §9.3 environment checks; capture the real error messages.
11. `README.md`, using the captured output from 8–10.
12. `CONTEXT.md` — two new terms.
13. ADR 0007 amendment; ADR 0008; ADR 0009 — with §9 output pasted into their
    Verification sections.
14. Final `diff -rqx __pycache__` against step 03 to confirm nothing outside
    §4's NEW / EDIT / REWRITE list drifted.

---

## 8. Divergences from the Ruby port

Steps 00–03's divergences all still apply. These are the rows step 04 adds.

Note this is the longest divergence table of any step so far, and that most rows
are **Ruby reliability defects**, not Python-idiom choices. The README should
say so, or it reads as drift.

| # | Ruby | This port | Why |
|---|---|---|---|
| 1 | `net/http` | `urllib.request` | external constraint forbids vendor SDKs; stdlib on both sides (§2.10); ADR 0008 |
| 2 | `Client.new(builder)`; `call(max_output_tokens:)` | `Client(backend, api_key=…)`; `call(payload)` | the Agent already holds the builder; avoids the step-05 `tools=` ternary and a second `max_output_tokens` resolution point (§2.6); ADR 0009 |
| 3 | `ENV.fetch` at the wiring site | `Config.require_secret` | `.env` is filesystem, and ADR 0001 makes `Config` its only reader; removes a temporal coupling through a global (§5.3) |
| 4 | `RETRYABLE_STATUS_CODES` omits **529** | `status in {408,409,429} or status >= 500` | 529 `overloaded_error` is the most common retryable status; a rule doesn't rot (§2.1) |
| 5 | `retry-after` ignored | honoured, clamped to `MAX_RETRY_DELAY` | 0.5/1/2s against a 30s request achieves nothing but three more rejections (§2.2) |
| 6 | no jitter | equal jitter on computed backoff only | free; and a server-specified delay is a floor, not a suggestion |
| 7 | no timeouts set (inherits 60s) | explicit `DEFAULT_TIMEOUT = 600.0` | 60s is below our 16000-token generation time (§2.3) |
| 8 | read timeout is retried | timeouts are **not** retried | the server may have generated and billed; worst case was 4 billed generations per logical call (§2.3) |
| 9 | `OpenSSL::SSL::SSLError` retried; README section on `ca_file` | certificate failures not retryable; **no README section, no code** | `ssl.create_default_context()` loads the system store on every platform (§2.4) |
| 10 | blocklist of transient errors | **allowlist** of retryable errors | a blocklist can silently admit a permanent failure |
| 11 | `ApiError < StandardError`, message only | `ApiError(BoukenshaError)` with `status_code` / `error_type` / `request_id` / `attempts` / `body` | status shouldn't require parsing prose; `request-id` is what support asks for (§2.5) |
| 12 | request id discarded | captured on the error path | free — it is already in `HTTPError.headers` |
| 13 | `call(max_output_tokens: 1024)` — a library default | payload built by the caller; `1024` passed explicitly by the example | keeps one resolution point; puts the number where Ruby's own call-site default is |
| 14 | example: `read_file` / `list_directory` | `look` / `move` retained from step 03 | Ruby's tools contradict the MUD system prompt actually in force; filesystem tools arrive properly at step 10 (§2.8) |
| 15 | example: 3 messages incl. an unmatched `tool_result` | 1 user message | step 03's fixture is a hard 400 (§2.7). Ruby's step 04 also collapses to one message — the change was forced, not stylistic |
| 16 | example prints the raw response | also prints `stop_reason`, `usage`, and `estimate_cost` | gives `estimate_cost` its first caller in the ladder and makes spend visible |
| 17 | README output is stale and mislabels its own command | output generated from a real run, labelled as a snapshot | §2.9; steps 00–03 established this |

Rows 4–10 are one decision seen from seven angles — *the Ruby's retry loop is
wrong in ways that only bite at production settings* — and ADR 0002 (the port
fixes known limitations) is the standing licence for all of them. Rows 2 and 13
are one decision; ADR 0009 is the record. Row 1 is ADR 0008.

---

## 9. Verification

`examples/example.py` remains the safety net (step-03 decision 16, carried
forward). Step 04 only makes *hand-verified* cover the branches the example
structurally cannot reach.

### 9.1 Already captured

**The live call**, run against the real API with the step's exact fixture:

```
model        claude-haiku-4-5-20251001
stop_reason  tool_use
content      [ tool_use look {},
               tool_use move {"direction": "north"} ]
usage        688 in, 69 out
cost         $0.001033
request-id   req_011CdPtQhGGgjMLC5fATVVap
```

Two things to note in the README. The response contains **two** `tool_use`
blocks — parallel tool use — which is exactly what step 05's `handle_tool_calls`
loop iterates over. And the real cost of a run is about a tenth of a cent, so
the `1024` ceiling is a bound on the pathological case, not a cost control.

**The step-03 fixture is unsendable** (§2.7), confirmed by posting step 03's
exact `to_api_payload()` output:

```
HTTP 400   request-id: req_011CdPt61tRdqQSWdD6Nj475
messages.2.content.0: unexpected `tool_use_id` found in `tool_result` blocks:
toolu_01X. Each `tool_result` block must have a corresponding `tool_use` block
in the previous message.
```

### 9.2 Stub-server checks — run during implementation, ship nothing

The example proves the POST works and nothing else. It cannot make the API
return a 529 on demand, send a `retry-after: 30`, or stall for 600 seconds — so
every fix in rows 4–11 of §8 would otherwise ship on reasoning alone, and each
fails silently when wrong.

Drive a throwaway `http.server` stub **from the scratchpad**, capture the
output, paste it into the README and ADRs, then delete it.

| Scenario | Expected |
|---|---|
| 529, then 200 | succeeds; `attempts == 2` |
| 429 with `retry-after: 2` | sleeps ≈2s, not 0.5s |
| 429 with `retry-after: 99999` | sleep clamped to `MAX_RETRY_DELAY` |
| 500 × 4 | `ApiError(status_code=500, attempts=4)` |
| 400 | raises immediately; `attempts == 1` (not retryable) |
| error body is not JSON | `ApiError.body` holds the raw text; `error_type is None`; no exception from `__str__` |
| 200 with a non-JSON body | `ApiError`, not a `JSONDecodeError` escaping |
| stall beyond `timeout` | `ApiError`; **`attempts == 1`** — the billing rule (§2.3) |
| connection refused | retried; `attempts == 4` before raising |
| `request-id` header present on a 4xx | surfaces in `ApiError.request_id` and in `str(e)` |

### 9.3 Environment checks

```bash
# the step runs end to end
./week1_baseline/bin/python/04_api_client

# a missing credential fails at wiring time with a message that names the file
TMP=$(mktemp -d); cp .boukensha/settings.yaml "$TMP/"; cp -r .boukensha/prompts "$TMP/"
env -u ANTHROPIC_API_KEY BOUKENSHA_DIR="$TMP" ./week1_baseline/bin/python/04_api_client
# expect: ValueError "ANTHROPIC_API_KEY is not set. Add it to <TMP>/.env or export it."

# the step is still self-contained — the check ADR 0002 established
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/04_api_client
# expect: ValueError "tasks.player is missing from settings.yaml" — step-00 behaviour, unchanged
```

`env -u` alone is not sufficient for the second check: this repo's
`.boukensha/.env` defines `ANTHROPIC_API_KEY` and `Config.load()` loads it. The
honest check points at a config dir with settings and prompts but **no `.env`**.
Same reasoning as ADR 0007's Verification section.

### 9.4 The no-tests guardrail

**No test file, test directory, or test dependency is created by this step.**
The stub in §9.2 is a throwaway that lives in the scratchpad and is never
committed. `requirements.txt` stays PyYAML + python-dotenv. Step-03 decision 16
carries forward unchanged.

If a future step wants a test suite, that is a decision with its own ADR — it
binds every subsequent step to a convention — and not something to arrive at
sideways through step 04.

---

## 10. Out of scope

- **The `anthropic` SDK, `httpx`, and `requests`.** ADR 0008.
- **Streaming.** The vendor SDKs refuse non-streaming requests they estimate
  will exceed ten minutes; we have no such guard and no streaming support. At
  16000 max output tokens this is a theoretical rather than practical limit, but
  it is a real gap and the README names it.
- **`parse_response`.** Step 05 adds it to `Backend`; it is the next abstract
  method to join the contract. `call()` returning a plain `dict` is what keeps
  it meaningful.
- **Widening `Message.content` to `str | list[dict]`.** Step 05's
  `handle_tool_calls` does `add_message(:assistant, content)` where `content` is
  a list of content blocks (`agent.rb:96`). Ruby's `Context` is untyped so it
  works there; ours is not. Recorded here so it is not rediscovered.
- **The `tools=` narrowing parameter.** Never written, by construction — step
  05's tools-disabled turn constructs a `PromptBuilder` with `tools={}`.
  ADR 0009.
- **Prompt caching, `thinking`, `output_config.effort`, task budgets, and
  `fallbacks`.** The payload is the five-key shape step 03 built. Anything
  richer is a later step's decision, and the model table is where it would land.
- **Making `Config` hold `.env` values instead of reading through `os.environ`.**
  `dotenv_values()` instead of `load_dotenv()` would make `require_secret` a
  pure accessor rather than a read-through (§5.3). It changes step-00 semantics
  and deserves its own decision.
- **Promoting the timeout to a task setting.** `max_output_tokens` became one at
  step 03 because a caller wanted to vary it. Nothing varies the timeout yet.
- **Editing the root `.boukensha/` fixture.** No new settings key is introduced,
  and the file is shared with the Ruby tree.
- **Reporting §2.7 upstream.** Worth doing as a courtesy; not a blocker, and not
  this plan's job.
- **Modifying any earlier step's tree.** `Config` changes in *this* step's copy
  only; `week1_baseline/python/03_prompt_builder` stays frozen.
