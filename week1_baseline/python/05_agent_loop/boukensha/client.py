"""The client: the object that actually sends a payload and gets a reply back.

Step 03 produced a payload, a URL and a set of headers, and posted nothing. This
is the caller those three members were waiting for.

The `Client` **transports**; it does not serialize. It takes a backend for its
`url` and `headers(api_key)`, and a payload someone else built. It never sees a
`Context`, a `Registry`, or a tool — one dict in, one dict out. See
`docs/adr/0009-client-transports-payloads.md`.

Standard library only: `urllib.request` and `json`. No vendor SDK, which is a
constraint on the exercise rather than a preference — see
`docs/adr/0008-no-vendor-sdks.md`. Retries, backoff, `retry-after`, timeouts and
error classification are therefore ours to get right, and are the bulk of this
file.
"""

import json
import random
import socket
import time
import urllib.error
import urllib.request
from collections.abc import Mapping
from typing import TYPE_CHECKING, Any

from .errors import ApiError

if TYPE_CHECKING:  # for the annotations only
    from .backends.base import Backend

#: A single socket timeout covering connect *and* read, in seconds. Ten minutes
#: is what the vendor SDKs default to, so the number is citable rather than
#: invented, and it comfortably clears a 16000-token generation. Ruby sets no
#: timeout at all and inherits `Net::HTTP`'s 60s — below our own default
#: generation time. See the README, "Why timeouts are not retried".
DEFAULT_TIMEOUT = 600.0

#: Retries *after* the first attempt, so four HTTP requests at most. Ruby parity.
MAX_RETRIES = 3

BASE_RETRY_DELAY = 0.5
#: Ceiling on any single sleep, including a server-supplied `retry-after`, so a
#: pathological header value cannot wedge the process.
MAX_RETRY_DELAY = 60.0

#: Retryable statuses below 500. Everything at 500 and above is retryable by the
#: rule in `_retryable_status`, which is why this set is short.
RETRYABLE_STATUSES = frozenset({408, 409, 429})

#: An **allowlist**: only these transport failures are retried. A blocklist —
#: Ruby's shape — can silently admit a permanent failure the day a new exception
#: type appears. Read the two exclusions documented on `_retryable_error` before
#: adding to this tuple.
RETRYABLE_ERRORS = (ConnectionError, socket.gaierror)


def _retryable_status(status: int) -> bool:
    """Whether an HTTP status is worth another attempt.

    A rule, not an enumeration. Ruby lists `[408, 409, 429, 500, 502, 503, 504]`,
    which omits **529 `overloaded_error`** — the status the API returns when it
    is at capacity, and the single most likely retryable failure in normal
    operation. The rule covers it without naming it, and does not rot the next
    time a new 5xx appears.
    """
    return status in RETRYABLE_STATUSES or status >= 500


def _retryable_error(reason: object) -> bool:
    """Whether a transport failure is worth another attempt.

    `TimeoutError` is **deliberately absent.** `urlopen` applies one socket
    timeout to both connect and read, and a non-streaming Messages call withholds
    the response until generation finishes — so a timeout at a 600s ceiling most
    likely means the server generated a response and billed us for it. Retrying
    would re-run, and re-bill, work that was already done: up to four billed
    generations for one logical call, silently. The rule is *retry only when we
    know the server didn't do the work.* See the README section of the same name.

    `ssl.SSLCertVerificationError` is **deliberately absent** too: a certificate
    failure never succeeds on retry. Ruby retries it three times with backoff and
    then tells you in its README to go fix your machine. Nothing to configure
    here — `urlopen` uses `ssl.create_default_context()`, which loads the system
    trust store on every supported platform.

    Ordinary network blips do not surface as timeouts at this ceiling; they
    surface as `ConnectionResetError`, `ConnectionRefusedError` or
    `socket.gaierror`, all of which stay retryable.
    """
    return isinstance(reason, RETRYABLE_ERRORS)


