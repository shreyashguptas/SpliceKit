//
//  SpliceKitServerBrowser.m
//  SpliceKit - Browser clips: listing, placing a source clip or range on the timeline
//  (insert / connect / append), importing media into an event and removing it again.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Browser Clip Handlers
//
// Access clips in the event browser (source media, not timeline items).
//

// List clips available in the event browser
// The clips of one event as the browser shows them: displayOwnedClips (browser-visible)
// first, then ownedClips, childItems, items; a set becomes an array. Every walk over
// browser clips (browser.listClips, browser.placeClip by index or name, the timeline
// overview, the song-cut clip pool) goes through this, so an index from one listing
// names the same clip in the others. browser.placeClip used to ask ownedClips only, which FCP 12.3's
// FFEventRecord does not answer as an array, so name and index never resolved.
// Drop the items sitting in the library trash.
//
// -displayOwnedClips keeps answering an item after it has been moved to the library
// trash — renamed with a random suffix, "_SKPaste_10705" becoming
// "_SKPaste_10705-AWx2h5" — even though Final Cut Pro's own browser no longer shows it.
// That made cleanup_temp_projects report the same three scratch projects again
// immediately after trashing them, and browser.listClips offer trashed projects as clips
// to place. FFLibrary's -_itemInTrash: is the test, and it wants the item's library
// RECORD, not the FFAnchoredSequence: asked about the sequence it answers NO for a
// project that is demonstrably in __Trash/ on disk.
//
// -targetLibraryItem answers the FFSequenceRecord for a project but only the enclosing
// FFEventRecord for a source clip, so a source clip can only be judged by its event. An
// item we cannot positively identify as trashed is kept.
// Whether a browser item is a project (a timeline) rather than a source clip.
//
// -isProject only answers YES once Final Cut Pro has loaded the sequence, so right after
// launch every project except the open one reported NO: browser.listClips labelled three
// leaked scratch projects "isProject": false, and the live sweep duly handed one to
// add_clip_to_timeline. -sequenceType answers "sequence" for a project Final Cut Pro has
// not loaded and "clip" for a source clip, so between them both states are covered — a
// loaded project answers isProject YES and sequenceType "clip", an unloaded one answers
// isProject NO and sequenceType "sequence", and a source clip answers NO and "clip"
// either way.
BOOL SpliceKit_browserItemIsProject(id item) {
    if (!item) return NO;
    BOOL isProject = NO;
    if (SpliceKit_tryReadBoolSelector(item, @"isProject", &isProject) && isProject) return YES;
    SEL typeSel = NSSelectorFromString(@"sequenceType");
    if ([item respondsToSelector:typeSel]) {
        id type = nil;
        @try { type = ((id (*)(id, SEL))objc_msgSend)(item, typeSel); } @catch (NSException *e) { type = nil; }
        if ([type isKindOfClass:[NSString class]] &&
            [(NSString *)type caseInsensitiveCompare:@"sequence"] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static NSArray *SpliceKit_browserRemoveTrashedItems(id event, NSArray *items) {
    if (items.count == 0) return items;
    SEL inTrashSel = NSSelectorFromString(@"_itemInTrash:");
    id library = nil;
    SEL librarySel = NSSelectorFromString(@"library");
    if ([event respondsToSelector:librarySel]) {
        @try { library = ((id (*)(id, SEL))objc_msgSend)(event, librarySel); }
        @catch (NSException *e) { library = nil; }
    }
    if (!library || ![library respondsToSelector:inTrashSel]) return items;

    SEL recordSels[] = {
        NSSelectorFromString(@"targetSequenceRecord"),
        NSSelectorFromString(@"targetLibraryItem"),
    };
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        id record = nil;
        for (NSUInteger i = 0; i < sizeof(recordSels) / sizeof(recordSels[0]) && !record; i++) {
            if (![item respondsToSelector:recordSels[i]]) continue;
            @try { record = ((id (*)(id, SEL))objc_msgSend)(item, recordSels[i]); }
            @catch (NSException *e) { record = nil; }
        }
        BOOL trashed = NO;
        if (record) {
            @try {
                trashed = ((BOOL (*)(id, SEL, id))objc_msgSend)(library, inTrashSel, record);
            } @catch (NSException *e) { trashed = NO; }
        }
        if (!trashed) [kept addObject:item];
    }
    return kept;
}

NSArray *SpliceKit_browserClipsOfEvent(id event) {
    if (!event) return @[];
    for (NSString *name in @[@"displayOwnedClips", @"ownedClips", @"childItems", @"items"]) {
        SEL sel = NSSelectorFromString(name);
        if (![event respondsToSelector:sel]) continue;
        id clips = nil;
        @try { clips = ((id (*)(id, SEL))objc_msgSend)(event, sel); } @catch (NSException *e) { clips = nil; }
        NSArray *arr = SpliceKit_mixerArrayFromContainer(clips);
        if (arr) return SpliceKit_browserRemoveTrashedItems(event, arr);
    }
    return @[];
}

NSDictionary *SpliceKit_handleBrowserListClips(NSDictionary *params) {
    NSString *eventFilter = [params[@"event"] isKindOfClass:[NSString class]] ? params[@"event"] : nil;
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            // Get active library -> events -> clips
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            id library = [(NSArray *)libs firstObject];

            // Get events from library — events are FFFolder objects
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableArray *allClips = [NSMutableArray array];
            NSInteger clipIndex = 0;

            for (id event in (NSArray *)events) {
                NSString *eventName = @"";
                if ([event respondsToSelector:@selector(displayName)])
                    eventName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";
                if (eventFilter.length > 0 &&
                    ![[eventName lowercaseString] containsString:[eventFilter lowercaseString]]) {
                    continue;
                }

                // The event's clips as the browser shows them (shared walk, see
                // SpliceKit_browserClipsOfEvent).
                NSArray *clips = SpliceKit_browserClipsOfEvent(event);
                NSUInteger clipCount = clips.count;
                SpliceKit_log(@"[Browser] Event '%@' class=%@ clips=%@ count=%lu",
                    eventName, NSStringFromClass([event class]),
                    clips ? NSStringFromClass([clips class]) : @"nil",
                    (unsigned long)clipCount);

                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in (NSArray *)clips) {
                    NSMutableDictionary *info = [NSMutableDictionary dictionary];
                    info[@"index"] = @(clipIndex++);
                    info[@"event"] = eventName;
                    info[@"class"] = NSStringFromClass([clip class]);
                    // A project sits in the browser next to the clips (FCP's isProject flag);
                    // it is not a source clip for add_clip_to_timeline.
                    info[@"isProject"] = @(SpliceKit_browserItemIsProject(clip));

                    if ([clip respondsToSelector:@selector(displayName)]) {
                        id name = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                        info[@"name"] = name ?: @"";
                    }
                    if ([clip respondsToSelector:@selector(duration)]) {
                        CMTime d = ((CMTime (*)(id, SEL))STRET_MSG)(clip, @selector(duration));
                        info[@"duration"] = SpliceKit_serializeCMTime(d);
                    } else if ([clip respondsToSelector:NSSelectorFromString(@"clippedRange")]) {
                        CMTimeRange r = ((CMTimeRange (*)(id, SEL))STRET_MSG)(
                            clip, NSSelectorFromString(@"clippedRange"));
                        info[@"duration"] = SpliceKit_serializeCMTime(r.duration);
                    } else if ([clip respondsToSelector:NSSelectorFromString(@"unclippedRange")]) {
                        CMTimeRange r = ((CMTimeRange (*)(id, SEL))STRET_MSG)(
                            clip, NSSelectorFromString(@"unclippedRange"));
                        info[@"duration"] = SpliceKit_serializeCMTime(r.duration);
                    }

                    NSString *handle = SpliceKit_storeHandle(clip);
                    info[@"handle"] = handle;
                    [allClips addObject:info];
                }
            }

            result = @{@"clips": allClips, @"count": @(allClips.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list browser clips"};
}

static NSString *SpliceKit_browserClipName(id clip) {
    if (!clip) return @"";
    if ([clip respondsToSelector:@selector(displayName)]) {
        id name = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
        if ([name isKindOfClass:[NSString class]]) return name;
    }
    return @"";
}

static NSString *SpliceKit_browserShortDescription(id obj, NSUInteger maxLength) {
    if (!obj) return @"";
    NSString *desc = [obj description] ?: @"";
    if (desc.length > maxLength) {
        return [desc substringToIndex:maxLength];
    }
    return desc;
}

static BOOL SpliceKit_browserCMTimeIsUsable(CMTime t) {
    return (t.timescale > 0 && t.value >= 0);
}

static void SpliceKit_browserAssignTime(NSMutableDictionary *dict, NSString *key, CMTime t) {
    if (!dict || key.length == 0) return;
    if (SpliceKit_browserCMTimeIsUsable(t)) {
        dict[key] = SpliceKit_serializeCMTime(t);
    }
}

static id SpliceKit_browserSequenceForTimeline(id timelineModule) {
    if (!timelineModule || ![timelineModule respondsToSelector:@selector(sequence)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence));
}

static id SpliceKit_browserPrimaryContainerForSequence(id sequence) {
    if (!sequence) return nil;
    if ([sequence respondsToSelector:@selector(primaryObject)]) {
        id container = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
        if (container) return container;
    }
    return sequence;
}

static NSArray *SpliceKit_browserContainedItems(id sequence, id container) {
    id items = nil;
    if (container && [container respondsToSelector:@selector(containedItems)]) {
        items = ((id (*)(id, SEL))objc_msgSend)(container, @selector(containedItems));
    } else if (sequence && [sequence respondsToSelector:@selector(containedItems)]) {
        items = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(containedItems));
    }
    return [items isKindOfClass:[NSArray class]] ? items : nil;
}

static NSDictionary *SpliceKit_browserTimelineItemSummary(id item, id container) {
    if (!item) return @{};

    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"class"] = NSStringFromClass([item class]) ?: @"";
    summary[@"description"] = SpliceKit_browserShortDescription(item, 240);
    summary[@"handle"] = SpliceKit_storeHandle(item) ?: @"";

    NSString *name = SpliceKit_browserClipName(item);
    if (name.length > 0) summary[@"name"] = name;

    if ([item respondsToSelector:@selector(duration)]) {
        CMTime duration = ((CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
        SpliceKit_browserAssignTime(summary, @"duration", duration);
    }

    SEL effectiveRangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (container && [container respondsToSelector:effectiveRangeSel]) {
        @try {
            CMTimeRange range =
                ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(container, effectiveRangeSel, item);
            if (SpliceKit_browserCMTimeIsUsable(range.start)) {
                summary[@"startTime"] = SpliceKit_serializeCMTime(range.start);
            }
            if (SpliceKit_browserCMTimeIsUsable(range.duration)) {
                CMTime endTime = SpliceKit_endTimeForRange(range);
                if (SpliceKit_browserCMTimeIsUsable(endTime)) {
                    summary[@"endTime"] = SpliceKit_serializeCMTime(endTime);
                }
            }
        } @catch (__unused NSException *e) {}
    }

    return summary;
}

static NSDictionary *SpliceKit_browserPlacementSnapshot(id timelineModule, id clip) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    id sequence = SpliceKit_browserSequenceForTimeline(timelineModule);
    id container = SpliceKit_browserPrimaryContainerForSequence(sequence);

    if (clip) {
        snapshot[@"clipHandle"] = SpliceKit_storeHandle(clip) ?: @"";
        snapshot[@"clipClass"] = NSStringFromClass([clip class]) ?: @"";
        snapshot[@"clipDescription"] = SpliceKit_browserShortDescription(clip, 240);
        NSString *clipName = SpliceKit_browserClipName(clip);
        if (clipName.length > 0) snapshot[@"clipName"] = clipName;
    }

    if (sequence) {
        snapshot[@"sequenceHandle"] = SpliceKit_storeHandle(sequence) ?: @"";
        snapshot[@"sequenceClass"] = NSStringFromClass([sequence class]) ?: @"";
        snapshot[@"sequenceDescription"] = SpliceKit_browserShortDescription(sequence, 240);
        NSString *sequenceName = SpliceKit_browserClipName(sequence);
        if (sequenceName.length > 0) snapshot[@"sequenceName"] = sequenceName;
        if ([sequence respondsToSelector:@selector(duration)]) {
            CMTime duration = ((CMTime (*)(id, SEL))STRET_MSG)(sequence, @selector(duration));
            SpliceKit_browserAssignTime(snapshot, @"sequenceDuration", duration);
        }
    }

    if (container) {
        snapshot[@"containerHandle"] = SpliceKit_storeHandle(container) ?: @"";
        snapshot[@"containerClass"] = NSStringFromClass([container class]) ?: @"";
        snapshot[@"containerDescription"] = SpliceKit_browserShortDescription(container, 240);
        SEL endSel = NSSelectorFromString(@"endTimeOfLastContainedItem");
        if ([container respondsToSelector:endSel]) {
            CMTime end = ((CMTime (*)(id, SEL))STRET_MSG)(container, endSel);
            SpliceKit_browserAssignTime(snapshot, @"containerEndTime", end);
        }
    }

    SEL currentSel = NSSelectorFromString(@"currentSequenceTime");
    if ([timelineModule respondsToSelector:currentSel]) {
        CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(timelineModule, currentSel);
        SpliceKit_browserAssignTime(snapshot, @"currentSequenceTime", t);
    }
    if ([timelineModule respondsToSelector:@selector(playheadTime)]) {
        CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(timelineModule, @selector(playheadTime));
        SpliceKit_browserAssignTime(snapshot, @"playheadTime", t);
    }
    SEL committedSel = NSSelectorFromString(@"committedPlayheadTime");
    if ([timelineModule respondsToSelector:committedSel]) {
        CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(timelineModule, committedSel);
        SpliceKit_browserAssignTime(snapshot, @"committedPlayheadTime", t);
    }

    NSArray *items = SpliceKit_browserContainedItems(sequence, container);
    snapshot[@"itemCount"] = @(items.count);
    if (items.count > 0) {
        NSInteger tailStart = MAX((NSInteger)0, (NSInteger)items.count - 5);
        NSMutableArray *tailItems = [NSMutableArray array];
        for (NSInteger idx = tailStart; idx < (NSInteger)items.count; idx++) {
            [tailItems addObject:SpliceKit_browserTimelineItemSummary(items[idx], container)];
        }
        snapshot[@"tailItems"] = tailItems;
        snapshot[@"lastItem"] = SpliceKit_browserTimelineItemSummary(items.lastObject, container);
    }

    return snapshot;
}

static BOOL SpliceKit_browserPrepareExplicitPasteboard(id clip,
                                                       id mediaRange,
                                                       NSString **outPasteboardName,
                                                       NSMutableDictionary *debugInfo,
                                                       NSString **outError) {
    NSPasteboard *generalPB = [NSPasteboard generalPasteboard];
    [generalPB clearContents];

    Class ffPasteboardClass = objc_getClass("FFPasteboard");
    if (!ffPasteboardClass) {
        if (outError) *outError = @"FFPasteboard class not found";
        return NO;
    }

    id ffPasteboard = ((id (*)(id, SEL))objc_msgSend)((id)ffPasteboardClass, @selector(alloc));
    SEL initWithNameSel = NSSelectorFromString(@"initWithName:");
    if (![ffPasteboard respondsToSelector:initWithNameSel]) {
        if (outError) *outError = @"FFPasteboard does not respond to initWithName:";
        return NO;
    }

    NSString *pasteboardName = NSPasteboardNameGeneral;
    ffPasteboard = ((id (*)(id, SEL, id))objc_msgSend)(ffPasteboard, initWithNameSel, pasteboardName);
    BOOL wroteRanges = NO;
    BOOL wroteAnchored = NO;

    SEL writeRangesSel = NSSelectorFromString(@"writeRangesOfMedia:options:");
    if (mediaRange && [ffPasteboard respondsToSelector:writeRangesSel]) {
        wroteRanges = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ffPasteboard, writeRangesSel, @[mediaRange], nil);
    }

    if (!wroteRanges) {
        SEL writeAnchoredSel = NSSelectorFromString(@"writeAnchoredObjects:options:");
        if ([ffPasteboard respondsToSelector:writeAnchoredSel]) {
            wroteAnchored = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ffPasteboard, writeAnchoredSel, @[clip], nil);
        }
    }

    if (debugInfo) {
        debugInfo[@"pasteboardName"] = pasteboardName ?: @"";
        debugInfo[@"pasteboardWriteRanges"] = @(wroteRanges);
        debugInfo[@"pasteboardWriteAnchored"] = @(wroteAnchored);
        if ([ffPasteboard respondsToSelector:@selector(hasMedia:)]) {
            BOOL hasMedia = ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(ffPasteboard, @selector(hasMedia:), YES);
            debugInfo[@"pasteboardHasMedia"] = @(hasMedia);
        }
        if ([ffPasteboard respondsToSelector:@selector(hasEdits:)]) {
            BOOL hasEdits = ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(ffPasteboard, @selector(hasEdits:), YES);
            debugInfo[@"pasteboardHasEdits"] = @(hasEdits);
        }
    }

    if (outPasteboardName) *outPasteboardName = pasteboardName;
    if (!wroteRanges && !wroteAnchored) {
        if (outError) *outError = @"Failed to write explicit clip data to pasteboard";
        return NO;
    }
    return YES;
}

