# 0007 — The backend holds no credentials

**Status:** accepted
**Date:** 2026-07-25
**Applies to:** `week1_baseline/python/03_prompt_builder` and later steps

## Context

The Ruby's step-03 example cannot run without an Anthropic account:

```ruby
Boukensha::Backends::Anthropic.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"), model: model)
```

`ENV.fetch` raises `KeyError` when the variable is unset, so the script dies
before printing anything — for a step that **makes no network call at all**. Step
03 produces a payload, a set of headers and a URL. `Client`, HTTP and `ApiError`
are step 04.

And the key is barely used. `Backends::Anthropic` has five public members:

| Member | Uses `@api_key`? |
|---|---|
| `to_messages` | no |
| `to_tools` | no |
| `to_payload` | no |
| `url` | no |
| `headers` | **yes** |

One of five. A credential is held for the whole lifetime of the object so that a
single method can interpolate it into a hash.

The same pattern repeats across the Ruby's other four backends, and step 12 adds
a *second* case statement beside the provider→class one, mapping provider to the
name of its environment variable — so provider→env-var is duplicated too.

## Decision

**The backend is a serializer. It holds no credential and reads no environment.**

1. No `api_key` field. `AnthropicBackend(model=…)` is the whole constructor.
2. `headers(api_key)` takes the credential at the one call that needs it. It is
   therefore a **method**, not a property — the one asymmetry with `url`, and it
   follows from the argument.
3. `PromptBuilder.headers(api_key)` forwards it.
4. `backend_for(task)` reads nothing from the environment.
5. **Nothing anywhere in the library calls `os.environ`** except
   `Config._resolve_dir`, which reads `BOUKENSHA_DIR`. ADR 0001 established that
   `Config.load()` is the only thing that touches the filesystem; this is that
   same principle one level out.
6. `API_KEY_ENV` stays on the backend class as the *name* of the variable — not
   its value. Step 04's `Client` reads it to know what to fetch. Provider→env-var
   is knowledge the backend owns, so it lives on the backend, once.

The example reads the key itself, at the point of use, and runs fine when it is
absent:

```python
api_key = os.environ.get(AnthropicBackend.API_KEY_ENV)
for name, value in builder.headers(api_key or "<unset>").items():
    print(f"  {name}: {'***' if name == 'x-api-key' else value}")
```

Headers are printed **redacted**. The header *shape* — `x-api-key` rather than a
bearer token, plus the mandatory `anthropic-version` — is part of what this step
teaches, and the Ruby example sidesteps it by not printing headers at all.
Redaction makes it safe to paste a real run into a README.

**Rejected: an optional `api_key` on the constructor**, with `headers` raising
when it is absent. It fixes runnability, but it buys a partially-valid object:
whether the backend works depends on which method you call, and the null surfaces
far from where it was allowed in. A constructor that accepts incomplete state is
a constructor that stops being a guarantee.

**Rejected: `backend_for` reading `os.environ`.** Convenient — it would also
absorb the provider→env-var duplication — and this was the design initially
agreed in the session before being reversed. It is a hidden dependency on global
mutable state: invisible at the call site, and untestable without monkeypatching
the environment. `API_KEY_ENV` gets the deduplication without the hidden read;
the caller does the reading, visibly.

## Consequences

- **Step 03 runs on a bare checkout with no Anthropic account.** Verified below.
- **`headers` is a method, `url` is a property.** Deliberate: one takes an
  argument and one does not.
- **Step 04's `Client` becomes the thing that holds the credential**, which is
  the right owner — it is the object that makes the request.

  *Amended at step 04.* This originally continued: *"It finds the variable name
  via `AnthropicBackend.API_KEY_ENV`."* That is not what happens. A `Client` that
  looked up a variable name and read `os.environ` would break Decision §5 above —
  the whole point of which is that **nothing in the library reads the
  environment**. `Client` is library code; the rule applies to it too.

  What actually happens: the **example** finds the variable name via
  `API_KEY_ENV` and asks `Config.require_secret()` for its value, then passes it
  to a required `api_key=` keyword. `.env` is filesystem, and ADR 0001 makes
  `Config.load()` the only thing that touches it, so its values come back through
  `Config` rather than being left as a puddle in `os.environ`.

  The amendment **strengthens rather than reverses** the original decision: the
  credential still arrives at the object that makes the request, and there is now
  one *more* place that reads no environment rather than one fewer.
- **Tests need no environment fixture.** Every serialization path is reachable
  with nothing set.
- **A backend is always fully constructed.** There is no state in which some of
  its methods work and others do not.
- The Ruby's `ENV.fetch` failure mode — a `KeyError` from library construction,
  raised at step 03 for a step that sends nothing — has no analogue here.

## Verification

```
AnthropicBackend(model="claude-haiku-4-5")     constructed with no credential of any kind
builder.to_api_payload()                       ['model', 'system', 'max_tokens', 'tools', 'messages']
builder.url                                    'https://api.anthropic.com/v1/messages'
builder.headers("sk-ant-test")["x-api-key"]    'sk-ant-test'
AnthropicBackend.API_KEY_ENV                   'ANTHROPIC_API_KEY'    — the name, not the value
```

The step runs with no credential, because it sends nothing:

```
env -u ANTHROPIC_API_KEY ./week1_baseline/bin/python/03_prompt_builder
exit 0    — full payload printed; the header line reads `x-api-key: ***`
```

`env -u` alone is not a sufficient check here: this repo's `.boukensha/.env`
defines `ANTHROPIC_API_KEY`, and `Config.load()` loads it. The honest check
points at a config dir that has settings and prompts but **no `.env`**, so no
key exists anywhere in the process:

```
TMP=$(mktemp -d); cp .boukensha/settings.yaml "$TMP/"; cp -r .boukensha/prompts "$TMP/"
env -u ANTHROPIC_API_KEY BOUKENSHA_DIR="$TMP" ./week1_baseline/bin/python/03_prompt_builder
exit 0    — same full payload; `x-api-key: ***`
```

The Ruby, for contrast, needs `ANTHROPIC_API_KEY` set or `ENV.fetch` kills it
before the first `puts`.

And the step is still self-contained, the check ADR 0002 established:

```
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/03_prompt_builder
ValueError: tasks.player is missing from settings.yaml
```
