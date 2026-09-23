//
//  SpliceKitServerCapture.m
//  SpliceKit - Screenshots of the Viewer, the timeline and the inspector, rendered from
//  FCP's own views (with flat-frame detection for the Viewer).
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Capture Viewer Screenshot

static NSView *SpliceKit_findPlayerViewForCapture(NSWindow *mainWindow,
                                                  NSString *requestedViewer,
                                                  NSMutableDictionary *debugInfo) {
    Class playerViewClass = objc_getClass("FFPlayerView");
    if (!playerViewClass || !mainWindow.contentView) return nil;

    NSString *viewer = [requestedViewer isKindOfClass:[NSString class]]
        ? requestedViewer.lowercaseString
        : @"largest";
    BOOL wants360 = [viewer isEqualToString:@"360"] || [viewer isEqualToString:@"native360"];
    BOOL wantsNormal = [viewer isEqualToString:@"normal"] || [viewer isEqualToString:@"flat"];

    if (wants360 || wantsNormal) {
        @try {
            id editorContainer = SpliceKit_getEditorContainer();
            SEL targetModulesSel = NSSelectorFromString(@"targetModules");
            SEL playerModulesSel = NSSelectorFromString(@"playerModules");
            SEL videoModuleSel = NSSelectorFromString(@"videoModule");
            SEL playerViewSel = NSSelectorFromString(@"playerView");
            SEL is360ViewerSel = NSSelectorFromString(@"is360Viewer");

            id targetModules = (editorContainer && [editorContainer respondsToSelector:targetModulesSel])
                ? ((id (*)(id, SEL))objc_msgSend)(editorContainer, targetModulesSel)
                : nil;

            if ([targetModules isKindOfClass:[NSArray class]]) {
                for (id module in (NSArray *)targetModules) {
                    if (![module respondsToSelector:playerModulesSel]) continue;
                    id playerModules = ((id (*)(id, SEL))objc_msgSend)(module, playerModulesSel);
                    if (![playerModules isKindOfClass:[NSArray class]]) continue;

                    for (id playerModule in (NSArray *)playerModules) {
                        id videoModule = ([playerModule respondsToSelector:videoModuleSel])
                            ? ((id (*)(id, SEL))objc_msgSend)(playerModule, videoModuleSel)
                            : nil;
                        if (!videoModule || ![videoModule respondsToSelector:is360ViewerSel]) continue;

                        BOOL is360Viewer = ((BOOL (*)(id, SEL))objc_msgSend)(videoModule, is360ViewerSel);
                        if ((wants360 && !is360Viewer) || (wantsNormal && is360Viewer)) continue;

                        NSView *playerView = nil;
                        if ([videoModule respondsToSelector:playerViewSel]) {
                            playerView = ((id (*)(id, SEL))objc_msgSend)(videoModule, playerViewSel);
                        }
                        if (!playerView && [playerModule respondsToSelector:playerViewSel]) {
                            playerView = ((id (*)(id, SEL))objc_msgSend)(playerModule, playerViewSel);
                        }
                        if (![playerView isKindOfClass:playerViewClass] || playerView.window != mainWindow) {
                            continue;
                        }

                        if (debugInfo) {
                            debugInfo[@"selectedViewer"] = wants360 ? @"360" : @"normal";
                            debugInfo[@"selectedViewClass"] = NSStringFromClass(playerView.class) ?: @"";
                            debugInfo[@"selectedVideoClass"] = NSStringFromClass([videoModule class]) ?: @"";
                        }
                        return playerView;
                    }
                }
            }
        } @catch (NSException *exception) {
            if (debugInfo) {
                debugInfo[@"selectorError"] = exception.reason ?: exception.name ?: @"unknown exception";
            }
        }

        if (debugInfo) debugInfo[@"selectedViewer"] = @"notFound";
        return nil;
    }

    NSView *largestPlayerView = nil;
    CGFloat largestArea = 0;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:mainWindow.contentView];
    while (queue.count > 0) {
        NSView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!view) continue;
        if ([view isKindOfClass:playerViewClass]) {
            CGFloat area = view.bounds.size.width * view.bounds.size.height;
            if (area > largestArea) {
                largestArea = area;
                largestPlayerView = view;
            }
        }
        NSArray *subs = [view subviews];
        if (subs) [queue addObjectsFromArray:subs];
    }
    if (debugInfo) debugInfo[@"selectedViewer"] = @"largest";
    return largestPlayerView;
}