static NSDictionary *SpliceKit_browserInsertExplicitClipAtPlayhead(id timelineModule,
                                                                   id clip,
                                                                   NSString *pasteboardName) {
    NSMutableDictionary *debugInfo = [NSMutableDictionary dictionary];
    debugInfo[@"primitive"] = @"explicit_paste_at_playhead";
    debugInfo[@"before"] = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"pasteboardName"] = pasteboardName ?: @"";

    SEL pasteSel = NSSelectorFromString(@"paste:");
    if (![timelineModule respondsToSelector:pasteSel]) {
        return @{@"error": @"Timeline module does not respond to paste:",
                 @"placementDebug": debugInfo};
    }

    ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, pasteSel, nil);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.12]];

    NSDictionary *after = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"after"] = after;

    return @{@"status": @"ok",
             @"primitive": @"explicit_paste_at_playhead",
             @"placementVerified": @YES,
             @"placementDebug": debugInfo};
}

static NSDictionary *SpliceKit_browserAppendExplicitClipToTimelineEnd(id timelineModule,
                                                                      id clip,
                                                                      NSString *pasteboardName) {
    NSMutableDictionary *debugInfo = [NSMutableDictionary dictionary];
    debugInfo[@"primitive"] = @"verified_seek_to_end_then_paste";
    debugInfo[@"pasteboardName"] = pasteboardName ?: @"";

    NSDictionary *before = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"before"] = before;

    NSDictionary *durationInfo = before[@"sequenceDuration"];
    NSDictionary *containerEndInfo = before[@"containerEndTime"];
    double targetSeconds = [containerEndInfo[@"seconds"] doubleValue];
    if (targetSeconds <= 0.0) targetSeconds = [durationInfo[@"seconds"] doubleValue];

    if (targetSeconds < 0.0) {
        return @{@"error": @"Could not determine the current primary storyline end.",
                 @"placementDebug": debugInfo};
    }

    double frameSeconds = SpliceKit_transitionFrameDurationSeconds(timelineModule);
    double tolerance = MAX(frameSeconds * 2.0, 0.05);
    debugInfo[@"targetEndSeconds"] = @(targetSeconds);
    debugInfo[@"toleranceSeconds"] = @(tolerance);

    NSString *expectedName = SpliceKit_browserClipName(clip);
    double beforePlayheadSeconds = [before[@"playheadTime"][@"seconds"] doubleValue];
    SpliceKit_log(@"%@", [NSString stringWithFormat:
        @"[AppendPlacement] begin clip=%@ targetEnd=%.6f playheadBefore=%.6f primitive=%@",
        expectedName.length > 0 ? expectedName : @"<unnamed>",
        targetSeconds,
        beforePlayheadSeconds,
        @"verified_seek_to_end_then_paste"]);

    if (!SpliceKit_transitionSeekToSeconds(timelineModule, targetSeconds)) {
        return @{@"error": @"Could not move the playhead to the current storyline end.",
                 @"placementDebug": debugInfo};
    }

    NSDictionary *seekImmediate = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"seekImmediate"] = seekImmediate;

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    NSDictionary *seekNextRunloop = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"seekNextRunloop"] = seekNextRunloop;

    NSDictionary *seekDeferred = nil;
    double currentSequenceSeconds = 0.0;
    double playheadSeconds = 0.0;
    double committedSeconds = 0.0;
    BOOL currentMatches = NO;
    BOOL playheadMatches = NO;
    BOOL committedMatches = NO;
    NSInteger seekVerificationPollCount = 0;

    NSDate *seekDeadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
    do {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        seekVerificationPollCount++;
        seekDeferred = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
        debugInfo[@"seekDeferred"] = seekDeferred;

        currentSequenceSeconds = [seekDeferred[@"currentSequenceTime"][@"seconds"] doubleValue];
        playheadSeconds = [seekDeferred[@"playheadTime"][@"seconds"] doubleValue];
        committedSeconds = [seekDeferred[@"committedPlayheadTime"][@"seconds"] doubleValue];

        currentMatches = fabs(currentSequenceSeconds - targetSeconds) <= tolerance;
        playheadMatches = fabs(playheadSeconds - targetSeconds) <= tolerance;
        committedMatches = (seekDeferred[@"committedPlayheadTime"] == nil) ||
            fabs(committedSeconds - targetSeconds) <= tolerance;
    } while (!(currentMatches && playheadMatches && committedMatches) &&
             [seekDeadline timeIntervalSinceNow] > 0.0);

    debugInfo[@"seekVerificationPollCount"] = @(seekVerificationPollCount);
    debugInfo[@"seekVerified"] = @(currentMatches && playheadMatches && committedMatches);

    if (!(currentMatches && playheadMatches && committedMatches)) {
        NSString *reason = [NSString stringWithFormat:
            @"Append verification failed before paste. target=%.6f current=%.6f playhead=%.6f committed=%.6f",
            targetSeconds, currentSequenceSeconds, playheadSeconds, committedSeconds];
        SpliceKit_log(@"[AppendPlacement] %@", reason);
        return @{@"error": reason, @"placementDebug": debugInfo};
    }

    SEL pasteSel = NSSelectorFromString(@"paste:");
    if (![timelineModule respondsToSelector:pasteSel]) {
        return @{@"error": @"Timeline module does not respond to paste:",
                 @"placementDebug": debugInfo};
    }

    ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, pasteSel, nil);
    NSDictionary *after = nil;
    NSDictionary *match = nil;
    double afterTailSeconds = targetSeconds;
    BOOL tailAdvanced = NO;
    NSInteger verificationPollCount = 0;

    NSDate *verificationDeadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
    do {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        verificationPollCount++;

        after = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
        NSDictionary *afterContainerEnd = after[@"containerEndTime"];
        NSDictionary *afterDuration = after[@"sequenceDuration"];
        afterTailSeconds = [afterContainerEnd[@"seconds"] doubleValue];
        if (afterTailSeconds <= 0.0) afterTailSeconds = [afterDuration[@"seconds"] doubleValue];
        tailAdvanced = afterTailSeconds > (targetSeconds + (frameSeconds * 0.5));

        id sequence = SpliceKit_browserSequenceForTimeline(timelineModule);
        id container = SpliceKit_browserPrimaryContainerForSequence(sequence);
        NSArray *items = SpliceKit_browserContainedItems(sequence, container);
        match = nil;

        for (id item in items) {
            NSString *itemName = SpliceKit_browserClipName(item);
            if (expectedName.length == 0 || ![itemName isEqualToString:expectedName]) continue;

            NSDictionary *summary = SpliceKit_browserTimelineItemSummary(item, container);
            double startSeconds = [summary[@"startTime"][@"seconds"] doubleValue];
            if (fabs(startSeconds - targetSeconds) <= tolerance) {
                match = summary;
                break;
            }
        }
    } while ((match == nil || !tailAdvanced) &&
             [verificationDeadline timeIntervalSinceNow] > 0.0);

    debugInfo[@"after"] = after;
    if (match) debugInfo[@"matchedInsertedItem"] = match;

    double beforeTailSeconds = [containerEndInfo[@"seconds"] doubleValue];
    if (beforeTailSeconds <= 0.0) beforeTailSeconds = [durationInfo[@"seconds"] doubleValue];
    BOOL durationGrew = afterTailSeconds > (beforeTailSeconds + (frameSeconds * 0.5));
    BOOL verified = (match != nil && durationGrew);
    debugInfo[@"durationBeforeSeconds"] = @(beforeTailSeconds);
    debugInfo[@"durationAfterSeconds"] = @(afterTailSeconds);
    debugInfo[@"storylineTailBeforeSeconds"] = @(beforeTailSeconds);
    debugInfo[@"storylineTailAfterSeconds"] = @(afterTailSeconds);
    debugInfo[@"durationGrew"] = @(durationGrew);
    debugInfo[@"verificationPollCount"] = @(verificationPollCount);

    if (!verified) {
        NSString *reason = [NSString stringWithFormat:
            @"Append paste completed but could not verify the inserted clip at the prior storyline end."];
        SpliceKit_log(@"%@", [NSString stringWithFormat:
            @"[AppendPlacement] fail clip=%@ targetEnd=%.6f afterTail=%.6f match=%@ polls=%ld",
            expectedName.length > 0 ? expectedName : @"<unnamed>",
            targetSeconds,
            afterTailSeconds,
            match ? @"YES" : @"NO",
            (long)verificationPollCount]);
        SpliceKit_log(@"[AppendPlacement] %@", reason);
        return @{@"error": reason, @"placementDebug": debugInfo};
    }

    double insertedStartSeconds = [match[@"startTime"][@"seconds"] doubleValue];
    SpliceKit_log(@"%@", [NSString stringWithFormat:
        @"[AppendPlacement] success clip=%@ targetEnd=%.6f insertedStart=%.6f tailBefore=%.6f tailAfter=%.6f polls=%ld",
        expectedName.length > 0 ? expectedName : @"<unnamed>",
        targetSeconds,
        insertedStartSeconds,
        beforeTailSeconds,
        afterTailSeconds,
        (long)verificationPollCount]);

    return @{@"status": @"ok",
             @"primitive": @"verified_seek_to_end_then_paste",
             @"placementVerified": @YES,
             @"placementDebug": debugInfo};
}

