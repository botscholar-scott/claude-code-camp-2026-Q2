"""Configuration for Boukensha, read from an external `.boukensha/` directory.

`Config.load()` is the only thing in this package that touches the filesystem:
it resolves the config directory, loads `.env`, and parses the settings file.
What it returns is frozen, plain data — no attribute access does hidden I/O.
"""

import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any, ClassVar, Self

import yaml
from dotenv import load_dotenv

# The .boukensha config directory is resolved in this order:
#   1. BOUKENSHA_DIR environment variable (read before .env is loaded)
#   2. ~/.boukensha  (the default location for a real install)
DEFAULT_DIR = Path.home() / ".boukensha"

# Accepted settings filenames, in preference order.
SETTINGS_FILENAMES = ("settings.yaml", "settings.yml")

# Default prompts shipped alongside the library code.
PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"

DEFAULT_MUD_HOST = "localhost"
DEFAULT_MUD_PORT = 4000


@dataclass(frozen=True, slots=True)
class Mud:
    """MUD connection details for the main player."""

    host: str = DEFAULT_MUD_HOST
    port: int = DEFAULT_MUD_PORT
    username: str | None = None
    password: str | None = None

    @classmethod
    def from_settings(cls, settings: Mapping[str, Any] | None) -> Self:
        """Build from the `mud:` block. A missing or malformed block gives defaults."""
        if not isinstance(settings, Mapping):
            settings = {}

        port = settings.get("port")
        return cls(
            host=settings.get("host") or DEFAULT_MUD_HOST,
            port=DEFAULT_MUD_PORT if port is None else int(port),
            username=settings.get("username"),
            password=settings.get("password"),
        )


@dataclass(frozen=True, slots=True, repr=False)
class Config:
    """A loaded `.boukensha/` directory.

    Build with `Config.load()`; the constructor takes already-resolved data.
    """

    dir: Path
    #: The raw parsed settings file — the escape hatch for keys not yet modelled.
    settings: Mapping[str, Any]
    mud: Mud

    DEFAULT_DIR: ClassVar[Path] = DEFAULT_DIR
    PROMPTS_DIR: ClassVar[Path] = PROMPTS_DIR

    @classmethod
    def load(cls) -> Self:
        """Resolve the config directory, load `.env`, then parse the settings file."""
        directory = cls._resolve_dir()
        cls._load_env(directory)
        settings = cls._load_settings(directory)

        return cls(
            dir=directory,
            settings=MappingProxyType(settings),
            mud=Mud.from_settings(settings.get("mud")),
        )

    # ---------- tasks -----------------------------------------------------

    @property
    def tasks(self) -> Mapping[str, Any]:
        """The full `tasks:` map from the settings file, keyed by task name."""
        tasks = self.settings.get("tasks")
        return tasks if isinstance(tasks, Mapping) else {}

    def task(self, name: str) -> Mapping[str, Any] | None:
        """One task's settings, or `None` when that task is not configured."""
        return self.tasks.get(name)

    @property
    def user_prompts_dir(self) -> Path:
        """The user's prompts directory, holding per-task prompt overrides."""
        return self.dir / "prompts"

    # ---------- secrets ---------------------------------------------------

    def require_secret(self, name: str) -> str:
        """The value of an environment variable that must be present.

        `Config.load()` has already run `load_dotenv()` on the config dir, so
        this reads through to whatever `.env` supplied. Keeping the read here
        rather than at the call site means the class that loaded the file is the
        class that hands back its values — and the error can name the file.

        The alternative, a bare `os.environ[...]` at the call site, works only
        because `Config.load()` ran first; reorder the two lines and it silently
        reads an ambient key or raises. That temporal coupling through a global
        is what this removes.

        `ValueError`, not a `BoukenshaError` subclass: *absent* config is a
        `ValueError` and *unknown* config is a `BoukenshaError` — the same rule
        `Task.from_settings` follows. A missing key is absent.
        """
        value = os.environ.get(name)
        if not value:
            raise ValueError(
                f"{name} is not set. Add it to {self.dir / '.env'} or export it."
            )
        return value

    # ---------- low-level helpers -----------------------------------------

    def dig(self, *keys: str) -> Any:
        """Fetch a nested key path from settings, e.g. `dig("mud", "host")`."""
        node: Any = self.settings
        for key in keys:
            if not isinstance(node, Mapping):
                return None
            node = node.get(key)
        return node

    def __repr__(self) -> str:
        # Hand-written on purpose: `settings` holds mud.password, and the
        # generated repr would print the whole YAML.
        return f"Config(dir={str(self.dir)!r}, tasks={list(self.tasks)!r})"

    # ---------- loading ---------------------------------------------------

    @staticmethod
    def _resolve_dir() -> Path:
        # Resolved before `.env` is loaded, so `.env` cannot redirect the
        # directory it was itself read from.
        raw = os.environ.get("BOUKENSHA_DIR") or DEFAULT_DIR
        return Path(raw).expanduser().resolve()

    @staticmethod
    def _load_env(directory: Path) -> None:
        env_file = directory / ".env"
        if env_file.is_file():
            # Does not override already-set variables, matching Dotenv.load.
            load_dotenv(env_file)

    @staticmethod
    def _load_settings(directory: Path) -> dict[str, Any]:
        for filename in SETTINGS_FILENAMES:
            path = directory / filename
            if path.is_file():
                settings = yaml.safe_load(path.read_text(encoding="utf-8"))
                return settings if isinstance(settings, dict) else {}
        return {}