// Is the captured Viewer content one flat colour? Downsample to 32×32, take the centre pixel
// as reference, trim each edge inward while that row/column still does not match (trimming
// toward the content colour sheds blended border rows from high-quality scaling), cap each
// edge at 40% of the dimension, then require the inner rect be at least 8×8 and uniform ±2.
static BOOL SpliceKit_pixelMatchesFlatRef(const unsigned char *p, const unsigned char *ref) {
    return abs((int)p[0] - (int)ref[0]) <= 2 && abs((int)p[1] - (int)ref[1]) <= 2
        && abs((int)p[2] - (int)ref[2]) <= 2;
}

static BOOL SpliceKit_rowMatchesFlatRef(const unsigned char *pixels, int side, int y,
                                        int left, int right, const unsigned char *ref) {
    for (int x = left; x < right; x++) {
        const unsigned char *p = pixels + (y * side + x) * 4;
        if (!SpliceKit_pixelMatchesFlatRef(p, ref)) return NO;
    }
    return YES;
}

static BOOL SpliceKit_colMatchesFlatRef(const unsigned char *pixels, int side, int x,
                                        int top, int bottom, const unsigned char *ref) {
    for (int y = top; y < bottom; y++) {
        const unsigned char *p = pixels + (y * side + x) * 4;
        if (!SpliceKit_pixelMatchesFlatRef(p, ref)) return NO;
    }
    return YES;
}

static BOOL SpliceKit_imageIsFlat(CGImageRef image, unsigned char outRGB[3]) {
    if (!image) return NO;
    const int side = 32;
    unsigned char *pixels = calloc((size_t)side * side * 4, 1);
    if (!pixels) return NO;
    BOOL flat = NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, side, side, 8, side * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (ctx) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), image);
        const unsigned char *ref = pixels + ((side / 2) * side + (side / 2)) * 4;
        int left = 0, top = 0, right = side, bottom = side;
        const int maxTrimX = (int)(side * 0.4);
        const int maxTrimY = (int)(side * 0.4);
        int trimTop = 0;
        while (top < bottom && !SpliceKit_rowMatchesFlatRef(pixels, side, top, left, right, ref)) {
            trimTop++;
            if (trimTop > maxTrimY) { CGContextRelease(ctx); CGColorSpaceRelease(cs); free(pixels); return NO; }
            top++;
        }
        int trimBottom = 0;
        while (bottom > top && !SpliceKit_rowMatchesFlatRef(pixels, side, bottom - 1, left, right, ref)) {
            trimBottom++;
            if (trimBottom > maxTrimY) { CGContextRelease(ctx); CGColorSpaceRelease(cs); free(pixels); return NO; }
            bottom--;
        }
        int trimLeft = 0;
        while (left < right && !SpliceKit_colMatchesFlatRef(pixels, side, left, top, bottom, ref)) {
            trimLeft++;
            if (trimLeft > maxTrimX) { CGContextRelease(ctx); CGColorSpaceRelease(cs); free(pixels); return NO; }
            left++;
        }
        int trimRight = 0;
        while (right > left && !SpliceKit_colMatchesFlatRef(pixels, side, right - 1, top, bottom, ref)) {
            trimRight++;
            if (trimRight > maxTrimX) { CGContextRelease(ctx); CGColorSpaceRelease(cs); free(pixels); return NO; }
            right--;
        }
        const int innerW = right - left;
        const int innerH = bottom - top;
        if (innerW < 8 || innerH < 8) {
            CGContextRelease(ctx);
            CGColorSpaceRelease(cs);
            free(pixels);
            return NO;
        }
        flat = YES;
        for (int y = top; y < bottom && flat; y++) {
            for (int x = left; x < right; x++) {
                const unsigned char *p = pixels + (y * side + x) * 4;
                if (!SpliceKit_pixelMatchesFlatRef(p, ref)) { flat = NO; break; }
            }
        }
        if (flat && outRGB) { outRGB[0] = ref[0]; outRGB[1] = ref[1]; outRGB[2] = ref[2]; }
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    free(pixels);
    return flat;
}