static NSDictionary *SpliceKit_browserConnectExplicitClipAtPlayhead(id timelineModule,
                                                                    id clip,
                                                                    NSString *pasteboardName,
                                                                    BOOL backtimed) {
    NSMutableDictionary *debugInfo = [NSMutableDictionary dictionary];
    debugInfo[@"primitive"] = backtimed ? @"explicit_anchor_backtimed" : @"explicit_paste_anchored";
    debugInfo[@"before"] = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"pasteboardName"] = pasteboardName ?: @"";

    // pasteAnchored: is Edit > Paste as Connected Clip. A backtimed connect edit (FCP:
    // Shift-Q, the end of the source range lands at the playhead) only exists on the
    // anchorWithPasteboard:backtimed:trackType: path.
    SEL pasteAnchoredSel = NSSelectorFromString(@"pasteAnchored:");
    SEL anchorSel = NSSelectorFromString(@"anchorWithPasteboard:backtimed:trackType:");

    if (!backtimed && [timelineModule respondsToSelector:pasteAnchoredSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, pasteAnchoredSel, nil);
    } else if ([timelineModule respondsToSelector:anchorSel]) {
        NSString *resolvedPasteboardName = pasteboardName.length > 0 ? pasteboardName : NSPasteboardNameGeneral;
        ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(timelineModule,
                                                        anchorSel,
                                                        resolvedPasteboardName,
                                                        backtimed,
                                                        @"all");
    } else if (backtimed) {
        return @{@"error": @"a backtimed connect edit is not available: this Final Cut Pro build's timeline module has no anchorWithPasteboard:backtimed:trackType:",
                 @"placementDebug": debugInfo};
    } else {
        return @{@"error": @"Timeline module does not respond to pasteAnchored: or anchorWithPasteboard:backtimed:trackType:",
                 @"placementDebug": debugInfo};
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.12]];

    NSDictionary *after = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"after"] = after;

    return @{@"status": @"ok",
             @"primitive": backtimed ? @"explicit_anchor_backtimed" : @"explicit_paste_anchored",
             @"placementVerified": @YES,
             @"placementDebug": debugInfo};
}

