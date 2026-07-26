# 0008 — No vendor SDKs

**Status:** accepted
**Date:** 2026-07-25
**Applies to:** `week1_baseline/python/04_api_client` and later steps

## Context

**The course forbids using a vendor SDK.** This is an external constraint on the
exercise, not a design trade-off reasoned to from first principles.

That distinction is the reason this ADR exists. The arguments that *would*
justify the same choice — "it keeps the `Backend` seam load-bearing", "it matches
the Ruby's pedagogy", "the HTTP call should be visible rather than hidden behind
a library" — are all true and all weaker than the constraint itself. Recording
them as the rationale would invite someone to weigh them against the SDK's merits
and reasonably conclude the other way. Leading with the constraint closes the
question instead of re-arguing it.

And it **will** be re-argued. Week 2 extends this tree, and the SDK is going to
look extremely tempting, because it ships exactly the things step 04 spends most
of its code hand-rolling.

So it is worth being honest, on the record, about what the constraint costs:

| The `anthropic` SDK provides | Step 04's answer |
|---|---|
| retries, with the correct retryable status set | `_retryable_status`, a rule we wrote |
| connect and read timeouts | `DEFAULT_TIMEOUT`, one socket timeout |
| `request-id` capture | `ApiError.request_id`, on the error path only |
| typed exceptions per failure kind | one `ApiError` with five fields |
| a guard refusing non-streaming requests it estimates will exceed ten minutes | **nothing** |

We hand-roll the first four. We do not have the fifth at all.

## Decision

**`urllib.request` and `json`. Standard library only.**

1. `boukensha/client.py` imports `json`, `random`, `socket`, `time`,
   `urllib.error` and `urllib.request`. Nothing else.
2. `requirements.txt` stays `PyYAML` + `python-dotenv`, both of which exist for
   `Config` and predate this step.
3. The retry loop, backoff, `retry-after` handling, timeout and error
   classification are written here and are ours to get right.

**Rejected: the `anthropic` SDK.** Not rejected on merit. It is the better
engineering answer for production Python — it is maintained by the vendor, it
tracks API changes, its retry set is correct by construction, and the general
guidance for building on this API is to default to it. It is rejected **because
the constraint forbids it**, and for no other reason. Recording the merit is the
point: it stops the next reader assuming we simply hadn't considered it, and it
means the week-2 conversation starts from "the constraint no longer applies"
rather than from "was this ever a good idea".

**Rejected: `httpx` or `requests`.** The worst of both. It abandons the
no-third-party-libraries position while buying strictly less than the SDK would:
no retry policy tuned to this API, no `request-id` capture, no typed errors, no
knowledge of what a Messages call is. Every hand-rolled piece in `client.py`
would still have to be written.

## Consequences

- **The `Backend` seam stays load-bearing.** `url`, `headers(api_key)` and
  `to_api_payload()` get their first real caller here. §2.2 of the step-03 plan —
  public methods with no callers anywhere in twelve steps, which is how the
  Ruby's `to_messages` `ArgumentError` survived undetected — does not recur.
- **`parse_response` stays meaningful at step 05.** `call()` returns a plain
  `dict`, so there is a response shape to parse. An SDK returning a typed
  `Message` object would make the next step's abstract method largely redundant
  and quietly delete a rung of the ladder.
- **`AnthropicBackend` keeps its name but needed a new reason.** Its module
  docstring said it was named that way "because step 04 imports the SDK's
  `Anthropic` client into the same namespace." That will now never happen. The
  name is still right — the class is a *backend*, one member of a family sharing
  a contract, and a bare `Anthropic` names a vendor rather than a role — but the
  stated reason had to go.
- **Retry correctness is our problem.** Which is why the step drives a throwaway
  stub server through ten failure scenarios rather than shipping the retry loop
  on reasoning alone. See Verification.
- **No streaming, and no long-request guard.** Recorded in the step README's
  "Out of scope" as a real gap rather than an oversight.

## Verification

`requirements.txt` is unchanged from steps 00–03:

```
$ diff week1_baseline/python/03_prompt_builder/requirements.txt \
       week1_baseline/python/04_api_client/requirements.txt
(no output)
```

No third-party import reaches the client:

```
$ grep -nE '^(import|from) ' week1_baseline/python/04_api_client/boukensha/client.py
import json
import random
import socket
import time
import urllib.error
import urllib.request
from collections.abc import Mapping
from typing import TYPE_CHECKING, Any
from .errors import ApiError
```

All standard library, plus one local import.

The hand-rolled stack works against the real API:

```
$ ./week1_baseline/bin/python/04_api_client
model        claude-haiku-4-5-20251001
stop_reason  tool_use
content      [ tool_use look {} ]
usage        688 in, 35 out
cost         $0.000863
exit 0
```

And the four hand-rolled capabilities in the table above were each driven against
a throwaway `http.server` stub — 529-then-200, `retry-after` honoured and
clamped, retries exhausted, non-retryable statuses, timeouts not retried,
`request-id` captured, non-JSON bodies on both the success and error paths. Full
output is in the step README's Verification section.
