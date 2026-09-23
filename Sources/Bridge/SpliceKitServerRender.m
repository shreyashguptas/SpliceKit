//
//  SpliceKitServerRender.m
//  SpliceKit - Background render status and control (backgroundRender.*): the render
//  queues, renderer manager and render defaults.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Background Render (backgroundRender.*)

static id SpliceKit_backgroundRenderSharedObject(NSString *className, NSArray<NSString *> *selectorNames) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;

    for (NSString *selectorName in selectorNames) {
        SEL sel = NSSelectorFromString(selectorName);
        if ([cls respondsToSelector:sel]) {
            return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
        }
    }

    return nil;
}

static id SpliceKit_backgroundRenderValueForKey(id obj, NSString *key) {
    if (!obj || key.length == 0) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static id SpliceKit_backgroundRenderJSONValue(id value) {
    if (!value) return [NSNull null];

    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] || value == [NSNull null]) {
        return value;
    }

    if ([value isKindOfClass:[NSDate class]]) {
        NSDate *date = (NSDate *)value;
        return @{
            @"description": date.description ?: @"",
            @"secondsFromNow": @([date timeIntervalSinceNow]),
            @"timeIntervalSince1970": @([date timeIntervalSince1970]),
        };
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            [items addObject:SpliceKit_backgroundRenderJSONValue(item)];
        }
        return items;
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
            NSString *jsonKey = [key isKindOfClass:[NSString class]] ? key : [key description];
            dict[jsonKey ?: @"<null>"] = SpliceKit_backgroundRenderJSONValue(obj);
        }];
        return dict;
    }

    return [value description] ?: [NSNull null];
}

static NSDictionary *SpliceKit_backgroundRenderDescribeQueue(NSOperationQueue *queue, NSString *name) {
    if (!queue) return @{};

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"name"] = name ?: queue.name ?: @"";
    result[@"operationCount"] = @(queue.operationCount);
    result[@"maxConcurrentOperationCount"] = @(queue.maxConcurrentOperationCount);
    result[@"suspended"] = @(queue.isSuspended);
    result[@"qualityOfService"] = @(queue.qualityOfService);
    return result;
}

static NSDictionary *SpliceKit_collectBackgroundRenderStatusOnMainThread(void) {
    id bgQueue = SpliceKit_backgroundRenderSharedObject(@"FFBackgroundTaskQueue", @[@"sharedInstance", @"sharedQueue"]);
    id bgManager = SpliceKit_backgroundRenderSharedObject(@"FFBackgroundRenderManager", @[@"sharedInstance", @"copySharedInstance"]);
    id rendererManager = SpliceKit_backgroundRenderSharedObject(@"FFHGRendererManager", @[@"sharedManager", @"sharedInstance"]);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"available"] = @((bgQueue != nil) || (bgManager != nil));

    if (bgQueue) {
        NSMutableDictionary *queueStatus = [NSMutableDictionary dictionary];
        queueStatus[@"class"] = NSStringFromClass([bgQueue class]) ?: @"";

        SEL inLOSel = NSSelectorFromString(@"inLowOverheadMode");
        if ([bgQueue respondsToSelector:inLOSel]) {
            queueStatus[@"inLowOverheadMode"] = @(((BOOL (*)(id, SEL))objc_msgSend)(bgQueue, inLOSel));
        }

        id loExitTime = SpliceKit_backgroundRenderValueForKey(bgQueue, @"_loExitTime");
        if (loExitTime) queueStatus[@"lowOverheadExitTime"] = SpliceKit_backgroundRenderJSONValue(loExitTime);

        NSOperationQueue *generalQueue = SpliceKit_backgroundRenderValueForKey(bgQueue, @"_generalQueue");
        if (generalQueue) {
            queueStatus[@"generalQueue"] = SpliceKit_backgroundRenderDescribeQueue(generalQueue, generalQueue.name);
        }

        NSDictionary *runGroups = SpliceKit_backgroundRenderValueForKey(bgQueue, @"_runGroups");
        if ([runGroups isKindOfClass:[NSDictionary class]]) {
            NSMutableArray *runGroupStates = [NSMutableArray array];
            NSArray *sortedKeys = [[runGroups allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
            for (id key in sortedKeys) {
                id queueObj = runGroups[key];
                if ([queueObj isKindOfClass:[NSOperationQueue class]]) {
                    NSDictionary *queueDesc = SpliceKit_backgroundRenderDescribeQueue((NSOperationQueue *)queueObj, [key description]);
                    [runGroupStates addObject:queueDesc];
                    if ([[key description] isEqualToString:@"Background Render"]) {
                        queueStatus[@"backgroundRenderQueue"] = queueDesc;
                    }
                }
            }
            queueStatus[@"runGroups"] = runGroupStates;
        }

        result[@"taskQueue"] = queueStatus;
    }

    if (bgManager) {
        NSMutableDictionary *managerStatus = [NSMutableDictionary dictionary];
        managerStatus[@"class"] = NSStringFromClass([bgManager class]) ?: @"";

        for (NSString *key in @[@"_suspended", @"_loOverhead", @"_autoStart", @"_autoStartDelay", @"_reportedFullyComplete"]) {
            id value = SpliceKit_backgroundRenderValueForKey(bgManager, key);
            if (value) {
                NSString *cleanKey = [key hasPrefix:@"_"] ? [key substringFromIndex:1] : key;
                managerStatus[cleanKey] = SpliceKit_backgroundRenderJSONValue(value);
            }
        }

        id earliestRunTime = SpliceKit_backgroundRenderValueForKey(bgManager, @"_earliestRunTime");
        if (earliestRunTime) managerStatus[@"earliestRunTime"] = SpliceKit_backgroundRenderJSONValue(earliestRunTime);

        NSOperationQueue *houseKeepingQueue = SpliceKit_backgroundRenderValueForKey(bgManager, @"_houseKeepingOpQueue");
        if (houseKeepingQueue) {
            managerStatus[@"houseKeepingQueue"] = SpliceKit_backgroundRenderDescribeQueue(houseKeepingQueue, houseKeepingQueue.name);
        }

        result[@"manager"] = managerStatus;
    }

    if (rendererManager) {
        NSMutableDictionary *rendererStatus = [NSMutableDictionary dictionary];
        rendererStatus[@"class"] = NSStringFromClass([rendererManager class]) ?: @"";

        SEL gpuCountSel = NSSelectorFromString(@"getGPUCount");
        if ([rendererManager respondsToSelector:gpuCountSel]) {
            rendererStatus[@"gpuCount"] = @(((int (*)(id, SEL))objc_msgSend)(rendererManager, gpuCountSel));
        }

        SEL hasEGPUSel = NSSelectorFromString(@"hasExternalGPU");
        if ([rendererManager respondsToSelector:hasEGPUSel]) {
            rendererStatus[@"hasExternalGPU"] = @(((BOOL (*)(id, SEL))objc_msgSend)(rendererManager, hasEGPUSel));
        }

        result[@"rendererManager"] = rendererStatus;
    }

    result[@"defaults"] = @{
        @"autoRenderDelay": SpliceKit_backgroundRenderJSONValue([defaults objectForKey:@"FFAutoRenderDelay"]),
        @"resourceChoiceMode": SpliceKit_backgroundRenderJSONValue([defaults objectForKey:@"FFPlayerBackgroundRenderResourceChoiceMode"]),
        @"gpuDescriptions": SpliceKit_backgroundRenderJSONValue([defaults objectForKey:@"FFPlayerBackgroundRenderGPUDescriptions"]),
        @"useQOSUtilityForRender": SpliceKit_backgroundRenderJSONValue([defaults objectForKey:@"FFPlayerUseQOSUtilityForRender"]),
    };

    return result;
}

NSDictionary *SpliceKit_handleBackgroundRenderStatus(__unused NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            result = SpliceKit_collectBackgroundRenderStatusOnMainThread();
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason ?: e.description]};
        }
    });
    return result ?: @{@"error": @"Unable to collect background render status"};
}

