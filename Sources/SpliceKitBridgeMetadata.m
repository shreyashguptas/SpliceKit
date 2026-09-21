//
//  SpliceKitBridgeMetadata.m
//  Self-describing RPC surface + lightweight liveness probe.
//
//  Registers three endpoints through the plugin registry:
//    bridge.describe     — returns metadata for every known RPC (built-in + plugin)
//    bridge.alive        — cheap probe that doesn't touch the main thread
//    bridge.safetyTags   — returns the set of safety classifications used
//
//  Built-in method metadata is a static table seeded below. Methods registered
//  via SpliceKit_registerPluginMethod already carry their own metadata dict
//  (see SpliceKitServer.m — sPluginMethodMeta) and are merged into the output.
//

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "SpliceKit.h"

extern NSDictionary *SpliceKit_getPluginMetadataSnapshot(void);  // defined in SpliceKitServer.m

// Safety classifications:
//   safe              — read-only, no side effects on project/library/UI
//   state_dependent   — modifies state, requires current selection/project/timeline
//   modal             — may open a dialog or block the UI
//   destructive       — writes to library/project/clips
//   system            — touches runtime, handles, debug internals
//
// When in doubt, use state_dependent.

static NSDictionary<NSString *, NSDictionary *> *sBuiltinMetadata = nil;

static NSDictionary *meta(NSString *safety, NSString *summary) {
    return @{@"safety": safety, @"summary": summary, @"source": @"builtin"};
}