// Move the playhead to `seconds` and wait (up to 0.75 s) until the timeline module
// reports it there on every clock it exposes. The same check the append path makes
// before it pastes: an edit made at a playhead that has not settled lands elsewhere.
// Also records whether the skimmer is active: while the pointer skims the timeline,
// FCP makes edits at the skimmer, not the playhead.
static BOOL SpliceKit_browserSeekAndVerify(id timelineModule, double seconds, double tolerance,
                                           NSMutableDictionary *debugInfo) {
    if (!SpliceKit_transitionSeekToSeconds(timelineModule, seconds)) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
    NSInteger polls = 0;
    BOOL ok = NO;
    do {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        polls++;
        NSDictionary *snap = SpliceKit_browserPlacementSnapshot(timelineModule, nil);
        double current = [snap[@"currentSequenceTime"][@"seconds"] doubleValue];
        double playhead = [snap[@"playheadTime"][@"seconds"] doubleValue];
        BOOL committedOK = (snap[@"committedPlayheadTime"] == nil) ||
            fabs([snap[@"committedPlayheadTime"][@"seconds"] doubleValue] - seconds) <= tolerance;
        ok = fabs(current - seconds) <= tolerance && fabs(playhead - seconds) <= tolerance && committedOK;
    } while (!ok && [deadline timeIntervalSinceNow] > 0.0);
    if (debugInfo) {
        debugInfo[@"seekPolls"] = @(polls);
        debugInfo[@"seekVerified"] = @(ok);
    }
    return ok;
}

static BOOL SpliceKit_browserSkimmingActive(id timelineModule) {
    SEL sel = NSSelectorFromString(@"isToolSkimming");
    if (![timelineModule respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(timelineModule, sel);
}

// The timeline exactly as get_timeline_clips reports it (spine items + connected
// items, no markers), keyed by object identity (pointerKey), with the handle as a
// fallback key. A placement is verified by diffing this before and after the edit:
// the new entries are the object(s) the edit added. Object identity is used rather
// than handle strings because the handle table is cleared when it reaches
// SPLICEKIT_MAX_HANDLES entries, which would make every item look new.
static NSDictionary *SpliceKit_browserTimelineEntries(void) {
    NSDictionary *state = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @100000,
                                                                     @"connected_limit": @100000,
                                                                     @"include_markers": @NO,
                                                                     @"include_nested": @NO,
                                                                     @"include_pointer_keys": @YES});
    NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
    if (![state isKindOfClass:[NSDictionary class]] || state[@"error"]) return byKey;
    for (NSString *listKey in @[@"items", @"connectedItems"]) {
        id list = state[listKey];
        if (![list isKindOfClass:[NSArray class]]) continue;
        for (id entry in (NSArray *)list) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *key = entry[@"pointerKey"];
            if (![key isKindOfClass:[NSString class]] || key.length == 0) key = entry[@"handle"];
            if (![key isKindOfClass:[NSString class]] || key.length == 0) continue;
            NSMutableDictionary *copy = [entry mutableCopy];
            copy[@"connected"] = @([listKey isEqualToString:@"connectedItems"]);
            byKey[key] = copy;
        }
    }
    return byKey;
}

double SpliceKit_browserEntrySeconds(NSDictionary *entry, NSString *key) {
    id time = entry[key];
    if ([time isKindOfClass:[NSDictionary class]] && [time[@"seconds"] respondsToSelector:@selector(doubleValue)]) {
        return [time[@"seconds"] doubleValue];
    }
    return NAN;
}

// One placed clip, in the vocabulary get_timeline_clips already uses.
static NSDictionary *SpliceKit_browserPlacedEntry(NSDictionary *entry) {
    NSMutableDictionary *placed = [NSMutableDictionary dictionary];
    placed[@"handle"] = entry[@"handle"] ?: @"";
    if (entry[@"name"]) placed[@"name"] = entry[@"name"];
    if (entry[@"class"]) placed[@"class"] = entry[@"class"];
    id lane = entry[@"effectiveLane"] ?: entry[@"lane"];
    if (lane) placed[@"lane"] = lane;
    BOOL connected = [entry[@"connected"] boolValue];
    placed[@"connected"] = @(connected);
    if (!connected && entry[@"index"]) placed[@"spineIndex"] = entry[@"index"];
    if (connected && entry[@"parentIndex"]) placed[@"anchoredToSpineIndex"] = entry[@"parentIndex"];
    double startSeconds = SpliceKit_browserEntrySeconds(entry, @"startTime");
    double endSeconds = SpliceKit_browserEntrySeconds(entry, @"endTime");
    if (!isnan(startSeconds)) placed[@"startSeconds"] = @(startSeconds);
    if (!isnan(endSeconds)) placed[@"endSeconds"] = @(endSeconds);
    if (!isnan(startSeconds) && !isnan(endSeconds)) placed[@"durationSeconds"] = @(endSeconds - startSeconds);
    return placed;
}

