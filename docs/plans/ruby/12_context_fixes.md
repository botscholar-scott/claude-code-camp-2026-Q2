# `12_context` — fix list

**Target:** `week1_baseline/ruby/12_context`
**Written:** 2026-07-26 · **Reconciled:** 2026-07-27
**Supersedes:** `12_context+fixes.md`, now deleted. Everything in it that was
still live has been folded in here — §1.1, §5 (F19), §6, §9.

A menu, not a mandate. Every item says what it is, where it lives, how it was
found, and what it costs. Pick from it.

**Where the tools come from.** boukensha ships none of its own. Every tool the
agent has is discovered from an MCP server listed under `mcp_servers` in
`settings.yaml`; `Tools::FileSystem`, `Tools::Shell` and `Tools::Mud` were
deleted when `12_context` was synced from upstream and `tools/mcp.rb` replaced
all three. See `docs/adr/0012-boukensha-is-an-mcp-host.md`. The consequence that
keeps recurring below: an empty or unloadable `mcp_servers` means **zero tools**,
which presents as "the agent can only talk" rather than as an error.

---

## 1. Where things actually stand

Verified by running it, not by reading it.

| Check | Result |
|---|---|
| tbaMUD on `localhost:4000` | open |
| `mud-manager --mcp` handshake + `tools/list` | 26 tools |
| `bundle check` | satisfied |
| `bundle exec rake test` | 36 runs, 111 assertions, **0 failures** |
| `./week1_baseline/bin/ruby/12_context` | connects, logs in, 3 parallel tool calls, answers, `turn_end completed`, 11,393 tokens |

The old plan sorted everything by "what blocks play." Nothing blocks play. The
three things that did — no daemon on PATH, no `charm` gem, no `BOUKENSHA_DIR` in
the launcher — are all fixed, and `rake test` runs (the `Gemfile` now declares
`rake` and `minitest`, which was the "no tests ran" bug).

So this list is sorted by **what will bite during a long session**, then by
**what bites when you change a setting**, then by cheap cleanups.

### 1.1 Landed in the working tree, not yet committed

Three defects carried over from the superseded plan were fixed after this list
was written. They have no F-number because they were never on it; their old
D-numbers are kept so the history stays traceable.

| was | what changed | where |
|---|---|---|
| **D4** — every tool parameter advertised as required; the MCP server's own `required`, `enum` and `default` thrown away | `Tool#parameters` is now the server's JSON Schema, carried through verbatim. `Tools::Mcp.to_boukensha_params` became `normalize_schema`, and all five backends drop the schema straight into their own envelope instead of re-deriving `required` from the property names. `Tool#properties`/`#required` are readers over it; `EMPTY_SCHEMA` covers zero-argument tools. | `tool.rb`, `tools/mcp.rb`, `registry.rb`, `run_dsl.rb`, `backends/*.rb` (5) |
| **D1** — compaction cut by message count, landing mid-`tool_use`/`tool_result` pair → opaque API 400 | `compact_messages!` advances the cut forward to the first real `:user` message at or after the target, and drops nothing when no safe boundary exists ahead. | `context.rb` |
| **D6** — the `prompt` event serialized the whole history every iteration, O(n²) per turn | Logs the newest message only; full history behind `BOUKENSHA_DEBUG`. `message_count` still reports the true history length. | `logger.rb` |

Covered by `test/test_context_compaction.rb`, `test/test_logger_prompt.rb` and
three new cases in `test/test_tools_mcp.rb`. Suite: **36 runs, 0 failures.**

**D1 is not F2, and neither is finished.** Three separate compaction bugs:
D1 was *where* the cut lands (fixed), F2 is *when* the check runs (open), and
**F33** is that the fixed rule finds no boundary at all in a one-shot run
(open). `agent.rb` is untouched by the above. Read §2's F33 before treating
compaction as solved — the landed fix is correct and currently inert.

**The D4 fix is backend-symmetric.** All five got the same edit and all five now
receive a more correct schema than before — verified by emitting
`Backends::Ollama#to_tools` against a real mud-manager `inputSchema` and getting
valid `/api/chat` function format back, with `enum` surviving as structure. If
verbatim schemas strain any backend it will be **Gemini**, whose OpenAPI subset
is the strict one; that is a thing to watch, not a known defect.

---

## 2. Bites you today

### F2 — Compaction never fires during a turn
**File:** `agent.rb:31` · **Size:** small (move one call)

```ruby
def run
  @context.reset_turn_tokens
  compact_if_needed          # ← outside the loop
  loop do
    ...
```

