//
//  SpliceKitServerBatchEdits.m
//  SpliceKit - Batch timeline edits: markers at many times, blades at many times, beat
//  timing metadata read off a song clip, and trimming clips to beats; plus the item
//  helpers (lane, display name, timeline range) they share with the rest of the server.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Range Selection & Batch Export

// Helper: build a CMTime from seconds using the sequence timescale
CMTime SpliceKit_buildCMTime(double seconds, id timeline) {
    int32_t timescale = 24000; // default
    SEL seqSel = @selector(sequence);
    if ([timeline respondsToSelector:seqSel]) {
        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        if (sequence) {
            CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
            if (fd.timescale > 0) timescale = fd.timescale;
        }
    }
    CMTime t;
    t.value = (int64_t)(seconds * timescale);
    t.timescale = timescale;
    t.flags = 1; // kCMTimeFlags_Valid
    t.epoch = 0;
    return t;
}

// Helper: seek playhead and mark in/out via direct responder chain (no key simulation)
BOOL SpliceKit_seekAndMark(id timeline, CMTime time, NSString *actionSelector) {
    // Seek playhead
    SEL setSel = @selector(setPlayheadTime:);
    if (![timeline respondsToSelector:setSel]) return NO;
    ((void (*)(id, SEL, CMTime))objc_msgSend)(timeline, setSel, time);

    // Let FCP update playhead position
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

    // Prefer the active timeline module (same path as timeline_action); responder-chain
    // sendAction often returns NO when Final Cut Pro is not the frontmost app.
    SEL actionSel = NSSelectorFromString(actionSelector);
    BOOL sent = NO;
    if ([timeline respondsToSelector:actionSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(timeline, actionSel, nil);
        sent = YES;
    } else {
        id app = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("NSApplication"), @selector(sharedApplication));
        sent = ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
            app, @selector(sendAction:to:from:), actionSel, nil, nil);
    }

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return sent;
}

