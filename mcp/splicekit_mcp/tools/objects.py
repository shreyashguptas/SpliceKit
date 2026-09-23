"""Tools: ObjC method calls with arguments and object handles."""

import json

from ..registry import DESTRUCTIVE, LOCAL, READ, splicekit_tool
from ..bridge import _call_or_error, _err, _fmt, bridge


def _handle_management_response(action: str, handle: str = "") -> str:
    if action == "list":
        r = bridge.call("object.list")
    elif action == "inspect" and handle:
        r = bridge.call("object.get", handle=handle)
    elif action == "release" and handle:
        r = bridge.call("object.release", handle=handle)
    elif action == "release_all":
        r = bridge.call("object.release", all=True)
    else:
        return (
            "Unknown handle action. Use list_handles(), inspect_handle(handle), "
            "release_handle(handle), or release_all_handles()."
        )

    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


# ============================================================
# Advanced Method Calling (with arguments)
# ============================================================
# The swiss army knife — call any ObjC method on any object.
# Use this when a specific tool doesn't exist for what you need.

@splicekit_tool("call_method_with_args", DESTRUCTIVE)
def call_method_with_args(target: str, selector: str, args: str | list = "[]",
                          class_method: bool = True, return_handle: bool = False) -> str:
    """Call any ObjC method with typed arguments via NSInvocation.

    Args:
        target: ObjC class name (e.g. "FFLibraryDocument") or retained handle (e.g. "obj_3").
        selector: Method selector (e.g. "copyActiveLibraries" or "objectAtIndex:").
        args: JSON array of typed arguments as a string or Python list. Each element is
            ``{"type": "...", "value": ...}``. Types: string, int, double, float, bool,
            nil, sender, handle, cmtime, selector. cmtime value example:
            ``{"value": 30000, "timescale": 600}``.
        class_method: When True (default), call ``+[target selector]``; when False, call on the
            handle instance ``-[target selector]``.
        return_handle: When True, retain the returned object and include its handle in the response.

    Warnings:
      - Selectors with out-parameters (error:, askedRetry:, etc.) are invoked with the raw pointer
        bytes you pass in args. Passing [{"type":"nil"}] only works when the selector explicitly
        tolerates a null out pointer.
      - FFAnchoredSequence actionTrimDuration:forEdits:isDelta:error: is known to crash Final Cut
        on a constrained trim if error: is null.
      - If you need an NSArray argument, build it first via NSArray arrayWithObject: and pass the
        returned handle into the real call.

    Examples:
      call_method_with_args("FFLibraryDocument", "copyActiveLibraries", return_handle=True)
      call_method_with_args("obj_3", "displayName", "[]", false)
      call_method_with_args("obj_1", "objectAtIndex:", [{"type":"int","value":0}], false, true)
    """
    # Accept args as either a JSON string or a direct list
    if isinstance(args, list):
        parsed_args = args
    else:
        try:
            parsed_args = json.loads(args)
        except json.JSONDecodeError as e:
            return f"Invalid args JSON: {e}"

    # Safety rail: these selectors crash FCP when the error: out-pointer is nil
    unsafe_nil_error_selectors = {
        "actionTrimDuration:forEdits:isDelta:error:",
        "operationTrimDuration:forEdits:isDelta:error:",
    }
    if selector in unsafe_nil_error_selectors and parsed_args:
        last_arg = parsed_args[-1] if isinstance(parsed_args[-1], dict) else {}
        last_arg_type = last_arg.get("type", "nil")
        if last_arg_type == "nil":
            return (
                f"Refusing {selector} with a nil error: pointer. "
                "This selector is known to crash Final Cut when the trim is constrained. "
                "Use a dedicated safe wrapper instead."
            )

    return _call_or_error("system.callMethodWithArgs", target=target, selector=selector,
                          args=parsed_args, classMethod=class_method, returnHandle=return_handle)


# ============================================================
# Object Handles
# ============================================================
# The handle system lets you hold references to live ObjC objects
# across multiple tool calls. Think of handles as pointers that
# survive between requests. Always release_all when you're done.

@splicekit_tool("list_handles", READ, title="List Object Handles")
def list_handles() -> str:
    """Use this tool to inspect the currently retained bridge object handles."""
    return _handle_management_response("list")


