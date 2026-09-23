"""Tools: ObjC runtime introspection and raw calls."""

import json

from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge


# ============================================================
# Runtime Introspection
# ============================================================
# Reverse-engineering tools — enumerate classes, explore methods,
# inspect the class hierarchy. Use these to discover new APIs.

@splicekit_tool("get_classes")
def get_classes(filter: str = "") -> str:
    """List ObjC classes loaded in FCP's process.

    Args:
        filter: Case-insensitive substring to match against the class names. Left out, it
            lists everything, which is tens of thousands of classes — pass a prefix.
            Common prefixes: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getClasses", filter=filter) if filter else bridge.call("system.getClasses")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    classes = r.get("classes", [])
    count = r.get("count", len(classes))
    if count > 200:
        return f"Found {count} classes matching '{filter}'. Showing first 200:\n" + "\n".join(classes[:200])
    return f"Found {count} classes:\n" + "\n".join(classes)


@splicekit_tool("get_methods")
def get_methods(class_name: str, include_super: bool = False) -> str:
    """List all methods on an ObjC class with type encodings.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
        include_super: Also list methods inherited from superclasses. Default False.
    """
    r = bridge.call("system.getMethods", className=class_name, includeSuper=include_super)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"=== {class_name} ==="]
    lines.append(f"\nInstance methods ({r.get('instanceMethodCount', 0)}):")
    for name in sorted(r.get("instanceMethods", {}).keys()):
        info = r["instanceMethods"][name]
        lines.append(f"  - {name}  ({info.get('typeEncoding', '')})")
    lines.append(f"\nClass methods ({r.get('classMethodCount', 0)}):")
    for name in sorted(r.get("classMethods", {}).keys()):
        info = r["classMethods"][name]
        lines.append(f"  + {name}  ({info.get('typeEncoding', '')})")
    return "\n".join(lines)


@splicekit_tool("get_properties")
def get_properties(class_name: str) -> str:
    """List declared @property definitions on an ObjC class.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getProperties", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"{class_name}: {r.get('count', 0)} properties"]
    for p in r.get("properties", []):
        lines.append(f"  {p['name']}: {p['attributes']}")
    return "\n".join(lines)


@splicekit_tool("get_ivars")
def get_ivars(class_name: str) -> str:
    """List instance variables of an ObjC class with their types.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getIvars", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = [f"{class_name}: {r.get('count', 0)} ivars"]
    for iv in r.get("ivars", []):
        lines.append(f"  {iv['name']}: {iv['type']}")
    return "\n".join(lines)


@splicekit_tool("get_protocols")
def get_protocols(class_name: str) -> str:
    """List protocols adopted by an ObjC class.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getProtocols", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return f"{class_name}: {r.get('count', 0)} protocols\n" + "\n".join(f"  {p}" for p in r.get("protocols", []))