// Batch add markers at specific times using direct ObjC calls (no playhead movement needed)
NSDictionary *SpliceKit_handleBatchAddMarkers(NSDictionary *params) {
    NSArray *markers = params[@"markers"];
    if (!markers || ![markers isKindOfClass:[NSArray class]] || markers.count == 0) {
        return @{@"error": @"markers array required (each: {time, name, kind})"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) { result = @{@"error": @"No sequence in timeline"}; return; }

            // Get frame duration for marker length
            CMTime frameDur = {100, 2400, 1, 0}; // default 24fps
            CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
            if (fd.timescale > 0) frameDur = fd;

            // Build a list of clips with their timeline start/end times so we can
            // target the correct clip for each marker (not just the longest one).
            // Each item's placement is read from the sequence (-effectiveRangeOfObject:, the
            // times get_timeline_clips and seek_to_time use). Summing durations from 0 put
            // every marker one start-timecode late on a timeline that does not start at
            // 00:00:00:00 (43 s landed at 73.03 s on a timeline starting at 00:00:30:00).
            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
            if (!primaryObj) { result = @{@"error": @"Cannot access primary storyline"}; return; }

            id containedItems = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
            NSMutableArray *clipInfos = [NSMutableArray array];

            if ([containedItems isKindOfClass:[NSArray class]]) {
                double cumulativeStart = 0;
                CMTimeRange spineRange = {{0, 0, 0, 0}, {0, 0, 0, 0}};
                if (SpliceKit_tryReadCMTimeRangeSelector(primaryObj, @"clippedRange", &spineRange) &&
                    spineRange.start.timescale > 0) {
                    cumulativeStart = SpliceKit_secondsFromTime(spineRange.start);
                }
                for (id item in (NSArray *)containedItems) {
                    if (![item respondsToSelector:@selector(duration)]) continue;
                    CMTime d = ((CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
                    double dur = SpliceKit_secondsFromTime(d);
                    double start = cumulativeStart;
                    CMTimeRange placed = {{0, 0, 0, 0}, {0, 0, 0, 0}};
                    if (SpliceKit_tryReadTimelineRange(primaryObj, item, &placed)) {
                        start = SpliceKit_secondsFromTime(placed.start);
                        dur = SpliceKit_secondsFromTime(placed.duration);
                    }

                    [clipInfos addObject:@{@"clip": item, @"start": @(start), @"end": @(start + dur)}];
                    cumulativeStart = start + dur;
                }
            }
            if (clipInfos.count == 0) { result = @{@"error": @"No clips found in timeline"}; return; }

            SEL addSel = NSSelectorFromString(@"actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:");
            if (![sequence respondsToSelector:addSel]) {
                result = @{@"error": @"Sequence does not support actionAddMarkerToAnchoredObject:"};
                return;
            }

            // For renaming markers after creation
            SEL renameSel = NSSelectorFromString(@"actionChangeMarkerDisplayName:marker:error:");
            BOOL canRename = [sequence respondsToSelector:renameSel];

            typedef BOOL (*AddMarkerFn)(id, SEL, id, BOOL, BOOL, CMTimeRange, NSError **);
            AddMarkerFn addMarker = (AddMarkerFn)objc_msgSend;

            int32_t ts = frameDur.timescale > 0 ? frameDur.timescale : 600;
            NSUInteger applied = 0;
            NSMutableArray *results = [NSMutableArray array];
            NSString *undoGroupName = @"Add Markers";
            BOOL openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoGroupName);

            @try {
            for (NSDictionary *m in markers) {
                double t = [m[@"time"] doubleValue];
                NSString *name = m[@"name"];
                NSString *kind = m[@"kind"] ?: @"standard";
                BOOL isToDo = [kind isEqualToString:@"todo"];
                BOOL isChapter = [kind isEqualToString:@"chapter"];

                // Find the clip that contains this time (content-relative start/end).
                // ci[@"start"] is the item's timeline start (sequence time, not source timecode).
                id targetClip = nil;
                double clipTimelineStart = 0;
                double clipTimelineEnd = 0;
                for (NSDictionary *ci in clipInfos) {
                    double cStart = [ci[@"start"] doubleValue];
                    double cEnd = [ci[@"end"] doubleValue];
                    if (t >= cStart - 0.01 && t < cEnd + 0.01) {
                        targetClip = ci[@"clip"];
                        clipTimelineStart = cStart;
                        clipTimelineEnd = cEnd;
                        break;
                    }
                }
                // Fallback: use the last clip if marker time is past all clips
                if (!targetClip) {
                    NSDictionary *last = [clipInfos lastObject];
                    targetClip = last[@"clip"];
                    clipTimelineStart = [last[@"start"] doubleValue];
                    clipTimelineEnd = [last[@"end"] doubleValue];
                }

                double clipDuration = clipTimelineEnd - clipTimelineStart;
                double localTime = t - clipTimelineStart;
                if (localTime < -0.01 || localTime > clipDuration + 0.01) {
                    [results addObject:@{@"time": @(t), @"success": @NO,
                        @"error": [NSString stringWithFormat:
                            @"Marker time %.3fs is outside clip timeline range %.3f-%.3fs",
                            t, clipTimelineStart, clipTimelineEnd]}];
                    continue;
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
                CMTime markerTime = {(int64_t)llround(rangeStartSeconds * ts), ts, 1, 0};
                CMTimeRange range = {markerTime, frameDur};
                NSError *err = nil;
                BOOL ok = addMarker(sequence, addSel, targetClip, isToDo, isChapter, range, &err);
                if (ok) {
                    applied++;

                    // Rename the marker if a name was provided
                    if (name.length > 0 && canRename) {
                        // Find the marker we just added on this clip by looking for a marker
                        // at the exact time we placed it
                        SEL markersSel = NSSelectorFromString(@"markersInTimeRange:");
                        if ([sequence respondsToSelector:markersSel]) {
                            CMTime searchEnd = markerTime;
                            searchEnd.value += frameDur.value;
                            CMTimeRange searchRange = {markerTime, frameDur};
                            id foundMarkers = ((id (*)(id, SEL, CMTimeRange))objc_msgSend)(
                                sequence, markersSel, searchRange);
                            if ([foundMarkers respondsToSelector:@selector(lastObject)]) {
                                id marker = ((id (*)(id, SEL))objc_msgSend)(foundMarkers, @selector(lastObject));
                                if (marker) {
                                    NSError *renameErr = nil;
                                    ((void (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                                        sequence, renameSel, name, marker, &renameErr);
                                }
                            }
                        }
                    }

                    NSMutableDictionary *one = [@{@"time": @(t), @"success": @YES} mutableCopy];
                    if (!sourceStartKnown) {
                        one[@"warning"] =
                            @"clip sourceStart unknown; used 0 for marker range (may be misplaced)";
                    }
                    [results addObject:one];
                } else {
                    [results addObject:@{@"time": @(t), @"success": @NO,
                        @"error": err ? [err localizedDescription] : @"unknown"}];
                }
            }
            } @finally {
                if (openedUndoGroup) {
                    SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoGroupName, YES);
                }
            }

            NSMutableDictionary *out = [@{
                @"status": @"ok",
                @"count": @(markers.count),
                @"applied": @(applied),
                @"markers": results,
            } mutableCopy];
            if (openedUndoGroup) {
                out[@"undoStep"] = undoGroupName;
            } else if (sOpenEditGroupName) {
                out[@"undoStep"] = sOpenEditGroupName;
            }
            result = out;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to add markers"};
}

// Batch blade at specific times using seek + blade (no manual playhead stepping needed)
NSDictionary *SpliceKit_handleBladeAtTimes(NSDictionary *params) {
    NSArray *times = params[@"times"];
    if (!times || ![times isKindOfClass:[NSArray class]] || times.count == 0) {
        return @{@"error": @"times array required (list of seconds, e.g. [3.0, 6.0, 9.0])"};
    }

    // Sort times ascending so we blade left-to-right (avoids offset issues)
    NSArray *sortedTimes = [times sortedArrayUsingSelector:@selector(compare:)];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            NSUInteger applied = 0;
            NSMutableArray *results = [NSMutableArray array];
            NSString *undoGroupName = @"Blade at Times";
            BOOL openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoGroupName);

            @try {
            for (NSNumber *timeNum in sortedTimes) {
                double t = [timeNum doubleValue];
                SpliceKit_handlePlaybackSeek(@{@"seconds": @(t)});
                [NSThread sleepForTimeInterval:0.03];
                NSDictionary *bladeResult = SpliceKit_handleTimelineAction(@{@"action": @"blade"});

                BOOL ok = bladeResult && !bladeResult[@"error"];
                if (ok) {
                    applied++;
                    [results addObject:@{@"time": @(t), @"success": @YES}];
                } else {
                    [results addObject:@{@"time": @(t), @"success": @NO,
                        @"error": bladeResult[@"error"] ?: @"blade failed"}];
                }
            }
            } @finally {
                if (openedUndoGroup) {
                    SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoGroupName, YES);
                }
            }

            NSMutableDictionary *out = [@{
                @"status": @"ok",
                @"count": @(sortedTimes.count),
                @"applied": @(applied),
                @"cuts": results,
            } mutableCopy];
            if (openedUndoGroup) {
                out[@"undoStep"] = undoGroupName;
            } else if (sOpenEditGroupName) {
                out[@"undoStep"] = sOpenEditGroupName;
            }
            result = out;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to blade at times"};
}

BOOL SpliceKit_tryReadTimelineRange(id primaryObj, id item, CMTimeRange *outRange) {
    if (!primaryObj || !item || !outRange) return NO;
    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (![primaryObj respondsToSelector:erSel]) return NO;
    @try {
        *outRange = ((CMTimeRange (*)(id, SEL, id))STRET_MSG)(primaryObj, erSel, item);
        return outRange->start.timescale > 0 && outRange->duration.timescale > 0;
    } @catch (NSException *e) {}
    return NO;
}

static BOOL SpliceKit_tryReadLocalAudioRange(id item, CMTimeRange *outRange) {
    if (!item || !outRange) return NO;

    SEL audioSel = NSSelectorFromString(@"audioClippedRange");
    if ([item respondsToSelector:audioSel]) {
        @try {
            CMTimeRange range = ((CMTimeRange (*)(id, SEL))STRET_MSG)(item, audioSel);
            if (range.start.timescale > 0 && range.duration.timescale > 0) {
                *outRange = range;
                return YES;
            }
        } @catch (NSException *e) {}
    }

    SEL clipSel = NSSelectorFromString(@"clippedRange");
    if ([item respondsToSelector:clipSel]) {
        @try {
            CMTimeRange range = ((CMTimeRange (*)(id, SEL))STRET_MSG)(item, clipSel);
            if (range.start.timescale > 0 && range.duration.timescale > 0) {
                *outRange = range;
                return YES;
            }
        } @catch (NSException *e) {}
    }

    return NO;
}

NSArray<NSNumber *> *SpliceKit_sortedUniqueSeconds(NSArray<NSNumber *> *values, double epsilon) {
    if (!values || values.count == 0) return @[];

    NSArray<NSNumber *> *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSNumber *> *unique = [NSMutableArray arrayWithCapacity:sorted.count];
    double last = 0.0;
    BOOL hasLast = NO;
    for (NSNumber *num in sorted) {
        double value = [num doubleValue];
        if (!isfinite(value)) continue;
        if (!hasLast || fabs(value - last) > epsilon) {
            [unique addObject:@(value)];
            last = value;
            hasLast = YES;
        }
    }
    return unique;
}

static NSArray<NSNumber *> *SpliceKit_copyTimingMetadataSecondsForType(id clip, NSInteger type) {
    if (!clip || ![clip respondsToSelector:@selector(newTimingMetadata)]) return @[];

    id timing = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(newTimingMetadata));
    if (!timing) return @[];

    SEL typeSel = NSSelectorFromString(@"newTimingMetadataForType:");
    if (![timing respondsToSelector:typeSel]) return @[];

    id entriesValue = ((id (*)(id, SEL, NSInteger))objc_msgSend)(timing, typeSel, type);
    NSArray *entries = SpliceKit_mixerArrayFromContainer(entriesValue);
    if (!entries || entries.count == 0) return @[];

    SEL timeSel = NSSelectorFromString(@"time");
    NSMutableArray<NSNumber *> *times = [NSMutableArray arrayWithCapacity:entries.count];
    for (id entry in entries) {
        if (![entry respondsToSelector:timeSel]) continue;
        @try {
            CMTime time = ((CMTime (*)(id, SEL))STRET_MSG)(entry, timeSel);
            double seconds = SpliceKit_secondsFromTime(time);
            if (isfinite(seconds)) [times addObject:@(seconds)];
        } @catch (NSException *e) {}
    }

    return SpliceKit_sortedUniqueSeconds(times, 0.0001);
}

static double SpliceKit_copyTimingMetadataTempo(id clip) {
    if (!clip || ![clip respondsToSelector:@selector(newTimingMetadata)]) return 0.0;

    id timing = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(newTimingMetadata));
    if (!timing) return 0.0;

    SEL typeSel = NSSelectorFromString(@"newTimingMetadataForType:");
    if (![timing respondsToSelector:typeSel]) return 0.0;

    id entriesValue = ((id (*)(id, SEL, NSInteger))objc_msgSend)(timing, typeSel, 8);
    NSArray *entries = SpliceKit_mixerArrayFromContainer(entriesValue);
    if (!entries || entries.count == 0) return 0.0;

    id first = entries.firstObject;
    if (!first) return 0.0;

    SEL dataSel = NSSelectorFromString(@"data");
    if (![first respondsToSelector:dataSel]) return 0.0;

    id data = ((id (*)(id, SEL))objc_msgSend)(first, dataSel);
    SEL valueSel = NSSelectorFromString(@"value");
    if (!data || ![data respondsToSelector:valueSel]) return 0.0;

    @try {
        return ((float (*)(id, SEL))objc_msgSend)(data, valueSel);
    } @catch (NSException *e) {}
    return 0.0;
}

