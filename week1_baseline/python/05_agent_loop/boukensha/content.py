"""Content blocks: the pieces an assistant reply is made of.

Ruby keeps these as raw hashes and every backend re-derives meaning from
`b["type"]` at each site that touches them — `parse_response`, `extract_text`,
`handle_tool_calls`, and each backend's private `assistant_message`. Naming the
two shapes once gives both directions — parse *and* serialize — one vocabulary.

The union is **closed**: a provider block whose `type` is neither `text` nor
`tool_use` (Anthropic's `thinking`, for one) is dropped on parse. See the
README, "What is dropped on parse".
"""

from collections.abc import Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any

from ._repr import truncate

#: How much of `text` the repr shows before cutting.
TEXT_REPR_LIMIT = 60

#: How much of the rendered `input` mapping the repr shows before cutting.
INPUT_REPR_LIMIT = 60


@dataclass(frozen=True, slots=True, repr=False)
class TextBlock:
    """Prose the model wrote. Several may appear in one reply, hence
    `Reply.text` joining rather than picking the first."""

    text: str

    def __repr__(self) -> str:
        return f"TextBlock(text={truncate(self.text, TEXT_REPR_LIMIT)!r})"


@dataclass(frozen=True, slots=True, repr=False)
class ToolUseBlock:
    """A tool the model wants run: which one, with what, and under what id.

    `id` is what pairs the eventual `tool_result` back to this call. Anthropic
    and OpenAI assign one; Ollama and Gemini do not, and Ruby's backends for
    those reuse the tool *name* as the id. Nothing here depends on which
    convention produced the string.
    """

    id: str
    name: str
    input: Mapping[str, Any]

    def __post_init__(self) -> None:
        # Frozen with a mutable mapping inside is not frozen. Copy, then wrap —
        # the same thing `Tool.parameters` already does.
        object.__setattr__(self, "input", MappingProxyType(dict(self.input)))

    def __repr__(self) -> str:
        # `dict(...)` first: `MappingProxyType.__repr__` prints the wrapper.
        args = truncate(repr(dict(self.input)), INPUT_REPR_LIMIT)
        return f"ToolUseBlock(id={self.id!r}, name={self.name!r}, input={args})"


type ContentBlock = TextBlock | ToolUseBlock
