"""Tools: the timeline / playback action dispatchers and playback speed."""

from ..registry import _lists_actions, DESTRUCTIVE, LOCAL, splicekit_tool
from ..bridge import _call_or_error


TIMELINE_NAVIGATION_ACTIONS = {
    "nextEdit", "previousEdit", "nextMarker", "previousMarker",
    "nextKeyframe", "previousKeyframe",
    "selectClipAtPlayhead", "selectToPlayhead", "selectAll", "deselectAll",
    "showVideoAnimation", "showAudioAnimation", "soloAnimation",
    "showTrackingEditor", "showCinematicEditor", "showMagneticMaskEditor",
    "enableBeatDetection",
    "showPrecisionEditor", "showAudioLanes", "expandSubroles",
    "showDuplicateRanges", "showKeywordEditor", "togglePrecisionEditor",
    "toggleSnapping", "toggleSkimming", "toggleClipSkimming",
    "toggleAudioSkimming", "toggleInspector", "toggleTimeline",
    "toggleTimelineIndex", "toggleInspectorHeight", "beatDetectionGrid",
    "timelineScrolling", "enterFullScreen", "timelineHistoryBack",
    "timelineHistoryForward", "zoomToFit", "zoomIn", "zoomOut",
    "verticalZoomToFit", "zoomToSamples", "goToInspector", "goToTimeline",
    "goToViewer", "goToColorBoard", "selectNextItem", "selectUpperItem",
}

TIMELINE_EDIT_ACTIONS = {
    "addMarker", "addTodoMarker", "addChapterMarker", "addTransition",
    "copy", "paste", "pasteAsConnected", "pasteEffects",
    "pasteAttributes", "removeAttributes", "copyAttributes", "copyTimecode",
    "connectToPrimaryStoryline", "insertEdit", "appendEdit", "insertGap",
    "insertPlaceholder", "addAdjustmentClip", "addColorBoard", "addColorWheels",
    "addColorCurves", "addColorAdjustment", "addHueSaturation",
    "addEnhanceLightAndColor", "balanceColor", "matchColor",
    "addMagneticMask", "smartConform", "adjustVolumeUp", "adjustVolumeDown",
    "expandAudio", "expandAudioComponents", "addChannelEQ", "enhanceAudio",
    "matchAudio", "detachAudio", "addBasicTitle", "addBasicLowerThird",
    "addKeyframe",
    "favorite", "reject", "unrate", "setRangeStart", "setRangeEnd",
    "clearRange", "setClipRange", "solo", "disable", "createCompoundClip",
    "autoReframe", "synchronizeClips", "openClip", "renameClip",
    "addToSoloedClips", "referenceNewParentClip", "changeDuration",
    "createStoryline", "liftFromPrimaryStoryline", "createAudition",
    "finalizeAudition", "nextAuditionPick", "previousAuditionPick",
    "addCaption", "createMulticamClip", "addKeywordGroup1", "addKeywordGroup2",
    "addKeywordGroup3", "addKeywordGroup4", "addKeywordGroup5",
    "addKeywordGroup6", "addKeywordGroup7", "nextColorEffect",
    "previousColorEffect", "resetColorBoard", "toggleAllColorOff",
    "alignAudioToVideo", "volumeMute", "addDefaultAudioEffect",
    "addDefaultVideoEffect", "applyAudioFades", "makeClipsUnique",
    "enableDisable", "transcodeMedia", "pasteAllAttributes", "duplicateProject", "snapshotProject",
    "projectProperties", "libraryProperties", "consolidateEventMedia",
    "mergeEvents", "renderSelection", "renderAll", "exportXML",
    "shareSelection", "find", "findAndReplaceTitle", "revealInBrowser",
    "revealProjectInBrowser", "revealInFinder", "analyzeAndFix",
    "backgroundTasks", "recordVoiceover", "editRoles", "addVideoGenerator",
}

