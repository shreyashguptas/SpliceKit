"""Tools: audio levels of timeline clips."""

import json

from ..config import _LOG
from ..images import _image_content, _maybe_with_image, _png_encode
from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge
from .timeline_reads import _s3


# ============================================================
# Audio levels (timeline.getAudioLevels)
# ============================================================

_SPARK_BLOCKS = "▁▂▃▄▅▆▇█"
_AUDIO_DB_LO, _AUDIO_DB_HI = -60.0, 0.0


def _is_num(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value == value


def _num_list(values, fill=-100.0):
    """Floats for a list of dB values; a missing, non-numeric or NaN entry becomes `fill` so
    positions stay aligned with the other array."""
    if not isinstance(values, (list, tuple)):
        return []
    return [float(v) if _is_num(v) else fill for v in values]


def _sparkline(values, columns=100, lo=_AUDIO_DB_LO, hi=_AUDIO_DB_HI):
    """One line of block characters for a series of dB values: the maximum of each column,
    mapped from lo..hi onto eight levels. Left is the start of the series. One column per
    value, or per 1/columns of the series when it is longer than that."""
    vals = [float(v) for v in (values or []) if _is_num(v)]
    if not vals or hi <= lo:
        return ""
    n = len(vals)
    columns = max(1, min(int(columns), n))
    out = []
    for c in range(columns):
        a = c * n // columns
        b = max(a + 1, (c + 1) * n // columns)
        f = (max(vals[a:b]) - lo) / (hi - lo)
        f = 0.0 if f < 0 else (1.0 if f > 1 else f)
        out.append(_SPARK_BLOCKS[min(7, int(f * 8))])
    return "".join(out)


def _db(value):
    return f"{value:.1f} dB" if _is_num(value) else "?"


def _ms(value, fallback="?"):
    return f"{value * 1000:.0f} ms" if _is_num(value) else fallback


def _audio_place(clip):
    return "primary storyline" if not clip.get("connected") else f"lane {clip.get('lane')} (connected clip)"


def _render_audio_levels(r: dict, detail: str) -> str:
    tl = r.get("timeline") if isinstance(r.get("timeline"), dict) else {}
    slice_s = r.get("sliceSeconds")
    silence = r.get("silenceDb") if _is_num(r.get("silenceDb")) else -50.0
    edge = r.get("edgeSeconds")
    clips = [c for c in (r.get("clips") or []) if isinstance(c, dict)]
    cuts = [c for c in (r.get("cuts") or []) if isinstance(c, dict)]
    skipped = [k for k in (r.get("skipped") or []) if isinstance(k, dict)]
    lines = ["Audio levels in dBFS measured by SpliceKit from each clip's source media file (0 = full scale; "
             "-100 is the floor for a slice with no sample above 1e-5). Not Final Cut Pro's audio meters (the mix "
             "during playback) and not its timeline waveforms (which follow the clip's volume and effects): FCP's "
             "volume, fades, effects, retiming and the mix of all concurrent clips are NOT applied. Channels are "
             "pooled, not mixed: a slice's peak is the loudest sample in any channel and its RMS is over all "
             "channels' samples (for a file with one audio track, the figures ffmpeg's volumedetect gives for the "
             "same range), unless a clip's line says mixdownMono."]
    rng = ""
    if _is_num(tl.get("rangeStartSeconds")) or _is_num(tl.get("rangeEndSeconds")):
        rng = (f"; requested range {_s3(tl.get('rangeStartSeconds')) if _is_num(tl.get('rangeStartSeconds')) else 'start'}"
               f" to {_s3(tl.get('rangeEndSeconds')) if _is_num(tl.get('rangeEndSeconds')) else 'end'}")
    fps = tl.get("frameRate")
    head = (f"Slice requested {_ms(slice_s, '50 ms')} (each clip line shows its own); silence below "
            f"{silence:.0f} dB; edge window {_ms(edge, '100 ms')}, rounded up to whole slices")
    if _is_num(fps):
        head += f"; timeline {fps:g} fps, {_s3(tl.get('durationSeconds'))}"
    lines.append(head + rng + ".")
    errors = sum(1 for c in clips if c.get("error"))
    skips = len(skipped) + sum(1 for c in clips if c.get("skipped"))
    neighbours = sum(1 for c in clips if c.get("role") == "neighbor")
    summary = (f"Clips considered: {r.get('clipCount', len(clips))}; analyzed: {r.get('analyzedCount', 0)}"
               + (f" (including {neighbours} neighbour{'s' if neighbours != 1 else ''} of the requested clip, summary only)"
                  if neighbours else "")
               + f"; skipped: {skips}; errors: {errors}")
    if r.get("outsideRangeCount"):
        summary += f"; outside the range: {r.get('outsideRangeCount')}"
    if r.get("truncatedTo"):
        summary += f"; only the first {r.get('truncatedTo')} analyzed (narrow the range or pass handles)"
    lines.append(summary + ".")

    for clip in clips:
        role = "Neighbour clip" if clip.get("role") == "neighbor" else "Clip"
        head = (f"\n{role} {clip.get('handle')} \"{clip.get('name')}\"  {_audio_place(clip)}  "
                f"{_s3(clip.get('startSeconds'))}-{_s3(clip.get('endSeconds'))} ({_s3(clip.get('durationSeconds'))})")
        if clip.get("role") == "neighbor":
            head += "  [analyzed for the cut comparison; summary only]"
        lines.append(head)
        if clip.get("error"):
            lines.append(f"  error: {clip['error']}")
            if clip.get("note"):
                lines.append(f"  note: {clip['note']}")
            continue
        if clip.get("skipped"):
            lines.append(f"  skipped: {clip['skipped']}")
            continue
        src = clip.get("source") if isinstance(clip.get("source"), dict) else {}
        audio = clip.get("audio") if isinstance(clip.get("audio"), dict) else {}
        st = clip.get("stats") if isinstance(clip.get("stats"), dict) else {}
        sl = clip.get("slices") if isinstance(clip.get("slices"), dict) else {}
        rate = audio.get("sampleRate")
        rate_s = f"{rate:g} Hz" if _is_num(rate) else "? Hz"
        a_slice = audio.get("sliceSeconds") if _is_num(audio.get("sliceSeconds")) else slice_s
        mode = audio.get("channelsMode")
        ch_n = audio.get("channels") if _is_num(audio.get("channels")) else "?"
        if mode == "pooled":
            ch_s = f"{ch_n} ch pooled"
            tracks = audio.get("audioTrackCount")
            decoded = audio.get("tracksDecoded")
            if _is_num(tracks) and tracks > 1:
                ch_s += f" over {decoded if _is_num(decoded) else tracks} of {tracks} audio tracks"
        elif mode == "mixdownMono":
            ch_s = ("1 ch mixdownMono (the decoder's mono mixdown, the fallback when no track decodes at its own "
                    "channel count: it reads 3 dB above either channel on a dual-mono file, two channels carrying "
                    "the same signal; more such channels read higher)")
        else:
            ch_s = f"{ch_n} ch decoded ({mode})"
        lines.append(f"  source: {src.get('fileName')} ({src.get('representation')}) file "
                     f"{_s3(src.get('fileStart'))}-{_s3(src.get('fileEnd'))}; {rate_s}, {ch_s}, "
                     f"{audio.get('sliceCount')} slices of {_ms(a_slice)}")
        ar = clip.get("analysisRange") if isinstance(clip.get("analysisRange"), dict) else {}
        if ar and (ar.get("startSeconds") != clip.get("startSeconds") or ar.get("endSeconds") != clip.get("endSeconds")):
            lines.append(f"  analyzed: {_s3(ar.get('startSeconds'))}-{_s3(ar.get('endSeconds'))} (the requested range)")
        count = audio.get("sliceCount") if _is_num(audio.get("sliceCount")) else 0
        silent = st.get("silentSlices") if _is_num(st.get("silentSlices")) else 0
        pct = f" ({100.0 * silent / count:.0f}%)" if count else ""
        lines.append(f"  peak max {_db(st.get('maxPeakDb'))} at {_s3(st.get('maxPeakAtSeconds'))}; "
                     f"RMS mean {_db(st.get('meanRmsDb'))}; slices at full scale (peak >= -0.1 dBFS) "
                     f"{st.get('clippedSlices', 0)}; slices below {silence:.0f} dB {silent}/{count}{pct}"
                     + ("; ALL BELOW THE SILENCE THRESHOLD" if st.get("allSilent") else ""))
        # channels="separate": the same figures per channel of the first audio track.
        for i, ch in enumerate(sl.get("perChannel") if isinstance(sl.get("perChannel"), list) else []):
            if isinstance(ch, dict) and _is_num(ch.get("maxPeakDb")):
                lines.append(f"  ch{i + 1}: peak max {_db(ch.get('maxPeakDb'))}; RMS mean {_db(ch.get('meanRmsDb'))}; "
                             f"slices at full scale {ch.get('clippedSlices', 0)}")
        lines.append(f"  start: {_s3(st.get('headSilenceSeconds'))} below threshold, first window RMS "
                     f"{_db(st.get('headRmsDb'))} (peak {_db(st.get('headPeakDb'))}); end: "
                     f"{_s3(st.get('tailSilenceSeconds'))} below threshold, last window RMS "
                     f"{_db(st.get('tailRmsDb'))} (peak {_db(st.get('tailPeakDb'))}); window {_ms(st.get('edgeSeconds'))}")
        if clip.get("retimed") is True and not clip.get("note"):
            lines.append(f"  retimed: FCP's {clip.get('retimeSelector') or 'retime flag'} is true (a speed change, or "
                         "possibly a frame-rate conform); levels mapped at normal speed, so they may not match playback")
        elif clip.get("retimed") == "unknown":
            lines.append("  retimed: unknown (no retime flag found on this clip's object; if it is retimed, the "
                         "levels do not match playback)")
        if clip.get("note"):
            lines.append(f"  note: {clip['note']}")
        if sl.get("rmsDb"):
            lines.append(f"  RMS  {_sparkline(sl.get('rmsDb'))}")
            lines.append(f"  peak {_sparkline(sl.get('peakDb'))}")
            per_channel = sl.get("perChannel") if isinstance(sl.get("perChannel"), list) else []
            for i, ch in enumerate(per_channel):
                if isinstance(ch, dict) and ch.get("rmsDb"):
                    lines.append(f"  ch{i + 1} RMS {_sparkline(ch.get('rmsDb'))}")
        if detail == "full" and sl:
            compact = {k: sl.get(k) for k in ("startSeconds", "sliceSeconds", "count", "peakDb", "rmsDb",
                                              "clippedSliceIndices") if k in sl}
            if sl.get("perChannel"):
                compact["perChannel"] = sl.get("perChannel")
            lines.append("  slices: " + json.dumps(compact, separators=(",", ":")))

    if cuts:
        lines.append("\nCuts between analysed primary-storyline clips (outgoing clip's last window -> incoming "
                     "clip's first window):")
        for cut in cuts:
            out = cut.get("outgoing") if isinstance(cut.get("outgoing"), dict) else {}
            inc = cut.get("incoming") if isinstance(cut.get("incoming"), dict) else {}
            at = _s3(cut.get("atSeconds"))
            if cut.get("transition"):
                lines.append(f"  {at}  \"{out.get('name')}\" -> \"{inc.get('name')}\": transition {cut['transition']} "
                             f"(FCP crossfades attached audio under a transition; whether this audio is expanded "
                             f"or detached is not checked)")
            elif _is_num(cut.get("jumpDb")):
                flags = []
                if cut.get("outgoingEndsInSilence"):
                    flags.append("outgoing ends below the silence threshold")
                if cut.get("incomingStartsInSilence"):
                    flags.append("incoming starts below the silence threshold")
                lines.append(f"  {at}  \"{out.get('name')}\" end {_db(out.get('tailRmsDb'))} -> "
                             f"\"{inc.get('name')}\" start {_db(inc.get('headRmsDb'))}  jump {cut['jumpDb']:+.1f} dB"
                             + (f"  ({'; '.join(flags)})" if flags else ""))
            else:
                lines.append(f"  {at}  \"{out.get('name')}\" -> \"{inc.get('name')}\": {cut.get('note', 'not a straight cut')}")
    if skipped:
        shown = "; ".join(f"{k.get('handle')} \"{k.get('name')}\" ({k.get('reason')})" for k in skipped[:20])
        more = f"; and {len(skipped) - 20} more" if len(skipped) > 20 else ""
        lines.append(f"\nSkipped: {shown}{more}")
    lines.append("\nSparklines: -60..0 dB over eight levels, one column per slice (or per 1/100 of the clip when it "
                 "has more than 100 slices), left = clip start. Raw arrays: detail=\"full\" or the RPC "
                 "timeline.getAudioLevels. `slice`, `edge window`, `jump` and the sparkline are SpliceKit's "
                 "bookkeeping, not FCP terms.")
    return "\n".join(lines)


def _render_audio_levels_png(r: dict, width: int = 1200):
    """A waveform strip of every analyzed clip that carries slices: one row per lane (upper lanes
    on top, the primary storyline, then lanes below), x = timeline seconds across the analyzed
    span (clamped to the requested range), symmetric bars (light = peak, dark = RMS, -60..0 dB),
    red top marks where a slice peaked at full scale, white lines at straight cuts between analysed
    primary-storyline clips, grey lines at regular time ticks. Returns (png_bytes, legend) or
    (None, None) when nothing was analyzed."""
    clips = []
    for c in (r.get("clips") or []):
        if not isinstance(c, dict) or not isinstance(c.get("slices"), dict) or not c.get("stats"):
            continue
        ar = c.get("analysisRange") if isinstance(c.get("analysisRange"), dict) else {}
        a0 = ar.get("startSeconds") if _is_num(ar.get("startSeconds")) else c.get("startSeconds")
        a1 = ar.get("endSeconds") if _is_num(ar.get("endSeconds")) else c.get("endSeconds")
        if _is_num(a0) and _is_num(a1) and a1 > a0:
            clips.append((float(a0), float(a1), c))
    if not clips:
        return None, None
    width = max(200, min(int(width), 4000))
    tl = r.get("timeline") if isinstance(r.get("timeline"), dict) else {}
    span_lo = min(a for a, _, _ in clips)
    span_hi = max(b for _, b, _ in clips)
    t0 = max(float(tl["rangeStartSeconds"]), span_lo) if _is_num(tl.get("rangeStartSeconds")) else span_lo
    t1 = min(float(tl["rangeEndSeconds"]), span_hi) if _is_num(tl.get("rangeEndSeconds")) else span_hi
    if t1 <= t0:
        return None, None
    lanes = sorted({int(c.get("lane")) if _is_num(c.get("lane")) else 0 for _, _, c in clips}, reverse=True)
    row_h, gutter, top, bottom = 88, 4, 14, 6
    height = top + len(lanes) * (row_h + gutter) + bottom
    bg, row_bg, clip_bg = (28, 28, 30), (36, 36, 38), (44, 44, 46)
    peak_col, rms_col, red, white = (74, 127, 181), (142, 197, 255), (255, 69, 58), (255, 255, 255)
    tick_col, edge_col, baseline = (58, 58, 60), (12, 12, 12), (70, 70, 74)
    buf = bytearray(bytes(bg) * (width * height))

    def fill(x0, y0, x1, y1, col):
        x0, x1 = max(0, min(x0, x1)), min(width, max(x0, x1))
        y0, y1 = max(0, min(y0, y1)), min(height, max(y0, y1))
        if x1 <= x0 or y1 <= y0:
            return
        row = bytes(col) * (x1 - x0)
        for y in range(y0, y1):
            off = (y * width + x0) * 3
            buf[off:off + len(row)] = row

    px_per_s = (width - 2) / (t1 - t0)

    def X(t):
        return int(round(1 + (t - t0) * px_per_s))

    span = t1 - t0
    tick = 600.0
    for cand in (0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600):
        if span / cand <= 16:
            tick = float(cand)
            break
    import math as _m
    if span / tick <= width:
        k = _m.ceil(t0 / tick)
        drawn = 0
        while k * tick <= t1 and drawn <= width:
            fill(X(k * tick), 0, X(k * tick) + 1, height, tick_col)
            k += 1
            drawn += 1

    cuts_x = [X(float(c.get("atSeconds"))) for c in (r.get("cuts") or [])
              if isinstance(c, dict) and _is_num(c.get("jumpDb")) and _is_num(c.get("atSeconds"))]
    half = row_h // 2 - 2
    for i, lane in enumerate(lanes):
        y0 = top + i * (row_h + gutter)
        y1 = y0 + row_h
        mid = y0 + row_h // 2
        fill(0, y0, width, y1, row_bg)
        fill(0, mid, width, mid + 1, baseline)
        for a0, a1, c in clips:
            c_lane = int(c.get("lane")) if _is_num(c.get("lane")) else 0
            if c_lane != lane:
                continue
            xa, xb = X(a0), X(a1)
            fill(xa, y0, xb, y1, clip_bg)
            fill(xa, y0, xa + 1, y1, edge_col)
            fill(xb - 1, y0, xb, y1, edge_col)
            fill(xa + 1, mid, xb - 1, mid + 1, baseline)   # under the bars: a silent slice shows it
            sl = c["slices"]
            peak = _num_list(sl.get("peakDb"))
            rms = _num_list(sl.get("rmsDb"))
            n = min(len(peak), len(rms))
            ss = sl.get("sliceSeconds") if _is_num(sl.get("sliceSeconds")) and sl.get("sliceSeconds") > 0 else None
            if ss is None:
                ss = r.get("sliceSeconds") if _is_num(r.get("sliceSeconds")) and r.get("sliceSeconds") > 0 else 0.05
            s0 = float(sl.get("startSeconds")) if _is_num(sl.get("startSeconds")) else a0
            idx = sl.get("clippedSliceIndices")
            clipped_idx = {int(v) for v in idx if _is_num(v)} if isinstance(idx, list) else None
            if n == 0:
                continue
            for x in range(max(xa, 0), min(xb, width)):
                ta = t0 + (x - 1) / px_per_s
                tb = t0 + x / px_per_s
                ia = int((ta - s0) / ss)
                ib = int((tb - s0) / ss)
                ia = 0 if ia < 0 else (n - 1 if ia > n - 1 else ia)
                ib = ia if ib < ia else (n - 1 if ib > n - 1 else ib)
                p = max(peak[ia:ib + 1])
                q = max(rms[ia:ib + 1])
                fp = (p - _AUDIO_DB_LO) / (_AUDIO_DB_HI - _AUDIO_DB_LO)
                fq = (q - _AUDIO_DB_LO) / (_AUDIO_DB_HI - _AUDIO_DB_LO)
                hp = int(half * (0.0 if fp < 0 else (1.0 if fp > 1 else fp)))
                hq = int(half * (0.0 if fq < 0 else (1.0 if fq > 1 else fq)))
                if hp > 0:
                    fill(x, mid - hp, x + 1, mid + hp + 1, peak_col)
                if hq > 0:
                    fill(x, mid - hq, x + 1, mid + hq + 1, rms_col)
                at_full_scale = (any(j in clipped_idx for j in range(ia, ib + 1)) if clipped_idx is not None
                                 else p >= -0.1)
                if at_full_scale:
                    fill(x, y0, x + 1, y0 + 3, red)
        if lane == 0:
            for x in cuts_x:
                fill(x, y0, x + 1, y1, white)
    legend = {"width": width, "height": height, "lanes": lanes, "startSeconds": round(t0, 3),
              "endSeconds": round(t1, 3), "tickSeconds": tick}
    return _png_encode(width, height, buf), legend


@splicekit_tool("get_audio_levels")
def get_audio_levels(handle: str = "", handles: list[str] | None = None,
                     start_seconds: float | None = None, end_seconds: float | None = None,
                     slice_ms: int = 50, channels: str = "mix", edge_ms: int = 100,
                     silence_db: float = -50.0, detail: str = "summary",
                     include_image: bool = True, image_width: int = 1200,
                     max_slices_per_clip: int = 600):
    """Audio levels of timeline clips over time, measured by SpliceKit from each clip's
    source media file: per slice the peak and the RMS level in dBFS, the way an editor
    reads a waveform. These are NOT Final Cut Pro's audio meters (which show the level of
    the mix during playback) and NOT FCP's timeline waveforms (which change with the
    clip's volume and effects); see "What the numbers are NOT". Read-only: never moves
    the playhead or the selection, never changes the project.

    Scope: one clip (`handle`, from get_timeline_clips(); its nearest primary-storyline
    neighbours with audio are analyzed too, summary only, so the cuts on both sides are
    compared), several clips (`handles`; pass one of the two, not both), a timeline range
    (`start_seconds` / `end_seconds`: every clip with audio overlapping it, each analyzed
    only inside the range), or no arguments for every clip with audio on the timeline,
    primary storyline and connected clips, at most the first 100 in timeline order (the
    answer says when it stopped; narrow with a range or handles). A whole timeline can
    take minutes: each clip's range is decoded by a helper process. Transitions, gap
    clips, titles and generators have no audio of their own, a compound or multicam clip
    has no single source media file, and a connected storyline container is analyzed
    through its clips;
    all are listed as skipped with the reason.

    Per clip: the source media file and where the clip lies in it, the sample rate and the
    number of channels pooled (and of audio tracks, when the file has several), then per slice (`slice_ms`,
    default 50 ms; lengthened for a clip that would otherwise exceed `max_slices_per_clip`
    slices, so with the defaults any clip longer than 30 s gets longer slices; each clip's
    actual slice length is reported) the peak level and the RMS level in dBFS (0 = full
    scale; -100 is the floor SpliceKit reports for a slice with no sample above 1e-5; a
    decoded peak can exceed 0), placed in timeline seconds. Summary numbers: the loudest
    slice and when, the mean RMS, how many slices peaked at or above -0.1 dBFS (at full
    scale: possible clipping; FCP's waveforms and meters turn red when a level exceeds
    0 dB), how many are below `silence_db`, the seconds below `silence_db` at the clip's
    start and end, and the RMS and peak of the first and last `edge_ms` (rounded up to
    whole slices, so at least one slice; the actual window is reported). The text carries a
    sparkline of RMS and of peak per clip; `detail="full"` appends the raw arrays as JSON.
    The image (`include_image`) is a waveform strip: one row per lane, x = timeline
    seconds, light bars = peak, dark = RMS, red top marks = slices at full scale, white
    lines = straight cuts between analyzed primary-storyline clips.

    Cuts: for neighbouring primary-storyline clips that were both analyzed, the outgoing
    clip's last window against the incoming clip's first window (`edge_ms`) and the jump in
    dB, flagging when either side is below `silence_db`. A cut with a transition on it is
    reported as such instead: Final Cut Pro applies an audio crossfade there when the
    clips' audio is attached (not when it is expanded or detached), which this tool does
    not verify. Cuts next to a gap clip, a title, a skipped or failed clip, and cuts
    between connected clips are not compared. That is where a harsh audio cut shows: fix
    it with trim_clip, a fade (direct_timeline_action applyAudioFadesDirect on the selected
    clip) or changeAudioVolume, then call this again.

    What the numbers are NOT: they are decoded from the source media file by SpliceKit's
    audio-levels helper, so Final Cut Pro's volume, fades, effects, retiming and the mix of
    all concurrent clips are not applied (the same way get_clip_info's frame is the raw
    footage). The file-to-timeline mapping always assumes normal speed (100%): for a
    retimed clip the levels and their times do not correspond to what FCP plays. `retimed`
    is FCP's own flag (`isRetimed` on 12.3) and "unknown" when the clip object answers
    none. When the flag is set the note compares two readings of the media file's video,
    its average frame rate over the file and the rate its most common frame duration
    corresponds to (neither is a "nominal" rate), with the project's rate, naming a
    variable-frame-rate recording when they differ; a conform is asserted only when both
    differ from the project's rate, and left open when they straddle it, since which one
    FCP's Rate Conform goes by SpliceKit does not know. A file at another frame rate is
    rate-conformed by FCP (Rate Conform in the Video inspector); a conform was seen to set
    the flag by itself on 12.3 (a 30 fps, variable-frame-rate screen recording in a 29.97
    fps project), and FCP's conform repeats or drops frames without a speed
    change, so the mapping holds for a conform alone; whether a speed change sits on top of
    it SpliceKit cannot tell. Check the clip's Retime state yourself before trusting a
    retimed clip's levels. Channels are pooled, never mixed: up to eight audio tracks of the
    file are decoded, each at its own channel count; a slice's peak is the loudest sample in
    any channel and its RMS is over all channels' samples (for a file with one audio track,
    the figures ffmpeg's volumedetect gives for the same range), so a channel at full scale
    is never hidden by another. `channels="separate"` adds each channel of the first audio
    track when it has more than one (up to eight): its peak max, RMS mean and full-scale
    count, a per-channel RMS sparkline and, with `detail="full"`, per-channel arrays. A clip
    whose line says mixdownMono fell back to the decoder's mono mixdown (no track decoded
    at its own channel count), which reads 3 dB above either channel on a dual-mono file
    (two channels carrying the same signal; more such channels read higher).

    Args:
        handle: one clip's handle (get_timeline_clips()).
        handles: several clips' handles (not together with `handle`).
        start_seconds / end_seconds: timeline range in seconds (either or both).
        slice_ms: slice length in milliseconds (5-5000, default 50).
        channels: "mix" (default) or "separate".
        edge_ms: window for the start/end levels and the cut comparison (10-5000, default 100).
        silence_db: RMS below this counts as silence (default -50).
        detail: "summary" (default) or "full" (raw per-slice arrays appended as JSON).
        include_image: return the waveform strip inline as MCP image content (default True).
        image_width: width of that image in pixels (200-4000, default 1200).
        max_slices_per_clip: the slice is lengthened so no clip reports more (20-4000, default 600).

    `slice`, `edge window`, `jump`, the sparkline and the waveform strip are SpliceKit's own
    bookkeeping, not FCP terms; FCP says straight cut, start point / end point and outgoing /
    incoming clip, and shows levels in dB.
    """
    if channels not in ("mix", "separate"):
        return "Error: channels must be \"mix\" or \"separate\""
    if detail not in ("summary", "full"):
        return "Error: detail must be \"summary\" or \"full\""
    try:
        slice_ms = int(slice_ms)
        edge_ms = int(edge_ms)
        image_width = int(image_width)
        max_slices_per_clip = int(max_slices_per_clip)
        silence_db = float(silence_db)
    except (TypeError, ValueError):
        return "Error: slice_ms, edge_ms, image_width and max_slices_per_clip must be integers; silence_db a number"
    if not 5 <= slice_ms <= 5000:
        return "Error: slice_ms must be between 5 and 5000"
    if not 10 <= edge_ms <= 5000:
        return "Error: edge_ms must be between 10 and 5000"
    if not 200 <= image_width <= 4000:
        return "Error: image_width must be between 200 and 4000"
    if not 20 <= max_slices_per_clip <= 4000:
        return "Error: max_slices_per_clip must be between 20 and 4000"
    if not -100.0 <= silence_db <= 0.0:
        return "Error: silence_db must be between -100 and 0"
    for name, value in (("start_seconds", start_seconds), ("end_seconds", end_seconds)):
        if value is not None and (not isinstance(value, (int, float)) or isinstance(value, bool)
                                  or value != value or value in (float("inf"), float("-inf"))):
            return f"Error: {name} must be a finite number of seconds"
    if start_seconds is not None and end_seconds is not None and end_seconds <= start_seconds:
        return "Error: end_seconds must be greater than start_seconds"
    handle_list = []
    if handles is not None:
        if isinstance(handles, str):
            handles = [handles]
        handle_list = [str(h) for h in handles if h]
        if not handle_list:
            return "Error: handles is empty; pass the clip handles from get_timeline_clips(), or leave it out"
        if handle:
            return "Error: pass handle (one clip) or handles (several), not both"

    params = {"sliceSeconds": slice_ms / 1000.0, "edgeSeconds": edge_ms / 1000.0,
              "silenceDb": silence_db, "perChannel": channels == "separate",
              "maxSlicesPerClip": max_slices_per_clip, "includeSlices": True}
    if handle:
        params["handle"] = handle
    elif handle_list:
        params["handles"] = handle_list
    if start_seconds is not None:
        params["startSeconds"] = float(start_seconds)
    if end_seconds is not None:
        params["endSeconds"] = float(end_seconds)
    # Decoding runs per clip in a helper process; a whole timeline can take minutes.
    r = bridge.call("timeline.getAudioLevels", params, timeout=180.0 if handle else 600.0)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    try:
        text = _render_audio_levels(r, detail)
    except Exception as exc:  # a rendering bug must never discard a finished analysis
        _LOG.exception("get_audio_levels: text rendering failed")
        text = f"(summary not rendered: {type(exc).__name__}: {exc}; raw answer follows)\n{_fmt(r)}"
    image = None
    if include_image:
        try:
            png, legend = _render_audio_levels_png(r, image_width)
        except Exception as exc:
            _LOG.exception("get_audio_levels: image rendering failed")
            png, legend = None, None
            text += f"\n(image not rendered: {type(exc).__name__}: {exc})"
        if png:
            image = _image_content(data=png, fmt="png")
            lanes = ", ".join("primary storyline" if l == 0 else f"lane {l}" for l in legend["lanes"])
            text += (f"\nImage ({legend['width']}x{legend['height']}): rows top to bottom = {lanes}; "
                     f"x = timeline {legend['startSeconds']:.3f}s to {legend['endSeconds']:.3f}s, grey ticks every "
                     f"{legend['tickSeconds']:g} s; light = peak, dark = RMS (-60..0 dB); red top marks = peak at "
                     f"full scale (>= -0.1 dBFS); white lines = straight cuts between analyzed primary-storyline clips.")
            if image is None:
                text += "\n  (image not attached: the mcp Image helper is unavailable in this process)"
    return _maybe_with_image(text, image)
