# Plan — Port `week1_baseline/ruby/00_config` to Python

**Target:** `week1_baseline/python/00_config`
**Source of truth:** `week1_baseline/ruby/00_config` (README + 5 source files + `prompts/system.md`)
**Status:** agreed via grilling session; ready to implement.

---

## 1. Goal

Reproduce step 0 of the Boukensha ladder in Python: a `Config` class that reads
an external `~/.boukensha/` directory, and a per-task abstraction that resolves
provider, model, and system prompt for the `player` task.

This is **not** a translation exercise. The Python tree is a deliverable that
gets significantly extended in week2, so it is written as idiomatic Python and
is permitted to diverge from the Ruby where Python has a better answer. Every
divergence is deliberate and recorded (§7).

### Reference material

| Path | Role |
|---|---|
| `week1_baseline/ruby/00_config/README.md` | the spec |
| `week1_baseline/ruby/00_config/lib/boukensha/config.rb` | `Config` behaviour to reproduce |
| `week1_baseline/ruby/00_config/lib/boukensha/tasks/base.rb` | task behaviour to reproduce |
| `week1_baseline/ruby/00_config/lib/boukensha/tasks/player.rb` | concrete task |
| `week1_baseline/ruby/00_config/examples/example.rb` | output the example must reproduce |
| `week1_baseline/ruby/00_config/prompts/system.md` | default prompt, copied verbatim |
| `week1_baseline/bin/00_config`, `week1_baseline/ruby/bin/00_config` | launcher convention |
| `.boukensha/` (repo root) | live fixture — language-agnostic, shared with Ruby, **not modified** |

Two further references were consulted during design:

- `week1_baseline/ruby/05_agent_loop/lib/boukensha/tasks/base.rb` — shows where
  this class is heading: it gains `DEFAULT_MAX_ITERATIONS = 25`,
  `DEFAULT_MAX_OUTPUT_TOKENS = 1024`, `max_iterations`, `max_output_tokens`, an
  integer coercer, and a `settings.is_a?(Hash)` guard. The final shape is a
  record with defaults, which is why the dataclass design below ages well.
- `/Users/scott/src/GITROOT/omenking/claude-code-camp-2026-Q2/week1_baseline/python/00_config`
  — Andrew's Python port. Reviewed, **not copied**. It is a literal 1:1 mirror of
  the Ruby (stateless classmethods, lazy resolution, Ruby-style `repr`). We
  diverge deliberately; see §7.

---

