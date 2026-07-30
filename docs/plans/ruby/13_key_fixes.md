# `13_key_fixes` — fix list

**Target:** `week2_capable/ruby/13_key_fixes/boukensha`
**Written:** 2026-07-26 · **Reconciled:** 2026-07-30

The fixes in this list are applied to the `12_context` code, which is what
`13_key_fixes/boukensha` is a copy of. The list was written against
`week1_baseline/ruby/12_context` and every file reference below still resolves,
since the two trees were identical when this epic started. §17 records what has
since landed here and no longer applies to the source tree.

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

## 1. Defects at a glance

Sorted by kind: what is broken, what wastes tokens through a logic error, what is
cheap enough to do anyway, what is structural. Feature area in brackets, detail
section in parentheses.

### 1.1 Broken — the app does not do what it should

- **F33** [CONTEXT] (§3): compaction drops nothing, ever, in a one-shot run. The
  safe cut point needs a second `:user` message the workload never produces.
- **F2** [CONTEXT] (§3): `compact_if_needed` runs once outside the loop, so
  compaction never gets a second look inside a 25-iteration turn. Land with F33.
- **F34** [MCP] (§4): a tool-level MCP error (`isError: true`) comes back as prose
  and is logged as a success, so a dropped telnet socket is indistinguishable
  from "you can't go that way".
- **F4** [MCP] (§4): a dead `mud-manager` subprocess is handed to the model as an
  ordinary tool result. It issues two dozen more commands into nothing, then
  summarises a session that never happened. Wrong answer, silently, for money.
- **F25** [BACKENDS] (§6): six stop reasons collapse to two, so `max_tokens` is
  recorded as a completed turn and any `tool_use` blocks in a truncated reply are
  silently discarded. Loses work, not just labelling.
- **F10** [CONFIG] (§7): a wrong `BOUKENSHA_DIR`, a missing directory or a `.yml`
  extension each yield an agent with zero tools and no error.
- **F24** [BACKENDS] (§6): the Ollama backends never set `num_ctx`, so Ollama
  serves a 4,096 window while the harness believes it has 128,000. Compaction
  never fires and Ollama truncates from the front. Fires only on a local run.

### 1.2 Wasting tokens through a programming or logic error

- **F22** [BACKENDS] (§6): nothing is cached, and ~4,124 tokens of tool schemas
  are re-sent on every call. By iteration 8 that is ~33k of the ~60k turn budget
  spent re-transmitting bytes that never change. Needs F9 first.
- **F23** [MCP] (§4): ~2,010 of those tokens are the `filesystem` server, rooted
  at `/tmp`, which cannot reach the MUD or the repo. Paid on every call.
- **F9** [CONTEXT] (§3): window pressure counts `input_tokens` only. Harmless
  today; silently disables compaction the moment F22 lands.
- **F7** [CLIENT] (§5): no `read_timeout`, and `Net::ReadTimeout` is retryable, so
  a slow generation can be re-run up to four times. Rare at a 1024 output
  ceiling; a billing bug the moment that ceiling rises.
- **F8** [CLIENT] (§5): `OpenSSL::SSL::SSLError` retried three times for nothing,
  `Retry-After` ignored so backoff just buys three more rejections, 529 not
  retried at all.
- **F14** [CONFIG] (§7): `1024` arrives down two chains, one of them dead. Low
  enough to make F25 truncation likely, and the dead chain hides where the value
  comes from.
- **F30** [CLIENT] (§5): retry classification is a blocklist, and backoff has no
  jitter. Fold into F7/F8, same method.

### 1.3 Cheap to fix, high win

- **F5** [LAUNCHER] (§7): the launcher never prints the return value, so a
  successful run looks like a hang. One `puts`. Belongs in §1.1 by symptom; it is
  here because of what it costs to fix.
- **F21** [TUI] (§9): delete `tui.rb`. The TUI was abandoned upstream in favour of
  the live jsonl viewer, so this is removal, not repair, and it takes the
  two-Go-runtimes problem and two native gem dependencies with it.
- **F6** [BACKENDS] (§6): three table rows unlock `claude-opus-5`,
  `claude-sonnet-5` and `claude-fable-5`, and with them the lower cache floors
  that make F22 and F23 additive instead of exclusive.
- **F13** [MCP] (§4): raise instead of silently overwriting a duplicate tool name.
- **F18** [LOGGING] (§10): log the system prompt once at `session_start`. The
  largest single determinant of behaviour is currently invisible in the
  transcript.
- **F20** [LOGGING] (§10): route REPL `/compact` through `@logger.compaction` so
  history doesn't jump for no recorded reason.
- **F35** [LOGGING] (§10): the logger drops the `tool_use_id` it already holds, so
  the transcript pairs calls to results by position. One argument.
- **F11** [CLEANUP] (§11): delete `LoopError`, declared and rescued but never
  raised. Two lines.
- **F12** [CLEANUP] (§11): rename `turn_count` to `message_count`. Three call
  sites.
- **F15** [CLEANUP] (§11): delete the unreachable `DEFAULT_CONTEXT_WINDOW`.

### 1.4 Structural and diagnostic — no behaviour change today

- **F26** [CLIENT] (§5): `ApiError` fuses everything into one string; status code,
  `error.type` and `request-id` are all discarded.
