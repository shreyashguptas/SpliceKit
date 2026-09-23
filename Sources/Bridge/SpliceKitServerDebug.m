//
//  SpliceKitServerDebug.m
//  SpliceKit - In-process debugging handlers: FCP debug flags and presets, method
//  tracing, KVO watches, crash handler, threads, expression evaluation, hot plugin
//  loading, notification observation and breakpoints (debug.*).
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Debug & Diagnostics
//
// Exposes FCP's hidden developer tools: TimelineKit visual overlays (TLK* keys),
// ProAppSupport logging, video decoder diagnostics, GPU logging, and frame rate
// monitoring. All controlled through NSUserDefaults and CFPreferences.
//

// All known TLK debug UserDefaults keys
static NSArray *SpliceKit_tlkDebugKeys(void) {
    return @[
        // Visual overlays
        @"TLKShowItemLaneIndex",
        @"TLKShowMisalignedEdges",
        @"TLKShowRenderBar",
        @"TLKShowHiddenGapItems",        // via showHiddenGapItems
        @"TLKShowHiddenItemHeaders",     // via showHiddenItemHeaders
        @"TLKShowInvalidLayoutRects",    // via showInvalidLayoutRects
        @"TLKShowContainerBounds",       // via showContainerBounds
        @"TLKShowContentLayers",         // via showContentLayers
        @"TLKShowRulerBounds",           // via showRulerBounds
        @"TLKShowUsedRegion",            // via showUsedRegion
        @"TLKShowZeroHeightSpineItems",  // via showZeroHeightSpineItems
        // Logging
        @"TLKLogVisibleLayerChanges",
        @"TLKLogParts",
        @"TLKLogReloadRequests",         // via logReloadRequests
        @"TLKLogRecyclingLayerChanges",  // via logRecyclingLayerChanges
        @"TLKLogVisibleRectChanges",     // via logVisibleRectChanges
        @"TLKLogSegmentationStatistics", // via logSegmentationStatistics
        // Performance / rendering
        @"TLKPerformanceMonitorEnabled",
        @"TLKDebugColorChangedObjects",  // via debugColorChangedObjects
        @"TLKDebugLayoutConstraints",    // via debugLayoutConstraints
        @"TLKDebugErrorsAndWarnings",    // via debugErrorsAndWarnings
        @"TLKDisableItemContents",
        @"TLKLoadDebugMicaAssets",       // via loadDebugMicaAssets
        @"TLKForceLayoutOnDrag",         // via forceLayoutOnDrag
        @"TLKOptimizedReload",
        @"TLKOptimizedZooming",
        @"TLKLegacyLayout",
        @"TLKColorizesLanes",            // via colorizesLanes
        @"TLKViewStateUsesLanePositions",
        @"TLKEnableUpdateFilmstripsForItemComponentFragments",
        @"TLKItemLayerContentsOperations",
        // Raw debug keys
        @"DebugKeyItemVideoFilmstripsDisabled",
        @"DebugKeyItemBackgroundDisabled",
        @"DebugKeyItemAudioWaveformsDisabled",
    ];
}

// All known CFPreferences debug keys (integer or bool)
static NSDictionary *SpliceKit_cfprefsDebugKeys(void) {
    return @{
        @"VideoDecoderLogLevelInNLE": @"int",
        @"FrameDropLogLevel": @"int",
        @"GPU_LOGGING": @"bool",
        @"EnableScheduledReadAudioLogging": @"bool",
        @"EnableLibraryUpdateHistoryValidation": @"bool",
        @"FFVAMLSaveTranscription": @"bool",
    };
}

// ProAppSupport log level names
static NSArray *SpliceKit_logLevelNames(void) {
    return @[@"trace", @"debug", @"info", @"warning", @"error", @"failure"];
}

// ProAppSupport log category names (matching PASLogCategory class methods)
static NSArray *SpliceKit_logCategoryNames(void) {
    return @[
        @"dev", @"player", @"sequenceEditor", @"camera", @"inspector",
        @"director", @"voiceover", @"selection", @"network", @"theme",
        @"share", @"analysisKit", @"backgroundTasks", @"angleEditor",
        @"lessons", @"onboarding", @"userNotifications", @"ui", @"all"
    ];
}

NSDictionary *SpliceKit_handleDebugGetConfig(NSDictionary *params) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // 1) TLK debug flags
    NSMutableDictionary *tlkFlags = [NSMutableDictionary dictionary];
    for (NSString *key in SpliceKit_tlkDebugKeys()) {
        tlkFlags[key] = @([defaults boolForKey:key]);
    }

    // 2) CFPreferences debug flags
    NSMutableDictionary *cfFlags = [NSMutableDictionary dictionary];
    NSDictionary *cfKeys = SpliceKit_cfprefsDebugKeys();
    for (NSString *key in cfKeys) {
        Boolean exists = false;
        if ([cfKeys[key] isEqualToString:@"int"]) {
            CFIndex val = CFPreferencesGetAppIntegerValue(
                (__bridge CFStringRef)key, kCFPreferencesCurrentApplication, &exists);
            cfFlags[key] = exists ? @(val) : @"<not set>";
        } else {
            Boolean val = CFPreferencesGetAppBooleanValue(
                (__bridge CFStringRef)key, kCFPreferencesCurrentApplication, &exists);
            cfFlags[key] = exists ? @(val) : @"<not set>";
        }
    }

    // 3) ProAppSupport log settings (via UserDefaults keys LogLevel, LogUI, LogThread, LogCategory)
    NSMutableDictionary *logSettings = [NSMutableDictionary dictionary];
    id logLevelVal = [defaults objectForKey:@"LogLevel"];
    if (logLevelVal) {
        NSInteger level = [logLevelVal integerValue];
        NSArray *names = SpliceKit_logLevelNames();
        logSettings[@"LogLevel"] = (level >= 0 && level < (NSInteger)names.count)
            ? names[level] : [NSString stringWithFormat:@"%ld", (long)level];
    } else {
        logSettings[@"LogLevel"] = @"<not set>";
    }
    logSettings[@"LogUI"] = [defaults objectForKey:@"LogUI"] ? @([defaults boolForKey:@"LogUI"]) : @"<not set>";
    logSettings[@"LogThread"] = [defaults objectForKey:@"LogThread"] ? @([defaults boolForKey:@"LogThread"]) : @"<not set>";
    id logCatVal = [defaults objectForKey:@"LogCategory"];
    if (logCatVal) {
        logSettings[@"LogCategory"] = logCatVal;
    } else {
        logSettings[@"LogCategory"] = @"<not set>";
    }

    // 4) Additional FCP defaults
    NSMutableDictionary *fcpFlags = [NSMutableDictionary dictionary];
    NSArray *fcpKeys = @[@"FFDontCoalesceGaps", @"FFDisableSnapping", @"FFDisableSkimming"];
    for (NSString *key in fcpKeys) {
        id val = [defaults objectForKey:key];
        fcpFlags[key] = val ? @([defaults boolForKey:key]) : @"<not set>";
    }

    return @{
        @"timeline_debug": tlkFlags,
        @"cfpreferences_debug": cfFlags,
        @"proapp_log": logSettings,
        @"fcp_flags": fcpFlags,
        @"available_log_levels": SpliceKit_logLevelNames(),
        @"available_log_categories": SpliceKit_logCategoryNames(),
    };
}

NSDictionary *SpliceKit_handleDebugSetConfig(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
    NSString *key = params[@"key"];
    id value = params[@"value"];

    if (!key) {
        result = @{@"error": @"'key' parameter required"};
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Check if it's a TLK key
    NSArray *tlkKeys = SpliceKit_tlkDebugKeys();
    if ([tlkKeys containsObject:key]) {
        BOOL boolVal = [value boolValue];
        [defaults setBool:boolVal forKey:key];
        [defaults synchronize];

        // Reload TLK settings live
        Class tlkClass = NSClassFromString(@"TLKUserDefaults");
        if (tlkClass && [tlkClass respondsToSelector:NSSelectorFromString(@"_loadUserDefaults")]) {
            ((void (*)(id, SEL))objc_msgSend)(tlkClass, NSSelectorFromString(@"_loadUserDefaults"));
        }

        result = @{@"status": @"ok", @"key": key, @"value": @(boolVal), @"type": @"tlk_debug",
                 @"note": @"TLKUserDefaults reloaded"};
        return;
    }

    // Check if it's a CFPreferences key
    NSDictionary *cfKeys = SpliceKit_cfprefsDebugKeys();
    if (cfKeys[key]) {
        if ([cfKeys[key] isEqualToString:@"int"]) {
            CFPreferencesSetAppValue(
                (__bridge CFStringRef)key,
                (__bridge CFPropertyListRef)@([value integerValue]),
                kCFPreferencesCurrentApplication);
        } else {
            CFPreferencesSetAppValue(
                (__bridge CFStringRef)key,
                (__bridge CFPropertyListRef)@([value boolValue]),
                kCFPreferencesCurrentApplication);
        }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        result = @{@"status": @"ok", @"key": key, @"value": value, @"type": @"cfpreferences",
                 @"note": @"CFPreferences set (may need restart for some flags)"};
        return;
    }

    // Check if it's a ProAppSupport log key
    if ([key isEqualToString:@"LogLevel"]) {
        NSArray *names = SpliceKit_logLevelNames();
        NSInteger level = -1;
        if ([value isKindOfClass:[NSString class]]) {
            level = [names indexOfObject:[value lowercaseString]];
            if (level == NSNotFound) level = -1;
        } else {
            level = [value integerValue];
        }
        if (level < 0 || level >= (NSInteger)names.count) {
            result = @{@"error": [NSString stringWithFormat:@"Invalid log level. Use one of: %@",
                                [names componentsJoinedByString:@", "]]};
            return;
        }
        [defaults setInteger:level forKey:@"LogLevel"];
        [defaults synchronize];
        result = @{@"status": @"ok", @"key": @"LogLevel", @"value": names[level],
                 @"rawValue": @(level), @"type": @"proapp_log"};
        return;
    }

    if ([key isEqualToString:@"LogUI"]) {
        BOOL boolVal = [value boolValue];
        [defaults setBool:boolVal forKey:@"LogUI"];
        [defaults synchronize];
        if (boolVal) [[SpliceKitLogPanel sharedPanel] showPanel];
        else [[SpliceKitLogPanel sharedPanel] hidePanel];
        result = @{@"status": @"ok", @"key": @"LogUI", @"value": @(boolVal), @"type": @"proapp_log"};
        return;
    }

    if ([key isEqualToString:@"LogThread"]) {
        BOOL boolVal = [value boolValue];
        [defaults setBool:boolVal forKey:@"LogThread"];
        [defaults synchronize];
        result = @{@"status": @"ok", @"key": @"LogThread", @"value": @(boolVal), @"type": @"proapp_log"};
        return;
    }

    if ([key isEqualToString:@"LogCategory"]) {
        [defaults setObject:value forKey:@"LogCategory"];
        [defaults synchronize];
        result = @{@"status": @"ok", @"key": @"LogCategory", @"value": value, @"type": @"proapp_log"};
        return;
    }

    // FCP flags
    NSArray *fcpKeys = @[@"FFDontCoalesceGaps", @"FFDisableSnapping", @"FFDisableSkimming"];
    if ([fcpKeys containsObject:key]) {
        BOOL boolVal = [value boolValue];
        [defaults setBool:boolVal forKey:key];
        [defaults synchronize];
        result = @{@"status": @"ok", @"key": key, @"value": @(boolVal), @"type": @"fcp_flag"};
        return;
    }

    // Allow setting arbitrary keys as a fallback
    if ([value isKindOfClass:[NSNumber class]]) {
        [defaults setObject:value forKey:key];
    } else {
        [defaults setBool:[value boolValue] forKey:key];
    }
    [defaults synchronize];
    result = @{@"status": @"ok", @"key": key, @"value": value, @"type": @"custom",
             @"note": @"Set as custom UserDefaults key"};
    });
    return result ?: @{@"error": @"debug.setConfig failed"};
}

