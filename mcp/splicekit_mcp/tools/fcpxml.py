"""Tools: FCPXML import, URL import, FCPXML generation."""

import json
import time

from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge
from ..otio_fcpxml import _otio_write_fcpx_string


# ============================================================
# FCPXML Import & Generation
# ============================================================
# FCPXML is Apple's interchange format for FCP projects. We can
# generate it programmatically and import it to create complex
# timelines without clicking through FCP's UI.

def _format_import_job(job: dict) -> str:
    lines = [f"Import job {job.get('jobId', '?')}: {job.get('state', '?')}"
             + (f" after {job.get('elapsedSeconds')}s" if job.get("elapsedSeconds") is not None else "")]
    if job.get("path"):
        lines.append(f"  file: {job['path']}")
    res = job.get("result") if isinstance(job.get("result"), dict) else {}
    if res.get("library"):
        lines.append(f"  library: {res['library']} (chosen by {res.get('libraryChosenBy', '?')})")
    if res.get("libraryNote"):
        lines.append(f"  NOTE: {res['libraryNote']}")
    if res.get("routeNote"):
        lines.append(f"  NOTE: {res['routeNote']}")
    if job.get("message") and job.get("state") == "handedToFCP":
        lines.append(f"  {job['message']}")
    if job.get("importError") or job.get("error"):
        lines.append(f"  error: {job.get('importError') or job.get('error')}")
    windows = job.get("windows") or []
    if job.get("state") == "running" and windows:
        titles = [w.get("title") or "(untitled)" for w in windows if isinstance(w, dict)]
        lines.append(f"  Final Cut Pro windows now: {', '.join(titles)}")
        if any("Import" in t for t in titles):
            lines.append("  (an import progress sheet is up: media on a network volume can take minutes; "
                         "do not start the import again)")
    if job.get("state") == "running":
        lines.append(f"  Poll again: import_fcpxml_status(job_id=\"{job.get('jobId')}\")")
    return "\n".join(lines)


