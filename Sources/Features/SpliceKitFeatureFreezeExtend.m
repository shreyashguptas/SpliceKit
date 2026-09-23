//
//  SpliceKitFeatureFreezeExtend.m
//  SpliceKit - "Use Freeze Frames" for transitions without enough media handles:
//  the transition alert swizzles, hold-frame extension and the transition helpers
//  transitions.apply and timeline.action share.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Freeze Extend Transition Swizzle

// When FCP shows "not enough extra media" for a transition, this swizzle replaces
// the dialog with our own that includes a "Use Freeze Frames" button.
//
// We swizzle -[FFAnchoredSequence displayTransitionAvailableMediaAlertDialog:] directly
// rather than NSAlert's runModal, because FCP uses the deprecated NSAlert API with
// unpredictable return value mapping. By owning the dialog entirely, we control the
// output parameter (*a3): 1 = accept (create with overlap), 0 = cancel.

BOOL sFreezeExtendPendingAutoAccept = NO;
BOOL sFreezeExtendDidApply = NO;

void SpliceKit_armTransitionAlertAutoAccept(void) {
    sFreezeExtendPendingAutoAccept = YES;
    sFreezeExtendDidApply = NO;
}

static BOOL sFreezeExtendUseFreezeFramesForCurrentAlert = NO;
static IMP sOrigNSAlertRunModal = NULL;
static IMP sOrigActionAddTransitions = NULL;
static IMP sOrigOperationAddTransitions = NULL;
static IMP sOrigOperationAddTransitionsAskedRetry = NULL;
static double sFreezeExtendTargetClipStart = 0.0;

static IMP sOrigDisplayTransitionAlert = NULL;

static BOOL SpliceKit_shouldForceFreezeOverlap(void) {
    return sFreezeExtendUseFreezeFramesForCurrentAlert;
}

double SpliceKit_transitionFrameDurationSeconds(id timeline) {
    double seconds = 1.0 / 30.0;
    SEL seqSel = @selector(sequence);
    if ([timeline respondsToSelector:seqSel]) {
        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
        if (fd.timescale > 0 && fd.value > 0) {
            seconds = (double)fd.value / (double)fd.timescale;
        }
    }
    return MAX(seconds, 1.0 / 120.0);
}

double SpliceKit_transitionCurrentTimeSeconds(id timeline) {
    SEL currentTimeSel = NSSelectorFromString(@"currentSequenceTime");
    if (![timeline respondsToSelector:currentTimeSel]) return 0.0;
    CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, currentTimeSel);
    return SpliceKit_secondsFromTime(t);
}

BOOL SpliceKit_transitionSeekToSeconds(id timeline, double seconds) {
    if (!timeline) return NO;

    int32_t timescale = 24000;
    SEL seqSel = @selector(sequence);
    if ([timeline respondsToSelector:seqSel]) {
        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
        if (fd.timescale > 0) timescale = fd.timescale;
    }

    SEL setSel = @selector(setPlayheadTime:);
    if (![timeline respondsToSelector:setSel]) return NO;

    CMTime targetTime;
    targetTime.value = (int64_t)llround(seconds * (double)timescale);
    targetTime.timescale = timescale;
    targetTime.flags = 1;
    targetTime.epoch = 0;
    ((void (*)(id, SEL, CMTime))objc_msgSend)(timeline, setSel, targetTime);
    return YES;
}

BOOL SpliceKit_sendTimelineSimpleAction(id timeline, NSString *selectorName) {
    if (!timeline || selectorName.length == 0) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    if (![timeline respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(timeline, sel, nil);
    return YES;
}

static BOOL SpliceKit_transitionGetItemBounds(id item, double *outStart, double *outEnd) {
    if (!item || !outStart || !outEnd) return NO;

    SEL startSel = @selector(timelineStartTime);
    SEL durSel = @selector(duration);
    if (![item respondsToSelector:startSel] || ![item respondsToSelector:durSel]) return NO;

    CMTime start = ((CMTime (*)(id, SEL))STRET_MSG)(item, startSel);
    CMTime duration = ((CMTime (*)(id, SEL))STRET_MSG)(item, durSel);
    if (start.timescale <= 0 || duration.timescale <= 0) return NO;

    *outStart = (double)start.value / (double)start.timescale;
    *outEnd = *outStart + ((double)duration.value / (double)duration.timescale);
    return YES;
}

static BOOL SpliceKit_transitionGetItemBoundsInContext(id context, id item,
                                                       double *outStart, double *outEnd) {
    if (!item || !outStart || !outEnd) return NO;
    if (SpliceKit_transitionGetItemBounds(item, outStart, outEnd)) return YES;

    SEL rangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![context respondsToSelector:rangeSel]) return NO;

    CMTimeRange range =
        ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(context, rangeSel, item);
    if (range.start.timescale <= 0 || range.duration.timescale <= 0) return NO;

    *outStart = (double)range.start.value / (double)range.start.timescale;
    *outEnd = *outStart + ((double)range.duration.value / (double)range.duration.timescale);
    return YES;
}

static BOOL SpliceKit_transitionSelectItem(id timeline, id item) {
    if (!timeline || !item) return NO;

    SEL setSel = NSSelectorFromString(@"setSelectedItems:");
    if (![timeline respondsToSelector:setSel]) {
        setSel = NSSelectorFromString(@"_setSelectedItems:");
    }
    if (![timeline respondsToSelector:setSel]) return NO;

    ((void (*)(id, SEL, id))objc_msgSend)(timeline, setSel, @[item]);
    return YES;
}

static NSArray *SpliceKit_transitionContainedItemsForSequence(id sequence) {
    if (!sequence) return nil;

    id itemsSource = nil;
    if ([sequence respondsToSelector:@selector(primaryObject)]) {
        id primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
        if (primaryObj && [primaryObj respondsToSelector:@selector(containedItems)]) {
            itemsSource = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
        }
    }
    if (!itemsSource && [sequence respondsToSelector:@selector(containedItems)]) {
        itemsSource = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(containedItems));
    }

    return [itemsSource isKindOfClass:[NSArray class]] ? itemsSource : nil;
}

