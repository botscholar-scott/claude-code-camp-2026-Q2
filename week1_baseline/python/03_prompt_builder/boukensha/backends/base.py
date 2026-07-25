"""The backend contract: the provider-specific half of an API call.

A backend knows one provider's payload shape, its endpoint, its headers, and
which models it supports. It **serializes; it does not send** — no HTTP lives
here, and none arrives until step 04.

It also holds **no credential**. `headers(api_key)` takes the key at the one call
that needs it, so a backend is always fully constructed and reads nothing from
the environment. See `docs/adr/0007-backend-holds-no-credentials.md`.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING, Any, ClassVar

from ..errors import UnsupportedModelError

if TYPE_CHECKING:  # for the annotations only — no runtime dependency either way
    from ..context import Context
    from ..tool import Tool


class UsageUnit(StrEnum):
    """What a provider meters. Anthropic bills tokens; a plan-based provider
    would add its own member here."""

    TOKENS = "tokens"


@dataclass(frozen=True, slots=True)
class ModelInfo:
    """What this library knows about one model.

    Ruby nests a hash per model with a `cost_per_million` sub-hash and a
    `usage_unit` repeated on every row. A frozen dataclass names the three fields
    that are actually read and catches a typo at construction instead of at
    `fetch`. `usage_unit` moves to `Backend.USAGE_UNIT`, because it describes the
    provider rather than the model.
    """

    context_window: int
    input_cost_per_million: float
    output_cost_per_million: float


class Backend(ABC):
    """The contract every provider backend satisfies.

    This port ships **only** `AnthropicBackend`, but the seam is kept: adding a
    provider in week 2 is one new file plus one row in `_BACKENDS`. The shape was
    validated against the five reference implementations in the Ruby tree, which
    were read during design and then deliberately not ported. See
    `docs/adr/0006-port-ships-only-the-anthropic-backend.md`.

    `MODELS` is a declared `ClassVar` rather than Ruby's `const_get(:MODELS)`
    metaprogramming. A subclass that forgets it fails with `AttributeError` at
    construction; with one subclass, an `__init_subclass__` guard would protect
    against a mistake nobody can currently make.
    """

    #: What this backend can be asked for, keyed by model id.
    MODELS: ClassVar[Mapping[str, ModelInfo]]
    #: What the provider meters. A property of the provider, not of the model.
    USAGE_UNIT: ClassVar[UsageUnit] = UsageUnit.TOKENS
    #: The *name* of the environment variable holding this provider's key — not
    #: its value. Step 04's `Client` reads this to know what to fetch.
    API_KEY_ENV: ClassVar[str | None] = None

    def __init__(self, *, model: str) -> None:
        self.model = self._validate_model(model)

    @classmethod
    def _validate_model(cls, model: str) -> str:
        if model not in cls.MODELS:
            supported = ", ".join(sorted(cls.MODELS))
            raise UnsupportedModelError(
                f"{cls.__name__} does not support model {model!r}. "
                f"Supported models: {supported}"
            )
        return model

    # ---------- model metadata --------------------------------------------

    @property
    def model_info(self) -> ModelInfo:
        """Everything known about the model this backend was built for."""
        return self.MODELS[self.model]

    @property
    def context_window(self) -> int:
        """The model's total token ceiling for one call — input *and* output.

        Distinct from `max_output_tokens`, which caps only the response. Step 12
        turns this into compaction accounting.
        """
        return self.model_info.context_window

    @property
    def input_cost_per_million(self) -> float:
        return self.model_info.input_cost_per_million

    @property
    def output_cost_per_million(self) -> float:
        return self.model_info.output_cost_per_million

    def estimate_cost(self, *, input_tokens: int, output_tokens: int) -> float:
        """What a call of this size costs, in dollars.

        Returns a `float`, never `None`. Ruby guards on missing prices because
        Ollama Cloud's are plan-based; every Anthropic price is known, so the
        guard has nothing to catch. Its sibling `usage_level` — also Ollama
        Cloud's alone, and read by nothing before step 06 — is not ported.
        """
        return (
            input_tokens * self.input_cost_per_million
            + output_tokens * self.output_cost_per_million
        ) / 1_000_000

    # ---------- serialization ---------------------------------------------

    @abstractmethod
    def to_messages(self, context: Context) -> list[dict[str, Any]]:
        """The conversation history in this provider's message shape."""

    @abstractmethod
    def to_tools(self, tools: Mapping[str, Tool]) -> list[dict[str, Any]]:
        """The tool catalog in this provider's tool-definition shape."""

    @abstractmethod
    def to_payload(
        self, context: Context, tools: Mapping[str, Tool], *, max_output_tokens: int
    ) -> dict[str, Any]:
        """The complete request body for one call.

        `tools` is explicit and `max_output_tokens` is a required keyword. Ruby
        reaches `context.tools` and defaults the limit to `1024` here *and* in the
        builder; both defaults resolve once, in `PromptBuilder`.
        """

    @abstractmethod
    def headers(self, api_key: str) -> Mapping[str, str]:
        """The request headers, given the credential at the point of use."""

    @property
    @abstractmethod
    def url(self) -> str:
        """The endpoint this provider's calls are posted to."""
