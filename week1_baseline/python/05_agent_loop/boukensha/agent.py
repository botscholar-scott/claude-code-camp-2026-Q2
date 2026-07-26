"""The agent loop: where the player's goal becomes work.

Steps 00–04 built the parts and never joined them — a `Context` nobody advanced,
a `Registry` nobody dispatched from, a `PromptBuilder` whose payload was posted
exactly once. This is the step where the ladder becomes an agent:

    send the history  →  read the reply  →  dispatch the tools it asked for
          ↑                                              │
          └──────────────────────────────────────────────┘
                    until the model stops, or the ceiling hits
"""

from collections.abc import Mapping
from typing import TYPE_CHECKING, Any

from .errors import ApiError, UnknownToolError
from .logging import AgentLogger, NullLogger
from .message import Role
from .prompt_builder import PromptBuilder
from .reply import Reply, StopReason
from .tasks.base import DEFAULT_MAX_ITERATIONS

if TYPE_CHECKING:  # for the annotations only
    from .backends.base import Backend
    from .client import Client
    from .context import Context
    from .registry import Registry

#: The wind-down call is deliberately short and cheap.
WRAP_UP_OUTPUT_TOKENS = 400

#: Sent to the model when the ceiling is reached. Ruby says "for this turn"; the
#: word means three different things across this project (see `CONTEXT.md`), so
#: this says what the player actually cares about instead.
WRAP_UP_DIRECTIVE = (
    "You have reached your action limit. Do not call any more tools. "
    "Briefly summarize what you accomplished, what is still unfinished, "
    "and the single next action you would take."
)


