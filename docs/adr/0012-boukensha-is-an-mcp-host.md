# 0012 — Boukensha is an MCP host and ships no tools of its own

**Status:** accepted
**Date:** 2026-07-26
**Applies to:** `week1_baseline/python/12_context` and later steps

## Context

Ruby's `12_context` ships three tool modules: `Tools::FileSystem` (pwd,
read/write/delete file), `Tools::Shell` (`run_command` with an allow-list and a
timeout), and `Tools::Mud` — 26 gameplay tools built on the `mud_manager` gem,
which owns the telnet session, IAC stripping, background buffering, and the
multi-step CircleMUD login dance.

A literal port has to answer for `mud_manager`. There is no Python equivalent, so
"port `Tools::Mud`" means writing a telnet session layer from scratch and then 26
tool definitions on top of it. That is the single largest piece of work in the
step, and it reimplements the one asset the Ruby tree already got right.

The reference Python port took a different route, and the evidence is worth
recording because it is easy to assume otherwise:

| Tree | `.rb` files | `.py` files |
|---|---|---|
| `week0_explore/mud_manager` | 31 | **0** |
| `week2_capable/mud_manager` | 31 | **0** |
| `week2_capable/boukensha` | 66 | **0** |

`mud_manager` was **never ported to Python, in any tree**. Instead it grew an MCP
daemon (`bin/mud-manager --mcp`, `lib/mud_manager/mcp/*`, 1,189 lines) and the
Python port's step 10 deleted its built-in tool library rather than translating
it. `week2_capable` is then 100% Ruby — the Python port stops at week 1, so
"follow the reference port" buys week-1 parity and no week-2 path.

Two further facts shaped the decision rather than the port's authority:

- **Performance is not a reason to be in Python here.** The harness is I/O-bound
  on model inference and MUD round-trips; interpreter speed is noise.
- **Capability is.** The week-2 direction (local ONNX scoring, embeddings-based
  recall, evaluation harnesses) is Python-native and Ruby-hostile, and Textual is
  a better TUI substrate than FFI bindings to a Go TUI library. So the Python bet
  is worth making — which makes it worth *not* paying for a telnet rewrite to
  make it.

## Decision

**Boukensha is an MCP host. It holds the tool catalog and implements no tools.**

1. Every capability comes from an **MCP server** declared in an `mcp_servers:`
   block in `settings.yaml` — `command` / `args` / `env`, the standard stdio
   transport triple. An empty block means an agent that can only talk.
2. The MUD arrives as `mud-manager --mcp`: the **Ruby gem, reused unmodified**.
   The session, login, and 26 primitives stay where they already work.
3. Filesystem access is a third-party server (`@modelcontextprotocol/server-filesystem`).
   `Tools::FileSystem` and `Tools::Shell` are **not ported** — not deferred,
   deleted. Adding a capability is a config edit, not a code change.
4. Discovered tool names are scoped host-side by an optional per-server **tool
   prefix**; a collision raises and names the fix.

**Rejected: port `Tools::Mud` to Python.** It removes a Ruby dependency and buys
no capability, at the cost of the largest single work item in the step and a
telnet/login path nobody has debugged. If a Python MUD server is ever wanted, MCP
makes it a subprocess swap — the host does not change.

**Rejected: keep `FileSystem`/`Shell` native and use MCP only for the MUD.** It
contradicts the line that makes the story coherent ("boukensha ships no tools"),
and it keeps two tool-registration paths alive to save one `npx` dependency.

## Consequences

- **The language question is deferred at the seam where it is expensive.** Tools
  are processes, not code. The Python harness gets the capability upside without
  paying to rewrite what Ruby already does.
- **A Python harness now needs Ruby installed to play a MUD.** This is the real
  cost and it should not be soft-pedalled: the deliverable acquires a runtime
  dependency on another language's toolchain, and a process boundary to debug
  across. `mud-manager` must be on `PATH`; nothing hunts for it.
- **`week0_explore/mud_manager` must be synced first.** The copy in this repo
  predates the MCP work — no `bin/`, no `lib/mud_manager/mcp/`, no
  `fake_mud.rb`. Until it is, there are no tools at all.
- **Verification stops depending on a live MUD.** `fake_mud.rb` gives an offline
  run with no tbaMUD and no API key, which is the only way this step satisfies
  `CONTEXT.md`'s "self-contained, runnable tree".
- **Servers spawn eagerly at boot.** Every declared server costs a subprocess and
  a handshake even if the model never calls it. Fine at two; revisit past that.
- **Schema fidelity improves rather than degrades.** `Tool.required` already
  exists here (ADR 0005), so an MCP `inputSchema` maps across verbatim —
  `properties` untouched, `required` as declared. The reference port drops
  `required`, drops `default`, and flattens `enum` into prose, which makes its
  schema claim every parameter mandatory; `look` documents "call with NO
  arguments" while its schema demands two, and the schema wins. Sixteen of the
  MUD spec's 42 parameters are optional and four tools take none, so this is a
  live defect there and not a hypothetical one. See ADR 0002.
- **Non-text MCP content is dropped.** Images and embedded resources yield an
  empty string rather than an exception. No MUD tool can hit it.
- **`CONTEXT.md` gained four terms and sharpened two.** *Tool* no longer implies
  the work happens locally, and *Handler* is allowed to be a proxy.