// `flat`, and for a flat image `flatColor` + `warning`, on a capture answer. The status
// stays "ok": a flat frame can be real (a black frame, an empty Viewer); the reader is told.
static void SpliceKit_captureAnnotateFlat(NSMutableDictionary *r, BOOL flat, const unsigned char rgb[3]) {
    r[@"flat"] = @(flat);
    if (!flat) return;
    r[@"flatColor"] = @[@(rgb[0]), @(rgb[1]), @(rgb[2])];
    r[@"warning"] = [NSString stringWithFormat:
        @"the captured image is one flat colour (RGB %d,%d,%d): either what Final Cut Pro shows there really is flat "
        @"(a black frame, a gap, an empty Viewer) or nothing rendered in that area. Captures are drawn in-process "
        @"from Final Cut Pro's views and a locked screen does not blank them; when the display is asleep Final Cut "
        @"Pro renders a black frame, so a flat black capture with the display asleep is expected and is not a failure",
        rgb[0], rgb[1], rgb[2]];
    SpliceKit_log(@"[Capture] flat image (RGB %d,%d,%d) at %@", rgb[0], rgb[1], rgb[2], r[@"path"] ?: @"");
}

NSDictionary *SpliceKit_handleCaptureViewer(NSDictionary *params) {
    NSString *outputPath = params[@"path"] ?: @"/tmp/splicekit_viewer.png";
    NSString *requestedViewer = params[@"viewer"] ?: params[@"which"];

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            // Find the main FCP window
            NSWindow *mainWindow = [NSApp mainWindow];
            if (!mainWindow) {
                for (NSWindow *w in [NSApp windows]) {
                    if ([w isVisible] && (!mainWindow || w.frame.size.width > mainWindow.frame.size.width)) {
                        mainWindow = w;
                    }
                }
            }
            if (!mainWindow) {
                result = @{@"error": @"No visible FCP window found"};
                return;
            }

            CGWindowID windowID = (CGWindowID)[mainWindow windowNumber];

            // Capture the full window using CGWindowListCreateImage (captures GPU/Metal content)
            // CGRectNull = capture the entire window bounds
            CGImageRef fullImage = CGWindowListCreateImage(
                CGRectNull,
                kCGWindowListOptionIncludingWindow,
                windowID,
                kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution
            );

            if (!fullImage) {
                result = @{@"error": @"CGWindowListCreateImage returned nil — screen recording permission may be needed"};
                return;
            }

            NSMutableDictionary *captureDebug = [NSMutableDictionary dictionary];
            NSView *targetPlayerView = SpliceKit_findPlayerViewForCapture(mainWindow, requestedViewer, captureDebug);
            if (requestedViewer && !targetPlayerView) {
                CGImageRelease(fullImage);
                result = @{@"error": [NSString stringWithFormat:@"No %@ viewer FFPlayerView found", requestedViewer],
                           @"capture": captureDebug};
                return;
            }

            NSData *pngData = nil;
            int outWidth = (int)CGImageGetWidth(fullImage);
            int outHeight = (int)CGImageGetHeight(fullImage);
            BOOL cropped = NO;
            BOOL flat = NO;
            unsigned char flatRGB[3] = {0, 0, 0};

            if (targetPlayerView) {
                // Convert view frame to window coordinates (flipped for image)
                NSRect viewFrameInWindow = [targetPlayerView convertRect:[targetPlayerView bounds] toView:nil];
                CGFloat imgScaleX = (CGFloat)CGImageGetWidth(fullImage) / mainWindow.frame.size.width;
                CGFloat imgScaleY = (CGFloat)CGImageGetHeight(fullImage) / mainWindow.frame.size.height;
                CGFloat windowHeight = mainWindow.frame.size.height;

                CGRect cropRect = CGRectMake(
                    viewFrameInWindow.origin.x * imgScaleX,
                    (windowHeight - viewFrameInWindow.origin.y - viewFrameInWindow.size.height) * imgScaleY,
                    viewFrameInWindow.size.width * imgScaleX,
                    viewFrameInWindow.size.height * imgScaleY
                );

                CGImageRef croppedImage = CGImageCreateWithImageInRect(fullImage, cropRect);
                if (croppedImage) {
                    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:croppedImage];
                    pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    outWidth = (int)CGImageGetWidth(croppedImage);
                    outHeight = (int)CGImageGetHeight(croppedImage);
                    flat = SpliceKit_imageIsFlat(croppedImage, flatRGB);
                    CGImageRelease(croppedImage);
                    cropped = YES;
                }
            }

            // Fallback: full window
            if (!pngData) {
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:fullImage];
                pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                flat = SpliceKit_imageIsFlat(fullImage, flatRGB);
            }

            CGImageRelease(fullImage);

            if (!pngData) {
                result = @{@"error": @"Failed to generate PNG data"};
                return;
            }

            BOOL written = [pngData writeToFile:outputPath atomically:YES];
            if (!written) {
                result = @{@"error": [NSString stringWithFormat:@"Failed to write to %@", outputPath]};
                return;
            }

            NSMutableDictionary *r = [@{
                @"status": @"ok",
                @"path": outputPath,
                @"width": @(outWidth),
                @"height": @(outHeight),
                @"bytes": @(pngData.length),
                @"cropped": @(cropped),
                @"capture": captureDebug,
            } mutableCopy];
            SpliceKit_captureAnnotateFlat(r, flat, flatRGB);
            result = r;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

