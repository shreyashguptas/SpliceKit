//
//  SpliceKitServerBeatGrid.m
//  SpliceKit - timeline.getBeatGrid: Final Cut Pro's own beat map (the result of
//  Modify > Detect Beats, the data behind its beat grid) for the songs on the timeline,
//  as beats, bars, sections and tempo in timeline seconds.
//
//  What Final Cut Pro stores: when -[FFAnchoredTimelineModule detectBeatsOnSelection:]
//  analyses an audio-only clip, Flexo writes setBeatTimeValues:barTimeValues:
//  sectionTimeValues:tempo: onto the clip model (docs/internals/beat-detection.md). Those
//  come back through -newTimingMetadata / -newTimingMetadataForType: as times in the
//  clip's own source time: type 1 beats, 2 bars, 4 sections, 8 tempo. There is no
//  per-beat strength; the hierarchy is the strength: a section start is also a bar start
//  (a downbeat), and a bar start is also a beat.
//
//  This handler only reads. It walks the same visible-entry list the beat-sync tools use
//  (spine clips, connected clips, connected storylines), maps each song's beat map onto the
//  timeline through the clip's visible range, numbers every beat by its bar and section
//  counted from the start of the song (so the numbers do not change when the song is
//  trimmed or moved), and lists the audio clips Final Cut Pro could analyse but has not.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

static const double kBeatGridEpsilon = 0.0001;

static double SpliceKit_beatGridRound(double seconds) {
    return round(seconds * 1000000.0) / 1000000.0;
}