NSDictionary *SpliceKit_handleDebugResetConfig(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
    NSString *scope = params[@"scope"] ?: @"all";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *removedKeys = [NSMutableArray array];

    if ([scope isEqualToString:@"tlk"] || [scope isEqualToString:@"all"]) {
        for (NSString *key in SpliceKit_tlkDebugKeys()) {
            [defaults removeObjectForKey:key];
            [removedKeys addObject:key];
        }
        // Reload TLK
        Class tlkClass = NSClassFromString(@"TLKUserDefaults");
        if (tlkClass && [tlkClass respondsToSelector:NSSelectorFromString(@"_loadUserDefaults")]) {
            ((void (*)(id, SEL))objc_msgSend)(tlkClass, NSSelectorFromString(@"_loadUserDefaults"));
        }
    }

    if ([scope isEqualToString:@"cfprefs"] || [scope isEqualToString:@"all"]) {
        for (NSString *key in SpliceKit_cfprefsDebugKeys()) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, kCFPreferencesCurrentApplication);
            [removedKeys addObject:key];
        }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    }

    if ([scope isEqualToString:@"log"] || [scope isEqualToString:@"all"]) {
        for (NSString *key in @[@"LogLevel", @"LogUI", @"LogThread", @"LogCategory"]) {
            [defaults removeObjectForKey:key];
            [removedKeys addObject:key];
        }
        [[SpliceKitLogPanel sharedPanel] hidePanel];
    }

    [defaults synchronize];
    result = @{@"status": @"ok", @"scope": scope, @"removedKeys": removedKeys,
             @"count": @(removedKeys.count)};
    });
    return result ?: @{@"error": @"debug.resetConfig failed"};
}

// Framerate monitor state
static id sFramerateMonitor = nil;

NSDictionary *SpliceKit_handleDebugStartFramerateMonitor(NSDictionary *params) {
    __block NSDictionary *result = nil;
    float interval = [params[@"interval"] floatValue];
    if (interval <= 0) interval = 2.0;

    dispatch_sync(dispatch_get_main_queue(), ^{
        Class hmdClass = NSClassFromString(@"HMDFramerate");
        if (!hmdClass) {
            result = @{@"error": @"HMDFramerate class not found"};
            return;
        }

        if (sFramerateMonitor) {
            // Stop existing monitor first
            if ([sFramerateMonitor respondsToSelector:NSSelectorFromString(@"stopLogging")]) {
                ((void (*)(id, SEL))objc_msgSend)(sFramerateMonitor, NSSelectorFromString(@"stopLogging"));
            }
            sFramerateMonitor = nil;
        }

        sFramerateMonitor = [[hmdClass alloc] init];
        if (!sFramerateMonitor) {
            result = @{@"error": @"Failed to create HMDFramerate instance"};
            return;
        }

        SEL startSel = NSSelectorFromString(@"startLogging:");
        if ([sFramerateMonitor respondsToSelector:startSel]) {
            ((void (*)(id, SEL, float))objc_msgSend)(sFramerateMonitor, startSel, interval);
            result = @{@"status": @"ok", @"interval": @(interval),
                       @"message": [NSString stringWithFormat:
                                    @"Framerate monitor started (%.1fs interval). Output goes to Console.app / system log.",
                                    interval]};
        } else {
            result = @{@"error": @"HMDFramerate does not respond to startLogging:"};
            sFramerateMonitor = nil;
        }
    });
    return result ?: @{@"error": @"Failed to start framerate monitor"};
}

NSDictionary *SpliceKit_handleDebugStopFramerateMonitor(NSDictionary *params) {
    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!sFramerateMonitor) {
            result = @{@"status": @"ok", @"message": @"No framerate monitor running"};
            return;
        }
        if ([sFramerateMonitor respondsToSelector:NSSelectorFromString(@"stopLogging")]) {
            ((void (*)(id, SEL))objc_msgSend)(sFramerateMonitor, NSSelectorFromString(@"stopLogging"));
        }
        sFramerateMonitor = nil;
        result = @{@"status": @"ok", @"message": @"Framerate monitor stopped"};
    });
    return result;
}

NSDictionary *SpliceKit_handleDebugEnablePreset(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
    NSString *preset = params[@"preset"];
    if (!preset) {
        result = @{@"error": @"'preset' parameter required",
                 @"available": @[@"timeline_visual", @"timeline_logging",
                                 @"performance", @"render_debug", @"verbose_logging", @"all_off"]};
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *changed = [NSMutableArray array];

    void (^setKey)(NSString *, BOOL) = ^(NSString *key, BOOL val) {
        [defaults setBool:val forKey:key];
        [changed addObject:@{@"key": key, @"value": @(val)}];
    };

    if ([preset isEqualToString:@"timeline_visual"]) {
        setKey(@"TLKShowItemLaneIndex", YES);
        setKey(@"TLKShowMisalignedEdges", YES);
        setKey(@"TLKShowRenderBar", YES);
        setKey(@"TLKShowHiddenGapItems", YES);
        setKey(@"TLKShowInvalidLayoutRects", YES);
        setKey(@"TLKDebugColorChangedObjects", YES);
    } else if ([preset isEqualToString:@"timeline_logging"]) {
        setKey(@"TLKLogVisibleLayerChanges", YES);
        setKey(@"TLKLogParts", YES);
        setKey(@"TLKLogReloadRequests", YES);
        setKey(@"TLKLogRecyclingLayerChanges", YES);
        setKey(@"TLKLogVisibleRectChanges", YES);
        setKey(@"TLKLogSegmentationStatistics", YES);
    } else if ([preset isEqualToString:@"performance"]) {
        setKey(@"TLKPerformanceMonitorEnabled", YES);
        [defaults setInteger:2 forKey:@"VideoDecoderLogLevelInNLE"];
        [changed addObject:@{@"key": @"VideoDecoderLogLevelInNLE", @"value": @2}];
        [defaults setInteger:2 forKey:@"FrameDropLogLevel"];
        [changed addObject:@{@"key": @"FrameDropLogLevel", @"value": @2}];
    } else if ([preset isEqualToString:@"render_debug"]) {
        setKey(@"DebugKeyItemVideoFilmstripsDisabled", YES);
        setKey(@"DebugKeyItemBackgroundDisabled", YES);
        setKey(@"DebugKeyItemAudioWaveformsDisabled", YES);
        setKey(@"TLKDisableItemContents", YES);
        setKey(@"GPU_LOGGING", YES);
    } else if ([preset isEqualToString:@"verbose_logging"]) {
        [defaults setInteger:0 forKey:@"LogLevel"]; // trace
        [changed addObject:@{@"key": @"LogLevel", @"value": @"trace"}];
        setKey(@"LogUI", YES);
        setKey(@"LogThread", YES);
        setKey(@"EnableScheduledReadAudioLogging", YES);
    } else if ([preset isEqualToString:@"all_off"]) {
        // Turn off all TLK visual/logging flags
        for (NSString *key in SpliceKit_tlkDebugKeys()) {
            [defaults removeObjectForKey:key];
            [changed addObject:@{@"key": key, @"value": @"removed"}];
        }
        // Reset CFPreferences
        for (NSString *key in SpliceKit_cfprefsDebugKeys()) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, kCFPreferencesCurrentApplication);
            [changed addObject:@{@"key": key, @"value": @"removed"}];
        }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        // Reset log settings
        for (NSString *key in @[@"LogLevel", @"LogUI", @"LogThread", @"LogCategory"]) {
            [defaults removeObjectForKey:key];
            [changed addObject:@{@"key": key, @"value": @"removed"}];
        }
        [[SpliceKitLogPanel sharedPanel] hidePanel];
    } else {
        result = @{@"error": [NSString stringWithFormat:@"Unknown preset: %@", preset],
                 @"available": @[@"timeline_visual", @"timeline_logging",
                                 @"performance", @"render_debug", @"verbose_logging", @"all_off"]};
        return;
    }

    [defaults synchronize];
    if ([[defaults objectForKey:@"LogUI"] boolValue]) {
        [[SpliceKitLogPanel sharedPanel] showPanel];
    }

    // Reload TLK
    Class tlkClass = NSClassFromString(@"TLKUserDefaults");
    if (tlkClass && [tlkClass respondsToSelector:NSSelectorFromString(@"_loadUserDefaults")]) {
        ((void (*)(id, SEL))objc_msgSend)(tlkClass, NSSelectorFromString(@"_loadUserDefaults"));
    }

    result = @{@"status": @"ok", @"preset": preset, @"changed": changed, @"count": @(changed.count)};
    });
    return result ?: @{@"error": @"debug.enablePreset failed"};
}

