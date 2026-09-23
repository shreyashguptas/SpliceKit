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
    __block double trimStart = 0;
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

            // Get playhead time
            SEL currentTimeSel = NSSelectorFromString(@"currentSequenceTime");
            if ([timelineModule respondsToSelector:currentTimeSel]) {
                CMTime t;
                NSMethodSignature *sig = [timelineModule methodSignatureForSelector:currentTimeSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:timelineModule];
                [inv setSelector:currentTimeSel];
                [inv invoke];
                [inv getReturnValue:&t];
                if (t.timescale > 0) playheadTime = (double)t.value / t.timescale;
            }

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

            // Get clip timeline start and duration
            if ([selectedClip respondsToSelector:@selector(timelineStartTime)]) {
                CMTime t;
                NSMethodSignature *sig = [selectedClip methodSignatureForSelector:@selector(timelineStartTime)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:selectedClip];
                [inv setSelector:@selector(timelineStartTime)];
                [inv invoke];
                [inv getReturnValue:&t];
                if (t.timescale > 0) clipStart = (double)t.value / t.timescale;
            }
            if ([selectedClip respondsToSelector:@selector(duration)]) {
                CMTime t;
                NSMethodSignature *sig = [selectedClip methodSignatureForSelector:@selector(duration)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:selectedClip];
                [inv setSelector:@selector(duration)];
                [inv invoke];
                [inv getReturnValue:&t];
                if (t.timescale > 0) clipDuration = (double)t.value / t.timescale;
            }

            // Get trim offset
            if ([selectedClip respondsToSelector:NSSelectorFromString(@"trimStartTime")]) {
                CMTime t;
                SEL tsSel = NSSelectorFromString(@"trimStartTime");
                NSMethodSignature *sig = [selectedClip methodSignatureForSelector:tsSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:selectedClip];
                [inv setSelector:tsSel];
                [inv invoke];
                [inv getReturnValue:&t];
                if (t.timescale > 0) trimStart = (double)t.value / t.timescale;
            }

            // Same resolver as timeline.getClipInfo (handles FCP 12.3 clipRef / media chains).
            id clipForMedia = selectedClip;
            if ([selectedClip respondsToSelector:NSSelectorFromString(@"containedItems")]) {
                NSArray *contained = ((id (*)(id, SEL))objc_msgSend)(selectedClip, NSSelectorFromString(@"containedItems"));
                if ([contained isKindOfClass:[NSArray class]] && contained.count > 0) {
                    for (id item in contained) {
                        NSString *cn = NSStringFromClass([item class]);
                        if ([cn containsString:@"MediaComponent"]) {
                            clipForMedia = item;
                            break;
                        }
                    }
                }
            }
            NSString *urlSource = nil;
            NSString *representation = nil;
            mediaURL = SpliceKit_clipInfoMediaURL(clipForMedia, &representation, &urlSource);
            if (!mediaURL) {
                mediaURL = SpliceKit_clipInfoMediaURL(selectedClip, &representation, &urlSource);
            }
            SpliceKit_log(@"[Stabilize] Selected clip class: %@, mediaURL: %@",
                NSStringFromClass([selectedClip class]), mediaURL ? mediaURL.path : @"nil");

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

    if (!mediaURL) {
        return @{@"error": @"Could not find media file for selected clip"};
    }
    if (!hexFormEffect) {
        return @{@"error": [NSString stringWithFormat:
            @"Could not find transform effect on clip (class: %@, media: %@)",
            NSStringFromClass([selectedClip class]),
            mediaURL ? mediaURL.lastPathComponent : @"nil"]};
    }

    SpliceKit_log(@"[Stabilize] Clip: %@ (start:%.2f dur:%.2f trim:%.2f playhead:%.2f fps:%.1f)",
        mediaURL.lastPathComponent, clipStart, clipDuration, trimStart, playheadTime, frameRate);

    // Step 2: Use Vision framework to track subject
    // Load the video and get the reference frame
    AVAsset *asset = [AVAsset assetWithURL:mediaURL];
    if (!asset) {
        return @{@"error": @"Could not load media asset"};
    }

    // The playhead time in source media coordinates
    double sourceTime = trimStart + (playheadTime - clipStart);
    CMTime refTime = CMTimeMakeWithSeconds(sourceTime, 600);

    // Generate reference frame
    AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter = kCMTimeZero;

    NSError *imgErr = nil;
    CGImageRef refImage = [gen copyCGImageAtTime:refTime actualTime:nil error:&imgErr];
    if (!refImage) {
        return @{@"error": [NSString stringWithFormat:@"Could not get reference frame: %@", imgErr.localizedDescription]};
    }

    size_t imgWidth = CGImageGetWidth(refImage);
    size_t imgHeight = CGImageGetHeight(refImage);

    // Use Vision to detect the subject at the reference frame
    // Default: track center region (40% of frame) if no specific subject
    CGRect initialBBox = CGRectMake(0.3, 0.3, 0.4, 0.4); // normalized, center region

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

        CMTime startCM = CMTimeMakeWithSeconds(trimStart, 600);
        CMTime durCM = CMTimeMakeWithSeconds(clipDuration, 600);
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

    CMSampleBufferRef sampleBuffer;
    while ((sampleBuffer = [output copyNextSampleBuffer]) != NULL) {
        @autoreleasepool {
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            double frameTime = CMTimeGetSeconds(pts) - trimStart; // time within clip

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

                [frameDeltas addObject:@{
                    @"time": @(frameTime),
                    @"dx": @(dx),    // normalized 0-1
                    @"dy": @(dy),
                }];
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
                CMTime t0 = CMTimeMakeWithSeconds(0, (int32_t)(frameRate * 100));
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
