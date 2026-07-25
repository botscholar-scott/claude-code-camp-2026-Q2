"""The player task — the main agentic loop."""

from __future__ import annotations

from typing import ClassVar

from .base import Task


class Player(Task):
    NAME: ClassVar[str] = "player"