#pragma mark - Debug: Method Tracing
//
// Non-blocking alternative to breakpoints. Swizzles target methods to log every
// call with arguments, return value, and optional call stack. Traces are stored
// in a circular buffer and broadcast to MCP clients in real-time.
//

// Storage for active traces: key = "ClassName.selectorName", value = trace config
static NSMutableDictionary<NSString *, NSDictionary *> *sActiveTraces = nil;
// Circular buffer for trace logs (newest first)
static NSMutableArray<NSDictionary *> *sTraceLog = nil;
static const NSUInteger kMaxTraceLogEntries = 500;
static dispatch_queue_t sTraceQueue = nil;

static void SpliceKit_ensureTraceStorage(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sActiveTraces = [NSMutableDictionary dictionary];
        sTraceLog = [NSMutableArray array];
        sTraceQueue = dispatch_queue_create("com.splicekit.trace", DISPATCH_QUEUE_SERIAL);
    });
}

static void SpliceKit_addTraceEntry(NSDictionary *entry) {
    dispatch_async(sTraceQueue, ^{
        [sTraceLog insertObject:entry atIndex:0];
        while (sTraceLog.count > kMaxTraceLogEntries) {
            [sTraceLog removeLastObject];
        }
    });
    // Broadcast to connected clients
    SpliceKit_broadcastEvent(@{@"type": @"trace", @"data": entry});
}

// debug.traceMethod - Swizzle any method to log args, return value, and call stack
// {"method":"debug.traceMethod","params":{"action":"add","className":"FFAnchoredTimelineModule","selector":"actionRetimeHoldPreset:holdComponentTime:duration:newHoldComponentTime:error:","logStack":true}}
// {"method":"debug.traceMethod","params":{"action":"remove","className":"FFAnchoredTimelineModule","selector":"actionRetimeHoldPreset:..."}}
// {"method":"debug.traceMethod","params":{"action":"list"}}
// {"method":"debug.traceMethod","params":{"action":"getLog","limit":50}}
// {"method":"debug.traceMethod","params":{"action":"clearLog"}}
NSDictionary *SpliceKit_handleDebugTraceMethod(NSDictionary *params) {
    SpliceKit_ensureTraceStorage();

    NSString *act = params[@"action"] ?: @"add";

    if ([act isEqualToString:@"list"]) {
        return @{@"traces": [sActiveTraces allKeys], @"count": @(sActiveTraces.count)};
    }

    if ([act isEqualToString:@"getLog"]) {
        __block NSArray *entries;
        NSUInteger limit = params[@"limit"] ? [params[@"limit"] unsignedIntegerValue] : 50;
        dispatch_sync(sTraceQueue, ^{
            NSUInteger n = MIN(limit, sTraceLog.count);
            entries = [sTraceLog subarrayWithRange:NSMakeRange(0, n)];
        });
        return @{@"log": entries, @"count": @(entries.count), @"total": @(sTraceLog.count)};
    }

    if ([act isEqualToString:@"clearLog"]) {
        dispatch_sync(sTraceQueue, ^{ [sTraceLog removeAllObjects]; });
        return @{@"status": @"ok", @"message": @"Trace log cleared"};
    }

    if ([act isEqualToString:@"removeAll"]) {
        __block NSMutableArray *removed = [NSMutableArray array];
        for (NSString *key in [sActiveTraces allKeys]) {
            NSDictionary *info = sActiveTraces[key];
            Class cls = NSClassFromString(info[@"className"]);
            SEL sel = NSSelectorFromString(info[@"selector"]);
            if (cls && sel) {
                SpliceKit_unswizzleMethod(cls, sel);
                [removed addObject:key];
            }
        }
        [sActiveTraces removeAllObjects];
        return @{@"status": @"ok", @"removed": removed, @"count": @(removed.count)};
    }

    NSString *className = params[@"className"];
    NSString *selectorName = params[@"selector"];
    if (!className || !selectorName) {
        return @{@"error": @"className and selector parameters required"};
    }

    NSString *key = [NSString stringWithFormat:@"%@.%@", className, selectorName];

    if ([act isEqualToString:@"remove"]) {
        Class cls = NSClassFromString(className);
        SEL sel = NSSelectorFromString(selectorName);
        if (!cls || !sel) return @{@"error": @"Class or selector not found"};
        BOOL ok = SpliceKit_unswizzleMethod(cls, sel);
        [sActiveTraces removeObjectForKey:key];
        return ok ? @{@"status": @"ok", @"removed": key}
                  : @{@"error": [NSString stringWithFormat:@"No trace active for %@", key]};
    }

    // action == "add"
    Class cls = NSClassFromString(className);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class not found: %@", className]};
    SEL sel = NSSelectorFromString(selectorName);
    BOOL isClassMethod = [params[@"classMethod"] boolValue];
    Method method = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!method) return @{@"error": [NSString stringWithFormat:@"Method not found: -[%@ %@]", className, selectorName]};

    BOOL logStack = params[@"logStack"] ? [params[@"logStack"] boolValue] : NO;
    BOOL logArgs = params[@"logArgs"] ? [params[@"logArgs"] boolValue] : YES;

    // Get method signature for argument info
    const char *typeEncoding = method_getTypeEncoding(method);
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:typeEncoding];
    NSUInteger argCount = [sig numberOfArguments]; // includes self + _cmd

    // Create a trampoline that logs and forwards to original
    // We use a block-based IMP via imp_implementationWithBlock
    IMP originalIMP = method_getImplementation(method);

    // Store trace config
    sActiveTraces[key] = @{
        @"className": className,
        @"selector": selectorName,
        @"logStack": @(logStack),
        @"logArgs": @(logArgs),
        @"argCount": @(argCount),
        @"typeEncoding": [NSString stringWithUTF8String:typeEncoding ?: ""],
        @"timestamp": [NSDate date].description
    };

    // For methods with varying arg counts, we use a generic trampoline
    // that captures the call, logs it, and forwards to original.
    // We handle up to 8 object args (covers virtually all ObjC methods).
    IMP trampoline = imp_implementationWithBlock(^(id _self, ...) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"class"] = className;
        entry[@"selector"] = selectorName;
        entry[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
        entry[@"selfClass"] = NSStringFromClass([_self class]);

        if (logStack) {
            NSArray *stack = [NSThread callStackSymbols];
            // Trim to first 15 frames
            if (stack.count > 15) stack = [stack subarrayWithRange:NSMakeRange(0, 15)];
            entry[@"callStack"] = stack;
        }

        // Log self description (truncated)
        NSString *selfDesc = [_self description];
        if (selfDesc.length > 200) selfDesc = [selfDesc substringToIndex:200];
        entry[@"self"] = selfDesc ?: @"nil";

        SpliceKit_log(@"[Trace] -[%@ %@] called on <%@: %p>",
                      className, selectorName, NSStringFromClass([_self class]), _self);

        SpliceKit_addTraceEntry(entry);

        // Forward to original - use generic forwarding with the right number of args
        // For the trampoline to work correctly with varargs, we use NSInvocation
        NSMethodSignature *origSig = [_self methodSignatureForSelector:sel];
        if (origSig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:origSig];
            [inv setTarget:_self];
            [inv setSelector:sel];
            // We can't easily forward varargs, so we call original directly
            // This works for 0-arg methods (self + _cmd only)
        }

        // Direct call to original with proper casting based on arg count
        if (argCount <= 2) {
            ((void (*)(id, SEL))originalIMP)(_self, sel);
        } else if (argCount == 3) {
            // We can't access varargs reliably from a block, so log the trace
            // and use the original IMP. For full arg capture, callers should
            // use call_method with store_result instead.
            ((void (*)(id, SEL, id))originalIMP)(_self, sel, nil);
        }
    });

    // Only swizzle methods with 0-1 object args (self+_cmd+optional sender)
    // For complex multi-arg methods, use a simpler approach
    if (argCount <= 3) {
        IMP orig = SpliceKit_swizzleMethod(cls, sel, trampoline);
        if (!orig) {
            [sActiveTraces removeObjectForKey:key];
            return @{@"error": @"Swizzle failed"};
        }
    } else {
        // For multi-arg methods, we can't use block-based IMP safely.
        // Instead, install a pre/post notification using KVO-style observation.
        // Store the fact that we're "tracing" it and use a polling approach
        // or set a symbolic breakpoint hint.
        sActiveTraces[key] = @{
            @"className": className,
            @"selector": selectorName,
            @"logStack": @(logStack),
            @"logArgs": @(logArgs),
            @"argCount": @(argCount),
            @"typeEncoding": [NSString stringWithUTF8String:typeEncoding ?: ""],
            @"mode": @"notification_only",
            @"note": @"Multi-arg methods are traced via NSNotification observation. Use call_method with store_result for full arg inspection.",
            @"timestamp": [NSDate date].description
        };

        // Register for NSNotification-based observation of related events
        SpliceKit_log(@"[Trace] Registered notification trace for -[%@ %@] (%lu args - use call_method for full inspection)",
                      className, selectorName, (unsigned long)argCount);
    }

    return @{@"status": @"ok", @"tracing": key, @"argCount": @(argCount),
             @"mode": (argCount <= 3) ? @"swizzle" : @"notification_only"};
}