TIMELINE_DESTRUCTIVE_ACTIONS = {
    "blade", "bladeAll", "deleteMarker", "deleteMarkersInSelection",
    "delete", "cut", "replaceWithGap", "overwriteEdit", "trimToPlayhead",
    "extendEditToPlayhead", "trimStart", "trimEnd", "joinClips", "nudgeLeft",
    "nudgeRight", "nudgeUp", "nudgeDown", "retimeNormal", "retimeFast2x",
    "retimeFast4x", "retimeFast8x", "retimeFast20x", "retimeSlow50",
    "retimeSlow25", "retimeSlow10", "retimeReverse", "retimeHold",
    "freezeFrame", "retimeBladeSpeed", "retimeSpeedRampToZero",
    "retimeSpeedRampFromZero", "deleteKeyframes", "removeAllKeyframesFromClip",
    "breakApartClipItems",
    "removeEffects", "overwriteToPrimaryStoryline", "collapseToConnectedStoryline",
    "splitCaption", "resolveOverlaps", "toggleSelectedEffectsOff",
    "toggleDuplicateDetection", "insertEditAudio", "insertEditVideo",
    "appendEditAudio", "appendEditVideo", "overwriteEditAudio",
    "overwriteEditVideo", "connectEditAudio", "connectEditVideo",
    "connectEditBacktimed", "avEditModeAudio", "avEditModeVideo",
    "avEditModeBoth", "replaceFromStart", "replaceFromEnd", "replaceWhole",
    "retimeCustomSpeed", "retimeInstantReplayHalf", "retimeInstantReplayQuarter",
    "retimeReset", "retimeOpticalFlow", "retimeFrameBlending",
    "retimeFloorFrame", "removeAllKeywords", "removeAnalysisKeywords",
    "closeLibrary", "deleteGeneratedFiles", "moveToTrash", "hideClip",
}

TIMELINE_HISTORY_ACTIONS = {
    "undo", "redo",
}


# ============================================================
# Timeline Actions
# ============================================================
# These map directly to FCP's IBAction methods on the timeline module.
# Most require a clip to be selected first (selectClipAtPlayhead).

