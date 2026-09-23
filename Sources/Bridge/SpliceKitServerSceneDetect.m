//
//  SpliceKitServerSceneDetect.m
//  SpliceKit - Scene change detection, markers and blades at the detected cuts.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Scene Change Detection
//
// Detects visual cuts in timeline media by comparing histogram differences
// between consecutive frames. Optionally places markers or blades at cuts.
//

// Primary-storyline clip whose timeline range contains the playhead (nil if none).
static id SpliceKit_scenePrimaryClipAtPlayhead(id timeline, id primaryObj,
                                               double *outStart, double *outEnd) {
    if (!timeline || !primaryObj) return nil;
    CMTime playheadTime = {0, 1, 0, 0};
    @try {
        if ([timeline respondsToSelector:@selector(playheadTime)]) {
            playheadTime = ((CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
        }
    } @catch (NSException *e) {}
    double ph = SpliceKit_secondsFromTime(playheadTime);
    NSArray *items = SpliceKit_mixerArrayFromContainer(
        [primaryObj respondsToSelector:@selector(containedItems)]
            ? ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems)) : nil);
    for (id item in items) {
        CMTimeRange range;
        if (!SpliceKit_tryReadTimelineRange(primaryObj, item, &range)) continue;
        double start = SpliceKit_secondsFromTime(range.start);
        double end = start + SpliceKit_secondsFromTime(range.duration);
        if (ph >= start - 0.01 && ph < end + 0.01) {
            if (outStart) *outStart = start;
            if (outEnd) *outEnd = end;
            return item;
        }
    }
    return nil;
}

static NSArray *SpliceKit_scenePrimarySpineCandidates(id primaryObj) {
    NSMutableArray *list = [NSMutableArray array];
    if (!primaryObj) return list;
    NSArray *items = SpliceKit_mixerArrayFromContainer(
        [primaryObj respondsToSelector:@selector(containedItems)]
            ? ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems)) : nil);
    for (id item in items) {
        CMTimeRange range;
        if (!SpliceKit_tryReadTimelineRange(primaryObj, item, &range)) continue;
        double start = SpliceKit_secondsFromTime(range.start);
        double end = start + SpliceKit_secondsFromTime(range.duration);
        [list addObject:@{
            @"handle": SpliceKit_storeHandle(item) ?: @"",
            @"name": SpliceKit_displayNameForItem(item),
            @"start": @(start),
            @"end": @(end),
        }];
    }
    return list;
}

// Single source media file for scene detection (no compound/multicam descent).
static NSURL *SpliceKit_sceneMediaURLForClip(id item, NSString **outError) {
    if (outError) *outError = nil;
    if (!item) {
        if (outError) *outError = @"nil clip";
        return nil;
    }
    BOOL hasVideo = SpliceKit_boolForSelector(item, @"hasVideo");
    BOOL hasAudio = SpliceKit_boolForSelector(item, @"hasAudio");
    NSString *kind = SpliceKit_clipInfoKindForItem(item, hasVideo, hasAudio);
    NSString *containerKind = ([kind isEqualToString:@"compound clip"]
                               || [kind isEqualToString:@"reference clip"]
                               || [kind isEqualToString:@"multicam clip"]) ? kind : nil;
    if (containerKind) {
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"no single source media file: this is a %@. Pass handle to a specific inner clip, "
                @"or fileURL to analyse a file directly",
                containerKind];
        }
        return nil;
    }
    int mediaDepth = -1;
    id mediaComp = SpliceKit_clipInfoMediaComponentWithDepth(item, &mediaDepth);
    if (mediaDepth >= 2) {
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"no single source media file: the first media file inside this clip sits %d levels "
                @"down inside nested containers; pass handle to a specific clip or fileURL",
                mediaDepth];
        }
        return nil;
    }
    NSURL *url = SpliceKit_clipInfoMediaURL(mediaComp ?: item, NULL, NULL);
    if (!url && outError) *outError = @"No video media file found for this clip.";
    return url;
}

