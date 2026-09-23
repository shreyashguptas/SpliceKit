"""Tools: Flexo's parameterized timeline action methods."""

from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge


# ---------------------------------------------------------------------------
# Direct Timeline Actions (parameterized Flexo methods)
# ---------------------------------------------------------------------------
# Unlike timeline_action() which dispatches through the responder chain
# with no arguments, these call Flexo's action* methods directly with
# real parameters (rates, durations, flags, etc). More powerful but
# requires knowing which parameters each action needs.

@splicekit_tool("direct_timeline_action")
def direct_timeline_action(action: str = "", selector: str = "",
                           rate: float = 0, ripple: bool = False,
                           allow_variable_speed: bool = True,
                           to_zero: bool = False, from_zero: bool = False,
                           frames_to_jump: int = 0, speed: float = 0,
                           name: str = "", marker: str = "",
                           type_: str = "", completed: bool = False,
                           amount: float = 0, frames: int = 0,
                           relative: bool = True,
                           fade_in: bool = True, duration: float = 0,
                           enabled: bool = True, effect_id: str = "",
                           keywords: str = "", language: str = "",
                           format_: str = "", multicam: bool = False,
                           as_split: bool = False, is_delta: bool = False,
                           replace_with_gap: bool = False,
                           on_edges: bool = True, on_left: bool = True,
                           add_title: bool = True,
                           interpolation: str = "",
                           time: float = -1,
                           store_result: bool = False) -> str:
    """Call Flexo's parameterized action methods directly on FFAnchoredTimelineModule.

    More powerful than timeline_action() because these accept real parameters
    (rates, durations, flags) instead of just dispatching through the responder chain.

    Many advertised actions call Flexo ``action*`` selectors that are not present on
    Final Cut Pro 12.3 (only 17 ``action*`` methods exist on FFAnchoredTimelineModule
    there). Unsupported ones return a clear error:
    ``<action> is not supported on this Final Cut Pro build``, plus ``missingSelector``
    and ``fcpVersion``. Verified working on FCP 12.3: insertGap, insertPlaceholder,
    insertGapDirect, splitAtTime, nudgeAnchoredItems, nudgeSpineItems, insertFreezeFrame,
    removeEdits, joinThroughEdits.

    Args:
        action: The action name. Available actions:

            Retiming/Speed:
              retimeSetRate (rate, ripple, allow_variable_speed)
              retimeHoldPreset, retimeReverse, retimeBladeSpeedPreset
              retimeSpeedRamp (to_zero, from_zero)
              retimeInstantReplay (rate, allow_variable_speed, add_title)
              retimeJumpCut (frames_to_jump, allow_variable_speed)
              retimeRewind (speed, allow_variable_speed)
              retimeSetInterpolation (interpolation)
              insertFreezeFrame

            Markers:
              changeMarkerType (type_: "chapter"/"todo"/"note")
              changeMarkerName (name, marker handle)
              markMarkerCompleted (completed, marker handle)
              removeMarker (marker handle)

            Audio:
              changeAudioVolume (amount, relative)
              applyAudioFadesDirect (fade_in, duration)
              setAudioPlayEnable (enabled)
              setBackgroundMusic (enabled)
              detachAudioDirect, alignAudioToVideoDirect

            Trim/Edit:
              splitAtTime (time: seconds, or current playhead when omitted)
              trimDuration (is_delta)
              extendOverNextClip, joinThroughEdits (on_edges/on_left kept for
              compatibility but ignored — FCP 12.3 only has parameterless join)
              removeEdits (replace_with_gap), insertGapDirect

            Clips:
              breakApartClipItems, createCompoundClipDirect (multicam)
              liftAnchoredEdits, renameDirect (name)
              deleteItemsInArray, moveClipsToTrash

            Keywords/Roles:
              addKeywords (keywords: comma-separated), removeKeywords

            Effects:
              removeEffectByID (effect_id), invertEffectMasks, toggleEnabled

            Multicam:
              deleteMultiAngle, renameAngle (name), audioSyncMultiAngle

            Variants:
              addVariants, removeVariants, finalizeVariant

            Captions:
              duplicateCaptions (language, format_)

            Music:
              alignToMusicMarkers, alignClipsAtMusicMarkers (as_split)

            Project:
              newProject (name), newEvent (name), validateAndRepair

            Other:
              autoReframeDirect, addTransitionsDirect
              analyzeAndOptimize, resolveLaneConflicts, resolveLaneGaps
              nudgeAnchoredItems, nudgeSpineItems (frames for whole frames, amount for
              seconds; default one project frame when neither is set)

        selector: Raw ObjC selector fallback when action is empty (e.g.
            "actionValidateAndRepair:validateMode:error:"). Passed through to timeline.directAction.

    Shared parameters (only sent when non-default; each action uses a subset):

        Retiming / speed (retimeSetRate, retimeSpeedRamp, retimeInstantReplay, retimeJumpCut,
        retimeRewind, retimeSetInterpolation, insertFreezeFrame, …):
            rate: Playback rate for retimeSetRate / retimeInstantReplay (0 skips sending).
            ripple: When True, ripple the retime to following clips (retimeSetRate).
            allow_variable_speed: When False, disallow variable-speed retime paths (default True).
            to_zero: Speed ramp toward zero (retimeSpeedRamp).
            from_zero: Speed ramp from zero (retimeSpeedRamp).
            frames_to_jump: Frame count for retimeJumpCut (>0 to send).
            speed: Rewind speed for retimeRewind (non-zero to send).
            interpolation: Interpolation mode string for retimeSetInterpolation.
            add_title: For retimeInstantReplay, whether to add a title (default True; False to send).

        Markers (changeMarkerType, changeMarkerName, markMarkerCompleted, removeMarker):
            type_: Marker kind for changeMarkerType: "chapter", "todo", or "note".
            name: New marker name for changeMarkerName / renameDirect / newProject / newEvent.
            marker: Handle of the marker object (from list_markers).
            completed: When True, mark a to-do marker completed (markMarkerCompleted).

        Audio (changeAudioVolume, applyAudioFadesDirect, setAudioPlayEnable, setBackgroundMusic):
            amount: Volume change in dB for changeAudioVolume (non-zero to send).
            relative: When False, set absolute volume instead of relative (default True).
            fade_in: When False, apply fade-out only for applyAudioFadesDirect (default True).
            duration: Fade duration in seconds for applyAudioFadesDirect (non-zero to send).
            enabled: When False, disable audio play or background music (default True).

        Trim / edit (splitAtTime, trimDuration, removeEdits, joinThroughEdits, nudge*, …):
            time: Timeline seconds for splitAtTime (>=0 to send; omit for playhead).
            is_delta: For trimDuration, how `duration` is read. True (the default) treats
                it as a change to add to the clip's current length; False treats it as the
                length to set. Getting this backwards silently trims to the wrong place.
            replace_with_gap: When True, removeEdits leaves a gap instead of ripple.
            on_edges / on_left: Ignored on FCP 12.3 for joinThroughEdits (reported in response).
            frames: Whole frames to nudge (nudgeAnchoredItems, nudgeSpineItems).
            amount: Seconds to nudge when frames is 0; also used by changeAudioVolume.

        Effects / keywords:
            effect_id: Effect identifier for removeEffectByID.
            keywords: Comma-separated keyword strings for addKeywords / removeKeywords.

        Captions / multicam / variants:
            language: Language code for duplicateCaptions.
            format_: Export format for duplicateCaptions (e.g. "SRT").
            multicam: When True, createCompoundClipDirect builds a multicam compound.
            as_split: For alignClipsAtMusicMarkers, when True each clip is cut at the
                marker and both halves are kept, instead of the clip being moved so its
                start lands on the marker.

        Misc:
            store_result: When True, retain a direct-action result object as a handle.

    Nudge amount (nudgeAnchoredItems, nudgeSpineItems): pass frames=N to move N whole
    frames, or amount=S to move S seconds. Omit both for a one-frame nudge.
    """
    # Only include params that were explicitly set -- the bridge uses their
    # presence/absence to determine which ObjC selector variant to call
    params = {}
    if action:
        params["action"] = action
    if selector:
        params["selector"] = selector
    if rate != 0:
        params["rate"] = rate
    if ripple:
        params["ripple"] = True
    if not allow_variable_speed:
        params["allowVariableSpeed"] = False
    if to_zero:
        params["toZero"] = True
    if from_zero:
        params["fromZero"] = True
    if frames_to_jump > 0:
        params["framesToJump"] = frames_to_jump
    if speed != 0:
        params["speed"] = speed
    if name:
        params["name"] = name
    if marker:
        params["marker"] = marker
    if type_:
        params["type"] = type_
    if completed:
        params["completed"] = True
    if amount != 0:
        params["amount"] = amount
    if frames != 0:
        params["frames"] = frames
    if not relative:
        params["relative"] = False
    if not fade_in:
        params["fadeIn"] = False
    if duration != 0:
        params["duration"] = duration
    if not enabled:
        params["enabled"] = False
    if effect_id:
        params["effectID"] = effect_id
    if keywords:
        params["keywords"] = [k.strip() for k in keywords.split(",")]
    if language:
        params["language"] = language
    if format_:
        params["format"] = format_
    if multicam:
        params["multicam"] = True
    if as_split:
        params["asSplit"] = True
    if is_delta:
        params["isDelta"] = True
    if replace_with_gap:
        params["replaceWithGap"] = True
    if time >= 0:
        params["time"] = time
    if not add_title:
        params["addTitle"] = False
    if interpolation:
        params["interpolation"] = interpolation
    ignored_parameters = []
    if action == "joinThroughEdits":
        if not on_edges:
            ignored_parameters.append("on_edges")
        if not on_left:
            ignored_parameters.append("on_left")

    r = bridge.call("timeline.directAction", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if ignored_parameters and isinstance(r, dict):
        r = dict(r)
        r["ignoredParameters"] = ignored_parameters
        r["ignoredParametersNote"] = (
            "FCP 12.3 only exposes the parameterless join-through-edits path "
            "(_joinSelectedThroughEdits); on_edges and on_left are not applied."
        )
    return _fmt(r)
