"""Tools: browser clips, placing source clips, import, titles."""

import json

from ..registry import DESTRUCTIVE, LOCAL_IDEMPOTENT, READ, splicekit_tool
from ..bridge import _call_or_error, _err, bridge
from .timeline_reads import _s3


# ---------------------------------------------------------------------------
# Additional tools: browser, pasteboard import, seek, stabilize, titles,
# transcript engine selection
# ---------------------------------------------------------------------------


@splicekit_tool("browser_list_clips", READ, title="List Browser Clips")
def browser_list_clips(event: str = "") -> str:
    """List what is in the browser (the active library's events): name, event, duration,
    a handle, and whether each row is a project.

    Use the handle with add_clip_to_timeline() to make an append, insert or connect edit
    from a clip or a range of it.

    Check `isProject` first. A project sits in the browser next to the source clips but it
    is a whole timeline, not footage: add_clip_to_timeline() and browser_append_clip()
    refuse it, and remove_browser_clip() refuses it unless you pass include_projects. Open
    a project with open_project(name) instead. Items already in the library trash are not
    listed at all.

    One caveat: a project with nothing in it cannot be told apart from a clip here and
    reports `isProject: false`. Final Cut Pro answers -isProject NO and -sequenceType
    "clip" for an empty, unopened project, and there is nothing else to go on.

    Args:
        event: Optional event name to filter by (case-insensitive substring match).
    """
    params = {}
    if event:
        params["event"] = event
    return _call_or_error("browser.listClips", **params)


@splicekit_tool("browser_append_clip", DESTRUCTIVE, title="Append Browser Clip")
def browser_append_clip(handle: str = "", index: int = -1, name: str = "") -> str:
    """Append a whole browser clip at the end of the primary storyline (FCP: Append, E).
    Shortcut for add_clip_to_timeline(edit="append"); use that tool for a range of the
    clip, an insert or connect edit, a target time, or a dry run.

    Pass exactly one of handle, index or name. A project is refused: it is a whole
    timeline, not footage. Check `isProject` in browser_list_clips() before choosing.

    Args:
        handle: Object handle of the clip from browser_list_clips() (e.g. "obj_5").
            Unambiguous; preferred.
        index: The clip's `index` as browser_list_clips() reports it. That ordering is
            Final Cut Pro's and can change when the library changes, so read it fresh.
        name: The clip's name. Matched case-insensitively; an exact match wins over a
            longer name that merely contains it. If several clips still match, the first
            found wins, so prefer a handle when names repeat across events.
    """
    params = {}
    if handle:
        params["handle"] = handle
    if index >= 0:
        params["index"] = index
    if name:
        params["name"] = name
    r = bridge.call("browser.appendClip", **params)
    # The bridge carries a placementDebug dump (every timeline read it made, ~20 KB);
    # the answer is the same report add_clip_to_timeline gives.
    if _err(r):
        return f"Error: {r.get('error', str(r))}"
    if isinstance(r, dict) and r.get("placed") is not None:
        r = dict(r)
        r.setdefault("edit", "append")
        return _render_place_clip(r)
    if isinstance(r, dict):
        r = {k: v for k, v in r.items() if k != "placementDebug"}
    return json.dumps(r, indent=2, default=str)


def _yes_no(value) -> str:
    return "unknown" if value is None else ("yes" if value else "no")


def _place_where(item: dict) -> str:
    """Where a placed item sits, in FCP's words: the primary storyline, or a lane for a connected clip."""
    if item.get("connected"):
        lane = item.get("lane")
        return f"lane {lane} (connected clip)" if lane is not None else "connected clip"
    return "primary storyline"


