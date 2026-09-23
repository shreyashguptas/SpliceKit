"""Bridge answers for the offline tests, shaped like what the ObjC handlers send.

Shared by the test files (and kept here so one change to a payload shape is made once):
CMTime dicts, timeline.getDetailedState, timeline.getMarkers, timeline.getClipInfo,
timeline.captureClipFrame, timeline.selectClips, timeline.trimClip, browser.placeClip and
the clip / cut entries of timeline.getAudioLevels.
"""
import base64


# A valid 1x1 PNG; the tools only pass the bytes through, so the pixel format is irrelevant.
TINY_PNG_B64 = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJ"
                "RU5ErkJggg==")
TINY_PNG = base64.b64decode(TINY_PNG_B64)


def cmtime(seconds, timescale=600):
    return {"value": int(round(seconds * timescale)), "timescale": timescale, "seconds": seconds}


def clip_info_response(params, **overrides):
    out = {
        "handle": params["handle"], "name": "Interview A", "class": "FFAnchoredMediaComponent",
        "kind": "video clip", "onPrimaryStoryline": True, "lane": 0,
        "startTime": cmtime(0.0), "endTime": cmtime(6.0), "duration": cmtime(6.0),
        "timeline": {"start": 0.0, "end": 6.0, "duration": 6.0},
        "enabled": True, "hasVideo": True, "hasAudio": True, "selected": False,
        "roles": {"video": "Video", "audio": "Dialogue"},
        "notes": "Good take",
        "sourceMedia": {
            "path": "/Volumes/Media/interview_a.mov", "fileName": "interview_a.mov", "exists": True,
            "representation": "original", "urlSource": "media.originalMediaURL",
            "sourceStart": 12.5, "sourceStartSelector": "trimStartTime",
            "mediaOrigin": 0.0, "mediaOriginSelector": "unclippedRange",
            "fileStart": 12.5, "fileEnd": 18.5,
        },
        "effects": [{"class": "FFColorBoardEffect", "name": "Color Board",
                     "effectID": "FFColorBoardEffect", "handle": "obj_50"}],
        "effectCount": 1, "effectStackHandle": "obj_49",
        "title": {"text": "Hello", "fontName": "Helvetica-Bold", "fontFamily": "Helvetica",
                  "fontSize": 72, "textColor": "1.000 1.000 1.000 1.000",
                  "channels": [{"text": "Hello", "channelName": "Text"}], "channelCount": 1},
        "markers": [{"handle": "obj_21", "class": "FFAnchoredMarker", "kind": "todo",
                     "name": "Fix audio", "time": cmtime(1.5), "parentHandle": params["handle"]}],
        "markerCount": 1,
        "transcript": {
            "available": True, "status": "ready", "engine": "parakeet", "wordCount": 3,
            "matchedByHandle": 3, "truncated": False, "speakers": ["Host"],
            "text": "hello there world",
            "words": [{"text": "hello", "startTime": 0.5, "endTime": 0.8, "confidence": 0.9, "speaker": "Host"},
                      {"text": "there", "startTime": 0.9, "endTime": 1.2, "confidence": 0.8, "speaker": "Host"},
                      {"text": "world", "startTime": 1.3, "endTime": 1.7, "confidence": 0.7, "speaker": "Host"}],
        },
        "frame": {"format": "jpeg", "width": 640, "height": 360, "base64": TINY_PNG_B64,
                  "bytes": len(TINY_PNG), "timelineTime": 3.0, "sourceTime": 15.5, "mediaOrigin": 0.0,
                  "fileTime": 15.5, "actualFileTime": 15.5, "source": "media file", "maxWidth": 640},
        "timings": {"mainThreadMs": 4.2, "frameMs": 120.0},
    }
    out.update(overrides)
    return out


def capture_clip_frame_response(params, **overrides):
    out = {
        "status": "ok", "handle": params["handle"], "name": "Interview A",
        "class": "FFAnchoredMediaComponent", "timelineTime": params.get("frameTime", 3.0),
        "playheadBefore": 10.0, "playheadAtCapture": params.get("frameTime", 3.0),
        "playheadAfter": 10.0, "playheadRestored": True, "restorePlayhead": True,
        "path": f"/tmp/splicekit_clip_{params['handle']}.png",
        "capture": {"width": 1920, "height": 1080, "bytes": 12345, "cropped": True},
        "frame": {"format": "jpeg", "width": 960, "height": 540, "base64": TINY_PNG_B64,
                  "bytes": len(TINY_PNG), "source": "viewer", "maxWidth": 960},
    }
    out.update(overrides)
    return out