// Place a browser clip on the timeline with one of Final Cut Pro's edits: append (E),
// insert (W) or connect (Q). Optional params:
//   inSeconds / outSeconds  range selection inside the source clip, in seconds from
//                           the clip's first frame (FCP: Set Range Start I / End O)
//   atSeconds               move the playhead there first; insert and connect are made
//                           at the playhead (append always goes to the storyline end)
//   backtimed               connect only (FCP: Shift-Q): the END of the range lands at
//                           the playhead
//   dryRun                  resolve clip, range and target; change nothing
// The edit goes through Final Cut Pro's own pasteboard route (FFPasteboard
// writeRangesOfMedia: with the range, then paste: / pasteAnchored:), which is what a
// range selection in the browser does; the general pasteboard is replaced. The result
// reports the placed clip found by diffing the timeline before and after (object
// identity), whether the placed duration matches the range (rangeHonored) and whether
// it landed where asked (positionVerified), both within two frames (at least 50 ms).
// Other objects the edit created (the far half of a split clip, a gap) are listed
// under alsoNew. Error answers after state changed carry stateChanged.
// browser.placeClip's index / name lookup: the walk browser.listClips makes with no
// event filter, so `index` is that listing's index and `name` its first
// case-insensitive substring match; index is tried first when both are given.
// outListed receives how many clips were walked, for the error text.
static id SpliceKit_browserFindClip(NSNumber *indexNum, NSString *name, NSInteger *outListed) {
    if (outListed) *outListed = 0;
    id libs = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
    if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) return nil;
    id library = [(NSArray *)libs firstObject];
    SEL eventsSel = NSSelectorFromString(@"events");
    if (![library respondsToSelector:eventsSel]) return nil;
    id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
    if (![events isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *all = [NSMutableArray array];
    for (id event in (NSArray *)events) {
        [all addObjectsFromArray:SpliceKit_browserClipsOfEvent(event)];
    }
    if (outListed) *outListed = (NSInteger)all.count;
    if (indexNum) {
        NSInteger idx = [indexNum integerValue];
        if (idx >= 0 && idx < (NSInteger)all.count) return all[(NSUInteger)idx];
    }
    NSString *lowerName = name.length > 0 ? [name lowercaseString] : nil;
    if (lowerName) {
        for (id c in all) {
            if ([[SpliceKit_browserClipName(c) lowercaseString] containsString:lowerName]) return c;
        }
    }
    return nil;
}

static NSDictionary *SpliceKit_handleBrowserPlaceClip(NSDictionary *params,
                                                      NSString *selectorName,
                                                      NSString *actionName) {
    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    NSNumber *indexNum = [params[@"index"] isKindOfClass:[NSNumber class]] ? params[@"index"] : nil;
    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : nil;

    NSString *edit = @"insert";
    if ([selectorName isEqualToString:@"appendWithSelectedMedia:"]) edit = @"append";
    else if ([selectorName isEqualToString:@"anchorWithPasteboard:backtimed:trackType:"]) edit = @"connect";

    NSNumber *inNum = [params[@"inSeconds"] isKindOfClass:[NSNumber class]] ? params[@"inSeconds"] : nil;
    NSNumber *outNum = [params[@"outSeconds"] isKindOfClass:[NSNumber class]] ? params[@"outSeconds"] : nil;
    NSNumber *atNum = [params[@"atSeconds"] isKindOfClass:[NSNumber class]] ? params[@"atSeconds"] : nil;
    BOOL backtimed = [params[@"backtimed"] respondsToSelector:@selector(boolValue)] && [params[@"backtimed"] boolValue];
    BOOL dryRun = [params[@"dryRun"] respondsToSelector:@selector(boolValue)] && [params[@"dryRun"] boolValue];
    const double kMaxSeconds = 86400.0 * 24.0;   // 24 days: longer than any timeline, short of overflow

    if (!handle && !indexNum && !name) {
        return @{@"error": @"Clip not found. Provide handle, index, or name."};
    }
    for (NSNumber *n in @[inNum ?: @0, outNum ?: @0, atNum ?: @0]) {
        double v = [n doubleValue];
        if (!isfinite(v) || v > kMaxSeconds) {
            return @{@"error": @"inSeconds, outSeconds and atSeconds must be finite times in seconds"};
        }
    }
    if (atNum && [edit isEqualToString:@"append"]) {
        return @{@"error": @"an append edit (Final Cut Pro: Append, E) always adds at the end of the primary storyline; use insert or connect to place at a time"};
    }
    if (atNum && [atNum doubleValue] < 0.0) {
        return @{@"error": @"atSeconds must be 0 or more"};
    }
    if (backtimed && ![edit isEqualToString:@"connect"]) {
        return @{@"error": @"backtimed is only available for connect edits here (Final Cut Pro: Shift-Q)"};
    }
    if (backtimed) actionName = @"connectBacktimedAtPlayhead";

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        // What this call has already changed when an error answer is built.
        __block BOOL playheadMoved = NO, pasteboardReplaced = NO, selectionCleared = NO;
        NSDictionary *(^failed)(NSString *, NSDictionary *) = ^NSDictionary *(NSString *message, NSDictionary *debug) {
            NSMutableDictionary *err = [NSMutableDictionary dictionary];
            err[@"error"] = message;
            if (debug.count > 0) err[@"placementDebug"] = debug;
            if (playheadMoved || pasteboardReplaced || selectionCleared) {
                err[@"stateChanged"] = @{@"playheadMoved": @(playheadMoved),
                                         @"pasteboardReplaced": @(pasteboardReplaced),
                                         @"selectionCleared": @(selectionCleared)};
            }
            return err;
        };
        @try {
            id clip = nil;
            BOOL clipFromHandle = NO;

            // Resolve clip by handle, index, or name
            if (handle) {
                clip = SpliceKit_resolveHandle(handle);
                clipFromHandle = (clip != nil);
            }

            NSInteger listedCount = 0;
            if (!clip && (indexNum || name)) {
                clip = SpliceKit_browserFindClip(indexNum, name, &listedCount);
            }

            if (!clip) {
                NSString *message;
                if (handle && !indexNum && !name) {
                    message = [NSString stringWithFormat:
                        @"handle %@ does not resolve to an object (handles expire when the handle table is cleared; browser_list_clips() gives fresh ones)", handle];
                } else if (indexNum && !name) {
                    message = [NSString stringWithFormat:
                        @"no browser clip at index %ld (browser_list_clips() lists %ld clip%@%@)",
                        (long)[indexNum integerValue], (long)listedCount, listedCount == 1 ? @"" : @"s",
                        listedCount > 0 ? [NSString stringWithFormat:@", indices 0-%ld", (long)(listedCount - 1)] : @""];
                } else if (name && !indexNum) {
                    message = [NSString stringWithFormat:
                        @"no browser clip whose name contains \"%@\" (%ld clip%@ listed; browser_list_clips() shows their names)",
                        name, (long)listedCount, listedCount == 1 ? @"" : @"s"];
                } else {
                    message = [NSString stringWithFormat:
                        @"no browser clip at index %ld or named like \"%@\" (%ld clip%@ listed)",
                        (long)[indexNum integerValue], name ?: @"", (long)listedCount, listedCount == 1 ? @"" : @"s"];
                }
                result = @{@"error": message};
                return;
            }

            id timelineModule = SpliceKit_getActiveTimelineModule();
            if (!timelineModule) {
                result = @{@"error": @"No active timeline module. Is a project open?"};
                return;
            }

            // A handle from get_timeline_clips names an item already on the timeline; this
            // edit places source clips from the browser. Checked by object identity against
            // the same walk the result diff uses, so it cannot be fooled by a reused handle.
            // A project is not a source clip: Final Cut Pro does not paste a project into
            // a timeline (the edit runs and places nothing), and the open timeline's own
            // project least of all.
            {
                BOOL clipIsProject = SpliceKit_browserItemIsProject(clip);
                id currentSequence = [timelineModule respondsToSelector:@selector(sequence)]
                    ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence)) : nil;
                if (clipIsProject || (currentSequence && clip == currentSequence)) {
                    NSString *projectName = SpliceKit_browserClipName(clip);
                    result = @{@"error": [NSString stringWithFormat:
                        @"\"%@\" is %@, not a source clip: SpliceKit does not place a project (pasting one placed "
                        @"nothing in the QA run). Pick a clip from browser_list_clips() (projects are marked "
                        @"isProject: true there), or open the project with open_project().",
                        projectName, (currentSequence && clip == currentSequence) ? @"the open timeline's own project" : @"a project"]};
                    return;
                }
            }

            if (clipFromHandle) {
                NSDictionary *onTimeline = SpliceKit_browserTimelineEntries();
                NSString *clipKey = SpliceKit_handlePointerKey(clip);
                NSDictionary *timelineEntry = clipKey.length > 0 ? onTimeline[clipKey] : nil;
                if (timelineEntry) {
                    NSString *entryName = [timelineEntry[@"name"] isKindOfClass:[NSString class]] ? timelineEntry[@"name"] : @"";
                    result = @{@"error": [NSString stringWithFormat:
                        @"handle %@ is a clip on the current timeline (\"%@\"), not a source clip in the browser; "
                        @"add_clip_to_timeline places browser clips (handles from browser_list_clips()). To repeat a "
                        @"timeline clip use FCP's copy and paste: select_clips([...]), then timeline_action(\"copy\") and "
                        @"\"paste\" or \"pasteAsConnected\" at the playhead.", handle, entryName]};
                    return;
                }
            }

            // The clip's own range. Its first frame is not necessarily time 0 (clippedRange
            // starts at the source timecode), so inSeconds/outSeconds count from that frame.
            // browser.listClips reports `duration`, which can differ from clippedRange; the
            // range end is accepted up to the longer of the two.
            CMTimeRange clipRange = {0};
            BOOL haveClipRange = NO;
            if ([clip respondsToSelector:@selector(clippedRange)]) {
                clipRange = ((CMTimeRange (*)(id, SEL))STRET_MSG)(clip, @selector(clippedRange));
                haveClipRange = clipRange.duration.timescale > 0;
            }
            double listedDuration = NAN;
            if ([clip respondsToSelector:@selector(duration)]) {
                CMTime dur = ((CMTime (*)(id, SEL))STRET_MSG)(clip, @selector(duration));
                if (dur.timescale > 0) listedDuration = (double)dur.value / (double)dur.timescale;
                if (!haveClipRange && dur.timescale > 0) {
                    clipRange.start = (CMTime){0, dur.timescale, 1, 0};
                    clipRange.duration = dur;
                    haveClipRange = YES;
                }
            }
            BOOL wholeClip = (inNum == nil && outNum == nil);
            if (!haveClipRange && !wholeClip) {
                result = @{@"error": @"a range needs the clip's duration, which could not be read (no clippedRange or duration); the whole clip can still be placed"};
                return;
            }

            double frameSeconds = SpliceKit_transitionFrameDurationSeconds(timelineModule);
            // The clip's own frame duration when it exposes one: FCP snaps a range to the
            // clip's frames, so a 12 fps time-lapse can differ from the request by more
            // than a sequence frame and still be right.
            double clipFrameSeconds = 0.0;
            SEL clipFrameSel = NSSelectorFromString(@"frameDuration");
            if ([clip respondsToSelector:clipFrameSel]) {
                @try {
                    CMTime fd = ((CMTime (*)(id, SEL))STRET_MSG)(clip, clipFrameSel);
                    if (fd.timescale > 0 && fd.value > 0) clipFrameSeconds = (double)fd.value / (double)fd.timescale;
                } @catch (__unused NSException *e) {}
            }
            double tolerance = MAX(MAX(frameSeconds * 2.0, clipFrameSeconds), 0.05);
            double clipDuration = haveClipRange
                ? (double)clipRange.duration.value / (double)clipRange.duration.timescale : NAN;
            double maxDuration = clipDuration;
            if (!isnan(listedDuration) && (isnan(maxDuration) || listedDuration > maxDuration)) maxDuration = listedDuration;
            double clipStartSeconds = (haveClipRange && clipRange.start.timescale > 0)
                ? (double)clipRange.start.value / (double)clipRange.start.timescale : 0.0;
            double inSeconds = inNum ? [inNum doubleValue] : 0.0;
            double outSeconds = outNum ? [outNum doubleValue] : (isnan(clipDuration) ? 0.0 : clipDuration);
            BOOL snapped = NO;

            if (!wholeClip) {
                if (inSeconds < 0.0) {
                    result = @{@"error": @"the range start must be 0 or more (seconds from the clip's first frame)"};
                    return;
                }
                if (outSeconds > maxDuration + frameSeconds * 0.5) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"the range end (%.3fs) is beyond the end of the clip, which is %.3fs long%@",
                        outSeconds, maxDuration,
                        (!isnan(listedDuration) && fabs(listedDuration - clipDuration) > 0.0005)
                            ? [NSString stringWithFormat:@" (clippedRange %.3fs, duration %.3fs)", clipDuration, listedDuration] : @""]};
                    return;
                }
                outSeconds = MIN(outSeconds, maxDuration);
                if (clipFrameSeconds > 0.0) {
                    double snappedIn = round(inSeconds / clipFrameSeconds) * clipFrameSeconds;
                    double snappedOut = round(outSeconds / clipFrameSeconds) * clipFrameSeconds;
                    if (fabs(snappedIn - inSeconds) > 1e-6 || fabs(snappedOut - outSeconds) > 1e-6) snapped = YES;
                    inSeconds = MAX(0.0, snappedIn);
                    outSeconds = MIN(maxDuration, snappedOut);
                }
                double minLength = clipFrameSeconds > 0.0 ? clipFrameSeconds : frameSeconds;
                if (outSeconds - inSeconds < minLength * 0.5) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"the range must be at least one frame long (start %.3fs, end %.3fs; one frame is %.4fs)",
                        inSeconds, outSeconds, minLength]};
                    return;
                }
            }

            CMTimeRange sourceRange = clipRange;
            if (!wholeClip) {
                int32_t startScale = clipRange.start.timescale > 0 ? clipRange.start.timescale : clipRange.duration.timescale;
                int32_t durationScale = clipRange.duration.timescale;
                sourceRange.start.value = (clipRange.start.timescale > 0 ? clipRange.start.value : 0)
                    + (int64_t)llround(inSeconds * (double)startScale);
                sourceRange.start.timescale = startScale;
                sourceRange.start.flags = 1;
                sourceRange.start.epoch = clipRange.start.epoch;
                sourceRange.duration.value = (int64_t)llround((outSeconds - inSeconds) * (double)durationScale);
                sourceRange.duration.timescale = durationScale;
                sourceRange.duration.flags = 1;
                sourceRange.duration.epoch = 0;
            }

            NSString *clipName = @"";
            if ([clip respondsToSelector:@selector(displayName)])
                clipName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";

            NSMutableDictionary *plan = [NSMutableDictionary dictionary];
            plan[@"edit"] = edit;
            plan[@"backtimed"] = @(backtimed);
            plan[@"clip"] = clipName;   // legacy: the clip's name, as browser.appendClip always returned
            NSMutableDictionary *sourceClip = [NSMutableDictionary dictionary];
            sourceClip[@"handle"] = SpliceKit_storeHandle(clip) ?: @"";
            sourceClip[@"name"] = clipName;
            sourceClip[@"class"] = NSStringFromClass([clip class]) ?: @"";
            if (!isnan(clipDuration)) sourceClip[@"durationSeconds"] = @(clipDuration);
            if (!isnan(listedDuration)) sourceClip[@"listedDurationSeconds"] = @(listedDuration);
            sourceClip[@"startSeconds"] = @(clipStartSeconds);
            if (clipFrameSeconds > 0.0) sourceClip[@"frameSeconds"] = @(clipFrameSeconds);
            plan[@"sourceClip"] = sourceClip;
            NSMutableDictionary *source = [NSMutableDictionary dictionary];
            source[@"startSeconds"] = @(inSeconds);
            source[@"endSeconds"] = @(outSeconds);
            source[@"durationSeconds"] = @(outSeconds - inSeconds);
            source[@"wholeClip"] = @(wholeClip);
            if (snapped) source[@"snappedToClipFrames"] = @YES;
            plan[@"source"] = source;
            NSMutableDictionary *target = [NSMutableDictionary dictionary];
            if (atNum) target[@"requestedSeconds"] = atNum;
            target[@"playheadBeforeSeconds"] = @(SpliceKit_transitionCurrentTimeSeconds(timelineModule));
            plan[@"target"] = target;

            if (dryRun) {
                plan[@"status"] = @"dry_run";
                plan[@"dryRun"] = @YES;
                result = plan;
                return;
            }

            // Order: seek (and verify) first, then the pasteboard, then the selection, then
            // paste, so the pasteboard is replaced as late as possible before it is used.
            NSMutableDictionary *seekDebug = [NSMutableDictionary dictionary];
            double targetSeconds = NAN;
            if (atNum) {
                targetSeconds = [atNum doubleValue];
                playheadMoved = YES;
                if (!SpliceKit_browserSeekAndVerify(timelineModule, targetSeconds, tolerance, seekDebug)) {
                    result = failed([NSString stringWithFormat:
                        @"could not move the playhead to %.3fs before the edit", targetSeconds], seekDebug);
                    return;
                }
            } else if (![edit isEqualToString:@"append"]) {
                targetSeconds = SpliceKit_transitionCurrentTimeSeconds(timelineModule);
            }
            BOOL skimmingActive = SpliceKit_browserSkimmingActive(timelineModule);
            seekDebug[@"skimmingActive"] = @(skimmingActive);

            id mediaRange = nil;
            Class rangeObjClass = objc_getClass("FigTimeRangeAndObject");
            SEL rangeAndObjSel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
            if (haveClipRange && rangeObjClass && [(id)rangeObjClass respondsToSelector:rangeAndObjSel]) {
                mediaRange = ((id (*)(id, SEL, CMTimeRange, id))objc_msgSend)(
                    (id)rangeObjClass, rangeAndObjSel, sourceRange, clip);
            }
            if (!wholeClip && !mediaRange) {
                result = failed(@"a range selection needs FigTimeRangeAndObject, which this Final Cut Pro build does not provide; the whole clip can still be placed", seekDebug);
                return;
            }

            NSString *pasteboardName = nil;
            NSMutableDictionary *pasteboardDebug = [NSMutableDictionary dictionary];
            NSString *pasteboardError = nil;
            pasteboardReplaced = YES;
            BOOL wroteExplicitClip = SpliceKit_browserPrepareExplicitPasteboard(
                clip, mediaRange, &pasteboardName, pasteboardDebug, &pasteboardError);
            [pasteboardDebug addEntriesFromDictionary:seekDebug];
            if (!wroteExplicitClip) {
                result = failed(pasteboardError ?: @"Failed to prepare explicit pasteboard data.", pasteboardDebug);
                return;
            }
            if (!wholeClip && ![pasteboardDebug[@"pasteboardWriteRanges"] boolValue]) {
                // The fallback wrote the whole clip; placing that would silently ignore the range.
                result = failed(@"Final Cut Pro did not accept a range for this clip (writeRangesOfMedia: failed), so the range cannot be honored; nothing was placed (the pasteboard now holds the whole clip)", pasteboardDebug);
                return;
            }

            selectionCleared = YES;
            SpliceKit_sendTimelineSimpleAction(timelineModule, @"deselectAll:");
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

            uint64_t handleGenerationBefore = SpliceKit_handleGeneration();
            NSDictionary *beforeEntries = SpliceKit_browserTimelineEntries();

            NSDictionary *placementResult = nil;
            if ([edit isEqualToString:@"append"]) {
                placementResult = SpliceKit_browserAppendExplicitClipToTimelineEnd(
                    timelineModule, clip, pasteboardName);
            } else if ([edit isEqualToString:@"connect"]) {
                placementResult = SpliceKit_browserConnectExplicitClipAtPlayhead(
                    timelineModule, clip, pasteboardName, backtimed);
            } else {
                placementResult = SpliceKit_browserInsertExplicitClipAtPlayhead(
                    timelineModule, clip, pasteboardName);
            }

            NSMutableDictionary *mergedResult = [NSMutableDictionary dictionaryWithDictionary:
                placementResult ?: @{}];
            NSMutableDictionary *mergedDebug = [NSMutableDictionary dictionary];
            if ([placementResult[@"placementDebug"] isKindOfClass:[NSDictionary class]]) {
                [mergedDebug addEntriesFromDictionary:placementResult[@"placementDebug"]];
            }
            [mergedDebug addEntriesFromDictionary:pasteboardDebug];
            if (mergedDebug.count > 0) {
                mergedResult[@"placementDebug"] = mergedDebug;
            }
            if (placementResult[@"error"]) {
                result = failed(placementResult[@"error"], mergedDebug);
                return;
            }

            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

            // What the edit added: objects that exist now and did not before.
            NSDictionary *afterEntries = SpliceKit_browserTimelineEntries();
            BOOL handleTableReset = SpliceKit_handleGeneration() != handleGenerationBefore;
            NSMutableArray *newEntries = [NSMutableArray array];
            for (NSString *entryKey in afterEntries) {
                if (beforeEntries[entryKey]) continue;
                [newEntries addObject:SpliceKit_browserPlacedEntry(afterEntries[entryKey])];
            }

            // The placed clip is the new object that is the source clip: same name, on the
            // primary storyline for append/insert and connected for connect, not a gap, and
            // nearest the target. Anything else new (the far half of a split clip, a gap FCP
            // added) is reported separately.
            BOOL wantConnected = [edit isEqualToString:@"connect"];
            double storylineEndBefore = [mergedDebug[@"targetEndSeconds"] doubleValue];
            double aimSeconds = [edit isEqualToString:@"append"] ? storylineEndBefore : targetSeconds;
            NSDictionary *primary = nil;
            double primaryDistance = INFINITY;
            for (NSDictionary *entry in newEntries) {
                if ([entry[@"connected"] boolValue] != wantConnected) continue;
                NSString *cls = entry[@"class"] ?: @"";
                if ([cls rangeOfString:@"Gap"].location != NSNotFound) continue;
                BOOL sameName = clipName.length == 0 || [entry[@"name"] isEqualToString:clipName];
                double anchor = backtimed ? [entry[@"endSeconds"] doubleValue] : [entry[@"startSeconds"] doubleValue];
                double distance = isnan(aimSeconds) ? 0.0 : fabs(anchor - aimSeconds);
                if (!sameName) distance += 1.0e6;   // a differently named object only if nothing else fits
                if (distance < primaryDistance) {
                    primaryDistance = distance;
                    primary = entry;
                }
            }
            NSMutableArray *alsoNew = [NSMutableArray array];
            for (NSDictionary *entry in newEntries) {
                if (entry != primary) [alsoNew addObject:entry];
            }
            [alsoNew sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                double sa = [a[@"startSeconds"] doubleValue], sb = [b[@"startSeconds"] doubleValue];
                return sa < sb ? NSOrderedAscending : (sa > sb ? NSOrderedDescending : NSOrderedSame);
            }];

            double sourceDuration = outSeconds - inSeconds;
            NSNumber *rangeHonored = nil;
            NSNumber *positionVerified = nil;
            if (primary && primary[@"durationSeconds"] && !wholeClip) {
                double placedDuration = [primary[@"durationSeconds"] doubleValue];
                rangeHonored = @(fabs(placedDuration - sourceDuration) <= tolerance);
            } else if (primary && primary[@"durationSeconds"] && !isnan(clipDuration)) {
                double placedDuration = [primary[@"durationSeconds"] doubleValue];
                rangeHonored = @(fabs(placedDuration - clipDuration) <= tolerance);
            }
            if (primary && primary[@"startSeconds"] && primary[@"endSeconds"]) {
                double placedStart = [primary[@"startSeconds"] doubleValue];
                double placedEnd = [primary[@"endSeconds"] doubleValue];
                if ([edit isEqualToString:@"append"]) {
                    positionVerified = @(fabs(placedStart - storylineEndBefore) <= tolerance);
                    target[@"storylineEndBeforeSeconds"] = @(storylineEndBefore);
                } else if (!isnan(targetSeconds)) {
                    positionVerified = @(backtimed ? fabs(placedEnd - targetSeconds) <= tolerance
                                                   : fabs(placedStart - targetSeconds) <= tolerance);
                }
            }
            target[@"playheadAfterSeconds"] = @(SpliceKit_transitionCurrentTimeSeconds(timelineModule));
            if (!isnan(targetSeconds)) target[@"editSeconds"] = @(targetSeconds);

            BOOL verified = primary != nil && !handleTableReset
                && (rangeHonored == nil || [rangeHonored boolValue])
                && (positionVerified == nil || [positionVerified boolValue]);

            [mergedResult addEntriesFromDictionary:plan];
            mergedResult[@"target"] = target;
            mergedResult[@"status"] = @"ok";
            mergedResult[@"clipName"] = clipName;
            mergedResult[@"action"] = actionName ?: @"browserPlaceClip";
            mergedResult[@"placed"] = primary ? @[primary] : @[];
            mergedResult[@"placedCount"] = @(primary ? 1 : 0);
            mergedResult[@"alsoNew"] = alsoNew;
            mergedResult[@"verified"] = @(verified);
            mergedResult[@"placementVerified"] = @(verified);
            mergedResult[@"handleTableReset"] = @(handleTableReset);
            mergedResult[@"skimmingActive"] = @(skimmingActive);
            if (rangeHonored) mergedResult[@"rangeHonored"] = rangeHonored;
            if (positionVerified) mergedResult[@"positionVerified"] = positionVerified;
            if (!handleTableReset && !primary && newEntries.count == 0) {
                // Nothing appeared: Final Cut Pro placed nothing (it refuses some sources,
                // a project among them). Not an "ok" (QA run 2); the pasteboard was replaced
                // and the playhead may have moved, which the error answer says.
                SpliceKit_log(@"[Place] %@ of \"%@\": the edit ran but no new clip appeared on the timeline", edit, clipName);
                result = failed([NSString stringWithFormat:
                    @"the %@ edit ran but no new clip appeared on the timeline: Final Cut Pro placed nothing "
                    @"(the source \"%@\" may not be something it pastes; get_timeline_clips shows the timeline as it is)",
                    edit, clipName], mergedDebug);
                return;
            }
            NSMutableArray *notes = [NSMutableArray array];
            if (handleTableReset) {
                [notes addObject:@"the handle table was reset during this call (it holds at most 2000 handles): handles from earlier reads are no longer valid and the placement could not be verified; call get_timeline_clips again"];
            } else if (!primary) {
                [notes addObject:@"the edit created objects on the timeline but none is the source clip where it was expected; see alsoNew, check get_timeline_clips and undo if needed"];
            } else if (!verified) {
                [notes addObject:@"a clip was placed but its duration or position does not match the request within two frames (at least 50 ms); compare placed with source/target and undo if needed"];
            }
            if (skimmingActive) {
                [notes addObject:@"the skimmer was active over the timeline; Final Cut Pro makes edits at the skimmer, not the playhead, while skimming"];
            }
            if (alsoNew.count > 0) {
                [notes addObject:[NSString stringWithFormat:@"%lu other new object(s) on the timeline (alsoNew): the far half of a split clip or a gap Final Cut Pro added", (unsigned long)alsoNew.count]];
            }
            if (notes.count > 0) mergedResult[@"note"] = [notes componentsJoinedByString:@" | "];
            result = mergedResult;
        } @catch (NSException *e) {
            result = failed([NSString stringWithFormat:@"Exception: %@", e.reason], nil);
        }
    });
    return result ?: @{@"error": @"Failed to place browser clip (main thread did not finish in time)"};
}