def _render_place_clip(r: dict) -> str:
    """Human-readable report for browser.placeClip: what was asked, what landed, and
    whether the two agree (the bridge re-reads the timeline and compares within two
    frames, at least 50 ms)."""
    edit = r.get("edit", "?")
    key = {"append": "E", "insert": "W", "connect": "Q"}.get(edit, "")
    label = f"{edit} edit" + (f" (the effect of {key})" if key else "") + (" backtimed (Shift-Q)" if r.get("backtimed") else "")
    clip = r.get("sourceClip") or {}
    src = r.get("source") or {}
    tgt = r.get("target") or {}
    dry = r.get("status") == "dry_run" or r.get("dryRun") is True
    lines = []
    if dry:
        lines.append(f"Dry run (nothing changed): {label}")
    else:
        lines.append(f"{label[:1].upper()}{label[1:]}: " + ("verified" if r.get("verified") else "done, NOT verified"))
    if src.get("wholeClip"):
        span = "whole clip"
    else:
        span = f"{_s3(src.get('startSeconds'))} to {_s3(src.get('endSeconds'))} from the clip's first frame"
        if src.get("snappedToClipFrames"):
            span += " (snapped to the clip's frames)"
    lines.append(f"Source: {clip.get('name') or '?'} ({clip.get('handle') or '?'}): {span}, "
                 f"{_s3(src.get('durationSeconds'))} of {_s3(clip.get('durationSeconds'))}")
    if edit == "append":
        target = "end of the primary storyline"
        if tgt.get("storylineEndBeforeSeconds") is not None:
            target += f" (was at {_s3(tgt.get('storylineEndBeforeSeconds'))})"
        if dry:
            target += "; the playhead will be moved there"
    elif tgt.get("requestedSeconds") is not None:
        verb = "will move to" if dry else "moved to"
        target = f"playhead {verb} {_s3(tgt.get('requestedSeconds'))} ({'now' if dry else 'was'} {_s3(tgt.get('playheadBeforeSeconds'))})"
    else:
        target = f"playhead at {_s3(tgt.get('editSeconds', tgt.get('playheadBeforeSeconds')))}"
    if not dry and tgt.get("playheadAfterSeconds") is not None:
        target += f"; playhead now {_s3(tgt.get('playheadAfterSeconds'))}"
    lines.append(f"Target: {target}")
    if not dry:
        placed = r.get("placed") or []
        if not placed:
            lines.append("Placed: no new clip found on the timeline afterwards")
        for item in placed:
            lines.append(f"Placed: {item.get('name') or '?'} ({item.get('handle') or '?'}) {_place_where(item)}, "
                         f"{_s3(item.get('startSeconds'))} to {_s3(item.get('endSeconds'))} ({_s3(item.get('durationSeconds'))})")
        also = r.get("alsoNew") or []
        if also:
            shown = ", ".join(f"{i.get('name') or i.get('class') or '?'} ({i.get('handle') or '?'}) {_place_where(i)} "
                              f"{_s3(i.get('startSeconds'))} to {_s3(i.get('endSeconds'))}" for i in also[:5])
            more = f", and {len(also) - 5} more" if len(also) > 5 else ""
            lines.append(f"Also new on the timeline (not the source clip): {len(also)}: {shown}{more}")
        lines.append(f"Range honored: {_yes_no(r.get('rangeHonored'))}; position as requested: {_yes_no(r.get('positionVerified'))} "
                     "(within two frames, at least 50 ms)")
        if r.get("note"):
            lines.append(f"Note: {r['note']}")
        lines.append('Undo: history_action("undo")')
    return "\n".join(lines)


