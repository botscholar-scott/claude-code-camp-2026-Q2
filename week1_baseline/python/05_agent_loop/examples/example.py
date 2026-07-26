"""Runnable smoke test for step 5 — the only safety net this step has.

**Makes several real API calls and spends real money** (a few cents). It needs
`ANTHROPIC_API_KEY`, in the environment or in the config dir's `.env`.

The tools are `read_file` / `list_directory`, ported from Ruby's step-05 example
verbatim, and they give the loop real varied output to chew on. They are also
**not** what the system prompt in force says the agent is doing — see the README,
"Why the example is not playing the MUD". The real MUD tools arrive at step 10.
"""

import os
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

STEP_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(STEP_DIR))

# Override the config directory so the example works from the repo root.
# In real usage a user's ~/.boukensha is picked up automatically.
# examples -> 05_agent_loop -> python -> week1_baseline -> repo root
REPO_ROOT = STEP_DIR.parent.parent.parent
os.environ.setdefault("BOUKENSHA_DIR", str(REPO_ROOT / ".boukensha"))

# noqa: E402 throughout — these need the sys.path insert above.
from boukensha import (  # noqa: E402
    Agent,
    AnthropicBackend,
    Client,
    Config,
    Context,
    Player,
    Registry,
    backend_for,
)

#: How much of a tool result the printing logger shows. Ruby prints `[0..60]`.
RESULT_PREVIEW = 60


class PrintLogger:
    """Progress on stdout. **This lives in the example, not the package.**

    Ruby calls `puts` from inside `Agent#run` and unpicks it at step 08. A
    library that writes to stdout unbidden cannot be driven by step 08's REPL or
    step 11's TUI. `AgentLogger` is the seam; this is one implementation of it,
    and it satisfies the protocol structurally — nothing here subclasses or
    imports it. See `docs/adr/0011-agent-logger-protocol.md`.
    """

    def iteration(self, *, n: int, limit: int) -> None:
        print(f"[iteration {n}/{limit}]")

    def tool_call(self, *, name: str, args: Mapping[str, Any]) -> None:
        print(f"  tool call   → {name}({dict(args)})")

    def tool_result(self, *, name: str, result: str, is_error: bool) -> None:
        marker = "!" if is_error else "→"
        preview = result[:RESULT_PREVIEW].replace("\n", " ")
        print(f"  tool result {marker} {preview}")

    def limit_reached(self, *, kind: str, n: int, limit: int) -> None:
        print(f"[{kind} reached at {n}/{limit} — winding down]")


config = Config.load()
player = Player.from_config(config)

ctx = Context(task=player, system=player.system_prompt)
registry = Registry()


@registry.tool(
    "read_file",
    description="Read the contents of a file from disk",
    parameters={"path": {"type": "string", "description": "The file path to read"}},
)
def read_file(path):
    # Resolved against the step directory, the same as Ruby's `base_dir`. This is
    # a demo, not a sandbox: nothing stops `../../../etc/passwd`.
    return (STEP_DIR / path).read_text(encoding="utf-8")


@registry.tool(
    "list_directory",
    description="List the files in a directory",
    parameters={"path": {"type": "string", "description": "The directory path to list"}},
)
def list_directory(path):
    entries = sorted(
        entry.name
        for entry in (STEP_DIR / path).iterdir()
        if not entry.name.startswith(".")
    )
    return ", ".join(entries)


ctx.add_message(
    "user",
    "Read the README.md file and summarise what this MUD player assistant "
    "framework can do.",
)

# The provider seam: one lookup, no `case` statement, and no credential.
backend = backend_for(player)

# The credential comes back through `Config`, which is the thing that loaded
# `.env`. The library itself reads no environment. See ADR 0007.
api_key = config.require_secret(AnthropicBackend.API_KEY_ENV)
client = Client(backend, api_key=api_key)

# No `PromptBuilder` line: the Agent derives both of its builders — the one with
# tools, and the bare one for the wind-down call.
agent = Agent(ctx, registry, backend, client, logger=PrintLogger())

print("=== Boukensha Step 5: The Agent Loop ===")
print()
print(f"Config:             {config!r}")
print(f"Model:              {backend.model}")
print(f"Max iterations:     {player.max_iterations}")
print(f"Max output tokens:  {player.max_output_tokens}")
print()

result = agent.run()

print()
print("=== FINAL RESPONSE ===")
print(result)
print()
print(f"History: {ctx!r}")
