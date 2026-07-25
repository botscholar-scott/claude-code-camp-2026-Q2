"""Runnable smoke test for step 1 — the only safety net this step has."""

import os
import sys
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(STEP_DIR))

# Override the config directory so the example works from the repo root.
# In real usage a user's ~/.boukensha is picked up automatically.
# examples -> 01_struct_skeleton -> python -> week1_baseline -> repo root
REPO_ROOT = STEP_DIR.parent.parent.parent
os.environ.setdefault("BOUKENSHA_DIR", str(REPO_ROOT / ".boukensha"))

# noqa: E402 throughout — these need the sys.path insert above.
from boukensha import Config, Context, Player, Tool  # noqa: E402

config = Config.load()
player = Player.from_config(config)

ctx = Context(task=player, system=player.system_prompt)

ctx.register_tool(
    Tool(
        "move",
        "Move the player in a direction (north, south, east, west, up, down)",
        {"direction": {"type": "string", "description": "The direction to move"}},
        lambda direction: f"You move {direction} into a torch-lit corridor.",
    )
)

ctx.add_message("user", "Explore north and tell me what you find.")
ctx.add_message("assistant", "Sure, let me head north and take a look.")

print("=== Boukensha Step 1: Struct Skeleton ===")
print()
print(f"Config:   {config!r}")
print(f"Context:  {ctx!r}")
print(f"Tool:     {ctx.tools['move']!r}")
print("Messages:")
for message in ctx.messages:
    print(f"  {message!r}")