@splicekit_tool("get_superchain")
def get_superchain(class_name: str) -> str:
    """Get the inheritance chain for an ObjC class, from it up to NSObject.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    r = bridge.call("system.getSuperchain", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return " -> ".join(r.get("superchain", []))


@splicekit_tool("explore_class")
def explore_class(class_name: str) -> str:
    """Comprehensive overview of an ObjC class: inheritance, protocols, properties, ivars, key methods.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
    """
    lines = [f"=== {class_name} ===\n"]
    r = bridge.call("system.getSuperchain", className=class_name)
    if not _err(r):
        lines.append("Inheritance: " + " -> ".join(r.get("superchain", [])))
    r = bridge.call("system.getProtocols", className=class_name)
    if not _err(r) and r.get("count", 0) > 0:
        lines.append(f"\nProtocols ({r['count']}): " + ", ".join(r.get("protocols", [])))
    r = bridge.call("system.getProperties", className=class_name)
    if not _err(r) and r.get("count", 0) > 0:
        lines.append(f"\nProperties ({r['count']}):")
        for p in r.get("properties", [])[:30]:
            lines.append(f"  {p['name']}")
    r = bridge.call("system.getIvars", className=class_name)
    if not _err(r) and r.get("count", 0) > 0:
        lines.append(f"\nIvars ({r['count']}):")
        for iv in r.get("ivars", [])[:15]:
            lines.append(f"  {iv['name']}: {iv['type']}")
    r = bridge.call("system.getMethods", className=class_name)
    if not _err(r):
        im = r.get("instanceMethodCount", 0)
        cm = r.get("classMethodCount", 0)
        lines.append(f"\nMethods: {im} instance, {cm} class")
        if cm > 0:
            lines.append(f"\nClass methods:")
            for name in sorted(r.get("classMethods", {}).keys()):
                lines.append(f"  + {name}")
        # Surface the most interesting methods -- the ones an AI is likely to want to call
        keywords = ['get', 'set', 'current', 'active', 'selected', 'add', 'remove',
                    'create', 'delete', 'open', 'close', 'name', 'items', 'clip', 'effect', 'marker']
        notable = [m for m in sorted(r.get("instanceMethods", {}).keys()) if any(k in m.lower() for k in keywords)]
        if notable:
            lines.append(f"\nNotable instance methods ({len(notable)} of {im}):")
            for m in notable[:50]:
                lines.append(f"  - {m}")
    return "\n".join(lines)


@splicekit_tool("search_methods")
def search_methods(class_name: str, keyword: str) -> str:
    """Search for methods on a class by keyword.

    This, and get_methods(), are the only acceptable evidence that a selector exists on
    this build of Final Cut Pro. Do not assume one from a header, a disassembly or
    another version.

    Args:
        class_name: The Objective-C class name, spelled exactly as the runtime has it and
            case-sensitively — "FFAnchoredSequence", not "ffanchoredsequence". Find one
            with get_classes(filter=...) or explore_class(). Common prefixes inside Final
            Cut Pro: FF (Flexo), OZ (Ozone), PE (ProEditor), LK (LunaKit),
            TK (TimelineKit), IX (Interchange).
        keyword: Case-insensitive substring to match against the method names.
    """
    r = bridge.call("system.getMethods", className=class_name)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    lines = []
    for name in sorted(r.get("instanceMethods", {}).keys()):
        if keyword.lower() in name.lower():
            lines.append(f"  - {name}  ({r['instanceMethods'][name].get('typeEncoding', '')})")
    for name in sorted(r.get("classMethods", {}).keys()):
        if keyword.lower() in name.lower():
            lines.append(f"  + {name}  ({r['classMethods'][name].get('typeEncoding', '')})")
    if not lines:
        return f"No methods matching '{keyword}' on {class_name}"
    return f"Methods matching '{keyword}' on {class_name} ({len(lines)}):\n" + "\n".join(lines)


# -- Low-level escape hatches for arbitrary ObjC calls --

@splicekit_tool("call_method")
def call_method(class_name: str, selector: str, class_method: bool = True) -> str:
    """Call a zero-argument ObjC method. For methods WITH arguments, use call_method_with_args instead.

    Args:
        class_name: ObjC class name (e.g. "FFLibraryDocument").
        selector: Zero-argument selector (e.g. "copyActiveLibraries").
        class_method: When True (default), invoke the class method ``+[class_name selector]``;
            when False, not supported here — use call_method_with_args with a handle target.
    """
    r = bridge.call("system.callMethod", className=class_name, selector=selector, classMethod=class_method)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("raw_call")
def raw_call(method: str, params: str = "{}") -> str:
    """Send a raw JSON-RPC call to SpliceKit. Last resort when no other tool fits.

    Args:
        method: Bridge RPC method name (e.g. "timeline.getState").
        params: JSON object string of keyword arguments for that method (default "{}").
    """
    try:
        p = json.loads(params)
    except json.JSONDecodeError as e:
        return f"Invalid JSON params: {e}"
    r = bridge.call(method, **p)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)
