"""Tools: clip information, clip frames and the Viewer capture."""

from ..sdk import Image
from ..images import _decode_base64_image, _image_content, _maybe_with_image
from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge, BridgeConnection
from .timeline_reads import _time_seconds


# ============================================================
# Clip Information (Info inspector fields + SpliceKit extras) and Viewer frame
# ============================================================
# Per-clip context for the AI: the Info inspector's fields for one clip
# (name, notes, roles, source media file) plus what SpliceKit adds from
# the model (timeline placement, effects, title text, markers, transcript
# words, a frame image), all by handle and without moving the playhead.

def _secs3(value):
    return f"{value:.3f}s" if isinstance(value, (int, float)) else "?"


def _render_clip_info(r: dict) -> str:
    """Compact Info-inspector style summary of a timeline.getClipInfo response."""
    tl = r.get("timeline") if isinstance(r.get("timeline"), dict) else {}
    start = tl.get("start", _time_seconds(r, "startTime"))
    end = tl.get("end", _time_seconds(r, "endTime"))
    duration = tl.get("duration", _time_seconds(r, "duration"))
    where = "primary storyline" if r.get("onPrimaryStoryline") else "connected clip"
    lines = [f"{r.get('name', '?')} — {r.get('kind', 'clip')} on lane {r.get('lane', 0)} ({where}), "
             f"{_secs3(start)}–{_secs3(end)} ({_secs3(duration)})",
             f"  handle {r.get('handle', '?')} ({r.get('class', '?')})"]
    if r.get("timelineRangeError"):
        lines.append(f"  timeline range: unknown -- {r['timelineRangeError']}")

    roles = r.get("roles") if isinstance(r.get("roles"), dict) else {}
    role_bits = []
    if roles.get("video"):
        role_bits.append(f"video: {roles['video']}")
    if roles.get("audio"):
        role_bits.append(f"audio: {roles['audio']}")
    lines.append("  roles: " + (", ".join(role_bits) if role_bits else "(none reported)"))

    flags = []
    if "enabled" in r:
        flags.append("enabled" if r.get("enabled") else "DISABLED")
    media = [name for name, key in (("video", "hasVideo"), ("audio", "hasAudio")) if r.get(key)]
    flags.append("+".join(media) if media else "no media flags")
    if r.get("selected"):
        flags.append("selected")
    lines.append("  " + ", ".join(flags))

    sm = r.get("sourceMedia")
    if isinstance(sm, dict):
        lines.append(f"  source media file: {sm.get('fileName', '?')} "
                     f"({'exists' if sm.get('exists') else 'missing on disk (FCP: Missing File)'}; "
                     f"media representation: {sm.get('representation', '?')})")
        lines.append(f"    path: {sm.get('path', '')}")
        if sm.get("isSymlink") and sm.get("resolvedPath") and sm.get("resolvedPath") != sm.get("path"):
            lines.append(f"    resolvedPath: {sm.get('resolvedPath')} (the path above is a symlink to this file)")
        if sm.get("sourceStartKnown") is False:
            lines.append(f"    start point in the source media: not read (FCP's clip object answered none of "
                         f"clippedRange / trimStartTime / trimmedOffset); media starts at "
                         f"{_secs3(sm.get('mediaOrigin'))}; taken as {_secs3(sm.get('fileStart'))}–"
                         f"{_secs3(sm.get('fileEnd'))} into the media file, counted from the file's start "
                         f"(right only if the clip's start is not trimmed)")
        else:
            lines.append(f"    start point in the source media: {_secs3(sm.get('sourceStart'))}; "
                         f"media starts at {_secs3(sm.get('mediaOrigin'))}; "
                         f"{_secs3(sm.get('fileStart'))}–{_secs3(sm.get('fileEnd'))} into the media file")
    elif r.get("sourceMediaError"):
        lines.append(f"  source media file: {r['sourceMediaError']}")

    if "effects" in r or "effectCount" in r:
        effects = r.get("effects") or []
        names = []
        for e in effects:
            if not isinstance(e, dict):
                continue
            label = e.get("name") or e.get("class", "?")
            eid = e.get("effectID")
            names.append(f"{label} ({eid})" if eid and eid != label else str(label))
        lines.append(f"  effects: {r.get('effectCount', len(effects))}" + (": " + ", ".join(names) if names else ""))
        if r.get("effectsError"):
            lines.append(f"    effects error: {r['effectsError']}")

    title = r.get("title")
    if isinstance(title, dict):
        font = ""
        if title.get("fontFamily") or title.get("fontName"):
            font = f", {title.get('fontFamily') or title.get('fontName')}"
            if title.get("fontSize") is not None:
                font += f" {title['fontSize']}pt"
        channels = [c for c in (title.get("channels") or []) if isinstance(c, dict)]
        count = title.get("channelCount", len(channels))
        lines.append(f"  title text: {title.get('text', '')!r}{font} ({count} text layer(s))")
        if len(channels) > 1:
            for c in channels[:8]:
                lines.append(f"    {c.get('channelName') or 'text'}: {str(c.get('text', ''))!r}")
            if len(channels) > 8:
                lines.append(f"    ... {len(channels) - 8} more text layer(s)")

    if "markers" in r or "markerCount" in r:
        markers = r.get("markers") or []
        lines.append(f"  markers within the clip: {r.get('markerCount', len(markers))}")
        for m in markers[:5]:
            lines.append(f"    at {_secs3(_time_seconds(m, 'time'))} (timeline) {m.get('kind', '?')} {m.get('name', '')}".rstrip())
        if len(markers) > 5:
            lines.append(f"    ... {len(markers) - 5} more")

    tr = r.get("transcript")
    if isinstance(tr, dict):
        if tr.get("error"):
            lines.append(f"  transcript (SpliceKit Text-Based Editor): error {tr['error']}")
        elif not tr.get("available"):
            lines.append(f"  transcript: none (SpliceKit Text-Based Editor status: {tr.get('status', 'idle')}; "
                         f"run open_transcript() first; this is not FCP's Transcribe to Captions)")
        else:
            words = [w for w in (tr.get("words") or []) if isinstance(w, dict)]
            span = ""
            if words and isinstance(words[0].get("startTime"), (int, float)) \
                    and isinstance(words[-1].get("endTime"), (int, float)):
                span = f", {_secs3(words[0]['startTime'])}–{_secs3(words[-1]['endTime'])} timeline"
            lines.append(f"  transcript (SpliceKit Text-Based Editor): {tr.get('wordCount', len(words))} word(s) in clip"
                         f"{span} (status {tr.get('status', '?')}, {tr.get('matchedByHandle', 0)} tagged with this handle"
                         f"{', truncated' if tr.get('truncated') else ''})")
            preview = " ".join(str(w.get("text", "")) for w in words[:60]).strip()
            if preview:
                lines.append(f'    "{preview}{" ..." if len(words) > 60 else ""}"')
            if tr.get("speakers"):
                lines.append(f"    speakers: {', '.join(str(x) for x in tr['speakers'])}")
            lines.append("    (per-word times and confidence: get_transcript() / search_transcript())")

    if r.get("notes"):
        lines.append(f"  notes: {r['notes']}")

    frame = r.get("frame")
    if isinstance(frame, dict):
        lines.append(f"  frame: {frame.get('width')}x{frame.get('height')} JPEG at {_secs3(frame.get('timelineTime'))} "
                     f"(source {_secs3(frame.get('sourceTime'))}, file {_secs3(frame.get('fileTime'))}) "
                     f"from the source media file, no effects")
    elif r.get("frameError"):
        lines.append(f"  frame: not available -- {r['frameError']}")

    timings = r.get("timings")
    if isinstance(timings, dict):
        lines.append(f"  (timings: main thread {timings.get('mainThreadMs', 0):.0f} ms, "
                     f"frame {timings.get('frameMs', 0):.0f} ms)")
    return "\n".join(lines)


