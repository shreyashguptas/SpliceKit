//
//  SpliceKitServerEditing.m
//  SpliceKit - Handle-based selection (timeline.selectItems) and exact ripple trims
//  (timeline.trimClip).
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Handle-based selection & exact trims
//
// timeline.selectItems and timeline.trimClip act on clip HANDLES (from
// timeline.getDetailedState) instead of the playhead, so an AI can target a
// specific clip without moving anything first.
//
// Selection goes through the same model-level setter the lane selector and the
// transition repair already use (setSelectedItems: / _setSelectedItems: /
// selectItems: on FFAnchoredTimelineModule). Trims go through FCP's own
// ripple-trim entry point on the sequence, exactly as the beat trim and
// FreezeExtend do: operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:
// trimFlags:temporalResolutionMode:animationHint:error: with trimCommand=1
// (ripple) and trimFlags=2 -- what FCP uses when the clip edge is dragged.
//

// Current timeline selection as an NSArray (never nil). Same query as
// timeline.getDetailedState: selectedItems:includeItemBeforePlayheadIfLast: (NO, NO).
NSArray *SpliceKit_handleSelectionCurrentItems(id timeline) {
    if (!timeline) return @[];
    SEL richSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    if ([timeline respondsToSelector:richSel]) {
        id items = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, richSel, NO, NO);
        NSArray *arr = SpliceKit_mixerArrayFromContainer(items);
        return arr ?: @[];
    }
    if ([timeline respondsToSelector:@selector(selectedItems)]) {
        id items = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(selectedItems));
        NSArray *arr = SpliceKit_mixerArrayFromContainer(items);
        return arr ?: @[];
    }
    return @[];
}

// Pointer-identity keys for a set of items (selection membership is by object,
// not by handle string).
NSMutableSet<NSString *> *SpliceKit_handleSelectionPointerKeys(NSArray *items) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (id item in items) {
        NSString *key = SpliceKit_handlePointerKey(item);
        if (key.length > 0) [keys addObject:key];
    }
    return keys;
}

// Model-level selection setter with the same fallbacks the lane selector and
// the transition repair use. Returns NO when the module has none of them.
BOOL SpliceKit_handleSelectionApply(id timeline, NSArray *items, NSString **outSelector) {
    if (!timeline) return NO;
    SEL setSel = NSSelectorFromString(@"setSelectedItems:");
    if (![timeline respondsToSelector:setSel]) {
        setSel = NSSelectorFromString(@"_setSelectedItems:");
    }
    if (![timeline respondsToSelector:setSel]) {
        setSel = NSSelectorFromString(@"selectItems:");
    }
    if (![timeline respondsToSelector:setSel]) return NO;
    if (outSelector) *outSelector = NSStringFromSelector(setSel);
    ((void (*)(id, SEL, id))objc_msgSend)(timeline, setSel, items ?: @[]);
    return YES;
}

// One row of the `selected` readback: handle, name, class, lane, absolute range.
static NSDictionary *SpliceKit_handleSelectionEntryForItem(id item, id primaryObj) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"handle"] = SpliceKit_storeHandle(item) ?: @"";
    entry[@"name"] = SpliceKit_displayNameForItem(item) ?: @"";
    entry[@"class"] = NSStringFromClass([item class]) ?: @"";
    entry[@"lane"] = @(SpliceKit_laneForItem(item));
    CMTimeRange range;
    if (SpliceKit_tryReadTimelineRange(primaryObj, item, &range)) {
        entry[@"startTime"] = SpliceKit_serializeCMTime(range.start);
        entry[@"endTime"] = SpliceKit_serializeCMTime(SpliceKit_endTimeForRange(range));
    }
    return entry;
}