@splicekit_tool("add_clip_to_timeline", DESTRUCTIVE)
def add_clip_to_timeline(handle: str = "", name: str = "", index: int = -1,
                         edit: str = "append",
                         start_seconds: float | None = None, end_seconds: float | None = None,
                         at_seconds: float | None = None, backtimed: bool = False,
                         dry_run: bool = False) -> str:
    """Put a browser clip, or a range of it, on the timeline. SpliceKit writes the range to
    Final Cut Pro's pasteboard and uses FCP's Edit > Paste (insert) or Edit > Paste as
    Connected Clip (connect) at the playhead; append moves the playhead to the end of the
    primary storyline and pastes there. For insert and connect this is FCP's three-point
    edit: source start + end, with the playhead as the timeline point.

      edit="insert"   the effect of Insert (W): into the primary storyline at the playhead;
                      later clips move right
      edit="connect"  the effect of Connect to Primary Storyline (Q): a connected clip at the
                      playhead. FCP picks the lane (its Connect puts video above and audio-only
                      clips below the primary storyline); the answer reports where it landed
      edit="append"   the effect of Append to Storyline (E): at the end of the primary storyline
                      regardless of the playhead. SpliceKit moves the playhead there first and
                      leaves it there
      No overwrite: FCP has no paste that overwrites. FCP's own E / W / Q / D on whatever the
      browser currently has selected are timeline_edit_action("appendEdit" | "insertEdit" |
      "connectToPrimaryStoryline") and timeline_destructive_action("overwriteEdit").

    Source: prefer the handle from browser_list_clips(); name is the first case-insensitive
    substring match; index is that listing's index. start_seconds / end_seconds are the
    equivalent of a browser range selection (Set Range Start I / Set Range End O), in seconds
    from the clip's first frame. Either alone works (start only = to the end, end only = from
    the first frame); neither = the whole clip. The range is snapped to the clip's own frames
    when FCP exposes its frame duration.
    Target: at_seconds moves the playhead there first. backtimed=True (connect only, the
    effect of Connect to Primary Storyline - Backtimed, Shift-Q) puts the END of the range at
    the playhead. If the pointer is skimming over the timeline FCP may edit at the skimmer
    instead; the answer says so.

    The answer re-reads the timeline and reports the placed clip as get_timeline_clips() would
    (handle, primary storyline or lane, timeline range), whether its duration matches the range
    and its position the target (both within two frames, at least 50 ms), and anything else the
    edit created (the far half of a split clip, a gap FCP added). The pasteboard is replaced:
    whatever was copied before is gone. The edit is a single paste, so history_action("undo")
    removes it in one step (Edit > Undo shows FCP's paste name). dry_run=True resolves the
    clip, range and target and changes nothing.
    """
    edit = (edit or "append").lower()
    if edit not in ("append", "insert", "connect", "overwrite"):
        return "Error: edit must be append, insert or connect"
    if edit == "overwrite":
        return ("Error: no overwrite here: FCP has no paste that overwrites. FCP's own Overwrite (D) of the "
                "browser's current selection is timeline_destructive_action(\"overwriteEdit\"); otherwise use "
                "insert or connect")
    if not handle and not name and index < 0:
        return "Error: give the source clip as handle (from browser_list_clips), name, or index"
    if start_seconds is not None and end_seconds is not None and end_seconds <= start_seconds:
        return f"Error: end_seconds ({end_seconds}) must be after start_seconds ({start_seconds})"
    if at_seconds is not None and edit == "append":
        return "Error: an append edit always adds at the end of the primary storyline; use insert or connect with at_seconds"
    if backtimed and edit != "connect":
        return "Error: backtimed is only available for connect edits (Connect to Primary Storyline - Backtimed, Shift-Q)"
    params = {"edit": edit}
    if handle:
        params["handle"] = handle
    if name:
        params["name"] = name
    if index >= 0:
        params["index"] = index
    if start_seconds is not None:
        params["inSeconds"] = float(start_seconds)
    if end_seconds is not None:
        params["outSeconds"] = float(end_seconds)
    if at_seconds is not None:
        params["atSeconds"] = float(at_seconds)
    if backtimed:
        params["backtimed"] = True
    if dry_run:
        params["dryRun"] = True
    r = bridge.call("browser.placeClip", **params)
    if _err(r):
        return f"Error: {r.get('error', str(r))}"
    return _render_place_clip(r)


@splicekit_tool("import_media", DESTRUCTIVE, title="Import Media Files")
def import_media(paths: list[str] | None = None,
                 path: str = "",
                 event: str = "",
                 library: str = "",
                 manage_file_type: int = 0) -> str:
    """Import local media files into an event's browser — the same landing
    place dragging a file into FCP puts it.

    Wraps -[FFMediaEventProject newClipFromURL:manageFileType:] + addOwnedClipsObject:
    which is FCP's native drop-import path. Works with any file type FCP can
    read (QuickTime, MP4, MXF, etc.).

    Args:
        paths: List of absolute paths to import
        path: Single absolute path (alternative to paths)
        event: Substring match for event name (case-insensitive). Empty = first event.
        library: Substring match for library display name. Empty = any library.
        manage_file_type: 0 = leave in place (default), 1 = copy into managed media.

    Returns imported clip handles plus any skipped paths with reasons.
    """
    all_paths: list[str] = []
    if paths:
        all_paths.extend(p for p in paths if p)
    if path:
        all_paths.append(path)
    if not all_paths:
        return "Error: provide `paths` (list) or `path` (single)"
    params: dict = {"paths": all_paths, "manageFileType": manage_file_type}
    if event:
        params["event"] = event
    if library:
        params["library"] = library
    return _call_or_error("media.importFile", **params)


