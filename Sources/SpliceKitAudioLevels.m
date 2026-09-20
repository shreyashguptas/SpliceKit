//
//  SpliceKitAudioLevels.m
//  SpliceKit
//
//  timeline.getAudioLevels -- peak and RMS audio levels over time for one clip, a
//  list of clips, or every clip with audio on the current timeline, mapped to
//  timeline seconds; plus head/tail silence, clipping, and the level jump at each
//  cut between neighbouring primary-storyline clips.
//
//  How it works
//    1. timeline.getDetailedState lists the clips (spine + connected) with their
//       timeline ranges and handles.
//    2. On the main thread each clip resolves to its source media file and the
//       point in that file where the clip starts (SpliceKit_audioSourceForItem,
//       the same resolution timeline.getClipInfo reports).
//    3. Off the main thread the `audio-levels` helper (tools/audio-levels.swift)
//       decodes just that range of the file and returns per-slice levels.
//       AVFoundation audio decoding inside Final Cut Pro's process deadlocks
//       (see the beat-detector note in SpliceKitServer.m), hence the helper.
//    4. The slices are placed on the timeline (clip start + offset) and summarised.
//
//  What the numbers are
//    Levels of the source media file as decoded, in dBFS (0 = full scale; -100 is
//    the floor reported for a slice with no sample above 1e-5). Final Cut Pro's
//    volume, fades, effects, retiming and the mix of all concurrent clips are NOT
//    applied: this is the raw footage, the same way getClipInfo's frame is the raw
//    footage. These are not FCP's audio meters (the mix during playback) and not
//    its timeline waveforms (which follow the clip's volume and effects). The
//    file-to-timeline mapping assumes normal speed (100%); a retimed clip is
//    flagged when FCP's object exposes a retime flag, "unknown" otherwise.
//

#import "SpliceKit.h"
#import "SpliceKitAudioLevels.h"
#import <objc/message.h>
#import <math.h>
#import <signal.h>

extern NSDictionary *SpliceKit_handleTimelineGetDetailedState(NSDictionary *params);

static const double kSKALFloorDb = -100.0;

#pragma mark - Small helpers

static double SKAL_number(id value, double fallback) {
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    return fallback;
}

static BOOL SKAL_bool(id value, BOOL fallback) {
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    return fallback;
}

static double SKAL_clamp(double v, double lo, double hi) {
    if (!isfinite(v)) return lo;
    return v < lo ? lo : (v > hi ? hi : v);
}

// timeline.getDetailedState serialises times as {value, timescale, seconds}.
static double SKAL_seconds(NSDictionary *item, NSString *key, double fallback) {
    id t = item[key];
    if ([t isKindOfClass:[NSDictionary class]]) return SKAL_number(t[@"seconds"], fallback);
    return SKAL_number(t, fallback);
}

static NSNumber *SKAL_round1(double v) { return @(round(v * 10.0) / 10.0); }
static NSNumber *SKAL_round3(double v) { return @(round(v * 1000.0) / 1000.0); }

static NSString *SKAL_arg(double v) { return [NSString stringWithFormat:@"%.4f", v]; }

// Power mean of `count` dB values from `from` (mean of the squared linear amplitudes,
// back to dB): the RMS of a window built from per-slice RMS values.
static double SKAL_powerMeanDb(NSArray<NSNumber *> *dbs, NSUInteger from, NSUInteger count) {
    double sum = 0.0;
    NSUInteger n = 0;
    for (NSUInteger i = from; i < dbs.count && i < from + count; i++) {
        double lin = pow(10.0, [dbs[i] doubleValue] / 20.0);
        sum += lin * lin;
        n++;
    }
    if (n == 0) return kSKALFloorDb;
    double rms = sqrt(sum / (double)n);
    return rms > 1e-5 ? fmax(kSKALFloorDb, 20.0 * log10(rms)) : kSKALFloorDb;
}

static double SKAL_maxDb(NSArray<NSNumber *> *dbs, NSUInteger from, NSUInteger count) {
    double best = kSKALFloorDb;
    BOOL any = NO;
    for (NSUInteger i = from; i < dbs.count && i < from + count; i++) {
        double v = [dbs[i] doubleValue];
        if (!any || v > best) { best = v; any = YES; }
    }
    return best;
}

static NSArray<NSNumber *> *SKAL_numberArray(id value, NSUInteger limit) {
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:MIN([value count], limit)];
    for (id v in (NSArray *)value) {
        if (out.count >= limit) break;
        [out addObject:[v isKindOfClass:[NSNumber class]] ? v : @(kSKALFloorDb)];
    }
    return out;
}

#pragma mark - Helper binary

