"""The context: everything one API call needs, and the one mutable object here."""

from collections.abc import Mapping, Sequence
from types import MappingProxyType
from typing import TYPE_CHECKING

from .message import Message, Role
from .tool import Tool

if TYPE_CHECKING:  # for the annotation only — avoids importing the tasks package
    from .tasks.base import Task


class Context:
    """Everything Boukensha needs to make an API call. Nothing lives outside it.

    A plain mutable class, not a frozen dataclass: a context is the accumulating
    state of a run — messages arrive every turn and tools are registered at
    startup. `Tool` and `Message` are the frozen value objects it holds. See
    `docs/adr/0003-context-is-the-mutable-object.md`.

    The collections are encapsulated: read them through `messages` / `tools` and
    write through `add_message` / `register_tool`.
    """

    def __init__(self, *, task: Task | None = None, system: str | None = None) -> None:
        self.task = task
        self.system = system
        self._messages: list[Message] = []
        self._tools: dict[str, Tool] = {}
        # Built once; a fresh proxy per access would cost for nothing.
        self._tools_view: Mapping[str, Tool] = MappingProxyType(self._tools)

    @property
    def messages(self) -> Sequence[Message]:
        """The full conversation history, replayed on every turn.

        Read-only by type, not by enforcement — Python has no zero-copy
        read-only list view, and a defensive copy would be paid once per turn by
        the agent loop. `tools` below *is* enforced; the asymmetry is deliberate.
        """
        return self._messages

    @property
    def tools(self) -> Mapping[str, Tool]:
        """The registered tools the agent may invoke, keyed by tool name."""
        return self._tools_view

    def register_tool(self, tool: Tool) -> None:
        """Register a tool. Raises `ValueError` if the name is already taken."""
        if tool.name in self._tools:
            raise ValueError(
                f"a tool named {tool.name!r} is already registered on this context"
            )
        self._tools[tool.name] = tool

    def add_message(
        self,
        role: Role | str,
        content: str,
        *,
        tool_use_id: str | None = None,
    ) -> None:
        """Append a message. A role outside `Role` raises `ValueError`."""
        self._messages.append(Message(role, content, tool_use_id))

    def __repr__(self) -> str:
        task = None if self.task is None else self.task.name
        return (
            f"Context(task={task!r}, turns={len(self._messages)}, "
            f"tools={len(self._tools)})"
        )
