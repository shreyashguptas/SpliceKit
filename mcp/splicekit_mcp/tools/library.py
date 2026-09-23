"""Tools: active libraries and library update state."""

from urllib.parse import unquote, urlparse

from ..registry import READ, splicekit_tool
from ..bridge import _call_or_error, _err, bridge


# ============================================================
# Library & Project Management
# ============================================================
# Thin wrappers around FCP's FFLibraryDocument class methods.

@splicekit_tool("get_active_libraries", READ)
def get_active_libraries() -> str:
    """Get list of currently open libraries in FCP."""

    def _objc(target, selector, args=None, return_handle=False):
        return bridge.call(
            "system.callMethodWithArgs",
            target=target,
            selector=selector,
            args=args or [],
            classMethod=False,
            returnHandle=return_handle,
        )

    r = bridge.call("system.callMethodWithArgs", target="FFLibraryDocument",
                    selector="copyActiveLibraries", args=[], classMethod=True, returnHandle=True)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    array_handle = r.get("handle")
    if not array_handle:
        return "No libraries are open."

    lib_handles = []
    count = None
    try:
        cr = _objc(array_handle, "count")
        if not _err(cr) and cr.get("result") is not None:
            count = int(cr["result"])
    except (TypeError, ValueError):
        count = None

    if count is not None:
        if count == 0:
            return "No libraries are open."
        for i in range(count):
            lr = _objc(
                array_handle,
                "objectAtIndex:",
                [{"type": "int", "value": i}],
                return_handle=True,
            )
            lib_handles.append(lr.get("handle") if not _err(lr) else None)
    else:
        i = 0
        while i < 256:
            lr = _objc(
                array_handle,
                "objectAtIndex:",
                [{"type": "int", "value": i}],
                return_handle=True,
            )
            if _err(lr) or not lr.get("handle"):
                break
            lib_handles.append(lr["handle"])
            i += 1
        count = len(lib_handles)

    if count == 0:
        return "No libraries are open."

    lines = [f"Open libraries ({count}):"]
    for lib_handle in lib_handles:
        name = None
        path = None
        unread = []
        if not lib_handle:
            lines.append("  (could not read library entry)")
            continue
        try:
            nr = _objc(lib_handle, "displayName")
            if _err(nr):
                unread.append("name")
            else:
                name = nr.get("result")
        except Exception:
            unread.append("name")
        try:
            ur = _objc(lib_handle, "URL")
            if _err(ur):
                unread.append("path")
            else:
                url_str = ur.get("result") or ""
                if url_str:
                    parsed = urlparse(str(url_str))
                    path = unquote(parsed.path).rstrip("/")
        except Exception:
            unread.append("path")
        if name and path:
            line = f"  {name} — {path}"
        elif name:
            line = f"  {name}"
        elif path:
            line = f"  (unnamed) — {path}"
        else:
            line = "  (library)"
        if unread:
            line += f" (could not read: {', '.join(unread)})"
        try:
            ir = _objc(lib_handle, "isUpdating")
            if not _err(ir) and ir.get("result"):
                line += " [updating]"
        except Exception:
            pass
        try:
            idr = _objc(lib_handle, "uniqueIdentifier")
            if not _err(idr) and idr.get("result"):
                line += f"  id={idr['result']}"
        except Exception:
            pass
        lines.append(line)
    return "\n".join(lines)


@splicekit_tool("is_library_updating", READ, title="Check Library Updating")
def is_library_updating() -> str:
    """Check if any library is currently being updated/saved."""
    return _call_or_error("system.callMethod", className="FFLibraryDocument",
                          selector="isAnyLibraryUpdating", classMethod=True)