class Client:
    """Performs one API call: sends a payload, returns the parsed response.

    ```python
    client = Client(backend, api_key=config.require_secret(backend.API_KEY_ENV))
    response = client.call(builder.to_api_payload(max_output_tokens=1024))
    ```

    Ruby's `Client.new(builder)` wraps the builder, but step 05's `Agent` is
    constructed with **both** a builder and a client and calls `parse_response`
    on the builder directly — so the client's copy is redundant coupling. Taking
    the payload instead keeps `max_output_tokens` at exactly one resolution point
    and means step 05's tools-disabled wind-down call is a second `PromptBuilder`
    with `tools={}` rather than a `tools=` parameter threaded through three
    layers. Step 05 shipped and no `tools=` parameter was written; the forward
    check ADR 0009 asserted has been run.
    """

    def __init__(
        self,
        backend: "Backend",
        *,
        api_key: str,
        timeout: float = DEFAULT_TIMEOUT,
    ) -> None:
        if not api_key:
            # Fail at wiring time rather than as a 401 in the middle of a run.
            raise ValueError("api_key is required and must not be empty")
        self._backend = backend
        self._api_key = api_key
        self._timeout = timeout

    def call(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        """POST one payload and return the parsed response body.

        The payload is sent as given. The backend built it, so re-validating it
        here would duplicate knowledge that already lives in one place.

        Raises `ApiError` for every failure — a rejected request, a request that
        never arrived, a timeout, or a 2xx whose body is not JSON.
        """
        url = self._backend.url
        headers = dict(self._backend.headers(self._api_key))
        body = json.dumps(payload).encode("utf-8")

        for attempt in range(1, MAX_RETRIES + 2):
            final = attempt > MAX_RETRIES
            request = urllib.request.Request(url, data=body, headers=headers, method="POST")

            try:
                with urllib.request.urlopen(request, timeout=self._timeout) as response:
                    return self._decode(response, attempt)

            # `HTTPError` subclasses `URLError` subclasses `OSError`, and so do
            # `TimeoutError`, `ConnectionError` and `socket.gaierror`. This
            # clause MUST come first, or every HTTP status is swallowed by the
            # transport branch below.
            except urllib.error.HTTPError as error:
                raw = error.read().decode("utf-8", errors="replace")
                request_id = error.headers.get("request-id")
                if final or not _retryable_status(error.code):
                    raise ApiError.from_body(
                        "API request failed",
                        body=raw,
                        status_code=error.code,
                        request_id=request_id,
                        attempts=attempt,
                    ) from None
                delay = self._delay(attempt, error.headers.get("retry-after"))

            except OSError as error:
                # A connect-phase failure arrives wrapped in `URLError`; a
                # read-phase timeout arrives bare. Unwrap so both classify the
                # same way.
                reason = (
                    error.reason if isinstance(error, urllib.error.URLError) else error
                )
                if final or not _retryable_error(reason):
                    raise self._transport_error(reason, attempt) from error
                delay = self._delay(attempt, None)

            time.sleep(delay)

        # Unreachable: the last iteration always raises, because `final` is true.
        raise AssertionError("retry loop exited without a result")

    # ---------- internals -------------------------------------------------

    def _decode(self, response: Any, attempt: int) -> dict[str, Any]:
        """Parse a successful response body.

        `json.loads` runs on the success path too: a 2xx that is not JSON is an
        `ApiError` like any other failure, not a `JSONDecodeError` escaping from
        the client into a caller that only knows to catch `ApiError`.
        """
        raw = response.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = None
        if not isinstance(parsed, dict):
            raise ApiError(
                "API returned a success status with a body that is not a JSON object",
                status_code=response.status,
                request_id=response.headers.get("request-id"),
                attempts=attempt,
                body=raw,
            ) from None
        return parsed

    def _transport_error(self, reason: object, attempt: int) -> ApiError:
        """An `ApiError` for a request that never got a response.

        `status_code` stays `None`, which is what tells a caller the difference
        between *rejected* and *never arrived*.
        """
        if isinstance(reason, TimeoutError):
            message = (
                f"Request to {self._backend.url} exceeded the {self._timeout}s timeout"
            )
        else:
            message = (
                f"Connection to {self._backend.url} failed "
                f"({type(reason).__name__}: {reason})"
            )
        return ApiError(message, attempts=attempt)

    def _delay(self, attempt: int, retry_after: str | None) -> float:
        """How long to wait before the next attempt.

        A present `retry-after` is used as-is, clamped: if the server asks for 30
        seconds, 30 seconds is a floor, not a suggestion, so no jitter is added
        to it. Ruby ignores the header entirely and retries three times inside
        3.5 seconds — achieving nothing but three more rejected requests.

        `retry-after` may legally be an HTTP-date. Anthropic sends seconds; the
        date form falls through to backoff rather than adding a parser for a
        shape we will not receive.
        """
        if retry_after is not None:
            try:
                return min(max(float(int(retry_after)), 0.0), MAX_RETRY_DELAY)
            except ValueError:
                pass  # HTTP-date form, or junk — fall through to backoff.

        delay = min(BASE_RETRY_DELAY * 2 ** (attempt - 1), MAX_RETRY_DELAY)
        # Equal jitter: half the window fixed, half random. Free, and it stops a
        # fleet of clients retrying in lockstep.
        return delay / 2 + random.uniform(0, delay / 2)
