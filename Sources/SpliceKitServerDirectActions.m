//
//  SpliceKitServerDirectActions.m
//  SpliceKit - timeline.directAction: Flexo's parameterized action* methods called
//  with real arguments; also the player/playback-context lookups, sendAppAction and
//  the playback.* handlers (play, seek, position) that sit in the same section.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Direct Flexo Action Methods (Parameterized)
//
// The actionMap above handles simple IBAction-style methods (void return, sender arg).
// But many of Flexo's editing methods take real parameters — rates, time values,
// error pointers, item arrays. This handler provides access to those richer APIs.
//
// Clients can either use friendly names ("retimeSetRate" with rate/ripple params)
// or pass raw selectors for full control. The friendly names are preferred because
// they handle parameter marshaling and validation.
//

static SpliceKit_CMTime SpliceKit_directActionFrameDuration(id timeline) {
    SpliceKit_CMTime frameDuration = {1, 24, 1, 0};
    SEL seqSel = @selector(sequence);
    if ([timeline respondsToSelector:seqSel]) {
        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        if (sequence) {
            SEL fdSel = NSSelectorFromString(@"frameDuration");
            if ([sequence respondsToSelector:fdSel]) {
                SpliceKit_CMTime fd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, fdSel);
                if (fd.timescale > 0 && fd.value > 0) frameDuration = fd;
            }
        }
    }
    return frameDuration;
}

// Nudge delta from timeline.directAction params. MCP tool direct_timeline_action can only
// send `frames` and `amount` (mapped to params[@"frames"] / params[@"amount"]). Raw JSON-RPC
// callers may also use deltaSeconds, seconds, or nudgeAmount — not exposed on the MCP tool.
static SpliceKit_CMTime SpliceKit_directActionNudgeDelta(NSDictionary *params, id timeline) {
    SpliceKit_CMTime frameDuration = SpliceKit_directActionFrameDuration(timeline);
    if (params[@"frames"] != nil) {
        long long frames = [params[@"frames"] longLongValue];
        if (frames == 0) frames = 1;
        SpliceKit_CMTime delta = frameDuration;
        delta.value = frames * frameDuration.value;
        return delta;
    }
    double seconds = 0.0;
    BOOL haveSeconds = NO;
    if (params[@"deltaSeconds"] != nil) {
        seconds = [params[@"deltaSeconds"] doubleValue];
        haveSeconds = YES;
    } else if (params[@"seconds"] != nil) {
        seconds = [params[@"seconds"] doubleValue];
        haveSeconds = YES;
    } else if (params[@"nudgeAmount"] != nil) {
        seconds = [params[@"nudgeAmount"] doubleValue];
        haveSeconds = YES;
    } else if (params[@"amount"] != nil) {
        seconds = [params[@"amount"] doubleValue];
        haveSeconds = YES;
    }
    if (haveSeconds) {
        int32_t timescale = frameDuration.timescale > 0 ? frameDuration.timescale : 24000;
        SpliceKit_CMTime t = {(int64_t)(seconds * timescale), timescale, 1, 0};
        return t;
    }
    return frameDuration;
}

static NSString *SpliceKit_fcpShortVersionString(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    return info[@"CFBundleShortVersionString"] ?: @"unknown";
}

NSDictionary *SpliceKit_directActionMissingSelectorError(id timeline, SEL sel, NSString *actionName) {
    if ([timeline respondsToSelector:sel]) {
        return nil;
    }
    NSString *selStr = NSStringFromSelector(sel);
    NSString *action = (actionName.length > 0) ? actionName : selStr;
    return @{
        @"error": [NSString stringWithFormat:@"%@ is not supported on this Final Cut Pro build", action],
        @"missingSelector": selStr,
        @"fcpVersion": SpliceKit_fcpShortVersionString(),
    };
}

NSDictionary *SpliceKit_handlePlaybackSeek(NSDictionary *params);
NSDictionary *SpliceKit_handlePlaybackGetPosition(NSDictionary *params);

// selectedItems is an array, a set, or a one-object proxy. Never assume firstObject is a marker:
// the live failure was an FFAnchoredClip sitting in that slot.
static NSArray *SpliceKit_directActionCollection(id container) {
    NSArray *items = SpliceKit_mixerArrayFromContainer(container);
    if (items) return items;
    if (container && [container respondsToSelector:@selector(firstObject)]) {
        @try {
            id first = ((id (*)(id, SEL))objc_msgSend)(container, @selector(firstObject));
            if (first) return @[first];
        } @catch (NSException *e) {}
    }
    return @[];
}

static id SpliceKit_directActionFirstMarkerLike(id container) {
    for (id item in SpliceKit_directActionCollection(container)) {
        if (SpliceKit_isMarkerLikeItem(item)) return item;
    }
    return nil;
}