NSString *SpliceKit_findAudioLevelsHelper(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // Developer override (the environment Final Cut Pro was launched with).
    NSString *override = [[NSProcessInfo processInfo] environment][@"SPLICEKIT_AUDIO_LEVELS_PATH"];
    if (override.length > 0) [candidates addObject:override];

    // 1. Inside the patched app's SpliceKit.framework (make install / make deploy put it there).
    NSString *fwResources = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/Frameworks/SpliceKit.framework/Versions/A/Resources/audio-levels"];
    [candidates addObject:fwResources];

    // 2. The same per-user locations the silence detector is looked up in.
    NSString *home = NSHomeDirectory();
    [candidates addObjectsFromArray:@[
        [home stringByAppendingPathComponent:@"Applications/SpliceKit/tools/audio-levels"],
        [home stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/tools/audio-levels"],
        [home stringByAppendingPathComponent:@"Library/Caches/SpliceKit/build/audio-levels"],
    ]];
    for (NSString *p in candidates) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

// Run the helper and parse its JSON. Both pipes are drained concurrently before
// waiting for exit (a large JSON on stdout would otherwise fill the pipe and hang).
static NSDictionary *SKAL_runHelper(NSString *helper, NSArray<NSString *> *arguments,
                                    NSTimeInterval timeout, NSString **errorOut) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:helper];
    task.arguments = arguments;
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"could not launch %@: %@", helper,
                                   launchError.localizedDescription ?: @"unknown error"];
        return nil;
    }

    NSFileHandle *outHandle = outPipe.fileHandleForReading;
    NSFileHandle *errHandle = errPipe.fileHandleForReading;
    __block NSData *outData = nil;
    __block NSData *errData = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    // The error-returning reads never throw (readDataToEndOfFile can raise on a GCD thread,
    // where nothing would catch it).
    dispatch_group_async(group, queue, ^{ outData = [outHandle readDataToEndOfFileAndReturnError:NULL] ?: [NSData data]; });
    dispatch_group_async(group, queue, ^{ errData = [errHandle readDataToEndOfFileAndReturnError:NULL] ?: [NSData data]; });

    long timedOut = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (timedOut != 0) {
        [task terminate];
        long stillRunning = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
        if (stillRunning != 0) {
            kill(task.processIdentifier, SIGKILL);       // wedged in a decoder: do not leak the readers
            dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
        }
        if (errorOut) *errorOut = [NSString stringWithFormat:@"audio-levels did not finish within %.0f s", timeout];
        return nil;
    }
    [task waitUntilExit];

    NSString *errText = errData.length > 0
        ? ([[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"") : @"";
    if (task.terminationStatus != 0) {
        // The helper prefixes real failures with "Error:"; notes (a fallback taken) come first.
        NSString *reason = nil;
        for (NSString *line in [errText componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"Error:"]) { reason = line; break; }
        }
        if (!reason) reason = [[errText componentsSeparatedByString:@"\n"] firstObject] ?: @"";
        if (errorOut) *errorOut = reason.length > 0 ? reason
            : [NSString stringWithFormat:@"audio-levels exited with status %d", task.terminationStatus];
        return nil;
    }
    NSError *jsonError = nil;
    id parsed = outData.length > 0
        ? [NSJSONSerialization JSONObjectWithData:outData options:0 error:&jsonError] : nil;
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"audio-levels returned no JSON (%@)",
                                   jsonError.localizedDescription ?: @"empty output"];
        return nil;
    }
    return parsed;
}

#pragma mark - Handler