static NSArray *SpliceKit_transitionContainedItems(id timeline) {
    if (!timeline) return nil;

    SEL seqSel = @selector(sequence);
    id sequence = [timeline respondsToSelector:seqSel]
        ? ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel)
        : nil;
    return SpliceKit_transitionContainedItemsForSequence(sequence);
}

static id SpliceKit_transitionFindRightClipInItems(NSArray *items, double timeSeconds, double frame) {
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return nil;
    Class transitionClass = objc_getClass("FFAnchoredTransition");
    id bestItem = nil;
    double bestStart = -DBL_MAX;
    for (id item in items) {
        if (transitionClass && [item isKindOfClass:transitionClass]) continue;

        NSString *className = NSStringFromClass([item class]) ?: @"";
        if ([className containsString:@"Gap"]) continue;

        double start = 0.0;
        double end = 0.0;
        if (!SpliceKit_transitionGetItemBounds(item, &start, &end)) continue;
        if (end < timeSeconds - (frame * 2.0)) continue;
        if (start > timeSeconds + (frame * 2.0)) continue;
        if (start > bestStart) {
            bestStart = start;
            bestItem = item;
        }
    }

    return bestItem;
}

static NSArray *SpliceKit_transitionCandidateItems(id objects) {
    if (!objects) return @[];
    if ([objects isKindOfClass:[NSArray class]]) return (NSArray *)objects;
    if ([objects respondsToSelector:@selector(allObjects)]) {
        id all = ((id (*)(id, SEL))objc_msgSend)(objects, @selector(allObjects));
        if ([all isKindOfClass:[NSArray class]]) return (NSArray *)all;
    }
    return @[objects];
}

static void SpliceKit_transitionCaptureTargetFromObjects(id objects, id context, NSString *source) {
    NSArray *items = SpliceKit_transitionCandidateItems(objects);
    if (items.count == 0) return;

    Class transitionClass = objc_getClass("FFAnchoredTransition");
    id bestItem = nil;
    double bestStart = -DBL_MAX;
    NSMutableArray<NSString *> *summaries = [NSMutableArray array];

    for (id item in items) {
        if (!item) continue;

        NSString *className = NSStringFromClass([item class]) ?: @"<unknown>";
        double start = 0.0;
        double end = 0.0;
        BOOL hasBounds = SpliceKit_transitionGetItemBoundsInContext(context, item, &start, &end);
        [summaries addObject:hasBounds
            ? [NSString stringWithFormat:@"%@ %.4f-%.4f", className, start, end]
            : className];

        if (transitionClass && [item isKindOfClass:transitionClass]) continue;
        if (!hasBounds) continue;
        if (start > bestStart) {
            bestStart = start;
            bestItem = item;
        }
    }

    SpliceKit_log(@"[FreezeExtend] %@ candidates: %@", source ?: @"transition",
        [summaries componentsJoinedByString:@", "]);

    if (!bestItem) return;

    double start = 0.0;
    double end = 0.0;
    if (!SpliceKit_transitionGetItemBoundsInContext(context, bestItem, &start, &end)) return;

    id timeline = SpliceKit_getActiveTimelineModule();
    double frame = timeline ? SpliceKit_transitionFrameDurationSeconds(timeline) : (1.0 / 60.0);
    NSArray *timelineItems = SpliceKit_transitionContainedItems(timeline);
    id rightNeighbor = SpliceKit_transitionFindRightClipInItems(timelineItems, end + (frame * 0.25), frame);
    if (rightNeighbor && rightNeighbor != bestItem) {
        double neighborStart = 0.0;
        double neighborEnd = 0.0;
        if (SpliceKit_transitionGetItemBounds(rightNeighbor, &neighborStart, &neighborEnd) &&
            fabs(neighborStart - end) <= (frame * 4.0)) {
            bestItem = rightNeighbor;
            start = neighborStart;
            end = neighborEnd;
        }
    }

    sFreezeExtendTargetClipStart = start;
    SpliceKit_log(@"[FreezeExtend] Captured target from %@ start=%.4f end=%.4f class=%@",
        source ?: @"transition",
        start,
        end,
        NSStringFromClass([bestItem class]) ?: @"<unknown>");
}