- **F27** [ERRORS] (§8): no `BoukenshaError` base, so there is no family to
  rescue. Cheaper to retrofit now than once callers depend on the ancestry.
- **F28** [MESSAGES] (§8): no role validation, so a typo surfaces as an opaque API
  error far from the call site that caused it.
- **F19** [LOGGING] (§10): the `compaction` event records only a count, so the
  viewer cannot say what was lost or kept.
- **F29** [REGISTRY] (§4): `Registry` is a façade over `Context`'s tool table.
  Largest structural item on the list; buys no behaviour until a second tool
  source appears.
- **F31** [WIRING] (§7): "task" names both the goal string and a config role.
- **F32** [CONFIG] (§7): loop limits and role limits share one `agent:` block.
- **F17** [WIRING] (§7): `run` and `repl` duplicate ~45 lines, so every wiring fix
  is written twice.
- **F16** [BACKENDS] (§6): `PromptBuilder#to_messages` breaks on 3 of 5 backends.
  Latent; the agent path never reaches it.

Three more (D1, D4, D6) are already fixed in the working tree and uncommitted.
See §2.1.

---

## 2. Where things actually stand

Verified by running it, not by reading it.

| Check | Result |
|---|---|
| tbaMUD on `localhost:4000` | open |
| `mud-manager --mcp` handshake + `tools/list` | 26 tools |
| `bundle check` | satisfied |
| `bundle exec rake test` | 36 runs, 111 assertions, **0 failures** |
| `./week1_baseline/bin/ruby/12_context` | connects, logs in, 3 parallel tool calls, answers, `turn_end completed`, 11,393 tokens |

Nothing blocks play. The three things that did — no daemon on PATH, no `charm`
gem, no `BOUKENSHA_DIR` in the launcher — are all fixed, and `rake test` runs
(the `Gemfile` now declares `rake` and `minitest`, which was the "no tests ran"
bug).

§1 sorts every defect by kind. The sections below are grouped by feature area and
carry the detail; §14 records the pairs where doing one without the other is
worse than doing neither.

### 2.1 Landed in the working tree, not yet committed

Three defects were fixed after this list was written. They have no F-number
because they were never on it; their D-numbers are kept so the history stays
traceable.

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
(open). `agent.rb` is untouched by the above. Read §3's F33 before treating
compaction as solved — the landed fix is correct and currently inert.

**The D4 fix is backend-symmetric.** All five got the same edit and all five now
receive a more correct schema than before — verified by emitting
`Backends::Ollama#to_tools` against a real mud-manager `inputSchema` and getting
valid `/api/chat` function format back, with `enum` surviving as structure. If
verbatim schemas strain any backend it will be **Gemini**, whose OpenAPI subset
is the strict one; that is a thing to watch, not a known defect.

---

## 3. Context and compaction

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

The D1 fix (§2.1) cuts only at a real `:user` message, which is the one place no
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

## 4. Tools, MCP, and the registry

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

### F34 — A tool-level MCP error is prose, so F4's fix cannot see it
**File:** `tools/mcp.rb:61` · `mcp/client.rb:42-43` · `agent.rb:169` · **Size:** small

```ruby
# tools/mcp.rb:60-61
result = client.call_tool(remote, kwargs.transform_keys(&:to_s))
result[:error] ? "error: #{result[:text]}" : result[:text]
```

MCP reports failure two different ways, and the harness only notices one. A
JSON-RPC protocol error lands in `res["error"]` and `client.rb:41` raises on it —
that path reaches `agent.rb:170` and is what F4 is about. But a *tool-level*
failure is returned as a *successful* JSON-RPC response carrying
`isError: true`. `client.rb:43` reduces it to a boolean, and `mcp.rb:61` folds
that boolean into the string as a lowercase `"error: "` prefix.

Nothing raises, so **F4's fix cannot reach this path.** Catching
`UnknownToolError`/`ArgumentError` and letting the rest propagate does nothing
for a failure that was never an exception. Note the two stringification sites
even disagree on spelling: `agent.rb:171` writes `"ERROR: "`, `mcp.rb:61` writes
`"error: "`.

Three consequences:

- **The failure mode F4 describes still happens.** A live `mud-manager` whose
  telnet socket has dropped returns `isError: true`, which becomes a string
  shaped exactly like `"error: you can't go that way"` — a legitimate response
  the model *should* shrug off and retry around. So it retries, into nothing, at
  cost. F4 closes the dead-process door; this one stays open.
- **The transcript records it as a success.** `agent.rb:169` runs the `ok: true`
  branch, because `dispatch` returned normally. `log_viz` consumes that flag
  directly (`log_viz/lib/log_viz/session.rb:133` → `tool_ok`), so the viewer
  renders a failed call as a successful one. Any week-2 observability work
  inherits the lie.
- **Non-text content is dropped silently.** `client.rb:42` is
  `Array(result["content"]).map { |c| c["text"] }.compact.join("\n")` — block
  types are discarded and any block without a `"text"` key vanishes without
  trace.

**Fix:** stop flattening at the boundary. `Tools::Mcp`'s registered block should
hand back the `{ text:, error: }` pair (or a small result object) rather than
prose, `agent.rb` should pass its `error` through to `@logger.tool_result(ok:)`
so the transcript is truthful, and only then decide what the model sees.