// Append a clip from the event browser to the timeline
NSDictionary *SpliceKit_handleBrowserAppendClip(NSDictionary *params) {
    return SpliceKit_handleBrowserPlaceClip(params,
                                            @"appendWithSelectedMedia:",
                                            @"appendToStoryline");
}

// Insert a clip from the event browser at the current playhead
NSDictionary *SpliceKit_handleBrowserInsertClip(NSDictionary *params) {
    return SpliceKit_handleBrowserPlaceClip(params,
                                            @"insertWithSelectedMedia:",
                                            @"insertAtPlayhead");
}

#pragma mark - Media Import

// Find an event by name across all open libraries. If name is nil or empty,
// picks the first event of the first library. Returns nil if nothing matches.
// Optional library name filters the library too.
static id SpliceKit_resolveMediaImportEvent(NSString *libraryName, NSString *eventName) {
    id libs = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
    if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
        return nil;
    }

    NSString *libLower = libraryName.length ? [libraryName lowercaseString] : nil;
    NSString *evtLower = eventName.length ? [eventName lowercaseString] : nil;

    for (id library in (NSArray *)libs) {
        if (libLower) {
            NSString *name = nil;
            if ([library respondsToSelector:@selector(displayName)]) {
                name = ((id (*)(id, SEL))objc_msgSend)(library, @selector(displayName));
            }
            if (!name || ![[name lowercaseString] containsString:libLower]) continue;
        }

        SEL eventsSel = NSSelectorFromString(@"events");
        if (![library respondsToSelector:eventsSel]) continue;
        id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
        if (![events isKindOfClass:[NSArray class]]) continue;

        for (id eventRecord in (NSArray *)events) {
            if (evtLower) {
                // FFEventRecord answers displayName (the name the browser shows, and the one
                // browser.listClips and this handler's own answer report), not name.
                NSString *ename = nil;
                for (NSString *selName in @[@"displayName", @"name"]) {
                    SEL sel = NSSelectorFromString(selName);
                    if (![eventRecord respondsToSelector:sel]) continue;
                    id v = nil;
                    @try { v = ((id (*)(id, SEL))objc_msgSend)(eventRecord, sel); } @catch (NSException *e) { v = nil; }
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { ename = v; break; }
                }
                if (!ename || ![[ename lowercaseString] containsString:evtLower]) continue;
            }
            if (![eventRecord respondsToSelector:@selector(project)]) continue;
            id project = ((id (*)(id, SEL))objc_msgSend)(eventRecord, @selector(project));
            if (project) return project;
        }

        // If event name wasn't specified, return first event of this library.
        if (!evtLower && [(NSArray *)events count] > 0) {
            id eventRecord = [(NSArray *)events firstObject];
            if ([eventRecord respondsToSelector:@selector(project)]) {
                return ((id (*)(id, SEL))objc_msgSend)(eventRecord, @selector(project));
            }
        }
    }
    return nil;
}

