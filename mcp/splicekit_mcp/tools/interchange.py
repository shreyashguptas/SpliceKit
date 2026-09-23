"""Tools: FCPXML export and OpenTimelineIO import / export."""

import tempfile
import os

from ..registry import DESTRUCTIVE, splicekit_tool
from ..bridge import _call_or_error, _err, _fmt, bridge
from ..otio_fcpxml import (
    _otio_all_timelines, _otio_detect_rate, _otio_fcpxml_clean_for_paste, _otio_first_timeline,
    _otio_normalize_rate, _otio_prepare_for_fcp, _otio_read_fcpx_document,
    _otio_read_fcpx_string, _otio_timeline_summary, _otio_write_fcpx_string,
)


# ============================================================
# Export FCPXML (Programmatic, No Dialog)
# ============================================================
# Export the current project to FCPXML without the save dialog.

# DESTRUCTIVE: writes to a caller-supplied path and overwrites whatever is there, with no
# existence check and no dry run — the same disk-write risk export_captions_srt/txt carry.
@splicekit_tool("export_xml", DESTRUCTIVE, title="Export FCPXML")
def export_xml(path: str = "/tmp/splicekit_export.fcpxml") -> str:
    """Export the current project/sequence as FCPXML to a file — no save dialog.

    Programmatically serializes the active timeline's sequence to FCPXML format
    and writes it to the specified path. Unlike timeline_action("exportXML")
    which opens FCP's save dialog, this writes directly.

    timeline_action("exportXML") and some share/export flows can still open modal
    save/open panels; while one is open the bridge cannot serve main-thread RPC.
    Save/open panels cannot be confirmed from the bridge — only
    dismiss_dialog(action=\"cancel\") closes them.

    Args:
        path: Output file path for the FCPXML.
              Default: /tmp/splicekit_export.fcpxml

    The exported FCPXML contains the full project structure including clips,
    effects, titles, markers, and timing. Useful for:
    - Inspecting the project structure (e.g. finding Custom Speed keyframes)
    - Backing up before destructive edits
    - Transferring projects between systems
    """
    return _call_or_error("fcpxml.export", path=path)


# ============================================================
# OpenTimelineIO Import & Export
# ============================================================
# Universal timeline interchange via OpenTimelineIO. Handles all
# OTIO-supported formats (.otio, .otioz, .otiod) AND .fcpxml via
# the otio-fcpx-xml-adapter. Replaces import_fcpxml / export_xml
# as the primary format tools.


