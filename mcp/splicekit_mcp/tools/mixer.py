"""Tools: SpliceKit's audio mixer."""

from ..registry import splicekit_tool
from ..bridge import _err, bridge


# ============================================================
# Mixer (Audio Faders)
# ============================================================
# Real-time audio mixer with per-clip volume faders.
# Returns clips overlapping the playhead with volume levels.

@splicekit_tool("mixer_get_state")
def mixer_get_state() -> str:
    """Get current mixer state: all clips overlapping the playhead with their volumes.

    Returns up to 12 faders, sorted by lane (highest/topmost clip = fader 0).
    Each fader includes clipHandle, volumeChannelHandle, effectStackHandle,
    volumeDB, volumeLinear, lane, role, and clip name.
    """
    r = bridge.call("mixer.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    faders = r.get("faders", [])
    if not faders:
        return f"No clips at playhead (time: {r.get('playheadSeconds', 0):.3f}s)"
    lines = [f"Mixer State (playhead: {r.get('playheadSeconds', 0):.3f}s, {len(faders)} faders):"]
    lines.append("")
    for f in faders:
        db = f.get("volumeDB", 0)
        db_str = f"-inf" if db == float("-inf") else f"{db:.1f}"
        role_str = f" [{f['role']}]" if f.get("role") else ""
        flags = []
        if f.get("soloed"):
            flags.append("SOLO")
        if f.get("soloMuted"):
            flags.append("solo-muted")
        if f.get("muted"):
            flags.append("MUTE")
        elif f.get("muteMixed"):
            flags.append("mute-mixed")
        flag_str = f" ({', '.join(flags)})" if flags else ""
        lines.append(f"  Fader {f['index']}: {f.get('name', '?')} (lane {f['lane']})"
                     f"  {db_str} dB{role_str}{flag_str}")
        lines.append(f"    handles: clip={f.get('clipHandle','?')}"
                     f" vol={f.get('volumeChannelHandle','?')}"
                     f" es={f.get('effectStackHandle','?')}"
                     f" bus={f.get('busEffectStackHandle','?')}")
        if f.get("busKind") and f.get("busKind") != "none":
            lines.append(f"    bus: {f.get('busKind')} ({f.get('busObjectCount', 0)} object(s),"
                         f" {f.get('busEffectCount', 0)} effect(s))")
    if r.get("totalClipsAtPlayhead", 0) > 10:
        lines.append(f"\n  ({r['totalClipsAtPlayhead']} total clips, showing first 10)")
    return "\n".join(lines)


@splicekit_tool("mixer_set_volume")
def mixer_set_volume(handle: str, volume_db: float = None,
                     volume_linear: float = None) -> str:
    """Set volume on a specific clip via its volumeChannelHandle.

    Use mixer_get_state() first to get handles. For proper undo support,
    call mixer_volume_begin() before a series of changes, then mixer_volume_end() after.

    Args:
        handle: The volumeChannelHandle from mixer_get_state()
        volume_db: Volume in dB (0 = unity, -6 = half, -inf = silent). Use this OR
            volume_linear. If both are given, volume_db wins and volume_linear is ignored.
        volume_linear: Volume as linear gain (1.0 = 0dB, 0.5 = -6dB, 0 = silent)
    """
    params = {"handle": handle}
    if volume_db is not None:
        params["volumeDB"] = volume_db
    elif volume_linear is not None:
        params["volumeLinear"] = volume_linear
    else:
        return "Error: provide either volume_db or volume_linear"
    r = bridge.call("mixer.setVolume", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    db = r.get("volumeDB", 0)
    db_str = f"-inf" if db == float("-inf") else f"{db:.1f}"
    return f"Volume set: {db_str} dB (linear: {r.get('volumeLinear', 0):.3f})"


@splicekit_tool("mixer_set_solo")
def mixer_set_solo(index: int = -1, role: str = "", mode: str = "toggle",
                   solo: bool = None) -> str:
    """Solo, unsolo, or clear solo for a mixer role fader.

    Args:
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role or clearing.
        role: Role name from mixer_get_state, used when index is not provided.
        mode: "toggle", "exclusive", "add", "remove", or "clear".
        solo: Optional explicit state. If omitted, toggle/exclusive behavior is used.
    """
    params = {"mode": mode}
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role
    if solo is not None:
        params["solo"] = solo

    r = bridge.call("mixer.setSolo", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if mode == "clear":
        return "Mixer solo cleared"
    state = "soloed" if r.get("soloed") else "not soloed"
    target = r.get("role") or f"fader {r.get('index', index)}"
    return f"Mixer role {target}: {state} ({r.get('soloObjectCount', 0)} soloed objects)"


@splicekit_tool("mixer_set_mute")
def mixer_set_mute(index: int = -1, role: str = "", mode: str = "toggle",
                   muted: bool = None) -> str:
    """Mute, unmute, or clear mute for a mixer role fader.

    This uses Final Cut Pro's disabled audio-role playback map, so it does not
    change clip gain or insert mute effects.

    Args:
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role or clearing.
        role: Role name from mixer_get_state, used when index is not provided.
        mode: "toggle", "mute", "unmute", or "clear".
        muted: Optional explicit mute state. If omitted, toggle/mode behavior is used.
    """
    params = {"mode": mode}
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role
    if muted is not None:
        params["muted"] = muted

    r = bridge.call("mixer.setMute", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if mode == "clear":
        return "Mixer role mutes cleared"
    state = "muted" if r.get("muted") else "unmuted"
    target = r.get("role") or f"fader {r.get('index', index)}"
    return f"Mixer role {target}: {state} ({r.get('roleUIDCount', 0)} role UIDs)"


@splicekit_tool("mixer_apply_bus_effect")
def mixer_apply_bus_effect(effect_id: str = "", name: str = "",
                           index: int = -1, role: str = "",
                           dry_run: bool = False,
                           allow_object_fallback: bool = False) -> str:
    """Apply an audio effect to a mixer role's collection-backed bus.

    The true bus path targets role-bearing compound/collection objects, so the
    effect is inserted on the parent audio stack that all contained audio flows through.

    Args:
        effect_id: Exact FCP audio effect ID. Use this or name.
        name: Audio effect display name, e.g. "Channel EQ". Used when effect_id is empty.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        dry_run: Preview the bus targets without applying the effect.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {"dryRun": dry_run, "allowObjectFallback": allow_object_fallback}
    if effect_id:
        params["effectID"] = effect_id
    if name:
        params["name"] = name
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.applyBusEffect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    effect = r.get("effect", {})
    effect_name = effect.get("name") or effect.get("effectID") or name or effect_id
    target = r.get("role") or f"fader {r.get('index', index)}"
    count = r.get("busObjectCount", 0)
    if dry_run:
        return f"Mixer bus preview: {effect_name} -> {target} ({count} bus object{'s' if count != 1 else ''})"
    return f"Applied {effect_name} to mixer role {target} ({count} bus object{'s' if count != 1 else ''})"


@splicekit_tool("mixer_open_bus_effect")
def mixer_open_bus_effect(effect_index: int = -1, index: int = -1, role: str = "",
                          effect_handle: str = "", effect_stack_handle: str = "",
                          allow_object_fallback: bool = False) -> str:
    """Open the native FCP editor window for an effect on a mixer role bus.

    Args:
        effect_index: Zero-based effect index from mixer_get_state busEffects.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        effect_handle: Exact effect handle from mixer_get_state busEffects. Preferred when available.
        effect_stack_handle: Exact effect stack handle from mixer_get_state busEffects.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {"allowObjectFallback": allow_object_fallback}
    if effect_index >= 0:
        params["effectIndex"] = effect_index
    if effect_handle:
        params["effectHandle"] = effect_handle
    if effect_stack_handle:
        params["effectStackHandle"] = effect_stack_handle
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.openBusEffect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    effect = r.get("effect", {})
    effect_name = effect.get("name") or effect.get("effectID") or f"effect {effect_index}"
    target = r.get("role") or f"fader {r.get('index', index)}"
    return f"Opened {effect_name} editor for mixer role {target}"


@splicekit_tool("mixer_set_bus_effect_enabled")
def mixer_set_bus_effect_enabled(effect_index: int = -1, enabled: bool = True,
                                 index: int = -1, role: str = "",
                                 effect_handle: str = "", effect_stack_handle: str = "",
                                 allow_object_fallback: bool = False) -> str:
    """Enable or disable an effect on a mixer role's collection-backed bus.

    Args:
        effect_index: Zero-based effect index from mixer_get_state busEffects.
        enabled: True to enable the effect, false to disable it.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        effect_handle: Exact effect handle from mixer_get_state busEffects. Preferred when available.
        effect_stack_handle: Exact effect stack handle from mixer_get_state busEffects.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {
        "enabled": enabled,
        "allowObjectFallback": allow_object_fallback,
    }
    if effect_index >= 0:
        params["effectIndex"] = effect_index
    if effect_handle:
        params["effectHandle"] = effect_handle
    if effect_stack_handle:
        params["effectStackHandle"] = effect_stack_handle
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.setBusEffectEnabled", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    target = r.get("role") or f"fader {r.get('index', index)}"
    state = "enabled" if r.get("enabled") else "disabled"
    return f"Mixer bus effect {effect_index} on {target}: {state}"


@splicekit_tool("mixer_remove_bus_effect")
def mixer_remove_bus_effect(effect_index: int = -1, index: int = -1, role: str = "",
                            effect_handle: str = "", effect_stack_handle: str = "",
                            allow_object_fallback: bool = False) -> str:
    """Remove an effect from a mixer role's collection-backed bus.

    Args:
        effect_index: Zero-based effect index from mixer_get_state busEffects.
        index: Mixer fader index from mixer_get_state. Use -1 when addressing by role.
        role: Role name from mixer_get_state, used when index is not provided.
        effect_handle: Exact effect handle from mixer_get_state busEffects. Preferred when available.
        effect_stack_handle: Exact effect stack handle from mixer_get_state busEffects.
        allow_object_fallback: If true, target per-object audio stacks when no collection bus exists.
    """
    params = {"allowObjectFallback": allow_object_fallback}
    if effect_index >= 0:
        params["effectIndex"] = effect_index
    if effect_handle:
        params["effectHandle"] = effect_handle
    if effect_stack_handle:
        params["effectStackHandle"] = effect_stack_handle
    if index >= 0:
        params["index"] = index
    if role:
        params["role"] = role

    r = bridge.call("mixer.removeBusEffect", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    target = r.get("role") or f"fader {r.get('index', index)}"
    count = r.get("busObjectCount", 0)
    return f"Removed mixer bus effect {effect_index} from {target} ({count} bus object{'s' if count != 1 else ''})"


@splicekit_tool("mixer_volume_begin")
def mixer_volume_begin(effect_stack_handle: str) -> str:
    """Begin an undo-batched volume change (call before a series of mixer_set_volume).

    Opens an undo transaction so all volume changes until mixer_volume_end()
    are grouped as a single undo action.

    Args:
        effect_stack_handle: The effectStackHandle from mixer_get_state()
    """
    r = bridge.call("mixer.volumeBegin", effectStackHandle=effect_stack_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Undo transaction opened for volume adjustment"


@splicekit_tool("mixer_volume_end")
def mixer_volume_end(effect_stack_handle: str) -> str:
    """End an undo-batched volume change (call after mixer_set_volume series).

    Closes the undo transaction. The entire series of changes becomes one undo action.

    Args:
        effect_stack_handle: The effectStackHandle used in mixer_volume_begin()
    """
    r = bridge.call("mixer.volumeEnd", effectStackHandle=effect_stack_handle)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Undo transaction closed"


@splicekit_tool("mixer_set_all_volumes")
def mixer_set_all_volumes(volumes: list) -> str:
    """Set volumes for multiple faders at once.

    For proper undo support, call mixer_volume_begin() before this and
    mixer_volume_end() after: without that scope each fader move lands in Final Cut Pro's
    undo stack separately, or not at all, and one ``history_action("undo")`` will not put
    them all back.

    Args:
        volumes: List of dicts with 'handle' (volumeChannelHandle) and
                 'volumeDB' or 'volumeLinear'. Example:
                 [{"handle": "obj_42", "volumeDB": -6.0},
                  {"handle": "obj_43", "volumeDB": -3.0}]
                 When an entry carries both, 'volumeDB' wins.
    """
    r = bridge.call("mixer.setAllVolumes", volumes=volumes)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    results = r.get("results", [])
    lines = [f"Set {len(results)} volumes:"]
    for res in results:
        if res.get("ok"):
            db = res.get("volumeDB", 0)
            db_str = f"-inf" if db == float("-inf") else f"{db:.1f}"
            lines.append(f"  {res.get('handle', '?')}: {db_str} dB")
        else:
            lines.append(f"  {res.get('handle', '?')}: ERROR - {res.get('error', '?')}")
    return "\n".join(lines)