NSUInteger SpliceKit_transitionCount(id timeline) {
    NSArray *items = SpliceKit_transitionContainedItems(timeline);
    if (![items isKindOfClass:[NSArray class]]) return 0;

    Class transitionClass = objc_getClass("FFAnchoredTransition");
    NSUInteger count = 0;
    for (id item in items) {
        if (transitionClass && [item isKindOfClass:transitionClass]) {
            count++;
        }
    }
    return count;
}

void SpliceKit_clearFreezeExtendTransientState(void) {
    sFreezeExtendPendingAutoAccept = NO;
    sFreezeExtendUseFreezeFramesForCurrentAlert = NO;
}

BOOL SpliceKit_waitForTransitionInsertion(id timeline, NSUInteger previousCount,
                                                 NSTimeInterval timeoutSeconds) {
    if (!timeline) return NO;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeoutSeconds, 0.0)];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        if (SpliceKit_transitionCount(timeline) > previousCount) {
            return YES;
        }

        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    return SpliceKit_transitionCount(timeline) > previousCount;
}

static double SpliceKit_defaultTransitionDurationSeconds(id timeline) {
    double seconds = 1.0;
    SEL seqSel = @selector(sequence);
    if (![timeline respondsToSelector:seqSel]) return seconds;

    id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
    if (!sequence) return seconds;

    SEL durSel = NSSelectorFromString(@"defaultTransitionDurationForVideo");
    if (![sequence respondsToSelector:durSel]) return seconds;

    CMTime duration = ((CMTime (*)(id, SEL))STRET_MSG)(sequence, durSel);
    if (duration.timescale > 0 && duration.value > 0) {
        seconds = (double)duration.value / (double)duration.timescale;
    }
    return MAX(seconds, 0.1);
}

static int SpliceKit_effectiveTransitionOverlapType(int overlapType, NSString *source) {
    if (!SpliceKit_shouldForceFreezeOverlap()) {
        return overlapType;
    }

    if (overlapType != 2) {
        SpliceKit_log(@"[FreezeExtend] Forcing transitionOverlapType -> 2");
        if (source.length > 0) {
            SpliceKit_log(@"%@", [NSString stringWithFormat:
                @"[FreezeExtend] Source=%@ original transitionOverlapType=%d",
                source, overlapType]);
        }
    }
    return 2;
}

static NSModalResponse SpliceKit_swizzled_NSAlert_runModal(id self, SEL _cmd) {
    // Only intercept when a freeze_extend API call is in progress.
    // All other alerts (including FCP's native transition dialog) pass through
    // completely unmodified so the user sees the original FCP behavior.
    if (!sFreezeExtendPendingAutoAccept) {
        return ((NSModalResponse (*)(id, SEL))sOrigNSAlertRunModal)(self, _cmd);
    }

    SpliceKit_log(@"[FreezeExtend] Auto-accepting NSAlert");
    sFreezeExtendUseFreezeFramesForCurrentAlert = YES;
    return 0;
}

static BOOL SpliceKit_swizzled_actionAddTransitions(id self, SEL _cmd, id spineObjects,
                                                    BOOL before, BOOL after, id effects,
                                                    int transitionOverlapType,
                                                    id *transitionsCreated, id rootItem,
                                                    BOOL reportErrors, id *error) {
    SpliceKit_transitionCaptureTargetFromObjects(spineObjects, rootItem ?: self,
        @"actionAddTransitionsToSpineObjects");
    int effectiveType = SpliceKit_effectiveTransitionOverlapType(transitionOverlapType,
        @"actionAddTransitionsToSpineObjects");
    return ((BOOL (*)(id, SEL, id, BOOL, BOOL, id, int, id *, id, BOOL, id *))
        sOrigActionAddTransitions)(self, _cmd, spineObjects, before, after, effects,
            effectiveType, transitionsCreated, rootItem, reportErrors, error);
}

static BOOL SpliceKit_swizzled_operationAddTransitions(id self, SEL _cmd, id spineObject,
                                                       id spineObjectsToAddTransition,
                                                       BOOL before, BOOL after,
                                                       id *spineTransitionClipsCreated,
                                                       id effects, CMTime transitionDuration,
                                                       int transitionOverlapType,
                                                       BOOL reportErrors, id *error) {
    SpliceKit_transitionCaptureTargetFromObjects(spineObjectsToAddTransition, spineObject ?: self,
        @"operationAddTransitionsToObjectsOnSpineObject");
    int effectiveType = SpliceKit_effectiveTransitionOverlapType(transitionOverlapType,
        @"operationAddTransitionsToObjectsOnSpineObject");
    return ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, id *, id, CMTime, int, BOOL, id *))
        sOrigOperationAddTransitions)(self, _cmd, spineObject, spineObjectsToAddTransition,
            before, after, spineTransitionClipsCreated, effects, transitionDuration,
            effectiveType, reportErrors, error);
}

