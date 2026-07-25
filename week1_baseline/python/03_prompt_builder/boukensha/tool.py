"""A tool: a capability the agent may invoke."""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
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

    `required` names the subset of `parameters` the model must supply. `None`
    means *unspecified*, which resolves to **all** of them — the Ruby's only
    behaviour, since it hardcodes `required: tool.parameters.keys`. An explicit
    `[]` means none are required. After `__post_init__` this is always a
    `tuple[str, ...]`; the backend never sees the sentinel.
    """

    name: str
    description: str
    parameters: Mapping[str, Any]
    handler: Callable[..., Any]
    required: Sequence[str] | None = None

    def __post_init__(self) -> None:
        # Frozen with a mutable mapping inside is not frozen. Copy, then wrap;
        # `object.__setattr__` is the sanctioned way past `frozen=True`.
        object.__setattr__(self, "parameters", MappingProxyType(dict(self.parameters)))

        required = (
            tuple(self.parameters) if self.required is None else tuple(self.required)
        )
        # A typo in `required=` is a startup error here rather than a schema the
        # provider rejects mid-run.
        unknown = [name for name in required if name not in self.parameters]
        if unknown:
            raise ValueError(
                f"tool {self.name!r} marks unknown parameter(s) required: "
                f"{', '.join(sorted(unknown))}"
            )
        object.__setattr__(self, "required", required)

    def __repr__(self) -> str:
        description = truncate(self.description, DESCRIPTION_REPR_LIMIT)
        return (
            f"Tool(name={self.name!r}, description={description!r}, "
            f"params={list(self.parameters)!r})"
        )
