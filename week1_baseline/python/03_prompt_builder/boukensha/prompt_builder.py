"""The prompt builder: where conversation, capability, and provider meet."""

from collections.abc import Mapping
from typing import TYPE_CHECKING, Any

from .tasks.base import DEFAULT_MAX_OUTPUT_TOKENS

if TYPE_CHECKING:  # for the annotations only
    from .backends.base import Backend
    from .context import Context
    from .tool import Tool


class PromptBuilder:
    """Joins a `Context` and a tool catalog to a `Backend` and produces a payload.

    Steps 01–02 built the two halves of an API call and kept them orthogonal: a
    context is the conversation, a registry is the capability set. This is the
    object that puts them together, hands them to a backend, and gets back the
    exact JSON an LLM API expects.

    It takes the **catalog**, not the `Registry` — it reads `name`,
    `description`, `parameters` and `required`, and never dispatches. Step 05's
    tools-disabled turn is then `PromptBuilder(ctx, backend, tools={})`, with no
    extra parameter and no `tools.nil? ?` ternary. See
    `docs/adr/0004-registry-owns-the-tool-catalog.md`.
    """

    def __init__(
        self,
        context: Context,
        backend: Backend,
        *,
        tools: Mapping[str, Tool],
    ) -> None:
        self._context = context
        self._backend = backend
        # Deliberately NOT copied. `Registry.tools` is a live view, so a builder
        # constructed before registration still sees tools registered later —
        # which is what step 07's `RunDSL` needs, since it registers inside a
        # block. A defensive copy would silently freeze the catalog.
        self._tools = tools

    def to_messages(self) -> list[dict[str, Any]]:
        """The conversation in the backend's message shape."""
        return self._backend.to_messages(self._context)

    def to_tools(self) -> list[dict[str, Any]]:
        """The catalog in the backend's tool-definition shape."""
        return self._backend.to_tools(self._tools)

    def to_api_payload(self, *, max_output_tokens: int | None = None) -> dict[str, Any]:
        """The complete request body for one call.

        `max_output_tokens` resolves here and nowhere else: the explicit argument
        wins, then the task's setting, then `DEFAULT_MAX_OUTPUT_TOKENS`. Ruby
        hardcodes `1024` in this method *and* in every backend's `to_payload`;
        the backend's is a required keyword here, so there is one default and one
        resolution point.
        """
        if max_output_tokens is None:
            task = self._context.task  # `Context.task` is optional, hence the guard
            max_output_tokens = (
                DEFAULT_MAX_OUTPUT_TOKENS if task is None else task.max_output_tokens
            )
        return self._backend.to_payload(
            self._context, self._tools, max_output_tokens=max_output_tokens
        )

    def headers(self, api_key: str) -> Mapping[str, str]:
        """The request headers. A method, not a property — it takes the credential.

        Nothing in the library reads the environment; the caller fetches the key
        and passes it. See `docs/adr/0007-backend-holds-no-credentials.md`.
        """
        return self._backend.headers(api_key)

    @property
    def url(self) -> str:
        """The endpoint the payload is posted to. Step 04 does the posting."""
        return self._backend.url
