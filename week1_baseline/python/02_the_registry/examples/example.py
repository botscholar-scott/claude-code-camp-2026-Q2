"""Runnable smoke test for step 2 — the only safety net this step has."""

import os
import sys
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(STEP_DIR))

# Override the config directory so the example works from the repo root.
# In real usage a user's ~/.boukensha is picked up automatically.
# examples -> 02_the_registry -> python -> week1_baseline -> repo root
REPO_ROOT = STEP_DIR.parent.parent.parent
os.environ.setdefault("BOUKENSHA_DIR", str(REPO_ROOT / ".boukensha"))

# noqa: E402 throughout — these need the sys.path insert above.
from boukensha import Config, Context, Player, Registry, UnknownToolError  # noqa: E402

config = Config.load()
player = Player.from_config(config)

# Two orthogonal objects: the context carries the conversation, the registry
# carries the capabilities. Neither knows about the other, so the registry needs
# no argument. Step 03 is where they meet.
ctx = Context(task=player, system=player.system_prompt)
registry = Registry()


@registry.tool(
    "move",
    description="Move the player in a direction (north, south, east, west, up, down)",
    parameters={"direction": {"type": "string", "description": "The direction to move"}},
)
def move(direction):
    return f"You move {direction} into a torch-lit corridor."


@registry.tool(
    "shout",
    description="Shout a message so everyone in the zone can hear it",
    parameters={"message": {"type": "string", "description": "What to shout"}},
)
def shout(message):
    return message.upper()


print("=== Boukensha Step 2: The Tool Registry ===")
print()
print(f"Config:   {config!r}")
print(f"Context:  {ctx!r}")
print("Tools:")
for tool in registry.tools.values():
    print(f"  {tool!r}")
print()

# Mimicking what the agent will do once it can decide *when* to call a tool: it
# emits a name and a set of arguments, and the registry does the rest.
print("Dispatching 'shout' with message='dragon spotted'...")
print(f"Result: {registry.dispatch('shout', {'message': 'dragon spotted'})}")
print()

print("Dispatching 'move' with direction='north'...")
print(f"Result: {registry.dispatch('move', {'direction': 'north'})}")
print()

try:
    registry.dispatch("flee")
except UnknownToolError as error:
    print(f"UnknownToolError caught: {error}")