NSArray<NSNumber *> *SpliceKit_translateTimingMetadataToTimeline(id clip,
                                                                        id primaryObj,
                                                                        NSString *gridMode,
                                                                        double *outStartSec,
                                                                        double *outEndSec,
                                                                        double *outTempo) {
    if (!clip || !primaryObj) return @[];

    CMTimeRange timelineRange;
    if (!SpliceKit_tryReadTimelineRange(primaryObj, clip, &timelineRange)) return @[];

    CMTimeRange localRange;
    if (!SpliceKit_tryReadLocalAudioRange(clip, &localRange)) return @[];

    double timelineStartSec = SpliceKit_secondsFromTime(timelineRange.start);
    double timelineDurationSec = SpliceKit_secondsFromTime(timelineRange.duration);
    double timelineEndSec = timelineStartSec + timelineDurationSec;
    double localStartSec = SpliceKit_secondsFromTime(localRange.start);
    double localDurationSec = SpliceKit_secondsFromTime(localRange.duration);
    double localEndSec = localStartSec + localDurationSec;

    if (outStartSec) *outStartSec = timelineStartSec;
    if (outEndSec) *outEndSec = timelineEndSec;
    if (outTempo) *outTempo = SpliceKit_copyTimingMetadataTempo(clip);

    NSArray<NSNumber *> *beats = SpliceKit_copyTimingMetadataSecondsForType(clip, 1);
    NSArray<NSNumber *> *bars = SpliceKit_copyTimingMetadataSecondsForType(clip, 2);
    NSArray<NSNumber *> *sections = SpliceKit_copyTimingMetadataSecondsForType(clip, 4);

    NSMutableArray<NSNumber *> *timelinePoints = [NSMutableArray array];
    NSString *mode = (gridMode ?: @"beat").lowercaseString;
    BOOL useBars = [mode isEqualToString:@"bar"];
    BOOL useSections = [mode isEqualToString:@"section"];
    BOOL useHalfBeats = [mode isEqualToString:@"half"] || [mode isEqualToString:@"half_beat"];
    BOOL useQuarterBeats = [mode isEqualToString:@"quarter"] || [mode isEqualToString:@"quarter_beat"];

    NSArray<NSNumber *> *base = beats;
    if (useBars) base = bars;
    if (useSections) base = sections;

    for (NSNumber *num in base) {
        double localSec = [num doubleValue];
        if (localSec + 0.0001 < localStartSec || localSec - 0.0001 > localEndSec) continue;
        double timelineSec = timelineStartSec + (localSec - localStartSec);
        if (timelineSec + 0.0001 < timelineStartSec || timelineSec - 0.0001 > timelineEndSec) continue;
        [timelinePoints addObject:@(timelineSec)];
    }

    if (useQuarterBeats && beats.count > 1) {
        for (NSUInteger i = 0; i + 1 < beats.count; i++) {
            double left = [beats[i] doubleValue];
            double right = [beats[i + 1] doubleValue];
            if (right <= left) continue;
            double delta = right - left;
            double quarter = left + (delta * 0.25);
            double midpoint = left + (delta * 0.5);
            double threeQuarter = left + (delta * 0.75);
            for (NSNumber *subdivision in @[@(quarter), @(midpoint), @(threeQuarter)]) {
                double localSec = [subdivision doubleValue];
                if (localSec + 0.0001 < localStartSec || localSec - 0.0001 > localEndSec) continue;
                double timelineSec = timelineStartSec + (localSec - localStartSec);
                if (timelineSec + 0.0001 < timelineStartSec || timelineSec - 0.0001 > timelineEndSec) continue;
                [timelinePoints addObject:@(timelineSec)];
            }
        }
    } else if (useHalfBeats && beats.count > 1) {
        for (NSUInteger i = 0; i + 1 < beats.count; i++) {
            double left = [beats[i] doubleValue];
            double right = [beats[i + 1] doubleValue];
            if (right <= left) continue;
            double midpoint = left + ((right - left) * 0.5);
            if (midpoint + 0.0001 < localStartSec || midpoint - 0.0001 > localEndSec) continue;
            double timelineSec = timelineStartSec + (midpoint - localStartSec);
            if (timelineSec + 0.0001 < timelineStartSec || timelineSec - 0.0001 > timelineEndSec) continue;
            [timelinePoints addObject:@(timelineSec)];
        }
    }

    return SpliceKit_sortedUniqueSeconds(timelinePoints, 0.0001);
}

