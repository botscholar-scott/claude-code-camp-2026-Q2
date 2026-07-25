# 0001 — The Python port models config as parsed frozen dataclasses

**Status:** accepted
**Date:** 2026-07-24
**Applies to:** `week1_baseline/python/`

## Context

The Ruby ladder models configuration lazily and statelessly. `Boukensha::Config`
does its file I/O inside `initialize` and then re-derives every value on each
access (`dig(:mud, :host) || "localhost"`). `Boukensha::Tasks::Base` is never
instantiated at all: every behaviour is a class method taking a `settings` hash
plus, for prompts, `user_prompts_dir:` and `default_prompts_dir:` keyword
arguments that the call site has to supply again each time.

A literal 1:1 translation of that into Python is possible — Andrew's port does
exactly this — but it carries the Ruby's shape into a language where it reads
badly:

- a class that is never instantiated is a Python anti-pattern; passing `settings`
  as the first argument of every class method is `self` written out by hand
- attribute access silently touching the filesystem is surprising, and it happens
  once per read
- the call site repeats `user_prompts_dir=` / `default_prompts_dir=` for every
  prompt it wants
- a bad settings file is discovered at first access, which may be well after
  startup

We also know where the class is going. `week1_baseline/ruby/05_agent_loop`'s
`Tasks::Base` gains `DEFAULT_MAX_ITERATIONS = 25`,
`DEFAULT_MAX_OUTPUT_TOKENS = 1024`, integer coercion, and an
`is_a?(Hash)` guard. That end state is a record with defaults and a validating
constructor.

## Decision

`Config`, `Mud`, and `Task` are `@dataclass(frozen=True, slots=True)` records,
built by explicit factories:

- `Config.load()` is the only thing in the package that touches the filesystem.
  It resolves the config dir, loads `.env`, parses the settings file, and returns
  a frozen instance.
- `Task.from_settings(settings, *, user_prompts_dir, default_prompts_dir)`
  validates one task's settings and reads its prompts **once**.
  `Task.from_config(config)` is the convenience wrapper over it.
- Everything after construction is pure data. `config.mud.host`,
  `player.system_prompt`, and `player.prompt_override` are plain attribute reads.

`Config.settings` is retained as the raw parsed mapping, so keys not yet modelled
are still reachable, and `Config.dig(*keys)` walks it safely.

## Consequences

- Configuration errors surface at load time, not at first access. A missing
  `provider` raises from `Player.from_config(config)`, not later inside the loop.
- No hidden I/O behind attribute access; each prompt file is read at most once.
- Call sites stop threading prompt directories through every call.
- Ruby's `?`-suffixed predicates disappear: with resolution eager,
  `prompt_override?` is just data (`player.prompt_override.get("system", False)`).
- The frozen dataclass is the shape step 05 needs anyway — the extra fields
  (`max_iterations=25`, `max_output_tokens=1024`) drop in as defaults.
- Downside accepted: the Python source no longer reads line-for-line against the
  Ruby, so porting later steps means porting behaviour rather than syntax. The
  divergence table in each step's README carries that mapping.
- `Config.__repr__` must be written by hand (`repr=False` on the dataclass),
  because holding the raw `settings` means the generated repr would print
  `mud.password`.
