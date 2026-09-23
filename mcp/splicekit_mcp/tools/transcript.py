"""Tools: transcript-based editing."""

import json
import os

from ..registry import DESTRUCTIVE, LOCAL, LOCAL_IDEMPOTENT, READ, splicekit_tool
from ..bridge import _call_or_error, _err, bridge


# ============================================================
# Transcript-Based Editing
# ============================================================
# Text-based editing: transcribe clips, then edit the video by
# editing the text. Delete words to remove video segments,
# drag words to reorder clips.

@splicekit_tool("open_transcript", LOCAL)
def open_transcript(file_url: str = "", force_retranscribe: bool = False,
                    primary_storyline_only: bool = None) -> str:
    """Open the transcript panel and start transcribing.

    If no file_url is provided, transcribes all clips on the current timeline.
    If file_url is provided, transcribes that specific audio/video file.

    By default, if a persisted transcript exists it will be restored without
    re-running analysis. Set force_retranscribe=True to discard the cache
    and run a fresh transcription (a run still in progress is stopped).

    Args:
        file_url: a media file to transcribe instead of the timeline: a plain path
            ("/Users/me/a b.wav"), "~/..." or a file:// URL ("file:///Users/me/a%20b.wav").
            A file that does not exist is refused at once. File mode needs no project open.
        force_retranscribe: discard the cached transcript and transcribe again.
        primary_storyline_only: timeline mode: True transcribes only the primary storyline
            (connected clips such as B-roll and music are left out), False includes them.
            Omit to keep the current setting (default: include). Clips turned down to
            -60 dB or lower (muted, e.g. -96 dB) are always left out.

    Clips that cannot be transcribed (no audio track, e.g. a screen recording; media on
    an unmounted volume; a file the transcriber cannot decode) are skipped and listed by
    get_transcript() with the reason, instead of failing the whole run.

    The transcript panel allows text-based editing:
    - Clicking a word jumps the playhead to that time
    - Deleting words removes those segments from the timeline
    - Dragging words reorders clips on the timeline

    Transcription is async - use get_transcript() to check progress and results.
    """
    params = {}
    if file_url:
        params["fileURL"] = file_url
    if force_retranscribe:
        params["forceRetranscribe"] = True
    if primary_storyline_only is not None:
        params["primaryStorylineOnly"] = bool(primary_storyline_only)
    return _call_or_error("transcript.open", **params)


def _transcript_header_lines(r: dict) -> list:
    """Status lines shared by every form of get_transcript."""
    lines = [f"Status: {r.get('status', 'unknown')}"]
    src = r.get("source") if isinstance(r.get("source"), dict) else {}
    if src.get("mode") == "file":
        lines.append(f"Source: file {src.get('path', '?')}")
    elif src:
        lines.append("Source: timeline" + (" (primary storyline only)" if src.get("primaryStorylineOnly") else ""))
    lines.append(f"Words: {r.get('wordCount', 0)}")
    lines.append(f"Silences: {r.get('silenceCount', 0)}")
    lines.append(f"Silence threshold: {r.get('silenceThreshold', 0.3):.1f}s")
    if r.get("frameRate") is None and r.get("frameRateNote"):
        lines.append(f"Frame rate: {r['frameRateNote']}")

    if r.get('gapBuckets'):
        gb = r['gapBuckets']
        buckets = ' | '.join(f">={k}: {gb[k]}" for k in sorted(gb.keys()))
        lines.append(f"Gap histogram: {buckets}")

    if r.get('progress'):
        p = r['progress']
        line = f"Progress: {p.get('completed', 0)}/{p.get('total', 0)} files"
        if p.get("fraction") is not None:
            line += f", {float(p.get('fraction') or 0) * 100:.0f}%"
        if p.get("message"):
            line += f" — {p['message']}"
        if p.get("elapsedSeconds") is not None:
            line += f" ({p['elapsedSeconds']}s elapsed)"
        lines.append(line)

    skipped = r.get("skippedClips") or []
    if skipped:
        lines.append(f"Skipped clips ({len(skipped)}; not in the transcript):")
        for c in skipped[:40]:
            where = f"{float(c.get('timelineStart') or 0):.2f}s"
            lane = "connected" if c.get("connected") else "primary"
            name = c.get("name") or os.path.basename(str(c.get("file") or "")) or "?"
            lines.append(f"  {where} [{lane}] {name}: {c.get('reason', '?')}")
        if len(skipped) > 40:
            lines.append(f"  ... and {len(skipped) - 40} more")
    return lines