static void SpliceKit_initBuiltinMetadata(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sBuiltinMetadata = @{
            // system.*
            @"system.version": meta(@"safe", @"SpliceKit + FCP version info."),
            @"system.getClasses": meta(@"safe", @"Enumerate ObjC classes in the process."),
            @"system.getMethods": meta(@"safe", @"List methods on a class."),
            @"system.callMethod": meta(@"system", @"Invoke an ObjC selector — can crash on bad selectors."),
            @"system.callMethodWithArgs": meta(@"system", @"Invoke an ObjC selector with typed args."),
            @"system.getProperties": meta(@"safe", @"List properties on a class."),
            @"system.getProtocols": meta(@"safe", @"List protocol conformances."),
            @"system.getSuperchain": meta(@"safe", @"Walk the inheritance chain."),
            @"system.getIvars": meta(@"safe", @"List ivars with byte offsets."),
            @"system.swizzle": meta(@"system", @"Swap method implementations."),

            // object.*
            @"object.get": meta(@"system", @"Resolve an object handle."),
            @"object.release": meta(@"system", @"Release an object handle."),
            @"object.list": meta(@"safe", @"List active object handles."),
            @"object.getProperty": meta(@"safe", @"Read a property via KVC."),
            @"object.setProperty": meta(@"destructive", @"Write a property via KVC."),

            // timeline.*
            @"timeline.action": meta(@"state_dependent", @"Run a timeline action via responder chain. Needs a loaded project."),
            @"timeline.directAction": meta(@"state_dependent", @"Call action* selector directly on timeline module."),
            @"timeline.getState": meta(@"safe", @"Read basic timeline state (name, duration)."),
            @"timeline.getDetailedState": meta(@"safe", @"Snapshot spine clips, connected clips (anchoredItems), markers, handles, selection."),
            @"timeline.getMarkers": meta(@"safe", @"List markers with time, kind, name, completion, handle."),
            @"timeline.setRange": meta(@"state_dependent", @"Set in/out range selection."),
            @"timeline.addMarkers": meta(@"destructive", @"Batch-add markers at times."),
            @"timeline.bladeAtTimes": meta(@"destructive", @"Batch-blade at multiple times."),
            @"timeline.trimClipsToBeats": meta(@"destructive", @"Trim clips to a beat grid."),
            @"timeline.assembleRandomClipsToBeats": meta(@"destructive", @"Build beat-synced cut from browser pool."),
            @"timeline.batchActions": meta(@"destructive", @"Run a sequence of timeline+playback actions."),
            @"timeline.batchExport": meta(@"destructive", @"Export each clip via Share."),
            @"timeline.selectItems": meta(@"state_dependent", @"Select timeline items by handle (replace/add/remove); never moves the playhead."),
            @"timeline.trimClip": meta(@"destructive", @"Ripple-trim one edit point of a clip by handle, by delta or to an absolute time."),
            @"timeline.getClipInfo": meta(@"safe", @"Clip information by handle: Info inspector fields (name, notes, roles, source media file and its media representation) plus SpliceKit extras (timeline placement, effects, title text, markers, transcript words, a frame from the source media file)."),
            @"timeline.getAudioLevels": meta(@"safe", @"Peak and RMS audio levels (dBFS) over time for one clip, a list of clips or every clip with audio on the timeline (at most 100 per call), mapped to timeline seconds, with the silence at each clip's start and end, the slices at full scale and, for neighbouring primary-storyline clips that were both analysed, the level jump at the cut between them (a transition on the cut is reported instead); decoded from the source media files by the audio-levels helper, so FCP's volume, fades, effects, retiming and the mix are not applied."),
            @"timeline.captureClipFrame": meta(@"state_dependent", @"Captures the clip as rendered in the Viewer; moves the playhead and restores it."),
            @"timeline.beginEdit": meta(@"state_dependent", @"Open one undoable action on the sequence; edits until endEdit become one undo step."),
            @"timeline.endEdit": meta(@"state_dependent", @"Close the open undoable action (actionEnd:save:error:) so the group is one undo step."),

            // browser.*
            @"browser.listClips": meta(@"safe", @"Clips in the browser (the active library's event clips): name, event, duration, handle."),
            @"browser.placeClip": meta(@"destructive", @"Place a browser clip, or a range of it (inSeconds/outSeconds from the clip's first frame), through FCP's pasteboard: edit=insert pastes at the playhead (the effect of Insert W), connect pastes as a connected clip (the effect of Connect Q, backtimed optional), append pastes at the end of the primary storyline (the effect of Append E); atSeconds moves the playhead first. The timeline is re-read before and after: placed, alsoNew, rangeHonored, positionVerified (within two frames). dryRun resolves without editing; the pasteboard is replaced."),
            @"browser.appendClip": meta(@"destructive", @"browser.placeClip with edit=append: paste a browser clip at the end of the primary storyline (the effect of Append E)."),
            @"browser.insertClip": meta(@"destructive", @"browser.placeClip with edit=insert: paste a browser clip at the playhead (the effect of Insert W)."),
            @"browser.connectClip": meta(@"destructive", @"browser.placeClip with edit=connect: paste a browser clip as a connected clip at the playhead (the effect of Connect Q)."),

            // spine.*
            @"spine.getItems": meta(@"safe", @"Read spine-level items from primary storyline."),
            @"spine.reorder": meta(@"destructive", @"Move items within the spine."),
            @"spine.removeItemAtIndex": meta(@"destructive", @"Delete a spine item by index."),
            @"spine.insertItem": meta(@"destructive", @"Insert a spine item at position."),

            // playback.*
            @"playback.action": meta(@"state_dependent", @"Play/pause/step/shuttle."),
            @"playback.seekToTime": meta(@"state_dependent", @"Jump playhead to time (seconds)."),
            @"playback.getPosition": meta(@"safe", @"Read playhead position + playing state."),
            @"playback.setRate": meta(@"state_dependent", @"Set playback rate (negative for reverse)."),
            @"playback.shuttle": meta(@"state_dependent", @"Smooth shuttle at variable speed."),

            // fcpxml.*
            @"fcpxml.import": meta(@"destructive", @"Import FCPXML (new project or into current)."),
            @"fcpxml.pasteImport": meta(@"destructive", @"Paste FCPXML from clipboard."),
            @"otio.toFCPXML": meta(@"safe", @"Convert OTIO to FCPXML in memory."),

            // menu.*
            @"menu.execute": meta(@"modal", @"Execute a menu item by path. May open dialogs."),
            @"menu.list": meta(@"safe", @"List menu items at a path."),

            // effects.* / transitions.*
            @"effects.list": meta(@"safe", @"List all effects on current clip."),
            @"effects.getClipEffects": meta(@"safe", @"Effects on selected clip with handles."),
            @"effects.listAvailable": meta(@"safe", @"Browse library of installed effects."),
            @"effects.apply": meta(@"destructive", @"Apply an effect to the selected clip."),

            // inspector.*
            @"inspector.get": meta(@"safe", @"Read inspector properties of selected clip."),
            @"inspector.set": meta(@"destructive", @"Write an inspector property."),
            @"inspector.getTitle": meta(@"safe", @"Read text/font from selected title."),

            // view.*
            @"view.toggle": meta(@"state_dependent", @"Show/hide a panel (inspector, scopes, etc.)."),
            @"view.workspace": meta(@"state_dependent", @"Switch workspace layout."),

            // debug.*
            @"debug.traceMethod": meta(@"system", @"Install a method trace."),
            @"debug.watch": meta(@"system", @"Watch a keypath for changes."),
            @"debug.crashHandler": meta(@"system", @"Install/query crash handler."),
            @"debug.threads": meta(@"safe", @"Inspect process threads."),
            @"debug.eval": meta(@"system", @"Evaluate an ObjC keypath chain."),
            @"debug.loadPlugin": meta(@"system", @"Hot-load a dylib/bundle into FCP."),
            @"debug.observeNotification": meta(@"system", @"Subscribe to NSNotification events."),
            @"debug.breakpoint": meta(@"system", @"Install a method breakpoint (pauses FCP)."),

            // captions.*
            @"captions.open": meta(@"state_dependent", @"Open caption panel."),
            @"captions.close": meta(@"state_dependent", @"Close caption panel."),
            @"captions.getState": meta(@"safe", @"Read caption pipeline state."),
            @"captions.getStyles": meta(@"safe", @"List caption style presets."),
            @"captions.setStyle": meta(@"state_dependent", @"Apply a caption style."),
            @"captions.generate": meta(@"destructive", @"Generate and paste captions onto timeline."),
            @"captions.verify": meta(@"safe", @"Inspect titles to verify caption text."),
            @"captions.exportSRT": meta(@"safe", @"Write SRT file."),
            @"captions.exportTXT": meta(@"safe", @"Write plain text file."),

            // transcript.*
            @"transcript.open": meta(@"destructive", @"Transcribe timeline or file (long-running)."),
            @"transcript.close": meta(@"state_dependent", @"Close transcript panel."),
            @"transcript.getState": meta(@"safe", @"Read transcript words/silences/speakers."),
            @"transcript.deleteWords": meta(@"destructive", @"Delete timeline segments by word range."),
            @"transcript.moveWords": meta(@"destructive", @"Reorder timeline segments."),
            @"transcript.search": meta(@"safe", @"Search transcript text."),
            @"transcript.deleteSilences": meta(@"destructive", @"Ripple-delete pauses."),
            @"transcript.clear": meta(@"destructive", @"Clears transcript text and on-disk cache for the panel."),
            @"transcript.setSilenceThreshold": meta(@"state_dependent", @"Recomputes silence markers at a new threshold."),
            @"transcript.setSpeaker": meta(@"state_dependent", @"Labels speaker on a word range in the transcript panel."),
            @"transcript.setEngine": meta(@"state_dependent", @"Switches the transcript recognition engine."),

            // scene.*
            @"scene.detect": meta(@"safe", @"Detect scene changes in timeline."),

            // transitions.*
            @"transitions.list": meta(@"safe", @"Lists installed transition effects."),
            @"transitions.apply": meta(@"destructive", @"Applies a transition at the current edit point."),

            // titles.* / stabilize.*
            @"titles.insert": meta(@"destructive", @"Inserts a Motion title on the timeline at the playhead."),
            @"stabilize.subject": meta(@"destructive", @"Tracks a subject and writes position keyframes on the selected clip."),

            // command.* (palette)
            @"command.show": meta(@"state_dependent", @"Opens the in-app command palette window."),
            @"command.hide": meta(@"state_dependent", @"Closes the command palette."),
            @"command.search": meta(@"safe", @"Fuzzy-searches available commands without executing them."),
            @"command.execute": meta(@"state_dependent", @"Runs a palette command by id."),
            @"command.ai": meta(@"state_dependent", @"Sends natural language to Apple Intelligence via the palette."),
            @"command.aiGemma": meta(@"state_dependent", @"Runs a Gemma model prompt through the palette."),
            @"command.aiAppleAgentic": meta(@"state_dependent", @"Runs an agentic Apple Intelligence request via the palette."),

            // liveCam.*
            @"liveCam.show": meta(@"state_dependent", @"Opens the Live Cam floating panel."),
            @"liveCam.hide": meta(@"state_dependent", @"Closes the Live Cam panel."),
            @"liveCam.status": meta(@"safe", @"Reports Live Cam panel and capture state."),

            // dualTimeline.*
            @"dualTimeline.status": meta(@"safe", @"Reports dual-timeline panel state."),
            @"dualTimeline.open": meta(@"state_dependent", @"Opens the secondary timeline editor."),
            @"dualTimeline.syncRoot": meta(@"state_dependent", @"Syncs root sequence between primary and secondary."),
            @"dualTimeline.openSelectedInSecondary": meta(@"state_dependent", @"Opens the selected compound/reference clip in the secondary timeline."),
            @"dualTimeline.focus": meta(@"state_dependent", @"Moves keyboard focus between primary and secondary timelines."),
            @"dualTimeline.close": meta(@"state_dependent", @"Closes the secondary timeline."),
            @"dualTimeline.togglePanel": meta(@"state_dependent", @"Shows or hides the dual-timeline panel."),

            // media.*
            @"media.importFile": meta(@"modal", @"Imports a media file into the active event (may show import UI)."),
            @"media.removeClip": meta(@"destructive", @"Removes a source clip from an event's browser. The media file on disk is untouched."),

            // roles.*
            @"roles.assign": meta(@"destructive", @"Assigns a video or audio role on the selected clip."),

            // mixer.*
            @"mixer.getState": meta(@"safe", @"Reads role faders, mutes, solos, and bus effects for the open timeline."),
            @"mixer.setVolume": meta(@"state_dependent", @"Sets a role or clip fader level."),
            @"mixer.setSolo": meta(@"state_dependent", @"Solo or unsolo a role."),
            @"mixer.setMute": meta(@"state_dependent", @"Mute or unmute a role."),
            @"mixer.applyBusEffect": meta(@"destructive", @"Inserts a managed bus effect on a role."),
            @"mixer.openBusEffect": meta(@"state_dependent", @"Opens the bus effect editor for a role."),
            @"mixer.setBusEffectEnabled": meta(@"state_dependent", @"Enables or disables a managed bus effect."),
            @"mixer.removeBusEffect": meta(@"destructive", @"Removes a managed bus effect from a role."),
            @"mixer.setMasterVolume": meta(@"state_dependent", @"Sets the master output level."),
            @"mixer.volumeBegin": meta(@"state_dependent", @"Begins a grouped volume drag on the mixer."),
            @"mixer.volumeEnd": meta(@"state_dependent", @"Ends a grouped volume drag on the mixer."),
            @"mixer.setAllVolumes": meta(@"state_dependent", @"Sets fader levels for every role at once."),
            @"mixer.open": meta(@"state_dependent", @"Opens the SpliceKit mixer panel."),
            @"mixer.close": meta(@"state_dependent", @"Closes the SpliceKit mixer panel."),
            @"mixer.debug": meta(@"safe", @"Dumps internal mixer reconciliation state for debugging."),

            // share.*
            @"share.export": meta(@"modal", @"Triggers File > Share (opens the share sheet)."),

            // project.*
            @"project.create": meta(@"modal", @"Starts new project creation (may show a save panel)."),
            @"project.createEvent": meta(@"modal", @"Starts new event creation (may show a save panel)."),
            @"project.createLibrary": meta(@"modal", @"Starts new library creation (may show a save panel)."),
            @"project.open": meta(@"state_dependent", @"Loads a project by name in the active library."),

            // urlImport.*
            @"urlImport.start": meta(@"state_dependent", @"Begins a background URL import job."),
            @"urlImport.import": meta(@"destructive", @"Imports remote media into the library synchronously."),
            @"urlImport.status": meta(@"safe", @"Reports progress of an in-flight URL import."),
            @"urlImport.cancel": meta(@"state_dependent", @"Cancels a running URL import."),

            // timeline capture / lane selection
            @"timeline.selectClipInLane": meta(@"state_dependent", @"Selects the connected clip on a storyline lane at the playhead."),
            @"timeline.capture": meta(@"safe", @"Captures the timeline window to a PNG file."),

            // viewer.* / inspector capture
            @"viewer.capture": meta(@"safe", @"Captures the viewer window to a PNG file."),
            @"inspector.capture": meta(@"safe", @"Captures the inspector window to a PNG file."),
            @"viewer.getZoom": meta(@"safe", @"Reads viewer canvas zoom level."),
            @"viewer.setZoom": meta(@"state_dependent", @"Sets viewer canvas zoom level."),

            // fcpxml export
            @"fcpxml.export": meta(@"destructive", @"Writes the active sequence to an FCPXML file on disk."),

            // tool.*
            @"tool.select": meta(@"state_dependent", @"Switches the active timeline tool (blade, trim, etc.)."),

            // dialog.*
            @"dialog.detect": meta(@"safe", @"Lists open dialogs, buttons, fields, and checkboxes."),
            @"dialog.click": meta(@"state_dependent", @"Clicks a dialog button by title or index."),
            @"dialog.fill": meta(@"state_dependent", @"Types into a dialog text field."),
            @"dialog.checkbox": meta(@"state_dependent", @"Toggles a dialog checkbox."),
            @"dialog.popup": meta(@"state_dependent", @"Chooses an item from a dialog pop-up."),
            @"dialog.dismiss": meta(@"state_dependent", @"Dismisses the front dialog via default or cancel."),

            // backgroundRender.*
            @"backgroundRender.status": meta(@"safe", @"Reads background render queue state."),
            @"backgroundRender.control": meta(@"state_dependent", @"Starts, stops, or pauses background rendering."),

            // options.*
            @"options.get": meta(@"safe", @"Reads SpliceKit/FCP behavioral option flags."),
            @"options.set": meta(@"system", @"Writes SpliceKit/FCP behavioral option flags."),

            // beats.*
            @"beats.detect": meta(@"safe", @"Runs beat detection on an audio file path (no timeline change)."),

            // flexmusic.*
            @"flexmusic.listSongs": meta(@"safe", @"Lists FlexMusic songs in the library."),
            @"flexmusic.getSong": meta(@"safe", @"Reads metadata for one FlexMusic song."),
            @"flexmusic.getTiming": meta(@"safe", @"Reads beat/bar timing metadata for a song."),
            @"flexmusic.renderToFile": meta(@"destructive", @"Renders a FlexMusic mix to an audio file on disk."),
            @"flexmusic.addToTimeline": meta(@"destructive", @"Places FlexMusic audio on the timeline."),

            // montage.*
            @"montage.analyzeClips": meta(@"safe", @"Scores browser clips for montage assembly (read-only)."),
            @"montage.planEdit": meta(@"safe", @"Builds a montage edit plan without applying it."),
            @"montage.assemble": meta(@"destructive", @"Executes a montage plan on the timeline."),
            @"montage.auto": meta(@"destructive", @"Analyzes, plans, and assembles a montage in one call."),

            // sections.* (timeline bar)
            @"sections.show": meta(@"state_dependent", @"Shows the custom sections bar overlay."),
            @"sections.hide": meta(@"state_dependent", @"Hides the custom sections bar overlay."),
            @"sections.add": meta(@"destructive", @"Adds a labeled section on the timeline bar."),
            @"sections.remove": meta(@"destructive", @"Removes a section from the timeline bar."),
            @"sections.setColor": meta(@"state_dependent", @"Changes a section's color on the timeline bar."),
            @"sections.get": meta(@"safe", @"Lists sections on the timeline bar."),

            // structure.*
            @"structure.generateBlocks": meta(@"destructive", @"Generates structure blocks on the timeline from analysis."),
            @"structure.generateCaptions": meta(@"destructive", @"Generates structure caption titles on the timeline."),
            @"structure.remove": meta(@"destructive", @"Removes generated structure items."),
            @"structure.toggle": meta(@"state_dependent", @"Toggles structure overlay visibility."),

            // debug config / runtime export (additional)
            @"debug.getConfig": meta(@"safe", @"Reads FCP debug and log configuration keys."),
            @"debug.setConfig": meta(@"system", @"Sets a FCP debug or log configuration key."),
            @"debug.resetConfig": meta(@"system", @"Resets debug configuration groups to defaults."),
            @"debug.enablePreset": meta(@"system", @"Applies a named debug flag preset."),
            @"debug.startFramerateMonitor": meta(@"system", @"Starts HMDFramerate logging to the system log."),
            @"debug.stopFramerateMonitor": meta(@"system", @"Stops HMDFramerate logging."),
            @"debug.dumpRuntimeMetadata": meta(@"safe", @"Exports ObjC runtime metadata JSON (read-only introspection)."),
            @"debug.listLoadedImages": meta(@"safe", @"Lists Mach-O images loaded in the process."),
            @"debug.getImageSections": meta(@"safe", @"Reads ObjC class/selector sections from a binary."),
            @"debug.getImageSymbols": meta(@"safe", @"Lists demangled symbols from a loaded image."),
            @"debug.getNotificationNames": meta(@"safe", @"Discovers notification-related classes and names."),
            @"debug.showSettingsPanel": meta(@"state_dependent", @"Opens the SpliceKit debug settings panel."),
            @"debug.installMenuBar": meta(@"system", @"Installs SpliceKit items on the menu bar."),

            // captions.* (additional)
            @"captions.setGrouping": meta(@"state_dependent", @"Sets caption word-grouping mode for generation."),
            @"captions.setWords": meta(@"state_dependent", @"Supplies transcript words to the caption pipeline."),
            @"captions.setXML": meta(@"state_dependent", @"Loads caption title XML into the pipeline."),
            @"captions.cleanup": meta(@"destructive", @"Removes temporary caption projects from the library."),

            // nativeCaptions.*
            @"nativeCaptions.generate": meta(@"destructive", @"Creates FFAnchoredCaption objects on the caption lane."),
            @"nativeCaptions.verify": meta(@"safe", @"Inspects native captions against expected text."),
            @"nativeCaptions.remove": meta(@"destructive", @"Deletes caption items from the open sequence (native or Motion-title pipeline)."),

            // lua.*
            @"lua.execute": meta(@"system", @"Runs Lua source in the embedded VM (full FCP access)."),
            @"lua.executeFile": meta(@"system", @"Runs a Lua file in the embedded VM."),
            @"lua.reset": meta(@"system", @"Resets the Lua VM state."),
            @"lua.getState": meta(@"safe", @"Reads Lua VM globals and loaded modules."),
            @"lua.watch": meta(@"system", @"Registers a filesystem watch on a Lua script path."),

            // plugin.*
            @"plugin.listMethods": meta(@"safe", @"Lists dynamically registered plugin RPC methods."),
            @"plugin.list": meta(@"safe", @"Lists loaded SpliceKit plugins."),
        };
    });
}

