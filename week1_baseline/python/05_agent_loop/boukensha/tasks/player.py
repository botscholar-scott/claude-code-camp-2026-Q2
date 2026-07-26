"""The player task — the main agentic loop."""

from typing import ClassVar

from .base import Task


class Player(Task):
    NAME: ClassVar[str] = "player"
