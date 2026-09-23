"""Tools: debug flags, runtime metadata, breakpoints, tracing, eval."""

from ..registry import DESTRUCTIVE, LOCAL, READ, splicekit_tool
from ..bridge import _call_or_error


# ============================================================
# Debug & Diagnostics
# ============================================================
# Exposes FCP's hidden internal debug flags (TLK visual overlays,
# ProAppSupport logging, CFPreferences keys) and SpliceKit's own
# debugging toolkit (breakpoints, tracing, eval, crash handling).

@splicekit_tool("debug_get_config", READ, title="Get Debug Config")
def debug_get_config() -> str:
    """Get current state of all FCP internal debug/logging settings.

    Returns the current values of:
    - Timeline debug flags (TLK*): visual overlays, logging, performance monitors
    - CFPreferences debug flags: video decoder log level, frame drop logging, GPU logging
    - ProAppSupport log settings: log level, categories, in-app panel visibility, thread info
    - FCP behavior flags: gap coalescing, snapping, skimming overrides

    Use this to see what debug options are currently active before changing them.
    """
    return _call_or_error("debug.getConfig")


@splicekit_tool("debug_set_config", DESTRUCTIVE, title="Set Debug Config")
def debug_set_config(key: str, value: str = "true") -> str:
    """Set a single FCP internal debug/logging flag.

    Args:
        key: The debug key to set. Common keys:

            Timeline visual overlays:
              TLKShowItemLaneIndex, TLKShowMisalignedEdges, TLKShowRenderBar,
              TLKShowHiddenGapItems, TLKShowHiddenItemHeaders,
              TLKShowInvalidLayoutRects, TLKShowContainerBounds,
              TLKShowContentLayers, TLKShowRulerBounds, TLKShowUsedRegion,
              TLKShowZeroHeightSpineItems

            Timeline logging:
              TLKLogVisibleLayerChanges, TLKLogParts, TLKLogReloadRequests,
              TLKLogRecyclingLayerChanges, TLKLogVisibleRectChanges,
              TLKLogSegmentationStatistics

            Performance/rendering:
              TLKPerformanceMonitorEnabled, TLKDebugColorChangedObjects,
              TLKDebugLayoutConstraints, TLKDebugErrorsAndWarnings,
              TLKDisableItemContents,
              DebugKeyItemVideoFilmstripsDisabled,
              DebugKeyItemBackgroundDisabled,
              DebugKeyItemAudioWaveformsDisabled

            Video/audio logging (integer values, higher = more verbose):
              VideoDecoderLogLevelInNLE, FrameDropLogLevel

            GPU/effects logging:
              GPU_LOGGING, EnableScheduledReadAudioLogging

            Library debugging:
              EnableLibraryUpdateHistoryValidation

            Transcription:
              FFVAMLSaveTranscription

            ProAppSupport log system:
              LogLevel (trace/debug/info/warning/error/failure),
              LogUI (show/hide the in-app SpliceKit log panel),
              LogThread (include thread info in emitted SpliceKit log lines),
              LogCategory (bitmask)

            FCP behavior overrides:
              FFDontCoalesceGaps, FFDisableSnapping, FFDisableSkimming

        value: Value to set. "true"/"false" for bools, integer string for int keys,
               or level name for LogLevel (trace/debug/info/warning/error/failure).
    """
    # Coerce the string value to the right type -- the bridge expects bool/int/string
    if value.lower() in ("true", "yes", "1"):
        parsed = True
    elif value.lower() in ("false", "no", "0"):
        parsed = False
    else:
        try:
            parsed = int(value)
        except ValueError:
            parsed = value  # pass as string (for LogLevel names like "trace", "debug", etc.)

    return _call_or_error("debug.setConfig", key=key, value=parsed)


@splicekit_tool("debug_reset_config", DESTRUCTIVE, title="Reset Debug Config")
def debug_reset_config(scope: str = "all") -> str:
    """Reset debug/logging settings to defaults.

    Args:
        scope: What to reset:
          "all" - reset everything
          "tlk" - reset timeline debug flags only
          "cfprefs" - reset CFPreferences debug flags only
          "log" - reset ProAppSupport log settings only
    """
    return _call_or_error("debug.resetConfig", scope=scope)