@splicekit_tool("inspect_handle", READ, title="Inspect Object Handle")
def inspect_handle(handle: str) -> str:
    """Inspect one retained bridge object handle: its class, description and key properties.

    A handle ("obj_3") is a reference SpliceKit keeps to one Objective-C object,
    handed out by an earlier read — get_timeline_clips(), browser_list_clips(),
    get_selected_clips(), list_markers(), mixer_get_state(), import_media(), or any call
    made with return_handle=True. It is not a Final Cut Pro media handle. Handles are
    dropped when a project is reopened, so a stale one answers "no longer resolves" and
    the fix is to make the read again, not to guess a number.

    Args:
        handle: The handle to inspect, e.g. "obj_3".
    """
    return _handle_management_response("inspect", handle)


@splicekit_tool("release_handle", LOCAL, title="Release Object Handle")
def release_handle(handle: str) -> str:
    """Release one retained bridge object handle when it is no longer needed.

    This frees SpliceKit's reference to the object. It does not delete anything in Final
    Cut Pro — the clip, marker or project the handle pointed at is untouched. Any other
    handle you still hold stays valid.

    Args:
        handle: The handle to release, e.g. "obj_3".
    """
    return _handle_management_response("release", handle)


@splicekit_tool("release_all_handles", LOCAL)
def release_all_handles() -> str:
    """Release every retained bridge object handle.

    Frees all of SpliceKit's references at once. Nothing in Final Cut Pro is deleted, but
    every handle you are holding stops resolving, so re-read anything you still need.
    """
    return _handle_management_response("release_all")


@splicekit_tool("get_object_property", READ)
def get_object_property(handle: str, key: str, return_handle: bool = False) -> str:
    """Use this tool to inspect one property on a retained Objective-C object handle.

    A handle ("obj_3") is a reference SpliceKit keeps to one Objective-C object,
    handed out by an earlier read — get_timeline_clips(), browser_list_clips(),
    get_selected_clips(), list_markers(), mixer_get_state(), import_media(), or any call
    made with return_handle=True. It is not a Final Cut Pro media handle. Handles are
    dropped when a project is reopened, so a stale one answers "no longer resolves" and
    the fix is to make the read again, not to guess a number.

    Args:
        handle: Retained bridge handle (e.g. "obj_3").
        key: KVC key or property name (e.g. "displayName", "duration", "containedItems").
            Spelled exactly as the runtime has it; get_properties(class_name) lists them.
        return_handle: When True, retain the property value and return a new handle for it,
            instead of describing it. Use this to walk from one object to another.

    Example: get_object_property("obj_3", "displayName")
    """
    return _call_or_error("object.getProperty", handle=handle, key=key, returnHandle=return_handle)


@splicekit_tool("set_object_property", DESTRUCTIVE)
def set_object_property(handle: str, key: str, value: str, value_type: str = "string") -> str:
    """Set a property on an object handle using Key-Value Coding.

    WARNING: Direct KVC bypasses undo. For undoable edits, use timeline_action() instead.
    Nothing written here can be taken back with history_action("undo"), and writing a key
    Final Cut Pro did not expect can leave the document in a state it cannot save.

    A handle ("obj_3") is a reference SpliceKit keeps to one Objective-C object,
    handed out by an earlier read — get_timeline_clips(), browser_list_clips(),
    get_selected_clips(), list_markers(), mixer_get_state(), import_media(), or any call
    made with return_handle=True. It is not a Final Cut Pro media handle. Handles are
    dropped when a project is reopened, so a stale one answers "no longer resolves" and
    the fix is to make the read again, not to guess a number.

    Args:
        handle: Retained bridge handle whose property will be written.
        key: KVC key or property name, spelled exactly as the runtime has it.
        value: Value as a string; converted using value_type before sending to the bridge.
        value_type: One of string, int, double, bool, nil (default string).
    """
    # Convert the string value to the correct Python type before sending to the bridge
    val_spec = {"type": value_type, "value": value}
    if value_type == "int":
        val_spec["value"] = int(value)
    elif value_type == "double":
        val_spec["value"] = float(value)
    elif value_type == "bool":
        val_spec["value"] = value.lower() in ("true", "1", "yes")
    return _call_or_error("object.setProperty", handle=handle, key=key, value=val_spec)
