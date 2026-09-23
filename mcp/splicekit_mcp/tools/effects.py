"""Tools: effects and transitions."""

from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge


# ============================================================
# Effects (video filters, generators, titles, audio)
# ============================================================
# Enumerate FCP's installed effects and apply them to clips.
# FCP organizes effects by type (filter, generator, title, audio).

@splicekit_tool("list_effects")
def list_effects(type: str = "filter", filter: str = "") -> str:
    """List available effects in FCP by type.

    Args:
        type: "filter" (video effects), "generator", "title", "audio", or "all"
        filter: Optional search string to filter by name or category.

    Returns effect name, effectID, category, and type for each.
    Use the effectID or name with apply_effect() to add one.
    """
    params = {"type": type}
    if filter:
        params["filter"] = filter
    r = bridge.call("effects.listAvailable", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    effects = r.get("effects", [])
    lines = [f"Available {type} effects: {r.get('count', len(effects))}"]
    lines.append("")

    if effects:
        lines.append(f"{'Name':<30} {'Category':<25} {'Type':<12} {'Effect ID'}")
        lines.append("-" * 100)
        for e in effects:
            lines.append(
                f"{e['name']:<30} {e.get('category', ''):<25} "
                f"{e.get('type', ''):<12} {e['effectID'][:40]}"
            )
    else:
        lines.append("No effects found.")

    return "\n".join(lines)


@splicekit_tool("apply_effect")
def apply_effect(name: str = "", effectID: str = "") -> str:
    """Apply a video effect, generator, or title to the selected clip(s).

    Select a clip first with timeline_action("selectClipAtPlayhead").
    Use list_effects() to see available effects.

    Args:
        name: Display name of the effect (e.g. "Gaussian Blur", "Vignette")
        effectID: The effect ID string

    Supports undo via timeline_action("undo").
    """
    if not name and not effectID:
        return "Error: provide either name or effectID"

    params = {}
    if effectID:
        params["effectID"] = effectID
    if name:
        params["name"] = name

    r = bridge.call("effects.apply", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    return f"Applied effect: {r.get('effect', '?')} ({r.get('effectID', '')})"


# ============================================================
# Transitions
# ============================================================
# FCP has 376+ built-in transitions. These tools enumerate them
# and apply them at edit points (between adjacent clips).

@splicekit_tool("list_transitions")
def list_transitions(filter: str = "") -> str:
    """List all available video transitions installed in FCP.

    Returns transition name, effectID, and category for each.
    Use the effectID or name with apply_transition() to add one.

    Args:
        filter: Optional search string to filter by name or category.
    """
    params = {}
    if filter:
        params["filter"] = filter
    r = bridge.call("transitions.list", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    transitions = r.get("transitions", [])
    default = r.get("defaultTransition", {})

    lines = [f"Available transitions: {r.get('count', len(transitions))}"]
    lines.append(f"Default: {default.get('name', '?')} ({default.get('effectID', '?')})")
    lines.append("")

    if transitions:
        lines.append(f"{'Name':<30} {'Category':<30} {'Effect ID'}")
        lines.append("-" * 90)
        for t in transitions:
            lines.append(
                f"{t['name']:<30} {t.get('category', ''):<30} {t['effectID'][:50]}"
            )
    else:
        lines.append("No transitions found.")

    return "\n".join(lines)


@splicekit_tool("apply_transition")
def apply_transition(name: str = "", effectID: str = "", freeze_extend: bool = True) -> str:
    """Apply a specific transition at the current edit point.

    You can specify the transition by display name or effectID.
    Use list_transitions() to see available transitions.

    Args:
        name: Display name of the transition (e.g. "Cross Dissolve", "Flow")
        effectID: The effect ID (e.g. "FxPlug:4731E73A-...")
        freeze_extend: If True, automatically resolve missing-media transitions with freeze frames
            when there isn't enough media for the transition. This avoids the
            "not enough extra media" dialog and prevents ripple trimming.

    The transition is applied at the selected edit point (between clips).
    Select an edit point first with timeline_action("nextEdit") or
    timeline_action("previousEdit").

    Supports undo via ``history_action("undo")``. Note that a transition consumes media
    from both sides of the cut, so with freeze_extend the clips around it may be altered
    too; undo takes the whole thing back together.
    """
    if not name and not effectID:
        return "Error: provide either name or effectID"

    params = {}
    if effectID:
        params["effectID"] = effectID
    if name:
        params["name"] = name
    if freeze_extend:
        params["freezeExtend"] = True

    r = bridge.call("transitions.apply", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    msg = f"Applied transition: {r.get('transition', '?')} ({r.get('effectID', '')})"
    if r.get("freezeExtended"):
        msg += " (missing-media fixed with freeze frames)"
    return msg


@splicekit_tool("apply_transition_to_all_clips")
def apply_transition_to_all_clips() -> str:
    """Apply the default transition (Cross Dissolve) between every clip on the timeline.

    This selects all clips and adds the default transition at every edit point
    in a single operation. Much faster than applying transitions one at a time.

    Use list_transitions() to see which transition is currently set as default.
    """
    r = bridge.call("command.execute", action="addTransitionToAll", type="timeline")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)