@splicekit_tool("debug_enable_preset", DESTRUCTIVE, title="Enable Debug Preset")
def debug_enable_preset(preset: str) -> str:
    """Enable a preset group of debug settings.

    Args:
        preset: One of:
          "timeline_visual" - Show lane indices, misaligned edges, render bar,
                              hidden gaps, invalid layouts, color-highlight changes
          "timeline_logging" - Log layer changes, parts, reload requests,
                               recycling, visible rect changes, segmentation stats
          "performance" - Enable TLK performance monitor, video decoder logging,
                          frame drop logging
          "render_debug" - Disable filmstrips/backgrounds/waveforms rendering,
                           enable GPU logging (isolates render issues)
          "verbose_logging" - Set ProAppSupport log level to trace, enable log UI,
                              thread info, and audio logging
          "all_off" - Disable all debug flags and reset to defaults
    """
    return _call_or_error("debug.enablePreset", preset=preset)


@splicekit_tool("debug_start_framerate_monitor", LOCAL, title="Start Framerate Monitor")
def debug_start_framerate_monitor(interval: float = 2.0) -> str:
    """Start FCP's built-in HMD framerate monitor.

    Logs FPS and frame timing statistics to the system log at regular intervals.
    View output in Console.app or via: log stream --process "Final Cut Pro"

    Reports: overall fps, average getFrame() time, min/max frame times in ms.

    Args:
        interval: Seconds between measurements (default 2.0).
    """
    return _call_or_error("debug.startFramerateMonitor", interval=interval)


@splicekit_tool("debug_stop_framerate_monitor", LOCAL, title="Stop Framerate Monitor")
def debug_stop_framerate_monitor() -> str:
    """Stop the HMD framerate monitor."""
    return _call_or_error("debug.stopFramerateMonitor")


# -- Runtime metadata export (for reverse engineering / IDA Pro) --

@splicekit_tool("dump_runtime_metadata", READ)
def dump_runtime_metadata(binary: str = "", classes_only: bool = False) -> str:
    """Bulk-export ObjC runtime metadata from a running FCP process for IDA Pro import.

    Returns loaded images (with ASLR slides and base addresses) and full class metadata
    including instance/class methods with IMP addresses, ivars with offsets, properties,
    protocols, and superchains.

    Args:
        binary: Optional filter — match binary/framework name (e.g. "Flexo", "TLKit")
        classes_only: If true, return just class names per image (fast overview)
    """
    params = {}
    if binary:
        params["binary"] = binary
    if classes_only:
        params["classesOnly"] = True
    return _call_or_error("debug.dumpRuntimeMetadata", **params)


@splicekit_tool("list_loaded_images", READ)
def list_loaded_images(filter: str = "") -> str:
    """List all Mach-O images loaded in FCP's process with base addresses and ASLR slides.

    Use this to see which frameworks/dylibs are loaded and their address information
    needed for mapping runtime IMP addresses to static IDA addresses.

    Args:
        filter: Optional filter string to match image name/path
    """
    params = {}
    if filter:
        params["filter"] = filter
    return _call_or_error("debug.listLoadedImages", **params)


@splicekit_tool("get_image_sections", READ)
def get_image_sections(binary: str) -> str:
    """Get ObjC section data for a loaded binary: selector refs, class refs, superclass refs.

    Returns the selectors referenced by this binary (which methods it calls),
    the classes it references, and superclass references. Essential for
    understanding cross-binary dependencies and building call graphs.

    Args:
        binary: Binary/framework name to inspect (e.g. "Flexo", "TLKit")
    """
    return _call_or_error("debug.getImageSections", binary=binary)


@splicekit_tool("get_image_symbols", READ)
def get_image_symbols(binary: str, filter: str = "", demangle: bool = True) -> str:
    """Get exported symbols from a loaded binary's symbol table.

    Returns all exported defined symbols including C functions, ObjC class symbols,
    global variables, and Swift symbols (with automatic demangling).

    Args:
        binary: Binary/framework name to inspect
        filter: Optional filter to match symbol names
        demangle: Whether to demangle Swift symbols (default True)
    """
    params = {"binary": binary}
    if filter:
        params["filter"] = filter
    if not demangle:
        params["demangle"] = False
    return _call_or_error("debug.getImageSymbols", **params)