`compact_if_needed` runs once, before the first API call. Inside a 25-iteration
MUD turn the history grows unchecked and compaction never gets a second look.
The one place it's needed — a long tool-calling grind — is the one place it
can't run.

There is a second effect worth knowing: because the context is fresh in a
one-shot `Boukensha.run`, `current_tokens` is 0 at that single check, so
`needs_compaction?` is false and compaction never runs at all. It only ever
fires in the REPL, where one `Context` is shared across turns.

**Fix:** also check at the top of each iteration. Two lines — but **not without
F33**, or you get a no-op that runs every iteration instead of once.

---

### F33 — Safe-boundary compaction has no boundary to find in a one-shot run
**File:** `context.rb#compact_messages!`, `#safe_cut_point` · **Size:** small
**Must land with:** F2 — fixing either alone is worse than fixing both

The D1 fix (§1.1) cuts only at a real `:user` message, which is the one place no
tool pair is open *and* a legal place for a history to start. Correct rule, but
`:user` messages are added in exactly three places:

| where | when |
|---|---|
| `boukensha.rb:103` | the goal — once, at index 0 |
| `agent.rb:108` | the wrap-up directive — at the very end of a turn |
| `repl.rb:119` | REPL input — once per turn |

So in `Boukensha.run(task:)` — the tbaMUD grind — index 0 is the *only* `:user`
message. `target` is `min(ceil(n*0.40), n-2)`, which is ≥ 2 for any history of
4+, and no `:user` exists at or after it. `safe_cut_point` returns 0.
**Compaction drops nothing, ever, in a one-shot run.** The suite already pins
this: `test_drops_nothing_when_no_user_message_follows_the_target`.

**This is not a regression.** On the pre-fix code compaction never fired in a
one-shot run either, for an unrelated reason: `compact_if_needed` is called once
at `agent.rb:31`, before the loop, on a context whose `current_tokens` is still
0, so `needs_compaction?` is false and it is never asked again (that is F2). The
two versions differ only in the **REPL**, which shares one `Context` across turns
— there the threshold genuinely is crossed at a turn start, and the new rule cuts
at a turn boundary instead of chopping blind. Strictly better there, equal
elsewhere.

**Why it must land with F2.** `current_tokens` is now only zeroed when something
was actually dropped, which is honest but means pressure stays pinned above the
threshold once crossed. Today F2 hides that by asking only once per turn. Fix F2
alone and you get a per-iteration no-op that reports a compaction each time.

**Fix:** stop requiring a second `:user` message. Pin `messages[0]` — the goal,
which is the one message a long run must never lose — and cut the *middle*:
drop from index 1 forward to a point that begins a fresh `assistant[tool_use]`
group. That satisfies both API constraints (history starts with a user message,
no orphaned pair) without depending on a boundary the workload never produces.

**Consequence of leaving it:** history grows unbounded within a turn. On
Anthropic at 200k that ends at `max_turn_tokens` via `wrap_up`, which is
graceful. Under F24 on Ollama at a 4,096 `num_ctx` it is silent truncation from
the front.

---

### F4 — A dead MCP subprocess is handed to the model as a tool result
**File:** `agent.rb:170` · **Size:** small

```ruby
rescue StandardError => e
  result = "ERROR: #{e.class}: #{e.message}"
```

`mud-manager` is a separate process. If it dies, or the telnet socket drops, the
agent reads the crash as an ordinary tool result, issues another two dozen
commands into nothing at real cost, and then confidently summarises a session
that never happened. Wrong answer, silently, for money.

**Fix:** catch `UnknownToolError` and `ArgumentError` — the model's own mistakes,
which it genuinely recovers from — and let everything else propagate.

**Source:** this is exactly ADR 0010, written for the Python port and never
applied to Ruby.

---

### F5 — The launcher throws the answer away
**File:** `examples/example.rb:31` · **Size:** trivial

```ruby
Boukensha.run(
  task: "Look at your surroundings, ..."
)
```

The return value is never printed. The launcher prints three config lines, sits
silent for a minute, and exits — which is what "it doesn't work" looks like. It
did work; the transcript is in `.boukensha/sessions/*.jsonl`.

**Fix:** `puts Boukensha.run(...)`. Or point the launcher at `bin/boukensha` and
use the REPL, which does print.

---

## 3. Bites you the moment you change a setting

### F6 — Only 4 Anthropic models are known, and none of them are current
**File:** `backends/anthropic.rb:8-35` · **Size:** trivial