static BOOL SpliceKit_swizzled_operationAddTransitionsAskedRetry(
    id self, SEL _cmd, id spineObject, id spineObjectsToAddTransition, BOOL before,
    BOOL after, id *spineTransitionClipsCreated, id effects, CMTime transitionDuration,
    int transitionOverlapType, id spareTransition, int reportErrors, int *askedRetry,
    id *error) {
    SpliceKit_transitionCaptureTargetFromObjects(spineObjectsToAddTransition, spineObject ?: self,
        @"operationAddTransitionsToObjectsOnSpineObject askedRetry");
    int effectiveType = SpliceKit_effectiveTransitionOverlapType(transitionOverlapType,
        @"operationAddTransitionsToObjectsOnSpineObject askedRetry");
    return ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, id *, id, CMTime, int, id, int, int *, id *))
        sOrigOperationAddTransitionsAskedRetry)(self, _cmd, spineObject,
            spineObjectsToAddTransition, before, after, spineTransitionClipsCreated,
            effects, transitionDuration, effectiveType, spareTransition, reportErrors,
            askedRetry, error);
}

// Helper: get all clip info from the timeline for debugging
static void SpliceKit_logTimelineClips(id timelineModule, NSString *label) {
    if (!timelineModule) return;
    id sequence = [timelineModule respondsToSelector:@selector(sequence)]
        ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence))
        : nil;
    if (!sequence) return;
    id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
        : nil;
    if (!primaryObj) return;
    NSArray *items = [primaryObj respondsToSelector:@selector(containedItems)]
        ? ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems))
        : nil;
    if (![items isKindOfClass:[NSArray class]]) return;

    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    BOOL canGetRange = [primaryObj respondsToSelector:erSel];
    NSMutableString *desc = [NSMutableString stringWithFormat:@"[FreezeExtend] %@ (%lu items):", label, (unsigned long)items.count];

    for (id item in items) {
        NSString *cls = NSStringFromClass([item class]) ?: @"?";
        if (canGetRange) {
            @try {
                CMTimeRange range =
                    ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(primaryObj, erSel, item);
                double s = SpliceKit_secondsFromTime(range.start);
                double d = SpliceKit_secondsFromTime(range.duration);
                [desc appendFormat:@" [%@ %.4f+%.4f]", cls, s, d];
            } @catch (NSException *e) {
                [desc appendFormat:@" [%@ ERR]", cls];
            }
        } else {
            [desc appendFormat:@" [%@]", cls];
        }
    }
    SpliceKit_log(@"%@", desc);
}

