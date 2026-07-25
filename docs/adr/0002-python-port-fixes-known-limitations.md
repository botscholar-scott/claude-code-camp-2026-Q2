# 0002 — The Python port fixes the Ruby step's known limitations

**Status:** accepted
**Date:** 2026-07-24
**Applies to:** `week1_baseline/python/00_config`

## Context

`week1_baseline/ruby/00_config/README.md` ends with a "Considerations" section
listing things the step observed but explicitly does **not** want fixed, because
future steps of the Ruby ladder will break them anyway:

- the default prompt (`prompts/system.md`) should be scoped per task
  (`prompts/<task>/system.md`)
- the settings loader should accept `.yml` or `.yaml`, and currently accepts only
  `.yaml`

There is a third, unlisted one: when a task is absent from the settings file,
`Config#tasks(:player)` returns `nil` and `Player.provider(nil)` dies with a bare
`NoMethodError`. Ruby only guards this at step 05, where `fetch` gains
`return nil unless settings.is_a?(Hash)`.

The Ruby tree is a teaching ladder, where leaving a limitation in place is the
lesson. The Python tree is a deliverable that gets significantly extended in
week 2, so carrying a known defect forward on purpose buys nothing.

## Decision

Fix all three in the Python port at step 00.

1. **Settings filename** — `SETTINGS_FILENAMES = ("settings.yaml", "settings.yml")`,
   first existing file wins.
2. **Task-scoped library defaults** — prompt resolution is a three-step chain:
   the user override (`<config dir>/prompts/<task>/<prompt>.md`, only when
   `prompt_override.<prompt>` is `true`), then the task-scoped library default
   (`prompts/<task>/<prompt>.md`), then the flat library default
   (`prompts/<prompt>.md`). Only `prompts/system.md` ships, so today's resolved
   text is byte-identical to the Ruby's.
3. **Absent task** — `Task.from_settings` rejects a non-mapping `settings` with
   `ValueError("tasks.<name> is missing from settings.yaml")`.

## Consequences

- The Python port runs **ahead** of the Ruby ladder. When a later Ruby step
  announces one of these as its lesson, Python already has it. This ADR exists so
  that gap is not later mistaken for a bug or a missed port.
- Adding a task-scoped library default prompt later needs no code change, just a
  file at `prompts/<task>/system.md`.
- Verified by hand at implementation time, since this step has no test suite:
  - `BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/00_config` →
    `ValueError: tasks.player is missing from settings.yaml`
  - the same directory with a `settings.yml` (not `.yaml`) → loads, and falls
    back to the shipped flat default prompt
  - a temporary `prompts/player/system.md` → chosen over the flat default
- Error text says `settings.yaml` even when a `settings.yml` was loaded. Accepted:
  naming both in every message costs more than it clarifies.