The table has `claude-haiku-4-5`, `claude-haiku-4-5-20251001`,
`claude-sonnet-4-6`, `claude-opus-4-8`. `configure_model` raises
`UnsupportedModelError` on anything else, so putting `claude-opus-5`,
`claude-sonnet-5`, or `claude-fable-5` in `settings.yaml` fails at boot. If you
want to try a stronger model when navigation misbehaves, this blocks you.

Rows needed (context window / input $ / output $ per MTok):
`claude-opus-5` 1M / 5 / 25 · `claude-sonnet-5` 1M / 3 / 15 ·
`claude-fable-5` 1M / 10 / 50.

**Source:** `03_prompt_builder.md` divergence #14.

---

### F7 — No HTTP timeout, and timeouts are retried
**File:** `client.rb:26-33`, `client.rb:8-17` · **Size:** small

No `open_timeout`, no `read_timeout`, so `Net::HTTP` uses its 60s default. And
`Net::ReadTimeout` is in `TRANSIENT_ERRORS`, so the response to hitting it is to
**retry** — re-running a generation the server may already have completed and
billed. Worst case is four billed generations for one logical call.

Survivable today only because `agent.max_output_tokens` defaults to 1024 and a
1024-token generation finishes inside a minute. Raise that ceiling and this
becomes a billing bug.

**Fix:** set an explicit `read_timeout` (600s is what the vendor SDKs use), and
take `Net::ReadTimeout` out of the retryable list.

**Source:** `04_api_client.md` §2.3 and divergences #7, #8.

---

### F8 — Retry list is wrong in three cheap ways
**File:** `client.rb:7-17`, `client.rb:74` · **Size:** trivial each

| | Now | Should be | Why |
|---|---|---|---|
| **529** | not in `RETRYABLE_STATUS_CODES` | retryable | `overloaded_error` is the most common retryable status; use `>= 500` and it can't rot |
| **`Retry-After`** | ignored | honoured, clamped | 0.5/1/2s backoff against a 30s server-requested delay just buys three more rejections |
| **`OpenSSL::SSL::SSLError`** | retried 3× | not retryable | a certificate failure never succeeds on retry |

**Source:** `04_api_client.md` divergences #4, #5, #9.

---

### F9 — Window pressure counts only the uncached tokens
**File:** `agent.rb:91` · **Size:** trivial

```ruby
@context.update_tokens(usage["input_tokens"].to_i)
```

`input_tokens` is the **uncached remainder**. True prompt size is
`input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. Nothing
sets `cache_control` today so they're equal — but 26 tool schemas plus the system
prompt is a large, stable prefix and prompt caching is the obvious cost lever for
a level climb. The day you turn it on, the compaction trigger reads a number far
below reality and **stops firing entirely**.

`log_viz/session.rb:111-112` already reads both cache fields, so the consumer
expects them.

**Fix:** sum the three for window pressure. Leave `add_turn_tokens` alone — spend
and pressure are different measurements. Do this *before* enabling caching, not
after.

---

### F10 — Missing or misnamed config is indistinguishable from an empty one
**File:** `config.rb:136-143` · **Size:** small

`settings.yml` isn't tried; only `settings.yaml`. And the `else` branch returns
`{}` instead of raising, so a wrong `BOUKENSHA_DIR`, a missing directory, and a
`.yml` extension all produce an agent with no model, no tasks, and **zero tools**
— silently. Under MCP that presents as "the agent can only talk", not "your
config is missing." This already cost time once.

**Fix:** accept both extensions; raise when the resolved dir doesn't exist,
naming the path. An empty `mcp_servers:` on a *present* config stays legal.

**Source:** ADR 0002 fixed this in Python; it never reached Ruby.

---

### F21 — The TUI aborts the process: two Go runtimes in one process
**File:** `tui.rb:194` (`lip`), `tui.rb:6-8` (requires) · **Size:** ~15 lines
**Status:** workaround available — `boukensha --no-tui` is unaffected

`boukensha` without `--no-tui` dies with `Abort trap: 6`. Not a Ruby exception —
the Go side dies and takes the process with it:

```
fatal error: bad sweepgen in refill
runtime.(*mcache).refill   mcache.go:157
runtime.(*mcache).nextFree malloc.go:945
runtime.mallocgc
goroutine 17 ... [running, locked to thread]
```

Crash report confirms the layer: `lipgloss.bundle` → `runtime.fatalthrow` →
`dieFromSignal` → Ruby's `sigabrt` → `rb_bug_for_fatal_signal`.

`bubbletea.bundle` and `lipgloss.bundle` are **separate Go c-archives, each with
a complete embedded Go runtime**. `mcache` is per-OS-thread, so two runtimes
binding Ms to the same threads corrupt each other's allocator state. Timing
dependent, hence a hard abort rather than an error.

`tui.rb:1-3` already documents this failure mode — it requires
`bubbletea`/`lipgloss`/`bubbles` rather than `charm` precisely because charm also
pulls `ntcharts`, "whose Go runtime breaks bubbletea's input reader." That fix
removed the *third* runtime. Two remain. (`bubbles` is pure Ruby — no native
bundle — so it's not a factor.)

**Fix:** `Lipgloss` appears exactly once, in the `lip` helper, and all 5 styled
call sites go through it. It sets foreground/background from hex strings
(`ANSI_COLORS`) plus bold, then `.render(str)` — three ANSI SGR sequences.
Replace the helper with a small object exposing `#render`, delete
`require "lipgloss"`, and bubbletea is the only Go runtime left.