@splicekit_tool("timeline_action", DESTRUCTIVE)
def timeline_action(action: str, dry_run: bool = False) -> str:
    """Use this legacy catch-all tool when a timeline action does not fit the narrower action tools.

    Actions:
      Blade: blade, bladeAll
      Markers: addMarker, addTodoMarker, addChapterMarker, deleteMarker, nextMarker,
               previousMarker, deleteMarkersInSelection
      Transitions: addTransition
      Navigation: nextEdit, previousEdit, selectClipAtPlayhead, selectToPlayhead
      Selection: selectAll, deselectAll
      Edit: delete, cut, copy, paste, undo, redo, pasteAsConnected, replaceWithGap,
            pasteEffects, pasteAttributes, removeAttributes, copyAttributes, copyTimecode
      Edit Modes: connectToPrimaryStoryline, insertEdit, appendEdit, overwriteEdit
      Insert: insertGap, insertPlaceholder, addAdjustmentClip
      Trim: trimToPlayhead, extendEditToPlayhead, trimStart, trimEnd, joinClips,
            nudgeLeft, nudgeRight, nudgeUp, nudgeDown
      Color: addColorBoard, addColorWheels, addColorCurves, addColorAdjustment,
             addHueSaturation, addEnhanceLightAndColor, balanceColor, matchColor,
             addMagneticMask, smartConform
      Volume: adjustVolumeUp, adjustVolumeDown
      Audio: expandAudio, expandAudioComponents, addChannelEQ, enhanceAudio,
             matchAudio, detachAudio
      Titles: addBasicTitle, addBasicLowerThird
      Speed: retimeNormal, retimeFast2x/4x/8x/20x, retimeSlow50/25/10,
             retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed,
             retimeSpeedRampToZero, retimeSpeedRampFromZero
      Keyframes: addKeyframe, deleteKeyframes, removeAllKeyframesFromClip,
                 nextKeyframe, previousKeyframe
      Rating: favorite, reject, unrate
      Range: setRangeStart, setRangeEnd, clearRange, setClipRange
      Clip Ops: solo, disable, createCompoundClip, autoReframe, detachAudio,
                breakApartClipItems, removeEffects, synchronizeClips, openClip,
                renameClip, addToSoloedClips, referenceNewParentClip, changeDuration
      Storyline: createStoryline, liftFromPrimaryStoryline,
                 overwriteToPrimaryStoryline, collapseToConnectedStoryline
      Audition: createAudition, finalizeAudition, nextAuditionPick, previousAuditionPick
      Captions: addCaption, splitCaption, resolveOverlaps
      Multicam: createMulticamClip
      Show/Hide: showVideoAnimation, showAudioAnimation, soloAnimation,
                 showTrackingEditor, showCinematicEditor, showMagneticMaskEditor,
                 enableBeatDetection, showPrecisionEditor, showAudioLanes,
                 expandSubroles, showDuplicateRanges, showKeywordEditor,
                 togglePrecisionEditor, toggleSelectedEffectsOff, toggleDuplicateDetection
      Edit Modes AV: insertEditAudio, insertEditVideo, appendEditAudio, appendEditVideo,
                     overwriteEditAudio, overwriteEditVideo, connectEditAudio,
                     connectEditVideo, connectEditBacktimed, avEditModeAudio,
                     avEditModeVideo, avEditModeBoth
      Replace: replaceFromStart, replaceFromEnd, replaceWhole
      Speed Extra: retimeCustomSpeed, retimeInstantReplayHalf, retimeInstantReplayQuarter,
                   retimeReset, retimeOpticalFlow, retimeFrameBlending, retimeFloorFrame
      Keywords: addKeywordGroup1..7
      Color Nav: nextColorEffect, previousColorEffect, resetColorBoard, toggleAllColorOff
      Audio Extra: alignAudioToVideo, volumeMute, toggleMuteAudio, addDefaultAudioEffect,
                   addDefaultVideoEffect, applyAudioFades
      Clip Extra: makeClipsUnique, enableDisable, transcodeMedia, pasteAllAttributes
      Navigate: goToInspector, goToTimeline, goToViewer, goToColorBoard,
                selectNextItem, selectUpperItem
      View: zoomToFit, zoomIn, zoomOut, verticalZoomToFit, zoomToSamples,
            toggleSnapping, toggleSkimming, toggleClipSkimming, toggleAudioSkimming,
            toggleInspector, toggleTimeline, toggleTimelineIndex, toggleInspectorHeight,
            beatDetectionGrid, timelineScrolling, enterFullScreen,
            timelineHistoryBack, timelineHistoryForward
      Project: duplicateProject, snapshotProject, projectProperties
      Library: closeLibrary, libraryProperties, consolidateEventMedia, mergeEvents,
               deleteGeneratedFiles
      Render: renderSelection, renderAll
      Export: exportXML, shareSelection
      Find: find, findAndReplaceTitle
      Reveal: revealInBrowser, revealProjectInBrowser, revealInFinder, moveToTrash
      Other: analyzeAndFix, backgroundTasks, recordVoiceover, editRoles,
             hideClip, removeAllKeywords, removeAnalysisKeywords, addVideoGenerator

    You can also pass any raw ObjC selector name.

    Pass dry_run=True to see what would fire without firing it — useful when
    you want to verify a project is loaded and a clip is selected before a
    destructive action.
    """
    return _call_or_error("timeline.action", action=action, dry_run=dry_run)


@splicekit_tool("timeline_navigation_action", LOCAL)
@_lists_actions(TIMELINE_NAVIGATION_ACTIONS,
                "Nothing here changes the project. For edits use timeline_edit_action(), for "
                "deletes and trims timeline_destructive_action(), for undo/redo history_action().")
def timeline_navigation_action(action: str) -> str:
    """Move the playhead, change the selection, or change what the timeline shows.

    Args:
        action: One of the values below.
    """
    if action not in TIMELINE_NAVIGATION_ACTIONS:
        return (
            f"Error: '{action}' is not a supported navigation action. "
            "Use timeline_edit_action(), timeline_destructive_action(), history_action(), or legacy timeline_action()."
        )
    return _call_or_error("timeline.action", action=action)


@splicekit_tool("timeline_edit_action", LOCAL)
@_lists_actions(TIMELINE_EDIT_ACTIONS,
                "These change the project but do not remove media: markers, effects, titles, "
                "roles, ranges. Undo with history_action(\"undo\"). For deletes, cuts, blades, "
                "trims and retimes use timeline_destructive_action().")
def timeline_edit_action(action: str) -> str:
    """Change the timeline without removing anything: markers, effects, titles, ranges.

    Args:
        action: One of the values below.
    """
    if action not in TIMELINE_EDIT_ACTIONS:
        return (
            f"Error: '{action}' is not a supported non-destructive edit action. "
            "Use timeline_navigation_action(), timeline_destructive_action(), history_action(), or legacy timeline_action()."
        )
    return _call_or_error("timeline.action", action=action)