// media.importFile — import one or more local files into an event's browser.
// Uses -[FFMediaEventProject newClipFromURL:manageFileType:] + addOwnedClipsObject:
// which is the same path drag-and-drop funnels into once the user drops.
//
// Params:
//   paths       : [str]  — absolute file paths (required)
//   event?      : str    — case-insensitive substring match for event name
//   library?    : str    — case-insensitive substring match for library display name
//   manageFileType? : int — 0 = leave in place (default), other values per FCP
//                          (e.g. 1 = copy to managed media location).
//
// Returns { status, event, imported:[{path, handle, name}], skipped:[{path, reason}] }.
NSDictionary *SpliceKit_handleMediaImportFile(NSDictionary *params) {
    id pathsAny = params[@"paths"];
    NSString *single = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if ([pathsAny isKindOfClass:[NSArray class]]) {
        for (id p in (NSArray *)pathsAny) {
            if ([p isKindOfClass:[NSString class]] && [(NSString *)p length]) [paths addObject:p];
        }
    }
    if (single) [paths addObject:single];
    if (paths.count == 0) {
        return @{@"error": @"No paths provided. Pass `paths` (array of absolute file paths) or `path` (single)."};
    }

    NSString *libHint = [params[@"library"] isKindOfClass:[NSString class]] ? params[@"library"] : nil;
    NSString *eventHint = [params[@"event"] isKindOfClass:[NSString class]] ? params[@"event"] : nil;
    NSNumber *manageNum = [params[@"manageFileType"] isKindOfClass:[NSNumber class]] ? params[@"manageFileType"] : nil;
    int manageFileType = manageNum ? [manageNum intValue] : 0;

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id project = SpliceKit_resolveMediaImportEvent(libHint, eventHint);
            if (!project) {
                NSString *message;
                if (eventHint.length > 0 || libHint.length > 0) {
                    message = [NSString stringWithFormat:
                        @"No event matching%@%@ in the open libraries (names as the browser shows them; browser_list_clips() lists each clip's event). Leave event out to import into the first event.",
                        eventHint.length > 0 ? [NSString stringWithFormat:@" \"%@\"", eventHint] : @"",
                        libHint.length > 0 ? [NSString stringWithFormat:@" in a library matching \"%@\"", libHint] : @""];
                } else {
                    message = @"No event found. Make sure a library with at least one event is open.";
                }
                result = @{@"error": message};
                return;
            }
            NSString *eventName = nil;
            if ([project respondsToSelector:@selector(displayName)]) {
                eventName = ((id (*)(id, SEL))objc_msgSend)(project, @selector(displayName));
            }

            NSMutableArray *imported = [NSMutableArray array];
            NSMutableArray *skipped = [NSMutableArray array];
            SEL newClipSel = NSSelectorFromString(@"newClipFromURL:manageFileType:");
            SEL addOwnedSel = NSSelectorFromString(@"addOwnedClipsObject:");

            for (NSString *path in paths) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    [skipped addObject:@{@"path": path, @"reason": @"file not found"}];
                    continue;
                }
                NSURL *url = [NSURL fileURLWithPath:path];
                id clip = nil;
                if ([project respondsToSelector:newClipSel]) {
                    clip = ((id (*)(id, SEL, id, int))objc_msgSend)(project, newClipSel, url, manageFileType);
                }
                if (!clip) {
                    [skipped addObject:@{@"path": path, @"reason": @"newClipFromURL returned nil (unsupported format or invalid source?)"}];
                    continue;
                }
                if ([project respondsToSelector:addOwnedSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(project, addOwnedSel, clip);
                }
                NSString *displayName = nil;
                if ([clip respondsToSelector:@selector(displayName)]) {
                    displayName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                }
                NSString *handle = SpliceKit_storeHandle(clip);
                [imported addObject:@{
                    @"path": path,
                    @"handle": handle ?: @"",
                    @"name": displayName ?: @"",
                }];
            }

            result = @{
                @"status": imported.count > 0 ? @"ok" : @"error",
                @"event": eventName ?: @"",
                @"imported": imported,
                @"skipped": skipped,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Import failed on main thread"};
}