@splicekit_tool("get_notification_names", READ)
def get_notification_names(binary: str = "") -> str:
    """Enumerate NSNotification name constants from exported symbols.

    Finds all exported symbols containing 'Notification' and resolves their
    actual NSString values. These are the notification names used in
    NSNotificationCenter postNotificationName: calls.

    Args:
        binary: Optional filter to a specific binary/framework
    """
    params = {}
    if binary:
        params["binary"] = binary
    return _call_or_error("debug.getNotificationNames", **params)


# ---------------------------------------------------------------------------
# Debug: Breakpoints
# ---------------------------------------------------------------------------
# True breakpoints that freeze FCP mid-execution. The JSON-RPC server
# stays alive on a background thread so you can inspect state while paused.

@splicekit_tool("debug_breakpoint", LOCAL)
def debug_breakpoint(action: str = "list", class_name: str = "", selector: str = "",
                     condition: str = "", hit_count: int = 0, one_shot: bool = False,
                     key_path: str = "", store_result: bool = False,
                     class_method: bool = False) -> str:
    """Set, manage, and interact with in-process breakpoints on FCP methods.

    True breakpoints that pause FCP execution, let you inspect state, then continue.
    FCP's UI freezes while paused (same as Xcode). The JSON-RPC server stays alive
    on a separate thread so you can inspect and continue.

    Args:
        action: One of:
            - "add": Set a breakpoint on className.selector
            - "remove": Remove a breakpoint
            - "removeAll": Remove all breakpoints (auto-resumes if paused)
            - "list": List all breakpoints and paused state
            - "enable": Re-enable a disabled breakpoint
            - "disable": Disable without removing
            - "continue": Resume paused execution
            - "step": Resume but auto-break on next call to same class
            - "inspect": Get current paused state (self, args, call stack)
            - "inspectSelf": Evaluate a keyPath on the paused self object
        class_name: ObjC class name (e.g. "FFAnchoredTimelineModule")
        selector: ObjC selector (e.g. "blade:")
        condition: Optional keyPath on self that must be truthy for bp to fire
        hit_count: Only fire after this many calls (skip earlier ones)
        one_shot: If true, auto-remove after first hit
        key_path: For inspectSelf — the property path to evaluate
        store_result: For inspectSelf — store the result as a handle
        class_method: If true, breakpoint a class method (+) instead of instance (-)

    When a breakpoint fires, a "breakpoint.hit" event is broadcast with:
    - selfClass, self description, selfHandle
    - firstArg (if present), firstArgHandle
    - callStack (up to 20 frames)
    - threadName, isMainThread

    While paused, use debug_eval(), call_method_with_args(), or inspectSelf
    to examine state before continuing.
    """
    params = {"action": action}
    if class_name:
        params["className"] = class_name
    if selector:
        params["selector"] = selector
    if condition:
        params["condition"] = condition
    if hit_count > 0:
        params["hitCount"] = hit_count
    if one_shot:
        params["oneShot"] = True
    if key_path:
        params["keyPath"] = key_path
    if store_result:
        params["storeResult"] = True
    if class_method:
        params["classMethod"] = True
    return _call_or_error("debug.breakpoint", **params)


# ---------------------------------------------------------------------------
# Debug: Method Tracing
# ---------------------------------------------------------------------------
# Non-blocking alternative to breakpoints. Swizzles methods to log calls
# without pausing. Good for understanding call patterns and frequencies.

@splicekit_tool("debug_trace_method", LOCAL, title="Trace Method")
def debug_trace_method(action: str = "list", class_name: str = "", selector: str = "",
                       log_stack: bool = False, log_args: bool = True,
                       limit: int = 50, class_method: bool = False) -> str:
    """Trace ObjC method calls without pausing execution.

    Swizzles the target method to log every call with timestamp, self, and
    optionally the call stack. Traces are stored in a circular buffer (500 entries)
    and broadcast to MCP clients in real-time.

    Use this when you want to observe call patterns without freezing FCP.
    Use debug_breakpoint() when you need to pause and inspect.

    Args:
        action: One of:
            - "add": Start tracing className.selector
            - "remove": Stop tracing a specific method
            - "removeAll": Stop all traces
            - "list": List active traces
            - "getLog": Read trace log entries
            - "clearLog": Clear the trace log buffer
        class_name: ObjC class name
        selector: ObjC selector
        log_stack: Include call stack in trace entries (slower but more info)
        log_args: Log argument info (default true)
        limit: For getLog — max entries to return
        class_method: Trace a class method (+) instead of instance (-)
    """
    params = {"action": action}
    if class_name:
        params["className"] = class_name
    if selector:
        params["selector"] = selector
    if log_stack:
        params["logStack"] = True
    if not log_args:
        params["logArgs"] = False
    if action == "getLog":
        params["limit"] = limit
    if class_method:
        params["classMethod"] = True
    return _call_or_error("debug.traceMethod", **params)


