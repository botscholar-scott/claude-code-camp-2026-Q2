# `12_context` — what the uncommitted changes fix

**Target:** `week1_baseline/ruby/12_context`
**Status:** staged, not committed · suite: 36 runs, 0 failures

---

## Tool schemas

`tool.rb` · `tools/mcp.rb` · `registry.rb` · `run_dsl.rb` · `backends/*.rb` (5)

- Optional parameters were advertised as required, because backends re-derived `required` from every property name. Affected 16 of mud-manager's 42 parameters.
- `enum` constraints were flattened into prose inside the description, so the API could not enforce them. Affected 14 parameters.
- `default` values were discarded entirely during schema translation. Affected 5 parameters.
- Zero-argument tools were uncallable as documented: `look` says "call with NO arguments" while demanding every parameter.
- `Tool` had no `required` member. It now holds the server's JSON Schema verbatim, with `#properties` and `#required` as readers over it.
- `Tools::Mcp.to_boukensha_params` became `normalize_schema`, which substitutes an empty schema only when a server omits `inputSchema` entirely.
- Tools registered with no parameters now get `EMPTY_SCHEMA` (`{"type":"object","properties":{}}`), since every provider requires an object schema.
- All five backends now pass the schema straight into their own envelope instead of rebuilding it. Ollama and Gemini included, identically.

## Compaction

`context.rb`

- The cut was by message count, landing mid-`tool_use`/`tool_result` pair and leaving an orphaned result that the API rejects with an opaque 400.
- A cut landing on an assistant message left a history not starting with a user message, which the API also rejects.
- Both are fixed by one rule: advance the cut forward to the first real `:user` message at or after the target.
- `current_tokens` was zeroed even when nothing was dropped, so the next `needs_compaction?` read 0% usage on an untouched history.

## Logging

`logger.rb`

- The `prompt` event serialized the whole message history every iteration — O(n) per iteration, O(n²) per turn. Now logs the newest message only.
- Full history is still available behind `BOUKENSHA_DEBUG`, and `message_count` continues to report the true history length.
- Avoided `Kernel#Array` on `Message`, which is a Struct and would splat into its own members rather than wrapping.

## Tests

- `test_context_compaction.rb` — 7 cases pinning cut safety, the no-op path, and `current_tokens` handling against the Messages API contract.
- `test_logger_prompt.rb` — 5 cases pinning newest-message-only logging, the `BOUKENSHA_DEBUG` fallback, and `message_count`.
- `test_tools_mcp.rb` — 3 cases: schema carried verbatim, optional parameters not marked required, zero-argument tools get an empty object schema.

## Docs

- `docs/adr/0012-boukensha-is-an-mcp-host.md` added, recording that boukensha ships no tools and sources every one from an MCP server.

---

## Explicitly not fixed by these changes

- Compaction still drops nothing in a one-shot `Boukensha.run` — no `:user` message exists after index 0 for the cut to find. See F33.
- Compaction is still checked once per turn, before the loop, rather than each iteration. See F2. `agent.rb` is untouched.
- Infrastructure failures are still returned to the model as ordinary tool results. See F4.
