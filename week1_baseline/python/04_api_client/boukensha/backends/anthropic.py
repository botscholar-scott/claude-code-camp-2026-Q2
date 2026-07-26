"""The Anthropic backend — the only one this port ships.

Named `AnthropicBackend`, not `Anthropic`, because the class is a **backend**:
one member of a family sharing a contract. A bare `Anthropic` names the vendor
rather than the role, and reads like the vendor's own client object — which is
exactly the confusion `docs/adr/0008-no-vendor-sdks.md` forbids, since no such
object is ever imported here.
"""

from collections.abc import Mapping
from typing import TYPE_CHECKING, Any, ClassVar, override

from ..message import Role
from .base import Backend, ModelInfo

if TYPE_CHECKING:  # for the annotations only
    from ..context import Context
    from ..tool import Tool

#: The API version header Anthropic requires on every request.
DEFAULT_ANTHROPIC_VERSION = "2023-06-01"


class AnthropicBackend(Backend):
    """Serializes a context and a tool catalog into Anthropic's Messages API shape.

    The model table below is **static tutorial data**, accurate as of
    **2026-07-25**. It is not fetched, and it does not expire on its own — see
    the README for why `claude-sonnet-5` is listed at its standard rate.
    """

    BASE_URL: ClassVar[str] = "https://api.anthropic.com/v1/messages"
    API_KEY_ENV: ClassVar[str] = "ANTHROPIC_API_KEY"

    MODELS: ClassVar[Mapping[str, ModelInfo]] = {
        #                            context window   $/M in  $/M out
        "claude-opus-5":             ModelInfo(1_000_000,  5.0, 25.0),
        "claude-sonnet-5":           ModelInfo(1_000_000,  3.0, 15.0),
        "claude-fable-5":            ModelInfo(1_000_000, 10.0, 50.0),
        "claude-opus-4-8":           ModelInfo(1_000_000,  5.0, 25.0),
        "claude-sonnet-4-6":         ModelInfo(1_000_000,  3.0, 15.0),
        "claude-haiku-4-5":          ModelInfo(  200_000,  1.0,  5.0),
        "claude-haiku-4-5-20251001": ModelInfo(  200_000,  1.0,  5.0),
    }

    @override
    def to_messages(self, context: Context) -> list[dict[str, Any]]:
        """The history as Anthropic messages.

        `TOOL_RESULT` is a pseudo-role no provider has. Anthropic wants it as a
        `user` message whose content is a list holding one `tool_result` block —
        counterintuitive, and correct.
        """
        messages: list[dict[str, Any]] = []
        for message in context.messages:
            if message.role is Role.TOOL_RESULT:
                messages.append(
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": message.tool_use_id,
                                "content": message.content,
                            }
                        ],
                    }
                )
            else:
                messages.append({"role": message.role.value, "content": message.content})
        return messages

    @override
    def to_tools(self, tools: Mapping[str, Tool]) -> list[dict[str, Any]]:
        """The catalog as Anthropic tool definitions.

        `properties` is `tool.parameters` passed straight through, which is why
        the per-argument `description` matters: it is the only thing telling the
        model what an argument means.

        `required` comes from `tool.required`, not from every parameter name.
        Ruby writes `tool.parameters.keys` unconditionally, so its step-10 tools
        describe arguments as optional in prose while the schema calls them
        mandatory — and the schema wins.
        """
        return [
            {
                "name": tool.name,
                "description": tool.description,
                "input_schema": {
                    "type": "object",
                    "properties": dict(tool.parameters),
                    "required": list(tool.required or ()),
                },
            }
            for tool in tools.values()
        ]

    @override
    def to_payload(
        self, context: Context, tools: Mapping[str, Tool], *, max_output_tokens: int
    ) -> dict[str, Any]:
        """The five-key request body for one Messages API call."""
        return {
            "model": self.model,
            "system": context.system,
            "max_tokens": max_output_tokens,
            "tools": self.to_tools(tools),
            "messages": self.to_messages(context),
        }

    @override
    def headers(self, api_key: str) -> Mapping[str, str]:
        """Anthropic authenticates with `x-api-key`, not a bearer token."""
        return {
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": DEFAULT_ANTHROPIC_VERSION,
        }

    @property
    @override
    def url(self) -> str:
        return self.BASE_URL