# ---------------------------------------------------------------------------
# Debug: Property Watching (KVO)
# ---------------------------------------------------------------------------
# Uses ObjC Key-Value Observing to fire events whenever a property changes.
# Replaces hardware watchpoints -- works on any KVO-compliant property.

@splicekit_tool("debug_watch", LOCAL, title="Watch Property Changes")
def debug_watch(action: str = "list", handle: str = "", class_name: str = "",
                key_path: str = "", watch_key: str = "") -> str:
    """Watch ObjC property changes via KVO (Key-Value Observing).

    When a watched property changes, old/new values are broadcast to MCP clients.

    Args:
        action: One of:
            - "add": Start watching a property
            - "remove": Stop watching (requires watch_key)
            - "removeAll": Stop all watches
            - "list": List active watches
        handle: Object handle (e.g. "obj_1") to watch
        class_name: Class name (resolved to singleton if no handle)
        key_path: The property to watch (e.g. "mainWindow", "sequence.displayName")
        watch_key: For remove — the key returned when the watch was created
    """
    params = {"action": action}
    if handle:
        params["handle"] = handle
    if class_name:
        params["className"] = class_name
    if key_path:
        params["keyPath"] = key_path
    if watch_key:
        params["watchKey"] = watch_key
    return _call_or_error("debug.watch", **params)


# ---------------------------------------------------------------------------
# Debug: Crash Handler
# ---------------------------------------------------------------------------
# Catches NSExceptions and Unix signals before the process dies,
# so you get a stack trace instead of a silent crash.

@splicekit_tool("debug_crash_handler", LOCAL, title="Crash Handler")
def debug_crash_handler(action: str = "install") -> str:
    """Install or query the in-process crash handler.

    Catches uncaught NSExceptions and Unix signals (SIGABRT, SIGSEGV, SIGBUS,
    SIGFPE, SIGILL) inside FCP. Captures full stack traces and broadcasts to
    MCP clients before the process terminates.

    Args:
        action: One of:
            - "install": Install exception + signal handlers (idempotent)
            - "status": Check if installed + crash count
            - "getLog": Read captured crash stack traces
            - "clearLog": Clear the crash log
    """
    return _call_or_error("debug.crashHandler", action=action)


# ---------------------------------------------------------------------------
# Debug: Thread Inspection
# ---------------------------------------------------------------------------
# Lists all ~45 threads in FCP's process with CPU usage via Mach APIs.

@splicekit_tool("debug_threads", READ)
def debug_threads(detailed: bool = False) -> str:
    """List all threads in FCP's process with CPU usage and state.

    Uses Mach kernel APIs for accurate thread counts and per-thread metrics.

    Args:
        detailed: If true, include per-thread CPU usage, run state, and
                  call stacks for the current and main threads.

    Returns thread count, operation queue info, and optionally per-thread:
    - cpuUsage (percentage 0-100)
    - userTime / systemTime (seconds)
    - runState (1=running, 2=stopped, 3=waiting)
    - suspended flag
    """
    return _call_or_error("debug.threads", detailed=detailed)


# ---------------------------------------------------------------------------
# Debug: Expression Evaluation
# ---------------------------------------------------------------------------
# Like lldb's `po` command. Walks ObjC property chains at runtime.