@splicekit_tool("timeline_destructive_action", DESTRUCTIVE)
@_lists_actions(TIMELINE_DESTRUCTIVE_ACTIONS,
                "Every one of these removes or rewrites timeline content. Most are undoable with "
                "history_action(\"undo\") — check the result and verify with get_timeline_clips() "
                "rather than assuming.")
def timeline_destructive_action(action: str) -> str:
    """Delete, cut, blade, replace, trim or retime timeline content.

    Args:
        action: One of the values below.
    """
    if action not in TIMELINE_DESTRUCTIVE_ACTIONS:
        return (
            f"Error: '{action}' is not a supported destructive action. "
            "Use timeline_navigation_action(), timeline_edit_action(), history_action(), or legacy timeline_action()."
        )
    return _call_or_error("timeline.action", action=action)


@splicekit_tool("history_action", DESTRUCTIVE, title="Timeline History Action")
@_lists_actions(TIMELINE_HISTORY_ACTIONS)
def history_action(action: str) -> str:
    """Undo or redo the last timeline edit.

    Args:
        action: One of the values below.
    """
    if action not in TIMELINE_HISTORY_ACTIONS:
        return (
            f"Error: '{action}' is not a supported history action. "
            "Valid actions are: undo, redo."
        )
    return _call_or_error("timeline.action", action=action)


PLAYBACK_ACTIONS = (
    "playPause",
    "goToStart",
    "goToEnd",
    "nextFrame",
    "prevFrame",
    "nextFrame10",
    "prevFrame10",
    "playAroundCurrent",
    "playFromStart",
    "playInToOut",
    "playReverse",
    "stopPlaying",
    "loop",
    "fastForward",
    "rewind",
    "playRate1X",
    "playRate2X",
    "playRate4X",
    "playRate8X",
    "playRate16X",
    "playRate32X",
    "playRateHalf",
    "playRateMinusHalf",
    "playRateMinus1X",
    "playRateMinus2X",
    "playRateMinus32X",
)


def _playback_action_doc() -> str:
    return (
        "Use this tool to move playback state without changing timeline content.\n\n"
        f"Actions: {', '.join(PLAYBACK_ACTIONS)}\n\n"
        "For precise speed control, use set_playback_speed() instead."
    )


@splicekit_tool("playback_action", LOCAL)
def playback_action(action: str) -> str:
    """Use this tool to move playback state without changing timeline content."""
    if action not in PLAYBACK_ACTIONS:
        return (
            f"Error: unknown playback action '{action}'. "
            f"Available: {', '.join(PLAYBACK_ACTIONS)}"
        )
    return _call_or_error("playback.action", action=action)


playback_action.__doc__ = _playback_action_doc()


@splicekit_tool("set_playback_speed", LOCAL)
def set_playback_speed(rate: float = None, action: str = None) -> str:
    """Set playback speed to an exact rate, or use shuttle actions.

    Args:
        rate: Exact playback rate as float. Examples:
              0.5 = half speed, 1.0 = normal, 1.5, 1.8,
              2.0 = double speed, -1.0 = reverse normal.
              Supports any float value.
        action: Named speed action. One of:
              "faster" - play forward at configured L speed
              "slower" - play reverse at configured J speed
              "stop" - stop playback

    L/J speed ladders are configurable via Enhancements > Playback Speed menu,
    or via set_bridge_option("lLadder", value=[1, 1.5, 2, 4, 8]).
    Default ladders: [1, 2, 4, 8, 16, 32].
    "faster"/"slower" trigger the swizzled fastForward/rewind which walk
    the configured ladder progressively (like pressing L/J on keyboard).

    Provide either rate OR action, not both.
    """
    if rate is not None and action is not None:
        return "Error: provide either rate or action, not both"

    if rate is not None:
        return _call_or_error("playback.setRate", rate=rate)

    if action is not None:
        if action in ("faster", "slower", "stop"):
            return _call_or_error("playback.shuttle", direction=action)
        return f"Error: unknown action '{action}'. Valid: faster, slower, stop"

    return "Error: provide either rate (float) or action (string)"