**Deliberately not settled here:** whether a server-reported error should
*raise*. `isError` is one flag covering both "you can't go that way" and "my
connection died", and they are not distinguishable from the flag alone — telling
them apart needs to know which conditions `mud-manager` marks, which is an
open question, not a known answer. Making the failure structured is worth doing
regardless; routing it is a separate decision.

**Source:** found by the Python port. Step 05 divergence #1 replaced raw hash
arrays with typed `TextBlock`/`ToolUseBlock` — *"one vocabulary for both
directions"* — which is the same fix one layer up. ADR 0010 is the standing
record that the loop must distinguish the model's mistakes from infrastructure
failure.

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

### F13 — `register_tool` silently overwrites on duplicate name
**File:** `context.rb:22` · **Size:** trivial

Raise instead. MCP-vs-MCP collision is already guarded by `Mcp::CollisionError`,
but a `run` block tool can still clobber a discovered one without a word.

**Source:** `01_struct_skeleton.md` divergence #6 / ADR 0004.

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

## 5. API client and transport

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

## 6. Backends and models

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

### F16 — `PromptBuilder#to_messages` breaks on 3 of 5 backends
**File:** `backends/*.rb` · **Size:** small

`ollama`/`ollama_cloud` take `(system, messages)`, and `openai` has no
`to_messages` at all. Latent only: the agent path uses `to_payload`, so nothing
reaches it.

**Source:** `03_prompt_builder.md` divergence #6.

---

## 7. Configuration and wiring

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

### F14 — `1024` is two default chains, one of them dead
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

---

### F32 — Loop limits and role limits share one config block
**File:** `config.rb:84-102`

All four of `agent_max_iterations`, `agent_max_output_tokens`,
`agent_max_turn_tokens` and `agent_compaction_threshold` read from one global
`agent:` block — but `max_output_tokens` describes calls to a *role's* model
while the other three describe the loop. Low cost today; revisit only if a second
role appears. Interacts with F14, which is about the same value arriving down two
chains, one of them dead.

---

### F17 — `run` and `repl` duplicate ~45 lines verbatim
**File:** `boukensha.rb:45-107` vs `113-193` · **Size:** medium

Config load, the api-key `case`, the backend `case`, and the logger snapshot are
written twice. Every fix above that touches wiring must therefore be written
twice.

Not worth doing on its own. Do it only if you end up touching wiring for three or
more items, at which point it pays for itself.

---

## 8. Errors and message types

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

## 9. TUI

### F21 — Delete the TUI
**Files:** `tui.rb` (whole file), `boukensha.rb:123,184,242`,
`boukensha_loader.rb:104,114`, `patches/bubbletea/` · **Size:** deletion

The TUI was abandoned upstream in favour of the live viewer that tails the
session jsonl, and its problems were covered on the 2026-07-25 livestream. This
is removal, not repair, so the diagnosis below is kept only as the record of why.

`boukensha` without `--no-tui` died with `Abort trap: 6`: a Go-side fatal error
(`bad sweepgen in refill`, inside `mallocgc`) that took the Ruby process with it.
`bubbletea.bundle` and `lipgloss.bundle` are separate Go c-archives, each
carrying a complete embedded Go runtime, and `mcache` is per-OS-thread, so two
runtimes binding Ms to the same threads corrupt each other's allocator state.
`tui.rb:1-3` already documented an earlier instance of the same class of bug,
which is why it required `bubbletea`/`lipgloss`/`bubbles` rather than `charm`:
that removed a *third* runtime. Two remained.

Deleting the file also removes the `tui:` keyword, the `--no-tui` flag, both
native gem dependencies, and the `patches/bubbletea` directory.

**One aftermath worth remembering:** when the TUI aborted it never restored the
tty, so that terminal tab stayed in raw mode and Enter echoed as `^M`. `stty
sane`, or a new tab.

---

## 10. Logging and transcript

Deliberately thin, because week 2 owns observability. Four cheap things that
make week-2 work easier and don't pre-empt it:

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
- **F35 — the `tool_use_id` is read and then thrown away.** `agent.rb:163` binds
  `use_id = block["id"]` and passes it to `@context.add_message`, but neither
  `@logger.tool_call` nor `@logger.tool_result` receives it. Any consumer that
  needs to pair a result back to its call (`log_viz`, and a map projection
  replaying the jsonl) must do it by position. That is safe *today* only because
  dispatch at `agent.rb:161` is a serial `each`, so the ordering is an
  implementation detail the transcript does not state. Passing the id through is
  one argument in three places and makes the log self-describing.

Explicitly **not** here: elision, summarisation, `world.md`, cross-session
knowledge files, thinking blocks. Those are week 2.

---

## 11. Cheap cleanups

| # | What | Where | Size |
|---|---|---|---|
| F11 | `LoopError` is declared and rescued but **never raised** anywhere | `errors.rb:4`, `repl.rb:135` | delete 2 lines |
| F12 | `turn_count` returns the message count and `to_s` prints it as `turns=` | `context.rb:92,95` | rename to `message_count`, 3 call sites |
| F15 | `DEFAULT_CONTEXT_WINDOW = 32_000` is unreachable — every backend raises on unknown models first | `models.rb:14` | delete, or make `context_window` raise |

**Sources:** F11 = `05_agent_loop.md` divergence #7 · F12 =
`01_struct_skeleton.md` divergence #8.