// Find a connected item anywhere under the spine (any depth) with the same walk
// timeline.getDetailedState uses, so handles it reported always resolve here too.
// Returns the walk entry (with startTime/endTime when the walk could place it).
static NSDictionary *SpliceKit_handleFindConnectedEntry(id primaryObj, id target) {
    if (!primaryObj || !target) return nil;
    NSString *wanted = SpliceKit_storeHandle(target);
    if (wanted.length == 0) return nil;
    NSArray *spineItems = nil;
    @try {
        if ([primaryObj respondsToSelector:@selector(containedItems)]) {
            spineItems = SpliceKit_mixerArrayFromContainer(
                ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems)));
        }
    } @catch (NSException *e) { spineItems = nil; }
    if (spineItems.count == 0) return nil;

    NSMutableArray *found = [NSMutableArray array];
    NSMutableArray *markers = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];
    NSInteger spineIndex = 0;
    for (id spineItem in spineItems) {
        CMTimeRange sr = {{0, 0, 0, 0}, {0, 0, 0, 0}};
        BOOL haveSpineStart = SpliceKit_tryReadTimelineRange(primaryObj, spineItem, &sr);
        double spineStart = haveSpineStart ? SpliceKit_secondsFromTime(sr.start) : 0.0;
        SpliceKit_collectConnectedItems(spineItem, primaryObj, primaryObj, 0.0, YES,
                                        haveSpineStart, spineStart,
                                        SpliceKit_storeHandle(spineItem), spineIndex, 0, 0,
                                        nil, NO, found, markers, visited, 2000, 8);
        spineIndex++;
        for (NSDictionary *entry in found) {
            if ([entry[@"handle"] isEqualToString:wanted]) return entry;
        }
        [found removeAllObjects];
    }
    return nil;
}

// Shared validation for handle-targeted clip operations. Returns nil and fills
// *outError when the handle does not name a clip in the active sequence. When
// the clip is a nested connected clip whose absolute range the spine cannot
// report, *outRange has timescale 0 (callers that need a range check for it).
id SpliceKit_handleResolveTimelineClip(NSString *handle, id primaryObj,
                                              CMTimeRange *outRange,
                                              NSString **outError) {
    id obj = SpliceKit_resolveHandle(handle);
    if (!obj) {
        if (outError) *outError = [NSString stringWithFormat:@"Handle not found: %@ (re-run timeline.getDetailedState)", handle];
        return nil;
    }
    Class anchoredObjectClass = objc_getClass("FFAnchoredObject");
    if (anchoredObjectClass && ![obj isKindOfClass:anchoredObjectClass]) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ is not a timeline item (FFAnchoredObject)",
                                   NSStringFromClass([obj class]) ?: @"object"];
        return nil;
    }
    NSString *className = NSStringFromClass([obj class]) ?: @"";
    if ([className containsString:@"Marker"]) {
        if (outError) *outError = @"markers are not clips; use the marker actions (changeMarkerName, markMarkerCompleted, removeMarker)";
        return nil;
    }
    CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
    if (!SpliceKit_tryReadTimelineRange(primaryObj, obj, &range)) {
        // Not directly on the spine's coordinate system: nested connected clips
        // (inside a connected storyline, or anchored to a connected clip).
        NSDictionary *entry = SpliceKit_handleFindConnectedEntry(primaryObj, obj);
        if (!entry) {
            if (outError) *outError = @"clip is not in the active sequence";
            return nil;
        }
        NSDictionary *st = [entry[@"startTime"] isKindOfClass:[NSDictionary class]] ? entry[@"startTime"] : nil;
        NSDictionary *et = [entry[@"endTime"] isKindOfClass:[NSDictionary class]] ? entry[@"endTime"] : nil;
        int32_t ts = (int32_t)[st[@"timescale"] intValue];
        if (st && et && ts > 0) {
            long long startValue = [st[@"value"] longLongValue];
            long long endValue = [et[@"value"] longLongValue];
            if ((int32_t)[et[@"timescale"] intValue] != ts) {
                endValue = (long long)llround([et[@"seconds"] doubleValue] * ts);
            }
            CMTime start = {startValue, ts, 1, 0};
            CMTime duration = {endValue - startValue, ts, 1, 0};
            range.start = start;
            range.duration = duration;
        }
    }
    if (outRange) *outRange = range;
    return obj;
}