NSDictionary *SpliceKit_handleBackgroundRenderControl(NSDictionary *params) {
    NSString *action = [params[@"action"] lowercaseString];
    NSNumber *secondsValue = params[@"seconds"];
    if (action.length == 0) {
        return @{@"error": @"'action' parameter required ('hold_off' or 'low_overhead')"};
    }
    if (!secondsValue) {
        return @{@"error": @"'seconds' parameter required (> 0)"};
    }

    double seconds = [secondsValue doubleValue];
    if (seconds <= 0.0) {
        return @{@"error": @"'seconds' must be > 0"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            if ([action isEqualToString:@"hold_off"] || [action isEqualToString:@"holdoff"]) {
                id manager = SpliceKit_backgroundRenderSharedObject(@"FFBackgroundRenderManager", @[@"sharedInstance", @"copySharedInstance"]);
                SEL sel = NSSelectorFromString(@"holdOffBGRenderFor:");
                if (!manager || ![manager respondsToSelector:sel]) {
                    result = @{@"error": @"FFBackgroundRenderManager holdOffBGRenderFor: unavailable"};
                    return;
                }
                ((void (*)(id, SEL, double))objc_msgSend)(manager, sel, seconds);
                result = @{
                    @"status": @"ok",
                    @"action": @"hold_off",
                    @"seconds": @(seconds),
                    @"snapshot": SpliceKit_collectBackgroundRenderStatusOnMainThread(),
                };
                return;
            }

            if ([action isEqualToString:@"low_overhead"] || [action isEqualToString:@"lowoverhead"]) {
                id queue = SpliceKit_backgroundRenderSharedObject(@"FFBackgroundTaskQueue", @[@"sharedInstance", @"sharedQueue"]);
                SEL sel = NSSelectorFromString(@"runLowOverHeadForTime:");
                if (!queue || ![queue respondsToSelector:sel]) {
                    result = @{@"error": @"FFBackgroundTaskQueue runLowOverHeadForTime: unavailable"};
                    return;
                }
                ((void (*)(id, SEL, double))objc_msgSend)(queue, sel, seconds);
                result = @{
                    @"status": @"ok",
                    @"action": @"low_overhead",
                    @"seconds": @(seconds),
                    @"snapshot": SpliceKit_collectBackgroundRenderStatusOnMainThread(),
                };
                return;
            }

            result = @{@"error": [NSString stringWithFormat:
                @"Unknown action '%@'. Valid actions: hold_off, low_overhead", action]};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason ?: e.description]};
        }
    });
    return result ?: @{@"error": @"Unable to control background render state"};
}
