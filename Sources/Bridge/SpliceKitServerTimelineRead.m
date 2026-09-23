//
//  SpliceKitServerTimelineRead.m
//  SpliceKit - Timeline reads: timeline.getDetailedState (spine items, connected clips,
//  markers, captions, selection) and timeline.getMarkers.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

// When set, getDetailedState adds a "pointerKey" (object identity, independent of the
// handle table) to every item and connected item. Main-thread only; placement uses it
// to diff the timeline before/after an edit without relying on handle strings.
static BOOL sDetailedStateIncludePointerKeys = NO;

#pragma mark - timeline.getDetailedState
//
// Returns everything about the current timeline: sequence name, playhead position,
// duration, frame rate, and all contained items with their types, positions,
// durations, and handles. This is the main way clients understand what's in
// the timeline before performing edits.
//
// FCP's data model: sequence -> primaryObject (FFAnchoredCollection) -> containedItems.
// Each item is an FFAnchoredMediaComponent (clip), FFAnchoredTransition, or gap.
//
// Connected clips (titles, B-roll, music on negative lanes, connected storylines)
// live in each spine item's `anchoredItems`, and markers are FFAnchoredObjects
// anchored to clips as well. The helpers below walk that graph defensively so
// the snapshot also reports `connectedItems` and `markers`.
//

// ---------------------------------------------------------------------------
// Return-type guards. Before calling an unverified private selector that we
// expect to return a struct or BOOL, check the method signature so we never
// invoke it with the wrong return convention (which would corrupt the stack
// on x86_64 or misread registers on arm64).
// ---------------------------------------------------------------------------

static const char *SpliceKit_skipTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static NSString *SpliceKit_returnEncodingForSelector(id obj, SEL sel) {
    if (!obj || !sel) return nil;
    NSMethodSignature *sig = nil;
    @try {
        sig = [obj methodSignatureForSelector:sel];
    } @catch (NSException *e) {
        sig = nil;
    }
    if (!sig) return nil;
    const char *retType = SpliceKit_skipTypeQualifiers([sig methodReturnType]);
    if (!retType || retType[0] == '\0') return nil;
    return [NSString stringWithUTF8String:retType];
}

// CMTime encodes as {?=qiIq}; CMTimeRange as {?={?=qiIq}{?=qiIq}}.
static NSUInteger SpliceKit_countCMTimeFieldsInEncoding(NSString *encoding) {
    if (encoding.length == 0) return 0;
    NSArray *parts = [encoding componentsSeparatedByString:@"qiIq"];
    return parts.count > 0 ? parts.count - 1 : 0;
}

static BOOL SpliceKit_selectorReturnsCMTime(id obj, SEL sel) {
    NSString *encoding = SpliceKit_returnEncodingForSelector(obj, sel);
    if (encoding.length == 0 || ![encoding hasPrefix:@"{"]) return NO;
    return SpliceKit_countCMTimeFieldsInEncoding(encoding) == 1;
}

static BOOL SpliceKit_selectorReturnsCMTimeRange(id obj, SEL sel) {
    NSString *encoding = SpliceKit_returnEncodingForSelector(obj, sel);
    if (encoding.length == 0 || ![encoding hasPrefix:@"{"]) return NO;
    return SpliceKit_countCMTimeFieldsInEncoding(encoding) == 2;
}

BOOL SpliceKit_selectorReturnsBOOL(id obj, SEL sel) {
    NSString *encoding = SpliceKit_returnEncodingForSelector(obj, sel);
    if (encoding.length == 0) return NO;
    unichar c = [encoding characterAtIndex:0];
    return c == 'B' || c == 'c';
}

BOOL SpliceKit_selectorReturnsObject(id obj, SEL sel) {
    NSString *encoding = SpliceKit_returnEncodingForSelector(obj, sel);
    return encoding.length > 0 && [encoding characterAtIndex:0] == '@';
}

// ---------------------------------------------------------------------------
// Guarded probes: respondsToSelector + return-type check + @try.
// ---------------------------------------------------------------------------

