# 04 · The API Client (Python)

The API Client takes the payload `PromptBuilder` assembled, POSTs it, and returns
the parsed response. **One HTTP request, one response.** No tool loop — that is
step 05.

Step 03 produced a payload, a URL and a set of headers, and posted nothing. This
is the step where the seam those three members form gets its first caller, and
where the ladder first spends money.

This is the Python port of `week1_baseline/ruby/04_api_client`, built on top of
[step 03](../03_prompt_builder/README.md). The deliberate differences are listed
under [Divergences from the Ruby port](#divergences-from-the-ruby-port) — this is
the longest such table of any step so far, and **most of its rows are Ruby
reliability defects rather than Python-idiom choices.**

**Step 04 is additive over step 03** for everything except two edits that reach
into classes earlier steps own: `Config` gains `require_secret()`, and
`AnthropicBackend`'s module docstring loses a claim it can never fulfil. Step
03's tree is untouched and remains a valid frozen snapshot.

`config.py` **stops being byte-identical across steps 00–04.** It was KEEP at
every rung until now. The change is purely additive — one new method — so every
earlier step's tree stays valid, but it is a first.

## Setup

Runs on the repo-root `.venv`, currently **Python 3.14.5**:

```bash
python3 -m venv .venv                                              # at the repo root
.venv/bin/pip install -r week1_baseline/python/04_api_client/requirements.txt
```

`requirements.txt` is **unchanged** from steps 00–03 (`PyYAML` and
`python-dotenv`, both still needed by `Config`). Everything new in this step —
the HTTP client, the retry loop, the JSON handling — is pure standard library.

**Unlike steps 00–03, this step cannot run without an API key.** It makes a real
call. See [Credentials](#credentials).

## New Files

| File | Purpose |
|------|---------|
| `boukensha/client.py` | **new** — `Client`, the retry loop, and the four tuning constants |
| `boukensha/errors.py` | edited — `ApiError` |
| `boukensha/config.py` | edited — `require_secret()` |
| `boukensha/backends/anthropic.py` | edited — module docstring only, no code change |
| `boukensha/__init__.py` | edited — exports `Client` and `ApiError` |
| `examples/example.py` | rewritten — makes the call, prints usage and cost |

`_repr.py`, `message.py`, `context.py`, `registry.py`, `tool.py`,
`prompt_builder.py`, `backends/base.py`, `backends/__init__.py`, `tasks/`,
`prompts/` and `requirements.txt` are **byte-identical to step 03**.

## How It Works

```
PromptBuilder.to_api_payload()
      ↓  dict
Client.call(payload)
      ↓  POST  (retry · backoff · retry-after · timeout)
https://api.anthropic.com/v1/messages
      ↓  JSON
dict
```

The builder knows *what* to send. The backend knows *what shape* to send it in.
The client knows *how to get it there and back* — and nothing else.

---

## `boukensha.Client`

| Member | Description |
|---|---|
| `Client(backend, *, api_key, timeout=600.0)` | Takes a backend for its `url` and `headers()`, and the credential |
| `call(payload)` | POSTs the payload; returns the parsed body as a `dict` |

```python
api_key = config.require_secret(AnthropicBackend.API_KEY_ENV)
client = Client(backend, api_key=api_key)

response = client.call(builder.to_api_payload(max_output_tokens=1024))
```

| Constant | Value | Meaning |
|---|---:|---|
| `DEFAULT_TIMEOUT` | `600.0` | One socket timeout covering connect *and* read |
| `MAX_RETRIES` | `3` | → **4** attempts at most. Ruby parity |
| `BASE_RETRY_DELAY` | `0.5` | First backoff window |
| `MAX_RETRY_DELAY` | `60.0` | Ceiling on any single sleep, `retry-after` included |

### It transports payloads; it does not wrap a builder

Ruby writes `Boukensha::Client.new(builder)`. This port takes the **backend** and
a **payload**:

```python
Client(backend, api_key=…).call(payload)      # one dict in, one dict out
```

It never sees a `Context`, a `Registry`, or a tool.

The reason is step 05. `Agent` is constructed with **both** a builder and a
client (`agent.rb:16-17`) and calls `parse_response` on the *builder* directly
(`agent.rb:38`) — so the client's own reference to the builder is redundant
coupling. And it costs something: `wrap_up` calls
`@client.call(tools: [], max_output_tokens: 400)` (`agent.rb:79`). Under
`Client(builder)` a tools-narrowed call has to plumb `tools=` down through
`Client.call` → `to_api_payload` → `to_payload`, which reintroduces exactly the
`tools.nil? ?` ternary step 03 avoided by construction, and gives
`max_output_tokens` a **second** resolution point.

Taking the payload instead means step 05's tools-disabled turn is just a second
`PromptBuilder(ctx, backend, tools={})`. No new parameter anywhere. See
[ADR 0009](../../../docs/adr/0009-client-transports-payloads.md).

It also means the client is constructible in isolation — the checks below drive
it with a nine-line stub backend and a dict, with no `Context` in sight.

---

## No dependencies

`Client` uses `urllib.request` and `json`. No `anthropic`, no `httpx`, no
`requests`.

**This is a constraint on the exercise, not a design preference.** The course
forbids vendor SDKs. Recording it that way matters, because the reasoning that
*would* justify it ("keeps the Backend seam load-bearing") is weaker than the
constraint itself, and week 2 will make the SDK look tempting.

So it is worth being explicit about what the constraint costs. The vendor SDK
ships all of this; we hand-roll the first four and simply do not have the fifth:

| The SDK gives you | Here |
|---|---|
| retries with the correct status set | `_retryable_status` (§ below) |
| connect and read timeouts | `DEFAULT_TIMEOUT`, one socket timeout |
| `request-id` capture | `ApiError.request_id`, on the error path |
| typed exceptions | `ApiError` with five fields |
| a guard refusing non-streaming requests estimated over 10 minutes | **absent** — see [Out of scope](#out-of-scope) |

See [ADR 0008](../../../docs/adr/0008-no-vendor-sdks.md).

---

## Retry policy

| Question | Answer |
|---|---|
| How many attempts? | **4** — one, plus `MAX_RETRIES = 3` |
| Which statuses retry? | `408`, `409`, `429`, **and everything `>= 500`** |
| Which transport errors retry? | `ConnectionError`, `socket.gaierror` — an **allowlist** |
| What about a timeout? | **Never retried.** See below |
| What about a certificate failure? | Never retried — it cannot succeed on a retry |
| How long between attempts? | `retry-after` when the server sends one, clamped to 60s; otherwise 0.5s / 1s / 2s with equal jitter |

### The status rule, not a list

```python
def _retryable_status(status: int) -> bool:
    return status in RETRYABLE_STATUSES or status >= 500
```

Ruby enumerates `[408, 409, 429, 500, 502, 503, 504]`. That list omits **529
`overloaded_error`** — the status the API returns when it is at capacity, and the
single most likely retryable failure in normal operation. Ruby treats it as
fatal.

An enumerated list is also the wrong shape: it rots the moment a new 5xx appears.
The rule covers 529 without naming it and needs no maintenance.

### `retry-after` is honoured

Ruby computes `0.5 * 2**(attempt-1)` regardless of what the server asked for. If
a 429 carries `retry-after: 30`, Ruby retries three times inside 3.5 seconds and
then fails, having achieved nothing except three more rejected requests.

A present `retry-after` is used **as-is**, clamped to `MAX_RETRY_DELAY`. No
jitter is added to it: if the server asks for 30 seconds, 30 seconds is a floor,
not a suggestion. Only the *computed* fallback gets jitter.

`retry-after` may legally be an HTTP-date. Anthropic sends seconds; the date form
falls through to backoff rather than adding a parser for a shape we will not
receive.

### Why timeouts are not retried

**This is the section that should stop you "fixing" the allowlist.**

Ruby sets no timeout at all, so `Net::HTTP` inherits its 60s default read
timeout. That is survivable there only because `call(max_output_tokens: 1024)`
caps generation short enough to usually finish inside a minute. **Our
`DEFAULT_MAX_OUTPUT_TOKENS` is 16000**, so a long generation will routinely
exceed 60 seconds — and `Net::ReadTimeout` is in Ruby's `TRANSIENT_ERRORS`, so
its response is to **retry**, re-running a generation the server may already have
completed and billed. Worst case for one logical call is **four billed
generations, silently.**

Two separate fixes:

1. **An explicit timeout.** `DEFAULT_TIMEOUT = 600.0` — the ten minutes the
   vendor SDKs default to, so the number is citable rather than invented, and it
   comfortably clears a 16000-token generation.
2. **Timeouts are not retryable.** `urlopen(req, timeout=N)` applies a **single
   socket timeout** to both connect and read; urllib exposes no separate knobs,
   and because a non-streaming Messages call withholds the response until
   generation completes, a connect-phase timeout and a generation-phase timeout
   are not reliably distinguishable. The choice is all-or-nothing, and at a 600s
   ceiling a timeout genuinely means the server held the request for ten minutes.

The rule states cleanly: **retry only when we know the server didn't do the
work.**

This is narrower than it sounds. Network blips do not surface as timeouts at a
600s ceiling — they surface as `ConnectionResetError`, `ConnectionRefusedError`
or `socket.gaierror`, all of which stay retryable. The code comment on
`_retryable_error` points back at this section.

### An allowlist, not a blocklist

Ruby lists the errors that *are* transient. We list the errors that *are*
retryable and raise on everything else. A blocklist can silently admit a
permanent failure the day a new exception type appears; an allowlist cannot.

### Certificates

**There is nothing to configure, and no code for it.**

Ruby's README devotes a whole section to telling you to fix your machine
(`ruby -e "require 'openssl'; puts OpenSSL::X509::DEFAULT_CERT_FILE"`), and
`client.rb:30-33` carries a commented-out `http.ca_file =` line with a note that
the macOS-correct value breaks on Linux/WSL2.

All of that evaporates here. `urllib.request.urlopen` uses
`ssl.create_default_context()`, which loads the system trust store on every
supported platform without configuration. *(Named explicitly because a reader
comparing the two trees will otherwise go looking for the missing section.)*

---

## Credentials

```python
api_key = config.require_secret(AnthropicBackend.API_KEY_ENV)
client = Client(backend, api_key=api_key)
```

**The library still reads no environment**, exactly as at step 03 — the backend
holds no credential, and `Client` does not call `os.environ` either. What is new
is `Config.require_secret()`.

The obvious alternative is for the example to read `os.environ` itself. That
works, but it creates a temporal coupling through a global:

```python
config  = Config.load()                        # side effect: load_dotenv()
api_key = os.environ["ANTHROPIC_API_KEY"]      # only works because of line 1
```

Reorder those and it silently reads an ambient key, or raises. ADR 0001 already
committed to *"`Config.load()` is the only thing that touches the filesystem"* —
and `.env` **is** the filesystem, so its values should come back through
`Config` rather than be left as a puddle in `os.environ` for callers to find.

**Honesty note:** this is a read-through, not a pure frozen-data story.
`load_dotenv()` mutates `os.environ`, so the value really does transit a global.
Making it pure means switching to `dotenv_values()` and holding the mapping on
`Config` — a change to step-00 semantics with its own blast radius, deliberately
[out of scope](#out-of-scope).

A missing key raises plain `ValueError`, and the message names the file:

```
ValueError: ANTHROPIC_API_KEY is not set. Add it to /…/tmp.zuyrtsRqyu/.env or export it.
```

`ValueError`, not a new error class: step 03 set the rule that *absent* config
raises `ValueError` while *unknown* config raises a `BoukenshaError` subclass. A
missing key is absent.

An empty or missing `api_key` also fails at **construction**, so a
misconfiguration surfaces at wiring time rather than as a 401 mid-run:

```
>>> Client(backend, api_key="")
ValueError: api_key is required and must not be empty
```

See [ADR 0007](../../../docs/adr/0007-backend-holds-no-credentials.md).

---

## `ApiError`

```
BoukenshaError
├── UnknownToolError            (step 02)
├── UnsupportedModelError       (step 03)
├── UnsupportedProviderError    (step 03)
└── ApiError                    (new — Ruby has this, flat under StandardError)
```

| Field | Meaning |
|---|---|
| `status_code` | The HTTP status, or **`None` when the request never got a response** |
| `error_type` | Anthropic's machine-readable kind, eg. `"rate_limit_error"` |
| `request_id` | The `request-id` header — what Anthropic support asks for |
| `attempts` | How many HTTP requests this one logical call made |
| `body` | The raw response body, verbatim |

Ruby fuses all of it into one string:

```ruby
raise ApiError, "API request failed after #{attempts} attempt#{...} (#{response.code}): #{response.body}"
```

so a caller wanting the status back has to parse prose, and the useful sentence
inside the JSON body — `error.message` — is buried in punctuation. Two things
are dropped that cost nothing to keep: the **request id**, already sitting in
`HTTPError.headers`, and **`error.type`**, already a field in the structured
body.

One class, not a hierarchy. Step 05's `except ApiError` catches everything, and
no caller in twelve steps needs to distinguish *rejected* from *never arrived* —
`status_code is None` already says which happened.

`__str__` composes the sentence from the parsed body:

```
API request failed after 1 attempt (401 authentication_error): invalid x-api-key [request-id: req_011CSHoEeqs5C35K2UUqR7Fy]
```

The parse is deliberately total. When the body is not JSON, `error_type` is
`None` and the raw text is used — an error path that raises while constructing
its own error message is worse than the failure it was reporting.

---

## Cost

The run below costs **$0.000863** — about a tenth of a cent. `estimate_cost` gets
its **first caller in the whole ladder** here; it has existed since step 03 with
none.

`max_output_tokens=1024` is passed **explicitly by the example**, not by
changing the library default (which stays 16000). Ruby's 1024 lives on
`Client#call` — at the boundary of the call — so putting ours at the call site is
*more* faithful to where Ruby has it than editing the constant would be. It is a
ceiling, not a target: the model used 35 output tokens, so the real spend is the
same either way. The `1024` bounds the pathological case; it is not a cost
control.

**`estimate_cost` ignores `cache_creation_input_tokens` and
`cache_read_input_tokens`.** Both are `0` here because nothing enables prompt
caching, so the figure is exact for this run — but it would be wrong the moment
caching is switched on. Said plainly rather than left as a silent inaccuracy.

---

## The system prompt actually in force

`prompts/system.md` ships with this step and is **never read**.

The repo fixture sets `prompt_override.system: true`, so `Task._read_prompt`
resolves to `.boukensha/prompts/player/system.md` instead. That was already true
at step 03; it becomes visible at step 04 because the prompt now reaches a model.

The file stays so the step remains self-contained when run against a config dir
with no override — but **editing `prompts/system.md` and seeing no change is
expected.** Edit `.boukensha/prompts/player/system.md`.

## Why the fixture changed

Step 03's example built three messages, and the last two make the payload
**unsendable**:

```python
ctx.add_message("assistant", "Let me take a look around first.")    # plain text, no tool_use
ctx.add_message("tool_result", "…", tool_use_id="toolu_01X")        # references nothing
```

Every `tool_result` must reference a `tool_use` block in the immediately
preceding assistant turn. `toolu_01X` was never emitted. Posting step 03's exact
`to_api_payload()` output returns a hard 400:

```
messages.2.content.0: unexpected `tool_use_id` found in `tool_result` blocks:
toolu_01X. Each `tool_result` block must have a corresponding `tool_use` block
in the previous message.
```

The backend is not at fault — `to_messages` serializes the `tool_result`
correctly. **The fixture data is invalid.** It is latent in the Ruby too, and
invisible at step 03 because that step never posts. Step 04 is the step that
exposes it, so the example collapses to a single user turn. Ruby's step 04 makes
the same collapse — the change was forced, not stylistic.

**Both tool registrations are unchanged, byte for byte.** That is the point: the
reader carries the identical `look` / `move` fixture across the step boundary,
and the only visible change is that it now gets posted.

Ruby's step-04 example instead swaps to `read_file` / `list_directory` and asks
*"What files are in the current directory?"* — while the system prompt actually
in force is the MUD one ("You are a MUD Journey Player Agent…"). It works, but it
reads oddly, and the handlers are unreachable at this step since step 04 never
dispatches. Filesystem tools arrive properly at step 10.

---

## Run Example

```bash
./week1_baseline/bin/python/04_api_client
```

**This makes a real API call and spends real money.** It needs
`ANTHROPIC_API_KEY` in the environment or in the config dir's `.env`.

Actual output, generated from a real run against this repo's `.boukensha/`
fixture — **not hand-written.** The model's reply varies between runs, so this is
a snapshot:

```
=== Boukensha Step 4: The API Client ===

Config:         Config(dir='/Users/…/claude-code-camp-2026-Q2/.boukensha', tasks=['player'])
Model:          claude-haiku-4-5
Max tokens:     1024

Sending request to https://api.anthropic.com/v1/messages…

Raw response:
{
  "model": "claude-haiku-4-5-20251001",
  "id": "msg_011CdPxqbSSwQHLVFYJeberT",
  "type": "message",
  "role": "assistant",
  "content": [
    {
      "type": "tool_use",
      "id": "toolu_01LYXVSNxun6uZeLvH5eLgCr",
      "name": "look",
      "input": {},
      "caller": {
        "type": "direct"
      }
    }
  ],
  "stop_reason": "tool_use",
  "stop_sequence": null,
  "stop_details": null,
  "usage": {
    "input_tokens": 688,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0,
    "cache_creation": {
      "ephemeral_5m_input_tokens": 0,
      "ephemeral_1h_input_tokens": 0
    },
    "output_tokens": 35,
    "service_tier": "standard",
    "inference_geo": "not_available"
  }
}

Stop reason: tool_use
Usage:       688 in, 35 out
Cost:        $0.000863

`stop_reason: tool_use` means the model wants a tool run. Acting on that
is step 05 — the Agent Loop. This step stops at the round trip.
```

Three runs produced this **identically** — same single `look` block, same 688 in
/ 35 out, same $0.000863. The model asks to `look` and stops there rather than
also requesting `move`, which is the sensible reading of *"Look around, then head
north"*: it wants the result of the first tool before choosing the second. A
response *may* carry several `tool_use` blocks — parallel tool use — and step
05's loop iterates `content` either way; this fixture just does not produce one.

*(The Ruby step-04 README's captured output, by contrast, shows the model saying
it has no way to list a directory — a run that predates the `list_directory` tool
its own current example registers. It also labels the command
`ruby 03_api_client/examples/step3.rb` while the banner says Step 4. Steps 00–03
of this port each hit a version of the same problem, which is why output here is
generated rather than written.)*

### What the response headers say

Nothing — **success-path headers are discarded.** `request-id` survives only on
the error path, where it is actionable. Nothing needs it on success until step
06's logger, which reads `usage` from the body.

### What step 05 does

The response comes back with `stop_reason: "tool_use"` and `tool_use` blocks in
`content`. Dispatching those through the `Registry`, feeding the results back as
`tool_result` messages, and looping until `stop_reason` is `end_turn` is the
**Agent Loop** — step 05. This step stops at the round trip.

---

## Verification

The example is the safety net, as at every step ([no test suite is
shipped](#out-of-scope)). But the example proves the POST works and nothing else:
it cannot make the API return a 529 on demand, send a `retry-after: 30`, or stall
for ten minutes. So every retry fix below would otherwise ship on reasoning
alone, and each fails silently when wrong.

These were driven against a throwaway `http.server` stub during implementation.
The stub is **not committed**; this is its real output.

| Scenario | Result |
|---|---|
| 529, then 200 | ✅ succeeded, `attempts == 2`, slept 0.41s |
| 429 with `retry-after: 2` | ✅ slept **2.0s**, not 0.5s |
| 429 with `retry-after: 99999` | ✅ clamped to **60.0s** |
| 500 × 4 | ✅ `ApiError(status_code=500, error_type='api_error', attempts=4)` |
| 400 | ✅ raised immediately, `attempts == 1`, no sleeps |
| 503 with a non-JSON body | ✅ `body` holds the raw HTML, `error_type is None`, `__str__` did not raise |
| 200 with a non-JSON body | ✅ `ApiError`, not a `JSONDecodeError` escaping |
| stall past the timeout | ✅ `ApiError`, **`attempts == 1`**, no sleeps — the billing rule |
| connection refused | ✅ retried, `attempts == 4` before raising |
| `request-id` on a 401 | ✅ in `.request_id` and in `str(e)` |
| empty `api_key` | ✅ `ValueError` at construction |

```
--- 529 then 200
    returned      {'id': 'msg_stub', 'stop_reason': 'end_turn'}
    sleeps        [0.414]

--- 429 retry-after: 2
    sleeps        [2.0]                     wall clock 2.01s

--- 429 retry-after: 99999
    sleeps        [60.0]                    (clamped to MAX_RETRY_DELAY)

--- 500 x4
    ApiError      API request failed after 4 attempts (500 api_error): Internal server error
    fields        status_code=500 error_type='api_error' request_id=None attempts=4
    sleeps        [0.435, 0.958, 1.198]     (equal jitter on 0.5 / 1 / 2)

--- 400
    ApiError      API request failed after 1 attempt (400 invalid_request_error): messages: at least one message is required
    sleeps        []

--- non-JSON error body
    ApiError      API request failed after 4 attempts (503): <html><body>502 Bad Gateway</body></html>
    fields        status_code=503 error_type=None request_id=None attempts=4

--- 200 with a non-JSON body
    ApiError      API returned a success status with a body that is not a JSON object after 1 attempt (200): not json at all

--- stall past timeout
    ApiError      Request to http://127.0.0.1:59151/ exceeded the 1.0s timeout after 1 attempt
    fields        status_code=None error_type=None request_id=None attempts=1
    sleeps        []                        <-- NOT retried. The billing rule.

--- connection refused
    ApiError      Connection to http://127.0.0.1:59153/ failed (ConnectionRefusedError: [Errno 61] Connection refused) after 4 attempts
    fields        status_code=None attempts=4
    sleeps        [0.464, 0.65, 1.511]

--- request-id on a 4xx
    ApiError      API request failed after 1 attempt (401 authentication_error): invalid x-api-key [request-id: req_011CSHoEeqs5C35K2UUqR7Fy]
    fields        status_code=401 error_type='authentication_error' request_id='req_011CSHoEeqs5C35K2UUqR7Fy' attempts=1

--- empty api_key
    ValueError    api_key is required and must not be empty
```

Note the last two transport rows: `status_code=None` is what distinguishes *never
arrived* from *rejected*, and it is why `ApiError` needs no subclasses.

The stub backend is the whole surface `Client` touches, which is
[ADR 0009](../../../docs/adr/0009-client-transports-payloads.md) demonstrated
rather than argued — no `Context`, no `Registry`, no `PromptBuilder`:

```python
class StubBackend:
    def __init__(self, url):
        self.url = url

    def headers(self, api_key):
        return {"Content-Type": "application/json", "x-api-key": api_key}
```

### Environment checks

A missing credential fails at wiring time, with a message that names the file:

```
TMP=$(mktemp -d); cp .boukensha/settings.yaml "$TMP/"; cp -r .boukensha/prompts "$TMP/"
env -u ANTHROPIC_API_KEY BOUKENSHA_DIR="$TMP" ./week1_baseline/bin/python/04_api_client

ValueError: ANTHROPIC_API_KEY is not set. Add it to /…/tmp.zuyrtsRqyu/.env or export it.
```

(`env -u` alone is not sufficient: this repo's `.boukensha/.env` defines
`ANTHROPIC_API_KEY` and `Config.load()` loads it. The honest check points at a
config dir with settings and prompts but **no `.env`**.)

And the step is still self-contained — the check ADR 0002 established:

```
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/04_api_client
ValueError: tasks.player is missing from settings.yaml
```

Step-00 behaviour, unchanged.

---

## Considerations

**Every failure is an `ApiError`.** A rejected request, a request that never
arrived, a timeout, and a 2xx whose body is not JSON all raise the same class.
Step 05 needs one `except`.

**`call()` does not validate the payload.** The backend built it; re-checking it
here would duplicate knowledge that already lives in one place.

**The retry loop is inline, not a `RetryPolicy` object.** Four module constants
and three small helpers. A policy object would be a seam no caller has asked
for — and there is exactly one caller.

**Exception ordering is load-bearing.** `urllib.error.HTTPError` subclasses
`URLError` subclasses `OSError` — and so do `TimeoutError`, `ConnectionError` and
`socket.gaierror`. The `except HTTPError` clause **must** precede `except
OSError`, or every HTTP status is swallowed by the transport branch and no status
is ever classified. There is a comment saying so in `client.py`.

**A connect failure arrives wrapped, a read timeout arrives bare.** urllib wraps
connect-phase `OSError`s in `URLError(reason=…)` but lets a read-phase
`TimeoutError` through directly. The handler unwraps `URLError.reason` so both
classify the same way.

**Success bodies are parsed too.** `json.loads` runs on the 2xx path, so a
malformed success body is an `ApiError` rather than a `JSONDecodeError` escaping
into a caller that only knows to catch `ApiError`.

**The conversation is still stateless.** The API remembers nothing between calls.
`Client` holds no session, no cookie and no connection pool — a fresh
`urlopen` per attempt. Step 12's compaction exists because every turn replays the
whole history.

---

## Divergences from the Ruby port

Steps 00–03's divergences all still apply. These are the rows step 04 adds.

**Most of these are Ruby reliability defects, not Python-idiom choices** — rows
4–10 in particular are one problem seen from seven angles: *the Ruby's retry loop
is wrong in ways that only bite at production settings.*
[ADR 0002](../../../docs/adr/0002-python-port-fixes-known-limitations.md) is the
standing licence for all of them.

| # | Ruby | This port | Why |
|---|---|---|---|
| 1 | `net/http` | `urllib.request` | external constraint forbids vendor SDKs; stdlib on both sides; ADR 0008 |
| 2 | `Client.new(builder)`; `call(max_output_tokens:)` | `Client(backend, api_key=…)`; `call(payload)` | the Agent already holds the builder; avoids the step-05 `tools=` ternary and a second `max_output_tokens` resolution point; ADR 0009 |
| 3 | `ENV.fetch` at the wiring site | `Config.require_secret` | `.env` is filesystem, and ADR 0001 makes `Config` its only reader; removes a temporal coupling through a global |
| 4 | `RETRYABLE_STATUS_CODES` omits **529** | `status in {408,409,429} or status >= 500` | 529 `overloaded_error` is the most likely retryable status; a rule doesn't rot |
| 5 | `retry-after` ignored | honoured, clamped to `MAX_RETRY_DELAY` | 0.5/1/2s against a 30s request achieves nothing but three more rejections |
| 6 | no jitter | equal jitter on computed backoff only | free; and a server-specified delay is a floor, not a suggestion |
| 7 | no timeouts set (inherits 60s) | explicit `DEFAULT_TIMEOUT = 600.0` | 60s is below our 16000-token generation time |
| 8 | read timeout is retried | timeouts are **not** retried | the server may have generated and billed; worst case was 4 billed generations per logical call |
| 9 | `OpenSSL::SSL::SSLError` retried; README section on `ca_file` | certificate failures not retryable; **no README section, no code** | `ssl.create_default_context()` loads the system store on every platform |
| 10 | blocklist of transient errors | **allowlist** of retryable errors | a blocklist can silently admit a permanent failure |
| 11 | `ApiError < StandardError`, message only | `ApiError(BoukenshaError)` with five fields | status shouldn't require parsing prose; `request-id` is what support asks for |
| 12 | request id discarded | captured on the error path | free — it is already in `HTTPError.headers` |
| 13 | `call(max_output_tokens: 1024)` — a library default | payload built by the caller; `1024` passed explicitly by the example | keeps one resolution point; puts the number where Ruby's own call-site default is |
| 14 | example: `read_file` / `list_directory` | `look` / `move` retained from step 03 | Ruby's tools contradict the MUD system prompt actually in force; filesystem tools arrive properly at step 10 |
| 15 | example: 3 messages incl. an unmatched `tool_result` | 1 user message | step 03's fixture is a hard 400. Ruby's step 04 also collapses to one message — the change was forced, not stylistic |
| 16 | example prints the raw response | also prints `stop_reason`, `usage`, and `estimate_cost` | gives `estimate_cost` its first caller in the ladder and makes spend visible |
| 17 | README output is stale and mislabels its own command | output generated from a real run, labelled as a snapshot | steps 00–03 established this |

Rows 2 and 13 are one decision;
[ADR 0009](../../../docs/adr/0009-client-transports-payloads.md) is the record.
Row 1 is [ADR 0008](../../../docs/adr/0008-no-vendor-sdks.md).

---

## Out of scope

- **The `anthropic` SDK, `httpx`, and `requests`.** ADR 0008. The SDK is not
  rejected on merit — it is the better engineering answer for production Python.
  It is rejected because the course constraint forbids it.
- **Streaming.** The vendor SDKs refuse non-streaming requests they estimate will
  exceed ten minutes; **we have no such guard and no streaming support.** At
  16000 max output tokens this is theoretical rather than practical, but it is a
  real gap.
- **`parse_response`.** Step 05 adds it to `Backend`; it is the next abstract
  method to join the contract. `call()` returning a plain `dict` is what keeps it
  meaningful — there is no typed SDK object to make it redundant.
- **Widening `Message.content` to `str | list[dict]`.** Step 05's
  `handle_tool_calls` appends an assistant message whose content is a *list of
  content blocks*. Ruby's `Context` is untyped so it works there; ours is not.
  Recorded so it is not rediscovered.
- **The `tools=` narrowing parameter.** Never written, by construction — step
  05's tools-disabled turn constructs a `PromptBuilder` with `tools={}`.
- **A test suite.** No test file, test directory, or test dependency is created
  by this step; the stub above was a throwaway. If a future step wants one, that
  is a decision with its own ADR — it binds every subsequent step to a
  convention — and not something to arrive at sideways through step 04.
- **Prompt caching, `thinking`, `output_config.effort`, task budgets and
  `fallbacks`.** The payload is the five-key shape step 03 built.
- **Making `Config` hold `.env` values instead of reading through `os.environ`.**
  `dotenv_values()` instead of `load_dotenv()` would make `require_secret` a pure
  accessor. It changes step-00 semantics and deserves its own decision.
- **Promoting the timeout to a task setting.** `max_output_tokens` became one at
  step 03 because a caller wanted to vary it. Nothing varies the timeout yet.
- **Editing the root `.boukensha/` fixture.** No new settings key is introduced,
  and the file is shared with the Ruby tree.