def detailed_state():
    """A getDetailedState-shaped payload: two spine clips, a music bed on lane -1,
    a title on lane 1, one chapter marker and one to-do marker."""
    return {
        "sequenceName": "Demo Edit",
        "sequenceClass": "FFAnchoredSequence",
        "playheadTime": cmtime(2.0),
        "duration": cmtime(12.0),
        "frameRate": 24.0,
        "itemCount": 2,
        "selectedCount": 2,
        "items": [
            {
                "index": 0, "class": "FFAnchoredMediaComponent", "name": "Interview A",
                "duration": cmtime(6.0), "lane": 0, "mediaType": 1, "selected": True,
                "handle": "obj_1", "startTime": cmtime(0.0), "endTime": cmtime(6.0),
                "hasVideo": True, "hasAudio": True,
            },
            {
                "index": 1, "class": "FFAnchoredMediaComponent", "name": "Interview B",
                "duration": cmtime(6.0), "lane": 0, "mediaType": 1, "selected": False,
                "handle": "obj_2", "startTime": cmtime(6.0), "endTime": cmtime(12.0),
                "hasVideo": True, "hasAudio": True,
            },
        ],
        "connectedItems": [
            {
                "class": "FFAnchoredTitle", "name": "Lower Third", "duration": cmtime(3.0),
                "lane": 1, "effectiveLane": 1, "mediaType": 1, "selected": True, "handle": "obj_11",
                "parentHandle": "obj_2", "parentIndex": 1, "depth": 0, "relation": "anchored",
                "hasVideo": True, "hasAudio": False, "isConnectedStoryline": False,
                "isGap": False, "isTransition": False,
                "startTime": cmtime(7.0), "endTime": cmtime(10.0), "timeSource": "effectiveRange",
            },
            {
                "class": "FFAnchoredMediaComponent", "name": "Music Bed", "duration": cmtime(12.0),
                "lane": -1, "effectiveLane": -1, "mediaType": 2, "selected": False, "handle": "obj_10",
                "parentHandle": "obj_1", "parentIndex": 0, "depth": 0, "relation": "anchored",
                "hasVideo": False, "hasAudio": True, "isConnectedStoryline": False,
                "isGap": False, "isTransition": False,
                "startTime": cmtime(0.0), "endTime": cmtime(12.0), "timeSource": "effectiveRange",
            },
        ],
        "connectedCount": 2,
        "markers": [
            {
                "handle": "obj_20", "class": "FFAnchoredChapterMarker", "name": "Chapter 1",
                "kind": "chapter", "time": cmtime(6.0), "timeSource": "effectiveRange",
                "parentHandle": "obj_2",
            },
            {
                "handle": "obj_21", "class": "FFAnchoredMarker", "name": "Fix audio",
                "kind": "todo", "completed": False, "time": cmtime(1.5),
                "timeSource": "effectiveRange", "parentHandle": "obj_1",
            },
        ],
        "markerCount": 2,
        "markerTotal": 2,
        "markerSources": {
            "markersInTimeRange": 2,
            "anchoredWalk": 2,
            "sequenceRespondsToMarkersInTimeRange": True,
        },
    }


def markers_response(kind=None):
    state = detailed_state()
    markers = state["markers"]
    if kind:
        markers = [m for m in markers if m["kind"] == kind]
    out = {
        "sequenceName": state["sequenceName"],
        "playheadTime": state["playheadTime"],
        "duration": state["duration"],
        "frameRate": state["frameRate"],
        "markers": markers,
        "markerCount": len(markers),
        "markerSources": state["markerSources"],
    }
    if kind:
        out["kind"] = kind
    return out


def select_response(params, **overrides):
    handles = params.get("handles", [])
    selected = [
        {"handle": h, "name": f"Clip {h}", "class": "FFAnchoredMediaComponent", "lane": 0,
         "startTime": cmtime(6.0), "endTime": cmtime(12.0)}
        for h in handles
    ]
    out = {
        "status": "ok", "mode": params.get("mode", "replace"),
        "requestedCount": len(handles), "resolvedCount": len(handles),
        "unresolved": [], "rejected": [], "selected": selected,
        "selectedCount": len(selected), "matchesRequest": True, "selector": "setSelectedItems:",
    }
    out.update(overrides)
    return out


def trim_response(params, dry_run=False):
    before = {"start": 6.0, "end": 12.0, "duration": 6.0}
    delta = params.get("deltaSeconds", -0.5)
    if dry_run:
        return {"dryRun": True, "handle": params["handle"], "name": "Interview B",
                "edge": params["edge"], "requestedDelta": delta, "deltaSeconds": delta,
                "deltaFrames": -12, "before": before,
                "projected": {"start": 6.0, "end": 12.0 + delta, "duration": 6.0 + delta},
                "frameSeconds": 1 / 24, "trimCommand": "ripple"}
    return {"status": "ok", "handle": params["handle"], "name": "Interview B",
            "edge": params["edge"], "requestedDelta": delta, "deltaSeconds": delta,
            "before": before, "after": {"start": 6.0, "end": 12.0 + delta, "duration": 6.0 + delta},
            "appliedDelta": delta, "returnedOK": True, "trimCommand": "ripple"}


