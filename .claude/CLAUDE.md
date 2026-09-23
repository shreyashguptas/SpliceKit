# SpliceKit - Programmatic Final Cut Pro Control

SpliceKit is an ObjC dylib injected into FCP's process. It exposes all 78,000+ ObjC classes
via a JSON-RPC server on TCP 127.0.0.1:9876. Everything is fully programmatic -- no AppleScript,
no UI automation, no menu clicks.

This file is the operating essentials. Every tool, by area, is in
[docs/reference/mcp-tools.md](../docs/reference/mcp-tools.md); the rest is under
[Where to look](#where-to-look).

## NEVER Use Keyboard Simulation or AppleScript

All FCP actions MUST go through direct ObjC calls. Never use any of these:
- `SpliceKit_simulateKeyPress()` or synthetic NSEvent key events
- `CGEvent` keyboard/mouse posting
- `osascript` / `NSAppleScript` / AppleScript `tell application`
- Accessibility APIs (`AXUIElement`) for clicking or typing
- Frame-stepping loops (`nextFrame` x N) when `seekToTime` exists

**Instead, always use one of these patterns (in priority order):**
1. **Direct method call** on the timeline/sequence/clip object via `objc_msgSend`
2. **Responder chain** via `[NSApp sendAction:NSSelectorFromString(@"selector:") to:nil from:nil]`
3. **Batch bridge endpoint** (e.g. `timeline.addMarkers`) for operations on multiple items
4. **Menu execute** via `menu.execute` for actions only accessible through menus

If an action doesn't have a direct ObjC selector yet, find one using `explore_class` /
`search_methods` on the relevant class (FFAnchoredTimelineModule, FFAnchoredSequence, etc.)
rather than simulating the keyboard shortcut.

## Quick Start

```
1. bridge_status()                    -- verify connection
2. open_project("My Project")         -- open a project by name
3. get_timeline_clips()               -- see timeline contents: spine clips + connected clips + markers
4. get_clip_info("obj_12")            -- what is IN the clip: source file, transcript words, effects, title text, a frame image
5. browser_list_clips()               -- source clips in the browser, with handles
6. add_clip_to_timeline("obj_5", edit="connect", start_seconds=12, end_seconds=18, at_seconds=45)
                                      -- a range of that source clip pasted at the playhead (the effect of Insert / Connect / Append)
7. blade_at_times([3.0])              -- edit
8. verify_action("after blade")       -- confirm state changed
9. capture_timeline()                 -- visually verify the timeline
10. capture_viewer()                  -- visually verify the viewer/canvas
```

## CRITICAL: Must Know Before Editing

### Opening a Project
Use `open_project()` to load a project by name:
```python
open_project("My Project")                   # find by name
open_project("Edit v2", event="4-5-26")      # filter by event too
```
An exact project name always beats a longer one that merely contains it, so
`open_project("QA Timeline")` opens that and not "QA Timeline 1".

If you need lower-level control, you can still navigate manually:
```python
# Navigate: library -> sequences -> find one with content -> load it
libs = call_method_with_args("FFLibraryDocument", "copyActiveLibraries", "[]", true, true)
libs_handle = json.loads(libs)["handle"]
lib = call_method_with_args(libs_handle, "objectAtIndex:", '[{"type":"int","value":0}]', false, true)
lib_handle = json.loads(lib)["handle"]
seqs = call_method_with_args(lib_handle, "_deepLoadedSequences", "[]", false, true)
seqs_handle = json.loads(seqs)["handle"]
allSeqs = call_method_with_args(seqs_handle, "allObjects", "[]", false, true)
# For each sequence result, extract its "handle" before calling hasContainedItems
# Example: seq_handle = json.loads(seq)["handle"]
# Check each: call_method_with_args(seq_handle, "hasContainedItems", "[]", false)
# Load: get NSApp -> delegate -> activeEditorContainer -> loadEditorForSequence:
```

### Select Before Acting
Color correction, retiming, titles, and effects require a selected clip:
```
seek_to_time(12.5)                                   # position the playhead
timeline_navigation_action("selectClipAtPlayhead")   # select primary storyline clip
timeline_edit_action("addColorBoard")                # now apply
```

To select a connected clip (title, B-roll, etc.) use `select_clip_in_lane()`:
```
select_clip_in_lane(lane=1)               # select connected clip above primary
select_clip_in_lane(lane=-1)              # select connected clip below
select_clip_in_lane(lane=0)               # same as selectClipAtPlayhead
```

To act on a specific clip without moving the playhead, select it by handle:
```
get_timeline_clips()                      # every clip (spine + connected) comes with a handle
select_clips(handles=["obj_12"])          # make that clip the selection (add/remove modes too)
timeline_edit_action("addColorBoard")     # now apply
```
Markers are not selectable this way; an empty list deselects everything.

### Playhead Positioning
- 1 frame = ~0.042s at 24fps, ~0.033s at 30fps
- Use `seek_to_time(seconds)` for precise positioning. This is the rule at the top of this
  file: never step frame by frame to reach a time `seek_to_time` can jump to.
- `nextFrame` / `prevFrame` are for moving one or two frames off a position you are
  already at — nudging to the next edit, checking the frame after a cut.
- For many edits at many times, use the batch tools (`blade_at_times`,
  `add_markers_at_times`) instead of a loop of seeks.

### Undo After Mistakes
```
history_action("undo")    # undoes last edit, returns action name
history_action("redo")    # redoes it
```
Undo routes through FCP's FFUndoManager (not the responder chain).

Group a multi-step edit into ONE undo step (Edit > Undo <name>; FCP's internal term is an undoable action):
```
begin_edit("Rough cut")   # open the group
blade_at_times([...]); trim_clip(...); ...
end_edit()                # close it -- always, also after an error; one undo now reverts it all
```

### Timeline Data Model (Spine)
FCP stores items in: `sequence -> primaryObject (FFAnchoredCollection) -> containedItems`
- `FFAnchoredMediaComponent` = video/audio clips
- `FFAnchoredTransition` = transitions (Cross Dissolve, etc.)
- `get_timeline_clips()` handles this automatically

### Which action tool
FCP's own commands on the selection / playhead go through dispatchers that take an action
name (each tool's docstring lists the names it accepts; the full table is in
[mcp-tools.md](../docs/reference/mcp-tools.md#timeline-actions)):

| Tool | For |
|------|-----|
| `timeline_navigation_action` | nextEdit, selectClipAtPlayhead, selectAll, zoomToFit... (no content change) |
| `timeline_edit_action` | addMarker, addColorBoard, addBasicTitle, setRangeStart, paste, appendEdit... |
| `timeline_destructive_action` | blade, delete, cut, trimToPlayhead, retimeSlow50, replaceWithGap... |
| `history_action` | undo, redo |
| `playback_action` | playPause, goToStart, goToEnd, nextFrame, prevFrame... |
| `timeline_action` | the legacy dispatcher that accepts all of the above by name |
| `direct_timeline_action` | FCP's parameterized action methods with real arguments (retimeSetRate, changeAudioVolume...) |

"No responder handled X" means the action is not available in this state (nothing
selected, no edit point, wrong tool).

## Common Workflows

### Blade at a specific time
```
seek_to_time(3.0)                          # jump to 3 seconds
timeline_destructive_action("blade")       # cut there
```

### Multiple cuts (batch — preferred)
```
blade_at_times([3.0, 6.0, 9.0, 12.0, 15.0])   # cut at all times in one call
```

### Cuts at regular intervals across entire timeline
```
# Compute times: every 3s across a 30s timeline
blade_at_times([3.0, 6.0, 9.0, 12.0, 15.0, 18.0, 21.0, 24.0, 27.0])
```

### Add markers at intervals
```
add_markers_at_times("5.0, 10.0, 15.0, 20.0")        # standard markers, one undo step
add_markers_at_times('[{"time": 5.0, "name": "Intro", "kind": "chapter"},
                       {"time": 10.0, "name": "Fix VO", "kind": "todo"}]')
```

### Trim a clip to an exact time
```
get_timeline_clips()                                              # find the clip's handle
trim_clip("obj_12", edge="end", to_seconds=8.0, dry_run=True)     # plan: before/projected ranges
trim_clip("obj_12", edge="end", to_seconds=8.0)                   # ripple trim the end edit point to 8.0s
```
This is FCP's default trim, a ripple edit: subsequent clips move so no gap is left.
`delta_seconds=-0.5` works too (negative = edit point earlier). Each trim is one undo step.

### Add a source clip, or a range of it, to the timeline
```
browser_list_clips()                                                       # name, event, handle, isProject
add_clip_to_timeline("obj_5", edit="connect", start_seconds=12, end_seconds=18, at_seconds=45, dry_run=True)
add_clip_to_timeline("obj_5", edit="insert", at_seconds=0)                 # whole clip, the effect of Insert (W) at 0s
add_clip_to_timeline("obj_5", edit="append")                               # whole clip, the effect of Append (E)
```
Check `isProject` before using a row: a project is a whole timeline, and these tools refuse
it (open it with `open_project(name)`). The pasteboard is replaced; one `history_action("undo")`
removes the edit.

### Look inside a clip, hear it
```
get_clip_info("obj_12")                   # Info inspector fields, effects, title text, markers, transcript words, a source frame
capture_clip_frame("obj_12")              # the clip as rendered in the Viewer (effects included)
get_audio_levels("obj_12")                # peak/RMS of its source audio + the jump at the cuts on both sides
```
`get_audio_levels` measures the source media file, not FCP's meters: volume, fades and effects
are not applied.

### Add color correction
```
select_clips(handles=["obj_12"])
timeline_edit_action("addColorBoard")
```

### Change speed
```
select_clips(handles=["obj_12"])
timeline_destructive_action("retimeSlow50")    # 50% speed
direct_timeline_action(action="retimeSetRate", rate=0.75, ripple=True)   # any rate
# Undo: history_action("undo")
```

### Apply a transition
```
seek_to_time(12.0)                                  # at or near the cut
timeline_navigation_action("nextEdit")              # go to the edit point
apply_transition(name="Cross Dissolve")             # freeze-extends when media handles are short
```

### Set in/out range programmatically
```
set_timeline_range(start_seconds=5.0, end_seconds=10.0)  # mark in at 5s, out at 10s
timeline_edit_action("clearRange")                       # remove range selection
```

### Create project via FCPXML (no restart)
```
xml = generate_fcpxml(
    project_name="My Project",
    frame_rate="24",
    items='[
      {"type":"gap","duration":10},
      {"type":"title","text":"Introduction","duration":5},
      {"type":"transition","duration":1},
      {"type":"gap","duration":15},
      {"type":"marker","time":5,"name":"Chapter 1","kind":"chapter"}
    ]'
)
import_fcpxml(xml, internal=True)
```
`import_fcpxml(path=...)` imports a file; a long import returns a job id for
`import_fcpxml_status(job_id)`; never import the same file again while its job runs.

### Text-based editing via transcript
```
open_transcript()                              # transcribe all clips on timeline
get_transcript()                               # first 1000 words + silences; status, skipped clips, progress
search_transcript("pauses")                    # find all silences/pauses
delete_transcript_words(start_index=5, count=3) # delete words 5-7 (removes video segment)
move_transcript_words(start_index=10, count=2, dest_index=3) # reorder clips
delete_transcript_silences(min_duration=1.0)   # remove only silences > 1 second
```

### Scene changes
```
detect_scene_changes(handle="obj_12")          # read-only: cuts in source-media seconds + scores
mark_scene_changes(handle="obj_12")            # markers at cuts (one undo step)
blade_scene_changes(handle="obj_12")           # blade at cuts (one undo step)
```

### Export
```
export_xml(path="/tmp/my_project.fcpxml")        # FCPXML, no dialog
export_otio(path="/tmp/my_project.otio")         # .otio / .fcpxml / .edl / .aaf
batch_export(folder="/path/to/output")           # every clip as its own file; folder is required
```

## Error Recovery
- "No active timeline module" / "No sequence in timeline" -> No project open: `open_project()`.
- "Cannot connect" -> the patched FCP is not running. Launch it.
- "Handle not found" -> Released or stale. Re-read with `get_timeline_clips()`.
- "No responder handled X" -> Action not available (wrong state or no selection).
- Broken pipe -> Stale connection. Next call auto-reconnects.
- A modal dialog is blocking -> `detect_dialog()`, then `click_dialog_button` / `dismiss_dialog`.

## Where to look

| Topic | Doc |
|-------|-----|
| Every MCP tool, by area | [docs/reference/mcp-tools.md](../docs/reference/mcp-tools.md) |
| Transcript editing | [docs/guides/transcript-editing.md](../docs/guides/transcript-editing.md) |
| Social captions | [docs/guides/captions.md](../docs/guides/captions.md) |
| Song cut (beat-synced assembly) | [docs/guides/song-cut.md](../docs/guides/song-cut.md) |
| Scene and beat detection | [docs/guides/scene-and-beat-detection.md](../docs/guides/scene-and-beat-detection.md) |
| FlexMusic and montage | [docs/guides/flexmusic-and-montage.md](../docs/guides/flexmusic-and-montage.md) |
| Command palette | [docs/guides/command-palette.md](../docs/guides/command-palette.md) |
| Dialogs | [docs/guides/dialog-automation.md](../docs/guides/dialog-automation.md) |
| Lua scripting (tutorial / SDK) | [docs/guides/lua-scripting.md](../docs/guides/lua-scripting.md), [docs/reference/lua-sdk.md](../docs/reference/lua-sdk.md) |
| FCP's classes and methods | [docs/reference/fcp-api.md](../docs/reference/fcp-api.md) |
| Runtime introspection, IDA export | [docs/reference/runtime-introspection.md](../docs/reference/runtime-introspection.md) |
| Debugger, FCP debug flags | [docs/reference/debug-tools.md](../docs/reference/debug-tools.md) |
| FCPXML format | [docs/reference/fcpxml-format.md](../docs/reference/fcpxml-format.md) |
| How features work inside | [docs/internals/](../docs/internals/) (captions, FCPXML paste, beat detection, haptics) |
| Changes, network access | [docs/CHANGELOG.md](../docs/CHANGELOG.md), [docs/THIRD_PARTY_DEPENDENCIES.md](../docs/THIRD_PARTY_DEPENDENCIES.md) |

## For contributors

### Layout
- `Sources/` — the dylib: `Core/` (entry point, shared helpers such as
  `SpliceKitStrings.h`), `Bridge/` (JSON-RPC server and handlers), `Features/`, `Panels/`,
  `Timeline/`, `Media/`, `Audio/`, `Haptics/`, `Lua/`.
- `mcp/server.py` — a thin launcher for the `mcp/splicekit_mcp/` package; tools live in
  `mcp/splicekit_mcp/tools/`, one module per area, imported in registration order by
  `mcp/splicekit_mcp/tools/__init__.py`. The server's instructions are in
  `mcp/splicekit_mcp/app.py`.
- `helpers/` (Swift CLIs: beat detection, audio levels, transcribers), `scripts/`, `lua/`,
  `plugins/`, `patcher/`, `tests/` (`tests/live/` needs the running app).

### Build, test, deploy
```
make                   # build the dylib
make test              # every offline check: unit tests + mcp-check (no FCP needed)
make test-unit         # just the unit tests
make mcp-check         # every tool/resource/prompt over MCP against a fake bridge (no FCP)
make mcp-check-live    # read from the running patched FCP through the MCP server
make deploy            # build and copy into the patched app (restart FCP to load it)
make install           # the full one-command install; make install-check to inspect
```

### Add an RPC
Write the handler (`NSDictionary *handler(NSDictionary *params)`, declared in
`Sources/Bridge/SpliceKitServerInternal.h`, or `SpliceKitServerHandlers.h` when other files
call it), add one row to `Sources/Bridge/SpliceKitRPCTable.def`:
```
SK_RPC("timeline.myThing", SpliceKit_handleMyThing, @"state_dependent", @"One line for bridge.describe.")
```
then run `python3 scripts/gen_bridge_params.py` so `bridge.describe` lists the parameters it
reads. The safety tag is one of safe / state_dependent / modal / destructive / system.

### Add an MCP tool
In the right `mcp/splicekit_mcp/tools/*.py` module:
```python
@splicekit_tool("my_thing", LOCAL, title="My thing")   # READ | LOCAL | LOCAL_IDEMPOTENT | DESTRUCTIVE
def my_thing(seconds: float) -> str:
    """What it does, in FCP's terms. Args: ..."""
    return _call_or_error("timeline.myThing", seconds=seconds)
```
The decorator sets the tool's annotations from its class (and fills READ_ONLY_TOOLS /
LOCAL_WRITE_TOOLS / IDEMPOTENT_LOCAL_WRITE_TOOLS / DESTRUCTIVE_TOOLS), checks that `name`
matches the function, and turns unexpected exceptions into a `ToolError` whose text reaches
the client; `title=` is optional. Tools return `-> str` (published as structured output
`{"result": ...}`); the image tools carry no return annotation so they can return text +
image content. Then: add the tool to [docs/reference/mcp-tools.md](../docs/reference/mcp-tools.md)
(`tests/test_docs_tool_names.py` fails otherwise), keep the server's `instructions` in step
when it changes which tool to pick, and run `make test`.

The server runs on the official MCP Python SDK 2.x (`mcp>=2.2,<3` in `mcp/requirements.txt`;
`MCPServer` from `mcp.server.mcpserver`, protocol revision 2026-07-28, legacy `initialize`
handshake still accepted). The SDK runs sync tools in worker threads, so
`BridgeConnection.call` holds a lock for each round trip.
