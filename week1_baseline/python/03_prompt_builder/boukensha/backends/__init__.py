"""The provider seam: which backends exist, and how a task picks one."""

from __future__ import annotations

from collections.abc import Mapping
from typing import TYPE_CHECKING

from ..errors import UnsupportedProviderError
from .anthropic import AnthropicBackend
from .base import Backend, ModelInfo, UsageUnit

if TYPE_CHECKING:  # typing only, so `backends` never imports `tasks` at runtime
    from ..tasks.base import Task

#: provider name -> backend class. The registry of valid providers *is* this
#: dict, which is why `Task.provider` stays a plain `str` and the check lives
#: here rather than in a one-member enum.
_BACKENDS: Mapping[str, type[Backend]] = {
    "anthropic": AnthropicBackend,
}


def backend_for(task: Task) -> Backend:
    """The backend for a task's provider, built for that task's model.

    Reads nothing from the environment and takes no credential — a backend
    serializes, and the key arrives at `headers(api_key)`.

    Ruby writes this as a `case provider` in the example, then copies it into
    steps 04, 05, and `lib/boukensha.rb` at steps 07, 09, 10, 11 and 12 — seven
    places, with a second `case` beside it mapping provider to environment
    variable. Both belong to the seam: this function owns provider→class, and
    `Backend.API_KEY_ENV` owns the variable name.
    """
    backend_cls = _BACKENDS.get(task.provider)
    if backend_cls is None:
        supported = ", ".join(sorted(_BACKENDS))
        raise UnsupportedProviderError(
            f"unsupported provider {task.provider!r} for task {task.name!r}. "
            f"Supported providers: {supported}"
        )
    return backend_cls(model=task.model)


__all__ = [
    "AnthropicBackend",
    "Backend",
    "ModelInfo",
    "UsageUnit",
    "backend_for",
]
