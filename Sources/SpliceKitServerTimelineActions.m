//
//  SpliceKitServerTimelineActions.m
//  SpliceKit - Timeline helpers (active timeline module, editor container, pending
//  dialog notes) and timeline.action, the named-action entry point for editing.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Timeline Helpers
//
// The path to the timeline is: NSApp -> delegate (PEAppController) ->
// activeEditorContainer (PEEditorContainerModule) -> timelineModule
// (FFAnchoredTimelineModule). That last one has 1400+ methods and is
// where all the editing magic happens.
//

id SpliceKit_getActiveTimelineModule(void) {
    id editorContainer = nil;
    id delegate = nil;

    // Only walk the dual timeline focus chain if the feature is actually installed.
    // Without this check, the focus chain can dereference stale or invalid state
    // on platforms where the dual timeline swizzles failed to install.
    if (SpliceKit_isDualTimelineInstalled()) {
        editorContainer = SpliceKit_dualTimelineFocusedEditorContainer();
    }

    if (!editorContainer) {
        id app = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("NSApplication"), @selector(sharedApplication));
        delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
        if (!delegate) return nil;

        SEL aecSel = @selector(activeEditorContainer);
        if (![delegate respondsToSelector:aecSel]) return nil;
        editorContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, aecSel);
    }
    if (!editorContainer) return nil;

    // Get timeline module from editor container
    SEL tmSel = NSSelectorFromString(@"timelineModule");
    if ([editorContainer respondsToSelector:tmSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(editorContainer, tmSel);
    }

    // Fallback: try activeEditorModule
    SEL aemSel = @selector(activeEditorModule);
    if (!delegate) {
        id app = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("NSApplication"), @selector(sharedApplication));
        delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    }
    if ([delegate respondsToSelector:aemSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(delegate, aemSel);
    }

    return nil;
}

