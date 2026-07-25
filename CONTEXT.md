# CONTEXT

Shared vocabulary for this repo. Definitions only — no implementation detail.
The terms are taken from `week1_baseline/ruby/00_config/README.md`, which is
currently the only place they are defined.

**Task**
: A role in the agentic loop, bound to its own LLM. Configuration is organised by
task: each one carries its own provider, model, and prompts. `week1_baseline`
drives a single task, `player`, but a more advanced loop assigns different LLMs to
different tasks.

**Single-task**
: A task that does one job with one LLM and does not itself dispatch to other
tasks.

**Multi-task**
: A task that coordinates other tasks — a full **agent**.

**Agent**
: A multi-task: a task whose job includes driving other tasks.

**Provider**
: The vendor behind a task's LLM, named as a string in settings (eg.
`anthropic`). Held separately from the model so the two can vary independently.

**Prompt override**
: A per-task opt-in, `tasks.<name>.prompt_override.<prompt>: true`, that lets a
file in the user's config dir replace the prompt shipped with the library.
Overrides are per task; there is no global override.

**Config dir**
: The external `.boukensha/` directory holding `.env` (secrets), the settings
file (non-secret settings), and `prompts/<task>/` (prompt overrides). Located via
`BOUKENSHA_DIR`, else `~/.boukensha`. It is language-agnostic — the Ruby and
Python trees read the same one.

**Step**
: One numbered rung of the ladder (`00_config`, `01_struct_skeleton`, …). Each
step is a self-contained, runnable tree with its own README and example; a step
does not import from its neighbours. Steps exist per language
(`week1_baseline/ruby/`, `week1_baseline/python/`).
