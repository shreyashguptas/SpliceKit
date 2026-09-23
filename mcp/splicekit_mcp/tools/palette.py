"""Tools: command palette, LiveCam, commands and AI commands."""

from ..registry import splicekit_tool
from ..bridge import _err, _fmt, bridge


# ============================================================
# Command Palette
# ============================================================
# A floating search palette (like VS Code's Cmd+Shift+P) that
# can also pipe queries through Apple Intelligence for natural
# language editing commands.

@splicekit_tool("show_command_palette")
def show_command_palette() -> str:
    """Open the command palette inside FCP.
    The palette provides quick access to all FCP actions via fuzzy search,
    and supports natural language commands via Apple Intelligence.
    Shortcut: Cmd+Shift+P
    """
    r = bridge.call("command.show")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Command palette opened."


@splicekit_tool("hide_command_palette")
def hide_command_palette() -> str:
    """Close the command palette."""
    r = bridge.call("command.hide")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return "Command palette closed."


@splicekit_tool("livecam_open")
def livecam_open() -> str:
    """Open the LiveCam panel inside Final Cut Pro."""
    r = bridge.call("liveCam.show")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("livecam_close")
def livecam_close() -> str:
    """Close the LiveCam panel."""
    r = bridge.call("liveCam.hide")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("livecam_status")
def livecam_status() -> str:
    """Get the current LiveCam panel state, selected devices, recording flags, and destination."""
    r = bridge.call("liveCam.status")
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


@splicekit_tool("search_commands")
def search_commands(query: str, limit: int = 20) -> str:
    """Search available FCP commands by name, keyword, or category.

    Returns matching commands sorted by relevance. Each result includes:
    name, action, type (timeline/playback/transcript), category, detail, shortcut.

    Use execute_command() to run one of the results.
    """
    r = bridge.call("command.search", query=query, limit=limit)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    commands = r.get("commands", [])
    if not commands:
        return f"No commands match '{query}'"

    lines = [f"Found {r.get('total', len(commands))} matches:"]
    for cmd in commands:
        shortcut = f"  [{cmd['shortcut']}]" if cmd.get("shortcut") else ""
        lines.append(f"  {cmd['name']:<30} {cmd['category']:<12} {cmd['type']}/{cmd['action']}{shortcut}")
        if cmd.get("detail"):
            lines.append(f"    {cmd['detail']}")

    return "\n".join(lines)


@splicekit_tool("execute_command")
def execute_command(action: str, type: str = "timeline") -> str:
    """Execute a command from the palette by action name.

    Args:
        action: The action ID (e.g. "blade", "addColorBoard", "retimeSlow50")
        type: "timeline", "playback", or "transcript"

    This is equivalent to selecting a command in the palette and pressing Enter.
    """
    r = bridge.call("command.execute", action=action, type=type)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return _fmt(r)


_AI_COMMAND_ENGINES = ("standard", "agentic", "gemma")