**On F12's rationale.** An earlier justification for the rename leaned on a
glossary in `CONTEXT.md` that defined **Turn** as one goal driven to a final
answer. That file has since been deliberately deleted, so F12 stands on its own
merits instead: a method named `turn_count` that returns `@messages.size`,
printed by `to_s` as `turns=`, is simply mislabelled.

---

## 12. Direction: world model, decomposition, navigation

Not a defect list. This is the shape the next block of work wants to take,
recorded here because it changes which defects matter and why.

### 12.1 What one session actually cost

Measured from `.boukensha/sessions/20260728T020721Z-11017d94.jsonl`, a real
tbaMUD run on `claude-haiku-4-5` (200k window, `max_turn_tokens` 60,000,
`max_iterations` 25):

| | |
|---|---|
| turns | 24 |
| turns that died exhausting the turn budget | **18** |
| turns that completed | 6 |
| API calls | 110 |
| input tokens | **1,698,189** |
| output tokens | 8,984 |
| input : output ratio | **189 : 1** |
| median input per call | 15,001 |
| largest single call | 26,536 |
| tool calls | 86 |
| of those, `tbamud__move` | 50 |
| of those, `fs__*` | **0** |
| session cost | $0.35 |

Three quarters of all turns died without finishing, most after only 3 to 7
iterations. 1.7M input tokens bought 50 moves: roughly **34,000 input tokens per
step through a doorway**. Almost none of that is the model thinking. It is the
same history and the same 40 tool schemas re-sent on every call.

Three of the defects above are directly measurable in this one file:

- **F23.** 40 tools are advertised, 14 of them `fs__*`, and not one `fs__*` call
  was made in 86 tool calls. At ~2,010 tokens across 110 calls that is ~221,000
  input tokens, **13% of the session's entire input spend**, for a server rooted
  at `/tmp`.
- **F22.** The full schema block is ~4,124 tokens, so ~453,000 tokens, **27% of
  input**, was re-transmitting bytes that never changed.
- **F25.** Every `stop_reason` in the log is `end_turn` or `tool_use`, because
  the backend collapsed the value before the logger saw it. Whether any reply was
  truncated is **not answerable from this transcript**. (The `max_tokens` in
  `turn_end` records is boukensha's own turn budget, not the API's stop reason.)

### 12.2 Two graphs, not one

The temptation is to put everything in the room graph: mark this edge "needs
brass key", mark that room "level 25+". Resist it, or you get a pathfinder that
knows about quests and a quest system that knows about geography.

**The map.** Nodes are rooms, edges are exits. Dense, spatial, stable once
observed, searched constantly.

**The dependency graph.** Nodes are facts and objectives: "hold the brass key",
"level >= 25", "1,000 gold", "the priest is friendly". Edges are *achieves* and
*requires*. Sparse, grows as you learn, searched when deciding what to do next.

They touch at exactly one point: **a map edge is traversable only if certain facts
hold.** The locked door is an edge with a precondition. The angry mob is an edge
whose cost is a function of your level. Keeping the interface that narrow is what
stops the two from contaminating each other.

### 12.3 The pathfinder takes state as a parameter

Don't mutate the graph when you get a key. Annotate edges with predicates and
evaluate them against a state passed in:

```
path(from:, to:, state:)   # skips edges whose preconditions fail in `state`
```

This buys counterfactual queries, and those are how subgoals get *derived*
instead of guessed: "could I reach the crypt if I held the brass key?" If yes,
"get the brass key" is now a subgoal, discovered from the map. The same query
turns a level requirement into a subgoal.

It is also where Dijkstra earns its keep over BFS. With mobs in play the edges
genuinely differ: a plain exit costs 1, a beatable mob costs expected damage plus
time, an unbeatable one is infinite. Uniform-cost search cannot express "go the
long way around the ogre".

### 12.4 Where the model belongs, and where it does not

**Model:** propose decompositions, read prose into facts, resolve genuine
ambiguity, choose between alternatives when the choice is not mechanical.

**Code:** hold the goal stack, evaluate preconditions, run the search, execute
the movement batch, classify failure, remember what has already been tried.

The model is good at world knowledge and bad at bookkeeping. Every piece of state
left in its head is paid for on every subsequent call, and it still gets it wrong.

### 12.5 Failed attempts have to be durable

Big goals decompose N ways and nothing is known in advance, so failure is the
normal case. A goal stack that records only what to do next will retry what just
failed, forever. Each objective needs to carry which alternative it is on, what
has been ruled out, and why, **in the structured store rather than the
transcript**, because the transcript is exactly what gets dropped.

This is also the answer to the context problem. With this shape the map, the
facts and the dead ends live in a store; each subgoal runs in a fresh short
context holding its goal plus the facts relevant to it; the parent gets one line
back. Compaction stops being load-bearing and goes back to being a seatbelt.

### 12.6 What tbaMUD actually hands you

Read out of the same session log. Better than feared in one way, worse in three.

**Exits are enumerated, not inferred.** Every room result carries a literal
`[ Exits: n e s w ]` line. Edges are directly observable, so the map does not
need prose inference to be built. `u` and `d` both appear, so the direction set
is the full six.

