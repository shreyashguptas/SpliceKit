"""Parsers for list-valued tool arguments (seconds, markers)."""

import json

from .sdk import ToolError


_SECONDS_LIST_PARSE_HELP = (
    "Accepted forms: JSON array of seconds (e.g. '[3.0, 6.0, 9.0]') or "
    "comma-separated seconds (e.g. '3.0, 6.0, 9.0' or '25.0')."
)


def _parse_seconds_list(value: str) -> list[float]:
    """Parse a JSON seconds array or a plain comma-separated list of numbers."""
    text = (value or "").strip()
    if not text:
        raise ToolError(f"times is required. {_SECONDS_LIST_PARSE_HELP}")

    if text.startswith("["):
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ToolError(
                f"Invalid times JSON: {exc}. {_SECONDS_LIST_PARSE_HELP}"
            ) from exc
        if isinstance(parsed, (int, float)):
            return [float(parsed)]
        if not isinstance(parsed, list):
            raise ToolError(
                f"times must be a JSON array of numbers. {_SECONDS_LIST_PARSE_HELP}"
            )
        try:
            return [float(x) for x in parsed]
        except (TypeError, ValueError) as exc:
            raise ToolError(
                f"times must contain only numbers. {_SECONDS_LIST_PARSE_HELP}"
            ) from exc

    parts = [p.strip() for p in text.split(",") if p.strip()]
    try:
        return [float(p) for p in parts]
    except ValueError as exc:
        raise ToolError(
            f"Invalid comma-separated times: {exc}. {_SECONDS_LIST_PARSE_HELP}"
        ) from exc


_MARKERS_PARSE_HELP = (
    "Accepted forms: JSON array of marker objects "
    '(e.g. \'[{"time": 5.0, "name": "Scene 1"}]\') or comma-separated seconds '
    "(e.g. '5.0, 12.0' — standard markers at those times)."
)


def _parse_markers_list(value: str) -> list:
    """Parse marker specs from JSON or comma-separated time values."""
    text = (value or "").strip()
    if not text:
        raise ToolError(f"markers is required. {_MARKERS_PARSE_HELP}")

    if text.startswith("["):
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ToolError(
                f"Invalid markers JSON: {exc}. {_MARKERS_PARSE_HELP}"
            ) from exc
        if not isinstance(parsed, list):
            raise ToolError(
                f"markers must be a JSON array. {_MARKERS_PARSE_HELP}"
            )
        return parsed

    try:
        times = _parse_seconds_list(text)
    except ToolError as exc:
        raise ToolError(f"{exc}. {_MARKERS_PARSE_HELP}") from exc
    return [{"time": t} for t in times]