def placed_response(edit="insert", **overrides):
    out = {
        "status": "ok", "dryRun": False, "edit": edit, "backtimed": False,
        "clip": "Interview A",   # legacy key: the name, as browser.appendClip always returned
        "sourceClip": {"handle": "obj_5", "name": "Interview A", "class": "FFAnchoredMediaComponent",
                       "durationSeconds": 42.0, "startSeconds": 3600.0},
        "source": {"startSeconds": 12.0, "endSeconds": 18.0, "durationSeconds": 6.0, "wholeClip": False},
        "target": {"requestedSeconds": 45.0, "playheadBeforeSeconds": 10.0, "editSeconds": 45.0,
                   "playheadAfterSeconds": 51.0},
        "placed": [{"handle": "obj_88", "name": "Interview A", "class": "FFAnchoredMediaComponent",
                    "lane": 0, "connected": False, "startSeconds": 45.0, "endSeconds": 51.0,
                    "durationSeconds": 6.0}],
        "alsoNew": [],
        "placedCount": 1, "verified": True, "rangeHonored": True, "positionVerified": True,
        "handleTableReset": False, "skimmingActive": False,
    }
    out.update(overrides)
    return out


def audio_levels_clip(handle, name, start, end, lane=0, connected=False, n=40, tail_silent=False, clipped=False,
          role=None, retimed="unknown"):
    rms = [-20.0 + (i % 5) for i in range(n)]
    peak = [v + 8.0 for v in rms]
    if tail_silent:
        rms[-6:] = [-80.0] * 6
        peak[-6:] = [-70.0] * 6
    if clipped:
        peak[3] = 0.0
    slice_s = (end - start) / n
    out = {
        "handle": handle, "name": name, "class": "FFAnchoredMediaComponent", "connected": connected,
        "lane": lane, "index": 0, "kind": "video clip", "startSeconds": start, "endSeconds": end,
        "durationSeconds": end - start, "retimed": retimed,
        "source": {"path": f"/Volumes/Media/{name}.mov", "fileName": f"{name}.mov", "representation": "original",
                   "fileStart": 3.0, "fileEnd": 3.0 + (end - start), "sourceStart": 3603.0, "mediaOrigin": 3600.0},
        "analysisRange": {"startSeconds": start, "endSeconds": end},
        "audio": {"sampleRate": 48000, "channels": 2, "channelsMode": "pooled", "audioTrackCount": 1,
                  "tracksDecoded": 1, "videoFrameRate": 24.0, "fileDuration": 120.0, "sliceSeconds": slice_s,
                  "sliceCount": n},
        "stats": {"maxPeakDb": max(peak), "maxPeakAtSeconds": start + 0.5, "meanRmsDb": -18.5,
                  "clippedSlices": 1 if clipped else 0, "silentSlices": 6 if tail_silent else 0,
                  "allSilent": False, "headSilenceSeconds": 0.0,
                  "tailSilenceSeconds": round(6 * slice_s, 3) if tail_silent else 0.0,
                  "headRmsDb": -20.0, "headPeakDb": -12.0,
                  "tailRmsDb": -80.0 if tail_silent else -19.0, "tailPeakDb": -70.0 if tail_silent else -11.0,
                  "edgeSeconds": 0.1},
    }
    if role:
        out["role"] = role          # neighbours carry no slices (summary only)
    else:
        out["slices"] = {"startSeconds": start, "sliceSeconds": slice_s, "count": n, "peakDb": peak, "rmsDb": rms,
                         "clippedSliceIndices": [3] if clipped else []}
    return out


def audio_levels_cut():
    return {"atSeconds": 2.0,
            "outgoing": {"handle": "obj_1", "name": "Interview A", "tailRmsDb": -80.0, "tailPeakDb": -70.0,
                         "tailSilenceSeconds": 0.3},
            "incoming": {"handle": "obj_2", "name": "B-roll", "headRmsDb": -20.0, "headPeakDb": -12.0,
                         "headSilenceSeconds": 0.0},
            "jumpDb": 60.0, "outgoingEndsInSilence": True, "incomingStartsInSilence": False}


def media_spine_item(index, name, handle, start, end):
    return {
        "index": index,
        "class": "FFAnchoredMediaComponent",
        "name": name,
        "duration": cmtime(end - start),
        "lane": 0,
        "mediaType": 1,
        "handle": handle,
        "startTime": cmtime(start),
        "endTime": cmtime(end),
        "hasVideo": True,
        "hasAudio": True,
    }


def three_clip_detailed_state(playhead_seconds, items=None):
    """timeline.getDetailedState for a 30 s timeline of three 10 s clips (A, B, C)."""
    if items is None:
        items = [
            media_spine_item(0, "A", "obj_a", 0, 10),
            media_spine_item(1, "B", "obj_b", 10, 20),
            media_spine_item(2, "C", "obj_c", 20, 30),
        ]
    return {
        "sequenceName": "Batch Test",
        "playheadTime": cmtime(playhead_seconds),
        "duration": cmtime(30),
        "frameRate": 24.0,
        "itemCount": len(items),
        "items": items,
    }