#pragma mark - Capture Timeline Screenshot

NSDictionary *SpliceKit_handleCaptureTimeline(NSDictionary *params) {
    NSString *outputPath = params[@"path"] ?: @"/tmp/splicekit_timeline.png";

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            // Find the main FCP window
            NSWindow *mainWindow = [NSApp mainWindow];
            if (!mainWindow) {
                for (NSWindow *w in [NSApp windows]) {
                    if ([w isVisible] && (!mainWindow || w.frame.size.width > mainWindow.frame.size.width)) {
                        mainWindow = w;
                    }
                }
            }
            if (!mainWindow) {
                result = @{@"error": @"No visible FCP window found"};
                return;
            }

            CGWindowID windowID = (CGWindowID)[mainWindow windowNumber];

            // Capture the full window using CGWindowListCreateImage (captures GPU/Metal content)
            CGImageRef fullImage = CGWindowListCreateImage(
                CGRectNull,
                kCGWindowListOptionIncludingWindow,
                windowID,
                kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution
            );

            if (!fullImage) {
                result = @{@"error": @"CGWindowListCreateImage returned nil — screen recording permission may be needed"};
                return;
            }

            // Find the TLKTimelineView in the window hierarchy
            // First try getting it from the active timeline module
            Class tlkClass = NULL;
            id activeModule = SpliceKit_getActiveTimelineModule();
            if (activeModule) {
                SEL tvSel = NSSelectorFromString(@"timelineView");
                if ([activeModule respondsToSelector:tvSel]) {
                    id tv = ((id (*)(id, SEL))objc_msgSend)(activeModule, tvSel);
                    if (tv) tlkClass = [tv class];
                }
            }
            if (!tlkClass) tlkClass = objc_getClass("TLKTimelineView");

            NSView *largestTimelineView = nil;
            CGFloat largestArea = 0;

            if (tlkClass) {
                NSMutableArray *queue = [NSMutableArray arrayWithObject:[mainWindow contentView]];
                while (queue.count > 0) {
                    NSView *view = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if (!view) continue;
                    if ([view isKindOfClass:tlkClass]) {
                        CGFloat area = view.bounds.size.width * view.bounds.size.height;
                        if (area > largestArea) {
                            largestArea = area;
                            largestTimelineView = view;
                        }
                    }
                    NSArray *subs = [view subviews];
                    if (subs) [queue addObjectsFromArray:subs];
                }
            }

            NSData *pngData = nil;
            int outWidth = (int)CGImageGetWidth(fullImage);
            int outHeight = (int)CGImageGetHeight(fullImage);
            BOOL cropped = NO;
            BOOL flat = NO;
            unsigned char flatRGB[3] = {0, 0, 0};

            if (largestTimelineView) {
                // Convert view frame to window coordinates (flipped for CG image)
                NSRect viewFrameInWindow = [largestTimelineView convertRect:[largestTimelineView bounds] toView:nil];
                CGFloat imgScaleX = (CGFloat)CGImageGetWidth(fullImage) / mainWindow.frame.size.width;
                CGFloat imgScaleY = (CGFloat)CGImageGetHeight(fullImage) / mainWindow.frame.size.height;
                CGFloat windowHeight = mainWindow.frame.size.height;

                CGRect cropRect = CGRectMake(
                    viewFrameInWindow.origin.x * imgScaleX,
                    (windowHeight - viewFrameInWindow.origin.y - viewFrameInWindow.size.height) * imgScaleY,
                    viewFrameInWindow.size.width * imgScaleX,
                    viewFrameInWindow.size.height * imgScaleY
                );

                CGImageRef croppedImage = CGImageCreateWithImageInRect(fullImage, cropRect);
                if (croppedImage) {
                    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:croppedImage];
                    pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    outWidth = (int)CGImageGetWidth(croppedImage);
                    outHeight = (int)CGImageGetHeight(croppedImage);
                    flat = SpliceKit_imageIsFlat(croppedImage, flatRGB);
                    CGImageRelease(croppedImage);
                    cropped = YES;
                }
            }

            // Fallback: full window
            if (!pngData) {
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:fullImage];
                pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                flat = SpliceKit_imageIsFlat(fullImage, flatRGB);
            }

            CGImageRelease(fullImage);

            if (!pngData) {
                result = @{@"error": @"Failed to generate PNG data"};
                return;
            }

            BOOL written = [pngData writeToFile:outputPath atomically:YES];
            if (!written) {
                result = @{@"error": [NSString stringWithFormat:@"Failed to write to %@", outputPath]};
                return;
            }

            NSMutableDictionary *r = [@{
                @"status": @"ok",
                @"path": outputPath,
                @"width": @(outWidth),
                @"height": @(outHeight),
                @"bytes": @(pngData.length),
                @"cropped": @(cropped),
            } mutableCopy];
            SpliceKit_captureAnnotateFlat(r, flat, flatRGB);
            result = r;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