**Closed doors are pre-announced in that same line.** A parenthesised direction
means a door that is shut: `[ Exits: n s (w) ]`, `[ Exits: e (s) w ]`,
`[ Exits: (n) (e) s w ]`. Five such observations across the session logs, and the
one time a parenthesised exit was walked, the reply was
`The door seems to be closed.` So an edge can be marked as door-bearing **before**
you ever try it, from the same line that gives you the exit set, and the failure
text on traversal is a distinct, greppable string. That is the cheapest possible
version of §12.9 step 2: no prose inference needed for the common case.

**Free state.** The status prompt is embedded in the output (`25H 100M 80V >`),
so hit points, mana and movement points come for free on every call and can feed
the fact store without a separate `check`.

**Two tools are already the sensors this design needs.** `tbamud__consider` is a
mob-difficulty oracle, which is the edge-weight input for §12.3.
`tbamud__track` is tbaMUD's own tracking skill, worth measuring against a local
search before duplicating it.

**Room name is not a unique key.** "Main Street" appears in this session with
both `[ Exits: n e s w ]` and `[ Exits: n e ]`. At least two distinct rooms share
the name, so identity needs `(name, exit set)` at minimum, and really wants to be
movement-derived.

**Output is interleaved with async events.** One move returned
`The Mayor says 'Good day, citizens!'` *above* the room name. The first line of a
result is not the room. Parsing has to anchor on the exits line or the prompt,
not on position.

**Some rooms cannot be identified at all.** A dark room returns
`It is pitch black...` with no name and no exits. Identity there depends on
movement history or a light source.

No room vnum is exposed anywhere in the transcript, and every line carries ANSI
colour codes that need stripping before parsing.

### 12.7 How the map gets recorded

The atom is the traversal event, `(from, direction, to)`. Everything else is
derived from a sequence of those.

**Identity is dead reckoning, and the name is just an attribute.** A room gets a
UUID on arrival. You were at node X, you moved north, the move succeeded, so the
destination *is* "the node north of X". Correct by construction, needs no
parsing. Two rooms called "Main Street" are simply two UUIDs that happen to share
a `name` field, and no step in this scheme ever considers merging them on that
basis.

**The risk is over-splitting, not over-merging.** Reach the same physical room by
two different routes and you mint two UUIDs for it. The map grows phantom rooms,
loops never close, and search returns paths longer than reality or fails to find
one that exists. That is loop closure, and it is the real problem here.

**Loop closure is a hypothesis you can test, not a guess you have to make.**
Arriving somewhere that matches a known node (same name, same exit set, same
dead-reckoned coordinate) gives you a *candidate*, not a fact. Settle it: pick an
exit whose destination you already recorded for the candidate, walk it, and check
whether you land where predicted. Confirmed, union the two UUIDs and repoint the
edges. Refuted, you now hold positive evidence they are distinct. One move buys
certainty. A freshly-seen room has no known neighbours yet, so early closure is
weak and strengthens as the neighbourhood fills in.

**Coordinates propose, traversal decides.** The graph-paper method works:
`n=+y, s=-y, e=+x, w=-x, u=+z, d=-z` from an origin, which gives a drawable map
for free and makes same-coordinate arrivals a good closure *candidate*. But MUDs
are non-Euclidean, with one-way exits, teleports, and rooms where north then
south does not bring you back. Never let a coordinate collision decide identity
on its own.

**Never auto-create the reverse edge.** A north from A to B does not imply a
south from B to A. Record only the traversal you made and let the reverse be
discovered.

**Two derived tables, projected over logs you already write.**
`.boukensha/sessions/*.jsonl` is already the append-only observation log: it
carries `tool_call{name,args}` and `tool_result{result}` in dispatch order. There
is no third artifact to build.

| artifact | contents | mutability |
|---|---|---|
| rooms | UUID, name, exit set, description hash, flags (dark, shop, guild), dead-reckoned coords | derived, union-mergeable |
| edges | from, direction, to (**may be unknown**), status, evidence seq, last confirmed | derived |

**Frontier edges are the whole point.** `[ Exits: n e s w ]` tells you a room has
four exits *before* you have walked any of them, so every visited room
contributes unvisited edges. Recording an edge with `to = unknown` turns "find
location X" from wandering into a search with a real frontier, and gives you
"nearest unexplored exit" for free. Without it, exploration has no plan and you
are back to the 189:1 ratio.

**Two navigation modes, and the destination decides which.** If the destination
is a known node, search the graph. If it is not, you are expanding the boundary,
and the right choice is the unexplored exit that is cheapest to reach *from where
you are now*, which is a search to the nearest frontier edge rather than an
arbitrary pick. That is what stops exploration ping-ponging across the map.

**Searching backwards from a hub is worth doing deliberately.** For destinations
you return to constantly (temple, shop, guild), run one single-source shortest
path *from* the destination over reversed edges and keep the resulting distance
field. Navigation then becomes greedy descent: from any room, step to the
neighbour with the lower number. No search per move, and the field survives until
the map changes.

**Edge status is where §12.9 step 2 lives.** `open` / `locked` /
`blocked_by_mob` / `one_way_suspected` / `unknown`, each carrying the observation
sequence that established it. That is what lets the search route around the ogre,
and what lets you audit why it did.

**Execution needs verification, not faith.** A path is a direction sequence, and
each step should confirm that arrival matches the expected node. On mismatch,
stop and re-localize rather than continuing blind. A map-follower that assumes
its own moves worked is F34 all over again, one layer up.