**Caveat:** two-runtimes is the strongly indicated cause, not a proven one. This
change is the cheapest test of the hypothesis and a real fix if it holds.

**Not the cause, ruled out:** terminal emulator (the panic is inside `mallocgc`;
no terminal I/O in the frame stack) · ABI mismatch (both gems ship a `4.0/`
build and `require "lipgloss"` loads clean on ruby 4.0.6) · the missing
`patches/bubbletea` patch (that one is about dropped keystrokes) · config (the
`~/.boukensharc` fix landed; `--no-tui` reaches the prompt with mud (26) and
filesystem (14)).

**Aftermath to know about:** when the TUI aborts it never restores the tty, so
that terminal tab stays in raw mode and Enter echoes as `^M`. `stty sane`, or a
new tab.

---

### F22 — Nothing is cached, and 78% of every call is a stable prefix
**Files:** `backends/anthropic.rb#to_payload` · **Size:** small
**Depends on:** F9 (must land first) · **Interacts with:** F6, F23

Measured on the live config:

| | tools | bytes | ~tokens | share of schemas |
|---|---|---|---|---|
| `tbamud` | 26 | 8,456 | ~2,114 | 51% |
| `fs` | 14 | 8,042 | ~2,010 | 48% |
| **schemas total** | 40 | 16,498 | ~4,124 | |
| system prompt | | 716 | ~179 | |

Observed first-call input: 5,531 tokens; growth ~650/iteration. So the *fixed*
prefix dominates, and it is re-sent uncached on every call — by iteration 8 the
same 16 KB of schemas has been paid for eight times, roughly 33k of the 60k
turn budget.

Render order is `tools` → `system` → `messages`, and both are byte-stable, so a
single `cache_control: {type: "ephemeral"}` breakpoint on the last tool or
system block caches the lot at ~0.1× after a 1.25× write.

**Two hard ordering constraints:**

1. **F9 first.** With caching on, `usage["input_tokens"]` becomes the *uncached
   remainder*. `record_usage` reads only that field, so window pressure would
   read near-zero and compaction would stop firing entirely.
2. **Minimum cacheable prefix is model-dependent**, and Haiku 4.5's is **4,096
   tokens**. Below it, caching silently no-ops — no error, `cache_creation` just
   stays 0. This is what makes F22 and F23 conflict on Haiku (see F23).

Verify with `usage.cache_read_input_tokens` — `log_viz/session.rb:111-112`
already parses it.

---

### F23 — The `filesystem` MCP server costs ~2,010 tokens per call and does nothing
**File:** `.boukensha/settings.yaml` · **Size:** one line, no code
**Interacts with:** F22, F6

`npx -y @modelcontextprotocol/server-filesystem /tmp`, prefix `fs`,
`required: false`, 14 tools. Rooted at `/tmp`, so it cannot reach the repo, the
MUD, or any game data. Nothing in the system prompt refers to it. Its purpose is
architectural demonstration — settings.yaml says so: *"a third-party server
nobody wrote boukensha code for — which is the whole point."* It is what
replaced the deleted `Tools::FileSystem` / `Tools::Shell` under ADR 0012.

For a level climb it is 48% of the tool-schema budget, paid on every call, to
prove a point already proved.

**But do not remove it before deciding F6.** On Haiku 4.5 the prefix without
`fs` falls to ~3,400 tokens, below the 4,096 cacheable minimum — so dropping it
would *forfeit F22 entirely*:

