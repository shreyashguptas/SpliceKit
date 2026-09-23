"""Tools: social media captions and native captions."""

import json

from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge


# ============================================================
# Social Media Captions
# ============================================================
# Word-by-word highlighted, animated caption titles overlaid
# on the timeline as a connected storyline. Uses the Parakeet
# transcript engine for word timing, then generates styled
# FCPXML title elements and imports via pasteboard.


@splicekit_tool("open_captions")
def open_captions(file_url: str = "", style: str = "") -> str:
    """Open the social captions panel and start transcribing the timeline.

    Transcribes timeline audio using Parakeet (word-level timing), then lets
    you choose a visual style and generate social-media-style captions
    (word-by-word highlighted, animated) as FCPXML title clips.

    Args:
        file_url: Optional path to a specific media file to transcribe.
                  If empty, transcribes all clips on the current timeline.
        style: Optional preset ID to apply (e.g. "bold_pop", "neon_glow").
               Use get_caption_styles() to see all available presets.

    Transcription is async — use get_caption_state() to check progress.
    """
    params = {}
    if file_url:
        params["fileURL"] = file_url
    if style:
        params["style"] = style
    r = bridge.call("captions.open", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("close_captions")
def close_captions() -> str:
    """Close the social captions panel."""
    r = bridge.call("captions.close")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Captions panel closed."


@splicekit_tool("get_caption_state")
def get_caption_state() -> str:
    """Get the current caption panel state.

    Returns status, word count, segment count, current style, and segment list.
    Use after open_captions() to check transcription progress.

    `Last error` is the panel's own record of the last caption run that went wrong.
    It is a state reading, not a failure of this call.
    """
    r = bridge.call("captions.getState")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Status: {r.get('status', 'unknown')}"]
    lines.append(f"Words: {r.get('wordCount', 0)}")
    lines.append(f"Segments: {r.get('segmentCount', 0)}")
    if r.get("lastError"):
        lines.append(f"Last error (from an earlier caption run): {r['lastError']}")

    if r.get('style'):
        s = r['style']
        lines.append(f"\nStyle: {s.get('name', 'Custom')}")
        lines.append(f"  Font: {s.get('font', '?')} {s.get('fontSize', '?')}pt")
        lines.append(f"  Position: {s.get('position', '?')}")
        lines.append(f"  Animation: {s.get('animation', 'none')}")
        lines.append(f"  Word highlight: {s.get('wordByWordHighlight', False)}")

    if r.get('segments'):
        lines.append(f"\nSegments ({len(r['segments'])}):")
        for seg in r['segments'][:20]:
            lines.append(f"  [{seg['index']:3d}] {seg['startTime']:.2f}s - "
                         f"{seg['endTime']:.2f}s \"{seg['text']}\"")
        if len(r['segments']) > 20:
            lines.append(f"  ... and {len(r['segments']) - 20} more")

    return "\n".join(lines)


@splicekit_tool("get_caption_styles")
def get_caption_styles() -> str:
    """List all available caption style presets.

    Returns preset IDs and their visual characteristics (font, colors, animation).
    Use set_caption_style() or generate_captions() with a preset ID to apply one.
    """
    r = bridge.call("captions.getStyles")
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Available caption styles ({r.get('count', 0)}):"]
    for s in r.get('styles', []):
        lines.append(f"\n  {s['presetID']}: \"{s['name']}\"")
        lines.append(f"    Font: {s.get('font', '?')} {s.get('fontSize', '?')}pt")
        hl = s.get('highlightColor', 'none')
        lines.append(f"    Text: {s.get('textColor', '?')}  Highlight: {hl}")
        lines.append(f"    Animation: {s.get('animation', 'none')}  Position: {s.get('position', 'bottom')}")
        lines.append(f"    Caps: {s.get('allCaps', False)}  Word highlight: {s.get('wordByWordHighlight', True)}")
    return "\n".join(lines)


@splicekit_tool("set_caption_style")
def set_caption_style(preset_id: str = "", font: str = "", font_size: float = 0,
                      text_color: str = "", highlight_color: str = "",
                      outline_color: str = "", outline_width: float = -1,
                      position: str = "", animation: str = "",
                      word_highlight: bool = True, all_caps: bool = False) -> str:
    """Set the caption style, either from a preset or with custom values.

    Args:
        preset_id: Preset name (e.g. "bold_pop", "neon_glow", "clean_minimal",
                   "karaoke", "social_bold"). Use get_caption_styles() for full list.
        font: Font family name (e.g. "Futura-Bold", "Impact", "Avenir-Heavy")
        font_size: Size in points (20-120)
        text_color: RGBA as "R G B A" (0-1 floats), e.g. "1 1 1 1" for white
        highlight_color: RGBA for active word highlight
        outline_color: RGBA for text outline/stroke
        outline_width: Stroke width (0-6)
        position: "bottom", "center", "top"
        animation: "none", "fade", "pop", "slide_up", "typewriter", "bounce"
        word_highlight: Enable word-by-word karaoke highlighting (default True)
        all_caps: Convert text to uppercase

    If preset_id is given, it's used as the base and other params override it.
    """
    params = {}
    if preset_id:
        params["presetID"] = preset_id
    if font:
        params["font"] = font
    if font_size > 0:
        params["fontSize"] = font_size
    if text_color:
        params["textColor"] = text_color
    if highlight_color:
        params["highlightColor"] = highlight_color
    if outline_color:
        params["outlineColor"] = outline_color
    if outline_width >= 0:
        params["outlineWidth"] = outline_width
    if position:
        params["position"] = position
    if animation:
        params["animation"] = animation
    params["wordByWordHighlight"] = word_highlight
    params["allCaps"] = all_caps

    r = bridge.call("captions.setStyle", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_caption_grouping")
def set_caption_grouping(mode: str = "social", max_words: int = 3,
                         max_chars: int = 20, max_seconds: float = 3.0) -> str:
    """Configure how words are grouped into caption segments.

    Args:
        mode: "social" (2-3 words, 0.5s silence break — best for TikTok/Reels),
              "words" (by word count), "sentence" (by punctuation),
              "time" (by duration), "chars" (by character count)
        max_words: Max words per segment (when mode="words", default 3)
        max_chars: Max characters per segment (when mode="chars", default 20)
        max_seconds: Max duration per segment (when mode="time", default 3.0)
    """
    r = bridge.call("captions.setGrouping",
                    mode=mode, maxWords=max_words,
                    maxChars=max_chars, maxSeconds=max_seconds)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("generate_captions")
def generate_captions(style: str = "", position: str = "center",
                      animation: str = "pop", word_highlight: bool = True,
                      max_words: int = 3, all_caps: bool = True) -> str:
    """Generate social-media-style captions and add them to the USER's timeline.

    One-shot tool: uses the current transcription (or existing words),
    applies the style, generates FCPXML title clips, imports them into a
    temp project, then copies and pastes them as a connected storyline
    onto the user's actual timeline. The temp project is deleted after.

    Position offset (bottom/center/top) is applied via ObjC transform
    after paste, not via FCPXML adjust-transform (which breaks with
    Motion templates).

    After insertion, the pipeline self-verifies by inspecting the first
    title's text channel — returns verified text, font size, and font
    family in the response.

    Requires words to be loaded first via open_captions() or set_caption_words().

    Args:
        style: Preset ID (e.g. "bold_pop", "social_bold"). Empty = current style.
        position: "bottom", "center", "top"
        animation: "none", "fade", "pop", "slide_up", "typewriter", "bounce"
        word_highlight: Word-by-word karaoke highlighting (default True)
        max_words: Max words per caption segment (default 3)
        all_caps: Convert text to uppercase

    Returns the number of caption clips generated, import status,
    and self-verification results (text, fontSize, fontFamily).
    Remove pasted title captions with remove_captions(native=False).
    """
    params = {}
    if style:
        params["style"] = style
    params["position"] = position
    params["animation"] = animation
    params["wordByWordHighlight"] = word_highlight
    params["maxWords"] = max_words
    params["allCaps"] = all_caps

    r = bridge.call("captions.generate", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("export_captions_srt")
def export_captions_srt(path: str) -> str:
    """Export the current captions as an SRT subtitle file.

    Args:
        path: Output file path (e.g. "/Users/you/Desktop/captions.srt")

    Requires captions to have been transcribed first.

    If FCP shows a save panel for the path, while it is open the bridge cannot
    serve main-thread RPC. Save/open panels cannot be confirmed from the bridge —
    only dismiss_dialog(action=\"cancel\") closes them.
    """
    r = bridge.call("captions.exportSRT", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("export_captions_txt")
def export_captions_txt(path: str) -> str:
    """Export the current captions as plain text.

    Args:
        path: Output file path (e.g. "/Users/you/Desktop/captions.txt")

    If FCP shows a save panel for the path, while it is open the bridge cannot
    serve main-thread RPC. Save/open panels cannot be confirmed from the bridge —
    only dismiss_dialog(action=\"cancel\") closes them.
    """
    r = bridge.call("captions.exportTXT", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("set_caption_words")
def set_caption_words(words: str) -> str:
    """Manually set caption words with timing (bypasses transcription).

    Args:
        words: JSON array of word objects, each with:
            {"text": "hello", "startTime": 1.5, "duration": 0.3}

    Use this when you already have word-level timing (e.g. from an SRT file
    or external transcription service).

    Example:
        set_caption_words('[
            {"text": "Hello", "startTime": 0.5, "duration": 0.3},
            {"text": "world", "startTime": 0.9, "duration": 0.4}
        ]')
    """
    try:
        word_list = json.loads(words)
    except json.JSONDecodeError as e:
        return f"Invalid JSON: {e}"

    r = bridge.call("captions.setWords", words=word_list)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("generate_native_captions")
def generate_native_captions(grouping: str = "word", language: str = "en",
                              max_words: int = 1, max_seconds: float = 3.0,
                              format: str = "ITT") -> str:
    """Generate native FCP captions (FFAnchoredCaption) with word-level timing.

    Unlike generate_captions() which creates styled Motion title clips for
    social media, this creates FCP's native caption/subtitle objects that
    appear in the dedicated caption lane. These are real captions — editable
    in FCP's caption editor and exportable as ITT/SRT/SCC files.

    The key feature: words appear one at a time (one caption per word),
    using precise word-level timing from Parakeet transcription.

    Requires words to be loaded first via open_captions() or set_caption_words().

    Args:
        grouping: How to group words into captions.
                  "word" - one caption per word (default, words appear one at a time)
                  "phrase" or "sentence" - one caption per sentence
                  "group:N" - N words per caption (e.g. "group:3")
                  "time:S" - max S seconds per caption (e.g. "time:2.0")
                  "social" - 2-3 words, break on pauses (TikTok/Reels style)
        language: Language identifier (e.g. "en", "en-US", "fr")
        max_words: Override max words per caption (when grouping="word" or "group:N")
        max_seconds: Override max duration per caption (when grouping="time:S")
        format: Caption format - "ITT" (default), "SRT", or "CEA608"

    Returns the number of native captions created and their placement status.
    Remove them later with remove_captions(native=True).
    """
    params = {
        "grouping": grouping,
        "language": language,
        "maxWords": max_words,
        "maxSeconds": max_seconds,
        "format": format,
    }
    r = bridge.call("nativeCaptions.generate", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("cleanup_temp_projects")
def cleanup_temp_projects(dry_run: bool = False) -> str:
    """Remove stale scratch projects left by caption and song-structure pipelines.

    ``generate_native_captions``, ``song_structure_blocks`` (and related
    structure-caption import) and the FCPXML pasteboard route create temporary
    import projects named ``SpliceKit Caption Import <number>``, ``SK Structure
    <number>`` or ``_SKPaste_<number>``, inside events named ``SpliceKit Captions``
    or ``SpliceKit Structure``. They should be deleted automatically when each run
    finishes; this tool finds any that were left behind and moves them to the
    library Trash.

    An event SpliceKit's own FCPXML created, holding SpliceKit scratch and nothing
    else, goes as a unit. That is also the only way to clear a scratch project Final
    Cut Pro has not loaded, which is every one left over from an earlier session. An
    empty event is never removed, however its name reads.

    Your own projects and clips are never touched. The whole name has to match one of
    the shapes above — the number is required, and Final Cut Pro's own de-duplicating
    " 2" suffix is allowed after it. A project of yours called "SK Structure notes",
    or an event called "SpliceKit Captions Q3 review", does not match and is left
    alone. Run with ``dry_run=True`` first to see exactly what it would remove.

    Args:
        dry_run: When true, only list matching project names without deleting.

    Returns found/removed project and event names, plus any that failed to delete.
    """
    r = bridge.call("captions.cleanup", dryRun=dry_run)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("verify_native_captions")
def verify_native_captions() -> str:
    """Verify native captions on the current timeline.

    Walks the timeline's caption lane and reports all FFAnchoredCaption
    objects found — their text, display names, and count. Use after
    generate_native_captions() to confirm captions were placed correctly.
    """
    r = bridge.call("nativeCaptions.verify")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


def _format_caption_removal_item(row: dict) -> str:
    label = row.get("displayName") or row.get("text") or row.get("class") or "?"
    text = row.get("text")
    if text and text != label:
        return f'  "{label}" — {text}'
    return f'  "{label}"'


def _render_remove_captions(r: dict) -> str:
    native = r.get("native", True)
    pipeline = (
        "native FFAnchoredCaption (generate_native_captions)"
        if native
        else "Motion title captions (generate_captions)"
    )
    found = int(r.get("foundCount", 0))
    removed = int(r.get("removedCount", 0))
    not_removed = r.get("notRemoved") or []
    items = r.get("items") or []

    if r.get("dryRun"):
        if found == 0:
            return f"Dry run: no {pipeline} items found on the timeline."
        lines = [f"Dry run — would remove {found} {pipeline} item(s):"]
        for row in items:
            lines.append(_format_caption_removal_item(row))
        return "\n".join(lines)

    if found == 0:
        return f"No {pipeline} items found on the timeline."

    lines = [
        f"Removed {removed} of {found} {pipeline} item(s) "
        f"(Edit > Undo \"Remove Captions\")."
    ]
    if not_removed:
        lines.append(f"Could not remove {len(not_removed)} item(s):")
        for row in not_removed:
            line = _format_caption_removal_item(row).lstrip()
            reason = row.get("reason")
            if reason:
                line += f" — {reason}"
            lines.append(f"  {line}")
    elif removed and items:
        lines.append("Removed:")
        for row in items[:min(len(items), removed)]:
            lines.append(_format_caption_removal_item(row))
    return "\n".join(lines)


@splicekit_tool("remove_captions")
def remove_captions(native: bool = True, dry_run: bool = False) -> str:
    """Delete caption items from the open sequence.

    Removes captions placed by SpliceKit caption pipelines — not scratch import
    projects (use cleanup_temp_projects for those).

    Args:
        native: When True (default), delete FCP native ``FFAnchoredCaption`` objects
            from the caption lane (the pipeline behind generate_native_captions).
            When False, delete connected Motion title clips produced by
            generate_captions (social-style title captions).
        dry_run: When True, report how many caption items would be removed without
            changing the timeline.

    Reports foundCount and removedCount separately. Only caption items from the
    chosen pipeline are considered; ordinary clips are never touched. Any item
    the bridge could not delete is listed under notRemoved with a reason.

    Supports undo via ``history_action("undo")``, which takes the whole removal back as
    one step. Run with dry_run=True first to see the count before committing.
    """
    r = bridge.call("nativeCaptions.remove", native=native, dryRun=dry_run)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _render_remove_captions(r)
