"""The context: the conversation half of an API call, and the one mutable object here."""

from collections.abc import Sequence
from typing import TYPE_CHECKING

from .message import Message, Role

if TYPE_CHECKING:  # for the annotation only — avoids importing the tasks package
    from .tasks.base import Task


class Context:
    """The conversation: the system prompt, the message history, and the task.

    It is one half of what an API call needs. The other half is a `Registry`,
    which holds the tools — a context has none, and the two objects hold no
    reference to each other. See
    `docs/adr/0004-registry-owns-the-tool-catalog.md` for why that changed at
    step 02.

    A plain mutable class, not a frozen dataclass: a context is the accumulating
    state of a run, and messages arrive every turn. `Message` is the frozen value
    object it holds. See `docs/adr/0003-context-is-the-mutable-object.md`.

    The history is encapsulated: read it through `messages`, write it through
    `add_message`.
    """

    def __init__(self, *, task: Task | None = None, system: str | None = None) -> None:
        self.task = task
        self.system = system
        self._messages: list[Message] = []

    @property
    def messages(self) -> Sequence[Message]:
        """The full conversation history, replayed on every turn.

        Read-only by type, not by enforcement — Python has no zero-copy
        read-only list view, and a defensive copy would be paid once per turn by
        the agent loop. `Registry.tools` *is* enforced; the asymmetry is
        deliberate.
        """
        return self._messages

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
        return f"Context(task={task!r}, turns={len(self._messages)})"