@splicekit_tool("get_transcript", READ)
def get_transcript(start_seconds: float = None, end_seconds: float = None,
                   offset: int = 0, limit: int = 1000, fields: str = "",
                   words_only: bool = False, include_silences: bool = True,
                   include_text: bool = False, format: str = "text") -> str:
    """Get the transcript: status, words with timestamps and speakers, and silences.

    A long timeline's full state is hundreds of thousands of characters, more than an
    MCP answer can carry, so this returns one page of words at a time.

    Args:
        start_seconds / end_seconds: only words and silences overlapping this timeline
            window (seconds). Omit both for the whole transcript.
        offset: skip this many words of the (windowed) list; the answer ends with the
            offset of the next page while there are more.
        limit: at most this many words (default 1000; 0 = no limit).
        fields: comma-separated word keys to return, e.g. "text,startTime,endTime"
            (index,text,startTime,endTime,duration,confidence,speaker). Default all.
        words_only: words and counts only (no silences, gap histogram or panel text).
        include_silences: list the pauses in the window (default True).
        include_text: also return the panel's rendered text (segment headers, silence
            markers) in full, for the whole transcript. Default False.
        format: "text" (default, one line per word) or "json" (the bridge's answer as
            compact JSON, for parsing).

    Status: idle / transcribing / ready / error. While transcribing, the progress line
    gives files done, percent, the transcriber's current step and the elapsed time.
    "Skipped clips" lists what the last run left out and why (no audio track, muted,
    unreadable). Raw RPC: transcript.getState with wordsOnly, fields, startSeconds,
    endSeconds, offset, limit, includeSilences, includeText, includeGapBuckets.
    """
    params = {"offset": max(0, int(offset or 0))}
    if limit and int(limit) > 0:
        params["limit"] = int(limit)
    if start_seconds is not None:
        params["startSeconds"] = float(start_seconds)
    if end_seconds is not None:
        params["endSeconds"] = float(end_seconds)
    field_list = [f.strip() for f in str(fields or "").split(",") if f.strip()]
    if field_list:
        params["fields"] = field_list
    if words_only:
        params["wordsOnly"] = True
    params["includeSilences"] = bool(include_silences) and not words_only
    params["includeText"] = bool(include_text) and not words_only
    r = bridge.call("transcript.getState", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if str(format).lower() == "json":
        return json.dumps(r, separators=(",", ":"), ensure_ascii=False)

    lines = _transcript_header_lines(r)
    # Say up front when this is not the whole list: get_transcript() used to return
    # every word, and a caller that stops reading after the header must not take a
    # first page for the full transcript.
    page = r.get('words') or []
    if r.get("nextOffset") is not None and page:
        first = r.get("wordsOffset", 0)
        lines.insert(2, f"PARTIAL: this answer lists words {first}–{first + len(page) - 1} of "
                        f"{r.get('wordsMatched', r.get('wordCount', '?'))}; next page: "
                        f"get_transcript(offset={r['nextOffset']}), or limit=0 for all")

    if r.get('text'):
        lines.append(f"\nTranscript:\n{r['text']}")

    if r.get('silences'):
        lines.append(f"\nSilences ({len(r['silences'])} pauses"
                     + (" in the window" if (start_seconds is not None or end_seconds is not None) else "") + "):")
        for s_ in r['silences']:
            lines.append(f"  {s_.get('startTimecode', '?')} - {s_.get('endTimecode', '?')} "
                         f"({s_['duration']:.1f}s) after word [{s_.get('afterWordIndex', '?')}]")

    words = r.get('words') or []
    if words:
        matched = r.get("wordsMatched", len(words))
        first = r.get("wordsOffset", 0)
        lines.append(f"\nWord list ({len(words)} words, {first}–{first + len(words) - 1} of {matched}"
                     + (" in the window" if (start_seconds is not None or end_seconds is not None) else "") + "):")
        for w in words:
            if field_list:
                lines.append("  " + " ".join(
                    f"{k}={w[k]!r}" if isinstance(w.get(k), str)
                    else f"{k}={w[k]:.3f}" if isinstance(w.get(k), float)
                    else f"{k}={w.get(k)}" for k in field_list if k in w))
                continue
            conf = (w.get('confidence') or 0) * 100
            speaker = w.get('speaker', 'Unknown')
            lines.append(f"  [{w['index']:3d}] {w['startTime']:7.2f}s - {w['endTime']:7.2f}s "
                         f"({conf:3.0f}%) [{speaker}] \"{w['text']}\"")
        if r.get("nextOffset") is not None:
            lines.append(f"\nMore words: get_transcript(offset={r['nextOffset']}"
                         + (f", start_seconds={start_seconds}" if start_seconds is not None else "")
                         + (f", end_seconds={end_seconds}" if end_seconds is not None else "")
                         + (f", limit={limit}" if limit else "") + ")")

    # The bridge reports the failure reason in `errorMessage` (see
    # SpliceKitTranscriptPanel getState). Reading only `error` meant every failed
    # transcription came back as a bare "Status: error" with no explanation,
    # which is indistinguishable from the feature being broken.
    detail = r.get('errorMessage') or r.get('error')
    if detail:
        lines.append(f"\nError: {detail}")
    elif r.get('status') == 'error':
        lines.append("\nError: transcription failed, but the bridge reported no reason. "
                     "Check the SpliceKit log panel in Final Cut Pro for [Transcript] lines.")

    return "\n".join(lines)


@splicekit_tool("delete_transcript_words", DESTRUCTIVE)
def delete_transcript_words(start_index: int, count: int) -> str:
    """Delete words from the transcript, which removes the corresponding video segments.

    This performs a ripple delete on the timeline:
    1. Blades at the start time of the first word
    2. Blades at the end time of the last word
    3. Selects and deletes the segment between the blades

    Args:
        start_index: Index of the first word to delete (from get_transcript word list)
        count: Number of consecutive words to delete

    The timeline gap closes automatically (ripple delete).
    Use timeline_action("undo") to reverse.
    """
    return _call_or_error("transcript.deleteWords", startIndex=start_index, count=count)


@splicekit_tool("move_transcript_words", DESTRUCTIVE)
def move_transcript_words(start_index: int, count: int, dest_index: int) -> str:
    """Move words in the transcript to a new position, which reorders clips on the timeline.

    This performs a cut-and-paste on the timeline:
    1. Blades at source start/end to isolate the segment
    2. Cuts the segment
    3. Moves playhead to the destination position
    4. Pastes the segment

    Args:
        start_index: Index of the first word to move
        count: Number of consecutive words to move
        dest_index: Target position in the word list (the words will be inserted before this index)

    Use timeline_action("undo") to reverse.
    """
    return _call_or_error("transcript.moveWords", startIndex=start_index, count=count,
                          destIndex=dest_index)


@splicekit_tool("close_transcript", LOCAL_IDEMPOTENT, title="Close Transcript Panel")
def close_transcript() -> str:
    """Close the transcript panel."""
    r = bridge.call("transcript.close")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Transcript panel closed."


@splicekit_tool("search_transcript", READ)
def search_transcript(query: str) -> str:
    """Search the transcript for text or special keywords.

    Args:
        query: Search text to find in the transcript.
               Special keywords: "pauses" or "silences" to find all detected pauses.

    Returns matching words or silences with timestamps.
    Also updates the UI to highlight matches.
    """
    r = bridge.call("transcript.search", query=query)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Query: {r.get('query', query)}"]
    lines.append(f"Results: {r.get('resultCount', 0)}")

    results = r.get("results", [])
    for res in results:
        if res.get("type") == "silence":
            lines.append(f"  [Pause] {res['startTime']:.2f}s - {res['endTime']:.2f}s ({res['duration']:.1f}s)")
        else:
            lines.append(f"  [{res.get('index', '?'):3d}] {res['startTime']:.2f}s - {res['endTime']:.2f}s "
                         f"({res.get('confidence', 0)*100:.0f}%) \"{res.get('text', '')}\"")

    return "\n".join(lines)


@splicekit_tool("delete_transcript_silences", DESTRUCTIVE)
def delete_transcript_silences(min_duration: float = 0.0) -> str:
    """Delete all detected silences/pauses from the timeline.

    This performs batch ripple-deletes on all silence gaps, removing dead air
    from the video. Silences are deleted from end to start to maintain accuracy.

    Args:
        min_duration: Minimum silence duration in seconds to delete. Default 0 = all silences.
                      Use 0.5 to only delete pauses longer than half a second, etc.

    Use timeline_action("undo") repeatedly to reverse.
    """
    r = bridge.call("transcript.deleteSilences", minDuration=min_duration)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    lines = [f"Status: {r.get('status', 'unknown')}"]
    lines.append(f"Deleted: {r.get('deletedCount', 0)}/{r.get('totalSilences', 0)} silences")
    if r.get("lastError"):
        lines.append(f"Last error: {r['lastError']}")

    return "\n".join(lines)


@splicekit_tool("set_transcript_speaker", LOCAL)
def set_transcript_speaker(start_index: int, count: int, speaker: str) -> str:
    """Assign a speaker name to a range of words in the transcript.

    Args:
        start_index: Index of the first word to label
        count: Number of consecutive words to label
        speaker: Speaker name (e.g., "Host", "Guest", "Speaker 1")

    This updates the speaker labels in the transcript display.
    """
    return _call_or_error("transcript.setSpeaker", speaker=speaker, startIndex=start_index,
                          count=count)


@splicekit_tool("set_silence_threshold", LOCAL_IDEMPOTENT)
def set_silence_threshold(threshold: float) -> str:
    """Set the minimum gap duration (seconds) to detect as a silence/pause.

    Args:
        threshold: Duration in seconds. Default is 0.3 (300ms).
                   Lower values detect shorter pauses, higher values only long ones.

    Takes effect immediately — silences are recomputed from existing word
    timings without re-transcription. Returns the updated silence count.
    """
    return _call_or_error("transcript.setSilenceThreshold", threshold=threshold)
