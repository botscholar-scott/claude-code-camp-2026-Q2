"""A message: one unit of conversation, and the closed set of roles it may have."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from ._repr import truncate

#: How much of `content` the repr shows before cutting.
CONTENT_REPR_LIMIT = 60


class Role(StrEnum):
    """Who is speaking in a message.

    `TOOL_RESULT` is a pseudo-role: no provider has it. Backends translate it
    into a provider `user` message carrying a `tool_result` content block.

    A `StrEnum` rather than a bare `Enum` so members *are* strings — they
    interpolate, compare, and serialise as `"user"` with no conversion.
    """

    USER = "user"
    ASSISTANT = "assistant"
    TOOL_RESULT = "tool_result"


@dataclass(frozen=True, slots=True, repr=False)
class Message:
    """One unit of conversation: who spoke, what was said, and — for a tool
    result — which tool call it answers.

    `tool_use_id` is only set on `TOOL_RESULT` messages. The pairing is not
    validated here; enforcing it belongs to the backend that builds the payload.
    """

    role: Role
    content: str
    tool_use_id: str | None = None

    def __post_init__(self) -> None:
        # Coerce here rather than in `Context.add_message`, so a directly
        # constructed `Message("usr", …)` fails at the call site too.
        object.__setattr__(self, "role", Role(self.role))

    def __repr__(self) -> str:
        # Omitted when absent, mirroring Ruby's conditional `id_tag`.
        id_tag = "" if self.tool_use_id is None else f"tool_use_id={self.tool_use_id!r}, "
        content = truncate(self.content, CONTENT_REPR_LIMIT)
        # `.value`, not `!r` on the member: an enum's repr is `<Role.USER: 'user'>`,
        # which `StrEnum` does not override — only `str()` and `format()`.
        return f"Message(role={self.role.value!r}, {id_tag}content={content!r})"