// Index of the last value in `sorted` that is <= t + tolerance, or -1 when t comes first.
static NSInteger SpliceKit_beatGridIndexAtOrBefore(NSArray<NSNumber *> *sorted, double t, double tolerance) {
    NSInteger lo = 0, hi = (NSInteger)sorted.count - 1, found = -1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        if ([sorted[(NSUInteger)mid] doubleValue] <= t + tolerance) {
            found = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return found;
}

static BOOL SpliceKit_beatGridMatches(NSArray<NSNumber *> *sorted, NSInteger index, double t, double tolerance) {
    if (index < 0 || index >= (NSInteger)sorted.count) return NO;
    return fabs([sorted[(NSUInteger)index] doubleValue] - t) <= tolerance;
}

static double SpliceKit_beatGridMedian(NSArray<NSNumber *> *values) {
    if (values.count == 0) return 0.0;
    NSArray<NSNumber *> *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger n = sorted.count;
    if (n % 2) return [sorted[n / 2] doubleValue];
    return ([sorted[n / 2 - 1] doubleValue] + [sorted[n / 2] doubleValue]) / 2.0;
}

// Why Final Cut Pro will not analyse this clip, in its own predicates' terms
// (-[FFAnchoredObject canDetectBeats] and _supportsBeatGrid).
static NSString *SpliceKit_beatGridUnsupportedReason(NSDictionary *entry, BOOL sequenceSupports) {
    id item = entry[@"item"];
    if ([entry[@"isConnectedStoryline"] boolValue])
        return @"a connected storyline: ask for the song clip inside it (get_beat_grid with no handle lists it)";
    if (!sequenceSupports) return @"this project type does not support beat detection";
    if (![entry[@"hasAudio"] boolValue]) return @"no audio";
    if (SpliceKit_boolForSelector(item, @"isFlexMusicObject"))
        return @"a FlexMusic song: read its timing with flexmusic_get_timing";
    if ([entry[@"hasVideo"] boolValue])
        return @"has video: Final Cut Pro only analyses audio-only clips (detach or expand the audio, "
               @"or use detect_beats on the source file)";
    return @"Final Cut Pro does not offer beat detection for this clip (multicam, reference, "
           @"synchronized or variably retimed clips are excluded)";
}

static NSDictionary *SpliceKit_beatGridClipBase(NSDictionary *entry) {
    double start = [entry[@"start"] doubleValue];
    double end = [entry[@"end"] doubleValue];
    NSInteger lane = [entry[@"lane"] integerValue];
    id item = entry[@"item"];
    return @{
        @"handle": SpliceKit_storeHandle(item) ?: @"",
        @"name": entry[@"name"] ?: @"",
        @"class": NSStringFromClass([item class]) ?: @"",
        @"lane": @(lane),
        @"connected": @(lane != 0),
        @"startSeconds": @(SpliceKit_beatGridRound(start)),
        @"endSeconds": @(SpliceKit_beatGridRound(end)),
        @"durationSeconds": @(SpliceKit_beatGridRound(end - start)),
    };
}

// The beat map of one clip, mapped onto the timeline and limited to [winStart, winEnd].
static NSDictionary *SpliceKit_beatGridForEntry(NSDictionary *entry, double winStart, double winEnd) {
    id item = entry[@"item"];
    NSMutableDictionary *clip = [SpliceKit_beatGridClipBase(entry) mutableCopy];
    clip[@"status"] = @"detected";
    clip[@"beatGridVisible"] = @(SpliceKit_boolForSelector(item, @"beatGridEnabled"));
    if (SpliceKit_boolForSelector(item, @"isFlexMusicObject")) clip[@"flexMusic"] = @YES;

    double tlStart = [entry[@"start"] doubleValue];
    double tlEnd = [entry[@"end"] doubleValue];
    CMTimeRange localRange;
    if (!SpliceKit_tryReadLocalAudioRange(item, &localRange)) {
        clip[@"status"] = @"error";
        clip[@"error"] = @"could not read the clip's source range (audioClippedRange / clippedRange)";
        return clip;
    }
    // The beat map is in song (source media) seconds. The clip's own range is in its local
    // time, which a speed change scales: at 2x, song second 4 is local second 2
    // (verified on 12.3: a constant 2x retime halves audioClippedRange and leaves the
    // timing metadata as it was). So song = local * speed, and a song second s plays at
    // tlStart + (s - songStart) / speed on the timeline.
    double speed = SpliceKit_clipPlaybackSpeed(item, localRange);
    if (!isfinite(speed)) {
        clip[@"status"] = @"error";
        clip[@"error"] = @"the clip is reversed, frozen or has an unreadable speed: its beats "
                         @"cannot be placed on the timeline";
        return clip;
    }
    if (SpliceKit_boolForSelector(item, @"hasArtisticRetime")
        && !SpliceKit_boolForSelector(item, @"isConstantArtisticRetime")) {
        clip[@"note"] = @"the clip's speed varies (a speed ramp); times use its average speed "
                        @"and drift inside the ramp";
    }
    double songStart = SpliceKit_secondsFromTime(localRange.start) * speed;
    double songEnd = songStart + SpliceKit_secondsFromTime(localRange.duration) * speed;
    clip[@"songStartSeconds"] = @(SpliceKit_beatGridRound(songStart));
    clip[@"songEndSeconds"] = @(SpliceKit_beatGridRound(songEnd));
    if (fabs(speed - 1.0) > 1e-6) clip[@"speed"] = @(round(speed * 10000.0) / 10000.0);
    double (^toTimeline)(double) = ^double(double songSec) {
        return SpliceKit_beatGridRound(tlStart + (songSec - songStart) / speed);
    };

    NSArray<NSNumber *> *beats = SpliceKit_copyTimingMetadataSecondsForType(item, 1);
    NSArray<NSNumber *> *bars = SpliceKit_copyTimingMetadataSecondsForType(item, 2);
    NSArray<NSNumber *> *sections = SpliceKit_copyTimingMetadataSecondsForType(item, 4);
    double tempo = SpliceKit_copyTimingMetadataTempo(item);
    if (tempo > 0.0 && isfinite(tempo)) {
        clip[@"tempo"] = @(round(tempo * 1000.0) / 1000.0);
        if (clip[@"speed"]) clip[@"timelineTempo"] = @(round(tempo * speed * 1000.0) / 1000.0);
    }

    // Beat spacing across the whole song: tells a steady tempo from a drifting one.
    NSMutableArray<NSNumber *> *intervals = [NSMutableArray array];
    for (NSUInteger i = 1; i < beats.count; i++) {
        double d = [beats[i] doubleValue] - [beats[i - 1] doubleValue];
        if (d > kBeatGridEpsilon) [intervals addObject:@(d)];
    }
    double medianInterval = SpliceKit_beatGridMedian(intervals);
    if (intervals.count > 0) {
        NSNumber *mn = [intervals valueForKeyPath:@"@min.self"];
        NSNumber *mx = [intervals valueForKeyPath:@"@max.self"];
        clip[@"beatIntervalSeconds"] = @{
            @"median": @(SpliceKit_beatGridRound(medianInterval)),
            @"min": @(SpliceKit_beatGridRound(mn.doubleValue)),
            @"max": @(SpliceKit_beatGridRound(mx.doubleValue)),
        };
    }
    // A beat counts as a bar/section start when it lies within a quarter beat of one
    // (capped at 50 ms), so float noise in the stored times does not split them.
    double tol = medianInterval > 0.0 ? MIN(0.05, medianInterval * 0.25) : 0.05;

    clip[@"song"] = @{
        @"beatCount": @(beats.count),
        @"barCount": @(bars.count),
        @"sectionCount": @(sections.count),
        @"firstBeatSeconds": beats.count ? @(SpliceKit_beatGridRound(beats.firstObject.doubleValue)) : [NSNull null],
        @"lastBeatSeconds": beats.count ? @(SpliceKit_beatGridRound(beats.lastObject.doubleValue)) : [NSNull null],
    };

    // Visible part of the song on the timeline, limited to the requested window.
    double visStart = MAX(songStart, songStart + (winStart - tlStart) * speed);
    double visEnd = MIN(songEnd, songStart + (winEnd - tlStart) * speed);
    BOOL (^visible)(double) = ^BOOL(double s) {
        return s + kBeatGridEpsilon >= visStart && s - kBeatGridEpsilon <= visEnd;
    };

    // Beats, numbered by bar and section from the start of the song.
    NSMutableArray *beatRows = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSNumber *> *beatsPerBar = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < beats.count; i++) {
        double s = [beats[i] doubleValue];
        NSInteger barIdx = SpliceKit_beatGridIndexAtOrBefore(bars, s, tol);
        NSInteger secIdx = SpliceKit_beatGridIndexAtOrBefore(sections, s, tol);
        beatsPerBar[@(barIdx)] = @([beatsPerBar[@(barIdx)] integerValue] + 1);
        if (!visible(s)) continue;
        NSString *level = @"beat";
        if (SpliceKit_beatGridMatches(bars, barIdx, s, tol)) level = @"bar";
        if (SpliceKit_beatGridMatches(sections, secIdx, s, tol)) level = @"section";
        [beatRows addObject:@{
            @"t": @(toTimeline(s)),
            @"songSeconds": @(SpliceKit_beatGridRound(s)),
            @"index": @(i + 1),
            @"bar": @(barIdx + 1),            // 0 = a pickup before the first bar
            @"beatInBar": beatsPerBar[@(barIdx)],
            @"section": @(secIdx + 1),        // 0 = before the first section
            @"level": level,
        }];
    }

    NSMutableArray *barRows = [NSMutableArray array];
    for (NSUInteger i = 0; i < bars.count; i++) {
        double s = [bars[i] doubleValue];
        if (!visible(s)) continue;
        NSInteger secIdx = SpliceKit_beatGridIndexAtOrBefore(sections, s, tol);
        double next = (i + 1 < bars.count) ? [bars[i + 1] doubleValue] : NAN;
        NSMutableDictionary *row = [@{
            @"t": @(toTimeline(s)),
            @"songSeconds": @(SpliceKit_beatGridRound(s)),
            @"bar": @(i + 1),
            @"section": @(secIdx + 1),
            @"sectionStart": @(SpliceKit_beatGridMatches(sections, secIdx, s, tol)),
            @"beats": beatsPerBar[@((NSInteger)i)] ?: @0,
        } mutableCopy];
        if (isfinite(next)) row[@"durationSeconds"] = @(SpliceKit_beatGridRound((next - s) / speed));
        [barRows addObject:row];
    }

    // Sections as ranges: each runs to the next section start, or to the end of the song's
    // beats. Listed when any part of them is visible.
    double songTail = beats.count ? MAX(beats.lastObject.doubleValue, songEnd) : songEnd;
    NSMutableArray *sectionRows = [NSMutableArray array];
    for (NSUInteger i = 0; i < sections.count; i++) {
        double s = [sections[i] doubleValue];
        double e = (i + 1 < sections.count) ? [sections[i + 1] doubleValue] : songTail;
        if (e < visStart - kBeatGridEpsilon || s > visEnd + kBeatGridEpsilon) continue;
        NSInteger firstBar = SpliceKit_beatGridIndexAtOrBefore(bars, s, tol);
        NSInteger lastBar = SpliceKit_beatGridIndexAtOrBefore(bars, e - tol * 2.0, tol);
        double shownStart = MAX(s, songStart), shownEnd = MIN(e, songEnd);
        NSMutableDictionary *row = [@{
            @"section": @(i + 1),
            @"t": @(toTimeline(s)),
            @"endT": @(toTimeline(e)),
            @"songSeconds": @(SpliceKit_beatGridRound(s)),
            @"songEndSeconds": @(SpliceKit_beatGridRound(e)),
            @"durationSeconds": @(SpliceKit_beatGridRound((e - s) / speed)),
            @"firstBar": @(firstBar + 1),
            @"bars": @(MAX((NSInteger)0, lastBar - firstBar + 1)),
        } mutableCopy];
        // The part of the section the timeline actually plays (the song may be trimmed).
        if (shownStart > s + kBeatGridEpsilon || shownEnd < e - kBeatGridEpsilon) {
            row[@"onTimelineT"] = @(toTimeline(shownStart));
            row[@"onTimelineEndT"] = @(toTimeline(MAX(shownStart, shownEnd)));
        }
        [sectionRows addObject:row];
    }

    clip[@"beats"] = beatRows;
    clip[@"bars"] = barRows;
    clip[@"sections"] = sectionRows;
    if (beats.count == 0 && bars.count == 0 && sections.count == 0) {
        clip[@"status"] = @"empty";
        clip[@"note"] = @"Final Cut Pro reports a beat map on this clip but it holds no beat, bar or section times";
    }
    return clip;
}