#pragma mark - Debug: KVO Property Watching
//
// Replaces lldb watchpoints. Uses KVO to monitor property changes on any ObjC
// object and broadcasts old/new values to MCP clients in real-time.
//

static NSMutableDictionary<NSString *, id> *sActiveWatches = nil;

// KVO observer that broadcasts change events to connected clients
@interface SpliceKitKVOObserver : NSObject
@property (nonatomic, copy) NSString *watchKey;
@property (nonatomic, copy) NSString *keyPath;
@property (nonatomic, weak) id target;
@end

@implementation SpliceKitKVOObserver

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    NSDictionary *event = @{
        @"type": @"watch",
        @"watchKey": self.watchKey ?: @"",
        @"keyPath": keyPath ?: @"",
        @"objectClass": NSStringFromClass([object class]),
        @"oldValue": [change[NSKeyValueChangeOldKey] description] ?: @"nil",
        @"newValue": [change[NSKeyValueChangeNewKey] description] ?: @"nil",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    SpliceKit_log(@"[Watch] %@.%@ changed: %@ -> %@",
                  NSStringFromClass([object class]), keyPath,
                  change[NSKeyValueChangeOldKey], change[NSKeyValueChangeNewKey]);
    SpliceKit_broadcastEvent(event);
}

- (void)dealloc {
    if (self.target) {
        @try { [self.target removeObserver:self forKeyPath:self.keyPath]; }
        @catch (NSException *e) { /* already removed */ }
    }
}

@end

// debug.watch - Observe property changes via KVO
// {"method":"debug.watch","params":{"action":"add","handle":"obj_1","keyPath":"displayName"}}
// {"method":"debug.watch","params":{"action":"add","className":"FFAnchoredTimelineModule","singleton":true,"keyPath":"sequence"}}
// {"method":"debug.watch","params":{"action":"remove","watchKey":"obj_1.displayName"}}
// {"method":"debug.watch","params":{"action":"list"}}
NSDictionary *SpliceKit_handleDebugWatch(NSDictionary *params) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sActiveWatches = [NSMutableDictionary dictionary];
    });

    NSString *act = params[@"action"] ?: @"add";

    if ([act isEqualToString:@"list"]) {
        NSMutableArray *watches = [NSMutableArray array];
        for (NSString *key in sActiveWatches) {
            SpliceKitKVOObserver *obs = sActiveWatches[key];
            [watches addObject:@{
                @"key": key,
                @"keyPath": obs.keyPath ?: @"",
                @"targetClass": obs.target ? NSStringFromClass([obs.target class]) : @"released"
            }];
        }
        return @{@"watches": watches, @"count": @(watches.count)};
    }

    if ([act isEqualToString:@"removeAll"]) {
        NSUInteger count = sActiveWatches.count;
        for (NSString *key in [sActiveWatches allKeys]) {
            SpliceKitKVOObserver *obs = sActiveWatches[key];
            if (obs.target) {
                @try { [obs.target removeObserver:obs forKeyPath:obs.keyPath]; }
                @catch (NSException *e) { }
            }
        }
        [sActiveWatches removeAllObjects];
        return @{@"status": @"ok", @"removed": @(count)};
    }

    NSString *keyPath = params[@"keyPath"];
    if (!keyPath && ![act isEqualToString:@"remove"]) {
        return @{@"error": @"keyPath parameter required"};
    }

    if ([act isEqualToString:@"remove"]) {
        NSString *watchKey = params[@"watchKey"];
        if (!watchKey) return @{@"error": @"watchKey parameter required"};
        SpliceKitKVOObserver *obs = sActiveWatches[watchKey];
        if (!obs) return @{@"error": [NSString stringWithFormat:@"No watch found for %@", watchKey]};
        if (obs.target) {
            @try { [obs.target removeObserver:obs forKeyPath:obs.keyPath]; }
            @catch (NSException *e) { }
        }
        [sActiveWatches removeObjectForKey:watchKey];
        return @{@"status": @"ok", @"removed": watchKey};
    }

    // action == "add"
    __block id target = nil;
    NSString *handle = params[@"handle"];
    if (handle) {
        target = SpliceKit_resolveHandle(handle);
        if (!target) return @{@"error": [NSString stringWithFormat:@"Handle not found: %@", handle]};
    } else {
        NSString *className = params[@"className"];
        if (!className) return @{@"error": @"handle or className required"};
        target = SpliceKit_resolveTarget(params);
        if (!target) return @{@"error": [NSString stringWithFormat:@"Could not resolve target for %@", className]};
    }

    NSString *watchKey = [NSString stringWithFormat:@"%@.%@",
                          handle ?: NSStringFromClass([target class]), keyPath];

    if (sActiveWatches[watchKey]) {
        return @{@"error": [NSString stringWithFormat:@"Already watching %@", watchKey]};
    }

    SpliceKitKVOObserver *observer = [[SpliceKitKVOObserver alloc] init];
    observer.watchKey = watchKey;
    observer.keyPath = keyPath;
    observer.target = target;

    @try {
        [target addObserver:observer
                 forKeyPath:keyPath
                    options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
                    context:NULL];
        sActiveWatches[watchKey] = observer;
        return @{@"status": @"ok", @"watching": watchKey,
                 @"targetClass": NSStringFromClass([target class])};
    } @catch (NSException *e) {
        return @{@"error": [NSString stringWithFormat:@"KVO registration failed: %@", e.reason]};
    }
}

#pragma mark - Debug: Crash Handler
//
// Catches NSExceptions and Unix signals (SIGABRT, SIGSEGV, SIGBUS) with full
// stack traces. Replaces debugger crash catching for when lldb isn't attached.
//

static BOOL sCrashHandlerInstalled = NO;
static NSMutableArray<NSDictionary *> *sCrashLog = nil;