@splicekit_tool("remove_browser_clip", DESTRUCTIVE)
def remove_browser_clip(handle: str = "", name: str = "", event: str = "",
                        library: str = "", include_projects: bool = False,
                        dry_run: bool = False) -> str:
    """Take a source clip back out of an event's browser — the counterpart to import_media.

    Removes the clip from the event the way Final Cut Pro's own delete does
    (-removeOwnedClipsObject:, the exact inverse of the add import_media makes).
    The media file on disk is left alone.

    Refuses a project unless include_projects is set: removing a project removes a whole
    timeline. cleanup_temp_projects removes SpliceKit's own scratch projects without it.

    A name is not unique. If `name` matches more than one item — the same clip name in two
    events, or in two open libraries — nothing is removed and the error lists every match
    with its event, so you can narrow it with `event=` or pass the handle instead. A handle
    is unambiguous by definition and never triggers this.

    Returns `removed` (each with name, event and whether it was a clip or a project) and
    `failed` (anything that matched but Final Cut Pro refused to remove, with the reason).
    A partial result still reports both lists rather than reading as a total failure.

    Args:
        handle: A handle from browser_list_clips() or import_media(). Unambiguous; preferred.
        name: The clip's name exactly as the browser shows it, when no handle is given.
            Matched in full, case-sensitively, not as a substring.
        event: Substring match for the event name (case-insensitive), to narrow the search.
        library: Substring match for the library display name.
        include_projects: Allow removing a project (a whole timeline), not just a source clip.
        dry_run: Report what would be removed and change nothing. Default False.
    """
    params: dict = {}
    if handle:
        params["handle"] = handle
    if name:
        params["name"] = name
    if event:
        params["event"] = event
    if library:
        params["library"] = library
    if include_projects:
        params["includeProjects"] = True
    if dry_run:
        params["dryRun"] = True
    if not handle and not name:
        return ("Error: provide `handle` (from browser_list_clips or import_media) or "
                "`name` (the clip's name exactly as the browser shows it)")
    return _call_or_error("media.removeClip", **params)


@splicekit_tool("paste_fcpxml", DESTRUCTIVE)
def paste_fcpxml(xml: str = "") -> str:
    """Import FCPXML content via the pasteboard (no file I/O, no dialogs).

    Puts FCPXML data on the system pasteboard and triggers FCP's internal
    paste-from-XML handler. Faster and cleaner than file-based import.

    Args:
        xml: FCPXML content string
    """
    params = {}
    if xml:
        params["xml"] = xml
    return _call_or_error("fcpxml.pasteImport", **params)


@splicekit_tool("stabilize_subject", DESTRUCTIVE)
def stabilize_subject() -> str:
    """Stabilize the selected clip around a tracked subject.

    Uses the Vision framework to detect and track a subject at the current
    playhead position, then applies inverse position keyframes so the subject
    stays fixed on screen while the background moves.

    Requirements: a clip must be selected and the playhead should be on a frame
    where the subject is clearly visible. The clip's source media file and the part
    of it the clip plays are read the way get_clip_info reads them. When the playhead
    is not over the selected clip, its first frame is the reference frame. When
    Vision finds no person in the reference frame, the centre 40% of the frame is
    tracked instead; the answer's `subject` says which ("person" / "center region").
    One undo step ("Stabilize Subject").
    """
    return _call_or_error("stabilize.subject")


@splicekit_tool("insert_title", DESTRUCTIVE)
def insert_title(name: str = "", effect_id: str = "") -> str:
    """Insert a title or generator into the timeline.

    Resolves by display name or effect ID. If name is provided, searches
    all available title effects for a case-insensitive match.

    Args:
        name: Display name of the title (e.g. "Basic Title", "Lower Third")
        effect_id: Direct effect ID (e.g. "FFBasicTitleEffect")
    """
    params = {}
    if name:
        params["name"] = name
    if effect_id:
        params["effectID"] = effect_id
    return _call_or_error("titles.insert", **params)


@splicekit_tool("set_transcript_engine", LOCAL_IDEMPOTENT)
def set_transcript_engine(engine: str) -> str:
    """Set the speech recognition engine for transcript panel.

    Args:
        engine: One of:
            - "parakeet" (= "parakeetV3"): NVIDIA Parakeet TDT 0.6B v3, multilingual,
              on-device; the panel's default and the fastest
            - "parakeetV2": the English-optimized Parakeet model
            - "fcpNative": FCP's built-in AASpeechAnalyzer
            - "appleSpeech": Apple's SFSpeechRecognizer (slower; needs the Speech
              Recognition permission)
    """
    return _call_or_error("transcript.setEngine", engine=engine)