# DESTRUCTIVE: writes to a caller-supplied path and overwrites whatever is there, with no
# existence check and no dry run — the same disk-write risk export_captions_srt/txt carry.
@splicekit_tool("export_otio", DESTRUCTIVE, title="Export OpenTimelineIO")
def export_otio(path: str = "/tmp/splicekit_export.otio", rate: float = 0) -> str:
    """Export the current project/sequence via OpenTimelineIO.

    Universal export that handles all OTIO-supported formats including FCPXML.
    Enables timeline interchange with DaVinci Resolve, Premiere Pro, Avid Media
    Composer, and any NLE that supports OTIO or FCPXML.

    Supported output formats (determined by file extension):
      .otio   — OpenTimelineIO native JSON (default, most compatible for NLE exchange)
      .otioz  — OpenTimelineIO bundled with media references (zipped)
      .otiod  — OpenTimelineIO directory bundle
      .fcpxml — Final Cut Pro XML (uses FCP's native exporter for full fidelity,
                then round-trips through OTIO for normalization)
      .fcpxmld — Final Cut Pro XML package (writes native export to `Info.fcpxml`)
      .edl    — CMX 3600 EDL (Premiere, Resolve, Avid compatible)
      .aaf    — Advanced Authoring Format (Avid Media Composer)

    Args:
        path: Output file path. Extension determines format.
              Default: /tmp/splicekit_export.otio
        rate: Frame rate for EDL export (e.g. 23.98, 24, 29.97, 30).
              Required for .edl, ignored for other formats. If 0, auto-detected
              from timeline.

    Returns:
        JSON with status, output path, timeline name, track/clip counts, and duration,
        plus `not_carried_across` listing anything OTIO has no way to represent — a
        compound clip, for instance, is flattened into the clips it contains.

    Some export paths use FCP's native save dialog instead of writing directly.
    While a modal save/open panel is open the bridge cannot serve main-thread RPC.
    Save/open panels cannot be confirmed from the bridge — only
    dismiss_dialog(action=\"cancel\") closes them.
    """
    try:
        import opentimelineio as otio
    except ImportError:
        return "Error: opentimelineio not installed. Run: pip install opentimelineio otio-fcpxml-adapter (or legacy otio-fcpx-xml-adapter)"


    # For .fcpxml/.fcpxmld output, use FCP's native exporter directly for maximum fidelity.
    if path.lower().endswith((".fcpxml", ".fcpxmld")):
        export_path = path
        if path.lower().endswith(".fcpxmld"):
            os.makedirs(path, exist_ok=True)
            export_path = os.path.join(path, "Info.fcpxml")

        r = bridge.call("fcpxml.export", path=export_path)
        if _err(r):
            return f"Error exporting FCPXML: {r.get('error', r)}"
        # Also parse through OTIO for summary info
        try:
            with open(export_path, "r") as f:
                fcpxml_str = f.read()
            result = _otio_read_fcpx_string(fcpxml_str)
            timeline = _otio_first_timeline(result)
            summary = _otio_timeline_summary(timeline)
        except Exception:
            summary = {}
        summary.update({
            "status": "ok",
            "path": path,
            "bytes": os.path.getsize(export_path),
            "format": "fcpxmld" if path.lower().endswith(".fcpxmld") else "fcpxml",
        })
        return _fmt(summary)

    # For OTIO formats: export FCPXML from FCP, convert via adapter, write target format
    fcpxml_path = os.path.join(tempfile.gettempdir(), "splicekit_otio_export.fcpxml")
    r = bridge.call("fcpxml.export", path=fcpxml_path)
    if _err(r):
        return f"Error exporting FCPXML: {r.get('error', r)}"

    try:
        with open(fcpxml_path, "r") as f:
            fcpxml_str = f.read()
        result = _otio_read_fcpx_string(fcpxml_str)
    except Exception as e:
        return f"Error reading FCPXML into OTIO: {e}"

    timeline = _otio_first_timeline(result)

    # Format-specific write options
    ext = path.rsplit(".", 1)[-1].lower()
    try:
        if ext == "edl":
            # EDL needs a rate; auto-detect from timeline or use provided rate
            edl_rate = _otio_normalize_rate(rate) if rate > 0 else _otio_detect_rate(timeline)
            otio.adapters.write_to_file(timeline, path, rate=edl_rate)
        else:
            otio.adapters.write_to_file(timeline, path)
    except Exception as e:
        hint = ""
        if ext == "aaf" and "mob" in str(e).lower():
            hint = " (AAF requires Avid-specific metadata on clips — try .edl or .otio instead)"
        elif ext == "otioz" and ("NotAFileOnDisk" in type(e).__name__ or "not" in str(e).lower()):
            hint = " (.otioz bundles media files — referenced files must exist on disk)"
        return f"Error writing {ext.upper()} file: {e}{hint}"

    summary = _otio_timeline_summary(timeline)
    summary.update({"status": "ok", "path": path, "bytes": os.path.getsize(path), "format": ext})

    try:
        os.unlink(fcpxml_path)
    except OSError:
        pass

    return _fmt(summary)