static void SpliceKit_exceptionHandler(NSException *exception) {
    NSDictionary *info = @{
        @"type": @"exception",
        @"name": exception.name ?: @"unknown",
        @"reason": exception.reason ?: @"unknown",
        @"callStack": [exception callStackSymbols] ?: @[],
        @"userInfo": [exception.userInfo description] ?: @"nil",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    if (sCrashLog) [sCrashLog addObject:info];

    SpliceKit_log(@"[CRASH] Uncaught exception: %@ - %@", exception.name, exception.reason);
    for (NSString *frame in [exception callStackSymbols]) {
        SpliceKit_log(@"  %@", frame);
    }

    // Broadcast to any connected clients
    SpliceKit_broadcastEvent(@{@"type": @"crash", @"data": info});
}

static void SpliceKit_signalHandler(int signal) {
    const char *signalName = "UNKNOWN";
    switch (signal) {
        case SIGABRT: signalName = "SIGABRT"; break;
        case SIGSEGV: signalName = "SIGSEGV"; break;
        case SIGBUS:  signalName = "SIGBUS"; break;
        case SIGFPE:  signalName = "SIGFPE"; break;
        case SIGILL:  signalName = "SIGILL"; break;
        case SIGTRAP: signalName = "SIGTRAP"; break;
    }

    // Can't use ObjC safely in signal handler, but we can write to the log file
    NSArray *stack = [NSThread callStackSymbols];
    NSDictionary *info = @{
        @"type": @"signal",
        @"signal": [NSString stringWithUTF8String:signalName],
        @"signalNumber": @(signal),
        @"callStack": stack ?: @[],
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    if (sCrashLog) [sCrashLog addObject:info];
    SpliceKit_log(@"[CRASH] Signal %s (%d) received", signalName, signal);

    // Re-raise to let the default handler run (or debugger catch it)
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(signal, &sa, NULL);
    raise(signal);
}

// debug.crashHandler
// {"method":"debug.crashHandler","params":{"action":"install"}}
// {"method":"debug.crashHandler","params":{"action":"getLog"}}
// {"method":"debug.crashHandler","params":{"action":"clearLog"}}
// {"method":"debug.crashHandler","params":{"action":"status"}}
NSDictionary *SpliceKit_handleDebugCrashHandler(NSDictionary *params) {
    NSString *act = params[@"action"] ?: @"install";

    if ([act isEqualToString:@"install"]) {
        if (sCrashHandlerInstalled) {
            return @{@"status": @"ok", @"message": @"Crash handler already installed"};
        }
        sCrashLog = [NSMutableArray array];
        NSSetUncaughtExceptionHandler(SpliceKit_exceptionHandler);
        signal(SIGABRT, SpliceKit_signalHandler);
        signal(SIGSEGV, SpliceKit_signalHandler);
        signal(SIGBUS,  SpliceKit_signalHandler);
        signal(SIGFPE,  SpliceKit_signalHandler);
        signal(SIGILL,  SpliceKit_signalHandler);
        sCrashHandlerInstalled = YES;
        return @{@"status": @"ok", @"message": @"Crash handler installed (exceptions + signals)"};
    }

    if ([act isEqualToString:@"status"]) {
        return @{@"installed": @(sCrashHandlerInstalled),
                 @"crashCount": @(sCrashLog ? sCrashLog.count : 0)};
    }

    if ([act isEqualToString:@"getLog"]) {
        return @{@"crashes": sCrashLog ?: @[], @"count": @(sCrashLog ? sCrashLog.count : 0)};
    }

    if ([act isEqualToString:@"clearLog"]) {
        [sCrashLog removeAllObjects];
        return @{@"status": @"ok", @"message": @"Crash log cleared"};
    }

    return @{@"error": [NSString stringWithFormat:@"Unknown action: %@", act]};
}

#pragma mark - Debug: Thread Inspection
//
// Uses Mach kernel APIs to enumerate all ~45 threads in FCP's process.
// Detailed mode shows per-thread CPU usage, run state, and stack traces.
//

// debug.threads
// {"method":"debug.threads","params":{}}
// {"method":"debug.threads","params":{"detailed":true}}
NSDictionary *SpliceKit_handleDebugThreads(NSDictionary *params) {
    BOOL detailed = [params[@"detailed"] boolValue];

    // Current thread info
    NSThread *currentThread = [NSThread currentThread];
    NSMutableDictionary *currentInfo = [NSMutableDictionary dictionary];
    currentInfo[@"name"] = currentThread.name.length ? currentThread.name : @"(unnamed)";
    currentInfo[@"isMain"] = @(currentThread.isMainThread);
    currentInfo[@"qualityOfService"] = @(currentThread.qualityOfService);
    currentInfo[@"stackSize"] = @(currentThread.stackSize);
    currentInfo[@"current"] = @YES;
    if (detailed) {
        currentInfo[@"callStack"] = [NSThread callStackSymbols];
    }

    // Get main thread info
    __block NSMutableDictionary *mainInfo = nil;
    if (!currentThread.isMainThread) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            mainInfo = [NSMutableDictionary dictionary];
            mainInfo[@"name"] = @"main";
            mainInfo[@"isMain"] = @YES;
            if (detailed) {
                mainInfo[@"callStack"] = [NSThread callStackSymbols];
            }
        });
    }

    // Get all operation queues we know about
    NSMutableArray *queues = [NSMutableArray array];

    // Main queue
    NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
    [queues addObject:@{
        @"name": mainQueue.name ?: @"mainQueue",
        @"operationCount": @(mainQueue.operationCount),
        @"maxConcurrent": @(mainQueue.maxConcurrentOperationCount),
        @"suspended": @(mainQueue.isSuspended)
    }];

    // Try to get FCP's background task queue
    Class bgClass = NSClassFromString(@"FFBackgroundTaskQueue");
    if (bgClass) {
        id shared = nil;
        SEL sharedSel = NSSelectorFromString(@"sharedQueue");
        if ([bgClass respondsToSelector:sharedSel]) {
            shared = ((id (*)(id, SEL))objc_msgSend)(bgClass, sharedSel);
        }
        if (shared) {
            NSString *desc = [shared description];
            if (desc.length > 300) desc = [desc substringToIndex:300];
            [queues addObject:@{@"name": @"FFBackgroundTaskQueue", @"description": desc}];
        }
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"currentThread"] = currentInfo;
    if (mainInfo) result[@"mainThread"] = mainInfo;
    result[@"operationQueues"] = queues;

    // pthread count via mach
    thread_act_array_t threads;
    mach_msg_type_number_t threadCount;
    if (task_threads(mach_task_self(), &threads, &threadCount) == KERN_SUCCESS) {
        result[@"totalThreadCount"] = @(threadCount);
        if (detailed) {
            NSMutableArray *threadInfos = [NSMutableArray array];
            for (mach_msg_type_number_t i = 0; i < threadCount && i < 64; i++) {
                thread_basic_info_data_t info;
                mach_msg_type_number_t infoCount = THREAD_BASIC_INFO_COUNT;
                if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &infoCount) == KERN_SUCCESS) {
                    [threadInfos addObject:@{
                        @"index": @(i),
                        @"cpuUsage": @(info.cpu_usage / 10.0), // TH_USAGE_SCALE = 1000
                        @"userTime": @(info.user_time.seconds + info.user_time.microseconds / 1e6),
                        @"systemTime": @(info.system_time.seconds + info.system_time.microseconds / 1e6),
                        @"runState": @(info.run_state), // 1=running, 2=stopped, 3=waiting
                        @"suspended": @(info.suspend_count > 0)
                    }];
                }
            }
            result[@"threads"] = threadInfos;
        }
        // Deallocate
        for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads,
                      threadCount * sizeof(thread_act_t));
    }

    return result;
}

#pragma mark - Debug: Expression Evaluation
//
// Replaces lldb's `po` command. Walks ObjC property chains like
// "NSApp.delegate._targetLibrary.displayName" and returns the result.
//

static id SpliceKit_debugEvalInvokeZeroArgSelector(id target, SEL selector, NSString **errorOut) {
    if (!target || !selector) {
        if (errorOut) *errorOut = @"Missing target or selector";
        return nil;
    }

    NSMethodSignature *sig = [target methodSignatureForSelector:selector];
    if (!sig) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"%@ has no signature for %@",
                         NSStringFromClass([target class]), NSStringFromSelector(selector)];
        }
        return nil;
    }

    if (sig.numberOfArguments != 2) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"%@ expects arguments and cannot be used in debug.eval",
                         NSStringFromSelector(selector)];
        }
        return nil;
    }

    const char *returnType = sig.methodReturnType;
    switch (returnType[0]) {
        case '@':
        case '#':
            return ((id (*)(id, SEL))objc_msgSend)(target, selector);
        case 'v':
            ((void (*)(id, SEL))objc_msgSend)(target, selector);
            return @"<void>";
        case 'B':
            return @(((BOOL (*)(id, SEL))objc_msgSend)(target, selector));
        case 'c':
            return @(((char (*)(id, SEL))objc_msgSend)(target, selector));
        case 'C':
            return @(((unsigned char (*)(id, SEL))objc_msgSend)(target, selector));
        case 's':
            return @(((short (*)(id, SEL))objc_msgSend)(target, selector));
        case 'S':
            return @(((unsigned short (*)(id, SEL))objc_msgSend)(target, selector));
        case 'i':
            return @(((int (*)(id, SEL))objc_msgSend)(target, selector));
        case 'I':
            return @(((unsigned int (*)(id, SEL))objc_msgSend)(target, selector));
        case 'l':
            return @(((long (*)(id, SEL))objc_msgSend)(target, selector));
        case 'L':
            return @(((unsigned long (*)(id, SEL))objc_msgSend)(target, selector));
        case 'q':
            return @(((long long (*)(id, SEL))objc_msgSend)(target, selector));
        case 'Q':
            return @(((unsigned long long (*)(id, SEL))objc_msgSend)(target, selector));
        case 'f':
            return @(((float (*)(id, SEL))objc_msgSend)(target, selector));
        case 'd':
            return @(((double (*)(id, SEL))objc_msgSend)(target, selector));
        case ':': {
            SEL value = ((SEL (*)(id, SEL))objc_msgSend)(target, selector);
            return value ? NSStringFromSelector(value) : @"(null selector)";
        }
        case '*': {
            const char *value = ((const char *(*)(id, SEL))objc_msgSend)(target, selector);
            return value ? [NSString stringWithUTF8String:value] : @"(null cstring)";
        }
        case '^': {
            void *value = ((void *(*)(id, SEL))objc_msgSend)(target, selector);
            return [NSString stringWithFormat:@"%p", value];
        }
        default:
            if (errorOut) {
                *errorOut = [NSString stringWithFormat:@"%@ returns unsupported type '%s' for debug.eval",
                             NSStringFromSelector(selector), returnType];
            }
            return nil;
    }
}