// Helper: apply retimeHold to a clip to create hidden media handles.
// retimeHold: (Shift+H) adds a hold segment at the playhead
// position, extending the clip's total duration. We DON'T trim back — the
// hold extension gives FCP the extra media it needs for the transition.
static BOOL SpliceKit_applyHoldFrameExtension(id timelineModule, double clipStart,
                                               double clipEnd, double frame,
                                               BOOL holdAtStart, double holdDuration) {
    if (!timelineModule) return NO;
    double clipDur = clipEnd - clipStart;
    SpliceKit_log(@"[FreezeExtend] === applyHold === clip=%.4f-%.4f holdAtStart=%@",
        clipStart, clipEnd, holdAtStart ? @"YES" : @"NO");

    id seq = [timelineModule respondsToSelector:@selector(sequence)]
        ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence)) : nil;
    id prim = (seq && [seq respondsToSelector:@selector(primaryObject)])
        ? ((id (*)(id, SEL))objc_msgSend)(seq, @selector(primaryObject)) : nil;
    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    id targetClip = nil;
    if (prim && [prim respondsToSelector:erSel] && [prim respondsToSelector:@selector(containedItems)]) {
        NSArray *items = ((id (*)(id, SEL))objc_msgSend)(prim, @selector(containedItems));
        Class transCls = objc_getClass("FFAnchoredTransition");
        if ([items isKindOfClass:[NSArray class]]) {
            for (id item in items) {
                if (transCls && [item isKindOfClass:transCls]) continue;
                @try {
                    CMTimeRange range = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(prim, erSel, item);
                    double s = (range.start.timescale > 0) ? (double)range.start.value/(double)range.start.timescale : -1;
                    if (fabs(s - clipStart) < frame * 2.0) { targetClip = item; break; }
                } @catch (NSException *ex) { continue; }
            }
        }
    }
    if (!targetClip) { SpliceKit_log(@"[FreezeExtend] applyHold: CLIP NOT FOUND"); return NO; }

    // Step 1: Apply retimeHold: to extend the clip.
    // For holdAtStart (right clip): select by seeking INTO the clip first,
    // then navigate to the edit point with nextEdit. This matches how FCP
    // handles Shift+H when the user clicks a clip then moves the playhead.
    // For !holdAtStart (left clip): seek to the last frame of the clip.
    if (holdAtStart) {
        // Select the right clip by seeking into its midpoint
        SpliceKit_transitionSeekToSeconds(timelineModule, clipStart + (clipDur * 0.5));
        SpliceKit_sendTimelineSimpleAction(timelineModule, @"selectClipAtPlayhead:");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        // Navigate playhead to the edit point (clip's start) via prevEdit
        SpliceKit_transitionSeekToSeconds(timelineModule, clipEnd);
        SpliceKit_sendTimelineSimpleAction(timelineModule, @"previousEdit:");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    } else {
        SpliceKit_transitionSeekToSeconds(timelineModule, clipEnd - frame);
        SpliceKit_transitionSelectItem(timelineModule, targetClip);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    }
    double actualPos = SpliceKit_transitionCurrentTimeSeconds(timelineModule);
    SpliceKit_log(@"[FreezeExtend] applyHold: playhead=%.4f holdAtStart=%@", actualPos, holdAtStart ? @"YES" : @"NO");

    SEL holdSel = NSSelectorFromString(@"retimeHold:");
    if ([timelineModule respondsToSelector:holdSel])
        ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, holdSel, nil);

    BOOL holdWorked = NO;
    double newDur = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        if (prim && [prim respondsToSelector:erSel]) {
            @try {
                CMTimeRange curRange = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(prim, erSel, targetClip);
                newDur = SpliceKit_secondsFromTime(curRange.duration);
                if (newDur > clipDur + frame) { holdWorked = YES; break; }
            } @catch (NSException *ex) {}
        }
    }
    if (!holdWorked) { SpliceKit_log(@"[FreezeExtend] applyHold: hold failed"); return NO; }
    SpliceKit_log(@"[FreezeExtend] applyHold: hold confirmed dur=%.4f (was %.4f)", newDur, clipDur);

    // Step 2: Trim back to original size.
    // For !holdAtStart (left clip): hold is at the END. Trim END back.
    // For holdAtStart (right clip): hold is at the START. The clip extends
    //   to the right. DON'T trim — the hold on the left edge is what the
    //   transition needs. We'll trim the excess after the transition.
    if (holdAtStart) {
        SpliceKit_log(@"[FreezeExtend] applyHold: skipping trim for holdAtStart (hold is on left edge)");
        SpliceKit_logTimelineClips(timelineModule, @"applyHold:done");
        SpliceKit_sendTimelineSimpleAction(timelineModule, @"deselectAll:");
        return holdWorked;
    }

    // Trim END back for left clip
    // FCP uses when manually dragging the clip edge (trimCommand=1, trimFlags=2).
    double holdAmount = newDur - clipDur;
    SEL trimSel = NSSelectorFromString(
        @"operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:trimFlags:temporalResolutionMode:animationHint:error:");
    if (seq && [seq respondsToSelector:trimSel]) {
        NSMethodSignature *sig = [seq methodSignatureForSelector:trimSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:seq];
            [inv setSelector:trimSel];

            // For end trim: startEdits=nil, endEdits=[clip], delta=negative
            // For start trim: startEdits=[clip], endEdits=nil, delta=positive
            id clipArray = @[targetClip];
            id nilVal = nil;
            int edgeType = 0;
            int trimCommand = 1;  // ripple
            int trimFlags = 2;
            int temporalRes = 0;
            id animHint = nil;
            void *errorPtr = NULL;

            // The hold always extends the END of the clip on the timeline.
            // Trim the END back by the hold amount (negative delta).
            CMTime delta;
            delta.timescale = 60000;
            delta.flags = 1;
            delta.epoch = 0;
            delta.value = -(int64_t)llround(holdAmount * 60000.0);

            SpliceKit_log(@"[FreezeExtend] applyHold: trimming end by delta=%.4f via operationTrimEdit (with beginEditing)", -holdAmount);

            // Wrap in beginEditing/endEditing like the manual drag does
            if ([seq respondsToSelector:@selector(beginEditing)])
                ((void (*)(id, SEL))objc_msgSend)(seq, @selector(beginEditing));

            // operationTrimEdit: has 9 params (with trimFlags):
            [inv setArgument:&nilVal atIndex:2];      // startEdits = nil
            [inv setArgument:&clipArray atIndex:3];    // endEdits = [clip]
            [inv setArgument:&edgeType atIndex:4];     // edgeType = 0
            [inv setArgument:&delta atIndex:5];        // byDelta = -holdAmount
            [inv setArgument:&trimCommand atIndex:6];  // trimCommand = 1 (ripple)
            [inv setArgument:&trimFlags atIndex:7];    // trimFlags = 2
            [inv setArgument:&temporalRes atIndex:8];  // temporalResolutionMode = 0
            [inv setArgument:&animHint atIndex:9];     // animationHint = nil
            [inv setArgument:&errorPtr atIndex:10];    // error = NULL

            @try {
                [inv invoke];
                BOOL ok = NO;
                [inv getReturnValue:&ok];
                SpliceKit_log(@"[FreezeExtend] applyHold: operationTrimEdit result=%@", ok ? @"YES" : @"NO");
            } @catch (NSException *e) {
                SpliceKit_log(@"[FreezeExtend] applyHold: operationTrimEdit exception: %@", e.reason);
            }

            if ([seq respondsToSelector:@selector(endEditing)])
                ((void (*)(id, SEL))objc_msgSend)(seq, @selector(endEditing));

            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        }
    }

    SpliceKit_logTimelineClips(timelineModule, @"applyHold:done");
    SpliceKit_sendTimelineSimpleAction(timelineModule, @"deselectAll:");
    return holdWorked;
}

