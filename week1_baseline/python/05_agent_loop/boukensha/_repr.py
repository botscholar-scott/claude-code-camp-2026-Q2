"""Shared formatting helper for the value objects' `__repr__`."""

ELLIPSIS = "…"


def truncate(text: str, limit: int) -> str:
    """Cut to `limit` characters, appending an ellipsis only when something was cut."""
    if len(text) <= limit:
        return text
    return text[:limit] + ELLIPSIS
