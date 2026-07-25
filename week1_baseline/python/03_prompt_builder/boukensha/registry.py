"""The registry: what the agent can do, and how one gets run."""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from types import MappingProxyType
from typing import Any

from .errors import UnknownToolError
from .tool import Tool


class Registry:
    """The catalog of tools the agent may use, and the thing that runs one.

    It has two jobs: storing tools, and dispatching a tool when the agent asks
    for it by name. The agent never calls a tool directly — it emits a name and
    a set of arguments, and the registry does the lookup.

    The registry holds the **only** tool table; a `Context` has none. The two
    objects are orthogonal — a context is the conversation, a registry is the
    capability set — and neither holds a reference to the other. Callers compose
    them. See `docs/adr/0004-registry-owns-the-tool-catalog.md`.
    """

    def __init__(self) -> None:
        self._tools: dict[str, Tool] = {}
        # Built once; a fresh proxy per access would cost for nothing.
        self._tools_view: Mapping[str, Tool] = MappingProxyType(self._tools)

    @property
    def tools(self) -> Mapping[str, Tool]:
        """The registered tools, keyed by name, in registration order."""
        return self._tools_view

    def tool[F: Callable[..., Any]](
        self,
        name: str,
        *,
        description: str,
        parameters: Mapping[str, Any] | None = None,
        required: Sequence[str] | None = None,
    ) -> Callable[[F], F]:
        """Decorator factory that registers the function it decorates as a tool.

        `F` is bound to the decorated function's own type, so a type checker sees
        `move` keep its signature after decoration — the handler passes through
        unchanged.

        Ruby attaches the handler with a trailing block; Python has no block, so
        the handler arrives as the decorated function:

            @registry.tool("move", description="…", parameters={…})
            def move(direction): ...

        Returns the handler **unchanged**, so `move` stays a plain callable you
        can invoke and test directly. The `Tool` is reachable as
        `registry.tools["move"]` when it is wanted. Ruby returns the tool
        instead; see `docs/adr/0005-tools-register-via-decorator.md`.

        Registration happens when the decorator is *applied*, so a duplicate name
        raises `ValueError` at `def` time rather than at dispatch.

        `required` names the parameters the model must supply. Omitting it means
        **all** of them, which is what the Ruby always does — so every existing
        call site keeps its behaviour exactly. A tool with optional arguments now
        has a way to say so:

            @registry.tool(
                "look_at",
                description="…",
                parameters={"target": {…}, "preposition": {…}},
                required=[],
            )
            def look_at(target=None, preposition=None): ...
        """

        def register(handler: F) -> F:
            if name in self._tools:
                raise ValueError(f"a tool named {name!r} is already registered")
            self._tools[name] = Tool(
                name, description, parameters or {}, handler, required
            )
            return handler

        return register

    def dispatch(self, name: str, args: Mapping[str, Any] | None = None) -> Any:
        """Look a tool up by name and run its handler with `args` as keywords.

        Raises `UnknownToolError` on a name with no registered tool — a harness
        needs an explicit error boundary here, because an unrecognised tool name
        must never silently do nothing.

        Arguments the handler does not accept raise `TypeError` from Python
        itself; nothing is guarded, which matches the Ruby. Exceptions from the
        handler propagate uncaught — turning a tool failure into a tool *result*
        the model can read is the agent loop's job, not the registry's.
        """
        tool = self._tools.get(name)
        if tool is None:
            raise UnknownToolError(f"No tool registered as {name!r}")
        return tool.handler(**(args or {}))