// State for the async hold-frame-then-retry workflow
static double sFreezeExtendEditPointTime = 0.0;
static BOOL sFreezeExtendAsyncPending = NO;

// Replacement for -[FFAnchoredSequence displayTransitionAvailableMediaAlertDialog:]
// Instead of showing the "not enough extra media" dialog, cancel the current
// transition attempt, schedule hold-frame extensions on the short clips, then
// retry the transition on the next run-loop iteration.
static char SpliceKit_swizzled_displayTransitionAlert(id self, SEL _cmd, char *result) {
    // Freeze-extend auto-hold is disabled pending further development.
    // Pass through to FCP's original dialog.
    if (!sFreezeExtendPendingAutoAccept) {
        return ((char (*)(id, SEL, char *))sOrigDisplayTransitionAlert)(self, _cmd, result);
    }

    SpliceKit_log(@"[FreezeExtend] Intercepted 'not enough media' dialog");

    id timeline = SpliceKit_getActiveTimelineModule();
    if (!timeline) {
        return ((char (*)(id, SEL, char *))sOrigDisplayTransitionAlert)(self, _cmd, result);
    }

    double frame = SpliceKit_transitionFrameDurationSeconds(timeline);
    double defaultDur = SpliceKit_defaultTransitionDurationSeconds(timeline);
    double halfTransition = defaultDur / 2.0;

    // Use the captured target clip start as the edit point — the playhead may
    // be elsewhere (e.g. when a transition is dragged from the browser).
    // Fall back to currentSequenceTime if no capture is available.
    double editPointTime = (sFreezeExtendTargetClipStart > 0)
        ? sFreezeExtendTargetClipStart
        : SpliceKit_transitionCurrentTimeSeconds(timeline);

    // Scan ALL clips via the sequence (self) -> primaryObject and find the
    // two clips adjacent to the edit point.
    id primaryObj = [self respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(primaryObject))
        : nil;
    NSArray *items = nil;
    if (primaryObj && [primaryObj respondsToSelector:@selector(containedItems)])
        items = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));

    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    BOOL canGetRange = primaryObj && [primaryObj respondsToSelector:erSel];
    Class transCls = objc_getClass("FFAnchoredTransition");

    typedef struct { double start; double end; double dur; BOOL found; } ClipInfo;
    ClipInfo leftClip = {0, 0, 0, NO};
    ClipInfo rightClip = {0, 0, 0, NO};

    if (canGetRange && [items isKindOfClass:[NSArray class]]) {
        for (id item in items) {
            if (transCls && [item isKindOfClass:transCls]) continue;
            @try {
                CMTimeRange range =
                    ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(
                        primaryObj, erSel, item);
                if (range.duration.timescale <= 0 || range.duration.value <= 0) continue;
                double s = (double)range.start.value / (double)range.start.timescale;
                double d = (double)range.duration.value / (double)range.duration.timescale;
                double e = s + d;
                // Left clip: ends at or near the edit point
                if (fabs(e - editPointTime) < frame * 2.0) {
                    leftClip = (ClipInfo){s, e, d, YES};
                }
                // Right clip: starts at or near the edit point
                if (fabs(s - editPointTime) < frame * 2.0) {
                    rightClip = (ClipInfo){s, e, d, YES};
                }
            } @catch (NSException *ex) { continue; }
        }
    }

    SpliceKit_log(@"[FreezeExtend] Edit point=%.4f left=%@ (%.4f-%.4f, dur=%.4f) right=%@ (%.4f-%.4f, dur=%.4f) halfTrans=%.4f",
        editPointTime,
        leftClip.found ? @"YES" : @"NO", leftClip.start, leftClip.end, leftClip.dur,
        rightClip.found ? @"YES" : @"NO", rightClip.start, rightClip.end, rightClip.dur,
        halfTransition);

    BOOL needsExtension = (rightClip.found && rightClip.dur < halfTransition) ||
                           (leftClip.found && leftClip.dur < halfTransition);

    if (!needsExtension || sFreezeExtendAsyncPending) {
        if (sFreezeExtendPendingAutoAccept) {
            // Hold frames were already applied — just auto-accept
            SpliceKit_log(@"[FreezeExtend] Auto-accepting after hold extension");
            if (result) *result = 1;
            return 1;
        }
        SpliceKit_log(@"[FreezeExtend] No clips need extension (or retry pending), showing original dialog");
        return ((char (*)(id, SEL, char *))sOrigDisplayTransitionAlert)(self, _cmd, result);
    }

    // Cancel the current transition attempt (result=0), then schedule
    // hold-frame extension + transition retry asynchronously.
    if (result) *result = 0;
    sFreezeExtendEditPointTime = editPointTime;
    sFreezeExtendAsyncPending = YES;

    // Capture clip info for the async block
    __block ClipInfo asyncLeft = leftClip;
    __block ClipInfo asyncRight = rightClip;
    __block double asyncFrame = frame;
    __block double asyncHalf = halfTransition;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            id tl = SpliceKit_getActiveTimelineModule();
            if (!tl) {
                SpliceKit_log(@"[FreezeExtend] Async: no timeline module");
                sFreezeExtendAsyncPending = NO;
                return;
            }

            SpliceKit_log(@"[FreezeExtend] Async: starting hold extension workflow");
            SpliceKit_logTimelineClips(tl, @"Async start");

            // Undo the failed/cancelled transition attempt
            SpliceKit_log(@"[FreezeExtend] Async: undoing cancelled transition");
            SpliceKit_sendTimelineSimpleAction(tl, @"undo");
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.3]];
            SpliceKit_logTimelineClips(tl, @"After undo");

            // Extend LEFT clip first — the right clip extension shifts timeline
            // positions, making it hard to select the left clip afterward.
            if (asyncLeft.found && asyncLeft.dur < asyncHalf) {
                SpliceKit_log(@"[FreezeExtend] Async: extending left clip (%.4f-%.4f, dur=%.4fs)",
                    asyncLeft.start, asyncLeft.end, asyncLeft.dur);
                SpliceKit_applyHoldFrameExtension(tl, asyncLeft.start, asyncLeft.end, asyncFrame, NO, asyncHalf);
                SpliceKit_logTimelineClips(tl, @"After left hold");
            }

            // Extend right clip — after left extension, the right clip's start
            // has shifted. Re-scan to find its new position.
            if (asyncRight.found && asyncRight.dur < asyncHalf) {
                // Re-scan timeline to find the right clip's new position
                double newEditPoint = sFreezeExtendEditPointTime;
                id seq = [tl respondsToSelector:@selector(sequence)]
                    ? ((id (*)(id, SEL))objc_msgSend)(tl, @selector(sequence)) : nil;
                id prim = (seq && [seq respondsToSelector:@selector(primaryObject)])
                    ? ((id (*)(id, SEL))objc_msgSend)(seq, @selector(primaryObject)) : nil;
                if (prim && [prim respondsToSelector:@selector(containedItems)]) {
                    NSArray *curItems = ((id (*)(id, SEL))objc_msgSend)(prim, @selector(containedItems));
                    SEL erS = NSSelectorFromString(@"effectiveRangeOfObject:");
                    if ([curItems isKindOfClass:[NSArray class]] && [prim respondsToSelector:erS]) {
                        // Find the second non-transition clip (the right one)
                        Class tCls = objc_getClass("FFAnchoredTransition");
                        int clipIdx = 0;
                        for (id itm in curItems) {
                            if (tCls && [itm isKindOfClass:tCls]) continue;
                            clipIdx++;
                            if (clipIdx == 2) {
                                @try {
                                    CMTimeRange r =
                                        ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(prim, erS, itm);
                                    if (r.duration.timescale > 0) {
                                        double s = (double)r.start.value / (double)r.start.timescale;
                                        double d = (double)r.duration.value / (double)r.duration.timescale;
                                        double e = s + d;
                                        newEditPoint = s;
                                        SpliceKit_log(@"[FreezeExtend] Async: right clip now at %.4f-%.4f (dur=%.4f)", s, e, d);
                                        asyncRight = (ClipInfo){s, e, d, YES};
                                    }
                                } @catch (NSException *ex) {}
                                break;
                            }
                        }
                    }
                }
                sFreezeExtendEditPointTime = newEditPoint;
                SpliceKit_log(@"[FreezeExtend] Async: extending right clip (%.4f-%.4f, dur=%.4fs)",
                    asyncRight.start, asyncRight.end, asyncRight.dur);
                SpliceKit_applyHoldFrameExtension(tl, asyncRight.start, asyncRight.end, asyncFrame, YES, asyncHalf);
                SpliceKit_logTimelineClips(tl, @"After right hold");
            }

            // Navigate to edit point and retry the transition
            double seekTarget = MAX(0, sFreezeExtendEditPointTime - asyncFrame);
            SpliceKit_log(@"[FreezeExtend] Async: seeking to %.4f then nextEdit", seekTarget);
            SpliceKit_transitionSeekToSeconds(tl, seekTarget);
            SpliceKit_sendTimelineSimpleAction(tl, @"nextEdit:");
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.2]];

            double retryPos = SpliceKit_transitionCurrentTimeSeconds(tl);
            SpliceKit_log(@"[FreezeExtend] Async: retrying addTransition at playhead=%.4f", retryPos);
            SpliceKit_logTimelineClips(tl, @"Before retry");

            // Temporarily reduce the default transition duration to fit within
            // the available hold handles. The holds are ~2s but we want the
            // transition to only use what's needed — sized to 2x the shorter clip
            // so the transition overlaps holds, not real content.
            double minClipDur = MIN(asyncLeft.dur, asyncRight.dur);
            double fitDuration = 2.0 * minClipDur;
            float origDurSetting = [[NSUserDefaults standardUserDefaults]
                floatForKey:@"FFSequenceTransDefaultDuration"];
            [[NSUserDefaults standardUserDefaults]
                setFloat:(float)fitDuration
                forKey:@"FFSequenceTransDefaultDuration"];
            SpliceKit_log(@"[FreezeExtend] Async: set transition duration to %.4f (2 x %.4f)", fitDuration, minClipDur);

            // Auto-accept if the dialog still appears
            sFreezeExtendPendingAutoAccept = YES;

            SEL addSel = @selector(addTransition:);
            if ([tl respondsToSelector:addSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(tl, addSel, nil);
            } else {
                [[NSApplication sharedApplication] sendAction:addSel to:nil from:nil];
            }
            sFreezeExtendPendingAutoAccept = NO;

            // Restore original transition duration
            if (origDurSetting > 0.0f) {
                [[NSUserDefaults standardUserDefaults]
                    setFloat:origDurSetting forKey:@"FFSequenceTransDefaultDuration"];
            } else {
                [[NSUserDefaults standardUserDefaults]
                    removeObjectForKey:@"FFSequenceTransDefaultDuration"];
            }

            SpliceKit_logTimelineClips(tl, @"After transition added");

            SpliceKit_sendTimelineSimpleAction(tl, @"deselectAll:");
            SpliceKit_logTimelineClips(tl, @"Final result");
        } @catch (NSException *e) {
            SpliceKit_log(@"[FreezeExtend] Async hold+retry exception: %@", e.reason);
        }
        sFreezeExtendAsyncPending = NO;
    });

    SpliceKit_log(@"[FreezeExtend] Cancelled transition, scheduled async hold+retry");
    return 1;
}