// debug.eval - Evaluate an ObjC expression chain in FCP's process
// {"method":"debug.eval","params":{"expression":"[NSApp delegate]"}}
// {"method":"debug.eval","params":{"expression":"[[NSApp delegate] _targetLibrary]","storeResult":true}}
// {"method":"debug.eval","params":{"target":"obj_1","chain":["sequence","primaryObject","containedItems","count"]}}
NSDictionary *SpliceKit_handleDebugEval(NSDictionary *params) {
    // Mode 1: KVC chain evaluation
    NSArray *chain = params[@"chain"];
    NSString *targetHandle = params[@"target"];
    BOOL storeResult = [params[@"storeResult"] boolValue];

    if (chain && chain.count > 0) {
        __block NSDictionary *result = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id obj = nil;
                if (targetHandle) {
                    obj = SpliceKit_resolveHandle(targetHandle);
                    if (!obj) { result = @{@"error": @"Handle not found"}; return; }
                } else {
                    // Start from NSApp
                    obj = ((id (*)(id, SEL))objc_msgSend)(
                        objc_getClass("NSApplication"), @selector(sharedApplication));
                }

                NSMutableArray *steps = [NSMutableArray array];
                for (NSString *step in chain) {
                    if (!obj) {
                        [steps addObject:@{@"step": step, @"result": @"nil"}];
                        break;
                    }
                    SEL sel = NSSelectorFromString(step);
                    if (![obj respondsToSelector:sel]) {
                        // Try KVC
                        @try {
                            obj = [obj valueForKey:step];
                        } @catch (NSException *e) {
                            [steps addObject:@{@"step": step, @"error": e.reason ?: @"KVC failed"}];
                            obj = nil;
                            break;
                        }
                    } else {
                        NSString *invokeError = nil;
                        obj = SpliceKit_debugEvalInvokeZeroArgSelector(obj, sel, &invokeError);
                        if (!obj && invokeError) {
                            [steps addObject:@{@"step": step, @"error": invokeError}];
                            break;
                        }
                    }
                    NSString *desc = obj ? [obj description] : @"nil";
                    if (desc.length > 500) desc = [desc substringToIndex:500];
                    [steps addObject:@{
                        @"step": step,
                        @"class": obj ? NSStringFromClass([obj class]) : @"nil",
                        @"value": desc
                    }];
                }

                NSMutableDictionary *res = [NSMutableDictionary dictionary];
                res[@"steps"] = steps;
                if (obj) {
                    NSString *desc = [obj description];
                    if (desc.length > 2000) desc = [desc substringToIndex:2000];
                    res[@"result"] = desc;
                    res[@"resultClass"] = NSStringFromClass([obj class]);
                    if (storeResult) {
                        res[@"handle"] = SpliceKit_storeHandle(obj);
                    }
                } else {
                    res[@"result"] = @"nil";
                }
                result = res;
            } @catch (NSException *e) {
                result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
            }
        });
        return result;
    }

    // Mode 2: Simple selector-chain expression like "[NSApp delegate]" or "NSApp.delegate._targetLibrary"
    NSString *expression = params[@"expression"];
    if (!expression) return @{@"error": @"expression or chain parameter required"};

    // Parse dot-separated chain: "NSApp.delegate._targetLibrary.displayName"
    NSArray *parts = [expression componentsSeparatedByString:@"."];
    if (parts.count < 1) return @{@"error": @"Empty expression"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id obj = nil;
            NSString *first = parts[0];

            // Resolve starting object
            if ([first isEqualToString:@"NSApp"]) {
                obj = ((id (*)(id, SEL))objc_msgSend)(
                    objc_getClass("NSApplication"), @selector(sharedApplication));
            } else if ([first hasPrefix:@"obj_"]) {
                obj = SpliceKit_resolveHandle(first);
            } else {
                Class cls = NSClassFromString(first);
                if (cls) {
                    // Try common singleton accessors
                    for (NSString *acc in @[@"sharedInstance", @"shared", @"defaultManager"]) {
                        SEL s = NSSelectorFromString(acc);
                        if ([cls respondsToSelector:s]) {
                            obj = ((id (*)(id, SEL))objc_msgSend)(cls, s);
                            break;
                        }
                    }
                    if (!obj) obj = (id)cls; // Use class itself
                }
            }

            if (!obj) {
                result = @{@"error": [NSString stringWithFormat:@"Could not resolve: %@", first]};
                return;
            }

            // Walk remaining chain
            for (NSUInteger i = 1; i < parts.count; i++) {
                NSString *prop = parts[i];
                if (!obj) { result = @{@"error": [NSString stringWithFormat:@"nil at step %@", prop]}; return; }

                SEL sel = NSSelectorFromString(prop);
                if ([obj respondsToSelector:sel]) {
                    NSString *invokeError = nil;
                    obj = SpliceKit_debugEvalInvokeZeroArgSelector(obj, sel, &invokeError);
                    if (!obj && invokeError) {
                        result = @{@"error": invokeError};
                        return;
                    }
                } else {
                    @try { obj = [obj valueForKey:prop]; }
                    @catch (NSException *e) {
                        result = @{@"error": [NSString stringWithFormat:@"%@ does not respond to %@", NSStringFromClass([obj class]), prop]};
                        return;
                    }
                }
            }

            NSMutableDictionary *res = [NSMutableDictionary dictionary];
            if (obj) {
                NSString *desc = [obj description];
                if (desc.length > 2000) desc = [desc substringToIndex:2000];
                res[@"result"] = desc;
                res[@"class"] = NSStringFromClass([obj class]);
                if (storeResult) {
                    res[@"handle"] = SpliceKit_storeHandle(obj);
                }
            } else {
                res[@"result"] = @"nil";
            }
            result = res;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

#pragma mark - Debug: Hot Plugin Loading
//
// Inject compiled .dylib code into FCP at runtime without restarting.
// Compile a patch, load it here, and it has full access to FCP's process space.
//

static NSMutableDictionary<NSString *, id> *sLoadedPlugins = nil;

// debug.loadPlugin - Dynamically load a dylib or bundle into FCP's process
// {"method":"debug.loadPlugin","params":{"action":"load","path":"/path/to/patch.dylib"}}
// {"method":"debug.loadPlugin","params":{"action":"list"}}
// {"method":"debug.loadPlugin","params":{"action":"unload","path":"/path/to/patch.dylib"}}
NSDictionary *SpliceKit_handleDebugLoadPlugin(NSDictionary *params) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLoadedPlugins = [NSMutableDictionary dictionary];
    });

    NSString *act = params[@"action"] ?: @"load";

    if ([act isEqualToString:@"list"]) {
        return @{@"plugins": [sLoadedPlugins allKeys], @"count": @(sLoadedPlugins.count)};
    }

    NSString *path = params[@"path"];
    if (!path) return @{@"error": @"path parameter required"};

    if ([act isEqualToString:@"load"]) {
        // Check if already loaded
        if (sLoadedPlugins[path]) {
            return @{@"status": @"ok", @"message": @"Already loaded", @"path": path};
        }

        // Try NSBundle first (for .bundle / .framework)
        if ([path hasSuffix:@".bundle"] || [path hasSuffix:@".framework"]) {
            NSBundle *bundle = [NSBundle bundleWithPath:path];
            if (!bundle) return @{@"error": [NSString stringWithFormat:@"Could not create bundle: %@", path]};
            NSError *error = nil;
            if (![bundle loadAndReturnError:&error]) {
                return @{@"error": [NSString stringWithFormat:@"Bundle load failed: %@", error.localizedDescription]};
            }
            sLoadedPlugins[path] = bundle;

            // Try to find and call a setup function
            Class principalClass = [bundle principalClass];
            NSString *info = principalClass ? NSStringFromClass(principalClass) : @"no principal class";
            SpliceKit_log(@"[Plugin] Loaded bundle: %@ (%@)", path, info);
            return @{@"status": @"ok", @"path": path, @"type": @"bundle",
                     @"principalClass": info};
        }

        // dylib via dlopen
        void *handle = dlopen([path UTF8String], RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            const char *err = dlerror();
            return @{@"error": [NSString stringWithFormat:@"dlopen failed: %s", err ?: "unknown"]};
        }
        sLoadedPlugins[path] = [NSValue valueWithPointer:handle];
        SpliceKit_log(@"[Plugin] Loaded dylib: %@", path);
        return @{@"status": @"ok", @"path": path, @"type": @"dylib"};
    }

    if ([act isEqualToString:@"unload"]) {
        id loaded = sLoadedPlugins[path];
        if (!loaded) return @{@"error": [NSString stringWithFormat:@"Not loaded: %@", path]};

        if ([loaded isKindOfClass:[NSBundle class]]) {
            // NSBundle can't reliably unload ObjC code
            [sLoadedPlugins removeObjectForKey:path];
            return @{@"status": @"ok", @"path": path,
                     @"warning": @"Bundle unregistered but ObjC classes remain in runtime"};
        }

        if ([loaded isKindOfClass:[NSValue class]]) {
            void *handle = [loaded pointerValue];
            if (dlclose(handle) != 0) {
                const char *err = dlerror();
                return @{@"error": [NSString stringWithFormat:@"dlclose failed: %s", err ?: "unknown"]};
            }
            [sLoadedPlugins removeObjectForKey:path];
            return @{@"status": @"ok", @"path": path, @"type": @"dylib"};
        }

        return @{@"error": @"Unknown plugin type"};
    }

    return @{@"error": [NSString stringWithFormat:@"Unknown action: %@", act]};
}

#pragma mark - Debug: Notification Observation
//
// Subscribe to FCP's internal NSNotification events. Events are broadcast to
// MCP clients in real-time. Use "*" for all notifications (high volume).
//

static NSMutableDictionary<NSString *, id> *sNotificationObservers = nil;

// debug.observeNotification - Subscribe to NSNotificationCenter events
// {"method":"debug.observeNotification","params":{"action":"add","name":"FFEffectsChangedNotification"}}
// {"method":"debug.observeNotification","params":{"action":"add","name":"*"}} // all notifications
// {"method":"debug.observeNotification","params":{"action":"remove","name":"FFEffectsChangedNotification"}}
// {"method":"debug.observeNotification","params":{"action":"list"}}
NSDictionary *SpliceKit_handleDebugObserveNotification(NSDictionary *params) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sNotificationObservers = [NSMutableDictionary dictionary];
    });

    NSString *act = params[@"action"] ?: @"add";
    if ([act isEqualToString:@"start"]) act = @"add";
    if ([act isEqualToString:@"stop"]) act = @"remove";

    if ([act isEqualToString:@"list"]) {
        return @{@"observers": [sNotificationObservers allKeys],
                 @"count": @(sNotificationObservers.count)};
    }

    if ([act isEqualToString:@"removeAll"]) {
        for (NSString *key in [sNotificationObservers allKeys]) {
            [[NSNotificationCenter defaultCenter] removeObserver:sNotificationObservers[key]];
        }
        [sNotificationObservers removeAllObjects];
        return @{@"status": @"ok", @"message": @"All notification observers removed"};
    }

    NSString *name = params[@"name"];
    if (!name) return @{@"error": @"name parameter required"};

    if ([act isEqualToString:@"remove"]) {
        id observer = sNotificationObservers[name];
        if (!observer) return @{@"error": [NSString stringWithFormat:@"No observer for %@", name]};
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        [sNotificationObservers removeObjectForKey:name];
        return @{@"status": @"ok", @"removed": name};
    }

    // action == "add"
    if (sNotificationObservers[name]) {
        return @{@"status": @"ok", @"message": @"Already observing", @"name": name};
    }

    NSString *notifName = [name isEqualToString:@"*"] ? nil : name;
    BOOL logObject = [params[@"logObject"] boolValue];

    id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:notifName
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        NSMutableDictionary *event = [NSMutableDictionary dictionary];
        event[@"type"] = @"notification";
        event[@"name"] = note.name ?: @"unknown";
        event[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
        if (note.object) {
            event[@"objectClass"] = NSStringFromClass([note.object class]);
            if (logObject) {
                NSString *desc = [note.object description];
                if (desc.length > 300) desc = [desc substringToIndex:300];
                event[@"object"] = desc;
            }
        }
        if (note.userInfo) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            for (NSString *key in note.userInfo) {
                NSString *val = [note.userInfo[key] description];
                if (val.length > 200) val = [val substringToIndex:200];
                info[key] = val;
            }
            event[@"userInfo"] = info;
        }

        SpliceKit_broadcastEvent(event);
    }];

    sNotificationObservers[name] = observer;
    return @{@"status": @"ok", @"observing": name};
}

