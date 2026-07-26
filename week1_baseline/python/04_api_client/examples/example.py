"""Runnable smoke test for step 4 — the only safety net this step has.

Unlike steps 00–03 this one **makes a real API call and spends real money**
(about a tenth of a cent). It needs `ANTHROPIC_API_KEY`, in the environment or in
the config dir's `.env`.
"""

import json
import os
import sys
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(STEP_DIR))

# Override the config directory so the example works from the repo root.
# In real usage a user's ~/.boukensha is picked up automatically.
# examples -> 04_api_client -> python -> week1_baseline -> repo root
REPO_ROOT = STEP_DIR.parent.parent.parent
os.environ.setdefault("BOUKENSHA_DIR", str(REPO_ROOT / ".boukensha"))

# noqa: E402 throughout — these need the sys.path insert above.
from boukensha import (  # noqa: E402
    AnthropicBackend,
    Client,
    Config,
    Context,
    Player,
    PromptBuilder,
    Registry,
    backend_for,
)

config = Config.load()
player = Player.from_config(config)

ctx = Context(task=player, system=player.system_prompt)
registry = Registry()


@registry.tool("look", description="Look around the current room for details")
def look():
    return "A damp stone corridor stretches north. Torches flicker on the walls."


@registry.tool(
    "move",
    description="Move the player in a direction (north, south, east, west, up, down)",
    parameters={"direction": {"type": "string", "description": "The direction to move"}},
)
def move(direction):
    return f"You move {direction} into a torch-lit corridor."


# One user turn. Step 03's fixture also carried an assistant message and a
# `tool_result` referencing `toolu_01X` — a tool_use block that was never
# emitted — which the API rejects with a 400. Invisible while nothing posted;
# this is the step that posts. See the README, "Why the fixture changed".
ctx.add_message("user", "I've just arrived in the dungeon. Look around, then head north.")

# The provider seam: one lookup, no `case` statement, and no credential.
backend = backend_for(player)
builder = PromptBuilder(ctx, backend, tools=registry.tools)

# The credential comes back through `Config`, which is the thing that loaded
# `.env`. The library itself reads no environment. See ADR 0007.
api_key = config.require_secret(AnthropicBackend.API_KEY_ENV)
client = Client(backend, api_key=api_key)

# 1024 is explicit and at the call site, which is where Ruby's own default
# lives. The library default stays 16000.
payload = builder.to_api_payload(max_output_tokens=1024)

print("=== Boukensha Step 4: The API Client ===")
print()
print(f"Config:         {config!r}")
print(f"Model:          {backend.model}")
print(f"Max tokens:     {payload['max_tokens']}")
print()
print(f"Sending request to {builder.url}…")
print()

response = client.call(payload)

print("Raw response:")
print(json.dumps(response, indent=2))
print()

usage = response["usage"]
cost = backend.estimate_cost(
    input_tokens=usage["input_tokens"],
    output_tokens=usage["output_tokens"],
)
print(f"Stop reason: {response['stop_reason']}")
print(f"Usage:       {usage['input_tokens']} in, {usage['output_tokens']} out")
print(f"Cost:        ${cost:.6f}")
print()
print("`stop_reason: tool_use` means the model wants a tool run. Acting on that")
print("is step 05 — the Agent Loop. This step stops at the round trip.")