class Agent:
    """Drives a goal to an answer: model call, tool dispatch, repeat.

    ```python
    agent = Agent(context, registry, backend, client)
    answer = agent.run()
    ```

    It takes the **backend**, not a builder. Ruby's `Agent` holds a builder and
    reaches `@builder.parse_response(response)`, which only exists as a
    pass-through to the backend — and parsing is the *inbound* direction, which
    needs neither a context nor a tool catalog. Taking the backend lets the agent
    construct both of its builders itself, so a caller never names one.

    The `Context` is **borrowed, not owned.** The agent appends to it and never
    replaces it, so a caller can hydrate one from disk, run, and write it back.
    """

    def __init__(
        self,
        context: "Context",
        registry: "Registry",
        backend: "Backend",
        client: "Client",
        *,
        max_iterations: int | None = None,
        max_output_tokens: int | None = None,
        logger: AgentLogger | None = None,
    ) -> None:
        self._context = context
        self._registry = registry
        self._backend = backend
        self._client = client
        self._logger = logger or NullLogger()

        # Both builders are derived, not injected: a PromptBuilder is fully
        # determined by (context, backend, tools), all of which we hold. The
        # bare one is the tools-disabled wind-down call — the forward check
        # `docs/adr/0009-client-transports-payloads.md` asserted but could not
        # run. No `tools=` parameter is added to anything.
        self._tools_builder = PromptBuilder(context, backend, tools=registry.tools)
        self._bare_builder = PromptBuilder(context, backend, tools={})

        self._max_iterations = self._resolve_max_iterations(max_iterations)
        # Left as `None` unless given: `PromptBuilder.to_api_payload` already
        # resolves it from the task, and ADR 0009's whole point is that there is
        # exactly one resolution point.
        self._max_output_tokens = max_output_tokens
        self._iteration = 0

    def run(self) -> str:
        """Work the goal until the model stops, and return its final text.

        Raises `ApiError` if a call fails inside the loop, and anything a tool
        raises that is not the model's own mistake — see `_handle_tool_calls`.
        """
        while True:
            # A limit is a *trigger threshold*, not a hard cap: on reaching it we
            # stop starting new work and make exactly one terminal wind-down call
            # instead of raising.
            if self._limit_reached():
                self._logger.limit_reached(
                    kind="max_iterations",
                    n=self._iteration,
                    limit=self._max_iterations,
                )
                return self._wrap_up()

            self._iteration += 1
            self._logger.iteration(n=self._iteration, limit=self._max_iterations)

            reply = self._call(self._tools_builder)
            # Anything that is not TOOL_USE ends the run — including MAX_TOKENS,
            # whose `tool_use` blocks are therefore *not* dispatched. Ruby
            # dispatches nothing here either, but only because its ternary has
            # already relabelled the truncated reply `end_turn`.
            if reply.stop_reason is not StopReason.TOOL_USE:
                return reply.text
            self._handle_tool_calls(reply)

    # ---------- internals -----------------------------------------------------

    def _resolve_max_iterations(self, explicit: int | None) -> int:
        """Explicit argument, then the task's setting, then the default.

        `0` disables the ceiling, as in Ruby (`@max_iterations.positive? && …`).
        """
        if explicit is not None:
            return int(explicit)
        task = self._context.task  # `Context.task` is optional, hence the guard
        return DEFAULT_MAX_ITERATIONS if task is None else task.max_iterations

    def _limit_reached(self) -> bool:
        return self._max_iterations > 0 and self._iteration >= self._max_iterations

    def _call(
        self, builder: PromptBuilder, *, max_output_tokens: int | None = None
    ) -> Reply:
        """One model round-trip, normalized.

        The raw response is handed straight to the backend; nothing above this
        line ever sees a provider-shaped dict.
        """
        if max_output_tokens is None:
            max_output_tokens = self._max_output_tokens
        payload = builder.to_api_payload(max_output_tokens=max_output_tokens)
        return self._backend.parse_response(self._client.call(payload))

    def _handle_tool_calls(self, reply: Reply) -> None:
        """Run every tool the reply asked for and record each result."""
        # The assistant's `tool_use` blocks MUST be in the history before their
        # `tool_result`, or the API rejects the next request. This is the reason
        # `Message.content` had to widen beyond `str` at this step.
        self._context.add_message(Role.ASSISTANT, reply.content)

        for block in reply.tool_uses:
            self._logger.tool_call(name=block.name, args=block.input)
            text, is_error = self._dispatch(block.name, block.input)
            self._logger.tool_result(name=block.name, result=text, is_error=is_error)
            # One message per block. Measured identical to the single-message,
            # N-block form — see the README, "Parallel tool calls".
            self._context.add_message(
                Role.TOOL_RESULT, text, tool_use_id=block.id, is_error=is_error
            )

    def _dispatch(self, name: str, args: Mapping[str, Any]) -> tuple[str, bool]:
        """Run one tool, returning what the model should read and whether it failed.

        **Only the model's own mistakes are caught.** An invented tool name
        (`UnknownToolError`) and a wrong keyword (`TypeError`) are things the
        model can read and correct on the next iteration. A dropped MUD socket or
        a bug in a handler is not — handing those back as a tool result buys
        another two dozen commands into a dead connection, at real cost, followed
        by a confident summary of a session that never happened. Those propagate.
        See `docs/adr/0010-agent-catches-model-mistakes.md`.
        """
        try:
            return str(self._registry.dispatch(name, args)), False
        except (UnknownToolError, TypeError) as exc:
            return f"{type(exc).__name__}: {exc}", True

    def _wrap_up(self) -> str:
        """One final, tools-disabled call so the run ends in character.

        Runs *outside* the counted loop: it never re-checks the limit (so it
        cannot re-trigger) and does not increment the iteration counter. When the
        ceiling hits, the character is somewhere — mid-dungeon, torch lit or
        not — and telling the player where they ended up is worth more than
        telling them a limit was reached.
        """
        self._context.add_message(Role.USER, WRAP_UP_DIRECTIVE)
        try:
            reply = self._call(
                self._bare_builder, max_output_tokens=WRAP_UP_OUTPUT_TOKENS
            )
        except ApiError:
            # The single-`except` case step 04's `ApiError` docstring predicted —
            # the reason it is one class and not a hierarchy.
            return self._fallback()
        return reply.text.strip() or self._fallback()

    def _fallback(self) -> str:
        """What the player is told when even the wind-down call fails."""
        return (
            f"I reached my {self._max_iterations}-action limit before finishing. "
            "Ask me to continue and I'll pick up from here."
        )

    def __repr__(self) -> str:
        return (
            f"Agent(iteration={self._iteration}, "
            f"max_iterations={self._max_iterations}, "
            f"tools={list(self._registry.tools)!r})"
        )