**Build it as a replay first.** The projection should be a pure function from a
session jsonl to those two tables. That means it can be written and tested
against the ten session files already on disk, which contain 50 real moves
complete with ANSI codes, the interleaved Mayor broadcast, and the pitch-black
room, with no MUD running and no tokens spent. Harden the parser on recorded
data, then feed the live stream through the same entry point. It is also the
cheapest possible proof that the map idea works at all.

One caveat on replay, verified in `agent.rb:161-176`: dispatch is a serial
`each`, so `tool_call` and `tool_result` records strictly alternate and pair
positionally. That held for all 86 pairs in this session. But the logger never
writes the `tool_use_id` it already has in hand, so the pairing is an artifact of
serial dispatch rather than something the transcript states. See F35.

### 12.8 Why F34 stops being a cost fix and becomes the sensor

Room identity will be movement-derived: you were at A, you moved north, so this
is the room north of A. That holds exactly as long as failed moves are
distinguishable from successful ones.

They are not. In this session **all 86 tool results logged `ok: true, error:
null`**, including all 50 moves. A failure returns `isError: true`, which
`tools/mcp.rb:61` flattens into a string shaped like ordinary game prose and
`agent.rb:169` records as a success. One swallowed failure and the agent files
the *current* room's description under the *next* node, and every room observed
after that is recorded at the wrong place. The corruption is silent, permanent,
and written to the store.

The same flag is the best available signal for annotating blocked edges: "the
door is locked" and "you can't go that way" are precisely the failures that
should become edge predicates. Today they are indistinguishable from a dead
subprocess.

**Now confirmed with a real failure in hand.** Session
`20260730T030227Z-82215bf4.jsonl` contains an actual blocked move: the reply was
`The door seems to be closed.` and the room's exit line had flagged it in advance
as `[ Exits: n s (w) ]`. **All 79 tool results in that session still logged
`ok: true, error: null`**, the failed move included. So this is no longer a
predicted failure mode. A move that did not happen was recorded as one that did,
in a log on disk.

What that buys for the fact extractor: the common blocked case needs no prose
inference at all, because the parenthesis convention (§12.6) marks it before you
attempt it and the failure string is distinct. Still open is the *rest* of the
taxonomy: no sample of "you can't go that way" or of a mob blocking a move exists
yet in any session, so whether those are equally greppable is unverified.

### 12.9 Build order

Smallest thing that gets most of the value:

1. **Map plus search over observed rooms.** No predicates, no weights. "Take me
   to a room I have seen." This alone kills the wander-and-re-`look` loop that
   produced the 189:1 ratio in §12.1.
2. **Edge annotations learned from failure.** Try north, get "the door is
   locked", mark the edge. The pathfinder routes around it with no planner
   involved. Requires F34 first.
3. **A fact store** (level, inventory, gold, HP from the prompt line) and edge
   predicates referencing it. Weights and counterfactual queries turn on here.
4. **Goal decomposition** over the dependency graph.

Steps 1 and 2 are most of the win and need no planner. Whether step 4 is needed
at all, or whether a good map plus learned obstacles plus a human-supplied
ordering of the big objectives is enough, is worth deciding after step 3 rather
than before step 1.

### 12.10 What this does to the fix list

| defect | was | becomes | why |
|---|---|---|---|
| **F34** | §1.1 broken | **blocker** for the map | it is the only sensor that can tell a failed move from a successful one, and identity is movement-derived |
| **F4** | §1.1 broken | **blocker** for the map | same door, infrastructure side |
| **F25** | §1.1 broken | **blocker** for the planner, not the map | a truncated reply drops `tool_use` blocks, so an intended move is never dispatched and the turn is still logged `completed`. That is lost work plus a false completion, not a phantom observation: nothing corrupt reaches the map, but a decomposition layer that trusts "completed" marks a subgoal done that never ran |
| **F23** | §1.2 tokens | **do it now** | measured at 13% of session input for zero calls |
| **F22** | §1.2 tokens | **do it now** | measured at 27% of session input, survives any architecture change |
| **F29** | §1.4 structural | **scheduled** | a local pathfinding tool is the second tool source the entry says would make it matter |
| **F33/F2** | §1.1 broken | fix the seatbelt | still worth doing, no longer the headline; decomposition is what fixes context |
| **F18** | §1.3 cheap | more valuable | the jsonl is now the only window into a run |

---

## 13. Not worth doing

- **F16** unless you actually switch to Ollama or OpenAI.
- **F17** as a standalone task — do it only if you end up touching wiring for
  three or more of the above, at which point it pays for itself.
- Anything about the week-2 tree beyond §16 — it is `week2_capable/`,
  seeded but not yet worked.
- **Splitting `tool_result` blocks.** `backends/anthropic.rb:44` emits one `user`
  message per `tool_result`, so the smoke run's 3 parallel calls became 3
  separate user messages. Anthropic's guidance is to return them in a single user
  message; splitting them nudges the model away from parallel tool use over time.
  But it demonstrably works today, so this is a "someday", not a fix.

**Explicitly cut, and to stay cut:**

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

