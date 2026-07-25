# 0004 — `Registry` owns the tool catalog; `Context` holds no tools

**Status:** accepted
**Date:** 2026-07-25
**Applies to:** `week1_baseline/python/02_the_registry` and later steps

## Context

Step 02 introduces the **Registry** — the object that stores what the agent can
do and runs a tool when the agent asks for it by name. In the Ruby the registry
does not own that table. `Registry.new(context)` takes a context, and
`Registry#tool` writes through it:

```ruby
def tool(name, description:, parameters: {}, &block)
  tool = Tool.new(name.to_s, description, parameters, block)
  @context.register_tool(tool)
  tool
end

def dispatch(name, args = {})
  tool = @context.tools[name.to_s]
  raise UnknownToolError, "No tool registered as '#{name}'" unless tool
  tool.block.call(**args.transform_keys(&:to_sym))
end
```

The table lives on `Context`; the registry is a thin façade over it.

### The author flagged this, specified the fix, and never shipped it

This needed provenance work, because the note does not appear everywhere.

| Repo | Commit | Ownership note in step-02 README? | `tool_names` on `Registry` at step 10? |
|---|---|---|---|
| `ExamProCo/claude-code-camp-2026-Q2` (course canon) | `ea92f4d` 2026-07-13, Andrew Brown | no | no |
| `omenking/claude-code-camp-2026-Q2` (author's personal fork) | `7387182` 2026-07-13, Andrew Brown, *"bring over ruby code for 03_prompt_builder"* | **yes** | yes |
| ours (`week1_baseline/ruby/02_the_registry/README.md`) | `ec7db92` 2026-07-25, Scott Rankin, *"clarification from the videos…"* | **yes** — restored by hand from the course videos | no |

The note reads, in full:

> ## Considerations
>
> We now register tools with the Registry but our code still has direct
> registration and tools in context. This likely should have been reworked.
>
> Checking the final baseline example, we did correct the issue.
> The context should have reference to tools[] its currently using, and the
> full table of tools registered should live on the Registry.
>
> We'll correct this manually in a future step and we will leave things place.

The personal fork also carries an abandoned mid-word comment, `# This isn'`,
directly above `Context#register_tool` — the same thought, started and dropped.
(That comment is in the fork only; our tree has no such marker.)

Three facts about the note:

1. **It is the author's own writing**, added while he was working through step 03,
   and he restates it on the course videos — which is where our copy came from.
   It is not a third-party opinion.
2. **It never reached the course repo.** ExamProCo's step-02 README has no such
   section at any commit; `git log -S "full table of tools registered"` there
   returns nothing.
3. **The stated correction never lands anywhere.** `registry.rb` is byte-identical
   (md5 `7eccb51c755a944b2b65fb384943664f`) from step 02 through step 12 in
   ExamProCo — verified across all eleven copies in this tree. The personal fork
   diverges only at step 10 by adding `tool_names`, which still reads
   `@context.tools.keys`. `context.rb` owns `@tools` at step 12 in **both** repos
   and in both language ports:

   ```ruby
   # week1_baseline/ruby/12_context/lib/boukensha/context.rb
   attr_reader :system, :messages, :tools, :context_window, :working_dir, …
   @tools[tool.name] = tool
   def tool_count = @tools.size
   ```

   The claim "checking the final baseline example, we did correct the issue" is
   not borne out by any code in either repo.

So: a defect the author named, whose fix he specified, and which nobody
implemented. [ADR 0002](0002-python-port-fixes-known-limitations.md) commits this
port to fixing known limitations rather than carrying them forward, and step 02 —
the step named for the Registry — is the cheapest place in the ladder to change
this shape.

### Tools on the context also create a downstream wart

From step 05, every backend carries the same ternary:

```ruby
# backends/{anthropic,openai,gemini,ollama,ollama_cloud}.rb — all five
tools: tools.nil? ? to_tools(context.tools) : tools
```

and its one real caller is `Agent#wrap_up`, which sends `tools: []` to disable
tools for the wind-down turn. That branch exists **only because** tools live on
the context but sometimes need overriding. If tools never live on the context,
the branch is never written: the payload builder takes tools explicitly,
`wrap_up` passes an empty mapping, and the override stops being a special case.

## Decision

**`Registry` owns the only tool table.**

1. `Registry()` takes no arguments. With the table here, the constructor argument
   has nothing to do, and the registry becomes independently constructible and
   testable.
2. `Context` holds **no tools at all** — no `_tools`, no `tools` property, no
   `register_tool`. Its `__repr__` loses `tools=`.
3. **Neither object holds a reference to the other.** They are orthogonal: a
   context is the conversation, a registry is the capability set. Callers compose
   them.
4. The duplicate-name `ValueError` moves from `Context.register_tool` to
   `Registry.tool`, unchanged in kind. It is a programmer error at startup, which
   is what `ValueError` means, and it needs no new exception class.

**Rejected: `Context` delegating to a `Registry` it holds.** The catalog would be
reachable two ways (`ctx.tools` and `registry.tools`) aliasing one dict, through
a property that adds no behaviour, and a `Context` could no longer be constructed
without a `Registry`. Coupling bought for nothing.

**Rejected: the author's literal split** — the full catalog on the `Registry`, and
on the `Context` a reference to the subset of tools "its currently using". The
right idea, but there is no consumer yet: `wrap_up` is the only caller that wants
to narrow the tool set, and an explicit parameter serves it. The reversibility
asymmetry settles it — adding `Context.tools` later is additive and non-breaking,
while removing it later breaks every call site. Start without it and let a later
step earn it back. Recorded as an open door, not a closed one.

## Consequences

- The step-05 ternary never gets written. `to_payload` takes tools explicitly and
  `wrap_up` passes an empty mapping.
- Two shapes downstream already match this design: `Agent.new(context:, registry:,
  …)` at step 05 takes **both** objects, and `Tools::FileSystem.register(registry,
  working_dir:)` at step 10 takes the **registry only**.
- Construction order flips. Ruby's `lib/boukensha.rb` does
  `registry = Registry.new(ctx)` at steps 07/09/10; ours builds the two
  independently in either order.
- `context.tool_count`, whose only reader is step 11's TUI, becomes
  `len(registry.tools)`.
- Step 03's `PromptBuilder` — Ruby's `PromptBuilder.new(context, backend)`
  reaching `@context.messages` and `@context.tools` — takes both objects here.
- `Context.__repr__` diverges visibly from the Ruby's: `Context(task='player',
  turns=0)` against `#<Context task=player turns=0 tools=2>`. That is the honest
  output — an object that does not own tools should not report how many there are.
