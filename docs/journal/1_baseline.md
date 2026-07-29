# Week 1: Baseline

## Technical Goal

Port the Ruby boukensha agent to Python and carry **Python** forward as the real implementation into week 2.
The motivation was not language preference. Andrew's own Ruby flags limitations it deliberately declines to fix. `week1_baseline/ruby/00_config/README.md` ends with a "Considerations" section listing them outright (prompts should be scoped per task; the settings loader should accept `.yml` as well as `.yaml`).
Definitely wondering if leaving the defect in place was one of the lessons? So the plan was to port, fix the known limitations on the way through, and end week 1 with a cleaner base than the one I started from.

## Technical Uncertainty

- Would a step-by-step port stay tractable, or would each rung's fixes compound into a tree that no longer tracked upstream?
- The Ruby ladder is 13 rungs (`00_config` → `12_context`). Could I actually finish?
- How much of the surrounding stack is Ruby, and does that matter? At the start I assumed it didn't as MCP is language-agnostic, so a Python host talking to a Ruby MCP server should be fine.

## Technical Hypotheses

Recorded as ADRs *before* the code, which turned out to be useful.

1. **A port surfaces bugs a read-through misses.** Translating forced me to answer questions while reading lets me skip. I expected to find defects.
2. **Running ahead of the ladder is safe.** ADR 0002 states this as a decision: *"The Python tree is a deliverable that gets significantly extended in week 2, so carrying a known defect forward on purpose buys nothing."* It also predicts the consequence, *"The Python port runs **ahead** of the Ruby ladder"* and treats that gap as a feature to be documented, not a risk to be managed.
3. **Divergence is bounded.** I assumed the number of places Python would differ from Ruby would stay small and stable per step.
Hypothesis 3 is the one that was wrong, and it is what killed the port.

## Technical Observations

### What worked

- **The port ran.** Steps `00_config` through `05_agent_loop` were ported and executed. 6,151 lines of Python. `05_agent_loop` does a real agentic loop against Anthropic with tool calls.
- **Porting found real bugs, exactly as hypothesized.** Across six steps the divergence tables record **84 rows**: 13 / 14 / 12 / 18 / 17 / 10. Critically, these are not all idiom choices. The `04_api_client` plan says so in its own words: *"most rows are **Ruby reliability defects**, not Python-idiom choices."* The retry loop alone was wrong several ways; 529 not retryable, `Retry-After` ignored, no timeouts set, and read timeouts *retried* (worst case four billed generations for one logical call).
- **Plans, not code, were the real output.** 4,783 lines of porting plans against 6,151 lines of Python. Every step has an "Upstream findings" section written before implementation.
- **The findings landed in Ruby.** Commit `fd4d7d2`, *"12_context fixes found by the python port"*: tool schemas (16 of 42 parameters wrongly marked required, 14 `enum` constraints flattened to prose, 5 `default` values discarded), compaction cutting mid-`tool_use`/`tool_result` pair for an opaque 400, and an O(n²) logger. Plus three test files where there had been none. Suite now runs 36 tests / 111 assertions / 0 failures.

### What didn't work

- **The divergence tables grew instead of converging.** Each step's table opens with "Steps 00–NN's divergences all still apply", they are *cumulative*. By `03_prompt_builder` and `04_api_client` I was adding 18 and 17 new rows per rung. Every row is a decision that has to be re-justified the moment upstream moves.
- **The stack underneath stayed Ruby.** By `12_context` the architecture had changed: boukensha ships no tools of its own and sources all of them from an MCP server (ADR 0012). That server is `mud-manager` still in Ruby. So a Python `12_context` meant a Ruby MCP server, a Ruby MudManager, and one Python island in the middle carrying 84 accumulated divergences.
- **The port stopped at 05 of 12.** Not because 06 was hard, but because when I tried to port 6-12 onto what I had with 05 in python (combined with my fairly significant pythonic deviations and structural improvements) the writing was on the wall and this was going to take another week or two.

### Unexpected