NSDictionary *SpliceKit_handleDetectSceneChanges(NSDictionary *params) {
    // Get parameters
    double threshold = [params[@"threshold"] doubleValue] ?: 0.35;
    double sampleInterval = [params[@"sampleInterval"] doubleValue] ?: 0.1; // check every 0.1s
    NSString *action = params[@"action"] ?: @"detect"; // "detect", "markers", "blade"

    NSString *urlStr = [params[@"fileURL"] isKindOfClass:[NSString class]] ? params[@"fileURL"] : nil;
    BOOL fileURLMode = (urlStr.length > 0);
    NSString *handleParam = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    if (handleParam.length == 0) handleParam = nil;

    if (fileURLMode && handleParam) {
        return @{@"error": @"Pass either handle (timeline clip) or fileURL (direct file analysis), not both."};
    }
    if (fileURLMode && ([action isEqualToString:@"markers"] || [action isEqualToString:@"blade"])) {
        return @{@"error":
            @"Cannot place markers or blade when analysing fileURL directly: there is no timeline clip "
            @"to map source-media times onto. Open a project, pass handle to a timeline clip, or use "
            @"detect_scene_changes() with file_url only to list cuts in the file."};
    }

    __block NSURL *mediaURL = fileURLMode ? [NSURL fileURLWithPath:urlStr] : nil;
    __block id targetClip = nil;
    __block NSString *clipHandle = nil;
    __block NSString *clipName = nil;
    __block double clipTimelineStart = 0.0;
    __block double clipTimelineEnd = 0.0;
    __block double fileStartSeconds = 0.0;
    __block double clipSourceStartSeconds = 0.0;
    __block BOOL clipSourceStartKnown = NO;
    __block NSString *mediaResolveError = nil;
    __block NSArray *spineCandidates = nil;

    if (!fileURLMode) {
        SpliceKit_executeOnMainThread(^{
            @try {
                id timeline = SpliceKit_getActiveTimelineModule();
                if (!timeline) {
                    mediaResolveError = @"No active timeline module. Is a project open?";
                    return;
                }
                id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
                if (!sequence) {
                    mediaResolveError = @"No sequence in timeline.";
                    return;
                }
                id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                    ? ((id (*)(id, SEL))objc_msgSend)(sequence, NSSelectorFromString(@"primaryObject")) : nil;
                spineCandidates = SpliceKit_scenePrimarySpineCandidates(primaryObj);

                if (handleParam) {
                    targetClip = SpliceKit_resolveHandle(handleParam);
                    if (!targetClip) {
                        mediaResolveError = [NSString stringWithFormat:
                            @"handle %@ does not resolve to an object (get_timeline_clips() gives fresh handles)",
                            handleParam];
                        return;
                    }
                } else {
                    NSArray *selected = SpliceKit_handleSelectionCurrentItems(timeline);
                    if (selected.count == 1) {
                        targetClip = selected[0];
                    } else if (selected.count > 1) {
                        mediaResolveError =
                            @"More than one clip is selected. Select exactly one clip, pass handle, "
                            @"or position the playhead on a primary storyline clip.";
                        return;
                    } else {
                        double phStart = 0, phEnd = 0;
                        targetClip = SpliceKit_scenePrimaryClipAtPlayhead(timeline, primaryObj, &phStart, &phEnd);
                        if (targetClip) {
                            clipTimelineStart = phStart;
                            clipTimelineEnd = phEnd;
                        }
                    }
                }

                if (!targetClip) {
                    NSMutableString *msg = [NSMutableString stringWithString:
                        @"Could not determine which clip to analyse. Pass handle, select exactly one clip, "
                        @"or position the playhead on a primary storyline clip."];
                    if (spineCandidates.count > 0) {
                        [msg appendString:@" Primary storyline:"];
                        for (NSDictionary *c in spineCandidates) {
                            [msg appendFormat:@" \"%@\" %@ %.3f-%.3fs;",
                             c[@"name"] ?: @"", c[@"handle"] ?: @"",
                             [c[@"start"] doubleValue], [c[@"end"] doubleValue]];
                        }
                    }
                    mediaResolveError = msg;
                    return;
                }

                clipHandle = SpliceKit_storeHandle(targetClip) ?: @"";
                clipName = SpliceKit_displayNameForItem(targetClip);

                if (clipTimelineEnd <= clipTimelineStart) {
                    CMTimeRange range;
                    if (primaryObj && SpliceKit_tryReadTimelineRange(primaryObj, targetClip, &range)) {
                        clipTimelineStart = SpliceKit_secondsFromTime(range.start);
                        clipTimelineEnd = clipTimelineStart + SpliceKit_secondsFromTime(range.duration);
                    }
                }

                NSDictionary *audioSrc = SpliceKit_audioSourceForItem(targetClip);
                if (audioSrc[@"fileStart"]) {
                    fileStartSeconds = [audioSrc[@"fileStart"] doubleValue];
                }
                clipSourceStartKnown = [audioSrc[@"sourceStartKnown"] boolValue];
                if (clipSourceStartKnown) {
                    clipSourceStartSeconds = [audioSrc[@"sourceStart"] doubleValue];
                }

                NSString *clipMediaError = nil;
                mediaURL = SpliceKit_sceneMediaURLForClip(targetClip, &clipMediaError);
                if (!mediaURL) {
                    mediaResolveError = clipMediaError ?: @"No media file found for the resolved clip.";
                }
            } @catch (NSException *e) {
                mediaResolveError = [NSString stringWithFormat:@"Exception resolving clip: %@", e.reason];
            }
        });
        if (mediaResolveError) {
            NSMutableDictionary *err = [@{@"error": mediaResolveError} mutableCopy];
            if (spineCandidates.count > 0) err[@"candidates"] = spineCandidates;
            return err;
        }
    }

    if (!mediaURL) {
        return @{@"error": @"No media file found. Open a project with media on the timeline or pass fileURL."};
    }

    SpliceKit_log(@"Scene detection starting on: %@ (threshold=%.2f, interval=%.2fs)",
                  mediaURL.path, threshold, sampleInterval);

    // Run scene detection synchronously on this thread (called from background)
    AVAsset *asset = [AVAsset assetWithURL:mediaURL];
    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error || !reader) {
        return @{@"error": [NSString stringWithFormat:@"Cannot read media: %@", error.localizedDescription]};
    }

    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
        return @{@"error": @"No video track in media file"};
    }

    AVAssetTrack *videoTrack = videoTracks[0];
    NSDictionary *outputSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:videoTrack outputSettings:outputSettings];
    output.alwaysCopiesSampleData = NO;
    [reader addOutput:output];

    if (!fileURLMode && targetClip) {
        double clipDuration = clipTimelineEnd - clipTimelineStart;
        if (isfinite(fileStartSeconds) && isfinite(clipDuration) && clipDuration > 0.0
            && fileStartSeconds >= 0.0) {
            CMTime rangeStart = CMTimeMakeWithSeconds(fileStartSeconds, 600);
            CMTime rangeDuration = CMTimeMakeWithSeconds(clipDuration, 600);
            reader.timeRange = CMTimeRangeMake(rangeStart, rangeDuration);
            SpliceKit_log(@"Scene detection: limiting decode to file %.3f-%.3fs (clip timeline %.3f-%.3fs)",
                          fileStartSeconds, fileStartSeconds + clipDuration,
                          clipTimelineStart, clipTimelineEnd);
        }
    }

    if (![reader startReading]) {
        return @{@"error": [NSString stringWithFormat:@"Cannot start reading: %@", reader.error.localizedDescription]};
    }

    // Histogram comparison for scene detection
    double duration = CMTimeGetSeconds(asset.duration);
    double frameRate = videoTrack.nominalFrameRate;
    int framesPerSample = (int)(frameRate * sampleInterval);
    if (framesPerSample < 1) framesPerSample = 1;

    vImagePixelCount prevHistR[256] = {0}, prevHistG[256] = {0}, prevHistB[256] = {0};
    BOOL hasPrevHist = NO;
    NSMutableArray *sceneChanges = [NSMutableArray array];
    int frameIndex = 0;
    int sampledFrames = 0;

    while (reader.status == AVAssetReaderStatusReading) {
        @autoreleasepool {
            CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
            if (!sampleBuffer) break;

            frameIndex++;
            // Only analyze every Nth frame
            if (frameIndex % framesPerSample != 0) {
                CFRelease(sampleBuffer);
                continue;
            }
            sampledFrames++;

            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            double timeSec = CMTimeGetSeconds(pts);

            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!imageBuffer) {
                CFRelease(sampleBuffer);
                continue;
            }

            CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

            size_t width = CVPixelBufferGetWidth(imageBuffer);
            size_t height = CVPixelBufferGetHeight(imageBuffer);
            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
            void *baseAddr = CVPixelBufferGetBaseAddress(imageBuffer);

            vImage_Buffer buf = { baseAddr, (vImagePixelCount)height, (vImagePixelCount)width, bytesPerRow };

            // Compute ARGB histogram (BGRA in memory, but histogram bins are still useful)
            vImagePixelCount *histPtrs[4];
            vImagePixelCount histA[256] = {0}, histR[256] = {0}, histG[256] = {0}, histB[256] = {0};
            histPtrs[0] = histB; // B channel (BGRA byte order)
            histPtrs[1] = histG;
            histPtrs[2] = histR;
            histPtrs[3] = histA;
            vImageHistogramCalculation_ARGB8888(&buf, histPtrs, kvImageNoFlags);

            if (hasPrevHist) {
                // Compare histograms: normalized absolute difference
                double totalPixels = (double)(width * height);
                double diffR = 0, diffG = 0, diffB = 0;
                for (int i = 0; i < 256; i++) {
                    diffR += fabs((double)histR[i] - (double)prevHistR[i]);
                    diffG += fabs((double)histG[i] - (double)prevHistG[i]);
                    diffB += fabs((double)histB[i] - (double)prevHistB[i]);
                }
                double normalizedDiff = (diffR + diffG + diffB) / (3.0 * totalPixels);

                if (normalizedDiff > threshold) {
                    [sceneChanges addObject:@{
                        @"time": @(timeSec),
                        @"score": @(normalizedDiff),
                    }];
                    SpliceKit_log(@"Scene change at %.2fs (score=%.3f)", timeSec, normalizedDiff);
                }
            }

            // Store current histogram as previous
            memcpy(prevHistR, histR, sizeof(prevHistR));
            memcpy(prevHistG, histG, sizeof(prevHistG));
            memcpy(prevHistB, histB, sizeof(prevHistB));
            hasPrevHist = YES;

            CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
            CFRelease(sampleBuffer);
        }
    }

    [reader cancelReading];

    SpliceKit_log(@"Scene detection complete: %lu changes found in %.1fs (%d frames sampled)",
                  (unsigned long)sceneChanges.count, duration, sampledFrames);

    NSMutableDictionary *baseResult = [@{
        @"sceneChanges": sceneChanges,
        @"count": @(sceneChanges.count),
        @"duration": @(duration),
        @"threshold": @(threshold),
        @"action": action,
        @"mediaFile": mediaURL.lastPathComponent ?: @"",
        @"sourceTimesAreMediaFile": @YES,
    } mutableCopy];
    if (targetClip) {
        baseResult[@"clipHandle"] = clipHandle ?: @"";
        baseResult[@"clipName"] = clipName ?: @"";
        baseResult[@"clipTimelineStart"] = @(clipTimelineStart);
        baseResult[@"clipTimelineEnd"] = @(clipTimelineEnd);
        baseResult[@"fileStart"] = @(fileStartSeconds);
    }

    // If action is "markers" or "blade", apply at timeline times mapped from source file times
    if (([action isEqualToString:@"markers"] || [action isEqualToString:@"blade"]) && sceneChanges.count > 0) {
        if (!targetClip) {
            baseResult[@"error"] =
                @"Cannot apply markers or blade without a timeline clip (fileURL-only analysis has no mapping).";
            return baseResult;
        }

        __block NSInteger applied = 0;
        __block NSInteger skippedOutsideClip = 0;
        __block BOOL sceneOpenedUndoGroup = NO;
        NSString *sceneUndoGroupName = [action isEqualToString:@"blade"]
            ? @"Blade Scene Changes" : @"Mark Scene Changes";
        id clipForApply = targetClip;
        double mapClipStart = clipTimelineStart;
        double mapClipEnd = clipTimelineEnd;
        double mapFileStart = fileStartSeconds;
        double mapClipSourceStart = clipSourceStartSeconds;
        BOOL mapClipSourceStartKnown = clipSourceStartKnown;

        SpliceKit_executeOnMainThread(^{
            id timeline = nil;
            id sequence = nil;
            NSString *undoGroupName = sceneUndoGroupName;
            BOOL openedUndoGroup = NO;
            @try {
                timeline = SpliceKit_getActiveTimelineModule();
                if (!timeline) return;
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
                if (!sequence) return;

                openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoGroupName);
                sceneOpenedUndoGroup = openedUndoGroup;

                CMTime frameDur = {1, 30, 1, 0};
                SEL fdSel = NSSelectorFromString(@"frameDuration");
                if ([sequence respondsToSelector:fdSel]) {
                    frameDur = ((CMTime (*)(id, SEL))STRET_MSG)(sequence, fdSel);
                }
                int32_t ts = (frameDur.timescale > 0) ? frameDur.timescale : 600;

                if ([action isEqualToString:@"markers"]) {
                    SEL addSel = NSSelectorFromString(@"actionAddMarkerToAnchoredObject:isToDo:isChapter:withRange:error:");
                    if (![sequence respondsToSelector:addSel]) {
                        SpliceKit_log(@"Scene detection: sequence does not respond to actionAddMarkerToAnchoredObject:");
                        return;
                    }

                    typedef BOOL (*AddMarkerFn)(id, SEL, id, BOOL, BOOL, CMTimeRange, NSError **);
                    AddMarkerFn addMarker = (AddMarkerFn)objc_msgSend;

                    for (NSDictionary *sc in sceneChanges) {
                        double fileTime = [sc[@"time"] doubleValue];
                        double timelineTime = mapClipStart + (fileTime - mapFileStart);
                        if (timelineTime < mapClipStart - 0.001 || timelineTime > mapClipEnd + 0.001) {
                            skippedOutsideClip++;
                            continue;
                        }
                        // actionAddMarkerToAnchoredObject: range.start is SOURCE MEDIA time (measured):
                        // timeline = range.start - clipSourceStart + clipTimelineStart.
                        // Detection times are media-file seconds; range.start = clipSourceStart + (fileTime - fileStart).
                        double clipSourceStart = mapClipSourceStartKnown ? mapClipSourceStart : 0.0;
                        double rangeStartSeconds = clipSourceStart + (fileTime - mapFileStart);
                        CMTime markerTime = {(int64_t)llround(rangeStartSeconds * ts), ts, 1, 0};
                        CMTimeRange range = {markerTime, frameDur};
                        NSError *err = nil;
                        BOOL ok = addMarker(sequence, addSel, clipForApply, NO, NO, range, &err);
                        if (ok) applied++;
                        else SpliceKit_log(@"Scene marker failed at file %.2fs / tl %.2fs: %@", fileTime, timelineTime, err);
                    }
                } else {
                    for (NSDictionary *sc in sceneChanges) {
                        double fileTime = [sc[@"time"] doubleValue];
                        double timelineTime = mapClipStart + (fileTime - mapFileStart);
                        if (timelineTime < mapClipStart - 0.001 || timelineTime > mapClipEnd + 0.001) {
                            skippedOutsideClip++;
                            continue;
                        }
                        // Blade seeks the playhead; needs absolute timeline seconds, not clip-local.
                        SpliceKit_handlePlaybackSeek(@{@"seconds": @(timelineTime)});
                        [NSThread sleepForTimeInterval:0.03];
                        SpliceKit_handleTimelineAction(@{@"action": @"blade"});
                        applied++;
                    }
                }
            } @catch (NSException *e) {
                SpliceKit_log(@"Scene action error: %@", e.reason);
            } @finally {
                if (openedUndoGroup) {
                    SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoGroupName, YES);
                }
            }
        });

        baseResult[@"applied"] = @(applied);
        baseResult[@"skippedOutsideClip"] = @(skippedOutsideClip);
        if (applied > 0 && sceneOpenedUndoGroup) {
            baseResult[@"undoStep"] = sceneUndoGroupName;
        }
    }

    return baseResult;
}