@splicekit_tool("import_fcpxml")
def import_fcpxml(xml: str = "", path: str = "", internal: bool = True,
                  library: str = "", wait_seconds: float = 60) -> str:
    """Import FCPXML into Final Cut Pro, from a file on this Mac or from a string.

    Args:
        xml: the FCPXML document as a string (this or path).
        path: a .fcpxml file on this Mac — plain path, "~/..." or file:// URL. Read on
            the Mac side, so a large document does not have to travel through the client.
        internal: True (default) imports through FCP's own pasteboard importer into an
            open library: no restart and no "Which library do you want to import into?"
            chooser. False opens the file with FCP (NSWorkspace), which shows that
            chooser as a modal panel whenever FCP asks, blocking the bridge until it is
            answered; avoid it unless the library is not open.
        library: name of the open library to import into. Default: the library the
            XML's <library location> names when it is open, else the first open library
            (the answer says which was used and why).
        wait_seconds: how long to wait for the import to finish (default 60). The import
            runs as a job on the Mac either way: an FCPXML whose media sits on a network
            volume keeps FCP's "Importing Remote Resources" sheet up for minutes. If it is
            still running when the wait ends, the answer gives the job id; poll
            import_fcpxml_status(job_id) and do NOT import again (it would import twice).

    Returns the job state (ok / error / running), the library it went into, and the
    error text when it failed. Raw RPC: fcpxml.import (xml | path, internal, library,
    async=true) and fcpxml.importStatus(jobId).
    """
    # With neither, the bridge answers "xml or path parameter required".
    params = {"internal": bool(internal), "async": True}
    if xml:
        params["xml"] = xml
    elif path:
        params["path"] = path
    if library:
        params["library"] = library
    r = bridge.call("fcpxml.import", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    job_id = r.get("jobId")
    if not job_id:
        return _fmt(r)
    deadline = time.time() + max(0.0, float(wait_seconds or 0))
    job = {"jobId": job_id, "state": "running"}
    delay = 0.25
    while True:
        st = bridge.call("fcpxml.importStatus", jobId=job_id)
        if not _err(st):
            job = st
        if job.get("state") != "running" or time.time() >= deadline:
            break
        time.sleep(delay)
        delay = min(2.0, delay * 1.5)
    return _format_import_job(job)


@splicekit_tool("import_fcpxml_status")
def import_fcpxml_status(job_id: str = "") -> str:
    """State of an FCPXML import started by import_fcpxml (running / ok / error).

    Answers without Final Cut Pro's main thread, so it works while an import's progress
    sheet has that thread busy; while a job runs it also lists FCP's on-screen windows
    (the "Import XML" sheet shows up there). Omit job_id to list every job since FCP
    started.
    """
    params = {"jobId": job_id} if job_id else {}
    r = bridge.call("fcpxml.importStatus", **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    if job_id:
        return _format_import_job(r)
    jobs = r.get("jobs") or []
    if not jobs:
        return "No FCPXML import jobs since Final Cut Pro started."
    windows = r.get("windows") or []
    out = []
    for j in jobs:
        if j.get("state") == "running" and windows:
            j = {**j, "windows": windows}
        out.append(_format_import_job(j))
    return "\n".join(out)


@splicekit_tool("import_url")
def import_url(url: str, mode: str = "import_only", target_event: str = "",
               title: str = "", highest_quality: bool = False,
               wait_until_complete: bool = True) -> str:
    """Download a remote media URL, import it into Final Cut Pro, and optionally
    place it into the active timeline.

    Args:
        url: Direct media URL (.mp4, .mov, .m4v, .webm) or a supported provider URL
            like YouTube or Vimeo.
        mode: "import_only", "insert_at_playhead", or "append_to_timeline".
        target_event: Optional event name override.
        title: Optional clip title override.
        highest_quality: If True, fetch the highest available resolution from
            YouTube/Vimeo (1080p/1440p/4K via VP9/AV1 when needed). Default False
            downloads the best progressive mp4 (typically 720p) for faster imports.
        wait_until_complete: If False, returns immediately with a job_id that can
            be polled via import_url_status().

    Notes:
        Provider URLs rely on yt-dlp + ffmpeg being available to the modded app.
    """
    params = {"url": url, "mode": mode}
    if target_event:
        params["target_event"] = target_event
    if title:
        params["title"] = title
    if highest_quality:
        params["highest_quality"] = True

    method = "urlImport.import" if wait_until_complete else "urlImport.start"
    r = bridge.call(method, **params)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("import_url_status")
def import_url_status(job_id: str) -> str:
    """Check the current status of a URL import job."""
    r = bridge.call("urlImport.status", job_id=job_id)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("cancel_import_url")
def cancel_import_url(job_id: str) -> str:
    """Cancel an in-flight URL import job."""
    r = bridge.call("urlImport.cancel", job_id=job_id)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("generate_fcpxml")
def generate_fcpxml(event_name: str = "SpliceKit Event", project_name: str = "SpliceKit Project",
                    frame_rate: str = "24", width: int = 1920, height: int = 1080,
                    items: str = "[]") -> str:
    """Generate valid FCPXML for import using OpenTimelineIO.

    Builds an OTIO Timeline from the provided items, then serializes to FCPXML
    via the otio-fcpx-xml-adapter. Title and transition items (which OTIO doesn't
    model natively) are injected as FCPXML-specific post-processing.

    Args:
        event_name: FCP event name embedded in the FCPXML (default "SpliceKit Event").
        project_name: Sequence/project name in the FCPXML (default "SpliceKit Project").
        frame_rate: Timeline frame rate as a string: 23.976, 24, 25, 29.97, 30, 48, 50,
            59.94, or 60 (default "24").
        width: Project raster width in pixels (default 1920).
        height: Project raster height in pixels (default 1080).
        items: JSON array of timeline items (string). Each item:
      {"type": "gap", "duration": 5.0}
      {"type": "gap", "duration": 5.0, "name": "My Gap"}
      {"type": "title", "text": "Hello World", "duration": 5.0}
      {"type": "title", "text": "Lower Third", "duration": 3.0, "position": "lower-third"}
      {"type": "marker", "time": 2.5, "name": "Review Here", "kind": "standard"}
      {"type": "marker", "time": 5.0, "name": "Chapter 1", "kind": "chapter"}
      {"type": "transition", "duration": 1.0}

    Returns the FCPXML string. Pass to import_fcpxml() or import_otio() to load into FCP.

    Example:
      xml = generate_fcpxml(project_name="Test", items='[
        {"type":"gap","duration":5},
        {"type":"transition","duration":1},
        {"type":"title","text":"Hello","duration":3},
        {"type":"gap","duration":5},
        {"type":"marker","time":2,"name":"Start","kind":"chapter"}
      ]')
      import_fcpxml(xml, internal=True)
    """
    try:
        item_list = json.loads(items)
    except json.JSONDecodeError:
        item_list = []

    # Frame rate string → numeric fps for OTIO RationalTime
    fps_map = {
        "23.976": 23.98, "24": 24, "25": 25, "29.97": 29.97,
        "30": 30, "48": 48, "50": 50, "59.94": 59.94, "60": 60,
    }
    fps = fps_map.get(frame_rate, 24)

    # Separate spine items, markers, titles, and transitions
    spine_items = [i for i in item_list if i.get("type") in ("gap", "title", "transition", None)]
    markers = [i for i in item_list if i.get("type") == "marker"]

    if not spine_items:
        spine_items = [{"type": "gap", "duration": 10.0}]

    # Keep the direct builder for title/transition synthesis. The custom `items`
    # input schema is intentionally tiny and relies on FCP-specific defaults.
    has_fcpxml_only_items = any(i.get("type") in ("title", "transition") for i in spine_items)

    if has_fcpxml_only_items:
        # Fall back to direct FCPXML construction for full feature support
        return _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers)

    # Build OTIO Timeline from items
    try:
        import opentimelineio as otio
        from opentimelineio import opentime
    except ImportError:
        return _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers)

    timeline = otio.schema.Timeline(name=project_name)
    track = otio.schema.Track(name="V1", kind=otio.schema.TrackKind.Video)

    for item in spine_items:
        itype = item.get("type", "gap")
        idur = item.get("duration", 5.0)
        frames = round(idur * fps)

        if itype == "gap":
            gap = otio.schema.Gap(
                source_range=opentime.TimeRange(
                    start_time=opentime.RationalTime(0, fps),
                    duration=opentime.RationalTime(frames, fps)
                )
            )
            track.append(gap)

    timeline.tracks.append(track)

    # Add markers to the first gap/clip (OTIO attaches markers to items, not the sequence)
    marker_color_map = {
        "standard": otio.schema.MarkerColor.PURPLE,
        "todo": otio.schema.MarkerColor.RED,
        "chapter": otio.schema.MarkerColor.GREEN,
    }
    if markers and len(track) > 0:
        for m in markers:
            mt = m.get("time", 0)
            mname = m.get("name", "Marker")
            mkind = m.get("kind", "standard")
            mdur = m.get("duration", 1.0 / fps)
            marker = otio.schema.Marker(
                name=mname,
                marked_range=opentime.TimeRange(
                    start_time=opentime.RationalTime(round(mt * fps), fps),
                    duration=opentime.RationalTime(max(1, round(mdur * fps)), fps)
                ),
                color=marker_color_map.get(mkind, otio.schema.MarkerColor.PURPLE)
            )
            track[0].markers.append(marker)

    # Serialize to FCPXML via the adapter
    try:
        xml = _otio_write_fcpx_string(timeline)
    except Exception as e:
        # Fall back to direct construction on adapter failure
        return _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers)

    return xml