| | per-call cost after the first |
|---|---|
| keep `fs` + cache (Haiku) | ~550 effective tokens |
| drop `fs`, no cache (Haiku) | ~3,400 tokens |
| drop `fs` + cache (Sonnet 5 / Opus 5) | ~230 effective tokens |

The third row needs F6. On `claude-sonnet-5` the minimum is 1,024 and on
`claude-opus-5` it is 512, so both levers become additive instead of exclusive.
That makes F6 a prerequisite for getting the best of F22 and F23 together, not
just a convenience.

---

### F24 — The Ollama backends discard `max_output_tokens` and never set `num_ctx`
**Files:** `backends/ollama.rb#to_payload`, `backends/ollama_cloud.rb#to_payload`
**Size:** small · **Blocks:** running any local model usefully

Both build a payload with **no `options` block**:

```ruby
def to_payload(context, max_output_tokens: 1024, tools: nil)
  { model: @model, stream: false, messages: ..., tools: ..., think: false }
end
```

Two consequences:

1. `max_output_tokens` is accepted and silently dropped. Nothing bounds
   generation locally.
2. No `num_ctx`, so Ollama serves its **default ~4,096-token context** whatever
   the model supports — while `MODELS` claims 128,000–256,000 and
   `Models.context_window` feeds that number into `compaction_threshold`.
   Compaction believes it has 128k of room in a 4k window and never fires;
   Ollama silently truncates from the front instead.

**The arithmetic that makes this urgent for a local run:** the tool schemas are
~4,124 tokens and the default context is ~4,096. The tool definitions alone fill
the window before the system prompt or one line of game text. Dropping `fs`
(F23) takes schemas to ~2,114 and makes local play possible at all.

Note the collision with F22: **4,096 is the number in both cases and it cuts
opposite ways** — on Haiku 4.5 it is the *floor* below which prompt caching
silently no-ops (so keep `fs`), on Ollama it is the *ceiling* (so drop `fs`).
The right answer depends entirely on which model is in `settings.yaml`.

**Fix:** send `options: { num_ctx: <model window>, num_predict: max_output_tokens }`.
Sourcing `num_ctx` from the backend's own `context_window` keeps one number in
one place.

**Also true and separate:** `ollama` is not installed on this machine and
nothing is listening on `localhost:11434`. And 26-tool function calling is
demanding for 8B-class models — expect to test tool-call reliability before
trusting a local run, independent of this fix.

---

### F25 — A truncated response is recorded as a completed turn
**Files:** `backends/*.rb#parse_response` (5), `agent.rb:57-65` · **Size:** small
**Amplified by:** F14 (`max_output_tokens` defaults to 1024)

Every backend flattens the provider's stop reason to two values:

```ruby
stop_reason = response["stop_reason"] == "tool_use" ? "tool_use" : "end_turn"
```

Anthropic returns **six** stop reasons — `end_turn`, `max_tokens`,
`stop_sequence`, `tool_use`, `pause_turn`, `refusal` — and this folds five into
one. `"max_tokens"` becomes `"end_turn"`, so `Agent#run` takes the completion
branch: it logs `turn_end(reason: "completed")`, appends the truncated text to
the context as the assistant's final answer, and returns it to the caller.

**And it loses work, not just labelling.** The completion branch runs
`extract_text`, which keeps `"text"` blocks only. A reply cut off at the ceiling
that *also* contained `tool_use` blocks has those calls **silently dropped** —
the agent never dispatches them and never learns they existed. `refusal` and
`pause_turn` disappear down the same path.

The agent cannot tell "I finished" from "I was cut off", and neither can the
transcript. With `max_output_tokens: 1024` and 26 tools this is a live risk, not
a theoretical one — and the same collapse hides `refusal` and
`model_context_window_exceeded` too.

**Fix:** carry the provider's raw stop reason through alongside the normalized
one, and have `Agent#run` treat truncation as its own outcome rather than as
completion. `log_viz` already renders `stop_reason` on the response entry, so a
truthful value shows up in the viewer for free.

**Source:** Python port, `05_agent_loop.md` divergence #2 — *"`stop_reason`
collapsed to two values / truncation is not completion."*

---

### F14 (expanded) — `1024` is two default chains, one of them dead
**Files:** `tasks/base.rb:5,42`, `config.rb:91`, `prompt_builder.rb:18`,
`client.rb:25`, 5 × `to_payload` · **Size:** small

Live chain: `settings.yaml` → `Config#agent_max_output_tokens` → `Agent` →
`Client#call` → `to_api_payload` → `to_payload`.

