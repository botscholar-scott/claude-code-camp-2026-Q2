"""A message: one unit of conversation, and the closed set of roles it may have."""

from collections.abc import Sequence
from dataclasses import dataclass
from enum import StrEnum

from ._repr import truncate
from .content import ContentBlock

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

    `content` is prose for a `USER` or `TOOL_RESULT` message, and either prose or
    a sequence of `ContentBlock`s for an `ASSISTANT` one. The block form is not
    optional: Anthropic requires the assistant's `tool_use` block to be in the
    history before its matching `tool_result`, so step 05's loop has to store
    exactly what the model sent. Ruby's `Context` is untyped and stores raw
    hashes; this names the two shapes instead.

    `tool_use_id` and `is_error` are only meaningful on `TOOL_RESULT` messages.
    Neither pairing is validated here; enforcing it belongs to the backend that
    builds the payload.
    """

    role: Role
    content: str | Sequence[ContentBlock]
    tool_use_id: str | None = None
    is_error: bool = False

    def __post_init__(self) -> None:
        # Coerce here rather than in `Context.add_message`, so a directly
        # constructed `Message("usr", …)` fails at the call site too.
        object.__setattr__(self, "role", Role(self.role))
        if not isinstance(self.content, str):
            # Frozen with a list inside is not frozen — as with `Tool.parameters`.
            object.__setattr__(self, "content", tuple(self.content))

    def __repr__(self) -> str:
        # Omitted when absent, mirroring Ruby's conditional `id_tag`.
        id_tag = "" if self.tool_use_id is None else f"tool_use_id={self.tool_use_id!r}, "
        error_tag = "is_error=True, " if self.is_error else ""
        content = (
            repr(truncate(self.content, CONTENT_REPR_LIMIT))
            if isinstance(self.content, str)
            else truncate(repr(list(self.content)), CONTENT_REPR_LIMIT)
        )
        # `.value`, not `!r` on the member: an enum's repr is `<Role.USER: 'user'>`,
        # which `StrEnum` does not override — only `str()` and `format()`.
        return (
            f"Message(role={self.role.value!r}, {id_tag}{error_tag}content={content})"
        )