@splicekit_tool("get_clip_info")
def get_clip_info(handle: str, include_frame: bool = True, frame_time: float | None = None,
                  frame_max_width: int = 640):
    """Clip information for one clip by handle: the fields Final Cut Pro's Info
    inspector shows for it, plus timeline placement, effects, title text, markers,
    transcript words and a frame from its source media file. Read-only: never moves
    the playhead and never changes the selection.

    Info inspector fields: name, notes, Video Roles / Audio Roles, and the source
    media file: path, file name, whether the file exists on disk (FCP: Missing File
    when it does not), and which media representation it is, in FCP's words:
    original, optimized or proxy (the Info inspector lists these under Available
    Media Representations). The Info inspector's Start / End / Duration are shown
    there as timecode; this tool reports timeline seconds instead (below).

    Timeline placement and source timing (SpliceKit, in seconds): start, end and
    duration on the timeline; whether the clip is on the primary storyline or a
    connected clip and its lane; enabled or disabled (Clip > Disable); selected; the
    clip's start point in the source media; where the source media starts (normally
    its starting source timecode); and how many seconds into the media file the
    clip's range lies.

    Added by SpliceKit from the model: the effects on the clip (names and effect IDs;
    get_clip_effects() for handles and parameters), the title text of a title or
    generator (text, font and size, and the text of every text layer), the markers
    placed within the clip, the words of SpliceKit's Text-Based Editor transcript that
    fall inside the clip (open_transcript() first; the summary shows the text, the
    count and the time span; get_transcript() has per-word times, confidence and
    speaker), and a JPEG frame decoded straight from the source media file at the
    clip's midpoint (or frame_time). That frame is the raw footage WITHOUT effects,
    color or transforms; use capture_clip_frame() for the rendered look. The frame is
    returned inline as MCP image content, so any MCP client can look at it.

    Args:
        handle: the clip's handle from get_timeline_clips() (e.g. "obj_12").
        include_frame: also decode a frame from the source media file (default True).
        frame_time: absolute timeline time in seconds of the frame to read; default the
                    clip's midpoint; a time outside the clip is clamped into it.
        frame_max_width: longest side of the returned frame in pixels (64-1920, default 640).

    `kind` (video clip, audio clip, title, generator, gap clip, transition, compound
    clip, reference clip, multicam clip, connected storyline, caption), handles and
    `timings` are SpliceKit's own bookkeeping, spelled with FCP's words; compound,
    reference (an FFAnchoredClip standing in for an event clip: a compound, multicam or
    synchronized clip) and multicam come from FCP's own flags on the clip, not from its
    class name. Titles, generators and gap clips have no
    source media file and report that instead of a frame. A compound clip (FCP: reference
    clip, verified on 12.3; a multicam or synchronized clip answers the same flag) has no
    single source media file: its contents are clips of their own, so no source file, no
    start point and no frame are reported for it (`containerKind` says which;
    capture_clip_frame shows it as the Viewer shows it; timeline_action "openClip" on the
    selected clip opens its own timeline). A marker is not a clip; use list_markers().
    """
    if not handle:
        return "Error: handle is required (get it from get_timeline_clips())"
    params = {"handle": handle, "includeFrame": bool(include_frame),
              "frameMaxWidth": int(frame_max_width)}
    if frame_time is not None:
        params["frameTime"] = float(frame_time)
    r = bridge.call("timeline.getClipInfo", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    text = _render_clip_info(r)
    frame = r.get("frame") if isinstance(r.get("frame"), dict) else None
    image = None
    if frame and frame.get("base64"):
        image = _image_content(data=_decode_base64_image(frame.get("base64")),
                               fmt=frame.get("format") or "jpeg")
        if image is None and Image is None:
            text += "\n  (frame available as base64 in the raw RPC timeline.getClipInfo)"
    return _maybe_with_image(text, image)


def _capture_flat_note(r: dict) -> str:
    """One WARNING line when the bridge found the captured image content to be one flat colour."""
    if not isinstance(r, dict) or not r.get("flat"):
        return ""
    return "\nWARNING: " + str(r.get("warning") or "the captured image is one flat colour: the window may have rendered nothing")


@splicekit_tool("capture_clip_frame")
def capture_clip_frame(handle: str, frame_time: float | None = None, frame_max_width: int = 960,
                       render_timeout: float = 5.0):
    """The clip as rendered in the Viewer: effects, color correction and transforms
    included. Moves the playhead to the frame time and restores it afterwards.

    Moves the playhead to frame_time (default the clip's midpoint), lets Final Cut Pro
    render the frame, captures the Viewer to a PNG (a screenshot of the Viewer, not
    FCP's File > Share > Save Current Frame export) and puts the playhead back where
    it was (the selection is not touched). The frame is returned inline as MCP image
    content and the PNG path is reported. The Viewer shows the playhead frame only
    while the pointer is not skimming over the timeline. A one-colour content region is
    reported with `flat: true` and a WARNING line; that can be a genuinely flat frame
    (black, a gap) or nothing rendered in the Viewer area.

    Prefer get_clip_info() when the raw footage is enough: it reads the frame from the
    source media file without moving the playhead. Use this tool to see what the clip
    actually looks like in the Viewer after effects, color or a title over it.

    Args:
        handle: the clip's handle from get_timeline_clips() (e.g. "obj_12").
        frame_time: absolute timeline time in seconds; default the clip's midpoint;
                    clamped into the clip.
        frame_max_width: longest side of the returned JPEG in pixels (64-1920, default 960).
        render_timeout: seconds to wait for the Viewer to show the new frame (default 5, max 15).
                    SpliceKit captures the Viewer before the seek, then keeps capturing until
                    the picture has changed and holds still. If it never changes the answer
                    says `stale` (the Viewer still showed the old frame; 60 fps or non-16:9
                    media with a Fill conform renders slowly), so retry with a longer wait.

    Reports playheadBefore / playheadAtCapture and whether the playhead was restored
    (within half a frame). If it was not, seek_to_time(playheadBefore) puts it back.
    A capture that fails still reports those playhead fields (status "failed").
    """
    if not handle:
        return "Error: handle is required (get it from get_timeline_clips())"
    render_timeout = max(0.35, min(15.0, float(render_timeout)))
    params = {"handle": handle, "frameMaxWidth": int(frame_max_width),
              "renderTimeout": render_timeout}
    if frame_time is not None:
        params["frameTime"] = float(frame_time)
    # The Viewer render wait can take the full render_timeout on the main thread.
    r = bridge.call("timeline.captureClipFrame", params,
                    timeout=max(BridgeConnection.READ_TIMEOUT, render_timeout + 25))
    if _err(r) and "status" not in r:
        return f"Error: {r.get('error', r)}"

    status = r.get("status", "?")
    tt = r.get("timelineTime")
    lines = [f"Viewer frame {'captured' if status == 'ok' else 'FAILED'} for '{r.get('name', '')}' "
             f"({r.get('handle', handle)}) at {_secs3(tt)}"]
    restored = r.get("playheadRestored")
    if isinstance(r.get("playheadBefore"), (int, float)):
        lines.append(f"  playhead: {_secs3(r.get('playheadBefore'))} -> {_secs3(r.get('playheadAtCapture'))} "
                     f"at capture -> restored: {'yes' if restored else 'NO'}")
        if not restored:
            lines.append(f"  WARNING: the playhead was not restored; seek_to_time({r.get('playheadBefore')}) puts it back")
    elif restored is False:
        lines.append("  WARNING: the playhead was moved and its previous position could not be read, so it was "
                     "not restored; check get_playhead_position()")
    if r.get("path"):
        lines.append(f"  PNG: {r['path']}")
    capture = r.get("capture") if isinstance(r.get("capture"), dict) else {}
    frame = r.get("frame") if isinstance(r.get("frame"), dict) else None
    if frame:
        where = ("as rendered in the Viewer (effects included)" if capture.get("cropped", True)
                 else "of the whole FCP window (the Viewer could not be isolated; effects included)")
        lines.append(f"  frame: {frame.get('width')}x{frame.get('height')} JPEG {where}")
    if r.get("renderWaitSeconds") is not None:
        if r.get("staleCheck"):
            lines.append(f"  render wait: {r['renderWaitSeconds']}s ({r['staleCheck']})")
        else:
            lines.append(f"  render wait: {r['renderWaitSeconds']}s (the Viewer "
                         + ("changed from the pre-seek frame" if r.get("changedFromBefore") else "did NOT change") + ")")
    if r.get("stale"):
        lines.append("  WARNING: stale: " + str(r.get("staleWarning") or
                     "the Viewer still showed the frame from before the seek"))
    elif r.get("renderStillChanging"):
        lines.append("  NOTE: the Viewer was still changing when the wait ended; the frame may be mid-render")
    if capture.get("flat") or r.get("flat"):
        lines.append("  WARNING: " + str(capture.get("warning") or r.get("warning")
                                         or "the Viewer image is one flat colour: not a verified frame"))
    failure = r.get("failure") or r.get("error")
    if failure:
        lines.append(f"  failure: {failure}")

    image = None
    if frame and frame.get("base64"):
        image = _image_content(data=_decode_base64_image(frame.get("base64")),
                               fmt=frame.get("format") or "jpeg")
        if image is None and Image is None:
            lines.append("  (frame available as base64 in the raw RPC timeline.captureClipFrame)")
    return _maybe_with_image("\n".join(lines), image)


# ============================================================
# Capture Viewer Screenshot
# ============================================================
# Captures the viewer/canvas contents directly — no external
# screencapture tool needed, no other windows in the way.

@splicekit_tool("capture_viewer")
def capture_viewer(path: str = "/tmp/splicekit_viewer.png", return_image: bool = True):
    """Capture the FCP viewer/canvas as a PNG screenshot.

    Screenshots the viewer area only (cropped from the FCP window, not the
    whole screen). Captures the window's content directly (CGWindowListCreateImage),
    so FCP need not be frontmost. Flat detection trims uniform Viewer chrome /
    letterbox bars and tests the inner content; `flat: true` with a WARNING can mean
    a genuinely flat frame (black, a gap) or that nothing rendered in the content area.

    Use after: applying effects, color correction, titles, captions, or
    any change visible in the canvas. Read the resulting PNG to visually
    verify text rendering, font/size, position, color, and compositing.

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_viewer.png
        return_image: also return the PNG inline as MCP image content (default True),
              so any MCP client can look at it without reading the file.

    Returns the file path, image dimensions, and file size, plus the image itself
    when return_image is True. The saved PNG can also be read from disk.
    """
    r = bridge.call("viewer.capture", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        text = (f"Viewer captured: {r.get('path')}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)" + _capture_flat_note(r))
        return _maybe_with_image(text, _image_content(path=r.get("path")) if return_image else None)
    return _fmt(r)
