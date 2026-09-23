//
//  SpliceKitCommandPalette+Registry.m
//  The command list: every registered command, favorites, the right-click menu
//  and the browse modes (favorites, transitions, effects).
//

#import "SpliceKitCommandPalette+Private.h"

@implementation SpliceKitCommandPalette (Registry)

#pragma mark - Command Registry
//
// Every command the palette knows about is registered here. Each entry specifies
// a display name, the action string (passed to timeline_action/playback_action),
// a category for grouping, a keyboard shortcut hint, and search keywords.
// The `add` block is just syntactic sugar so each registration fits on one line.
//

- (void)registerCommands {
    NSMutableArray<SpliceKitCommand *> *cmds = [NSMutableArray array];

    // Helper to create and register a command in one line
    void (^add)(NSString *, NSString *, NSString *, SpliceKitCommandCategory, NSString *, NSString *, NSString *, NSArray *) =
        ^(NSString *name, NSString *action, NSString *type, SpliceKitCommandCategory cat,
          NSString *catName, NSString *shortcut, NSString *detail, NSArray *keywords) {
        SpliceKitCommand *cmd = [[SpliceKitCommand alloc] init];
        cmd.name = name;
        cmd.action = action;
        cmd.type = type;
        cmd.category = cat;
        cmd.categoryName = catName;
        cmd.shortcut = shortcut ?: @"";
        cmd.detail = detail ?: @"";
        cmd.keywords = keywords ?: @[];
        [cmds addObject:cmd];
    };

    // --- Editing ---
    add(@"Blade", @"blade", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+B", @"Split clip at playhead", @[@"cut", @"split", @"razor"]);
    add(@"Blade All", @"bladeAll", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Split all clips at playhead", @[@"cut all", @"split all"]);
    add(@"Delete", @"delete", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Delete", @"Remove selected clip (ripple)", @[@"remove", @"ripple delete"]);
    add(@"Cut", @"cut", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+X", @"Cut selected to clipboard", @[]);
    add(@"Copy", @"copy", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+C", @"Copy selected to clipboard", @[]);
    add(@"Paste", @"paste", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+V", @"Paste from clipboard", @[]);
    add(@"Undo", @"undo", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+Z", @"Undo last action", @[@"revert"]);
    add(@"Redo", @"redo", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+Shift+Z", @"Redo last undone action", @[]);
    add(@"Select All", @"selectAll", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Cmd+A", @"Select all clips", @[]);
    add(@"Deselect All", @"deselectAll", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Clear selection", @[@"unselect"]);
    add(@"Select Clip at Playhead", @"selectClipAtPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Select the clip under playhead", @[@"select current"]);
    add(@"Select to Playhead", @"selectToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Extend selection to playhead", @[]);
    add(@"Trim to Playhead", @"trimToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Opt+]", @"Trim clip end to playhead position", @[@"shorten"]);
    add(@"Extend Edit to Playhead", @"extendEditToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Extend edit point to playhead", @[]);
    add(@"Insert Gap", @"insertGap", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Insert gap at playhead", @[@"space", @"blank"]);
    add(@"Insert Placeholder", @"insertPlaceholder", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Insert placeholder storyline", @[]);
    add(@"Solo", @"solo", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Solo selected clips", @[@"isolate"]);
    add(@"Disable", @"disable", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"V", @"Disable/enable selected clips", @[@"mute", @"toggle"]);
    add(@"Create Compound Clip", @"createCompoundClip", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Nest selected clips into compound", @[@"nest", @"group"]);

    // --- Navigation ---
    add(@"Next Edit Point", @"nextEdit", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Down", @"Move to next edit point", @[@"next cut"]);
    add(@"Previous Edit Point", @"previousEdit", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Up", @"Move to previous edit point", @[@"prev cut"]);

    // --- Playback ---
    add(@"Play / Pause", @"playPause", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Space", @"Toggle playback", @[@"stop", @"start"]);
    add(@"Go to Start", @"goToStart", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Home", @"Jump to beginning of timeline", @[@"beginning", @"rewind"]);
    add(@"Go to End", @"goToEnd", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"End", @"Jump to end of timeline", @[]);
    add(@"Next Frame", @"nextFrame", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Right", @"Step forward one frame", @[@"forward"]);
    add(@"Previous Frame", @"prevFrame", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Left", @"Step backward one frame", @[@"backward", @"back"]);
    add(@"Forward 10 Frames", @"nextFrame10", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Shift+Right", @"Jump forward 10 frames", @[]);
    add(@"Back 10 Frames", @"prevFrame10", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Shift+Left", @"Jump backward 10 frames", @[]);

    // --- Color Correction ---
    add(@"Add Color Board", @"addColorBoard", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Color Board effect to selected clip", @[@"color correction", @"grade"]);
    add(@"Add Color Wheels", @"addColorWheels", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Color Wheels effect", @[@"color correction"]);
    add(@"Add Color Curves", @"addColorCurves", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Color Curves effect", @[@"rgb curves"]);
    add(@"Add Color Adjustment", @"addColorAdjustment", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Color Adjustment controls", @[@"brightness", @"contrast", @"saturation"]);
    add(@"Add Hue/Saturation", @"addHueSaturation", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add Hue/Saturation curves", @[@"hsl"]);
    add(@"Enhance Light and Color", @"addEnhanceLightAndColor", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Auto-enhance lighting and color", @[@"auto color", @"magic"]);

    // --- Speed / Retiming ---
    add(@"Normal Speed (100%)", @"retimeNormal", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Reset to normal speed", @[@"retime", @"1x"]);
    add(@"Fast 2x", @"retimeFast2x", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Double speed", @[@"200%", @"speed up"]);
    add(@"Fast 4x", @"retimeFast4x", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"4x speed", @[@"400%"]);
    add(@"Fast 8x", @"retimeFast8x", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"8x speed", @[@"800%"]);
    add(@"Fast 20x", @"retimeFast20x", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"20x speed", @[@"2000%"]);
    add(@"Slow 50%", @"retimeSlow50", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Half speed", @[@"slow motion", @"slow mo"]);
    add(@"Slow 25%", @"retimeSlow25", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Quarter speed", @[@"slow motion"]);
    add(@"Slow 10%", @"retimeSlow10", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"1/10 speed", @[@"super slow"]);
    add(@"Reverse", @"retimeReverse", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Reverse playback direction", @[@"backwards"]);
    add(@"Hold Frame", @"retimeHold", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Hold current frame", @[@"freeze"]);
    add(@"Freeze Frame", @"freezeFrame", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Create a freeze frame", @[@"still"]);
    add(@"Blade Speed", @"retimeBladeSpeed", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Split speed segment", @[]);

    // --- Markers ---
    add(@"Add Marker", @"addMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", @"M", @"Add standard marker at playhead", @[@"mark"]);
    add(@"Add To-Do Marker", @"addTodoMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Add to-do marker", @[@"task"]);
    add(@"Add Chapter Marker", @"addChapterMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Add chapter marker for export", @[@"chapter"]);
    add(@"Delete Marker", @"deleteMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Remove marker at playhead", @[]);
    add(@"Delete All Markers", @"deleteMarkersInSelection", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Remove all markers in selection (select all first)", @[@"remove all markers", @"clear markers"]);
    add(@"Next Marker", @"nextMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Go to next marker", @[]);
    add(@"Previous Marker", @"previousMarker", @"timeline", SpliceKitCommandCategoryMarkers, @"Markers", nil, @"Go to previous marker", @[]);

    // --- Transitions ---
    add(@"Add Default Transition", @"addTransition", @"timeline", SpliceKitCommandCategoryEffects, @"Transitions", @"Cmd+T", @"Add default transition (Cross Dissolve)", @[@"cross dissolve", @"fade"]);
    add(@"Add Default Transition to All Clips", @"addTransitionToAll", @"timeline", SpliceKitCommandCategoryEffects, @"Transitions", nil, @"Add default transition between every clip on the timeline", @[@"transition all", @"cross dissolve all", @"fade all", @"transition every"]);
    add(@"Browse Transitions...", @"browseTransitions", @"transition_browse", SpliceKitCommandCategoryEffects, @"Transitions", nil, @"Search and apply a specific transition by name", @[@"find transition", @"list transitions"]);
    add(@"Browse Effects...", @"browseEffects", @"effect_browse", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Search and apply an effect by name", @[@"find effect", @"filter", @"plugin"]);
    add(@"Browse Generators...", @"browseGenerators", @"generator_browse", SpliceKitCommandCategoryEffects, @"Generators", nil, @"Search and apply a generator", @[@"background", @"solid"]);
    add(@"Browse Titles...", @"browseTitles", @"title_browse", SpliceKitCommandCategoryTitles, @"Titles", nil, @"Search and apply a title template", @[@"text", @"lower third"]);
    add(@"Browse Favorites...", @"browseFavorites", @"favorites_browse", SpliceKitCommandCategoryEffects, @"Favorites", nil, @"View all favorited effects, transitions, and generators", @[@"starred", @"pinned", @"bookmarks"]);

    // --- Titles ---
    add(@"Add Basic Title", @"addBasicTitle", @"timeline", SpliceKitCommandCategoryTitles, @"Titles", nil, @"Insert basic title at playhead", @[@"text"]);
    add(@"Add Lower Third", @"addBasicLowerThird", @"timeline", SpliceKitCommandCategoryTitles, @"Titles", nil, @"Insert lower third title", @[@"name plate", @"super"]);

    // --- Volume ---
    add(@"Volume Up", @"adjustVolumeUp", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Increase clip volume", @[@"louder"]);
    add(@"Volume Down", @"adjustVolumeDown", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Decrease clip volume", @[@"quieter", @"softer"]);

    // --- Keyframes ---
    add(@"Add Keyframe", @"addKeyframe", @"timeline", SpliceKitCommandCategoryKeyframes, @"Keyframes", nil, @"Add keyframe at playhead", @[@"animation"]);
    add(@"Delete Keyframes", @"deleteKeyframes", @"timeline", SpliceKitCommandCategoryKeyframes, @"Keyframes", nil, @"Remove keyframes from selection", @[]);
    add(@"Remove All Keyframes From Clip", @"removeAllKeyframesFromClip", @"timeline", SpliceKitCommandCategoryKeyframes, @"Keyframes", nil, @"Clear every keyframed channel on the selected clip", @[@"clear all keyframes", @"remove keyframe animation", @"reset animation"]);
    add(@"Next Keyframe", @"nextKeyframe", @"timeline", SpliceKitCommandCategoryKeyframes, @"Keyframes", nil, @"Go to next keyframe", @[]);
    add(@"Previous Keyframe", @"previousKeyframe", @"timeline", SpliceKitCommandCategoryKeyframes, @"Keyframes", nil, @"Go to previous keyframe", @[]);

    // --- Export ---
    add(@"Export FCPXML", @"exportXML", @"timeline", SpliceKitCommandCategoryExport, @"Export", nil, @"Export timeline as FCPXML", @[@"xml"]);
    add(@"Share Selection", @"shareSelection", @"timeline", SpliceKitCommandCategoryExport, @"Export", nil, @"Share/export selected range", @[@"render"]);
    add(@"Batch Export", @"batchExport", @"batch_export", SpliceKitCommandCategoryExport, @"Export", nil, @"Export each clip individually using default share destination", @[@"batch", @"export all", @"individual"]);
    add(@"Auto Reframe", @"autoReframe", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Auto-reframe for different aspect ratios", @[@"crop", @"aspect"]);
    add(@"Stabilize Subject", @"stabilize_subject", @"subject_stabilize", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Lock camera onto a subject — keeps it fixed while background moves", @[@"lock on", @"track", @"stabilize", @"pin", @"follow", @"steady"]);

    // --- Generators ---
    add(@"Add Generator", @"addVideoGenerator", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Add a video generator", @[@"background"]);

    // ===================================================================
    // Extended commands (~100 additional everyday editing actions)
    // ===================================================================

    // --- Timeline View ---
    add(@"Zoom to Fit", @"zoomToFit", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Shift+Z", @"Fit entire timeline in view", @[@"fit", @"overview"]);
    add(@"Zoom In", @"zoomIn", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+=", @"Zoom into timeline", @[@"magnify", @"closer"]);
    add(@"Zoom Out", @"zoomOut", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+-", @"Zoom out of timeline", @[@"wider"]);
    add(@"Toggle Snapping", @"toggleSnapping", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"N", @"Enable/disable magnetic snapping", @[@"snap", @"magnet"]);
    add(@"Toggle Skimming", @"toggleSkimming", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"S", @"Enable/disable skimming preview", @[@"skim", @"hover"]);
    add(@"Toggle Timeline Index", @"toggleTimelineIndex", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+Shift+2", @"Show/hide the timeline index panel", @[@"index", @"sidebar", @"clips list"]);
    add(@"Toggle Inspector", @"toggleInspector", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+4", @"Show/hide the inspector panel", @[@"properties", @"parameters"]);
    add(@"Toggle Event Viewer", @"toggleEventViewer", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show/hide the event viewer", @[@"dual viewer", @"source"]);
    add(@"Toggle Timeline", @"toggleTimeline", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show/hide the timeline panel", @[]);

    // --- Clip Operations ---
    add(@"Detach Audio", @"detachAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Separate audio from selected clip", @[@"split audio", @"unlink"]);
    add(@"Break Apart Clip Items", @"breakApartClipItems", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"Cmd+Shift+G", @"Break compound or multicam into individual clips", @[@"ungroup", @"flatten", @"decompose"]);
    add(@"Lift from Storyline", @"liftFromPrimaryStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Lift selected clip from primary storyline", @[@"extract"]);
    add(@"Overwrite to Primary", @"overwriteToPrimaryStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Overwrite clip onto primary storyline", @[@"stamp"]);
    add(@"Connect to Primary", @"connectClipToPrimaryStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"Q", @"Connect selected clip to primary storyline", @[@"attach"]);
    add(@"Insert at Playhead", @"insertClipAtPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"W", @"Insert clip at playhead position", @[@"splice"]);
    add(@"Append to Storyline", @"appendToStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"E", @"Append clip to end of storyline", @[@"add to end"]);
    add(@"Replace with Gap", @"replaceWithGap", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Replace selected clip with gap (no ripple)", @[@"lift", @"remove in place"]);
    add(@"Create Storyline", @"createStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"Cmd+G", @"Group connected clips into a storyline", @[@"group", @"storyline"]);
    add(@"Synchronize Clips", @"synchronizeClips", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Sync clips by audio waveform or timecode", @[@"sync", @"multicam"]);
    add(@"Create Audition", @"createAudition", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Create audition from selected clips", @[@"audition", @"alternatives"]);
    add(@"Expand Audio / Video", @"expandAudioVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Expand audio and video into separate lanes", @[@"split components"]);
    add(@"Expand Audio Components", @"expandAudioComponents", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Expand audio into individual channel components", @[@"channels", @"mono"]);
    add(@"Collapse to Clip", @"collapseToClip", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Collapse expanded audio/video back to single clip", @[@"collapse"]);
    add(@"Reference New Parent Clip", @"referenceNewParentClip", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Re-link clip to a new source", @[@"relink", @"reconnect"]);

    // --- Selection & Navigation ---
    add(@"Nudge Left", @"nudgeLeft", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @",", @"Move selected clip left by one frame", @[@"shift left", @"move left"]);
    add(@"Nudge Right", @"nudgeRight", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @".", @"Move selected clip right by one frame", @[@"shift right", @"move right"]);
    add(@"Nudge Left 10 Frames", @"nudgeLeftBig", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Shift+,", @"Move selected clip left by 10 frames", @[@"shift left big"]);
    add(@"Nudge Right 10 Frames", @"nudgeRightBig", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Shift+.", @"Move selected clip right by 10 frames", @[@"shift right big"]);
    add(@"Nudge Up", @"nudgeUp", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Opt+Cmd+Up", @"Move selected clip to lane above", @[@"lane up"]);
    add(@"Nudge Down", @"nudgeDown", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Opt+Cmd+Down", @"Move selected clip to lane below", @[@"lane down"]);
    add(@"Go to Range Start", @"goToRangeStart", @"playback", SpliceKitCommandCategoryPlayback, @"Navigation", @"Shift+I", @"Jump playhead to start of range selection", @[@"in point"]);
    add(@"Go to Range End", @"goToRangeEnd", @"playback", SpliceKitCommandCategoryPlayback, @"Navigation", @"Shift+O", @"Jump playhead to end of range selection", @[@"out point"]);
    add(@"Set Range Start", @"setRangeStart", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"I", @"Set start point of range selection", @[@"in point", @"mark in"]);
    add(@"Set Range End", @"setRangeEnd", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"O", @"Set end point of range selection", @[@"out point", @"mark out"]);
    add(@"Clear Range", @"clearRange", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"Opt+X", @"Remove range selection", @[@"deselect range"]);

    // --- Audio ---
    add(@"Remove Silences", @"removeSilences", @"silence_options", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Detect and remove silent segments from timeline", @[@"silence", @"quiet", @"dead air", @"gap", @"pause", @"mute"]);
    add(@"Audio Fade In", @"addAudioFadeIn", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Add audio fade-in to selected clip", @[@"ramp up"]);
    add(@"Audio Fade Out", @"addAudioFadeOut", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Add audio fade-out to selected clip", @[@"ramp down"]);
    add(@"Mute Audio", @"toggleMuteAudio", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", @"Ctrl+Opt+M", @"Mute/unmute audio on selected clip or clip at playhead", @[@"mute", @"silence", @"audio off", @"toggle audio", @"unmute"]);
    add(@"Audio Enhancements", @"showAudioEnhancements", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Open audio enhancement controls", @[@"eq", @"noise removal", @"loudness"]);
    add(@"Audio Match", @"matchAudio", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Match audio levels between clips", @[@"normalize"]);

    // --- Effects & Color ---
    add(@"Remove Effects", @"removeEffects", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Remove all effects from selected clip", @[@"clear effects", @"strip"]);
    add(@"Copy Effects", @"copyEffects", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Copy effects from selected clip", @[@"copy grade"]);
    add(@"Paste Effects", @"pasteEffects", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Paste effects onto selected clip", @[@"apply grade"]);
    add(@"Paste Attributes", @"pasteAttributes", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", @"Cmd+Shift+V", @"Choose which attributes to paste", @[@"selective paste"]);
    add(@"Match Color", @"matchColor", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Match color grading between clips", @[@"color match"]);
    add(@"Balance Color", @"balanceColor", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Auto-balance color of selected clip", @[@"auto color", @"white balance"]);
    add(@"Show Color Inspector", @"showColorInspector", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Open color correction inspector", @[@"color grading", @"color panel"]);
    add(@"Reset Effect Parameters", @"resetAllParameters", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Reset all parameters to default values", @[@"defaults", @"clear"]);

    // --- Rendering ---
    add(@"Render Selection", @"renderSelection", @"timeline", SpliceKitCommandCategoryExport, @"Render", @"Ctrl+R", @"Render selected portion of timeline", @[@"process"]);
    add(@"Render All", @"renderAll", @"timeline", SpliceKitCommandCategoryExport, @"Render", nil, @"Render entire timeline", @[@"process all"]);
    add(@"Delete Render Files", @"deleteRenderFiles", @"timeline", SpliceKitCommandCategoryExport, @"Render", nil, @"Delete generated render files to free space", @[@"clean", @"clear cache"]);

    // --- Stabilization & Analysis ---
    add(@"Analyze and Fix", @"analyzeAndFix", @"timeline", SpliceKitCommandCategoryEffects, @"Analysis", nil, @"Analyze clip for problems and fix automatically", @[@"stabilize", @"rolling shutter", @"repair"]);
    add(@"Detect Scene Changes", @"sceneDetect", @"scene_options", SpliceKitCommandCategoryEditing, @"Analysis", nil, @"Find cuts/scene changes and mark or blade them", @[@"shot boundary", @"find cuts", @"scene detection", @"auto marker", @"mark cuts", @"auto cut", @"split at cuts"]);

    // --- Trim & Precision Editing ---
    add(@"Roll Edit Left", @"rollEditLeft", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Roll the edit point one frame left", @[@"trim"]);
    add(@"Roll Edit Right", @"rollEditRight", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Roll the edit point one frame right", @[@"trim"]);
    add(@"Slip Left", @"slipLeft", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Slip clip content one frame left", @[@"slide content"]);
    add(@"Slip Right", @"slipRight", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Slip clip content one frame right", @[@"slide content"]);
    add(@"Ripple Trim Start to Playhead", @"rippleTrimStartToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Ripple-trim clip start to playhead", @[@"top"]);
    add(@"Ripple Trim End to Playhead", @"rippleTrimEndToPlayhead", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Ripple-trim clip end to playhead", @[@"tail"]);

    // --- Multicam ---
    add(@"Switch Angle 1", @"switchAngle01", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Switch to camera angle 1", @[@"cam 1"]);
    add(@"Switch Angle 2", @"switchAngle02", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Switch to camera angle 2", @[@"cam 2"]);
    add(@"Switch Angle 3", @"switchAngle03", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Switch to camera angle 3", @[@"cam 3"]);
    add(@"Switch Angle 4", @"switchAngle04", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Switch to camera angle 4", @[@"cam 4"]);
    add(@"Cut and Switch Angle 1", @"cutAndSwitchAngle01", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Blade and switch to angle 1", @[@"cut cam 1"]);
    add(@"Cut and Switch Angle 2", @"cutAndSwitchAngle02", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Blade and switch to angle 2", @[@"cut cam 2"]);
    add(@"Cut and Switch Angle 3", @"cutAndSwitchAngle03", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Blade and switch to angle 3", @[@"cut cam 3"]);
    add(@"Cut and Switch Angle 4", @"cutAndSwitchAngle04", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Blade and switch to angle 4", @[@"cut cam 4"]);
    add(@"Create Multicam Clip", @"createMulticamClip", @"timeline", SpliceKitCommandCategoryEditing, @"Multicam", nil, @"Create multicam clip from selected", @[@"multicamera"]);

    // --- Playback Modes ---
    add(@"Play Around Current", @"playAroundCurrent", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Shift+?", @"Play around the current playhead position", @[@"review"]);
    add(@"Play Selection", @"playSelection", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"/", @"Play the selected range", @[@"preview range"]);
    add(@"Play Full Screen", @"playFullScreen", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Cmd+Shift+F", @"Play timeline in full screen mode", @[@"cinema", @"presentation"]);
    add(@"Loop Playback", @"toggleLoopPlayback", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"Cmd+L", @"Toggle loop playback on/off", @[@"repeat"]);
    add(@"Play Reverse", @"playReverse", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"J", @"Play in reverse", @[@"backwards", @"rewind"]);
    add(@"Play Forward 2x", @"playForward2x", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"L L", @"Play forward at double speed", @[@"fast forward"]);

    // --- Project & Library ---
    add(@"New Project", @"newProject", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Cmd+N", @"Create a new project in the current event", @[@"new timeline"]);
    add(@"New Event", @"newEvent", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Create a new event in the library", @[]);
    add(@"Import Media", @"importMedia", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Cmd+I", @"Open the import media dialog", @[@"add files", @"ingest"]);
    add(@"Import URL to Library", @"import_only", @"url_import_prompt", SpliceKitCommandCategoryExport, @"Project", nil, @"Download a remote video URL and import it into the current library/event", @[@"import from url", @"download url", @"web video", @"remote media", @"youtube url", @"vimeo url"]);
    add(@"Import URL to Timeline", @"insert_at_playhead", @"url_import_prompt", SpliceKitCommandCategoryExport, @"Project", nil, @"Download a remote video URL, import it, and place it in the active timeline", @[@"add url to timeline", @"download and insert", @"append url"]);
    add(@"Show Project Properties", @"showProjectProperties", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"View resolution, frame rate, and codec settings", @[@"settings", @"format"]);
    add(@"Consolidate Library Media", @"consolidateMedia", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Copy external media into the library", @[@"collect", @"gather"]);

    // --- Organization & Rating ---
    add(@"Favorite", @"rateAsFavorite", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", @"F", @"Mark selected clip as favorite", @[@"like", @"star", @"keep"]);
    add(@"Reject", @"rateAsReject", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", @"Delete", @"Mark selected clip as rejected", @[@"dislike", @"bad"]);
    add(@"Remove Rating", @"removeRating", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", @"U", @"Clear favorite/reject rating", @[@"unrate"]);
    add(@"Remove All Ratings", @"removeAllRatings", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", nil, @"Clear all ratings in selection", @[@"reset ratings"]);

    // --- Roles ---
    add(@"Show Role Editor", @"showRoleEditor", @"timeline", SpliceKitCommandCategoryEditing, @"Roles", nil, @"Open the role assignment editor", @[@"roles", @"subroles"]);
    add(@"Assign Default Video Role", @"assignDefaultVideoRole", @"timeline", SpliceKitCommandCategoryEditing, @"Roles", nil, @"Assign default video role to clip", @[@"video role"]);
    add(@"Assign Default Audio Role", @"assignDefaultAudioRole", @"timeline", SpliceKitCommandCategoryEditing, @"Roles", nil, @"Assign default audio role to clip", @[@"audio role"]);

    // --- Captions & Subtitles ---
    add(@"Add Caption", @"addCaption", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Add caption at playhead position", @[@"subtitle", @"text"]);
    add(@"Duplicate Caption", @"duplicateCaption", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Duplicate the selected caption", @[@"copy caption"]);
    add(@"Import Captions", @"importCaptions", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Import captions from SRT/ITT file", @[@"subtitles", @"srt"]);

    // --- Transform & Spatial ---
    add(@"Transform", @"showTransformControls", @"timeline", SpliceKitCommandCategoryEffects, @"Transform", nil, @"Show on-screen transform controls", @[@"position", @"scale", @"rotate"]);
    add(@"Crop", @"showCropControls", @"timeline", SpliceKitCommandCategoryEffects, @"Transform", @"Shift+C", @"Show crop controls on viewer", @[@"trim edges", @"ken burns"]);
    add(@"Distort", @"showDistortControls", @"timeline", SpliceKitCommandCategoryEffects, @"Transform", nil, @"Show corner-pin distort controls", @[@"perspective", @"corner pin"]);

    // --- Clip Appearance ---
    add(@"Increase Clip Height", @"increaseClipHeight", @"timeline", SpliceKitCommandCategoryEditing, @"Appearance", @"Cmd+Shift+=", @"Make timeline clips taller", @[@"bigger", @"larger waveform"]);
    add(@"Decrease Clip Height", @"decreaseClipHeight", @"timeline", SpliceKitCommandCategoryEditing, @"Appearance", @"Cmd+Shift+-", @"Make timeline clips shorter", @[@"smaller", @"compact"]);
    add(@"Show Clip Names", @"showClipNames", @"timeline", SpliceKitCommandCategoryEditing, @"Appearance", nil, @"Toggle clip name display on timeline", @[@"labels"]);
    add(@"Show Audio Waveforms", @"toggleClipAppearanceAudioWaveformsAction", @"timeline", SpliceKitCommandCategoryEditing, @"Appearance", nil, @"Toggle audio waveform display", @[@"waveform"]);

    // --- Compound & Nesting ---
    add(@"Open in Timeline", @"openInTimeline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Open compound/multicam clip in its own timeline", @[@"dive in", @"enter"]);
    add(@"Back to Parent", @"backToParent", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Return to the parent timeline", @[@"go back", @"exit compound"]);

    // --- Dual Timeline ---
    add(@"Open Secondary Timeline", @"open", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Open a floating second timeline window with the primary sequence", @[@"dual timeline", @"second timeline", @"two timelines", @"secondary pane"]);
    add(@"Clone Primary Root to Secondary", @"syncRoot", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Load the primary sequence into the secondary window and match the current root", @[@"clone root", @"sync root", @"match compound", @"same root"]);
    add(@"Open Selection in Secondary", @"openSelectedInSecondary", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Open the selected compound or multicam item in the secondary timeline", @[@"open selected compound", @"secondary compound", @"open on other side"]);
    add(@"Focus Primary Timeline", @"focusPrimary", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Route commands back to the main timeline window", @[@"focus main timeline", @"primary pane"]);
    add(@"Focus Secondary Timeline", @"focusSecondary", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Route commands to the floating secondary timeline window", @[@"focus second timeline", @"secondary pane"]);
    add(@"Close Secondary Timeline", @"close", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Close the floating secondary timeline window", @[@"close second timeline", @"remove dual timeline"]);
    add(@"Toggle Secondary Browser", @"toggleSecondaryBrowser", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Show or hide the Browser in the secondary timeline window", @[@"secondary browser", @"second browser"]);
    add(@"Toggle Secondary Timeline Index", @"toggleSecondaryTimelineIndex", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Show or hide the Timeline Index in the secondary timeline window", @[@"secondary timeline index", @"second index"]);
    add(@"Toggle Secondary Audio Meters", @"toggleSecondaryAudioMeters", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Show or hide Audio Meters in the secondary timeline window", @[@"secondary audio meters", @"second meters"]);
    add(@"Toggle Secondary Effects Browser", @"toggleSecondaryEffectsBrowser", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Show or hide the Effects browser in the secondary timeline window", @[@"secondary effects", @"second effects"]);
    add(@"Toggle Secondary Transitions Browser", @"toggleSecondaryTransitionsBrowser", @"dual_timeline", SpliceKitCommandCategoryEditing, @"Dual Timeline", nil, @"Show or hide the Transitions browser in the secondary timeline window", @[@"secondary transitions", @"second transitions"]);

    // --- Snapping & Guides ---
    add(@"Snapping On", @"toggleSnappingUp", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Force snapping on", @[@"snap on"]);
    add(@"Snapping Off", @"toggleSnappingDown", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Force snapping off", @[@"snap off"]);
    add(@"Skimming On", @"toggleSkimmingUp", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Force skimming on", @[@"skim on"]);
    add(@"Skimming Off", @"toggleSkimmingDown", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Force skimming off", @[@"skim off"]);

    // --- Transcript ---
    add(@"Open Transcript Editor", @"openTranscript", @"transcript", SpliceKitCommandCategoryTranscript, @"Transcript", @"Ctrl+Opt+T", @"Open transcript-based editing panel", @[@"speech", @"captions"]);
    add(@"Close Transcript Editor", @"closeTranscript", @"transcript", SpliceKitCommandCategoryTranscript, @"Transcript", nil, @"Close the transcript panel", @[]);

    // --- Social Captions ---
    add(@"Social Captions", @"openCaptions", @"captions", SpliceKitCommandCategoryTitles, @"Captions", @"Ctrl+Opt+C", @"Open social captions panel with auto-transcription", @[@"subtitle", @"tiktok", @"reels", @"highlight"]);
    add(@"Close Social Captions", @"closeCaptions", @"captions", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Close the social captions panel", @[]);

    // --- Audio Mixer ---
    add(@"Audio Mixer", @"openMixer", @"mixer", SpliceKitCommandCategoryEditing, @"Audio", @"Ctrl+Opt+M", @"Open audio mixer with volume faders for clips at playhead", @[@"fader", @"volume", @"mix", @"levels"]);
    add(@"Close Audio Mixer", @"closeMixer", @"mixer", SpliceKitCommandCategoryEditing, @"Audio", nil, @"Close the audio mixer panel", @[]);

    // --- LiveCam ---
    add(@"Open LiveCam", @"openLiveCam", @"livecam", SpliceKitCommandCategoryExport, @"LiveCam", nil, @"Open the native webcam booth for direct-to-Library or direct-to-Timeline capture", @[@"camera", @"webcam", @"record to timeline", @"reaction cam", @"live booth"]);
    add(@"Close LiveCam", @"closeLiveCam", @"livecam", SpliceKitCommandCategoryExport, @"LiveCam", nil, @"Close the LiveCam panel", @[@"hide camera", @"close webcam"]);

    // ===================================================================
    // NEW: Comprehensive MCP actions added to command palette
    // ===================================================================

    // --- Edit Modes ---
    add(@"Paste as Connected Clip", @"pasteAsConnected", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", @"Ctrl+V", @"Paste clipboard as connected clip", @[@"paste anchored"]);
    add(@"Copy Timecode", @"copyTimecode", @"timeline", SpliceKitCommandCategoryEditing, @"Editing", nil, @"Copy current timecode to clipboard", @[@"timecode"]);
    add(@"Connect Edit (Audio Only)", @"connectEditAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Connect only audio to primary storyline", @[@"audio only"]);
    add(@"Connect Edit (Video Only)", @"connectEditVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Connect only video to primary storyline", @[@"video only"]);
    add(@"Insert Edit (Audio Only)", @"insertEditAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Insert only audio", @[@"audio only insert"]);
    add(@"Insert Edit (Video Only)", @"insertEditVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Insert only video", @[@"video only insert"]);
    add(@"Append Edit (Audio Only)", @"appendEditAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Append only audio", @[@"audio only append"]);
    add(@"Append Edit (Video Only)", @"appendEditVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Append only video", @[@"video only append"]);
    add(@"Overwrite Edit (Audio Only)", @"overwriteEditAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Overwrite only audio", @[@"audio only overwrite"]);
    add(@"Overwrite Edit (Video Only)", @"overwriteEditVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Overwrite only video", @[@"video only overwrite"]);
    add(@"AV Edit Mode: Audio", @"avEditModeAudio", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Switch to audio-only editing mode", @[@"audio mode"]);
    add(@"AV Edit Mode: Video", @"avEditModeVideo", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Switch to video-only editing mode", @[@"video mode"]);
    add(@"AV Edit Mode: Both", @"avEditModeBoth", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Switch to audio+video editing mode", @[@"av mode", @"both"]);
    add(@"Replace from Start", @"replaceFromStart", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Replace clip from start", @[@"replace edit"]);
    add(@"Replace from End", @"replaceFromEnd", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Replace clip from end", @[@"replace edit backtimed"]);
    add(@"Replace Whole Clip", @"replaceWhole", @"timeline", SpliceKitCommandCategoryEditing, @"Edit Modes", nil, @"Replace entire clip", @[@"swap"]);

    // --- Trim Extras ---
    add(@"Trim Start", @"trimStart", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", @"Opt+[", @"Trim clip start to playhead", @[@"head trim"]);
    add(@"Trim End", @"trimEnd", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", @"Opt+]", @"Trim clip end to playhead", @[@"tail trim"]);
    add(@"Join Through Edit", @"joinClips", @"timeline", SpliceKitCommandCategoryEditing, @"Trim", nil, @"Join clips at edit point (remove through edit)", @[@"heal", @"join edit"]);
    add(@"Set Clip Range", @"setClipRange", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", @"X", @"Set range to clip boundaries", @[@"select clip range"]);
    add(@"Collapse to Connected Storyline", @"collapseToConnectedStoryline", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Collapse selection to connected storyline", @[@"collapse connected"]);

    // --- Speed Extras ---
    add(@"Custom Speed", @"retimeCustomSpeed", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Set custom speed percentage", @[@"retime custom"]);
    add(@"Instant Replay 50%", @"retimeInstantReplayHalf", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Instant replay at half speed", @[@"replay"]);
    add(@"Instant Replay 25%", @"retimeInstantReplayQuarter", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Instant replay at quarter speed", @[@"slow replay"]);
    add(@"Reset Speed", @"retimeReset", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Remove all retiming from clip", @[@"clear retime"]);
    add(@"Speed Ramp to Zero", @"retimeSpeedRampToZero", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Ramp speed down to freeze", @[@"speed ramp", @"slow down"]);
    add(@"Speed Ramp from Zero", @"retimeSpeedRampFromZero", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Ramp speed up from freeze", @[@"speed ramp", @"speed up"]);
    add(@"Optical Flow", @"retimeOpticalFlow", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Set retime quality to Optical Flow", @[@"high quality retime"]);
    add(@"Frame Blending", @"retimeFrameBlending", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Set retime quality to Frame Blending", @[@"smooth transition"]);
    add(@"Floor Frame (Nearest)", @"retimeFloorFrame", @"timeline", SpliceKitCommandCategorySpeed, @"Speed", nil, @"Set retime quality to nearest frame", @[@"floor frame"]);

    // --- Audio Extras ---
    add(@"Add Channel EQ", @"addChannelEQ", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Add Channel EQ effect", @[@"equalizer"]);
    add(@"Enhance Audio", @"enhanceAudio", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Apply audio enhancement", @[@"audio fix"]);
    add(@"Align Audio to Video", @"alignAudioToVideo", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Synchronize audio to video", @[@"sync audio"]);
    add(@"Mute Volume", @"volumeMute", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Set volume to -infinity (mute)", @[@"silence", @"mute"]);
    add(@"Apply Audio Fades", @"applyAudioFades", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Apply fade in/out to audio", @[@"crossfade"]);
    add(@"Add Default Audio Effect", @"addDefaultAudioEffect", @"timeline", SpliceKitCommandCategoryEffects, @"Audio", nil, @"Add default audio effect", @[@"audio plugin"]);
    add(@"Add Default Video Effect", @"addDefaultVideoEffect", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Add default video effect to selected clip", @[@"video plugin"]);

    // --- Color Extras ---
    add(@"Next Color Effect", @"nextColorEffect", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Go to next color correction", @[@"next grade"]);
    add(@"Previous Color Effect", @"previousColorEffect", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Go to previous color correction", @[@"prev grade"]);
    add(@"Reset Color Board", @"resetColorBoard", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Reset color board pucks to center", @[@"clear color"]);
    add(@"Toggle All Color Off", @"toggleAllColorOff", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Disable/enable all color corrections", @[@"bypass color"]);
    add(@"Add Magnetic Mask", @"addMagneticMask", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Add AI magnetic mask to clip", @[@"object mask", @"isolation"]);
    add(@"Smart Conform", @"smartConform", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Auto-reframe clip for project resolution", @[@"auto crop", @"reframe"]);

    // --- Show/Hide Editors ---
    add(@"Show Video Animation", @"showVideoAnimation", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Ctrl+V", @"Show/hide video animation editor", @[@"keyframe editor"]);
    add(@"Show Audio Animation", @"showAudioAnimation", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Ctrl+A", @"Show/hide audio animation editor", @[@"audio keyframes"]);
    add(@"Solo Animation", @"soloAnimation", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Collapse animation to single lane", @[@"collapse animation"]);
    add(@"Show Tracking Editor", @"showTrackingEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show object tracking editor", @[@"tracker"]);
    add(@"Show Cinematic Editor", @"showCinematicEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show cinematic mode editor", @[@"depth", @"focus"]);
    add(@"Show Magnetic Mask Editor", @"showMagneticMaskEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show magnetic mask editor", @[@"mask editor"]);
    add(@"Enable Beat Detection", @"enableBeatDetection", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Detect beats in audio", @[@"rhythm", @"music"]);
    add(@"Toggle Precision Editor", @"togglePrecisionEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show/hide precision trim editor", @[@"detailed trim"]);
    add(@"Show Audio Lanes", @"showAudioLanes", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show audio lanes in timeline", @[@"audio tracks"]);
    add(@"Expand Subroles", @"expandSubroles", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Expand subrole lanes in timeline", @[@"role lanes"]);
    add(@"Show Duplicate Ranges", @"showDuplicateRanges", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Highlight duplicate clip ranges", @[@"duplicates"]);
    add(@"Show Keyword Editor", @"showKeywordEditor", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+K", @"Open keyword editor panel", @[@"tags"]);

    // --- View Extras ---
    add(@"Vertical Zoom to Fit", @"verticalZoomToFit", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Fit timeline vertically", @[@"vertical fit"]);
    add(@"Zoom to Samples", @"zoomToSamples", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Zoom to audio sample level", @[@"waveform zoom"]);
    add(@"Toggle Clip Skimming", @"toggleClipSkimming", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Enable/disable clip skimming", @[@"item skim"]);
    add(@"Toggle Audio Skimming", @"toggleAudioSkimming", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Opt+S", @"Enable/disable audio preview during skimming", @[@"audio skim", @"scrub audio"]);
    add(@"Toggle Inspector Height", @"toggleInspectorHeight", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Toggle inspector panel height", @[@"tall inspector"]);
    add(@"Beat Detection Grid", @"beatDetectionGrid", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Toggle beat detection grid overlay", @[@"beat grid"]);
    add(@"Timeline Scrolling", @"timelineScrolling", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Toggle timeline auto-scrolling mode", @[@"scroll mode"]);
    add(@"Enter Full Screen", @"enterFullScreen", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Ctrl+Cmd+F", @"Enter full screen mode", @[@"maximize"]);
    add(@"Timeline History Back", @"timelineHistoryBack", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+[", @"Go back in timeline navigation history", @[@"back"]);
    add(@"Timeline History Forward", @"timelineHistoryForward", @"timeline", SpliceKitCommandCategoryEditing, @"View", @"Cmd+]", @"Go forward in timeline navigation history", @[@"forward"]);

    // --- Navigation Go-To ---
    add(@"Go to Inspector", @"goToInspector", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Focus the inspector panel", @[@"focus inspector"]);
    add(@"Go to Timeline", @"goToTimeline", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Focus the timeline", @[@"focus timeline"]);
    add(@"Go to Viewer", @"goToViewer", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Focus the viewer", @[@"focus viewer"]);
    add(@"Go to Color Board", @"goToColorBoard", @"timeline", SpliceKitCommandCategoryColor, @"Color", nil, @"Jump to color board panel", @[@"open color"]);

    // --- Keywords ---
    add(@"Apply Keyword Group 1", @"addKeywordGroup1", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+1", @"Apply keyword shortcut 1", @[@"tag 1"]);
    add(@"Apply Keyword Group 2", @"addKeywordGroup2", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+2", @"Apply keyword shortcut 2", @[@"tag 2"]);
    add(@"Apply Keyword Group 3", @"addKeywordGroup3", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+3", @"Apply keyword shortcut 3", @[@"tag 3"]);
    add(@"Apply Keyword Group 4", @"addKeywordGroup4", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+4", @"Apply keyword shortcut 4", @[@"tag 4"]);
    add(@"Apply Keyword Group 5", @"addKeywordGroup5", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+5", @"Apply keyword shortcut 5", @[@"tag 5"]);
    add(@"Apply Keyword Group 6", @"addKeywordGroup6", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+6", @"Apply keyword shortcut 6", @[@"tag 6"]);
    add(@"Apply Keyword Group 7", @"addKeywordGroup7", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", @"Ctrl+7", @"Apply keyword shortcut 7", @[@"tag 7"]);
    add(@"Remove All Keywords", @"removeAllKeywords", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", nil, @"Remove all keywords from selection", @[@"clear tags"]);
    add(@"Remove Analysis Keywords", @"removeAnalysisKeywords", @"timeline", SpliceKitCommandCategoryEditing, @"Keywords", nil, @"Remove auto-analysis keywords", @[@"clear analysis"]);

    // --- Clip Extras ---
    add(@"Enable/Disable Clip", @"enableDisable", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Toggle clip enabled/disabled", @[@"toggle clip"]);
    add(@"Make Clips Unique", @"makeClipsUnique", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Make referenced clips independent copies", @[@"independent"]);
    add(@"Rename Clip", @"renameClip", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Rename the selected clip", @[@"name"]);
    add(@"Add to Soloed Clips", @"addToSoloedClips", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Add clip to solo group", @[@"solo group"]);
    add(@"Transcode Media", @"transcodeMedia", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Transcode clip to optimized or proxy media", @[@"optimize", @"proxy"]);
    add(@"Paste All Attributes", @"pasteAllAttributes", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Paste all attributes from clipboard", @[@"paste everything"]);
    add(@"Remove Attributes", @"removeAttributes", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Remove specific attributes from clip", @[@"strip attributes"]);
    add(@"Toggle Selected Effects Off", @"toggleSelectedEffectsOff", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Disable/enable selected effects", @[@"bypass effects"]);
    add(@"Toggle Duplicate Detection", @"toggleDuplicateDetection", @"timeline", SpliceKitCommandCategoryEditing, @"View", nil, @"Show/hide duplicate clip indicators", @[@"dupes"]);

    // --- Audition Extras ---
    add(@"Finalize Audition", @"finalizeAudition", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Finalize audition with current pick", @[@"commit audition"]);
    add(@"Next Audition Pick", @"nextAuditionPick", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Preview next audition variant", @[@"next alternative"]);
    add(@"Previous Audition Pick", @"previousAuditionPick", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", nil, @"Preview previous audition variant", @[@"prev alternative"]);

    // --- Captions Extras ---
    add(@"Split Caption", @"splitCaption", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Split caption at playhead", @[@"break caption"]);
    add(@"Resolve Caption Overlaps", @"resolveOverlaps", @"timeline", SpliceKitCommandCategoryTitles, @"Captions", nil, @"Fix overlapping captions", @[@"fix captions"]);

    // --- Project Extras ---
    add(@"Duplicate Project", @"duplicateProject", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Cmd+D", @"Duplicate the current project", @[@"copy project"]);
    add(@"Snapshot Project", @"snapshotProject", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Opt+Cmd+D", @"Save a timestamped snapshot of the project", @[@"backup", @"save version"]);
    add(@"Project Properties", @"projectProperties", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Show project settings (resolution, frame rate)", @[@"project settings"]);
    add(@"Library Properties", @"libraryProperties", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Show library storage and settings", @[@"library info"]);
    add(@"Close Library", @"closeLibrary", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Close the current library", @[@"close lib"]);
    add(@"Merge Events", @"mergeEvents", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Merge selected events", @[@"combine events"]);
    add(@"Delete Generated Files", @"deleteGeneratedFiles", @"timeline", SpliceKitCommandCategoryExport, @"Project", nil, @"Delete render, proxy, and analysis files", @[@"free space", @"clean up"]);

    // --- Find ---
    add(@"Find", @"find", @"timeline", SpliceKitCommandCategoryEditing, @"Find", @"Cmd+F", @"Open find panel", @[@"search"]);
    add(@"Find and Replace Title Text", @"findAndReplaceTitle", @"timeline", SpliceKitCommandCategoryEditing, @"Find", nil, @"Find and replace text in titles", @[@"replace text"]);

    // --- Reveal ---
    add(@"Reveal Source in Browser", @"revealInBrowser", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Show source clip in browser", @[@"find source"]);
    add(@"Reveal Project in Browser", @"revealProjectInBrowser", @"timeline", SpliceKitCommandCategoryEditing, @"Navigation", nil, @"Show project in browser", @[@"find project"]);
    add(@"Reveal in Finder", @"revealInFinder", @"timeline", SpliceKitCommandCategoryExport, @"Project", @"Opt+Cmd+R", @"Show file in macOS Finder", @[@"show in finder"]);
    add(@"Move to Trash", @"moveToTrash", @"timeline", SpliceKitCommandCategoryEditing, @"Clips", @"Cmd+Delete", @"Move selected to trash", @[@"delete permanently"]);

    // --- Playback Extras ---
    add(@"Play from Start", @"playFromStart", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", nil, @"Play from the beginning of timeline", @[@"play beginning"]);
    add(@"Fast Forward", @"fastForward", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"L", @"Fast forward playback", @[@"speed up"]);
    add(@"Rewind", @"rewind", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"J", @"Rewind playback", @[@"reverse play"]);
    add(@"Stop Playing", @"stopPlaying", @"playback", SpliceKitCommandCategoryPlayback, @"Playback", @"K", @"Stop playback", @[@"pause"]);

    // --- Window & Workspace ---
    add(@"Record Voiceover", @"recordVoiceover", @"timeline", SpliceKitCommandCategoryEditing, @"Window", nil, @"Open voiceover recording panel", @[@"voice", @"microphone", @"narration"]);
    add(@"Background Tasks", @"backgroundTasks", @"timeline", SpliceKitCommandCategoryEditing, @"Window", @"Cmd+9", @"Show background tasks window", @[@"rendering", @"progress"]);
    add(@"Edit Roles", @"editRoles", @"timeline", SpliceKitCommandCategoryEditing, @"Roles", nil, @"Open role editor dialog", @[@"manage roles"]);
    add(@"Hide Clip", @"hideClip", @"timeline", SpliceKitCommandCategoryEditing, @"Rating", nil, @"Hide selected clip in browser", @[@"reject hide"]);
    add(@"Show Preferences", @"showPreferences", @"timeline", SpliceKitCommandCategoryOptions, @"Options", @"Cmd+,", @"Open FCP preferences", @[@"settings"]);
    add(@"Add Adjustment Clip", @"addAdjustmentClip", @"timeline", SpliceKitCommandCategoryEffects, @"Effects", nil, @"Add adjustment layer above timeline", @[@"adjustment layer"]);

    // --- Beat Detection ---
    add(@"Detect Beats in Audio File", @"detect", @"beats", SpliceKitCommandCategoryMusic, @"Music", nil, @"Analyze any MP3/WAV/M4A to detect beats, bars, tempo", @[@"beat detection", @"tempo", @"bpm", @"rhythm", @"onset", @"audio analysis"]);

    // --- FlexMusic (Dynamic Soundtrack) ---
    add(@"Browse FlexMusic Songs", @"listSongs", @"flexmusic", SpliceKitCommandCategoryMusic, @"FlexMusic", nil, @"Browse available dynamic soundtrack songs", @[@"music", @"soundtrack", @"song", @"browse", @"library"]);
    add(@"Add FlexMusic to Timeline", @"addToTimeline", @"flexmusic", SpliceKitCommandCategoryMusic, @"FlexMusic", nil, @"Add a dynamic soundtrack that auto-fits the timeline duration", @[@"music", @"soundtrack", @"background music", @"add song"]);
    add(@"Get Song Beat Timing", @"getTiming", @"flexmusic", SpliceKitCommandCategoryMusic, @"FlexMusic", nil, @"Get beat, bar, and section timestamps for a song", @[@"beats", @"bars", @"rhythm", @"tempo", @"timing"]);
    add(@"Render FlexMusic to File", @"renderToFile", @"flexmusic", SpliceKitCommandCategoryMusic, @"FlexMusic", nil, @"Export a fitted soundtrack as M4A or WAV audio", @[@"export", @"render", @"audio file", @"bounce"]);

    // --- Montage Maker ---
    add(@"Auto Montage", @"auto", @"montage", SpliceKitCommandCategoryMusic, @"Montage", nil, @"Auto-create a montage: analyze clips, pick song, cut to beat", @[@"montage", @"auto edit", @"highlight reel", @"music video", @"auto cut"]);
    add(@"Analyze Clips for Montage", @"analyzeClips", @"montage", SpliceKitCommandCategoryMusic, @"Montage", nil, @"Score and rank clips in the browser for montage creation", @[@"analyze", @"score", @"rank", @"clips"]);
    add(@"Plan Montage Edit", @"planEdit", @"montage", SpliceKitCommandCategoryMusic, @"Montage", nil, @"Create an edit decision list mapping clips to musical beats", @[@"plan", @"edl", @"edit plan", @"beat sync"]);
    add(@"Assemble Montage", @"assemble", @"montage", SpliceKitCommandCategoryMusic, @"Montage", nil, @"Build a montage timeline from an edit plan with transitions and music", @[@"assemble", @"build", @"create", @"timeline"]);

    // --- Arrange ---
    add(@"Shuffle Clips", @"shuffle", @"spine_action", SpliceKitCommandCategoryEditing, @"Arrange", nil, @"Randomly reorder all clips on the timeline", @[@"randomize", @"random", @"scramble", @"rearrange", @"mix up", @"shuffle order"]);
    add(@"Reverse Clips", @"reverse", @"spine_action", SpliceKitCommandCategoryEditing, @"Arrange", nil, @"Reverse the order of all clips on the timeline", @[@"backwards", @"flip order", @"mirror"]);

    // --- Options ---
    add(@"SpliceKit Options", @"bridgeOptions", @"bridge_options", SpliceKitCommandCategoryOptions, @"Options", nil, @"Open SpliceKit options panel", @[@"settings", @"preferences", @"config"]);
    add(@"Toggle Effect Drag as Adjustment Clip", @"toggleEffectDragAsAdjustmentClip", @"bridge_toggle", SpliceKitCommandCategoryOptions, @"Options", nil, @"Enable/disable dragging an effect to empty timeline space to create an adjustment clip", @[@"effect drag", @"adjustment layer", @"drop effect", @"effect browser"]);
    add(@"Toggle Viewer Pinch-to-Zoom", @"toggleViewerPinchZoom", @"bridge_toggle", SpliceKitCommandCategoryOptions, @"Options", nil, @"Enable/disable trackpad pinch-to-zoom on the viewer", @[@"trackpad", @"zoom", @"magnify", @"gesture"]);
    add(@"Cycle Default Spatial Conform", @"cycleSpatialConform", @"bridge_conform_cycle", SpliceKitCommandCategoryOptions, @"Options", nil, @"Cycle default spatial conform type: Fit -> Fill -> None", @[@"spatial", @"conform", @"fit", @"fill", @"none", @"scale", @"resize"]);

    self.allCommands = [cmds copy];
    self.masterCommands = self.allCommands;
}

#pragma mark - Favorites
//
// Users can star commands (right-click -> Favorite). Favorites persist in
// NSUserDefaults and appear at the top of the command list when the search
// field is empty. O(1) lookups via a key set ("type::action").
//

NSString *FCPFavoriteKey(NSString *type, NSString *action) {
    return [NSString stringWithFormat:@"%@::%@", type, action];
}

- (NSArray<NSDictionary *> *)allFavoriteDicts {
    return [[NSUserDefaults standardUserDefaults] arrayForKey:kSpliceKitFavoritesKey] ?: @[];
}

- (BOOL)isFavorite:(SpliceKitCommand *)cmd {
    if (!cmd.type || !cmd.action) return NO;
    return [self.favoriteKeys containsObject:FCPFavoriteKey(cmd.type, cmd.action)];
}

- (void)addFavorite:(SpliceKitCommand *)cmd {
    NSString *key = FCPFavoriteKey(cmd.type, cmd.action);
    if ([self.favoriteKeys containsObject:key]) return; // already favorited
    [self.favoriteKeys addObject:key];

    NSMutableArray *dicts = [[self allFavoriteDicts] mutableCopy];
    [dicts addObject:@{
        @"type": cmd.type ?: @"",
        @"action": cmd.action ?: @"",
        @"name": cmd.name ?: @"",
        @"categoryName": cmd.categoryName ?: @"",
    }];
    [[NSUserDefaults standardUserDefaults] setObject:dicts forKey:kSpliceKitFavoritesKey];
}

- (void)removeFavorite:(SpliceKitCommand *)cmd {
    NSString *key = FCPFavoriteKey(cmd.type, cmd.action);
    [self.favoriteKeys removeObject:key];

    NSMutableArray *dicts = [[self allFavoriteDicts] mutableCopy];
    NSIndexSet *toRemove = [dicts indexesOfObjectsPassingTest:^BOOL(NSDictionary *d, NSUInteger idx, BOOL *stop) {
        return [FCPFavoriteKey(d[@"type"], d[@"action"]) isEqualToString:key];
    }];
    [dicts removeObjectsAtIndexes:toRemove];
    [[NSUserDefaults standardUserDefaults] setObject:dicts forKey:kSpliceKitFavoritesKey];
}

#pragma mark - NSMenuDelegate (right-click context menu)

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];

    NSInteger row = self.tableView.clickedRow;
    if (row < 0) return;

    SpliceKitCommand *cmd = [self commandForDisplayRow:row];
    if (!cmd || cmd.isSeparatorRow) return;
    if (!self.inBrowseMode) return;

    static NSSet *favoritableTypes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        favoritableTypes = [NSSet setWithArray:@[
            @"effect_apply", @"transition_apply", @"generator_apply", @"title_apply"
        ]];
    });
    if (![favoritableTypes containsObject:cmd.type]) return;

    BOOL isFav = [self isFavorite:cmd];
    NSMenuItem *item = [[NSMenuItem alloc]
        initWithTitle:isFav ? @"Remove from Favorites" : @"Add to Favorites"
               action:@selector(toggleFavoriteFromMenu:)
        keyEquivalent:@""];
    item.target = self;
    item.representedObject = cmd;
    [menu addItem:item];
}

- (void)toggleFavoriteFromMenu:(NSMenuItem *)sender {
    SpliceKitCommand *cmd = sender.representedObject;
    if ([self isFavorite:cmd]) {
        [self removeFavorite:cmd];
    } else {
        [self addFavorite:cmd];
    }
    [self rebuildBrowseModeListWithFavorites];
}

- (void)injectFavoritesIntoCurrentList {
    if (!self.rawBrowseCommands || self.rawBrowseCommands.count == 0) return;

    NSMutableArray<SpliceKitCommand *> *favoriteCmds = [NSMutableArray array];
    NSMutableArray<SpliceKitCommand *> *regularCmds = [NSMutableArray array];

    for (SpliceKitCommand *cmd in self.rawBrowseCommands) {
        BOOL isFav = [self isFavorite:cmd];
        if (isFav) {
            // Create a copy for the favorites section
            SpliceKitCommand *favCopy = [[SpliceKitCommand alloc] init];
            favCopy.name = cmd.name;
            favCopy.action = cmd.action;
            favCopy.type = cmd.type;
            favCopy.category = cmd.category;
            favCopy.categoryName = cmd.categoryName;
            favCopy.shortcut = cmd.shortcut;
            favCopy.detail = cmd.detail;
            favCopy.keywords = cmd.keywords;
            favCopy.isFavoritedItem = YES;
            [favoriteCmds addObject:favCopy];
        }
        // Mark the original too so the star shows in the main list
        cmd.isFavoritedItem = isFav;
        [regularCmds addObject:cmd];
    }

    if (favoriteCmds.count > 0) {
        NSMutableArray *combined = [NSMutableArray array];
        [combined addObjectsFromArray:favoriteCmds];

        // Add separator
        SpliceKitCommand *separator = [[SpliceKitCommand alloc] init];
        separator.isSeparatorRow = YES;
        separator.name = @"";
        [combined addObject:separator];

        [combined addObjectsFromArray:regularCmds];
        self.allCommands = combined;
    } else {
        self.allCommands = regularCmds;
    }
    self.filteredCommands = self.allCommands;
}

- (void)rebuildBrowseModeListWithFavorites {
    [self injectFavoritesIntoCurrentList];
    NSString *query = self.searchField.stringValue;
    if (query.length > 0) {
        // When searching, use raw list (no favorites section) to avoid duplicates
        self.filteredCommands = [self searchCommandsInArray:self.rawBrowseCommands query:query];
    }
    [self.tableView reloadData];
    if (self.filteredCommands.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
    }
}

- (NSArray<SpliceKitCommand *> *)searchCommandsInArray:(NSArray<SpliceKitCommand *> *)commands query:(NSString *)query {
    if (query.length == 0) return commands;

    NSMutableArray<SpliceKitCommand *> *results = [NSMutableArray array];
    for (SpliceKitCommand *cmd in commands) {
        if (cmd.isSeparatorRow) continue;
        CGFloat nameScore = FCPFuzzyScore(query, cmd.name);
        CGFloat keywordScore = 0;
        for (NSString *kw in cmd.keywords) {
            CGFloat s = FCPFuzzyScore(query, kw);
            if (s > keywordScore) keywordScore = s;
        }
        CGFloat catScore = FCPFuzzyScore(query, cmd.categoryName) * 0.5;
        CGFloat detailScore = FCPFuzzyScore(query, cmd.detail) * 0.3;
        CGFloat best = MAX(MAX(nameScore, keywordScore), MAX(catScore, detailScore));
        if (best > 0.2) {
            cmd.score = best;
            cmd.isFavoritedItem = [self isFavorite:cmd];
            [results addObject:cmd];
        }
    }
    [results sortUsingComparator:^NSComparisonResult(SpliceKitCommand *a, SpliceKitCommand *b) {
        if (a.score > b.score) return NSOrderedAscending;
        if (a.score < b.score) return NSOrderedDescending;
        return [a.name compare:b.name];
    }];
    return results;
}

- (void)exitBrowseMode {
    self.inBrowseMode = NO;
    self.rawBrowseCommands = nil;
    self.allCommands = self.masterCommands;
    self.searchField.stringValue = @"";
    self.searchField.placeholderString = @"Type a command or describe what you want to do...";
    self.filteredCommands = self.allCommands;
    [self.tableView reloadData];
    [self updateStatusLabel];
    if (self.filteredCommands.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
    }
}

- (void)enterTransitionBrowseMode {
    // Show loading state immediately
    self.inBrowseMode = YES;
    self.allCommands = @[];
    self.filteredCommands = @[];
    self.searchField.stringValue = @"";
    self.searchField.placeholderString = @"Loading transitions...";
    [self.tableView reloadData];
    self.statusLabel.stringValue = @"Loading transitions...";

    // Fetch transitions on background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            NSDictionary *r = SpliceKit_handleTransitionsList(@{});
            NSArray *transitions = r[@"transitions"];

            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (!transitions || transitions.count == 0) {
                        self.statusLabel.stringValue = r[@"error"] ?: @"No transitions found";
                        self.searchField.placeholderString = @"No transitions available. Esc to go back.";
                        return;
                    }

                    // Build command list from transitions
                    NSMutableArray<SpliceKitCommand *> *cmds = [NSMutableArray array];
                    for (NSDictionary *t in transitions) {
                        SpliceKitCommand *cmd = [[SpliceKitCommand alloc] init];
                        cmd.name = t[@"name"] ?: @"Unknown";
                        cmd.action = t[@"effectID"] ?: @"";
                        cmd.type = @"transition_apply";
                        cmd.category = SpliceKitCommandCategoryEffects;
                        cmd.categoryName = t[@"category"] ?: @"Transitions";
                        cmd.shortcut = @"";
                        cmd.detail = [NSString stringWithFormat:@"Apply %@ transition", t[@"name"]];
                        cmd.keywords = @[];
                        [cmds addObject:cmd];
                    }

                    self.rawBrowseCommands = cmds;
                    [self injectFavoritesIntoCurrentList];
                    self.searchField.placeholderString = @"Search transitions...";
                    [self.tableView reloadData];
                    self.statusLabel.stringValue = [NSString stringWithFormat:
                        @"%lu transitions | Type to filter | Right-click to favorite | Esc to go back", (unsigned long)cmds.count];

                    if (self.filteredCommands.count > 0) {
                        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                                    byExtendingSelection:NO];
                    }
                } @catch (NSException *e) {
                    SpliceKit_log(@"Exception populating transitions: %@", e.reason);
                    self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", e.reason];
                }
            });
        } @catch (NSException *e) {
            SpliceKit_log(@"Exception fetching transitions: %@", e.reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", e.reason];
                self.searchField.placeholderString = @"Error loading transitions. Esc to go back.";
            });
        }
    });
}

- (void)enterEffectBrowseMode:(NSString *)effectType {
    // Show loading state
    self.inBrowseMode = YES;
    self.allCommands = @[];
    self.filteredCommands = @[];
    self.searchField.stringValue = @"";

    NSDictionary *labels = @{
        @"filter": @"effects",
        @"generator": @"generators",
        @"title": @"titles",
        @"audio": @"audio effects",
    };
    NSString *label = labels[effectType] ?: @"effects";
    self.searchField.placeholderString = [NSString stringWithFormat:@"Loading %@...", label];
    [self.tableView reloadData];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Loading %@...", label];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            NSDictionary *r = SpliceKit_handleEffectsListAvailable(@{@"type": effectType});
            NSArray *effects = r[@"effects"];

            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (!effects || effects.count == 0) {
                        self.statusLabel.stringValue = r[@"error"] ?: [NSString stringWithFormat:@"No %@ found", label];
                        self.searchField.placeholderString = [NSString stringWithFormat:@"No %@ available. Esc to go back.", label];
                        return;
                    }

                    NSMutableArray<SpliceKitCommand *> *cmds = [NSMutableArray array];
                    for (NSDictionary *e in effects) {
                        SpliceKitCommand *cmd = [[SpliceKitCommand alloc] init];
                        cmd.name = e[@"name"] ?: @"Unknown";
                        cmd.action = e[@"effectID"] ?: @"";
                        // Titles and generators are connected to the timeline via pasteboard,
                        // not applied as filters to selected clips
                        NSString *effType = e[@"type"] ?: @"filter";
                        if ([effType isEqualToString:@"title"]) {
                            cmd.type = @"title_apply";
                        } else if ([effType isEqualToString:@"generator"]) {
                            cmd.type = @"generator_apply";
                        } else {
                            cmd.type = @"effect_apply";
                        }
                        cmd.category = SpliceKitCommandCategoryEffects;
                        cmd.categoryName = e[@"category"] ?: label;
                        cmd.shortcut = @"";
                        cmd.detail = [NSString stringWithFormat:@"Apply %@", e[@"name"]];
                        cmd.keywords = @[];
                        [cmds addObject:cmd];
                    }

                    self.rawBrowseCommands = cmds;
                    [self injectFavoritesIntoCurrentList];
                    self.searchField.placeholderString = [NSString stringWithFormat:@"Search %@...", label];
                    [self.tableView reloadData];
                    self.statusLabel.stringValue = [NSString stringWithFormat:
                        @"%lu %@ | Type to filter | Right-click to favorite | Esc to go back", (unsigned long)cmds.count, label];

                    if (self.filteredCommands.count > 0) {
                        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                                    byExtendingSelection:NO];
                    }
                } @catch (NSException *e) {
                    SpliceKit_log(@"Exception populating effects: %@", e.reason);
                    self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", e.reason];
                }
            });
        } @catch (NSException *e) {
            SpliceKit_log(@"Exception fetching effects: %@", e.reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Error: %@", e.reason];
            });
        }
    });
}

- (void)enterFavoritesBrowseMode {
    self.inBrowseMode = YES;
    self.searchField.stringValue = @"";
    self.searchField.placeholderString = @"Search favorites...";

    NSMutableArray<SpliceKitCommand *> *cmds = [NSMutableArray array];
    for (SpliceKitCommand *cmd in self.masterCommands ?: self.allCommands) {
        if (!cmd || cmd.isSeparatorRow) continue;
        if ([self isFavorite:cmd]) {
            [cmds addObject:cmd];
        }
    }

    self.rawBrowseCommands = cmds;
    [self injectFavoritesIntoCurrentList];
    [self.tableView reloadData];

    if (cmds.count == 0) {
        self.statusLabel.stringValue = @"No favorites yet";
        self.searchField.placeholderString = @"No favorites yet. Esc to go back.";
        return;
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:
        @"%lu favorites | Type to filter | Right-click to unfavorite | Esc to go back",
        (unsigned long)cmds.count];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];
}

@end