// params (all optional):
//   handle              one clip (from timeline.getDetailedState / get_timeline_clips); on the
//                       primary storyline its nearest neighbours with audio are analysed too
//                       (summary only, role "neighbor") so the cuts on both sides are reported
//   handles             several clips
//   startSeconds, endSeconds   a timeline range; without a handle: every clip with audio
//                       overlapping it (whole timeline when both are absent)
//   sliceSeconds        slice length (0.05; 0.005..5)
//   maxSlicesPerClip    lengthen the slice so no clip reports more (600; 20..4000)
//   perChannel          also report each channel of the first audio track (NO)
//   edgeSeconds         window for the head/tail levels and the cut comparison (0.1)
//   silenceDb           RMS below this counts as silence (-50)
//   includeSlices       include the per-slice arrays (YES); NO for a summary only
//   maxClips            most clips analysed in one call (100; 1..500)
//   helperTimeoutSeconds  per clip (90)
NSDictionary *SpliceKit_handleTimelineGetAudioLevels(NSDictionary *params) {
    NSDate *startedAt = [NSDate date];
    if ([NSThread isMainThread]) {
        return @{@"error": @"timeline.getAudioLevels waits for a helper process and must not run on the main "
                           @"thread; call it through the JSON-RPC bridge or the Lua queue (sk.rpc)"};
    }

    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    if (handle.length == 0) handle = nil;
    NSArray *handles = [params[@"handles"] isKindOfClass:[NSArray class]] ? params[@"handles"] : nil;
    if (handles && handles.count == 0) {
        return @{@"error": @"handles is empty; pass clip handles, or leave it out for the whole timeline"};
    }
    BOOL haveStart = [params[@"startSeconds"] isKindOfClass:[NSNumber class]];
    BOOL haveEnd = [params[@"endSeconds"] isKindOfClass:[NSNumber class]];
    double rangeStart = haveStart ? [params[@"startSeconds"] doubleValue] : -INFINITY;
    double rangeEnd = haveEnd ? [params[@"endSeconds"] doubleValue] : INFINITY;
    if ((haveStart && !isfinite(rangeStart)) || (haveEnd && !isfinite(rangeEnd))) {
        return @{@"error": @"startSeconds and endSeconds must be finite numbers"};
    }
    if (haveStart && haveEnd && rangeEnd <= rangeStart) {
        return @{@"error": @"endSeconds must be greater than startSeconds"};
    }
    double sliceSeconds = SKAL_clamp(SKAL_number(params[@"sliceSeconds"], 0.05), 0.005, 5.0);
    double edgeSeconds = SKAL_clamp(SKAL_number(params[@"edgeSeconds"], 0.1), 0.01, 5.0);
    double silenceDb = SKAL_clamp(SKAL_number(params[@"silenceDb"], -50.0), -100.0, 0.0);
    NSInteger maxSlices = (NSInteger)SKAL_clamp(SKAL_number(params[@"maxSlicesPerClip"], 600), 20, 4000);
    NSInteger maxClips = (NSInteger)SKAL_clamp(SKAL_number(params[@"maxClips"], 100), 1, 500);
    BOOL perChannel = SKAL_bool(params[@"perChannel"], NO);
    BOOL includeSlices = SKAL_bool(params[@"includeSlices"], YES);
    double helperTimeout = SKAL_clamp(SKAL_number(params[@"helperTimeoutSeconds"], 90), 5, 600);

    NSString *helper = SpliceKit_findAudioLevelsHelper();
    if (!helper) {
        return @{@"error": @"audio-levels helper not found. `make install` builds it (step 3c, swiftc from the "
                           @"Command Line Tools) into the patched app's SpliceKit.framework/Versions/A/Resources and "
                           @"says so in its final banner when that failed (log: build/audio-levels-build.log). By hand: "
                           @"`make tools`, then copy build/audio-levels there or to ~/Applications/SpliceKit/tools/."};
    }

    NSDictionary *state = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @1000,
                                                                     @"connected_limit": @1000,
                                                                     @"include_markers": @NO});
    if (![state isKindOfClass:[NSDictionary class]]) return @{@"error": @"timeline.getDetailedState returned nothing"};
    if (state[@"error"]) return @{@"error": state[@"error"]};
    double frameRate = SKAL_number(state[@"frameRate"], 0.0);
    double frame = frameRate > 0 ? 1.0 / frameRate : 1.0 / 30.0;
    double timelineDuration = SKAL_seconds(state, @"duration", 0.0);

    // --- Candidates: every item the state lists, filtered to the requested handles.
    NSMutableSet *wanted = nil;
    if (handle) wanted = [NSMutableSet setWithObject:handle];
    else if (handles.count > 0) wanted = [NSMutableSet setWithArray:handles];
    NSMutableSet *seenWanted = [NSMutableSet set];
    NSMutableArray<NSMutableDictionary *> *candidates = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *spineOrder = [NSMutableArray array];   // every spine item, for cuts

    void (^consider)(NSDictionary *, BOOL) = ^(NSDictionary *item, BOOL connected) {
        if (![item isKindOfClass:[NSDictionary class]]) return;
        NSString *h = [item[@"handle"] isKindOfClass:[NSString class]] ? item[@"handle"] : @"";
        NSString *cls = [item[@"class"] isKindOfClass:[NSString class]] ? item[@"class"] : @"";
        double start = SKAL_seconds(item, @"startTime", NAN);
        double dur = SKAL_seconds(item, @"duration", NAN);
        double end = SKAL_seconds(item, @"endTime", NAN);
        if (isnan(end) && !isnan(start) && !isnan(dur)) end = start + dur;
        NSMutableDictionary *c = [NSMutableDictionary dictionary];
        c[@"handle"] = h;
        c[@"name"] = [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : @"";
        c[@"class"] = cls;
        c[@"connected"] = @(connected);
        c[@"lane"] = [item[@"lane"] isKindOfClass:[NSNumber class]] ? item[@"lane"] : @0;
        if ([item[@"index"] isKindOfClass:[NSNumber class]]) c[@"index"] = item[@"index"];
        if (!isnan(start)) c[@"startSeconds"] = @(start);
        if (!isnan(end)) c[@"endSeconds"] = @(end);
        c[@"isTransition"] = @([cls containsString:@"Transition"] || SKAL_bool(item[@"isTransition"], NO));
        c[@"isGap"] = @([cls containsString:@"Gap"] || SKAL_bool(item[@"isGap"], NO));
        c[@"hasAudio"] = @(SKAL_bool(item[@"hasAudio"], NO));
        c[@"isCompound"] = @(SKAL_bool(item[@"isCompound"], NO));
        c[@"isReferenceClip"] = @(SKAL_bool(item[@"isReferenceClip"], NO));
        if (!connected) [spineOrder addObject:c];
        if (wanted && ![wanted containsObject:h]) return;
        if (wanted) [seenWanted addObject:h];
        [candidates addObject:c];
    };
    for (NSDictionary *item in ([state[@"items"] isKindOfClass:[NSArray class]] ? state[@"items"] : @[])) consider(item, NO);
    for (NSDictionary *item in ([state[@"connectedItems"] isKindOfClass:[NSArray class]] ? state[@"connectedItems"] : @[])) consider(item, YES);

    NSMutableArray *skipped = [NSMutableArray array];
    if (wanted) {
        NSMutableSet *missing = [wanted mutableCopy];
        [missing minusSet:seenWanted];
        if (handle && missing.count > 0) {
            return @{@"error": [NSString stringWithFormat:@"handle %@ is not a clip on the current timeline "
                                @"(get_timeline_clips lists the clips and their handles)", handle]};
        }
        for (NSString *h in missing) {
            [skipped addObject:@{@"handle": h, @"name": @"", @"reason": @"not a clip on the current timeline"}];
        }
    }

    // A single handle on the primary storyline also brings its nearest neighbours with
    // audio (summary only, no slices), so the cuts on both sides of that clip are reported.
    NSInteger neighborCount = 0;
    if (handle && candidates.count == 1 && ![candidates[0][@"connected"] boolValue]) {
        NSUInteger pos = NSNotFound;
        for (NSUInteger i = 0; i < spineOrder.count; i++) {
            if ([spineOrder[i][@"handle"] isEqualToString:handle]) { pos = i; break; }
        }
        if (pos != NSNotFound) {
            NSInteger directions[2] = {-1, 1};
            for (int d = 0; d < 2; d++) {
                NSInteger i = (NSInteger)pos + directions[d];
                while (i >= 0 && i < (NSInteger)spineOrder.count) {
                    NSMutableDictionary *n = (NSMutableDictionary *)spineOrder[(NSUInteger)i];
                    if ([n[@"isTransition"] boolValue]) { i += directions[d]; continue; }
                    if ([n[@"hasAudio"] boolValue] && ![n[@"isGap"] boolValue]
                        && n[@"startSeconds"] && n[@"endSeconds"]) {
                        n[@"role"] = @"neighbor";
                        [candidates addObject:n];
                        neighborCount++;
                    }
                    break;      // the nearest non-transition item decides; a gap or silent item ends the chain
                }
            }
        }
    }

    // --- Which candidates get analysed.
    NSMutableArray<NSMutableDictionary *> *selected = [NSMutableArray array];
    NSInteger outsideRange = 0;
    for (NSMutableDictionary *c in candidates) {
        NSString *reason = nil;
        BOOL haveRange = c[@"startSeconds"] && c[@"endSeconds"];
        if ([c[@"isTransition"] boolValue]) reason = @"transition (no source media of its own)";
        else if ([c[@"isGap"] boolValue]) reason = @"gap clip (no audio)";
        else if (![c[@"hasAudio"] boolValue]) reason = @"no audio";
        else if ([c[@"isCompound"] boolValue]) reason = @"compound clip: no single source media file (open it to analyse the clips inside)";
        else if ([c[@"isReferenceClip"] boolValue]) reason = @"reference clip (a compound, multicam or synchronized clip on the timeline): no single source media file (open it to analyse the clips inside)";
        else if (!haveRange) reason = @"no timeline range reported for this item";
        if (reason) {
            [skipped addObject:@{@"handle": c[@"handle"], @"name": c[@"name"], @"reason": reason}];
            SpliceKit_log(@"[AudioLevels] %@ \"%@\" skipped: %@", c[@"handle"], c[@"name"], reason);
            continue;
        }
        double start = [c[@"startSeconds"] doubleValue], end = [c[@"endSeconds"] doubleValue];
        if ((haveStart && end <= rangeStart) || (haveEnd && start >= rangeEnd)) { outsideRange++; continue; }
        [selected addObject:c];
    }
    BOOL truncated = NO;
    if ((NSInteger)selected.count > maxClips) {
        [selected removeObjectsInRange:NSMakeRange((NSUInteger)maxClips, selected.count - (NSUInteger)maxClips)];
        truncated = YES;
    }

    // --- Main thread: each selected clip -> source media file + where the clip starts in it.
    // No file-system access happens in this block (see SpliceKit_audioSourceForItem).
    __block BOOL resolved = NO;
    SpliceKit_executeOnMainThread(^{
        for (NSMutableDictionary *c in selected) {
            id obj = SpliceKit_resolveHandle(c[@"handle"]);
            if (!obj) { c[@"sourceError"] = @"handle no longer resolves (call get_timeline_clips again)"; continue; }
            NSDictionary *src = SpliceKit_audioSourceForItem(obj);
            if ([src isKindOfClass:[NSDictionary class]]) c[@"source"] = src;
            else c[@"sourceError"] = @"could not resolve the source media";
        }
        resolved = YES;
    });
    if (!resolved) {
        // SpliceKit_executeOnMainThread gives up after its timeout and returns while the block
        // may still run; the dictionaries above must not be read while that is possible.
        return @{@"error": @"the main thread did not answer in time (a modal dialog or a busy app); try again"};
    }

    // --- Off the main thread: decode each clip's range with the helper.
    NSMutableArray *clips = [NSMutableArray array];
    NSInteger analyzed = 0;
    for (NSMutableDictionary *c in selected) {
        @autoreleasepool {
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"handle"] = c[@"handle"];
            entry[@"name"] = c[@"name"];
            entry[@"class"] = c[@"class"];
            entry[@"connected"] = c[@"connected"];
            entry[@"lane"] = c[@"lane"];
            if (c[@"index"]) entry[@"index"] = c[@"index"];
            BOOL isNeighbor = [c[@"role"] isEqualToString:@"neighbor"];
            if (isNeighbor) entry[@"role"] = @"neighbor";
            double clipStart = [c[@"startSeconds"] doubleValue];
            double clipEnd = [c[@"endSeconds"] doubleValue];
            entry[@"startSeconds"] = SKAL_round3(clipStart);
            entry[@"endSeconds"] = SKAL_round3(clipEnd);
            entry[@"durationSeconds"] = SKAL_round3(clipEnd - clipStart);

            NSDictionary *src = c[@"source"];
            if (c[@"sourceError"]) { entry[@"error"] = c[@"sourceError"]; [clips addObject:entry]; continue; }
            NSString *kind = [src[@"kind"] isKindOfClass:[NSString class]] ? src[@"kind"] : @"";
            if (kind.length > 0) entry[@"kind"] = kind;
            // A collection is skipped before its file is looked at: the media resolver would
            // otherwise hand back the first clip inside it under the container's name.
            if ([kind isEqualToString:@"compound clip"] || [kind isEqualToString:@"reference clip"]) {
                entry[@"skipped"] = [kind isEqualToString:@"compound clip"]
                    ? @"compound clip: no single source media file (open it to analyse the clips inside)"
                    : @"reference clip (a compound, multicam or synchronized clip on the timeline): no single source media file (open it to analyse the clips inside)";
                SpliceKit_log(@"[AudioLevels] %@ \"%@\" skipped: %@", c[@"handle"], c[@"name"], entry[@"skipped"]);
                [clips addObject:entry];
                continue;
            }
            if ([kind isEqualToString:@"multicam clip"]) {
                entry[@"skipped"] = @"multicam clip: no single source media file (its angles are clips inside it)";
                SpliceKit_log(@"[AudioLevels] %@ \"%@\" skipped: %@", c[@"handle"], c[@"name"], entry[@"skipped"]);
                [clips addObject:entry];
                continue;
            }
            if ([kind isEqualToString:@"connected storyline"]) {
                entry[@"skipped"] = @"connected storyline container: its clips are analysed individually";
                SpliceKit_log(@"[AudioLevels] %@ \"%@\" skipped: %@", c[@"handle"], c[@"name"], entry[@"skipped"]);
                [clips addObject:entry];
                continue;
            }
            // The media resolver digs into nested containers (containedItems) for the first
            // media component it finds. For an ordinary clip that is a direct child (depth
            // 1); two or more levels down it is the first file inside a container of
            // containers, and nothing says which part of this clip that file is -- skipped
            // rather than analysed against a file that may not be this clip's content.
            NSInteger mediaDepth = [src[@"mediaComponentDepth"] respondsToSelector:@selector(integerValue)]
                ? [src[@"mediaComponentDepth"] integerValue] : -1;
            if (mediaDepth >= 2) {
                entry[@"skipped"] = [NSString stringWithFormat:
                    @"its first source media file was found %ld levels down inside nested containers; SpliceKit "
                    @"cannot tell which part of this clip that file is, so it is skipped (get_clip_info shows the "
                    @"structure)", (long)mediaDepth];
                SpliceKit_log(@"[AudioLevels] %@ \"%@\" skipped: %@", c[@"handle"], c[@"name"], entry[@"skipped"]);
                [clips addObject:entry];
                continue;
            }
            NSString *path = [src[@"path"] isKindOfClass:[NSString class]] ? src[@"path"] : @"";
            if (path.length == 0) {
                if (src[@"error"]) entry[@"error"] = src[@"error"];
                else entry[@"skipped"] = [NSString stringWithFormat:
                    @"no source media file could be resolved for this clip (kind: %@)", kind.length ? kind : @"unknown"];
                SpliceKit_log(@"[AudioLevels] %@ \"%@\" %@: %@", c[@"handle"], c[@"name"],
                              entry[@"error"] ? @"error" : @"skipped", entry[@"error"] ?: entry[@"skipped"]);
                [clips addObject:entry];
                continue;
            }
            NSMutableDictionary *sourceOut = [NSMutableDictionary dictionary];
            sourceOut[@"path"] = path;
            sourceOut[@"fileName"] = src[@"fileName"] ?: [path lastPathComponent];
            sourceOut[@"representation"] = src[@"representation"] ?: @"unknown";
            sourceOut[@"sourceStart"] = src[@"sourceStart"] ?: @0;
            sourceOut[@"sourceStartSelector"] = src[@"sourceStartSelector"] ?: @"none";
            sourceOut[@"mediaOrigin"] = src[@"mediaOrigin"] ?: @0;
            sourceOut[@"mediaOriginSelector"] = src[@"mediaOriginSelector"] ?: @"none";
            BOOL sourceStartKnown = SKAL_bool(src[@"sourceStartKnown"], YES);
            sourceOut[@"sourceStartKnown"] = @(sourceStartKnown);
            if (mediaDepth >= 0) sourceOut[@"mediaComponentDepth"] = @(mediaDepth);
            entry[@"source"] = sourceOut;
            NSMutableArray<NSString *> *notes = [NSMutableArray array];
            if (!sourceStartKnown) {
                [notes addObject:@"the clip's start point in its source media could not be read from FCP's clip object "
                                 @"(clippedRange, trimStartTime and trimmedOffset did not answer); the levels are taken "
                                 @"from the start of the media file, which is right only for a clip whose start is not trimmed"];
            }
            entry[@"retimed"] = src[@"retimed"] ?: @"unknown";
            if (src[@"retimeSelector"]) entry[@"retimeSelector"] = src[@"retimeSelector"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {     // off the main thread
                entry[@"skipped"] = @"source media file is missing on disk (Final Cut Pro: Missing File)";
                SpliceKit_log(@"[AudioLevels] %@ \"%@\" skipped: %@", c[@"handle"], c[@"name"], entry[@"skipped"]);
                [clips addObject:entry];
                continue;
            }

            double aStart = haveStart ? fmax(clipStart, rangeStart) : clipStart;
            double aEnd = haveEnd ? fmin(clipEnd, rangeEnd) : clipEnd;
            if (aEnd - aStart < 0.001) {
                entry[@"skipped"] = @"the requested range covers none of this clip";
                SpliceKit_log(@"[AudioLevels] %@ \"%@\" skipped: %@", c[@"handle"], c[@"name"], entry[@"skipped"]);
                [clips addObject:entry];
                continue;
            }
            double fileStart = SKAL_number(src[@"fileStart"], 0.0) + (aStart - clipStart);
            if (fileStart < 0) {
                // FCP's readings place the clip's start before its media file's origin. The
                // file's first sample then sits at timeline time aStart - fileStart, so the
                // analysed range starts there; the readings are named so this can be checked.
                double missing = -fileStart;
                aStart += missing;
                fileStart = 0;
                if (aEnd - aStart < 0.001) {
                    entry[@"skipped"] = [NSString stringWithFormat:
                        @"SpliceKit's readings of FCP's clip object place the whole clip before the start of its media file "
                        @"(source start %.3f s via %@, media origin %.3f s via %@; SpliceKit's terms): the clip-to-file mapping "
                        @"does not fit this clip, so it is not analysed",
                        SKAL_number(src[@"sourceStart"], 0.0), sourceOut[@"sourceStartSelector"],
                        SKAL_number(src[@"mediaOrigin"], 0.0), sourceOut[@"mediaOriginSelector"]];
                    SpliceKit_log(@"[AudioLevels] %@ skipped: %@", c[@"handle"], entry[@"skipped"]);
                    [clips addObject:entry];
                    continue;
                }
                [notes addObject:[NSString stringWithFormat:
                    @"SpliceKit's readings of FCP's clip object place the clip's first %.3f s before the start of its media "
                    @"file (source start via %@, media origin via %@; SpliceKit's terms); the levels start at %.3f s on the "
                    @"timeline, where the file does",
                    missing, sourceOut[@"sourceStartSelector"], sourceOut[@"mediaOriginSelector"], aStart]];
            }
            double fileEnd = fileStart + (aEnd - aStart);
            sourceOut[@"fileStart"] = SKAL_round3(fileStart);
            sourceOut[@"fileEnd"] = SKAL_round3(fileEnd);
            entry[@"analysisRange"] = @{@"startSeconds": SKAL_round3(aStart), @"endSeconds": SKAL_round3(aEnd)};

            NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
                path, @"--start", SKAL_arg(fileStart), @"--end", SKAL_arg(fileEnd),
                @"--slice", SKAL_arg(sliceSeconds), @"--max-slices", [@(maxSlices) stringValue]]];
            if (perChannel) [args addObject:@"--per-channel"];
            NSString *helperError = nil;
            NSDate *helperStarted = [NSDate date];
            NSDictionary *r = SKAL_runHelper(helper, args, helperTimeout, &helperError);
            SpliceKit_log(@"[AudioLevels] %@ \"%@\" file %.3f-%.3f s of %@: %@ in %.2f s", c[@"handle"], c[@"name"],
                          fileStart, fileEnd, [path lastPathComponent], r ? @"decoded" : (helperError ?: @"failed"),
                          -[helperStarted timeIntervalSinceNow]);
            if (!r) {
                NSString *err = helperError ?: @"audio-levels failed";
                if ([err rangeOfString:@"empty range"].location != NSNotFound) {
                    err = [NSString stringWithFormat:
                        @"the file range %.3f-%.3f s lies outside the media file (%@): SpliceKit's clip-to-file mapping from "
                        @"FCP's clip object (source start via %@, media origin via %@; SpliceKit's terms) does not fit this clip",
                        fileStart, fileEnd, err, sourceOut[@"sourceStartSelector"], sourceOut[@"mediaOriginSelector"]];
                }
                entry[@"error"] = err;
                if (notes.count > 0) entry[@"note"] = [notes componentsJoinedByString:@" | "];
                [clips addObject:entry];
                continue;
            }

            // Slices onto the timeline.
            NSDictionary *slices = [r[@"slices"] isKindOfClass:[NSDictionary class]] ? r[@"slices"] : @{};
            NSArray<NSNumber *> *peak = SKAL_numberArray(slices[@"peakDb"], (NSUInteger)maxSlices * 2);
            NSArray<NSNumber *> *rms = SKAL_numberArray(slices[@"rmsDb"], (NSUInteger)maxSlices * 2);
            NSUInteger n = MIN(peak.count, rms.count);
            if (peak.count != n) peak = [peak subarrayWithRange:NSMakeRange(0, n)];
            if (rms.count != n) rms = [rms subarrayWithRange:NSMakeRange(0, n)];
            double helperSlice = SKAL_number(r[@"sliceSeconds"], sliceSeconds);
            if (!(helperSlice > 0)) helperSlice = sliceSeconds;
            double sliceFileStart = SKAL_number(slices[@"start"], fileStart);
            double timelineSliceStart = aStart + (sliceFileStart - fileStart);

            NSUInteger edgeSlices = MAX((NSUInteger)1, (NSUInteger)ceil(edgeSeconds / helperSlice));
            NSUInteger headSilent = 0;
            while (headSilent < n && [rms[headSilent] doubleValue] < silenceDb) headSilent++;
            NSUInteger tailSilent = 0;
            while (tailSilent < n - headSilent && [rms[n - 1 - tailSilent] doubleValue] < silenceDb) tailSilent++;
            NSUInteger silentSlices = 0;
            for (NSNumber *v in rms) if ([v doubleValue] < silenceDb) silentSlices++;
            NSUInteger tailFrom = n > edgeSlices ? n - edgeSlices : 0;

            NSDictionary *hs = [r[@"stats"] isKindOfClass:[NSDictionary class]] ? r[@"stats"] : @{};
            double maxPeakAtFile = SKAL_number(hs[@"maxPeakAt"], sliceFileStart);

            // channelsMode "pooled": the peak of a slice is the loudest sample in any channel and
            // its RMS is over all channels' samples, no channel mixed with another (QA run 3: the
            // decoder's mono mixdown read +3 dB on dual-mono files); "mixdownMono" is the fallback.
            double averageFps = SKAL_number(r[@"videoFrameRateAverage"], SKAL_number(r[@"videoFrameRate"], 0.0));
            double shortestFps = SKAL_number(r[@"videoFrameRateShortest"], 0.0);
            NSMutableDictionary *audioOut = [@{
                @"sampleRate": @(SKAL_number(r[@"sampleRate"], 0)),
                @"channels": @((NSInteger)SKAL_number(r[@"channels"], 1)),
                @"channelsMode": r[@"channelsMode"] ?: @"unknown",
                @"audioTrackCount": @((NSInteger)SKAL_number(r[@"audioTrackCount"], 1)),
                @"tracksDecoded": @((NSInteger)SKAL_number(r[@"tracksDecoded"], SKAL_number(r[@"audioTrackCount"], 1))),
                @"fileDuration": @(SKAL_number(r[@"fileDuration"], 0)),
                @"sliceSeconds": @(helperSlice),
                @"sliceCount": @(n),
            } mutableCopy];
            if (averageFps > 0) audioOut[@"videoFrameRate"] = @(averageFps);          // the average, as before
            if (averageFps > 0) audioOut[@"videoFrameRateAverage"] = @(averageFps);
            if (shortestFps > 0) audioOut[@"videoFrameRateShortest"] = @(shortestFps);
            entry[@"audio"] = audioOut;
            if (includeSlices && !isNeighbor) {
                NSMutableDictionary *sl = [NSMutableDictionary dictionary];
                sl[@"startSeconds"] = SKAL_round3(timelineSliceStart);
                sl[@"sliceSeconds"] = @(helperSlice);
                sl[@"count"] = @(n);
                sl[@"peakDb"] = peak;
                sl[@"rmsDb"] = rms;
                if ([slices[@"clippedSliceIndices"] isKindOfClass:[NSArray class]]) {
                    sl[@"clippedSliceIndices"] = slices[@"clippedSliceIndices"];
                }
                if ([r[@"perChannel"] isKindOfClass:[NSArray class]]) sl[@"perChannel"] = r[@"perChannel"];
                entry[@"slices"] = sl;
            }
            entry[@"stats"] = @{
                @"maxPeakDb": SKAL_round1(SKAL_number(hs[@"maxPeakDb"], SKAL_maxDb(peak, 0, n))),
                @"maxPeakAtSeconds": SKAL_round3(aStart + (maxPeakAtFile - fileStart)),
                @"meanRmsDb": SKAL_round1(SKAL_number(hs[@"meanRmsDb"], SKAL_powerMeanDb(rms, 0, n))),
                @"clippedSlices": @((NSInteger)SKAL_number(hs[@"clippedSlices"], 0)),
                @"silentSlices": @(silentSlices),
                @"allSilent": @(n > 0 && headSilent == n),
                @"headSilenceSeconds": SKAL_round3((double)headSilent * helperSlice),
                @"tailSilenceSeconds": SKAL_round3((double)tailSilent * helperSlice),
                @"headRmsDb": SKAL_round1(SKAL_powerMeanDb(rms, 0, edgeSlices)),
                @"headPeakDb": SKAL_round1(SKAL_maxDb(peak, 0, edgeSlices)),
                @"tailRmsDb": SKAL_round1(SKAL_powerMeanDb(rms, tailFrom, edgeSlices)),
                @"tailPeakDb": SKAL_round1(SKAL_maxDb(peak, tailFrom, edgeSlices)),
                @"edgeSeconds": SKAL_round3((double)edgeSlices * helperSlice),
            };
            if ([entry[@"retimed"] isKindOfClass:[NSNumber class]] && [entry[@"retimed"] boolValue]) {
                // The flag is FCP's; what it covers beyond a speed change SpliceKit cannot tell
                // from the flag alone. What it can read (from the helper, SpliceKit's readings
                // of the file, not FCP's): the average frame rate over the file and the rate
                // the shortest frame duration corresponds to. A file at another frame rate is
                // rate-conformed by FCP (Video inspector: Rate Conform), which QA run 3 found
                // sets isRetimed by itself on a 30 fps, variable-frame-rate screen recording
                // in a 29.97 fps project; a conform keeps the file-to-timeline mapping
                // (frames are repeated or dropped, the audio is not stretched). Neither
                // reading is the file's "nominal" rate (QA run 4: the average alone had been
                // presented as that; a 29.97 fps file in a 600-tick timescale has 30.000 as
                // its shortest-frame rate), and which one FCP's Rate Conform goes by SpliceKit
                // does not know: a conform is asserted only when both differ from the
                // project's rate, and left open when they straddle it.
                NSString *flagName = entry[@"retimeSelector"] ?: @"its retime flag";
                BOOL haveAverage = averageFps > 0, haveShortest = shortestFps > 0;
                BOOL averageDiffers = haveAverage && frameRate > 0 && fabs(averageFps - frameRate) / frameRate > 1e-4;
                BOOL shortestDiffers = haveShortest && frameRate > 0 && fabs(shortestFps - frameRate) / frameRate > 1e-4;
                BOOL variableRate = haveAverage && haveShortest && fabs(averageFps - shortestFps) / shortestFps > 0.002;
                NSString *readings = nil;
                if (haveAverage && haveShortest) {
                    readings = [NSString stringWithFormat:
                        @"the media file's video averages %.3f fps over the file and its shortest frame duration corresponds "
                        @"to %.3f fps%@", averageFps, shortestFps,
                        variableRate ? @" (a variable-frame-rate recording, most likely)" : @""];
                } else if (haveAverage) {
                    readings = [NSString stringWithFormat:
                        @"the media file's video averages %.3f fps over the file (its shortest frame duration could not be "
                        @"read or was not trusted)", averageFps];
                } else if (haveShortest) {
                    readings = [NSString stringWithFormat:
                        @"the media file's shortest frame duration corresponds to %.3f fps (its average frame rate could "
                        @"not be read)", shortestFps];
                }
                BOOL allDiffer = readings && frameRate > 0
                    && (haveAverage ? averageDiffers : YES) && (haveShortest ? shortestDiffers : YES);
                BOOL noneDiffers = readings && frameRate > 0 && !averageDiffers && !shortestDiffers;
                if (allDiffer) {
                    [notes addObject:[NSString stringWithFormat:
                        @"FCP's clip object answers %@ = true; %@, in a %.3f fps project, which FCP rate-conforms (Rate "
                        @"Conform in the Video inspector); a frame-rate conform on its own can set this flag (seen on 12.3 "
                        @"with a 30 fps, variable-frame-rate screen recording in a 29.97 fps project); whether the clip is "
                        @"also retimed (a speed change) SpliceKit cannot tell. The levels are mapped assuming normal speed "
                        @"(100%%): right for a conform alone, not for a speed change",
                        flagName, readings, frameRate]];
                } else if (noneDiffers) {
                    [notes addObject:[NSString stringWithFormat:
                        @"FCP's clip object answers %@ = true, and %@, the project's rate (%.3f fps), so a frame-rate "
                        @"conform is unlikely to be what set it: the clip is most likely retimed (a speed change), and the "
                        @"levels, mapped assuming normal speed (100%%), then do not match what Final Cut Pro plays",
                        flagName, readings, frameRate]];
                } else if (readings && frameRate > 0) {
                    [notes addObject:[NSString stringWithFormat:
                        @"FCP's clip object answers %@ = true; %@; the project runs at %.3f fps, and which of the two "
                        @"readings FCP's Rate Conform goes by SpliceKit does not know, so whether this flag is a frame-rate "
                        @"conform or a speed change is open. The levels are mapped assuming normal speed (100%%): right for "
                        @"a conform alone, not for a speed change",
                        flagName, readings, frameRate]];
                } else {
                    [notes addObject:[NSString stringWithFormat:
                        @"FCP's clip object answers %@ = true (a speed change, or possibly a frame-rate conform; SpliceKit "
                        @"cannot tell which); the levels are mapped assuming normal speed (100%%), so for a clip that really "
                        @"is retimed the levels and their times do not match what Final Cut Pro plays",
                        flagName]];
                }
            }
            if (notes.count > 0) entry[@"note"] = [notes componentsJoinedByString:@" | "];
            analyzed++;
            [clips addObject:entry];
        }
    }

    // --- Cuts between neighbouring primary-storyline clips that were both analysed.
    NSMutableArray *cuts = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary *> *byHandle = [NSMutableDictionary dictionary];
    for (NSDictionary *e in clips) if (e[@"stats"] && ![e[@"connected"] boolValue]) byHandle[e[@"handle"]] = e;
    NSDictionary *previous = nil;      // last analysed spine clip
    NSDictionary *transitionBetween = nil;
    for (NSDictionary *c in spineOrder) {
        if ([c[@"isTransition"] boolValue]) { if (previous) transitionBetween = c; continue; }
        NSDictionary *e = byHandle[c[@"handle"]];
        if (!e) {                       // gap, title, skipped or errored clip: breaks the chain
            previous = nil;
            transitionBetween = nil;
            continue;
        }
        if (previous) {
            double prevEnd = [previous[@"endSeconds"] doubleValue];
            double thisStart = [e[@"startSeconds"] doubleValue];
            NSMutableDictionary *cut = [NSMutableDictionary dictionary];
            cut[@"atSeconds"] = SKAL_round3(prevEnd);
            cut[@"outgoing"] = @{@"handle": previous[@"handle"], @"name": previous[@"name"],
                                 @"tailRmsDb": previous[@"stats"][@"tailRmsDb"], @"tailPeakDb": previous[@"stats"][@"tailPeakDb"],
                                 @"tailSilenceSeconds": previous[@"stats"][@"tailSilenceSeconds"]};
            cut[@"incoming"] = @{@"handle": e[@"handle"], @"name": e[@"name"],
                                 @"headRmsDb": e[@"stats"][@"headRmsDb"], @"headPeakDb": e[@"stats"][@"headPeakDb"],
                                 @"headSilenceSeconds": e[@"stats"][@"headSilenceSeconds"]};
            if (transitionBetween) {
                cut[@"transition"] = transitionBetween[@"name"] ?: @"transition";
                cut[@"note"] = @"a transition sits on this cut; Final Cut Pro applies an audio crossfade there when "
                               @"the clips' audio is attached (not when it is expanded or detached), which SpliceKit "
                               @"does not check";
            } else if (fabs(thisStart - prevEnd) <= 1.5 * frame) {
                double outDb = [previous[@"stats"][@"tailRmsDb"] doubleValue];
                double inDb = [e[@"stats"][@"headRmsDb"] doubleValue];
                cut[@"jumpDb"] = SKAL_round1(inDb - outDb);
                cut[@"outgoingEndsInSilence"] = @(outDb < silenceDb);
                cut[@"incomingStartsInSilence"] = @(inDb < silenceDb);
            } else if (thisStart > prevEnd) {
                cut[@"note"] = [NSString stringWithFormat:@"%.3f s between these clips: not a straight cut", thisStart - prevEnd];
            } else {
                cut[@"note"] = [NSString stringWithFormat:@"the clips overlap by %.3f s: not a straight cut", fabs(thisStart - prevEnd)];
            }
            [cuts addObject:cut];
        }
        previous = e;
        transitionBetween = nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"status"] = @"ok";
    result[@"levelsAre"] = @"the source media file as decoded by the audio-levels helper (dBFS): Final Cut Pro's "
                           @"volume, fades, effects, retiming and the mix of all concurrent clips are not applied; "
                           @"not FCP's audio meters and not its timeline waveforms";
    result[@"floorDb"] = @(kSKALFloorDb);
    result[@"sliceSeconds"] = @(sliceSeconds);
    result[@"silenceDb"] = @(silenceDb);
    result[@"edgeSeconds"] = @(edgeSeconds);
    result[@"perChannel"] = @(perChannel);
    result[@"helper"] = helper;
    NSMutableDictionary *tl = [NSMutableDictionary dictionary];
    tl[@"frameRate"] = @(frameRate);
    tl[@"durationSeconds"] = SKAL_round3(timelineDuration);
    if (haveStart) tl[@"rangeStartSeconds"] = SKAL_round3(rangeStart);
    if (haveEnd) tl[@"rangeEndSeconds"] = SKAL_round3(rangeEnd);
    result[@"timeline"] = tl;
    result[@"clipCount"] = @(candidates.count);
    result[@"analyzedCount"] = @(analyzed);
    result[@"neighborCount"] = @(neighborCount);
    result[@"outsideRangeCount"] = @(outsideRange);
    if (truncated) result[@"truncatedTo"] = @(maxClips);
    result[@"clips"] = clips;
    result[@"cuts"] = cuts;
    result[@"skipped"] = skipped;
    result[@"elapsedSeconds"] = SKAL_round3(-[startedAt timeIntervalSinceNow]);
    SpliceKit_log(@"[AudioLevels] %lu clip(s) considered, %ld analysed, %lu skipped, %lu cut(s), %.2f s",
                  (unsigned long)candidates.count, (long)analyzed, (unsigned long)skipped.count,
                  (unsigned long)cuts.count, -[startedAt timeIntervalSinceNow]);
    return result;
}
