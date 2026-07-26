# 0010 — The agent loop catches the model's mistakes, not infrastructure failures

**Status:** accepted
**Date:** 2026-07-26
**Applies to:** `week1_baseline/python/05_agent_loop` and later steps

## Context

Ruby's `handle_tool_calls` dispatches unguarded:

```ruby
result = @registry.dispatch(name, args)      # agent.rb:104
```

Anything a handler raises propagates out of `Agent#run` and kills the run. Step
02 of this port already flagged that as wrong and committed to fixing it here.
`registry.py` ships this today:

> Exceptions from the handler propagate uncaught — turning a tool failure into a
> tool *result* the model can read is the agent loop's job, not the registry's.

The obvious reading of that promise is `except Exception`. **In this domain that
is the wrong reading**, and the reason is what BOUKENSHA actually is: a Player
Journey Agent driving a character through a tbaMUD on a player's behalf,
unattended, spending real money.

**In a MUD, failure is not an exception.** *"You can't go that way."*, *"There is
no such thing here."*, *"You are too exhausted."* — these are strings the MUD
returns and the model reads. Almost nothing a MUD tool does raises. What *does*
raise splits cleanly in two, and the two halves want opposite handling:

| Raises | Can the model recover? |
|---|---|
| `UnknownToolError` — the model invented a tool name | **Yes.** It reads the error and picks a real tool. |
| `TypeError` — the model called `move(dir=…)` not `move(direction=…)` | **Yes.** It reads the error and fixes the keyword. |
| `ConnectionResetError`, socket timeout — the MUD dropped | **No.** |
| A bug in our own tool code | **No.** |

Handing back the second kind as a tool result is not defensive, it is actively
harmful. The agent issues another two dozen commands into a dead socket, pays for
every one of them, and then gives the player a confident summary of a session
that never happened. The failure is silent, expensive, and produces a *wrong
answer* rather than an error — the worst of the three outcomes.

The first kind is genuinely worth recovering. A hallucinated tool name is a
one-token slip that the model corrects immediately when told, and crashing an
otherwise healthy twenty-iteration run over it wastes everything spent so far.

## Decision

**`Agent._dispatch` catches `UnknownToolError` and `TypeError`. Everything else
propagates.**

```python
try:
    return str(self._registry.dispatch(name, args)), False
except (UnknownToolError, TypeError) as exc:
    return f"{type(exc).__name__}: {exc}", True
```

A caught exception becomes a `TOOL_RESULT` message with `is_error=True`, which
the Anthropic backend serializes as `"is_error": true` on the `tool_result`
block. The model reads it on the next iteration and tries again.

The `Registry` is unchanged: it still raises, and its docstring is still
accurate. **Recoverability is a policy of the loop, not of the catalog.** A
future caller that wants different policy writes a different loop and reuses the
same registry.

**Rejected: `except Exception`.** The reading step 02's docstring most naturally
suggests, and it never crashes — which is exactly the problem. It converts every
infrastructure failure into a confident wrong answer at full price.

**Rejected: catching nothing, matching Ruby.** One hallucinated tool name — a
thing models genuinely do — destroys a twenty-iteration run that was otherwise
going fine, and the player gets a traceback instead of a summary.

**Rejected: an allowlist of exception types on `Tool`.** Lets a tool author
declare what is recoverable. Real, and correct in the long run, but there is
exactly one policy and one loop today; it is a seam nobody has asked for.

## Consequences

- **A tool author may assume exceptions are fatal by default.** Step 10's MUD
  tools are written against this: a dropped socket must raise, and must not be
  caught and described to the model.
- **A `TypeError` raised *inside* a handler is swallowed.** This is a real cost,
  not a hypothetical one. At the call site `registry.dispatch(name, args)`, a
  `TypeError` from *binding* the arguments (the model's mistake) and a
  `TypeError` from the handler's own body (our bug) are indistinguishable — the
  handler frame is one level down and Python does not distinguish them. The bug
  becomes a tool result the model reads and works around, and the run continues.
  Accepted, and named in the step README rather than left to be discovered.
  Narrowing it means inspecting `exc.__traceback__.tb_next`, which is fragile in
  a different way.
- **`is_error` reaches the wire.** `Message` gains the field and
  `AnthropicBackend.to_messages` emits it *only when true*, so every payload
  steps 03 and 04 produced is byte-identical.
- **`ApiError` is not caught here.** A failed API call inside the loop
  propagates. Only the wind-down call catches it, because at that point there is
  a useful fallback sentence to return instead.

## Verification

Driven offline with a scripted stub client — no network, no key:

```
--- model invents a tool name
    [iteration 1/25]
      call   -> teleport({})
      result ! UnknownToolError: No tool registered as 'teleport'
    [iteration 2/25]
   result: Recovered.

--- model uses the wrong keyword
    [iteration 1/25]
      call   -> move({'dir': 'north'})
      result ! TypeError: move() got an unexpected keyword argument 'dir'
    [iteration 2/25]
   result: Recovered.

--- infrastructure failure propagates
    [iteration 1/25]
      call   -> explode({})
   propagated: ConnectionResetError the MUD dropped
```

The third case is the one that matters: the run **stopped**, at the first sign
that the world was gone, rather than continuing to bill for commands into a dead
connection.
