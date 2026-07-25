# 00 · Configuration (Python)

We want to be able to manage all configuration from an external file eg.
`~/.boukensha/settings.yaml`. We want a dedicated class to handle configuration,
eg. `boukensha.Config`. Please consider that as we add configuration in each
iteration we will be updating the configuration schema and class. We can
hardcode defaults but we should not hardcode configurable values.

Configuration is organised by **task** — a role in the agentic loop bound to its
own LLM. week1_baseline only drives a single `player` task (the main loop), but
a more advanced loop will assign different LLMs to different tasks. A task is
either a "single-task" or a "multi-task" — the latter being a full agent.

This is the Python port of `week1_baseline/ruby/00_config`. It reproduces the
same behaviour but is written as idiomatic Python; the deliberate differences are
listed under [Divergences from the Ruby port](#divergences-from-the-ruby-port).

## Design Considerations

We want to use the standard library as much as possible, avoiding external
packages. Two are unavoidable: the standard library has no YAML parser, and we
need to load `.env` files.

- `PyYAML` — `yaml.safe_load` is the direct analogue of Ruby's `YAML.safe_load`.
- `python-dotenv` — mirrors the Ruby side's single `dotenv` gem.

Both are unpinned, matching the Ruby's unpinned `Gemfile`.

## Setup

Requires **Python 3.11+** (`slots=True` on dataclasses needs 3.10, `typing.Self`
needs 3.11).

```bash
python3 -m venv .venv                                        # at the repo root
.venv/bin/pip install -r week1_baseline/python/00_config/requirements.txt
```

The launcher uses the repo-root `.venv` when it exists and falls back to
`python3` otherwise, so a global install works too.

## Code Changes

| File | Purpose |
|------|---------|
| `boukensha/config.py` | `Config` and `Mud` |
| `boukensha/tasks/base.py` | abstract `Task` (provider/model + prompt resolution) |
| `boukensha/tasks/player.py` | concrete `Player` (the main loop) |
| `boukensha/__init__.py` | package exports |
| `prompts/system.md` | default system prompt shipped with the library |
| `examples/example.py` | runnable smoke-test |
| `requirements.txt` | PyYAML, python-dotenv |

---

## Config directory resolution

`Config.load()` looks for a `.boukensha/` directory in this order:

1. **`BOUKENSHA_DIR` env var** — set this to point at any directory you like.
2. **`~/.boukensha`** — the default location for a real install.

The directory is resolved *before* `.env` is loaded, so a `.env` cannot redirect
the directory it was itself read from.

## Config directory structure

The class expects the following:

```
.boukensha/
  .env                    # stores credentials eg. LLM APIs (never committed to repo)
  settings.yaml           # all non-secret settings (settings.yml also accepted)
  prompts/
    <task>/
      system.md           # per-task override for the default system prompt (optional)
```

---

## Tasks

`Task` is a **frozen dataclass**, not a stateless class. `Task.from_settings`
validates one task's settings hash and resolves its prompts once; the instance it
returns is pure data, so no attribute access does hidden I/O. Concrete subclasses
set `NAME`; for now only `Player` exists. Future steps add per-turn ceilings
(`max_iterations`, `max_turn_tokens`, `max_output_tokens`,
`compaction_threshold`) — these are **not** read yet.

`Config.tasks` is a property returning the raw `tasks:` map from the settings
file; `Config.task(name)` returns one task's settings hash (or `None`).
`Task.from_config` is the convenience that wires the two together:

```python
config = Config.load()
player = Player.from_config(config)

player.provider        # "anthropic"
player.model           # "claude-haiku-4-5"
player.system_prompt   # already resolved text
```

The underlying primitive is available when you have a settings hash but no
`Config`:

```python
Player.from_settings(
    config.task("player"),
    user_prompts_dir=config.user_prompts_dir,
    default_prompts_dir=Config.PROMPTS_DIR,
)
```

Validation happens in `from_settings`, at load time rather than at first access:

- task absent from the settings file → `ValueError: tasks.player is missing from settings.yaml`
- `provider` missing → `ValueError: tasks.player.provider is required in settings.yaml`
- `model` missing → `ValueError: tasks.player.model is required in settings.yaml`
- subclass without `NAME` → `NotImplementedError`

## System prompt resolution

Per task, `system_prompt` is resolved in this order — first existing file wins,
`None` if none exist:

1. **`.boukensha/prompts/<task>/system.md`** — used when the task's
   `prompt_override.system` is `true` and the file exists.
2. **`prompts/<task>/system.md`** — task-scoped default shipped with the library.
3. **`prompts/system.md`** — the flat default system prompt shipped with the library.

Step 2 is the hook for task-scoped library defaults. Only the flat
`prompts/system.md` ships today, so the resolved text is identical to the Ruby's;
dropping in `prompts/player/system.md` later needs no code change.

(We no longer use a top-level `system.override`; override is now per-task via
`prompt_override.system`.)

## Configuration Schema

The following properties so far:
- `tasks`: a map of task name → task config (provider, model, prompt_override).
- `tasks.<name>.prompt_override.system`: when `true`, the task's
  `.boukensha/prompts/<name>/system.md` overrides the default system prompt.
- `mud`: MUD connection information for the main player.

```yaml
tasks:
  player:
    provider: anthropic        # provider name (string)
    model: claude-haiku-4-5
    prompt_override:
      system: true
mud:
  host: localhost
  port: 4000
  username: dummy
  password: helloworld
```

`mud` is modelled as a typed `Mud` sub-object reached through `config.mud`
(`host`, `port`, `username`, `password`), with `localhost` / `4000` as defaults.
`config.settings` remains available as the raw parsed YAML — the escape hatch for
keys not yet modelled — and `config.dig("mud", "host")` walks it safely.

## Run Example

```bash
./week1_baseline/bin/python/00_config
```

Actual output against this repo's `.boukensha/` fixture:

```
=== Boukensha Step 0: Configuration ===

Config dir:     /Users/scott/src/GITROOT/botscholar-scott/claude-code-camp-2026-Q2/.boukensha
Tasks:          player

-- player task --
Provider:       anthropic
Model:          claude-haiku-4-5
Prompt override?True
System prompt:  You are a MUD Journey Player Agent. You are playing the MUD ...

MUD host:       localhost:4000
MUD user:       dummy

API key set?    True

Config(dir='/Users/scott/src/GITROOT/botscholar-scott/claude-code-camp-2026-Q2/.boukensha', tasks=['player'])
```

Note the system prompt line: the fixture sets `prompt_override.system: true` and
ships `.boukensha/prompts/player/system.md`, so the **user override** wins and
the shipped default (`"You are a MUD player assistant…"`) never appears. The
Ruby README's sample block shows the default, which is stale — the Ruby code
prints the override too.

The final line prints no password, by design: `Config.__repr__` is hand-written
because `config.settings` holds `mud.password` and the dataclass-generated repr
would dump the whole YAML.

## Considerations

The Ruby step lists two things it observed but did not want fixed. This port
fixes them, plus a third — see
[ADR 0002](../../../docs/adr/0002-python-port-fixes-known-limitations.md):

- The default prompt may now be task-scoped (`prompts/<task>/system.md`), with
  the flat `prompts/system.md` as the fallback.
- The settings loader accepts `settings.yaml` **or** `settings.yml`.
- A task missing from the settings file raises a clear `ValueError` instead of an
  attribute error on `None`.

The consequence is that this port runs slightly **ahead** of the Ruby ladder.
When a later step's README announces one of these as its lesson, Python already
has it. That is recorded so the difference is not later mistaken for a bug.

## Naming conventions for this port

- Ruby's `?`-suffixed predicates have no Python equivalent. Because resolution is
  eager, `prompt_override?` becomes plain data: `player.prompt_override` is a
  read-only mapping, queried as `player.prompt_override.get("system", False)`.
- `repr` is Pythonic — `Config(dir=…, tasks=[…])`, not `#<Boukensha::Config …>`.
- Error messages say `settings.yaml`. Ruby's step 00 says `settings.yml`, which
  is a typo it corrects itself at step 05.
- Factories are named `load` (does I/O) and `from_settings` / `from_config`
  (build from data), never `__init__`.
- Module-level constants (`DEFAULT_DIR`, `SETTINGS_FILENAMES`, `PROMPTS_DIR`) are
  the source of truth; `Config.DEFAULT_DIR` and `Config.PROMPTS_DIR` re-export
  them as `ClassVar`s for call sites that already hold a `Config`.

## Divergences from the Ruby port

| # | Ruby | This port | Why |
|---|---|---|---|
| 1 | `Tasks::Base` stateless classmethods | frozen `Task` dataclass | a never-instantiated class is a Python anti-pattern; `settings` as every method's first argument is `self` by hand |
| 2 | lazy — every access re-reads dict/disk | eager — the factory resolves once | fail fast at startup; no hidden I/O in getters |
| 3 | `Config.new` loads | `Config.load()` | a constructor that does file I/O is not constructible in isolation |
| 4 | flat `mud_host`, `mud_port`, … | typed `config.mud` sub-object | one place for MUD defaults |
| 5 | dual-mode `tasks(name = nil)` | `.tasks` property + `.task(name)` | return type must not depend on arity |
| 6 | `settings.yaml` only | `.yaml` **or** `.yml` | Ruby README limitation, fixed (ADR 0002) |
| 7 | library default prompt is flat | task-scoped, flat fallback | Ruby README limitation, fixed (ADR 0002) |
| 8 | missing task → `NoMethodError` | clear `ValueError` | Ruby README limitation, fixed (ADR 0002) |
| 9 | error text says `settings.yml` | says `settings.yaml` | step-00 typo; Ruby corrects it itself at step 05 |
| 10 | `#<Boukensha::Config …>` | `Config(dir=…, tasks=[…])` | a Ruby-shaped repr in Python is cargo cult; also keeps `mud.password` out of `print(config)` |
| 11 | prints `true` / `false` | prints `True` / `False` | Python booleans |
| 12 | `prompt_override?` predicate | `prompt_override` mapping field | the eager design makes it data, so no predicate is needed |
| 13 | string/symbol dual key lookup | plain string keys | YAML keys are strings in Python; Ruby symbols have no analogue |
| 14 | unset `mud.username` prints as empty | prints as `None` | Ruby interpolates `nil` to `""`; only visible when the key is absent, which the fixture never is |

See also [ADR 0001](../../../docs/adr/0001-python-port-parsed-dataclasses.md) for
the reasoning behind divergences 1–5.