// media.removeClip — take a source clip back out of an event's browser.
//
// The counterpart to media.importFile. Without it SpliceKit could put clips into a
// library and never take them out: every import_media / import_url call in a test run
// left a clip behind, and nothing short of Final Cut Pro's own UI could remove it.
// -removeOwnedClipsObject: is the exact inverse of the -addOwnedClipsObject: the import
// uses, so the clip goes the same way it came.
//
// Params:
//   handle?  : str — a handle from browser.listClips or media.importFile
//   name?    : str — exact display name, used when no handle is given
//   event?   : str — case-insensitive substring match, narrows the search
//   library? : str — case-insensitive substring match
//   dryRun?  : bool — report what would be removed, change nothing
//   includeProjects? : bool — allow removing a project (a whole timeline), off by default
//
// Returns { status, removed:[{name, event}], message } or an error naming what it
// searched. Refuses a project: a project is a library item, not an owned clip, and
// cleanup_temp_projects / Final Cut Pro's own delete is the way to remove one.
NSDictionary *SpliceKit_handleMediaRemoveClip(NSDictionary *params) {
    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : nil;
    NSString *libHint = [params[@"library"] isKindOfClass:[NSString class]] ? params[@"library"] : nil;
    NSString *eventHint = [params[@"event"] isKindOfClass:[NSString class]] ? params[@"event"] : nil;
    BOOL dryRun = [params[@"dryRun"] boolValue];
    BOOL includeProjects = [params[@"includeProjects"] boolValue];

    if (handle.length == 0 && name.length == 0) {
        return @{@"error": @"Pass `handle` (from browser_list_clips or import_media) or `name` "
                           @"(the clip's name exactly as the browser shows it)."};
    }

    id wanted = nil;
    if (handle.length > 0) {
        wanted = SpliceKit_resolveHandle(handle);
        if (!wanted) {
            return @{@"error": [NSString stringWithFormat:
                @"Handle '%@' no longer resolves. Handles are dropped when a project is "
                @"reopened; call browser_list_clips() again for a fresh one.", handle]};
        }
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            SEL dnSel = @selector(displayName);
            SEL removeSel = NSSelectorFromString(@"removeOwnedClipsObject:");
            NSMutableArray *removed = [NSMutableArray array];
            NSMutableArray *searched = [NSMutableArray array];
            NSMutableArray *matches = [NSMutableArray array];
            NSMutableArray *failed = [NSMutableArray array];
            NSUInteger projectCount = 0;

            for (id library in (NSArray *)libs) {
                if (libHint.length > 0) {
                    NSString *libName = [library respondsToSelector:dnSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(library, dnSel) : @"";
                    if (![[libName lowercaseString] containsString:[libHint lowercaseString]]) continue;
                }
                SEL eventsSel = NSSelectorFromString(@"events");
                if (![library respondsToSelector:eventsSel]) continue;
                id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
                if (![events isKindOfClass:[NSArray class]]) continue;

                for (id event in (NSArray *)events) {
                    NSString *eventName = [event respondsToSelector:dnSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(event, dnSel) : @"";
                    if (eventHint.length > 0 &&
                        ![[eventName lowercaseString] containsString:[eventHint lowercaseString]]) {
                        continue;
                    }
                    [searched addObject:eventName ?: @"?"];

                    // The clips belong to the event's FFMediaEventProject, which is what
                    // answers -removeOwnedClipsObject: (and what media.importFile adds to).
                    // The FFEventRecord from -events does not, so asking it directly found
                    // nothing and skipped every event.
                    id project = [event respondsToSelector:@selector(project)]
                        ? ((id (*)(id, SEL))objc_msgSend)(event, @selector(project)) : nil;
                    if (!project || ![project respondsToSelector:removeSel]) continue;

                    // Collect first, remove afterwards. Removing inside the walk meant a name
                    // that happened to match in two events took both, silently, and a raise
                    // part way through threw away the record of what had already gone.
                    for (id clip in SpliceKit_browserClipsOfEvent(event)) {
                        NSString *clipName = [clip respondsToSelector:dnSel]
                            ? ((id (*)(id, SEL))objc_msgSend)(clip, dnSel) : nil;
                        BOOL match = wanted ? (clip == wanted)
                                            : (clipName && [clipName isEqualToString:name]);
                        if (!match) continue;

                        BOOL clipIsProject = SpliceKit_browserItemIsProject(clip);
                        if (clipIsProject && !includeProjects) {
                            result = @{@"error": [NSString stringWithFormat:
                                @"'%@' is a project, not a source clip. Removing a project removes a "
                                @"whole timeline, so pass include_projects=True if that is what you mean; "
                                @"cleanup_temp_projects removes SpliceKit's own scratch projects without "
                                @"the flag.", clipName ?: @"?"]};
                            return;
                        }

                        [matches addObject:@[clip, project, clipName ?: @"", eventName ?: @"",
                                             @(clipIsProject)]];
                    }
                }
            }

            // A name is not unique across a library, let alone across every open library. One
            // call used to take every clip that happened to share the name, in every event, and
            // only say "Removed 3 clips". For something that deletes, ambiguity is an error.
            if (!wanted && matches.count > 1) {
                NSMutableArray *where = [NSMutableArray array];
                for (NSArray *m in matches) {
                    [where addObject:[NSString stringWithFormat:@"'%@' in event '%@'%@",
                        m[2], m[3], [m[4] boolValue] ? @" (a project)" : @""]];
                }
                result = @{@"error": [NSString stringWithFormat:
                    @"'%@' matches %lu items: %@. Nothing was removed. Pass event= (and library= "
                    @"if more than one is open) to say which, or pass the handle from "
                    @"browser_list_clips().",
                    name, (unsigned long)matches.count,
                    [where componentsJoinedByString:@"; "]]};
                return;
            }

            for (NSArray *m in matches) {
                id clip = m[0], project = m[1];
                NSString *clipName = m[2], *eventName = m[3];
                BOOL clipIsProject = [m[4] boolValue];
                if (!dryRun) {
                    // Guarded one at a time so a raise on the second item cannot erase the
                    // record that the first one already went.
                    @try {
                        ((void (*)(id, SEL, id))objc_msgSend)(project, removeSel, clip);
                    } @catch (NSException *e) {
                        [failed addObject:@{@"name": clipName,
                                            @"event": eventName,
                                            @"reason": e.reason ?: @"unknown"}];
                        continue;
                    }
                }
                [removed addObject:@{@"name": clipName,
                                     @"event": eventName,
                                     @"kind": clipIsProject ? @"project" : @"clip"}];
                if (clipIsProject) projectCount++;
            }

            if (removed.count == 0 && failed.count > 0) {
                result = @{@"status": @"error",
                           @"removed": removed,
                           @"failed": failed,
                           @"error": @"Every matching item failed to remove; see `failed`."};
                return;
            }

            if (removed.count == 0) {
                result = @{@"error": [NSString stringWithFormat:
                    @"No browser clip matching %@ in %@. browser_list_clips() lists every clip "
                    @"with its event and handle.",
                    wanted ? [NSString stringWithFormat:@"handle '%@'", handle]
                           : [NSString stringWithFormat:@"name '%@'", name],
                    searched.count > 0 ? [searched componentsJoinedByString:@", "]
                                       : @"any event"]};
                return;
            }

            result = @{
                @"status": @"ok",
                @"dryRun": @(dryRun),
                @"removed": removed,
                @"failed": failed,
                // Say which it was: "1 clip" when a project went is the sort of answer that
                // makes someone think their timeline is still there.
                @"message": [NSString stringWithFormat:@"%@ %lu %@ from the browser.%@",
                    dryRun ? @"Would remove" : @"Removed",
                    (unsigned long)removed.count,
                    projectCount == removed.count
                        ? (removed.count == 1 ? @"project" : @"projects")
                        : (projectCount > 0
                            ? @"item(s), projects among them,"
                            : (removed.count == 1 ? @"clip" : @"clips")),
                    dryRun ? @"" : @" The media files on disk are untouched."]
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Remove failed on main thread"};
}

NSDictionary *SpliceKit_handleBrowserConnectClip(NSDictionary *params) {
    return SpliceKit_handleBrowserPlaceClip(params,
                                            @"anchorWithPasteboard:backtimed:trackType:",
                                            @"connectAbovePlayhead");
}

// browser.placeClip: append (E), insert (W) or connect (Q) in one call; see
// SpliceKit_handleBrowserPlaceClip for the range / target / backtimed / dryRun params.
NSDictionary *SpliceKit_handleBrowserPlaceClipEdit(NSDictionary *params) {
    NSString *edit = [params[@"edit"] isKindOfClass:[NSString class]]
        ? [params[@"edit"] lowercaseString] : @"append";
    if ([edit isEqualToString:@"append"]) return SpliceKit_handleBrowserAppendClip(params);
    if ([edit isEqualToString:@"insert"]) return SpliceKit_handleBrowserInsertClip(params);
    if ([edit isEqualToString:@"connect"]) return SpliceKit_handleBrowserConnectClip(params);
    if ([edit isEqualToString:@"overwrite"]) {
        return @{@"error": @"an overwrite edit (Final Cut Pro: Overwrite, D) is not available through this method: Final Cut Pro makes it from the browser's own range selection, which SpliceKit does not set; use insert or connect"};
    }
    return @{@"error": [NSString stringWithFormat:@"unknown edit '%@': use append, insert or connect", edit]};
}