@splicekit_tool("import_otio", DESTRUCTIVE, title="Import OpenTimelineIO")
def import_otio(path: str = "", otio_json: str = "", rate: float = 0, event: str = "") -> str:
    """Import a timeline file into FCP via OpenTimelineIO.

    Universal import that handles all OTIO-supported formats including FCPXML.
    Enables importing timelines from DaVinci Resolve, Premiere Pro, Avid Media
    Composer, and any NLE that exports OTIO or FCPXML.

    Supported input formats (determined by file extension):
      .otio   — OpenTimelineIO native JSON (DaVinci Resolve, universal)
      .otioz  — OpenTimelineIO bundle (zipped)
      .otiod  — OpenTimelineIO directory bundle
      .fcpxml — Final Cut Pro XML (sent directly to FCP's native importer
                for full fidelity — effects, transitions, titles all preserved)
      .fcpxmld — Final Cut Pro XML package (loads `Info.fcpxml` for native import)
      .edl    — CMX 3600 EDL (Premiere, Resolve, Avid)
      .aaf    — Advanced Authoring Format (Avid Media Composer)

    Args:
        path:      Path to the file to import. Extension determines format.
        otio_json: Alternatively, pass raw OTIO JSON string directly (uses .otio adapter).
                   If both path and otio_json are provided, path takes priority.
        rate:      Frame rate for EDL import (e.g. 23.98, 24, 29.97, 30).
                   Required for .edl files with drop-frame timecodes. If 0, defaults to 24.
        event:     Event to import into, by name. Empty uses the library's first event,
                   which is where import_media puts things too.

    Where it lands:
        A NEW project, in an existing event. The project you have open is not touched.
        Verified on FCP 12.3 against a four-clip timeline with a connected clip: offsets,
        durations, source in-points and the connected clip's lane all came back matching.

    What OTIO cannot carry:
        A compound clip. export_otio flattens one into the clips it contains and says so
        in `not_carried_across`; what comes back is those clips, not a compound clip.

    Returns:
        JSON with import status, timeline name, track/clip counts.
    """
    try:
        import opentimelineio as otio
    except ImportError:
        return "Error: opentimelineio not installed. Run: pip install opentimelineio otio-fcpxml-adapter (or legacy otio-fcpx-xml-adapter)"

    # For .fcpxml/.fcpxmld input, send directly to FCP's native importer for full fidelity.
    if path and path.lower().endswith((".fcpxml", ".fcpxmld")):
        try:
            fcpxml_str = _otio_read_fcpx_document(path)
        except Exception as e:
            return f"Error reading file: {e}"

        r = bridge.call("fcpxml.import", xml=fcpxml_str, internal=True)

        # Also parse through OTIO for summary info
        summary = {"format": path.rsplit(".", 1)[-1].lower()}
        try:
            result = _otio_read_fcpx_string(fcpxml_str)
            timelines = _otio_all_timelines(result)
            summary["timelines_total"] = len(timelines)
            summary["details"] = [_otio_timeline_summary(tl) for tl in timelines]
        except Exception:
            pass

        if _err(r):
            summary["status"] = "error"
            summary["error"] = r.get("error", str(r))
        else:
            summary["status"] = "ok"
        return _fmt(summary)

    # For .otio files: prefer the native ObjC converter (correct transitions,
    # titles, connected clips, exact frame-rate math) over the Python adapter.
    ext = path.rsplit(".", 1)[-1].lower() if path else ""
    if ext == "otio" or (not path and otio_json):
        native_ok = False
        try:
            if path and ext == "otio":
                r = bridge.call("otio.toFCPXML", path=path, event=event)
            elif otio_json:
                r = bridge.call("otio.toFCPXML", path="/dev/null", otio_json=otio_json,
                                event=event)
            else:
                r = {"error": "no input"}

            if not _err(r) and r.get("fcpxml"):
                fcpxml_str = r["fcpxml"]
                fcpxml_str = _otio_fcpxml_clean_for_paste(fcpxml_str)
                ir = bridge.call("fcpxml.import", xml=fcpxml_str, internal=True)
                # Parse through OTIO for summary
                summary = {"format": ext or "otio_json", "converter": "native"}
                try:
                    parsed = _otio_read_fcpx_string(fcpxml_str)
                    timelines = _otio_all_timelines(parsed)
                    summary["timelines_total"] = len(timelines)
                    summary["details"] = [_otio_timeline_summary(tl) for tl in timelines]
                except Exception:
                    pass
                if _err(ir):
                    summary["status"] = "error"
                    summary["error"] = ir.get("error", str(ir))
                else:
                    summary["status"] = "ok"
                return _fmt(summary)
        except Exception:
            pass  # Fall through to Python adapter path

    # Fallback: read via Python OTIO adapter, convert to FCPXML, import into FCP
    try:
        if path:
            if ext == "edl":
                edl_rate = _otio_normalize_rate(rate) if rate > 0 else 24
                result = otio.adapters.read_from_file(path, rate=edl_rate)
            else:
                result = otio.adapters.read_from_file(path)
        elif otio_json:
            result = otio.adapters.read_from_string(otio_json, "otio_json")
        else:
            return "Error: provide either 'path' (file path) or 'otio_json' (raw OTIO JSON string)"
    except Exception as e:
        hint = ""
        if path and path.lower().endswith(".edl") and "drop frame" in str(e).lower():
            hint = " (try setting rate=29.97 for drop-frame EDLs)"
        return f"Error reading file: {e}{hint}"

    timelines = _otio_all_timelines(result)
    if not timelines:
        return "Error: no timelines found in OTIO file"

    imported = []
    for tl in timelines:
        _otio_prepare_for_fcp(tl)
        try:
            fcpxml_str = _otio_write_fcpx_string(tl)
            fcpxml_str = _otio_fcpxml_clean_for_paste(fcpxml_str)
        except Exception as e:
            err_msg = f"FCPXML conversion failed: {e}"
            if "kind" in str(e):
                err_msg += " (nested compound clips may not convert — try flattening first)"
            elif "start_time" in str(e) or "NoneType" in str(e):
                err_msg += " (clip has missing source range — may need media references)"
            imported.append({"name": getattr(tl, "name", "unknown"), "error": err_msg})
            continue

        r = bridge.call("fcpxml.import", xml=fcpxml_str, internal=True)
        entry = _otio_timeline_summary(tl)
        entry["converter"] = "python_adapter"
        if _err(r):
            entry["error"] = r.get("error", str(r))
        else:
            entry["status"] = "ok"
        imported.append(entry)

    summary = {
        "status": "ok" if any(i.get("status") == "ok" for i in imported) else "error",
        "format": path.rsplit(".", 1)[-1] if path else "otio_json",
        "timelines_imported": len([i for i in imported if i.get("status") == "ok"]),
        "timelines_total": len(imported),
        "details": imported,
    }
    return _fmt(summary)
