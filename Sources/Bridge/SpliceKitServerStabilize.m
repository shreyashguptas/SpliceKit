//
//  SpliceKitServerStabilize.m
//  SpliceKit - Subject stabilization (lock-on): tracking a subject and keyframing the
//  transform to hold it in place.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Subject Stabilization (Lock-On)
//
// Uses Apple's Vision framework to track a person in a clip, then applies
// inverse position/scale keyframes to keep the subject centered. Think of it
// as a "lock-on" camera that stabilizes around the detected subject.
//

NSDictionary *SpliceKit_handleSubjectStabilize(NSDictionary *params) {
    // Stabilize the selected clip around a tracked subject.
    // The subject stays fixed on screen while the background moves.
    //
    // Flow:
    // 1. Get selected clip and its media URL
    // 2. Get playhead time as the reference frame (where subject is)
    // 3. Use Vision framework to detect and track the subject
    // 4. Compute inverse position deltas per frame
    // 5. Apply position keyframes on the clip's FFHeXFormEffect

    __block NSDictionary *result = nil;
    __block id selectedClip = nil;
    __block id timelineModule = nil;
    __block double playheadTime = 0;
    __block double clipStart = 0;
    __block double clipDuration = 0;
    __block double localStart = 0;      // the clip's clippedRange start (effect keyframe time)
    __block double fileStart = 0;       // seconds into the media file where the clip starts
    __block double conformFactor = 1.0; // timeline seconds per file second (rate conform)
    __block NSDictionary *source = nil;
    __block NSURL *mediaURL = nil;
    __block double frameRate = 24.0;
    __block id hexFormEffect = nil;
    __block id effectStack = nil;
    __block BOOL undoRegistered = NO;

    // Step 1: Get selected clip info on main thread
    SpliceKit_executeOnMainThread(^{
        @try {
            timelineModule = SpliceKit_getActiveTimelineModule();
            if (!timelineModule) {
                result = @{@"error": @"No active timeline"};
                return;
            }

            // Get frame rate
            if ([timelineModule respondsToSelector:@selector(sequenceFrameDuration)]) {
                CMTime fd;
                NSMethodSignature *sig = [timelineModule methodSignatureForSelector:@selector(sequenceFrameDuration)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:timelineModule];
                [inv setSelector:@selector(sequenceFrameDuration)];
                [inv invoke];
                [inv getReturnValue:&fd];
                if (fd.timescale > 0 && fd.value > 0) {
                    frameRate = (double)fd.timescale / fd.value;
                }
            }

            // Playhead, in the same timeline seconds get_playhead_position and the clip
            // placement below use.
            BOOL havePlayhead = NO;
            for (NSString *name in @[@"playheadTime", @"currentSequenceTime"]) {
                CMTime t = {0, 0, 0, 0};
                if (SpliceKit_tryReadCMTimeSelector(timelineModule, name, &t) && t.timescale > 0) {
                    playheadTime = SpliceKit_secondsFromTime(t);
                    havePlayhead = YES;
                    break;
                }
            }
            (void)havePlayhead;

            // Get selected items
            SEL selSel = NSSelectorFromString(@"selectedItems");
            NSArray *items = nil;
            if ([timelineModule respondsToSelector:selSel]) {
                items = ((id (*)(id, SEL))objc_msgSend)(timelineModule, selSel);
            }
            if (!items || items.count == 0) {
                result = @{@"error": @"No clip selected. Select a clip first."};
                return;
            }
            selectedClip = items[0];

            // Where the clip sits and which part of which file it plays: the same readings
            // timeline.getClipInfo and timeline.getAudioLevels use. The clip's placement comes
            // from the sequence (-effectiveRangeOfObject:, or the connected-clip walk for a clip
            // anchored above or below the primary storyline); its source media file and the
            // seconds into that file where the clip starts come from SpliceKit_audioSourceForItem.
            // This handler used to read -timelineStartTime and -trimStartTime itself. On FCP 12.3
            // a connected clip answers -timelineStartTime with 0 (relative to its parent), so the
            // reference time became the playhead's absolute time: 42 s into a 20 s screen
            // recording, which AVFoundation answers with "Cannot Open".
            id sequence = [timelineModule respondsToSelector:@selector(sequence)]
                ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence)) : nil;
            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
            CMTimeRange placement = {{0, 0, 0, 0}, {0, 0, 0, 0}};
            NSString *placementError = nil;
            NSString *clipHandle = SpliceKit_storeHandle(selectedClip);
            if (!primaryObj || !SpliceKit_handleResolveTimelineClip(clipHandle, primaryObj, &placement, &placementError) ||
                placement.start.timescale <= 0 || placement.duration.timescale <= 0) {
                result = @{@"error": [NSString stringWithFormat:
                    @"Could not read where the selected clip sits on the timeline%@",
                    placementError.length ? [@": " stringByAppendingString:placementError] : @""]};
                return;
            }
            clipStart = SpliceKit_secondsFromTime(placement.start);
            clipDuration = SpliceKit_secondsFromTime(placement.duration);

            // The clip's own time (FCP's clippedRange), the time its effect keyframes are in.
            CMTimeRange localRange = {{0, 0, 0, 0}, {0, 0, 0, 0}};
            if (SpliceKit_tryReadCMTimeRangeSelector(selectedClip, @"clippedRange", &localRange) &&
                localRange.start.timescale > 0) {
                localStart = SpliceKit_secondsFromTime(localRange.start);
            }

            source = SpliceKit_audioSourceForItem(selectedClip);
            NSString *path = [source[@"path"] isKindOfClass:[NSString class]] ? source[@"path"] : nil;
            if (path.length) mediaURL = [NSURL fileURLWithPath:path];
            fileStart = [source[@"fileStart"] respondsToSelector:@selector(doubleValue)]
                ? [source[@"fileStart"] doubleValue] : 0.0;
            if ([source[@"rateConformFactor"] respondsToSelector:@selector(doubleValue)]) {
                double f = [source[@"rateConformFactor"] doubleValue];
                if (isfinite(f) && f > 0) conformFactor = f;
            }
            SpliceKit_log(@"[Stabilize] Selected clip class: %@ at %.3f-%.3f s, media: %@, file start %.3f s (via %@)",
                NSStringFromClass([selectedClip class]), clipStart, clipStart + clipDuration,
                mediaURL ? mediaURL.path : @"nil", fileStart, source[@"sourceStartSelector"] ?: @"none");

            // Get FFHeXFormEffect via FFCutawayEffects.transformEffectForObject:createIfAbsent:
            // This is FCP's own way to get/create the transform effect on any clip type.
            @try {
                Class cutawayEffects = objc_getClass("FFCutawayEffects");
                if (cutawayEffects) {
                    SEL tfSel = NSSelectorFromString(@"transformEffectForObject:createIfAbsent:");
                    hexFormEffect = ((id (*)(Class, SEL, id, BOOL))objc_msgSend)(
                        cutawayEffects, tfSel, selectedClip, YES);
                }
            } @catch (NSException *e) {}

            // Fallback: try representedToolObject.videoEffects chain directly
            if (!hexFormEffect) {
                @try {
                    id toolObj = selectedClip;
                    if ([selectedClip respondsToSelector:NSSelectorFromString(@"representedToolObject")]) {
                        toolObj = ((id (*)(id, SEL))objc_msgSend)(selectedClip, NSSelectorFromString(@"representedToolObject"));
                    }
                    if ([toolObj respondsToSelector:NSSelectorFromString(@"videoEffects")]) {
                        id vidEffects = ((id (*)(id, SEL))objc_msgSend)(toolObj, NSSelectorFromString(@"videoEffects"));
                        if (vidEffects) {
                            // Try intrinsicEffectWithID:createIfAbsent: with known transform ID
                            SEL ieSel = NSSelectorFromString(@"intrinsicEffectWithID:createIfAbsent:");
                            if ([vidEffects respondsToSelector:ieSel]) {
                                // The transform effect ID is "FFHeXFormEffect" or similar constant
                                for (NSString *eid in @[@"FFHeXFormEffect", @"transform", @"Transform"]) {
                                    hexFormEffect = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                                        vidEffects, ieSel, eid, YES);
                                    if (hexFormEffect) break;
                                }
                            }
                            // Also try heXFormEffect accessor
                            if (!hexFormEffect && [vidEffects respondsToSelector:NSSelectorFromString(@"heXFormEffect")]) {
                                hexFormEffect = ((id (*)(id, SEL))objc_msgSend)(vidEffects, NSSelectorFromString(@"heXFormEffect"));
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }
            // The effect stack owns the undo scope for parameter changes (see step 4).
            @try {
                id stackClip = nil;
                effectStack = SpliceKit_getSelectedClipEffectStack(timelineModule, &stackClip);
            } @catch (NSException *e) {}

            SpliceKit_log(@"[Stabilize] heXFormEffect: %@ (class: %@) effectStack: %@",
                hexFormEffect ? @"found" : @"nil",
                hexFormEffect ? NSStringFromClass([hexFormEffect class]) : @"n/a",
                effectStack ? @"found" : @"nil");

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception getting clip info: %@", e.reason]};
        }
    });

    if (result) return result;

    NSString *kind = [source[@"kind"] isKindOfClass:[NSString class]] ? source[@"kind"] : @"";
    if (!mediaURL) {
        if ([source[@"isCollection"] boolValue] && [kind containsString:@"compound"]) {
            return @{@"error": @"The selected clip is a compound clip with no single source media file; open it (Clip > Open Clip) and stabilize a clip inside it"};
        }
        return @{@"error": [NSString stringWithFormat:
            @"The selected clip (%@) has no source media file to track (a title, generator or gap clip has none)",
            kind.length ? kind : NSStringFromClass([selectedClip class])]};
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:mediaURL.path]) {   // off the main thread
        return @{@"error": [NSString stringWithFormat:
            @"The selected clip's source media file is missing on disk (Final Cut Pro: Missing File): %@", mediaURL.path]};
    }
    if (!hexFormEffect) {
        return @{@"error": [NSString stringWithFormat:
            @"Could not find transform effect on clip (class: %@, media: %@)",
            NSStringFromClass([selectedClip class]),
            mediaURL ? mediaURL.lastPathComponent : @"nil"]};
    }
    if (!(clipDuration > 0)) {
        return @{@"error": @"The selected clip has no duration on the timeline"};
    }

    // Step 2: Use Vision framework to track subject
    AVAsset *asset = [AVAsset assetWithURL:mediaURL];
    NSArray *videoTracksForAsset = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!asset || videoTracksForAsset.count == 0) {
        return @{@"error": [NSString stringWithFormat:
            @"The selected clip's source media file has no video track to track a subject in: %@", mediaURL.lastPathComponent]};
    }
    double assetDuration = CMTimeGetSeconds(asset.duration);
    double fileDuration = clipDuration / conformFactor;
    double fileEnd = fileStart + fileDuration;
    // The file range the clip plays, from FCP's readings (get_clip_info shows the same
    // numbers). A range that misses the file cannot be tracked; say so with the readings
    // instead of handing AVFoundation a time it answers with "Cannot Open".
    if (fileEnd <= 0.0 || (isfinite(assetDuration) && assetDuration > 0 && fileStart >= assetDuration)) {
        return @{@"error": [NSString stringWithFormat:
            @"The selected clip's range (%.3f-%.3f s into %@, a %.3f s file) lies outside its media file, from "
            @"SpliceKit's readings of FCP's clip object (source start %.3f s via %@, media origin %.3f s via %@; "
            @"get_clip_info shows the same): there are no frames of this clip to track",
            fileStart, fileEnd, mediaURL.lastPathComponent, assetDuration,
            [source[@"sourceStart"] doubleValue], source[@"sourceStartSelector"] ?: @"none",
            [source[@"mediaOrigin"] doubleValue], source[@"mediaOriginSelector"] ?: @"none"]};
    }
    double readStart = fmax(0.0, fileStart);
    double readEnd = (isfinite(assetDuration) && assetDuration > 0) ? fmin(fileEnd, assetDuration) : fileEnd;

    // The reference frame is the one under the playhead when the playhead is over the
    // clip; otherwise the clip's first frame, and the answer says so.
    double clipEnd = clipStart + clipDuration;
    BOOL playheadOverClip = (playheadTime >= clipStart - 0.0005 && playheadTime < clipEnd - 0.0005);
    double referenceTimelineTime = playheadOverClip ? playheadTime : clipStart;
    double sourceTime = fileStart + (referenceTimelineTime - clipStart) / conformFactor;
    if (sourceTime < readStart) sourceTime = readStart;
    if (sourceTime > readEnd - 0.001) sourceTime = fmax(readStart, readEnd - 0.001);
    CMTime refTime = CMTimeMakeWithSeconds(sourceTime, 600);

    SpliceKit_log(@"[Stabilize] Clip: %@ (timeline %.3f-%.3f, file %.3f-%.3f of %.3f, reference %.3f -> file %.3f, local start %.3f, fps %.3f)",
        mediaURL.lastPathComponent, clipStart, clipEnd, fileStart, fileEnd, assetDuration,
        referenceTimelineTime, sourceTime, localStart, frameRate);

    // Generate reference frame. Half a frame of tolerance either side: exact-time requests
    // on long-GOP files can come back empty between frames.
    AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    CMTime halfFrame = CMTimeMakeWithSeconds(0.5 / fmax(frameRate, 1.0), 600000);
    gen.requestedTimeToleranceBefore = halfFrame;
    gen.requestedTimeToleranceAfter = halfFrame;

    NSError *imgErr = nil;
    CGImageRef refImage = [gen copyCGImageAtTime:refTime actualTime:nil error:&imgErr];
    if (!refImage) {
        return @{@"error": [NSString stringWithFormat:@"Could not read the reference frame at %.3f s into %@: %@",
                            sourceTime, mediaURL.lastPathComponent, imgErr.localizedDescription ?: @"unknown error"]};
    }

    size_t imgWidth = CGImageGetWidth(refImage);
    size_t imgHeight = CGImageGetHeight(refImage);

    // Use Vision to detect the subject at the reference frame
    // Default: track center region (40% of frame) if no specific subject
    CGRect initialBBox = CGRectMake(0.3, 0.3, 0.4, 0.4); // normalized, center region
    NSString *subject = @"center region";

    // Try to detect a person/face first
    Class vnDetectReq = NSClassFromString(@"VNDetectHumanRectanglesRequest");
    if (vnDetectReq) {
        id request = [[vnDetectReq alloc] init];
        Class vnHandler = NSClassFromString(@"VNImageRequestHandler");
        id handler = ((id (*)(id, SEL, CGImageRef, id))objc_msgSend)(
            [vnHandler alloc], NSSelectorFromString(@"initWithCGImage:options:"), refImage, @{});
        NSError *vnErr = nil;
        ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
            handler, NSSelectorFromString(@"performRequests:error:"), @[request], &vnErr);
        NSArray *results = ((id (*)(id, SEL))objc_msgSend)(request, @selector(results));
        if (results.count > 0) {
            id obs = results[0];
            CGRect bbox = ((CGRect (*)(id, SEL))STRET_MSG)(obs, NSSelectorFromString(@"boundingBox"));
            initialBBox = bbox;
            subject = @"person";
            SpliceKit_log(@"[Stabilize] Detected human at (%.2f, %.2f, %.2f, %.2f)",
                bbox.origin.x, bbox.origin.y, bbox.size.width, bbox.size.height);
        }
    }

    CGImageRelease(refImage);

    // Step 3: Track the subject across all frames using VNTrackObjectRequest
    SpliceKit_log(@"[Stabilize] Tracking subject across %.1fs of video...", clipDuration);

    // Track center of initial bbox as reference point
    double refCenterX = initialBBox.origin.x + initialBBox.size.width / 2.0;
    double refCenterY = initialBBox.origin.y + initialBBox.size.height / 2.0;

    // Read frames and track
    AVAssetReader *reader = nil;
    @try {
        NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count == 0) {
            return @{@"error": @"No video track in media"};
        }
        AVAssetTrack *videoTrack = videoTracks[0];

        // Only the part of the file the clip plays.
        CMTime startCM = CMTimeMakeWithSeconds(readStart, 600);
        CMTime durCM = CMTimeMakeWithSeconds(readEnd - readStart, 600);
        CMTimeRange range = CMTimeRangeMake(startCM, durCM);

        reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        reader.timeRange = range;

        NSDictionary *outputSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:videoTrack outputSettings:outputSettings];
        output.alwaysCopiesSampleData = NO;
        [reader addOutput:output];
        [reader startReading];

    } @catch (NSException *e) {
        return @{@"error": [NSString stringWithFormat:@"Failed to read video: %@", e.reason]};
    }

    // Collect position deltas per frame
    NSMutableArray *frameDeltas = [NSMutableArray array]; // [{time, dx, dy}]
    AVAssetReaderOutput *output = reader.outputs.firstObject;

    Class vnTrackReqClass = NSClassFromString(@"VNTrackObjectRequest");
    Class vnSeqHandler = NSClassFromString(@"VNSequenceRequestHandler");

    if (!vnTrackReqClass || !vnSeqHandler) {
        return @{@"error": @"Vision tracking not available"};
    }

    id observation = nil;
    // Create initial observation from bbox
    Class vnDetectedObj = NSClassFromString(@"VNDetectedObjectObservation");
    observation = ((id (*)(Class, SEL, CGRect))objc_msgSend)(
        vnDetectedObj, NSSelectorFromString(@"observationWithBoundingBox:"), initialBBox);

    id sequenceHandler = [[vnSeqHandler alloc] init];
    int frameCount = 0;
    int totalFrames = (int)(clipDuration * frameRate);
    // One keyframe per timeline frame: a 60 fps file in a 29.97 fps project is tracked on
    // every file frame (tracking needs them) but keyframed at the project's rate.
    double keyframeSpacing = 1.0 / fmax(frameRate, 1.0);
    double lastKeyframeTime = -INFINITY;

    CMSampleBufferRef sampleBuffer;
    while ((sampleBuffer = [output copyNextSampleBuffer]) != NULL) {
        @autoreleasepool {
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            // Keyframe time in the clip's own time (clippedRange), where its effects live:
            // the clip's local start plus how far into the clip this frame plays.
            double frameTime = localStart + (CMTimeGetSeconds(pts) - fileStart) * conformFactor;

            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!pixelBuffer) {
                CFRelease(sampleBuffer);
                continue;
            }

            // Track the object in this frame
            id trackRequest = ((id (*)(id, SEL, id))objc_msgSend)(
                [vnTrackReqClass alloc],
                NSSelectorFromString(@"initWithDetectedObjectObservation:"), observation);
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                trackRequest, NSSelectorFromString(@"setTrackingLevel:"), 1); // Fast

            NSError *trackErr = nil;
            ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(
                sequenceHandler, NSSelectorFromString(@"performRequests:onCVPixelBuffer:error:"),
                @[trackRequest], (__bridge id)pixelBuffer, &trackErr);

            NSArray *trackResults = ((id (*)(id, SEL))objc_msgSend)(trackRequest, @selector(results));
            if (trackResults.count > 0) {
                observation = trackResults[0]; // Update observation for next frame
                CGRect bbox = ((CGRect (*)(id, SEL))STRET_MSG)(
                    observation, NSSelectorFromString(@"boundingBox"));
                double cx = bbox.origin.x + bbox.size.width / 2.0;
                double cy = bbox.origin.y + bbox.size.height / 2.0;

                // Delta from reference position (in normalized coordinates)
                double dx = cx - refCenterX;
                double dy = cy - refCenterY;

                if (frameTime - lastKeyframeTime >= keyframeSpacing * 0.95) {
                    lastKeyframeTime = frameTime;
                    [frameDeltas addObject:@{
                    @"time": @(frameTime),
                    @"dx": @(dx),    // normalized 0-1
                    @"dy": @(dy),
                    }];
                }
            }

            CFRelease(sampleBuffer);
            frameCount++;

            if (frameCount % 30 == 0) {
                SpliceKit_log(@"[Stabilize] Tracked frame %d/%d", frameCount, totalFrames);
            }
        }
    }

    [reader cancelReading];

    SpliceKit_log(@"[Stabilize] Tracked %d frames, got %lu position deltas",
        frameCount, (unsigned long)frameDeltas.count);

    if (frameDeltas.count == 0) {
        return @{@"error": @"No tracking data obtained"};
    }

    // Step 4: Apply inverse position keyframes
    __block NSUInteger keyframesSet = 0;

    // Step 4: Apply position keyframes through FCP's undo system
    SpliceKit_executeOnMainThread(^{
        @try {
            // Undo scope. The previous route asked the clip for -projectDocument and then
            // that document for -undoHandler; FFAnchoredClip has no -projectDocument on
            // FCP 12.3, so undoHandler was always nil and stabilize left nothing on the
            // undo stack. Effect-parameter changes are made undoable by the effect
            // stack's own action scope, which is what set_inspector_property uses.
            NSString *undoName = @"Stabilize Subject";
            @try {
                SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
                if (effectStack && [effectStack respondsToSelector:beginSel]) {
                    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                        effectStack, beginSel, undoName, nil, YES);
                    undoRegistered = YES;
                }
            } @catch (NSException *e) {}

            @try {

            // Set position keyframes using direct objc_msgSend with CMTime by value
            // CMTime is a 32-byte struct — on ARM64 it's passed in registers
            typedef void (*SetPixelPosFn)(id, SEL, CMTime, double, double, double, unsigned int);
            SetPixelPosFn setPixelPos = (SetPixelPosFn)objc_msgSend;
            SEL setPosSel = NSSelectorFromString(@"setPixelPositionAtTime:curveX:curveY:curveZ:options:");

            if ([hexFormEffect respondsToSelector:setPosSel]) {
                // Smooth the tracking data: apply a simple moving average to reduce jitter
                // and clamp maximum displacement to 15% of frame dimensions
                double maxDisplaceX = imgWidth * 0.15;
                double maxDisplaceY = imgHeight * 0.15;
                int windowSize = 5; // frames for smoothing

                for (NSUInteger fi = 0; fi < frameDeltas.count; fi++) {
                    // Moving average smoothing
                    double avgDx = 0, avgDy = 0;
                    int count = 0;
                    for (int w = -(windowSize/2); w <= (windowSize/2); w++) {
                        NSInteger idx = (NSInteger)fi + w;
                        if (idx >= 0 && idx < (NSInteger)frameDeltas.count) {
                            avgDx += [frameDeltas[idx][@"dx"] doubleValue];
                            avgDy += [frameDeltas[idx][@"dy"] doubleValue];
                            count++;
                        }
                    }
                    avgDx /= count;
                    avgDy /= count;

                    double time = [frameDeltas[fi][@"time"] doubleValue];

                    // Convert to pixels (inverse to stabilize)
                    double pixelDX = -avgDx * imgWidth;
                    double pixelDY = avgDy * imgHeight; // Vision Y is flipped vs FCP

                    // Clamp to prevent extreme shifts
                    if (pixelDX > maxDisplaceX) pixelDX = maxDisplaceX;
                    if (pixelDX < -maxDisplaceX) pixelDX = -maxDisplaceX;
                    if (pixelDY > maxDisplaceY) pixelDY = maxDisplaceY;
                    if (pixelDY < -maxDisplaceY) pixelDY = -maxDisplaceY;

                    CMTime cmTime = CMTimeMakeWithSeconds(time, (int32_t)(frameRate * 100));

                    setPixelPos(hexFormEffect, setPosSel, cmTime, pixelDX, pixelDY, 0.0, 0);
                    keyframesSet++;
                }
            }

            // Scale up slightly (105%) to hide edge movement from stabilization
            SEL setScaleSel = NSSelectorFromString(@"setScaleAtTime:curveX:curveY:curveZ:options:");
            if ([hexFormEffect respondsToSelector:setScaleSel]) {
                typedef void (*SetScaleFn)(id, SEL, CMTime, double, double, double, unsigned int);
                SetScaleFn setScale = (SetScaleFn)objc_msgSend;
                CMTime t0 = CMTimeMakeWithSeconds(localStart, (int32_t)(frameRate * 100));
                setScale(hexFormEffect, setScaleSel, t0, 1.05, 1.05, 1.0, 0);
            }

            // Verify: read back position at first keyframe time to confirm it stuck
            SEL getPosSel = NSSelectorFromString(@"getPixelPositionAtTime:x:y:z:");
            if (frameDeltas.count > 0 && [hexFormEffect respondsToSelector:getPosSel]) {
                double t0 = [frameDeltas[frameDeltas.count / 2][@"time"] doubleValue];
                CMTime checkTime = CMTimeMakeWithSeconds(t0, (int32_t)(frameRate * 100));

                typedef void (*GetPosFn)(id, SEL, CMTime, double*, double*, double*);
                GetPosFn getPos = (GetPosFn)objc_msgSend;
                double rx = 9999, ry = 9999, rz = 9999;
                getPos(hexFormEffect, getPosSel, checkTime, &rx, &ry, &rz);
                SpliceKit_log(@"[Stabilize] Verify: position at t=%.2f is (%.1f, %.1f, %.1f)", t0, rx, ry, rz);
                // Store for response
                objc_setAssociatedObject(hexFormEffect, "verifyX", @(rx), OBJC_ASSOCIATION_RETAIN);
                objc_setAssociatedObject(hexFormEffect, "verifyY", @(ry), OBJC_ASSOCIATION_RETAIN);
            }

            } @finally {
                // Always close the scope, including when a keyframe write throws:
                // an action left open wedges every later edit on this sequence.
                @try {
                    SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
                    if (undoRegistered && [effectStack respondsToSelector:endSel]) {
                        ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                            effectStack, endSel, undoName, YES, nil);
                    }
                } @catch (NSException *e) {}
            }

        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception applying keyframes: %@", e.reason]};
        }
    });

    if (result) return result;

    SpliceKit_log(@"[Stabilize] Applied %lu position keyframes + 105%% scale",
        (unsigned long)keyframesSet);

    // Collect some debug info about the deltas
    double maxDx = 0, maxDy = 0;
    for (NSDictionary *d in frameDeltas) {
        double adx = fabs([d[@"dx"] doubleValue]);
        double ady = fabs([d[@"dy"] doubleValue]);
        if (adx > maxDx) maxDx = adx;
        if (ady > maxDy) maxDy = ady;
    }

    BOOL hasSetPos = [hexFormEffect respondsToSelector:NSSelectorFromString(@"setPixelPositionAtTime:curveX:curveY:curveZ:options:")];
    BOOL hasOffsetPos = [hexFormEffect respondsToSelector:NSSelectorFromString(@"offsetPixelPositionAtTime:deltaX:deltaY:deltaZ:options:")];
    BOOL hasGetPos = [hexFormEffect respondsToSelector:NSSelectorFromString(@"getPixelPositionAtTime:x:y:z:")];
    BOOL hasSetScale = [hexFormEffect respondsToSelector:NSSelectorFromString(@"setScaleAtTime:curveX:curveY:curveZ:options:")];

    return @{
        @"status": @"ok",
        @"framesTracked": @(frameCount),
        @"keyframesApplied": @(keyframesSet),
        @"clipDuration": @(clipDuration),
        @"undoName": undoRegistered ? @"Stabilize Subject" : [NSNull null],
        @"undoRegistered": @(undoRegistered),
        @"subject": subject,
        @"subjectNote": [subject isEqualToString:@"person"]
            ? @"a person was detected at the reference frame and tracked"
            : @"no person was detected at the reference frame (Vision's human detector found none); the centre 40% of the frame was tracked instead",
        @"referenceFrame": @{
            @"timelineTime": @(referenceTimelineTime),
            @"fileTime": @(sourceTime),
            @"atPlayhead": @(playheadOverClip),
            @"note": playheadOverClip ? @"the frame under the playhead"
                : @"the playhead was not over the selected clip, so its first frame was used",
        },
        @"timeline": @{@"start": @(clipStart), @"end": @(clipEnd)},
        @"sourceMedia": @{@"path": mediaURL.path ?: @"", @"fileStart": @(readStart), @"fileEnd": @(readEnd)},
        @"referencePosition": @{
            @"x": @(refCenterX),
            @"y": @(refCenterY),
        },
        @"debug": @{
            @"effectClass": NSStringFromClass([hexFormEffect class]),
            @"maxDeltaX_normalized": @(maxDx),
            @"maxDeltaY_normalized": @(maxDy),
            @"maxDeltaX_pixels": @(maxDx * imgWidth),
            @"maxDeltaY_pixels": @(maxDy * imgHeight),
            @"imgSize": [NSString stringWithFormat:@"%zux%zu", imgWidth, imgHeight],
            @"hasSetPixelPosition": @(hasSetPos),
            @"hasOffsetPixelPosition": @(hasOffsetPos),
            @"hasGetPixelPosition": @(hasGetPos),
            @"hasSetScale": @(hasSetScale),
            @"verifyPosX": objc_getAssociatedObject(hexFormEffect, "verifyX") ?: @"n/a",
            @"verifyPosY": objc_getAssociatedObject(hexFormEffect, "verifyY") ?: @"n/a",
        },
    };
}