BOOL SpliceKit_tryReadBoolSelector(id obj, NSString *name, BOOL *out) {
    if (!obj || name.length == 0 || !out) return NO;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return NO;
    if (!SpliceKit_selectorReturnsBOOL(obj, sel)) return NO;
    @try {
        *out = ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

// Is `item` a compound clip? Final Cut Pro answers itself: -isCompoundClip on
// FFAnchoredCollection (FCP 12.3), called only when its type encoding really returns
// BOOL. The class name is no test -- an ordinary clip that carries both video and
// audio is an FFAnchoredCollection too, with its media components inside it, which
// is what the earlier class-name check got wrong (every camera clip came back as a
// compound clip). When no flag answers, the item is not called compound.
// Which of FCP's container flags `item` answers yes to: "compound clip" for
// isCompoundClip (FFAnchoredCollection answers it: NO for an ordinary clip, verified on
// 12.3), "reference clip" for isReferenceClip (an FFAnchoredClip standing in for an event
// clip: a compound clip -- verified YES on 12.3 -- and, by the same mechanism, a multicam
// or synchronized clip, which is why it is not called a compound clip), nil for neither.
// The class name is asked only when no flag answers, and never "Collection", which is
// what every ordinary audio+video clip is. Either kind has no single source media file.
NSString *SpliceKit_itemContainerKind(id item) {
    if (!item) return nil;
    BOOL flag = NO, answered = NO;
    if (SpliceKit_tryReadBoolSelector(item, @"isCompoundClip", &flag)) { if (flag) return @"compound clip"; answered = YES; }
    if (SpliceKit_tryReadBoolSelector(item, @"isReferenceClip", &flag)) { if (flag) return @"reference clip"; answered = YES; }
    if (answered) return nil;
    NSString *cls = NSStringFromClass([item class]) ?: @"";
    if ([cls containsString:@"Compound"]) return @"compound clip";
    if ([cls containsString:@"Sequence"] || [cls containsString:@"AnchoredClip"]) return @"reference clip";
    return nil;
}

// Same for a multicam clip (FCP: Multicam Clip). Selector names unverified on a
// live build; a name FCP does not answer with a BOOL is skipped, so a wrong guess
// changes nothing.
BOOL SpliceKit_itemIsMulticamClip(id item) {
    if (!item) return NO;
    for (NSString *name in @[@"isMulticamClip", @"isMultiCamClip", @"isMulticam"]) {
        BOOL flag = NO;
        if (SpliceKit_tryReadBoolSelector(item, name, &flag)) return flag;
    }
    return NO;
}

BOOL SpliceKit_tryReadCMTimeSelector(id obj, NSString *name, CMTime *out) {
    if (!obj || name.length == 0 || !out) return NO;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return NO;
    if (!SpliceKit_selectorReturnsCMTime(obj, sel)) return NO;
    @try {
        CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(obj, sel);
        if (t.timescale > 0) {
            *out = t;
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

BOOL SpliceKit_tryReadCMTimeRangeSelector(id obj, NSString *name, CMTimeRange *out) {
    if (!obj || name.length == 0 || !out) return NO;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return NO;
    if (!SpliceKit_selectorReturnsCMTimeRange(obj, sel)) return NO;
    @try {
        CMTimeRange r = ((CMTimeRange (*)(id, SEL))STRET_MSG)(obj, sel);
        if (r.start.timescale > 0 && r.duration.timescale > 0) {
            *out = r;
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

NSString *SpliceKit_tryReadStringSelector(id obj, NSString *name) {
    if (!obj || name.length == 0) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    if (!SpliceKit_selectorReturnsObject(obj, sel)) return nil;
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    } @catch (NSException *e) {}
    return nil;
}

// end = start + duration. When the two timescales differ the sum is formed in the finer
// one when it is a multiple of the other (exact), else in the duration's timescale with
// rounding. The earlier integer division in the start's timescale truncated: a clip at
// time zero (timescale 1) and 18.018 s long reported an end of 18.000 s (QA run 2).
CMTime SpliceKit_endTimeForRange(CMTimeRange range) {
    CMTime start = range.start, duration = range.duration;
    if (duration.timescale <= 0) return start;
    if (start.timescale <= 0) return start;   // an unknown start stays unknown
    if (duration.timescale == start.timescale) {
        start.value += duration.value;
        return start;
    }
    if (duration.timescale % start.timescale == 0) {
        int64_t factor = duration.timescale / start.timescale;
        CMTime end = duration;
        end.value = start.value * factor + duration.value;
        end.flags = start.flags; end.epoch = start.epoch;
        return end;
    }
    if (start.timescale % duration.timescale == 0) {
        int64_t factor = start.timescale / duration.timescale;
        start.value += duration.value * factor;
        return start;
    }
    CMTime end = duration;
    end.value = (int64_t)llround((double)start.value * (double)duration.timescale / (double)start.timescale) + duration.value;
    end.flags = start.flags; end.epoch = start.epoch;
    return end;
}

// ---------------------------------------------------------------------------
// Markers
// ---------------------------------------------------------------------------

BOOL SpliceKit_isMarkerLikeItem(id item) {
    if (!item) return NO;
    NSString *cls = NSStringFromClass([item class]) ?: @"";
    return [cls containsString:@"Marker"];
}

// Marker kind from class name first (FFAnchoredChapterMarker, FFAnchoredKeywordMarker, ...),
// then from BOOL probes on the marker object. Probed selectors (unverified, all guarded):
//   chapter: isChapter, isChapterMarker
//   todo:    isToDo, isTodo, isToDoMarker, isIncomplete, isCompleted (a completed to-do is still a to-do)
static NSString *SpliceKit_markerKindForItem(id marker) {
    if (!marker) return @"standard";
    NSString *cls = NSStringFromClass([marker class]) ?: @"";
    if ([cls containsString:@"Keyword"]) return @"keyword";
    if ([cls containsString:@"Analysis"]) return @"analysis";
    if ([cls containsString:@"Chapter"]) return @"chapter";

    BOOL flag = NO;
    NSArray<NSString *> *chapterSelectors = @[@"isChapter", @"isChapterMarker"];
    for (NSString *name in chapterSelectors) {
        flag = NO;
        if (SpliceKit_tryReadBoolSelector(marker, name, &flag) && flag) return @"chapter";
    }
    NSArray<NSString *> *todoSelectors = @[@"isToDo", @"isTodo", @"isToDoMarker", @"isIncomplete", @"isCompleted"];
    for (NSString *name in todoSelectors) {
        flag = NO;
        if (SpliceKit_tryReadBoolSelector(marker, name, &flag) && flag) return @"todo";
    }
    return @"standard";
}

// Serialises one marker. Time resolution order:
//   1. effectiveRangeOfObject: on the spine (absolute timeline position). Only
//      attempted when the marker is an FFAnchoredObject, the same base class as
//      the clips that method is known to accept.
//   2. CMTimeRange selectors on the marker: timeRange, range, anchoredRange
//   3. CMTime selectors on the marker: anchoredOffset (+ parent start when known),
//      startTime, time, offset (start only)
// `timeSource` records which path produced `time` so a live tester can see what fired.
NSDictionary *SpliceKit_describeMarker(id marker, id primaryObj, NSString *parentHandle,
                                              BOOL haveParentStart, double parentStartSeconds) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (!marker) return info;

    info[@"handle"] = SpliceKit_storeHandle(marker) ?: @"";
    info[@"class"] = NSStringFromClass([marker class]) ?: @"";

    NSString *name = SpliceKit_displayNameForItem(marker);
    if (name.length == 0) {
        name = SpliceKit_tryReadStringSelector(marker, @"name");
    }
    info[@"name"] = name ?: @"";
    info[@"kind"] = SpliceKit_markerKindForItem(marker);

    // Completion (to-do markers). Only emitted when a probe actually succeeded.
    NSArray<NSString *> *completedSelectors = @[@"isCompleted", @"completed", @"isDone"];
    for (NSString *selName in completedSelectors) {
        BOOL completed = NO;
        if (SpliceKit_tryReadBoolSelector(marker, selName, &completed)) {
            info[@"completed"] = @(completed);
            info[@"completedSource"] = selName;
            break;
        }
    }

    // Note text. Only emitted when non-empty.
    NSArray<NSString *> *noteSelectors = @[@"note", @"notes", @"comment"];
    for (NSString *selName in noteSelectors) {
        NSString *note = SpliceKit_tryReadStringSelector(marker, selName);
        if (note.length > 0) {
            info[@"note"] = note;
            break;
        }
    }

    if (parentHandle.length > 0) info[@"parentHandle"] = parentHandle;

    CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
    BOOL haveRange = NO;
    NSString *timeSource = @"unknown";

    Class anchoredObjectClass = objc_getClass("FFAnchoredObject");
    BOOL isAnchoredObject = anchoredObjectClass && [marker isKindOfClass:anchoredObjectClass];
    if (isAnchoredObject && SpliceKit_tryReadTimelineRange(primaryObj, marker, &range)) {
        haveRange = YES;
        timeSource = @"effectiveRange";
    } else {
        NSArray<NSString *> *rangeSelectors = @[@"timeRange", @"range", @"anchoredRange"];
        for (NSString *selName in rangeSelectors) {
            if (SpliceKit_tryReadCMTimeRangeSelector(marker, selName, &range)) {
                haveRange = YES;
                timeSource = [NSString stringWithFormat:@"rangeSelector:%@", selName];
                break;
            }
        }
    }

    if (haveRange) {
        info[@"time"] = SpliceKit_serializeCMTime(range.start);
        info[@"duration"] = SpliceKit_serializeCMTime(range.duration);
        info[@"endTime"] = SpliceKit_serializeCMTime(SpliceKit_endTimeForRange(range));
    } else {
        NSArray<NSString *> *timeSelectors = @[@"anchoredOffset", @"startTime", @"time", @"offset"];
        for (NSString *selName in timeSelectors) {
            CMTime t = {0, 0, 0, 0};
            if (SpliceKit_tryReadCMTimeSelector(marker, selName, &t)) {
                if ([selName isEqualToString:@"anchoredOffset"] && haveParentStart) {
                    // anchoredOffset is relative to the parent clip; make it absolute
                    // the same way the connected-clip fallback does.
                    double absSeconds = parentStartSeconds + SpliceKit_secondsFromTime(t);
                    info[@"time"] = SpliceKit_serializeCMTime(SpliceKit_timeFromSeconds(absSeconds, t.timescale));
                    timeSource = @"anchoredOffset+parentStart";
                } else {
                    info[@"time"] = SpliceKit_serializeCMTime(t);
                    timeSource = [NSString stringWithFormat:@"timeSelector:%@", selName];
                }
                break;
            }
        }
    }
    info[@"timeSource"] = timeSource;
    return info;
}

// ---------------------------------------------------------------------------
// Connected-clip walk
// ---------------------------------------------------------------------------
//
// Enumerates `item`'s anchoredItems (always) and its containedItems (only when
// `item` is a connected storyline or a non-video collection -- compound clips
// are left to include_nested). Marker-like children go to outMarkers; every
// other child is described with the same keys the spine items use plus
// parentHandle / parentIndex / depth / relation / timeSource, then recursed into.
//
//   primaryObj             spine collection; effectiveRangeOfObject: gives absolute ranges
//   container              collection to ask for a *relative* range when the spine fails
//   containerStartSeconds /
//   haveContainerStart     absolute start of `container` (0 / YES for the spine itself)
//   haveParentStart /
//   parentStartSeconds     absolute start of `item`, for the anchoredOffset fallback
//   parentEffectiveLane    `item`'s lane relative to the spine (0 for spine items);
//                          nested anchors report lanes relative to their parent, so
//                          each child's `effectiveLane` = parentEffectiveLane + lane,
//                          and items contained in a connected storyline inherit its lane
//
// `visited` holds "walk:<ptr>" for items already expanded and "<ptr>" for
// children already emitted (items or markers), so the same object is never
// reported twice even if the graph has shared references.

void SpliceKit_collectConnectedItems(id item,
                                            id primaryObj,
                                            id container,
                                            double containerStartSeconds,
                                            BOOL haveContainerStart,
                                            BOOL haveParentStart,
                                            double parentStartSeconds,
                                            NSString *parentHandle,
                                            NSInteger rootIndex,
                                            NSInteger depth,
                                            NSInteger parentEffectiveLane,
                                            NSSet *selectedSet,
                                            BOOL includeRoles,
                                            NSMutableArray *outItems,
                                            NSMutableArray *outMarkers,
                                            NSMutableSet *visited,
                                            NSInteger maxItems,
                                            NSInteger maxDepth) {
    if (!item || !outItems || !outMarkers || !visited) return;
    if (depth > maxDepth) return;
    if ((NSInteger)outItems.count >= maxItems) return;

    NSString *pointerKey = SpliceKit_handlePointerKey(item);
    if (pointerKey.length == 0) return;
    NSString *walkKey = [@"walk:" stringByAppendingString:pointerKey];
    if ([visited containsObject:walkKey]) return;
    [visited addObject:walkKey];

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    NSArray *anchored = nil;
    if ([item respondsToSelector:anchoredSel]) {
        @try {
            anchored = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, anchoredSel));
        } @catch (NSException *e) {
            anchored = nil;
        }
    }

    // Descend into containedItems only for connected storylines / non-video collections.
    BOOL itemIsConnectedStoryline = SpliceKit_boolForSelector(item, @"isConnectedStoryline");
    BOOL itemHasVideo = SpliceKit_boolForSelector(item, @"hasVideo");
    BOOL walkContained = itemIsConnectedStoryline || (!itemHasVideo && SpliceKit_mixerIsCollectionLike(item));
    NSArray *contained = nil;
    SEL containedSel = NSSelectorFromString(@"containedItems");
    if (walkContained && [item respondsToSelector:containedSel]) {
        @try {
            contained = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, containedSel));
        } @catch (NSException *e) {
            contained = nil;
        }
    }

    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");

    for (NSInteger pass = 0; pass < 2; pass++) {
        BOOL isContainedPass = (pass == 1);
        NSArray *children = isContainedPass ? contained : anchored;
        if (children.count == 0) continue;

        // Anchored children resolve relative to the same container as `item`;
        // contained children resolve relative to `item` itself.
        id childContainer = isContainedPass ? item : container;
        double childContainerStart = isContainedPass ? parentStartSeconds : containerStartSeconds;
        BOOL haveChildContainerStart = isContainedPass ? haveParentStart : haveContainerStart;
        BOOL childContainerCanRange = childContainer && (childContainer != primaryObj) &&
                                      haveChildContainerStart &&
                                      [childContainer respondsToSelector:erSel];

        for (id child in children) {
            if ((NSInteger)outItems.count >= maxItems) return;
            if (!child) continue;
            NSString *childKey = SpliceKit_handlePointerKey(child);
            if (childKey.length == 0 || [visited containsObject:childKey]) continue;

            if (SpliceKit_isMarkerLikeItem(child)) {
                [visited addObject:childKey];
                [outMarkers addObject:SpliceKit_describeMarker(child, primaryObj, parentHandle,
                                                               haveParentStart, parentStartSeconds)];
                continue;
            }
            [visited addObject:childKey];

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            NSString *cls = NSStringFromClass([child class]) ?: @"";
            info[@"class"] = cls;
            info[@"name"] = SpliceKit_displayNameForItem(child);

            CMTime childDuration = {0, 0, 0, 0};
            BOOL haveDuration = NO;
            if ([child respondsToSelector:@selector(duration)]) {
                @try {
                    childDuration = ((CMTime (*)(id, SEL))STRET_MSG)(child, @selector(duration));
                    haveDuration = childDuration.timescale > 0;
                    info[@"duration"] = SpliceKit_serializeCMTime(childDuration);
                } @catch (NSException *e) {}
            }

            NSInteger ownLane = SpliceKit_laneForItem(child);
            info[@"lane"] = @(ownLane);
            NSInteger effectiveLane = isContainedPass ? parentEffectiveLane : (parentEffectiveLane + ownLane);
            info[@"effectiveLane"] = @(effectiveLane);

            if ([child respondsToSelector:@selector(mediaType)]) {
                @try {
                    long long mt = ((long long (*)(id, SEL))objc_msgSend)(child, @selector(mediaType));
                    info[@"mediaType"] = @(mt);
                } @catch (NSException *e) {}
            }

            info[@"selected"] = @(selectedSet && [selectedSet containsObject:child]);

            NSString *childHandle = SpliceKit_storeHandle(child);
            info[@"handle"] = childHandle ?: @"";
            if (sDetailedStateIncludePointerKeys) {
                info[@"pointerKey"] = SpliceKit_handlePointerKey(child) ?: @"";
            }

            SEL trimOffSel = NSSelectorFromString(@"trimmedOffset");
            if ([child respondsToSelector:trimOffSel]) {
                @try {
                    CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(child, trimOffSel);
                    info[@"trimmedOffset"] = SpliceKit_serializeCMTime(t);
                } @catch (NSException *e) {}
            }

            if (parentHandle.length > 0) info[@"parentHandle"] = parentHandle;
            info[@"parentIndex"] = @(rootIndex);
            info[@"depth"] = @(depth);
            info[@"relation"] = isContainedPass ? @"contained" : @"anchored";

            BOOL hasVideo = SpliceKit_boolForSelector(child, @"hasVideo");
            BOOL hasAudio = SpliceKit_boolForSelector(child, @"hasAudio");
            BOOL isConnectedStoryline = SpliceKit_boolForSelector(child, @"isConnectedStoryline");
            info[@"hasVideo"] = @(hasVideo);
            info[@"hasAudio"] = @(hasAudio);
            info[@"isConnectedStoryline"] = @(isConnectedStoryline);
            info[@"isGap"] = @([cls containsString:@"Gap"]);
            info[@"isTransition"] = @([cls containsString:@"Transition"]);
            // The same container flags the spine items carry (FCP's isCompoundClip / isReferenceClip).
            NSString *childContainerKind = SpliceKit_itemContainerKind(child);
            if ([childContainerKind isEqualToString:@"compound clip"]) info[@"isCompound"] = @YES;
            if ([childContainerKind isEqualToString:@"reference clip"]) info[@"isReferenceClip"] = @YES;
            if (!childContainerKind && SpliceKit_itemIsMulticamClip(child)) info[@"isMulticamClip"] = @YES;

            BOOL enabledFlag = NO;
            if (SpliceKit_tryReadBoolSelector(child, @"isEnabled", &enabledFlag) ||
                SpliceKit_tryReadBoolSelector(child, @"enabled", &enabledFlag)) {
                info[@"enabled"] = @(enabledFlag);
            }
            if (includeRoles) {
                NSString *role = SpliceKit_readClipRole(child);
                if (role.length > 0) info[@"audioRole"] = role;
            }

            // Absolute timing: spine effectiveRange -> container-relative range -> anchoredOffset.
            CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
            BOOL haveStart = NO;
            double childStartSeconds = 0.0;
            NSString *timeSource = @"unknown";

            if (SpliceKit_tryReadTimelineRange(primaryObj, child, &range)) {
                haveStart = YES;
                childStartSeconds = SpliceKit_secondsFromTime(range.start);
                timeSource = @"effectiveRange";
                info[@"startTime"] = SpliceKit_serializeCMTime(range.start);
                info[@"endTime"] = SpliceKit_serializeCMTime(SpliceKit_endTimeForRange(range));
            } else if (childContainerCanRange && SpliceKit_tryReadTimelineRange(childContainer, child, &range)) {
                haveStart = YES;
                childStartSeconds = childContainerStart + SpliceKit_secondsFromTime(range.start);
                timeSource = @"containerRange+containerStart";
                CMTime absStart = SpliceKit_timeFromSeconds(childStartSeconds, range.start.timescale);
                CMTimeRange absRange = {absStart, range.duration};
                info[@"startTime"] = SpliceKit_serializeCMTime(absStart);
                info[@"endTime"] = SpliceKit_serializeCMTime(SpliceKit_endTimeForRange(absRange));
            } else {
                CMTime offset = {0, 0, 0, 0};
                if (haveParentStart && SpliceKit_tryReadCMTimeSelector(child, @"anchoredOffset", &offset)) {
                    haveStart = YES;
                    childStartSeconds = parentStartSeconds + SpliceKit_secondsFromTime(offset);
                    timeSource = @"anchoredOffset+parentStart";
                    CMTime absStart = SpliceKit_timeFromSeconds(childStartSeconds, offset.timescale);
                    info[@"startTime"] = SpliceKit_serializeCMTime(absStart);
                    if (haveDuration) {
                        CMTimeRange absRange = {absStart, childDuration};
                        info[@"endTime"] = SpliceKit_serializeCMTime(SpliceKit_endTimeForRange(absRange));
                    }
                }
            }
            info[@"timeSource"] = timeSource;

            [outItems addObject:info];

            // Recurse: the child's own anchored items (and contained items when it qualifies).
            SpliceKit_collectConnectedItems(child,
                                            primaryObj,
                                            childContainer,
                                            childContainerStart,
                                            haveChildContainerStart,
                                            haveStart,
                                            childStartSeconds,
                                            childHandle,
                                            rootIndex,
                                            depth + 1,
                                            effectiveLane,
                                            selectedSet,
                                            includeRoles,
                                            outItems,
                                            outMarkers,
                                            visited,
                                            maxItems,
                                            maxDepth);
        }
    }
}

static NSDictionary *SpliceKit_handleTimelineGetDetailedStateBody(NSDictionary *params);

NSDictionary *SpliceKit_handleTimelineGetDetailedState(NSDictionary *params) {
    // Placement verification asks for object identities alongside handles.
    BOOL includePointerKeys = [params[@"include_pointer_keys"] respondsToSelector:@selector(boolValue)]
        && [params[@"include_pointer_keys"] boolValue];
    BOOL previousPointerKeys = sDetailedStateIncludePointerKeys;
    if (includePointerKeys) sDetailedStateIncludePointerKeys = YES;
    NSDictionary *detailedStateResult = SpliceKit_handleTimelineGetDetailedStateBody(params);
    sDetailedStateIncludePointerKeys = previousPointerKeys;
    return detailedStateResult;
}

static NSDictionary *SpliceKit_handleTimelineGetDetailedStateBody(NSDictionary *params) {
    SpliceKit_installEffectDragSwizzlesNow();
    NSInteger limit = [params[@"limit"] integerValue] ?: 200;
    BOOL includeNested = [params[@"include_nested"] boolValue];
    // Connected clips + markers are on by default (backward compatible: the
    // existing `items` array is unchanged, these are additional keys).
    BOOL includeConnected = [params[@"include_connected"] respondsToSelector:@selector(boolValue)]
        ? [params[@"include_connected"] boolValue] : YES;
    BOOL includeMarkers = [params[@"include_markers"] respondsToSelector:@selector(boolValue)]
        ? [params[@"include_markers"] boolValue] : YES;
    BOOL includeRoles = [params[@"include_roles"] respondsToSelector:@selector(boolValue)]
        ? [params[@"include_roles"] boolValue] : NO;
    NSInteger connectedLimit = [params[@"connected_limit"] integerValue] ?: 500;
    NSInteger markerLimit = [params[@"marker_limit"] integerValue] ?: 1000;
    if (connectedLimit < 1) connectedLimit = 500;
    if (markerLimit < 1) markerLimit = 1000;
    const NSInteger connectedMaxDepth = 8;

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module. Is a project open?"};
                return;
            }

            NSMutableDictionary *state = [NSMutableDictionary dictionary];
            id sequence = nil;

            if ([timeline respondsToSelector:@selector(sequence)]) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            }

            if (!sequence) {
                result = @{@"error": @"No sequence in timeline. Open a project first."};
                return;
            }

            // Sequence info
            if ([sequence respondsToSelector:@selector(displayName)]) {
                id name = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(displayName));
                state[@"sequenceName"] = name ?: @"<unnamed>";
            }
            state[@"sequenceClass"] = NSStringFromClass([sequence class]);

            // Playhead
            if ([timeline respondsToSelector:@selector(playheadTime)]) {
                CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
                state[@"playheadTime"] = SpliceKit_serializeCMTime(t);
            }

            // Sequence duration — try sequence.duration first, fall back to summing spine clips
            BOOL durationSet = NO;
            if ([sequence respondsToSelector:@selector(duration)]) {
                CMTime d = ((CMTime (*)(id, SEL))STRET_MSG)(sequence, @selector(duration));
                double secs = SpliceKit_secondsFromTime(d);
                if (secs > 0) {
                    state[@"duration"] = SpliceKit_serializeCMTime(d);
                    durationSet = YES;
                }
            }
            if (!durationSet) {
                // Fallback: sum durations of primary spine items
                id pObj = [sequence respondsToSelector:@selector(primaryObject)]
                    ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
                if (pObj && [pObj respondsToSelector:@selector(containedItems)]) {
                    id cItems = ((id (*)(id, SEL))objc_msgSend)(pObj, @selector(containedItems));
                    if ([cItems isKindOfClass:[NSArray class]]) {
                        int64_t totalValue = 0;
                        int32_t totalTs = 0;
                        for (id ci in (NSArray *)cItems) {
                            if (![ci respondsToSelector:@selector(duration)]) continue;
                            CMTime cd = ((CMTime (*)(id, SEL))STRET_MSG)(ci, @selector(duration));
                            if (cd.timescale > 0) {
                                if (totalTs == 0) totalTs = cd.timescale;
                                if (cd.timescale == totalTs) {
                                    totalValue += cd.value;
                                } else {
                                    totalValue += cd.value * totalTs / cd.timescale;
                                }
                            }
                        }
                        if (totalTs > 0) {
                            CMTime computed = {totalValue, totalTs, 1, 0};
                            state[@"duration"] = SpliceKit_serializeCMTime(computed);
                        }
                    }
                }
            }

            // Selected items (get set for checking)
            NSSet *selectedSet = nil;
            SEL selItemsSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
            if ([timeline respondsToSelector:selItemsSel]) {
                id selItems = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selItemsSel, NO, NO);
                if ([selItems isKindOfClass:[NSArray class]]) {
                    selectedSet = [NSSet setWithArray:selItems];
                    state[@"selectedCount"] = @([(NSArray *)selItems count]);
                }
            }

            // Contained items - FCP uses spine model: sequence -> primaryObject (collection) -> items
            id itemsSource = nil;
            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
                if (primaryObj && [primaryObj respondsToSelector:@selector(containedItems)]) {
                    itemsSource = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
                }
            }
            // Fallback to sequence.containedItems
            if (!itemsSource && [sequence respondsToSelector:@selector(containedItems)]) {
                itemsSource = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(containedItems));
            }

            // Kept for the connected-clip / marker walk below, which covers ALL spine
            // items (not just the first `limit`).
            NSArray *spineArray = nil;

            if (itemsSource) {
                id items = itemsSource;
                if ([items isKindOfClass:[NSArray class]]) {
                    NSArray *arr = (NSArray *)items;
                    spineArray = arr;
                    state[@"itemCount"] = @(arr.count);
                    NSMutableArray *itemList = [NSMutableArray array];
                    NSInteger count = MIN((NSInteger)arr.count, limit);

                    // Check if container supports effectiveRangeOfObject: for absolute positions
                    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
                    BOOL canGetRange = primaryObj && [primaryObj respondsToSelector:erSel];

                    for (NSInteger i = 0; i < count; i++) {
                        id item = arr[i];
                        NSMutableDictionary *info = [NSMutableDictionary dictionary];
                        info[@"index"] = @(i);
                        if (sDetailedStateIncludePointerKeys) {
                            info[@"pointerKey"] = SpliceKit_handlePointerKey(item) ?: @"";
                        }
                        info[@"class"] = NSStringFromClass([item class]);

                        if ([item respondsToSelector:@selector(displayName)]) {
                            id name = ((id (*)(id, SEL))objc_msgSend)(item, @selector(displayName));
                            info[@"name"] = name ?: @"";
                        }
                        if ([item respondsToSelector:@selector(duration)]) {
                            CMTime d = ((CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
                            info[@"duration"] = SpliceKit_serializeCMTime(d);
                        }
                        if ([item respondsToSelector:@selector(anchoredLane)]) {
                            long long lane = ((long long (*)(id, SEL))objc_msgSend)(item, @selector(anchoredLane));
                            info[@"lane"] = @(lane);
                        }
                        if ([item respondsToSelector:@selector(mediaType)]) {
                            long long mt = ((long long (*)(id, SEL))objc_msgSend)(item, @selector(mediaType));
                            info[@"mediaType"] = @(mt);
                        }

                        info[@"selected"] = @(selectedSet && [selectedSet containsObject:item]);

                        // Store handle for the item
                        NSString *h = SpliceKit_storeHandle(item);
                        info[@"handle"] = h;

                        // Media flags / enabled state / optional audio role (additive keys)
                        info[@"hasVideo"] = @(SpliceKit_boolForSelector(item, @"hasVideo"));
                        info[@"hasAudio"] = @(SpliceKit_boolForSelector(item, @"hasAudio"));
                        {
                            BOOL enabledFlag = NO;
                            if (SpliceKit_tryReadBoolSelector(item, @"isEnabled", &enabledFlag) ||
                                SpliceKit_tryReadBoolSelector(item, @"enabled", &enabledFlag)) {
                                info[@"enabled"] = @(enabledFlag);
                            }
                        }
                        if (includeRoles) {
                            NSString *role = SpliceKit_readClipRole(item);
                            if (role.length > 0) info[@"audioRole"] = role;
                        }

                        // Trimmed offset (in-point in source media)
                        SEL trimOffSel = NSSelectorFromString(@"trimmedOffset");
                        if ([item respondsToSelector:trimOffSel]) {
                            CMTime t = ((CMTime (*)(id, SEL))STRET_MSG)(item, trimOffSel);
                            info[@"trimmedOffset"] = SpliceKit_serializeCMTime(t);
                        }

                        // Absolute position in timeline via effectiveRangeOfObject:
                        if (canGetRange) {
                            @try {
                                CMTimeRange range = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(
                                    primaryObj, erSel, item);
                                info[@"startTime"] = SpliceKit_serializeCMTime(range.start);
                                info[@"endTime"] = SpliceKit_serializeCMTime(SpliceKit_endTimeForRange(range));
                            } @catch (NSException *e) {
                                // Silently skip if effectiveRangeOfObject: fails for this item
                            }
                        }

                        // Compound clips: FCP's own -isCompoundClip flag. An ordinary clip
                        // with video and audio is an FFAnchoredCollection too, so the class
                        // name is no test. Nested contents are exposed when the flag says yes.
                        NSString *containerKind = SpliceKit_itemContainerKind(item);
                        BOOL isCompound = (containerKind != nil);
                        if ([containerKind isEqualToString:@"compound clip"]) info[@"isCompound"] = @YES;
                        if ([containerKind isEqualToString:@"reference clip"]) info[@"isReferenceClip"] = @YES;
                        if (!containerKind && SpliceKit_itemIsMulticamClip(item)) info[@"isMulticamClip"] = @YES;
                        if (isCompound && [item respondsToSelector:@selector(primaryObject)]) {
                            id innerPrimary = ((id (*)(id, SEL))objc_msgSend)(item, @selector(primaryObject));
                            if (innerPrimary && [innerPrimary respondsToSelector:@selector(containedItems)]) {
                                id innerItems = ((id (*)(id, SEL))objc_msgSend)(innerPrimary, @selector(containedItems));
                                if ([innerItems isKindOfClass:[NSArray class]]) {
                                    info[@"nestedItemCount"] = @([(NSArray *)innerItems count]);

                                    if (includeNested) {
                                        NSMutableArray *nested = [NSMutableArray array];
                                        SEL innerErSel = NSSelectorFromString(@"effectiveRangeOfObject:");
                                        BOOL canGetInnerRange = [innerPrimary respondsToSelector:innerErSel];
                                        for (id nestedItem in (NSArray *)innerItems) {
                                            NSMutableDictionary *ni = [NSMutableDictionary dictionary];
                                            ni[@"class"] = NSStringFromClass([nestedItem class]);
                                            if ([nestedItem respondsToSelector:@selector(displayName)]) {
                                                id nn = ((id (*)(id, SEL))objc_msgSend)(nestedItem, @selector(displayName));
                                                ni[@"name"] = nn ?: @"";
                                            }
                                            if ([nestedItem respondsToSelector:@selector(duration)]) {
                                                CMTime nd = ((CMTime (*)(id, SEL))STRET_MSG)(nestedItem, @selector(duration));
                                                ni[@"duration"] = SpliceKit_serializeCMTime(nd);
                                            }
                                            ni[@"handle"] = SpliceKit_storeHandle(nestedItem);
                                            if (canGetInnerRange) {
                                                @try {
                                                    CMTimeRange nr = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(
                                                        innerPrimary, innerErSel, nestedItem);
                                                    ni[@"startTime"] = SpliceKit_serializeCMTime(nr.start);
                                                } @catch (NSException *e) {}
                                            }
                                            [nested addObject:ni];
                                        }
                                        info[@"nestedItems"] = nested;
                                    }
                                }
                            }
                        }

                        [itemList addObject:info];
                    }
                    state[@"items"] = itemList;
                }
            }

            // Frame rate from sequence
            SEL frdSel = NSSelectorFromString(@"frameDuration");
            if ([sequence respondsToSelector:frdSel]) {
                CMTime fd = ((CMTime (*)(id, SEL))STRET_MSG)(sequence, frdSel);
                state[@"frameDuration"] = SpliceKit_serializeCMTime(fd);
                if (fd.value > 0) {
                    state[@"frameRate"] = @((double)fd.timescale / fd.value);
                }
            }

            // ------------------------------------------------------------------
            // Spine bounds (absolute seconds) — used for the marker query window
            // and as the parent start for the connected-clip walk.
            // ------------------------------------------------------------------
            double firstSpineStart = 0.0;
            double lastSpineEnd = 0.0;
            BOOL haveSpineBounds = NO;
            if (spineArray && primaryObj) {
                for (id spineItem in spineArray) {
                    CMTimeRange sr = {{0, 0, 0, 0}, {0, 0, 0, 0}};
                    if (!SpliceKit_tryReadTimelineRange(primaryObj, spineItem, &sr)) continue;
                    double s = SpliceKit_secondsFromTime(sr.start);
                    double e = s + SpliceKit_secondsFromTime(sr.duration);
                    if (!isfinite(s) || !isfinite(e)) continue;
                    if (!haveSpineBounds) {
                        firstSpineStart = s;
                        lastSpineEnd = e;
                        haveSpineBounds = YES;
                    } else {
                        if (s < firstSpineStart) firstSpineStart = s;
                        if (e > lastSpineEnd) lastSpineEnd = e;
                    }
                }
            }

            // Markers discovered while walking anchoredItems (also feeds the marker list).
            NSMutableArray *walkMarkers = [NSMutableArray array];
            NSMutableSet *walkVisited = [NSMutableSet set];

            // ------------------------------------------------------------------
            // Connected clips: titles, B-roll, music on negative lanes, connected
            // storylines. Walks anchoredItems of EVERY spine item.
            // ------------------------------------------------------------------
            if (includeConnected) {
                state[@"connectedItems"] = @[];
                state[@"connectedCount"] = @0;
                @try {
                    NSMutableArray *connectedItems = [NSMutableArray array];
                    if (spineArray && primaryObj) {
                        NSInteger spineIndex = 0;
                        for (id spineItem in spineArray) {
                            if ((NSInteger)connectedItems.count >= connectedLimit) break;
                            CMTimeRange sr = {{0, 0, 0, 0}, {0, 0, 0, 0}};
                            BOOL haveSpineStart = SpliceKit_tryReadTimelineRange(primaryObj, spineItem, &sr);
                            double spineStart = haveSpineStart ? SpliceKit_secondsFromTime(sr.start) : 0.0;
                            NSString *spineHandle = SpliceKit_storeHandle(spineItem);
                            SpliceKit_collectConnectedItems(spineItem,
                                                            primaryObj,
                                                            primaryObj,
                                                            0.0,
                                                            YES,
                                                            haveSpineStart,
                                                            spineStart,
                                                            spineHandle,
                                                            spineIndex,
                                                            0,
                                                            0,
                                                            selectedSet,
                                                            includeRoles,
                                                            connectedItems,
                                                            walkMarkers,
                                                            walkVisited,
                                                            connectedLimit,
                                                            connectedMaxDepth);
                            spineIndex++;
                        }
                    }
                    state[@"connectedItems"] = connectedItems;
                    state[@"connectedCount"] = @(connectedItems.count);
                    if ((NSInteger)connectedItems.count >= connectedLimit) {
                        state[@"connectedTruncated"] = @YES;
                    }
                } @catch (NSException *e) {
                    state[@"connectedItemsError"] = e.reason ?: @"unknown exception";
                }
            }

            // ------------------------------------------------------------------
            // Markers: sequence markersInTimeRange: over a wide window, merged with
            // the markers found on anchoredItems during the connected walk.
            // ------------------------------------------------------------------
            if (includeMarkers) {
                state[@"markers"] = @[];
                state[@"markerCount"] = @0;
                @try {
                    NSMutableArray *markerList = [NSMutableArray array];
                    NSMutableSet *markerHandles = [NSMutableSet set];
                    NSUInteger fromWalk = walkMarkers.count;
                    NSUInteger fromQuery = 0;

                    for (NSDictionary *wm in walkMarkers) {
                        NSString *h = wm[@"handle"];
                        if ([h isKindOfClass:[NSString class]] && h.length > 0) [markerHandles addObject:h];
                        [markerList addObject:wm];
                    }

                    SEL markersSel = NSSelectorFromString(@"markersInTimeRange:");
                    BOOL sequenceHasMarkersQuery = [sequence respondsToSelector:markersSel];
                    if (sequenceHasMarkersQuery) {
                        double seqDurationSeconds = 0.0;
                        id durationInfo = state[@"duration"];
                        if ([durationInfo isKindOfClass:[NSDictionary class]]) {
                            seqDurationSeconds = [((NSDictionary *)durationInfo)[@"seconds"] doubleValue];
                        }
                        double boundsStart = haveSpineBounds ? firstSpineStart : 0.0;
                        double boundsEnd = haveSpineBounds ? lastSpineEnd : seqDurationSeconds;
                        // Start at 0 (or earlier if the spine somehow starts before 0) and
                        // pad the end generously; a negative start is never needed and is
                        // not something FCP's marker query has been seen to accept.
                        double queryStart = MIN(0.0, boundsStart);
                        double queryDuration = (boundsEnd - queryStart) + 7200.0;
                        if (!isfinite(queryStart) || !isfinite(queryDuration) || queryDuration <= 0.0) {
                            queryStart = 0.0;
                            queryDuration = 86400.0;
                        }
                        int32_t queryTs = 600;
                        id fdInfo = state[@"frameDuration"];
                        if ([fdInfo isKindOfClass:[NSDictionary class]]) {
                            int32_t fdTs = (int32_t)[((NSDictionary *)fdInfo)[@"timescale"] intValue];
                            if (fdTs > 0) queryTs = fdTs;
                        }
                        CMTimeRange queryRange = {
                            SpliceKit_timeFromSeconds(queryStart, queryTs),
                            SpliceKit_timeFromSeconds(queryDuration, queryTs)
                        };
                        id found = ((id (*)(id, SEL, CMTimeRange))objc_msgSend)(sequence, markersSel, queryRange);
                        NSArray *foundArray = SpliceKit_mixerArrayFromContainer(found);
                        fromQuery = foundArray.count;
                        for (id m in foundArray) {
                            if (!m) continue;
                            NSString *pk = SpliceKit_handlePointerKey(m);
                            if (pk.length > 0 && [walkVisited containsObject:pk]) continue;  // already described by the walk
                            NSDictionary *desc = SpliceKit_describeMarker(m, primaryObj, nil, NO, 0.0);
                            NSString *h = desc[@"handle"];
                            if ([h isKindOfClass:[NSString class]] && h.length > 0) {
                                if ([markerHandles containsObject:h]) continue;
                                [markerHandles addObject:h];
                            }
                            [markerList addObject:desc];
                        }
                    }

                    // Sort by time ascending; entries without a resolved time go last.
                    [markerList sortUsingComparator:^NSComparisonResult(id a, id b) {
                        id ta = [a isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)a)[@"time"] : nil;
                        id tb = [b isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)b)[@"time"] : nil;
                        NSNumber *sa = [ta isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)ta)[@"seconds"] : nil;
                        NSNumber *sb = [tb isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)tb)[@"seconds"] : nil;
                        if (sa && sb) return [sa compare:sb];
                        if (sa) return NSOrderedAscending;
                        if (sb) return NSOrderedDescending;
                        return NSOrderedSame;
                    }];

                    NSUInteger markerTotal = markerList.count;
                    if ((NSInteger)markerList.count > markerLimit) {
                        markerList = [[markerList subarrayWithRange:NSMakeRange(0, (NSUInteger)markerLimit)] mutableCopy];
                        state[@"markersTruncated"] = @YES;
                    }
                    state[@"markers"] = markerList;
                    state[@"markerCount"] = @(markerList.count);
                    state[@"markerTotal"] = @(markerTotal);
                    state[@"markerSources"] = @{
                        @"markersInTimeRange": @(fromQuery),
                        @"anchoredWalk": @(fromWalk),
                        @"sequenceRespondsToMarkersInTimeRange": @(sequenceHasMarkersQuery),
                        @"connectedWalkRan": @(includeConnected),
                    };
                } @catch (NSException *e) {
                    state[@"markersError"] = e.reason ?: @"unknown exception";
                }
            }

            result = state;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