## 14. Ordering constraints

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
| F34 (structured MCP errors) | F4 (propagate infrastructure failures) | F4 alone closes the dead-process door and reads as "handled", while a live server reporting `isError` still arrives as prose the model retries around — the same wrong answer for money, now with false confidence that it was fixed |

F25 stands alone and is worth doing at any output ceiling.

---

## 15. Test seams — not yet agreed

The suite is real (36 runs / 111 assertions / 0 failures), so pinning
behaviour before changing it is cheap.

Three seams are already realized, and are worth reading as the pattern for the
rest: `Context#compact_messages!` (`test_context_compaction.rb`), `Tools::Mcp`
schema pass-through and backend `#to_tools` (`test_tools_mcp.rb`), and
`Logger#prompt` (`test_logger_prompt.rb`). Still open:

1. `Agent#handle_tool_calls` — needs a registry double that raises. The seam for
   F4, and the only one here that isn't a pure function. For F34 the same seam
   needs a double that *returns* rather than raises, asserting the logger is
   called with `ok: false`.
2. `Tools::Mcp`'s registered block — feed it a recorded `tools/call` response
   with `isError: true` and assert the failure survives as structure, not as a
   `"error: "` prefix. `test_tools_mcp.rb` already exists and pins schema
   pass-through, so this is a third case in a file that is already there.
3. `Backends::*#parse_response` — provider response in, normalized shape out.
   The seam for F25; feed it a recorded `stop_reason: "max_tokens"` body.
4. `Backends::*#to_payload` — the seam for F24; assert `options.num_ctx` and
   `options.num_predict` are present and sourced from one place.
5. `Config#load_settings` — the seam for F10; a temp dir with `settings.yml`,
   and a `BOUKENSHA_DIR` pointing nowhere.

Expected values come from an independent source — the MCP server's published
schema, `log_viz`'s parser, the Anthropic docs — never from the code under test.

---

## 16. Sequencing into week 2

Agreed 2026-07-29. Three epics, each a numbered directory under the week-2 tree,
following the week-1 convention where each numbered rung is a self-contained
snapshot rather than a shared library.

**Note on numbering.** Epic directories are written with their full name
(`13_key_fixes`) throughout, because bare "13" would collide with this
document's own §13.

### 16.1 `13_key_fixes` — make the sensor trustworthy

Six items. Five are small; one is a real design decision.

| item | why it is here |
|---|---|
| **F34** | the blocker. Dead reckoning is only valid if a failed move is distinguishable from a successful one, and today it is not. Proven on disk: session `20260730T030227Z` logged a real `The door seems to be closed.` as `ok: true, error: null` |
| **F4** | the infrastructure side of the same door. A dead `mud-manager` must not arrive as an ordinary game response, or edges get annotated from a crashed subprocess |
| **F25** | planner prerequisite, not a map one (§12.10). Cheap, same area, and it stops a truncated reply being reported as a completed turn |
| **F35** | the map projection replays the session jsonl, and today call/result pairing works only by accident of serial dispatch |
| **F23** | one line. 13% of session input for zero calls, and the schema budget is wanted for map tools |
| **F5** | one word, and without it the dev loop is silent |

The one genuine decision inside this epic is what shape a structured MCP result
takes, since F34 explicitly leaves "should a server-reported error raise?"
unsettled (§4).

### 16.2 `14_improved_navigation` — the map

§12.2 through §12.9. Build order is §12.9: observed-room graph and search first,
then failure-learned edge annotations, then the fact store and weights, then
decomposition only if it proves necessary.

**This epic starts before `13_key_fixes` finishes.** The map projection is a pure
function from session jsonl to the rooms and edges tables, so step 1 can be
written and tested against the eleven session files already on disk, which carry
129 moves complete with ANSI codes, an interleaved NPC broadcast, a pitch-black
room, five parenthesised-door exit lines and one real closed-door failure. That
corpus needs no fixes, no MUD, and no tokens. Only the *live* loop depends on
F34 and F4.

**`week0_explore/circlemud-world-parser/` is the test oracle, not the map.** It
parses CircleMUD and DikuMUD world files into JSON, which means tbaMUD's true
room graph (vnums, names, exits) is obtainable offline. Loading it as the map
would defeat the point, since the goal is discovery through play. Using it to
*verify* a discovered map is exactly the independent source §15 asks for: it
answers "did dead reckoning actually produce the real topology?" objectively
rather than by inspection. It is Python, but it emits JSON, so it runs once to
produce a fixture and nothing Python enters the Ruby runtime path.

### 16.3 `15_context_economy` — pay less per call

F9, then F22, then F6 to keep caching viable once `fs` is gone (§13's ordering
chain), plus F33 and F2 for the compaction seatbelt.

**Deliberately after navigation**, despite the 189:1 input-to-output ratio in
§12.1. The map is the structural fix and caching is a multiplier on it; F23 lands
in `13_key_fixes` anyway, which captures the cheapest 13% immediately. The
F9 → F22 → F6/F23 ordering chain is fiddly enough that it should not sit in front
of the thing actually being built.

### 16.4 Directory layout

**A component gets a subdirectory only when we already know that epic changes
it.** Never speculatively, never "it might need it later". Copy it in at the
moment the first real change is required.

By that rule, `13_key_fixes` is one directory:

```
week2_capable/ruby/          # rename to week2_observability is Scott's to make
  13_key_fixes/
    boukensha/          # copied from week1_baseline/ruby/12_context (308K)
```