// Install the swizzles (called once at startup)
void SpliceKit_installTransitionFreezeExtendSwizzle(void) {
    Class seqClass = objc_getClass("FFAnchoredSequence");
    if (!seqClass) {
        SpliceKit_log(@"[FreezeExtend] WARNING: FFAnchoredSequence class not found");
        return;
    }

    // Swizzle displayTransitionAvailableMediaAlertDialog: to add our button
    SEL alertSel = NSSelectorFromString(@"displayTransitionAvailableMediaAlertDialog:");
    Method alertMethod = class_getInstanceMethod(seqClass, alertSel);
    if (alertMethod) {
        sOrigDisplayTransitionAlert = method_setImplementation(alertMethod,
            (IMP)SpliceKit_swizzled_displayTransitionAlert);
        SpliceKit_log(@"[FreezeExtend] Swizzled -[FFAnchoredSequence displayTransitionAvailableMediaAlertDialog:]");
    }

    Method runModalMethod = class_getInstanceMethod([NSAlert class], @selector(runModal));
    if (runModalMethod) {
        sOrigNSAlertRunModal = method_setImplementation(runModalMethod,
            (IMP)SpliceKit_swizzled_NSAlert_runModal);
        SpliceKit_log(@"[FreezeExtend] Swizzled -[NSAlert runModal]");
    }

    SEL actionAddSel = NSSelectorFromString(
        @"actionAddTransitionsToSpineObjects:before:after:effects:transitionOverlapType:transitionsCreated:rootItem:reportErrors:error:");
    Method actionAddMethod = class_getInstanceMethod(seqClass, actionAddSel);
    if (actionAddMethod) {
        sOrigActionAddTransitions = method_setImplementation(actionAddMethod,
            (IMP)SpliceKit_swizzled_actionAddTransitions);
        SpliceKit_log(@"[FreezeExtend] Swizzled actionAddTransitionsToSpineObjects...");
    }

    SEL opAddSel = NSSelectorFromString(
        @"operationAddTransitionsToObjectsOnSpineObject:spineObjectsToAddTransition:before:after:spineTransitionClipsCreated:effects:transitionDuration:transitionOverlapType:reportErrors:error:");
    Method opAddMethod = class_getInstanceMethod(seqClass, opAddSel);
    if (opAddMethod) {
        sOrigOperationAddTransitions = method_setImplementation(opAddMethod,
            (IMP)SpliceKit_swizzled_operationAddTransitions);
        SpliceKit_log(@"[FreezeExtend] Swizzled operationAddTransitionsToObjectsOnSpineObject...");
    }

    SEL opAddRetrySel = NSSelectorFromString(
        @"operationAddTransitionsToObjectsOnSpineObject:spineObjectsToAddTransition:before:after:spineTransitionClipsCreated:effects:transitionDuration:transitionOverlapType:spareTransition:reportErrors:askedRetry:error:");
    Method opAddRetryMethod = class_getInstanceMethod(seqClass, opAddRetrySel);
    if (opAddRetryMethod) {
        sOrigOperationAddTransitionsAskedRetry = method_setImplementation(opAddRetryMethod,
            (IMP)SpliceKit_swizzled_operationAddTransitionsAskedRetry);
        SpliceKit_log(@"[FreezeExtend] Swizzled operationAddTransitionsToObjectsOnSpineObject...askedRetry...");
    }
}