BOOL SpliceKit_boolForSelector(id item, NSString *selectorName) {
    if (!item || selectorName.length == 0) return NO;
    SEL sel = NSSelectorFromString(selectorName);
    if (![item respondsToSelector:sel]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(item, sel);
    } @catch (NSException *e) {}
    return NO;
}

NSInteger SpliceKit_laneForItem(id item) {
    if (!item) return 0;
    SEL laneSel = NSSelectorFromString(@"anchoredLane");
    if (![item respondsToSelector:laneSel]) return 0;
    @try {
        return (NSInteger)((long long (*)(id, SEL))objc_msgSend)(item, laneSel);
    } @catch (NSException *e) {}
    return 0;
}

NSString *SpliceKit_displayNameForItem(id item) {
    if (!item || ![item respondsToSelector:@selector(displayName)]) return @"";
    @try {
        id name = ((id (*)(id, SEL))objc_msgSend)(item, @selector(displayName));
        return name ?: @"";
    } @catch (NSException *e) {}
    return @"";
}

void SpliceKit_collectVisibleTimelineEntries(id item,
                                                    id primaryObj,
                                                    NSMutableArray<NSDictionary *> *out,
                                                    NSMutableSet<NSString *> *visited) {
    if (!item || !out || !visited) return;

    NSString *pointerKey = SpliceKit_handlePointerKey(item);
    if (pointerKey.length == 0 || [visited containsObject:pointerKey]) return;
    [visited addObject:pointerKey];
    BOOL skipSelf = SpliceKit_mixerIsSkippableItem(item);
    BOOL hasVideo = NO;
    BOOL isConnectedStoryline = NO;

    if (!skipSelf) {
        CMTimeRange range;
        if (SpliceKit_tryReadTimelineRange(primaryObj, item, &range)) {
            double startSec = SpliceKit_secondsFromTime(range.start);
            double durationSec = SpliceKit_secondsFromTime(range.duration);
            double endSec = startSec + durationSec;
            if (isfinite(startSec) && isfinite(endSec) && endSec > startSec + 0.0001) {
                hasVideo = SpliceKit_boolForSelector(item, @"hasVideo");
                BOOL hasAudio = SpliceKit_boolForSelector(item, @"hasAudio");
                BOOL isAudioOnly = SpliceKit_boolForSelector(item, @"isAudioOnly");
                isConnectedStoryline = SpliceKit_boolForSelector(item, @"isConnectedStoryline");
                BOOL hasTimingMetadata = SpliceKit_boolForSelector(item, @"hasTimingMetadata");
                BOOL beatGridEnabled = SpliceKit_boolForSelector(item, @"beatGridEnabled");

                [out addObject:@{
                    @"item": item,
                    @"pointerKey": pointerKey,
                    @"name": SpliceKit_displayNameForItem(item),
                    @"start": @(startSec),
                    @"end": @(endSec),
                    @"lane": @(SpliceKit_laneForItem(item)),
                    @"hasVideo": @(hasVideo),
                    @"hasAudio": @(hasAudio),
                    @"isAudioOnly": @(isAudioOnly),
                    @"isConnectedStoryline": @(isConnectedStoryline),
                    @"hasTimingMetadata": @(hasTimingMetadata),
                    @"beatGridEnabled": @(beatGridEnabled),
                }];
            }
        }
    }

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    NSArray *anchored = [item respondsToSelector:anchoredSel]
        ? SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, anchoredSel))
        : nil;

    SEL containedSel = NSSelectorFromString(@"containedItems");
    NSArray *contained = [item respondsToSelector:containedSel]
        ? SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, containedSel))
        : nil;

    BOOL recurseContained = isConnectedStoryline || (!hasVideo && SpliceKit_mixerIsCollectionLike(item));
    if (recurseContained) {
        for (id child in contained) {
            SpliceKit_collectVisibleTimelineEntries(child, primaryObj, out, visited);
        }
    }
    for (id child in anchored) {
        SpliceKit_collectVisibleTimelineEntries(child, primaryObj, out, visited);
    }
}

