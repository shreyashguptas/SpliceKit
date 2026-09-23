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

static CMTime SpliceKit_directActionFrameDuration(id timeline) {
    CMTime frameDuration = {1, 24, 1, 0};
    SEL seqSel = @selector(sequence);
    if ([timeline respondsToSelector:seqSel]) {
        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        if (sequence) {
            CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
            if (fd.timescale > 0 && fd.value > 0) frameDuration = fd;
        }
    }
    return frameDuration;
}

// Nudge delta from timeline.directAction params. MCP tool direct_timeline_action can only
// send `frames` and `amount` (mapped to params[@"frames"] / params[@"amount"]). Raw JSON-RPC
// callers may also use deltaSeconds, seconds, or nudgeAmount — not exposed on the MCP tool.
static CMTime SpliceKit_directActionNudgeDelta(NSDictionary *params, id timeline) {
    CMTime frameDuration = SpliceKit_directActionFrameDuration(timeline);
    if (params[@"frames"] != nil) {
        long long frames = [params[@"frames"] longLongValue];
        if (frames == 0) frames = 1;
        CMTime delta = frameDuration;
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
        CMTime t = {(int64_t)(seconds * timescale), timescale, 1, 0};
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
    CMTime playhead = {0, 1, 0, 0};
    @try {
        playhead = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
    } @catch (NSException *e) {
        return nil;
    }
    CMTime frame = SpliceKit_directActionFrameDuration(timeline);
    double playheadSeconds = SpliceKit_secondsFromTime(playhead);
    double frameSeconds = SpliceKit_secondsFromTime(frame);
    if (!(frameSeconds > 0)) frameSeconds = 1.0 / 24.0;

    SEL markersSel = NSSelectorFromString(@"markersInTimeRange:");
    if ([sequence respondsToSelector:markersSel]) {
        @try {
            double startSeconds = playheadSeconds - frameSeconds;
            if (startSeconds < 0) startSeconds = 0;
            int32_t ts = frame.timescale > 0 ? frame.timescale : 2400;
            CMTimeRange window = {
                SpliceKit_timeFromSeconds(startSeconds, ts),
                SpliceKit_timeFromSeconds(frameSeconds * 2.0, ts)
            };
            id found = ((id (*)(id, SEL, CMTimeRange))objc_msgSend)(sequence, markersSel, window);
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
                CMTimeRange itemRange = {{0, 0, 0, 0}, {0, 0, 0, 0}};
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
                CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
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

// FCP 12.3 implements the parameterized action* methods below on FFAnchoredSequence,
// not on FFAnchoredTimelineModule. Their argument shapes were read from how Final Cut
// Pro's own commands call them (Modify > Retime, Trim > Extend Edit, Clip > Enable, ...):
// the selected clips as an NSArray, clip-local (component) times from -clippedRange and
// -containerToLocalTime:container:, and FigTimeRangeAndObject entries for rewind / jump cut.
// Each action* method opens and closes its own undo step (actionEnd:save:error:).
static NSDictionary *SpliceKit_directActionSequenceSelector(id sequence, SEL sel, NSString *action) {
    if (!sequence) return @{@"error": @"No sequence in timeline."};
    if ([sequence respondsToSelector:sel]) return nil;
    return @{
        @"error": [NSString stringWithFormat:@"%@ is not supported on this Final Cut Pro build", action],
        @"missingSelector": NSStringFromSelector(sel),
        @"receiver": @"FFAnchoredSequence",
        @"fcpVersion": SpliceKit_fcpShortVersionString(),
    };
}

// An action that FCP 12.3 has only on an object this handler does not drive (a browser
// event, the library document, a view controller), or that needs content SpliceKit has
// not verified it against. Kept as a name so callers get a reason instead of a guess.
static NSDictionary *SpliceKit_directActionUnavailable(NSString *action, NSString *reason) {
    return @{
        @"error": [NSString stringWithFormat:@"%@ is not available through direct_timeline_action in this Final Cut Pro version: %@",
                   action, reason],
        @"fcpVersion": SpliceKit_fcpShortVersionString(),
    };
}

static NSDictionary *SpliceKit_directActionResult(NSString *action, BOOL ok, NSError *error,
                                                   NSDictionary *extra) {
    if (!ok || error) {
        NSString *msg = error.localizedDescription.length ? error.localizedDescription
            : [NSString stringWithFormat:@"Final Cut Pro declined %@ for the current selection", action];
        return @{@"error": msg};
    }
    NSMutableDictionary *out = [@{@"action": action, @"status": @"ok"} mutableCopy];
    if (extra) [out addEntriesFromDictionary:extra];
    return out;
}

// The clip's own time range (component time), as FCP passes it to the retime presets.
static BOOL SpliceKit_directActionLocalRange(id clip, CMTimeRange *out) {
    SEL sel = NSSelectorFromString(@"clippedRange");
    if (!clip || ![clip respondsToSelector:sel]) return NO;
    @try {
        CMTimeRange r = ((CMTimeRange (*)(id, SEL))STRET_MSG)(clip, sel);
        if (r.start.timescale <= 0 || r.duration.timescale <= 0) return NO;
        *out = r;
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

// The playhead, snapped down to a frame boundary the way FCP's retime commands read it,
// converted into the clip's component time. NO when the playhead is not over the clip.
static BOOL SpliceKit_directActionLocalPlayhead(id timeline, id clip, id rootItem, CMTime *out) {
    if (!timeline || !clip || !rootItem) return NO;
    SEL convSel = NSSelectorFromString(@"containerToLocalTime:container:");
    if (![clip respondsToSelector:convSel] || ![timeline respondsToSelector:@selector(playheadTime)]) return NO;
    @try {
        CMTime ph = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
        CMTime fd = SpliceKit_directActionFrameDuration(timeline);
        if (fd.value > 0 && fd.timescale > 0 && ph.timescale > 0) {
            double frames = floor(((double)ph.value * fd.timescale) / ((double)ph.timescale * fd.value) + 1e-6);
            ph = (CMTime){(int64_t)frames * fd.value, fd.timescale, kCMTimeFlags_Valid, 0};
        }
        CMTime local = ((CMTime (*)(id, SEL, CMTime, id))STRET_MSG)(clip, convSel, ph, rootItem);
        CMTimeRange range;
        if (!(local.flags & kCMTimeFlags_Valid)) return NO;
        if (SpliceKit_directActionLocalRange(clip, &range)) {
            double t = SpliceKit_secondsFromTime(local);
            double s = SpliceKit_secondsFromTime(range.start);
            double e = s + SpliceKit_secondsFromTime(range.duration);
            if (t < s - 0.0005 || t > e + 0.0005) return NO;
        }
        *out = local;
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

// FigTimeRangeAndObject entries (clip + its component range), the argument FCP's own
// Rewind and Jump Cut at Markers commands pass.
static NSArray *SpliceKit_directActionRangesAndObjects(NSArray *items) {
    Class cls = NSClassFromString(@"FigTimeRangeAndObject");
    SEL make = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
    if (!cls || ![cls respondsToSelector:make]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id item in items) {
        CMTimeRange range;
        if (!SpliceKit_directActionLocalRange(item, &range)) continue;
        id entry = ((id (*)(id, SEL, CMTimeRange, id))objc_msgSend)((id)cls, make, range, item);
        if (entry) [out addObject:entry];
    }
    return out;
}

static CMTime SpliceKit_directActionFramesFromSeconds(double seconds, id timeline) {
    CMTime fd = SpliceKit_directActionFrameDuration(timeline);
    if (fd.value <= 0 || fd.timescale <= 0) return CMTimeMakeWithSeconds(seconds, 600);
    double frames = llround(seconds * fd.timescale / (double)fd.value);
    return (CMTime){(int64_t)frames * fd.value, fd.timescale, kCMTimeFlags_Valid, 0};
}

// The timeline range covering the selected clips (for keyword ranges).
static BOOL SpliceKit_directActionSelectionRange(id rootItem, NSArray *items, CMTimeRange *out) {
    BOOL have = NO;
    CMTimeRange total = {{0, 0, 0, 0}, {0, 0, 0, 0}};
    for (id item in items) {
        CMTimeRange r;
        if (!SpliceKit_tryReadTimelineRange(rootItem, item, &r)) continue;
        total = have ? CMTimeRangeGetUnion(total, r) : r;
        have = YES;
    }
    if (have) *out = total;
    return have;
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
            NSArray *items = SpliceKit_directActionCollection(getSelectedItems());

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
                // Constant speed, the way Modify > Retime > Slow / Fast set it:
                // -[FFAnchoredSequence actionSetEdits:constantRetiming:ripple:error:].
                double rate = [params[@"rate"] doubleValue];
                BOOL ripple = [params[@"ripple"] boolValue];
                if (rate <= 0) { result = @{@"error": @"rate must be > 0 (e.g. 0.5 for half speed, 2.0 for double)"}; return; }
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionSetEdits:constantRetiming:ripple:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, double, BOOL, NSError **))objc_msgSend)(
                    sequence, sel, items, rate, ripple, &error);
                NSMutableDictionary *extra = [@{@"rate": @(rate), @"ripple": @(ripple)} mutableCopy];
                if (params[@"allowVariableSpeed"]) {
                    extra[@"note"] = @"allowVariableSpeed does not apply to a constant-speed retime and was not used.";
                }
                result = SpliceKit_directActionResult(action, ok, error, extra);
                return;
            }

            if ([action isEqualToString:@"retimeHoldPreset"]) {
                // Modify > Retime > Hold: a hold segment at the playhead, `duration` seconds
                // long (default 2 s, rounded to whole frames).
                id clip = items.firstObject;
                if (!clip) { result = @{@"error": @"Select the clip to hold first."}; return; }
                CMTime at;
                if (!SpliceKit_directActionLocalPlayhead(timeline, clip, rootItem, &at)) {
                    result = @{@"error": @"The playhead is not over the selected clip."}; return;
                }
                double seconds = params[@"duration"] ? [params[@"duration"] doubleValue] : 2.0;
                if (seconds <= 0) { result = @{@"error": @"duration must be > 0 seconds"}; return; }
                CMTime duration = SpliceKit_directActionFramesFromSeconds(seconds, timeline);
                SEL sel = NSSelectorFromString(@"actionRetimeHoldPreset:holdComponentTime:duration:newHoldComponentTime:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                CMTime newHold = kCMTimeInvalid;
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, CMTime, CMTime, CMTime *, NSError **))objc_msgSend)(
                    sequence, sel, @[clip], at, duration, &newHold, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{
                    @"holdAt": SpliceKit_serializeCMTime(at),
                    @"duration": SpliceKit_serializeCMTime(duration)});
                return;
            }

            if ([action isEqualToString:@"retimeReverse"]) {
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionRetimeReverseClipPreset:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(sequence, sel, items, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
                return;
            }

            if ([action isEqualToString:@"retimeBladeSpeedPreset"]) {
                // Modify > Retime > Blade Speed at the playhead.
                id clip = items.firstObject;
                if (!clip) { result = @{@"error": @"Select the clip first."}; return; }
                CMTime at;
                if (!SpliceKit_directActionLocalPlayhead(timeline, clip, rootItem, &at)) {
                    result = @{@"error": @"The playhead is not over the selected clip."}; return;
                }
                SEL sel = NSSelectorFromString(@"actionRetimeBladeSpeedPreset:componentTime:newComponentTime:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                CMTime newTime = kCMTimeInvalid;
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, CMTime, CMTime *, NSError **))objc_msgSend)(
                    sequence, sel, @[clip], at, &newTime, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"bladeAt": SpliceKit_serializeCMTime(at)});
                return;
            }

            if ([action isEqualToString:@"retimeSpeedRamp"]) {
                // Modify > Retime > Speed Ramp over the whole selected clip.
                BOOL toZero = [params[@"toZero"] boolValue];
                BOOL fromZero = [params[@"fromZero"] boolValue];
                if (!toZero && !fromZero) toZero = YES;
                id clip = items.firstObject;
                CMTimeRange range;
                if (!clip || !SpliceKit_directActionLocalRange(clip, &range)) {
                    result = @{@"error": @"Select the clip to ramp first."}; return;
                }
                SEL sel = NSSelectorFromString(@"actionRetimeSpeedRampPreset:startComponentTime:endComponentTime:toZero:fromZero:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                CMTime end = CMTimeAdd(range.start, range.duration);
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, CMTime, CMTime, BOOL, BOOL, NSError **))objc_msgSend)(
                    sequence, sel, @[clip], range.start, end, toZero, fromZero, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"toZero": @(toZero), @"fromZero": @(fromZero)});
                return;
            }

            if ([action isEqualToString:@"retimeInstantReplay"]) {
                double rate = params[@"rate"] ? [params[@"rate"] doubleValue] : 0.5;
                BOOL allowVariable = params[@"allowVariableSpeed"] ? [params[@"allowVariableSpeed"] boolValue] : YES;
                BOOL addTitle = params[@"addTitle"] ? [params[@"addTitle"] boolValue] : YES;
                if (rate <= 0) { result = @{@"error": @"rate must be > 0"}; return; }
                id clip = items.firstObject;
                CMTimeRange range;
                if (!clip || !SpliceKit_directActionLocalRange(clip, &range)) {
                    result = @{@"error": @"Select the clip to replay first."}; return;
                }
                SEL sel = NSSelectorFromString(@"actionRetimeInstantReplayPreset:range:rate:allowVariableSpeedRetiming:addTitle:objectsAndNewRanges:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                id newRanges = nil;
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, CMTimeRange, double, BOOL, BOOL, id *, NSError **))objc_msgSend)(
                    sequence, sel, @[clip], range, rate, allowVariable, addTitle, &newRanges, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"rate": @(rate), @"addTitle": @(addTitle)});
                return;
            }

            if ([action isEqualToString:@"retimeJumpCut"]) {
                // Modify > Retime > Jump Cut at Markers: needs markers on the selected clip.
                int framesToJump = params[@"framesToJump"] ? [params[@"framesToJump"] intValue] : 5;
                BOOL allowVariable = params[@"allowVariableSpeed"] ? [params[@"allowVariableSpeed"] boolValue] : YES;
                if (framesToJump <= 0) { result = @{@"error": @"framesToJump must be > 0"}; return; }
                NSArray *ranges = SpliceKit_directActionRangesAndObjects(items);
                if (ranges.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionRetimeJumpCutPreset:framesToJump:allowVariableSpeedRetiming:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, int, BOOL, NSError **))objc_msgSend)(
                    sequence, sel, [ranges mutableCopy], framesToJump, allowVariable, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"framesToJump": @(framesToJump)});
                return;
            }

            if ([action isEqualToString:@"retimeRewind"]) {
                double rewindSpeed = params[@"speed"] ? [params[@"speed"] doubleValue] : 2.0;
                BOOL allowVariable = params[@"allowVariableSpeed"] ? [params[@"allowVariableSpeed"] boolValue] : YES;
                if (rewindSpeed <= 0) { result = @{@"error": @"speed must be > 0"}; return; }
                NSArray *ranges = SpliceKit_directActionRangesAndObjects(items);
                if (ranges.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionRetimeRewindPreset:rewindSpeed:allowVariableSpeedRetiming:objectsAndNewRanges:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                id newRanges = nil;
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, double, BOOL, id *, NSError **))objc_msgSend)(
                    sequence, sel, [ranges mutableCopy], rewindSpeed, allowVariable, &newRanges, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"speed": @(rewindSpeed)});
                return;
            }

            if ([action isEqualToString:@"retimeSetInterpolation"]) {
                // Modify > Retime > Video Quality. Each quality is its own FFAnchoredSequence
                // action taking the selected clips (actionRetimeSetInterpolation:edits: takes an
                // undocumented enum and is not used).
                NSString *mode = [params[@"interpolation"] isKindOfClass:[NSString class]] ? params[@"interpolation"] : @"";
                NSDictionary<NSString *, NSString *> *modes = @{
                    @"floor":             @"actionRetimeTurnOnFloorFrameSampling:",
                    @"nearest":           @"actionRetimeTurnOnNearestNeighbor:",
                    @"frameBlending":     @"actionRetimeTurnOnFrameBlending:",
                    @"opticalFlow":       @"actionRetimeTurnOnOpticalFlow:",
                    @"opticalFlowMedium": @"actionRetimeTurnOnOpticalFlowMedium:",
                    @"opticalFlowHigh":   @"actionRetimeTurnOnOpticalFlowHigh:",
                    @"opticalFlowFRC":    @"actionRetimeTurnOnOpticalFlowFRC:",
                };
                NSString *selName = modes[mode];
                if (!selName) {
                    result = @{@"error": [NSString stringWithFormat:@"interpolation must be one of: %@",
                        [[modes.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]]};
                    return;
                }
                if (items.count == 0) { result = @{@"error": @"Select one or more retimed clips first."}; return; }
                SEL sel = NSSelectorFromString(selName);
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                ((void (*)(id, SEL, id))objc_msgSend)(sequence, sel, items);
                result = @{@"action": action, @"interpolation": mode, @"status": @"ok"};
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
                // Modify > Change Duration: `duration` seconds (whole frames); isDelta adds it to
                // the current length instead of setting the length.
                BOOL isDelta = params[@"isDelta"] ? [params[@"isDelta"] boolValue] : NO;
                if (!params[@"duration"]) { result = @{@"error": @"duration (seconds) parameter required"}; return; }
                double seconds = [params[@"duration"] doubleValue];
                if (!isDelta && seconds <= 0) { result = @{@"error": @"duration must be > 0 seconds"}; return; }
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                CMTime duration = SpliceKit_directActionFramesFromSeconds(seconds, timeline);
                SEL sel = NSSelectorFromString(@"actionTrimDuration:forEdits:isDelta:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, CMTime, id, BOOL, NSError **))objc_msgSend)(
                    sequence, sel, duration, items, isDelta, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{
                    @"duration": SpliceKit_serializeCMTime(duration), @"isDelta": @(isDelta)});
                return;
            }

            if ([action isEqualToString:@"extendOverNextClip"]) {
                id clip = items.firstObject;
                if (!clip) { result = @{@"error": @"Select the clip to extend first."}; return; }
                SEL sel = NSSelectorFromString(@"actionExtendOverNextClip:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(sequence, sel, clip, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
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
                CMTime delta = SpliceKit_directActionNudgeDelta(params, timeline);
                typedef BOOL (*NudgeAnchorFn)(id, SEL, CMTime);
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
                CMTime delta = SpliceKit_directActionNudgeDelta(params, timeline);
                typedef BOOL (*NudgeSpineFn)(id, SEL, CMTime);
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
                // Modify > Adjust Volume: one clip per call, over the clip's whole range.
                // Several clips share one undo step, as FCP's own Up/Down commands do.
                double amount = [params[@"amount"] doubleValue];
                BOOL isRelative = params[@"relative"] ? [params[@"relative"] boolValue] : YES;
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionChangeAudioVolume:byAmount:overRange:isRelative:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                CMTimeRange whole = {kCMTimeNegativeInfinity, kCMTimePositiveInfinity};
                SEL beginSel = NSSelectorFromString(@"actionBegin:");
                SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
                BOOL grouped = items.count > 1 && [sequence respondsToSelector:beginSel] && [sequence respondsToSelector:endSel];
                NSString *stepName = @"Volume Adjustment";
                if (grouped) ((void (*)(id, SEL, id))objc_msgSend)(sequence, beginSel, stepName);
                BOOL ok = YES;
                NSError *error = nil;
                @try {
                    for (id item in items) {
                        NSError *itemError = nil;
                        BOOL itemOK = ((BOOL (*)(id, SEL, id, double, CMTimeRange, BOOL, NSError **))objc_msgSend)(
                            sequence, sel, item, amount, whole, isRelative, &itemError);
                        if (!itemOK || itemError) { ok = NO; if (!error) error = itemError; }
                    }
                } @finally {
                    if (grouped) {
                        NSError *endError = nil;
                        ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(sequence, endSel, stepName, YES, &endError);
                    }
                }
                result = SpliceKit_directActionResult(action, ok, error, @{
                    @"amount": @(amount), @"relative": @(isRelative), @"clips": @(items.count)});
                return;
            }

            if ([action isEqualToString:@"applyAudioFadesDirect"]) {
                BOOL fadeIn = params[@"fadeIn"] ? [params[@"fadeIn"] boolValue] : YES;
                double duration = params[@"duration"] ? [params[@"duration"] doubleValue] : 0.5;
                if (items.count == 0) { result = @{@"error": @"Select one or more clips with audio first."}; return; }
                if (duration <= 0) { result = @{@"error": @"duration must be > 0 seconds"}; return; }
                NSError *error = nil;
                SEL sel = NSSelectorFromString(@"actionApplyAudioFades:objects:fadeInNotOut:fadeDuration:error:");
                NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(timeline, sel, action);
                if (missingSel) { result = missingSel; return; }
                // As Modify > Adjust Audio Fades > Apply Fades calls it: the undo step name, the
                // clips as an array, and fadeDuration as a float (B48@0:8@16@24B32f36^@40).
                NSString *stepName = fadeIn ? @"Apply Audio Fade In" : @"Apply Audio Fade Out";
                BOOL ok = ((BOOL (*)(id, SEL, id, id, BOOL, float, NSError **))objc_msgSend)(
                    timeline, sel, stepName, [items mutableCopy], fadeIn, (float)duration, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"fadeIn": @(fadeIn), @"duration": @(duration)});
                return;
            }

            if ([action isEqualToString:@"setAudioPlayEnable"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionSetAudioPlayEnable:error: belongs to the audio components view (FFAudioComponentsConfigWaveformManager). "
                    @"Use timeline_action(\"toggleMuteAudio\") or the mixer tools instead.");
                return;
            }

            if ([action isEqualToString:@"setBackgroundMusic"]) {
                BOOL isBackground = params[@"enabled"] ? [params[@"enabled"] boolValue] : YES;
                if (items.count == 0) { result = @{@"error": @"Select one or more audio clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionSetBackgroundMusic:isBackgroundMusic:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                // Only some clips can carry the flag; FCP 12.3 answers YES without a change for
                // the rest (its own Toggle Background Music does nothing for them either), so
                // report whether an undo step was actually recorded.
                id um = SpliceKit_getUndoManager();
                NSString *topBefore = um ? ((id (*)(id, SEL))objc_msgSend)(um, @selector(undoActionName)) : nil;
                BOOL couldUndoBefore = um ? ((BOOL (*)(id, SEL))objc_msgSend)(um, @selector(canUndo)) : NO;
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(sequence, sel, items, isBackground, &error);
                NSString *topAfter = um ? ((id (*)(id, SEL))objc_msgSend)(um, @selector(undoActionName)) : nil;
                BOOL canUndoAfter = um ? ((BOOL (*)(id, SEL))objc_msgSend)(um, @selector(canUndo)) : NO;
                if (ok && !error && um && canUndoAfter == couldUndoBefore && [topAfter ?: @"" isEqualToString:topBefore ?: @""]) {
                    result = @{@"error": @"Final Cut Pro made no change: none of the selected clips can be marked as background music."};
                    return;
                }
                result = SpliceKit_directActionResult(action, ok, error, @{@"enabled": @(isBackground)});
                return;
            }

            if ([action isEqualToString:@"detachAudioDirect"]) {
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionDetachAudio:newDetachedEdits:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSMutableArray *detached = [NSMutableArray array];
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, items, detached, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"detached": @(detached.count)});
                return;
            }

            if ([action isEqualToString:@"alignAudioToVideoDirect"]) {
                // Trim > Align Audio to Video: select the video clip and its detached audio.
                if (items.count == 0) { result = @{@"error": @"Select the video clip and its detached audio first."}; return; }
                SEL sel = NSSelectorFromString(@"actionAlignAudioToVideo:endEdits:container:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                BOOL ok = ((BOOL (*)(id, SEL, id, id, id))objc_msgSend)(sequence, sel, items, items, rootItem);
                result = SpliceKit_directActionResult(action, ok, nil, nil);
                return;
            }

            // === Multicam / Angles ===
            // FCP's multicam clips have "angles" that can be renamed, deleted,
            // or audio-synced independently.

            if ([action isEqualToString:@"deleteMultiAngle"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"FFAnchoredSequence's actionDeleteMultiAngle:error: takes a multicam angle, and SpliceKit has not been verified against a multicam clip in 12.3. Use the angle editor (Clip > Open in Angle Editor) for now.");
                return;
            }

            if ([action isEqualToString:@"renameAngle"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"FFAnchoredSequence's actionRenameAngle:newName:error: takes a multicam angle, and SpliceKit has not been verified against a multicam clip in 12.3. Use the angle editor (Clip > Open in Angle Editor) for now.");
                return;
            }

            if ([action isEqualToString:@"audioSyncMultiAngle"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"FFAnchoredSequence's actionAudioSyncMultiAngleItems:rootItem:error: takes a multicam angle, and SpliceKit has not been verified against a multicam clip in 12.3. Use the angle editor (Clip > Open in Angle Editor) for now.");
                return;
            }

            // === Keywords / Roles ===
            // Keywords are FCP's tagging system. Roles control audio/video routing
            // for export (Dialogue, Music, Effects, Titles, etc).

            if ([action isEqualToString:@"addKeywords"]) {
                // The sequence's own keyword action: a keyword range on the project covering the
                // selected clips' timeline range (stored on the project's storyline, not the clips).
                NSArray *keywords = [params[@"keywords"] isKindOfClass:[NSArray class]] ? params[@"keywords"] : nil;
                if (keywords.count == 0) { result = @{@"error": @"keywords array required"}; return; }
                CMTimeRange range;
                if (!SpliceKit_directActionSelectionRange(rootItem, items, &range)) {
                    result = @{@"error": @"Select the clips to keyword first."}; return;
                }
                SEL sel = NSSelectorFromString(@"actionAddKeywordsWithNames:forRange:animationHint:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, CMTimeRange, id, NSError **))objc_msgSend)(
                    sequence, sel, [NSSet setWithArray:keywords], range, nil, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"keywords": keywords,
                    @"note": @"The keywords are a range on the project over the selected clips' time range (the sequence's keyword action), not keywords stored on the clips themselves."});
                return;
            }

            if ([action isEqualToString:@"removeKeywords"]) {
                NSArray *keywords = [params[@"keywords"] isKindOfClass:[NSArray class]] ? params[@"keywords"] : nil;
                if (keywords.count == 0) { result = @{@"error": @"keywords array required"}; return; }
                CMTimeRange range;
                if (!SpliceKit_directActionSelectionRange(rootItem, items, &range)) {
                    result = @{@"error": @"Select the clips to remove keywords from first."}; return;
                }
                SEL sel = NSSelectorFromString(@"actionRemoveKeywordsWithNames:forRange:animationHint:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, CMTimeRange, id, NSError **))objc_msgSend)(
                    sequence, sel, [NSSet setWithArray:keywords], range, nil, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"keywords": keywords});
                return;
            }

            // === Effects / Masks ===
            // Manipulate effects on selected clips: remove by ID, invert masks,
            // toggle enabled state.

            if ([action isEqualToString:@"removeEffectByID"]) {
                NSString *effectID = params[@"effectID"];
                if (!effectID) { result = @{@"error": @"effectID parameter required"}; return; }
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionRemoveEffectID:fromAnchoredObjects:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, effectID, items, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"effectID": effectID});
                return;
            }

            if ([action isEqualToString:@"invertEffectMasks"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionInvertEffectMasks:actionName:error: belongs to the project document (FFProjectDocument) and takes effect masks, not clips.");
                return;
            }

            if ([action isEqualToString:@"toggleEnabled"]) {
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionToggleEnabled:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(sequence, sel, items, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
                return;
            }

            // === Clip Operations ===
            // Structural operations on clips: break apart compound clips, create new
            // compound clips, lift from storyline, rename, delete, move to trash.

            if ([action isEqualToString:@"breakApartClipItems"]) {
                // The clips are passed by reference (^@); FCP replaces them with the pieces.
                if (items.count == 0) { result = @{@"error": @"Select one or more compound clips first."}; return; }
                // FCP's own Clip > Break Apart Clip Items asks first; the action itself would
                // also split an ordinary clip into its video and audio components.
                SEL canSel = NSSelectorFromString(@"canBreakApartClipItems");
                if ([timeline respondsToSelector:canSel] && !((BOOL (*)(id, SEL))objc_msgSend)(timeline, canSel)) {
                    result = @{@"error": @"Final Cut Pro cannot break apart the selection (select a compound clip, audition or storyline)."};
                    return;
                }
                SEL sel = NSSelectorFromString(@"actionBreakApartClipItems:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                id inOut = items;
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id *, NSError **))objc_msgSend)(sequence, sel, &inOut, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
                return;
            }

            if ([action isEqualToString:@"createCompoundClipDirect"]) {
                // No name sheet: FCP names the compound clip itself. The clips are passed by
                // reference (^@). spine:YES builds a storyline instead (Clip > Create Storyline,
                // seen live), so it is NO here.
                BOOL multiClip = [params[@"multicam"] boolValue];
                if (items.count == 0) { result = @{@"error": @"Select the clips to combine first."}; return; }
                SEL canSel = NSSelectorFromString(@"canCreateCompoundClip");
                if ([timeline respondsToSelector:canSel] && !((BOOL (*)(id, SEL))objc_msgSend)(timeline, canSel)) {
                    result = @{@"error": @"Final Cut Pro cannot make a compound clip from the selection."};
                    return;
                }
                SEL sel = NSSelectorFromString(@"actionCreateCompoundClip:multiClip:spine:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                id inOut = items;
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id *, BOOL, BOOL, NSError **))objc_msgSend)(
                    sequence, sel, &inOut, multiClip, NO, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"multicam": @(multiClip)});
                return;
            }

            if ([action isEqualToString:@"liftAnchoredEdits"]) {
                // Edit > Lift from Storyline.
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionLiftAnchoredEdits:rootItem:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, items, rootItem, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
                return;
            }

            if ([action isEqualToString:@"renameDirect"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionRename:actionName:error: belongs to the library document (FFModelDocument) and renames the document, not a clip. "
                    @"Use timeline_action(\"renameClip\") to rename the selected clip.");
                return;
            }

            if ([action isEqualToString:@"deleteItemsInArray"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionDeleteItemsInArray:error: is a class method of the browser event (FFMediaEventProject) that deletes browser items. "
                    @"Use timeline_destructive_action(\"delete\") for timeline clips or remove_browser_clip for browser items.");
                return;
            }

            if ([action isEqualToString:@"moveClipsToTrash"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionMoveClipsToTrash:mediaRefsToDelete:error: belongs to the browser's event controller (FFMediaEventController) and deletes media files. "
                    @"Use timeline_action(\"moveToTrash\") (File > Move to Trash) instead.");
                return;
            }

            // === Captions ===
            // Duplicate captions to a different language/format for localization.

            if ([action isEqualToString:@"duplicateCaptions"]) {
                NSString *language = params[@"language"] ?: @"en";
                NSString *format = params[@"format"] ?: @"ITT";
                SEL canSel = NSSelectorFromString(@"canDuplicateCaptions");
                if ([timeline respondsToSelector:canSel] && !((BOOL (*)(id, SEL))objc_msgSend)(timeline, canSel)) {
                    result = @{@"error": @"Select one or more captions first (Final Cut Pro cannot duplicate the current selection)."};
                    return;
                }
                SEL sel = NSSelectorFromString(@"actionDuplicateCaptions:toLanguageIdentifier:andCaptionFormat:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                id created = ((id (*)(id, SEL, id, id, id))objc_msgSend)(sequence, sel, items, language, format);
                result = @{@"action": action, @"language": language, @"format": format,
                           @"created": @([SpliceKit_directActionCollection(created) count]), @"status": @"ok"};
                return;
            }

            // === Audition / Variants ===
            // Auditions let you stack multiple takes in one timeline slot and cycle
            // through them. "Variants" are the individual takes within an audition.

            if ([action isEqualToString:@"addVariants"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionAddVariants:error: belongs to the browser event (FFMediaEventProject), not the timeline. "
                    @"Use timeline_action(\"createAudition\") on a timeline clip.");
                return;
            }

            if ([action isEqualToString:@"removeVariants"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionRemoveVariants:error: belongs to the browser event (FFMediaEventProject), not the timeline.");
                return;
            }

            if ([action isEqualToString:@"finalizeVariant"]) {
                // Clip > Audition > Finalize Audition on the selected audition.
                id audition = nil;
                for (id item in items) {
                    if ([NSStringFromClass([item class]) isEqualToString:@"FFAnchoredStack"]) { audition = item; break; }
                }
                if (!audition) { result = @{@"error": @"Select an audition clip first."}; return; }
                SEL sel = NSSelectorFromString(@"actionFinalizePickFromVariant:rootItem:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                id picked = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, audition, rootItem, &error);
                result = SpliceKit_directActionResult(action, picked != nil, error, nil);
                return;
            }

            // === Project / Library ===

            if ([action isEqualToString:@"newProject"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionNewProject:name:sequence:actionName:error: is a class method of FFProjectDocument, not a timeline action. "
                    @"Use create_project().");
                return;
            }

            if ([action isEqualToString:@"newEvent"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionNewEvent:name:actionName:error: is a class method of FFProjectDocument, not a timeline action. "
                    @"Use create_event().");
                return;
            }

            if ([action isEqualToString:@"validateAndRepair"]) {
                // Clip > Verify and Repair Project without its result sheet: repair on, mode 0,
                // as -[FFAnchoredTimelineModule validateAndRepairSequence:] calls it.
                SEL sel = NSSelectorFromString(@"actionValidateAndRepair:validateMode:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, BOOL, int, NSError **))objc_msgSend)(sequence, sel, YES, 0, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
                return;
            }

            // === Auto-reframe (Direct) ===

            if ([action isEqualToString:@"autoReframeDirect"]) {
                // Modify > Smart Conform.
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionAutoReframe:forContainer:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, items, rootItem, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
                return;
            }

            // === Music alignment ===

            if ([action isEqualToString:@"alignToMusicMarkers"]) {
                SEL canSel = NSSelectorFromString(@"canAlignToMusicMarkers");
                if ([timeline respondsToSelector:canSel] && !((BOOL (*)(id, SEL))objc_msgSend)(timeline, canSel)) {
                    result = @{@"error": @"Final Cut Pro cannot align to music markers here (it needs a clip with beat/music markers)."};
                    return;
                }
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionAlignToMusicMarkers:rootItem:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, items, rootItem, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
                return;
            }

            if ([action isEqualToString:@"alignClipsAtMusicMarkers"]) {
                BOOL asSplit = [params[@"asSplit"] boolValue];
                SEL canSel = NSSelectorFromString(@"canAlignToMusicMarkers");
                if ([timeline respondsToSelector:canSel] && !((BOOL (*)(id, SEL))objc_msgSend)(timeline, canSel)) {
                    result = @{@"error": @"Final Cut Pro cannot align to music markers here (it needs a clip with beat/music markers)."};
                    return;
                }
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionAlignClipsAtMusicMarkersOnItems:rootItem:asSplit:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, id, BOOL, NSError **))objc_msgSend)(sequence, sel, items, rootItem, asSplit, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"asSplit": @(asSplit)});
                return;
            }

            // === Transition operations (Direct) ===

            if ([action isEqualToString:@"addTransitionsDirect"]) {
                // Edit > Add Default Transition on both edges of the selected clips: the default
                // video transition plus FCP's audio crossfade, as addTransition: passes them.
                if (items.count == 0) { result = @{@"error": @"Select one or more clips first."}; return; }
                SEL sel = NSSelectorFromString(@"actionAddTransitionsToSpineObjects:before:after:effects:transitionOverlapType:transitionsCreated:rootItem:reportErrors:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSString *videoID = [params[@"effectID"] isKindOfClass:[NSString class]] ? params[@"effectID"] : nil;
                if (!videoID) {
                    Class ffEffect = NSClassFromString(@"FFEffect");
                    SEL defSel = NSSelectorFromString(@"defaultVideoTransitionEffectID");
                    if (ffEffect && [ffEffect respondsToSelector:defSel]) videoID = ((id (*)(id, SEL))objc_msgSend)(ffEffect, defSel);
                }
                if (!videoID) { result = @{@"error": @"No default video transition is set in Final Cut Pro."}; return; }
                NSDictionary *effects = @{@"video": videoID, @"audio": @"FFAudioTransition"};
                // Not enough media on an edge puts up an alert; accept it like apply_transition does.
                SpliceKit_armTransitionAlertAutoAccept();
                id created = nil;
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, BOOL, BOOL, id, int, id *, id, BOOL, NSError **))objc_msgSend)(
                    sequence, sel, items, YES, YES, effects, 1, &created, rootItem, YES, &error);
                result = SpliceKit_directActionResult(action, ok, error, @{@"videoTransition": videoID});
                return;
            }

            // === Analyze and optimize ===

            if ([action isEqualToString:@"analyzeAndOptimize"]) {
                result = SpliceKit_directActionUnavailable(action,
                    @"actionPerformAnalyzeAndOptimizeClips:options:error: belongs to the Analyze and Fix window's view controller. "
                    @"Use timeline_action(\"analyzeAndFix\") (Modify > Analyze and Fix…), which opens that window.");
                return;
            }

            // === Lane conflict resolution ===

            if ([action isEqualToString:@"resolveLaneConflicts"]) {
                SEL sel = NSSelectorFromString(@"actionResolveLaneConflictsInContainer:excludedItems:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(sequence, sel, rootItem, nil, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
                return;
            }

            if ([action isEqualToString:@"resolveLaneGaps"]) {
                SEL sel = NSSelectorFromString(@"actionResolveLaneGapsInContainer:error:");
                NSDictionary *missingSel = SpliceKit_directActionSequenceSelector(sequence, sel, action);
                if (missingSel) { result = missingSel; return; }
                NSError *error = nil;
                BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(sequence, sel, rootItem, &error);
                result = SpliceKit_directActionResult(action, ok, error, nil);
                return;
            }

            // === Fallback: raw selector invocation ===
            // If a selector string is provided directly, try to call it on the timeline module
            if (rawSelector) {
                SEL sel = NSSelectorFromString(rawSelector);
                if ([rawSelector hasPrefix:@"action"]) {
                    NSDictionary *missingSel = SpliceKit_directActionMissingSelectorError(
                        timeline, sel, rawSelector);
                    if (missingSel && sequence && [sequence respondsToSelector:sel]) {
                        // Raw calls pass nil for every argument, which is wrong for the
                        // sequence's struct / BOOL / pointer parameters.
                        result = @{
                            @"error": [NSString stringWithFormat:
                                @"%@ is implemented on FFAnchoredSequence, not the timeline module; "
                                @"a raw selector call cannot supply its arguments. Use the named action, "
                                @"or call_method_with_args on the sequence.", rawSelector],
                            @"receiver": @"FFAnchoredSequence",
                        };
                        return;
                    }
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
                    CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
                    if (fd.timescale > 0) timescale = fd.timescale;
                }
            }

            // Build CMTime from seconds
            double secs = [seconds doubleValue];
            CMTime targetTime;
            targetTime.value = (int64_t)(secs * timescale);
            targetTime.timescale = timescale;
            targetTime.flags = 1; // kCMTimeFlags_Valid
            targetTime.epoch = 0;

            // Call setPlayheadTime: on the timeline module
            SEL setSel = @selector(setPlayheadTime:);
            if ([timeline respondsToSelector:setSel]) {
                ((void (*)(id, SEL, CMTime))objc_msgSend)(
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
                CMTime pht = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, phSel);
                double seconds = SpliceKit_secondsFromTime(pht);

                NSMutableDictionary *r = [NSMutableDictionary dictionary];
                r[@"seconds"] = @(seconds);
                r[@"time"] = SpliceKit_serializeCMTime(pht);

                // Also get sequence duration for context
                SEL seqSel = @selector(sequence);
                if ([timeline respondsToSelector:seqSel]) {
                    id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                    if (sequence && [sequence respondsToSelector:@selector(duration)]) {
                        CMTime dur = ((CMTime (*)(id, SEL))STRET_MSG)(sequence, @selector(duration));
                        r[@"duration"] = SpliceKit_serializeCMTime(dur);
                    }
                    // Frame rate
                    CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
                    if (fd.timescale > 0 && fd.value > 0) {
                        r[@"frameRate"] = @((double)fd.timescale / fd.value);
                        r[@"frameDuration"] = SpliceKit_serializeCMTime(fd);
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