## 2. Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Fidelity | Same conceptual shape, Pythonic idioms |
| 2 | Tasks | Frozen dataclass instances, not stateless classmethods |
| 3 | Packaging | None — flat `boukensha/` package, `requirements.txt`, `sys.path` insert in the example |
| 4 | Interpreter | Launcher uses repo-root `.venv` if present, else falls back to `python3` |
| 5 | Launcher path | `week1_baseline/bin/python/00_config` (fills the already-carved empty dir; matches Andrew's path) |
| 6 | Resolution timing | **Eager** — a factory validates settings and reads the prompt once; the object is then pure data with no I/O |
| 7 | `Config` | Same treatment: `Config.load()` factory, frozen, typed `mud` sub-object |
| 8 | Known limitations | **Fixed**, all of them (the Ruby README says not to; we override — see ADR 0002) |
| 9 | Prompt chain | Three steps, only the flat `prompts/system.md` ships |
| 10 | Tests | None — `examples/example.py` is the smoke test |
| 11 | Output | Pythonic `repr`, Python booleans (`True`/`False`) |
| 12 | Call site | `from_settings` primitive + `from_config` convenience; `Config.tasks` property and `Config.task(name)` |
| 13 | Docs | Conventions and divergences in the step README; plus root `CONTEXT.md` and two ADRs |

**Python floor: 3.11+** (`slots=True` needs 3.10, `typing.Self` needs 3.11).
Local interpreter is 3.14.5.

---

## 3. File tree

```
CONTEXT.md                                    NEW  glossary
docs/adr/
  0001-python-port-parsed-dataclasses.md      NEW
  0002-python-port-fixes-known-limitations.md NEW
.gitignore                                    EDIT __pycache__/, *.pyc, .venv/

week1_baseline/
  bin/python/00_config                        NEW  launcher (chmod +x)
  python/00_config/
    README.md                                 NEW  ported + divergence sections
    requirements.txt                          NEW  PyYAML, python-dotenv
    prompts/system.md                         NEW  byte-copy of the Ruby's
    boukensha/
      __init__.py                             NEW
      config.py                               NEW
      tasks/
        __init__.py                           NEW  (empty)
        base.py                               NEW
        player.py                             NEW
    examples/example.py                       NEW
```

Untouched: everything under `week1_baseline/ruby/`, the legacy
`week1_baseline/bin/00_config`, the empty `week1_baseline/bin/ruby/`, and the
root `.boukensha/` fixture.

---

## 4. Design

### 4.1 `boukensha/config.py`

Module constants:

```python
DEFAULT_DIR = Path.home() / ".boukensha"
SETTINGS_FILENAMES = ("settings.yaml", "settings.yml")   # divergence: .yml accepted
PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"
```

```python
@dataclass(frozen=True, slots=True)
class Mud:
    host: str = "localhost"
    port: int = 4000
    username: str | None = None
    password: str | None = None

    @classmethod
    def from_settings(cls, settings: Mapping[str, Any] | None) -> Self
```

`from_settings` tolerates `None` or a non-mapping and falls back to defaults, so
a missing `mud:` block behaves exactly as the Ruby's `|| "localhost"` chain.
`port` is coerced with `int()`.

```python
@dataclass(frozen=True, slots=True, repr=False)
class Config:
    dir: Path
    settings: Mapping[str, Any]   # raw YAML — escape hatch for unmodelled keys
    mud: Mud

    DEFAULT_DIR: ClassVar[Path]
    PROMPTS_DIR: ClassVar[Path]

    @classmethod
    def load(cls) -> Self          # the only thing that touches the filesystem
    @property
    def tasks(self) -> Mapping[str, Mapping[str, Any]]
    def task(self, name: str) -> Mapping[str, Any] | None
    @property
    def user_prompts_dir(self) -> Path
    def dig(self, *keys: str) -> Any
    def __repr__(self) -> str
```

`load()` order is load-bearing and matches the Ruby exactly:

1. resolve `dir` — `Path(os.environ.get("BOUKENSHA_DIR") or DEFAULT_DIR).expanduser().resolve()`.
   Must happen **before** `.env` is loaded, so `.env` cannot redirect the
   directory it was itself read from.
2. `load_dotenv(dir / ".env")` if the file exists. `python-dotenv` does not
   override already-set variables by default, matching Ruby's `Dotenv.load`.
3. read the first existing name in `SETTINGS_FILENAMES`, `yaml.safe_load` it,
   coerce `None` to `{}`.
4. construct, deriving `mud` from `settings.get("mud")`.

`user_prompts_dir` returns a **`Path`**, not a string. (Andrew's returns an
`os.path.join` string while `PROMPTS_DIR` is a `Path`; both flow into the same
parameter, so we make them consistent.)

**`repr=False` is mandatory, not stylistic.** `Config` holds `settings`, which
contains `mud.password`. The dataclass-generated `__repr__` would print the
entire YAML — and `examples/example.py` ends with `print(config)`. The
hand-written one exposes no secrets:

```python
def __repr__(self) -> str:
    return f"Config(dir={str(self.dir)!r}, tasks={list(self.tasks)!r})"
```

### 4.2 `boukensha/tasks/base.py`

```python
@dataclass(frozen=True, slots=True)
class Task:
    name: str
    provider: str
    model: str
    prompt_override: Mapping[str, bool] = field(default_factory=dict)
    system_prompt: str | None = None

    NAME: ClassVar[str]           # concrete subclasses set this

    @classmethod
    def from_settings(cls, settings, *, user_prompts_dir=None,
                      default_prompts_dir=None) -> Self
    @classmethod
    def from_config(cls, config) -> Self
```

`from_settings` is the primitive and the only place validation happens:

- resolve `cls.NAME`; raise `NotImplementedError` if the subclass didn't set it.
- if `settings` is not a `Mapping` (covers the `None` returned by
  `config.task("player")` when the task is absent), raise
  `ValueError(f"tasks.{name} is missing from settings.yaml")`.
  *This is the Ruby's real ungraceful case — `Player.provider(nil)` raises a bare
  `NoMethodError` until step 05 adds an `is_a?(Hash)` guard.*
- `provider` missing → `ValueError(f"tasks.{name}.provider is required in settings.yaml")`.
  Same for `model`. Note **`settings.yaml`**, not the Ruby step-00 typo
  `settings.yml`.
- normalise `prompt_override` to a dict, wrap in `MappingProxyType` so the frozen
  dataclass is actually immutable through the field.
- resolve `system_prompt` once via the chain in §4.3.

`from_config` is the convenience that removes the duplication:

```python
@classmethod
def from_config(cls, config) -> Self:
    return cls.from_settings(
        config.task(cls.NAME),
        user_prompts_dir=config.user_prompts_dir,
        default_prompts_dir=config.PROMPTS_DIR,
    )
```

It reads `PROMPTS_DIR` **off the passed instance**, not by importing `Config`.
That is deliberate: `boukensha/__init__.py` imports both modules, and importing
`config` from `tasks/base` would create a cycle.

### 4.3 Prompt resolution chain

First existing file wins; `None` if none exist. Content is `.strip()`ed,
read as UTF-8.

1. `<config.dir>/prompts/<task>/<name>.md` — **only** when
   `prompt_override[<name>] is True`
2. `<pkg>/prompts/<task>/<name>.md`
3. `<pkg>/prompts/<name>.md`

Step 2 is new (the Ruby's library-side default is flat). We add the hook but
ship only `prompts/system.md`, so today's resolved text is identical to the
Ruby's. Dropping in `prompts/player/system.md` later needs no code change.

With the current repo fixture — `.boukensha/prompts/player/system.md` exists and
`prompt_override.system: true` — **step 1 wins**, exactly as in Ruby.

### 4.4 `boukensha/tasks/player.py`

```python
from typing import ClassVar
from .base import Task

class Player(Task):
    NAME: ClassVar[str] = "player"
```

No `@dataclass` decorator needed — it adds no fields, only a class attribute.

### 4.5 `boukensha/__init__.py`

```python
from .config import Config, Mud
from .tasks.base import Task
from .tasks.player import Player

__all__ = ["Config", "Mud", "Task", "Player"]
```

### 4.6 `examples/example.py`

Mirrors `examples/example.rb` line for line:

```python
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
os.environ.setdefault("BOUKENSHA_DIR", str(<repo root> / ".boukensha"))
```

The repo root is five `.parent` hops from `Path(__file__).resolve()`
(`example.py` → `examples` → `00_config` → `python` → `week1_baseline` → root),
matching the Ruby's `File.expand_path("../../../../.boukensha", __dir__)`.
`setdefault` matches Ruby's `||=` — an externally-set `BOUKENSHA_DIR` wins.

Body:

```python
config = Config.load()
player = Player.from_config(config)
```

then the same printed block, with `player.prompt_override.get("system", False)`
for the override line and `(player.system_prompt or "")[:60]` for the prompt
line.

### 4.7 `requirements.txt`

```
PyYAML
python-dotenv
```

Python's standard library has no YAML parser, so `PyYAML` is unavoidable —
`yaml.safe_load` is the direct analogue of Ruby's `YAML.safe_load`.
`python-dotenv` mirrors the Ruby side's single `dotenv` gem. Unpinned, matching
the Ruby's unpinned `Gemfile`.

### 4.8 `week1_baseline/bin/python/00_config`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."

PY="$REPO_ROOT/.venv/bin/python"
[ -x "$PY" ] || PY="python3"

cd "$SCRIPT_DIR/../../python/00_config"
exec "$PY" examples/example.py
```

`chmod +x`. Runs today with no venv; create a repo-root `.venv` later and it is
picked up with no script edit.

---

## 5. Documentation to write

### `week1_baseline/python/00_config/README.md`

Port of the Ruby README with Python names throughout, plus:

- **Setup** — `pip install -r requirements.txt`, note the optional repo-root
  `.venv`, note the 3.11+ floor.
- **Code Changes** table pointing at the Python files.
- **Tasks** section rewritten for the dataclass design (`Player.from_config`).
- **System prompt resolution** — the three-step chain.
- **Run Example** — `./week1_baseline/bin/python/00_config`.
- **Expected output** — *generated from an actual run, not copied.* The Ruby
  README's sample block is stale: it shows the default prompt
  (`"You are a MUD player assistant…"`), but the repo fixture sets
  `prompt_override.system: true` with a `player/system.md` that begins
  `"You are a MUD Journey Player Agent…"`, so the override is what actually
  prints.
- **Considerations** — rewritten: the Ruby's two entries are now *fixed*, so this
  section records what we changed and why instead of what we left alone.
- **Naming conventions for this port** — Ruby `?`-suffixed predicates, `repr`
  style, error-message wording.
- **Divergences from the Ruby port** — the table in §7.

### Root `CONTEXT.md`

Glossary only, no implementation detail: **Task**, **Single-task**,
**Multi-task**, **Agent**, **Provider**, **Prompt override**, **Config dir**,
**Step**. Terms are taken from the Ruby README, which is currently the only
place they are defined.

### `docs/adr/0001-python-port-parsed-dataclasses.md`

The Python port models `Config` and `Task` as frozen dataclasses built by
factories that validate and read the filesystem once, rather than mirroring
Ruby's stateless classmethods that re-derive on each access. Rationale:
parse-don't-validate at the boundary, no hidden I/O behind attribute access, no
repeated `user_prompts_dir`/`default_prompts_dir` arguments at call sites, and
the step-05 shape (`provider, model, prompt_override, max_iterations=25,
max_output_tokens=1024`) is already a record with defaults. Consequence: config
errors now surface at load time rather than first access.

### `docs/adr/0002-python-port-fixes-known-limitations.md`

The Ruby README lists limitations it explicitly does not want fixed. The Python
port fixes them anyway: `.yml` is accepted alongside `.yaml`, library default
prompts may be task-scoped, and an absent task raises a clear error. Consequence:
the Python port runs **ahead** of the Ruby — when a later step's README announces
one of these as its lesson, Python will already have it. Recorded so the
difference is not later mistaken for a bug.

---

## 6. Implementation order

1. `.gitignore` — add `__pycache__/`, `*.pyc`, `.venv/`.
2. Package skeleton + `prompts/system.md` (byte-copy) + `requirements.txt`.
3. `config.py` → `tasks/base.py` → `tasks/player.py` → `__init__.py`.
4. `examples/example.py`.
5. `bin/python/00_config`, `chmod +x`.
6. Run it; capture real output.
7. `README.md` using that captured output.
8. `CONTEXT.md`, `docs/adr/0001`, `docs/adr/0002`.

---

## 7. Divergences from the Ruby port

| # | Ruby / Andrew | This port | Why |
|---|---|---|---|
| 1 | `Tasks::Base` stateless classmethods | frozen `Task` dataclass | a never-instantiated class is a Python anti-pattern; `settings` as every method's first arg is `self` by hand |
| 2 | lazy — every access re-reads dict/disk | eager — factory resolves once | fail fast at startup; no hidden I/O in getters |
| 3 | `Config.new` loads | `Config.load()` | a constructor that does file I/O is not constructible in isolation |
| 4 | flat `mud_host`, `mud_port`, … | typed `config.mud` sub-object | one place for MUD defaults |
| 5 | dual-mode `tasks(name=None)` | `.tasks` property + `.task(name)` | return type must not depend on arity |
| 6 | `settings.yaml` only | `.yaml` **or** `.yml` | Ruby README limitation, fixed (ADR 0002) |
| 7 | library default prompt is flat | task-scoped, flat fallback | Ruby README limitation, fixed (ADR 0002) |
| 8 | missing task → `NoMethodError` | clear `ValueError` | Ruby README limitation, fixed (ADR 0002) |
| 9 | error text says `settings.yml` | says `settings.yaml` | step-00 typo; Ruby corrects it itself at step 05 |
| 10 | `#<Boukensha::Config …>` | `Config(dir=…, tasks=[…])` | Ruby-shaped repr in Python is cargo cult; also keeps `mud.password` out of `print(config)` |
| 11 | prints `true` / `false` | prints `True` / `False` | Python booleans |
| 12 | `prompt_override?` predicate | `prompt_override` mapping field | eager design makes it data, so no predicate is needed (Andrew needed `is_prompt_override`) |
| 13 | string/symbol dual key lookup | plain string keys | YAML keys are strings in Python; Ruby symbols have no analogue |

---

## 8. Verification

`examples/example.py` is the entire safety net — no test suite (decision 10).

```bash
./week1_baseline/bin/python/00_config    # new
./week1_baseline/bin/00_config           # Ruby, for comparison
```

Check by eye:

- config dir resolves to the repo-root `.boukensha`
- `Tasks: player`, provider `anthropic`, model `claude-haiku-4-5`
- override reports `True`, and the printed prompt is the **Journey Player Agent**
  text (the user override), not the shipped default
- `localhost:4000`, user `dummy`
- `API key set?    True`
- the final line prints **no password**

Then confirm the fixed behaviours by hand:

```bash
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/00_config
# expect: ValueError "tasks.player is missing from settings.yaml" — not a TypeError
```

and repeat with a `settings.yml` (not `.yaml`) in that directory to confirm it is
picked up.

---

## 9. Out of scope

- Migrating the 11 Ruby launchers from `week1_baseline/ruby/bin/` to
  `week1_baseline/bin/ruby/`, or retiring the legacy `week1_baseline/bin/00_config`.
  The repo has two half-built launcher conventions; unifying them is a separate change.
- Porting steps `01_struct_skeleton` … `12_context`. This plan covers `00_config` only.
- Any modification to `.boukensha/` or to the Ruby tree.
- Pinning dependency versions, `pyproject.toml`, or a lockfile.
