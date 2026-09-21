#import "SpliceKitImmersivePreviewPanel.h"
#import "SpliceKitVisionPro.h"
#import "SpliceKit.h"

static NSDictionary *SKIPError(NSString *message) {
    return @{@"error": message ?: @"unknown error"};
}

static NSDictionary *SKIPCustomRendererDisabled(void) {
    return SKIPError(@"The custom immersive renderer is disabled; use FCP's native 360 viewer");
}

static NSString *SKIPValidatedImmersivePath(id value, NSString **errorMessage) {
    (void)value;
    if (errorMessage) {
        *errorMessage = @"Immersive camera source loading is not available in this build";
    }
    return nil;
}

NSDictionary *SpliceKit_handleImmersivePreviewShow(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        NSString *surface = [params[@"surface"] isKindOfClass:[NSString class]] ? [params[@"surface"] lowercaseString] : @"";
        if (surface.length == 0) surface = [params[@"mode"] isKindOfClass:[NSString class]] ? [params[@"mode"] lowercaseString] : @"";
        SpliceKitImmersivePreviewPanel *panel = [SpliceKitImmersivePreviewPanel sharedPanel];
        if ([surface isEqualToString:@"panel"] || [surface isEqualToString:@"window"]) {
            status = SKIPError(@"The custom immersive popup viewer is disabled; use FCP's native 360 viewer");
            return;
        }

        NSError *error = nil;
        BOOL useLoaded = [params[@"useLoaded"] respondsToSelector:@selector(boolValue)] && [params[@"useLoaded"] boolValue];
        BOOL ok = useLoaded
            ? [panel showLoadedInViewer:&error]
            : [panel showInViewerForCurrentSelection:&error];
        if (!ok) {
            status = SKIPError(error.localizedDescription ?: @"show viewer failed");
            return;
        }

        NSString *timelinePath = SpliceKit_copyTimelineClipPathNearPlayhead() ?: @"";
        NSString *resolvedPath = timelinePath;
        NSMutableDictionary *snapshot = [[panel statusSnapshot] mutableCopy];
        snapshot[@"status"] = @"ok";
        snapshot[@"surface"] = @"fcp_native_360";
        snapshot[@"customRendererActive"] = @NO;
        snapshot[@"timelinePath"] = timelinePath;
        snapshot[@"resolvedPath"] = resolvedPath;
        status = [snapshot copy];
    });
    return status ?: @{@"visible": @NO};
}

NSDictionary *SpliceKit_handleImmersivePreviewHide(NSDictionary *params) {
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        NSString *surface = [params[@"surface"] isKindOfClass:[NSString class]] ? [params[@"surface"] lowercaseString] : @"";
        SpliceKitImmersivePreviewPanel *panel = [SpliceKitImmersivePreviewPanel sharedPanel];
        if (surface.length == 0 || [surface isEqualToString:@"viewer"]) {
            [panel hideInViewer];
        }
        if (surface.length == 0 || [surface isEqualToString:@"panel"] || [surface isEqualToString:@"window"]) {
            [panel hidePanel];
        }
        status = [panel statusSnapshot];
    });
    return status ?: @{@"visible": @NO};
}

NSDictionary *SpliceKit_handleImmersivePreviewStatus(NSDictionary *params) {
    (void)params;
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        status = [[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot];
    });
    return status ?: @{@"visible": @NO};
}

NSDictionary *SpliceKit_handleImmersivePreviewResolveSelectedPath(NSDictionary *params) {
    (void)params;
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        NSString *timelinePath = SpliceKit_copyTimelineClipPathNearPlayhead() ?: @"";
        NSString *resolvedPath = timelinePath;
        result = @{
            @"timelinePath": timelinePath,
            @"resolvedPath": resolvedPath,
            @"isImmersiveSource": @NO,
        };
    });
    return result ?: SKIPError(@"resolveSelectedPath failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewLoadSelected(NSDictionary *params) {
    (void)params;
    __block NSString *path = nil;
    SpliceKit_executeOnMainThread(^{
        path = SpliceKit_copyTimelineClipPathNearPlayhead() ?: @"";
    });
    NSString *pathError = nil;
    path = SKIPValidatedImmersivePath(path, &pathError);
    if (path.length == 0) {
        return SKIPError(pathError ?: @"No immersive clip is currently selected");
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *status = nil;
    [[SpliceKitImmersivePreviewPanel sharedPanel] loadClipAtPathAsync:path completion:^(BOOL ok, NSError *error) {
        status = ok
            ? [[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot]
            : SKIPError(error.localizedDescription ?: @"loadSelected failed");
        dispatch_semaphore_signal(sem);
    }];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 12LL * NSEC_PER_SEC));
    if (waitResult != 0) {
        return SKIPError(@"loadSelected timed out");
    }
    return status ?: SKIPError(@"loadSelected failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewLoadPath(NSDictionary *params) {
    NSString *pathError = nil;
    NSString *path = SKIPValidatedImmersivePath(params[@"path"], &pathError);
    if (path.length == 0) return SKIPError(pathError);

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *status = nil;
    [[SpliceKitImmersivePreviewPanel sharedPanel] loadClipAtPathAsync:path completion:^(BOOL ok, NSError *error) {
        status = ok
            ? [[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot]
            : SKIPError(error.localizedDescription ?: @"loadPath failed");
        dispatch_semaphore_signal(sem);
    }];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 12LL * NSEC_PER_SEC));
    if (waitResult != 0) {
        return SKIPError(@"loadPath timed out");
    }
    return status ?: SKIPError(@"loadPath failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewSetFrame(NSDictionary *params) {
    (void)params;
    return SKIPCustomRendererDisabled();
}

NSDictionary *SpliceKit_handleImmersivePreviewSetEyeMode(NSDictionary *params) {
    (void)params;
    return SKIPCustomRendererDisabled();
}

NSDictionary *SpliceKit_handleImmersivePreviewSetViewMode(NSDictionary *params) {
    (void)params;
    return SKIPCustomRendererDisabled();
}

NSDictionary *SpliceKit_handleImmersivePreviewSetViewport(NSDictionary *params) {
    (void)params;
    return SKIPCustomRendererDisabled();
}

NSDictionary *SpliceKit_handleImmersivePreviewRefresh(NSDictionary *params) {
    (void)params;
    return SKIPCustomRendererDisabled();
}

NSDictionary *SpliceKit_handleImmersivePreviewResetPerf(NSDictionary *params) {
    (void)params;
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        SpliceKitImmersivePreviewPanel *panel = [SpliceKitImmersivePreviewPanel sharedPanel];
        [panel resetPerformanceCounters];
        status = [panel statusSnapshot];
    });
    return status ?: SKIPError(@"resetPerf failed");
}

NSDictionary *SpliceKit_handleImmersivePreviewSendCurrentFrame(NSDictionary *params) {
    (void)params;
    __block NSDictionary *status = nil;
    SpliceKit_executeOnMainThread(^{
        NSError *error = nil;
        BOOL ok = [[SpliceKitImmersivePreviewPanel sharedPanel] sendCurrentFrameToVisionPro:&error];
        if (!ok) {
            status = SKIPError(error.localizedDescription ?: @"sendCurrentFrame failed");
            return;
        }
        NSMutableDictionary *snapshot = [[[SpliceKitImmersivePreviewPanel sharedPanel] statusSnapshot] mutableCopy];
        snapshot[@"visionPro"] = [[SpliceKitVisionPro shared] stateSnapshot];
        status = [snapshot copy];
    });
    return status ?: SKIPError(@"sendCurrentFrame failed");
}