// timeline.selectItems — select clips by handle. Never moves the playhead.
//   params: handles (array of strings; missing/empty = deselect all),
//           mode ("replace" | "add" | "remove")
NSDictionary *SpliceKit_handleTimelineSelectItems(NSDictionary *params) {
    id rawHandles = params[@"handles"];
    if (rawHandles && ![rawHandles isKindOfClass:[NSNull class]] && ![rawHandles isKindOfClass:[NSArray class]]) {
        return @{@"error": @"handles must be an array of handle strings (an empty array deselects all)"};
    }
    NSArray *handles = [rawHandles isKindOfClass:[NSArray class]] ? rawHandles : @[];
    NSString *mode = [params[@"mode"] isKindOfClass:[NSString class]]
        ? [params[@"mode"] lowercaseString] : @"replace";
    if (![@[@"replace", @"add", @"remove"] containsObject:mode]) {
        return @{@"error": @"mode must be one of: replace, add, remove"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id sequence = [timeline respondsToSelector:@selector(sequence)]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence)) : nil;
            if (!sequence) { result = @{@"error": @"No sequence in timeline"}; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
            if (!primaryObj) { result = @{@"error": @"Cannot access primary storyline"}; return; }

            // Resolve every handle; keep the reasons for the ones we cannot select.
            NSMutableArray *resolved = [NSMutableArray array];
            NSMutableArray<NSString *> *unresolved = [NSMutableArray array];
            NSMutableArray<NSDictionary *> *rejected = [NSMutableArray array];
            NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
            for (id rawHandle in handles) {
                if (![rawHandle isKindOfClass:[NSString class]] || [(NSString *)rawHandle length] == 0) {
                    [rejected addObject:@{@"handle": [rawHandle description] ?: @"",
                                          @"reason": @"handle must be a non-empty string"}];
                    continue;
                }
                NSString *handle = rawHandle;
                if (!SpliceKit_resolveHandle(handle)) {
                    [unresolved addObject:handle];
                    continue;
                }
                NSString *reason = nil;
                id obj = SpliceKit_handleResolveTimelineClip(handle, primaryObj, NULL, &reason);
                if (!obj) {
                    [rejected addObject:@{@"handle": handle, @"reason": reason ?: @"rejected"}];
                    continue;
                }
                NSString *key = SpliceKit_handlePointerKey(obj);
                if (key.length > 0) {
                    if ([seenKeys containsObject:key]) continue;   // same clip twice
                    [seenKeys addObject:key];
                }
                [resolved addObject:obj];
            }

            // Stale or wrong handles must never silently clear the user's selection.
            if (handles.count > 0 && resolved.count == 0) {
                result = @{
                    @"error": @"none of the requested handles resolved to a clip in the active sequence; selection left unchanged",
                    @"mode": mode,
                    @"requestedCount": @(handles.count),
                    @"resolvedCount": @0,
                    @"unresolved": unresolved,
                    @"rejected": rejected,
                };
                return;
            }

            // Intended final selection (by pointer identity).
            NSMutableArray *intended = [NSMutableArray array];
            if ([mode isEqualToString:@"replace"]) {
                [intended addObjectsFromArray:resolved];
            } else {
                NSArray *current = SpliceKit_handleSelectionCurrentItems(timeline);
                if ([mode isEqualToString:@"add"]) {
                    NSMutableSet<NSString *> *keys = SpliceKit_handleSelectionPointerKeys(current);
                    [intended addObjectsFromArray:current];
                    for (id item in resolved) {
                        NSString *key = SpliceKit_handlePointerKey(item);
                        if (key.length > 0 && [keys containsObject:key]) continue;
                        if (key.length > 0) [keys addObject:key];
                        [intended addObject:item];
                    }
                } else {
                    NSMutableSet<NSString *> *removeKeys = SpliceKit_handleSelectionPointerKeys(resolved);
                    for (id item in current) {
                        NSString *key = SpliceKit_handlePointerKey(item);
                        if (key.length > 0 && [removeKeys containsObject:key]) continue;
                        [intended addObject:item];
                    }
                }
            }

            NSString *usedSelector = nil;
            if (!SpliceKit_handleSelectionApply(timeline, intended, &usedSelector)) {
                result = @{@"error": @"Timeline module responds to none of setSelectedItems:, _setSelectedItems:, selectItems:"};
                return;
            }

            NSArray *readback = SpliceKit_handleSelectionCurrentItems(timeline);
            if (intended.count == 0 && readback.count > 0) {
                // Some builds ignore an empty array; fall back to FCP's own Deselect All.
                if (SpliceKit_sendTimelineSimpleAction(timeline, @"deselectAll:")) {
                    usedSelector = @"deselectAll:";
                }
                readback = SpliceKit_handleSelectionCurrentItems(timeline);
            }

            NSMutableSet<NSString *> *intendedKeys = SpliceKit_handleSelectionPointerKeys(intended);
            NSMutableSet<NSString *> *readbackKeys = SpliceKit_handleSelectionPointerKeys(readback);
            BOOL matchesRequest = [intendedKeys isEqualToSet:readbackKeys];

            NSMutableArray *selected = [NSMutableArray arrayWithCapacity:readback.count];
            for (id item in readback) {
                [selected addObject:SpliceKit_handleSelectionEntryForItem(item, primaryObj)];
            }

            result = @{
                @"status": @"ok",
                @"mode": mode,
                @"requestedCount": @(handles.count),
                @"resolvedCount": @(resolved.count),
                @"unresolved": unresolved,
                @"rejected": rejected,
                @"selected": selected,
                @"selectedCount": @(selected.count),
                @"matchesRequest": @(matchesRequest),
                @"selector": usedSelector ?: @"",
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to select timeline items"};
}

// timeline.trimClip — ripple-trim one edit point (start or end) of one clip by handle.
//   params: handle (required), edge ("start" | "end", required),
//           exactly one of deltaSeconds | toSeconds, dryRun (default NO)
// Delta sign is FCP's: how far the edit point moves along the timeline,
// positive = later, negative = earlier, for either edge. Because this is a
// ripple trim (FCP's default trim), a primary-storyline clip keeps its position
// when its START point is trimmed: the start point moves within the source
// media, the duration changes, and the clip's end plus every subsequent clip
// (with their connected clips) ripples. The result is therefore verified
// through the clip's duration rather than the edge position.
NSDictionary *SpliceKit_handleTimelineTrimClip(NSDictionary *params) {
    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    if (handle.length == 0) {
        return @{@"error": @"handle parameter required (a clip handle from timeline.getDetailedState)"};
    }
    NSString *edge = [params[@"edge"] isKindOfClass:[NSString class]] ? [params[@"edge"] lowercaseString] : nil;
    if (![edge isEqualToString:@"start"] && ![edge isEqualToString:@"end"]) {
        return @{@"error": @"edge parameter required: \"start\" or \"end\""};
    }
    BOOL hasDelta = [params[@"deltaSeconds"] isKindOfClass:[NSNumber class]];
    BOOL hasTo = [params[@"toSeconds"] isKindOfClass:[NSNumber class]];
    if (hasDelta == hasTo) {
        return @{@"error": @"provide exactly one of deltaSeconds or toSeconds"};
    }
    double deltaParam = hasDelta ? [params[@"deltaSeconds"] doubleValue] : 0.0;
    double toParam = hasTo ? [params[@"toSeconds"] doubleValue] : 0.0;
    BOOL dryRun = [params[@"dryRun"] boolValue];
    BOOL isStart = [edge isEqualToString:@"start"];

    __block NSDictionary *result = nil;
    // The undo step this call opened, so the outer @catch can close it: an action left
    // open would keep the sequence in an open transaction.
    __block BOOL trimUndoOpen = NO;
    __block id trimUndoSequence = nil;
    NSString *undoStepName = @"Trim";
    SEL undoBeginSel = NSSelectorFromString(@"actionBegin:");
    SEL undoEndSel = NSSelectorFromString(@"actionEnd:save:error:");
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id sequence = [timeline respondsToSelector:@selector(sequence)]
                ? ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence)) : nil;
            if (!sequence) { result = @{@"error": @"No sequence in timeline"}; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
            if (!primaryObj) { result = @{@"error": @"Cannot access primary storyline"}; return; }

            CMTimeRange beforeRange;
            NSString *resolveError = nil;
            id item = SpliceKit_handleResolveTimelineClip(handle, primaryObj, &beforeRange, &resolveError);
            if (!item) {
                if ([resolveError hasPrefix:@"markers are not clips"]) {
                    resolveError = @"markers cannot be trimmed; move them with the marker actions";
                }
                result = @{@"error": resolveError ?: @"clip is not in the active sequence", @"handle": handle};
                return;
            }

            if (beforeRange.start.timescale <= 0 || beforeRange.duration.timescale <= 0) {
                result = @{@"error": @"the clip's timeline range could not be determined (nested connected clip); it can be selected but not trimmed by handle",
                           @"handle": handle, @"trimCommand": @"ripple"};
                return;
            }

            // Only clips (and gaps) go into FCP's trim operation: not a transition, and
            // not a storyline (primary or connected; its clips are trimmed one by one).
            // The class name is no test for that: FCP wraps every clip that carries both
            // video and audio in an FFAnchoredCollection, and a compound clip is trimmed
            // like any clip, so the connected-storyline flag is asked instead.
            NSString *itemClass = NSStringFromClass([item class]) ?: @"";
            BOOL itemIsTransition = [itemClass containsString:@"Transition"];
            BOOL itemIsPrimary = (item == primaryObj);
            BOOL itemIsStoryline = itemIsPrimary || SpliceKit_boolForSelector(item, @"isConnectedStoryline");
            if (itemIsTransition || itemIsStoryline) {
                NSString *what = itemIsTransition ? @"transition"
                    : itemIsPrimary ? @"the primary storyline itself (trim the clips inside it)"
                    : @"connected storyline (trim the clips inside it)";
                result = @{
                    @"error": [NSString stringWithFormat:
                        @"trim_clip supports clips (and gaps) only; %@ is %@%@", itemClass,
                        itemIsPrimary ? @"" : @"a ", what],
                    @"handle": handle, @"itemClass": itemClass, @"trimCommand": @"ripple",
                };
                return;
            }

            // Is this item on the primary storyline (spine) itself? Decides how a
            // ripple moves its edges (see the comment above the handler).
            BOOL isSpineItem = NO;
            @try {
                id spineItems = [primaryObj respondsToSelector:@selector(containedItems)]
                    ? ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems)) : nil;
                for (id spineItem in SpliceKit_mixerArrayFromContainer(spineItems)) {
                    if (spineItem == item) { isSpineItem = YES; break; }
                }
            } @catch (NSException *e) {}
            NSString *rippleScope = isSpineItem
                ? @"primary storyline: subsequent clips and their connected clips move"
                : @"connected clip only: the primary storyline does not ripple";

            CMTime frameDuration = {100, 3000, 1, 0};
            CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
            if (fd.timescale > 0 && fd.value > 0) frameDuration = fd;
            double frameSeconds = MAX(0.001, SpliceKit_secondsFromTime(frameDuration));
            double halfFrame = frameSeconds / 2.0;

            double beforeStart = SpliceKit_secondsFromTime(beforeRange.start);
            double beforeDuration = SpliceKit_secondsFromTime(beforeRange.duration);
            double beforeEnd = beforeStart + beforeDuration;
            double currentEdge = isStart ? beforeStart : beforeEnd;
            double requestedDelta = hasDelta ? deltaParam : (toParam - currentEdge);
            NSString *name = SpliceKit_displayNameForItem(item) ?: @"";
            NSDictionary *before = @{@"start": @(beforeStart), @"end": @(beforeEnd), @"duration": @(beforeDuration)};

            if (!isfinite(requestedDelta)) {
                result = @{@"error": @"deltaSeconds / toSeconds must be a finite number",
                           @"handle": handle, @"name": name, @"edge": edge, @"before": before,
                           @"trimCommand": @"ripple"};
                return;
            }
            if (fabs(requestedDelta) > 1000000.0) {
                result = @{@"error": [NSString stringWithFormat:
                               @"delta out of range: %.1fs requested on the %@ edge (limit 1000000 s)",
                               requestedDelta, edge],
                           @"handle": handle, @"name": name, @"edge": edge, @"before": before,
                           @"trimCommand": @"ripple"};
                return;
            }
            if (fabs(requestedDelta) < halfFrame) {
                result = @{
                    @"error": [NSString stringWithFormat:
                        @"no-op: requested delta %.4fs is less than half a frame (%.4fs) on the %@ edge",
                        requestedDelta, halfFrame, edge],
                    @"handle": handle, @"name": name, @"edge": edge,
                    @"requestedDelta": @(requestedDelta), @"before": before,
                    @"frameSeconds": @(frameSeconds), @"trimCommand": @"ripple",
                };
                return;
            }

            // Snap to whole frames so the CMTime is an exact frame multiple
            // (SpliceKit_buildCMTime truncates seconds*timescale, which for 29.97
            // can land one unit short of a frame).
            long long deltaFrames = llround(requestedDelta / frameSeconds);
            if (deltaFrames == 0) deltaFrames = requestedDelta > 0 ? 1 : -1;
            double delta = (double)deltaFrames * frameSeconds;

            double projectedDuration = beforeDuration + (isStart ? -delta : delta);
            if (projectedDuration < frameSeconds - 1e-9) {
                result = @{
                    @"error": [NSString stringWithFormat:
                        @"trim would leave '%@' shorter than one frame: current duration %.4fs, %@ edge delta %+.4fs, projected %.4fs (minimum %.4fs)",
                        name, beforeDuration, edge, delta, projectedDuration, frameSeconds],
                    @"handle": handle, @"name": name, @"edge": edge,
                    @"requestedDelta": @(requestedDelta), @"deltaSeconds": @(delta), @"before": before,
                    @"frameSeconds": @(frameSeconds), @"trimCommand": @"ripple",
                };
                return;
            }
            // Where the edges land. A primary-storyline clip keeps its position: a
            // start-point trim changes its duration and moves its END (and everything
            // after it); an end-point trim moves the end. A connected clip is not
            // rippled by the storyline, so its trimmed edge itself moves.
            double projectedStart = beforeStart;
            double projectedEnd = beforeEnd;
            if (isStart) {
                if (isSpineItem) projectedEnd = beforeEnd - delta;
                else projectedStart = beforeStart + delta;
            } else {
                projectedEnd = beforeEnd + delta;
            }
            NSDictionary *projected = @{@"start": @(projectedStart), @"end": @(projectedEnd), @"duration": @(projectedDuration)};

            if (dryRun) {
                result = @{
                    @"dryRun": @YES,
                    @"handle": handle, @"name": name, @"edge": edge,
                    @"requestedDelta": @(requestedDelta),
                    @"deltaSeconds": @(delta), @"deltaFrames": @(deltaFrames),
                    @"before": before, @"projected": projected,
                    @"onPrimaryStoryline": @(isSpineItem), @"rippleScope": rippleScope,
                    @"frameSeconds": @(frameSeconds), @"trimCommand": @"ripple",
                };
                return;
            }

            SEL trimSel = NSSelectorFromString(
                @"operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:trimFlags:temporalResolutionMode:animationHint:error:");
            if (![sequence respondsToSelector:trimSel]) {
                result = @{@"error": @"Sequence does not respond to operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:trimFlags:temporalResolutionMode:animationHint:error:",
                           @"handle": handle, @"name": name, @"edge": edge, @"before": before,
                           @"trimCommand": @"ripple"};
                return;
            }
            NSMethodSignature *sig = [sequence methodSignatureForSelector:trimSel];
            if (!sig) {
                result = @{@"error": @"No method signature for operationTrimEdit", @"handle": handle,
                           @"name": name, @"edge": edge, @"before": before, @"trimCommand": @"ripple"};
                return;
            }

            // For start trim: startEdits=[clip], endEdits=nil.
            // For end trim:   startEdits=nil,    endEdits=[clip].
            NSArray *clipArray = @[item];
            id startEdits = isStart ? clipArray : nil;
            id endEdits = isStart ? nil : clipArray;
            int edgeType = 0;
            int trimCommand = 1;   // ripple
            int trimFlags = 2;     // what FCP uses when dragging the clip edge
            int temporalRes = 0;
            id animHint = nil;
            // Real error pointer: a rejected trim writes an NSError here instead of
            // through NULL (the actionTrimDuration crash we hit before).
            NSError * __autoreleasing trimError = nil;
            NSError * __autoreleasing *trimErrorPtr = &trimError;
            CMTime deltaTime = SpliceKit_buildCMTime(delta, timeline);
            if (deltaTime.timescale == frameDuration.timescale) {
                deltaTime.value = deltaFrames * frameDuration.value;   // exact frame multiple
            }

            // The trim is one undo step (FCP: Edit > Undo Trim). operationTrimEdit alone
            // changes the model without registering an undoable action -- undo answered
            // "nothing to undo" and the trim was permanent (QA run 2) -- so it is wrapped
            // in the same actionBegin: / actionEnd:save:error: pair begin_edit uses, unless
            // a begin_edit group is open, whose step then covers it.
            BOOL openedUndoStep = NO;
            NSString *undoStepUnavailable = nil;   // why no step of our own was opened
            if (sOpenEditGroupName) {
                undoStepUnavailable = nil;         // the open begin_edit group covers it
            } else if (![sequence respondsToSelector:undoBeginSel] || ![sequence respondsToSelector:undoEndSel]) {
                undoStepUnavailable = @"the sequence does not answer actionBegin: / actionEnd:save:error:";
            } else {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(sequence, undoBeginSel, undoStepName);
                    openedUndoStep = YES;
                    trimUndoOpen = YES;
                    trimUndoSequence = sequence;
                } @catch (NSException *e) {
                    undoStepUnavailable = [NSString stringWithFormat:@"actionBegin: raised: %@", e.reason ?: @"exception"];
                }
            }

            if ([sequence respondsToSelector:@selector(beginEditing)]) {
                ((void (*)(id, SEL))objc_msgSend)(sequence, @selector(beginEditing));
            }

            BOOL ok = NO;
            NSString *invokeError = nil;
            @try {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:sequence];
                [inv setSelector:trimSel];
                [inv setArgument:&startEdits atIndex:2];
                [inv setArgument:&endEdits atIndex:3];
                [inv setArgument:&edgeType atIndex:4];
                [inv setArgument:&deltaTime atIndex:5];
                [inv setArgument:&trimCommand atIndex:6];
                [inv setArgument:&trimFlags atIndex:7];
                [inv setArgument:&temporalRes atIndex:8];
                [inv setArgument:&animHint atIndex:9];
                [inv setArgument:&trimErrorPtr atIndex:10];
                [inv invoke];
                [inv getReturnValue:&ok];
            } @catch (NSException *e) {
                invokeError = e.reason ?: @"operationTrimEdit raised an exception";
            }

            if ([sequence respondsToSelector:@selector(endEditing)]) {
                ((void (*)(id, SEL))objc_msgSend)(sequence, @selector(endEditing));
            }

            NSString *undoStepError = nil;
            if (openedUndoStep) {
                NSError *undoEndErr = nil;
                trimUndoOpen = NO;
                @try {
                    if (SpliceKit_selectorReturnsBOOL(sequence, undoEndSel)) {
                        BOOL endOK = ((BOOL (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
                            sequence, undoEndSel, undoStepName, YES, &undoEndErr);
                        if (!endOK && !undoEndErr) undoStepError = @"actionEnd:save:error: returned NO";
                    } else {
                        ((void (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
                            sequence, undoEndSel, undoStepName, YES, &undoEndErr);
                    }
                } @catch (NSException *e) {
                    undoStepError = e.reason ?: @"actionEnd:save:error: raised an exception";
                }
                if (undoEndErr) undoStepError = undoEndErr.localizedDescription ?: [undoEndErr description];
            }
            // One log line per trim whichever undo step covers it (QA run 3: a trim inside
            // a begin_edit group left no [Trim] line, only the group's).
            NSString *undoStepLog = openedUndoStep
                ? [NSString stringWithFormat:@"undo step \"%@\" closed%@", undoStepName,
                   undoStepError ? [NSString stringWithFormat:@" with error: %@", undoStepError] : @""]
                : (sOpenEditGroupName
                   ? [NSString stringWithFormat:@"inside the open begin_edit group \"%@\"", sOpenEditGroupName]
                   : [NSString stringWithFormat:@"no undo step of its own (%@)", undoStepUnavailable ?: @"unknown reason"]);
            SpliceKit_log(@"[Trim] %@ %@ edge %+.4fs: operationTrimEdit %@%@; %@",
                          handle, edge, delta, ok ? @"OK" : @"failed",
                          invokeError ? [NSString stringWithFormat:@" (%@)", invokeError] : @"", undoStepLog);

            // Re-read the clip's absolute range and judge the result by its duration.
            CMTimeRange afterRange;
            BOOL afterReadable = SpliceKit_tryReadTimelineRange(primaryObj, item, &afterRange);
            double afterStart = afterReadable ? SpliceKit_secondsFromTime(afterRange.start) : beforeStart;
            double afterDuration = afterReadable ? SpliceKit_secondsFromTime(afterRange.duration) : beforeDuration;
            double afterEnd = afterStart + afterDuration;
            NSDictionary *after = @{@"start": @(afterStart), @"end": @(afterEnd), @"duration": @(afterDuration)};

            double durationDelta = afterDuration - beforeDuration;
            double expectedDurationDelta = isStart ? -delta : delta;
            // Edit-point movement in FCP's sign convention, measured through the
            // duration so a rippled start edge (which stays put) still reads correctly.
            double appliedDelta = isStart ? -durationDelta : durationDelta;
            double startShift = afterStart - beforeStart;
            double endShift = afterEnd - beforeEnd;

            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            if (openedUndoStep) {
                out[@"undoStep"] = undoStepName;
                if (undoStepError) out[@"undoStepError"] = undoStepError;
            } else if (sOpenEditGroupName) {
                out[@"undoStep"] = sOpenEditGroupName;
                out[@"undoStepNote"] = @"inside the open begin_edit group; end_edit closes the step";
            } else {
                out[@"undoStepNote"] = [NSString stringWithFormat:@"%@, so no undo step could be registered for this trim",
                                        undoStepUnavailable ?: @"no undo step was opened"];
            }
            out[@"handle"] = handle;
            out[@"name"] = name;
            out[@"edge"] = edge;
            out[@"requestedDelta"] = @(requestedDelta);
            out[@"deltaSeconds"] = @(delta);
            out[@"deltaFrames"] = @(deltaFrames);
            out[@"before"] = before;
            out[@"after"] = after;
            out[@"afterReadable"] = @(afterReadable);
            out[@"appliedDelta"] = @(appliedDelta);
            out[@"appliedDurationDelta"] = @(durationDelta);
            out[@"startShift"] = @(startShift);
            out[@"endShift"] = @(endShift);
            out[@"returnedOK"] = @(ok);
            out[@"frameSeconds"] = @(frameSeconds);
            out[@"trimCommand"] = @"ripple";
            out[@"onPrimaryStoryline"] = @(isSpineItem);
            out[@"rippleScope"] = rippleScope;

            NSString *errorText = nil;
            if (invokeError) {
                errorText = invokeError;
            } else if (trimError) {
                errorText = trimError.localizedDescription ?: [trimError description];
            } else if (!ok) {
                errorText = @"operationTrimEdit returned NO";
            } else if (!afterReadable) {
                errorText = @"clip range could not be re-read after the trim";
            } else if (fabs(durationDelta) < halfFrame) {
                if (fabs(startShift) > halfFrame || fabs(endShift) > halfFrame) {
                    errorText = [NSString stringWithFormat:
                        @"clip duration did not change; the clip shifted by %+.4fs instead of being trimmed", startShift];
                } else {
                    errorText = @"nothing changed: clip range is identical after the trim";
                }
            } else if ((durationDelta > 0) != (expectedDurationDelta > 0)) {
                errorText = [NSString stringWithFormat:
                    @"the wrong edge moved: requested %@ edge %+.4fs, but the clip duration changed by %+.4fs (start %+.4fs, end %+.4fs)",
                    edge, delta, durationDelta, startShift, endShift];
            }

            if (errorText) {
                out[@"status"] = @"failed";
                out[@"error"] = errorText;
            } else {
                out[@"status"] = @"ok";
                if (fabs(durationDelta - expectedDurationDelta) > halfFrame) {
                    out[@"warning"] = [NSString stringWithFormat:
                        @"applied %+.4fs but %+.4fs was requested (reached the end of the source media)",
                        appliedDelta, delta];
                }
                if (isStart && fabs(startShift) < halfFrame && fabs(endShift) > halfFrame) {
                    out[@"note"] = @"ripple trim on the primary storyline: the clip kept its position; its start point moved within the source media, its duration changed, and subsequent clips rippled";
                }
            }
            result = out;
        } @catch (NSException *e) {
            if (trimUndoOpen && trimUndoSequence) {
                // Never leave the action open: close the step so the sequence is not
                // stuck in an open transaction (the trim itself may or may not have run).
                @try {
                    NSError *closeErr = nil;
                    ((void (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(trimUndoSequence, undoEndSel, undoStepName, YES, &closeErr);
                } @catch (NSException *e2) {}
                trimUndoOpen = NO;
                SpliceKit_log(@"[Trim] %@: exception %@; the undo step was closed", handle, e.reason ?: @"");
            }
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason], @"handle": handle};
        }
    });
    return result ?: @{@"error": @"Failed to trim clip"};
}