uint64_t SpliceKit_nextRandom(uint64_t *state) {
    *state = (*state * 6364136223846793005ULL) + 1442695040888963407ULL;
    return *state;
}

NSInteger SpliceKit_chooseRandomAssemblyStep(NSInteger segmentMinStep,
                                                    NSInteger segmentMaxStep,
                                                    NSDictionary<NSNumber *, NSNumber *> *stepWeights,
                                                    uint64_t *rngState) {
    if (segmentMinStep < 1) segmentMinStep = 1;
    if (segmentMaxStep < segmentMinStep) segmentMaxStep = segmentMinStep;

    NSInteger totalWeight = 0;
    if (stepWeights.count > 0) {
        for (NSInteger step = segmentMinStep; step <= segmentMaxStep; step++) {
            NSInteger weight = [stepWeights[@(step)] integerValue];
            if (weight > 0) totalWeight += weight;
        }
    }

    if (totalWeight > 0) {
        NSInteger pick = (NSInteger)(SpliceKit_nextRandom(rngState) % (uint64_t)totalWeight);
        NSInteger cumulative = 0;
        for (NSInteger step = segmentMinStep; step <= segmentMaxStep; step++) {
            NSInteger weight = [stepWeights[@(step)] integerValue];
            if (weight <= 0) continue;
            cumulative += weight;
            if (pick < cumulative) return step;
        }
    }

    if (segmentMaxStep <= segmentMinStep) return segmentMinStep;
    NSInteger span = segmentMaxStep - segmentMinStep + 1;
    return segmentMinStep + (NSInteger)(SpliceKit_nextRandom(rngState) % (uint64_t)span);
}

static NSDictionary *SpliceKit_buildVisibleEntryContextForSequence(id sequence) {
    if (!sequence) {
        return @{@"error": @"Missing sequence"};
    }

    id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
    if (!primaryObj) {
        return @{@"error": @"Sequence has no primary storyline"};
    }

    NSArray *rootItems = SpliceKit_mixerArrayFromContainer(
        ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems))) ?: @[];
    NSMutableArray<NSDictionary *> *visibleEntries = [NSMutableArray array];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (id item in rootItems) {
        SpliceKit_collectVisibleTimelineEntries(item, primaryObj, visibleEntries, visited);
    }

    return @{
        @"sequence": sequence,
        @"primaryObject": primaryObj,
        @"visibleEntries": visibleEntries,
        @"sequenceName": SpliceKit_displayNameForItem(sequence) ?: @"",
    };
}

NSDictionary *SpliceKit_findVisibleEntryContextNamed(NSString *projectName) {
    if (projectName.length == 0) {
        return @{@"error": @"Missing project name"};
    }

    id sequence = SpliceKit_findSequenceNamedInActiveLibraries(projectName);
    if (!sequence) {
        return @{@"error": [NSString stringWithFormat:@"Couldn't find sequence named \"%@\"", projectName]};
    }

    return SpliceKit_buildVisibleEntryContextForSequence(sequence);
}