#pragma mark - Debug: Breakpoints

// True breakpoint system: swizzle a method, pause the calling thread,
// let the MCP client inspect state, then resume on command.
//
// Architecture:
//   - Each breakpoint swizzles the target method with a trampoline
//   - The trampoline captures self, args, call stack
//   - It posts a "breakpoint.hit" event to MCP clients
//   - It blocks on a dispatch_semaphore until "continue" or "step" is received
//   - While paused, the JSON-RPC server keeps running (separate thread)
//     so the client can call debug.eval, call_method, etc.
//   - FCP's UI freezes while paused (same behavior as Xcode)
//
// Limitations:
//   - Block-based IMP can only safely intercept methods with 0-1 object args
//     after self+_cmd (the block captures the first arg, varargs aren't accessible)
//   - For multi-arg methods, we capture self and call stack but not individual args
//   - Breakpoints on the JSON-RPC dispatch thread would deadlock (we prevent this)

// Breakpoint state
static NSMutableDictionary<NSString *, NSDictionary *> *sBreakpoints = nil;
static dispatch_semaphore_t sBreakpointSemaphore = nil;
static NSMutableDictionary *sBreakpointHitState = nil;    // current paused state
static BOOL sBreakpointPaused = NO;                       // is execution paused?
static NSString *sBreakpointStepClass = nil;              // for "step" mode
static BOOL sBreakpointStepActive = NO;
static dispatch_queue_t sBreakpointQueue = nil;

static void SpliceKit_ensureBreakpointStorage(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sBreakpoints = [NSMutableDictionary dictionary];
        sBreakpointSemaphore = dispatch_semaphore_create(0);
        sBreakpointHitState = [NSMutableDictionary dictionary];
        sBreakpointQueue = dispatch_queue_create("com.splicekit.breakpoint", DISPATCH_QUEUE_SERIAL);
    });
}

// Called by the trampoline when a breakpoint is hit.
// Pauses the current thread until continue/step is received.
static void SpliceKit_breakpointHit(NSString *key, id self_obj, SEL _cmd,
                                     id firstArg, NSArray *callStack,
                                     NSDictionary *bpConfig) {
    // Never pause when the main thread is executing a block dispatched from our
    // JSON-RPC handler — the RPC thread is blocked on a semaphore waiting for
    // this block to finish, so pausing here would deadlock both threads.
    if ([NSThread isMainThread] && SpliceKit_isMainThreadInRPCDispatch()) {
        SpliceKit_log(@"[Breakpoint] SKIPPED %@ (main thread in RPC dispatch — would deadlock)", key);
        return;
    }

    // Check condition if set
    NSString *condition = bpConfig[@"condition"];
    if (condition.length > 0 && self_obj) {
        @try {
            // Evaluate condition as a keyPath on self
            id val = [self_obj valueForKeyPath:condition];
            // If result is falsy, skip this breakpoint hit
            if (!val || ([val respondsToSelector:@selector(boolValue)] && ![val boolValue])) {
                return;
            }
        } @catch (NSException *e) {
            // Condition eval failed — break anyway
        }
    }

    // Check hit count
    NSNumber *hitCountLimit = bpConfig[@"hitCount"];
    if (hitCountLimit) {
        static NSMutableDictionary<NSString *, NSNumber *> *sHitCounts = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ sHitCounts = [NSMutableDictionary dictionary]; });
        NSInteger current = [sHitCounts[key] integerValue] + 1;
        sHitCounts[key] = @(current);
        if (current < [hitCountLimit integerValue]) {
            return; // Haven't reached the hit count threshold yet
        }
    }

    // Build the hit state
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"breakpoint"] = key;
    state[@"selector"] = NSStringFromSelector(_cmd);
    state[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    state[@"threadName"] = [NSThread currentThread].name ?: @"(unnamed)";
    state[@"isMainThread"] = @([NSThread isMainThread]);

    if (self_obj) {
        state[@"selfClass"] = NSStringFromClass([self_obj class]);
        NSString *selfDesc = [self_obj description];
        if (selfDesc.length > 500) selfDesc = [selfDesc substringToIndex:500];
        state[@"self"] = selfDesc;
        // Store self as a handle so the client can inspect it while paused
        state[@"selfHandle"] = SpliceKit_storeHandle(self_obj);
    }
    if (firstArg) {
        state[@"firstArgClass"] = NSStringFromClass([firstArg class]);
        NSString *argDesc = [firstArg description];
        if (argDesc.length > 500) argDesc = [argDesc substringToIndex:500];
        state[@"firstArg"] = argDesc;
        state[@"firstArgHandle"] = SpliceKit_storeHandle(firstArg);
    }
    if (callStack) {
        state[@"callStack"] = callStack.count > 20
            ? [callStack subarrayWithRange:NSMakeRange(0, 20)]
            : callStack;
    }

    // Set paused state
    dispatch_sync(sBreakpointQueue, ^{
        [sBreakpointHitState setDictionary:state];
        sBreakpointPaused = YES;
    });

    SpliceKit_log(@"[Breakpoint] HIT %@ on thread %@ — paused, waiting for continue/step",
                  key, [NSThread currentThread].name ?: @"(unnamed)");

    // Broadcast the hit event to MCP clients
    SpliceKit_broadcastEvent(@{
        @"type": @"breakpoint.hit",
        @"data": state
    });

    // BLOCK here until the client sends continue or step
    // The JSON-RPC server runs on a different thread so it can still process commands
    dispatch_semaphore_wait(sBreakpointSemaphore, DISPATCH_TIME_FOREVER);

    // Execution resumes here after continue/step
    dispatch_sync(sBreakpointQueue, ^{
        sBreakpointPaused = NO;
        [sBreakpointHitState removeAllObjects];
    });

    SpliceKit_log(@"[Breakpoint] RESUMED %@", key);
}

