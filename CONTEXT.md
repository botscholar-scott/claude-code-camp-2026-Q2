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

**Tool**
: A capability the agent may invoke: a name, a description shown to the agent so
it knows when to reach for it, a parameter schema, and the code that runs.

**Handler**
: The callable a tool runs when it is invoked. Ruby calls this the tool's
*block*.

**Parameters**
: A tool's arguments, expressed as a JSON-Schema properties map. Becomes the
provider's `input_schema.properties`. A tool separately declares which of its
parameters are **required**; the rest are optional, and a tool that says nothing
requires all of them.

**Message**
: One unit of conversation — who spoke, what was said, and, for a tool result,
which call it answers.

**Role**
: Who is speaking in a message. Exactly three: `user`, `assistant`,
`tool_result`.

**Tool result**
: A **pseudo-role**. No provider has it; backends translate it into a provider
`user` message carrying a `tool_result` content block.

**Tool use id**
: The identifier pairing a tool result to the tool call that requested it. The
pairing must be exact or the provider rejects the call.

**Context**
: The conversation half of an API call: the system prompt, the full message
history, and the task that owns them. What a call needs is a **context** *and* a
**registry** — the tools live on the latter, not here.

**Turn**
: One message in the history. A context's turn count is the length of its message
history.

**Registry**
: The catalog of tools the agent may use, and the thing that runs one when asked
for it by name. Holds the only tool table; a context does not.

**Catalog**
: The full set of registered tools. Distinct from the set offered on any one API
call, which a caller may narrow.

**Dispatch**
: Looking a tool up by name and running its handler with the arguments the agent
supplied. Fails loudly on an unregistered name.

**Backend**
: The provider-specific half of an API call: it knows one provider's payload
shape, its endpoint, its headers, and which models it supports. It **serializes;
it does not send.**

**Payload**
: The plain data structure a provider's API expects for one call — the serialized
form of a context, a tool set, and the call's limits.

**Prompt builder**
: The object that joins a context and a tool catalog to a backend and produces a
payload. It is the seam where conversation, capability, and provider meet.

**Client**
: The object that performs one API call: it sends a payload to a provider's
endpoint and returns the parsed response. It **transports; it does not
serialize** — the mirror of what a **backend** does.

**Attempt**
: One HTTP request. A single call may make several — a retryable failure is
retried — and only the last one's outcome is returned.

**Context window**
: A model's total token ceiling for one call, input and output together — a fact
about the model, looked up, never configured. Distinct from the **max output
tokens** a single response may use.

**Step**
: One numbered rung of the ladder (`00_config`, `01_struct_skeleton`, …). Each
step is a self-contained, runnable tree with its own README and example; a step
does not import from its neighbours. Steps exist per language
(`week1_baseline/ruby/`, `week1_baseline/python/`).