- **ADR 0012 is written for a directory that does not exist.** Its header says *Applies to: `week1_baseline/python/12_context`*. There is no such directory. That ADR is where the decision to stop actually happened. I wrote the architecture note for the Python target and then never built it.
- **The gap ADR 0002 predicted became the failure mode, not the feature.** It says the port running ahead should not "later be mistaken for a bug or a missed port." What it did not anticipate is that running ahead in *both* directions both more Pythonic *and* fixing discovered defects is what made the two trees irreconcilable. Being ahead was fine; being ahead along two axes at once was not.
- **Arguments are converted twice for no reason, and the conversions cancel.** Tracing one tool call end to end: Anthropic returns `tool_use.input` as a JSON object, which arrives as a string-keyed Hash (`agent.rb:164`). `Registry#dispatch` then splats it to kwargs via `args.transform_keys(&:to_sym)` (`registry.rb:24`). The MCP tool block's very first act is `kwargs.transform_keys(&:to_s)` (`mcp.rb:60`), which turns every key straight back into a string before `JSON.generate` puts it on the wire (`client.rb:104`). The comment in `mcp.rb` states the problem without noticing it is self-inflicted: *"Boukensha hands us symbol-keyed kwargs; the server wants strings."* So the path is JSON → string keys → symbol keys → string keys → JSON, with two full key rewrites per call that undo each other.
- **The return path loses structure the same way, and that one actually costs something.** MCP replies with `content` as a typed array of blocks; `client.rb:42` flattens it to a single string with `.map { |c| c["text"] }.compact.join("\n")`. Then the `isError` boolean is folded into that string as prose: `result[:error] ? "error: #{result[:text]}" : result[:text]` (`mcp.rb:61`). Finally `agent.rb:175` calls `.to_s` on it once more. So failure reaches the loop as prose, through **two independent sites with two different prefixes**: `agent.rb:170` stringifies rescued exceptions as `"ERROR: ..."`, and `mcp.rb:61` stringifies MCP's `isError` flag as `"error: ..."`. Only the first is written down. It is F4, and F4's fix (catch the model's own mistakes, let the rest propagate) does work there, because a dead subprocess raises on the broken pipe. The second had **not** been written down anywhere, and F4's fix cannot reach it: `isError: true` is a *successful* JSON-RPC response, so it never raises and sails past every rescue. A live `mud-manager` whose telnet socket has dropped therefore returns a string indistinguishable from `"error: you can't go that way"`. F4's exact failure mode through a door F4 does not watch. I have since written this up as **F34** in `docs/plans/ruby/12_context_fixes.md`, with an ordering constraint saying to do it *before* F4: F4 alone closes one door and reads as "handled."
- **Chasing that one turned up a worse one: the transcript lies.** Because `dispatch` returns normally on an `isError` result, `agent.rb:169` takes the `ok: true` branch, so a failed tool call is recorded in `.boukensha/sessions/*.jsonl` as a success. `log_viz` reads that flag straight through (`log_viz/lib/log_viz/session.rb:133` → `tool_ok`) and renders it green. This is the one that actually changes my week-2 plan. My conclusion from the session logs was "the agent wanders" but I was reading a transcript that cannot distinguish a move that failed from a move that worked. Some unknown share of those 50 `move` calls may be retries of failures the log reported as successes. I no longer fully trust my own primary evidence, and fixing the instrument now outranks acting on what it told me. The lost type information is the bug; the wasted cycles are incidental.
- **Python did not have this problem, which is how I found it.** Python kwargs are already strings, so the port's `tool.handler(**args)` needed no coercion at all (step 01 divergence #14, step 02 #9). The entire symbol/string dance is a Ruby artifact with no analogue. And step 05 divergence #1 replaced the raw hash arrays with typed `TextBlock` / `ToolUseBlock`, *"one vocabulary for both directions."* Neither fix has been applied to Ruby.
- **Fixes stranded on the Python side.** ADR 0010 (infrastructure failures must not be handed to the model as ordinary tool results) was written for the port and never reached Ruby and it is now logged as F4. ADR 0002's `.yml` fix likewise never reached Ruby it is now F10. The port found them; the Ruby still has them.
- **Ruby, once fixed, works.** `12_context` connects, logs in, discovers 26 tools over MCP, makes 3 parallel tool calls, and answers in 11,393 tokens.
- **The remaining problem is budget, not the loop.** A 24-turn session (`.boukensha/sessions/20260728T020721Z-11017d94.jsonl`) made 86 tool calls, of which **50 were `move`**. 18 of 24 turns ended on `max_tokens` a 60,000 turn budget overshot to 62k–80k. The agent is not hitting a tool-call safety cap; it is spending its entire budget walking in circles.

## Technical Conclusions

- **Abandoning the port was correct, and it was not a sunk cost.** The port's actual product was the defect catalogue, and that shipped into Ruby as `fd4d7d2` and as the 40-item menu in `docs/plans/ruby/12_context_fixes.md`. What I stopped paying for was maintenance on a second ladder that was 7 rungs behind and diverging faster than I could close the gap.
- **The mistake was pursuing two goals in one artifact.** "Be more Pythonic" and "fix defects we discover" are both defensible. Together in a port that must also track a moving upstream, they guarantee drift. If I do this again, I port *straight* and log fixes separately where the fix list is the valuable output and it does not need a second implementation to live in.
- **Language choice follows the stack, not preference.** MCP being language-agnostic is true and irrelevant. When MudManager, the MCP server, and 12 of 13 ladder rungs are Ruby, the honest question is not "can Python talk to this?" but "what does one Python island buy?" The answer was: nothing that the fix list didn't already deliver.
- **No layer owns the wire vocabulary, so every layer re-encodes.** The argument round-trip and the flattened tool result are the same defect seen twice: the boundary between the agent, the registry, and the MCP client was never given an agreed shape, so each side defensively converts to what it prefers. The cheap half (symbol/string churn) is harmless; the expensive half (collapsing typed results to a string) is what makes F4 unfixable without touching it first. Fix the type, and the efficiency comes along for free.
- **Week 2 is Ruby, and the problem is memory, not plumbing.** The loop works. The failure is 50 `move` calls burning a token budget with no world model, no map, and no memory across turns. We need graphs of locations and edges to use Dijkstra's algorithm for path finding. We need to really manage that context and see if there are ways to build some structured "recall" of various memories.

## Remaining Questions

- The 40-item fix list is a menu, not a plan. Which items actually unblock week 2 versus which are correctness debt I can carry? F33 (pin the goal, cut the middle) and F9 (count cached tokens for window pressure) look load-bearing.
- Is the token overshoot a compaction bug or genuinely too much to say? Turns exceed a 60k budget by 2k–20k, which suggests the check fires too late and F2 has compaction checked once per turn rather than per iteration.
- The TUI aborts the process with two Go runtimes in one address space (F21). The diagnosis is strongly indicated but unproven, and `--no-tui` works so is a live view of tool calls worth the fix, or is `log_viz` enough?
- Should the stranded Python-side ADRs (0010, 0002) be applied to Ruby now, or does applying them piecemeal recreate the drift I just walked away from?
- Which conditions does `mud-manager` actually mark with `isError`? One flag covers both "you can't go that way" (the model should shrug and retry) and "my telnet connection died" (it must not). They are not separable from the flag alone, so F34 makes the failure *structured* without yet deciding how the loop should route it. Answering this needs reading mud-manager, not boukensha.
- How much of "the agent wanders" survives a truthful transcript? Re-run the navigation session after F34 and count failed moves separately before drawing any conclusion about world models or memory.

## Key Takeaway

The port failed as a deliverable and succeeded as an instrument. Its output was never Python, it was 84 divergence rows and a 40-item defect list that made the Ruby better. The lesson is to recognise which of those two things you are building *before* you have 6,151 lines of the wrong one: had I separated "read the code closely" from "replace the code," I would have gotten the same findings without the second tree to abandon.