NSDictionary *SpliceKit_handleTrimClipsToBeats(NSDictionary *params) {
    NSString *sourceHandle = [params[@"sourceHandle"] isKindOfClass:[NSString class]] ? params[@"sourceHandle"] : nil;
    NSArray *targetHandles = [params[@"targetHandles"] isKindOfClass:[NSArray class]] ? params[@"targetHandles"] : nil;
    NSString *grid = [params[@"grid"] isKindOfClass:[NSString class]] ? [params[@"grid"] lowercaseString] : @"beat";
    NSString *targetMode = [params[@"targetMode"] isKindOfClass:[NSString class]]
        ? [params[@"targetMode"] lowercaseString] : @"auto";
    BOOL randomize = [params[@"randomize"] boolValue];
    BOOL dryRun = [params[@"dryRun"] boolValue];
    NSInteger randomMinStep = params[@"randomMinStep"] ? [params[@"randomMinStep"] integerValue] : 1;
    NSInteger randomMaxStep = params[@"randomMaxStep"] ? [params[@"randomMaxStep"] integerValue] : 4;
    long long randomSeed = params[@"randomSeed"] ? [params[@"randomSeed"] longLongValue] : 1337;
    double minTrimSeconds = params[@"minTrimSeconds"] ? [params[@"minTrimSeconds"] doubleValue] : -1.0;
    double minResultDuration = params[@"minResultDuration"] ? [params[@"minResultDuration"] doubleValue] : -1.0;
    __block double effectiveMinTrimSeconds = minTrimSeconds;
    __block double effectiveMinResultDuration = minResultDuration;

    if ([grid isEqualToString:@"random"]) {
        grid = @"beat";
        randomize = YES;
    } else if ([grid isEqualToString:@"random_half"] || [grid isEqualToString:@"random_half_beat"]) {
        grid = @"half_beat";
        randomize = YES;
    } else if ([grid isEqualToString:@"random_quarter"] || [grid isEqualToString:@"random_quarter_beat"]) {
        grid = @"quarter_beat";
        randomize = YES;
    }

    NSSet *allowed = [NSSet setWithArray:@[@"beat", @"half", @"half_beat", @"quarter", @"quarter_beat", @"bar", @"section"]];
    if (![allowed containsObject:grid]) {
        return @{@"error": @"grid must be one of: beat, half_beat, quarter_beat, bar, section, random, random_half_beat, random_quarter_beat"};
    }
    if (![@[@"auto", @"selected", @"overlay", @"all"] containsObject:targetMode]) {
        return @{@"error": @"targetMode must be one of: auto, selected, overlay, all"};
    }

    if (randomMinStep < 1) randomMinStep = 1;
    if (randomMaxStep < randomMinStep) randomMaxStep = randomMinStep;

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

            CMTime frameDuration = {100, 3000, 1, 0};
            CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
            if (fd.timescale > 0 && fd.value > 0) frameDuration = fd;
            double frameSeconds = MAX(0.001, SpliceKit_secondsFromTime(frameDuration));
            if (effectiveMinTrimSeconds < 0.0) effectiveMinTrimSeconds = frameSeconds;
            if (effectiveMinResultDuration < 0.0) effectiveMinResultDuration = frameSeconds * 2.0;

            NSArray *rootItems = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems)));
            if (!rootItems || rootItems.count == 0) {
                result = @{@"error": @"No clips found in timeline"};
                return;
            }

            NSMutableArray<NSDictionary *> *visibleEntries = [NSMutableArray array];
            NSMutableSet<NSString *> *visited = [NSMutableSet set];
            for (id item in rootItems) {
                SpliceKit_collectVisibleTimelineEntries(item, primaryObj, visibleEntries, visited);
            }
            if (visibleEntries.count == 0) {
                result = @{@"error": @"No visible timeline items found"};
                return;
            }

            NSArray *selectedItems = nil;
            NSMutableSet<NSString *> *selectedKeys = [NSMutableSet set];
            SEL selectedSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
            if ([timeline respondsToSelector:selectedSel]) {
                id selItems = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selectedSel, NO, NO);
                selectedItems = SpliceKit_mixerArrayFromContainer(selItems);
            } else if ([timeline respondsToSelector:@selector(selectedItems)]) {
                selectedItems = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(timeline, @selector(selectedItems)));
            }
            for (id selectedItem in selectedItems) {
                NSString *pointerKey = SpliceKit_handlePointerKey(selectedItem);
                if (pointerKey.length > 0) [selectedKeys addObject:pointerKey];
            }

            NSDictionary *sourceEntry = nil;
            NSString *sourceKey = nil;
            if (sourceHandle.length > 0) {
                id sourceObj = SpliceKit_resolveHandle(sourceHandle);
                if (!sourceObj) {
                    result = @{@"error": [NSString stringWithFormat:@"Source handle not found: %@", sourceHandle]};
                    return;
                }
                sourceKey = SpliceKit_handlePointerKey(sourceObj);
                for (NSDictionary *entry in visibleEntries) {
                    if ([entry[@"pointerKey"] isEqualToString:sourceKey]) {
                        sourceEntry = entry;
                        break;
                    }
                }
                if (!sourceEntry) {
                    result = @{@"error": @"Source clip is not visible in the active timeline"};
                    return;
                }
            } else {
                NSArray *orderedEntries = [visibleEntries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
                    return [lhs[@"start"] compare:rhs[@"start"]];
                }];
                for (NSDictionary *entry in orderedEntries) {
                    if (![selectedKeys containsObject:entry[@"pointerKey"]]) continue;
                    if (![entry[@"hasTimingMetadata"] boolValue] || ![entry[@"hasAudio"] boolValue]) continue;
                    sourceEntry = entry;
                    break;
                }
                if (!sourceEntry) {
                    for (NSDictionary *entry in orderedEntries) {
                        if (![entry[@"hasTimingMetadata"] boolValue] || ![entry[@"hasAudio"] boolValue]) continue;
                        if (![entry[@"beatGridEnabled"] boolValue]) continue;
                        sourceEntry = entry;
                        break;
                    }
                }
                if (!sourceEntry) {
                    for (NSDictionary *entry in orderedEntries) {
                        if ([entry[@"hasTimingMetadata"] boolValue] && [entry[@"hasAudio"] boolValue]) {
                            sourceEntry = entry;
                            break;
                        }
                    }
                }
                if (!sourceEntry) {
                    result = @{@"error": @"No audio clip on this timeline carries a Final Cut Pro "
                                         @"beat map. These tools read Final Cut Pro's own timing "
                                         @"metadata, which comes with songs from its music library; "
                                         @"detect_beats cannot add it. Pass sourceHandle to name a "
                                         @"clip, or use detect_beats with beat_sync_blade to cut to "
                                         @"beats on ordinary audio."};
                    return;
                }
                sourceKey = sourceEntry[@"pointerKey"];
            }

            id sourceItem = sourceEntry[@"item"];
            if (!SpliceKit_boolForSelector(sourceItem, @"hasTimingMetadata")) {
                // -hasTimingMetadata is Final Cut Pro's own flag for audio it holds a
                // beat map for, which in practice means a song from its built-in music
                // library. SpliceKit only ever reads it; detect_beats analyses a file
                // with an external binary and cannot set it. The old wording here said
                // "Run beat detection on it first", which sends the caller down a path
                // that can never make this check pass.
                result = @{@"error": @"This clip has no Final Cut Pro beat map. Only audio "
                                     @"from Final Cut Pro's own music library carries one, "
                                     @"and nothing in SpliceKit can add it — detect_beats "
                                     @"analyses the file separately and does not set it. "
                                     @"To cut to beats on ordinary audio, use detect_beats "
                                     @"with beat_sync_blade or blade_at_times instead."};
                return;
            }

            double sourceStartSec = 0.0;
            double sourceEndSec = 0.0;
            double tempo = 0.0;
            NSArray<NSNumber *> *rawTimelineGrid = SpliceKit_translateTimingMetadataToTimeline(
                sourceItem, primaryObj, grid, &sourceStartSec, &sourceEndSec, &tempo);
            if (rawTimelineGrid.count == 0) {
                result = @{@"error": @"Source clip has no usable timing metadata for the requested grid"};
                return;
            }

            NSMutableArray<NSNumber *> *quantizedTimelineGrid = [NSMutableArray arrayWithCapacity:rawTimelineGrid.count];
            for (NSNumber *markerNum in rawTimelineGrid) {
                double markerSec = SpliceKit_quantizeSecondsToFrameGrid([markerNum doubleValue], frameSeconds);
                if (markerSec > 0.0) [quantizedTimelineGrid addObject:@(markerSec)];
            }
            NSArray<NSNumber *> *timelineGrid = SpliceKit_sortedUniqueSeconds(
                quantizedTimelineGrid, frameSeconds * 0.25);
            if (timelineGrid.count == 0) {
                result = @{@"error": @"Source clip has no frame-quantized timing metadata for the requested grid"};
                return;
            }

            NSMutableSet<NSString *> *requestedTargetKeys = [NSMutableSet set];
            for (id handleValue in targetHandles) {
                if (![handleValue isKindOfClass:[NSString class]]) continue;
                id targetObj = SpliceKit_resolveHandle(handleValue);
                NSString *pointerKey = SpliceKit_handlePointerKey(targetObj);
                if (pointerKey.length > 0) [requestedTargetKeys addObject:pointerKey];
            }

            BOOL haveSelectedVideoTargets = NO;
            BOOL haveOverlayTargets = NO;
            NSInteger sourceLane = [sourceEntry[@"lane"] integerValue];
            BOOL sourceIsAudioOnly = [sourceEntry[@"hasAudio"] boolValue] && ![sourceEntry[@"hasVideo"] boolValue];
            for (NSDictionary *entry in visibleEntries) {
                if ([entry[@"pointerKey"] isEqualToString:sourceKey]) continue;
                if (![entry[@"hasVideo"] boolValue]) continue;
                if ([entry[@"isConnectedStoryline"] boolValue]) continue;
                if ([selectedKeys containsObject:entry[@"pointerKey"]]) haveSelectedVideoTargets = YES;
                if ([entry[@"lane"] integerValue] != sourceLane) haveOverlayTargets = YES;
            }

            NSMutableArray<NSDictionary *> *targetEntries = [NSMutableArray array];
            for (NSDictionary *entry in visibleEntries) {
                NSString *pointerKey = entry[@"pointerKey"];
                if ([pointerKey isEqualToString:sourceKey]) continue;
                if (![entry[@"hasVideo"] boolValue]) continue;
                if ([entry[@"isConnectedStoryline"] boolValue]) continue;

                if (requestedTargetKeys.count > 0) {
                    if (![requestedTargetKeys containsObject:pointerKey]) continue;
                } else if ([targetMode isEqualToString:@"selected"]) {
                    if (![selectedKeys containsObject:pointerKey]) continue;
                } else if ([targetMode isEqualToString:@"overlay"]) {
                    if ([entry[@"lane"] integerValue] == sourceLane) continue;
                } else if ([targetMode isEqualToString:@"auto"]) {
                    if (haveSelectedVideoTargets) {
                        if (![selectedKeys containsObject:pointerKey]) continue;
                    } else if (sourceIsAudioOnly && haveOverlayTargets) {
                        if ([entry[@"lane"] integerValue] == sourceLane) continue;
                    }
                }

                [targetEntries addObject:entry];
            }

            if (targetEntries.count == 0) {
                result = @{@"error": @"No target video clips found to trim"};
                return;
            }

            [targetEntries sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
                NSComparisonResult startCmp = [lhs[@"start"] compare:rhs[@"start"]];
                if (startCmp != NSOrderedSame) return startCmp;
                return [lhs[@"lane"] compare:rhs[@"lane"]];
            }];

            NSMutableArray<NSDictionary *> *plan = [NSMutableArray array];
            uint64_t rngState = (uint64_t)randomSeed;
            NSUInteger planned = 0;

            for (NSDictionary *entry in targetEntries) {
                double clipStart = [entry[@"start"] doubleValue];
                double clipEnd = [entry[@"end"] doubleValue];
                double currentDuration = clipEnd - clipStart;
                NSString *name = entry[@"name"] ?: @"";
                NSString *handle = SpliceKit_storeHandle(entry[@"item"]);

                BOOL alreadyAligned = NO;
                for (NSNumber *markerNum in timelineGrid) {
                    double markerSec = [markerNum doubleValue];
                    if (fabs(markerSec - clipEnd) <= (frameSeconds * 0.25)) {
                        alreadyAligned = YES;
                        break;
                    }
                }
                if (alreadyAligned) {
                    [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                        @"handle": handle,
                        @"name": name,
                        @"start": @(clipStart),
                        @"end": @(clipEnd),
                        @"status": @"skipped",
                        @"reason": @"Clip already ends on a beat boundary",
                    }]];
                    continue;
                }

                NSMutableArray<NSNumber *> *futureMarkers = [NSMutableArray array];
                for (NSNumber *markerNum in timelineGrid) {
                    double markerSec = [markerNum doubleValue];
                    if (markerSec > clipStart + 0.0001 && markerSec < clipEnd - effectiveMinTrimSeconds + 0.0001) {
                        NSNumber *last = [futureMarkers lastObject];
                        if (!last || fabs([last doubleValue] - markerSec) > (frameSeconds * 0.25)) {
                            [futureMarkers addObject:@(markerSec)];
                        }
                    }
                }

                if (futureMarkers.count == 0) {
                    [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                        @"handle": handle,
                        @"name": name,
                        @"start": @(clipStart),
                        @"end": @(clipEnd),
                        @"status": @"skipped",
                        @"reason": @"No beat boundary falls inside the current clip range",
                    }]];
                    continue;
                }

                double targetSec = 0.0;
                if (randomize) {
                    NSInteger lastIndex = (NSInteger)futureMarkers.count - 1;
                    NSInteger minDistanceFromEnd = MAX(1, randomMinStep);
                    NSInteger maxDistanceFromEnd = MAX(minDistanceFromEnd, randomMaxStep);
                    NSInteger minIndex = MAX(0, lastIndex - maxDistanceFromEnd + 1);
                    NSInteger maxIndex = MAX(0, lastIndex - minDistanceFromEnd + 1);
                    if (maxIndex < minIndex) maxIndex = minIndex;
                    NSMutableArray<NSNumber *> *eligible = [NSMutableArray array];
                    for (NSInteger idx = minIndex; idx <= maxIndex; idx++) {
                        double candidate = [futureMarkers[idx] doubleValue];
                        double newDuration = candidate - clipStart;
                        double trimAmount = clipEnd - candidate;
                        if (newDuration >= effectiveMinResultDuration && trimAmount >= effectiveMinTrimSeconds) {
                            [eligible addObject:@(candidate)];
                        }
                    }
                    if (eligible.count == 0) {
                        [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                            @"handle": handle,
                            @"name": name,
                            @"start": @(clipStart),
                            @"end": @(clipEnd),
                            @"status": @"skipped",
                            @"reason": @"No random beat candidate satisfied the duration constraints",
                        }]];
                        continue;
                    }
                    uint64_t next = SpliceKit_nextRandom(&rngState);
                    targetSec = [eligible[(NSUInteger)(next % eligible.count)] doubleValue];
                } else {
                    BOOL found = NO;
                    for (NSInteger idx = (NSInteger)futureMarkers.count - 1; idx >= 0; idx--) {
                        NSNumber *candidateNum = futureMarkers[(NSUInteger)idx];
                        double candidate = [candidateNum doubleValue];
                        double newDuration = candidate - clipStart;
                        double trimAmount = clipEnd - candidate;
                        if (newDuration >= effectiveMinResultDuration && trimAmount >= effectiveMinTrimSeconds) {
                            targetSec = candidate;
                            found = YES;
                            break;
                        }
                    }
                    if (!found) {
                        [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                            @"handle": handle,
                            @"name": name,
                            @"start": @(clipStart),
                            @"end": @(clipEnd),
                            @"status": @"skipped",
                            @"reason": @"The available beat boundaries would create a clip that is too short",
                        }]];
                        continue;
                    }
                }

                double trimAmount = clipEnd - targetSec;
                [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                    @"handle": handle,
                    @"name": name,
                    @"start": @(clipStart),
                    @"end": @(clipEnd),
                    @"targetEnd": @(targetSec),
                    @"oldDuration": @(currentDuration),
                    @"newDuration": @(targetSec - clipStart),
                    @"trimAmount": @(trimAmount),
                    @"status": @"planned",
                    @"item": entry[@"item"],
                }]];
                planned++;
            }

            NSUInteger applied = 0;
            SEL trimSel = NSSelectorFromString(
                @"operationTrimEdit:endEdits:edgeType:byDelta:trimCommand:trimFlags:temporalResolutionMode:animationHint:error:");
            if (!dryRun && planned > 0 && [sequence respondsToSelector:trimSel]) {
                NSString *undoGroupName = @"Trim to Beats";
                BOOL openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoGroupName);
                @try {
                NSMethodSignature *sig = [sequence methodSignatureForSelector:trimSel];
                for (NSMutableDictionary *entry in plan) {
                    if (![entry[@"status"] isEqualToString:@"planned"]) continue;

                    id item = entry[@"item"];
                    NSArray *clipArray = @[item];
                    id nilValue = nil;
                    int edgeType = 0;
                    int trimCommand = 1;
                    int trimFlags = 2;
                    int temporalRes = 0;
                    id animHint = nil;
                    void *errorPtr = NULL;
                    double trimAmount = [entry[@"trimAmount"] doubleValue];
                    CMTime delta = SpliceKit_buildCMTime(-trimAmount, timeline);

                    BOOL ok = NO;
                    @try {
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setTarget:sequence];
                        [inv setSelector:trimSel];
                        [inv setArgument:&nilValue atIndex:2];
                        [inv setArgument:&clipArray atIndex:3];
                        [inv setArgument:&edgeType atIndex:4];
                        [inv setArgument:&delta atIndex:5];
                        [inv setArgument:&trimCommand atIndex:6];
                        [inv setArgument:&trimFlags atIndex:7];
                        [inv setArgument:&temporalRes atIndex:8];
                        [inv setArgument:&animHint atIndex:9];
                        [inv setArgument:&errorPtr atIndex:10];
                        [inv invoke];
                        [inv getReturnValue:&ok];
                    } @catch (NSException *e) {
                        entry[@"status"] = @"failed";
                        entry[@"reason"] = e.reason ?: @"trim invocation failed";
                    }

                    if (ok) {
                        entry[@"status"] = @"applied";
                        applied++;
                    } else if (!entry[@"reason"]) {
                        entry[@"status"] = @"failed";
                        entry[@"reason"] = @"operationTrimEdit returned NO";
                    }
                    [entry removeObjectForKey:@"item"];
                }
                } @finally {
                    if (openedUndoGroup) {
                        SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoGroupName, YES);
                    }
                }
            } else {
                for (NSMutableDictionary *entry in plan) {
                    [entry removeObjectForKey:@"item"];
                }
            }

            NSMutableArray *gridPreview = [NSMutableArray array];
            NSUInteger previewCount = MIN((NSUInteger)12, timelineGrid.count);
            for (NSUInteger i = 0; i < previewCount; i++) {
                [gridPreview addObject:timelineGrid[i]];
            }

            result = @{
                @"status": @"ok",
                @"dryRun": @(dryRun),
                @"grid": grid,
                @"targetMode": targetMode,
                @"randomize": @(randomize),
                @"randomSeed": @(randomSeed),
                @"source": @{
                    @"handle": SpliceKit_storeHandle(sourceItem),
                    @"name": sourceEntry[@"name"] ?: @"",
                    @"start": @(sourceStartSec),
                    @"end": @(sourceEndSec),
                    @"tempo": @(tempo),
                    @"beatGridEnabled": sourceEntry[@"beatGridEnabled"] ?: @NO,
                },
                @"gridPointCount": @(timelineGrid.count),
                @"gridPreview": gridPreview,
                @"targetCount": @(targetEntries.count),
                @"planned": @(planned),
                @"applied": @(applied),
                @"plan": plan,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to trim clips to beats"};
}