// A marker whose timeline time is within a frame of the playhead. selectedItems is not consulted.
static id SpliceKit_markerAtPlayhead(id timeline, id sequence) {
    if (!timeline || !sequence || ![timeline respondsToSelector:@selector(playheadTime)]) return nil;
    SpliceKit_CMTime playhead = {0, 1, 0, 0};
    @try {
        playhead = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
    } @catch (NSException *e) {
        return nil;
    }
    SpliceKit_CMTime frame = SpliceKit_directActionFrameDuration(timeline);
    double playheadSeconds = SpliceKit_secondsFromTime(playhead);
    double frameSeconds = SpliceKit_secondsFromTime(frame);
    if (!(frameSeconds > 0)) frameSeconds = 1.0 / 24.0;

    SEL markersSel = NSSelectorFromString(@"markersInTimeRange:");
    if ([sequence respondsToSelector:markersSel]) {
        @try {
            double startSeconds = playheadSeconds - frameSeconds;
            if (startSeconds < 0) startSeconds = 0;
            int32_t ts = frame.timescale > 0 ? frame.timescale : 2400;
            SpliceKit_CMTimeRange window = {
                SpliceKit_timeFromSeconds(startSeconds, ts),
                SpliceKit_timeFromSeconds(frameSeconds * 2.0, ts)
            };
            id found = ((id (*)(id, SEL, SpliceKit_CMTimeRange))objc_msgSend)(sequence, markersSel, window);
            for (id marker in SpliceKit_directActionCollection(found)) {
                if (SpliceKit_isMarkerLikeItem(marker)) return marker;
            }
        } @catch (NSException *e) {}
    }

    id primary = [sequence respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
    NSArray *spine = nil;
    SEL itemsSel = NSSelectorFromString(@"containedItems");
    if (primary && [primary respondsToSelector:itemsSel]) {
        @try {
            spine = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(primary, itemsSel));
        } @catch (NSException *e) {
            spine = nil;
        }
    }
    for (id item in spine) {
        @try {
            if (primary) {
                SpliceKit_CMTimeRange itemRange = {{0, 0, 0, 0}, {0, 0, 0, 0}};
                if (SpliceKit_tryReadTimelineRange(primary, item, &itemRange)) {
                    double start = SpliceKit_secondsFromTime(itemRange.start);
                    double end = start + SpliceKit_secondsFromTime(itemRange.duration);
                    if (playheadSeconds < start - frameSeconds || playheadSeconds > end + frameSeconds) continue;
                }
            }
            NSMutableArray *children = [NSMutableArray array];
            SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
            if ([item respondsToSelector:anchoredSel]) {
                NSArray *anchored = SpliceKit_mixerArrayFromContainer(
                    ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel));
                if (anchored) [children addObjectsFromArray:anchored];
            }
            SEL itemMarkers = NSSelectorFromString(@"markers");
            if ([item respondsToSelector:itemMarkers]) {
                NSArray *markers = SpliceKit_mixerArrayFromContainer(
                    ((id (*)(id, SEL))objc_msgSend)(item, itemMarkers));
                if (markers) [children addObjectsFromArray:markers];
            }
            for (id child in children) {
                if (!SpliceKit_isMarkerLikeItem(child)) continue;
                if (!primary) return child;
                SpliceKit_CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
                if (!SpliceKit_tryReadTimelineRange(primary, child, &range)) continue;
                double t = SpliceKit_secondsFromTime(range.start);
                if (fabs(t - playheadSeconds) <= frameSeconds + 0.0005) return child;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSString *SpliceKit_directActionObjectLabel(id obj) {
    if (!obj) return @"nothing";
    NSString *cls = NSStringFromClass([obj class]) ?: @"object";
    NSString *name = SpliceKit_displayNameForItem(obj);
    if (name.length) return [NSString stringWithFormat:@"%@ \"%@\"", cls, name];
    return cls;
}

// Marker argument for the sequence's actionChangeMarker* methods.
// requireDisplayNameFlag: changeMarkerName's implementation sends setDisplayNameIsDefault:
// to that argument. FFAnchoredMarker answers it; FFAnchoredClip does not.
static NSDictionary *SpliceKit_directActionResolveMarker(id timeline, id sequence, NSDictionary *params,
                                                        id selectedItems, BOOL requireDisplayNameFlag,
                                                        id *outMarker) {
    if (outMarker) *outMarker = nil;
    NSString *handle = [params[@"marker"] isKindOfClass:[NSString class]] ? params[@"marker"] : nil;
    id candidate = nil;
    NSString *how = nil;
    if (handle.length) {
        candidate = SpliceKit_resolveHandle(handle);
        how = [NSString stringWithFormat:@"handle %@", handle];
        if (!candidate) {
            return @{@"error": [NSString stringWithFormat:
                @"No marker found for %@. Select a marker or pass a marker handle.", how]};
        }
    } else {
        candidate = SpliceKit_directActionFirstMarkerLike(selectedItems);
        if (candidate) {
            how = @"the selection";
        } else {
            candidate = SpliceKit_markerAtPlayhead(timeline, sequence);
            if (candidate) how = @"the marker at the playhead";
        }
    }
    if (!candidate) {
        id sample = SpliceKit_directActionCollection(selectedItems).firstObject;
        if (requireDisplayNameFlag && sample) {
            return @{@"error": [NSString stringWithFormat:
                @"No marker is selected and none is at the playhead. Found %@, which does not respond to setDisplayNameIsDefault:.",
                SpliceKit_directActionObjectLabel(sample)]};
        }
        if (sample) {
            return @{@"error": [NSString stringWithFormat:
                @"No marker is selected and none is at the playhead. Found %@.",
                SpliceKit_directActionObjectLabel(sample)]};
        }
        return @{@"error": @"No marker is selected and none is at the playhead."};
    }

    SEL flagSel = NSSelectorFromString(@"setDisplayNameIsDefault:");
    BOOL answersFlag = [candidate respondsToSelector:flagSel];
    if (requireDisplayNameFlag && !answersFlag) {
        return @{@"error": [NSString stringWithFormat:
            @"%@ is %@. setDisplayNameIsDefault: belongs on a marker (FFAnchoredMarker); this object does not respond to it.",
            how ?: @"The object", SpliceKit_directActionObjectLabel(candidate)]};
    }
    if (!requireDisplayNameFlag && !SpliceKit_isMarkerLikeItem(candidate)) {
        return @{@"error": [NSString stringWithFormat:
            @"No marker is selected and none is at the playhead. Found %@.",
            SpliceKit_directActionObjectLabel(candidate)]};
    }
    if (outMarker) *outMarker = candidate;
    return nil;
}

NSDictionary *SpliceKit_handleDirectTimelineAction(NSDictionary *params) {
    NSString *action = params[@"action"];
    NSString *rawSelector = params[@"selector"];

    if (!action && !rawSelector) {
        return @{@"error": @"action or selector parameter required"};
    }

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module. Is a project open?"};
                return;
            }

            // Get the root item (primaryObject of the sequence) - needed by most action methods
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline,
                NSSelectorFromString(@"sequence"));
            id rootItem = nil;
            if (sequence) {
                rootItem = ((id (*)(id, SEL))objc_msgSend)(sequence,
                    NSSelectorFromString(@"primaryObject"));
            }

            // Helper: get selected items
            id (^getSelectedItems)(void) = ^{
                SEL selSel = NSSelectorFromString(@"selectedItems");
                if ([timeline respondsToSelector:selSel]) {
                    return ((id (*)(id, SEL))objc_msgSend)(timeline, selSel);
                }
                return (id)nil;
            };

            // === Marker Operations ===
            // Markers are owned by the sequence, not the timeline module. The action
            // methods live on FFAnchoredSequence and take the marker object directly.

            if ([action isEqualToString:@"changeMarkerType"]) {
                if (!sequence) {
                    result = @{@"error": @"No sequence in timeline."};
                    return;
                }
                NSString *type = params[@"type"] ?: @"note";
                SEL sel;
                if ([type isEqualToString:@"chapter"]) {
                    sel = NSSelectorFromString(@"actionChangeMarkerTypeToChapter:error:");
                } else if ([type isEqualToString:@"todo"]) {
                    sel = NSSelectorFromString(@"actionChangeMarkerTypeToTodo:error:");
                } else {
                    sel = NSSelectorFromString(@"actionChangeMarkerTypeToNote:error:");
                }
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                id marker = nil;
                NSDictionary *markerError = SpliceKit_directActionResolveMarker(
                    timeline, sequence, params, getSelectedItems(), NO, &marker);
                if (markerError) { result = markerError; return; }
                NSError *error = nil;
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(sequence, sel, marker, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"type": type, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"changeMarkerName"]) {
                if (!sequence) {
                    result = @{@"error": @"No sequence in timeline."};
                    return;
                }
                // Rename a marker. The sequence method sends setDisplayNameIsDefault: to the
                // marker argument; a selected clip must not be passed in its place.
                NSString *name = params[@"name"];
                if (!name) { result = @{@"error": @"name parameter required"}; return; }
                id marker = nil;
                NSDictionary *markerError = SpliceKit_directActionResolveMarker(
                    timeline, sequence, params, getSelectedItems(), YES, &marker);
                if (markerError) { result = markerError; return; }
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionChangeMarkerDisplayName:marker:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, name, marker, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"name": name, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"markMarkerCompleted"]) {
                if (!sequence) {
                    result = @{@"error": @"No sequence in timeline."};
                    return;
                }
                // Mark a todo marker as completed
                id marker = nil;
                NSDictionary *markerError = SpliceKit_directActionResolveMarker(
                    timeline, sequence, params, getSelectedItems(), NO, &marker);
                if (markerError) { result = markerError; return; }
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionMarkMarkerAsCompleted:marker:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                BOOL completed = [params[@"completed"] boolValue];
                ((void (*)(id, SEL, BOOL, id, NSError **))objc_msgSend)(sequence, sel, completed, marker, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"removeMarker"]) {
                if (!sequence) {
                    result = @{@"error": @"No sequence in timeline."};
                    return;
                }
                id marker = params[@"marker"] ? SpliceKit_resolveHandle(params[@"marker"]) : nil;
                if (!marker) { result = @{@"error": @"marker handle required"}; return; }
                if (!SpliceKit_isMarkerLikeItem(marker)) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"%@ is not a marker. Found %@.",
                        params[@"marker"], SpliceKit_directActionObjectLabel(marker)]};
                    return;
                }
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRemoveMarker:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(sequence, sel, marker, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Retiming / Speed (Direct API) ===
            // These call Flexo's parameterized retime methods directly, bypassing the
            // simple IBAction wrappers. They give precise control over rate, ripple
            // behavior, and variable speed settings. Each one operates on selected items.

            if ([action isEqualToString:@"retimeSetRate"]) {
                // Set exact retime rate with ripple control
                double rate = [params[@"rate"] doubleValue];
                BOOL ripple = [params[@"ripple"] boolValue];
                BOOL allowVariable = params[@"allowVariableSpeed"] ? [params[@"allowVariableSpeed"] boolValue] : YES;
                if (rate <= 0) { result = @{@"error": @"rate must be > 0 (e.g. 0.5 for half speed, 2.0 for double)"}; return; }
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRetimeSetRatePreset:rate:ripple:allowVariableSpeedRetiming:objectsAndNewRanges:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, double, BOOL, BOOL, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, rate, ripple, allowVariable, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"rate": @(rate), @"ripple": @(ripple), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"retimeHoldPreset"]) {
                // Insert a hold/freeze frame at a specific time
                // This is the direct API for freeze-extend
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRetimeHoldPreset:holdComponentTime:duration:newHoldComponentTime:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                // holdComponentTime and duration come from the selected clip context
                ((void (*)(id, SEL, id, id, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, nil, nil, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"retimeReverse"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRetimeReverseClipPreset:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, selectedItems, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"retimeBladeSpeedPreset"]) {
                // Blade at a speed segment boundary
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRetimeBladeSpeedPreset:componentTime:newComponentTime:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, nil, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"retimeSpeedRamp"]) {
                BOOL toZero = [params[@"toZero"] boolValue];
                BOOL fromZero = [params[@"fromZero"] boolValue];
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRetimeSpeedRampPreset:startComponentTime:endComponentTime:toZero:fromZero:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, id, BOOL, BOOL, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, nil, nil, toZero, fromZero, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"toZero": @(toZero), @"fromZero": @(fromZero), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"retimeInstantReplay"]) {
                double rate = params[@"rate"] ? [params[@"rate"] doubleValue] : 0.5;
                BOOL allowVariable = params[@"allowVariableSpeed"] ? [params[@"allowVariableSpeed"] boolValue] : YES;
                BOOL addTitle = params[@"addTitle"] ? [params[@"addTitle"] boolValue] : YES;
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRetimeInstantReplayPreset:range:rate:allowVariableSpeedRetiming:addTitle:objectsAndNewRanges:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, double, BOOL, BOOL, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, nil, rate, allowVariable, addTitle, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"rate": @(rate), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"retimeJumpCut"]) {
                int framesToJump = params[@"framesToJump"] ? [params[@"framesToJump"] intValue] : 5;
                BOOL allowVariable = params[@"allowVariableSpeed"] ? [params[@"allowVariableSpeed"] boolValue] : YES;
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRetimeJumpCutPreset:framesToJump:allowVariableSpeedRetiming:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, int, BOOL, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, framesToJump, allowVariable, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"framesToJump": @(framesToJump), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"retimeRewind"]) {
                double rewindSpeed = params[@"speed"] ? [params[@"speed"] doubleValue] : 2.0;
                BOOL allowVariable = params[@"allowVariableSpeed"] ? [params[@"allowVariableSpeed"] boolValue] : YES;
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRetimeRewindPreset:rewindSpeed:allowVariableSpeedRetiming:objectsAndNewRanges:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, double, BOOL, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, rewindSpeed, allowVariable, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"speed": @(rewindSpeed), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"retimeSetInterpolation"]) {
                // Set interpolation type on retime segments
                id selectedItems = getSelectedItems();
                NSString *interpolation = params[@"interpolation"];
                SEL sel = NSSelectorFromString(@"actionRetimeSetInterpolation:edits:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id))objc_msgSend)(timeline, sel, interpolation, selectedItems);
                result = @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Trim / Edit (Direct API) ===
            // More precise than the IBAction trim commands, which are mode-dependent
            // and coarse. These take explicit parameters and return errors properly.

            if ([action isEqualToString:@"splitAtTime"]) {
                // Same mechanism as timeline.bladeAtTimes: seek (when time given) + blade:
                static NSString * const kBladeSelector = @"blade:";
                SEL bladeSel = NSSelectorFromString(kBladeSelector);
                SEL canBladeSel = NSSelectorFromString(@"canBlade:");

                if (![timeline respondsToSelector:bladeSel]) {
                    result = @{@"error": @"Timeline module does not respond to blade:"};
                    return;
                }

                BOOL movedPlayhead = NO;
                BOOL havePlayheadBefore = NO;
                double playheadBefore = 0.0;
                double splitAtSeconds = 0.0;
                NSNumber *timeParam = params[@"time"];

                if (timeParam != nil) {
                    splitAtSeconds = [timeParam doubleValue];
                    NSDictionary *before = SpliceKit_handlePlaybackGetPosition(@{});
                    if ([before[@"seconds"] isKindOfClass:[NSNumber class]]) {
                        playheadBefore = [before[@"seconds"] doubleValue];
                        havePlayheadBefore = YES;
                    }
                    NSDictionary *seek = SpliceKit_handlePlaybackSeek(@{@"seconds": @(splitAtSeconds)});
                    if (seek[@"error"]) {
                        result = @{@"error": seek[@"error"]};
                        return;
                    }
                    movedPlayhead = YES;
                    [NSThread sleepForTimeInterval:0.03];
                } else {
                    NSDictionary *pos = SpliceKit_handlePlaybackGetPosition(@{});
                    if ([pos[@"seconds"] isKindOfClass:[NSNumber class]]) {
                        splitAtSeconds = [pos[@"seconds"] doubleValue];
                    }
                }

                if ([timeline respondsToSelector:canBladeSel]) {
                    BOOL canBlade = ((BOOL (*)(id, SEL, id))objc_msgSend)(timeline, canBladeSel, nil);
                    if (!canBlade) {
                        BOOL restored = NO;
                        if (movedPlayhead && havePlayheadBefore) {
                            SpliceKit_handlePlaybackSeek(@{@"seconds": @(playheadBefore)});
                            restored = YES;
                        }
                        result = @{
                            @"error": movedPlayhead
                                ? @"Final Cut Pro cannot blade at the requested time (canBlade: returned NO)"
                                : @"Final Cut Pro cannot blade at the current playhead (canBlade: returned NO)",
                            @"playheadMoved": @(movedPlayhead),
                            @"playheadRestored": @(restored),
                        };
                        return;
                    }
                }

                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(timeline, bladeSel, nil);
                } @catch (NSException *e) {
                    BOOL restored = NO;
                    if (movedPlayhead && havePlayheadBefore) {
                        SpliceKit_handlePlaybackSeek(@{@"seconds": @(playheadBefore)});
                        restored = YES;
                    }
                    result = @{
                        @"error": [NSString stringWithFormat:@"Exception: %@", e.reason],
                        @"playheadMoved": @(movedPlayhead),
                        @"playheadRestored": @(restored),
                    };
                    return;
                }

                BOOL playheadRestored = NO;
                if (movedPlayhead && havePlayheadBefore) {
                    SpliceKit_handlePlaybackSeek(@{@"seconds": @(playheadBefore)});
                    NSDictionary *after = SpliceKit_handlePlaybackGetPosition(@{});
                    double playheadAfter = playheadBefore;
                    if ([after[@"seconds"] isKindOfClass:[NSNumber class]]) {
                        playheadAfter = [after[@"seconds"] doubleValue];
                    }
                    playheadRestored = (fabs(playheadAfter - playheadBefore) < 0.001);
                }

                result = @{
                    @"action": kBladeSelector,
                    @"status": @"ok",
                    @"splitAtSeconds": @(splitAtSeconds),
                    @"playheadMoved": @(movedPlayhead),
                    @"playheadRestored": @(playheadRestored),
                };
                return;
            }

            if ([action isEqualToString:@"trimDuration"]) {
                // Trim selected edits to a specific duration
                BOOL isDelta = params[@"isDelta"] ? [params[@"isDelta"] boolValue] : NO;
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionTrimDuration:forEdits:isDelta:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, BOOL, NSError **))objc_msgSend)(
                    timeline, sel, nil, selectedItems, isDelta, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"extendOverNextClip"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionExtendOverNextClip:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, selectedItems, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"joinThroughEdits"]) {
                SEL joinSel = NSSelectorFromString(@"_joinSelectedThroughEdits");
                if (![timeline respondsToSelector:joinSel]) {
                    result = @{@"error": @"Timeline module does not respond to _joinSelectedThroughEdits"};
                    return;
                }
                SEL canSel = NSSelectorFromString(@"_canJoinThroughEditAtSelectedEdges");
                if ([timeline respondsToSelector:canSel]) {
                    BOOL canJoin = ((BOOL (*)(id, SEL))objc_msgSend)(timeline, canSel);
                    if (!canJoin) {
                        result = @{@"error": @"Final Cut Pro will not join through edits here — this needs edit EDGES selected (the Trim tool), not whole clips selected."};
                        return;
                    }
                }
                ((void (*)(id, SEL))objc_msgSend)(timeline, joinSel);
                result = @{@"action": @"_joinSelectedThroughEdits", @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"removeEdits"]) {
                BOOL replaceWithGap = params[@"replaceWithGap"] ? [params[@"replaceWithGap"] boolValue] : NO;
                id selectedItems = getSelectedItems();
                SEL sel = NSSelectorFromString(@"_deleteCore:replaceWithGap:removeOperation:");
                if (![timeline respondsToSelector:sel]) {
                    result = @{@"error": @"Timeline module does not respond to _deleteCore:replaceWithGap:removeOperation:"};
                    return;
                }
                ((void (*)(id, SEL, id, BOOL, int))objc_msgSend)(
                    timeline, sel, selectedItems, replaceWithGap, 0);
                result = @{
                    @"action": @"_deleteCore:replaceWithGap:removeOperation:",
                    @"replaceWithGap": @(replaceWithGap),
                    @"status": @"ok"
                };
                return;
            }

            if ([action isEqualToString:@"insertGapDirect"]) {
                result = SpliceKit_directInsertGap(timeline);
                if (result[@"status"]) {
                    NSMutableDictionary *out = [result mutableCopy];
                    out[@"action"] = action;
                    result = out;
                }
                return;
            }

            if ([action isEqualToString:@"insertFreezeFrame"]) {
                SEL sel = NSSelectorFromString(@"freezeFrame:");
                if (![timeline respondsToSelector:sel]) {
                    result = @{@"error": @"Timeline module does not respond to freezeFrame:"};
                    return;
                }
                SEL canSel = NSSelectorFromString(@"canFreezeFrame:");
                if ([timeline respondsToSelector:canSel]) {
                    BOOL canFreeze = ((BOOL (*)(id, SEL, id))objc_msgSend)(timeline, canSel, nil);
                    if (!canFreeze) {
                        result = @{@"error": @"Final Cut Pro cannot insert a freeze frame with the current selection or playhead"};
                        return;
                    }
                }
                ((void (*)(id, SEL, id))objc_msgSend)(timeline, sel, nil);
                result = @{@"action": @"freezeFrame:", @"status": @"ok"};
                return;
            }

            // === Nudge (Direct API with amounts) ===

            if ([action isEqualToString:@"nudgeAnchoredItems"]) {
                SEL sel = NSSelectorFromString(@"_nudgeAnchorObjectWithDelta:");
                if (![timeline respondsToSelector:sel]) {
                    result = @{@"error": @"Timeline module does not respond to _nudgeAnchorObjectWithDelta:"};
                    return;
                }
                SpliceKit_CMTime delta = SpliceKit_directActionNudgeDelta(params, timeline);
                typedef BOOL (*NudgeAnchorFn)(id, SEL, SpliceKit_CMTime);
                BOOL ok = ((NudgeAnchorFn)objc_msgSend)(timeline, sel, delta);
                if (!ok) {
                    result = @{@"error": @"Final Cut Pro could not nudge anchored items by the requested amount"};
                    return;
                }
                result = @{
                    @"action": @"_nudgeAnchorObjectWithDelta:",
                    @"delta": SpliceKit_serializeCMTime(delta),
                    @"status": @"ok"
                };
                return;
            }

            if ([action isEqualToString:@"nudgeSpineItems"]) {
                SEL sel = NSSelectorFromString(@"_nudgeSpineObjectWithDelta:");
                if (![timeline respondsToSelector:sel]) {
                    result = @{@"error": @"Timeline module does not respond to _nudgeSpineObjectWithDelta:"};
                    return;
                }
                SpliceKit_CMTime delta = SpliceKit_directActionNudgeDelta(params, timeline);
                typedef BOOL (*NudgeSpineFn)(id, SEL, SpliceKit_CMTime);
                BOOL ok = ((NudgeSpineFn)objc_msgSend)(timeline, sel, delta);
                if (!ok) {
                    result = @{@"error": @"Final Cut Pro could not nudge spine items by the requested amount"};
                    return;
                }
                result = @{
                    @"action": @"_nudgeSpineObjectWithDelta:",
                    @"delta": SpliceKit_serializeCMTime(delta),
                    @"status": @"ok"
                };
                return;
            }

            // === Audio Operations ===
            // Direct audio manipulation — volume (absolute or relative dB), fades,
            // background music flag, audio detach, and A/V sync alignment.

            if ([action isEqualToString:@"changeAudioVolume"]) {
                double amount = [params[@"amount"] doubleValue];
                BOOL isRelative = params[@"relative"] ? [params[@"relative"] boolValue] : YES;
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionChangeAudioVolume:byAmount:overRange:isRelative:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, double, id, BOOL, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, amount, nil, isRelative, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"amount": @(amount), @"relative": @(isRelative), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"applyAudioFadesDirect"]) {
                BOOL fadeIn = params[@"fadeIn"] ? [params[@"fadeIn"] boolValue] : YES;
                double duration = params[@"duration"] ? [params[@"duration"] doubleValue] : 0.5;
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionApplyAudioFades:objects:fadeInNotOut:fadeDuration:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, BOOL, double, NSError **))objc_msgSend)(
                    timeline, sel, nil, selectedItems, fadeIn, duration, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"fadeIn": @(fadeIn), @"duration": @(duration), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"setAudioPlayEnable"]) {
                BOOL enabled = params[@"enabled"] ? [params[@"enabled"] boolValue] : YES;
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionSetAudioPlayEnable:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, BOOL, NSError **))objc_msgSend)(timeline, sel, enabled, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"enabled": @(enabled), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"setBackgroundMusic"]) {
                BOOL isBackground = params[@"enabled"] ? [params[@"enabled"] boolValue] : YES;
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionSetBackgroundMusic:isBackgroundMusic:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, isBackground, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"enabled": @(isBackground), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"detachAudioDirect"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionDetachAudio:newDetachedEdits:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"alignAudioToVideoDirect"]) {
                id selectedItems = getSelectedItems();
                SEL sel = NSSelectorFromString(@"actionAlignAudioToVideo:endEdits:container:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                    timeline, sel, selectedItems, nil, rootItem);
                result = @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Multicam / Angles ===
            // FCP's multicam clips have "angles" that can be renamed, deleted,
            // or audio-synced independently.

            if ([action isEqualToString:@"deleteMultiAngle"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionDeleteMultiAngle:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, selectedItems, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"renameAngle"]) {
                NSString *newName = params[@"name"];
                if (!newName) { result = @{@"error": @"name parameter required"}; return; }
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRenameAngle:newName:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, newName, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"name": newName, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"audioSyncMultiAngle"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionAudioSyncMultiAngleItems:rootItem:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, rootItem, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Keywords / Roles ===
            // Keywords are FCP's tagging system. Roles control audio/video routing
            // for export (Dialogue, Music, Effects, Titles, etc).

            if ([action isEqualToString:@"addKeywords"]) {
                NSArray *keywords = params[@"keywords"];
                if (!keywords) { result = @{@"error": @"keywords array required"}; return; }
                NSSet *keywordSet = [NSSet setWithArray:keywords];
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionAddKeywordsWithNames:forRange:animationHint:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, int, NSError **))objc_msgSend)(
                    timeline, sel, keywordSet, nil, 0, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"keywords": keywords, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"removeKeywords"]) {
                NSArray *keywords = params[@"keywords"];
                if (!keywords) { result = @{@"error": @"keywords array required"}; return; }
                NSSet *keywordSet = [NSSet setWithArray:keywords];
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRemoveKeywordsWithNames:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, keywordSet, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Effects / Masks ===
            // Manipulate effects on selected clips: remove by ID, invert masks,
            // toggle enabled state.

            if ([action isEqualToString:@"removeEffectByID"]) {
                NSString *effectID = params[@"effectID"];
                if (!effectID) { result = @{@"error": @"effectID parameter required"}; return; }
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRemoveEffectID:fromAnchoredObjects:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, effectID, selectedItems, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"effectID": effectID, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"invertEffectMasks"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionInvertEffectMasks:actionName:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, @"Invert Mask", &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"toggleEnabled"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionToggleEnabled:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, selectedItems, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Clip Operations ===
            // Structural operations on clips: break apart compound clips, create new
            // compound clips, lift from storyline, rename, delete, move to trash.

            if ([action isEqualToString:@"breakApartClipItems"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionBreakApartClipItems:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, selectedItems, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"createCompoundClipDirect"]) {
                BOOL multiClip = [params[@"multicam"] boolValue];
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionCreateCompoundClip:multiClip:spine:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, BOOL, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, multiClip, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"multicam": @(multiClip), @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"liftAnchoredEdits"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionLiftAnchoredEdits:rootItem:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, rootItem, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"renameDirect"]) {
                NSString *newName = params[@"name"];
                if (!newName) { result = @{@"error": @"name parameter required"}; return; }
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRename:actionName:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, newName, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"name": newName, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"deleteItemsInArray"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionDeleteItemsInArray:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, selectedItems, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"moveClipsToTrash"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionMoveClipsToTrash:mediaRefsToDelete:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Captions ===
            // Duplicate captions to a different language/format for localization.

            if ([action isEqualToString:@"duplicateCaptions"]) {
                NSString *language = params[@"language"] ?: @"en";
                NSString *format = params[@"format"] ?: @"ITT";
                id selectedItems = getSelectedItems();
                SEL sel = NSSelectorFromString(@"actionDuplicateCaptions:toLanguageIdentifier:andCaptionFormat:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                    timeline, sel, selectedItems, language, format);
                result = @{@"action": action, @"language": language, @"format": format, @"status": @"ok"};
                return;
            }

            // === Audition / Variants ===
            // Auditions let you stack multiple takes in one timeline slot and cycle
            // through them. "Variants" are the individual takes within an audition.

            if ([action isEqualToString:@"addVariants"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionAddVariants:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, selectedItems, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"removeVariants"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionRemoveVariants:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, selectedItems, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"finalizeVariant"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionFinalizePickFromVariant:rootItem:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, rootItem, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Project / Library ===

            if ([action isEqualToString:@"newProject"]) {
                NSString *name = params[@"name"] ?: @"Untitled";
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionNewProject:name:sequence:actionName:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, id, id, NSError **))objc_msgSend)(
                    timeline, sel, nil, name, nil, @"New Project", &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"name": name, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"newEvent"]) {
                NSString *name = params[@"name"] ?: @"New Event";
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionNewEvent:name:actionName:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, id, NSError **))objc_msgSend)(
                    timeline, sel, nil, name, @"New Event", &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"name": name, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"validateAndRepair"]) {
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionValidateAndRepair:validateMode:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, int, NSError **))objc_msgSend)(
                    timeline, sel, nil, 0, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Auto-reframe (Direct) ===

            if ([action isEqualToString:@"autoReframeDirect"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionAutoReframe:forContainer:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, rootItem, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Music alignment ===

            if ([action isEqualToString:@"alignToMusicMarkers"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionAlignToMusicMarkers:rootItem:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, rootItem, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"alignClipsAtMusicMarkers"]) {
                BOOL asSplit = [params[@"asSplit"] boolValue];
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionAlignClipsAtMusicMarkersOnItems:rootItem:asSplit:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, BOOL, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, rootItem, asSplit, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"asSplit": @(asSplit), @"status": @"ok"};
                return;
            }

            // === Transition operations (Direct) ===

            if ([action isEqualToString:@"addTransitionsDirect"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionAddTransitionsToSpineObjects:before:after:effects:transitionOverlapType:transitionsCreated:rootItem:reportErrors:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, id, id, int, id, id, BOOL, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, nil, nil, nil, 0, nil, rootItem, YES, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Analyze and optimize ===

            if ([action isEqualToString:@"analyzeAndOptimize"]) {
                id selectedItems = getSelectedItems();
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionPerformAnalyzeAndOptimizeClips:options:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, selectedItems, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Lane conflict resolution ===

            if ([action isEqualToString:@"resolveLaneConflicts"]) {
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionResolveLaneConflictsInContainer:excludedItems:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                    timeline, sel, rootItem, nil, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            if ([action isEqualToString:@"resolveLaneGaps"]) {
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionResolveLaneGapsInContainer:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, rootItem, &error);
                result = error ? @{@"error": error.localizedDescription}
                               : @{@"action": action, @"status": @"ok"};
                return;
            }

            // === Fallback: raw selector invocation ===
            // If a selector string is provided directly, try to call it on the timeline module
            if (rawSelector) {
                SEL sel = NSSelectorFromString(rawSelector);
                if ([rawSelector hasPrefix:@"action"]) {
                    NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(
                        timeline, sel, rawSelector);
                    if (missingSel) {
                        result = missingSel;
                        return;
                    }
                } else if (![timeline respondsToSelector:sel]) {
                    result = @{@"error": [NSString stringWithFormat:@"Timeline module does not respond to %@", rawSelector]};
                    return;
                }
                // Count colons to determine argument count
                NSUInteger colonCount = [[rawSelector componentsSeparatedByString:@":"] count] - 1;
                if (colonCount == 0) {
                    ((void (*)(id, SEL))objc_msgSend)(timeline, sel);
                } else if (colonCount == 1) {
                    ((void (*)(id, SEL, id))objc_msgSend)(timeline, sel, nil);
                } else if (colonCount == 2) {
                    NSError *error = nil;
                    ((void (*)(id, SEL, id, NSError **))objc_msgSend)(timeline, sel, nil, &error);
                    if (error) { result = @{@"error": error.localizedDescription}; return; }
                } else {
                    // For 3+ args, pass nils - caller should use call_method for full control
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(timeline, sel, nil, nil, nil);
                }
                result = @{@"selector": rawSelector, @"status": @"ok"};
                return;
            }

            result = @{@"error": [NSString stringWithFormat:@"Unknown direct action: %@", action]};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

static id SpliceKit_getAppDelegate(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    return app ? ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate)) : nil;
}

static id SpliceKit_getCompareViewerContainer(void) {
    id delegate = SpliceKit_getAppDelegate();
    SEL compareSel = NSSelectorFromString(@"compareViewer");
    if (delegate && [delegate respondsToSelector:compareSel]) {
        id viewer = ((id (*)(id, SEL))objc_msgSend)(delegate, compareSel);
        if (viewer) return viewer;
    }
    return nil;
}

static id SpliceKit_getContextFromPlayerContainer(id container) {
    if (!container) return nil;

    SEL contextSel = NSSelectorFromString(@"context");
    if ([container respondsToSelector:contextSel]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(container, contextSel);
        if (context) return context;
    }

    for (NSString *playerSelName in @[@"viewerPlayerModule", @"canvasPlayerModule", @"_activePlayerModule"]) {
        SEL playerSel = NSSelectorFromString(playerSelName);
        if (![container respondsToSelector:playerSel]) continue;

        id playerModule = ((id (*)(id, SEL))objc_msgSend)(container, playerSel);
        if (!playerModule) continue;
        if (![playerModule respondsToSelector:contextSel]) continue;

        id context = ((id (*)(id, SEL))objc_msgSend)(playerModule, contextSel);
        if (context) return context;
    }

    return nil;
}

static id SpliceKit_getPlayerModuleFromPlayerContainer(id container) {
    if (!container) return nil;

    for (NSString *selName in @[@"viewerPlayerModule", @"canvasPlayerModule", @"_activePlayerModule"]) {
        SEL sel = NSSelectorFromString(selName);
        if (![container respondsToSelector:sel]) continue;

        id playerModule = ((id (*)(id, SEL))objc_msgSend)(container, sel);
        if (playerModule) return playerModule;
    }

    SEL modulesSel = NSSelectorFromString(@"playerModules");
    if ([container respondsToSelector:modulesSel]) {
        id modules = ((id (*)(id, SEL))objc_msgSend)(container, modulesSel);
        SEL firstSel = NSSelectorFromString(@"firstObject");
        if (modules && [modules respondsToSelector:firstSel]) {
            id firstPlayerModule = ((id (*)(id, SEL))objc_msgSend)(modules, firstSel);
            if (firstPlayerModule) return firstPlayerModule;
        }
    }

    return nil;
}

// Get the FFPlayerModule from editor container
id SpliceKit_getPlayerModule(void) {
    id container = SpliceKit_getEditorContainer();

    // Try playerModule or editorModule.playerModule
    SEL pmSel = NSSelectorFromString(@"playerModule");
    if (container && [container respondsToSelector:pmSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(container, pmSel);
    }
    // Try through editorModule
    SEL emSel = NSSelectorFromString(@"editorModule");
    if (container && [container respondsToSelector:emSel]) {
        id editor = ((id (*)(id, SEL))objc_msgSend)(container, emSel);
        if (editor && [editor respondsToSelector:pmSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(editor, pmSel);
        }
    }

    id compareViewer = SpliceKit_getCompareViewerContainer();
    id compareViewerPlayer = SpliceKit_getPlayerModuleFromPlayerContainer(compareViewer);
    if (compareViewerPlayer) return compareViewerPlayer;

    return nil;
}

// Resolve the playback context used by the active timeline/player.
id SpliceKit_getPlaybackContext(void) {
    id timeline = SpliceKit_getActiveTimelineModule();
    SEL contextSel = NSSelectorFromString(@"context");
    if (timeline && [timeline respondsToSelector:contextSel]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(timeline, contextSel);
        if (context) return context;
    }

    SEL selectionContextSel = NSSelectorFromString(@"selectionContext");
    if (timeline && [timeline respondsToSelector:selectionContextSel]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(timeline, selectionContextSel);
        if (context) return context;
    }

    id playerModule = SpliceKit_getPlayerModule();
    if (playerModule && [playerModule respondsToSelector:contextSel]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(playerModule, contextSel);
        if (context) return context;
    }

    id compareViewer = SpliceKit_getCompareViewerContainer();
    id compareViewerContext = SpliceKit_getContextFromPlayerContainer(compareViewer);
    if (compareViewerContext) return compareViewerContext;

    return nil;
}

static id SpliceKit_getAudioDestFromContext(id context) {
    if (!context) return nil;

    SEL audioDestSel = NSSelectorFromString(@"audioDest");
    if ([context respondsToSelector:audioDestSel]) {
        id audioDest = ((id (*)(id, SEL))objc_msgSend)(context, audioDestSel);
        if (audioDest) return audioDest;
    }

    Ivar ivar = class_getInstanceVariable([context class], "_audioDest");
    if (ivar) {
        id audioDest = object_getIvar(context, ivar);
        if (audioDest) return audioDest;
    }

    @try {
        id audioDest = [context valueForKey:@"audioDest"];
        if (audioDest) return audioDest;
    } @catch (NSException *e) {}

    return nil;
}

// The playback context owns the program-output audio destination.
id SpliceKit_getMasterAudioDest(void) {
    id timeline = SpliceKit_getActiveTimelineModule();
    SEL contextSel = NSSelectorFromString(@"context");
    if (timeline && [timeline respondsToSelector:contextSel]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(timeline, contextSel);
        id audioDest = SpliceKit_getAudioDestFromContext(context);
        if (audioDest) return audioDest;
    }

    SEL selectionContextSel = NSSelectorFromString(@"selectionContext");
    if (timeline && [timeline respondsToSelector:selectionContextSel]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(timeline, selectionContextSel);
        id audioDest = SpliceKit_getAudioDestFromContext(context);
        if (audioDest) return audioDest;
    }

    id playerModule = SpliceKit_getPlayerModule();
    if (playerModule && [playerModule respondsToSelector:contextSel]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(playerModule, contextSel);
        id audioDest = SpliceKit_getAudioDestFromContext(context);
        if (audioDest) return audioDest;
    }

    id compareViewer = SpliceKit_getCompareViewerContainer();
    id compareViewerContext = SpliceKit_getContextFromPlayerContainer(compareViewer);
    id compareViewerAudioDest = SpliceKit_getAudioDestFromContext(compareViewerContext);
    if (compareViewerAudioDest) return compareViewerAudioDest;

    id fallbackContext = SpliceKit_getPlaybackContext();
    id fallbackAudioDest = SpliceKit_getAudioDestFromContext(fallbackContext);
    if (fallbackAudioDest) return fallbackAudioDest;

    return nil;
}

// Fire sendAction on the main run loop without waiting — used when the action opens a modal
// save/open panel that blocks the main thread until the user dismisses it.
NSDictionary *SpliceKit_sendAppActionAsyncNoWait(NSString *selectorName) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            SEL sel = NSSelectorFromString(selectorName);
            ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                app, @selector(sendAction:to:from:), sel, nil, nil);
        } @catch (NSException *e) {
            SpliceKit_log(@"[AppAction] async %@ exception: %@", selectorName, e.reason);
        }
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    return @{@"action": selectorName, @"status": @"ok"};
}

// Send action via NSApp.sendAction:to:from: (goes through responder chain)
NSDictionary *SpliceKit_sendAppAction(NSString *selectorName) {
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            SEL sel = NSSelectorFromString(selectorName);
            BOOL sent = ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                app, @selector(sendAction:to:from:), sel, nil, nil);
            if (sent) {
                result = @{@"action": selectorName, @"status": @"ok"};
            } else {
                result = @{@"error": [NSString stringWithFormat:
                    @"No responder handled %@", selectorName]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    if (result) return result;
    if ([selectorName isEqualToString:@"newLibrary:"]) {
        return SpliceKit_makeFilePanelDialogPendingDictionary(@"createLibrary", nil);
    }
    if ([selectorName isEqualToString:@"newEvent:"]) {
        return SpliceKit_makeFilePanelDialogPendingDictionary(@"createEvent", nil);
    }
    if ([selectorName isEqualToString:@"newProject:"]) {
        return SpliceKit_makeFilePanelDialogPendingDictionary(@"createProject", nil);
    }
    return @{@"error": @"App action did not return a result (main thread may have timed out). "
             @"A modal save/open panel may be open; while it is up the bridge cannot serve "
             @"main-thread RPC. dismiss_dialog(action=\"cancel\") closes save/open panels."};
}

NSDictionary *SpliceKit_handlePlayback(NSDictionary *params) {
    NSString *action = params[@"action"];
    if (!action) return @{@"error": @"action parameter required"};

    // All playback actions go through the responder chain (NSApp.sendAction:to:from:)
    // This is how FCP's menu items work - they route to FFPlayerModule,
    // PEEditorContainerModule, etc. automatically.
    NSDictionary *actionMap = @{
        @"playPause":         @"playPause:",
        @"goToStart":         @"gotoStart:",
        @"goToEnd":           @"gotoEnd:",
        @"nextFrame":         @"stepForward:",
        @"prevFrame":         @"stepBackward:",
        @"nextFrame10":       @"stepForward10Frames:",
        @"prevFrame10":       @"stepBackward10Frames:",
        @"playAroundCurrent": @"playAroundCurrentFrame:",
        @"playFromStart":    @"playFromStart:",
        @"playInToOut":      @"playInToOut:",
        @"playReverse":      @"playReverse:",
        @"stopPlaying":      @"stopPlaying:",
        @"loop":             @"loop:",
        @"fastForward":      @"fastForward:",
        @"rewind":           @"rewind:",
        // Named rate presets (JKL-style)
        @"playRate1X":        @"playRate1X:",
        @"playRate2X":        @"playRate2X:",
        @"playRate4X":        @"playRate4X:",
        @"playRate8X":        @"playRate8X:",
        @"playRate16X":       @"playRate16X:",
        @"playRate32X":       @"playRate32X:",
        @"playRateHalf":      @"playRateHalf:",
        @"playRateMinusHalf": @"playRateMinusHalf:",
        @"playRateMinus1X":   @"playRateMinus1X:",
        @"playRateMinus2X":   @"playRateMinus2X:",
        @"playRateMinus32X":  @"playRateMinus32X:",
    };

    NSString *selector = actionMap[action];
    if (!selector) {
        selector = action;
        if (![selector hasSuffix:@":"]) {
            selector = [selector stringByAppendingString:@":"];
        }
    }

    return SpliceKit_sendAppAction(selector);
}

NSDictionary *SpliceKit_handlePlaybackSeek(NSDictionary *params) {
    NSNumber *seconds = params[@"seconds"];
    if (!seconds) return @{@"error": @"seconds parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            // Get the sequence timescale for accurate time construction
            int32_t timescale = 24000; // default
            SEL seqSel = @selector(sequence);
            if ([timeline respondsToSelector:seqSel]) {
                id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                if (sequence) {
                    // Try to get frameDuration to derive timescale
                    // On ARM64, objc_msgSend handles struct returns directly
                    SEL fdSel = NSSelectorFromString(@"frameDuration");
                    if ([sequence respondsToSelector:fdSel]) {
                        SpliceKit_CMTime fd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(
                            sequence, fdSel);
                        if (fd.timescale > 0) timescale = fd.timescale;
                    }
                }
            }

            // Build CMTime from seconds
            double secs = [seconds doubleValue];
            SpliceKit_CMTime targetTime;
            targetTime.value = (int64_t)(secs * timescale);
            targetTime.timescale = timescale;
            targetTime.flags = 1; // kCMTimeFlags_Valid
            targetTime.epoch = 0;

            // Call setPlayheadTime: on the timeline module
            SEL setSel = @selector(setPlayheadTime:);
            if ([timeline respondsToSelector:setSel]) {
                ((void (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                    timeline, setSel, targetTime);
                result = @{
                    @"status": @"ok",
                    @"seconds": @(secs),
                    @"time": SpliceKit_serializeCMTime(targetTime),
                };
            } else {
                result = @{@"error": @"Timeline module does not respond to setPlayheadTime:"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to seek"};
}

NSDictionary *SpliceKit_handlePlaybackGetPosition(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            // Read playhead time
            SEL phSel = NSSelectorFromString(@"playheadTime");
            if ([timeline respondsToSelector:phSel]) {
                SpliceKit_CMTime pht = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timeline, phSel);
                double seconds = (pht.timescale > 0) ? (double)pht.value / pht.timescale : 0;

                NSMutableDictionary *r = [NSMutableDictionary dictionary];
                r[@"seconds"] = @(seconds);
                r[@"time"] = SpliceKit_serializeCMTime(pht);

                // Also get sequence duration for context
                SEL seqSel = @selector(sequence);
                if ([timeline respondsToSelector:seqSel]) {
                    id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                    if (sequence && [sequence respondsToSelector:@selector(duration)]) {
                        SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, @selector(duration));
                        r[@"duration"] = SpliceKit_serializeCMTime(dur);
                    }
                    // Frame rate
                    SEL fdSel = NSSelectorFromString(@"frameDuration");
                    if (sequence && [sequence respondsToSelector:fdSel]) {
                        SpliceKit_CMTime fd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, fdSel);
                        if (fd.timescale > 0 && fd.value > 0) {
                            r[@"frameRate"] = @((double)fd.timescale / fd.value);
                            r[@"frameDuration"] = SpliceKit_serializeCMTime(fd);
                        }
                    }
                }

                // Check if playing
                SEL playSel = NSSelectorFromString(@"isPlaying");
                if ([timeline respondsToSelector:playSel]) {
                    BOOL playing = ((BOOL (*)(id, SEL))objc_msgSend)(timeline, playSel);
                    r[@"isPlaying"] = @(playing);
                }

                // Read current playback rate from player
                // Try timeline -> player -> rate (FFPlayerModule path)
                SEL playerSel = NSSelectorFromString(@"player");
                id player = nil;
                // First try getting player from timeline module
                if ([timeline respondsToSelector:playerSel]) {
                    player = ((id (*)(id, SEL))objc_msgSend)(timeline, playerSel);
                }
                // Fallback: try FFPlayerModule from editor container
                if (!player) {
                    id pm = SpliceKit_getPlayerModule();
                    if (pm && [pm respondsToSelector:playerSel]) {
                        player = ((id (*)(id, SEL))objc_msgSend)(pm, playerSel);
                    }
                }
                if (player) {
                    SEL rateSel = NSSelectorFromString(@"rate");
                    if ([player respondsToSelector:rateSel]) {
                        double currentRate = ((double (*)(id, SEL))objc_msgSend)(player, rateSel);
                        r[@"rate"] = @(currentRate);
                    }
                }

                result = r;
            } else {
                result = @{@"error": @"Cannot read playhead time"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to get position"};
}
