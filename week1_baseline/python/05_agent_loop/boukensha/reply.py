"""The normalized reply: what every backend turns a raw response into.

The loop never inspects a provider response. It reads a `Reply` — a stop reason
and a tuple of content blocks — which is the whole reason `agent.py` has one
branch instead of one per provider.
"""

from dataclasses import dataclass
from enum import StrEnum

from .content import ContentBlock, TextBlock, ToolUseBlock


class StopReason(StrEnum):
    """Why the model stopped. A closed vocabulary with an open escape hatch.

    Ruby collapses this to two values with a ternary:

        stop_reason = response["stop_reason"] == "tool_use" ? "tool_use" : "end_turn"

    which makes a reply cut off at the token ceiling indistinguishable from one
    the model chose to end — and the loop then returns the truncated text as the
    final answer. `MAX_TOKENS` exists here so that stops being invisible.

    Three named members, not Anthropic's six: `refusal`, `pause_turn` and
    `stop_sequence` have no caller in this step, and `_missing_` makes naming
    one later a purely additive change.
    """

    TOOL_USE = "tool_use"  # the loop's only continuation branch
    END_TURN = "end_turn"  # the model chose to stop
    MAX_TOKENS = "max_tokens"  # truncated — NOT the same as finished
    OTHER = "other"  # refusal, pause_turn, stop_sequence, anything new

    @classmethod
    def _missing_(cls, value: object) -> "StopReason":
        # A value we have never seen ends the run rather than crashing it. The
        # verbatim string survives on `Reply.raw_stop_reason`.
        return cls.OTHER


@dataclass(frozen=True, slots=True)
class Reply:
    """One model response, normalized: why it stopped and what it said."""

    stop_reason: StopReason
    content: tuple[ContentBlock, ...]
    #: The verbatim wire value. `OTHER` is lossy; this is not. Step 06 logs it.
    raw_stop_reason: str

    @property
    def text(self) -> str:
        """Every `TextBlock` joined, in order. `""` when the reply is all tools."""
        return "".join(b.text for b in self.content if isinstance(b, TextBlock))

    @property
    def tool_uses(self) -> tuple[ToolUseBlock, ...]:
        """Every tool the model asked for, in order. A reply may carry several."""
        return tuple(b for b in self.content if isinstance(b, ToolUseBlock))
