"""The abstract task: a role in the agentic loop bound to its own LLM."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from types import MappingProxyType
from typing import TYPE_CHECKING, Any, ClassVar, Self

if TYPE_CHECKING:  # import for typing only — `config` imports this module's package
    from ..config import Config

#: Ceiling on the tokens one response may use, when settings do not name one.
#:
#: Ruby hardcodes 1024 in the prompt builder *and* in every backend. That number
#: predates the current models: on `claude-opus-5` thinking is on by default and
#: `max_tokens` caps thinking *plus* response text together, so 1024 truncates
#: mid-answer. Anthropic's guidance for non-streaming requests is around 16000.
DEFAULT_MAX_OUTPUT_TOKENS = 16_000


@dataclass(frozen=True, slots=True)
class Task:
    """A resolved task: provider, model, and system prompt, already validated.

    Instances are built by `from_settings` / `from_config`, which do all the
    validation and all the prompt reading. Concrete subclasses set `NAME`.
    """

    name: str
    provider: str
    model: str
    prompt_override: Mapping[str, bool] = field(default_factory=dict)
    system_prompt: str | None = None
    max_output_tokens: int = DEFAULT_MAX_OUTPUT_TOKENS

    NAME: ClassVar[str]  # set by concrete subclasses

    @classmethod
    def task_name(cls) -> str:
        name = getattr(cls, "NAME", None)
        if not name:
            raise NotImplementedError(f"{cls.__name__} must define NAME")
        return name

    @classmethod
    def from_settings(
        cls,
        settings: Mapping[str, Any] | None,
        *,
        user_prompts_dir: Path | None = None,
        default_prompts_dir: Path | None = None,
    ) -> Self:
        """Validate one task's settings hash and resolve its prompts."""
        name = cls.task_name()

        # Covers the None that Config.task() returns for an absent task.
        if not isinstance(settings, Mapping):
            raise ValueError(f"tasks.{name} is missing from settings.yaml")

        provider = settings.get("provider")
        if not provider:
            raise ValueError(f"tasks.{name}.provider is required in settings.yaml")

        model = settings.get("model")
        if not model:
            raise ValueError(f"tasks.{name}.model is required in settings.yaml")

        raw_override = settings.get("prompt_override")
        prompt_override = MappingProxyType(
            dict(raw_override) if isinstance(raw_override, Mapping) else {}
        )

        # Optional, and coerced the same way as `Mud.port`.
        max_output_tokens = settings.get("max_output_tokens")

        return cls(
            name=name,
            provider=provider,
            model=model,
            prompt_override=prompt_override,
            max_output_tokens=(
                DEFAULT_MAX_OUTPUT_TOKENS
                if max_output_tokens is None
                else int(max_output_tokens)
            ),
            system_prompt=cls._read_prompt(
                "system",
                task_name=name,
                override=prompt_override.get("system") is True,
                user_prompts_dir=user_prompts_dir,
                default_prompts_dir=default_prompts_dir,
            ),
        )

    @classmethod
    def from_config(cls, config: Config) -> Self:
        """Build this task from a loaded `Config`."""
        # PROMPTS_DIR is read off the passed instance rather than by importing
        # Config, which would be a circular import.
        return cls.from_settings(
            config.task(cls.task_name()),
            user_prompts_dir=config.user_prompts_dir,
            default_prompts_dir=config.PROMPTS_DIR,
        )

    @staticmethod
    def _read_prompt(
        prompt_name: str,
        *,
        task_name: str,
        override: bool,
        user_prompts_dir: Path | None,
        default_prompts_dir: Path | None,
    ) -> str | None:
        """First existing candidate wins; `None` when none of them exist.

        1. `<config dir>/prompts/<task>/<prompt>.md`  (only when overridden)
        2. `<library>/prompts/<task>/<prompt>.md`
        3. `<library>/prompts/<prompt>.md`
        """
        candidates: list[Path] = []
        if override and user_prompts_dir is not None:
            candidates.append(user_prompts_dir / task_name / f"{prompt_name}.md")
        if default_prompts_dir is not None:
            candidates.append(default_prompts_dir / task_name / f"{prompt_name}.md")
            candidates.append(default_prompts_dir / f"{prompt_name}.md")

        for path in candidates:
            if path.is_file():
                return path.read_text(encoding="utf-8").strip()
        return None