// timeline.getBeatGrid
//   params: handle (optional; one clip, any status), startSeconds / endSeconds (optional
//           timeline window; beats, bars and sections outside it are left out).
//   result: clips (the songs with a beat map, each with beats, bars, sections, tempo),
//           detectable (audio clips Final Cut Pro can analyse but has not),
//           timeline (frame rate, duration, the window).
NSDictionary *SpliceKit_handleTimelineGetBeatGrid(NSDictionary *params) {
    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    if (handle.length == 0) handle = nil;
    NSNumber *startNum = [params[@"startSeconds"] isKindOfClass:[NSNumber class]] ? params[@"startSeconds"] : nil;
    NSNumber *endNum = [params[@"endSeconds"] isKindOfClass:[NSNumber class]] ? params[@"endSeconds"] : nil;
    double winStart = startNum ? startNum.doubleValue : -INFINITY;
    double winEnd = endNum ? endNum.doubleValue : INFINITY;
    if ((startNum && !isfinite(winStart)) || (endNum && !isfinite(winEnd))) {
        return @{@"error": @"startSeconds and endSeconds must be finite numbers"};
    }
    if (startNum && endNum && winEnd <= winStart) {
        return @{@"error": @"endSeconds must be after startSeconds"};
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

            SEL supportsSel = NSSelectorFromString(@"supportsBeatDetection");
            BOOL sequenceSupports = [sequence respondsToSelector:supportsSel]
                ? SpliceKit_boolForSelector(sequence, @"supportsBeatDetection") : YES;

            NSMutableDictionary *timelineInfo = [NSMutableDictionary dictionary];
            CMTime fd = SpliceKit_sequenceFrameDuration(sequence);
            double frameSeconds = SpliceKit_secondsFromTime(fd);
            if (fd.timescale > 0 && fd.value > 0 && frameSeconds > 0.0) {
                timelineInfo[@"frameRate"] = @(round((1.0 / frameSeconds) * 1000.0) / 1000.0);
                timelineInfo[@"frameSeconds"] = @(frameSeconds);
            }
            double durSec = 0.0;
            if ([sequence respondsToSelector:@selector(duration)]) {
                CMTime dur = ((CMTime (*)(id, SEL))STRET_MSG)(sequence, @selector(duration));
                durSec = SpliceKit_secondsFromTime(dur);
            }
            if (startNum) timelineInfo[@"rangeStartSeconds"] = startNum;
            if (endNum) timelineInfo[@"rangeEndSeconds"] = endNum;
            timelineInfo[@"supportsBeatDetection"] = @(sequenceSupports);

            NSArray *rootItems = SpliceKit_mixerArrayFromContainer(
                ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems)));
            if (!(durSec > 0.0) || !isfinite(durSec)) {
                // sequence.duration answers 0 on 12.3: the timeline ends where the last
                // primary-storyline item does.
                durSec = 0.0;
                for (id item in rootItems) {
                    CMTimeRange r;
                    if (SpliceKit_tryReadTimelineRange(primaryObj, item, &r)) {
                        durSec = MAX(durSec, SpliceKit_secondsFromTime(r.start) + SpliceKit_secondsFromTime(r.duration));
                    }
                }
            }
            if (durSec > 0.0 && isfinite(durSec)) timelineInfo[@"durationSeconds"] = @(SpliceKit_beatGridRound(durSec));

            NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
            NSMutableSet<NSString *> *visited = [NSMutableSet set];
            for (id item in rootItems) {
                SpliceKit_collectVisibleTimelineEntries(item, primaryObj, entries, visited);
            }
            // A clip inside a connected storyline reports its lane inside that storyline
            // (0); the timeline lane is the storyline's.
            NSMutableDictionary<NSString *, NSNumber *> *storylineLaneByChild = [NSMutableDictionary dictionary];
            SEL storylineContainedSel = NSSelectorFromString(@"containedItems");
            for (NSDictionary *entry in entries) {
                id item = entry[@"item"];
                if (![entry[@"isConnectedStoryline"] boolValue] || ![item respondsToSelector:storylineContainedSel]) continue;
                for (id child in SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, storylineContainedSel))) {
                    NSString *key = SpliceKit_handlePointerKey(child);
                    if (key.length) storylineLaneByChild[key] = entry[@"lane"];
                }
            }
            for (NSUInteger i = 0; i < entries.count; i++) {
                NSNumber *lane = storylineLaneByChild[entries[i][@"pointerKey"]];
                if (!lane) continue;
                NSMutableDictionary *fixed = [entries[i] mutableCopy];
                fixed[@"lane"] = lane;
                entries[i] = fixed;
            }
            [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                NSComparisonResult r = [a[@"start"] compare:b[@"start"]];
                return r != NSOrderedSame ? r : [a[@"lane"] compare:b[@"lane"]];
            }];

            if (handle) {
                id obj = SpliceKit_resolveHandle(handle);
                if (!obj) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"Handle not found: %@ (re-read with get_timeline_clips)", handle]};
                    return;
                }
                NSString *key = SpliceKit_handlePointerKey(obj);
                NSDictionary *match = nil;
                for (NSDictionary *entry in entries) {
                    if ([entry[@"pointerKey"] isEqualToString:key]) { match = entry; break; }
                }
                if (!match) {
                    // The media component inside an audio-only clip (get_timeline_clips lists
                    // it as "<name> - a1"): answer for the clip around it.
                    SEL containedSel = NSSelectorFromString(@"containedItems");
                    for (NSDictionary *entry in entries) {
                        id item = entry[@"item"];
                        if ([entry[@"isConnectedStoryline"] boolValue] || ![item respondsToSelector:containedSel]) continue;
                        for (id child in SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, containedSel))) {
                            if ([SpliceKit_handlePointerKey(child) isEqualToString:key]) { match = entry; break; }
                        }
                        if (match) break;
                    }
                }
                if (!match) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"%@ is not a clip on the active timeline's primary storyline or its connected "
                        @"clips (a clip inside a compound clip is not reached)", handle]};
                    return;
                }
                entries = [NSMutableArray arrayWithObject:match];
            }

            NSMutableArray *clips = [NSMutableArray array];
            NSMutableArray *detectable = [NSMutableArray array];
            NSMutableArray *unsupported = [NSMutableArray array];
            for (NSDictionary *entry in entries) {
                double s = [entry[@"start"] doubleValue], e = [entry[@"end"] doubleValue];
                if (!handle && (e < winStart - kBeatGridEpsilon || s > winEnd + kBeatGridEpsilon)) continue;
                id item = entry[@"item"];
                // A connected storyline holds clips; its songs are listed on their own.
                if ([entry[@"isConnectedStoryline"] boolValue] && !handle) continue;
                if ([entry[@"hasTimingMetadata"] boolValue] && ![entry[@"isConnectedStoryline"] boolValue]) {
                    [clips addObject:SpliceKit_beatGridForEntry(entry, winStart, winEnd)];
                } else if (![entry[@"isConnectedStoryline"] boolValue] && SpliceKit_boolForSelector(item, @"canDetectBeats")) {
                    NSMutableDictionary *row = [SpliceKit_beatGridClipBase(entry) mutableCopy];
                    row[@"status"] = @"not_detected";
                    [detectable addObject:row];
                } else if (handle) {
                    NSMutableDictionary *row = [SpliceKit_beatGridClipBase(entry) mutableCopy];
                    row[@"status"] = @"unsupported";
                    row[@"reason"] = SpliceKit_beatGridUnsupportedReason(entry, sequenceSupports);
                    [unsupported addObject:row];
                }
            }

            NSMutableDictionary *out = [@{
                @"status": @"ok",
                @"timeline": timelineInfo,
                @"clips": clips,
                @"detectable": detectable,
            } mutableCopy];
            if (unsupported.count) out[@"unsupported"] = unsupported;
            result = out;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to read the beat grid"};
}