All six items in §16.1 are boukensha-side. Nothing else is known to change:

- **`mud_manager/`** stays where it is. F34 is fixed entirely in `tools/mcp.rb`
  and `agent.rb`; the server already reports `isError: true` correctly, and the
  exits line and door parentheses are already in its output.
- **`log_viz/`** stays where it is. Emitting a truthful `ok: false` makes the
  existing viewer render correctly with no change on its side, and nothing
  requires it to consume F35's `tool_use_id`.
- **`circlemud-world-parser/`** is never copied and never modified. It is read
  in place, run once to emit a JSON fixture, and used only as the verification
  oracle described in §16.2.

Later epics get their `boukensha/` copied forward from the previous rung, and
any further component directories only when the same rule is met.

---

## 17. Landed in `13_key_fixes`

Applied 2026-07-30 to `week2_capable/ruby/13_key_fixes/boukensha`. Suite before:
36 runs / 111 assertions. After: **60 runs / 173 assertions / 0 failures / 0
skips**, in 10s.

| item | what changed | where |
|---|---|---|
| **F34** | `Tools::Mcp`'s block returns a `ToolResult` carrying the server's `isError` flag instead of folding it into an `"error: "` prefix. `Registry#dispatch` now returns a `ToolResult` for *every* tool, wrapping a local block's String, so nothing downstream type-tests. `agent.rb` logs `ok: !result.error?`. | `tool_result.rb` (new), `tools/mcp.rb`, `registry.rb`, `agent.rb`, `logger.rb` |
| **F35** | `tool_use_id` passed to `@logger.tool_call` and `@logger.tool_result`, so the transcript pairs a result to its call by id rather than by position. | `agent.rb`, `logger.rb` |
| **F4** | the rescue narrowed from `StandardError` to `UnknownToolError, ArgumentError`. The model's own mistakes still come back as failed results; anything else propagates. | `agent.rb` |
| **F25** | `parse_response` gained `raw_stop_reason` and a third normalized value, `max_tokens`. `Agent#run` ends such a turn as `max_output_tokens`, not `completed`, and logs the provider's own word. | `backends/base.rb`, `backends/*.rb` (5), `agent.rb` |
| **F23** | the `filesystem` MCP server commented out, with the reason recorded inline. ~2,010 tokens per call, 13% of session input, for zero calls. | `.boukensha/settings.yaml` |
| **F5** | `puts Boukensha.run(...)`, plus the missing `week2_capable/bin/ruby/13_key_fixes` launcher. | `examples/example.rb`, `week2_capable/bin/ruby/13_key_fixes` |

Covered by `test/test_mcp_tool_failures.rb` (new, 13 cases) and
`test/test_stop_reason.rb` (new, 10 cases).

### 17.1 Found while doing it, not on any list

- **The test harness was skipping 15 of its own tests.** `test/helper.rb` located
  `mud_manager` with a fixed `../../../..`, which no longer reaches the repo root
  now that the tree sits one level deeper (the extra `boukensha/`). It `skip`s
  when it can't find it, so the suite reported green at 60 assertions instead of
  111 and nothing said otherwise. Now walks up looking for `week0_explore`.
- **The tree was still Step 12 everywhere.** `VERSION`, the built `.gem`,
  `Gemfile.lock`, the README heading and its `BOUKENSHA_PATH` examples. Bumped to
  `0.13.0` to match the rung, as every step from `08` onward does.

### 17.2 Corrections to §16.1

Both found by measuring rather than reading, and both change what F34 is for.

- **§16.1's stated proof does not hold.** It justifies F34 with *"session
  `20260730T030227Z` logged a real `The door seems to be closed.` as `ok: true,
  error: null`."* The log line is real, but `mcp/server.rb:104` sets
  `isError: true` only for a rescued `ProtocolError`. A closed door is an
  ordinary command round-trip, so mud-manager returns `isError: false`, correctly.
  **F34 does not change that line.** Telling a refused move from a successful one
  is game-text parsing, and belongs to `14_improved_navigation`.
- **`isError` does not conflate the two cases the journal assumed it did.** It
  covers only `connection_error`, `timeout`, `login_error`, `not_configured`,
  `argument_error` and `unknown_tool`, and embeds the code in the text as
  `error [code]: message`. That splits cleanly along ADR 0010's line, so F4's
  routing question had an answer all along. What F34 actually buys is a truthful
  `ok` flag; the model already received the full failure text and could recover
  from it unaided.

### 17.3 Bottom of the list

- **A MUD that stops responding mid-session is never flagged.**
  `mud_manager/lib/mud_manager/session.rb:163-166` rescues `Timeout` inside
  `read_until_prompt` and returns the drained (empty) buffer, so
  `SessionPool#with_reconnect` never sees an exception and `isError` stays false.
  The call takes 10s, returns `""`, and logs `ok: true`, indefinitely. This is
  the failure F4 describes, arriving through a door neither F4 nor F34 watches,
  and the fix is in `mud-manager`, not boukensha. Judged unlikely enough to sit
  here rather than in the epic; pinning it costs ~20s of suite time against a
  hardcoded 10.0s timeout, so it is deliberately **not** covered by a test.
  Note that the *other* dead-MUD path, where no session exists yet and the
  connect is refused, is already reported correctly as `connection_error`.