NSDictionary *SpliceKit_builtinMetadataForMethod(NSString *method) {
    SpliceKit_initBuiltinMetadata();
    return sBuiltinMetadata[method];
}

static NSDictionary *SpliceKit_handleBridgeDescribe(NSDictionary *params) {
    SpliceKit_initBuiltinMetadata();

    NSString *wanted = params[@"method"];
    NSString *safetyFilter = params[@"safety"];

    // Merge built-in + plugin-registered metadata
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    for (NSString *name in sBuiltinMetadata) {
        merged[name] = sBuiltinMetadata[name];
    }
    NSDictionary *pluginSnapshot = SpliceKit_getPluginMetadataSnapshot();
    for (NSString *name in pluginSnapshot) {
        NSMutableDictionary *entry = [pluginSnapshot[name] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (!entry[@"source"]) entry[@"source"] = @"plugin";
        merged[name] = entry;
    }

    if (wanted) {
        NSDictionary *entry = merged[wanted];
        if (!entry) return @{@"error": [NSString stringWithFormat:@"No metadata for %@", wanted]};
        NSMutableDictionary *out = [entry mutableCopy];
        out[@"name"] = wanted;
        return out;
    }

    NSMutableArray *methods = [NSMutableArray arrayWithCapacity:merged.count];
    NSUInteger classified = 0;
    for (NSString *name in merged) {
        NSDictionary *entry = merged[name];
        NSString *safety = entry[@"safety"] ?: @"unclassified";
        if (safetyFilter && ![safety isEqualToString:safetyFilter]) continue;
        NSMutableDictionary *out = [entry mutableCopy];
        out[@"name"] = name;
        [methods addObject:out];
        if (![safety isEqualToString:@"unclassified"]) classified += 1;
    }
    [methods sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    return @{
        @"methods": methods,
        @"count": @(methods.count),
        @"classified": @(classified),
        @"safety_tags": @[@"safe", @"state_dependent", @"modal", @"destructive", @"system", @"unclassified"],
    };
}

static NSDictionary *SpliceKit_handleBridgeAlive(NSDictionary *params) {
    // Deliberately doesn't touch the main thread — purely process-local.
    return @{
        @"alive": @YES,
        @"version": @SPLICEKIT_VERSION,
        @"pid": @(getpid()),
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
    };
}

static NSDictionary *SpliceKit_handleBridgeSafetyTags(NSDictionary *params) {
    return @{
        @"tags": @{
            @"safe": @"Read-only, no side effects.",
            @"state_dependent": @"Modifies state; needs project/selection/timeline.",
            @"modal": @"May open a dialog or block the UI.",
            @"destructive": @"Writes to library/project/clips.",
            @"system": @"Runtime/handles/debug internals.",
            @"unclassified": @"No classification yet — treat as potentially destructive.",
        }
    };
}

void SpliceKit_installBridgeMetadata(void) {
    SpliceKit_initBuiltinMetadata();

    SpliceKit_registerPluginMethod(@"bridge.describe",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleBridgeDescribe(params); },
        @{@"safety": @"safe",
          @"summary": @"Self-describing metadata for every known RPC method.",
          @"source": @"builtin"});

    SpliceKit_registerPluginMethod(@"bridge.alive",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleBridgeAlive(params); },
        @{@"safety": @"safe",
          @"summary": @"Cheap liveness probe — does not touch main thread.",
          @"source": @"builtin"});

    SpliceKit_registerPluginMethod(@"bridge.safetyTags",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleBridgeSafetyTags(params); },
        @{@"safety": @"safe",
          @"summary": @"Enumerate safety classifications and their meanings.",
          @"source": @"builtin"});

    SpliceKit_log(@"[BridgeMetadata] Registered bridge.describe / bridge.alive / bridge.safetyTags (%lu built-in methods catalogued)",
                  (unsigned long)sBuiltinMetadata.count);
}