#pragma mark - Capture Inspector Screenshot

NSDictionary *SpliceKit_handleCaptureInspector(NSDictionary *params) {
    NSString *outputPath = params[@"path"] ?: @"/tmp/splicekit_inspector.png";

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            // Find the main FCP window
            NSWindow *mainWindow = [NSApp mainWindow];
            if (!mainWindow) {
                for (NSWindow *w in [NSApp windows]) {
                    if ([w isVisible] && (!mainWindow || w.frame.size.width > mainWindow.frame.size.width)) {
                        mainWindow = w;
                    }
                }
            }
            if (!mainWindow) {
                result = @{@"error": @"No visible FCP window found"};
                return;
            }

            CGWindowID windowID = (CGWindowID)[mainWindow windowNumber];

            CGImageRef fullImage = CGWindowListCreateImage(
                CGRectNull,
                kCGWindowListOptionIncludingWindow,
                windowID,
                kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution
            );

            if (!fullImage) {
                result = @{@"error": @"CGWindowListCreateImage returned nil — screen recording permission may be needed"};
                return;
            }

            // Walk view hierarchy and find the largest view matching one of FCP's inspector
            // root view classes. Priority: caller-supplied class_name first, then known roots.
            NSMutableArray<NSString *> *candidateClassNames = [NSMutableArray array];
            NSString *requestedClass = params[@"class_name"];
            if ([requestedClass isKindOfClass:[NSString class]] && requestedClass.length > 0) {
                [candidateClassNames addObject:requestedClass];
            }
            // Verified via runtime introspection: actual inspector container NSViews are
            // private (leading-underscore) classes. Walk in priority order.
            [candidateClassNames addObjectsFromArray:@[
                @"_FFInspectorContainerView",
                @"_FFInspectorContainerStackView",
                @"PEInspectorContainerBackgroundView",
                @"LKFlippedInspectorView",
                @"FFInspectorRootStackView",
                @"FFInspectorRootOutlineView",
                @"FFInspectorOutlineView",
                @"FFInspectorControllerView",
            ]];

            // FCP has multiple panes sharing container view classes (Effects Browser,
            // parameter Inspector, etc.). The parameter Inspector is anchored to the RIGHT
            // 1/3 of the window AND is the tallest such matching view. Pick the candidate
            // match satisfying: (origin.x > 0.65 * window.width) AND maximum height.
            CGFloat winWidth = mainWindow.frame.size.width;
            CGFloat rightThresholdX = winWidth * 0.55;

            NSView *largestInspectorView = nil;
            CGFloat bestHeight = 0;
            NSString *matchedClassName = nil;

            for (NSString *className in candidateClassNames) {
                Class candidateClass = objc_getClass([className UTF8String]);
                if (!candidateClass) continue;

                NSMutableArray *queue = [NSMutableArray arrayWithObject:[mainWindow contentView]];
                while (queue.count > 0) {
                    NSView *view = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if (!view) continue;
                    if ([view isKindOfClass:candidateClass]) {
                        if (view.bounds.size.width >= 200 && view.bounds.size.height >= 150 && !view.isHidden) {
                            NSRect frameInWindow = [view convertRect:[view bounds] toView:nil];
                            if (frameInWindow.origin.x >= rightThresholdX
                                && frameInWindow.size.height > bestHeight) {
                                bestHeight = frameInWindow.size.height;
                                largestInspectorView = view;
                                matchedClassName = className;
                            }
                        }
                    }
                    NSArray *subs = [view subviews];
                    if (subs) [queue addObjectsFromArray:subs];
                }
                if (largestInspectorView) break;  // Stop at the first matching class
            }

            NSData *pngData = nil;
            int outWidth = (int)CGImageGetWidth(fullImage);
            int outHeight = (int)CGImageGetHeight(fullImage);
            BOOL cropped = NO;
            BOOL flat = NO;
            unsigned char flatRGB[3] = {0, 0, 0};

            if (largestInspectorView) {
                NSRect viewFrameInWindow = [largestInspectorView convertRect:[largestInspectorView bounds] toView:nil];
                CGFloat imgScaleX = (CGFloat)CGImageGetWidth(fullImage) / mainWindow.frame.size.width;
                CGFloat imgScaleY = (CGFloat)CGImageGetHeight(fullImage) / mainWindow.frame.size.height;
                CGFloat windowHeight = mainWindow.frame.size.height;

                CGRect cropRect = CGRectMake(
                    viewFrameInWindow.origin.x * imgScaleX,
                    (windowHeight - viewFrameInWindow.origin.y - viewFrameInWindow.size.height) * imgScaleY,
                    viewFrameInWindow.size.width * imgScaleX,
                    viewFrameInWindow.size.height * imgScaleY
                );

                CGImageRef croppedImage = CGImageCreateWithImageInRect(fullImage, cropRect);
                if (croppedImage) {
                    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:croppedImage];
                    pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    outWidth = (int)CGImageGetWidth(croppedImage);
                    outHeight = (int)CGImageGetHeight(croppedImage);
                    flat = SpliceKit_imageIsFlat(croppedImage, flatRGB);
                    CGImageRelease(croppedImage);
                    cropped = YES;
                }
            }

            // Fallback: full window if no inspector view found
            if (!pngData) {
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:fullImage];
                pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                flat = SpliceKit_imageIsFlat(fullImage, flatRGB);
            }

            CGImageRelease(fullImage);

            if (!pngData) {
                result = @{@"error": @"Failed to generate PNG data"};
                return;
            }

            BOOL written = [pngData writeToFile:outputPath atomically:YES];
            if (!written) {
                result = @{@"error": [NSString stringWithFormat:@"Failed to write to %@", outputPath]};
                return;
            }

            NSMutableDictionary *r = [@{
                @"status": @"ok",
                @"path": outputPath,
                @"width": @(outWidth),
                @"height": @(outHeight),
                @"bytes": @(pngData.length),
                @"cropped": @(cropped),
            } mutableCopy];
            if (matchedClassName) r[@"matchedClass"] = matchedClassName;
            SpliceKit_captureAnnotateFlat(r, flat, flatRGB);
            result = r;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}