#pragma mark - timeline.getMarkers
//
// Marker-only view of timeline.getDetailedState. Forces the connected walk on
// (markers anchored to connected clips are only reachable that way), asks for
// a single spine item to keep the response small, and returns just the marker
// fields. Optional `kind` filters by marker kind (standard/todo/chapter/keyword/analysis).
//

NSDictionary *SpliceKit_handleTimelineGetMarkers(NSDictionary *params) {
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:params ?: @{}];
    merged[@"include_connected"] = @YES;
    merged[@"include_markers"] = @YES;
    merged[@"limit"] = @1;

    NSDictionary *state = SpliceKit_handleTimelineGetDetailedState(merged);
    if (![state isKindOfClass:[NSDictionary class]]) {
        return @{@"error": @"timeline.getDetailedState returned no result"};
    }
    if (state[@"error"]) {
        return @{@"error": state[@"error"]};
    }

    NSString *kindFilter = [params[@"kind"] isKindOfClass:[NSString class]] ? params[@"kind"] : nil;
    NSArray *markers = [state[@"markers"] isKindOfClass:[NSArray class]] ? state[@"markers"] : @[];
    if (kindFilter.length > 0) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (id m in markers) {
            if (![m isKindOfClass:[NSDictionary class]]) continue;
            id kind = ((NSDictionary *)m)[@"kind"];
            if ([kind isKindOfClass:[NSString class]] &&
                [(NSString *)kind caseInsensitiveCompare:kindFilter] == NSOrderedSame) {
                [filtered addObject:m];
            }
        }
        markers = filtered;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSArray<NSString *> *passthroughKeys = @[@"sequenceName", @"playheadTime", @"duration", @"frameRate",
                                             @"markerSources", @"markerTotal", @"markersTruncated", @"markersError"];
    for (NSString *key in passthroughKeys) {
        if (state[key]) out[key] = state[key];
    }
    out[@"markers"] = markers;
    out[@"markerCount"] = @(markers.count);
    if (kindFilter.length > 0) out[@"kind"] = kindFilter;
    return out;
}