- [ADR 0003](0003-context-is-the-mutable-object.md)'s tool-collection clauses are
  superseded from step 02 onward. Its **body is not edited**: those clauses remain
  exactly true of `week1_baseline/python/01_struct_skeleton`, which is a frozen,
  self-contained tree. Only its Status line changes. The rest of 0003 — the
  frozen/mutable split, and everything about `messages` — still stands.
- Step 01 stays byte-for-byte as it was, so **step 02 is the first non-additive
  step of the ladder**. Steps 00→01 and every Ruby step are purely additive over
  their predecessor; this one deletes code.

## Verification

There is no test suite at this step (the example is the safety net), so the
hand-checks were run and their real output recorded here:

```
duplicate name                     ValueError: a tool named 'move' is already registered
read-only catalog                  TypeError: 'mappingproxy' object does not support item assignment
unknown tool                       UnknownToolError: No tool registered as 'flee'
UnknownToolError is BoukenshaError True
unknown kwarg                      TypeError: move() got an unexpected keyword argument 'drection'. Did you mean 'direction'?
no-args dispatch                   'A torch-lit corridor.'      — handler called with no kwargs
ctx.register_tool                  AttributeError: 'Context' object has no attribute 'register_tool'
ctx.tools                          AttributeError: 'Context' object has no attribute 'tools'
list(registry.tools)               ['move']                     — no tool_names() needed
len(registry.tools)                1
```

The example run matches the Ruby on every behavioural line — same two dispatch
results, same tool order, same caught error message, exit 0 — and differs only on
the context repr:

```
python  Context:  Context(task='player', turns=0)
ruby    Context: #<Context task=player turns=0 tools=2>
```

And the step is still self-contained, the check ADR 0002 established:

```
BOUKENSHA_DIR=$(mktemp -d) ./week1_baseline/bin/python/02_the_registry
ValueError: tasks.player is missing from settings.yaml
```
