"""Tools: timeline and inspector captures."""

from ..images import _image_content, _maybe_with_image
from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge
from .clip_info import _capture_flat_note


# ============================================================
# Capture Timeline Screenshot
# ============================================================

@splicekit_tool("capture_timeline")
def capture_timeline(path: str = "/tmp/splicekit_timeline.png", return_image: bool = True):
    """Capture the FCP timeline as a PNG screenshot.

    Screenshots the timeline area only (cropped from the FCP window, not the
    whole screen). Captures the window's content directly (CGWindowListCreateImage),
    so FCP need not be frontmost. A one-colour capture is reported with `flat: true`
    and a WARNING line.

    Use after: blade cuts, clip rearrangement, adding/removing markers,
    transitions, trim edits, or any structural timeline change. Read the
    resulting PNG to visually verify clip layout, edit points, gaps,
    markers, transitions, and overall timeline structure.

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_timeline.png
        return_image: also return the PNG inline as MCP image content (default True),
              so any MCP client can look at it without reading the file.

    Returns the file path, image dimensions, and file size, plus the image itself
    when return_image is True. The saved PNG can also be read from disk.
    """
    r = bridge.call("timeline.capture", path=path)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        text = (f"Timeline captured: {r.get('path')}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)" + _capture_flat_note(r))
        return _maybe_with_image(text, _image_content(path=r.get("path")) if return_image else None)
    return _fmt(r)


# ============================================================
# Capture Inspector Screenshot
# ============================================================

@splicekit_tool("capture_inspector")
def capture_inspector(path: str = "/tmp/splicekit_inspector.png", class_name: str = "",
                      return_image: bool = True):
    """Capture the FCP Inspector pane as a PNG screenshot.

    Crops the Inspector area from the FCP window. Searches the view hierarchy
    for one of FCP's known inspector root view classes (FFInspectorRootStackView,
    FFInspectorRootOutlineView, FFInspectorOutlineView, etc.) and captures the
    largest matching view.

    Use after applying or modifying an effect on the selected clip to visually
    verify what parameters appear, their values, and custom UI views (e.g.
    FxPlug 4 custom parameter views).

    Args:
        path: Output file path for the PNG image.
              Default: /tmp/splicekit_inspector.png
        class_name: Optional override — search for a specific NSView subclass
              instead of the default candidate list.
        return_image: also return the PNG inline as MCP image content (default True),
              so any MCP client can look at it without reading the file.

    Returns the file path, image dimensions, file size, and the matched class, plus
    the image itself when return_image is True. The saved PNG can also be read from disk.
    """
    kwargs = {"path": path}
    if class_name:
        kwargs["class_name"] = class_name
    r = bridge.call("inspector.capture", **kwargs)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    if r.get("status") == "ok":
        matched = r.get("matchedClass", "(full window fallback)")
        text = (f"Inspector captured: {r.get('path')}\n"
                f"Matched class: {matched}\n"
                f"Size: {r.get('width')}x{r.get('height')} ({r.get('bytes', 0)} bytes)" + _capture_flat_note(r))
        return _maybe_with_image(text, _image_content(path=r.get("path")) if return_image else None)
    return _fmt(r)