@splicekit_tool("debug_eval", READ, title="Evaluate Debug Expression")
def debug_eval(expression: str = "", chain: str = "", target: str = "",
               store_result: bool = False) -> str:
    """Evaluate ObjC property chains inside FCP's process.

    Two modes:
    1. Dot expression: "NSApp.delegate._targetLibrary.displayName"
    2. Chain array: ["delegate", "_targetLibrary", "displayName"]

    Each step tries respondsToSelector: first, then KVC valueForKey: as fallback.

    Args:
        expression: Dot-separated property chain (e.g. "NSApp.delegate.className")
                   Starting points: "NSApp", "obj_XXX" (handle), or any class name
        chain: Comma-separated chain of property/method names (alternative to expression)
               e.g. "delegate,_targetLibrary,displayName"
        target: Object handle to start the chain from (e.g. "obj_1"). If omitted,
                starts from NSApp for chain mode.
        store_result: Store the final result as a handle for further inspection

    Returns the result value, its class, and optionally a handle.
    """
    params = {}
    if expression:
        params["expression"] = expression
    if chain:
        params["chain"] = [s.strip() for s in chain.split(",")]
    if target:
        params["target"] = target
    if store_result:
        params["storeResult"] = True
    return _call_or_error("debug.eval", **params)


# ---------------------------------------------------------------------------
# Debug: Hot Plugin Loading
# ---------------------------------------------------------------------------
# dlopen/dlclose for live-patching FCP without restarting.

@splicekit_tool("debug_load_plugin", DESTRUCTIVE, title="Load Debug Plugin")
def debug_load_plugin(action: str = "list", path: str = "") -> str:
    """Load or unload arbitrary native code inside Final Cut Pro's running process.

    This runs whatever is in the file, with Final Cut Pro's own privileges, in Final Cut
    Pro's own address space. The dylib's __attribute__((constructor)) runs the moment it
    loads, before this tool returns. A bad build crashes Final Cut Pro and takes any
    unsaved work with it, and a plugin that corrupts memory can damage the open library.
    There is no sandbox and no undo. Unloading does not reverse anything the constructor
    already did. Only load a file you compiled yourself and know the contents of.

    Load compiled .dylib or .bundle files without restarting FCP.
    Use for hot-patching fixes or adding features at runtime.

    Args:
        action: One of:
            - "load": Load a dylib or bundle into FCP
            - "unload": Unload a previously loaded dylib
            - "list": List currently loaded plugins
        path: File path to the .dylib or .bundle to load/unload

    Workflow:
    1. Write patch code (ObjC with constructor function)
    2. Compile: clang -dynamiclib -framework Foundation -o /tmp/fix.dylib fix.m
    3. Load: debug_load_plugin(action="load", path="/tmp/fix.dylib")
    4. Test the change
    5. Unload: debug_load_plugin(action="unload", path="/tmp/fix.dylib")
    """
    params = {"action": action}
    if path:
        params["path"] = path
    return _call_or_error("debug.loadPlugin", **params)


# ---------------------------------------------------------------------------
# Debug: Notification Observation
# ---------------------------------------------------------------------------
# Subscribe to NSNotificationCenter events. FCP posts 337+ named
# notifications internally -- this lets you see them in real time.

@splicekit_tool("debug_observe_notification", LOCAL, title="Observe Notifications")
def debug_observe_notification(action: str = "list", name: str = "",
                               log_object: bool = False) -> str:
    """Subscribe to FCP's internal NSNotification events.

    Events are broadcast to MCP clients in real-time with notification name,
    object class, and userInfo dictionary.

    Args:
        action: One of:
            - "add": Start observing a notification
            - "remove": Stop observing (requires name)
            - "removeAll": Stop all observers
            - "list": List active observers
        name: Notification name (e.g. "FFEffectsChangedNotification").
              Use "*" to observe ALL notifications (high volume — use briefly).
        log_object: Include the notification's object description in events

    Common notifications:
    - FFEffectsChangedNotification: effect stack modified
    - FFEffectStackChangedNotification: effect added/removed
    - FFAssetMediaChangedNotification: media asset changes
    - FFBeatGridSettingsChangedNotification: beat grid toggled
    - FFQTMovieExporterFinishedNotification: export completes
    get_notification_names(binary=...) lists the rest from the running app.
    """
    params = {"action": action}
    if name:
        params["name"] = name
    if log_object:
        params["logObject"] = True
    return _call_or_error("debug.observeNotification", **params)