Dead chain: `Tasks::Base::DEFAULT_MAX_OUTPUT_TOKENS` and
`Tasks::Base.max_output_tokens` are never called — `boukensha.rb` uses
`cfg.agent_max_output_tokens` at lines 93, 101, 161, 175.

The seven signature defaults are a silent fallback that fires only when the live
chain passes `nil` (which `Agent#call_opts` does whenever `@max_output_tokens`
is falsy), so they document nothing and can mask a wiring bug.

**Fix:** one constant, resolved once; delete the dead chain. Then reconsider the
*value* — 1024 is low enough to make F25 likely.

---

### F26 — `ApiError` is a string; status code, error type and request-id are discarded
**File:** `errors.rb:3`, `client.rb:62` · **Size:** small

```ruby
class ApiError < StandardError; end
raise ApiError, "API request failed after #{attempts} attempt#{...} (#{response.code}): #{response.body}"
```

Everything is fused into one sentence with the raw JSON body dumped in verbatim,
so the useful part — `error.message` — is buried in punctuation and a caller
wanting the status code has to parse prose.

Two things are dropped that cost nothing to keep:

- **`request-id`** (`req_011CSHoEeqs5C35K2UUqR7Fy`) — the identifier Anthropic
  support asks for, already sitting in the response headers on the failure path.
- **`error.type`** — the body is structured JSON
  (`{"error": {"type": "rate_limit_error", ...}}`), so the failure kind is
  machine-readable rather than something to regex out of a sentence.

**Fix:** carry `status_code`, `error_type`, `request_id`, `attempts` and the raw
`body` on the exception; compose the human sentence in `to_s`, falling back to
raw text when the body isn't JSON. Existing `rescue ApiError` sites keep working.

**Source:** `04_api_client.md` §2.5 and divergences #11, #12.

---

### F27 — The error classes are flat, so there is no family to rescue
**Files:** `errors.rb`, `boukensha.rb:85` · **Size:** small

`UnknownToolError`, `ApiError`, `LoopError` and `UnsupportedModelError` all
inherit `StandardError` directly — there is no `BoukenshaError` base, so a caller
cannot say "any failure from this library" without listing them or catching
`StandardError` (which is what F4 is trying to stop doing). An unknown provider
raises a bare `ArgumentError` from `boukensha.rb:85`, which isn't in the family
at all even though it's the same kind of failure as `UnsupportedModelError`.

**Fix:** introduce `BoukenshaError < StandardError`, reparent the four, and give
the unknown-provider case an `UnsupportedProviderError`. Retrofitting a base
later changes the ancestry of classes callers already rescue, so it is cheaper
now than after week 2.

**Source:** `02_the_registry.md` divergence #7, `03_prompt_builder.md` #17.

---

### F28 — A mistyped message role ships straight to the API
**File:** `message.rb`, `context.rb#add_message` · **Size:** small

`Message` is a bare `Struct` and `add_message(role, ...)` coerces nothing, so
`add_message(:assistnat, "…")` is accepted silently and each backend's `case`
falls through to its `else` branch, sending `role: "assistnat"` to the provider.
The failure surfaces as an opaque API error far from the call site that caused
it.

**Fix:** validate the role on construction against the three the codebase uses
(`:user`, `:assistant`, `:tool_result`) and raise at the call site.

**Source:** `01_struct_skeleton.md` divergence #4.

---

### F29 — `Registry` doesn't own the tool catalog; `Context` does
**Files:** `registry.rb`, `context.rb:21` · **Size:** medium

`Registry.new(context)` writes through to `@context.register_tool`, and
`dispatch` reads back out of `@context.tools`. The table lives on `Context`; the
registry is a façade over it. `Context` also exposes the live Hash via
`attr_reader :tools`, so any caller can reach past whatever the class intended —
which is why `register_tool` cannot enforce anything.

**This one is the author's own note, restored by hand from the course videos into
`week1_baseline/ruby/02_the_registry/README.md`:**

> We now register tools with the Registry but our code still has direct
> registration and tools in context. This likely should have been reworked.
> The context should have reference to tools[] its currently using, and the
> full table of tools registered should live on the Registry.
> We'll correct this manually in a future step and we will leave things place.

It was never corrected. Under MCP the blast radius is smaller than it was —
`Tools::Mcp` guards MCP-vs-MCP collisions itself — but the ownership is still
inverted.

**Verdict worth taking deliberately:** this is the largest structural item on the
list and buys no behaviour today. It matters if week 2 adds a second tool source.

