"""Runnable smoke test for step 3 — the only safety net this step has.

Nothing here makes a network call. `ANTHROPIC_API_KEY` is read only so the
header shape can be printed, and the example runs fine without it.
"""

import json
import os
import sys
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(STEP_DIR))

# Override the config directory so the example works from the repo root.
# In real usage a user's ~/.boukensha is picked up automatically.
# examples -> 03_prompt_builder -> python -> week1_baseline -> repo root
REPO_ROOT = STEP_DIR.parent.parent.parent
os.environ.setdefault("BOUKENSHA_DIR", str(REPO_ROOT / ".boukensha"))

# noqa: E402 throughout — these need the sys.path insert above.
from boukensha import (  # noqa: E402
    AnthropicBackend,
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


ctx.add_message(
    "user", "I just arrived in the dungeon. What's around me, and can you move north?"
)
ctx.add_message("assistant", "Let me take a look around first.")
ctx.add_message(
    "tool_result",
    "A damp stone corridor stretches north. Torches flicker on the walls.",
    tool_use_id="toolu_01X",
)

# The provider seam: one lookup, no `case` statement, and no credential.
backend = backend_for(player)
builder = PromptBuilder(ctx, backend, tools=registry.tools)

print("=== Boukensha Step 3: The Prompt Builder ===")
print()
print(f"Config:         {config!r}")
print(f"Provider:       {player.provider}")
print(f"Model:          {backend.model}")
print(f"Context window: {backend.context_window:,} tokens")
print(f"URL:            {builder.url}")
print()

# The key is read here, at the point of use — never by the library. The example
# runs with it unset, because this step sends nothing.
api_key = os.environ.get(AnthropicBackend.API_KEY_ENV)
print("Headers (x-api-key redacted):")
for name, value in builder.headers(api_key or "<unset>").items():
    print(f"  {name}: {'***' if name == 'x-api-key' else value}")
print()

# Ruby's `to_messages` and `to_tools` are public but never called anywhere in
# the twelve steps. Printing them shows the two shapes the READMEs describe.
print("to_messages():")
print(json.dumps(builder.to_messages(), indent=2))
print()

print("to_tools():")
print(json.dumps(builder.to_tools(), indent=2))
print()

print("to_api_payload():")
print(json.dumps(builder.to_api_payload(), indent=2))