id SpliceKit_getEditorContainer(void) {
    id editorContainer = SpliceKit_dualTimelineFocusedEditorContainer();
    if (editorContainer) return editorContainer;

    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    if (!delegate) return nil;

    SEL aecSel = @selector(activeEditorContainer);
    if (![delegate respondsToSelector:aecSel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(delegate, aecSel);
}

// Fire an IBAction-style method on the timeline module.
// Most FCP editing commands are -(void)something:(id)sender methods
// on FFAnchoredTimelineModule. We just call them with sender=nil.
static NSDictionary *SpliceKit_sendTimelineAction(NSString *selectorName) {
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module. Is a project open?"};
                return;
            }

            SEL sel = NSSelectorFromString(selectorName);
            if (![timeline respondsToSelector:sel]) {
                result = @{@"error": [NSString stringWithFormat:
                    @"Timeline module does not respond to %@", selectorName]};
                return;
            }

            ((void (*)(id, SEL, id))objc_msgSend)(timeline, sel, nil);
            result = @{@"action": selectorName, @"status": @"ok"};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

// Actions that can put up a sheet (a name, a confirmation, a settings panel). Only these
// get the short run-loop turn below; a blade or an undo in a batch must not pay for it.
static BOOL SpliceKit_actionMayOpenDialog(NSString *action) {
    NSString *a = [action lowercaseString] ?: @"";
    for (NSString *word in @[@"create", @"compound", @"multicam", @"synchronize", @"audition", @"project",
                             @"library", @"properties", @"rename", @"share", @"export", @"import", @"roles",
                             @"consolidate", @"merge", @"deletegenerated", @"record", @"new", @"find"]) {
        if ([a rangeOfString:word].location != NSNotFound) return YES;
    }
    return NO;
}

// After a timeline action: did it open a sheet or a modal dialog (Final Cut Pro asking
// for a name, a confirmation...)? The action itself has returned, so the answer would
// otherwise read "ok" while nothing has happened yet (QA run 2: createCompoundClip and
// its Compound Clip Name sheet). Reported as dialogPending + dialog, never as an error;
// a dialog that was already open before the action is reported the same way. Applied
// by the RPC dispatcher to timeline.action only: the handler itself stays free of the
// run-loop turn, so batch actions, blade_at_times, the command palette and Lua, which
// call it in loops on the main thread, neither pay for it nor yield between steps.
NSDictionary *SpliceKit_makeFilePanelDialogPendingDictionary(NSString *action, NSDictionary *base) {
    NSMutableDictionary *out = base ? [base mutableCopy] : [NSMutableDictionary dictionary];
    out[@"dialogPending"] = @YES;
    out[@"dialog"] = @{
        @"type": @"modal",
        @"isFilePanel": @YES,
        @"panelKind": @"save",
        @"summary": @"modal save/open file panel"
    };
    out[@"note"] = [NSString stringWithFormat:
        @"Final Cut Pro opened (or is opening) a modal save/open file panel after %@. "
        @"While it is open the bridge cannot serve main-thread RPC (detect_dialog, timeline edits, etc.); "
        @"bridge_alive still responds. Save/open panels cannot be confirmed from the bridge — only "
        @"dismiss_dialog(action=\"cancel\") or click_dialog_button(\"Cancel\") closes them. "
        @"Complete the panel in FCP, or cancel and use a tool that takes an explicit path instead.",
        action ?: @"this action"];
    return out;
}

NSDictionary *SpliceKit_annotateCreateActionFilePanelPending(NSDictionary *result, NSString *action) {
    if (![result isKindOfClass:[NSDictionary class]]) return result;
    if (result[@"error"]) {
        NSString *err = result[@"error"];
        if ([err isKindOfClass:[NSString class]] &&
            [err containsString:@"main thread may have timed out"]) {
            return SpliceKit_makeFilePanelDialogPendingDictionary(action, nil);
        }
        return result;
    }
    return SpliceKit_makeFilePanelDialogPendingDictionary(action, result);
}

NSDictionary *SpliceKit_annotatePendingDialog(NSDictionary *result, NSString *action) {
    if (![result isKindOfClass:[NSDictionary class]] || result[@"error"]) return result;
    __block NSDictionary *dialog = nil;
    int passes = SpliceKit_actionMayOpenDialog(action) ? 2 : 1;
    SpliceKit_executeOnMainThread(^{
        @try {
            for (int pass = 0; pass < passes && !dialog; pass++) {
                // A sheet is attached on the next run-loop turn; give it one short one.
                if (pass == 1) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
                NSWindow *modal = [NSApp modalWindow];
                if (modal) {
                    NSMutableDictionary *d = [SpliceKit_describeWindow(modal) mutableCopy];
                    d[@"type"] = @"modal";
                    dialog = d;
                    break;
                }
                for (NSWindow *w in [NSApp windows]) {
                    NSWindow *sheet = [w attachedSheet];
                    if (!sheet || ![sheet isVisible]) continue;
                    NSMutableDictionary *d = [SpliceKit_describeWindow(sheet) mutableCopy];
                    d[@"type"] = @"sheet";
                    d[@"parentWindow"] = [w title] ?: @"";
                    dialog = d;
                    break;
                }
            }
        } @catch (NSException *e) { dialog = nil; }
    });
    if (!dialog) return result;
    NSMutableDictionary *out = [result mutableCopy];
    out[@"dialogPending"] = @YES;
    out[@"dialog"] = dialog;
    // Named by its title when it has a real one, else by the summary describeWindow built
    // from its fields or buttons (QA run 3: the Compound Clip Name sheet is titled "Window").
    NSString *title = [dialog[@"title"] isKindOfClass:[NSString class]] ? dialog[@"title"] : @"";
    NSString *summary = [dialog[@"summary"] isKindOfClass:[NSString class]] ? dialog[@"summary"] : @"";
    NSString *label = (summary.length > 0 && ![summary isEqualToString:title]) ? summary
        : (title.length > 0 ? [NSString stringWithFormat:@"\"%@\"", title] : @"");
    NSString *filePanelHint = [dialog[@"isFilePanel"] boolValue]
        ? @" Save/open panels cannot be confirmed from the bridge (only cancel: works); dismiss_dialog(action=\"cancel\") cancels. "
        : @"";
    out[@"note"] = [NSString stringWithFormat:
        @"Final Cut Pro has a %@ open%@ after this action; nothing changes on the timeline until it is answered.%@ "
        @"While a modal save/open panel is up, main-thread bridge calls may time out; bridge_alive still responds. "
        @"detect_dialog() shows its fields and buttons; fill_dialog_field / click_dialog_button / dismiss_dialog answer it.",
        dialog[@"type"], label.length ? [NSString stringWithFormat:@" (%@)", label] : @"", filePanelHint];
    SpliceKit_log(@"[Action] %@: a %@ is open afterwards (%@)", action, dialog[@"type"], label);
    return out;
}

// Edit > Insert Generator > Gap (playhead). actionMap insertGapAtPlayhead: no longer works in FCP 12.3;
// FFAnchoredTimelineModule exposes -insertGap (v16@0:8, no arguments).
NSDictionary *SpliceKit_directInsertGap(id timeline) {
    SEL sel = NSSelectorFromString(@"insertGap");
    if (![timeline respondsToSelector:sel]) {
        return @{@"error": @"Timeline module does not respond to insertGap"};
    }
    ((void (*)(id, SEL))objc_msgSend)(timeline, sel);
    return @{@"action": @"insertGap", @"status": @"ok"};
}

// Edit > Insert Generator > Placeholder. Same shape as insertGap on FFAnchoredTimelineModule.
static NSDictionary *SpliceKit_directInsertPlaceholder(id timeline) {
    SEL sel = NSSelectorFromString(@"insertPlaceholder");
    if (![timeline respondsToSelector:sel]) {
        return @{@"error": @"Timeline module does not respond to insertPlaceholder"};
    }
    ((void (*)(id, SEL))objc_msgSend)(timeline, sel);
    return @{@"action": @"insertPlaceholder", @"status": @"ok"};
}

#pragma mark - Timeline Command Handlers

// This is the main entry point for all editing commands. Clients send a
// friendly action name like "blade" or "addColorBoard", and we map it to
// the actual ObjC selector on FFAnchoredTimelineModule.
//

// The actionMap below is essentially a reverse-engineered API surface of
// FCP's editing engine. These were found by disassembling Flexo.framework
// and looking at IB action connections, responder chain handlers, and
// menu item targets.
NSDictionary *SpliceKit_handleTimelineAction(NSDictionary *params) {
    SpliceKit_installEffectDragSwizzlesNow();

    NSString *action = params[@"action"];
    if (!action) return @{@"error": @"action parameter required"};

    // dry_run=true: report what would fire without firing. Returns the resolved
    // selector, safety classification, and whether a project/selection is present.
    if ([params[@"dry_run"] boolValue]) {
        NSDictionary *dryMeta = SpliceKit_builtinMetadataForMethod(@"timeline.action");
        __block BOOL hasProject = NO;
        __block BOOL hasSelection = NO;
        SpliceKit_executeOnMainThread(^{
            id timeline = SpliceKit_getActiveTimelineModule();
            hasProject = (timeline != nil);
            if (timeline) {
                id sel = SpliceKit_getSelectedTimelineItem(timeline);
                hasSelection = (sel != nil);
            }
        });
        BOOL needsSelection = ([action hasPrefix:@"addColor"]
                               || [action hasPrefix:@"retime"]
                               || [action hasPrefix:@"detach"]
                               || [action hasPrefix:@"expand"]
                               || [action hasPrefix:@"freeze"]
                               || [action isEqualToString:@"solo"]
                               || [action isEqualToString:@"disable"]
                               || [action isEqualToString:@"favorite"]
                               || [action isEqualToString:@"reject"]);
        return @{
            @"dry_run": @YES,
            @"action": action,
            @"safety": dryMeta[@"safety"] ?: @"state_dependent",
            @"requires_project": @YES,
            @"requires_selection": @(needsSelection),
            @"project_loaded": @(hasProject),
            @"clip_selected": @(hasSelection),
            @"would_fire": @(hasProject && (!needsSelection || hasSelection)),
            @"note": @"No action was performed. Remove dry_run=true to execute.",
        };
    }

    NSDictionary *actionMap = @{
        // Blade/Split
        @"blade":            @"blade:",
        @"bladeAll":         @"bladeAll:",

        // Markers
        @"addMarker":        @"addMarker:",
        @"addTodoMarker":    @"addTodoMarker:",
        @"addChapterMarker": @"addChapterMarker:",
        @"deleteMarker":     @"deleteMarker:",
        @"nextMarker":       @"nextMarker:",
        @"previousMarker":   @"previousMarker:",

        // Transitions
        @"addTransition":    @"addTransition:",

        // Navigation
        @"nextEdit":         @"nextEdit:",
        @"previousEdit":     @"previousEdit:",
        @"selectClipAtPlayhead": @"selectClipAtPlayhead:",
        @"selectToPlayhead": @"selectToPlayhead:",

        // Selection
        @"selectAll":        @"selectAll:",
        @"deselectAll":      @"deselectAll:",

        // Edit operations
        @"delete":           @"delete:",
        @"cut":              @"cut:",
        @"copy":             @"copy:",
        @"paste":            @"paste:",

        // Trim
        @"trimToPlayhead":   @"trimToPlayhead:",
        @"extendEditToPlayhead": @"actionExtendEditToPlayhead",

        // Insert (insertGap / insertPlaceholder — direct on FFAnchoredTimelineModule; see below)

        // Color Correction (add to selected clips)
        @"addColorBoard":          @"addColorBoardEffect:",
        @"addColorWheels":         @"addColorWheelsEffect:",
        @"addColorCurves":         @"addColorCurvesEffect:",
        @"addColorAdjustment":     @"addColorAdjustmentEffect:",
        @"addHueSaturation":       @"addHueSaturationEffect:",
        @"addEnhanceLightAndColor":@"addEnhanceLightAndColorEffect:",

        // Volume
        @"adjustVolumeUp":         @"adjustVolumeRelative:",
        @"adjustVolumeDown":       @"adjustVolumeAbsolute:",

        // Titles
        @"addBasicTitle":          @"addBasicTitle:",
        @"addBasicLowerThird":     @"addBasicLowerThird:",

        // Retiming/Speed presets
        @"retimeNormal":     @"retimeNormal:",
        @"retimeFast2x":     @"retimeFastx2:",
        @"retimeFast4x":     @"retimeFastx4:",
        @"retimeFast8x":     @"retimeFastx8:",
        @"retimeFast20x":    @"retimeFastx20:",
        @"retimeSlow50":     @"retimeSlowHalf:",
        @"retimeSlow25":     @"retimeSlowQuarter:",
        @"retimeSlow10":     @"retimeSlowTenth:",
        @"retimeReverse":    @"retimeReverse:",
        @"retimeHold":       @"retimeHold:",
        @"freezeFrame":      @"freezeFrame:",
        @"retimeBladeSpeed": @"retimeBladeSpeed:",
        @"retimeSpeedRampToZero": @"retimeSpeedRampToZero:",
        @"retimeSpeedRampFromZero": @"retimeSpeedRampFromZero:",

        // Generators
        @"addVideoGenerator": @"addVideoGenerator:",

        // Export/Share
        @"exportXML":        @"exportXML:",
        @"shareSelection":   @"shareSelection:",

        // Range selection (in/out points)
        @"setRangeStart":    @"setRangeStart:",
        @"setRangeEnd":      @"setRangeEnd:",
        @"clearRange":       @"clearRange:",

        // Keyframes
        @"addKeyframe":      @"addKeyframe:",
        @"deleteKeyframes":  @"deleteKeyframes:",
        @"nextKeyframe":     @"nextKeyframe:",
        @"previousKeyframe": @"previousKeyframe:",

        // Solo/Disable
        @"solo":             @"soloSelectedClips:",
        @"disable":          @"disableSelectedClips:",

        // Compound clips
        @"createCompoundClip": @"createCompoundClip:",

        // Auto-reframe
        @"autoReframe":      @"autoReframe:",

        // Clip operations
        @"detachAudio":      @"detachAudio:",
        @"breakApartClipItems": @"breakApartClipItems:",
        @"removeEffects":    @"removeEffects:",
        @"liftFromPrimaryStoryline": @"liftFromSpine:",
        @"overwriteToPrimaryStoryline": @"collapseToSpine:",
        @"createStoryline":  @"createStoryline:",
        @"collapseToConnectedStoryline": @"collapseToConnectedStoryline:",

        // Timeline view
        @"zoomToFit":        @"zoomToFit:",
        @"zoomIn":           @"zoomIn:",
        @"zoomOut":          @"zoomOut:",
        @"verticalZoomToFit": @"verticalZoomToFit:",
        @"zoomToSamples":    @"zoomToSamples:",
        @"toggleSnapping":   @"toggleSnapping:",
        @"toggleSkimming":   @"toggleSkimming:",
        @"toggleClipSkimming": @"toggleItemSkimming:",
        @"toggleAudioSkimming": @"toggleAudioScrubbingDown:",
        @"toggleInspector":  @"toggleInspector:",
        @"toggleTimeline":   @"toggleTimeline:",
        @"toggleTimelineIndex": @"toggleTimelineIndex:",
        @"toggleInspectorHeight": @"toggleInspectorHeight:",
        @"showPrecisionEditor": @"showPrecisionEditor:",
        @"showAudioLanes":   @"showAudioLanes:",
        @"expandSubroles":   @"expandSubroles:",
        @"timelineHistoryBack": @"timelineHistoryBack:",
        @"timelineHistoryForward": @"timelineHistoryForward:",
        @"beatDetectionGrid": @"toggleBeatDetectionGrid:",
        @"timelineScrolling": @"toggleTimelineScrolling:",
        @"enterFullScreen":  @"toggleFullScreen:",

        // Render
        @"renderSelection":  @"renderSelection:",
        @"renderAll":        @"renderAll:",

        // Markers
        @"deleteMarkersInSelection": @"deleteMarkersInSelection:",

        // Analysis
        @"analyzeAndFix":    @"analyzeAndFix:",

        // Edit modes (insert/append/overwrite/connect)
        @"connectToPrimaryStoryline": @"anchorWithSelectedMedia:",
        @"insertEdit":       @"insertWithSelectedMedia:",
        @"appendEdit":       @"appendWithSelectedMedia:",
        @"overwriteEdit":    @"overwriteWithSelectedMedia:",

        // Paste variants
        @"pasteAsConnected": @"pasteAnchored:",
        @"pasteEffects":     @"pasteEffects:",
        @"pasteAttributes":  @"pasteAttributes:",
        @"removeAttributes": @"removeAttributes:",
        @"copyAttributes":   @"copyAttributes:",

        // Replace/delete variants
        @"replaceWithGap":   @"shiftDelete:",
        @"deleteSelection":  @"deleteSelection:",

        // Trim operations
        @"trimStart":        @"trimStart:",
        @"trimEnd":          @"trimEnd:",
        @"joinClips":        @"joinSelection:",

        // Nudge
        @"nudgeLeft":        @"nudgeLeft:",
        @"nudgeRight":       @"nudgeRight:",
        @"nudgeUp":          @"nudgeUp:",
        @"nudgeDown":        @"nudgeDown:",

        // Rating
        @"favorite":         @"favorite:",
        @"reject":           @"reject:",
        @"unrate":           @"unfavorite:",

        // Mark/Range
        @"setClipRange":     @"selectClip:",
        @"copyTimecode":     @"copyTimecode:",

        // Project operations
        @"duplicateProject": @"duplicate:",
        @"snapshotProject":  @"snapshotProject:",

        // Audio operations
        @"expandAudio":      @"splitEdit:",
        @"expandAudioComponents": @"toggleAudioComponents:",
        @"addChannelEQ":     @"addChannelEQ:",
        @"enhanceAudio":     @"enhanceAudio:",
        @"matchAudio":       @"matchAudio:",

        // Show/hide editors
        @"showVideoAnimation": @"showTimelineCurveEditor:",
        @"showAudioAnimation": @"showTimelineCurveEditor:",
        @"soloAnimation":    @"collapseTimelineCurveEditor:",
        @"showTrackingEditor": @"showTrackingEditor:",
        @"showCinematicEditor": @"showCinematicEditor:",
        @"showMagneticMaskEditor": @"showMagneticMaskEditor:",
        @"enableBeatDetection": @"enableBeatDetection:",

        // Clip operations
        @"synchronizeClips": @"mergeClips:",
        @"openClip":         @"openInTimeline:",
        @"renameClip":       @"renameClip:",
        @"addToSoloedClips": @"addToSoloedClips:",
        @"referenceNewParentClip": @"referenceNewParentClip:",

        // Color correction extras
        @"balanceColor":     @"toggleBalanceColor:",
        @"matchColor":       @"matchColor:",
        @"addMagneticMask":  @"addObjectMaskEffect:",
        @"smartConform":     @"autoReframe:",
        @"enhanceLightAndColor": @"enhanceLightAndColor:",

        // Adjustment clip
        @"addAdjustmentClip": @"connectAdjustmentClip:",

        // Voiceover
        @"recordVoiceover":  @"toggleVoiceoverRecordView:",

        // Window/workspace
        @"backgroundTasks":  @"goToBackgroundTaskList:",
        @"showDuplicateRanges": @"showDuplicateRanges:",

        // Roles
        @"editRoles":        @"editRoles:",

        // Change duration
        @"changeDuration":   @"showTimecodeEntryDuration:",

        // Keywords
        @"showKeywordEditor": @"toggleKeywordEditor:",
        @"removeAllKeywords": @"removeAllKeywords:",
        @"removeAnalysisKeywords": @"removeAnalysisKeywords:",

        // Hide clip
        @"hideClip":         @"hideClip:",

        // Audition
        @"createAudition":   @"createAudition:",
        @"finalizeAudition": @"finalizeAudition:",
        @"nextAuditionPick": @"nextAuditionPick:",
        @"previousAuditionPick": @"previousAuditionPick:",

        // Captions
        @"addCaption":       @"addCaption:",
        @"splitCaption":     @"splitCaptions:",
        @"resolveOverlaps":  @"resolveCaptionOverlaps:",

        // Multicam
        @"createMulticamClip": @"createMulticamClip:",

        // Source media
        @"revealInBrowser":  @"revealSourceInBrowser:",
        @"revealProjectInBrowser": @"revealProjectInBrowser:",
        @"revealInFinder":   @"revealInFinder:",
        @"moveToTrash":      @"moveToTrash:",

        // Library
        @"closeLibrary":     @"closeLibrary:",
        @"libraryProperties": @"showLibraryProperties:",
        @"consolidateEventMedia": @"consolidateEventMedia:",
        @"mergeEvents":      @"mergeEvents:",
        @"deleteGeneratedFiles": @"deleteGeneratedFiles:",

        // Find
        @"find":             @"performFindPanelAction:",
        @"findAndReplaceTitle": @"findAndReplaceTitleText:",

        // Project properties
        @"projectProperties": @"showProjectProperties:",

        // Edit modes - audio/video only
        @"insertEditAudio":  @"insertWithSelectedMediaAudio:",
        @"insertEditVideo":  @"insertWithSelectedMediaVideo:",
        @"appendEditAudio":  @"appendWithSelectedMediaAudio:",
        @"appendEditVideo":  @"appendWithSelectedMediaVideo:",
        @"overwriteEditAudio": @"overwriteWithSelectedMediaAudio:",
        @"overwriteEditVideo": @"overwriteWithSelectedMediaVideo:",
        @"connectEditAudio": @"anchorWithSelectedMediaAudio:",
        @"connectEditVideo": @"anchorWithSelectedMediaVideo:",
        @"connectEditBacktimed": @"anchorWithSelectedMediaBacktimed:",

        // Replace edits
        @"replaceFromStart": @"replaceWithSelectedMediaFromStart:",
        @"replaceFromEnd":   @"replaceWithSelectedMediaFromEnd:",
        @"replaceWhole":     @"replaceWithSelectedMediaWhole:",

        // Retiming extras
        @"retimeCustomSpeed": @"retimeCustomSpeed:",
        @"retimeInstantReplayHalf": @"retimeInstantReplayHalf:",
        @"retimeInstantReplayQuarter": @"retimeInstantReplayQuarter:",
        @"retimeReset":      @"retimeReset:",
        @"retimeOpticalFlow": @"retimeTurnOnOpticalFlow:",
        @"retimeFrameBlending": @"retimeTurnOnSmoothTransition:",
        @"retimeFloorFrame": @"retimeTurnOnFloorFrameSampling:",

        // AV edit mode
        @"avEditModeAudio":  @"avEditModeAudio:",
        @"avEditModeVideo":  @"avEditModeVideo:",
        @"avEditModeBoth":   @"avEditModeBoth:",

        // Keyword groups
        @"addKeywordGroup1": @"addKeywordGroup1:",
        @"addKeywordGroup2": @"addKeywordGroup2:",
        @"addKeywordGroup3": @"addKeywordGroup3:",
        @"addKeywordGroup4": @"addKeywordGroup4:",
        @"addKeywordGroup5": @"addKeywordGroup5:",
        @"addKeywordGroup6": @"addKeywordGroup6:",
        @"addKeywordGroup7": @"addKeywordGroup7:",

        // Color correction navigation
        @"nextColorEffect":  @"nextColorEffect:",
        @"previousColorEffect": @"previousColorEffect:",
        @"resetColorBoard":  @"resetPucksOnCurrentBoard:",
        @"toggleAllColorOff": @"toggleAllColorCorrectionOff:",

        // Paste attribute variants
        @"pasteAllAttributes": @"pasteAllAttributes:",

        // Audio extras
        @"alignAudioToVideo": @"alignAudioToVideo:",
        @"volumeMute":       @"volumeMinusInfinity:",
        @"addDefaultAudioEffect": @"addDefaultAudioEffect:",
        @"addDefaultVideoEffect": @"addDefaultVideoEffect:",
        @"applyAudioFades":  @"applyAudioFades:",

        // Effects toggles
        @"toggleSelectedEffectsOff": @"toggleSelectedEffectsOff:",
        @"toggleDuplicateDetection": @"toggleDupeDetection:",

        // Clip extras
        @"makeClipsUnique":  @"makeClipsUnique:",
        @"enableDisable":    @"enableOrDisableEdit:",
        @"transcodeMedia":   @"transcodeMedia:",

        // Navigation extras
        @"selectNextItem":   @"selectNextItem:",
        @"selectUpperItem":  @"selectUpperItem:",

        // View extras
        @"togglePrecisionEditor": @"togglePrecisionEditor:",
        @"goToInspector":    @"goToInspector:",
        @"goToTimeline":     @"goToTimeline:",
        @"goToViewer":       @"goToViewer:",
        @"goToColorBoard":   @"goToColorBoard:",

        // Preferences
        @"showPreferences":  @"showPreferences:",

        // --- Drop menu actions (drag-and-drop edit modes) ---
        @"dropInsert":                  @"actionDropInsert:",
        @"dropMenuInsert":              @"actionDropMenuInsert:",
        @"dropMenuReplace":             @"actionDropMenuReplace:",
        @"dropMenuReplaceAndStack":     @"actionDropMenuReplaceAndStack:",
        @"dropMenuReplaceAtPlayhead":   @"actionDropMenuReplaceAtPlayhead:",
        @"dropMenuReplaceFromEnd":      @"actionDropMenuReplaceFromEnd:",
        @"dropMenuReplaceFromStart":    @"actionDropMenuReplaceFromStart:",
        @"dropMenuReplaceWithRetime":   @"actionDropMenuReplaceWithRetime:",
        @"dropMenuAddEditsToGroup":     @"actionDropMenuAddEditsToGroup:",
        @"dropMenuAddToStack":          @"actionDropMenuAddToStack:",
        @"dropMenuCancel":              @"actionDropMenuCancel:",

        // --- Retiming quality (direct Flexo methods) ---
        @"retimeTurnOnOpticalFlowHigh":    @"actionRetimeTurnOnOpticalFlowHigh:",
        @"retimeTurnOnOpticalFlowMedium":  @"actionRetimeTurnOnOpticalFlowMedium:",
        @"retimeTurnOnOpticalFlowFRC":     @"actionRetimeTurnOnOpticalFlowFRC:",
        @"retimeTurnOnNearestNeighbor":    @"actionRetimeTurnOnNearestNeighbor:",
        @"retimeRateConformOpticalFlowHigh": @"actionRateConformTurnOnOpticalFlowHigh:",

        // --- Cinematic / tracking ---
        @"resetCinematic":           @"actionResetCinematic:",
        @"addTrackerOnSource":       @"actionAddTrackerOnSource:",

        // --- Audio offset channels ---
        @"bakeAndRemoveOffsetChannels": @"actionBakeAndRemoveOffsetChannels",
        @"resetOffsetChannels":         @"actionResetOffsetChannels",

        // --- Caption playback ---
        @"setCaptionPlaybackEnabled":  @"actionSetCaptionPlaybackEnabled:",
        @"setCaptionPlaybackRoleUID":  @"actionSetCaptionPlaybackRoleUID:",

        // --- Trim extras ---
        @"trimEdgeAtPlayhead":         @"actionTrimEdgeAtPlayhead:",
        @"collapseToSpine":            @"actionCollapseToSpine",

        // --- Variant/audition extras ---
        @"deleteActiveVariant":        @"actionDeleteActiveVariantMakeNextActive:",
        @"removeCutawayEffects":       @"actionRemoveCutawayEffects:",
        @"toggleVerifyObjectAlignment": @"actionToggleVerifyObjectAlignment:",
    };

    // Undo/redo are special — they don't go through the timeline module's responder chain.
    // Instead we need to find the document's undo manager directly. The path is:
    // PEAppController -> _targetLibrary -> libraryDocument -> undoManager
    if ([action isEqualToString:@"undo"] || [action isEqualToString:@"redo"]) {
        __block NSDictionary *undoResult = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id app = ((id (*)(id, SEL))objc_msgSend)(
                    objc_getClass("NSApplication"), @selector(sharedApplication));
                id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
                // PEAppController -> _targetLibrary -> libraryDocument -> undoManager
                SEL libSel = NSSelectorFromString(@"_targetLibrary");
                id library = nil;
                if ([delegate respondsToSelector:libSel]) {
                    library = ((id (*)(id, SEL))objc_msgSend)(delegate, libSel);
                }
                if (!library) {
                    // Fallback: get first active library
                    id libs = ((id (*)(id, SEL))objc_msgSend)(
                        objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
                    if ([libs respondsToSelector:@selector(firstObject)]) {
                        library = ((id (*)(id, SEL))objc_msgSend)(libs, @selector(firstObject));
                    }
                }
                if (!library) {
                    undoResult = @{@"error": @"No library found for undo"};
                    return;
                }
                id doc = ((id (*)(id, SEL))objc_msgSend)(library, @selector(libraryDocument));
                if (!doc) {
                    undoResult = @{@"error": @"No document found for undo"};
                    return;
                }
                id um = ((id (*)(id, SEL))objc_msgSend)(doc, @selector(undoManager));
                if (!um) {
                    undoResult = @{@"error": @"No undo manager"};
                    return;
                }

                SEL undoSel = [action isEqualToString:@"undo"] ? @selector(undo) : @selector(redo);
                SEL canSel = [action isEqualToString:@"undo"] ? @selector(canUndo) : @selector(canRedo);
                SEL nameSel = [action isEqualToString:@"undo"] ? @selector(undoActionName) : @selector(redoActionName);

                BOOL can = ((BOOL (*)(id, SEL))objc_msgSend)(um, canSel);
                if (!can) {
                    undoResult = @{@"error": [NSString stringWithFormat:@"Cannot %@ - nothing to %@", action, action]};
                    return;
                }

                NSString *actionName = ((id (*)(id, SEL))objc_msgSend)(um, nameSel);
                ((void (*)(id, SEL))objc_msgSend)(um, undoSel);
                undoResult = @{@"action": action, @"status": @"ok",
                              @"actionName": actionName ?: @""};
            } @catch (NSException *e) {
                undoResult = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
            }
        });
        return undoResult;
    }

    // Add transition to ALL edit points: select all → addTransition
    // FCP natively adds transitions at every edit point when all clips are selected.
    if ([action isEqualToString:@"addTransitionToAll"]) {
        __block NSDictionary *allResult = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id timelineModule = SpliceKit_getActiveTimelineModule();
                if (!timelineModule) {
                    allResult = @{@"error": @"No active timeline module"};
                    return;
                }

                NSUInteger before = SpliceKit_transitionCount(timelineModule);

                // Select all clips
                SEL selectAllSel = @selector(selectAll:);
                if ([timelineModule respondsToSelector:selectAllSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, selectAllSel, nil);
                } else {
                    [[NSApplication sharedApplication] sendAction:selectAllSel to:nil from:nil];
                }

                // Let selection register
                [[NSRunLoop currentRunLoop] runUntilDate:
                    [NSDate dateWithTimeIntervalSinceNow:0.15]];

                // Final Cut Pro raises "there is not enough extra media for this
                // transition" when a clip either side of an edit is shorter than the
                // default transition duration. apply_transition arms the one-shot
                // auto-accept before adding; this path did not, so the alert went
                // unanswered, blocked the main thread, and the 20s dispatch timeout
                // turned into a bare "Failed to add transitions to all clips" while the
                // alert was still on screen and the action still open.
                SpliceKit_armTransitionAlertAutoAccept();

                // Add transition — FCP adds to all edit points when all clips selected
                SEL addSel = @selector(addTransition:);
                if ([timelineModule respondsToSelector:addSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, addSel, nil);
                } else {
                    [[NSApplication sharedApplication] sendAction:addSel to:nil from:nil];
                }

                // Wait for transitions to appear
                [[NSRunLoop currentRunLoop] runUntilDate:
                    [NSDate dateWithTimeIntervalSinceNow:0.5]];

                NSUInteger after = SpliceKit_transitionCount(timelineModule);
                NSUInteger added = (after > before) ? (after - before) : 0;

                SpliceKit_log(@"[Transition] Added %lu transitions to all edit points (total: %lu)",
                              (unsigned long)added, (unsigned long)after);

                allResult = @{
                    @"action": @"addTransitionToAll",
                    @"status": @"ok",
                    @"transitionsAdded": @(added),
                    @"totalTransitions": @(after)
                };
            } @catch (NSException *e) {
                allResult = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
            }
        });
        return allResult ?: @{@"error": @"Failed to add transitions to all clips"};
    }

    if ([action isEqualToString:@"removeAllKeyframesFromClip"]) {
        __block NSDictionary *clearResult = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id timelineModule = SpliceKit_getActiveTimelineModule();
                if (!timelineModule) {
                    clearResult = @{@"error": @"No active timeline module"};
                    return;
                }

                BOOL autoSelected = NO;
                id clip = SpliceKit_getSelectedTimelineItem(timelineModule);
                if (!clip) {
                    SEL selectAtPlayhead = NSSelectorFromString(@"selectClipAtPlayhead:");
                    if ([timelineModule respondsToSelector:selectAtPlayhead]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, selectAtPlayhead, nil);
                    } else {
                        [[NSApplication sharedApplication] sendAction:selectAtPlayhead to:nil from:nil];
                    }
                    autoSelected = YES;
                    [[NSRunLoop currentRunLoop] runUntilDate:
                        [NSDate dateWithTimeIntervalSinceNow:0.05]];
                    clip = SpliceKit_getSelectedTimelineItem(timelineModule);
                }

                if (!clip) {
                    clearResult = @{@"error": @"No clip selected and none found at playhead"};
                    return;
                }

                NSUInteger channelsCleared = 0;
                NSUInteger keyframesRemoved = 0;
                NSMutableArray *targetResults = [NSMutableArray array];
                for (id target in SpliceKit_keyframeTargetsForClip(clip)) {
                    NSDictionary *targetResult = SpliceKit_removeAllKeyframesFromEffectStack(
                        target, @"Remove All Keyframes");
                    if (!targetResult) continue;
                    channelsCleared += [targetResult[@"channelsCleared"] unsignedIntegerValue];
                    keyframesRemoved += [targetResult[@"keyframesRemoved"] unsignedIntegerValue];
                    [targetResults addObject:targetResult];
                }

                NSMutableDictionary *payload = [@{
                    @"action": @"removeAllKeyframesFromClip",
                    @"status": @"ok",
                    @"channelsCleared": @(channelsCleared),
                    @"keyframesRemoved": @(keyframesRemoved),
                    @"autoSelected": @(autoSelected),
                } mutableCopy];

                if (targetResults.count > 0) payload[@"targets"] = targetResults;
                @try {
                    if ([clip respondsToSelector:@selector(displayName)]) {
                        id name = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                        if (name) payload[@"clipName"] = [name description];
                    }
                } @catch (NSException *e) {}
                payload[@"selectedClass"] = NSStringFromClass([clip class]);

                if (channelsCleared == 0) {
                    payload[@"note"] = @"No keyframed channels found on the selected clip";
                }
                SpliceKit_log(@"[Keyframes] removeAllKeyframesFromClip class=%@ channels=%lu keyframes=%lu",
                              NSStringFromClass([clip class]),
                              (unsigned long)channelsCleared,
                              (unsigned long)keyframesRemoved);
                clearResult = payload;
            } @catch (NSException *e) {
                clearResult = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
            }
        });
        return clearResult ?: @{@"error": @"Failed to remove keyframes from clip"};
    }

    // === Toggle Mute Audio ===
    // Mutes or unmutes audio on selected clips (or clip at playhead if nothing selected).
    // Works like "Disable Clip" (V) but for the audio portion only.
    // Uses FFAnchoredTimelineModule's native doMute: which toggles audioPlayEnable.
    if ([action isEqualToString:@"toggleMuteAudio"]) {
        __block NSDictionary *muteResult = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id timelineModule = SpliceKit_getActiveTimelineModule();
                if (!timelineModule) {
                    muteResult = @{@"error": @"No active timeline module"};
                    return;
                }

                // Check for selected items
                SEL selectedSel = NSSelectorFromString(@"selectedItems");
                id selectedItems = nil;
                if ([timelineModule respondsToSelector:selectedSel]) {
                    selectedItems = ((id (*)(id, SEL))objc_msgSend)(timelineModule, selectedSel);
                }

                // If nothing selected, select clip at playhead first
                BOOL autoSelected = NO;
                if (!selectedItems || [selectedItems count] == 0) {
                    SEL selectAtPlayhead = NSSelectorFromString(@"selectClipAtPlayhead:");
                    if ([timelineModule respondsToSelector:selectAtPlayhead]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, selectAtPlayhead, nil);
                        autoSelected = YES;
                    } else {
                        [[NSApplication sharedApplication] sendAction:selectAtPlayhead to:nil from:nil];
                        autoSelected = YES;
                    }
                    // Let selection register
                    [[NSRunLoop currentRunLoop] runUntilDate:
                        [NSDate dateWithTimeIntervalSinceNow:0.05]];
                    // Re-read selection
                    if ([timelineModule respondsToSelector:selectedSel]) {
                        selectedItems = ((id (*)(id, SEL))objc_msgSend)(timelineModule, selectedSel);
                    }
                }

                if (!selectedItems || [selectedItems count] == 0) {
                    muteResult = @{@"error": @"No clip selected and none found at playhead"};
                    return;
                }

                // Use FCP's built-in adjustVolumeByAmount:isRelative:actionName: on the
                // timeline module. Mute sets -96 dB (silence), unmute restores to 0 dB.
                // This handles all clip types, undo, and connected storylines natively.
                //
                // Detect muted state by reading the audio volume channel from the
                // selected clip's effect stack.
                SEL adjustVolSel = NSSelectorFromString(@"adjustVolumeByAmount:isRelative:actionName:");
                if (![timelineModule respondsToSelector:adjustVolSel]) {
                    muteResult = @{@"error": @"Timeline module does not support volume adjustment"};
                    return;
                }

                // Detect muted state via newVolume.amount on the first selected clip.
                // FFAnchoredObject.newVolume returns an IXVolume; its amount is e.g. "0dB" or "-96dB".
                BOOL isMuted = NO;
                SEL newVolSel = NSSelectorFromString(@"newVolume");
                for (id item in selectedItems) {
                    if (![item respondsToSelector:newVolSel]) continue;
                    id vol = ((id (*)(id, SEL))objc_msgSend)(item, newVolSel);
                    if (!vol) continue;
                    id amountStr = ((id (*)(id, SEL))objc_msgSend)(vol, @selector(amount));
                    if (amountStr && [amountStr isKindOfClass:[NSString class]]) {
                        if ([amountStr hasPrefix:@"-96"]) isMuted = YES;
                    }
                    break;
                }

                BOOL shouldMute = !isMuted;
                NSString *actionName = shouldMute ? @"Mute Audio" : @"Unmute Audio";

                if (shouldMute) {
                    // Mute: set volume to -96 dB (silence)
                    ((void (*)(id, SEL, double, BOOL, id))objc_msgSend)(
                        timelineModule, adjustVolSel, -96.0, NO, actionName);
                } else {
                    // Unmute: undo the mute (restore previous volume via undo manager)
                    id um = SpliceKit_getUndoManager();
                    if (um && ((BOOL (*)(id, SEL))objc_msgSend)(um, @selector(canUndo))) {
                        NSString *undoName = ((id (*)(id, SEL))objc_msgSend)(um, @selector(undoActionName));
                        if ([undoName containsString:@"Mute"] || [undoName containsString:@"Volume"]) {
                            ((void (*)(id, SEL))objc_msgSend)(um, @selector(undo));
                        } else {
                            // No mute action to undo — set to 0 dB as fallback
                            ((void (*)(id, SEL, double, BOOL, id))objc_msgSend)(
                                timelineModule, adjustVolSel, 0.0, NO, actionName);
                        }
                    } else {
                        // No undo available — set to 0 dB as fallback
                        ((void (*)(id, SEL, double, BOOL, id))objc_msgSend)(
                            timelineModule, adjustVolSel, 0.0, NO, actionName);
                    }
                }

                NSUInteger count = [selectedItems count];
                SpliceKit_log(@"[Audio] %@ audio on %lu clip(s)%s",
                              actionName,
                              (unsigned long)count,
                              autoSelected ? " (auto-selected at playhead)" : "");
                muteResult = @{
                    @"action": @"toggleMuteAudio",
                    @"status": @"ok",
                    @"audioMuted": @(shouldMute),
                    @"clipCount": @(count),
                    @"autoSelected": @(autoSelected)
                };
            } @catch (NSException *e) {
                muteResult = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
            }
        });
        return muteResult ?: @{@"error": @"Failed to toggle audio mute"};
    }

    if ([action isEqualToString:@"insertGap"]) {
        __block NSDictionary *gapResult = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id timeline = SpliceKit_getActiveTimelineModule();
                if (!timeline) {
                    gapResult = @{@"error": @"No active timeline module. Is a project open?"};
                    return;
                }
                gapResult = SpliceKit_directInsertGap(timeline);
            } @catch (NSException *e) {
                gapResult = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
            }
        });
        return gapResult ?: @{@"error": @"Failed to insert gap"};
    }

    if ([action isEqualToString:@"insertPlaceholder"]) {
        __block NSDictionary *placeholderResult = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id timeline = SpliceKit_getActiveTimelineModule();
                if (!timeline) {
                    placeholderResult = @{@"error": @"No active timeline module. Is a project open?"};
                    return;
                }
                placeholderResult = SpliceKit_directInsertPlaceholder(timeline);
            } @catch (NSException *e) {
                placeholderResult = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
            }
        });
        return placeholderResult ?: @{@"error": @"Failed to insert placeholder"};
    }

    NSString *selector = actionMap[action];
    if (!selector) {
        // Allow passing raw selector names too
        selector = action;
        if (![selector hasSuffix:@":"]) {
            selector = [selector stringByAppendingString:@":"];
        }
    }

    // Paste gets special treatment: FCP's own paste: only knows about its native
    // pasteboard format (FFPasteboardItem). If someone put FCPXML on the clipboard
    // instead, we need to route it through our XML import path or it'll be silently ignored.
    if ([action isEqualToString:@"paste"]) {
        __block BOOL hasXML = NO;
        SpliceKit_executeOnMainThread(^{
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            SEL containsXMLSel = NSSelectorFromString(@"containsXML");
            if ([pb respondsToSelector:containsXMLSel]) {
                hasXML = ((BOOL (*)(id, SEL))objc_msgSend)(pb, containsXMLSel);
            }
            // Also check if it's NOT native (native takes priority)
            if (hasXML) {
                NSString *nativeType = @"com.apple.flexo.proFFPasteboardUTI";
                if ([[pb types] containsObject:nativeType]) {
                    hasXML = NO; // Native data present, use normal paste path
                }
            }
        });
        if (hasXML) {
            return SpliceKit_handlePasteboardImportXML(@{});
        }
    }

    // addTodoMarker: doesn't exist as an IBAction on FFAnchoredTimelineModule or in the
    // responder chain. Use the direct sequence method that batch markers also uses.
    if ([action isEqualToString:@"addTodoMarker"]) {
        __block NSDictionary *todoResult = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id timeline = SpliceKit_getActiveTimelineModule();
                if (!timeline) { todoResult = @{@"error": @"No active timeline module. Is a project open?"}; return; }

                id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
                if (!sequence) { todoResult = @{@"error": @"No sequence in timeline"}; return; }

                // Get playhead time for marker position
                SpliceKit_CMTime playheadTime = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
                SpliceKit_CMTime frameDur = {100, 2400, 1, 0};
                SEL fdSel = NSSelectorFromString(@"frameDuration");
                if ([sequence respondsToSelector:fdSel]) {
                    SpliceKit_CMTime fd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, fdSel);
                    if (fd.timescale > 0) frameDur = fd;
                }

                // Find the primary-storyline clip at the playhead (timeline range via effectiveRangeOfObject:).
                id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                    ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
                id targetClip = nil;
                double targetClipTimelineStart = 0;
                double targetClipTimelineEnd = 0;
                double ph = SpliceKit_secondsFromTime(playheadTime);
                if (primaryObj && [primaryObj respondsToSelector:@selector(containedItems)]) {
                    id items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
                    if ([items isKindOfClass:[NSArray class]]) {
                        SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
                        if ([primaryObj respondsToSelector:erSel]) {
                            for (id item in (NSArray *)items) {
                                @try {
                                    SpliceKit_CMTimeRange itemRange = ((SpliceKit_CMTimeRange (*)(id, SEL, id))STRET_MSG)(
                                        primaryObj, erSel, item);
                                    double clipTimelineStart = SpliceKit_secondsFromTime(itemRange.start);
                                    double clipDur = SpliceKit_secondsFromTime(itemRange.duration);
                                    double clipTimelineEnd = clipTimelineStart + clipDur;
                                    if (ph >= clipTimelineStart - 0.01 && ph < clipTimelineEnd + 0.01) {
                                        targetClip = item;
                                        targetClipTimelineStart = clipTimelineStart;
                                        targetClipTimelineEnd = clipTimelineEnd;
                                        break;
                                    }
                                } @catch (NSException *e) {}
                            }
                        }
                    }
                }
                if (!targetClip) {
                    todoResult = @{@"error": @"No primary storyline clip at playhead"};
                    return;
                }

                SEL addSel = NSSelectorFromString(@"actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:");
                if (![sequence respondsToSelector:addSel]) {
                    todoResult = @{@"error": @"Sequence does not support actionAddMarkerToAnchoredObject:"};
                    return;
                }

                double clipDuration = targetClipTimelineEnd - targetClipTimelineStart;
                double localTime = ph - targetClipTimelineStart;
                if (localTime < -0.01 || localTime > clipDuration + 0.01) {
                    todoResult = @{@"error": [NSString stringWithFormat:
                        @"Playhead %.3fs is outside clip timeline range %.3f-%.3fs",
                        ph, targetClipTimelineStart, targetClipTimelineEnd]};
                    return;
                }

                NSDictionary *audioSrc = SpliceKit_audioSourceForItem(targetClip);
                double clipSourceStart = 0;
                BOOL sourceStartKnown = [audioSrc[@"sourceStartKnown"] boolValue];
                if (sourceStartKnown) {
                    clipSourceStart = [audioSrc[@"sourceStart"] doubleValue];
                }
                // actionAddMarkerToAnchoredObject: range.start is SOURCE MEDIA time (measured):
                // timeline = range.start - clipSourceStart + clipTimelineStart
                // => range.start = clipSourceStart + (T - clipTimelineStart).
                double rangeStartSeconds = clipSourceStart + localTime;
                int32_t ts = frameDur.timescale > 0 ? frameDur.timescale : 600;
                SpliceKit_CMTime markerTime = {(int64_t)llround(rangeStartSeconds * ts), ts, 1, 0};
                SpliceKit_CMTimeRange range = {markerTime, frameDur};
                NSError *err = nil;
                typedef BOOL (*AddMarkerFn)(id, SEL, id, BOOL, BOOL, SpliceKit_CMTimeRange, NSError **);
                BOOL ok = ((AddMarkerFn)objc_msgSend)(sequence, addSel, targetClip, YES, NO, range, &err);
                if (ok) {
                    NSMutableDictionary *okOut = [@{@"action": @"addTodoMarker", @"status": @"ok"} mutableCopy];
                    if (!sourceStartKnown) {
                        okOut[@"warning"] =
                            @"clip sourceStart unknown; used 0 for marker range (may be misplaced)";
                    }
                    todoResult = okOut;
                } else {
                    todoResult = @{@"error": err ? [err localizedDescription] : @"Failed to add todo marker"};
                }
            } @catch (NSException *e) {
                todoResult = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
            }
        });
        return todoResult ?: @{@"error": @"Failed to add todo marker"};
    }

    // First try on the timeline module directly (fastest, most specific)
    NSDictionary *result = SpliceKit_sendTimelineAction(selector);

    // If timeline module doesn't respond, fall back to responder chain
    if (result[@"error"]) {
        NSString *errMsg = result[@"error"];
        if ([errMsg containsString:@"does not respond"] || [errMsg containsString:@"No active"]) {
            result = SpliceKit_sendAppAction(selector);
        }
    }

    return result;
}