**Source:** ADR 0004, `02_the_registry.md` §2.1 and divergences #1–#4.

---

### F30 — Retry classification is a blocklist, and backoff has no jitter
**File:** `client.rb:8-19, 74` · **Size:** small

`TRANSIENT_ERRORS` enumerates what *is* retryable, so anything not listed is
treated as permanent — but the reverse mistake is the dangerous one: a blocklist
can silently admit a permanent failure as retryable (which is exactly how
`OpenSSL::SSL::SSLError` ended up being retried three times, F8). An allowlist
cannot. Backoff is also pure `0.5 * 2**n` with no jitter, so concurrent clients
retry in lockstep.

Lower value than F7/F8 and touches the same method — worth folding in when you
open `client.rb`, not on its own.

**Source:** `04_api_client.md` divergences #6, #10.

---

## 4. Cheap cleanups

| # | What | Where | Size |
|---|---|---|---|
| F11 | `LoopError` is declared and rescued but **never raised** anywhere | `errors.rb:4`, `repl.rb:135` | delete 2 lines |
| F12 | `turn_count` returns the message count and `to_s` prints it as `turns=` | `context.rb:92,95` | rename to `message_count`, 3 call sites |
| F13 | `register_tool` silently overwrites on duplicate name | `context.rb:22` | raise instead (MCP-vs-MCP is already guarded by `Mcp::CollisionError`; a `run` block tool can still clobber) |
| F15 | `DEFAULT_CONTEXT_WINDOW = 32_000` is unreachable — every backend raises on unknown models first | `models.rb:14` | delete, or make `context_window` raise |
| F16 | `PromptBuilder#to_messages` breaks on 3 of 5 backends — `ollama`/`ollama_cloud` take `(system, messages)`, `openai` has no `to_messages` at all | `backends/*.rb` | latent only; the agent path uses `to_payload`, so nothing reaches it |
| F17 | `Boukensha.run` and `Boukensha.repl` duplicate ~45 lines verbatim (config, api-key `case`, backend `case`, logger snapshot) | `boukensha.rb:45-107` vs `113-193` | every fix above that touches wiring must be written twice |

**Sources:** F11 = `05_agent_loop.md` divergence #7 · F12 = `01_struct_skeleton.md`
divergence #8 · F13 = `01_struct_skeleton.md` divergence #6 / ADR 0004 ·
F16 = `03_prompt_builder.md`
divergence #6.

---

## 5. Observability — deliberately thin, because week 2 owns it

Three cheap things that make week-2 work easier and don't pre-empt it:

- **F18 — the system prompt is never logged.** `logger.rb#serialize_message`
  handles only `role`/`content`, and the `session_start` snapshot carries
  limits/model/provider only. The single largest determinant of behaviour is
  invisible in the transcript. Log it once at `session_start`.
- **F19 — the `compaction` event records only a count.**
  `compaction(before:, dropped:, context_window:)` takes `dropped` as a bare
  integer, so the viewer can only say "12 messages dropped" with no indication of
  what was lost or kept. Worth widening alongside anything that touches
  compaction — the D1 fix already changed what "dropped" means, since the cut is
  now the first safe boundary at or after the 40% mark rather than 40% exactly,
  and can legitimately be 0.
- **F20 — `/compact` in the REPL logs nothing.** `repl.rb:109` calls
  `@context.compact_messages!` directly, bypassing `@logger.compaction`. History
  jumps and the transcript shows no reason why. (See F19 for the shape of the
  event it should be writing.)

Explicitly **not** here: elision, summarisation, `world.md`, cross-session
knowledge files, thinking blocks. Those are week 2.

---

## 6. Not worth doing

- **F16** unless you actually switch to Ollama or OpenAI.
- **F17** as a standalone task — do it only if you end up touching wiring for
  three or more of the above, at which point it pays for itself.
- Anything about `week2_capable/` — it's empty in this tree.
- **Splitting `tool_result` blocks.** `backends/anthropic.rb:44` emits one `user`
  message per `tool_result`, so the smoke run's 3 parallel calls became 3
  separate user messages. Anthropic's guidance is to return them in a single user
  message; splitting them nudges the model away from parallel tool use over time.
  But it demonstrably works today, so this is a "someday", not a fix.

**Explicitly cut, and to stay cut** (carried over verbatim in intent from the
superseded plan, which is where these were first ruled out):

- **Elision** of old tool results, the summarisation call, `world.md`,
  per-session digests, and any cross-session knowledge file. Fix the compaction
  bugs; do not build a knowledge layer. Week 2 owns that.
