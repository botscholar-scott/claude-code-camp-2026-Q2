"""The errors Boukensha raises, under one base class."""

import json


class BoukenshaError(Exception):
    """Base class for every error this package raises.

    Ruby's ladder keeps its errors flat under `StandardError`. A base costs one
    line, lets a caller write `except BoukenshaError`, and the ladder shows it
    will be wanted: step 03 adds an unsupported-model error and step 05 adds two
    more. Retrofitting a base once those are in use would change their MRO.
    """


class UnknownToolError(BoukenshaError):
    """Dispatched a tool name that has no registered tool.

    Deliberately **not** a `KeyError` subclass, even though a failed lookup is
    the obvious reading: `KeyError.__str__` returns the *repr* of its argument,
    so the message would print wrapped in a second set of quotes.
    """


class UnsupportedModelError(BoukenshaError):
    """A backend was asked for a model it does not support."""


class UnsupportedProviderError(BoukenshaError):
    """settings.yaml names a provider this build has no backend for.

    Ruby raises a bare `ArgumentError` here. This is the same kind of failure as
    `UnsupportedModelError` — *settings.yaml names something we do not support* —
    so both live in one catchable family.

    A **missing** provider or model still raises plain `ValueError` from
    `Task.from_settings`; absent and unknown are genuinely different failures.
    """


class ApiError(BoukenshaError):
    """A request to a provider's API failed.

    Ruby fuses everything into one string — status, body and attempt count
    interpolated into a sentence — so a caller wanting the status code back has
    to parse prose. The fields are kept separately here and the sentence is
    composed in `__str__`.

    One class, not a hierarchy. Step 05's `except ApiError` catches everything,
    and no caller in twelve steps needs to distinguish *rejected* from *never
    arrived*: `status_code is None` already says which happened.
    """

    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        error_type: str | None = None,
        request_id: str | None = None,
        attempts: int = 1,
        body: str | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        #: The HTTP status, or `None` when the request never got a response.
        self.status_code = status_code
        #: Anthropic's machine-readable failure kind, eg. `"rate_limit_error"`.
        self.error_type = error_type
        #: The `request-id` header — the identifier Anthropic support asks for.
        self.request_id = request_id
        #: How many HTTP requests this one logical call made.
        self.attempts = attempts
        #: The raw response body, kept verbatim for when the parse gives nothing.
        self.body = body

    def __str__(self) -> str:
        plural = "" if self.attempts == 1 else "s"
        line = f"{self.message} after {self.attempts} attempt{plural}"

        if self.status_code is not None:
            kind = f" {self.error_type}" if self.error_type else ""
            line += f" ({self.status_code}{kind})"

        detail = self._detail()
        if detail:
            line += f": {detail}"
        if self.request_id:
            line += f" [request-id: {self.request_id}]"
        return line

    def _detail(self) -> str | None:
        """The human sentence, preferring the API's own `error.message`.

        Deliberately total: an error path that raises while composing its own
        message is worse than the failure it was reporting. Anything unexpected
        in the body falls back to the raw text.
        """
        if not self.body:
            return None
        try:
            parsed = json.loads(self.body)
            message = parsed["error"]["message"]
        except (ValueError, TypeError, LookupError):
            return self.body.strip() or None
        return message if isinstance(message, str) else self.body.strip() or None

    @classmethod
    def from_body(
        cls,
        message: str,
        *,
        body: str,
        status_code: int | None = None,
        request_id: str | None = None,
        attempts: int = 1,
    ) -> "ApiError":
        """Build one, reading `error.type` out of the body when it is there.

        The error body is structured JSON — `{"error": {"type": …, "message": …}}` —
        so the failure kind is a field rather than something to regex out of a
        sentence. When the body is not JSON, `error_type` is simply `None`.
        """
        try:
            parsed = json.loads(body)
            error_type = parsed["error"]["type"]
        except (ValueError, TypeError, LookupError):
            error_type = None
        return cls(
            message,
            status_code=status_code,
            error_type=error_type if isinstance(error_type, str) else None,
            request_id=request_id,
            attempts=attempts,
            body=body,
        )