def _generate_fcpxml_direct(event_name, project_name, frame_rate, width, height, spine_items, markers):
    """Direct FCPXML string construction for items that OTIO can't model (titles, transitions)."""
    fr_map = {
        "23.976": (1001, 24000), "24": (100, 2400), "25": (100, 2500),
        "29.97": (1001, 30000), "30": (100, 3000), "48": (100, 4800),
        "50": (100, 5000), "59.94": (1001, 60000), "60": (100, 6000),
    }
    fd_num, fd_den = fr_map.get(frame_rate, (100, 2400))
    fd_str = f"{fd_num}/{fd_den}s"

    def dur_rational(seconds):
        frames = round(seconds * fd_den / fd_num)
        return f"{frames * fd_num}/{fd_den}s"

    spine_xml = ""
    offset_seconds = 0.0
    total_seconds = 0.0
    ts_counter = 1

    for item in spine_items:
        itype = item.get("type", "gap")
        idur = item.get("duration", 5.0)
        iname = item.get("name", "")
        dur_str = dur_rational(idur)
        off_str = dur_rational(offset_seconds)

        if itype == "gap":
            gap_name = iname or "Gap"
            spine_xml += f'            <gap name="{gap_name}" offset="{off_str}" duration="{dur_str}" start="3600s"/>\n'
        elif itype == "title":
            text = item.get("text", "Title")
            title_name = iname or text
            font_size = "63" if item.get("position") != "lower-third" else "42"
            ts_id = f"ts{ts_counter}"
            ts_counter += 1
            spine_xml += f'''            <title name="{title_name}" offset="{off_str}" duration="{dur_str}" start="3600s">
                <text><text-style ref="{ts_id}">{text}</text-style></text>
                <text-style-def id="{ts_id}"><text-style font="Helvetica" fontSize="{font_size}" fontColor="1 1 1 1"/></text-style-def>
            </title>\n'''
        elif itype == "transition":
            spine_xml += f'            <transition name="Cross Dissolve" offset="{off_str}" duration="{dur_str}"/>\n'

        offset_seconds += idur
        total_seconds += idur

    total_dur_str = dur_rational(total_seconds)

    markers_xml = ""
    for m in markers:
        mt = m.get("time", 0)
        mname = m.get("name", "Marker")
        mkind = m.get("kind", "standard")
        moff = dur_rational(mt)
        mdur = dur_rational(m.get("duration", 0) if m.get("duration") else fd_num / fd_den)
        if mkind == "chapter":
            markers_xml += f'            <chapter-marker start="{moff}" duration="{mdur}" value="{mname}" posterOffset="0s"/>\n'
        elif mkind == "todo":
            markers_xml += f'            <marker start="{moff}" duration="{mdur}" value="{mname}" completed="0"/>\n'
        else:
            markers_xml += f'            <marker start="{moff}" duration="{mdur}" value="{mname}"/>\n'

    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.14">
    <resources>
        <format id="r1" name="FFVideoFormat{width}x{height}p{frame_rate}" frameDuration="{fd_str}" width="{width}" height="{height}"/>
    </resources>
    <library>
        <event name="{event_name}">
            <project name="{project_name}">
                <sequence format="r1" duration="{total_dur_str}" tcStart="0s" tcFormat="NDF">
                    <spine>
{spine_xml}                    </spine>
{markers_xml}                </sequence>
            </project>
        </event>
    </library>
</fcpxml>'''
