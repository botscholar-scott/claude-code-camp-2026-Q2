"""The errors Boukensha raises, under one base class."""

from __future__ import annotations


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