@splicekit_tool("ai_command")
def ai_command(query: str, engine: str = "") -> str:
    """Use Apple Intelligence (on-device LLM) to interpret a natural language
    editing instruction and execute the appropriate FCP actions.

    FCP's default AI engine is **agentic** (Apple Intelligence+, multi-turn).
    Calls on that path can take several minutes. Use engine="standard" for the
    fast single-shot Apple Intelligence path (fixed action schema, ~60s on the
    bridge).

    Args:
        query: Natural language editing instruction.
        engine: Optional override of the palette's configured engine:
            "standard" — single-shot Apple Intelligence;
            "agentic" — Apple Intelligence+ agent loop (FCP default);
            "gemma" — Gemma 4 via MLX (requires mlx-lm server).
            Omit or pass "" to use the palette setting (usually agentic).

    Examples:
      "cut at 3 seconds"
      "slow this clip to half speed"
      "add color correction"
      "go to the beginning and play"
      "add a chapter marker"

    The LLM translates your description into a sequence of FCP actions and
    executes them automatically. Falls back to keyword matching if Apple
    Intelligence is not available on this Mac.

    The MCP client waits up to ~5.5 minutes (330s) so it outlasts the bridge's
    300s agentic/Gemma deadline; standard mode usually finishes sooner.

    This hands the instruction to a language model that then edits the timeline itself.
    On the agentic and gemma engines it decides its own sequence of actions and can run
    destructive ones — delete, blade, trim, replace — without asking again. It is driven
    by your wording, so keep the instruction specific, and take a verify_action()
    snapshot first if you want to be able to tell exactly what it changed.
    """
    if engine and engine not in _AI_COMMAND_ENGINES:
        allowed = ", ".join(_AI_COMMAND_ENGINES)
        return f"Error: invalid engine '{engine}'. Use one of: {allowed}."
    call_params = {"query": query, "timeout": 330.0}
    if engine:
        call_params["engine"] = engine
    r = bridge.call("command.ai", **call_params)
    if _err(r):
        return f"Error: {r.get('error', r)}"

    # Apple Intelligence+ (agentic) returns a summary string, not actions
    if r.get("summary"):
        return r["summary"]

    actions = r.get("actions", [])
    if not actions:
        return "No actions determined from query."

    # Execute a single AI action, dispatching by type
    def _exec_one(act):
        act_type = act.get("type", "timeline")
        action_name = act.get("action", "")
        repeat = act.get("repeat", 1)

        if act_type == "seek":
            secs = act.get("seconds", 0)
            er = bridge.call("playback.seekToTime", seconds=secs)
            if _err(er):
                return f"Error on seek({secs}s): {er.get('error', er)}"
            return f"seek -> {secs}s"

        if act_type == "effect":
            eff_name = act.get("name", "")
            # Auto-select clip at playhead first
            bridge.call("timeline.action", action="selectClipAtPlayhead")
            er = bridge.call("effects.apply", name=eff_name)
            if _err(er):
                return f"Error on effect '{eff_name}': {er.get('error', er)}"
            return f"effect '{eff_name}' -> ok"

        if act_type == "transition":
            tr_name = act.get("name", "")
            er = bridge.call("transitions.apply", name=tr_name, freezeExtend=True)
            if _err(er):
                return f"Error on transition '{tr_name}': {er.get('error', er)}"
            return f"transition '{tr_name}' -> ok"

        if act_type == "repeat_pattern":
            count = act.get("count", 1)
            inner = act.get("actions", [])
            msgs = []
            for i in range(count):
                for sub in inner:
                    msgs.append(_exec_one(sub))
            return f"repeat_pattern x{count}: " + "; ".join(msgs)

        if act_type == "scene_detect":
            er = bridge.call("scene.detect", threshold=0.35, action="detect", sampleInterval=0.1)
            if _err(er):
                return f"Error on scene_detect: {er.get('error', er)}"
            return f"scene_detect -> {er.get('count', 0)} changes"

        if act_type == "scene_markers":
            er = bridge.call("scene.detect", threshold=0.35, action="markers", sampleInterval=0.1)
            if _err(er):
                return f"Error on scene_markers: {er.get('error', er)}"
            return f"scene_markers -> {er.get('count', 0)} markers"

        # timeline, playback, or any other type with an action field
        for _ in range(repeat):
            er = bridge.call(f"{act_type}.action", action=action_name)
            if _err(er):
                return f"Error on {act_type}.{action_name}: {er.get('error', er)}"
        return f"{act_type}.{action_name}" + (f" x{repeat}" if repeat > 1 else "") + " -> ok"

    # Apple Intelligence returns a list of FCP actions — execute them in order
    results = []
    for act in actions:
        results.append(_exec_one(act))

    return f"AI executed {len(actions)} action(s):\n" + "\n".join(results)


@splicekit_tool("ai_command_gemma")
def ai_command_gemma(query: str, model: str = "unsloth/gemma-4-E4B-it-UD-MLX-4bit") -> str:
    """Use Gemma 4 (via MLX on Apple Silicon) for agentic natural language editing.

    Runs a multi-turn tool-calling loop that can reach every bridge method, rather than
    the fixed action schema ai_command's "standard" engine uses.
    Requires mlx-lm server: python -m mlx_lm.server --model unsloth/gemma-4-E4B-it-UD-MLX-4bit

    ``ai_command(query, engine="gemma")`` reaches the same handler and does the same
    thing; this tool exists to name the model. Prefer whichever reads more clearly, and
    use this one when you want to choose a different `model`.

    This hands the instruction to a language model that then edits the timeline itself.
    It decides its own sequence of actions and can run destructive ones — delete, blade,
    trim, replace — without asking again. It is driven by your wording, so keep the
    instruction specific, and take a verify_action() snapshot first if you want to be able
    to tell exactly what it changed.

    Args:
        query: Natural language editing instruction
        model: HuggingFace model ID (default: unsloth/gemma-4-E4B-it-UD-MLX-4bit). Must be
            the model the mlx-lm server was started with.

    The Gemma path uses a multi-turn agentic loop (local MLX model) and can take
    several minutes; the MCP client waits up to ~5.5 minutes so it outlasts the
    bridge handler's own deadline.
    """
    r = bridge.call("command.aiGemma", query=query, model=model, timeout=330.0)
    if _err(r):
        return f"Error: {r.get('error', r)}"
    return r.get("summary", "Done.")
