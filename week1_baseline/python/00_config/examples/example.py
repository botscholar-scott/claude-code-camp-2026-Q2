"""Runnable smoke test for step 0 — the only safety net this step has."""

import os
import sys
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(STEP_DIR))

# Override the config directory so the example works from the repo root.
# In real usage a user's ~/.boukensha is picked up automatically.
# examples -> 00_config -> python -> week1_baseline -> repo root
REPO_ROOT = STEP_DIR.parent.parent.parent
os.environ.setdefault("BOUKENSHA_DIR", str(REPO_ROOT / ".boukensha"))

from boukensha import Config, Player  # noqa: E402  (needs the sys.path insert above)

config = Config.load()
player = Player.from_config(config)

print("=== Boukensha Step 0: Configuration ===")
print()
print(f"Config dir:     {config.dir}")
print(f"Tasks:          {', '.join(config.tasks)}")
print()
print("-- player task --")
print(f"Provider:       {player.provider}")
print(f"Model:          {player.model}")
print(f"Prompt override?{player.prompt_override.get('system', False)}")
print(f"System prompt:  {(player.system_prompt or '')[:60]}...")
print()
print(f"MUD host:       {config.mud.host}:{config.mud.port}")
print(f"MUD user:       {config.mud.username}")
print()
print(f"API key set?    {'ANTHROPIC_API_KEY' in os.environ}")
print()
print(config)
