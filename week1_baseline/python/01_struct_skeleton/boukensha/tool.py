"""A tool: a capability the agent may invoke."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any

from ._repr import truncate

#: How much of `description` the repr shows before cutting.
DESCRIPTION_REPR_LIMIT = 40


@dataclass(frozen=True, slots=True, repr=False)
class Tool:
    """A capability the agent may invoke.

    `parameters` is the tool's arguments as a JSON-Schema properties map —
    `{"direction": {"type": "string", "description": "…"}}` — which a backend
    passes straight through as `input_schema.properties`.

    `handler` is what Ruby calls the tool's *block*: the callable that runs when
    the tool is invoked. It is required; every tool is registered with one.
    """

    name: str
    description: str
    parameters: Mapping[str, Any]
    handler: Callable[..., Any]

    def __post_init__(self) -> None:
        # Frozen with a mutable mapping inside is not frozen. Copy, then wrap;
        # `object.__setattr__` is the sanctioned way past `frozen=True`.
        object.__setattr__(self, "parameters", MappingProxyType(dict(self.parameters)))

    def __repr__(self) -> str:
        description = truncate(self.description, DESCRIPTION_REPR_LIMIT)
        return (
            f"Tool(name={self.name!r}, description={description!r}, "
            f"params={list(self.parameters)!r})"
        )
