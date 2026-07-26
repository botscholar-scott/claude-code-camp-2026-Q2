"""Where the loop's progress goes — which is nowhere, unless a caller says so.

Ruby calls `puts` from inside `Agent#run` and `#handle_tool_calls`, then unpicks
it at step 08 by injecting a logger. Two reasons not to inherit the interim
state: a library that writes to stdout unbidden is a genuine Python smell, and
step 06 *is* the logger, so the seam is one rung away rather than three.

Method names and keyword shapes are taken from Ruby's step-08 logger
(`iteration(n:, max:)`, `limit_reached(kind:, n:, max:)`) so step 06 converges on
it rather than diverging. `max` becomes `limit` — `max` shadows a builtin.

See `docs/adr/0011-agent-logger-protocol.md`.
"""

from collections.abc import Mapping
from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class AgentLogger(Protocol):
    """What the agent reports as it works.

    Structural, not inherited: `examples/example.py` supplies a plain class with
    these four methods and never imports this one. `runtime_checkable` so an
    `isinstance` smoke check is available; it verifies method *names* only.
    """

    def iteration(self, *, n: int, limit: int) -> None:
        """A new model round-trip is starting. `limit` is `0` when uncapped."""

    def tool_call(self, *, name: str, args: Mapping[str, Any]) -> None:
        """The model asked for a tool, with these arguments."""

    def tool_result(self, *, name: str, result: str, is_error: bool) -> None:
        """What the tool returned — or the message the model will read instead."""

    def limit_reached(self, *, kind: str, n: int, limit: int) -> None:
        """A ceiling was hit. The wind-down call follows; the run does not raise."""


class NullLogger:
    """The default. A library writes nothing to stdout unbidden.

    Four empty methods rather than a `__getattr__` catch-all: the explicit
    version is what a type checker matches against `AgentLogger`, and it fails
    loudly if the protocol gains a method this class forgets.
    """

    def iteration(self, *, n: int, limit: int) -> None: ...

    def tool_call(self, *, name: str, args: Mapping[str, Any]) -> None: ...

    def tool_result(self, *, name: str, result: str, is_error: bool) -> None: ...

    def limit_reached(self, *, kind: str, n: int, limit: int) -> None: ...
