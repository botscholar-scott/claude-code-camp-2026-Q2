# 0009 — The client transports payloads; it does not wrap a builder

**Status:** accepted
**Date:** 2026-07-25
**Applies to:** `week1_baseline/python/04_api_client` and later steps

## Context

Ruby's step-04 client wraps the builder:

```ruby
Boukensha::Client.new(builder)
...
def call(max_output_tokens: 1024)
  uri          = URI(@builder.url)
  request      = Net::HTTP::Post.new(uri, @builder.headers)
  request.body = @builder.to_api_payload(max_output_tokens: max_output_tokens).to_json
```

The natural reading is that a client needs a builder to have something to send.
Step 05 shows otherwise, and the evidence is recorded here in full rather than by
reference, because plans are working documents superseded by the next step's and
this needs to outlive them.

**Step 05's `Agent` holds both objects.**

```ruby
def initialize(context:, registry:, builder:, client:, ...)   # agent.rb:16-17
```

**And it uses the builder directly, not through the client.**

```ruby
@builder.parse_response(response)                              # agent.rb:38
```

So the caller that matters already has a builder in hand. The client's own
reference to it is redundant coupling — two paths to one object, and the object
is reachable either way.

**The redundancy has a concrete cost, and it lands at step 05.** `wrap_up` is the
only tools-narrowed call in the whole ladder:

```ruby
@client.call(tools: [], max_output_tokens: WRAP_UP_OUTPUT_TOKENS)   # agent.rb:79
```

Under `Client(builder)`, supporting that one call site means plumbing `tools=`
down through three layers — `Client.call` → `to_api_payload` → `to_payload` —
which reintroduces exactly the `tools.nil? ?` ternary that
[ADR 0004](0004-registry-owns-the-tool-catalog.md) and the step-03 design avoided
by construction, in a port that ships one backend precisely so such ternaries
stay unwritten. It also gives `max_output_tokens` a **second** resolution point,
undoing the step-03 decision that there be exactly one.

Two decisions from earlier steps would be quietly reversed to preserve a
constructor argument that its only caller does not need.

## Decision

**The client takes a backend and a payload.**

```python
Client(backend, *, api_key, timeout=DEFAULT_TIMEOUT).call(payload) -> dict
```

1. The backend is taken for `url` and `headers(api_key)` — nothing else.
2. `call(payload)` takes a fully-built payload and returns the parsed body.
3. The client never sees a `Context`, a `Registry`, or a `Tool`. One dict in,
   one dict out.
4. It does **not** validate the payload. The backend built it; re-checking here
   would duplicate knowledge that already lives in one place.

**The `Client` knows how to send bytes and how to recover from transport failure.
It does not know what a conversation is.**

That is a narrow interface over real complexity — behind `call(payload)` sit SSL,
a four-attempt retry loop, a status-classification rule, `retry-after` handling,
equal-jitter backoff, a socket timeout, JSON encode/decode and error wrapping.

**Rejected: `Client(builder)`, matching Ruby.** It reads alike side by side,
which has real value in a port whose readers compare trees, and it would keep the
divergence table one row shorter. Rejected because it forces `tools=` through
three layers to support one call site at step 05, and gives `max_output_tokens` a
second resolution point — undoing a step-03 decision that was itself argued and
recorded. Paying that at step 05 to save a divergence row at step 04 is the wrong
trade.

**Rejected: `Client(builder)` with a no-argument `call()`.** The smallest
possible step-04 diff, and genuinely tempting on those grounds. Rejected because
it does not answer the question, it *defers* it — and it arrives at step 05 with
nothing durable arguing either way, at which point the pressure will be to add
the `tools=` parameter rather than restructure the client.

## Consequences

- **Step 05's tools-disabled turn needs no new parameter anywhere.** It is a
  second builder:

  ```python
  PromptBuilder(ctx, backend, tools={}).to_api_payload(max_output_tokens=400)
  ```

  No `tools=` on `Client.call`, no `tools.nil? ?` ternary, no second `Client`.
- **`max_output_tokens` keeps exactly one resolution point**,
  `PromptBuilder.to_api_payload`, as step 03 decided.
- **The example passes `1024` explicitly** rather than the library default of
  16000. Ruby's 1024 lives on `Client#call` — at the boundary of the call — so
  the call site is *more* faithful to where Ruby has it than editing the constant
  would be.
- **`Client` is constructible in isolation.** A stub backend and a dict are
  enough; no `Context`, `Registry` or `PromptBuilder` need exist. That is what
  made the ten stub-server failure scenarios cheap to drive.
- **The credential is a required keyword on the constructor.** An empty or
  missing `api_key` raises `ValueError` at construction, so a misconfiguration
  fails at wiring time rather than as a 401 mid-run. See
  [ADR 0007](0007-backend-holds-no-credentials.md), amended by this step.
- **`Client` gains no knowledge as the ladder grows.** Ruby's client is
  byte-identical from step 05 through step 12; the only change it ever takes is
  the `tools:` parameter this decision removes the need for.
- **One more divergence row.** Recorded honestly rather than avoided.

## Verification

The client was driven through every failure branch using nothing but a stub
backend and a dict — no `Context` was constructed at any point:

```python
class StubBackend:
    def __init__(self, url):
        self.url = url

    def headers(self, api_key):
        return {"Content-Type": "application/json", "x-api-key": api_key}

Client(StubBackend(url), api_key="sk-stub", timeout=1.0).call({"model": "stub", "messages": []})
```

That is the entire backend surface `Client` touches: `url` and `headers()`.

```
529 then 200            returned {'id': 'msg_stub', 'stop_reason': 'end_turn'}   attempts=2
429 retry-after: 2      slept 2.0s                                              (not 0.5s)
429 retry-after: 99999  slept 60.0s                                             (clamped)
500 x4                  ApiError status_code=500 error_type='api_error' attempts=4
400                     ApiError attempts=1, no sleeps                          (not retryable)
timeout                 ApiError status_code=None attempts=1, no sleeps         (the billing rule)
connection refused      ApiError status_code=None attempts=4
401 with request-id     ApiError request_id='req_011CSHoEeqs5C35K2UUqR7Fy'
empty api_key           ValueError: api_key is required and must not be empty
```

And against the real API, with a real builder:

```
$ ./week1_baseline/bin/python/04_api_client
Sending request to https://api.anthropic.com/v1/messages…
stop_reason  tool_use
content      [ tool_use look {} ]
usage        688 in, 35 out
cost         $0.000863
exit 0
```

The forward check that this decision is the right one — that step 05's `wrap_up`
needs no `tools=` parameter — cannot be run until step 05 exists. It is asserted
here as the thing to verify then.