- **Re-porting to Python.** Abandoned. `week2_capable` is 100% Ruby, and the
  Python port survives only as the source of several divergence notes cited above.
- **Enabling thinking** so `log_viz`'s `reasoning` lane populates. An open
  question, not a defect. Note that `claude-haiku-4-5` predates adaptive thinking
  and would need the older `budget_tokens` form; note also that both Ollama
  backends hardcode `think: false` in `to_payload`.
- **Rebuilding lesson steps `00`–`11`.** `12_context` is built from its
  predecessor, but the earlier rungs are teaching snapshots, not live code.

---

## 7. Ordering constraints

Not a schedule — these are the pairs where doing one without the other is worse
than doing neither.

| Do this | Before this | Or else |
|---|---|---|
| F33 (pin the goal, cut the middle) | F2 (check compaction each iteration) | F2 alone turns a once-per-turn no-op into a per-iteration no-op that logs a compaction every time |
| F9 (count cache tokens) | F22 (caching) | `input_tokens` becomes the uncached remainder, window pressure reads near-zero, compaction stops firing |
| F22 (caching) | F23 (drop `fs`) | prefix falls under Haiku's 4,096 cacheable floor and caching silently no-ops |
| F7 (timeouts) | raising `max_output_tokens` (F14) | a generation over 60s times out and is *retried* — up to four billed generations per call |
| F24 (`num_ctx`) | any local model run | Ollama serves a 4,096 window while the harness believes it has 128,000 |
| F18 (log system prompt) | — | touches the duplicated logger snapshot, so pairs naturally with F17 |

F25 stands alone and is worth doing at any output ceiling.

---

## 8. Test seams — not yet agreed

The suite is real (36 runs / 111 assertions / 0 failures), so pinning
behaviour before changing it is cheap. Natural seams:

Three seams proposed by the superseded plan are now realized, and are worth
reading as the pattern for the rest: `Context#compact_messages!`
(`test_context_compaction.rb`), `Tools::Mcp` schema pass-through and backend
`#to_tools` (`test_tools_mcp.rb`), and `Logger#prompt` (`test_logger_prompt.rb`).
Still open:

1. `Agent#handle_tool_calls` — needs a registry double that raises. The seam for
   F4, and the only one here that isn't a pure function.
2. `Backends::*#parse_response` — provider response in, normalized shape out.
   The seam for F25; feed it a recorded `stop_reason: "max_tokens"` body.
3. `Backends::*#to_payload` — the seam for F24; assert `options.num_ctx` and
   `options.num_predict` are present and sourced from one place.
4. `Config#load_settings` — the seam for F10; a temp dir with `settings.yml`,
   and a `BOUKENSHA_DIR` pointing nowhere.

Expected values come from an independent source — the MCP server's published
schema, `log_viz`'s parser, the Anthropic docs — never from the code under test.

---

## 9. Vocabulary and structure — migrated from the superseded plan

Neither of these buys behaviour. Both were recorded because they cost more to fix
the longer they stand.

### F31 — "task" means two different things
**Files:** `boukensha.rb:46` (`run`), `boukensha.rb:113+` (`repl`), `settings.yaml`

`Boukensha.run(task:)` is the **goal string** the agent is given. `settings.yaml`'s
`tasks.player` is a **role** bound to a provider and a model, with real structure
behind it in `lib/boukensha/tasks/`. One word, two concepts, one of which the
codebase now models properly.

**Resolution:** never call a goal a task — the keyword becomes `goal:`. Leave the
config concept named `tasks:`. Touches both public entry points and every call
site, which is why it pairs naturally with F17 (`run` and `repl` duplicate ~45
lines, so any wiring change is written twice).

### F32 — loop limits and role limits share one config block
**File:** `config.rb:84-102`

All four of `agent_max_iterations`, `agent_max_output_tokens`,
`agent_max_turn_tokens` and `agent_compaction_threshold` read from one global
`agent:` block — but `max_output_tokens` describes calls to a *role's* model
while the other three describe the loop. Low cost today; revisit only if a second
role appears. Interacts with F14, which is about the same value arriving down two
chains, one of them dead.

### Note on F12's rationale

The superseded plan justified renaming `turn_count` by pointing at a glossary in
`CONTEXT.md` that defined **Turn** as one goal driven to a final answer. That file
has since been deliberately deleted, so F12 stands on its own merits instead: a
method named `turn_count` that returns `@messages.size`, printed by `to_s` as
`turns=`, is simply mislabelled.