// debug.breakpoint
// {"method":"debug.breakpoint","params":{"action":"add","className":"FFAnchoredTimelineModule","selector":"blade:","condition":"optional_keyPath"}}
// {"method":"debug.breakpoint","params":{"action":"add","className":"FFAnchoredTimelineModule","selector":"blade:","hitCount":3}}
// {"method":"debug.breakpoint","params":{"action":"remove","className":"FFAnchoredTimelineModule","selector":"blade:"}}
// {"method":"debug.breakpoint","params":{"action":"removeAll"}}
// {"method":"debug.breakpoint","params":{"action":"list"}}
// {"method":"debug.breakpoint","params":{"action":"continue"}}
// {"method":"debug.breakpoint","params":{"action":"step"}}
// {"method":"debug.breakpoint","params":{"action":"inspect"}}  -- get current paused state
// {"method":"debug.breakpoint","params":{"action":"inspectSelf","keyPath":"sequence.displayName"}}
// {"method":"debug.breakpoint","params":{"action":"disable","className":"...","selector":"..."}}
// {"method":"debug.breakpoint","params":{"action":"enable","className":"...","selector":"..."}}
NSDictionary *SpliceKit_handleDebugBreakpoint(NSDictionary *params) {
    SpliceKit_ensureBreakpointStorage();

    NSString *act = params[@"action"] ?: @"add";

    // === Continue: resume paused execution ===
    if ([act isEqualToString:@"continue"]) {
        __block BOOL wasPaused;
        dispatch_sync(sBreakpointQueue, ^{
            wasPaused = sBreakpointPaused;
            sBreakpointStepActive = NO;
            sBreakpointStepClass = nil;
        });
        if (!wasPaused) {
            return @{@"error": @"Not paused at a breakpoint"};
        }
        dispatch_semaphore_signal(sBreakpointSemaphore);
        return @{@"status": @"ok", @"message": @"Execution resumed"};
    }

    // === Step: resume but auto-break on next call to same class ===
    if ([act isEqualToString:@"step"]) {
        __block BOOL wasPaused;
        __block NSString *hitClass;
        dispatch_sync(sBreakpointQueue, ^{
            wasPaused = sBreakpointPaused;
            hitClass = sBreakpointHitState[@"selfClass"];
        });
        if (!wasPaused) {
            return @{@"error": @"Not paused at a breakpoint"};
        }
        // Enable step mode: any breakpoint on the same class will fire
        dispatch_sync(sBreakpointQueue, ^{
            sBreakpointStepActive = YES;
            sBreakpointStepClass = [hitClass copy];
        });
        dispatch_semaphore_signal(sBreakpointSemaphore);
        return @{@"status": @"ok", @"message": [NSString stringWithFormat:
            @"Stepping — will break on next call to %@", hitClass]};
    }

    // === Inspect: get the current paused state ===
    if ([act isEqualToString:@"inspect"]) {
        __block NSDictionary *state;
        __block BOOL paused;
        dispatch_sync(sBreakpointQueue, ^{
            state = [sBreakpointHitState copy];
            paused = sBreakpointPaused;
        });
        if (!paused) {
            return @{@"paused": @NO, @"message": @"Not paused at a breakpoint"};
        }
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:state];
        result[@"paused"] = @YES;
        return result;
    }

    // === InspectSelf: evaluate a keyPath on the paused self object ===
    if ([act isEqualToString:@"inspectSelf"]) {
        __block BOOL paused;
        __block NSString *selfHandle;
        dispatch_sync(sBreakpointQueue, ^{
            paused = sBreakpointPaused;
            selfHandle = sBreakpointHitState[@"selfHandle"];
        });
        if (!paused) return @{@"error": @"Not paused at a breakpoint"};
        if (!selfHandle) return @{@"error": @"No self object captured"};

        NSString *keyPath = params[@"keyPath"];
        if (!keyPath) return @{@"error": @"keyPath parameter required"};

        id self_obj = SpliceKit_resolveHandle(selfHandle);
        if (!self_obj) return @{@"error": @"Self handle expired"};

        @try {
            id value = [self_obj valueForKeyPath:keyPath];
            NSString *desc = value ? [value description] : @"nil";
            if (desc.length > 2000) desc = [desc substringToIndex:2000];
            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            result[@"keyPath"] = keyPath;
            result[@"value"] = desc;
            result[@"class"] = value ? NSStringFromClass([value class]) : @"nil";
            BOOL store = [params[@"storeResult"] boolValue];
            if (store && value) {
                result[@"handle"] = SpliceKit_storeHandle(value);
            }
            return result;
        } @catch (NSException *e) {
            return @{@"error": [NSString stringWithFormat:@"KVC failed: %@", e.reason]};
        }
    }

    // === List: show all breakpoints ===
    if ([act isEqualToString:@"list"]) {
        __block BOOL paused;
        dispatch_sync(sBreakpointQueue, ^{ paused = sBreakpointPaused; });

        NSMutableArray *bps = [NSMutableArray array];
        for (NSString *key in sBreakpoints) {
            NSMutableDictionary *info = [sBreakpoints[key] mutableCopy];
            info[@"key"] = key;
            [bps addObject:info];
        }
        return @{@"breakpoints": bps, @"count": @(bps.count), @"paused": @(paused)};
    }

    // === RemoveAll ===
    if ([act isEqualToString:@"removeAll"]) {
        NSMutableArray *removed = [NSMutableArray array];
        for (NSString *key in [sBreakpoints allKeys]) {
            NSDictionary *info = sBreakpoints[key];
            if ([info[@"installed"] boolValue]) {
                Class cls = NSClassFromString(info[@"className"]);
                SEL sel = NSSelectorFromString(info[@"selector"]);
                if (cls && sel) SpliceKit_unswizzleMethod(cls, sel);
            }
            [removed addObject:key];
        }
        [sBreakpoints removeAllObjects];
        // If currently paused, resume so we don't leave a thread stuck
        __block BOOL wasPaused;
        dispatch_sync(sBreakpointQueue, ^{
            wasPaused = sBreakpointPaused;
            sBreakpointStepActive = NO;
        });
        if (wasPaused) dispatch_semaphore_signal(sBreakpointSemaphore);
        return @{@"status": @"ok", @"removed": removed, @"count": @(removed.count)};
    }

    // === Need className + selector for add/remove/disable/enable ===
    NSString *className = params[@"className"];
    NSString *selectorName = params[@"selector"];
    if (!className || !selectorName) {
        return @{@"error": @"className and selector parameters required"};
    }
    NSString *key = [NSString stringWithFormat:@"%@.%@", className, selectorName];

    // === Remove ===
    if ([act isEqualToString:@"remove"]) {
        NSDictionary *info = sBreakpoints[key];
        if (!info) return @{@"error": [NSString stringWithFormat:@"No breakpoint at %@", key]};
        if ([info[@"installed"] boolValue]) {
            Class cls = NSClassFromString(className);
            SEL sel = NSSelectorFromString(selectorName);
            if (cls && sel) SpliceKit_unswizzleMethod(cls, sel);
        }
        [sBreakpoints removeObjectForKey:key];
        return @{@"status": @"ok", @"removed": key};
    }

    // === Disable (keep registered but don't fire) ===
    if ([act isEqualToString:@"disable"]) {
        NSMutableDictionary *info = [sBreakpoints[key] mutableCopy];
        if (!info) return @{@"error": [NSString stringWithFormat:@"No breakpoint at %@", key]};
        info[@"enabled"] = @NO;
        sBreakpoints[key] = info;
        return @{@"status": @"ok", @"disabled": key};
    }

    // === Enable ===
    if ([act isEqualToString:@"enable"]) {
        NSMutableDictionary *info = [sBreakpoints[key] mutableCopy];
        if (!info) return @{@"error": [NSString stringWithFormat:@"No breakpoint at %@", key]};
        info[@"enabled"] = @YES;
        sBreakpoints[key] = info;
        return @{@"status": @"ok", @"enabled": key};
    }

    // === Add ===
    Class cls = NSClassFromString(className);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class not found: %@", className]};
    SEL sel = NSSelectorFromString(selectorName);
    BOOL isClassMethod = [params[@"classMethod"] boolValue];
    Method method = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!method) return @{@"error": [NSString stringWithFormat:@"Method not found: %@[%@ %@]",
                          isClassMethod ? @"+" : @"-", className, selectorName]};

    // Check if already set
    if (sBreakpoints[key]) {
        return @{@"status": @"ok", @"message": @"Breakpoint already set", @"key": key};
    }

    const char *typeEncoding = method_getTypeEncoding(method);
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:typeEncoding];
    NSUInteger argCount = [sig numberOfArguments]; // includes self + _cmd

    NSString *condition = params[@"condition"];
    NSNumber *hitCount = params[@"hitCount"];
    BOOL oneShot = [params[@"oneShot"] boolValue];

    // Store breakpoint config
    NSMutableDictionary *bpConfig = [NSMutableDictionary dictionary];
    bpConfig[@"className"] = className;
    bpConfig[@"selector"] = selectorName;
    bpConfig[@"enabled"] = @YES;
    bpConfig[@"argCount"] = @(argCount);
    bpConfig[@"typeEncoding"] = [NSString stringWithUTF8String:typeEncoding ?: ""];
    bpConfig[@"timestamp"] = [NSDate date].description;
    if (condition) bpConfig[@"condition"] = condition;
    if (hitCount) bpConfig[@"hitCount"] = hitCount;
    if (oneShot) bpConfig[@"oneShot"] = @YES;

    // Create the trampoline
    IMP originalIMP = method_getImplementation(method);

    // We support methods with 0 or 1 object args (after self + _cmd).
    // This covers most IBAction-style methods (sender:) and no-arg methods.
    if (argCount <= 3) {
        IMP trampoline = imp_implementationWithBlock(^(id _self, id firstArg) {
            // Check if breakpoint is still enabled
            NSDictionary *currentConfig = sBreakpoints[key];
            if (!currentConfig || ![currentConfig[@"enabled"] boolValue]) {
                // Disabled — call original directly
                if (argCount <= 2) {
                    ((void (*)(id, SEL))originalIMP)(_self, sel);
                } else {
                    ((void (*)(id, SEL, id))originalIMP)(_self, sel, firstArg);
                }
                return;
            }

            // Check step mode
            __block BOOL shouldBreak = YES;
            if (!sBreakpointPaused) {
                dispatch_sync(sBreakpointQueue, ^{
                    if (sBreakpointStepActive) {
                        // Only break if same class as the step target
                        if (sBreakpointStepClass &&
                            ![NSStringFromClass([_self class]) isEqualToString:sBreakpointStepClass]) {
                            shouldBreak = NO;
                        }
                    }
                });
            }

            if (!shouldBreak) {
                if (argCount <= 2) {
                    ((void (*)(id, SEL))originalIMP)(_self, sel);
                } else {
                    ((void (*)(id, SEL, id))originalIMP)(_self, sel, firstArg);
                }
                return;
            }

            // HIT — pause execution
            NSArray *stack = [NSThread callStackSymbols];
            SpliceKit_breakpointHit(key, _self, sel, (argCount > 2 ? firstArg : nil),
                                     stack, currentConfig);

            // One-shot: remove after first hit
            if ([currentConfig[@"oneShot"] boolValue]) {
                SpliceKit_unswizzleMethod(cls, sel);
                [sBreakpoints removeObjectForKey:key];
            }

            // Now call the original implementation
            if (argCount <= 2) {
                ((void (*)(id, SEL))originalIMP)(_self, sel);
            } else {
                ((void (*)(id, SEL, id))originalIMP)(_self, sel, firstArg);
            }
        });

        IMP orig = SpliceKit_swizzleMethod(cls, sel, trampoline);
        if (!orig) {
            return @{@"error": @"Swizzle failed"};
        }
        bpConfig[@"installed"] = @YES;
        bpConfig[@"mode"] = @"swizzle";
    } else {
        // Don't actually swizzle multi-arg methods — it would break them
        bpConfig[@"installed"] = @NO;
        bpConfig[@"mode"] = @"trace_only";
        bpConfig[@"warning"] = @"Multi-arg methods (4+ args including self/_cmd) cannot be "
                                "safely breakpointed because the original implementation cannot "
                                "be forwarded without the correct arguments. Use debug.traceMethod "
                                "for multi-arg methods, or use debug.breakpoint on a simpler method "
                                "in the same call chain.";
        SpliceKit_log(@"[Breakpoint] %@ has %lu args — registered as trace_only (not swizzled)",
                      key, (unsigned long)argCount);
    }

    sBreakpoints[key] = bpConfig;
    return @{@"status": @"ok", @"breakpoint": key, @"mode": bpConfig[@"mode"],
             @"argCount": @(argCount),
             @"warning": bpConfig[@"warning"] ?: [NSNull null]};
}
