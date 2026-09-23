"""Tools: bridge status, events, async jobs, background render."""

from ..registry import splicekit_tool
from ..bridge import _call_or_error, _err, _fmt, bridge


# ============================================================
# Core Connection & Status
# ============================================================
# The first thing any client should do is call bridge_status() to
# verify FCP is running and the bridge is responsive.

@splicekit_tool("bridge_status")
def bridge_status() -> str:
    """Check if SpliceKit is running and get FCP version info."""
    r = bridge.call("system.version")
    if _err(r):
        return f"Error: SpliceKit not connected: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("bridge_alive")
def bridge_alive() -> str:
    """Cheap liveness probe that does not touch the main thread.

    Returns {alive, version, pid, timestamp} without any FCP API calls. Use
    this when you want to verify the bridge is responsive without risking a
    hang on a stuck main thread.
    """
    return _call_or_error("bridge.alive")


@splicekit_tool("bridge_describe")
def bridge_describe(method: str = "", safety: str = "") -> str:
    """Return self-describing metadata for every known RPC method.

    - method: optional — return metadata for a single method only
    - safety: optional — filter by classification
      ("safe", "state_dependent", "modal", "destructive", "system", "unclassified")

    Each entry includes: name, safety classification, one-line summary, source
    (builtin/plugin). Use this to discover what's safe to call autonomously,
    what requires selection/project state, and what may open modals.
    """
    params = {}
    if method:
        params["method"] = method
    if safety:
        params["safety"] = safety
    return _call_or_error("bridge.describe", **params)


@splicekit_tool("bridge_safety_tags")
def bridge_safety_tags() -> str:
    """List the safety classifications used by bridge_describe with meanings."""
    return _call_or_error("bridge.safetyTags")


@splicekit_tool("events_subscribe")
def events_subscribe(patterns: list[str] | None = None) -> str:
    """Subscribe this connection to bridge events matching patterns.

    Patterns: exact event type (e.g. "command.completed"), "prefix.*" wildcard,
    or "*" for everything. Without a subscription, all events are delivered.

    Events arrive as JSON-RPC notifications with method="event" and params
    carrying {type, ...}. Relevant types include:
      - command.completed — when async=true RPCs finish (carries correlation_id)
      - crash             — when the in-process crash handler catches a signal
      - trace             — from debug.traceMethod installed traces

    Example: events_subscribe(patterns=["command.*", "crash"])
    """
    return _call_or_error("events.subscribe", patterns=patterns or ["*"])


@splicekit_tool("events_unsubscribe")
def events_unsubscribe() -> str:
    """Remove this connection's event pattern allowlist."""
    return _call_or_error("events.unsubscribe")


@splicekit_tool("events_status")
def events_status() -> str:
    """Report this connection's current event subscription state."""
    return _call_or_error("events.status")


@splicekit_tool("async_status")
def async_status() -> str:
    """List in-flight async operations with elapsed time.

    Long-running RPCs dispatched with async=true are tracked here. Each entry
    has a correlation_id, method name, and elapsed_ms since dispatch. When
    they finish, a `command.completed` event is broadcast with the result.
    """
    return _call_or_error("async.status")


@splicekit_tool("background_render_status")
def background_render_status() -> str:
    """Inspect Final Cut Pro's live background-render state.

    Returns queue and manager state pulled from the running process, including:
    - Whether background render is currently in low-overhead mode
    - The current Background Render run-group queue concurrency
    - Auto-start delay and related background-render defaults
    - Active GPU/render preference defaults used for background render

    Use this before and after background_render_control() to see whether FCP
    accepted the requested throttle window.
    """
    r = bridge.call("backgroundRender.status")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("background_render_control")
def background_render_control(action: str, seconds: float) -> str:
    """Temporarily reduce background-render impact while editing.

    Args:
        action: One of:
          - "hold_off": Delay background-render auto-start for `seconds`
          - "low_overhead": Enter FCP's internal low-overhead mode for `seconds`
        seconds: Duration in seconds. Must be > 0.

    This tool intentionally exposes only short-lived, reversible throttles.
    It does not change persistent preferences or attempt CPU affinity control.
    """
    normalized = action.strip().lower()
    if normalized not in {"hold_off", "low_overhead"}:
        return "Error: action must be 'hold_off' or 'low_overhead'."
    if seconds <= 0:
        return "Error: seconds must be > 0."

    r = bridge.call("backgroundRender.control", action=normalized, seconds=seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)
