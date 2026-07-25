# 0006 — The port ships only the Anthropic backend, and keeps the seam

**Status:** accepted
**Date:** 2026-07-25
**Applies to:** `week1_baseline/python/03_prompt_builder` and later steps

## Context

Step 03 introduces the **Backend** — the provider-specific half of an API call.
The Ruby ships five of them (Anthropic, OpenAI, Gemini, Ollama, OllamaCloud) and
its README opens with the case for provider independence.

The ladder does not sustain that case.

**The step-12 model table has three entries, all Claude.** By the last step, the
table the agent actually consults for compaction thresholds is:

```ruby
# week1_baseline/ruby/12_context/lib/boukensha/models.rb
TABLE = {
  "claude-opus-4-8"   => { context_window: 1_000_000, … },
  "claude-sonnet-4-6" => { context_window:   200_000, … },
  "claude-haiku-4-5"  => { context_window:   200_000, … }
}
```

No OpenAI model, no Gemini model, no Ollama model.

**The Gemini backend is decaying in place.** At step 12,
`12_context/lib/boukensha/backends/gemini.rb` has three of its five model entries
commented out — and the one live replacement is commented out too.

**The fixture is Anthropic.** This repo's own `.boukensha/settings.yaml` is
`provider: anthropic`, and it is the only settings file in the tree.

So the author ships five backends at step 03 and is effectively down to one by
step 12.

The user-side reason is plainer still: four of the five providers will never be
run against this tree. Porting them ships four untested code paths, four model
tables that will rot exactly as Gemini's already has, and four sets of
serialization quirks nobody here can verify. That is not provider independence;
it is four liabilities wearing its clothes.

There is also a concrete defect that only multi-backend makes possible.
`PromptBuilder#to_messages` calls the backend with one argument:

```ruby
def to_messages
  @backend.to_messages(@context.messages)
end
```

Anthropic and Gemini define `to_messages(messages)`. OpenAI, Ollama and
OllamaCloud define `to_messages(system, messages)` — they prepend the system
message themselves. So `builder.to_messages` raises `ArgumentError` on **three of
the five backends**, from step 03 through step 12, while sitting in the README's
public API table. It is never caught because it is never called: `grep` across
all twelve steps finds zero callers of `PromptBuilder#to_messages` or `#to_tools`;
`Client` uses only `to_api_payload`, `headers` and `url`.

## Decision

**Ship the Anthropic backend only. Keep the seam.**

1. `boukensha/backends/base.py` defines the contract: a `Backend` ABC with
   `to_messages`, `to_tools`, `to_payload`, `headers` and `url` abstract, plus the
   model-table machinery (`MODELS`, `model_info`, `context_window`, the two cost
   accessors, `estimate_cost`).
2. `boukensha/backends/anthropic.py` is the single implementation.
3. `backend_for(task)` maps provider→class from a one-row dict and rejects
   anything else by name with `UnsupportedProviderError`.

Adding OpenAI in week 2 costs **one new file and one row in `_BACKENDS`**.
Nothing else moves.

The ABC is not speculative. All five Ruby reference implementations were read
during design and the contract was validated against them — that is how the
`to_messages` signature split above was found, and how the Gemini/Ollama
tool-result mismatch in Consequences was found. They were read and then
deliberately not ported.

**Rejected: no abstraction at all.** One concrete `AnthropicBackend`, no ABC, no
factory — the purest YAGNI reading. Rejected because the seam is about thirty
lines and its absence puts provider→class knowledge at the call site, which is
exactly where the Ruby put it and exactly why it ended up copied into seven
files (the example, steps 04 and 05, and `lib/boukensha.rb` at steps 07, 09, 10,
11 and 12 — with a *second* case statement beside it at step 12 mapping provider
to environment variable).

**Rejected: Anthropic + OpenAI**, on the grounds that two implementations are
what actually proves an abstraction. Genuinely tempting, and the strongest
argument against this decision. Rejected on two counts: the second backend would
be unrunnable here, so it would be an abstraction proven by code nobody executes;
and it would reintroduce the `to_messages(system, messages)` signature split that
one backend dissolves. A second backend added in week 2 against a real need will
prove the shape better than one added now against a hypothetical.

## Consequences

- **The `to_messages` inconsistency is not inherited.** One backend, one
  signature: `to_messages(context)`. The latent `ArgumentError` cannot occur.
- **Both "dead" methods get a caller.** `to_messages()` and `to_tools()` are
  printed by the example, which is the clearest demonstration of what the step
  does, and gives them their first caller anywhere in the ladder.
- **`estimate_cost` loses its `None` branch.** Ruby guards with
  `return nil unless input_token_cost_per_million && output_token_cost_per_million`
  because Ollama Cloud's pricing is plan-based and its rows carry
  `cost_per_million: { input: nil, output: nil }`. Every Anthropic price is known,
  so the return type is `float`, and step 06's logger never has to handle a null
  cost.
- **`usage_level` is not ported.** Ollama Cloud's alone; it returns with that
  backend.
- **`usage_unit` becomes a class attribute.** It is `:tokens` on every Anthropic
  row in the Ruby, because it describes the provider rather than the model.
- **`advertised_context_window` is not ported.** Set on `minimax-m3:cloud` only,
  and read by nothing in twelve steps.
- **Adding a backend is additive**, and so is tightening the ABC when it happens.
  `MODELS` is a declared `ClassVar` with no `__init_subclass__` enforcement; with
  one subclass that guard protects against a mistake nobody can currently make,
  and it is a four-line change when the second backend lands.
- **Recorded for whoever ports the rest:** Gemini's `functionResponse.name` and
  Ollama's `tool_name` are both handed `msg.tool_use_id`, but both APIs match a
  result to its call by **function name** — the Ruby's `"toolu_01X"` would match
  nothing. Ollama and OllamaCloud also drop `max_output_tokens` entirely (no
  `options.num_predict`), so the limit is silently ignored on those providers.
  Both are bugs waiting in the unported code; neither is inherited.

## Verification

There is no test suite at this step (the example is the safety net), so the
hand-checks were run and their real output recorded here:

```
unknown model        UnsupportedModelError: AnthropicBackend does not support model 'claude-opus-9'.
                     Supported models: claude-fable-5, claude-haiku-4-5, claude-haiku-4-5-20251001,
                     claude-opus-4-8, claude-opus-5, claude-sonnet-4-6, claude-sonnet-5
unknown provider     UnsupportedProviderError: unsupported provider 'openai' for task 'player'.
                     Supported providers: anthropic
both one family      isinstance(UnsupportedModelError("x"),    BoukenshaError)  -> True
                     isinstance(UnsupportedProviderError("x"), BoukenshaError)  -> True
estimate_cost        backend.estimate_cost(input_tokens=1_000_000, output_tokens=1_000_000) -> 6.0   (a float, not None)
USAGE_UNIT           <UsageUnit.TOKENS: 'tokens'>              — a class attribute, not a model row
payload keys         ['model', 'system', 'max_tokens', 'tools', 'messages']
tools={}             PromptBuilder(ctx, backend, tools={}).to_api_payload()["tools"] -> []
                     — step 05's wrap_up, with no `tools.nil? ?` ternary anywhere
```

The example payload matches the Ruby's byte for byte except `max_tokens` (16000
against 1024, divergence row 13): same five keys in the same order, same three
messages, same `tool_use_id: "toolu_01X"` on the `tool_result` block, `look` at
`"required": []` and `move` at `"required": ["direction"]`. Both scripts exit 0.

And the step is still self-contained, the check ADR 0002 established:

```
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/03_prompt_builder
ValueError: tasks.player is missing from settings.yaml
```
