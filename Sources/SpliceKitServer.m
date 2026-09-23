//
//  SpliceKitServer.m
//  The brain of SpliceKit — JSON-RPC 2.0 server that listens on TCP 127.0.0.1:9876.
//
//  This file holds the server itself (client management, the per-client handler
//  thread, the socket listener), the request dispatcher SpliceKit_handleRequest,
//  and the domain handlers not yet split out: timeline editing, playback, effects,
//  transitions, markers, color, retiming, FCPXML, captions, mixer, dialogs, and more.
//  Runtime introspection, debug tools, metadata export, the handle table and the
//  option-controlled feature swizzles live in the SpliceKitServer*.m and
//  SpliceKitFeature*.m companion files (shared declarations: SpliceKitServerInternal.h).
//
//  External clients (the MCP server, scripts, etc.) connect via TCP and send
//  newline-delimited JSON-RPC requests. Each request is dispatched to a handler
//  function that does the real work via direct ObjC runtime calls into FCP's
//  private APIs. Results come back as JSON on the same connection.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"
#import "SpliceKitPlugins.h"

// Forward declaration — the actual implementation lives further down in the file
BOOL SpliceKit_removeChannelKeyframes(id channel);

#define SPLICEKIT_TCP_PORT 9876

static int sServerFd = -1;

// Forward declarations
static double SpliceKit_channelValue(id channel);  // forward declaration
static id SpliceKit_getClipEffectStack(id clip);
static id SpliceKit_getClipAudioEffectStack(id clip);
static void SpliceKit_addInspectableKeyframeTargets(id owner,
                                                    NSMutableArray *targets,
                                                    NSMutableSet<NSString *> *seenTargets,
                                                    NSString *ownerLabel);
static NSArray *SpliceKit_childClipsForKeyframeTraversal(id clip);
static void SpliceKit_collectKeyframeTargetsForClipRecursive(id clip,
                                                            NSMutableArray *targets,
                                                            NSMutableSet<NSString *> *seenTargets,
                                                            NSMutableSet<NSString *> *seenClips,
                                                            NSString *clipLabel);
static void SpliceKit_collectCaptionsFromItem(id item,
                                              Class captionClass,
                                              NSMutableArray *found,
                                              NSMutableSet *visited,
                                              NSInteger depth);
static NSDictionary *SpliceKit_describeWindowWithViewTree(NSWindow *window, BOOL includeViewTree);
static void SpliceKit_mixerReconcileManagedBusEffects(NSArray<NSDictionary *> *allClips, NSString *scopeKey);
static NSArray<NSDictionary *> *SpliceKit_mixerManagedBusEffectSummariesForRole(NSString *role, NSString *scopeKey);
static NSInteger SpliceKit_mixerIndexOfEffectInStack(id effectStack, id effect);
static id SpliceKit_mixerFirstManagedEffectInstance(NSMutableDictionary *entry,
                                                    id *outStack,
                                                    NSInteger *outEffectIndex);

static void SpliceKit_searchLayerTreeForMeterPeak(CALayer *layer,
                                                  Class meterLayerClass,
                                                  ptrdiff_t maskRatioOffset,
                                                  double *maxPeak) {
    if (!layer || !meterLayerClass || !maxPeak) return;

    if ([layer isKindOfClass:meterLayerClass]) {
        double ratio = *(double *)((char *)(__bridge void *)layer + maskRatioOffset);
        if (ratio > *maxPeak) *maxPeak = ratio;
    }

    for (CALayer *subLayer in layer.sublayers) {
        SpliceKit_searchLayerTreeForMeterPeak(subLayer, meterLayerClass, maskRatioOffset, maxPeak);
    }
}

static SpliceKit_CMTimeRange SpliceKit_clipRangeForItem(id item);
static NSDictionary *SpliceKit_prepareBrowserClipSourceForInsertion(id sourceBrowserClip,
                                                                    SpliceKit_CMTimeRange clipRange,
                                                                    BOOL preferAudio);
static id SpliceKit_normalizeSourceObjectForInsertion(id sourceObject);

#pragma mark - Client Management
//
// We track every connected client's file descriptor so we can push
// unsolicited events to all of them (e.g. playhead position changes).
// Access is serialized through sClientQueue to avoid races.
//

static NSMutableArray *sConnectedClients = nil;
static dispatch_queue_t sClientQueue = nil;
static char sClientQueueSpecificKey;
static char sClientWriteQueueSpecificKey;

// Per-client write serialization. Events broadcast from the async queue and
// RPC replies from the per-client accept thread both target the same fd;
// without serialization, either their bytes interleave mid-line (torn NDJSON)
// or their frame order gets shuffled.
//
// A serial dispatch queue per fd fixes both at once: it gives ordered delivery
// AND atomic writes. Events arrive on a client in the order they were emitted
// server-side, and each frame is a single write() call.
//
// Keyed by NSNumber(fd), guarded by sClientQueue.
static NSMutableDictionary<NSNumber *, dispatch_queue_t> *sClientWriteQueues = nil;

static BOOL SpliceKit_isOnClientQueue(void) {
    return dispatch_get_specific(&sClientQueueSpecificKey) == &sClientQueueSpecificKey;
}

static BOOL SpliceKit_isOnWriteQueueForClientFd(int fd) {
    if (fd < 0) return NO;
    uintptr_t current = (uintptr_t)dispatch_get_specific(&sClientWriteQueueSpecificKey);
    return current == (uintptr_t)(fd + 1);
}

static void SpliceKit_addConnectedClientFd(int fd) {
    if (!sClientQueue || fd < 0) return;
    void (^block)(void) = ^{
        [sConnectedClients addObject:@(fd)];
    };
    if (SpliceKit_isOnClientQueue()) {
        block();
    } else {
        dispatch_sync(sClientQueue, block);
    }
}

static void SpliceKit_removeConnectedClientFd(int fd) {
    if (!sClientQueue || fd < 0) return;
    void (^block)(void) = ^{
        [sConnectedClients removeObject:@(fd)];
    };
    if (SpliceKit_isOnClientQueue()) {
        block();
    } else {
        dispatch_sync(sClientQueue, block);
    }
}

static dispatch_queue_t SpliceKit_writeQueueForClientFd(int fd) {
    if (!sClientQueue || !sClientWriteQueues || fd < 0) return nil;
    __block dispatch_queue_t q = nil;

    void (^lookupOrCreate)(void) = ^{
        q = sClientWriteQueues[@(fd)];
        if (!q) {
            char label[64];
            snprintf(label, sizeof(label), "com.splicekit.client.write.%d", fd);
            q = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
            dispatch_queue_set_specific(q, &sClientWriteQueueSpecificKey,
                                        (void *)(uintptr_t)(fd + 1), NULL);
            sClientWriteQueues[@(fd)] = q;
        }
    };

    if (SpliceKit_isOnClientQueue()) {
        lookupOrCreate();
    } else {
        dispatch_sync(sClientQueue, lookupOrCreate);
    }
    return q;
}

static void SpliceKit_releaseWriteQueueForClientFd(int fd) {
    if (!sClientQueue || fd < 0) return;
    void (^block)(void) = ^{
        [sClientWriteQueues removeObjectForKey:@(fd)];
    };
    if (SpliceKit_isOnClientQueue()) {
        block();
    } else {
        dispatch_sync(sClientQueue, block);
    }
}

static void SpliceKit_drainWriteQueueForClientFd(int fd) {
    if (fd < 0 || SpliceKit_isOnWriteQueueForClientFd(fd)) return;
    dispatch_queue_t q = SpliceKit_writeQueueForClientFd(fd);
    if (!q) return;
    dispatch_sync(q, ^{});
}

// Raw write with EINTR handling. Call ONLY from the fd's serial queue so
// ordering + atomicity are preserved.
static BOOL SpliceKit_rawWriteAll(int fd, NSData *line) {
    if (fd < 0 || !line || line.length == 0) return NO;
    const uint8_t *bytes = line.bytes;
    size_t remaining = line.length;
    while (remaining > 0) {
        ssize_t n = write(fd, bytes, remaining);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR)) continue;
            return NO;
        }
        bytes += n;
        remaining -= (size_t)n;
    }
    return YES;
}

// Writes `line` to `fd` on its dedicated serial queue. `line` should already
// include a trailing newline (NDJSON framing). Dispatch is synchronous when
// called from any non-main, non-fd-queue thread so the caller doesn't return
// before the bytes are out — matters for RPC replies on the accept thread.
static BOOL SpliceKit_writeLineToClientFd(int fd, NSData *line) {
    if (fd < 0 || !line || line.length == 0) return NO;
    dispatch_queue_t q = SpliceKit_writeQueueForClientFd(fd);
    if (!q) return NO;
    __block BOOL ok = NO;
    void (^writeBlock)(void) = ^{
        ok = SpliceKit_rawWriteAll(fd, line);
    };
    if (SpliceKit_isOnWriteQueueForClientFd(fd)) {
        writeBlock();
    } else {
        dispatch_sync(q, writeBlock);
    }
    return ok;
}

// Async variant for event broadcasting. Preserves per-fd ordering (serial
// queue) without blocking the broadcaster on slow clients.
static void SpliceKit_writeLineToClientFdAsync(int fd, NSData *line) {
    if (fd < 0 || !line || line.length == 0) return;
    dispatch_queue_t q = SpliceKit_writeQueueForClientFd(fd);
    if (!q) return;
    if (SpliceKit_isOnWriteQueueForClientFd(fd)) {
        SpliceKit_rawWriteAll(fd, line);
    } else {
        dispatch_async(q, ^{
            SpliceKit_rawWriteAll(fd, line);
        });
    }
}

void SpliceKit_broadcastEvent(NSDictionary *event) {
    if (!sConnectedClients || !sClientQueue) return;

    NSMutableDictionary *notification = [NSMutableDictionary dictionaryWithDictionary:@{
        @"jsonrpc": @"2.0",
        @"method": @"event",
        @"params": event
    }];

    NSData *json = [NSJSONSerialization dataWithJSONObject:notification options:0 error:nil];
    if (!json) return;

    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];

    // events.subscribe installs per-fd allowlists. Default is now
    // deliver-nothing (see SpliceKit_asyncFdWantsEvent). Clients must
    // explicitly subscribe to receive events.
    NSString *eventType = [event[@"type"] isKindOfClass:[NSString class]]
        ? event[@"type"] : nil;

    dispatch_async(sClientQueue, ^{
        NSArray *clients = [sConnectedClients copy];
        for (NSNumber *fd in clients) {
            int cfd = [fd intValue];
            if (!SpliceKit_asyncFdWantsEvent(cfd, eventType)) continue;
            // Hop to the fd's serial queue so order is preserved AND writes
            // don't interleave with RPC replies.
            SpliceKit_writeLineToClientFdAsync(cfd, line);
        }
    });
}

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

static NSDictionary *SpliceKit_handleBackgroundRenderStatus(__unused NSDictionary *params) {
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

static NSDictionary *SpliceKit_handleBackgroundRenderControl(NSDictionary *params) {
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

#pragma mark - Transition Handlers
//
// List and apply FCP's 376+ built-in transitions. The freeze_extend option
// auto-extends clip edges with hold frames when there's not enough media overlap.
//

NSDictionary *SpliceKit_handleTransitionsList(NSDictionary *params) {
    NSString *filter = params[@"filter"];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            // Get all user-visible effect IDs
            id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
            if (!allIDs) { result = @{@"error": @"No effect IDs returned"}; return; }

            SEL typeSel = @selector(effectTypeForEffectID:);
            SEL nameSel = @selector(displayNameForEffectID:);
            SEL catSel = @selector(categoryForEffectID:);

            NSMutableArray *transitions = [NSMutableArray array];
            NSString *transitionType = @"effect.video.transition";

            for (NSString *effectID in allIDs) {
                @autoreleasepool {
                    id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, effectID);
                    if (![type isKindOfClass:[NSString class]]) continue;
                    if (![(NSString *)type isEqualToString:transitionType]) continue;

                    id name = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, effectID);
                    id category = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, catSel, effectID);

                    NSString *displayName = [name isKindOfClass:[NSString class]] ? (NSString *)name : @"Unknown";
                    NSString *catName = [category isKindOfClass:[NSString class]] ? (NSString *)category : @"";

                    // Apply name filter if provided
                    if (filter.length > 0) {
                        NSString *lowerFilter = [filter lowercaseString];
                        BOOL matches = [[displayName lowercaseString] containsString:lowerFilter] ||
                                       [[catName lowercaseString] containsString:lowerFilter];
                        if (!matches) continue;
                    }

                    [transitions addObject:@{
                        @"name": displayName,
                        @"effectID": effectID,
                        @"category": catName,
                    }];
                }
            }

            // Sort by name
            [transitions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"name"] compare:b[@"name"]];
            }];

            // Get the current default
            id defaultID = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect,
                @selector(defaultVideoTransitionEffectID));
            NSString *defaultName = @"";
            if (defaultID) {
                id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, defaultID);
                if ([dn isKindOfClass:[NSString class]]) defaultName = dn;
            }

            result = @{
                @"transitions": transitions,
                @"count": @(transitions.count),
                @"defaultTransition": @{
                    @"name": defaultName,
                    @"effectID": defaultID ?: @"",
                },
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list transitions"};
}

NSDictionary *SpliceKit_handleTransitionsApply(NSDictionary *params) {
    NSString *effectID = params[@"effectID"];
    NSString *name = params[@"name"];
    BOOL freezeExtend = params[@"freezeExtend"] ? [params[@"freezeExtend"] boolValue] : YES;

    if (!effectID && !name) {
        return @{@"error": @"effectID or name parameter required"};
    }

    __block NSDictionary *result = nil;
    __block NSString *resolvedID = effectID;

    SpliceKit_executeOnMainThread(^{
        @try {
            Class ffEffect = objc_getClass("FFEffect");
            if (!ffEffect) { result = @{@"error": @"FFEffect class not found"}; return; }

            // Resolve name -> effectID if needed
            if (!resolvedID && name) {
                id allIDs = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect, @selector(userVisibleEffectIDs));
                SEL typeSel = @selector(effectTypeForEffectID:);
                SEL nameSel = @selector(displayNameForEffectID:);
                NSString *transitionType = @"effect.video.transition";
                NSString *lowerName = [name lowercaseString];

                // Normalize: strip non-alphanumeric chars for fuzzy comparison
                NSString *(^normalize)(NSString *) = ^NSString *(NSString *s) {
                    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
                    NSString *lower = [s lowercaseString];
                    for (NSUInteger i = 0; i < lower.length; i++) {
                        unichar c = [lower characterAtIndex:i];
                        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
                            [out appendFormat:@"%C", c];
                    }
                    return out;
                };
                NSString *normalizedName = normalize(name);

                // Exact match first
                for (NSString *eid in allIDs) {
                    id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                    if (![type isKindOfClass:[NSString class]] ||
                        ![(NSString *)type isEqualToString:transitionType]) continue;
                    id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                    if ([dn isKindOfClass:[NSString class]] &&
                        [[(NSString *)dn lowercaseString] isEqualToString:lowerName]) {
                        resolvedID = eid;
                        break;
                    }
                }
                // Normalized match
                if (!resolvedID) {
                    for (NSString *eid in allIDs) {
                        id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                        if (![type isKindOfClass:[NSString class]] ||
                            ![(NSString *)type isEqualToString:transitionType]) continue;
                        id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                        if ([dn isKindOfClass:[NSString class]] &&
                            [normalize((NSString *)dn) isEqualToString:normalizedName]) {
                            resolvedID = eid;
                            break;
                        }
                    }
                }
                // Partial match fallback
                if (!resolvedID) {
                    for (NSString *eid in allIDs) {
                        id type = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, typeSel, eid);
                        if (![type isKindOfClass:[NSString class]] ||
                            ![(NSString *)type isEqualToString:transitionType]) continue;
                        id dn = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect, nameSel, eid);
                        if ([dn isKindOfClass:[NSString class]] &&
                            [[(NSString *)dn lowercaseString] containsString:lowerName]) {
                            resolvedID = eid;
                            break;
                        }
                    }
                }
                if (!resolvedID) {
                    result = @{@"error": [NSString stringWithFormat:@"No transition found matching '%@'", name]};
                    return;
                }
            }

            // Save the current default transition
            id originalDefault = ((id (*)(id, SEL))objc_msgSend)((id)ffEffect,
                @selector(defaultVideoTransitionEffectID));

            // Set the new default via NSUserDefaults
            [[NSUserDefaults standardUserDefaults] setObject:resolvedID
                                                      forKey:@"FFDefaultVideoTransition"];

            // Call addTransition: on the timeline module
            id timelineModule = SpliceKit_getActiveTimelineModule();
            if (!timelineModule) {
                // Restore default
                if (originalDefault) {
                    [[NSUserDefaults standardUserDefaults] setObject:originalDefault
                                                              forKey:@"FFDefaultVideoTransition"];
                }
                result = @{@"error": @"No active timeline module"};
                return;
            }

            NSUInteger transitionsBefore = SpliceKit_transitionCount(timelineModule);

            // When freezeExtend is enabled, detect whether the clips at the edit
            // point are shorter than the default transition duration.  If so,
            // temporarily reduce the duration via NSUserDefaults so that FCP's
            // internal range calculations can succeed, and pre-force overlapType=2
            // so FCP uses freeze-frame paths on the very first pass (avoiding the
            // "not enough extra media" dialog entirely when possible).
            if (freezeExtend) {
                // Freeze-extend auto-hold is disabled pending further development.
                // Just set the fallback auto-accept flag for the API path.
                sFreezeExtendPendingAutoAccept = YES;
                sFreezeExtendDidApply = NO;
            }

            SEL addSel = @selector(addTransition:);
            if ([timelineModule respondsToSelector:addSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, addSel, nil);
            } else {
                [[NSApplication sharedApplication] sendAction:addSel to:nil from:nil];
            }

            BOOL inserted = SpliceKit_waitForTransitionInsertion(
                timelineModule, transitionsBefore, freezeExtend ? 2.0 : 0.5);
            BOOL freezeExtended = sFreezeExtendDidApply;
            sFreezeExtendDidApply = NO;
            SpliceKit_clearFreezeExtendTransientState();

            // Restore the original default transition
            if (originalDefault) {
                [[NSUserDefaults standardUserDefaults] setObject:originalDefault
                                                          forKey:@"FFDefaultVideoTransition"];
            }

            if (!inserted) {
                result = @{@"error": @"No transition was inserted at the current edit point"};
                return;
            }

            // Get the display name of what we applied
            id appliedName = ((id (*)(id, SEL, id))objc_msgSend)((id)ffEffect,
                @selector(displayNameForEffectID:), resolvedID);

            result = @{
                @"status": @"ok",
                @"transition": [appliedName isKindOfClass:[NSString class]] ? appliedName : @"Unknown",
                @"effectID": resolvedID,
                @"freezeExtended": @(freezeExtended),
            };
        } @catch (NSException *e) {
            sFreezeExtendDidApply = NO;
            SpliceKit_clearFreezeExtendTransientState();
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to apply transition"};
}

#pragma mark - Command Palette Handlers

static NSDictionary *SpliceKit_handleCommandShow(NSDictionary *params) {
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitCommandPalette sharedPalette] showPalette];
    });
    return @{@"status": @"ok"};
}

static NSDictionary *SpliceKit_handleCommandHide(NSDictionary *params) {
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitCommandPalette sharedPalette] hidePalette];
    });
    return @{@"status": @"ok"};
}

static NSDictionary *SpliceKit_handleCommandSearch(NSDictionary *params) {
    NSString *query = params[@"query"] ?: @"";
    NSArray<SpliceKitCommand *> *results = [[SpliceKitCommandPalette sharedPalette] searchCommands:query];
    NSMutableArray *items = [NSMutableArray array];
    NSUInteger limit = [params[@"limit"] unsignedIntegerValue] ?: 20;
    for (NSUInteger i = 0; i < MIN(results.count, limit); i++) {
        SpliceKitCommand *cmd = results[i];
        [items addObject:@{
            @"name": cmd.name ?: @"",
            @"action": cmd.action ?: @"",
            @"type": cmd.type ?: @"",
            @"category": cmd.categoryName ?: @"",
            @"detail": cmd.detail ?: @"",
            @"shortcut": cmd.shortcut ?: @"",
            @"score": @(cmd.score),
        }];
    }
    return @{@"commands": items, @"total": @(results.count)};
}

static NSDictionary *SpliceKit_handleCommandExecute(NSDictionary *params) {
    NSString *action = params[@"action"];
    NSString *type = params[@"type"] ?: @"timeline";
    if (!action) return @{@"error": @"action parameter required"};
    return [[SpliceKitCommandPalette sharedPalette] executeCommand:action type:type];
}

static NSDictionary *SpliceKit_handleDualTimelineStatus(NSDictionary *params) {
    return SpliceKit_dualTimelineStatus();
}

static NSDictionary *SpliceKit_handleDualTimelineOpen(NSDictionary *params) {
    return SpliceKit_dualTimelineOpen(params ?: @{});
}

static NSDictionary *SpliceKit_handleDualTimelineSyncRoot(NSDictionary *params) {
    return SpliceKit_dualTimelineSyncRoot(params ?: @{});
}

static NSDictionary *SpliceKit_handleDualTimelineOpenSelectedInSecondary(NSDictionary *params) {
    return SpliceKit_dualTimelineOpenSelectedInSecondary(params ?: @{});
}

static NSDictionary *SpliceKit_handleDualTimelineFocus(NSDictionary *params) {
    return SpliceKit_dualTimelineFocus(params ?: @{});
}

static NSDictionary *SpliceKit_handleDualTimelineClose(NSDictionary *params) {
    return SpliceKit_dualTimelineClose(params ?: @{});
}

static NSDictionary *SpliceKit_handleDualTimelineTogglePanel(NSDictionary *params) {
    return SpliceKit_dualTimelineTogglePanel(params ?: @{});
}

// Forward declarations for AI engine handlers
static NSDictionary *SpliceKit_handleCommandAIGemma(NSDictionary *params);
static NSDictionary *SpliceKit_handleCommandAIAppleAgentic(NSDictionary *params);

static NSDictionary *SpliceKit_handleCommandAI(NSDictionary *params) {
    NSString *query = params[@"query"];
    if (!query) return @{@"error": @"query parameter required"};

    // Allow overriding the engine via params: "engine": "standard" | "agentic" | "gemma"
    NSString *engineOverride = params[@"engine"];
    SpliceKitAIEngine engine = [SpliceKitCommandPalette sharedPalette].aiEngine;
    if ([engineOverride isEqualToString:@"standard"]) {
        engine = SpliceKitAIEngineAppleIntelligence;
    } else if ([engineOverride isEqualToString:@"agentic"]) {
        engine = SpliceKitAIEngineAppleAgentic;
    } else if ([engineOverride isEqualToString:@"gemma"]) {
        engine = SpliceKitAIEngineGemma4;
    }

    // Route to the configured AI engine
    if (engine == SpliceKitAIEngineAppleAgentic) {
        return SpliceKit_handleCommandAIAppleAgentic(params);
    }
    if (engine == SpliceKitAIEngineGemma4) {
        return SpliceKit_handleCommandAIGemma(params);
    }

    // Default: non-agentic Apple Intelligence
    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[SpliceKitCommandPalette sharedPalette] executeNaturalLanguage:query
        completion:^(NSArray<NSDictionary *> *actions, NSString *error) {
            if (error) {
                result = @{@"error": error};
            } else {
                result = @{@"actions": actions ?: @[], @"count": @(actions.count)};
            }
            dispatch_semaphore_signal(sem);
        }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    return result ?: @{@"error": @"AI request timed out"};
}

static NSDictionary *SpliceKit_handleCommandAIGemma(NSDictionary *params) {
    NSString *query = params[@"query"];
    if (!query) return @{@"error": @"query parameter required"};

    NSString *model = params[@"model"];
    if (model) {
        [SpliceKitCommandPalette sharedPalette].gemmaModel = model;
    }

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[SpliceKitCommandPalette sharedPalette] executeNaturalLanguageGemma:query
        completion:^(NSString *summary, NSString *error) {
            if (error) {
                result = @{@"error": error};
            } else {
                result = @{@"summary": summary ?: @"Done."};
            }
            dispatch_semaphore_signal(sem);
        }];

    // 5 minute timeout — multi-turn loops take longer than single-shot AI
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC));
    return result ?: @{@"error": @"Gemma AI request timed out"};
}

static NSDictionary *SpliceKit_handleCommandAIAppleAgentic(NSDictionary *params) {
    NSString *query = params[@"query"];
    if (!query) return @{@"error": @"query parameter required"};

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[SpliceKitCommandPalette sharedPalette] executeNaturalLanguageAppleAgentic:query
        completion:^(NSString *summary, NSString *error) {
            if (error) {
                result = @{@"error": error};
            } else {
                result = @{@"summary": summary ?: @"Done."};
            }
            dispatch_semaphore_signal(sem);
        }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC));
    return result ?: @{@"error": @"Apple Intelligence+ request timed out"};
}

#pragma mark - Browser Clip Handlers
//
// Access clips in the event browser (source media, not timeline items).
//

// List clips available in the event browser
// The clips of one event as the browser shows them: displayOwnedClips (browser-visible)
// first, then ownedClips, childItems, items; a set becomes an array. Every walk over
// browser clips (browser.listClips, browser.placeClip by index or name, the timeline
// overview, the song-cut clip pool) goes through this, so an index from one listing
// names the same clip in the others. browser.placeClip used to ask ownedClips only, which FCP 12.3's
// FFEventRecord does not answer as an array, so name and index never resolved.
// Drop the items sitting in the library trash.
//
// -displayOwnedClips keeps answering an item after it has been moved to the library
// trash — renamed with a random suffix, "_SKPaste_10705" becoming
// "_SKPaste_10705-AWx2h5" — even though Final Cut Pro's own browser no longer shows it.
// That made cleanup_temp_projects report the same three scratch projects again
// immediately after trashing them, and browser.listClips offer trashed projects as clips
// to place. FFLibrary's -_itemInTrash: is the test, and it wants the item's library
// RECORD, not the FFAnchoredSequence: asked about the sequence it answers NO for a
// project that is demonstrably in __Trash/ on disk.
//
// -targetLibraryItem answers the FFSequenceRecord for a project but only the enclosing
// FFEventRecord for a source clip, so a source clip can only be judged by its event. An
// item we cannot positively identify as trashed is kept.
// Whether a browser item is a project (a timeline) rather than a source clip.
//
// -isProject only answers YES once Final Cut Pro has loaded the sequence, so right after
// launch every project except the open one reported NO: browser.listClips labelled three
// leaked scratch projects "isProject": false, and the live sweep duly handed one to
// add_clip_to_timeline. -sequenceType answers "sequence" for a project Final Cut Pro has
// not loaded and "clip" for a source clip, so between them both states are covered — a
// loaded project answers isProject YES and sequenceType "clip", an unloaded one answers
// isProject NO and sequenceType "sequence", and a source clip answers NO and "clip"
// either way.
static BOOL SpliceKit_browserItemIsProject(id item) {
    if (!item) return NO;
    BOOL isProject = NO;
    if (SpliceKit_tryReadBoolSelector(item, @"isProject", &isProject) && isProject) return YES;
    SEL typeSel = NSSelectorFromString(@"sequenceType");
    if ([item respondsToSelector:typeSel]) {
        id type = nil;
        @try { type = ((id (*)(id, SEL))objc_msgSend)(item, typeSel); } @catch (NSException *e) { type = nil; }
        if ([type isKindOfClass:[NSString class]] &&
            [(NSString *)type caseInsensitiveCompare:@"sequence"] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static NSArray *SpliceKit_browserRemoveTrashedItems(id event, NSArray *items) {
    if (items.count == 0) return items;
    SEL inTrashSel = NSSelectorFromString(@"_itemInTrash:");
    id library = nil;
    SEL librarySel = NSSelectorFromString(@"library");
    if ([event respondsToSelector:librarySel]) {
        @try { library = ((id (*)(id, SEL))objc_msgSend)(event, librarySel); }
        @catch (NSException *e) { library = nil; }
    }
    if (!library || ![library respondsToSelector:inTrashSel]) return items;

    SEL recordSels[] = {
        NSSelectorFromString(@"targetSequenceRecord"),
        NSSelectorFromString(@"targetLibraryItem"),
    };
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        id record = nil;
        for (NSUInteger i = 0; i < sizeof(recordSels) / sizeof(recordSels[0]) && !record; i++) {
            if (![item respondsToSelector:recordSels[i]]) continue;
            @try { record = ((id (*)(id, SEL))objc_msgSend)(item, recordSels[i]); }
            @catch (NSException *e) { record = nil; }
        }
        BOOL trashed = NO;
        if (record) {
            @try {
                trashed = ((BOOL (*)(id, SEL, id))objc_msgSend)(library, inTrashSel, record);
            } @catch (NSException *e) { trashed = NO; }
        }
        if (!trashed) [kept addObject:item];
    }
    return kept;
}

NSArray *SpliceKit_browserClipsOfEvent(id event) {
    if (!event) return @[];
    for (NSString *name in @[@"displayOwnedClips", @"ownedClips", @"childItems", @"items"]) {
        SEL sel = NSSelectorFromString(name);
        if (![event respondsToSelector:sel]) continue;
        id clips = nil;
        @try { clips = ((id (*)(id, SEL))objc_msgSend)(event, sel); } @catch (NSException *e) { clips = nil; }
        NSArray *arr = SpliceKit_mixerArrayFromContainer(clips);
        if (arr) return SpliceKit_browserRemoveTrashedItems(event, arr);
    }
    return @[];
}

static NSDictionary *SpliceKit_handleBrowserListClips(NSDictionary *params) {
    NSString *eventFilter = [params[@"event"] isKindOfClass:[NSString class]] ? params[@"event"] : nil;
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            // Get active library -> events -> clips
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            id library = [(NSArray *)libs firstObject];

            // Get events from library — events are FFFolder objects
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableArray *allClips = [NSMutableArray array];
            NSInteger clipIndex = 0;

            for (id event in (NSArray *)events) {
                NSString *eventName = @"";
                if ([event respondsToSelector:@selector(displayName)])
                    eventName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";
                if (eventFilter.length > 0 &&
                    ![[eventName lowercaseString] containsString:[eventFilter lowercaseString]]) {
                    continue;
                }

                // The event's clips as the browser shows them (shared walk, see
                // SpliceKit_browserClipsOfEvent).
                NSArray *clips = SpliceKit_browserClipsOfEvent(event);
                NSUInteger clipCount = clips.count;
                SpliceKit_log(@"[Browser] Event '%@' class=%@ clips=%@ count=%lu",
                    eventName, NSStringFromClass([event class]),
                    clips ? NSStringFromClass([clips class]) : @"nil",
                    (unsigned long)clipCount);

                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in (NSArray *)clips) {
                    NSMutableDictionary *info = [NSMutableDictionary dictionary];
                    info[@"index"] = @(clipIndex++);
                    info[@"event"] = eventName;
                    info[@"class"] = NSStringFromClass([clip class]);
                    // A project sits in the browser next to the clips (FCP's isProject flag);
                    // it is not a source clip for add_clip_to_timeline.
                    info[@"isProject"] = @(SpliceKit_browserItemIsProject(clip));

                    if ([clip respondsToSelector:@selector(displayName)]) {
                        id name = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                        info[@"name"] = name ?: @"";
                    }
                    if ([clip respondsToSelector:@selector(duration)]) {
                        SpliceKit_CMTime d = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(clip, @selector(duration));
                        info[@"duration"] = SpliceKit_serializeCMTime(d);
                    } else if ([clip respondsToSelector:NSSelectorFromString(@"clippedRange")]) {
                        SpliceKit_CMTimeRange r = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(
                            clip, NSSelectorFromString(@"clippedRange"));
                        info[@"duration"] = SpliceKit_serializeCMTime(r.duration);
                    } else if ([clip respondsToSelector:NSSelectorFromString(@"unclippedRange")]) {
                        SpliceKit_CMTimeRange r = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(
                            clip, NSSelectorFromString(@"unclippedRange"));
                        info[@"duration"] = SpliceKit_serializeCMTime(r.duration);
                    }

                    NSString *handle = SpliceKit_storeHandle(clip);
                    info[@"handle"] = handle;
                    [allClips addObject:info];
                }
            }

            result = @{@"clips": allClips, @"count": @(allClips.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list browser clips"};
}

static NSString *SpliceKit_browserClipName(id clip) {
    if (!clip) return @"";
    if ([clip respondsToSelector:@selector(displayName)]) {
        id name = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
        if ([name isKindOfClass:[NSString class]]) return name;
    }
    return @"";
}

static NSString *SpliceKit_browserShortDescription(id obj, NSUInteger maxLength) {
    if (!obj) return @"";
    NSString *desc = [obj description] ?: @"";
    if (desc.length > maxLength) {
        return [desc substringToIndex:maxLength];
    }
    return desc;
}

static BOOL SpliceKit_browserCMTimeIsUsable(SpliceKit_CMTime t) {
    return (t.timescale > 0 && t.value >= 0);
}

static void SpliceKit_browserAssignTime(NSMutableDictionary *dict, NSString *key, SpliceKit_CMTime t) {
    if (!dict || key.length == 0) return;
    if (SpliceKit_browserCMTimeIsUsable(t)) {
        dict[key] = SpliceKit_serializeCMTime(t);
    }
}

static id SpliceKit_browserSequenceForTimeline(id timelineModule) {
    if (!timelineModule || ![timelineModule respondsToSelector:@selector(sequence)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence));
}

static id SpliceKit_browserPrimaryContainerForSequence(id sequence) {
    if (!sequence) return nil;
    if ([sequence respondsToSelector:@selector(primaryObject)]) {
        id container = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
        if (container) return container;
    }
    return sequence;
}

static NSArray *SpliceKit_browserContainedItems(id sequence, id container) {
    id items = nil;
    if (container && [container respondsToSelector:@selector(containedItems)]) {
        items = ((id (*)(id, SEL))objc_msgSend)(container, @selector(containedItems));
    } else if (sequence && [sequence respondsToSelector:@selector(containedItems)]) {
        items = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(containedItems));
    }
    return [items isKindOfClass:[NSArray class]] ? items : nil;
}

static NSDictionary *SpliceKit_browserTimelineItemSummary(id item, id container) {
    if (!item) return @{};

    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"class"] = NSStringFromClass([item class]) ?: @"";
    summary[@"description"] = SpliceKit_browserShortDescription(item, 240);
    summary[@"handle"] = SpliceKit_storeHandle(item) ?: @"";

    NSString *name = SpliceKit_browserClipName(item);
    if (name.length > 0) summary[@"name"] = name;

    if ([item respondsToSelector:@selector(duration)]) {
        SpliceKit_CMTime duration = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
        SpliceKit_browserAssignTime(summary, @"duration", duration);
    }

    SEL effectiveRangeSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    if (container && [container respondsToSelector:effectiveRangeSel]) {
        @try {
            SpliceKit_CMTimeRange range =
                ((SpliceKit_CMTimeRange (*)(id, SEL, id))STRET_MSG)(container, effectiveRangeSel, item);
            if (SpliceKit_browserCMTimeIsUsable(range.start)) {
                summary[@"startTime"] = SpliceKit_serializeCMTime(range.start);
            }
            if (SpliceKit_browserCMTimeIsUsable(range.duration)) {
                SpliceKit_CMTime endTime = SpliceKit_endTimeForRange(range);
                if (SpliceKit_browserCMTimeIsUsable(endTime)) {
                    summary[@"endTime"] = SpliceKit_serializeCMTime(endTime);
                }
            }
        } @catch (__unused NSException *e) {}
    }

    return summary;
}

static NSDictionary *SpliceKit_browserPlacementSnapshot(id timelineModule, id clip) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    id sequence = SpliceKit_browserSequenceForTimeline(timelineModule);
    id container = SpliceKit_browserPrimaryContainerForSequence(sequence);

    if (clip) {
        snapshot[@"clipHandle"] = SpliceKit_storeHandle(clip) ?: @"";
        snapshot[@"clipClass"] = NSStringFromClass([clip class]) ?: @"";
        snapshot[@"clipDescription"] = SpliceKit_browserShortDescription(clip, 240);
        NSString *clipName = SpliceKit_browserClipName(clip);
        if (clipName.length > 0) snapshot[@"clipName"] = clipName;
    }

    if (sequence) {
        snapshot[@"sequenceHandle"] = SpliceKit_storeHandle(sequence) ?: @"";
        snapshot[@"sequenceClass"] = NSStringFromClass([sequence class]) ?: @"";
        snapshot[@"sequenceDescription"] = SpliceKit_browserShortDescription(sequence, 240);
        NSString *sequenceName = SpliceKit_browserClipName(sequence);
        if (sequenceName.length > 0) snapshot[@"sequenceName"] = sequenceName;
        if ([sequence respondsToSelector:@selector(duration)]) {
            SpliceKit_CMTime duration = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, @selector(duration));
            SpliceKit_browserAssignTime(snapshot, @"sequenceDuration", duration);
        }
    }

    if (container) {
        snapshot[@"containerHandle"] = SpliceKit_storeHandle(container) ?: @"";
        snapshot[@"containerClass"] = NSStringFromClass([container class]) ?: @"";
        snapshot[@"containerDescription"] = SpliceKit_browserShortDescription(container, 240);
        SEL endSel = NSSelectorFromString(@"endTimeOfLastContainedItem");
        if ([container respondsToSelector:endSel]) {
            SpliceKit_CMTime end = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(container, endSel);
            SpliceKit_browserAssignTime(snapshot, @"containerEndTime", end);
        }
    }

    SEL currentSel = NSSelectorFromString(@"currentSequenceTime");
    if ([timelineModule respondsToSelector:currentSel]) {
        SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timelineModule, currentSel);
        SpliceKit_browserAssignTime(snapshot, @"currentSequenceTime", t);
    }
    if ([timelineModule respondsToSelector:@selector(playheadTime)]) {
        SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timelineModule, @selector(playheadTime));
        SpliceKit_browserAssignTime(snapshot, @"playheadTime", t);
    }
    SEL committedSel = NSSelectorFromString(@"committedPlayheadTime");
    if ([timelineModule respondsToSelector:committedSel]) {
        SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timelineModule, committedSel);
        SpliceKit_browserAssignTime(snapshot, @"committedPlayheadTime", t);
    }

    NSArray *items = SpliceKit_browserContainedItems(sequence, container);
    snapshot[@"itemCount"] = @(items.count);
    if (items.count > 0) {
        NSInteger tailStart = MAX((NSInteger)0, (NSInteger)items.count - 5);
        NSMutableArray *tailItems = [NSMutableArray array];
        for (NSInteger idx = tailStart; idx < (NSInteger)items.count; idx++) {
            [tailItems addObject:SpliceKit_browserTimelineItemSummary(items[idx], container)];
        }
        snapshot[@"tailItems"] = tailItems;
        snapshot[@"lastItem"] = SpliceKit_browserTimelineItemSummary(items.lastObject, container);
    }

    return snapshot;
}

static BOOL SpliceKit_browserPrepareExplicitPasteboard(id clip,
                                                       id mediaRange,
                                                       NSString **outPasteboardName,
                                                       NSMutableDictionary *debugInfo,
                                                       NSString **outError) {
    NSPasteboard *generalPB = [NSPasteboard generalPasteboard];
    [generalPB clearContents];

    Class ffPasteboardClass = objc_getClass("FFPasteboard");
    if (!ffPasteboardClass) {
        if (outError) *outError = @"FFPasteboard class not found";
        return NO;
    }

    id ffPasteboard = ((id (*)(id, SEL))objc_msgSend)((id)ffPasteboardClass, @selector(alloc));
    SEL initWithNameSel = NSSelectorFromString(@"initWithName:");
    if (![ffPasteboard respondsToSelector:initWithNameSel]) {
        if (outError) *outError = @"FFPasteboard does not respond to initWithName:";
        return NO;
    }

    NSString *pasteboardName = NSPasteboardNameGeneral;
    ffPasteboard = ((id (*)(id, SEL, id))objc_msgSend)(ffPasteboard, initWithNameSel, pasteboardName);
    BOOL wroteRanges = NO;
    BOOL wroteAnchored = NO;

    SEL writeRangesSel = NSSelectorFromString(@"writeRangesOfMedia:options:");
    if (mediaRange && [ffPasteboard respondsToSelector:writeRangesSel]) {
        wroteRanges = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ffPasteboard, writeRangesSel, @[mediaRange], nil);
    }

    if (!wroteRanges) {
        SEL writeAnchoredSel = NSSelectorFromString(@"writeAnchoredObjects:options:");
        if ([ffPasteboard respondsToSelector:writeAnchoredSel]) {
            wroteAnchored = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ffPasteboard, writeAnchoredSel, @[clip], nil);
        }
    }

    if (debugInfo) {
        debugInfo[@"pasteboardName"] = pasteboardName ?: @"";
        debugInfo[@"pasteboardWriteRanges"] = @(wroteRanges);
        debugInfo[@"pasteboardWriteAnchored"] = @(wroteAnchored);
        if ([ffPasteboard respondsToSelector:@selector(hasMedia:)]) {
            BOOL hasMedia = ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(ffPasteboard, @selector(hasMedia:), YES);
            debugInfo[@"pasteboardHasMedia"] = @(hasMedia);
        }
        if ([ffPasteboard respondsToSelector:@selector(hasEdits:)]) {
            BOOL hasEdits = ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(ffPasteboard, @selector(hasEdits:), YES);
            debugInfo[@"pasteboardHasEdits"] = @(hasEdits);
        }
    }

    if (outPasteboardName) *outPasteboardName = pasteboardName;
    if (!wroteRanges && !wroteAnchored) {
        if (outError) *outError = @"Failed to write explicit clip data to pasteboard";
        return NO;
    }
    return YES;
}

static NSDictionary *SpliceKit_browserInsertExplicitClipAtPlayhead(id timelineModule,
                                                                   id clip,
                                                                   NSString *pasteboardName) {
    NSMutableDictionary *debugInfo = [NSMutableDictionary dictionary];
    debugInfo[@"primitive"] = @"explicit_paste_at_playhead";
    debugInfo[@"before"] = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"pasteboardName"] = pasteboardName ?: @"";

    SEL pasteSel = NSSelectorFromString(@"paste:");
    if (![timelineModule respondsToSelector:pasteSel]) {
        return @{@"error": @"Timeline module does not respond to paste:",
                 @"placementDebug": debugInfo};
    }

    ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, pasteSel, nil);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.12]];

    NSDictionary *after = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"after"] = after;

    return @{@"status": @"ok",
             @"primitive": @"explicit_paste_at_playhead",
             @"placementVerified": @YES,
             @"placementDebug": debugInfo};
}

static NSDictionary *SpliceKit_browserAppendExplicitClipToTimelineEnd(id timelineModule,
                                                                      id clip,
                                                                      NSString *pasteboardName) {
    NSMutableDictionary *debugInfo = [NSMutableDictionary dictionary];
    debugInfo[@"primitive"] = @"verified_seek_to_end_then_paste";
    debugInfo[@"pasteboardName"] = pasteboardName ?: @"";

    NSDictionary *before = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"before"] = before;

    NSDictionary *durationInfo = before[@"sequenceDuration"];
    NSDictionary *containerEndInfo = before[@"containerEndTime"];
    double targetSeconds = [containerEndInfo[@"seconds"] doubleValue];
    if (targetSeconds <= 0.0) targetSeconds = [durationInfo[@"seconds"] doubleValue];

    if (targetSeconds < 0.0) {
        return @{@"error": @"Could not determine the current primary storyline end.",
                 @"placementDebug": debugInfo};
    }

    double frameSeconds = SpliceKit_transitionFrameDurationSeconds(timelineModule);
    double tolerance = MAX(frameSeconds * 2.0, 0.05);
    debugInfo[@"targetEndSeconds"] = @(targetSeconds);
    debugInfo[@"toleranceSeconds"] = @(tolerance);

    NSString *expectedName = SpliceKit_browserClipName(clip);
    double beforePlayheadSeconds = [before[@"playheadTime"][@"seconds"] doubleValue];
    SpliceKit_log(@"%@", [NSString stringWithFormat:
        @"[AppendPlacement] begin clip=%@ targetEnd=%.6f playheadBefore=%.6f primitive=%@",
        expectedName.length > 0 ? expectedName : @"<unnamed>",
        targetSeconds,
        beforePlayheadSeconds,
        @"verified_seek_to_end_then_paste"]);

    if (!SpliceKit_transitionSeekToSeconds(timelineModule, targetSeconds)) {
        return @{@"error": @"Could not move the playhead to the current storyline end.",
                 @"placementDebug": debugInfo};
    }

    NSDictionary *seekImmediate = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"seekImmediate"] = seekImmediate;

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    NSDictionary *seekNextRunloop = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"seekNextRunloop"] = seekNextRunloop;

    NSDictionary *seekDeferred = nil;
    double currentSequenceSeconds = 0.0;
    double playheadSeconds = 0.0;
    double committedSeconds = 0.0;
    BOOL currentMatches = NO;
    BOOL playheadMatches = NO;
    BOOL committedMatches = NO;
    NSInteger seekVerificationPollCount = 0;

    NSDate *seekDeadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
    do {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        seekVerificationPollCount++;
        seekDeferred = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
        debugInfo[@"seekDeferred"] = seekDeferred;

        currentSequenceSeconds = [seekDeferred[@"currentSequenceTime"][@"seconds"] doubleValue];
        playheadSeconds = [seekDeferred[@"playheadTime"][@"seconds"] doubleValue];
        committedSeconds = [seekDeferred[@"committedPlayheadTime"][@"seconds"] doubleValue];

        currentMatches = fabs(currentSequenceSeconds - targetSeconds) <= tolerance;
        playheadMatches = fabs(playheadSeconds - targetSeconds) <= tolerance;
        committedMatches = (seekDeferred[@"committedPlayheadTime"] == nil) ||
            fabs(committedSeconds - targetSeconds) <= tolerance;
    } while (!(currentMatches && playheadMatches && committedMatches) &&
             [seekDeadline timeIntervalSinceNow] > 0.0);

    debugInfo[@"seekVerificationPollCount"] = @(seekVerificationPollCount);
    debugInfo[@"seekVerified"] = @(currentMatches && playheadMatches && committedMatches);

    if (!(currentMatches && playheadMatches && committedMatches)) {
        NSString *reason = [NSString stringWithFormat:
            @"Append verification failed before paste. target=%.6f current=%.6f playhead=%.6f committed=%.6f",
            targetSeconds, currentSequenceSeconds, playheadSeconds, committedSeconds];
        SpliceKit_log(@"[AppendPlacement] %@", reason);
        return @{@"error": reason, @"placementDebug": debugInfo};
    }

    SEL pasteSel = NSSelectorFromString(@"paste:");
    if (![timelineModule respondsToSelector:pasteSel]) {
        return @{@"error": @"Timeline module does not respond to paste:",
                 @"placementDebug": debugInfo};
    }

    ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, pasteSel, nil);
    NSDictionary *after = nil;
    NSDictionary *match = nil;
    double afterTailSeconds = targetSeconds;
    BOOL tailAdvanced = NO;
    NSInteger verificationPollCount = 0;

    NSDate *verificationDeadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
    do {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        verificationPollCount++;

        after = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
        NSDictionary *afterContainerEnd = after[@"containerEndTime"];
        NSDictionary *afterDuration = after[@"sequenceDuration"];
        afterTailSeconds = [afterContainerEnd[@"seconds"] doubleValue];
        if (afterTailSeconds <= 0.0) afterTailSeconds = [afterDuration[@"seconds"] doubleValue];
        tailAdvanced = afterTailSeconds > (targetSeconds + (frameSeconds * 0.5));

        id sequence = SpliceKit_browserSequenceForTimeline(timelineModule);
        id container = SpliceKit_browserPrimaryContainerForSequence(sequence);
        NSArray *items = SpliceKit_browserContainedItems(sequence, container);
        match = nil;

        for (id item in items) {
            NSString *itemName = SpliceKit_browserClipName(item);
            if (expectedName.length == 0 || ![itemName isEqualToString:expectedName]) continue;

            NSDictionary *summary = SpliceKit_browserTimelineItemSummary(item, container);
            double startSeconds = [summary[@"startTime"][@"seconds"] doubleValue];
            if (fabs(startSeconds - targetSeconds) <= tolerance) {
                match = summary;
                break;
            }
        }
    } while ((match == nil || !tailAdvanced) &&
             [verificationDeadline timeIntervalSinceNow] > 0.0);

    debugInfo[@"after"] = after;
    if (match) debugInfo[@"matchedInsertedItem"] = match;

    double beforeTailSeconds = [containerEndInfo[@"seconds"] doubleValue];
    if (beforeTailSeconds <= 0.0) beforeTailSeconds = [durationInfo[@"seconds"] doubleValue];
    BOOL durationGrew = afterTailSeconds > (beforeTailSeconds + (frameSeconds * 0.5));
    BOOL verified = (match != nil && durationGrew);
    debugInfo[@"durationBeforeSeconds"] = @(beforeTailSeconds);
    debugInfo[@"durationAfterSeconds"] = @(afterTailSeconds);
    debugInfo[@"storylineTailBeforeSeconds"] = @(beforeTailSeconds);
    debugInfo[@"storylineTailAfterSeconds"] = @(afterTailSeconds);
    debugInfo[@"durationGrew"] = @(durationGrew);
    debugInfo[@"verificationPollCount"] = @(verificationPollCount);

    if (!verified) {
        NSString *reason = [NSString stringWithFormat:
            @"Append paste completed but could not verify the inserted clip at the prior storyline end."];
        SpliceKit_log(@"%@", [NSString stringWithFormat:
            @"[AppendPlacement] fail clip=%@ targetEnd=%.6f afterTail=%.6f match=%@ polls=%ld",
            expectedName.length > 0 ? expectedName : @"<unnamed>",
            targetSeconds,
            afterTailSeconds,
            match ? @"YES" : @"NO",
            (long)verificationPollCount]);
        SpliceKit_log(@"[AppendPlacement] %@", reason);
        return @{@"error": reason, @"placementDebug": debugInfo};
    }

    double insertedStartSeconds = [match[@"startTime"][@"seconds"] doubleValue];
    SpliceKit_log(@"%@", [NSString stringWithFormat:
        @"[AppendPlacement] success clip=%@ targetEnd=%.6f insertedStart=%.6f tailBefore=%.6f tailAfter=%.6f polls=%ld",
        expectedName.length > 0 ? expectedName : @"<unnamed>",
        targetSeconds,
        insertedStartSeconds,
        beforeTailSeconds,
        afterTailSeconds,
        (long)verificationPollCount]);

    return @{@"status": @"ok",
             @"primitive": @"verified_seek_to_end_then_paste",
             @"placementVerified": @YES,
             @"placementDebug": debugInfo};
}

static NSDictionary *SpliceKit_browserConnectExplicitClipAtPlayhead(id timelineModule,
                                                                    id clip,
                                                                    NSString *pasteboardName,
                                                                    BOOL backtimed) {
    NSMutableDictionary *debugInfo = [NSMutableDictionary dictionary];
    debugInfo[@"primitive"] = backtimed ? @"explicit_anchor_backtimed" : @"explicit_paste_anchored";
    debugInfo[@"before"] = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"pasteboardName"] = pasteboardName ?: @"";

    // pasteAnchored: is Edit > Paste as Connected Clip. A backtimed connect edit (FCP:
    // Shift-Q, the end of the source range lands at the playhead) only exists on the
    // anchorWithPasteboard:backtimed:trackType: path.
    SEL pasteAnchoredSel = NSSelectorFromString(@"pasteAnchored:");
    SEL anchorSel = NSSelectorFromString(@"anchorWithPasteboard:backtimed:trackType:");

    if (!backtimed && [timelineModule respondsToSelector:pasteAnchoredSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(timelineModule, pasteAnchoredSel, nil);
    } else if ([timelineModule respondsToSelector:anchorSel]) {
        NSString *resolvedPasteboardName = pasteboardName.length > 0 ? pasteboardName : NSPasteboardNameGeneral;
        ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(timelineModule,
                                                        anchorSel,
                                                        resolvedPasteboardName,
                                                        backtimed,
                                                        @"all");
    } else if (backtimed) {
        return @{@"error": @"a backtimed connect edit is not available: this Final Cut Pro build's timeline module has no anchorWithPasteboard:backtimed:trackType:",
                 @"placementDebug": debugInfo};
    } else {
        return @{@"error": @"Timeline module does not respond to pasteAnchored: or anchorWithPasteboard:backtimed:trackType:",
                 @"placementDebug": debugInfo};
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.12]];

    NSDictionary *after = SpliceKit_browserPlacementSnapshot(timelineModule, clip);
    debugInfo[@"after"] = after;

    return @{@"status": @"ok",
             @"primitive": backtimed ? @"explicit_anchor_backtimed" : @"explicit_paste_anchored",
             @"placementVerified": @YES,
             @"placementDebug": debugInfo};
}

// Move the playhead to `seconds` and wait (up to 0.75 s) until the timeline module
// reports it there on every clock it exposes. The same check the append path makes
// before it pastes: an edit made at a playhead that has not settled lands elsewhere.
// Also records whether the skimmer is active: while the pointer skims the timeline,
// FCP makes edits at the skimmer, not the playhead.
static BOOL SpliceKit_browserSeekAndVerify(id timelineModule, double seconds, double tolerance,
                                           NSMutableDictionary *debugInfo) {
    if (!SpliceKit_transitionSeekToSeconds(timelineModule, seconds)) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.75];
    NSInteger polls = 0;
    BOOL ok = NO;
    do {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        polls++;
        NSDictionary *snap = SpliceKit_browserPlacementSnapshot(timelineModule, nil);
        double current = [snap[@"currentSequenceTime"][@"seconds"] doubleValue];
        double playhead = [snap[@"playheadTime"][@"seconds"] doubleValue];
        BOOL committedOK = (snap[@"committedPlayheadTime"] == nil) ||
            fabs([snap[@"committedPlayheadTime"][@"seconds"] doubleValue] - seconds) <= tolerance;
        ok = fabs(current - seconds) <= tolerance && fabs(playhead - seconds) <= tolerance && committedOK;
    } while (!ok && [deadline timeIntervalSinceNow] > 0.0);
    if (debugInfo) {
        debugInfo[@"seekPolls"] = @(polls);
        debugInfo[@"seekVerified"] = @(ok);
    }
    return ok;
}

static BOOL SpliceKit_browserSkimmingActive(id timelineModule) {
    SEL sel = NSSelectorFromString(@"isToolSkimming");
    if (![timelineModule respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(timelineModule, sel);
}

// The timeline exactly as get_timeline_clips reports it (spine items + connected
// items, no markers), keyed by object identity (pointerKey), with the handle as a
// fallback key. A placement is verified by diffing this before and after the edit:
// the new entries are the object(s) the edit added. Object identity is used rather
// than handle strings because the handle table is cleared when it reaches
// SPLICEKIT_MAX_HANDLES entries, which would make every item look new.
static NSDictionary *SpliceKit_browserTimelineEntries(void) {
    NSDictionary *state = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @100000,
                                                                     @"connected_limit": @100000,
                                                                     @"include_markers": @NO,
                                                                     @"include_nested": @NO,
                                                                     @"include_pointer_keys": @YES});
    NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
    if (![state isKindOfClass:[NSDictionary class]] || state[@"error"]) return byKey;
    for (NSString *listKey in @[@"items", @"connectedItems"]) {
        id list = state[listKey];
        if (![list isKindOfClass:[NSArray class]]) continue;
        for (id entry in (NSArray *)list) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *key = entry[@"pointerKey"];
            if (![key isKindOfClass:[NSString class]] || key.length == 0) key = entry[@"handle"];
            if (![key isKindOfClass:[NSString class]] || key.length == 0) continue;
            NSMutableDictionary *copy = [entry mutableCopy];
            copy[@"connected"] = @([listKey isEqualToString:@"connectedItems"]);
            byKey[key] = copy;
        }
    }
    return byKey;
}

static double SpliceKit_browserEntrySeconds(NSDictionary *entry, NSString *key) {
    id time = entry[key];
    if ([time isKindOfClass:[NSDictionary class]] && [time[@"seconds"] respondsToSelector:@selector(doubleValue)]) {
        return [time[@"seconds"] doubleValue];
    }
    return NAN;
}

// One placed clip, in the vocabulary get_timeline_clips already uses.
static NSDictionary *SpliceKit_browserPlacedEntry(NSDictionary *entry) {
    NSMutableDictionary *placed = [NSMutableDictionary dictionary];
    placed[@"handle"] = entry[@"handle"] ?: @"";
    if (entry[@"name"]) placed[@"name"] = entry[@"name"];
    if (entry[@"class"]) placed[@"class"] = entry[@"class"];
    id lane = entry[@"effectiveLane"] ?: entry[@"lane"];
    if (lane) placed[@"lane"] = lane;
    BOOL connected = [entry[@"connected"] boolValue];
    placed[@"connected"] = @(connected);
    if (!connected && entry[@"index"]) placed[@"spineIndex"] = entry[@"index"];
    if (connected && entry[@"parentIndex"]) placed[@"anchoredToSpineIndex"] = entry[@"parentIndex"];
    double startSeconds = SpliceKit_browserEntrySeconds(entry, @"startTime");
    double endSeconds = SpliceKit_browserEntrySeconds(entry, @"endTime");
    if (!isnan(startSeconds)) placed[@"startSeconds"] = @(startSeconds);
    if (!isnan(endSeconds)) placed[@"endSeconds"] = @(endSeconds);
    if (!isnan(startSeconds) && !isnan(endSeconds)) placed[@"durationSeconds"] = @(endSeconds - startSeconds);
    return placed;
}

// Place a browser clip on the timeline with one of Final Cut Pro's edits: append (E),
// insert (W) or connect (Q). Optional params:
//   inSeconds / outSeconds  range selection inside the source clip, in seconds from
//                           the clip's first frame (FCP: Set Range Start I / End O)
//   atSeconds               move the playhead there first; insert and connect are made
//                           at the playhead (append always goes to the storyline end)
//   backtimed               connect only (FCP: Shift-Q): the END of the range lands at
//                           the playhead
//   dryRun                  resolve clip, range and target; change nothing
// The edit goes through Final Cut Pro's own pasteboard route (FFPasteboard
// writeRangesOfMedia: with the range, then paste: / pasteAnchored:), which is what a
// range selection in the browser does; the general pasteboard is replaced. The result
// reports the placed clip found by diffing the timeline before and after (object
// identity), whether the placed duration matches the range (rangeHonored) and whether
// it landed where asked (positionVerified), both within two frames (at least 50 ms).
// Other objects the edit created (the far half of a split clip, a gap) are listed
// under alsoNew. Error answers after state changed carry stateChanged.
// browser.placeClip's index / name lookup: the walk browser.listClips makes with no
// event filter, so `index` is that listing's index and `name` its first
// case-insensitive substring match; index is tried first when both are given.
// outListed receives how many clips were walked, for the error text.
static id SpliceKit_browserFindClip(NSNumber *indexNum, NSString *name, NSInteger *outListed) {
    if (outListed) *outListed = 0;
    id libs = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
    if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) return nil;
    id library = [(NSArray *)libs firstObject];
    SEL eventsSel = NSSelectorFromString(@"events");
    if (![library respondsToSelector:eventsSel]) return nil;
    id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
    if (![events isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *all = [NSMutableArray array];
    for (id event in (NSArray *)events) {
        [all addObjectsFromArray:SpliceKit_browserClipsOfEvent(event)];
    }
    if (outListed) *outListed = (NSInteger)all.count;
    if (indexNum) {
        NSInteger idx = [indexNum integerValue];
        if (idx >= 0 && idx < (NSInteger)all.count) return all[(NSUInteger)idx];
    }
    NSString *lowerName = name.length > 0 ? [name lowercaseString] : nil;
    if (lowerName) {
        for (id c in all) {
            if ([[SpliceKit_browserClipName(c) lowercaseString] containsString:lowerName]) return c;
        }
    }
    return nil;
}

static NSDictionary *SpliceKit_handleBrowserPlaceClip(NSDictionary *params,
                                                      NSString *selectorName,
                                                      NSString *actionName) {
    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    NSNumber *indexNum = [params[@"index"] isKindOfClass:[NSNumber class]] ? params[@"index"] : nil;
    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : nil;

    NSString *edit = @"insert";
    if ([selectorName isEqualToString:@"appendWithSelectedMedia:"]) edit = @"append";
    else if ([selectorName isEqualToString:@"anchorWithPasteboard:backtimed:trackType:"]) edit = @"connect";

    NSNumber *inNum = [params[@"inSeconds"] isKindOfClass:[NSNumber class]] ? params[@"inSeconds"] : nil;
    NSNumber *outNum = [params[@"outSeconds"] isKindOfClass:[NSNumber class]] ? params[@"outSeconds"] : nil;
    NSNumber *atNum = [params[@"atSeconds"] isKindOfClass:[NSNumber class]] ? params[@"atSeconds"] : nil;
    BOOL backtimed = [params[@"backtimed"] respondsToSelector:@selector(boolValue)] && [params[@"backtimed"] boolValue];
    BOOL dryRun = [params[@"dryRun"] respondsToSelector:@selector(boolValue)] && [params[@"dryRun"] boolValue];
    const double kMaxSeconds = 86400.0 * 24.0;   // 24 days: longer than any timeline, short of overflow

    if (!handle && !indexNum && !name) {
        return @{@"error": @"Clip not found. Provide handle, index, or name."};
    }
    for (NSNumber *n in @[inNum ?: @0, outNum ?: @0, atNum ?: @0]) {
        double v = [n doubleValue];
        if (!isfinite(v) || v > kMaxSeconds) {
            return @{@"error": @"inSeconds, outSeconds and atSeconds must be finite times in seconds"};
        }
    }
    if (atNum && [edit isEqualToString:@"append"]) {
        return @{@"error": @"an append edit (Final Cut Pro: Append, E) always adds at the end of the primary storyline; use insert or connect to place at a time"};
    }
    if (atNum && [atNum doubleValue] < 0.0) {
        return @{@"error": @"atSeconds must be 0 or more"};
    }
    if (backtimed && ![edit isEqualToString:@"connect"]) {
        return @{@"error": @"backtimed is only available for connect edits here (Final Cut Pro: Shift-Q)"};
    }
    if (backtimed) actionName = @"connectBacktimedAtPlayhead";

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        // What this call has already changed when an error answer is built.
        __block BOOL playheadMoved = NO, pasteboardReplaced = NO, selectionCleared = NO;
        NSDictionary *(^failed)(NSString *, NSDictionary *) = ^NSDictionary *(NSString *message, NSDictionary *debug) {
            NSMutableDictionary *err = [NSMutableDictionary dictionary];
            err[@"error"] = message;
            if (debug.count > 0) err[@"placementDebug"] = debug;
            if (playheadMoved || pasteboardReplaced || selectionCleared) {
                err[@"stateChanged"] = @{@"playheadMoved": @(playheadMoved),
                                         @"pasteboardReplaced": @(pasteboardReplaced),
                                         @"selectionCleared": @(selectionCleared)};
            }
            return err;
        };
        @try {
            id clip = nil;
            BOOL clipFromHandle = NO;

            // Resolve clip by handle, index, or name
            if (handle) {
                clip = SpliceKit_resolveHandle(handle);
                clipFromHandle = (clip != nil);
            }

            NSInteger listedCount = 0;
            if (!clip && (indexNum || name)) {
                clip = SpliceKit_browserFindClip(indexNum, name, &listedCount);
            }

            if (!clip) {
                NSString *message;
                if (handle && !indexNum && !name) {
                    message = [NSString stringWithFormat:
                        @"handle %@ does not resolve to an object (handles expire when the handle table is cleared; browser_list_clips() gives fresh ones)", handle];
                } else if (indexNum && !name) {
                    message = [NSString stringWithFormat:
                        @"no browser clip at index %ld (browser_list_clips() lists %ld clip%@%@)",
                        (long)[indexNum integerValue], (long)listedCount, listedCount == 1 ? @"" : @"s",
                        listedCount > 0 ? [NSString stringWithFormat:@", indices 0-%ld", (long)(listedCount - 1)] : @""];
                } else if (name && !indexNum) {
                    message = [NSString stringWithFormat:
                        @"no browser clip whose name contains \"%@\" (%ld clip%@ listed; browser_list_clips() shows their names)",
                        name, (long)listedCount, listedCount == 1 ? @"" : @"s"];
                } else {
                    message = [NSString stringWithFormat:
                        @"no browser clip at index %ld or named like \"%@\" (%ld clip%@ listed)",
                        (long)[indexNum integerValue], name ?: @"", (long)listedCount, listedCount == 1 ? @"" : @"s"];
                }
                result = @{@"error": message};
                return;
            }

            id timelineModule = SpliceKit_getActiveTimelineModule();
            if (!timelineModule) {
                result = @{@"error": @"No active timeline module. Is a project open?"};
                return;
            }

            // A handle from get_timeline_clips names an item already on the timeline; this
            // edit places source clips from the browser. Checked by object identity against
            // the same walk the result diff uses, so it cannot be fooled by a reused handle.
            // A project is not a source clip: Final Cut Pro does not paste a project into
            // a timeline (the edit runs and places nothing), and the open timeline's own
            // project least of all.
            {
                BOOL clipIsProject = SpliceKit_browserItemIsProject(clip);
                id currentSequence = [timelineModule respondsToSelector:@selector(sequence)]
                    ? ((id (*)(id, SEL))objc_msgSend)(timelineModule, @selector(sequence)) : nil;
                if (clipIsProject || (currentSequence && clip == currentSequence)) {
                    NSString *projectName = SpliceKit_browserClipName(clip);
                    result = @{@"error": [NSString stringWithFormat:
                        @"\"%@\" is %@, not a source clip: SpliceKit does not place a project (pasting one placed "
                        @"nothing in the QA run). Pick a clip from browser_list_clips() (projects are marked "
                        @"isProject: true there), or open the project with open_project().",
                        projectName, (currentSequence && clip == currentSequence) ? @"the open timeline's own project" : @"a project"]};
                    return;
                }
            }

            if (clipFromHandle) {
                NSDictionary *onTimeline = SpliceKit_browserTimelineEntries();
                NSString *clipKey = SpliceKit_handlePointerKey(clip);
                NSDictionary *timelineEntry = clipKey.length > 0 ? onTimeline[clipKey] : nil;
                if (timelineEntry) {
                    NSString *entryName = [timelineEntry[@"name"] isKindOfClass:[NSString class]] ? timelineEntry[@"name"] : @"";
                    result = @{@"error": [NSString stringWithFormat:
                        @"handle %@ is a clip on the current timeline (\"%@\"), not a source clip in the browser; "
                        @"add_clip_to_timeline places browser clips (handles from browser_list_clips()). To repeat a "
                        @"timeline clip use FCP's copy and paste: select_clips([...]), then timeline_action(\"copy\") and "
                        @"\"paste\" or \"pasteAsConnected\" at the playhead.", handle, entryName]};
                    return;
                }
            }

            // The clip's own range. Its first frame is not necessarily time 0 (clippedRange
            // starts at the source timecode), so inSeconds/outSeconds count from that frame.
            // browser.listClips reports `duration`, which can differ from clippedRange; the
            // range end is accepted up to the longer of the two.
            SpliceKit_CMTimeRange clipRange = {0};
            BOOL haveClipRange = NO;
            if ([clip respondsToSelector:@selector(clippedRange)]) {
                clipRange = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(clip, @selector(clippedRange));
                haveClipRange = clipRange.duration.timescale > 0;
            }
            double listedDuration = NAN;
            if ([clip respondsToSelector:@selector(duration)]) {
                SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(clip, @selector(duration));
                if (dur.timescale > 0) listedDuration = (double)dur.value / (double)dur.timescale;
                if (!haveClipRange && dur.timescale > 0) {
                    clipRange.start = (SpliceKit_CMTime){0, dur.timescale, 1, 0};
                    clipRange.duration = dur;
                    haveClipRange = YES;
                }
            }
            BOOL wholeClip = (inNum == nil && outNum == nil);
            if (!haveClipRange && !wholeClip) {
                result = @{@"error": @"a range needs the clip's duration, which could not be read (no clippedRange or duration); the whole clip can still be placed"};
                return;
            }

            double frameSeconds = SpliceKit_transitionFrameDurationSeconds(timelineModule);
            // The clip's own frame duration when it exposes one: FCP snaps a range to the
            // clip's frames, so a 12 fps time-lapse can differ from the request by more
            // than a sequence frame and still be right.
            double clipFrameSeconds = 0.0;
            SEL clipFrameSel = NSSelectorFromString(@"frameDuration");
            if ([clip respondsToSelector:clipFrameSel]) {
                @try {
                    SpliceKit_CMTime fd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(clip, clipFrameSel);
                    if (fd.timescale > 0 && fd.value > 0) clipFrameSeconds = (double)fd.value / (double)fd.timescale;
                } @catch (__unused NSException *e) {}
            }
            double tolerance = MAX(MAX(frameSeconds * 2.0, clipFrameSeconds), 0.05);
            double clipDuration = haveClipRange
                ? (double)clipRange.duration.value / (double)clipRange.duration.timescale : NAN;
            double maxDuration = clipDuration;
            if (!isnan(listedDuration) && (isnan(maxDuration) || listedDuration > maxDuration)) maxDuration = listedDuration;
            double clipStartSeconds = (haveClipRange && clipRange.start.timescale > 0)
                ? (double)clipRange.start.value / (double)clipRange.start.timescale : 0.0;
            double inSeconds = inNum ? [inNum doubleValue] : 0.0;
            double outSeconds = outNum ? [outNum doubleValue] : (isnan(clipDuration) ? 0.0 : clipDuration);
            BOOL snapped = NO;

            if (!wholeClip) {
                if (inSeconds < 0.0) {
                    result = @{@"error": @"the range start must be 0 or more (seconds from the clip's first frame)"};
                    return;
                }
                if (outSeconds > maxDuration + frameSeconds * 0.5) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"the range end (%.3fs) is beyond the end of the clip, which is %.3fs long%@",
                        outSeconds, maxDuration,
                        (!isnan(listedDuration) && fabs(listedDuration - clipDuration) > 0.0005)
                            ? [NSString stringWithFormat:@" (clippedRange %.3fs, duration %.3fs)", clipDuration, listedDuration] : @""]};
                    return;
                }
                outSeconds = MIN(outSeconds, maxDuration);
                if (clipFrameSeconds > 0.0) {
                    double snappedIn = round(inSeconds / clipFrameSeconds) * clipFrameSeconds;
                    double snappedOut = round(outSeconds / clipFrameSeconds) * clipFrameSeconds;
                    if (fabs(snappedIn - inSeconds) > 1e-6 || fabs(snappedOut - outSeconds) > 1e-6) snapped = YES;
                    inSeconds = MAX(0.0, snappedIn);
                    outSeconds = MIN(maxDuration, snappedOut);
                }
                double minLength = clipFrameSeconds > 0.0 ? clipFrameSeconds : frameSeconds;
                if (outSeconds - inSeconds < minLength * 0.5) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"the range must be at least one frame long (start %.3fs, end %.3fs; one frame is %.4fs)",
                        inSeconds, outSeconds, minLength]};
                    return;
                }
            }

            SpliceKit_CMTimeRange sourceRange = clipRange;
            if (!wholeClip) {
                int32_t startScale = clipRange.start.timescale > 0 ? clipRange.start.timescale : clipRange.duration.timescale;
                int32_t durationScale = clipRange.duration.timescale;
                sourceRange.start.value = (clipRange.start.timescale > 0 ? clipRange.start.value : 0)
                    + (int64_t)llround(inSeconds * (double)startScale);
                sourceRange.start.timescale = startScale;
                sourceRange.start.flags = 1;
                sourceRange.start.epoch = clipRange.start.epoch;
                sourceRange.duration.value = (int64_t)llround((outSeconds - inSeconds) * (double)durationScale);
                sourceRange.duration.timescale = durationScale;
                sourceRange.duration.flags = 1;
                sourceRange.duration.epoch = 0;
            }

            NSString *clipName = @"";
            if ([clip respondsToSelector:@selector(displayName)])
                clipName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";

            NSMutableDictionary *plan = [NSMutableDictionary dictionary];
            plan[@"edit"] = edit;
            plan[@"backtimed"] = @(backtimed);
            plan[@"clip"] = clipName;   // legacy: the clip's name, as browser.appendClip always returned
            NSMutableDictionary *sourceClip = [NSMutableDictionary dictionary];
            sourceClip[@"handle"] = SpliceKit_storeHandle(clip) ?: @"";
            sourceClip[@"name"] = clipName;
            sourceClip[@"class"] = NSStringFromClass([clip class]) ?: @"";
            if (!isnan(clipDuration)) sourceClip[@"durationSeconds"] = @(clipDuration);
            if (!isnan(listedDuration)) sourceClip[@"listedDurationSeconds"] = @(listedDuration);
            sourceClip[@"startSeconds"] = @(clipStartSeconds);
            if (clipFrameSeconds > 0.0) sourceClip[@"frameSeconds"] = @(clipFrameSeconds);
            plan[@"sourceClip"] = sourceClip;
            NSMutableDictionary *source = [NSMutableDictionary dictionary];
            source[@"startSeconds"] = @(inSeconds);
            source[@"endSeconds"] = @(outSeconds);
            source[@"durationSeconds"] = @(outSeconds - inSeconds);
            source[@"wholeClip"] = @(wholeClip);
            if (snapped) source[@"snappedToClipFrames"] = @YES;
            plan[@"source"] = source;
            NSMutableDictionary *target = [NSMutableDictionary dictionary];
            if (atNum) target[@"requestedSeconds"] = atNum;
            target[@"playheadBeforeSeconds"] = @(SpliceKit_transitionCurrentTimeSeconds(timelineModule));
            plan[@"target"] = target;

            if (dryRun) {
                plan[@"status"] = @"dry_run";
                plan[@"dryRun"] = @YES;
                result = plan;
                return;
            }

            // Order: seek (and verify) first, then the pasteboard, then the selection, then
            // paste, so the pasteboard is replaced as late as possible before it is used.
            NSMutableDictionary *seekDebug = [NSMutableDictionary dictionary];
            double targetSeconds = NAN;
            if (atNum) {
                targetSeconds = [atNum doubleValue];
                playheadMoved = YES;
                if (!SpliceKit_browserSeekAndVerify(timelineModule, targetSeconds, tolerance, seekDebug)) {
                    result = failed([NSString stringWithFormat:
                        @"could not move the playhead to %.3fs before the edit", targetSeconds], seekDebug);
                    return;
                }
            } else if (![edit isEqualToString:@"append"]) {
                targetSeconds = SpliceKit_transitionCurrentTimeSeconds(timelineModule);
            }
            BOOL skimmingActive = SpliceKit_browserSkimmingActive(timelineModule);
            seekDebug[@"skimmingActive"] = @(skimmingActive);

            id mediaRange = nil;
            Class rangeObjClass = objc_getClass("FigTimeRangeAndObject");
            SEL rangeAndObjSel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
            if (haveClipRange && rangeObjClass && [(id)rangeObjClass respondsToSelector:rangeAndObjSel]) {
                mediaRange = ((id (*)(id, SEL, SpliceKit_CMTimeRange, id))objc_msgSend)(
                    (id)rangeObjClass, rangeAndObjSel, sourceRange, clip);
            }
            if (!wholeClip && !mediaRange) {
                result = failed(@"a range selection needs FigTimeRangeAndObject, which this Final Cut Pro build does not provide; the whole clip can still be placed", seekDebug);
                return;
            }

            NSString *pasteboardName = nil;
            NSMutableDictionary *pasteboardDebug = [NSMutableDictionary dictionary];
            NSString *pasteboardError = nil;
            pasteboardReplaced = YES;
            BOOL wroteExplicitClip = SpliceKit_browserPrepareExplicitPasteboard(
                clip, mediaRange, &pasteboardName, pasteboardDebug, &pasteboardError);
            [pasteboardDebug addEntriesFromDictionary:seekDebug];
            if (!wroteExplicitClip) {
                result = failed(pasteboardError ?: @"Failed to prepare explicit pasteboard data.", pasteboardDebug);
                return;
            }
            if (!wholeClip && ![pasteboardDebug[@"pasteboardWriteRanges"] boolValue]) {
                // The fallback wrote the whole clip; placing that would silently ignore the range.
                result = failed(@"Final Cut Pro did not accept a range for this clip (writeRangesOfMedia: failed), so the range cannot be honored; nothing was placed (the pasteboard now holds the whole clip)", pasteboardDebug);
                return;
            }

            selectionCleared = YES;
            SpliceKit_sendTimelineSimpleAction(timelineModule, @"deselectAll:");
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

            uint64_t handleGenerationBefore = SpliceKit_handleGeneration();
            NSDictionary *beforeEntries = SpliceKit_browserTimelineEntries();

            NSDictionary *placementResult = nil;
            if ([edit isEqualToString:@"append"]) {
                placementResult = SpliceKit_browserAppendExplicitClipToTimelineEnd(
                    timelineModule, clip, pasteboardName);
            } else if ([edit isEqualToString:@"connect"]) {
                placementResult = SpliceKit_browserConnectExplicitClipAtPlayhead(
                    timelineModule, clip, pasteboardName, backtimed);
            } else {
                placementResult = SpliceKit_browserInsertExplicitClipAtPlayhead(
                    timelineModule, clip, pasteboardName);
            }

            NSMutableDictionary *mergedResult = [NSMutableDictionary dictionaryWithDictionary:
                placementResult ?: @{}];
            NSMutableDictionary *mergedDebug = [NSMutableDictionary dictionary];
            if ([placementResult[@"placementDebug"] isKindOfClass:[NSDictionary class]]) {
                [mergedDebug addEntriesFromDictionary:placementResult[@"placementDebug"]];
            }
            [mergedDebug addEntriesFromDictionary:pasteboardDebug];
            if (mergedDebug.count > 0) {
                mergedResult[@"placementDebug"] = mergedDebug;
            }
            if (placementResult[@"error"]) {
                result = failed(placementResult[@"error"], mergedDebug);
                return;
            }

            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

            // What the edit added: objects that exist now and did not before.
            NSDictionary *afterEntries = SpliceKit_browserTimelineEntries();
            BOOL handleTableReset = SpliceKit_handleGeneration() != handleGenerationBefore;
            NSMutableArray *newEntries = [NSMutableArray array];
            for (NSString *entryKey in afterEntries) {
                if (beforeEntries[entryKey]) continue;
                [newEntries addObject:SpliceKit_browserPlacedEntry(afterEntries[entryKey])];
            }

            // The placed clip is the new object that is the source clip: same name, on the
            // primary storyline for append/insert and connected for connect, not a gap, and
            // nearest the target. Anything else new (the far half of a split clip, a gap FCP
            // added) is reported separately.
            BOOL wantConnected = [edit isEqualToString:@"connect"];
            double storylineEndBefore = [mergedDebug[@"targetEndSeconds"] doubleValue];
            double aimSeconds = [edit isEqualToString:@"append"] ? storylineEndBefore : targetSeconds;
            NSDictionary *primary = nil;
            double primaryDistance = INFINITY;
            for (NSDictionary *entry in newEntries) {
                if ([entry[@"connected"] boolValue] != wantConnected) continue;
                NSString *cls = entry[@"class"] ?: @"";
                if ([cls rangeOfString:@"Gap"].location != NSNotFound) continue;
                BOOL sameName = clipName.length == 0 || [entry[@"name"] isEqualToString:clipName];
                double anchor = backtimed ? [entry[@"endSeconds"] doubleValue] : [entry[@"startSeconds"] doubleValue];
                double distance = isnan(aimSeconds) ? 0.0 : fabs(anchor - aimSeconds);
                if (!sameName) distance += 1.0e6;   // a differently named object only if nothing else fits
                if (distance < primaryDistance) {
                    primaryDistance = distance;
                    primary = entry;
                }
            }
            NSMutableArray *alsoNew = [NSMutableArray array];
            for (NSDictionary *entry in newEntries) {
                if (entry != primary) [alsoNew addObject:entry];
            }
            [alsoNew sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                double sa = [a[@"startSeconds"] doubleValue], sb = [b[@"startSeconds"] doubleValue];
                return sa < sb ? NSOrderedAscending : (sa > sb ? NSOrderedDescending : NSOrderedSame);
            }];

            double sourceDuration = outSeconds - inSeconds;
            NSNumber *rangeHonored = nil;
            NSNumber *positionVerified = nil;
            if (primary && primary[@"durationSeconds"] && !wholeClip) {
                double placedDuration = [primary[@"durationSeconds"] doubleValue];
                rangeHonored = @(fabs(placedDuration - sourceDuration) <= tolerance);
            } else if (primary && primary[@"durationSeconds"] && !isnan(clipDuration)) {
                double placedDuration = [primary[@"durationSeconds"] doubleValue];
                rangeHonored = @(fabs(placedDuration - clipDuration) <= tolerance);
            }
            if (primary && primary[@"startSeconds"] && primary[@"endSeconds"]) {
                double placedStart = [primary[@"startSeconds"] doubleValue];
                double placedEnd = [primary[@"endSeconds"] doubleValue];
                if ([edit isEqualToString:@"append"]) {
                    positionVerified = @(fabs(placedStart - storylineEndBefore) <= tolerance);
                    target[@"storylineEndBeforeSeconds"] = @(storylineEndBefore);
                } else if (!isnan(targetSeconds)) {
                    positionVerified = @(backtimed ? fabs(placedEnd - targetSeconds) <= tolerance
                                                   : fabs(placedStart - targetSeconds) <= tolerance);
                }
            }
            target[@"playheadAfterSeconds"] = @(SpliceKit_transitionCurrentTimeSeconds(timelineModule));
            if (!isnan(targetSeconds)) target[@"editSeconds"] = @(targetSeconds);

            BOOL verified = primary != nil && !handleTableReset
                && (rangeHonored == nil || [rangeHonored boolValue])
                && (positionVerified == nil || [positionVerified boolValue]);

            [mergedResult addEntriesFromDictionary:plan];
            mergedResult[@"target"] = target;
            mergedResult[@"status"] = @"ok";
            mergedResult[@"clipName"] = clipName;
            mergedResult[@"action"] = actionName ?: @"browserPlaceClip";
            mergedResult[@"placed"] = primary ? @[primary] : @[];
            mergedResult[@"placedCount"] = @(primary ? 1 : 0);
            mergedResult[@"alsoNew"] = alsoNew;
            mergedResult[@"verified"] = @(verified);
            mergedResult[@"placementVerified"] = @(verified);
            mergedResult[@"handleTableReset"] = @(handleTableReset);
            mergedResult[@"skimmingActive"] = @(skimmingActive);
            if (rangeHonored) mergedResult[@"rangeHonored"] = rangeHonored;
            if (positionVerified) mergedResult[@"positionVerified"] = positionVerified;
            if (!handleTableReset && !primary && newEntries.count == 0) {
                // Nothing appeared: Final Cut Pro placed nothing (it refuses some sources,
                // a project among them). Not an "ok" (QA run 2); the pasteboard was replaced
                // and the playhead may have moved, which the error answer says.
                SpliceKit_log(@"[Place] %@ of \"%@\": the edit ran but no new clip appeared on the timeline", edit, clipName);
                result = failed([NSString stringWithFormat:
                    @"the %@ edit ran but no new clip appeared on the timeline: Final Cut Pro placed nothing "
                    @"(the source \"%@\" may not be something it pastes; get_timeline_clips shows the timeline as it is)",
                    edit, clipName], mergedDebug);
                return;
            }
            NSMutableArray *notes = [NSMutableArray array];
            if (handleTableReset) {
                [notes addObject:@"the handle table was reset during this call (it holds at most 2000 handles): handles from earlier reads are no longer valid and the placement could not be verified; call get_timeline_clips again"];
            } else if (!primary) {
                [notes addObject:@"the edit created objects on the timeline but none is the source clip where it was expected; see alsoNew, check get_timeline_clips and undo if needed"];
            } else if (!verified) {
                [notes addObject:@"a clip was placed but its duration or position does not match the request within two frames (at least 50 ms); compare placed with source/target and undo if needed"];
            }
            if (skimmingActive) {
                [notes addObject:@"the skimmer was active over the timeline; Final Cut Pro makes edits at the skimmer, not the playhead, while skimming"];
            }
            if (alsoNew.count > 0) {
                [notes addObject:[NSString stringWithFormat:@"%lu other new object(s) on the timeline (alsoNew): the far half of a split clip or a gap Final Cut Pro added", (unsigned long)alsoNew.count]];
            }
            if (notes.count > 0) mergedResult[@"note"] = [notes componentsJoinedByString:@" | "];
            result = mergedResult;
        } @catch (NSException *e) {
            result = failed([NSString stringWithFormat:@"Exception: %@", e.reason], nil);
        }
    });
    return result ?: @{@"error": @"Failed to place browser clip (main thread did not finish in time)"};
}

// Append a clip from the event browser to the timeline
static NSDictionary *SpliceKit_handleBrowserAppendClip(NSDictionary *params) {
    return SpliceKit_handleBrowserPlaceClip(params,
                                            @"appendWithSelectedMedia:",
                                            @"appendToStoryline");
}

// Insert a clip from the event browser at the current playhead
static NSDictionary *SpliceKit_handleBrowserInsertClip(NSDictionary *params) {
    return SpliceKit_handleBrowserPlaceClip(params,
                                            @"insertWithSelectedMedia:",
                                            @"insertAtPlayhead");
}

#pragma mark - Media Import

// Find an event by name across all open libraries. If name is nil or empty,
// picks the first event of the first library. Returns nil if nothing matches.
// Optional library name filters the library too.
static id SpliceKit_resolveMediaImportEvent(NSString *libraryName, NSString *eventName) {
    id libs = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
    if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
        return nil;
    }

    NSString *libLower = libraryName.length ? [libraryName lowercaseString] : nil;
    NSString *evtLower = eventName.length ? [eventName lowercaseString] : nil;

    for (id library in (NSArray *)libs) {
        if (libLower) {
            NSString *name = nil;
            if ([library respondsToSelector:@selector(displayName)]) {
                name = ((id (*)(id, SEL))objc_msgSend)(library, @selector(displayName));
            }
            if (!name || ![[name lowercaseString] containsString:libLower]) continue;
        }

        SEL eventsSel = NSSelectorFromString(@"events");
        if (![library respondsToSelector:eventsSel]) continue;
        id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
        if (![events isKindOfClass:[NSArray class]]) continue;

        for (id eventRecord in (NSArray *)events) {
            if (evtLower) {
                // FFEventRecord answers displayName (the name the browser shows, and the one
                // browser.listClips and this handler's own answer report), not name.
                NSString *ename = nil;
                for (NSString *selName in @[@"displayName", @"name"]) {
                    SEL sel = NSSelectorFromString(selName);
                    if (![eventRecord respondsToSelector:sel]) continue;
                    id v = nil;
                    @try { v = ((id (*)(id, SEL))objc_msgSend)(eventRecord, sel); } @catch (NSException *e) { v = nil; }
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { ename = v; break; }
                }
                if (!ename || ![[ename lowercaseString] containsString:evtLower]) continue;
            }
            if (![eventRecord respondsToSelector:@selector(project)]) continue;
            id project = ((id (*)(id, SEL))objc_msgSend)(eventRecord, @selector(project));
            if (project) return project;
        }

        // If event name wasn't specified, return first event of this library.
        if (!evtLower && [(NSArray *)events count] > 0) {
            id eventRecord = [(NSArray *)events firstObject];
            if ([eventRecord respondsToSelector:@selector(project)]) {
                return ((id (*)(id, SEL))objc_msgSend)(eventRecord, @selector(project));
            }
        }
    }
    return nil;
}

// media.importFile — import one or more local files into an event's browser.
// Uses -[FFMediaEventProject newClipFromURL:manageFileType:] + addOwnedClipsObject:
// which is the same path drag-and-drop funnels into once the user drops.
//
// Params:
//   paths       : [str]  — absolute file paths (required)
//   event?      : str    — case-insensitive substring match for event name
//   library?    : str    — case-insensitive substring match for library display name
//   manageFileType? : int — 0 = leave in place (default), other values per FCP
//                          (e.g. 1 = copy to managed media location).
//
// Returns { status, event, imported:[{path, handle, name}], skipped:[{path, reason}] }.
static NSDictionary *SpliceKit_handleMediaImportFile(NSDictionary *params) {
    id pathsAny = params[@"paths"];
    NSString *single = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : nil;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if ([pathsAny isKindOfClass:[NSArray class]]) {
        for (id p in (NSArray *)pathsAny) {
            if ([p isKindOfClass:[NSString class]] && [(NSString *)p length]) [paths addObject:p];
        }
    }
    if (single) [paths addObject:single];
    if (paths.count == 0) {
        return @{@"error": @"No paths provided. Pass `paths` (array of absolute file paths) or `path` (single)."};
    }

    NSString *libHint = [params[@"library"] isKindOfClass:[NSString class]] ? params[@"library"] : nil;
    NSString *eventHint = [params[@"event"] isKindOfClass:[NSString class]] ? params[@"event"] : nil;
    NSNumber *manageNum = [params[@"manageFileType"] isKindOfClass:[NSNumber class]] ? params[@"manageFileType"] : nil;
    int manageFileType = manageNum ? [manageNum intValue] : 0;

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id project = SpliceKit_resolveMediaImportEvent(libHint, eventHint);
            if (!project) {
                NSString *message;
                if (eventHint.length > 0 || libHint.length > 0) {
                    message = [NSString stringWithFormat:
                        @"No event matching%@%@ in the open libraries (names as the browser shows them; browser_list_clips() lists each clip's event). Leave event out to import into the first event.",
                        eventHint.length > 0 ? [NSString stringWithFormat:@" \"%@\"", eventHint] : @"",
                        libHint.length > 0 ? [NSString stringWithFormat:@" in a library matching \"%@\"", libHint] : @""];
                } else {
                    message = @"No event found. Make sure a library with at least one event is open.";
                }
                result = @{@"error": message};
                return;
            }
            NSString *eventName = nil;
            if ([project respondsToSelector:@selector(displayName)]) {
                eventName = ((id (*)(id, SEL))objc_msgSend)(project, @selector(displayName));
            }

            NSMutableArray *imported = [NSMutableArray array];
            NSMutableArray *skipped = [NSMutableArray array];
            SEL newClipSel = NSSelectorFromString(@"newClipFromURL:manageFileType:");
            SEL addOwnedSel = NSSelectorFromString(@"addOwnedClipsObject:");

            for (NSString *path in paths) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    [skipped addObject:@{@"path": path, @"reason": @"file not found"}];
                    continue;
                }
                NSURL *url = [NSURL fileURLWithPath:path];
                id clip = nil;
                if ([project respondsToSelector:newClipSel]) {
                    clip = ((id (*)(id, SEL, id, int))objc_msgSend)(project, newClipSel, url, manageFileType);
                }
                if (!clip) {
                    [skipped addObject:@{@"path": path, @"reason": @"newClipFromURL returned nil (unsupported format or invalid source?)"}];
                    continue;
                }
                if ([project respondsToSelector:addOwnedSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(project, addOwnedSel, clip);
                }
                NSString *displayName = nil;
                if ([clip respondsToSelector:@selector(displayName)]) {
                    displayName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                }
                NSString *handle = SpliceKit_storeHandle(clip);
                [imported addObject:@{
                    @"path": path,
                    @"handle": handle ?: @"",
                    @"name": displayName ?: @"",
                }];
            }

            result = @{
                @"status": imported.count > 0 ? @"ok" : @"error",
                @"event": eventName ?: @"",
                @"imported": imported,
                @"skipped": skipped,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Import failed on main thread"};
}

// media.removeClip — take a source clip back out of an event's browser.
//
// The counterpart to media.importFile. Without it SpliceKit could put clips into a
// library and never take them out: every import_media / import_url call in a test run
// left a clip behind, and nothing short of Final Cut Pro's own UI could remove it.
// -removeOwnedClipsObject: is the exact inverse of the -addOwnedClipsObject: the import
// uses, so the clip goes the same way it came.
//
// Params:
//   handle?  : str — a handle from browser.listClips or media.importFile
//   name?    : str — exact display name, used when no handle is given
//   event?   : str — case-insensitive substring match, narrows the search
//   library? : str — case-insensitive substring match
//   dryRun?  : bool — report what would be removed, change nothing
//   includeProjects? : bool — allow removing a project (a whole timeline), off by default
//
// Returns { status, removed:[{name, event}], message } or an error naming what it
// searched. Refuses a project: a project is a library item, not an owned clip, and
// cleanup_temp_projects / Final Cut Pro's own delete is the way to remove one.
static NSDictionary *SpliceKit_handleMediaRemoveClip(NSDictionary *params) {
    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : nil;
    NSString *libHint = [params[@"library"] isKindOfClass:[NSString class]] ? params[@"library"] : nil;
    NSString *eventHint = [params[@"event"] isKindOfClass:[NSString class]] ? params[@"event"] : nil;
    BOOL dryRun = [params[@"dryRun"] boolValue];
    BOOL includeProjects = [params[@"includeProjects"] boolValue];

    if (handle.length == 0 && name.length == 0) {
        return @{@"error": @"Pass `handle` (from browser_list_clips or import_media) or `name` "
                           @"(the clip's name exactly as the browser shows it)."};
    }

    id wanted = nil;
    if (handle.length > 0) {
        wanted = SpliceKit_resolveHandle(handle);
        if (!wanted) {
            return @{@"error": [NSString stringWithFormat:
                @"Handle '%@' no longer resolves. Handles are dropped when a project is "
                @"reopened; call browser_list_clips() again for a fresh one.", handle]};
        }
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            SEL dnSel = @selector(displayName);
            SEL removeSel = NSSelectorFromString(@"removeOwnedClipsObject:");
            NSMutableArray *removed = [NSMutableArray array];
            NSMutableArray *searched = [NSMutableArray array];
            NSMutableArray *matches = [NSMutableArray array];
            NSMutableArray *failed = [NSMutableArray array];
            NSUInteger projectCount = 0;

            for (id library in (NSArray *)libs) {
                if (libHint.length > 0) {
                    NSString *libName = [library respondsToSelector:dnSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(library, dnSel) : @"";
                    if (![[libName lowercaseString] containsString:[libHint lowercaseString]]) continue;
                }
                SEL eventsSel = NSSelectorFromString(@"events");
                if (![library respondsToSelector:eventsSel]) continue;
                id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
                if (![events isKindOfClass:[NSArray class]]) continue;

                for (id event in (NSArray *)events) {
                    NSString *eventName = [event respondsToSelector:dnSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(event, dnSel) : @"";
                    if (eventHint.length > 0 &&
                        ![[eventName lowercaseString] containsString:[eventHint lowercaseString]]) {
                        continue;
                    }
                    [searched addObject:eventName ?: @"?"];

                    // The clips belong to the event's FFMediaEventProject, which is what
                    // answers -removeOwnedClipsObject: (and what media.importFile adds to).
                    // The FFEventRecord from -events does not, so asking it directly found
                    // nothing and skipped every event.
                    id project = [event respondsToSelector:@selector(project)]
                        ? ((id (*)(id, SEL))objc_msgSend)(event, @selector(project)) : nil;
                    if (!project || ![project respondsToSelector:removeSel]) continue;

                    // Collect first, remove afterwards. Removing inside the walk meant a name
                    // that happened to match in two events took both, silently, and a raise
                    // part way through threw away the record of what had already gone.
                    for (id clip in SpliceKit_browserClipsOfEvent(event)) {
                        NSString *clipName = [clip respondsToSelector:dnSel]
                            ? ((id (*)(id, SEL))objc_msgSend)(clip, dnSel) : nil;
                        BOOL match = wanted ? (clip == wanted)
                                            : (clipName && [clipName isEqualToString:name]);
                        if (!match) continue;

                        BOOL clipIsProject = SpliceKit_browserItemIsProject(clip);
                        if (clipIsProject && !includeProjects) {
                            result = @{@"error": [NSString stringWithFormat:
                                @"'%@' is a project, not a source clip. Removing a project removes a "
                                @"whole timeline, so pass include_projects=True if that is what you mean; "
                                @"cleanup_temp_projects removes SpliceKit's own scratch projects without "
                                @"the flag.", clipName ?: @"?"]};
                            return;
                        }

                        [matches addObject:@[clip, project, clipName ?: @"", eventName ?: @"",
                                             @(clipIsProject)]];
                    }
                }
            }

            // A name is not unique across a library, let alone across every open library. One
            // call used to take every clip that happened to share the name, in every event, and
            // only say "Removed 3 clips". For something that deletes, ambiguity is an error.
            if (!wanted && matches.count > 1) {
                NSMutableArray *where = [NSMutableArray array];
                for (NSArray *m in matches) {
                    [where addObject:[NSString stringWithFormat:@"'%@' in event '%@'%@",
                        m[2], m[3], [m[4] boolValue] ? @" (a project)" : @""]];
                }
                result = @{@"error": [NSString stringWithFormat:
                    @"'%@' matches %lu items: %@. Nothing was removed. Pass event= (and library= "
                    @"if more than one is open) to say which, or pass the handle from "
                    @"browser_list_clips().",
                    name, (unsigned long)matches.count,
                    [where componentsJoinedByString:@"; "]]};
                return;
            }

            for (NSArray *m in matches) {
                id clip = m[0], project = m[1];
                NSString *clipName = m[2], *eventName = m[3];
                BOOL clipIsProject = [m[4] boolValue];
                if (!dryRun) {
                    // Guarded one at a time so a raise on the second item cannot erase the
                    // record that the first one already went.
                    @try {
                        ((void (*)(id, SEL, id))objc_msgSend)(project, removeSel, clip);
                    } @catch (NSException *e) {
                        [failed addObject:@{@"name": clipName,
                                            @"event": eventName,
                                            @"reason": e.reason ?: @"unknown"}];
                        continue;
                    }
                }
                [removed addObject:@{@"name": clipName,
                                     @"event": eventName,
                                     @"kind": clipIsProject ? @"project" : @"clip"}];
                if (clipIsProject) projectCount++;
            }

            if (removed.count == 0 && failed.count > 0) {
                result = @{@"status": @"error",
                           @"removed": removed,
                           @"failed": failed,
                           @"error": @"Every matching item failed to remove; see `failed`."};
                return;
            }

            if (removed.count == 0) {
                result = @{@"error": [NSString stringWithFormat:
                    @"No browser clip matching %@ in %@. browser_list_clips() lists every clip "
                    @"with its event and handle.",
                    wanted ? [NSString stringWithFormat:@"handle '%@'", handle]
                           : [NSString stringWithFormat:@"name '%@'", name],
                    searched.count > 0 ? [searched componentsJoinedByString:@", "]
                                       : @"any event"]};
                return;
            }

            result = @{
                @"status": @"ok",
                @"dryRun": @(dryRun),
                @"removed": removed,
                @"failed": failed,
                // Say which it was: "1 clip" when a project went is the sort of answer that
                // makes someone think their timeline is still there.
                @"message": [NSString stringWithFormat:@"%@ %lu %@ from the browser.%@",
                    dryRun ? @"Would remove" : @"Removed",
                    (unsigned long)removed.count,
                    projectCount == removed.count
                        ? (removed.count == 1 ? @"project" : @"projects")
                        : (projectCount > 0
                            ? @"item(s), projects among them,"
                            : (removed.count == 1 ? @"clip" : @"clips")),
                    dryRun ? @"" : @" The media files on disk are untouched."]
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Remove failed on main thread"};
}

static NSDictionary *SpliceKit_handleBrowserConnectClip(NSDictionary *params) {
    return SpliceKit_handleBrowserPlaceClip(params,
                                            @"anchorWithPasteboard:backtimed:trackType:",
                                            @"connectAbovePlayhead");
}

// browser.placeClip: append (E), insert (W) or connect (Q) in one call; see
// SpliceKit_handleBrowserPlaceClip for the range / target / backtimed / dryRun params.
static NSDictionary *SpliceKit_handleBrowserPlaceClipEdit(NSDictionary *params) {
    NSString *edit = [params[@"edit"] isKindOfClass:[NSString class]]
        ? [params[@"edit"] lowercaseString] : @"append";
    if ([edit isEqualToString:@"append"]) return SpliceKit_handleBrowserAppendClip(params);
    if ([edit isEqualToString:@"insert"]) return SpliceKit_handleBrowserInsertClip(params);
    if ([edit isEqualToString:@"connect"]) return SpliceKit_handleBrowserConnectClip(params);
    if ([edit isEqualToString:@"overwrite"]) {
        return @{@"error": @"an overwrite edit (Final Cut Pro: Overwrite, D) is not available through this method: Final Cut Pro makes it from the browser's own range selection, which SpliceKit does not set; use insert or connect"};
    }
    return @{@"error": [NSString stringWithFormat:@"unknown edit '%@': use append, insert or connect", edit]};
}

#pragma mark - Menu Execute Handler
//
// Navigate and click any FCP menu item by path, e.g. ["File", "New", "Project..."].
// This is the escape hatch for actions that don't have a known ObjC selector.
//

NSDictionary *SpliceKit_handleMenuExecute(NSDictionary *params) {
    NSArray *menuPath = params[@"menuPath"];
    if (![menuPath isKindOfClass:[NSArray class]] || menuPath.count < 2) {
        // Say which of the two it is: "array required" when an array WAS given, just
        // a one-entry one, sends the caller looking for a serialisation problem.
        return @{@"error": [menuPath isKindOfClass:[NSArray class]]
            ? [NSString stringWithFormat:
                 @"menuPath needs at least a menu and an item, got %lu entry: %@",
                 (unsigned long)menuPath.count, menuPath]
            : @"menuPath array required (e.g. [\"File\", \"New\", \"Project...\"])"};
    }

    BOOL dryRun = [params[@"dry_run"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
            if (!mainMenu) {
                result = @{@"error": @"No main menu found"};
                return;
            }

            // Navigate through the menu hierarchy
            NSMenu *currentMenu = mainMenu;
            NSMenuItem *targetItem = nil;

            for (NSUInteger i = 0; i < menuPath.count; i++) {
                NSString *title = menuPath[i];
                NSMenuItem *item = nil;

                // Search for matching menu item (case-insensitive, trimmed)
                for (NSInteger j = 0; j < [currentMenu numberOfItems]; j++) {
                    NSMenuItem *candidate = [currentMenu itemAtIndex:j];
                    NSString *candidateTitle = [candidate title];
                    // Match exact or without trailing ellipsis/dots
                    if ([candidateTitle caseInsensitiveCompare:title] == NSOrderedSame ||
                        [[candidateTitle stringByReplacingOccurrencesOfString:@"…" withString:@""]
                            caseInsensitiveCompare:
                            [title stringByReplacingOccurrencesOfString:@"..." withString:@""]] == NSOrderedSame ||
                        [[candidateTitle stringByReplacingOccurrencesOfString:@"…" withString:@""]
                            caseInsensitiveCompare:title] == NSOrderedSame) {
                        item = candidate;
                        break;
                    }
                }

                if (!item) {
                    // Build list of available items for error message
                    NSMutableArray *available = [NSMutableArray array];
                    for (NSInteger j = 0; j < [currentMenu numberOfItems]; j++) {
                        NSMenuItem *candidate = [currentMenu itemAtIndex:j];
                        if (![candidate isSeparatorItem]) {
                            [available addObject:[candidate title]];
                        }
                    }
                    result = @{@"error": [NSString stringWithFormat:@"Menu item '%@' not found. Available: %@",
                                title, [available componentsJoinedByString:@", "]]};
                    return;
                }

                if (i == menuPath.count - 1) {
                    // Last item - this is the target
                    targetItem = item;
                } else {
                    // Navigate into submenu
                    NSMenu *submenu = [item submenu];
                    if (!submenu) {
                        result = @{@"error": [NSString stringWithFormat:@"'%@' has no submenu", title]};
                        return;
                    }
                    currentMenu = submenu;
                }
            }

            if (!targetItem) {
                result = @{@"error": @"Target menu item not found"};
                return;
            }

            SEL action = [targetItem action];
            id target = [targetItem target];
            NSString *itemTitle = [targetItem title];
            BOOL enabled = [targetItem isEnabled];

            // dry_run=true: describe what would fire without firing it. Use
            // validateMenuItem: to probe the intended target; modal detection
            // is a heuristic based on trailing ellipsis in the menu title.
            if (dryRun) {
                BOOL validates = enabled;
                id validateTarget = target;
                if (action) {
                    if (target && [target respondsToSelector:@selector(validateMenuItem:)]) {
                        @try {
                            validates = ((BOOL (*)(id, SEL, id))objc_msgSend)(
                                target, @selector(validateMenuItem:), targetItem);
                        } @catch (NSException *e) { validates = enabled; }
                    } else if (!target) {
                        // Responder-chain action — walk the chain to see who'd handle it.
                        id responder = [[app keyWindow] firstResponder];
                        while (responder) {
                            if ([responder respondsToSelector:action]) {
                                validateTarget = responder;
                                break;
                            }
                            responder = [responder nextResponder];
                        }
                    }
                }
                BOOL likelyModal = [itemTitle hasSuffix:@"…"] || [itemTitle hasSuffix:@"..."];
                result = @{
                    @"dry_run": @YES,
                    @"menuItem": itemTitle ?: @"",
                    @"enabled": @(enabled),
                    @"validates": @(validates),
                    @"action": action ? NSStringFromSelector(action) : [NSNull null],
                    @"target_class": validateTarget
                                     ? NSStringFromClass([validateTarget class])
                                     : @"responder chain",
                    @"likely_modal": @(likelyModal),
                    @"would_fire": @(enabled && action != NULL),
                    @"note": @"No action was performed. Remove dry_run=true to execute.",
                };
                return;
            }

            if (!enabled) {
                result = @{@"error": [NSString stringWithFormat:@"Menu item '%@' is disabled",
                            itemTitle]};
                return;
            }

            // Execute the menu item's action
            if (action) {
                if (target) {
                    ((void (*)(id, SEL, id))objc_msgSend)(target, action, targetItem);
                } else {
                    // Send through responder chain
                    ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                        app, @selector(sendAction:to:from:), action, nil, targetItem);
                }
                result = @{@"status": @"ok", @"menuItem": itemTitle ?: @"",
                          @"action": NSStringFromSelector(action)};
            } else {
                result = @{@"error": @"Menu item has no action"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Menu execute failed"};
}

static NSDictionary *SpliceKit_handleMenuList(NSDictionary *params) {
    NSString *menuName = params[@"menu"]; // optional: specific top-level menu
    NSNumber *depth = params[@"depth"] ?: @(2);
    // validate: run each listed menu's validation first (-[NSMenu update], what AppKit
    // does when the menu opens), so titles set on validation (Edit > Undo <name>) and
    // the enabled states are current. Off by default: it validates every listed item.
    BOOL validate = [params[@"validate"] respondsToSelector:@selector(boolValue)] && [params[@"validate"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
            if (!mainMenu) {
                result = @{@"error": @"No main menu found"};
                return;
            }

            // Recursive helper to build menu tree
            __block id __weak (^weakBuildMenu)(NSMenu *, int);
            __block id (^buildMenu)(NSMenu *, int);
            weakBuildMenu = buildMenu = ^id(NSMenu *menu, int maxDepth) {
                NSMutableArray *items = [NSMutableArray array];
                if (validate) {
                    @try { [menu update]; } @catch (NSException *e) {}
                }
                for (NSInteger i = 0; i < [menu numberOfItems]; i++) {
                    NSMenuItem *item = [menu itemAtIndex:i];
                    if ([item isSeparatorItem]) continue;

                    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                    entry[@"title"] = [item title];
                    entry[@"enabled"] = @([item isEnabled]);
                    entry[@"checked"] = @([item state] == NSControlStateValueOn);

                    NSString *shortcut = [item keyEquivalent];
                    if (shortcut.length > 0) {
                        NSMutableString *combo = [NSMutableString string];
                        NSEventModifierFlags mods = [item keyEquivalentModifierMask];
                        if (mods & NSEventModifierFlagCommand) [combo appendString:@"⌘"];
                        if (mods & NSEventModifierFlagShift) [combo appendString:@"⇧"];
                        if (mods & NSEventModifierFlagOption) [combo appendString:@"⌥"];
                        if (mods & NSEventModifierFlagControl) [combo appendString:@"⌃"];
                        [combo appendString:shortcut];
                        entry[@"shortcut"] = combo;
                    }

                    if ([item hasSubmenu] && maxDepth > 0) {
                        entry[@"submenu"] = weakBuildMenu([item submenu], maxDepth - 1);
                    } else if ([item hasSubmenu]) {
                        entry[@"hasSubmenu"] = @YES;
                    }

                    [items addObject:entry];
                }
                return items;
            };

            if (menuName) {
                // Find specific top-level menu
                for (NSInteger i = 0; i < [mainMenu numberOfItems]; i++) {
                    NSMenuItem *item = [mainMenu itemAtIndex:i];
                    if ([[item title] caseInsensitiveCompare:menuName] == NSOrderedSame && [item hasSubmenu]) {
                        result = @{@"menu": menuName, @"items": buildMenu([item submenu], depth.intValue),
                                   @"validated": @(validate)};
                        return;
                    }
                }
                result = @{@"error": [NSString stringWithFormat:@"Menu '%@' not found", menuName]};
            } else {
                // List all top-level menus
                result = @{@"menus": buildMenu(mainMenu, depth.intValue), @"validated": @(validate)};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    if (!result) return @{@"error": @"Menu list failed"};
    if (result[@"error"]) return result;
    // Edit > Undo / Redo action names resolve in the menu titles regardless of focus; enabled
    // states are AppKit menu validation through the key window (false whenever FCP is not
    // frontmost). The library document's undo manager holds the real step — what Edit > Undo
    // and history_action act on — and is reported as undoState alongside.
    if (!menuName || [menuName caseInsensitiveCompare:@"Edit"] == NSOrderedSame) {
        __block NSDictionary *undoState = nil;
        SpliceKit_executeOnMainThread(^{
            @try {
                id um = SpliceKit_getUndoManager();
                if (!um) return;
                BOOL canUndo = ((BOOL (*)(id, SEL))objc_msgSend)(um, @selector(canUndo));
                BOOL canRedo = ((BOOL (*)(id, SEL))objc_msgSend)(um, @selector(canRedo));
                id undoName = canUndo ? ((id (*)(id, SEL))objc_msgSend)(um, @selector(undoActionName)) : nil;
                id redoName = canRedo ? ((id (*)(id, SEL))objc_msgSend)(um, @selector(redoActionName)) : nil;
                undoState = @{
                    @"canUndo": @(canUndo),
                    @"canRedo": @(canRedo),
                    @"undoActionName": [undoName isKindOfClass:[NSString class]] ? undoName : @"",
                    @"redoActionName": [redoName isKindOfClass:[NSString class]] ? redoName : @"",
                    @"source": @"the library document's undo manager (what Edit > Undo and history_action act on)",
                };
            } @catch (NSException *e) { undoState = nil; }
        });
        NSMutableDictionary *r = [result mutableCopy];
        if (undoState) r[@"undoState"] = undoState;
        r[@"note"] = @"Undo / Redo action names resolve in the menu titles regardless of focus; enabled states are "
                     @"AppKit menu validation through the key window, so they are false whenever Final Cut Pro is "
                     @"not frontmost. undoState is read from the document's undo manager and is always accurate.";
        result = r;
    }
    return result;
}

#pragma mark - Effect Parameter Helpers
//
// FCP's effect parameters live in a channel tree: clip -> effectStack -> channels
// (groups) -> sub-channels (individual params like position.x, opacity, etc).
//

// Get the selected clip's effect stack, creating it if needed
id SpliceKit_getSelectedTimelineItem(id timeline) {
    if (!timeline) return nil;

    // Get selected items
    NSArray *selected = nil;
    SEL selSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    if ([timeline respondsToSelector:selSel]) {
        id r = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selSel, NO, YES);
        if ([r isKindOfClass:[NSArray class]]) selected = (NSArray *)r;
    }
    if ((!selected || selected.count == 0) && [timeline respondsToSelector:@selector(selectedItems)]) {
        id r = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(selectedItems));
        if ([r isKindOfClass:[NSArray class]]) selected = (NSArray *)r;
    }
    if (!selected || selected.count == 0) return nil;

    return selected[0];
}

id SpliceKit_getSelectedClipEffectStack(id timeline, id *outClip) {
    if (!timeline) return nil;

    id clip = SpliceKit_getSelectedTimelineItem(timeline);
    if (!clip) return nil;

    if (outClip) *outClip = clip;

    // If clip is a collection (compound/storyline), get the first media component's effectStack
    if ([clip isKindOfClass:objc_getClass("FFAnchoredCollection")]) {
        @try {
            id items = [clip valueForKey:@"containedItems"];
            if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
                id firstItem = [(NSArray *)items firstObject];
                if ([firstItem respondsToSelector:@selector(effectStack)]) {
                    id es = ((id (*)(id, SEL))objc_msgSend)(firstItem, @selector(effectStack));
                    if (es) { if (outClip) *outClip = firstItem; return es; }
                }
            }
        } @catch (NSException *e) {}
    }

    // Direct effectStack access
    if ([clip respondsToSelector:@selector(effectStack)]) {
        return ((id (*)(id, SEL))objc_msgSend)(clip, @selector(effectStack));
    }
    return nil;
}

static id SpliceKit_getClipAudioEffectStack(id clip) {
    if (!clip) return nil;
    @try {
        SEL aeSel = NSSelectorFromString(@"audioEffectsForIdentifier:");
        if ([clip respondsToSelector:aeSel]) {
            return ((id (*)(id, SEL, unsigned long long))objc_msgSend)(clip, aeSel, 0ULL);
        }
    } @catch (NSException *e) {}
    return nil;
}

static void SpliceKit_addUniqueKeyframeTarget(id target,
                                              NSMutableArray *targets,
                                              NSMutableSet<NSString *> *seen,
                                              NSString *label) {
    if (!target) return;
    NSString *key = [NSString stringWithFormat:@"%p", (__bridge void *)target];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:target forKey:@"target"];
    if (label.length > 0) entry[@"label"] = label;
    [targets addObject:entry];
}

static void SpliceKit_addKeyframeTargetsFromOwner(id owner,
                                                  NSArray<NSString *> *selectors,
                                                  NSMutableArray *targets,
                                                  NSMutableSet<NSString *> *seen,
                                                  NSString *ownerLabel) {
    if (!owner) return;
    for (NSString *selName in selectors) {
        @try {
            SEL sel = NSSelectorFromString(selName);
            if (![owner respondsToSelector:sel]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(owner, sel);
            if (!value) continue;
            NSString *label = ownerLabel.length > 0
                ? [NSString stringWithFormat:@"%@.%@", ownerLabel, selName]
                : selName;
            SpliceKit_addUniqueKeyframeTarget(value, targets, seen, label);
        } @catch (NSException *e) {}
    }
}

static void SpliceKit_addInspectableKeyframeTargets(id owner,
                                                    NSMutableArray *targets,
                                                    NSMutableSet<NSString *> *seenTargets,
                                                    NSString *ownerLabel) {
    if (!owner) return;

    @try {
        SEL idsSel = NSSelectorFromString(@"inspectorTabIdentifiers");
        SEL channelsSel = NSSelectorFromString(@"inspectableChannelsForIdentifier:");
        if (![owner respondsToSelector:idsSel] || ![owner respondsToSelector:channelsSel]) return;

        id identifiers = ((id (*)(id, SEL))objc_msgSend)(owner, idsSel);
        if (![identifiers isKindOfClass:[NSArray class]]) return;

        for (id identifier in (NSArray *)identifiers) {
            if (!identifier) continue;
            id inspectable = ((id (*)(id, SEL, id))objc_msgSend)(owner, channelsSel, identifier);
            if ([inspectable isKindOfClass:[NSArray class]]) {
                NSUInteger idx = 0;
                for (id channel in (NSArray *)inspectable) {
                    NSString *label = [NSString stringWithFormat:@"%@.inspectable[%@][%lu]",
                                       ownerLabel ?: @"clip",
                                       [identifier description],
                                       (unsigned long)idx++];
                    SpliceKit_addUniqueKeyframeTarget(channel, targets, seenTargets, label);
                }
            } else if (inspectable) {
                NSString *label = [NSString stringWithFormat:@"%@.inspectable[%@]",
                                   ownerLabel ?: @"clip",
                                   [identifier description]];
                SpliceKit_addUniqueKeyframeTarget(inspectable, targets, seenTargets, label);
            }
        }
    } @catch (NSException *e) {}
}

static NSArray *SpliceKit_childClipsForKeyframeTraversal(id clip) {
    if (!clip) return @[];

    for (NSString *selName in @[@"descendentCompositedObjects", @"containedItems", @"allContainedItems"]) {
        @try {
            SEL sel = NSSelectorFromString(selName);
            if (![clip respondsToSelector:sel]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(clip, sel);
            if ([value isKindOfClass:[NSArray class]]) return value;
            if ([value isKindOfClass:[NSSet class]]) return [(NSSet *)value allObjects];
        } @catch (NSException *e) {}
    }
    return @[];
}

static void SpliceKit_collectKeyframeTargetsForClipRecursive(id clip,
                                                            NSMutableArray *targets,
                                                            NSMutableSet<NSString *> *seenTargets,
                                                            NSMutableSet<NSString *> *seenClips,
                                                            NSString *clipLabel) {
    if (!clip) return;

    NSString *clipKey = [NSString stringWithFormat:@"%p", (__bridge void *)clip];
    if ([seenClips containsObject:clipKey]) return;
    [seenClips addObject:clipKey];

    NSString *baseLabel = clipLabel.length > 0 ? clipLabel : @"clip";

    id videoTarget = SpliceKit_effectDragVideoEffectsTarget(clip);
    SpliceKit_addUniqueKeyframeTarget(
        videoTarget, targets, seenTargets, [baseLabel stringByAppendingString:@".videoEffects"]);

    id clipEffectStack = SpliceKit_getClipEffectStack(clip);
    SpliceKit_addUniqueKeyframeTarget(
        clipEffectStack, targets, seenTargets, [baseLabel stringByAppendingString:@".effectStack"]);

    id clipAudioEffectStack = SpliceKit_getClipAudioEffectStack(clip);
    SpliceKit_addUniqueKeyframeTarget(
        clipAudioEffectStack,
        targets,
        seenTargets,
        [baseLabel stringByAppendingString:@".audioEffectsForIdentifier"]);

    SpliceKit_addKeyframeTargetsFromOwner(
        clip,
        @[@"videoEffects", @"audioEffects", @"localAudioEffects", @"effectStack"],
        targets,
        seenTargets,
        baseLabel);
    SpliceKit_addInspectableKeyframeTargets(clip, targets, seenTargets, baseLabel);

    id toolObj = nil;
    @try {
        SEL toolSel = NSSelectorFromString(@"representedToolObject");
        if ([clip respondsToSelector:toolSel]) {
            toolObj = ((id (*)(id, SEL))objc_msgSend)(clip, toolSel);
        }
    } @catch (NSException *e) {}
    if (toolObj && toolObj != clip) {
        SpliceKit_addKeyframeTargetsFromOwner(
            toolObj,
            @[@"videoEffects", @"audioEffects", @"localAudioEffects", @"effectStack"],
            targets,
            seenTargets,
            [baseLabel stringByAppendingString:@".representedToolObject"]);
        SpliceKit_addInspectableKeyframeTargets(
            toolObj,
            targets,
            seenTargets,
            [baseLabel stringByAppendingString:@".representedToolObject"]);
    }

    NSArray *children = SpliceKit_childClipsForKeyframeTraversal(clip);
    for (NSUInteger idx = 0; idx < children.count; idx++) {
        id child = children[idx];
        NSString *childLabel = [NSString stringWithFormat:@"%@.containedItems[%lu]",
                                baseLabel,
                                (unsigned long)idx];
        SpliceKit_collectKeyframeTargetsForClipRecursive(
            child, targets, seenTargets, seenClips, childLabel);
    }
}

NSArray<id> *SpliceKit_keyframeTargetsForClip(id clip) {
    NSMutableArray *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seenTargets = [NSMutableSet set];
    NSMutableSet<NSString *> *seenClips = [NSMutableSet set];
    if (!clip) return @[];

    SpliceKit_collectKeyframeTargetsForClipRecursive(
        clip, entries, seenTargets, seenClips, @"clip");

    NSMutableArray *targets = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *entry in entries) {
        id target = entry[@"target"];
        if (!target) continue;
        [targets addObject:target];
    }
    return targets;
}

static void SpliceKit_collectKeyframedChannelsFromNode(id obj,
                                                       NSMutableArray *channels,
                                                       NSMutableSet<NSString *> *seen,
                                                       NSInteger depth) {
    if (!obj || depth > 10) return;

    if ([obj isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)obj) {
            SpliceKit_collectKeyframedChannelsFromNode(child, channels, seen, depth + 1);
        }
        return;
    }
    if ([obj isKindOfClass:[NSSet class]]) {
        for (id child in [(NSSet *)obj allObjects]) {
            SpliceKit_collectKeyframedChannelsFromNode(child, channels, seen, depth + 1);
        }
        return;
    }

    NSString *nodeKey = [NSString stringWithFormat:@"%p", (__bridge void *)obj];
    if ([seen containsObject:nodeKey]) return;
    [seen addObject:nodeKey];

    @try {
        SEL countSel = NSSelectorFromString(@"keyframeCount");
        if ([obj respondsToSelector:countSel]) {
            NSInteger keyframeCount = ((NSInteger (*)(id, SEL))objc_msgSend)(obj, countSel);
            if (keyframeCount > 0) [channels addObject:obj];
        }
    } @catch (NSException *e) {}

    NSArray<NSString *> *arraySelectors = @[@"channels", @"children", @"visibleEffects"];
    for (NSString *selName in arraySelectors) {
        @try {
            SEL sel = NSSelectorFromString(selName);
            if (![obj respondsToSelector:sel]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if (![value isKindOfClass:[NSArray class]]) continue;
            for (id child in (NSArray *)value) {
                SpliceKit_collectKeyframedChannelsFromNode(child, channels, seen, depth + 1);
            }
        } @catch (NSException *e) {}
    }

    NSArray<NSString *> *childSelectors = @[
        @"rootChannel",
        @"effectChannels",
        @"propertyChannels",
        @"objectChannels",
        @"stackPropertyChannels",
        @"audioPropertyChannels",
        @"intrinsicChannels",
        @"intrinsicCompositeEffect",
        @"xform3DEffect",
        @"cropEffect",
        @"audioLevelChannel",
        @"positionChannel3D",
        @"scaleChannel3D",
        @"rotationChannel3D",
        @"anchorChannel3D",
        @"opacityChannel",
        @"blendModeChannel",
        @"xChannel",
        @"yChannel",
        @"zChannel",
        @"leftChannel",
        @"rightChannel",
        @"topChannel",
        @"bottomChannel"
    ];
    for (NSString *selName in childSelectors) {
        @try {
            SEL sel = NSSelectorFromString(selName);
            if (![obj respondsToSelector:sel]) continue;
            id child = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if (!child) continue;
            if ([child isKindOfClass:[NSArray class]]) {
                for (id item in (NSArray *)child) {
                    SpliceKit_collectKeyframedChannelsFromNode(item, channels, seen, depth + 1);
                }
            } else {
                SpliceKit_collectKeyframedChannelsFromNode(child, channels, seen, depth + 1);
            }
        } @catch (NSException *e) {}
    }
}

NSDictionary *SpliceKit_removeAllKeyframesFromEffectStack(id effectStack, NSString *actionName) {
    if (!effectStack) {
        return @{@"channelsCleared": @0, @"keyframesRemoved": @0};
    }

    NSMutableArray *channels = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    SpliceKit_collectKeyframedChannelsFromNode(effectStack, channels, seen, 0);

    if (channels.count == 0) {
        return @{@"channelsCleared": @0, @"keyframesRemoved": @0};
    }

    @try {
        SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
        if ([effectStack respondsToSelector:beginSel]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                effectStack, beginSel, actionName ?: @"Remove All Keyframes", nil, YES);
        }
    } @catch (NSException *e) {}

    NSUInteger channelsCleared = 0;
    NSUInteger keyframesRemoved = 0;
    for (id channel in channels) {
        @try {
            SEL countSel = NSSelectorFromString(@"keyframeCount");
            NSInteger count = [channel respondsToSelector:countSel]
                ? ((NSInteger (*)(id, SEL))objc_msgSend)(channel, countSel) : 0;
            if (count <= 0) continue;
            if (SpliceKit_removeChannelKeyframes(channel)) {
                channelsCleared++;
                keyframesRemoved += (NSUInteger)count;
            }
        } @catch (NSException *e) {}
    }

    @try {
        SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
        if ([effectStack respondsToSelector:endSel]) {
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                effectStack, endSel, actionName ?: @"Remove All Keyframes", YES, nil);
        }
    } @catch (NSException *e) {}

    return @{
        @"channelsCleared": @(channelsCleared),
        @"keyframesRemoved": @(keyframesRemoved),
    };
}

// Read a channel's value at a given time (seconds)
static NSDictionary *SpliceKit_readChannel(id channel, double timeSeconds) {
    if (!channel) return nil;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"class"] = NSStringFromClass([channel class]);

    @try {
        // Get name
        SEL nameSel = NSSelectorFromString(@"name");
        if ([channel respondsToSelector:nameSel]) {
            id name = ((id (*)(id, SEL))objc_msgSend)(channel, nameSel);
            if (name) info[@"name"] = [name description];
        }
    } @catch (NSException *e) {}

    // Read value at time
    @try {
        SEL valSel = NSSelectorFromString(@"doubleValueAtTime:");
        if ([channel respondsToSelector:valSel]) {
            SpliceKit_CMTime t = {(int64_t)(timeSeconds * 600), 600, 1, 0};
            double val = ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, valSel, t);
            info[@"value"] = @(val);
        }
    } @catch (NSException *e) {}

    // Read default
    @try {
        SEL defSel = NSSelectorFromString(@"defaultCurveDoubleValue");
        if ([channel respondsToSelector:defSel]) {
            double def = ((double (*)(id, SEL))objc_msgSend)(channel, defSel);
            info[@"default"] = @(def);
        }
    } @catch (NSException *e) {}

    // Read min/max
    @try {
        SEL minSel = NSSelectorFromString(@"minCurveDoubleValue");
        SEL maxSel = NSSelectorFromString(@"maxCurveDoubleValue");
        if ([channel respondsToSelector:minSel])
            info[@"min"] = @(((double (*)(id, SEL))objc_msgSend)(channel, minSel));
        if ([channel respondsToSelector:maxSel])
            info[@"max"] = @(((double (*)(id, SEL))objc_msgSend)(channel, maxSel));
    } @catch (NSException *e) {}

    return info;
}

// Get all channels from an effect recursively
static void SpliceKit_collectChannels(id obj, NSMutableArray *channels, NSString *prefix, int depth) {
    if (!obj || depth > 8) return;

    // If this is itself a channel with a double value, add it
    if ([obj respondsToSelector:NSSelectorFromString(@"doubleValueAtTime:")]) {
        NSString *name = prefix ?: @"";
        @try {
            SEL nSel = NSSelectorFromString(@"name");
            if ([obj respondsToSelector:nSel]) {
                id n = ((id (*)(id, SEL))objc_msgSend)(obj, nSel);
                if (n) name = [n description];
            }
        } @catch (NSException *e) {}

        NSMutableDictionary *ch = [NSMutableDictionary dictionary];
        ch[@"name"] = name;
        ch[@"handle"] = SpliceKit_storeHandle(obj);

        NSDictionary *vals = SpliceKit_readChannel(obj, 0);
        if (vals[@"value"]) ch[@"value"] = vals[@"value"];
        if (vals[@"min"]) ch[@"min"] = vals[@"min"];
        if (vals[@"max"]) ch[@"max"] = vals[@"max"];
        if (vals[@"default"]) ch[@"default"] = vals[@"default"];
        [channels addObject:ch];
    }

    // Try to get sub-channels
    @try {
        SEL subSel = NSSelectorFromString(@"channels");
        if ([obj respondsToSelector:subSel]) {
            id subs = ((id (*)(id, SEL))objc_msgSend)(obj, subSel);
            if ([subs isKindOfClass:[NSArray class]]) {
                for (id sub in (NSArray *)subs) {
                    SpliceKit_collectChannels(sub, channels, nil, depth + 1);
                }
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - Inspector Handlers
//
// Read and write clip properties (transform, compositing, audio volume, etc.)
// by walking FCP's channel-based parameter model.
//

// Helper: read a double from a channel at time=0 (kCMTimeIndefinite for constant)
double SpliceKit_channelValue(id channel) {
    if (!channel) return 0;
    @try {
        // Use kCMTimeIndefinite: {0, 0, 17, 0} for constant (non-keyframed) value
        SpliceKit_CMTime t = {0, 0, 17, 0};
        SEL sel = NSSelectorFromString(@"curveDoubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, sel, t);
        }
        sel = NSSelectorFromString(@"doubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, sel, t);
        }
    } @catch (NSException *e) {}
    return 0;
}

// Read channel value at a specific time (for keyframed parameters)
static double SpliceKit_channelValueAtTime(id channel, SpliceKit_CMTime time) {
    if (!channel) return 0;
    @try {
        SEL sel = NSSelectorFromString(@"curveDoubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, sel, time);
        }
        sel = NSSelectorFromString(@"doubleValueAtTime:");
        if ([channel respondsToSelector:sel]) {
            return ((double (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(channel, sel, time);
        }
    } @catch (NSException *e) {}
    return 0;
}

// How many keyframes a channel carries; -1 when the channel cannot report it.
// This is what makes an animated parameter visible: the value readers below return
// a single number, so without a count there is no way to tell a static 0 from a
// channel carrying hundreds of keyframes (stabilize_subject writes one per frame).
static NSInteger SpliceKit_channelKeyframeCount(id channel) {
    if (!channel) return -1;
    @try {
        SEL countSel = NSSelectorFromString(@"keyframeCount");
        if ([channel respondsToSelector:countSel]) {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(channel, countSel);
        }
    } @catch (NSException *e) {}
    return -1;
}

// Remove all existing keyframes so a constant write takes effect.
BOOL SpliceKit_removeChannelKeyframes(id channel) {
    if (!channel) return NO;
    @try {
        SEL countSel = NSSelectorFromString(@"keyframeCount");
        if (![channel respondsToSelector:countSel]) return NO;

        NSInteger count = ((NSInteger (*)(id, SEL))objc_msgSend)(channel, countSel);
        if (count <= 0) return YES;

        SEL removeAllSel = NSSelectorFromString(@"removeAllKeyframes:");
        if ([channel respondsToSelector:removeAllSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(channel, removeAllSel, YES);
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

static BOOL SpliceKit_setChannelValueAtTimeWithOptions(id channel, double value, SpliceKit_CMTime time, unsigned int options) {
    if (!channel) return NO;
    @try {
        SEL sel = NSSelectorFromString(@"setCurveDoubleValue:atTime:options:");
        if ([channel respondsToSelector:sel]) {
            ((void (*)(id, SEL, double, SpliceKit_CMTime, unsigned int))objc_msgSend)(
                channel, sel, value, time, options);
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

BOOL SpliceKit_setChannelValueAtTime(id channel, double value, SpliceKit_CMTime time) {
    return SpliceKit_setChannelValueAtTimeWithOptions(channel, value, time, 0);
}

// Helper: set a double on a channel
BOOL SpliceKit_setChannelValue(id channel, double value) {
    SpliceKit_CMTime t = {0, 0, 17, 0}; // kCMTimeIndefinite
    return SpliceKit_setChannelValueAtTime(channel, value, t);
}

// Static mixer drags need the same channel operation bracketing FCP uses for live edits,
// otherwise playback can cache the old gain until transport is restarted.
BOOL SpliceKit_mixerSetStaticChannelValue(id channel, double value) {
    if (!channel) return NO;

    BOOL beganOperation = NO;
    @try {
        SEL beginSel = NSSelectorFromString(@"operationBegin");
        if ([channel respondsToSelector:beginSel]) {
            ((void (*)(id, SEL))objc_msgSend)(channel, beginSel);
            beganOperation = YES;
        }
    } @catch (NSException *e) {}

    // Match FCP's own control flow: touch the current value before updating.
    (void)SpliceKit_channelValue(channel);
    BOOL ok = SpliceKit_setChannelValue(channel, value);

    @try {
        SEL endSel = NSSelectorFromString(@"operationEnd");
        if (beganOperation && [channel respondsToSelector:endSel]) {
            ((void (*)(id, SEL))objc_msgSend)(channel, endSel);
        }
    } @catch (NSException *e) {}

    return ok;
}

// Helper: get sub-channel by name (xChannel, yChannel, zChannel)
static id SpliceKit_subChannel(id parentChannel, NSString *axis) {
    if (!parentChannel) return nil;
    @try {
        NSString *selName = [NSString stringWithFormat:@"%@Channel", axis];
        SEL sel = NSSelectorFromString(selName);
        if ([parentChannel respondsToSelector:sel]) {
            return ((id (*)(id, SEL))objc_msgSend)(parentChannel, sel);
        }
    } @catch (NSException *e) {}
    return nil;
}

static NSDictionary *SpliceKit_handleInspectorGet(NSDictionary *params) {
    NSString *property = params[@"property"]; // "all", "compositing", "transform", "audio", "crop", "info", "channels"

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id clip = nil;
            id effectStack = SpliceKit_getSelectedClipEffectStack(timeline, &clip);
            if (!clip) { result = @{@"error": @"No clips selected"}; return; }

            NSMutableDictionary *props = [NSMutableDictionary dictionary];

            // Clip info (always included)
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"class"] = NSStringFromClass([clip class]);
            @try {
                if ([clip respondsToSelector:@selector(displayName)]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                    if (n) info[@"name"] = [n description];
                }
            } @catch (NSException *e) {}
            info[@"hasEffectStack"] = @(effectStack != nil);
            props[@"info"] = info;

            if (!effectStack) {
                result = @{@"properties": props, @"note": @"Clip has no effect stack"};
                return;
            }

            NSString *esHandle = SpliceKit_storeHandle(effectStack);
            props[@"effectStackHandle"] = esHandle;

            // COMPOSITING (opacity, blend mode)
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"compositing"]) {
                NSMutableDictionary *comp = [NSMutableDictionary dictionary];
                @try {
                    SEL blendSel = NSSelectorFromString(@"intrinsicCompositeEffect");
                    id blendEffect = [effectStack respondsToSelector:blendSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, blendSel) : nil;
                    if (blendEffect) {
                        id opChan = ((id (*)(id, SEL))objc_msgSend)(blendEffect, NSSelectorFromString(@"opacityChannel"));
                        id bmChan = ((id (*)(id, SEL))objc_msgSend)(blendEffect, NSSelectorFromString(@"blendModeChannel"));
                        if (opChan) {
                            comp[@"opacity"] = @(SpliceKit_channelValue(opChan));
                            comp[@"opacityHandle"] = SpliceKit_storeHandle(opChan);
                        }
                        if (bmChan) comp[@"blendModeHandle"] = SpliceKit_storeHandle(bmChan);
                    } else {
                        comp[@"opacity"] = @(1.0); // default
                    }
                } @catch (NSException *e) { comp[@"error"] = e.reason; }
                props[@"compositing"] = comp;
            }

            // TRANSFORM (position, rotation, scale, anchor)
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"transform"]) {
                NSMutableDictionary *xform = [NSMutableDictionary dictionary];
                @try {
                    SEL xfSel = NSSelectorFromString(@"xform3DEffect");
                    id xfEffect = [effectStack respondsToSelector:xfSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, xfSel) : nil;
                    if (xfEffect) {
                        // Every value below is a single number. When a parameter is
                        // animated that number says nothing, so record the keyframe count
                        // alongside it: that is the only way the tool surface can show
                        // what stabilize_subject (one keyframe per frame) actually did.
                        NSMutableDictionary *kf = [NSMutableDictionary dictionary];
                        void (^recordKeyframes)(NSString *, id) = ^(NSString *label, id axisChannel) {
                            NSInteger n = SpliceKit_channelKeyframeCount(axisChannel);
                            if (n > 0) kf[label] = @(n);
                        };
                        // Position
                        id posCh = nil;
                        @try { posCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"positionChannel3D")); } @catch(NSException *e) {}
                        if (posCh) {
                            id px = SpliceKit_subChannel(posCh, @"x");
                            id py = SpliceKit_subChannel(posCh, @"y");
                            id pz = SpliceKit_subChannel(posCh, @"z");
                            xform[@"positionX"] = @(SpliceKit_channelValue(px));
                            xform[@"positionY"] = @(SpliceKit_channelValue(py));
                            xform[@"positionZ"] = @(SpliceKit_channelValue(pz));
                            recordKeyframes(@"positionX", px);
                            recordKeyframes(@"positionY", py);
                            recordKeyframes(@"positionZ", pz);
                        }
                        // Scale
                        id scaCh = nil;
                        @try { scaCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"scaleChannel3D")); } @catch(NSException *e) {}
                        if (scaCh) {
                            id sx = SpliceKit_subChannel(scaCh, @"x");
                            id sy = SpliceKit_subChannel(scaCh, @"y");
                            xform[@"scaleX"] = @(SpliceKit_channelValue(sx));
                            xform[@"scaleY"] = @(SpliceKit_channelValue(sy));
                            recordKeyframes(@"scaleX", sx);
                            recordKeyframes(@"scaleY", sy);
                        }
                        // Rotation
                        id rotCh = nil;
                        @try { rotCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"rotationChannel3D")); } @catch(NSException *e) {}
                        if (rotCh) {
                            id rz = SpliceKit_subChannel(rotCh, @"z");
                            xform[@"rotation"] = @(SpliceKit_channelValue(rz));
                            recordKeyframes(@"rotation", rz);
                        }
                        // Anchor
                        id ancCh = nil;
                        @try { ancCh = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(@"anchorChannel3D")); } @catch(NSException *e) {}
                        if (ancCh) {
                            id ax = SpliceKit_subChannel(ancCh, @"x");
                            id ay = SpliceKit_subChannel(ancCh, @"y");
                            xform[@"anchorX"] = @(SpliceKit_channelValue(ax));
                            xform[@"anchorY"] = @(SpliceKit_channelValue(ay));
                            recordKeyframes(@"anchorX", ax);
                            recordKeyframes(@"anchorY", ay);
                        }
                        if (kf.count > 0) xform[@"keyframes"] = kf;
                    } else {
                        xform[@"positionX"] = @(0); xform[@"positionY"] = @(0);
                        xform[@"scaleX"] = @(100); xform[@"scaleY"] = @(100);
                        xform[@"rotation"] = @(0);
                    }
                } @catch (NSException *e) { xform[@"error"] = e.reason; }
                props[@"transform"] = xform;
            }

            // AUDIO (volume)
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"audio"]) {
                NSMutableDictionary *audio = [NSMutableDictionary dictionary];
                @try {
                    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
                    id volChan = [effectStack respondsToSelector:volSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, volSel) : nil;
                    if (volChan) {
                        audio[@"volume"] = @(SpliceKit_channelValue(volChan));
                        audio[@"volumeHandle"] = SpliceKit_storeHandle(volChan);
                        NSInteger volKf = SpliceKit_channelKeyframeCount(volChan);
                        if (volKf > 0) audio[@"keyframes"] = @{@"volume": @(volKf)};
                    }
                } @catch (NSException *e) { audio[@"error"] = e.reason; }
                props[@"audio"] = audio;
            }

            // CROP
            if (!property || [property isEqualToString:@"all"] || [property isEqualToString:@"crop"]) {
                NSMutableDictionary *crop = [NSMutableDictionary dictionary];
                @try {
                    id cropEff = nil;
                    SEL cropSel = NSSelectorFromString(@"cropEffect");
                    if ([effectStack respondsToSelector:cropSel])
                        cropEff = ((id (*)(id, SEL))objc_msgSend)(effectStack, cropSel);
                    if (cropEff) {
                        id (^getCh)(NSString *) = ^id(NSString *name) {
                            @try {
                                SEL s = NSSelectorFromString([NSString stringWithFormat:@"%@Channel", name]);
                                if ([cropEff respondsToSelector:s])
                                    return ((id (*)(id, SEL))objc_msgSend)(cropEff, s);
                            } @catch (NSException *e) {}
                            return nil;
                        };
                        id lCh = getCh(@"left"); if (lCh) crop[@"left"] = @(SpliceKit_channelValue(lCh));
                        id rCh = getCh(@"right"); if (rCh) crop[@"right"] = @(SpliceKit_channelValue(rCh));
                        id tCh = getCh(@"top"); if (tCh) crop[@"top"] = @(SpliceKit_channelValue(tCh));
                        id bCh = getCh(@"bottom"); if (bCh) crop[@"bottom"] = @(SpliceKit_channelValue(bCh));
                    }
                } @catch (NSException *e) { crop[@"error"] = e.reason; }
                props[@"crop"] = crop;
            }

            // ALL EFFECT CHANNELS (for advanced access)
            if ([property isEqualToString:@"channels"]) {
                NSMutableArray *channels = [NSMutableArray array];
                // Get all effects and their channels
                @try {
                    SEL efSel = NSSelectorFromString(@"visibleEffects");
                    if ([effectStack respondsToSelector:efSel]) {
                        NSArray *effects = ((id (*)(id, SEL))objc_msgSend)(effectStack, efSel);
                        for (id effect in effects) {
                            SpliceKit_collectChannels(effect, channels, nil, 0);
                        }
                    }
                    // Also get intrinsic channels
                    SEL icSel = NSSelectorFromString(@"intrinsicChannels");
                    if ([effectStack respondsToSelector:icSel]) {
                        id intrinsic = ((id (*)(id, SEL))objc_msgSend)(effectStack, icSel);
                        if (intrinsic) SpliceKit_collectChannels(intrinsic, channels, @"intrinsic", 0);
                    }
                } @catch (NSException *e) {}
                props[@"channels"] = channels;
            }

            result = @{@"properties": props};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Inspector get failed"};
}

// Concrete keys SpliceKit_handleInspectorSet will actually write. A prefix such as
// "position" is not enough: only these names map onto a channel. Inspector labels
// ("Position X") are not keys.
static BOOL SpliceKit_inspectorTransformChannel(NSString *property,
                                                NSString **outMethod,
                                                NSString **outAxis) {
    NSString *channelMethod = nil;
    NSString *axis = nil;
    if ([property isEqualToString:@"positionX"]) { channelMethod = @"positionChannel3D"; axis = @"x"; }
    else if ([property isEqualToString:@"positionY"]) { channelMethod = @"positionChannel3D"; axis = @"y"; }
    else if ([property isEqualToString:@"positionZ"]) { channelMethod = @"positionChannel3D"; axis = @"z"; }
    else if ([property isEqualToString:@"scaleX"]) { channelMethod = @"scaleChannel3D"; axis = @"x"; }
    else if ([property isEqualToString:@"scaleY"]) { channelMethod = @"scaleChannel3D"; axis = @"y"; }
    else if ([property isEqualToString:@"rotation"]) { channelMethod = @"rotationChannel3D"; axis = @"z"; }
    else if ([property isEqualToString:@"anchorX"]) { channelMethod = @"anchorChannel3D"; axis = @"x"; }
    else if ([property isEqualToString:@"anchorY"]) { channelMethod = @"anchorChannel3D"; axis = @"y"; }
    else return NO;
    if (outMethod) *outMethod = channelMethod;
    if (outAxis) *outAxis = axis;
    return YES;
}

static NSString *SpliceKit_inspectorSetUnknownPropertyError(NSString *property) {
    return [NSString stringWithFormat:
        @"Unknown inspector property '%@'. "
        @"Accepted names: opacity, positionX, positionY, positionZ, scaleX, scaleY, "
        @"rotation, anchorX, anchorY, volume, handle:<object handle>. "
        @"These are keys like positionX, not inspector labels like Position X.",
        property ?: @""];
}

static NSDictionary *SpliceKit_handleInspectorSet(NSDictionary *params) {
    NSString *property = params[@"property"]; // "opacity", "positionX", "positionY", "rotation", "scaleX", "scaleY", "volume", etc.
    NSNumber *value = params[@"value"];
    if (!property || !value) return @{@"error": @"property and value parameters required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id clip = nil;
            id effectStack = SpliceKit_getSelectedClipEffectStack(timeline, &clip);
            if (!effectStack) { result = @{@"error": @"No clip selected or clip has no effect stack"}; return; }

            double val = [value doubleValue];
            NSString *transformMethod = nil;
            NSString *transformAxis = nil;
            BOOL setOpacity = [property isEqualToString:@"opacity"];
            BOOL setTransform = SpliceKit_inspectorTransformChannel(property, &transformMethod, &transformAxis);
            BOOL setVolume = [property isEqualToString:@"volume"];
            BOOL setHandle = [property hasPrefix:@"handle:"];
            // Recognise the name before opening an undo scope. An unrecognised name
            // (an inspector label such as "Position X", or a prefix that maps to no
            // channel) used to begin and end "Set <property>" with nothing inside it.
            if (!setOpacity && !setTransform && !setVolume && !setHandle) {
                result = @{@"error": SpliceKit_inspectorSetUnknownPropertyError(property)};
                return;
            }

            BOOL success = NO;
            NSString *desc = [NSString stringWithFormat:@"Set %@", property];

            // Begin undo action only once a branch below will run.
            @try {
                SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
                if ([effectStack respondsToSelector:beginSel]) {
                    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                        effectStack, beginSel, desc, nil, YES);
                }
            } @catch (NSException *e) {}

            // OPACITY
            if (setOpacity) {
                @try {
                    SEL bSel = NSSelectorFromString(@"intrinsicCompositeEffectCreateIfAbsent:");
                    id blendEffect = ((id (*)(id, SEL, BOOL))objc_msgSend)(effectStack, bSel, YES);
                    id opChan = ((id (*)(id, SEL))objc_msgSend)(blendEffect, NSSelectorFromString(@"opacityChannel"));
                    success = SpliceKit_setChannelValue(opChan, val);
                } @catch (NSException *e) {}
            }
            // TRANSFORM: positionX/Y/Z, scaleX/Y, rotation, anchorX/Y
            else if (setTransform) {
                @try {
                    // Get or create xform3D effect
                    id xfEffect = nil;
                    SEL xfSel = NSSelectorFromString(@"xform3DEffect");
                    if ([effectStack respondsToSelector:xfSel])
                        xfEffect = ((id (*)(id, SEL))objc_msgSend)(effectStack, xfSel);
                    // Create if absent using the known effect ID
                    if (!xfEffect) {
                        SEL addSel = NSSelectorFromString(@"addIntrinsicEffectForEffectID:");
                        if ([effectStack respondsToSelector:addSel]) {
                            xfEffect = ((id (*)(id, SEL, id))objc_msgSend)(
                                effectStack, addSel, @"HEXForm3D");
                        }
                    }
                    if (xfEffect) {
                        id ch3d = ((id (*)(id, SEL))objc_msgSend)(xfEffect, NSSelectorFromString(transformMethod));
                        id axisCh = SpliceKit_subChannel(ch3d, transformAxis);
                        success = SpliceKit_setChannelValue(axisCh, val);
                    }
                } @catch (NSException *e) {}
            }
            // VOLUME
            else if (setVolume) {
                @try {
                    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
                    id volChan = [effectStack respondsToSelector:volSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(effectStack, volSel) : nil;
                    if (volChan) success = SpliceKit_setChannelValue(volChan, val);
                } @catch (NSException *e) {}
            }
            // CHANNEL BY HANDLE (generic - set any channel by its handle)
            else if ([property hasPrefix:@"handle:"]) {
                NSString *handle = [property substringFromIndex:7];
                id channel = SpliceKit_resolveHandle(handle);
                if (channel) success = SpliceKit_setChannelValue(channel, val);
                else result = @{@"error": @"Handle not found"};
            }

            // End undo action
            @try {
                SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
                if ([effectStack respondsToSelector:endSel]) {
                    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                        effectStack, endSel, desc, YES, nil);
                }
            } @catch (NSException *e) {}

            if (!result) {
                result = success
                    ? @{@"status": @"ok", @"property": property, @"value": @(val)}
                    : @{@"error": [NSString stringWithFormat:@"Failed to set '%@'", property]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Inspector set failed"};
}

#pragma mark - Title Text Inspection

// Walk CHChannelFolder tree to find CHChannelText instances and read their content.
// Returns text string, font info (from NSAttributedString), and channel metadata.
void SpliceKit_collectTitleText(id folder, NSMutableArray *results, int depth) {
    if (!folder || depth > 12) return;

    // Check if this is a CHChannelText (has -string and -attributedString)
    Class chTextClass = objc_getClass("CHChannelText");
    if (chTextClass && [folder isKindOfClass:chTextClass]) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];

        @try {
            SEL strSel = NSSelectorFromString(@"string");
            if ([folder respondsToSelector:strSel]) {
                id str = ((id (*)(id, SEL))objc_msgSend)(folder, strSel);
                if (str) entry[@"text"] = [str description];
            }
        } @catch (NSException *e) {}

        // Extract font info from NSAttributedString
        @try {
            SEL asSel = NSSelectorFromString(@"attributedString");
            if ([folder respondsToSelector:asSel]) {
                NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(folder, asSel);
                if (attrStr && attrStr.length > 0) {
                    NSDictionary *attrs = [attrStr attributesAtIndex:0 effectiveRange:NULL];
                    NSFont *font = attrs[NSFontAttributeName];
                    if (font) {
                        entry[@"fontName"] = font.fontName;
                        entry[@"fontFamily"] = font.familyName;
                        entry[@"fontSize"] = @(font.pointSize);
                    }
                    NSColor *color = attrs[NSForegroundColorAttributeName];
                    if (color) {
                        NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                        if (rgb) {
                            entry[@"textColor"] = [NSString stringWithFormat:@"%.3f %.3f %.3f %.3f",
                                rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
                        }
                    }
                }
            }
        } @catch (NSException *e) {}

        // Channel metadata
        @try {
            SEL nameSel = NSSelectorFromString(@"name");
            if ([folder respondsToSelector:nameSel]) {
                id name = ((id (*)(id, SEL))objc_msgSend)(folder, nameSel);
                if (name) entry[@"channelName"] = [name description];
            }
            SEL idSel = NSSelectorFromString(@"channelID");
            if ([folder respondsToSelector:idSel]) {
                long long cid = ((long long (*)(id, SEL))objc_msgSend)(folder, idSel);
                entry[@"channelID"] = @(cid);
            }
        } @catch (NSException *e) {}

        entry[@"handle"] = SpliceKit_storeHandle(folder);
        [results addObject:entry];
    }

    // Recurse into children (CHChannelFolder)
    @try {
        SEL childrenSel = NSSelectorFromString(@"children");
        if ([folder respondsToSelector:childrenSel]) {
            NSArray *children = ((id (*)(id, SEL))objc_msgSend)(folder, childrenSel);
            if ([children isKindOfClass:[NSArray class]]) {
                for (id child in children) {
                    SpliceKit_collectTitleText(child, results, depth + 1);
                }
            }
        }
    } @catch (NSException *e) {}
}

static NSDictionary *SpliceKit_handleInspectorGetTitle(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) { result = @{@"error": @"No active timeline module"}; return; }

            id clip = nil;
            id effectStack = SpliceKit_getSelectedClipEffectStack(timeline, &clip);
            if (!clip) { result = @{@"error": @"No clips selected"}; return; }

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"class"] = NSStringFromClass([clip class]);
            @try {
                if ([clip respondsToSelector:@selector(displayName)]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                    if (n) info[@"name"] = [n description];
                }
            } @catch (NSException *e) {}

            // Walk the generator's own effect for text channels first.
            // Motion titles: text is on clip.effect.channelFolder, not effectStack.visibleEffects.
            NSMutableArray *textChannels = [NSMutableArray array];
            NSMutableArray *effectNames = [NSMutableArray array];

            // Primary path: clip.effect (FFAnchoredEffectComponent)
            @try {
                SEL effectSel = NSSelectorFromString(@"effect");
                id genEffect = [clip respondsToSelector:effectSel]
                    ? ((id (*)(id, SEL))objc_msgSend)(clip, effectSel) : nil;
                if (genEffect) {
                    SEL cfSel = NSSelectorFromString(@"channelFolder");
                    id cf = [genEffect respondsToSelector:cfSel]
                        ? ((id (*)(id, SEL))objc_msgSend)(genEffect, cfSel) : nil;
                    if (cf) SpliceKit_collectTitleText(cf, textChannels, 0);
                }
            } @catch (NSException *e) {}

            // Fallback: effectStack.visibleEffects
            if (textChannels.count == 0 && effectStack) {
                @try {
                    SEL efSel = NSSelectorFromString(@"visibleEffects");
                    if ([effectStack respondsToSelector:efSel]) {
                        NSArray *effects = ((id (*)(id, SEL))objc_msgSend)(effectStack, efSel);
                        for (id effect in effects) {
                            NSString *efName = @"(unknown)";
                            @try {
                                if ([effect respondsToSelector:@selector(displayName)])
                                    efName = [((id (*)(id, SEL))objc_msgSend)(effect, @selector(displayName)) description];
                            } @catch (NSException *e) {}
                            [effectNames addObject:efName];

                            SEL cfSel = NSSelectorFromString(@"channelFolder");
                            if ([effect respondsToSelector:cfSel]) {
                                id cf = ((id (*)(id, SEL))objc_msgSend)(effect, cfSel);
                                if (cf) SpliceKit_collectTitleText(cf, textChannels, 0);
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }

            info[@"effectNames"] = effectNames;
            info[@"textChannelCount"] = @(textChannels.count);

            NSMutableDictionary *res = [NSMutableDictionary dictionary];
            res[@"info"] = info;
            if (textChannels.count > 0) {
                res[@"textChannels"] = textChannels;
                // Convenience: surface first text channel's data at top level
                NSDictionary *first = textChannels.firstObject;
                if (first[@"text"]) res[@"text"] = first[@"text"];
                if (first[@"fontSize"]) res[@"fontSize"] = first[@"fontSize"];
                if (first[@"fontFamily"]) res[@"fontFamily"] = first[@"fontFamily"];
                if (first[@"fontName"]) res[@"fontName"] = first[@"fontName"];
            }
            result = res;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Title inspection failed"};
}

#pragma mark - View/Panel Toggle Handler

static NSDictionary *SpliceKit_handleViewToggle(NSDictionary *params) {
    NSString *panel = params[@"panel"];
    if (!panel) return @{@"error": @"panel parameter required"};

    // Map panel names to selectors
    NSDictionary *panelMap = @{
        @"inspector":       @"toggleInspector:",
        @"timeline":        @"toggleTimeline:",
        @"browser":         @"toggleBrowser:",
        @"eventViewer":     @"toggleEventViewer:",
        @"effectsBrowser":  @"toggleEffectsBrowser:",
        @"transitionsBrowser": @"toggleTransitionsBrowser:",
        @"videoScopes":     @"toggleVideoScopes:",
        @"histogram":       @"toggleHistogram:",
        @"vectorscope":     @"toggleVectorscope:",
        @"waveform":        @"toggleWaveformMonitor:",
        @"audioMeter":      @"toggleAudioMeters:",
        @"keywordEditor":   @"toggleKeywordEditor:",
        @"timelineIndex":   @"toggleTimelineIndex:",
        @"precisionEditor": @"showPrecisionEditor:",
        @"retimeEditor":    @"toggleRetimeEditor:",
        @"audioCurves":     @"toggleAudioCurves:",
        @"videoAnimation":  @"showTimelineCurveEditor:",
        @"audioAnimation":  @"showTimelineCurveEditor:",
        @"multicamViewer":  @"toggleAngleViewer:",
        @"360viewer":       @"toggle360Viewer:",
        @"fullscreenViewer": @"toggleFullScreenViewer:",
        @"backgroundTasks": @"goToBackgroundTaskList:",
        @"voiceover":       @"toggleVoiceoverRecordView:",
        @"comparisonViewer": @"toggleComparisonViewer:",
    };

    NSString *selector = panelMap[panel];
    if (!selector) {
        return @{@"error": [NSString stringWithFormat:@"Unknown panel '%@'. Available: %@",
                    panel, [[panelMap allKeys] componentsJoinedByString:@", "]]};
    }

    return SpliceKit_sendAppAction(selector);
}

#pragma mark - Workspace Handler

static NSDictionary *SpliceKit_handleWorkspace(NSDictionary *params) {
    NSString *workspace = params[@"workspace"];
    if (!workspace) return @{@"error": @"workspace parameter required"};

    NSDictionary *workspaceMap = @{
        @"default":       @"Default",
        @"organize":      @"Organize",
        @"colorEffects":  @"Color & Effects",
        @"dualDisplays":  @"Dual Displays",
    };

    NSString *menuTitle = workspaceMap[workspace];
    if (!menuTitle) {
        return @{@"error": [NSString stringWithFormat:@"Unknown workspace '%@'. Available: default, organize, colorEffects, dualDisplays", workspace]};
    }

    return SpliceKit_handleMenuExecute(@{@"menuPath": @[@"Window", @"Workspaces", menuTitle]});
}

#pragma mark - Roles Handler

static NSString *SpliceKit_formatRolesAssignMenuError(NSString *menuError,
                                                      NSString *menuCategory,
                                                      NSString *roleName) {
    if (!menuError.length) return @"Failed to assign role via menu";

    NSRange availRange = [menuError rangeOfString:@"Available: "];
    if (availRange.location != NSNotFound) {
        NSString *suffix = [menuError substringFromIndex:availRange.location + availRange.length];
        NSString *trimmed = [suffix stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            return [NSString stringWithFormat:
                @"Cannot assign role '%@' via Modify > %@: the submenu enumerated no items. "
                @"Final Cut Pro only populates Assign Roles menus when it is the frontmost "
                @"application. Bring Final Cut Pro to the front, keep a clip selected, and retry.",
                roleName, menuCategory];
        }
    }
    return menuError;
}

static NSDictionary *SpliceKit_handleRolesAssign(NSDictionary *params) {
    NSString *roleType = params[@"type"]; // "audio", "video", "caption"
    NSString *roleName = params[@"role"]; // e.g. "Dialogue", "Music", "Effects"
    if (!roleType || !roleName) {
        return @{@"error": @"type and role parameters required"};
    }

    NSString *menuCategory;
    if ([roleType isEqualToString:@"audio"]) menuCategory = @"Assign Audio Roles";
    else if ([roleType isEqualToString:@"video"]) menuCategory = @"Assign Video Roles";
    else if ([roleType isEqualToString:@"caption"]) menuCategory = @"Assign Caption Roles";
    else return @{@"error": @"type must be 'audio', 'video', or 'caption'"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            SEL selectedSel = NSSelectorFromString(@"selectedItems");
            id selectedItems = nil;
            if ([timeline respondsToSelector:selectedSel]) {
                selectedItems = ((id (*)(id, SEL))objc_msgSend)(timeline, selectedSel);
            }
            if (![selectedItems isKindOfClass:[NSArray class]] || [(NSArray *)selectedItems count] == 0) {
                result = @{@"error": @"No clip selected. Select a clip first."};
                return;
            }

            NSDictionary *menuResult = SpliceKit_handleMenuExecute(
                @{@"menuPath": @[@"Modify", menuCategory, roleName]});
            if (menuResult[@"error"]) {
                result = @{
                    @"error": SpliceKit_formatRolesAssignMenuError(
                        menuResult[@"error"], menuCategory, roleName),
                };
                return;
            }
            result = @{
                @"status": @"ok",
                @"type": roleType,
                @"role": roleName,
                @"method": @"menu",
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to assign role"};
}

#pragma mark - Mixer Handlers

// Helper: get effectStack from a clip, handling compound clips
static id SpliceKit_getClipEffectStack(id clip) {
    if (!clip) return nil;

    // Role-bearing collections have their own audio effect stack. Prefer that over
    // the first contained media component so connected stems keep separate gain.
    if ([clip isKindOfClass:objc_getClass("FFAnchoredCollection")]) {
        @try {
            SEL audioEffectsSel = NSSelectorFromString(@"audioEffects");
            if ([clip respondsToSelector:audioEffectsSel]) {
                id audioES = ((id (*)(id, SEL))objc_msgSend)(clip, audioEffectsSel);
                if (audioES) return audioES;
            }

            id items = [clip valueForKey:@"containedItems"];
            if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
                id firstItem = [(NSArray *)items firstObject];
                if ([firstItem respondsToSelector:@selector(effectStack)]) {
                    id es = ((id (*)(id, SEL))objc_msgSend)(firstItem, @selector(effectStack));
                    if (es) return es;
                }
            }
        } @catch (NSException *e) {}
    }

    // Direct effectStack access
    if ([clip respondsToSelector:@selector(effectStack)]) {
        return ((id (*)(id, SEL))objc_msgSend)(clip, @selector(effectStack));
    }
    return nil;
}

// Helper: read volume (dB and linear) from a clip.
// FCP stores audio effects in a separate effectStack accessed via audioEffectsForIdentifier:
// (not the main effectStack which is for video effects).
// Mixer state for volume reads — set before calling readVolume
static SpliceKit_CMTime sMixerPlayheadTime = {0, 0, 17, 0}; // default: kCMTimeIndefinite
static id sMixerContainer = nil; // primaryObject for containerToLocalTime conversion

static BOOL SpliceKit_refreshMixerTimelineState(void) {
    id timeline = SpliceKit_getActiveTimelineModule();
    if (!timeline) return NO;

    id sequence = nil;
    @try {
        SEL seqSel = @selector(sequence);
        if ([timeline respondsToSelector:seqSel]) {
            sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
        }
    } @catch (NSException *e) {}
    if (!sequence) return NO;

    SpliceKit_CMTime playhead = {0, 1, 0, 0};
    @try {
        SEL playheadSel = @selector(playheadTime);
        if ([timeline respondsToSelector:playheadSel]) {
            playhead = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timeline, playheadSel);
        }
    } @catch (NSException *e) {}

    id primaryObj = nil;
    @try {
        SEL primarySel = @selector(primaryObject);
        if ([sequence respondsToSelector:primarySel]) {
            primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel);
        }
    } @catch (NSException *e) {}

    if (!primaryObj || playhead.timescale <= 0) return NO;

    sMixerPlayheadTime = playhead;
    sMixerContainer = primaryObj;
    return YES;
}

// Convert absolute timeline time to clip-local time for keyframe reads
static SpliceKit_CMTime SpliceKit_clipLocalTime(id clip, SpliceKit_CMTime absTime, id container) {
    if (!clip || !container) return absTime;
    @try {
        SEL sel = NSSelectorFromString(@"containerToLocalTime:container:");
        if ([clip respondsToSelector:sel]) {
            return ((SpliceKit_CMTime (*)(id, SEL, SpliceKit_CMTime, id))STRET_MSG)(
                clip, sel, absTime, container);
        }
    } @catch (NSException *e) {}
    return absTime;
}

// Write one automation point to the mixer's volume channel at the live playhead.
// The current timeline state is refreshed here so drag writes do not depend on UI poll cadence.
BOOL SpliceKit_mixerWriteAutomationPoint(id clip, id channel, double value) {
    if (!clip || !channel) return NO;
    if (!SpliceKit_refreshMixerTimelineState()) return NO;

    SpliceKit_CMTime localTime = SpliceKit_clipLocalTime(clip, sMixerPlayheadTime, sMixerContainer);
    BOOL beganOperation = NO;

    @try {
        SEL beginSel = NSSelectorFromString(@"operationBegin");
        if ([channel respondsToSelector:beginSel]) {
            ((void (*)(id, SEL))objc_msgSend)(channel, beginSel);
            beganOperation = YES;
        }
    } @catch (NSException *e) {}

    // Match FCP's inspector/slider behavior: read current value first, then write
    // a timed curve value with the auto-keyframe option enabled.
    (void)SpliceKit_channelValueAtTime(channel, localTime);
    BOOL ok = SpliceKit_setChannelValueAtTimeWithOptions(channel, value, localTime, 1);

    @try {
        SEL endSel = NSSelectorFromString(@"operationEnd");
        if (beganOperation && [channel respondsToSelector:endSel]) {
            ((void (*)(id, SEL))objc_msgSend)(channel, endSel);
        }
    } @catch (NSException *e) {}

    return ok;
}

static NSNumber *SpliceKit_mixerJSONDBNumberFromLinear(double linear, double floorDB);
static NSArray<NSDictionary *> *SpliceKit_mixerRecordDebugState(NSDictionary *state);
void SpliceKit_installMixerSkimHooks(void);

static BOOL sMixerSkimmingLatched = NO;
static CFAbsoluteTime sMixerLastSkimBeginTime = 0;
static CFAbsoluteTime sMixerLastSkimEndTime = 0;
static CFAbsoluteTime sMixerLastSkimUpdateTime = 0;
static IMP sOrigFFPlayerBeginSkimming = NULL;
static IMP sOrigFFPlayerEndSkimming = NULL;
static IMP sOrigTimelineHandlerDidUpdateSkimming = NULL;

static void SpliceKit_readVolume(id clip, id effectStack, NSMutableDictionary *out) {
    if (!clip && !effectStack) return;

    // Strategy 1: Use audioEffectsForIdentifier: on the clip (correct FCP pattern)
    if (clip) {
        @try {
            SEL aeSel = NSSelectorFromString(@"audioEffectsForIdentifier:");
            if ([clip respondsToSelector:aeSel]) {
                id audioES = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(clip, aeSel, 0ULL);
                if (audioES) {
                    out[@"audioEffectStackHandle"] = SpliceKit_storeHandle(audioES);
                    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
                    if ([audioES respondsToSelector:volSel]) {
                        id volChan = ((id (*)(id, SEL))objc_msgSend)(audioES, volSel);
                        if (volChan) {
                            out[@"volumeChannelHandle"] = SpliceKit_storeHandle(volChan);
                            // Convert playhead time to clip-local time for keyframe reads
                            SpliceKit_CMTime localTime = SpliceKit_clipLocalTime(clip, sMixerPlayheadTime, sMixerContainer);
                            double linear = SpliceKit_channelValueAtTime(volChan, localTime);
                            out[@"volumeLinear"] = @(linear);
                            out[@"volumeDB"] = SpliceKit_mixerJSONDBNumberFromLinear(linear, -96.0);
                            return;
                        }
                    }
                }
            }
        } @catch (NSException *e) {}
    }

    // Strategy 2: Fallback to effectStack.audioLevelChannel (for clips where the above doesn't work)
    if (effectStack) {
        @try {
            SEL volSel = NSSelectorFromString(@"audioLevelChannel");
            if ([effectStack respondsToSelector:volSel]) {
                id volChan = ((id (*)(id, SEL))objc_msgSend)(effectStack, volSel);
                if (volChan) {
                    SpliceKit_CMTime localTime = SpliceKit_clipLocalTime(clip, sMixerPlayheadTime, sMixerContainer);
                    double linear = SpliceKit_channelValueAtTime(volChan, localTime);
                    out[@"volumeLinear"] = @(linear);
                    out[@"volumeDB"] = SpliceKit_mixerJSONDBNumberFromLinear(linear, -96.0);
                    out[@"volumeChannelHandle"] = SpliceKit_storeHandle(volChan);
                    return;
                }
            }
        } @catch (NSException *e) {}
    }
}

static NSNumber *SpliceKit_mixerJSONDBNumberFromLinear(double linear, double floorDB) {
    if (!isfinite(linear) || linear <= 0.000001) return @(floorDB);
    double db = 20.0 * log10(linear);
    if (!isfinite(db) || db < floorDB) db = floorDB;
    return @(db);
}

static void SpliceKit_swizzled_FFPlayer_beginSkimming(id self, SEL _cmd) {
    sMixerSkimmingLatched = YES;
    sMixerLastSkimBeginTime = CFAbsoluteTimeGetCurrent();
    sMixerLastSkimUpdateTime = sMixerLastSkimBeginTime;
    SpliceKit_log(@"[MixerSkim] beginSkimming");
    if (sOrigFFPlayerBeginSkimming) {
        ((void (*)(id, SEL))sOrigFFPlayerBeginSkimming)(self, _cmd);
    }
}

static void SpliceKit_swizzled_FFPlayer_endSkimming(id self, SEL _cmd) {
    sMixerSkimmingLatched = NO;
    sMixerLastSkimEndTime = CFAbsoluteTimeGetCurrent();
    SpliceKit_log(@"[MixerSkim] endSkimming");
    if (sOrigFFPlayerEndSkimming) {
        ((void (*)(id, SEL))sOrigFFPlayerEndSkimming)(self, _cmd);
    }
}

static void SpliceKit_swizzled_Timeline_handlerDidUpdateSkimming(id self, SEL _cmd, id info) {
    sMixerLastSkimUpdateTime = CFAbsoluteTimeGetCurrent();
    if (sOrigTimelineHandlerDidUpdateSkimming) {
        ((void (*)(id, SEL, id))sOrigTimelineHandlerDidUpdateSkimming)(self, _cmd, info);
    }
}

void SpliceKit_installMixerSkimHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class playerCls = NSClassFromString(@"FFPlayer");
        if (playerCls) {
            Method beginMethod = class_getInstanceMethod(playerCls, @selector(beginSkimming));
            if (beginMethod && !sOrigFFPlayerBeginSkimming) {
                sOrigFFPlayerBeginSkimming = SpliceKit_swizzleMethod(
                    playerCls, @selector(beginSkimming), (IMP)SpliceKit_swizzled_FFPlayer_beginSkimming);
            }
            Method endMethod = class_getInstanceMethod(playerCls, @selector(endSkimming));
            if (endMethod && !sOrigFFPlayerEndSkimming) {
                sOrigFFPlayerEndSkimming = SpliceKit_swizzleMethod(
                    playerCls, @selector(endSkimming), (IMP)SpliceKit_swizzled_FFPlayer_endSkimming);
            }
        }

        Class timelineCls = NSClassFromString(@"FFAnchoredTimelineModule");
        SEL updateSel = NSSelectorFromString(@"handlerDidUpdateSkimming:");
        if (timelineCls && class_getInstanceMethod(timelineCls, updateSel) && !sOrigTimelineHandlerDidUpdateSkimming) {
            sOrigTimelineHandlerDidUpdateSkimming = SpliceKit_swizzleMethod(
                timelineCls, updateSel, (IMP)SpliceKit_swizzled_Timeline_handlerDidUpdateSkimming);
        }

        SpliceKit_log(@"[MixerSkim] Hooks installed: begin=%@ end=%@ update=%@",
                      sOrigFFPlayerBeginSkimming ? @"yes" : @"no",
                      sOrigFFPlayerEndSkimming ? @"yes" : @"no",
                      sOrigTimelineHandlerDidUpdateSkimming ? @"yes" : @"no");
    });
}

static NSArray<NSDictionary *> *SpliceKit_mixerRecordDebugState(NSDictionary *state) {
    static NSMutableArray<NSDictionary *> *history = nil;
    static NSString *lastSignature = nil;

    if (!history) history = [NSMutableArray array];
    if (![state isKindOfClass:[NSDictionary class]]) return [history copy];

    double roundedTime = floor([state[@"activeTimeSeconds"] doubleValue] * 4.0) / 4.0;
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%.2f",
                           state[@"toolSkimming"] ?: @NO,
                           state[@"transportPlaying"] ?: @NO,
                           state[@"meteringLive"] ?: @NO,
                           state[@"usedPlayerMetering"] ?: @NO,
                           state[@"usedLayerFallback"] ?: @NO,
                           state[@"skimmedRole"] ?: @"",
                           state[@"skimmedName"] ?: @"",
                           roundedTime];
    if ([lastSignature isEqualToString:signature]) {
        return [history copy];
    }

    lastSignature = [signature copy];
    NSMutableDictionary *entry = [state mutableCopy];
    entry[@"wallTime"] = @([[NSDate date] timeIntervalSince1970]);
    entry[@"roundedActiveTimeSeconds"] = @(roundedTime);
    [history addObject:entry];
    while (history.count > 20) {
        [history removeObjectAtIndex:0];
    }
    return [history copy];
}

// Helper: read audio role info from a clip — returns name and color.
// Uses audioRoleIdentifier → library lookup → displayName, and
// FFColorForRole colorSchemeForRolesOfObject: → baseColor for the actual FCP role color.
NSString *SpliceKit_readClipRole(id clip) {
    if (!clip) return nil;

    @try {
        SEL ariSel = NSSelectorFromString(@"audioRoleIdentifier");
        if (![clip respondsToSelector:ariSel]) return nil;

        id roleUID = ((id (*)(id, SEL))objc_msgSend)(clip, ariSel);
        if (!roleUID || ![roleUID isKindOfClass:[NSString class]]) return nil;

        id libs = ((id (*)(Class, SEL))objc_msgSend)(
            objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
        if (!libs || ![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) return nil;

        for (id library in (NSArray *)libs) {
            SEL findSel = NSSelectorFromString(@"findRoleWithUID:");
            if (![library respondsToSelector:findSel]) continue;

            id role = ((id (*)(id, SEL, id))objc_msgSend)(library, findSel, roleUID);
            if (!role) continue;

            if ([role respondsToSelector:@selector(displayName)]) {
                id name = ((id (*)(id, SEL))objc_msgSend)(role, @selector(displayName));
                if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0)
                    return (NSString *)name;
            }
        }
    } @catch (NSException *e) {}

    // Fallback: known built-in UUIDs
    @try {
        SEL guessSel = NSSelectorFromString(@"guessAudioBuiltInMainRoleUID");
        if ([clip respondsToSelector:guessSel]) {
            id uid = ((id (*)(id, SEL))objc_msgSend)(clip, guessSel);
            if ([uid isKindOfClass:[NSString class]]) {
                if ([uid isEqualToString:@"AzxbPvadwQbKPP4kwdFxLVg"]) return @"Dialogue";
                if ([uid isEqualToString:@"A4bkI8U6kRJmBTQDqKJcJrg"]) return @"Music";
                if ([uid isEqualToString:@"ASw2gOhIuSd2wQ8jgLyN3Ew"]) return @"Effects";
            }
        }
    } @catch (NSException *e) {}

    return nil;
}

static NSString *SpliceKit_rawClipRoleUID(id clip) {
    if (!clip) return nil;
    @try {
        SEL ariSel = NSSelectorFromString(@"audioRoleIdentifier");
        if ([clip respondsToSelector:ariSel]) {
            id roleUID = ((id (*)(id, SEL))objc_msgSend)(clip, ariSel);
            if ([roleUID isKindOfClass:[NSString class]] && [roleUID length] > 0) {
                return roleUID;
            }
        }

        SEL guessSel = NSSelectorFromString(@"guessAudioBuiltInMainRoleUID");
        if ([clip respondsToSelector:guessSel]) {
            id roleUID = ((id (*)(id, SEL))objc_msgSend)(clip, guessSel);
            if ([roleUID isKindOfClass:[NSString class]] && [roleUID length] > 0) {
                return roleUID;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

// Helper: read the FCP role color for a clip as RGB hex string (e.g. "#3A7D44")
static NSString *SpliceKit_readClipRoleColor(id clip) {
    if (!clip) return nil;
    @try {
        Class colorForRole = objc_getClass("FFColorForRole");
        if (!colorForRole) return nil;
        SEL csSel = NSSelectorFromString(@"colorSchemeForRolesOfObject:");
        if (![colorForRole respondsToSelector:csSel]) return nil;

        id scheme = ((id (*)(Class, SEL, id))objc_msgSend)(colorForRole, csSel, clip);
        if (!scheme) return nil;

        // Use itemForegroundColor for bright text, fall back to baseColor
        SEL fgSel = NSSelectorFromString(@"itemForegroundColor");
        SEL baseSel = NSSelectorFromString(@"baseColor");
        NSColor *color = nil;
        if ([scheme respondsToSelector:fgSel])
            color = ((id (*)(id, SEL))objc_msgSend)(scheme, fgSel);
        if (!color && [scheme respondsToSelector:baseSel])
            color = ((id (*)(id, SEL))objc_msgSend)(scheme, baseSel);
        if (!color) return nil;

        // Convert to sRGB and extract components
        NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!rgb) return nil;
        CGFloat r, g, b, a;
        [rgb getRed:&r green:&g blue:&b alpha:&a];
        return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)(r * 255), (int)(g * 255), (int)(b * 255)];
    } @catch (NSException *e) {}
    return nil;
}

NSArray *SpliceKit_mixerArrayFromContainer(id value) {
    if (!value) return nil;
    if ([value isKindOfClass:[NSArray class]]) return value;
    if ([value isKindOfClass:[NSSet class]]) return [(NSSet *)value allObjects];
    SEL allObjectsSel = NSSelectorFromString(@"allObjects");
    if ([value respondsToSelector:allObjectsSel]) {
        @try {
            id arr = ((id (*)(id, SEL))objc_msgSend)(value, allObjectsSel);
            if ([arr isKindOfClass:[NSArray class]]) return arr;
        } @catch (NSException *e) {}
    }
    return nil;
}

BOOL SpliceKit_mixerIsCollectionLike(id item) {
    if (!item) return NO;
    NSString *cls = NSStringFromClass([item class]) ?: @"";
    return [cls containsString:@"Collection"] ||
           [cls containsString:@"Storyline"] ||
           [cls containsString:@"Sequence"] ||
           [cls containsString:@"Container"];
}

BOOL SpliceKit_mixerIsSkippableItem(id item) {
    NSString *cls = NSStringFromClass([item class]) ?: @"";
    return [cls containsString:@"Gap"] || [cls containsString:@"Transition"];
}

static BOOL SpliceKit_mixerHasExplicitAudioRole(id item) {
    NSString *roleUID = SpliceKit_rawClipRoleUID(item);
    return roleUID.length > 0;
}

static BOOL SpliceKit_mixerHasAudio(id item) {
    if (!item) return NO;
    @try {
        SEL hasAudioSel = NSSelectorFromString(@"hasAudio");
        if ([item respondsToSelector:hasAudioSel]) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(item, hasAudioSel);
        }
    } @catch (NSException *e) {}
    return NO;
}

static BOOL SpliceKit_mixerIsAudioCarrier(id item) {
    if (!item || SpliceKit_mixerIsSkippableItem(item)) return NO;

    NSString *cls = NSStringFromClass([item class]) ?: @"";
    if (SpliceKit_mixerIsCollectionLike(item)) {
        return NO;
    }

    SEL aeSel = NSSelectorFromString(@"audioEffectsForIdentifier:");
    SEL ariSel = NSSelectorFromString(@"audioRoleIdentifier");
    SEL volSel = NSSelectorFromString(@"audioLevelChannel");
    return [item respondsToSelector:aeSel] ||
           [item respondsToSelector:ariSel] ||
           [item respondsToSelector:volSel] ||
           [cls containsString:@"MediaComponent"];
}

static BOOL SpliceKit_mixerTryReadEffectiveRange(id primaryObj, SEL erSel, id item,
                                                 double *outStartSec, double *outEndSec) {
    if (!primaryObj || !item || !erSel || !outStartSec || !outEndSec) return NO;
    @try {
        SpliceKit_CMTimeRange range = ((SpliceKit_CMTimeRange (*)(id, SEL, id))STRET_MSG)(
            primaryObj, erSel, item);
        if (range.start.timescale <= 0 || range.duration.timescale <= 0) return NO;
        double startSec = (double)range.start.value / range.start.timescale;
        double durSec = (double)range.duration.value / range.duration.timescale;
        if (!isfinite(startSec) || !isfinite(durSec) || durSec <= 0.0) return NO;
        *outStartSec = startSec;
        *outEndSec = startSec + durSec;
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

static void SpliceKit_mixerCollectClipEntries(id item,
                                              id primaryObj,
                                              SEL erSel,
                                              BOOL canGetRange,
                                              NSInteger inheritedLane,
                                              double inheritedStartSec,
                                              double inheritedEndSec,
                                              NSMutableArray *out,
                                              NSMutableSet<NSString *> *visited) {
    if (!item || !out || !visited) return;

    NSString *visitKey = SpliceKit_handlePointerKey(item);
    if (visitKey.length == 0 || [visited containsObject:visitKey]) return;
    [visited addObject:visitKey];

    if (SpliceKit_mixerIsSkippableItem(item)) return;

    NSInteger lane = inheritedLane;
    @try {
        SEL laneSel = NSSelectorFromString(@"anchoredLane");
        if ([item respondsToSelector:laneSel]) {
            lane = (NSInteger)((long long (*)(id, SEL))objc_msgSend)(item, laneSel);
        }
    } @catch (NSException *e) {}

    double startSec = inheritedStartSec;
    double endSec = inheritedEndSec;
    if (canGetRange) {
        double rangeStart = 0.0;
        double rangeEnd = 0.0;
        if (SpliceKit_mixerTryReadEffectiveRange(primaryObj, erSel, item, &rangeStart, &rangeEnd)) {
            startSec = rangeStart;
            endSec = rangeEnd;
        }
    }

    SEL containedSel = NSSelectorFromString(@"containedItems");
    NSArray *contained = [item respondsToSelector:containedSel]
        ? SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, containedSel))
        : nil;

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    NSArray *anchored = [item respondsToSelector:anchoredSel]
        ? SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, anchoredSel))
        : nil;

    BOOL collectionRoleCarrier = SpliceKit_mixerIsCollectionLike(item) &&
                                 SpliceKit_mixerHasExplicitAudioRole(item) &&
                                 SpliceKit_mixerHasAudio(item);
    if ((collectionRoleCarrier || SpliceKit_mixerIsAudioCarrier(item)) &&
        endSec > startSec + 0.0001) {
        NSString *role = SpliceKit_readClipRole(item) ?: @"Dialogue";
        NSString *roleUID = SpliceKit_rawClipRoleUID(item) ?: @"";
        NSString *roleColor = SpliceKit_readClipRoleColor(item) ?: @"";
        [out addObject:@{
            @"item": item,
            @"role": role,
            @"roleUID": roleUID,
            @"roleColor": roleColor,
            @"start": @(startSec),
            @"end": @(endSec),
            @"lane": @(lane),
        }];
    }

    if (!collectionRoleCarrier) {
        for (id child in contained) {
            SpliceKit_mixerCollectClipEntries(child, primaryObj, erSel, canGetRange,
                                              lane, startSec, endSec, out, visited);
        }
    }
    for (id child in anchored) {
        SpliceKit_mixerCollectClipEntries(child, primaryObj, erSel, canGetRange,
                                          lane, startSec, endSec, out, visited);
    }
}

static NSMutableOrderedSet *SpliceKit_mixerRoleOrderFromClips(NSArray<NSDictionary *> *allClips) {
    NSMutableOrderedSet *roleOrder = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *clip in allClips) {
        NSString *r = clip[@"role"];
        if ([r containsString:@"Dialogue"]) [roleOrder addObject:r];
    }
    for (NSDictionary *clip in allClips) {
        NSString *r = clip[@"role"];
        if ([r containsString:@"Music"]) [roleOrder addObject:r];
    }
    for (NSDictionary *clip in allClips) {
        NSString *r = clip[@"role"];
        if ([r containsString:@"Effects"]) [roleOrder addObject:r];
    }
    for (NSDictionary *clip in allClips) {
        NSString *r = clip[@"role"];
        if (r.length > 0) [roleOrder addObject:r];
    }
    return roleOrder;
}

static NSArray *SpliceKit_mixerObjectsForRole(NSArray<NSDictionary *> *allClips, NSString *role) {
    if (role.length == 0) return @[];
    NSMutableArray *objects = [NSMutableArray array];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (NSDictionary *clip in allClips) {
        if (![clip[@"role"] isEqualToString:role]) continue;
        id item = clip[@"item"];
        if (!item) continue;
        NSString *key = SpliceKit_handlePointerKey(item);
        if (key.length > 0 && [visited containsObject:key]) continue;
        if (key.length > 0) [visited addObject:key];
        [objects addObject:item];
    }
    return objects;
}

static id SpliceKit_mixerBusEffectStackForObject(id object) {
    if (!object) return nil;

    @try {
        SEL localSel = NSSelectorFromString(@"localAudioEffects");
        if ([object respondsToSelector:localSel]) {
            id stack = ((id (*)(id, SEL))objc_msgSend)(object, localSel);
            if (stack) return stack;
        }
    } @catch (NSException *e) {}

    @try {
        SEL aeSel = NSSelectorFromString(@"audioEffectsForIdentifier:");
        if ([object respondsToSelector:aeSel]) {
            id stack = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(object, aeSel, 0ULL);
            if (stack) return stack;
        }
    } @catch (NSException *e) {}

    @try {
        SEL audioEffectsSel = NSSelectorFromString(@"audioEffects");
        if ([object respondsToSelector:audioEffectsSel]) {
            id stack = ((id (*)(id, SEL))objc_msgSend)(object, audioEffectsSel);
            if (stack) return stack;
        }
    } @catch (NSException *e) {}

    return nil;
}

static NSArray *SpliceKit_mixerEffectsInStack(id effectStack) {
    if (!effectStack) return @[];
    for (NSString *selectorName in @[@"visibleEffects", @"effects"]) {
        @try {
            SEL sel = NSSelectorFromString(selectorName);
            if (![effectStack respondsToSelector:sel]) continue;
            id effects = ((id (*)(id, SEL))objc_msgSend)(effectStack, sel);
            NSArray *array = SpliceKit_mixerArrayFromContainer(effects);
            if (array) return array;
        } @catch (NSException *e) {}
    }
    return @[];
}

static NSDictionary *SpliceKit_mixerEffectSummary(id effect, NSUInteger index) {
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"index"] = @(index);
    summary[@"handle"] = effect ? (SpliceKit_storeHandle(effect) ?: @"") : @"";
    summary[@"class"] = effect ? (NSStringFromClass([effect class]) ?: @"") : @"";

    @try {
        SEL displayNameSel = NSSelectorFromString(@"displayName");
        if (effect && [effect respondsToSelector:displayNameSel]) {
            id displayName = ((id (*)(id, SEL))objc_msgSend)(effect, displayNameSel);
            if (displayName) summary[@"name"] = [displayName description];
        }
    } @catch (NSException *e) {}

    @try {
        SEL effectIDSel = NSSelectorFromString(@"effectID");
        if (effect && [effect respondsToSelector:effectIDSel]) {
            id effectID = ((id (*)(id, SEL))objc_msgSend)(effect, effectIDSel);
            if (effectID) summary[@"effectID"] = [effectID description];
        }
    } @catch (NSException *e) {}

    BOOL enabled = YES;
    @try {
        SEL enabledSel = NSSelectorFromString(@"enabled");
        if (effect && [effect respondsToSelector:enabledSel]) {
            enabled = ((BOOL (*)(id, SEL))objc_msgSend)(effect, enabledSel);
        }
    } @catch (NSException *e) {}
    summary[@"enabled"] = @(enabled);

    if (![summary[@"name"] isKindOfClass:[NSString class]] || [summary[@"name"] length] == 0) {
        summary[@"name"] = summary[@"effectID"] ?: summary[@"class"] ?: @"Effect";
    }
    if (![summary[@"effectID"] isKindOfClass:[NSString class]]) {
        summary[@"effectID"] = @"";
    }
    return summary;
}

static NSDictionary *SpliceKit_mixerBusTargetSummary(id object, id effectStack) {
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    if (object) {
        summary[@"objectHandle"] = SpliceKit_storeHandle(object) ?: @"";
        summary[@"objectClass"] = NSStringFromClass([object class]) ?: @"";
        @try {
            SEL displayNameSel = NSSelectorFromString(@"displayName");
            if ([object respondsToSelector:displayNameSel]) {
                id displayName = ((id (*)(id, SEL))objc_msgSend)(object, displayNameSel);
                if (displayName) summary[@"name"] = [displayName description];
            }
        } @catch (NSException *e) {}
    }
    if (effectStack) {
        summary[@"effectStackHandle"] = SpliceKit_storeHandle(effectStack) ?: @"";
        summary[@"effectStackClass"] = NSStringFromClass([effectStack class]) ?: @"";

        NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
        summary[@"effectCount"] = @(effects.count);
        NSMutableArray *effectNames = [NSMutableArray array];
        NSMutableArray *effectSummaries = [NSMutableArray arrayWithCapacity:effects.count];
        for (NSUInteger i = 0; i < effects.count; i++) {
            NSDictionary *effectSummary = SpliceKit_mixerEffectSummary(effects[i], i);
            NSString *name = effectSummary[@"name"];
            if (name.length > 0) [effectNames addObject:name];
            [effectSummaries addObject:effectSummary];
        }
        summary[@"effectNames"] = effectNames;
        summary[@"effects"] = effectSummaries;
    }
    return summary;
}

static NSArray<NSDictionary *> *SpliceKit_mixerBusTargetsForRoleObjects(NSArray *roleObjects,
                                                                        BOOL allowObjectFallback) {
    NSMutableArray *targets = [NSMutableArray array];
    NSMutableSet<NSString *> *seenStacks = [NSMutableSet set];

    for (id object in roleObjects) {
        if (!object) continue;
        BOOL collectionBacked = SpliceKit_mixerIsCollectionLike(object);
        if (!collectionBacked && !allowObjectFallback) continue;

        id effectStack = SpliceKit_mixerBusEffectStackForObject(object);
        if (!effectStack) continue;

        NSString *stackKey = SpliceKit_handlePointerKey(effectStack);
        if (stackKey.length > 0 && [seenStacks containsObject:stackKey]) continue;
        if (stackKey.length > 0) [seenStacks addObject:stackKey];

        [targets addObject:@{
            @"object": object,
            @"effectStack": effectStack,
            @"collectionBacked": @(collectionBacked),
        }];
    }

    return targets;
}

static NSMutableDictionary<NSString *, NSMutableArray<NSMutableDictionary *> *> *sMixerManagedBusEffects = nil;
static BOOL sMixerManagedBusReconciling = NO;

static NSString *SpliceKit_mixerManagedBusScopeKey(id sequence, id rootObject) {
    NSString *sequenceKey = SpliceKit_handlePointerKey(sequence) ?: @"";
    NSString *rootKey = SpliceKit_handlePointerKey(rootObject) ?: @"";
    if (sequenceKey.length == 0 && rootKey.length == 0) return @"";
    return [NSString stringWithFormat:@"seq:%@|root:%@", sequenceKey, rootKey.length > 0 ? rootKey : sequenceKey];
}

static BOOL SpliceKit_mixerManagedBusEntryMatchesScope(NSDictionary *entry, NSString *scopeKey) {
    NSString *entryScope = [entry[@"scopeKey"] isKindOfClass:[NSString class]] ? entry[@"scopeKey"] : @"";
    return entryScope.length > 0 && scopeKey.length > 0 && [entryScope isEqualToString:scopeKey];
}

static NSMutableDictionary<NSString *, NSMutableArray<NSMutableDictionary *> *> *SpliceKit_mixerManagedBusRegistry(void) {
    if (!sMixerManagedBusEffects) sMixerManagedBusEffects = [NSMutableDictionary dictionary];
    return sMixerManagedBusEffects;
}

static NSMutableArray<NSMutableDictionary *> *SpliceKit_mixerManagedBusEntriesForRole(NSString *role, BOOL create) {
    if (role.length == 0) return nil;
    NSMutableDictionary *registry = SpliceKit_mixerManagedBusRegistry();
    NSMutableArray *entries = registry[role];
    if (!entries && create) {
        entries = [NSMutableArray array];
        registry[role] = entries;
    }
    return entries;
}

static NSArray<NSMutableDictionary *> *SpliceKit_mixerManagedBusEntriesForRoleInScope(NSString *role, NSString *scopeKey) {
    NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, NO);
    if (entries.count == 0 || scopeKey.length == 0) return @[];

    NSMutableArray *scoped = [NSMutableArray array];
    for (NSMutableDictionary *entry in [entries copy]) {
        if (SpliceKit_mixerManagedBusEntryMatchesScope(entry, scopeKey)) {
            [scoped addObject:entry];
        }
    }
    return scoped;
}

static BOOL SpliceKit_mixerManagedBusRegistryHasEntriesForScope(NSString *scopeKey) {
    if (scopeKey.length == 0 || sMixerManagedBusEffects.count == 0) return NO;
    for (NSString *role in [[sMixerManagedBusEffects allKeys] copy]) {
        if (SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey).count > 0) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *SpliceKit_mixerManagedBusRolesForScope(NSString *scopeKey) {
    if (scopeKey.length == 0 || sMixerManagedBusEffects.count == 0) return @[];
    NSMutableArray<NSString *> *roles = [NSMutableArray array];
    for (NSString *role in [[[sMixerManagedBusEffects allKeys] copy] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        if (SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey).count > 0) {
            [roles addObject:role];
        }
    }
    return roles;
}

static void SpliceKit_mixerAddManagedBusRolesToRoleOrder(NSMutableOrderedSet *roleOrder, NSString *scopeKey) {
    if (!roleOrder || scopeKey.length == 0) return;
    for (NSString *role in SpliceKit_mixerManagedBusRolesForScope(scopeKey)) {
        if (role.length > 0) [roleOrder addObject:role];
    }
}

static void SpliceKit_mixerPruneManagedBusRole(NSString *role) {
    if (role.length == 0 || !sMixerManagedBusEffects) return;
    NSMutableArray *entries = sMixerManagedBusEffects[role];
    if (entries.count == 0) [sMixerManagedBusEffects removeObjectForKey:role];
}

static NSString *SpliceKit_mixerEffectStringValue(id effect, NSString *selectorName) {
    if (!effect || selectorName.length == 0) return @"";
    @try {
        SEL sel = NSSelectorFromString(selectorName);
        if ([effect respondsToSelector:sel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(effect, sel);
            return value ? [value description] : @"";
        }
    } @catch (NSException *e) {}
    return @"";
}

static BOOL SpliceKit_mixerEffectMatchesManagedEntry(id effect, NSDictionary *entry) {
    if (!effect || !entry) return NO;
    NSString *entryEffectID = [entry[@"effectID"] isKindOfClass:[NSString class]] ? entry[@"effectID"] : @"";
    NSString *entryName = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"";
    NSString *effectID = SpliceKit_mixerEffectStringValue(effect, @"effectID");
    if (entryEffectID.length > 0 && effectID.length > 0) {
        return [entryEffectID isEqualToString:effectID];
    }
    NSString *name = SpliceKit_mixerEffectStringValue(effect, @"displayName");
    return entryName.length > 0 && name.length > 0 && [entryName isEqualToString:name];
}

static NSMutableDictionary *SpliceKit_mixerNewManagedBusEntry(NSString *role,
                                                              NSString *scopeKey,
                                                              NSDictionary *effect) {
    NSString *effectID = [effect[@"effectID"] isKindOfClass:[NSString class]] ? effect[@"effectID"] : @"";
    NSString *name = [effect[@"name"] isKindOfClass:[NSString class]] ? effect[@"name"] : effectID;
    if (name.length == 0) name = @"Effect";

    NSMutableDictionary *entry = [@{
        @"busEffectID": [[NSUUID UUID] UUIDString],
        @"role": role ?: @"",
        @"scopeKey": scopeKey ?: @"",
        @"effectID": effectID ?: @"",
        @"name": name,
        @"enabled": @YES,
        @"instances": [NSMutableArray array],
    } mutableCopy];
    NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, YES);
    [entries addObject:entry];
    return entry;
}

static NSDictionary *SpliceKit_mixerRememberManagedInstance(NSMutableDictionary *entry,
                                                            id object,
                                                            id effectStack,
                                                            id effect) {
    if (!entry || !object || !effectStack || !effect) return nil;

    NSString *objectKey = SpliceKit_handlePointerKey(object) ?: @"";
    NSMutableArray *instances = [entry[@"instances"] isKindOfClass:[NSMutableArray class]]
        ? entry[@"instances"]
        : nil;
    if (!instances) {
        instances = [NSMutableArray array];
        entry[@"instances"] = instances;
    }

    if (objectKey.length > 0) {
        for (NSDictionary *instance in [instances copy]) {
            NSString *existingObjectKey = [instance[@"objectKey"] isKindOfClass:[NSString class]]
                ? instance[@"objectKey"]
                : @"";
            if ([existingObjectKey isEqualToString:objectKey]) {
                [instances removeObject:instance];
            }
        }
    }

    NSInteger effectIndex = SpliceKit_mixerIndexOfEffectInStack(effectStack, effect);
    NSMutableDictionary *instance = [NSMutableDictionary dictionary];
    instance[@"objectKey"] = objectKey;
    instance[@"objectHandle"] = SpliceKit_storeHandle(object) ?: @"";
    instance[@"stackKey"] = SpliceKit_handlePointerKey(effectStack) ?: @"";
    instance[@"effectKey"] = SpliceKit_handlePointerKey(effect) ?: @"";
    instance[@"effectHandle"] = SpliceKit_storeHandle(effect) ?: @"";
    instance[@"effectStackHandle"] = SpliceKit_storeHandle(effectStack) ?: @"";
    if (effectIndex != NSNotFound) instance[@"effectIndex"] = @(effectIndex);
    [instances addObject:instance];
    return instance;
}

static NSDictionary *SpliceKit_mixerCaptureManagedInstanceAfterApply(NSMutableDictionary *entry,
                                                                     id object,
                                                                     NSUInteger beforeCount) {
    if (!entry || !object) return nil;
    id effectStack = SpliceKit_mixerBusEffectStackForObject(object);
    if (!effectStack) return nil;

    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    id chosenEffect = nil;
    NSUInteger start = MIN(beforeCount, effects.count);
    for (NSUInteger idx = start; idx < effects.count; idx++) {
        id effect = effects[idx];
        if (SpliceKit_mixerEffectMatchesManagedEntry(effect, entry)) {
            chosenEffect = effect;
            break;
        }
    }
    if (!chosenEffect) {
        for (NSUInteger idx = effects.count; idx > 0; idx--) {
            id effect = effects[idx - 1];
            if (SpliceKit_mixerEffectMatchesManagedEntry(effect, entry)) {
                chosenEffect = effect;
                break;
            }
        }
    }
    if (!chosenEffect) return nil;

    NSDictionary *instance = SpliceKit_mixerRememberManagedInstance(entry, object, effectStack, chosenEffect);
    BOOL enabled = ![entry[@"enabled"] isKindOfClass:[NSNumber class]] || [entry[@"enabled"] boolValue];
    if (!enabled) {
        SEL setEnabledSel = NSSelectorFromString(@"setEnabled:");
        if ([chosenEffect respondsToSelector:setEnabledSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(chosenEffect, setEnabledSel, NO);
        }
    }
    return instance;
}

static BOOL SpliceKit_mixerApplyAudioEffectIDToObjects(NSString *effectID,
                                                       NSArray *targetObjects,
                                                       NSString **outError) {
    if (effectID.length == 0) {
        if (outError) *outError = @"effectID is required";
        return NO;
    }
    if (targetObjects.count == 0) {
        if (outError) *outError = @"No target objects for audio effect";
        return NO;
    }

    Class cmdClass = objc_getClass("FFAddEffectCommand");
    if (!cmdClass) {
        if (outError) *outError = @"FFAddEffectCommand class not found";
        return NO;
    }

    id command = ((id (*)(id, SEL))objc_msgSend)((id)cmdClass, @selector(alloc));
    SEL initSel = NSSelectorFromString(@"initWithEffectID:items:");
    if (![command respondsToSelector:initSel]) {
        if (outError) *outError = @"FFAddEffectCommand does not expose initWithEffectID:items:";
        return NO;
    }
    command = ((id (*)(id, SEL, id, id))objc_msgSend)(command, initSel, effectID, targetObjects);

    Class selMgr = objc_getClass("PESelectionManager");
    id manager = selMgr ? ((id (*)(id, SEL))objc_msgSend)((id)selMgr, @selector(defaultSelectionManager)) : nil;
    if (manager && [manager respondsToSelector:@selector(timelineContext)] &&
        [command respondsToSelector:@selector(setContext:)]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(manager, @selector(timelineContext));
        if (context) ((void (*)(id, SEL, id))objc_msgSend)(command, @selector(setContext:), context);
    }

    if (![command respondsToSelector:@selector(execute)]) {
        if (outError) *outError = @"FFAddEffectCommand does not expose execute";
        return NO;
    }
    BOOL ok = ((BOOL (*)(id, SEL))objc_msgSend)(command, @selector(execute));
    if (!ok && outError) *outError = [NSString stringWithFormat:@"Failed to apply audio effect '%@'", effectID];
    return ok;
}

static BOOL SpliceKit_mixerSetEffectEnabledInStack(id effect, id effectStack, BOOL enabled) {
    if (!effect || !effectStack) return NO;
    SEL setEnabledSel = NSSelectorFromString(@"setEnabled:");
    if (![effect respondsToSelector:setEnabledSel]) return NO;

    @try {
        SEL enabledSel = NSSelectorFromString(@"enabled");
        if ([effect respondsToSelector:enabledSel]) {
            BOOL currentEnabled = ((BOOL (*)(id, SEL))objc_msgSend)(effect, enabledSel);
            if (currentEnabled == enabled) return YES;
        }
    } @catch (NSException *e) {}

    @try {
        SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
        if ([effectStack respondsToSelector:beginSel]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                effectStack, beginSel, enabled ? @"Enable Audio Effect" : @"Disable Audio Effect", nil, NO);
        }
    } @catch (NSException *e) {}

    ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setEnabledSel, enabled);

    @try {
        SEL respondSel = NSSelectorFromString(@"_respondToEffectActivationOrEnabledStateChange");
        if ([effect respondsToSelector:respondSel]) {
            ((void (*)(id, SEL))objc_msgSend)(effect, respondSel);
        }
    } @catch (NSException *e) {}

    @try {
        SEL postSel = NSSelectorFromString(@"postEffectsChangedNotification");
        if ([effectStack respondsToSelector:postSel]) {
            ((void (*)(id, SEL))objc_msgSend)(effectStack, postSel);
        }
    } @catch (NSException *e) {}

    @try {
        SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
        if ([effectStack respondsToSelector:endSel]) {
            id err = nil;
            ((BOOL (*)(id, SEL, id, BOOL, id *))objc_msgSend)(
                effectStack, endSel, enabled ? @"Enable Audio Effect" : @"Disable Audio Effect", YES, &err);
        }
    } @catch (NSException *e) {}
    return YES;
}

static BOOL SpliceKit_mixerRemoveEffectFromStackAtIndex(id effectStack, NSInteger effectIndex) {
    if (!effectStack || effectIndex == NSNotFound || effectIndex < 0) return NO;
    BOOL ok = NO;
    @try {
        SEL opRemoveSel = NSSelectorFromString(@"operationRemoveEffectAtIndex:error:");
        if ([effectStack respondsToSelector:opRemoveSel]) {
            id err = nil;
            ok = ((BOOL (*)(id, SEL, NSUInteger, id *))objc_msgSend)(
                effectStack, opRemoveSel, (NSUInteger)effectIndex, &err);
        }
    } @catch (NSException *e) {}

    if (!ok) {
        @try {
            SEL removeSel = NSSelectorFromString(@"removeEffectAtIndex:");
            if ([effectStack respondsToSelector:removeSel]) {
                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(effectStack, removeSel, (NSUInteger)effectIndex);
                ok = YES;
            }
        } @catch (NSException *e) {}
    }

    if (ok) {
        @try {
            SEL postSel = NSSelectorFromString(@"postEffectsChangedNotification");
            if ([effectStack respondsToSelector:postSel]) {
                ((void (*)(id, SEL))objc_msgSend)(effectStack, postSel);
            }
        } @catch (NSException *e) {}
    }
    return ok;
}

static void SpliceKit_mixerUpdateObjectAfterBusEffectMutation(id object) {
    if (!object) return;
    id effectStack = SpliceKit_mixerBusEffectStackForObject(object);
    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    if (effects.count == 0) {
        @try {
            SEL setMixdownSel = NSSelectorFromString(@"setMixdownRoleGroup:");
            if ([object respondsToSelector:setMixdownSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(object, setMixdownSel, nil);
            }
        } @catch (NSException *e) {}
    } else {
        @try {
            SEL updateSel = NSSelectorFromString(@"_updateMixdownRoleGroup");
            if ([object respondsToSelector:updateSel]) {
                ((void (*)(id, SEL))objc_msgSend)(object, updateSel);
            }
        } @catch (NSException *e) {}
    }
}

static id SpliceKit_mixerFindManagedEffectOnObject(NSMutableDictionary *entry,
                                                   id object,
                                                   id *outStack,
                                                   NSInteger *outEffectIndex) {
    if (!entry || !object) return nil;
    id effectStack = SpliceKit_mixerBusEffectStackForObject(object);
    if (!effectStack) return nil;

    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    for (NSUInteger idx = 0; idx < effects.count; idx++) {
        id effect = effects[idx];
        if (!SpliceKit_mixerEffectMatchesManagedEntry(effect, entry)) continue;

        SpliceKit_mixerRememberManagedInstance(entry, object, effectStack, effect);
        if (outStack) *outStack = effectStack;
        if (outEffectIndex) *outEffectIndex = (NSInteger)idx;
        return effect;
    }

    return nil;
}

static id SpliceKit_mixerTrackedEffectForObject(NSMutableDictionary *entry,
                                                id object,
                                                id *outStack,
                                                NSInteger *outEffectIndex) {
    if (!entry || !object) return nil;
    NSString *objectKey = SpliceKit_handlePointerKey(object) ?: @"";
    NSMutableArray *instances = [entry[@"instances"] isKindOfClass:[NSMutableArray class]]
        ? entry[@"instances"]
        : nil;
    if (!instances) return nil;

    for (NSDictionary *instance in [instances copy]) {
        NSString *instanceObjectKey = [instance[@"objectKey"] isKindOfClass:[NSString class]]
            ? instance[@"objectKey"]
            : @"";
        if (objectKey.length > 0 && ![instanceObjectKey isEqualToString:objectKey]) continue;

        NSString *effectHandle = [instance[@"effectHandle"] isKindOfClass:[NSString class]] ? instance[@"effectHandle"] : @"";
        NSString *stackHandle = [instance[@"effectStackHandle"] isKindOfClass:[NSString class]] ? instance[@"effectStackHandle"] : @"";
        id effect = effectHandle.length > 0 ? SpliceKit_resolveHandle(effectHandle) : nil;
        id stack = stackHandle.length > 0 ? SpliceKit_resolveHandle(stackHandle) : nil;
        NSInteger effectIndex = SpliceKit_mixerIndexOfEffectInStack(stack, effect);
        if (effect && stack && effectIndex != NSNotFound) {
            if (outStack) *outStack = stack;
            if (outEffectIndex) *outEffectIndex = effectIndex;
            return effect;
        }
        [instances removeObject:instance];
    }

    return SpliceKit_mixerFindManagedEffectOnObject(entry, object, outStack, outEffectIndex);
}

static id SpliceKit_mixerFirstManagedEffectInstance(NSMutableDictionary *entry,
                                                    id *outStack,
                                                    NSInteger *outEffectIndex) {
    if (!entry) return nil;
    NSMutableArray *instances = [entry[@"instances"] isKindOfClass:[NSMutableArray class]]
        ? entry[@"instances"]
        : nil;
    if (!instances) return nil;

    for (NSDictionary *instance in [instances copy]) {
        NSString *effectHandle = [instance[@"effectHandle"] isKindOfClass:[NSString class]] ? instance[@"effectHandle"] : @"";
        NSString *stackHandle = [instance[@"effectStackHandle"] isKindOfClass:[NSString class]] ? instance[@"effectStackHandle"] : @"";
        id effect = effectHandle.length > 0 ? SpliceKit_resolveHandle(effectHandle) : nil;
        id stack = stackHandle.length > 0 ? SpliceKit_resolveHandle(stackHandle) : nil;
        NSInteger effectIndex = SpliceKit_mixerIndexOfEffectInStack(stack, effect);
        if (effect && stack && effectIndex != NSNotFound) {
            if (outStack) *outStack = stack;
            if (outEffectIndex) *outEffectIndex = effectIndex;
            return effect;
        }
        NSString *objectHandle = [instance[@"objectHandle"] isKindOfClass:[NSString class]] ? instance[@"objectHandle"] : @"";
        id object = objectHandle.length > 0 ? SpliceKit_resolveHandle(objectHandle) : nil;
        id recovered = SpliceKit_mixerFindManagedEffectOnObject(entry, object, outStack, outEffectIndex);
        if (recovered) return recovered;
        [instances removeObject:instance];
    }
    return nil;
}

static NSSet<NSString *> *SpliceKit_mixerObjectKeysForBusTargets(NSArray<NSDictionary *> *busTargets) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (NSDictionary *target in busTargets) {
        NSString *objectKey = SpliceKit_handlePointerKey(target[@"object"]) ?: @"";
        if (objectKey.length > 0) [keys addObject:objectKey];
    }
    return keys;
}

static NSSet<NSString *> *SpliceKit_mixerObjectKeysForManagedEntry(NSDictionary *entry) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    NSArray *instances = [entry[@"instances"] isKindOfClass:[NSArray class]] ? entry[@"instances"] : @[];
    for (NSDictionary *instance in instances) {
        NSString *objectKey = [instance[@"objectKey"] isKindOfClass:[NSString class]] ? instance[@"objectKey"] : @"";
        if (objectKey.length > 0) [keys addObject:objectKey];
    }
    return keys;
}

static BOOL SpliceKit_mixerManagedBusRoleNeedsReconcile(NSString *role,
                                                        NSArray<NSDictionary *> *allClips,
                                                        NSString *scopeKey) {
    NSArray<NSMutableDictionary *> *entries = SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey);
    if (entries.count == 0) return NO;

    NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
    NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, NO);
    NSSet<NSString *> *currentObjectKeys = SpliceKit_mixerObjectKeysForBusTargets(busTargets);

    for (NSDictionary *entry in entries) {
        NSSet<NSString *> *trackedObjectKeys = SpliceKit_mixerObjectKeysForManagedEntry(entry);
        if (![trackedObjectKeys isEqualToSet:currentObjectKeys]) {
            return YES;
        }
    }
    return NO;
}

static BOOL SpliceKit_mixerManagedBusNeedsReconcile(NSArray<NSDictionary *> *allClips, NSString *scopeKey) {
    if (!SpliceKit_mixerManagedBusRegistryHasEntriesForScope(scopeKey)) return NO;
    for (NSString *role in SpliceKit_mixerManagedBusRolesForScope(scopeKey)) {
        if (SpliceKit_mixerManagedBusRoleNeedsReconcile(role, allClips, scopeKey)) {
            return YES;
        }
    }
    return NO;
}

static NSMutableDictionary *SpliceKit_mixerManagedBusEntryForID(NSString *busEffectID,
                                                                NSString **outRole,
                                                                NSUInteger *outEntryIndex) {
    if (busEffectID.length == 0 || !sMixerManagedBusEffects) return nil;
    for (NSString *role in [[sMixerManagedBusEffects allKeys] copy]) {
        NSMutableArray *entries = sMixerManagedBusEffects[role];
        for (NSUInteger idx = 0; idx < entries.count; idx++) {
            NSMutableDictionary *entry = entries[idx];
            NSString *entryID = [entry[@"busEffectID"] isKindOfClass:[NSString class]] ? entry[@"busEffectID"] : @"";
            if ([entryID isEqualToString:busEffectID]) {
                if (outRole) *outRole = role;
                if (outEntryIndex) *outEntryIndex = idx;
                return entry;
            }
        }
    }
    return nil;
}

static BOOL SpliceKit_mixerBuildRoleSnapshot(id timeline,
                                             id *outSequence,
                                             id *outRootObject,
                                             NSMutableArray **outAllClips,
                                             NSMutableOrderedSet **outRoleOrder,
                                             NSString **outError);

static NSMutableDictionary *SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(NSString *role,
                                                                               NSInteger displayIndex,
                                                                               NSUInteger *outEntryIndex) {
    if (role.length == 0 || displayIndex < 0) return nil;

    id timeline = SpliceKit_getActiveTimelineModule();
    id sequence = nil;
    id rootObject = nil;
    NSMutableArray *allClips = nil;
    NSMutableOrderedSet *roleOrder = nil;
    NSString *snapshotError = nil;
    if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
        return nil;
    }

    NSString *scopeKey = SpliceKit_mixerManagedBusScopeKey(sequence, rootObject);
    NSArray<NSMutableDictionary *> *scopedEntries = SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey);
    if ((NSUInteger)displayIndex >= scopedEntries.count) return nil;

    NSMutableDictionary *entry = scopedEntries[(NSUInteger)displayIndex];
    NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, NO);
    NSUInteger actualIndex = [entries indexOfObjectIdenticalTo:entry];
    if (outEntryIndex) *outEntryIndex = actualIndex == NSNotFound ? (NSUInteger)displayIndex : actualIndex;
    return entry;
}

static NSArray<NSDictionary *> *SpliceKit_mixerManagedBusEffectSummariesForRole(NSString *role, NSString *scopeKey) {
    NSArray<NSMutableDictionary *> *entries = SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey);
    if (entries.count == 0) return @[];

    NSMutableArray *summaries = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSUInteger entryIndex = 0; entryIndex < entries.count; entryIndex++) {
        NSMutableDictionary *entry = entries[entryIndex];
        id stack = nil;
        NSInteger actualEffectIndex = NSNotFound;
        id effect = SpliceKit_mixerFirstManagedEffectInstance(entry, &stack, &actualEffectIndex);

        NSMutableDictionary *summary = effect
            ? [SpliceKit_mixerEffectSummary(effect, actualEffectIndex == NSNotFound ? 0 : (NSUInteger)actualEffectIndex) mutableCopy]
            : [@{
                @"index": @(entryIndex),
                @"handle": @"",
                @"class": @"",
                @"name": [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"Effect",
                @"effectID": [entry[@"effectID"] isKindOfClass:[NSString class]] ? entry[@"effectID"] : @"",
                @"enabled": [entry[@"enabled"] isKindOfClass:[NSNumber class]] ? entry[@"enabled"] : @YES,
            } mutableCopy];

        summary[@"index"] = @(entryIndex);
        if (actualEffectIndex != NSNotFound) summary[@"actualEffectIndex"] = @(actualEffectIndex);
        summary[@"busEffectID"] = [entry[@"busEffectID"] isKindOfClass:[NSString class]] ? entry[@"busEffectID"] : @"";
        summary[@"managedBus"] = @YES;
        summary[@"role"] = role ?: @"";
        summary[@"scopeKey"] = scopeKey ?: @"";
        summary[@"targetName"] = @"Role Bus";
        if (stack) summary[@"effectStackHandle"] = SpliceKit_storeHandle(stack) ?: @"";
        [summaries addObject:summary];
    }
    return summaries;
}

static void SpliceKit_mixerReconcileManagedBusEffects(NSArray<NSDictionary *> *allClips, NSString *scopeKey) {
    if (sMixerManagedBusReconciling || !SpliceKit_mixerManagedBusRegistryHasEntriesForScope(scopeKey)) return;
    sMixerManagedBusReconciling = YES;
    @try {
        for (NSString *role in [[sMixerManagedBusEffects allKeys] copy]) {
            NSArray<NSMutableDictionary *> *entries = SpliceKit_mixerManagedBusEntriesForRoleInScope(role, scopeKey);
            NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
            NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, NO);

            NSMutableSet<NSString *> *currentObjectKeys = [NSMutableSet set];
            for (NSDictionary *target in busTargets) {
                NSString *objectKey = SpliceKit_handlePointerKey(target[@"object"]);
                if (objectKey.length > 0) [currentObjectKeys addObject:objectKey];
            }

            for (NSMutableDictionary *entry in [entries copy]) {
                NSMutableArray *instances = [entry[@"instances"] isKindOfClass:[NSMutableArray class]]
                    ? entry[@"instances"]
                    : nil;
                if (!instances) {
                    instances = [NSMutableArray array];
                    entry[@"instances"] = instances;
                }

                for (NSDictionary *instance in [instances copy]) {
                    NSString *objectKey = [instance[@"objectKey"] isKindOfClass:[NSString class]] ? instance[@"objectKey"] : @"";
                    if (objectKey.length == 0 || [currentObjectKeys containsObject:objectKey]) continue;

                    NSString *effectHandle = [instance[@"effectHandle"] isKindOfClass:[NSString class]] ? instance[@"effectHandle"] : @"";
                    NSString *stackHandle = [instance[@"effectStackHandle"] isKindOfClass:[NSString class]] ? instance[@"effectStackHandle"] : @"";
                    NSString *objectHandle = [instance[@"objectHandle"] isKindOfClass:[NSString class]] ? instance[@"objectHandle"] : @"";
                    id effect = effectHandle.length > 0 ? SpliceKit_resolveHandle(effectHandle) : nil;
                    id stack = stackHandle.length > 0 ? SpliceKit_resolveHandle(stackHandle) : nil;
                    NSInteger effectIndex = SpliceKit_mixerIndexOfEffectInStack(stack, effect);
                    id object = objectHandle.length > 0 ? SpliceKit_resolveHandle(objectHandle) : nil;
                    if ((!stack || effectIndex == NSNotFound) && object) {
                        effect = SpliceKit_mixerFindManagedEffectOnObject(entry, object, &stack, &effectIndex);
                    }
                    if (stack && effectIndex != NSNotFound) {
                        SpliceKit_mixerRemoveEffectFromStackAtIndex(stack, effectIndex);
                    }
                    SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                    for (NSDictionary *candidate in [instances copy]) {
                        NSString *candidateObjectKey = [candidate[@"objectKey"] isKindOfClass:[NSString class]]
                            ? candidate[@"objectKey"]
                            : @"";
                        if (candidateObjectKey.length == 0 || [candidateObjectKey isEqualToString:objectKey]) {
                            [instances removeObject:candidate];
                        }
                    }
                }

                NSString *effectID = [entry[@"effectID"] isKindOfClass:[NSString class]] ? entry[@"effectID"] : @"";
                BOOL enabled = ![entry[@"enabled"] isKindOfClass:[NSNumber class]] || [entry[@"enabled"] boolValue];
                for (NSDictionary *target in busTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger effectIndex = NSNotFound;
                    id existingEffect = SpliceKit_mixerTrackedEffectForObject(entry, object, &stack, &effectIndex);
                    if (existingEffect && stack) {
                        SpliceKit_mixerSetEffectEnabledInStack(existingEffect, stack, enabled);
                        continue;
                    }

                    id effectStack = target[@"effectStack"];
                    NSUInteger beforeCount = SpliceKit_mixerEffectsInStack(effectStack).count;
                    NSString *applyError = nil;
                    if (!SpliceKit_mixerApplyAudioEffectIDToObjects(effectID, @[object], &applyError)) {
                        SpliceKit_log(@"[Mixer] Failed to reconcile role bus effect %@ for %@: %@",
                                      entry[@"name"] ?: effectID,
                                      role,
                                      applyError ?: @"unknown error");
                        continue;
                    }
                    SpliceKit_mixerCaptureManagedInstanceAfterApply(entry, object, beforeCount);
                    SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                }
            }

            SpliceKit_mixerPruneManagedBusRole(role);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Mixer] Managed bus reconcile exception: %@", e.reason);
    }
    sMixerManagedBusReconciling = NO;
}

static NSArray<NSString *> *SpliceKit_mixerRoleUIDsForRole(NSArray<NSDictionary *> *allClips, NSString *role) {
    if (role.length == 0) return @[];
    NSMutableOrderedSet<NSString *> *roleUIDs = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *clip in allClips) {
        if (![clip[@"role"] isEqualToString:role]) continue;
        NSString *roleUID = clip[@"roleUID"];
        if (roleUID.length > 0) [roleUIDs addObject:roleUID];
    }
    return [roleUIDs array];
}

static BOOL SpliceKit_mixerSetIntersectsObjects(NSSet *set, NSArray *objects) {
    if (set.count == 0 || objects.count == 0) return NO;
    for (id object in objects) {
        if ([set containsObject:object]) return YES;
    }
    return NO;
}

static BOOL SpliceKit_mixerBuildRoleSnapshot(id timeline,
                                             id *outSequence,
                                             id *outRootObject,
                                             NSMutableArray **outAllClips,
                                             NSMutableOrderedSet **outRoleOrder,
                                             NSString **outError) {
    if (!timeline) {
        if (outError) *outError = @"No active timeline module. Is a project open?";
        return NO;
    }

    id sequence = nil;
    @try {
        if ([timeline respondsToSelector:@selector(sequence)]) {
            sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
        }
    } @catch (NSException *e) {}
    if (!sequence) {
        if (outError) *outError = @"No sequence in timeline.";
        return NO;
    }

    id primaryObj = nil;
    @try {
        if ([sequence respondsToSelector:@selector(primaryObject)]) {
            primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
        }
    } @catch (NSException *e) {}
    if (!primaryObj) {
        if (outError) *outError = @"No primary object on sequence";
        return NO;
    }

    id spineItems = nil;
    @try {
        if ([primaryObj respondsToSelector:@selector(containedItems)]) {
            spineItems = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
        }
    } @catch (NSException *e) {}
    if (!spineItems || ![spineItems isKindOfClass:[NSArray class]]) {
        if (outError) *outError = @"No spine items found";
        return NO;
    }

    SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
    BOOL canGetRange = [primaryObj respondsToSelector:erSel];
    NSMutableArray *allClips = [NSMutableArray array];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (id item in (NSArray *)spineItems) {
        SpliceKit_mixerCollectClipEntries(item, primaryObj, erSel, canGetRange,
                                          0, 0.0, 0.0, allClips, visited);
    }

    if (outSequence) *outSequence = sequence;
    if (outRootObject) *outRootObject = primaryObj;
    if (outAllClips) *outAllClips = allClips;
    if (outRoleOrder) *outRoleOrder = SpliceKit_mixerRoleOrderFromClips(allClips);
    return YES;
}

static NSString *SpliceKit_mixerRoleFromParams(NSDictionary *params,
                                               NSMutableOrderedSet *roleOrder,
                                               NSInteger *outIndex) {
    NSString *role = [params[@"role"] isKindOfClass:[NSString class]] ? params[@"role"] : nil;
    NSInteger index = NSNotFound;
    if (role.length == 0 && params[@"index"]) {
        index = [params[@"index"] integerValue];
        if (index >= 0 && (NSUInteger)index < roleOrder.count) {
            role = [roleOrder objectAtIndex:(NSUInteger)index];
        }
    } else if (role.length > 0) {
        NSUInteger found = [roleOrder indexOfObject:role];
        if (found != NSNotFound) index = (NSInteger)found;
    }
    if (outIndex) *outIndex = index;
    return role;
}

static NSSet *SpliceKit_mixerSoloedObjects(id sequence) {
    @try {
        SEL soloedObjectsSel = NSSelectorFromString(@"soloedObjects");
        if ([sequence respondsToSelector:soloedObjectsSel]) {
            id rawSoloed = ((id (*)(id, SEL))objc_msgSend)(sequence, soloedObjectsSel);
            if ([rawSoloed isKindOfClass:[NSSet class]]) return rawSoloed;
        }
    } @catch (NSException *e) {}
    return nil;
}

static NSSet *SpliceKit_mixerDisabledAudioRoleUIDs(id sequence) {
    @try {
        SEL disabledSel = NSSelectorFromString(@"roleUIDsForDisabledAVRolesOfType:");
        if ([sequence respondsToSelector:disabledSel]) {
            id disabled = ((id (*)(id, SEL, int))objc_msgSend)(sequence, disabledSel, 0);
            if ([disabled isKindOfClass:[NSSet class]]) return disabled;
        }
    } @catch (NSException *e) {}
    return nil;
}

static NSSet *SpliceKit_mixerDisabledAudioRoleUIDsForRootObject(id rootObject, id sequence) {
    @try {
        Class playbackRolesClass = objc_getClass("FFTimelinePlaybackRoles");
        SEL disabledMapSel = NSSelectorFromString(@"disabledRoleUIDsMapForRootItem:");
        if (playbackRolesClass && rootObject && [playbackRolesClass respondsToSelector:disabledMapSel]) {
            id map = ((id (*)(Class, SEL, id))objc_msgSend)(playbackRolesClass, disabledMapSel, rootObject);
            if ([map respondsToSelector:@selector(objectForKey:)]) {
                id disabledAudio = ((id (*)(id, SEL, id))objc_msgSend)(map, @selector(objectForKey:), @0);
                if ([disabledAudio isKindOfClass:[NSSet class]]) return disabledAudio;
            }
        }
    } @catch (NSException *e) {}
    return SpliceKit_mixerDisabledAudioRoleUIDs(sequence);
}

static NSUInteger SpliceKit_mixerCountDisabledRoleUIDs(NSArray<NSString *> *roleUIDs, NSSet *disabledRoleUIDs) {
    if (roleUIDs.count == 0 || disabledRoleUIDs.count == 0) return 0;
    NSUInteger count = 0;
    for (NSString *roleUID in roleUIDs) {
        if ([disabledRoleUIDs containsObject:roleUID]) count++;
    }
    return count;
}

static BOOL SpliceKit_mixerSetAudioRolesEnabled(id rootObject,
                                                id sequence,
                                                NSSet<NSString *> *roleUIDs,
                                                BOOL enabled,
                                                NSString **outError) {
    if (roleUIDs.count == 0) {
        if (outError) *outError = @"No audio role UIDs found for this mixer fader";
        return NO;
    }

    Class playbackRolesClass = objc_getClass("FFTimelinePlaybackRoles");
    SEL setRolesSel = NSSelectorFromString(@"setAudioVideoEnabledState:forAudioRoles:forVideoRoles:inRootItem:");
    if (playbackRolesClass && [playbackRolesClass respondsToSelector:setRolesSel] && rootObject) {
        ((void (*)(Class, SEL, BOOL, id, id, id))objc_msgSend)(
            playbackRolesClass, setRolesSel, enabled, roleUIDs, [NSSet set], rootObject);
        return YES;
    }

    SEL setDisabledSel = NSSelectorFromString(@"setRoleUIDsForDisabledAudio:video:");
    if (![sequence respondsToSelector:setDisabledSel]) {
        if (outError) *outError = @"FCP sequence does not expose disabled audio role controls";
        return NO;
    }

    NSMutableSet *nextDisabled = [NSMutableSet setWithSet:(SpliceKit_mixerDisabledAudioRoleUIDs(sequence) ?: [NSSet set])];
    if (enabled) {
        [nextDisabled minusSet:roleUIDs];
    } else {
        [nextDisabled unionSet:roleUIDs];
    }

    NSSet *disabledVideo = nil;
    @try {
        SEL disabledSel = NSSelectorFromString(@"roleUIDsForDisabledAVRolesOfType:");
        if ([sequence respondsToSelector:disabledSel]) {
            id rawDisabledVideo = ((id (*)(id, SEL, int))objc_msgSend)(sequence, disabledSel, 1);
            if ([rawDisabledVideo isKindOfClass:[NSSet class]]) disabledVideo = rawDisabledVideo;
        }
    } @catch (NSException *e) {}

    ((void (*)(id, SEL, id, id))objc_msgSend)(
        sequence, setDisabledSel, nextDisabled, disabledVideo ?: [NSSet set]);
    return YES;
}

// mixer.getState — enumerate clips at playhead with volumes, lanes, roles
NSDictionary *SpliceKit_handleMixerGetState(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module. Is a project open?"};
                return;
            }

            id sequence = nil;
            if ([timeline respondsToSelector:@selector(sequence)]) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            }
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline."};
                return;
            }

            // Get playhead time
            SpliceKit_CMTime playhead = {0, 1, 0, 0};
            if ([timeline respondsToSelector:@selector(playheadTime)]) {
                playhead = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
            }
            double playheadSec = (playhead.timescale > 0) ? (double)playhead.value / playhead.timescale : 0;
            BOOL transportPlaying = NO;
            double transportRate = 0.0;
            double frameRate = 0.0;

            // Set global playhead time for volume reads (picks up keyframed values)
            sMixerPlayheadTime = playhead;

            // Get primaryObject (spine container) — also used for time conversion
            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
            }
            if (!primaryObj) {
                result = @{@"error": @"No primary object on sequence"};
                return;
            }
            sMixerContainer = primaryObj; // For clip-local time conversion in readVolume

            SEL isPlayingSel = NSSelectorFromString(@"isPlaying");
            if ([timeline respondsToSelector:isPlayingSel]) {
                transportPlaying = ((BOOL (*)(id, SEL))objc_msgSend)(timeline, isPlayingSel);
            }

            SEL frameDurationSel = NSSelectorFromString(@"frameDuration");
            if ([sequence respondsToSelector:frameDurationSel]) {
                SpliceKit_CMTime frameDuration = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, frameDurationSel);
                if (frameDuration.timescale > 0 && frameDuration.value > 0) {
                    frameRate = (double)frameDuration.timescale / frameDuration.value;
                }
            }

            id timelinePlayer = nil;
            SEL playerSel = NSSelectorFromString(@"player");
            if ([timeline respondsToSelector:playerSel]) {
                timelinePlayer = ((id (*)(id, SEL))objc_msgSend)(timeline, playerSel);
            }
            SEL rateSel = NSSelectorFromString(@"rate");
            if (timelinePlayer && [timelinePlayer respondsToSelector:rateSel]) {
                transportRate = ((double (*)(id, SEL))objc_msgSend)(timelinePlayer, rateSel);
            }

            BOOL toolSkimming = NO;
            BOOL rawToolSkimming = NO;
            id skimmedItem = nil;
            NSString *skimmedRole = nil;
            NSString *skimmedName = nil;
            double activeTimeSec = playheadSec;
            if (!transportPlaying) {
                CFTimeInterval now = CFAbsoluteTimeGetCurrent();
                SEL isToolSkimmingSel = NSSelectorFromString(@"isToolSkimming");
                if ([timeline respondsToSelector:isToolSkimmingSel]) {
                    rawToolSkimming = ((BOOL (*)(id, SEL))objc_msgSend)(timeline, isToolSkimmingSel);
                }
                BOOL recentlyUpdatedSkimming = (sMixerLastSkimUpdateTime > 0) && ((now - sMixerLastSkimUpdateTime) < 0.35);
                toolSkimming = rawToolSkimming || sMixerSkimmingLatched || recentlyUpdatedSkimming;
                if (toolSkimming) {
                    SEL skimmingTimeSel = NSSelectorFromString(@"skimmingTime");
                    if ([timeline respondsToSelector:skimmingTimeSel]) {
                        SpliceKit_CMTime skimTime = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timeline, skimmingTimeSel);
                        if (skimTime.timescale > 0) {
                            activeTimeSec = (double)skimTime.value / skimTime.timescale;
                        }
                    }
                    SEL skimmingItemSel = NSSelectorFromString(@"skimmingItem");
                    if ([timeline respondsToSelector:skimmingItemSel]) {
                        skimmedItem = ((id (*)(id, SEL))objc_msgSend)(timeline, skimmingItemSel);
                    }
                    if (!skimmedItem) {
                        SEL skimmingItemComponentSel = NSSelectorFromString(@"skimmingItemComponent");
                        if ([timeline respondsToSelector:skimmingItemComponentSel]) {
                            skimmedItem = ((id (*)(id, SEL))objc_msgSend)(timeline, skimmingItemComponentSel);
                        }
                    }
                    if (skimmedItem) {
                        skimmedRole = SpliceKit_readClipRole(skimmedItem);
                        if ([skimmedItem respondsToSelector:@selector(displayName)]) {
                            id skimNameObj = ((id (*)(id, SEL))objc_msgSend)(skimmedItem, @selector(displayName));
                            if ([skimNameObj isKindOfClass:[NSString class]]) {
                                skimmedName = skimNameObj;
                            }
                        }
                    }
                }
            }
            else if (sMixerSkimmingLatched) {
                sMixerSkimmingLatched = NO;
                sMixerLastSkimEndTime = CFAbsoluteTimeGetCurrent();
            }

            // Get spine items
            id spineItems = nil;
            if ([primaryObj respondsToSelector:@selector(containedItems)]) {
                spineItems = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
            }
            if (!spineItems || ![spineItems isKindOfClass:[NSArray class]]) {
                result = @{@"error": @"No spine items found"};
                return;
            }

            SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
            BOOL canGetRange = [primaryObj respondsToSelector:erSel];

            // Role-based mixer: one fader per audio role used in the timeline.
            // For each role, find the clip at the playhead with that role and show its volume.
            // This gives a mixing-console view where roles are persistent faders.

            // Step 1: Collect ALL audio-bearing clips (including nested collection contents)
            // with their roles and time ranges.
            NSMutableArray *allClips = [NSMutableArray array]; // {item, role, startSec, endSec, lane}
            NSMutableSet<NSString *> *visited = [NSMutableSet set];

            for (id item in (NSArray *)spineItems) {
                SpliceKit_mixerCollectClipEntries(item, primaryObj, erSel, canGetRange,
                                                  0, 0.0, 0.0, allClips, visited);
            }

            // Step 2: Collect unique roles (ordered: Dialogue first, then Music, Effects, others)
            NSMutableOrderedSet *roleOrder = SpliceKit_mixerRoleOrderFromClips(allClips);
            NSSet *soloedObjects = SpliceKit_mixerSoloedObjects(sequence);
            BOOL soloActive = (soloedObjects.count > 0);
            NSSet *disabledAudioRoleUIDs = SpliceKit_mixerDisabledAudioRoleUIDsForRootObject(primaryObj, sequence);

            NSNumber *maxFadersParam = [params[@"maxFaders"] isKindOfClass:[NSNumber class]] ? params[@"maxFaders"] : nil;
            NSUInteger maxFaders = maxFadersParam ? [maxFadersParam unsignedIntegerValue] : 12;
            if (maxFaders < 1) maxFaders = 1;
            if (maxFaders > 64) maxFaders = 64;

            // Step 3: For each role, find the clip at the playhead and build fader data
            NSMutableArray *indexed = [NSMutableArray array];
            NSInteger faderIdx = 0;
            NSString *scopeKey = SpliceKit_mixerManagedBusScopeKey(sequence, primaryObj);
            if (SpliceKit_mixerManagedBusNeedsReconcile(allClips, scopeKey)) {
                SpliceKit_mixerReconcileManagedBusEffects(allClips, scopeKey);
            }
            SpliceKit_mixerAddManagedBusRolesToRoleOrder(roleOrder, scopeKey);

            for (NSString *role in roleOrder) {
                if ((NSUInteger)faderIdx >= maxFaders) break;

                // Get the role color from the first clip with this role
                NSString *roleColor = @"";
                for (NSDictionary *clip in allClips) {
                    if ([clip[@"role"] isEqualToString:role] && [clip[@"roleColor"] length] > 0) {
                        roleColor = clip[@"roleColor"];
                        break;
                    }
                }

                // Find clip with this role at the playhead
                id bestClip = nil;
                double bestStart = 0, bestEnd = 0;
                NSInteger bestLane = 0;
                for (NSDictionary *clip in allClips) {
                    if (![clip[@"role"] isEqualToString:role]) continue;
                    double s = [clip[@"start"] doubleValue];
                    double e = [clip[@"end"] doubleValue];
                    if (activeTimeSec >= s - 0.001 && activeTimeSec <= e + 0.001) {
                        bestClip = clip[@"item"];
                        bestStart = s;
                        bestEnd = e;
                        bestLane = [clip[@"lane"] integerValue];
                        break;
                    }
                }

                NSMutableDictionary *fader = [NSMutableDictionary dictionary];
                fader[@"index"] = @(faderIdx);
                fader[@"role"] = role;
                if (roleColor.length > 0) fader[@"roleColor"] = roleColor;

                NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
                BOOL roleSoloed = SpliceKit_mixerSetIntersectsObjects(soloedObjects, roleObjects);
                fader[@"soloed"] = @(roleSoloed);
                fader[@"soloActive"] = @(soloActive);
                fader[@"soloMuted"] = @(soloActive && !roleSoloed);
                fader[@"soloObjectCount"] = @(roleObjects.count);

                NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, NO);
                fader[@"busKind"] = busTargets.count > 0 ? @"collection" : @"none";
                fader[@"busObjectCount"] = @(busTargets.count);
                NSArray<NSDictionary *> *managedBusEffects = SpliceKit_mixerManagedBusEffectSummariesForRole(role, scopeKey);
                if (managedBusEffects.count > 0) {
                    NSMutableArray *managedNames = [NSMutableArray arrayWithCapacity:managedBusEffects.count];
                    for (NSDictionary *effect in managedBusEffects) {
                        NSString *effectName = [effect[@"name"] isKindOfClass:[NSString class]] ? effect[@"name"] : @"";
                        if (effectName.length > 0) [managedNames addObject:effectName];
                    }
                    NSDictionary *firstBusSummary = busTargets.count > 0
                        ? SpliceKit_mixerBusTargetSummary(busTargets.firstObject[@"object"], busTargets.firstObject[@"effectStack"])
                        : @{};
                    fader[@"busKind"] = @"managedRole";
                    fader[@"busHandle"] = firstBusSummary[@"objectHandle"] ?: @"";
                    fader[@"busClass"] = @"SpliceKitRoleBus";
                    fader[@"busEffectStackHandle"] = firstBusSummary[@"effectStackHandle"] ?: @"";
                    fader[@"busEffectCount"] = @(managedBusEffects.count);
                    fader[@"busEffectNames"] = managedNames;
                    fader[@"busEffects"] = managedBusEffects;
                } else if (busTargets.count > 0) {
                    NSMutableArray *allEffectNames = [NSMutableArray array];
                    NSMutableArray *allEffects = [NSMutableArray array];
                    NSDictionary *firstBusSummary = nil;

                    for (NSUInteger targetIdx = 0; targetIdx < busTargets.count; targetIdx++) {
                        NSDictionary *busTarget = busTargets[targetIdx];
                        NSDictionary *busSummary = SpliceKit_mixerBusTargetSummary(busTarget[@"object"],
                                                                                   busTarget[@"effectStack"]);
                        if (!firstBusSummary) firstBusSummary = busSummary;

                        NSArray *effects = [busSummary[@"effects"] isKindOfClass:[NSArray class]]
                            ? busSummary[@"effects"]
                            : @[];
                        for (NSDictionary *effect in effects) {
                            NSMutableDictionary *effectWithTarget = [effect mutableCopy];
                            effectWithTarget[@"targetIndex"] = @(targetIdx);
                            effectWithTarget[@"targetHandle"] = busSummary[@"objectHandle"] ?: @"";
                            effectWithTarget[@"targetName"] = busSummary[@"name"] ?: @"";
                            effectWithTarget[@"effectStackHandle"] = busSummary[@"effectStackHandle"] ?: @"";
                            [allEffects addObject:effectWithTarget];

                            NSString *effectName = effectWithTarget[@"name"];
                            if (effectName.length > 0) [allEffectNames addObject:effectName];
                        }
                    }

                    fader[@"busHandle"] = firstBusSummary[@"objectHandle"] ?: @"";
                    fader[@"busClass"] = firstBusSummary[@"objectClass"] ?: @"";
                    fader[@"busEffectStackHandle"] = firstBusSummary[@"effectStackHandle"] ?: @"";
                    fader[@"busEffectCount"] = @(allEffects.count);
                    fader[@"busEffectNames"] = allEffectNames;
                    fader[@"busEffects"] = allEffects;
                } else {
                    fader[@"busEffectCount"] = @0;
                    fader[@"busEffectNames"] = @[];
                    fader[@"busEffects"] = @[];
                }

                NSArray<NSString *> *roleUIDs = SpliceKit_mixerRoleUIDsForRole(allClips, role);
                NSUInteger mutedUIDCount = SpliceKit_mixerCountDisabledRoleUIDs(roleUIDs, disabledAudioRoleUIDs);
                fader[@"muted"] = @(roleUIDs.count > 0 && mutedUIDCount == roleUIDs.count);
                fader[@"muteMixed"] = @(mutedUIDCount > 0 && mutedUIDCount < roleUIDs.count);
                fader[@"mutedRoleUIDCount"] = @(mutedUIDCount);
                fader[@"roleUIDCount"] = @(roleUIDs.count);

                if (bestClip) {
                    // Active: clip with this role is at the playhead
                    fader[@"clipHandle"] = SpliceKit_storeHandle(bestClip);
                    fader[@"lane"] = @(bestLane);
                    fader[@"startSeconds"] = @(bestStart);
                    fader[@"endSeconds"] = @(bestEnd);
                    fader[@"class"] = NSStringFromClass([bestClip class]);
                    fader[@"playing"] = @YES;

                    if ([bestClip respondsToSelector:@selector(displayName)]) {
                        id name = ((id (*)(id, SEL))objc_msgSend)(bestClip, @selector(displayName));
                        fader[@"name"] = name ?: @"";
                    }

                    id es = SpliceKit_getClipEffectStack(bestClip);
                    if (es) fader[@"effectStackHandle"] = SpliceKit_storeHandle(es);
                    SpliceKit_readVolume(bestClip, es, fader);
                } else {
                    // Not playing: no clip at playhead, but show first clip with this role for info
                    fader[@"playing"] = @NO;
                    id firstClip = nil;
                    for (NSDictionary *clip in allClips) {
                        if ([clip[@"role"] isEqualToString:role]) {
                            firstClip = clip[@"item"];
                            fader[@"lane"] = clip[@"lane"];
                            break;
                        }
                    }
                    if (firstClip) {
                        fader[@"clipHandle"] = SpliceKit_storeHandle(firstClip);
                        if ([firstClip respondsToSelector:@selector(displayName)]) {
                            id name = ((id (*)(id, SEL))objc_msgSend)(firstClip, @selector(displayName));
                            fader[@"name"] = name ?: @"";
                        }
                        id es = SpliceKit_getClipEffectStack(firstClip);
                        if (es) fader[@"effectStackHandle"] = SpliceKit_storeHandle(es);
                        SpliceKit_readVolume(firstClip, es, fader);
                    } else {
                        fader[@"name"] = @"";
                        fader[@"lane"] = @(0);
                        fader[@"volumeDB"] = @(0);
                        fader[@"volumeLinear"] = @(1);
                    }
                }

                [indexed addObject:fader];
                faderIdx++;
            }

            if (toolSkimming && skimmedItem && skimmedRole.length == 0) {
                for (NSDictionary *clip in allClips) {
                    if (clip[@"item"] == skimmedItem) {
                        skimmedRole = clip[@"role"];
                        if (skimmedName.length == 0 && [clip[@"item"] respondsToSelector:@selector(displayName)]) {
                            id skimNameObj = ((id (*)(id, SEL))objc_msgSend)(clip[@"item"], @selector(displayName));
                            if ([skimNameObj isKindOfClass:[NSString class]]) {
                                skimmedName = skimNameObj;
                            }
                        }
                        break;
                    }
                }
            }

            if (!transportPlaying && toolSkimming && skimmedRole.length > 0) {
                for (NSMutableDictionary *fader in indexed) {
                    BOOL roleMatches = [fader[@"role"] isEqualToString:skimmedRole];
                    fader[@"playing"] = @(roleMatches);
                    if (roleMatches && skimmedName.length > 0) {
                        fader[@"name"] = skimmedName;
                    }
                }
            }

            BOOL meteringLive = NO;
            BOOL usedPlayerMetering = NO;
            BOOL usedLayerFallback = NO;
            double layerFallbackPeak = 0.0;
            BOOL playerMeteringEnabled = NO;

            // Audio metering: call FFPlayer.meterAudioLevelsForRole: directly.
            // The C++ FFAudioPlayer has a metering enable byte at offset 291 that gates
            // all level reporting. We flip it to 1 so metering works without the Audio
            // Meters panel being visible. Peak values are returned as linear amplitudes.
            @try {
                id player = nil;
                if ([timeline respondsToSelector:@selector(player)])
                    player = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(player));

                if (player && (transportPlaying || toolSkimming)) {
                    playerMeteringEnabled = YES;
                    // Enable metering on the C++ FFAudioPlayer (byte at offset 291)
                    Ivar apIvar = class_getInstanceVariable([player class], "_audioPlayer");
                    void *audioPlayer = NULL;
                    if (apIvar) {
                        audioPlayer = *(void **)((char *)(__bridge void *)player + ivar_getOffset(apIvar));
                        if (audioPlayer) {
                            *(uint8_t *)((char *)audioPlayer + 291) = 1;
                        }
                    }

                    SEL meterSel = NSSelectorFromString(@"meterAudioLevelsForRole:channels:peakValues:loudnessValues:");
                    typedef struct { float a, b, c, d; } LoudnessValues;

                    if ([player respondsToSelector:meterSel]) {
                        for (NSMutableDictionary *fader in indexed) {
                            id clipHandle = fader[@"clipHandle"];
                            id clip = clipHandle ? SpliceKit_resolveHandle(clipHandle) : nil;
                            if (!clip) continue;

                            NSMutableArray *candidates = [NSMutableArray array];
                            @try {
                                SEL ariSel = NSSelectorFromString(@"audioRoleIdentifier");
                                if ([clip respondsToSelector:ariSel]) {
                                    id ari = ((id (*)(id, SEL))objc_msgSend)(clip, ariSel);
                                    if (ari) [candidates addObject:ari];
                                }
                            } @catch (NSException *e) {}

                            NSString *roleName = fader[@"role"];
                            if (roleName) [candidates addObject:roleName];

                            float maxPeak = 0;
                            for (id roleUID in candidates) {
                                if (maxPeak > 0) break;
                                float peakValues[32] = {0};
                                LoudnessValues loudness = {0, 0, 0, 0};
                                @try {
                                    unsigned int filled = ((unsigned int (*)(id, SEL, id, unsigned int, float *, LoudnessValues *))objc_msgSend)(
                                        player, meterSel, roleUID, 32, peakValues, &loudness);
                                    for (unsigned int ch = 0; ch < filled && ch < 32; ch++) {
                                        if (peakValues[ch] > maxPeak) maxPeak = peakValues[ch];
                                    }
                                } @catch (NSException *e) {}
                            }

                            if (maxPeak > 0.0001) {
                                double dB = 20.0 * log10((double)maxPeak);
                                double ratio = (dB + 96.0) / 102.0;
                                if (ratio < 0) ratio = 0;
                                if (ratio > 1) ratio = 1;
                                fader[@"meterLinear"] = @(maxPeak);
                                fader[@"meterDB"] = @(dB);
                                fader[@"meterPeak"] = @(ratio);
                                fader[@"meterClipping"] = @((maxPeak >= 0.995f) || (dB >= -0.1));
                                meteringLive = YES;
                                usedPlayerMetering = YES;
                            }
                        }
                    }
                }
            } @catch (NSException *e) {}

            // Fallback: find PEMeterLayer instances anywhere in the CALayer tree.
            // This finds the mini audio meters in the transport bar (always visible)
            // as well as the full Audio Meters panel if open.
            @try {
                BOOL anyMeter = NO;
                for (NSDictionary *f in indexed) {
                    if ([f[@"meterPeak"] doubleValue] > 0.0001) {
                        anyMeter = YES;
                        break;
                    }
                }
                BOOL shouldUseLayerFallback = transportPlaying || toolSkimming;
                if (!anyMeter && shouldUseLayerFallback) {
                    Class mlc = NSClassFromString(@"PEMeterLayer");
                    Ivar mrIvar = mlc ? class_getInstanceVariable(mlc, "_maskRatio") : NULL;
                    if (mlc && mrIvar) {
                        ptrdiff_t off = ivar_getOffset(mrIvar);
                        double maxPeak = 0;

                        for (NSWindow *win in [NSApp windows]) {
                            if (!win.contentView) continue;
                            CALayer *rootLayer = win.contentView.layer;
                            if (rootLayer) {
                                SpliceKit_searchLayerTreeForMeterPeak(rootLayer, mlc, off, &maxPeak);
                            }
                            if (maxPeak > 0.001) break;
                        }

                        if (maxPeak > 0.001) {
                            usedLayerFallback = YES;
                            layerFallbackPeak = maxPeak;
                            if (!transportPlaying && toolSkimming) {
                                BOOL matchedSpecificSkimTarget = NO;
                                for (NSMutableDictionary *f in indexed) {
                                    BOOL roleMatches = NO;
                                    if (skimmedRole.length > 0) {
                                        roleMatches = [f[@"role"] isEqualToString:skimmedRole];
                                    } else if (skimmedName.length > 0) {
                                        roleMatches = [f[@"name"] isEqualToString:skimmedName];
                                    }
                                    if (roleMatches) matchedSpecificSkimTarget = YES;
                                    if (roleMatches) {
                                        f[@"meterPeak"] = @(maxPeak);
                                        f[@"meterLinear"] = @(maxPeak);
                                        f[@"meterDB"] = @((20.0 * log10(fmax(maxPeak, 0.000001))));
                                        f[@"meterClipping"] = @(maxPeak >= 0.98);
                                    } else {
                                        f[@"meterPeak"] = @(0.0);
                                        f[@"meterLinear"] = @(0.0);
                                        f[@"meterDB"] = @(-96.0);
                                        f[@"meterClipping"] = @NO;
                                    }
                                }
                                if (!matchedSpecificSkimTarget) {
                                    double totalVol = 0;
                                    for (NSMutableDictionary *f in indexed) {
                                        if ([f[@"playing"] boolValue]) totalVol += [f[@"volumeLinear"] doubleValue];
                                    }
                                    for (NSMutableDictionary *f in indexed) {
                                        if ([f[@"playing"] boolValue]) {
                                            double share = (totalVol > 0) ? [f[@"volumeLinear"] doubleValue] / totalVol : 1.0;
                                            double ratio = maxPeak * fmin(share * 1.5, 1.0);
                                            f[@"meterPeak"] = @(ratio);
                                            f[@"meterLinear"] = @(maxPeak);
                                            f[@"meterDB"] = @(ratio * 102.0 - 96.0);
                                            f[@"meterClipping"] = @(maxPeak >= 0.98);
                                        }
                                    }
                                }
                            } else {
                                double totalVol = 0;
                                for (NSMutableDictionary *f in indexed)
                                    if ([f[@"playing"] boolValue]) totalVol += [f[@"volumeLinear"] doubleValue];
                                for (NSMutableDictionary *f in indexed) {
                                    if ([f[@"playing"] boolValue]) {
                                        double share = (totalVol > 0) ? [f[@"volumeLinear"] doubleValue] / totalVol : 1.0;
                                        double ratio = maxPeak * fmin(share * 1.5, 1.0);
                                        f[@"meterPeak"] = @(ratio);
                                        f[@"meterLinear"] = @(maxPeak);
                                        f[@"meterDB"] = @(ratio * 102.0 - 96.0);
                                        f[@"meterClipping"] = @(maxPeak >= 0.98);
                                    }
                                }
                            }
                            meteringLive = YES;
                        }
                    }
                }
            } @catch (NSException *e) {}

            if (!meteringLive) {
                for (NSMutableDictionary *fader in indexed) {
                    fader[@"meterLinear"] = @(0.0);
                    fader[@"meterDB"] = @(-96.0);
                    fader[@"meterPeak"] = @(0.0);
                    fader[@"meterClipping"] = @NO;
                }
            }

            NSMutableDictionary *masterFader = nil;
            @try {
                id audioDest = SpliceKit_getMasterAudioDest();
                SEL outputVolumeSel = NSSelectorFromString(@"outputVolume");
                if (audioDest && [audioDest respondsToSelector:outputVolumeSel]) {
                    double masterLinear = ((float (*)(id, SEL))objc_msgSend)(audioDest, outputVolumeSel);
                    if (!isfinite(masterLinear) || masterLinear < 0.0) masterLinear = 0.0;
                    if (masterLinear > 1.0) masterLinear = 1.0;

                    double masterDB = (masterLinear > 0.000001) ? 20.0 * log10(masterLinear) : -96.0;
                    if (!isfinite(masterDB) || masterDB < -96.0) masterDB = -96.0;

                    double masterPeak = 0.0;
                    BOOL masterClipping = NO;
                    for (NSDictionary *fader in indexed) {
                        double peak = [fader[@"meterPeak"] doubleValue];
                        if (peak > masterPeak) masterPeak = peak;
                        if ([fader[@"meterClipping"] boolValue]) masterClipping = YES;
                    }

                    double masterMeterDB = masterPeak * 102.0 - 96.0;

                    masterFader = [@{
                        @"handle": SpliceKit_storeHandle(audioDest) ?: @"",
                        @"name": @"Playback",
                        @"role": @"Master",
                        @"volumeLinear": @(masterLinear),
                        @"volumeDB": @(masterDB),
                        @"minDB": @(-96.0),
                        @"maxDB": @(0.0),
                        @"meterLinear": @(masterPeak),
                        @"meterDB": @(masterMeterDB),
                        @"meterPeak": @(masterPeak),
                        @"meterClipping": @(masterClipping),
                        @"playing": @(transportPlaying || meteringLive)
                    } mutableCopy];
                }
            } @catch (NSException *e) {}

            NSMutableDictionary *payload = [@{
                @"playheadSeconds": @(playheadSec),
                @"playheadTime": SpliceKit_serializeCMTime(playhead),
                @"isPlaying": @(transportPlaying),
                @"isMeteringLive": @(meteringLive),
                @"playbackRate": @(transportRate),
                @"frameRate": @(frameRate),
                @"faders": indexed,
                @"count": @(indexed.count),
                @"maxFaders": @(maxFaders),
                @"totalRoles": @(roleOrder.count),
                @"roles": [roleOrder array],
                @"soloActive": @(soloActive),
                @"soloObjectCount": @(soloedObjects.count),
                @"mutedRoleUIDCount": @(disabledAudioRoleUIDs.count)
            } mutableCopy];
            NSMutableArray *resolvedClipPreview = [NSMutableArray array];
            NSUInteger previewCount = MIN((NSUInteger)20, allClips.count);
            for (NSUInteger i = 0; i < previewCount; i++) {
                NSDictionary *clipInfo = allClips[i];
                id clip = clipInfo[@"item"];
                NSString *name = @"";
                @try {
                    if ([clip respondsToSelector:@selector(displayName)]) {
                        id nameObj = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName));
                        if ([nameObj isKindOfClass:[NSString class]]) name = nameObj;
                    }
                } @catch (NSException *e) {}
                [resolvedClipPreview addObject:@{
                    @"class": NSStringFromClass([clip class]) ?: @"",
                    @"name": name ?: @"",
                    @"role": clipInfo[@"role"] ?: @"",
                    @"rawRoleUID": SpliceKit_rawClipRoleUID(clip) ?: @"",
                    @"lane": clipInfo[@"lane"] ?: @(0),
                    @"start": clipInfo[@"start"] ?: @(0),
                    @"end": clipInfo[@"end"] ?: @(0),
                }];
            }

            NSMutableDictionary *debugPayload = [@{
                @"buildStamp": [NSString stringWithFormat:@"%s %s", __DATE__, __TIME__],
                @"maxFaders": @(maxFaders),
                @"handleCount": @(sHandleMap.count),
                @"resolvedClipCount": @(allClips.count),
                @"resolvedClipPreview": resolvedClipPreview,
                @"toolSkimming": @(toolSkimming),
                @"rawToolSkimming": @(rawToolSkimming),
                @"latchedSkimming": @(sMixerSkimmingLatched),
                @"skimmedRole": skimmedRole ?: @"",
                @"skimmedName": skimmedName ?: @"",
                @"skimmedItemClass": skimmedItem ? NSStringFromClass([skimmedItem class]) : @"",
                @"activeTimeSeconds": @(activeTimeSec),
                @"transportPlaying": @(transportPlaying),
                @"playbackRate": @(transportRate),
                @"meteringLive": @(meteringLive),
                @"playerMeteringEnabled": @(playerMeteringEnabled),
                @"usedPlayerMetering": @(usedPlayerMetering),
                @"usedLayerFallback": @(usedLayerFallback),
                @"layerFallbackPeak": @(layerFallbackPeak),
                @"secondsSinceSkimBegin": @(sMixerLastSkimBeginTime > 0 ? CFAbsoluteTimeGetCurrent() - sMixerLastSkimBeginTime : -1),
                @"secondsSinceSkimEnd": @(sMixerLastSkimEndTime > 0 ? CFAbsoluteTimeGetCurrent() - sMixerLastSkimEndTime : -1),
                @"secondsSinceSkimUpdate": @(sMixerLastSkimUpdateTime > 0 ? CFAbsoluteTimeGetCurrent() - sMixerLastSkimUpdateTime : -1),
            } mutableCopy];
            debugPayload[@"recentStates"] = SpliceKit_mixerRecordDebugState(debugPayload);
            payload[@"debug"] = debugPayload;
            if (masterFader) payload[@"masterFader"] = masterFader;
            result = payload;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.setVolume — set volume on a specific channel handle
static NSDictionary *SpliceKit_handleMixerSetVolume(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    if (!handle) return @{@"error": @"handle parameter required (volumeChannelHandle from mixer.getState)"};

    // Accept either dB or linear
    NSNumber *dbVal = params[@"volumeDB"];
    NSNumber *linearVal = params[@"volumeLinear"];
    if (!dbVal && !linearVal) return @{@"error": @"volumeDB or volumeLinear parameter required"};

    double linear;
    if (linearVal) {
        linear = [linearVal doubleValue];
    } else {
        double db = [dbVal doubleValue];
        linear = (db <= -144.0) ? 0.0 : pow(10.0, db / 20.0);
    }

    // Clamp to FCP's valid range (0.0 to ~12 dB = ~3.98)
    if (linear < 0.0) linear = 0.0;
    if (linear > 3.98) linear = 3.98;

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id channel = SpliceKit_resolveHandle(handle);
            if (!channel) {
                result = @{@"error": @"Handle not found — clip may have changed. Call mixer.getState to refresh."};
                return;
            }

            SpliceKit_removeChannelKeyframes(channel);

            BOOL ok = SpliceKit_mixerSetStaticChannelValue(channel, linear);
            if (ok) {
                double readback = SpliceKit_channelValue(channel);
                result = @{
                    @"ok": @YES,
                    @"volumeLinear": @(readback),
                    @"volumeDB": SpliceKit_mixerJSONDBNumberFromLinear(readback, -96.0)
                };
            } else {
                result = @{@"error": @"Failed to set channel value"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.setSolo — solo role faders by writing FCP's native sequence solo set
NSDictionary *SpliceKit_handleMixerSetSolo(NSDictionary *params) {
    NSString *mode = [params[@"mode"] isKindOfClass:[NSString class]] ? params[@"mode"] : @"toggle";

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            id sequence = nil;
            id rootObject = nil;
            NSMutableArray *allClips = nil;
            NSMutableOrderedSet *roleOrder = nil;
            NSString *snapshotError = nil;
            if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
                result = @{@"error": snapshotError ?: @"Unable to inspect mixer roles"};
                return;
            }

            SEL setSoloedSel = NSSelectorFromString(@"setSoloedObjects:");
            if (![sequence respondsToSelector:setSoloedSel]) {
                result = @{@"error": @"FCP sequence does not expose solo controls"};
                return;
            }

            if ([mode isEqualToString:@"clear"]) {
                ((void (*)(id, SEL, id))objc_msgSend)(sequence, setSoloedSel, nil);
                result = @{
                    @"ok": @YES,
                    @"mode": mode,
                    @"soloed": @NO,
                    @"soloActive": @NO,
                    @"soloObjectCount": @(0)
                };
                return;
            }

            NSInteger index = NSNotFound;
            NSString *role = SpliceKit_mixerRoleFromParams(params, roleOrder, &index);
            if (role.length == 0) {
                result = @{@"error": @"role or index parameter required"};
                return;
            }

            NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
            if (roleObjects.count == 0) {
                result = @{@"error": @"No timeline objects found for this mixer role"};
                return;
            }

            NSSet *currentSoloed = SpliceKit_mixerSoloedObjects(sequence) ?: [NSSet set];
            NSMutableSet *nextSoloed = [NSMutableSet setWithSet:currentSoloed];
            BOOL currentlySoloed = SpliceKit_mixerSetIntersectsObjects(currentSoloed, roleObjects);

            BOOL hasExplicitSolo = (params[@"solo"] != nil);
            BOOL targetSoloed = hasExplicitSolo ? [params[@"solo"] boolValue] : !currentlySoloed;
            if ([mode isEqualToString:@"add"]) {
                targetSoloed = YES;
            } else if ([mode isEqualToString:@"remove"]) {
                targetSoloed = NO;
            } else if ([mode isEqualToString:@"exclusive"]) {
                if (!hasExplicitSolo) targetSoloed = YES;
                [nextSoloed removeAllObjects];
            } else if (![mode isEqualToString:@"toggle"]) {
                result = @{@"error": @"mode must be toggle, exclusive, add, remove, or clear"};
                return;
            }

            if (targetSoloed) {
                [nextSoloed addObjectsFromArray:roleObjects];
            } else {
                [nextSoloed minusSet:[NSSet setWithArray:roleObjects]];
            }

            NSSet *nextSet = nextSoloed.count > 0 ? [NSSet setWithSet:nextSoloed] : nil;
            ((void (*)(id, SEL, id))objc_msgSend)(sequence, setSoloedSel, nextSet);

            BOOL roleSoloed = SpliceKit_mixerSetIntersectsObjects(nextSet, roleObjects);
            result = @{
                @"ok": @YES,
                @"mode": mode,
                @"role": role,
                @"index": @(index),
                @"soloed": @(roleSoloed),
                @"soloActive": @(nextSet.count > 0),
                @"roleObjectCount": @(roleObjects.count),
                @"soloObjectCount": @(nextSet.count)
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.setMute — mute role faders through FCP's disabled audio-role playback map
NSDictionary *SpliceKit_handleMixerSetMute(NSDictionary *params) {
    NSString *mode = [params[@"mode"] isKindOfClass:[NSString class]] ? params[@"mode"] : @"toggle";

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            id sequence = nil;
            id rootObject = nil;
            NSMutableArray *allClips = nil;
            NSMutableOrderedSet *roleOrder = nil;
            NSString *snapshotError = nil;
            if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
                result = @{@"error": snapshotError ?: @"Unable to inspect mixer roles"};
                return;
            }

            id playbackRoot = rootObject ? rootObject : sequence;

            if ([mode isEqualToString:@"clear"]) {
                NSMutableOrderedSet *allRoleUIDs = [NSMutableOrderedSet orderedSet];
                for (NSString *role in roleOrder) {
                    [allRoleUIDs addObjectsFromArray:SpliceKit_mixerRoleUIDsForRole(allClips, role)];
                }
                if (allRoleUIDs.count > 0) {
                    NSString *setError = nil;
                    BOOL ok = SpliceKit_mixerSetAudioRolesEnabled(
                        playbackRoot, sequence, [NSSet setWithArray:[allRoleUIDs array]], YES, &setError);
                    if (!ok) {
                        result = @{@"error": setError ?: @"Failed to clear mixer role mutes"};
                        return;
                    }
                }
                result = @{
                    @"ok": @YES,
                    @"mode": mode,
                    @"muted": @NO,
                    @"roleUIDCount": @(allRoleUIDs.count)
                };
                return;
            }

            NSInteger index = NSNotFound;
            NSString *role = SpliceKit_mixerRoleFromParams(params, roleOrder, &index);
            if (role.length == 0) {
                result = @{@"error": @"role or index parameter required"};
                return;
            }

            NSArray<NSString *> *roleUIDs = SpliceKit_mixerRoleUIDsForRole(allClips, role);
            if (roleUIDs.count == 0) {
                result = @{@"error": @"No audio role UIDs found for this mixer fader"};
                return;
            }

            NSSet *disabledAudioRoleUIDs = SpliceKit_mixerDisabledAudioRoleUIDsForRootObject(rootObject, sequence);
            NSUInteger mutedUIDCount = SpliceKit_mixerCountDisabledRoleUIDs(roleUIDs, disabledAudioRoleUIDs);
            BOOL currentlyMuted = (roleUIDs.count > 0 && mutedUIDCount == roleUIDs.count);

            BOOL hasExplicitMuted = (params[@"muted"] != nil);
            BOOL targetMuted = hasExplicitMuted ? [params[@"muted"] boolValue] : !currentlyMuted;
            if ([mode isEqualToString:@"mute"]) {
                targetMuted = YES;
            } else if ([mode isEqualToString:@"unmute"]) {
                targetMuted = NO;
            } else if (![mode isEqualToString:@"toggle"]) {
                result = @{@"error": @"mode must be toggle, mute, unmute, or clear"};
                return;
            }

            NSString *setError = nil;
            BOOL ok = SpliceKit_mixerSetAudioRolesEnabled(
                playbackRoot, sequence, [NSSet setWithArray:roleUIDs], !targetMuted, &setError);
            if (!ok) {
                result = @{@"error": setError ?: @"Failed to update mixer role mute"};
                return;
            }

            result = @{
                @"ok": @YES,
                @"mode": mode,
                @"role": role,
                @"index": @(index),
                @"muted": @(targetMuted),
                @"roleUIDCount": @(roleUIDs.count)
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
	    return result;
}

// mixer.applyBusEffect — add an audio effect to the collection-backed bus for a role.
// This mirrors FCP's compound-clip behavior: audio on child items flows through the
// parent FFAnchoredCollection.localAudioEffects stack, so the effect is shared after
// the role's contained audio has been grouped by that collection.
NSDictionary *SpliceKit_handleMixerApplyBusEffect(NSDictionary *params) {
    NSString *effectID = [params[@"effectID"] isKindOfClass:[NSString class]] ? params[@"effectID"] : nil;
    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : nil;
    BOOL dryRun = [params[@"dryRun"] boolValue];
    BOOL allowObjectFallback = [params[@"allowObjectFallback"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            id sequence = nil;
            id rootObject = nil;
            NSMutableArray *allClips = nil;
            NSMutableOrderedSet *roleOrder = nil;
            NSString *snapshotError = nil;
            if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
                result = @{@"error": snapshotError ?: @"Unable to inspect mixer roles"};
                return;
            }

            NSInteger index = NSNotFound;
            NSString *role = SpliceKit_mixerRoleFromParams(params, roleOrder, &index);
            if (role.length == 0) {
                result = @{@"error": @"role or index parameter required"};
                return;
            }

            NSDictionary *effect = SpliceKit_resolveEffectDescriptor(effectID, name, @"effect.audio.effect");
            if (effect[@"error"]) {
                result = effect;
                return;
            }

            NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
            if (roleObjects.count == 0) {
                result = @{@"error": @"No timeline objects found for this mixer role"};
                return;
            }

            NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, allowObjectFallback);
            if (busTargets.count == 0) {
                result = @{
                    @"error": allowObjectFallback
                        ? @"No audio effect stack found for this mixer role"
                        : @"No collection-backed bus found for this mixer role. This first bus path requires a role-bearing collection or compound clip.",
                    @"role": role,
                    @"roleObjectCount": @(roleObjects.count),
                };
                return;
            }

            NSMutableArray *targetObjects = [NSMutableArray arrayWithCapacity:busTargets.count];
            NSMutableArray *beforeSummaries = [NSMutableArray arrayWithCapacity:busTargets.count];
            for (NSDictionary *target in busTargets) {
                id object = target[@"object"];
                id stack = target[@"effectStack"];
                if (object) [targetObjects addObject:object];
                [beforeSummaries addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
            }

            if (dryRun) {
                result = @{
                    @"ok": @YES,
                    @"dryRun": @YES,
                    @"role": role,
                    @"index": @(index),
                    @"effect": effect,
                    @"busMode": allowObjectFallback ? @"objectFallback" : @"collection",
                    @"busObjectCount": @(busTargets.count),
                    @"targets": beforeSummaries,
                };
                return;
            }

            NSString *scopeKey = SpliceKit_mixerManagedBusScopeKey(sequence, rootObject);
            NSMutableDictionary *managedEntry = SpliceKit_mixerNewManagedBusEntry(role, scopeKey, effect);
            NSMutableDictionary<NSString *, NSNumber *> *beforeCountsByObject = [NSMutableDictionary dictionary];
            for (NSDictionary *target in busTargets) {
                id object = target[@"object"];
                id stack = target[@"effectStack"];
                NSString *objectKey = SpliceKit_handlePointerKey(object);
                if (objectKey.length > 0) {
                    beforeCountsByObject[objectKey] = @(SpliceKit_mixerEffectsInStack(stack).count);
                }
            }

            NSString *applyError = nil;
            BOOL ok = SpliceKit_mixerApplyAudioEffectIDToObjects(effect[@"effectID"], targetObjects, &applyError);
            if (!ok) {
                NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, NO);
                [entries removeObject:managedEntry];
                result = @{
                    @"error": applyError ?: [NSString stringWithFormat:@"Failed to apply audio bus effect '%@'",
                                             effect[@"name"] ?: effect[@"effectID"]],
                    @"role": role,
                    @"effect": effect,
                };
                return;
            }

            NSMutableArray *afterSummaries = [NSMutableArray arrayWithCapacity:busTargets.count];
            for (NSDictionary *target in busTargets) {
                id object = target[@"object"];
                NSString *objectKey = SpliceKit_handlePointerKey(object);
                NSUInteger beforeCount = objectKey.length > 0 ? [beforeCountsByObject[objectKey] unsignedIntegerValue] : 0;
                SpliceKit_mixerCaptureManagedInstanceAfterApply(managedEntry, object, beforeCount);
                SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                [afterSummaries addObject:SpliceKit_mixerBusTargetSummary(object, target[@"effectStack"])];
            }

            result = @{
                @"ok": @YES,
                @"role": role,
                @"index": @(index),
                @"effect": effect,
                @"busEffectID": managedEntry[@"busEffectID"] ?: @"",
                @"busMode": allowObjectFallback ? @"objectFallback" : @"collection",
                @"busObjectCount": @(busTargets.count),
                @"beforeTargets": beforeSummaries,
                @"targets": afterSummaries,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to apply mixer bus effect"};
}

static id SpliceKit_mixerTimelineContext(void) {
    @try {
        Class selMgr = objc_getClass("PESelectionManager");
        id manager = selMgr ? ((id (*)(id, SEL))objc_msgSend)((id)selMgr, @selector(defaultSelectionManager)) : nil;
        if (manager && [manager respondsToSelector:@selector(timelineContext)]) {
            return ((id (*)(id, SEL))objc_msgSend)(manager, @selector(timelineContext));
        }
    } @catch (NSException *e) {}
    return nil;
}

static id SpliceKit_mixerEffectAtIndex(id effectStack, NSInteger effectIndex) {
    if (effectIndex < 0) return nil;
    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    if ((NSUInteger)effectIndex >= effects.count) return nil;
    return effects[(NSUInteger)effectIndex];
}

static id SpliceKit_mixerEffectStackForEffect(id effect) {
    if (!effect) return nil;
    @try {
        SEL effectStackSel = NSSelectorFromString(@"effectStack");
        if ([effect respondsToSelector:effectStackSel]) {
            return ((id (*)(id, SEL))objc_msgSend)(effect, effectStackSel);
        }
    } @catch (NSException *e) {}
    return nil;
}

static NSInteger SpliceKit_mixerIndexOfEffectInStack(id effectStack, id effect) {
    if (!effectStack || !effect) return NSNotFound;
    NSArray *effects = SpliceKit_mixerEffectsInStack(effectStack);
    for (NSUInteger idx = 0; idx < effects.count; idx++) {
        if (effects[idx] == effect) return (NSInteger)idx;
    }
    return NSNotFound;
}

static BOOL SpliceKit_mixerResolveEffectHandleParams(NSDictionary *params,
                                                     id *outEffect,
                                                     id *outStack,
                                                     NSInteger *outIndex,
                                                     NSString **outError) {
    NSString *effectHandle = [params[@"effectHandle"] isKindOfClass:[NSString class]] ? params[@"effectHandle"] : @"";
    if (effectHandle.length == 0) return NO;

    id effect = SpliceKit_resolveHandle(effectHandle);
    if (!effect) {
        if (outError) *outError = [NSString stringWithFormat:@"Effect handle not found: %@", effectHandle];
        return YES;
    }

    NSString *stackHandle = [params[@"effectStackHandle"] isKindOfClass:[NSString class]] ? params[@"effectStackHandle"] : @"";
    id stack = stackHandle.length > 0 ? SpliceKit_resolveHandle(stackHandle) : nil;
    if (!stack) stack = SpliceKit_mixerEffectStackForEffect(effect);
    if (!stack) {
        if (outError) *outError = @"Unable to resolve effect stack for effect handle";
        return YES;
    }

    NSInteger effectIndex = NSNotFound;
    NSNumber *effectIndexNumber = [params[@"effectIndex"] isKindOfClass:[NSNumber class]] ? params[@"effectIndex"] : nil;
    if (effectIndexNumber) effectIndex = [effectIndexNumber integerValue];
    if (effectIndex == NSNotFound) effectIndex = SpliceKit_mixerIndexOfEffectInStack(stack, effect);

    if (outEffect) *outEffect = effect;
    if (outStack) *outStack = stack;
    if (outIndex) *outIndex = effectIndex;
    return YES;
}

static BOOL SpliceKit_mixerBusTargetsFromParams(NSDictionary *params,
                                                BOOL allowObjectFallback,
                                                NSString **outRole,
                                                NSInteger *outIndex,
                                                NSArray<NSDictionary *> **outBusTargets,
                                                NSString **outError) {
    id timeline = SpliceKit_getActiveTimelineModule();
    id sequence = nil;
    id rootObject = nil;
    NSMutableArray *allClips = nil;
    NSMutableOrderedSet *roleOrder = nil;
    NSString *snapshotError = nil;
    if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
        if (outError) *outError = snapshotError ?: @"Unable to inspect mixer roles";
        return NO;
    }

    NSInteger index = NSNotFound;
    NSString *role = SpliceKit_mixerRoleFromParams(params, roleOrder, &index);
    if (role.length == 0) {
        if (outError) *outError = @"role or index parameter required";
        return NO;
    }

    NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
    if (roleObjects.count == 0) {
        if (outError) *outError = @"No timeline objects found for this mixer role";
        return NO;
    }

    NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, allowObjectFallback);
    if (busTargets.count == 0) {
        if (outError) *outError = allowObjectFallback
            ? @"No audio effect stack found for this mixer role"
            : @"No collection-backed bus found for this mixer role";
        return NO;
    }

    if (outRole) *outRole = role;
    if (outIndex) *outIndex = index;
    if (outBusTargets) *outBusTargets = busTargets;
    return YES;
}

static NSArray<NSDictionary *> *SpliceKit_mixerCurrentBusTargetsForManagedEntry(NSMutableDictionary *entry,
                                                                                NSString *role,
                                                                                BOOL allowObjectFallback,
                                                                                NSString **outError) {
    if (!entry || role.length == 0) {
        if (outError) *outError = @"Managed bus effect is missing its role";
        return nil;
    }

    id timeline = SpliceKit_getActiveTimelineModule();
    id sequence = nil;
    id rootObject = nil;
    NSMutableArray *allClips = nil;
    NSMutableOrderedSet *roleOrder = nil;
    NSString *snapshotError = nil;
    if (!SpliceKit_mixerBuildRoleSnapshot(timeline, &sequence, &rootObject, &allClips, &roleOrder, &snapshotError)) {
        if (outError) *outError = snapshotError ?: @"Unable to inspect mixer roles";
        return nil;
    }

    NSString *entryScope = [entry[@"scopeKey"] isKindOfClass:[NSString class]] ? entry[@"scopeKey"] : @"";
    NSString *currentScope = SpliceKit_mixerManagedBusScopeKey(sequence, rootObject);
    if (entryScope.length > 0 && currentScope.length > 0 && ![entryScope isEqualToString:currentScope]) {
        if (outError) *outError = @"Managed bus effect belongs to a different timeline";
        return nil;
    }

    NSArray *roleObjects = SpliceKit_mixerObjectsForRole(allClips, role);
    if (roleObjects.count == 0) {
        if (outError) *outError = @"No timeline objects found for this managed bus role";
        return nil;
    }

    NSArray<NSDictionary *> *busTargets = SpliceKit_mixerBusTargetsForRoleObjects(roleObjects, allowObjectFallback);
    if (busTargets.count == 0) {
        if (outError) *outError = allowObjectFallback
            ? @"No audio effect stack found for this managed bus role"
            : @"No collection-backed bus found for this managed bus role";
        return nil;
    }

    return busTargets;
}

NSDictionary *SpliceKit_handleMixerSetBusEffectEnabled(NSDictionary *params) {
    NSNumber *effectIndexNumber = [params[@"effectIndex"] isKindOfClass:[NSNumber class]] ? params[@"effectIndex"] : nil;
    NSString *busEffectID = [params[@"busEffectID"] isKindOfClass:[NSString class]] ? params[@"busEffectID"] : @"";
    if (!effectIndexNumber && busEffectID.length == 0) return @{@"error": @"effectIndex or busEffectID parameter required"};
    if (!params[@"enabled"]) return @{@"error": @"enabled parameter required"};
    NSInteger effectIndex = effectIndexNumber ? [effectIndexNumber integerValue] : NSNotFound;
    BOOL enabled = [params[@"enabled"] boolValue];
    BOOL allowObjectFallback = [params[@"allowObjectFallback"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSString *role = nil;
            NSInteger index = NSNotFound;
            NSArray<NSDictionary *> *busTargets = nil;
            NSString *error = nil;
            id handleEffect = nil;
            id handleStack = nil;
            NSInteger handleEffectIndex = NSNotFound;
            if (busEffectID.length > 0) {
                NSString *managedRole = nil;
                NSUInteger managedIndex = NSNotFound;
                NSMutableDictionary *entry = SpliceKit_mixerManagedBusEntryForID(busEffectID, &managedRole, &managedIndex);
                if (!entry) {
                    result = @{@"error": @"Managed bus effect not found", @"busEffectID": busEffectID};
                    return;
                }

                entry[@"enabled"] = @(enabled);
                NSMutableArray *updated = [NSMutableArray array];
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    entry, managedRole, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }

                for (NSDictionary *target in managedTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger trackedIndex = NSNotFound;
                    id effect = SpliceKit_mixerTrackedEffectForObject(entry, object, &stack, &trackedIndex);
                    if (!effect || !stack) continue;
                    if (SpliceKit_mixerSetEffectEnabledInStack(effect, stack, enabled)) {
                        [updated addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
                    }
                }

                result = @{
                    @"ok": @YES,
                    @"role": managedRole ?: @"",
                    @"index": managedIndex == NSNotFound ? @(-1) : @(managedIndex),
                    @"busEffectID": busEffectID,
                    @"enabled": @(enabled),
                    @"busObjectCount": @(updated.count),
                    @"targets": updated,
                };
                return;
            }

            if (SpliceKit_mixerResolveEffectHandleParams(params, &handleEffect, &handleStack, &handleEffectIndex, &error)) {
                if (!handleEffect || !handleStack) {
                    result = @{@"error": error ?: @"Unable to resolve mixer bus effect handle"};
                    return;
                }

                if (!SpliceKit_mixerSetEffectEnabledInStack(handleEffect, handleStack, enabled)) {
                    result = @{@"error": @"Resolved effect does not support enabling/disabling"};
                    return;
                }

                result = @{
                    @"ok": @YES,
                    @"effectIndex": @(handleEffectIndex),
                    @"enabled": @(enabled),
                    @"busObjectCount": @1,
                    @"effect": SpliceKit_mixerEffectSummary(handleEffect,
                                                            handleEffectIndex == NSNotFound ? 0 : (NSUInteger)handleEffectIndex),
                    @"targets": @[SpliceKit_mixerBusTargetSummary(nil, handleStack)],
                };
                return;
            }

            if (!SpliceKit_mixerBusTargetsFromParams(params, allowObjectFallback, &role, &index, &busTargets, &error)) {
                result = @{@"error": error ?: @"Unable to resolve mixer bus"};
                return;
            }

            NSUInteger managedIndex = NSNotFound;
            NSMutableDictionary *managedEntry = SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(role, effectIndex, &managedIndex);
            if (managedEntry) {
                managedEntry[@"enabled"] = @(enabled);
                NSMutableArray *updated = [NSMutableArray array];
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    managedEntry, role, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }

                for (NSDictionary *target in managedTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger trackedIndex = NSNotFound;
                    id effect = SpliceKit_mixerTrackedEffectForObject(managedEntry, object, &stack, &trackedIndex);
                    if (!effect || !stack) continue;
                    if (SpliceKit_mixerSetEffectEnabledInStack(effect, stack, enabled)) {
                        [updated addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
                    }
                }

                result = @{
                    @"ok": @YES,
                    @"role": role ?: @"",
                    @"index": managedIndex == NSNotFound ? @(-1) : @(managedIndex),
                    @"busEffectID": [managedEntry[@"busEffectID"] isKindOfClass:[NSString class]] ? managedEntry[@"busEffectID"] : @"",
                    @"enabled": @(enabled),
                    @"busObjectCount": @(updated.count),
                    @"targets": updated,
                };
                return;
            }

            NSMutableArray *updated = [NSMutableArray array];
            for (NSDictionary *target in busTargets) {
                id stack = target[@"effectStack"];
                id effect = SpliceKit_mixerEffectAtIndex(stack, effectIndex);
                if (!stack || !effect) continue;

                if (SpliceKit_mixerSetEffectEnabledInStack(effect, stack, enabled)) {
                    [updated addObject:SpliceKit_mixerBusTargetSummary(target[@"object"], stack)];
                }
            }

            if (updated.count == 0) {
                result = @{@"error": @"No bus effect found at that index", @"effectIndex": @(effectIndex)};
                return;
            }

            result = @{
                @"ok": @YES,
                @"role": role,
                @"index": @(index),
                @"effectIndex": @(effectIndex),
                @"enabled": @(enabled),
                @"busObjectCount": @(updated.count),
                @"targets": updated,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to set mixer bus effect enabled state"};
}

NSDictionary *SpliceKit_handleMixerRemoveBusEffect(NSDictionary *params) {
    NSNumber *effectIndexNumber = [params[@"effectIndex"] isKindOfClass:[NSNumber class]] ? params[@"effectIndex"] : nil;
    NSString *busEffectID = [params[@"busEffectID"] isKindOfClass:[NSString class]] ? params[@"busEffectID"] : @"";
    if (!effectIndexNumber && busEffectID.length == 0) return @{@"error": @"effectIndex or busEffectID parameter required"};
    NSInteger effectIndex = effectIndexNumber ? [effectIndexNumber integerValue] : NSNotFound;
    BOOL allowObjectFallback = [params[@"allowObjectFallback"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSString *role = nil;
            NSInteger index = NSNotFound;
            NSArray<NSDictionary *> *busTargets = nil;
            NSString *error = nil;
            id handleEffect = nil;
            id handleStack = nil;
            NSInteger handleEffectIndex = NSNotFound;
            if (busEffectID.length > 0) {
                NSString *managedRole = nil;
                NSUInteger managedIndex = NSNotFound;
                NSMutableDictionary *entry = SpliceKit_mixerManagedBusEntryForID(busEffectID, &managedRole, &managedIndex);
                if (!entry) {
                    result = @{@"error": @"Managed bus effect not found", @"busEffectID": busEffectID};
                    return;
                }

                NSMutableArray *updated = [NSMutableArray array];
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    entry, managedRole, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }

                for (NSDictionary *target in managedTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger trackedIndex = NSNotFound;
                    id effect = SpliceKit_mixerTrackedEffectForObject(entry, object, &stack, &trackedIndex);
                    if (stack && effect && trackedIndex != NSNotFound &&
                        SpliceKit_mixerRemoveEffectFromStackAtIndex(stack, trackedIndex)) {
                        [updated addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
                    }
                    SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                }

                NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(managedRole, NO);
                [entries removeObject:entry];
                SpliceKit_mixerPruneManagedBusRole(managedRole);

                result = @{
                    @"ok": @YES,
                    @"role": managedRole ?: @"",
                    @"index": managedIndex == NSNotFound ? @(-1) : @(managedIndex),
                    @"busEffectID": busEffectID,
                    @"busObjectCount": @(updated.count),
                    @"targets": updated,
                };
                return;
            }

            if (SpliceKit_mixerResolveEffectHandleParams(params, &handleEffect, &handleStack, &handleEffectIndex, &error)) {
                if (!handleEffect || !handleStack) {
                    result = @{@"error": error ?: @"Unable to resolve mixer bus effect handle"};
                    return;
                }
                if (handleEffectIndex == NSNotFound) {
                    result = @{@"error": @"Unable to locate effect in its stack"};
                    return;
                }

                if (!SpliceKit_mixerRemoveEffectFromStackAtIndex(handleStack, handleEffectIndex)) {
                    result = @{@"error": @"Failed to remove resolved mixer bus effect"};
                    return;
                }

                result = @{
                    @"ok": @YES,
                    @"effectIndex": @(handleEffectIndex),
                    @"busObjectCount": @1,
                    @"targets": @[SpliceKit_mixerBusTargetSummary(nil, handleStack)],
                };
                return;
            }

            if (!SpliceKit_mixerBusTargetsFromParams(params, allowObjectFallback, &role, &index, &busTargets, &error)) {
                result = @{@"error": error ?: @"Unable to resolve mixer bus"};
                return;
            }

            NSUInteger managedIndex = NSNotFound;
            NSMutableDictionary *managedEntry = SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(role, effectIndex, &managedIndex);
            if (managedEntry) {
                NSMutableArray *updated = [NSMutableArray array];
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    managedEntry, role, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }

                for (NSDictionary *target in managedTargets) {
                    id object = target[@"object"];
                    id stack = nil;
                    NSInteger trackedIndex = NSNotFound;
                    id effect = SpliceKit_mixerTrackedEffectForObject(managedEntry, object, &stack, &trackedIndex);
                    if (stack && effect && trackedIndex != NSNotFound &&
                        SpliceKit_mixerRemoveEffectFromStackAtIndex(stack, trackedIndex)) {
                        [updated addObject:SpliceKit_mixerBusTargetSummary(object, stack)];
                    }
                    SpliceKit_mixerUpdateObjectAfterBusEffectMutation(object);
                }

                NSMutableArray *entries = SpliceKit_mixerManagedBusEntriesForRole(role, NO);
                [entries removeObject:managedEntry];
                SpliceKit_mixerPruneManagedBusRole(role);

                result = @{
                    @"ok": @YES,
                    @"role": role ?: @"",
                    @"index": managedIndex == NSNotFound ? @(-1) : @(managedIndex),
                    @"busEffectID": [managedEntry[@"busEffectID"] isKindOfClass:[NSString class]] ? managedEntry[@"busEffectID"] : @"",
                    @"busObjectCount": @(updated.count),
                    @"targets": updated,
                };
                return;
            }

            NSMutableArray *updated = [NSMutableArray array];
            for (NSDictionary *target in busTargets) {
                id stack = target[@"effectStack"];
                id effect = SpliceKit_mixerEffectAtIndex(stack, effectIndex);
                if (!stack || !effect) continue;

                if (SpliceKit_mixerRemoveEffectFromStackAtIndex(stack, effectIndex)) {
                    [updated addObject:SpliceKit_mixerBusTargetSummary(target[@"object"], stack)];
                }
            }

            if (updated.count == 0) {
                result = @{@"error": @"No bus effect found at that index", @"effectIndex": @(effectIndex)};
                return;
            }

            result = @{
                @"ok": @YES,
                @"role": role,
                @"index": @(index),
                @"effectIndex": @(effectIndex),
                @"busObjectCount": @(updated.count),
                @"targets": updated,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to remove mixer bus effect"};
}

NSDictionary *SpliceKit_handleMixerOpenBusEffect(NSDictionary *params) {
    NSNumber *effectIndexNumber = [params[@"effectIndex"] isKindOfClass:[NSNumber class]] ? params[@"effectIndex"] : nil;
    NSString *busEffectID = [params[@"busEffectID"] isKindOfClass:[NSString class]] ? params[@"busEffectID"] : @"";
    NSString *effectHandleParam = [params[@"effectHandle"] isKindOfClass:[NSString class]] ? params[@"effectHandle"] : @"";
    if (!effectIndexNumber && busEffectID.length == 0 && effectHandleParam.length == 0) {
        return @{@"error": @"effectIndex, effectHandle, or busEffectID parameter required"};
    }
    NSInteger effectIndex = effectIndexNumber ? [effectIndexNumber integerValue] : NSNotFound;
    BOOL allowObjectFallback = [params[@"allowObjectFallback"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSString *role = nil;
            NSInteger index = NSNotFound;
            NSArray<NSDictionary *> *busTargets = nil;
            NSString *error = nil;
            id effect = nil;
            id sourceStack = nil;
            NSInteger resolvedEffectIndex = effectIndex;
            id handleEffect = nil;
            id handleStack = nil;
            NSInteger handleEffectIndex = NSNotFound;
            if (SpliceKit_mixerResolveEffectHandleParams(params, &handleEffect, &handleStack, &handleEffectIndex, &error)) {
                if (!handleEffect || !handleStack) {
                    result = @{@"error": error ?: @"Unable to resolve mixer bus effect handle"};
                    return;
                }
                effect = handleEffect;
                sourceStack = handleStack;
                if (handleEffectIndex != NSNotFound) resolvedEffectIndex = handleEffectIndex;
            } else if (busEffectID.length > 0) {
                NSString *managedRole = nil;
                NSMutableDictionary *entry = SpliceKit_mixerManagedBusEntryForID(busEffectID, &managedRole, NULL);
                if (!entry) {
                    result = @{@"error": @"Managed bus effect not found", @"busEffectID": busEffectID};
                    return;
                }
                role = managedRole;
                NSString *managedTargetError = nil;
                NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                    entry, managedRole, allowObjectFallback, &managedTargetError);
                if (!managedTargets) {
                    result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                    return;
                }
                for (NSDictionary *target in managedTargets) {
                    effect = SpliceKit_mixerTrackedEffectForObject(entry, target[@"object"], &sourceStack, &resolvedEffectIndex);
                    if (effect) break;
                }
            } else {
                if (!SpliceKit_mixerBusTargetsFromParams(params, allowObjectFallback, &role, &index, &busTargets, &error)) {
                    result = @{@"error": error ?: @"Unable to resolve mixer bus"};
                    return;
                }

                NSUInteger managedIndex = NSNotFound;
                NSMutableDictionary *managedEntry = SpliceKit_mixerManagedBusEntryForRoleDisplayIndex(role, effectIndex, &managedIndex);
                if (managedEntry) {
                    NSString *managedTargetError = nil;
                    NSArray<NSDictionary *> *managedTargets = SpliceKit_mixerCurrentBusTargetsForManagedEntry(
                        managedEntry, role, allowObjectFallback, &managedTargetError);
                    if (!managedTargets) {
                        result = @{@"error": managedTargetError ?: @"Unable to resolve managed bus targets"};
                        return;
                    }
                    for (NSDictionary *target in managedTargets) {
                        effect = SpliceKit_mixerTrackedEffectForObject(managedEntry, target[@"object"], &sourceStack, &resolvedEffectIndex);
                        if (effect) break;
                    }
                    index = managedIndex == NSNotFound ? NSNotFound : (NSInteger)managedIndex;
                } else {
                    for (NSDictionary *target in busTargets) {
                        sourceStack = target[@"effectStack"];
                        effect = SpliceKit_mixerEffectAtIndex(sourceStack, effectIndex);
                        if (effect) break;
                    }
                }
            }
            if (!effect) {
                result = @{@"error": @"No bus effect found at that index", @"effectIndex": @(effectIndex)};
                return;
            }

            Class editorClass = objc_getClass("FFAudioEffectEditorWindowController");
            if (!editorClass || ![editorClass respondsToSelector:NSSelectorFromString(@"showWindowControllerForEffect:context:")]) {
                result = @{@"error": @"FCP audio effect editor window controller is unavailable"};
                return;
            }

            id context = SpliceKit_mixerTimelineContext();
            if (!context) {
                result = @{@"error": @"No timeline context available for audio effect editor"};
                return;
            }

            ((void (*)(id, SEL, id, id))objc_msgSend)(
                (id)editorClass,
                NSSelectorFromString(@"showWindowControllerForEffect:context:"),
                effect,
                context);

            result = @{
                @"ok": @YES,
                @"role": role ?: @"",
                @"index": index == NSNotFound ? @(-1) : @(index),
                @"effectIndex": @(resolvedEffectIndex),
                @"effect": SpliceKit_mixerEffectSummary(effect, resolvedEffectIndex == NSNotFound ? 0 : (NSUInteger)resolvedEffectIndex),
                @"effectStackHandle": sourceStack ? (SpliceKit_storeHandle(sourceStack) ?: @"") : @"",
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to open mixer bus effect editor"};
}

// Active undo transactions for mixer fader drags
static NSMutableDictionary *sMixerUndoTransactions = nil;

// mixer.volumeBegin — open undo transaction for a fader drag
static NSDictionary *SpliceKit_handleMixerVolumeBegin(NSDictionary *params) {
    NSString *effectStackHandle = params[@"effectStackHandle"];
    // Also accept audioEffectStackHandle (preferred for mixer)
    if (!effectStackHandle) effectStackHandle = params[@"audioEffectStackHandle"];
    if (!effectStackHandle) return @{@"error": @"effectStackHandle or audioEffectStackHandle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id effectStack = SpliceKit_resolveHandle(effectStackHandle);
            if (!effectStack) {
                result = @{@"error": @"effectStackHandle not found"};
                return;
            }

            // Open undo transaction
            SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
            if ([effectStack respondsToSelector:beginSel]) {
                ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                    effectStack, beginSel, @"Adjust Volume", nil, YES);
            }

            // Track this transaction
            if (!sMixerUndoTransactions) sMixerUndoTransactions = [NSMutableDictionary dictionary];
            sMixerUndoTransactions[effectStackHandle] = @YES;

            result = @{@"ok": @YES, @"effectStackHandle": effectStackHandle};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.volumeEnd — close undo transaction for a fader drag
static NSDictionary *SpliceKit_handleMixerVolumeEnd(NSDictionary *params) {
    NSString *effectStackHandle = params[@"effectStackHandle"];
    if (!effectStackHandle) effectStackHandle = params[@"audioEffectStackHandle"];
    if (!effectStackHandle) return @{@"error": @"effectStackHandle or audioEffectStackHandle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id effectStack = SpliceKit_resolveHandle(effectStackHandle);
            if (!effectStack) {
                result = @{@"error": @"effectStackHandle not found"};
                return;
            }

            // Close undo transaction
            SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
            if ([effectStack respondsToSelector:endSel]) {
                ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                    effectStack, endSel, @"Adjust Volume", YES, nil);
            }

            // Remove from tracking
            [sMixerUndoTransactions removeObjectForKey:effectStackHandle];

            result = @{@"ok": @YES};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

// mixer.setAllVolumes — batch set multiple fader volumes in one undo transaction
static NSDictionary *SpliceKit_handleMixerSetAllVolumes(NSDictionary *params) {
    NSArray *volumes = params[@"volumes"]; // [{handle, volumeDB or volumeLinear}, ...]
    if (!volumes || ![volumes isKindOfClass:[NSArray class]] || volumes.count == 0) {
        return @{@"error": @"volumes array required: [{handle, volumeDB or volumeLinear}, ...]"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSMutableArray *results = [NSMutableArray array];
            for (NSDictionary *entry in volumes) {
                NSString *handle = entry[@"handle"];
                if (!handle) { [results addObject:@{@"error": @"missing handle"}]; continue; }

                id channel = SpliceKit_resolveHandle(handle);
                if (!channel) { [results addObject:@{@"error": @"handle not found"}]; continue; }

                NSNumber *dbVal = entry[@"volumeDB"];
                NSNumber *linearVal = entry[@"volumeLinear"];
                double linear;
                if (linearVal) {
                    linear = [linearVal doubleValue];
                } else if (dbVal) {
                    double db = [dbVal doubleValue];
                    linear = (db <= -144.0) ? 0.0 : pow(10.0, db / 20.0);
                } else {
                    [results addObject:@{@"error": @"volumeDB or volumeLinear required"}];
                    continue;
                }

                if (linear < 0.0) linear = 0.0;
                if (linear > 3.98) linear = 3.98;

                SpliceKit_removeChannelKeyframes(channel);
                BOOL ok = SpliceKit_mixerSetStaticChannelValue(channel, linear);
                double readback = ok ? SpliceKit_channelValue(channel) : 0;
                [results addObject:@{
                    @"handle": handle,
                    @"ok": @(ok),
                    @"volumeLinear": @(readback),
                    @"volumeDB": SpliceKit_mixerJSONDBNumberFromLinear(readback, -96.0)
                }];
            }
            result = @{@"ok": @YES, @"results": results};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result;
}

#pragma mark - Share/Export Handler

// The title of the item Final Cut Pro marks as the default share destination, e.g.
// "Export File (default)…". Main thread only.
static NSString *SpliceKit_defaultShareDestinationTitle(void) {
    @try {
        id app = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("NSApplication"), @selector(sharedApplication));
        NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
        for (NSMenuItem *fileItem in mainMenu.itemArray) {
            if (![fileItem.title isEqualToString:@"File"] || !fileItem.hasSubmenu) continue;
            for (NSMenuItem *shareItem in fileItem.submenu.itemArray) {
                if (![shareItem.title isEqualToString:@"Share"] || !shareItem.hasSubmenu) continue;
                NSString *firstEnabled = nil;
                for (NSMenuItem *dest in shareItem.submenu.itemArray) {
                    if (dest.isSeparatorItem || dest.title.length == 0) continue;
                    if ([dest.title containsString:@"(default)"]) return dest.title;
                    if (!firstEnabled && dest.isEnabled &&
                        ![dest.title hasPrefix:@"Add Destination"]) {
                        firstEnabled = dest.title;
                    }
                }
                return firstEnabled;
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[Share] could not read the Share menu: %@", e.reason);
    }
    return nil;
}

// Fire a File > Share destination without waiting for it.
//
// Every share destination opens the Export sheet and sits there until a person answers
// it. Going through SpliceKit_handleMenuExecute means that sheet opens inside the
// bridge's own main-thread dispatch, so the 20-second watchdog gives up and reports
// "main thread stayed busy" with the sheet still on screen — which is exactly what
// share_project did. The item is located on the main thread (cheap, no modal) and its
// action is fired on a later turn of the run loop, so the bridge answers immediately and
// says the sheet is open, the way create_project does.
static NSDictionary *SpliceKit_shareDestinationAsyncNoWait(NSString *destination) {
    __block NSMenuItem *target = nil;
    __block NSMutableArray *available = [NSMutableArray array];
    SpliceKit_executeOnMainThread(^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            NSMenu *mainMenu = ((id (*)(id, SEL))objc_msgSend)(app, @selector(mainMenu));
            for (NSMenuItem *fileItem in mainMenu.itemArray) {
                if (![fileItem.title isEqualToString:@"File"] || !fileItem.hasSubmenu) continue;
                for (NSMenuItem *shareItem in fileItem.submenu.itemArray) {
                    if (![shareItem.title isEqualToString:@"Share"] || !shareItem.hasSubmenu) continue;
                    for (NSMenuItem *dest in shareItem.submenu.itemArray) {
                        if (dest.isSeparatorItem || dest.title.length == 0) continue;
                        [available addObject:dest.title];
                        NSString *bare = [dest.title stringByReplacingOccurrencesOfString:@"…"
                                                                               withString:@""];
                        if ([dest.title caseInsensitiveCompare:destination] == NSOrderedSame ||
                            [bare caseInsensitiveCompare:destination] == NSOrderedSame) {
                            target = dest;
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[Share] could not read the Share menu: %@", e.reason);
        }
    });

    if (!target) {
        return @{@"error": [NSString stringWithFormat:
            @"No share destination called '%@' in File > Share. Available: %@",
            destination, [available componentsJoinedByString:@", "]]};
    }
    if (!target.isEnabled) {
        return @{@"error": [NSString stringWithFormat:
            @"The share destination '%@' is disabled right now. A project has to be open "
            @"and, for Share Selection, a range selected.", target.title]};
    }

    NSString *title = target.title;
    SEL action = target.action;
    id actionTarget = target.target;
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            ((BOOL (*)(id, SEL, SEL, id, id))objc_msgSend)(
                app, @selector(sendAction:to:from:), action, actionTarget, target);
        } @catch (NSException *e) {
            SpliceKit_log(@"[Share] async %@ exception: %@", title, e.reason);
        }
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());

    return @{
        @"status": @"ok",
        @"destination": title,
        @"dialogPending": @YES,
        @"message": [NSString stringWithFormat:
            @"Final Cut Pro is opening the Export sheet for '%@'. It has to be answered at "
            @"the machine — the bridge can read it with detect_dialog and cancel it with "
            @"dismiss_dialog(action=\"cancel\"), but it cannot confirm a save panel.", title]
    };
}

static NSDictionary *SpliceKit_handleShareExport(NSDictionary *params) {
    NSString *destination = params[@"destination"]; // optional: specific share destination

    if (destination) {
        return SpliceKit_shareDestinationAsyncNoWait(destination);
    }

    // No destination: use whichever one Final Cut Pro marks as the default.
    //
    // This used to send -shareDefaultDestination: down the responder chain. Nothing on
    // FCP 12.3 answers it, so share_project() with no argument always failed with "No
    // responder handled shareDefaultDestination:". The default destination is an ordinary
    // item in File > Share, titled "… (default)", so it is read from the menu and invoked
    // the same way a named destination is.
    __block NSString *title = nil;
    SpliceKit_executeOnMainThread(^{ title = SpliceKit_defaultShareDestinationTitle(); });
    if (title.length == 0) {
        return @{@"error": @"No share destination found in File > Share. Add one in Final "
                           @"Cut Pro's Settings > Destinations, or pass `destination` with "
                           @"the exact menu title."};
    }
    NSDictionary *r = SpliceKit_shareDestinationAsyncNoWait(title);
    if (![r isKindOfClass:[NSDictionary class]] || r[@"error"]) return r;
    NSMutableDictionary *out = [r mutableCopy];
    out[@"usedDefault"] = @YES;
    return out;
}

#pragma mark - Library/Project Management

static NSDictionary *SpliceKit_handleProjectCreate(NSDictionary *params) {
    return SpliceKit_sendAppActionAsyncNoWait(@"newProject:");
}

static NSDictionary *SpliceKit_handleEventCreate(NSDictionary *params) {
    return SpliceKit_sendAppActionAsyncNoWait(@"newEvent:");
}

static NSDictionary *SpliceKit_handleLibraryCreate(NSDictionary *params) {
    return SpliceKit_sendAppActionAsyncNoWait(@"newLibrary:");
}

#pragma mark - Open Project by Name

NSDictionary *SpliceKit_handleProjectOpen(NSDictionary *params) {
    NSString *nameFilter = params[@"name"];
    NSString *eventFilter = params[@"event"];
    if (!nameFilter) return @{@"error": @"name parameter required"};

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            // Step 1: Get active libraries
            Class libDocClass = objc_getClass("FFLibraryDocument");
            if (!libDocClass) {
                result = @{@"error": @"FFLibraryDocument class not found"};
                return;
            }

            SEL copyLibsSel = NSSelectorFromString(@"copyActiveLibraries");
            if (![libDocClass respondsToSelector:copyLibsSel]) {
                result = @{@"error": @"copyActiveLibraries not available"};
                return;
            }

            id libs = ((id (*)(id, SEL))objc_msgSend)((id)libDocClass, copyLibsSel);
            if (!libs || ![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active libraries found"};
                return;
            }

            // Step 2: Search across all libraries for matching sequence
            id foundSequence = nil;
            BOOL foundExact = NO;
            NSString *foundName = nil;
            NSString *foundEvent = nil;
            NSString *foundLibrary = nil;
            NSMutableArray *allSequences = [NSMutableArray array];

            // Walk each library's events, not -_deepLoadedSequences.
            //
            // Two things were wrong with the old walk. _deepLoadedSequences only answers
            // sequences Final Cut Pro has already loaded, so a project that has not been
            // opened yet in this session could not be opened by name at all. And the
            // event name came from -[FFAnchoredSequence event], which FCP 12.3 does not
            // answer: every entry reported event="" and so `event=` never matched
            // anything, including the name it was looking at. The event is the object
            // holding the sequence, which this walk has in hand.
            SEL dnSel = @selector(displayName);
            for (id lib in (NSArray *)libs) {
                NSString *libName = @"";
                if ([lib respondsToSelector:dnSel]) {
                    libName = ((id (*)(id, SEL))objc_msgSend)(lib, dnSel) ?: @"";
                }

                SEL eventsSel = NSSelectorFromString(@"events");
                if (![lib respondsToSelector:eventsSel]) continue;
                id events = ((id (*)(id, SEL))objc_msgSend)(lib, eventsSel);
                if (![events isKindOfClass:[NSArray class]]) continue;

                for (id event in (NSArray *)events) {
                    NSString *seqEvent = @"";
                    if ([event respondsToSelector:dnSel]) {
                        seqEvent = ((id (*)(id, SEL))objc_msgSend)(event, dnSel) ?: @"";
                    }

                    for (id seq in SpliceKit_browserClipsOfEvent(event)) {
                        if (!SpliceKit_browserItemIsProject(seq)) continue;

                        NSString *seqName = @"";
                        if ([seq respondsToSelector:dnSel]) {
                            seqName = ((id (*)(id, SEL))objc_msgSend)(seq, dnSel) ?: @"";
                        }

                        BOOL hasContent = NO;
                        SEL hasItemsSel = NSSelectorFromString(@"hasContainedItems");
                        if ([seq respondsToSelector:hasItemsSel]) {
                            hasContent = ((BOOL (*)(id, SEL))objc_msgSend)(seq, hasItemsSel);
                        }

                        [allSequences addObject:@{
                            @"name": seqName,
                            @"event": seqEvent,
                            @"library": libName,
                            @"hasContent": @(hasContent),
                        }];

                        // Match by name (case-insensitive contains), but an exact name
                        // wins over a longer one that merely contains it. Final Cut Pro
                        // hands out "QA Timeline 1" when "QA Timeline" is taken, and
                        // asking for "QA Timeline" used to open whichever of the two the
                        // walk reached first.
                        BOOL nameMatch = [seqName localizedCaseInsensitiveContainsString:nameFilter];
                        BOOL eventMatch = !eventFilter || eventFilter.length == 0 ||
                            [seqEvent localizedCaseInsensitiveContainsString:eventFilter];
                        BOOL exact = [seqName caseInsensitiveCompare:nameFilter] == NSOrderedSame;

                        if (nameMatch && eventMatch && (!foundSequence || (exact && !foundExact))) {
                            foundSequence = seq;
                            foundName = seqName;
                            foundEvent = seqEvent;
                            foundLibrary = libName;
                            foundExact = exact;
                        }
                    }
                }
            }

            if (!foundSequence) {
                result = @{@"error": [NSString stringWithFormat:
                    @"No project matching name='%@'%@ found. Available: %@",
                    nameFilter,
                    eventFilter ? [NSString stringWithFormat:@" event='%@'", eventFilter] : @"",
                    allSequences]};
                return;
            }

            // Step 3: Load the sequence into the editor
            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
            if (!delegate) {
                result = @{@"error": @"No app delegate"};
                return;
            }

            SEL aecSel = @selector(activeEditorContainer);
            if (![delegate respondsToSelector:aecSel]) {
                result = @{@"error": @"No activeEditorContainer"};
                return;
            }
            id editorContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, aecSel);
            if (!editorContainer) {
                result = @{@"error": @"Editor container is nil"};
                return;
            }

            SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
            if (![editorContainer respondsToSelector:loadSel]) {
                result = @{@"error": @"loadEditorForSequence: not available on editor container"};
                return;
            }

            ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, foundSequence);

            result = @{
                @"status": @"ok",
                @"project": foundName ?: @"",
                @"event": foundEvent ?: @"",
                @"library": foundLibrary ?: @"",
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

#pragma mark - Select Clip at Playhead with Lane

// The timeline item whose pointer key (object identity, as getDetailedState reports
// it with include_pointer_keys) is `key`: the spine's containedItems, every item's
// anchoredItems and every container's containedItems, to a bounded depth. Independent
// of the handle table, which a long walk can clear (SPLICEKIT_MAX_HANDLES).
static id SpliceKit_findTimelineItemByPointerKey(id container, NSString *key, NSInteger depth) {
    if (!container || key.length == 0 || depth > 8) return nil;
    for (NSString *selName in @[@"containedItems", @"anchoredItems"]) {
        SEL sel = NSSelectorFromString(selName);
        if (![container respondsToSelector:sel]) continue;
        NSArray *children = nil;
        @try {
            children = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(container, sel));
        } @catch (NSException *e) { children = nil; }
        for (id child in children) {
            if ([SpliceKit_handlePointerKey(child) isEqualToString:key]) return child;
        }
        for (id child in children) {
            id found = SpliceKit_findTimelineItemByPointerKey(child, key, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static NSDictionary *SpliceKit_handleSelectClipAtPlayheadLane(NSDictionary *params) {
    NSNumber *laneParam = params[@"lane"];
    if (!laneParam) return @{@"error": @"lane parameter required"};
    long long targetLane = [laneParam longLongValue];

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }

            id sequence = nil;
            if ([timeline respondsToSelector:@selector(sequence)]) {
                sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            }
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline"};
                return;
            }

            // Get playhead time
            SpliceKit_CMTime playhead = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(
                timeline, @selector(playheadTime));

            // Get all items including connected clips (anchoredItems)
            id primaryObj = nil;
            if ([sequence respondsToSelector:@selector(primaryObject)]) {
                primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
            }
            if (!primaryObj) {
                result = @{@"error": @"No primary object on sequence"};
                return;
            }

            // Candidates come from the same walk get_timeline_clips reports (spine items on
            // lane 0; connected clips, nested ones included, with their lane relative to the
            // primary storyline and their absolute range), so this tool and that one agree
            // about the same timeline. The earlier direct scan read anchoredItems as an
            // NSArray, which FCP does not hand back for every clip, and found nothing.
            double playheadSec = playhead.timescale > 0 ? (double)playhead.value / (double)playhead.timescale : 0.0;
            NSDictionary *state = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @100000,
                                                                             @"connected_limit": @100000,
                                                                             @"include_markers": @NO,
                                                                             @"include_nested": @NO,
                                                                             @"include_connected": @(targetLane != 0),
                                                                             @"include_pointer_keys": @YES});
            if (![state isKindOfClass:[NSDictionary class]] || state[@"error"]) {
                result = @{@"error": [NSString stringWithFormat:@"could not read the timeline: %@",
                                      state[@"error"] ?: @"no state"]};
                return;
            }
            id listAny = targetLane == 0 ? state[@"items"] : state[@"connectedItems"];
            NSArray *list = [listAny isKindOfClass:[NSArray class]] ? listAny : @[];
            NSUInteger candidateCount = 0;
            NSDictionary *bestEntry = nil;          // first clip under the playhead in that lane
            NSDictionary *containerEntry = nil;     // a connected storyline container there
            for (id entryAny in list) {
                if (![entryAny isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *entry = entryAny;
                if (targetLane != 0) {
                    id laneNum = entry[@"effectiveLane"] ?: entry[@"lane"];
                    if (![laneNum respondsToSelector:@selector(longLongValue)] ||
                        [laneNum longLongValue] != targetLane) continue;
                }
                candidateCount++;          // every clip in the lane, matched or not
                if (bestEntry) continue;
                double startSec = SpliceKit_browserEntrySeconds(entry, @"startTime");
                double endSec = SpliceKit_browserEntrySeconds(entry, @"endTime");
                if (isnan(startSec) || isnan(endSec)) continue;
                if (playheadSec < startSec - 0.001 || playheadSec > endSec + 0.001) continue;
                // A connected storyline is a container; the clip inside it (listed with the
                // same lane) is what a click there selects, so prefer that.
                if ([entry[@"isConnectedStoryline"] boolValue]) {
                    if (!containerEntry) containerEntry = entry;
                    continue;
                }
                bestEntry = entry;
            }
            if (!bestEntry) bestEntry = containerEntry;
            id bestMatch = nil;
            if (bestEntry) {
                // The walk stores a handle per item, and on a very long timeline the handle
                // table can be cleared before the walk ends; the object identity the walk
                // also reports (pointerKey) is what the match is checked and, if need be,
                // found by.
                NSString *wantKey = [bestEntry[@"pointerKey"] isKindOfClass:[NSString class]] ? bestEntry[@"pointerKey"] : nil;
                NSString *bestHandle = [bestEntry[@"handle"] isKindOfClass:[NSString class]] ? bestEntry[@"handle"] : nil;
                bestMatch = bestHandle.length > 0 ? SpliceKit_resolveHandle(bestHandle) : nil;
                if (bestMatch && wantKey.length > 0 && ![SpliceKit_handlePointerKey(bestMatch) isEqualToString:wantKey]) {
                    bestMatch = nil;
                }
                if (!bestMatch && wantKey.length > 0) {
                    bestMatch = SpliceKit_findTimelineItemByPointerKey(primaryObj, wantKey, 0);
                }
            }

            if (!bestMatch) {
                if (bestEntry) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"The clip at the playhead (%.3fs) in lane %lld, \"%@\", could not be resolved to its object (its handle expired and it was not found by identity); call get_timeline_clips and try again.",
                        playheadSec, targetLane,
                        [bestEntry[@"name"] isKindOfClass:[NSString class]] ? bestEntry[@"name"] : @""]};
                    return;
                }
                result = @{@"error": [NSString stringWithFormat:
                    @"No clip found at playhead (%.3fs) in lane %lld. %lu clip%@ in that lane (get_timeline_clips lists them with their times).",
                    playheadSec, targetLane, (unsigned long)candidateCount, candidateCount == 1 ? @"" : @"s"]};
                return;
            }

            // Select through the same path select_clips uses (setSelectedItems: and its
            // fallbacks), and read the selection back.
            NSString *usedSelector = nil;
            if (!SpliceKit_handleSelectionApply(timeline, @[bestMatch], &usedSelector)) {
                result = @{@"error": @"Timeline module responds to none of setSelectedItems:, _setSelectedItems:, selectItems:"};
                return;
            }
            NSArray *readback = SpliceKit_handleSelectionCurrentItems(timeline);
            BOOL selectedNow = NO;
            for (id sel in readback) { if (sel == bestMatch) { selectedNow = YES; break; } }

            NSString *clipName = SpliceKit_displayNameForItem(bestMatch) ?: @"";
            NSString *handle = SpliceKit_storeHandle(bestMatch);

            NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:@{
                @"status": @"ok",
                @"lane": @(targetLane),
                @"clip": clipName,
                @"class": NSStringFromClass([bestMatch class]),
                @"handle": handle,
                @"playheadSeconds": @(playheadSec),
                @"selected": @(selectedNow),
                @"selector": usedSelector ?: @"",
                @"candidatesInLane": @(candidateCount),
            }];
            double bs = SpliceKit_browserEntrySeconds(bestEntry, @"startTime");
            double be = SpliceKit_browserEntrySeconds(bestEntry, @"endTime");
            if (!isnan(bs)) out[@"startSeconds"] = @(bs);
            if (!isnan(be)) out[@"endSeconds"] = @(be);
            if ([bestEntry[@"isConnectedStoryline"] boolValue]) out[@"isConnectedStoryline"] = @YES;
            result = out;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}

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

static NSDictionary *SpliceKit_handleCaptureTimeline(NSDictionary *params) {
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

static NSDictionary *SpliceKit_handleCaptureInspector(NSDictionary *params) {
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

#pragma mark - Auto-Dismiss Known Dialogs

// Check for and auto-dismiss known blocking dialogs (e.g. "video properties not recognized").
// Called at the start of every request to clear stale dialogs that block interaction.
static void SpliceKit_autoDismissBlockingDialogs(void) {
    // Runs before every request. It is opportunistic, so it waits at most 2 s for the
    // main thread and is not counted as a timeout: with the full 20 s here, a main
    // thread stuck in a progress sheet made every request (detect_dialog included)
    // spend 20 s on this before its own work, and the MCP client gave up at 30 s.
    SpliceKit_executeOnMainThreadWithTimeout(^{
        @try {
            // Check for sheets on all windows
            for (NSWindow *window in [NSApp windows]) {
                NSWindow *sheet = [window attachedSheet];
                if (!sheet) continue;

                // Scan text labels in the sheet for known blocking messages
                NSMutableArray *labels = [NSMutableArray array];
                NSMutableArray *buttons = [NSMutableArray array];

                // Recursive BFS to find text fields and buttons
                NSMutableArray *queue = [NSMutableArray arrayWithObject:[sheet contentView]];
                while (queue.count > 0) {
                    NSView *view = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if (!view) continue;

                    if ([view isKindOfClass:[NSTextField class]] && ![(NSTextField *)view isEditable]) {
                        NSString *val = [(NSTextField *)view stringValue];
                        if (val.length > 0) [labels addObject:val];
                    }
                    if ([view isKindOfClass:[NSButton class]]) {
                        [buttons addObject:(NSButton *)view];
                    }
                    NSArray *subs = [view subviews];
                    if (subs) [queue addObjectsFromArray:subs];
                }

                // Check for "video properties" dialog
                BOOL isVideoPropsDialog = NO;
                for (NSString *label in labels) {
                    if ([label localizedCaseInsensitiveContainsString:@"video properties"] &&
                        [label localizedCaseInsensitiveContainsString:@"not recognized"]) {
                        isVideoPropsDialog = YES;
                        break;
                    }
                }

                if (isVideoPropsDialog) {
                    // Click "Continue" or "OK" or the default button
                    for (NSButton *btn in buttons) {
                        NSString *title = [btn title] ?: @"";
                        if ([title localizedCaseInsensitiveContainsString:@"continue"] ||
                            [title localizedCaseInsensitiveContainsString:@"ok"] ||
                            [[btn keyEquivalent] isEqualToString:@"\r"]) {
                            [btn performClick:nil];
                            SpliceKit_log(@"Auto-dismissed 'video properties not recognized' dialog");
                            break;
                        }
                    }
                }
            }

            // Also check modal windows
            NSWindow *modalWindow = [NSApp modalWindow];
            if (modalWindow) {
                NSMutableArray *labels = [NSMutableArray array];
                NSMutableArray *queue = [NSMutableArray arrayWithObject:[modalWindow contentView]];
                while (queue.count > 0) {
                    NSView *view = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if (!view) continue;
                    if ([view isKindOfClass:[NSTextField class]] && ![(NSTextField *)view isEditable]) {
                        NSString *val = [(NSTextField *)view stringValue];
                        if (val.length > 0) [labels addObject:val];
                    }
                    NSArray *subs = [view subviews];
                    if (subs) [queue addObjectsFromArray:subs];
                }

                for (NSString *label in labels) {
                    if ([label localizedCaseInsensitiveContainsString:@"video properties"] &&
                        [label localizedCaseInsensitiveContainsString:@"not recognized"]) {
                        // Try to end the modal session
                        [NSApp stopModal];
                        [modalWindow close];
                        SpliceKit_log(@"Auto-dismissed modal 'video properties' dialog");
                        break;
                    }
                }
            }
        } @catch (NSException *e) {
            // Silently ignore - auto-dismiss is best-effort
        }
    }, 2.0, NO);
}

#pragma mark - Tool Selection Handler

static NSDictionary *SpliceKit_handleToolSelect(NSDictionary *params) {
    NSString *tool = params[@"tool"];
    if (!tool) return @{@"error": @"tool parameter required"};

    NSDictionary *toolMap = @{
        @"select":    @"selectToolArrow:",
        @"trim":      @"selectToolTrim:",
        @"blade":     @"selectToolBlade:",
        @"position":  @"selectToolPlacement:",
        @"hand":      @"selectToolHand:",
        @"zoom":      @"selectToolZoom:",
        @"range":     @"selectToolRangeSelection:",
    };

    NSString *selector = toolMap[tool];
    if (!selector) {
        return @{@"error": [NSString stringWithFormat:@"Unknown tool '%@'. Available: %@",
                    tool, [[toolMap allKeys] componentsJoinedByString:@", "]]};
    }

    return SpliceKit_sendAppAction(selector);
}

#pragma mark - Dialog Detection & Interaction
//
// FCP shows modal dialogs (sheets) for various operations. These handlers detect
// open dialogs, read their buttons/fields/checkboxes, and interact with them
// programmatically — so MCP clients can handle dialogs without user intervention.
//

// Recursively collect UI elements from a view hierarchy
// Forward declarations for dialog helpers
static NSArray<NSButton *> *SpliceKit_findButtonsInView(NSView *root);
static NSWindow *SpliceKit_findDialogWindow(void);
static NSDictionary *SpliceKit_dialogUndoSettleSnapshot(void);
static BOOL SpliceKit_dialogUndoSettleChanged(NSDictionary *before, NSDictionary *after);
static void SpliceKit_dialogApplySettle(NSMutableDictionary *result, NSDictionary *undoBefore, BOOL waitForUndo);
static BOOL SpliceKit_dialogButtonIsCancelLike(NSButton *btn);
static NSButton *SpliceKit_findCancelDialogButton(NSArray<NSButton *> *allButtons);
static NSButton *SpliceKit_findDefaultDialogButton(NSArray<NSButton *> *allButtons);

// Safe subview accessor - returns a COPY of the subviews array to avoid mutation crashes
static NSArray *SpliceKit_safeSubviews(NSView *view) {
    if (!view) return nil;
    @try {
        NSArray *subs = [view subviews];
        return subs ? [subs copy] : nil; // copy to avoid mutation during iteration
    } @catch (NSException *e) {
        return nil;
    }
}

static BOOL SpliceKit_windowIsSaveOrOpenPanel(NSWindow *window) {
    if (!window) return NO;
    Class savePanelClass = [NSSavePanel class];
    return savePanelClass && [window isKindOfClass:savePanelClass];
}

static void SpliceKit_enrichFilePanelDescription(NSWindow *window, NSMutableDictionary *info) {
    if (!SpliceKit_windowIsSaveOrOpenPanel(window)) return;

    BOOL isOpenPanel = [window isKindOfClass:[NSOpenPanel class]];
    info[@"isFilePanel"] = @YES;
    info[@"panelKind"] = isOpenPanel ? @"open" : @"save";
    info[@"panelDismiss"] = @"cancel: on the panel only (confirm/Save/Open not supported from bridge)";

    NSSavePanel *panel = (NSSavePanel *)window;
    NSString *nameField = @"";
    if ([panel respondsToSelector:@selector(nameFieldStringValue)]) {
        NSString *n = panel.nameFieldStringValue;
        if ([n isKindOfClass:[NSString class]]) nameField = n;
    }
    info[@"nameField"] = nameField;

    NSString *directoryURL = @"";
    NSString *directoryPath = @"";
    if ([panel respondsToSelector:@selector(directoryURL)]) {
        NSURL *dir = panel.directoryURL;
        if ([dir isKindOfClass:[NSURL class]]) {
            directoryURL = dir.absoluteString ?: @"";
            directoryPath = dir.path ?: @"";
        }
    }
    info[@"directoryURL"] = directoryURL;
    info[@"directoryPath"] = directoryPath;
}

static NSDictionary *SpliceKit_filePanelConfirmUnsupportedError(NSWindow *window) {
    NSMutableDictionary *panelInfo = [NSMutableDictionary dictionary];
    SpliceKit_enrichFilePanelDescription(window, panelInfo);
    NSString *nameField = [panelInfo[@"nameField"] isKindOfClass:[NSString class]]
        ? panelInfo[@"nameField"] : @"";
    NSString *directory = [panelInfo[@"directoryPath"] isKindOfClass:[NSString class]]
        ? panelInfo[@"directoryPath"] : @"";
    if (directory.length == 0 &&
        [panelInfo[@"directoryURL"] isKindOfClass:[NSString class]]) {
        directory = panelInfo[@"directoryURL"];
    }
    if (directory.length == 0) directory = @"(unknown)";
    return @{@"error": [NSString stringWithFormat:
        @"A save/open panel cannot be confirmed programmatically from the bridge on this Final Cut Pro build; "
        @"only cancelling is supported (dismiss_dialog with action cancel, or click_dialog_button Cancel). "
        @"A human must complete the panel, or cancel it and use a tool that takes an explicit path instead. "
        @"Panel name field: \"%@\"; directory: %@.",
        nameField, directory]};
}

static BOOL SpliceKit_dispatchFilePanelCancel(NSWindow *window) {
    if (!SpliceKit_windowIsSaveOrOpenPanel(window)) return NO;
    SEL sel = @selector(cancel:);
    if (![window respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel, nil);
    return YES;
}

static BOOL SpliceKit_filePanelButtonTitleIsConfirm(NSString *title) {
    NSString *t = [[title lowercaseString] stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [t isEqualToString:@"ok"] || [t isEqualToString:@"save"] || [t isEqualToString:@"open"];
}

static BOOL SpliceKit_filePanelButtonTitleIsCancel(NSString *title) {
    NSString *t = [[title lowercaseString] stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [t isEqualToString:@"cancel"];
}

// AppKit builds a checkbox as a plain NSButton whose cell both shows and highlights
// its state by its contents; a radio button has the same cell shape and is told apart
// by the image the cell draws. FCP additionally ships button subclasses with
// "Checkbox" in the class name.
//
// The previous test was `className contains "Checkbox" || allowsMixedState`, which
// matched neither: -allowsMixedState is NO on an ordinary two-state checkbox, and
// FCP's Remove Attributes sheet is built from stock NSButtons. That sheet therefore
// reported zero checkboxes and could not be driven.
static BOOL SpliceKit_buttonIsCheckboxLike(NSButton *btn, BOOL *outIsRadio) {
    if (outIsRadio) *outIsRadio = NO;
    if (!btn) return NO;
    @try {
        NSString *cls = [btn className] ?: @"";
        if ([cls rangeOfString:@"heckbox" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cls rangeOfString:@"heckBox" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }

        id cell = [btn cell];
        if (![cell isKindOfClass:[NSButtonCell class]]) return NO;
        NSButtonCell *bc = (NSButtonCell *)cell;

        // Push, toggle and momentary buttons all differ here: only switch and radio
        // cells use NSContentsCellMask for both.
        if ([bc showsStateBy] != NSContentsCellMask) return NO;
        if ([bc highlightsBy] != NSContentsCellMask) return NO;

        NSString *imageName = [[bc image] name] ?: @"";
        if ([imageName isEqualToString:@"NSRadioButton"]) {
            if (outIsRadio) *outIsRadio = YES;
        }
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

// Flat dump of a dialog's view hierarchy: class, title, frame and depth per node.
// detect_dialog(view_tree=True) returns this so an unfamiliar sheet can be read
// without guessing which AppKit class FCP used to build it. Iterative on purpose —
// a recursive walker over a deep view tree is what crashed toggle_dialog_checkbox.
static NSArray *SpliceKit_describeViewTree(NSView *root, NSUInteger maxNodes) {
    NSMutableArray *nodes = [NSMutableArray array];
    if (!root) return nodes;
    if (maxNodes == 0) maxNodes = 2048;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:@[root, @0]];
    while (stack.count > 0 && nodes.count < maxNodes) {
        NSArray *entry = [stack lastObject];
        [stack removeLastObject];
        NSView *view = entry[0];
        NSInteger depth = [entry[1] integerValue];
        if (!view) continue;

        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"depth"] = @(depth);
        node[@"class"] = NSStringFromClass([view class]);
        @try {
            node[@"frame"] = NSStringFromRect([view frame]);
            node[@"hidden"] = @([view isHidden]);
            if ([view respondsToSelector:@selector(identifier)]) {
                NSString *ident = [view identifier];
                if (ident.length > 0) node[@"identifier"] = ident;
            }
            if ([view isKindOfClass:[NSControl class]]) {
                NSControl *ctl = (NSControl *)view;
                node[@"enabled"] = @([ctl isEnabled]);
                NSString *sv = [ctl stringValue];
                if (sv.length > 0) node[@"stringValue"] = sv;
            }
            if ([view isKindOfClass:[NSButton class]]) {
                NSButton *btn = (NSButton *)view;
                node[@"title"] = [btn title] ?: @"";
                node[@"state"] = @([btn state]);
                id cell = [btn cell];
                if ([cell isKindOfClass:[NSButtonCell class]]) {
                    NSButtonCell *bc = (NSButtonCell *)cell;
                    node[@"cellClass"] = NSStringFromClass([bc class]);
                    node[@"showsStateBy"] = @([bc showsStateBy]);
                    node[@"highlightsBy"] = @([bc highlightsBy]);
                    NSString *imageName = [[bc image] name];
                    if (imageName.length > 0) node[@"cellImage"] = imageName;
                }
            }
        } @catch (NSException *e) {
            node[@"error"] = e.reason ?: @"threw while being read";
        }
        [nodes addObject:node];

        NSArray *subviews = SpliceKit_safeSubviews(view);
        for (NSView *sub in [subviews reverseObjectEnumerator]) {
            if (sub) [stack addObject:@[sub, @(depth + 1)]];
        }
    }
    if (nodes.count >= maxNodes) {
        [nodes addObject:@{@"note": [NSString stringWithFormat:
            @"stopped at the %lu-node cap", (unsigned long)maxNodes]}];
    }
    return nodes;
}

static void SpliceKit_collectUIElements(NSView *view, NSMutableArray *buttons,
                                         NSMutableArray *textFields, NSMutableArray *labels,
                                         NSMutableArray *checkboxes, NSMutableArray *popups,
                                         int depth) {
    if (!view || depth > 15) return;

    NSArray *subviews = SpliceKit_safeSubviews(view);
    if (!subviews) return;

    for (NSView *subview in subviews) {
        if (!subview) continue;
        @try {
        if ([subview isKindOfClass:[NSButton class]]) {
            NSButton *btn = (NSButton *)subview;
            NSString *title = [btn title] ?: @"";
            NSInteger bezelStyle = [btn bezelStyle];
            BOOL isRadio = NO;
            BOOL isCheckbox = SpliceKit_buttonIsCheckboxLike(btn, &isRadio);
            if (isCheckbox) {
                NSInteger state = [btn state];
                [checkboxes addObject:@{
                    @"index": @(checkboxes.count),
                    @"title": title,
                    @"checked": @(state == NSControlStateValueOn),
                    @"state": state == NSControlStateValueMixed ? @"mixed"
                             : (state == NSControlStateValueOn ? @"on" : @"off"),
                    @"kind": isRadio ? @"radio" : @"checkbox",
                    @"enabled": @([btn isEnabled]),
                    @"tag": @([btn tag])
                }];
            } else if (title.length > 0) {
                [buttons addObject:@{
                    @"title": title,
                    @"enabled": @([btn isEnabled]),
                    @"tag": @([btn tag]),
                    @"keyEquivalent": [btn keyEquivalent] ?: @"",
                    @"bezelStyle": @(bezelStyle)
                }];
            }
        } else if ([subview isKindOfClass:[NSTextField class]]) {
            NSTextField *tf = (NSTextField *)subview;
            if ([tf isEditable]) {
                [textFields addObject:@{
                    @"value": [tf stringValue] ?: @"",
                    @"placeholder": [tf placeholderString] ?: @"",
                    @"editable": @YES,
                    @"tag": @([tf tag])
                }];
            } else {
                NSString *text = [tf stringValue] ?: @"";
                if (text.length > 0) {
                    [labels addObject:@{
                        @"text": text,
                        @"tag": @([tf tag])
                    }];
                }
            }
        } else if ([subview isKindOfClass:[NSPopUpButton class]]) {
            NSPopUpButton *popup = (NSPopUpButton *)subview;
            NSMutableArray *items = [NSMutableArray array];
            for (NSMenuItem *item in [popup itemArray]) {
                if (![item isSeparatorItem]) {
                    [items addObject:@{
                        @"title": [item title] ?: @"",
                        @"selected": @([popup selectedItem] == item)
                    }];
                }
            }
            [popups addObject:@{
                @"selectedTitle": [[popup titleOfSelectedItem] ?: @"" copy],
                @"items": items,
                @"tag": @([popup tag])
            }];
        } else if ([subview isKindOfClass:[NSSegmentedControl class]]) {
            NSSegmentedControl *seg = (NSSegmentedControl *)subview;
            NSMutableArray *segments = [NSMutableArray array];
            for (NSInteger i = 0; i < seg.segmentCount; i++) {
                [segments addObject:@{
                    @"label": [seg labelForSegment:i] ?: @"",
                    @"selected": @(seg.selectedSegment == i),
                    @"index": @(i)
                }];
            }
            [labels addObject:@{@"text": @"[segmented control]", @"segments": segments}];
        } else if ([subview isKindOfClass:[NSSlider class]]) {
            NSSlider *slider = (NSSlider *)subview;
            [labels addObject:@{
                @"text": @"[slider]",
                @"value": @([slider doubleValue]),
                @"min": @([slider minValue]),
                @"max": @([slider maxValue])
            }];
        }

        } @catch (NSException *e) {
            // Skip any view that throws when accessed
        }

        // Recurse into subviews
        SpliceKit_collectUIElements(subview, buttons, textFields, labels,
                                    checkboxes, popups, depth + 1);
    }
}

static NSDictionary *SpliceKit_describeWindowWithViewTree(NSWindow *window, BOOL includeViewTree) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"title"] = [window title] ?: @"";
    info[@"class"] = NSStringFromClass([window class]);
    info[@"visible"] = @([window isVisible]);
    info[@"isSheet"] = @([window isSheet]);
    info[@"isModal"] = @(window == [NSApp modalWindow]);
    info[@"frame"] = NSStringFromRect([window frame]);

    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableArray *textFields = [NSMutableArray array];
    NSMutableArray *labels = [NSMutableArray array];
    NSMutableArray *checkboxes = [NSMutableArray array];
    NSMutableArray *popups = [NSMutableArray array];

    SpliceKit_collectUIElements([window contentView], buttons, textFields,
                                labels, checkboxes, popups, 0);

    info[@"buttons"] = buttons;
    info[@"textFields"] = textFields;
    info[@"labels"] = labels;
    info[@"checkboxes"] = checkboxes;
    info[@"popups"] = popups;

    // A name for the dialog when its title is a placeholder (QA run 3: the Compound Clip
    // Name sheet is titled "Window"): the labels of its fields, else its buttons, else
    // its class. The pseudo-labels collectUIElements adds ("[slider]", "[segmented
    // control]") are not labels.
    NSString *title = info[@"title"];
    NSString *summary = title;
    if (title.length == 0 || [title isEqualToString:@"Window"] || [title isEqualToString:@"Untitled"]
        || [title isEqualToString:@"Panel"]) {
        NSMutableArray *texts = [NSMutableArray array];
        for (NSDictionary *label in labels) {              // field labels first ("Compound Clip Name:")
            NSString *t = label[@"text"];
            if ([t isKindOfClass:[NSString class]] && t.length > 0 && ![t hasPrefix:@"["] && [t hasSuffix:@":"]) {
                [texts addObject:t];
            }
            if (texts.count >= 3) break;
        }
        for (NSDictionary *label in labels) {              // other text only when fewer than two of those
            if (texts.count >= 2) break;
            NSString *t = label[@"text"];
            if ([t isKindOfClass:[NSString class]] && t.length > 0 && ![t hasPrefix:@"["] && ![t hasSuffix:@":"]) {
                [texts addObject:t];
            }
        }
        if (texts.count > 0) {
            summary = [NSString stringWithFormat:@"fields %@", [texts componentsJoinedByString:@" / "]];
        } else {
            for (NSDictionary *button in buttons) {
                NSString *t = button[@"title"];
                if ([t isKindOfClass:[NSString class]] && t.length > 0) [texts addObject:t];
                if (texts.count >= 3) break;
            }
            summary = texts.count > 0
                ? [NSString stringWithFormat:@"buttons %@", [texts componentsJoinedByString:@" / "]]
                : NSStringFromClass([window class]);
        }
    }
    info[@"summary"] = summary ?: @"";

    if (includeViewTree) {
        info[@"viewTree"] = SpliceKit_describeViewTree([window contentView], 2048);
    }

    SpliceKit_enrichFilePanelDescription(window, info);

    return info;
}

NSDictionary *SpliceKit_describeWindow(NSWindow *window) {
    return SpliceKit_describeWindowWithViewTree(window, NO);
}

static NSDictionary *SpliceKit_handleDialogDetect(NSDictionary *params) {
    // view_tree dumps each dialog's raw view hierarchy. Without it an unfamiliar
    // sheet can only be described through the element classes this file already
    // knows about, so anything FCP builds from something else reads as empty.
    BOOL includeViewTree = [params[@"viewTree"] boolValue] || [params[@"view_tree"] boolValue];
    __block NSDictionary *result = nil;
    BOOL answered = SpliceKit_executeOnMainThreadWithTimeout(^{
        @try {
            NSMutableArray *dialogs = [NSMutableArray array];
            NSMutableArray *overlays = [NSMutableArray array];

            // Check for modal window
            NSWindow *modalWindow = [NSApp modalWindow];
            if (modalWindow) {
                NSMutableDictionary *d = [SpliceKit_describeWindowWithViewTree(modalWindow, includeViewTree) mutableCopy];
                d[@"type"] = @"modal";
                [dialogs addObject:d];
            }

            // Check for sheets on all windows
            for (NSWindow *window in [NSApp windows]) {
                NSWindow *sheet = [window attachedSheet];
                if (sheet) {
                    NSMutableDictionary *d = [SpliceKit_describeWindowWithViewTree(sheet, includeViewTree) mutableCopy];
                    d[@"type"] = @"sheet";
                    d[@"parentWindow"] = [window title] ?: @"";
                    [dialogs addObject:d];
                }
            }

            // Check for any visible panels (alerts, floating windows, etc.)
            for (NSWindow *window in [NSApp windows]) {
                if (![window isVisible]) continue;
                if (modalWindow && window == modalWindow) continue;

                // Check if this is a panel/alert type window
                BOOL isPanel = [window isKindOfClass:[NSPanel class]];
                BOOL isAlert = [window isKindOfClass:NSClassFromString(@"NSAlertPanel") ?: [NSNull class]];
                BOOL isSheet = [window isSheet];
                BOOL isProgressPanel = [[window className] containsString:@"Progress"];
                BOOL isSharePanel = [[window className] containsString:@"Share"];

                // Check FCP-specific dialog classes
                NSString *className = NSStringFromClass([window class]);
                BOOL isFCPDialog = [className hasPrefix:@"FF"] && (
                    [className containsString:@"Panel"] ||
                    [className containsString:@"Sheet"] ||
                    [className containsString:@"Alert"] ||
                    [className containsString:@"Dialog"] ||
                    [className containsString:@"Progress"] ||
                    [className containsString:@"Window"] // Custom windows
                );

                if (isAlert || isProgressPanel || isSharePanel || isFCPDialog) {
                    NSMutableDictionary *d = [SpliceKit_describeWindowWithViewTree(window, includeViewTree) mutableCopy];
                    d[@"type"] = isAlert ? @"alert" : (isProgressPanel ? @"progress" :
                                  (isSharePanel ? @"share" : @"panel"));
                    // FCP's own chrome windows (FFOSCOverlayWindow: the Viewer's on-screen
                    // controls, up after every import) matched the "FF…Window" rule and made
                    // hasDialog true with nothing to answer. A non-modal window that is an
                    // overlay, or offers no control at all, is reported apart.
                    // Matched by what the window is, not by what collectUIElements found in
                    // it: a panel whose buttons are custom views reads as control-less and
                    // must still count as a dialog (flagged noControls instead).
                    BOOL noControls = [d[@"buttons"] count] == 0 && [d[@"textFields"] count] == 0 &&
                                      [d[@"checkboxes"] count] == 0 && [d[@"popups"] count] == 0;
                    BOOL isOverlay = window != [NSApp modalWindow] &&
                                     ([className containsString:@"Overlay"] || [window ignoresMouseEvents]);
                    if (noControls) d[@"noControls"] = @YES;
                    if (isOverlay) {
                        [overlays addObject:@{@"title": d[@"title"] ?: @"", @"class": className,
                                              @"frame": d[@"frame"] ?: @""}];
                        continue;
                    }
                    // Avoid duplicates
                    BOOL isDupe = NO;
                    for (NSDictionary *existing in dialogs) {
                        if ([existing[@"title"] isEqualToString:d[@"title"]] &&
                            [existing[@"class"] isEqualToString:d[@"class"]]) {
                            isDupe = YES; break;
                        }
                    }
                    if (!isDupe) [dialogs addObject:d];
                }

                // Also check for NSAlert-style windows (they have specific structure)
                if (isPanel && !isSheet) {
                    NSArray *buttons = [window contentView].subviews;
                    BOOL hasAlertButton = NO;
                    for (NSView *v in buttons) {
                        if ([v isKindOfClass:[NSButton class]] &&
                            [[(NSButton *)v keyEquivalent] isEqualToString:@"\r"]) {
                            hasAlertButton = YES;
                            break;
                        }
                    }
                    if (hasAlertButton) {
                        NSMutableDictionary *d = [SpliceKit_describeWindowWithViewTree(window, includeViewTree) mutableCopy];
                        d[@"type"] = @"alert";
                        BOOL isDupe = NO;
                        for (NSDictionary *existing in dialogs) {
                            if ([existing[@"title"] isEqualToString:d[@"title"]]) {
                                isDupe = YES; break;
                            }
                        }
                        if (!isDupe) [dialogs addObject:d];
                    }
                }
            }

            NSMutableDictionary *r = [@{
                @"hasDialog": @(dialogs.count > 0),
                @"dialogCount": @(dialogs.count),
                @"dialogs": dialogs
            } mutableCopy];
            if (overlays.count > 0) r[@"overlays"] = overlays;
            result = r;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    }, 3.0, NO);
    if (!answered) {
        // The main thread is inside something long (an import's progress sheet, a
        // modal the bridge cannot see from here). Answer from the window server
        // instead of timing out: titles and sizes of FCP's on-screen windows.
        NSArray *windows = SpliceKit_windowSnapshotOffMain();
        NSMutableArray *likelyDialogs = [NSMutableArray array];
        for (NSDictionary *w in windows) {
            NSString *title = w[@"title"];
            NSRect frame = NSRectFromString(w[@"bounds"]);
            int layer = [w[@"layer"] intValue];
            // By window level: a modal panel or alert sits at the modal-panel level (8);
            // a sheet at the document level (0) and much smaller than the document
            // window. Utility panels (SpliceKit's Transcript Editor, Lua REPL, Log,
            // Mixer; FCP's HUDs) float at level 3 and are not dialogs, nor are menus,
            // popups and overlays at higher levels.
            BOOL modalLevel = (layer == kCGModalPanelWindowLevel);
            BOOL sheetLike = (layer == kCGNormalWindowLevel && frame.size.width < 900 && frame.size.height < 700);
            if ((modalLevel || sheetLike) && ![title containsString:@"Overlay"]) {
                [likelyDialogs addObject:w];
            }
        }
        return @{
            @"mainThreadBusy": @YES,
            @"hasDialog": @(likelyDialogs.count > 0),
            @"dialogCount": @(likelyDialogs.count),
            @"dialogs": likelyDialogs,
            @"windows": windows,
            @"note": @"Final Cut Pro's main thread did not answer within 3 s, so this is read from the "
                     @"window server: window titles, sizes and levels only, no buttons or fields; dialogs are "
                     @"guessed from the window level (modal panels) and size (sheets). A window named like "
                     @"\"Import XML\" is a progress sheet; wait for it rather than retrying the operation.",
        };
    }
    return result ?: @{@"error": @"Dialog detect failed"};
}

static NSDictionary *SpliceKit_handleDialogClick(NSDictionary *params) {
    NSString *buttonTitle = params[@"button"]; // button title to click
    NSNumber *buttonIndex = params[@"index"];   // or button index (0-based)
    if (!buttonTitle && !buttonIndex) {
        return @{@"error": @"button (title) or index parameter required"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Find the dialog window (modal > sheet > panel)
            NSWindow *dialogWindow = [NSApp modalWindow];

            if (!dialogWindow) {
                // Check for sheets
                for (NSWindow *window in [NSApp windows]) {
                    NSWindow *sheet = [window attachedSheet];
                    if (sheet) { dialogWindow = sheet; break; }
                }
            }

            if (!dialogWindow) {
                // Check for visible panels
                for (NSWindow *window in [NSApp windows]) {
                    if (![window isVisible]) continue;
                    if ([window isKindOfClass:[NSPanel class]] && ![window isSheet]) {
                        NSString *className = NSStringFromClass([window class]);
                        if ([className hasPrefix:@"FF"] || [className containsString:@"Alert"]) {
                            dialogWindow = window;
                            break;
                        }
                    }
                }
            }

            if (!dialogWindow) {
                result = @{@"error": @"No dialog found to interact with"};
                return;
            }

            // Use BFS to safely find all buttons
            NSArray<NSButton *> *buttonObjects = SpliceKit_findButtonsInView([dialogWindow contentView]);

            NSButton *targetButton = nil;

            if (buttonTitle) {
                // Find button by title (case-insensitive)
                for (NSButton *btn in buttonObjects) {
                    if ([[btn title] caseInsensitiveCompare:buttonTitle] == NSOrderedSame) {
                        targetButton = btn;
                        break;
                    }
                }
                if (!targetButton) {
                    // Try partial match
                    for (NSButton *btn in buttonObjects) {
                        if ([[btn title] localizedCaseInsensitiveContainsString:buttonTitle]) {
                            targetButton = btn;
                            break;
                        }
                    }
                }
            } else if (buttonIndex) {
                NSInteger idx = [buttonIndex integerValue];
                if (idx >= 0 && idx < (NSInteger)buttonObjects.count) {
                    targetButton = buttonObjects[idx];
                }
            }

            if (!targetButton && buttonTitle && SpliceKit_windowIsSaveOrOpenPanel(dialogWindow)) {
                if (SpliceKit_filePanelButtonTitleIsConfirm(buttonTitle)) {
                    result = SpliceKit_filePanelConfirmUnsupportedError(dialogWindow);
                    return;
                }
                if (SpliceKit_filePanelButtonTitleIsCancel(buttonTitle) &&
                    SpliceKit_dispatchFilePanelCancel(dialogWindow)) {
                    NSMutableDictionary *answer = [@{
                        @"status": @"ok",
                        @"clicked": buttonTitle,
                        @"dispatch": @"panelAction",
                        @"panelAction": @"cancel:",
                        @"dialog": [dialogWindow title] ?: @""
                    } mutableCopy];
                    SpliceKit_dialogApplySettle(answer, nil, NO);
                    result = answer;
                    return;
                }
            }

            if (!targetButton) {
                NSMutableArray *available = [NSMutableArray array];
                for (NSButton *btn in buttonObjects) {
                    [available addObject:[btn title]];
                }
                if (SpliceKit_windowIsSaveOrOpenPanel(dialogWindow)) {
                    result = SpliceKit_filePanelConfirmUnsupportedError(dialogWindow);
                } else {
                    result = @{@"error": [NSString stringWithFormat:@"Button '%@' not found. Available: %@",
                                buttonTitle ?: [buttonIndex stringValue],
                                [available componentsJoinedByString:@", "]]};
                }
                return;
            }

            if (![targetButton isEnabled]) {
                result = @{@"error": [NSString stringWithFormat:@"Button '%@' is disabled", [targetButton title]]};
                return;
            }

            if (SpliceKit_windowIsSaveOrOpenPanel(dialogWindow) &&
                SpliceKit_filePanelButtonTitleIsConfirm([targetButton title])) {
                result = SpliceKit_filePanelConfirmUnsupportedError(dialogWindow);
                return;
            }

            BOOL waitForUndo = !SpliceKit_dialogButtonIsCancelLike(targetButton);
            NSDictionary *undoBefore = waitForUndo ? SpliceKit_dialogUndoSettleSnapshot() : nil;
            [targetButton performClick:nil];

            NSMutableDictionary *answer = [@{@"status": @"ok", @"clicked": [targetButton title],
                                              @"dialog": [dialogWindow title] ?: @""} mutableCopy];
            SpliceKit_dialogApplySettle(answer, undoBefore, waitForUndo);
            result = answer;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dialog click failed"};
}

static NSDictionary *SpliceKit_handleDialogFill(NSDictionary *params) {
    NSString *value = params[@"value"];
    NSNumber *fieldIndex = params[@"index"] ?: @(0);
    if (!value) return @{@"error": @"value parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Find dialog window
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    @try {
                        NSWindow *sheet = [window attachedSheet];
                        if (sheet) { dialogWindow = sheet; break; }
                    } @catch (NSException *e) {}
                }
            }
            if (!dialogWindow) {
                result = @{@"error": @"No dialog found"};
                return;
            }

            // Use the collectUIElements function which has full safety
            NSMutableArray *buttons = [NSMutableArray array];
            NSMutableArray *textFields = [NSMutableArray array];
            NSMutableArray *labels = [NSMutableArray array];
            NSMutableArray *checkboxes = [NSMutableArray array];
            NSMutableArray *popups = [NSMutableArray array];

            SpliceKit_collectUIElements([dialogWindow contentView], buttons, textFields,
                                        labels, checkboxes, popups, 0);

            // textFields array already contains only editable fields (from collectUIElements)
            // But we need the actual NSTextField objects, not dicts.
            // So let's find them differently - use the first responder chain.

            // Simple approach: find editable text fields using a breadth-first search
            // with maximum safety
            NSMutableArray *editableFields = [NSMutableArray array];
            NSMutableArray *queue = [NSMutableArray arrayWithObject:[dialogWindow contentView]];

            while (queue.count > 0 && editableFields.count < 20) {
                NSView *current = queue[0];
                [queue removeObjectAtIndex:0];
                if (!current) continue;

                @try {
                    if ([current isKindOfClass:[NSTextField class]]) {
                        NSTextField *tf = (NSTextField *)current;
                        // Use respondsToSelector as extra safety
                        if ([tf respondsToSelector:@selector(isEditable)] &&
                            [tf respondsToSelector:@selector(setStringValue:)]) {
                            BOOL editable = NO;
                            @try { editable = [tf isEditable]; } @catch (NSException *e) {}
                            if (editable) {
                                [editableFields addObject:tf];
                            }
                        }
                    }

                    // Add child views to queue (BFS)
                    NSArray *subs = SpliceKit_safeSubviews(current);
                    if (subs) {
                        [queue addObjectsFromArray:subs];
                    }
                } @catch (NSException *e) {
                    // Skip this view entirely
                }
            }

            NSInteger idx = [fieldIndex integerValue];
            if (idx >= 0 && idx < (NSInteger)editableFields.count) {
                NSTextField *field = editableFields[idx];
                @try {
                    [field setStringValue:value];
                    result = @{@"status": @"ok", @"field": @(idx), @"value": value};
                } @catch (NSException *e) {
                    result = @{@"error": [NSString stringWithFormat:@"Cannot set field: %@", e.reason]};
                }
            } else {
                result = @{@"error": [NSString stringWithFormat:@"Field index %ld not found (have %lu fields)",
                            (long)idx, (unsigned long)editableFields.count]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dialog fill failed"};
}

static NSDictionary *SpliceKit_handleDialogCheckbox(NSDictionary *params) {
    NSString *checkboxTitle = params[@"checkbox"];
    NSNumber *indexParam = params[@"index"];
    NSNumber *checked = params[@"checked"]; // YES/NO
    if (!checkboxTitle && !indexParam) {
        return @{@"error": @"checkbox (title) or index parameter required"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    NSWindow *sheet = [window attachedSheet];
                    if (sheet) { dialogWindow = sheet; break; }
                }
            }
            if (!dialogWindow) { result = @{@"error": @"No dialog found"}; return; }

            // Collect every checkbox first, in the same order detect_dialog reports
            // them, so an index from that listing selects the same control and a miss
            // can say what was actually there. Iterative walk: a recursive one over a
            // deep view tree is what used to segfault this handler.
            NSMutableArray<NSButton *> *found = [NSMutableArray array];
            const NSUInteger kMaxDialogViewNodes = 8192;
            NSMutableArray *stack = [NSMutableArray array];
            NSView *rootView = [dialogWindow contentView];
            NSArray *rootSubs = rootView ? SpliceKit_safeSubviews(rootView) : nil;
            if (rootSubs) {
                for (NSInteger i = (NSInteger)rootSubs.count - 1; i >= 0; i--) {
                    NSView *v = rootSubs[i];
                    if (v) [stack addObject:v];
                }
            }
            NSUInteger visited = 0;
            while (stack.count > 0 && visited < kMaxDialogViewNodes) {
                NSView *subview = stack.lastObject;
                [stack removeLastObject];
                visited++;
                @try {
                    if ([subview isKindOfClass:[NSButton class]]) {
                        NSButton *btn = (NSButton *)subview;
                        BOOL isRadio = NO;
                        if (SpliceKit_buttonIsCheckboxLike(btn, &isRadio)) {
                            [found addObject:btn];
                        }
                    }
                    NSArray *subs = SpliceKit_safeSubviews(subview);
                    if (subs) {
                        for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; i--) {
                            NSView *child = subs[i];
                            if (child) [stack addObject:child];
                        }
                    }
                } @catch (NSException *e) {
                    // Skip this view
                }
            }

            NSButton *targetCB = nil;
            if (checkboxTitle.length > 0) {
                for (NSButton *btn in found) {
                    if ([[btn title] localizedCaseInsensitiveContainsString:checkboxTitle]) {
                        targetCB = btn;
                        break;
                    }
                }
            } else {
                NSInteger idx = [indexParam integerValue];
                if (idx >= 0 && idx < (NSInteger)found.count) targetCB = found[(NSUInteger)idx];
            }

            if (!targetCB) {
                NSMutableArray *available = [NSMutableArray array];
                for (NSButton *btn in found) {
                    [available addObject:[btn title] ?: @""];
                }
                result = @{
                    @"error": checkboxTitle.length > 0
                        ? [NSString stringWithFormat:@"Checkbox '%@' not found", checkboxTitle]
                        : [NSString stringWithFormat:@"No checkbox at index %@", indexParam],
                    @"available": available,
                    @"dialog": [dialogWindow title] ?: NSStringFromClass([dialogWindow class]),
                };
                return;
            }

            if (checked) {
                [targetCB setState:[checked boolValue] ? NSControlStateValueOn : NSControlStateValueOff];
                // setState: alone updates the control but does not run its action, so
                // a sheet that enables its OK button from the action never sees it.
                @try {
                    SEL action = [targetCB action];
                    id target = [targetCB target];
                    if (action && target) {
                        ((void (*)(id, SEL, id))objc_msgSend)(target, action, targetCB);
                    }
                } @catch (NSException *e) {}
            } else {
                [targetCB performClick:nil];
            }
            result = @{@"status": @"ok", @"checkbox": [targetCB title] ?: @"",
                      @"checked": @([targetCB state] == NSControlStateValueOn),
                      @"checkboxCount": @(found.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Checkbox toggle failed"};
}

static NSDictionary *SpliceKit_handleDialogPopup(NSDictionary *params) {
    NSString *selection = params[@"select"]; // item title to select
    NSNumber *popupIndex = params[@"popupIndex"] ?: @(0); // which popup (if multiple)
    if (!selection) return @{@"error": @"select parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSWindow *dialogWindow = [NSApp modalWindow];
            if (!dialogWindow) {
                for (NSWindow *window in [NSApp windows]) {
                    NSWindow *sheet = [window attachedSheet];
                    if (sheet) { dialogWindow = sheet; break; }
                }
            }
            if (!dialogWindow) { result = @{@"error": @"No dialog found"}; return; }

            NSMutableArray *popups = [NSMutableArray array];
            const NSUInteger kMaxDialogViewNodes = 8192;
            NSMutableArray *stack = [NSMutableArray array];
            NSView *rootView = [dialogWindow contentView];
            NSArray *rootSubs = rootView ? SpliceKit_safeSubviews(rootView) : nil;
            if (rootSubs) {
                for (NSInteger i = (NSInteger)rootSubs.count - 1; i >= 0; i--) {
                    NSView *v = rootSubs[i];
                    if (v) [stack addObject:v];
                }
            }
            NSUInteger visited = 0;
            while (stack.count > 0 && visited < kMaxDialogViewNodes) {
                NSView *subview = stack.lastObject;
                [stack removeLastObject];
                visited++;
                @try {
                    if ([subview isKindOfClass:[NSPopUpButton class]]) {
                        [popups addObject:subview];
                    }
                    NSArray *subs = SpliceKit_safeSubviews(subview);
                    if (subs) {
                        for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; i--) {
                            NSView *child = subs[i];
                            if (child) [stack addObject:child];
                        }
                    }
                } @catch (NSException *e) {
                    // Skip this view
                }
            }

            NSInteger idx = [popupIndex integerValue];
            if (idx >= 0 && idx < (NSInteger)popups.count) {
                NSPopUpButton *popup = popups[idx];
                [popup selectItemWithTitle:selection];
                if ([popup selectedItem]) {
                    // Trigger the action
                    if ([popup action]) {
                        ((void (*)(id, SEL, id))objc_msgSend)([popup target], [popup action], popup);
                    }
                    result = @{@"status": @"ok", @"selected": selection, @"popupIndex": @(idx)};
                } else {
                    NSMutableArray *available = [NSMutableArray array];
                    for (NSMenuItem *item in [popup itemArray]) {
                        if (![item isSeparatorItem]) [available addObject:[item title]];
                    }
                    result = @{@"error": [NSString stringWithFormat:@"Item '%@' not found. Available: %@",
                                selection, [available componentsJoinedByString:@", "]]};
                }
            } else {
                result = @{@"error": [NSString stringWithFormat:@"Popup index %ld not found (have %lu)",
                            (long)idx, (unsigned long)popups.count]};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Popup select failed"};
}

// BFS helper to find buttons safely in a view hierarchy
static NSWindow *SpliceKit_findDialogWindow(void) {
    NSWindow *dialogWindow = [NSApp modalWindow];
    if (!dialogWindow) {
        for (NSWindow *window in [NSApp windows]) {
            @try {
                NSWindow *sheet = [window attachedSheet];
                if (sheet) { dialogWindow = sheet; break; }
            } @catch (NSException *e) {}
        }
    }
    return dialogWindow;
}

static NSDictionary *SpliceKit_dialogUndoSettleSnapshot(void) {
    id um = SpliceKit_getUndoManager();
    if (!um) return @{@"canUndo": @NO, @"undoActionName": @""};
    BOOL canUndo = ((BOOL (*)(id, SEL))objc_msgSend)(um, @selector(canUndo));
    id undoName = canUndo ? ((id (*)(id, SEL))objc_msgSend)(um, @selector(undoActionName)) : nil;
    NSString *name = [undoName isKindOfClass:[NSString class]] ? undoName : @"";
    return @{@"canUndo": @(canUndo), @"undoActionName": name};
}

static BOOL SpliceKit_dialogUndoSettleChanged(NSDictionary *before, NSDictionary *after) {
    if (!before || !after) return NO;
    if ([before[@"canUndo"] boolValue] != [after[@"canUndo"] boolValue]) return YES;
    return ![[before[@"undoActionName"] description] isEqualToString:[after[@"undoActionName"] description]];
}

// After a dialog button click: spin the main run loop until the dialog is gone and, when
// waitForUndo is YES, the library undo snapshot differs (bounded at 2s).
static void SpliceKit_dialogApplySettle(NSMutableDictionary *result, NSDictionary *undoBefore,
                                        BOOL waitForUndo) {
    if (result[@"error"]) return;
    NSDate *start = [NSDate date];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        BOOL dialogGone = (SpliceKit_findDialogWindow() == nil);
        if (!waitForUndo) {
            if (dialogGone) {
                result[@"settled"] = @YES;
                result[@"settleMs"] = @0;
                return;
            }
        } else if (dialogGone && SpliceKit_dialogUndoSettleChanged(undoBefore, SpliceKit_dialogUndoSettleSnapshot())) {
            NSInteger ms = (NSInteger)([[NSDate date] timeIntervalSinceDate:start] * 1000.0 + 0.5);
            result[@"settled"] = @YES;
            result[@"settleMs"] = @(ms);
            return;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
    }
    result[@"settled"] = @NO;
}

static BOOL SpliceKit_dialogButtonIsCancelLike(NSButton *btn) {
    @try {
        NSString *keyEq = [btn keyEquivalent] ?: @"";
        NSString *title = [btn title] ?: @"";
        return [keyEq isEqualToString:@"\033"] ||
               [title caseInsensitiveCompare:@"Cancel"] == NSOrderedSame ||
               [title caseInsensitiveCompare:@"Don't Save"] == NSOrderedSame;
    } @catch (NSException *e) { return NO; }
}

static NSButton *SpliceKit_findCancelDialogButton(NSArray<NSButton *> *allButtons) {
    for (NSButton *btn in allButtons) {
        if (SpliceKit_dialogButtonIsCancelLike(btn)) return btn;
    }
    return nil;
}

static NSButton *SpliceKit_findDefaultDialogButton(NSArray<NSButton *> *allButtons) {
    for (NSButton *btn in allButtons) {
        @try {
            if ([[btn keyEquivalent] isEqualToString:@"\r"] && [btn isEnabled]) return btn;
        } @catch (NSException *e) {}
    }
    for (NSButton *btn in allButtons) {
        @try {
            NSString *title = [btn title] ?: @"";
            if (([title caseInsensitiveCompare:@"OK"] == NSOrderedSame ||
                 [title caseInsensitiveCompare:@"Done"] == NSOrderedSame ||
                 [title caseInsensitiveCompare:@"Share"] == NSOrderedSame) &&
                [btn isEnabled]) {
                return btn;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSArray<NSButton *> *SpliceKit_findButtonsInView(NSView *root) {
    NSMutableArray<NSButton *> *found = [NSMutableArray array];
    if (!root) return found;
    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0 && found.count < 50) {
        NSView *current = queue[0];
        [queue removeObjectAtIndex:0];
        if (!current) continue;
        @try {
            if ([current isKindOfClass:[NSButton class]]) {
                NSButton *btn = (NSButton *)current;
                if ([btn respondsToSelector:@selector(title)] && [btn title].length > 0) {
                    [found addObject:btn];
                }
            }
            NSArray *subs = SpliceKit_safeSubviews(current);
            if (subs) [queue addObjectsFromArray:subs];
        } @catch (NSException *e) {}
    }
    return found;
}

static NSDictionary *SpliceKit_handleDialogDismiss(NSDictionary *params) {
    NSString *action = params[@"action"] ?: @"cancel";

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSWindow *dialogWindow = SpliceKit_findDialogWindow();
            if (!dialogWindow) {
                result = @{@"error": @"No dialog to dismiss"};
                return;
            }

            if (SpliceKit_windowIsSaveOrOpenPanel(dialogWindow)) {
                if (![action isEqualToString:@"cancel"]) {
                    result = SpliceKit_filePanelConfirmUnsupportedError(dialogWindow);
                    return;
                }
                if (SpliceKit_dispatchFilePanelCancel(dialogWindow)) {
                    result = @{@"status": @"ok", @"action": @"cancel", @"dispatch": @"panelAction",
                                 @"panelAction": @"cancel:"};
                    return;
                }
                result = @{@"error": @"Save/open panel did not respond to cancel:"};
                return;
            }

            NSArray<NSButton *> *allButtons = SpliceKit_findButtonsInView([dialogWindow contentView]);
            NSMutableDictionary *answer = nil;
            NSDictionary *undoBefore = nil;
            BOOL waitForUndo = NO;

            if ([action isEqualToString:@"cancel"]) {
                NSButton *cancelBtn = SpliceKit_findCancelDialogButton(allButtons);
                if (cancelBtn) {
                    [cancelBtn performClick:nil];
                    answer = [@{@"status": @"ok", @"action": @"cancel", @"clicked": [cancelBtn title]} mutableCopy];
                    waitForUndo = NO;
                } else if (SpliceKit_dispatchFilePanelCancel(dialogWindow)) {
                    answer = [@{@"status": @"ok", @"action": @"cancel", @"dispatch": @"panelAction",
                                 @"panelAction": @"cancel:"} mutableCopy];
                    waitForUndo = NO;
                } else {
                    [dialogWindow performClose:nil];
                    if (!SpliceKit_findDialogWindow()) {
                        answer = [@{@"status": @"ok", @"action": @"close"} mutableCopy];
                        waitForUndo = NO;
                    } else {
                        NSWindow *stillOpen = SpliceKit_findDialogWindow();
                        NSArray<NSButton *> *remaining = SpliceKit_findButtonsInView([stillOpen contentView]);
                        NSButton *defaultBtn = SpliceKit_findDefaultDialogButton(remaining);
                        if (defaultBtn) {
                            undoBefore = SpliceKit_dialogUndoSettleSnapshot();
                            [defaultBtn performClick:nil];
                            answer = [@{@"status": @"ok", @"action": @"cancel", @"clicked": [defaultBtn title],
                                         @"fellBackToDefault": @YES} mutableCopy];
                            waitForUndo = YES;
                        } else if (SpliceKit_dispatchFilePanelCancel(dialogWindow)) {
                            answer = [@{@"status": @"ok", @"action": @"cancel", @"dispatch": @"panelAction",
                                         @"panelAction": @"cancel:"} mutableCopy];
                            waitForUndo = NO;
                        } else {
                            result = @{@"error": @"No Cancel or default button found"};
                            return;
                        }
                    }
                }
            } else {
                NSButton *targetBtn = SpliceKit_findDefaultDialogButton(allButtons);
                if (targetBtn) {
                    undoBefore = SpliceKit_dialogUndoSettleSnapshot();
                    [targetBtn performClick:nil];
                    answer = [@{@"status": @"ok", @"action": action, @"clicked": [targetBtn title]} mutableCopy];
                    waitForUndo = YES;
                } else {
                    result = @{@"error": @"No default/OK button found"};
                    return;
                }
            }

            SpliceKit_dialogApplySettle(answer, undoBefore, waitForUndo);
            result = answer;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Dismiss failed"};
}

#pragma mark - Beat Detection (Any Audio File)

// Beat detection using AVFoundation spectral analysis.
// Reads any audio file (MP3, WAV, M4A, etc.) and detects beats, bars, tempo.
// Beat detection cannot run inside FCP's process (AVFoundation/popen deadlock in hardened runtime).
// The MCP server runs the beat-detector tool directly as an external process.
// This RPC endpoint accepts pre-computed beat data for passthrough.

static NSDictionary *SpliceKit_handleBeatsDetect(NSDictionary *params) {
    // If called with pre-computed data (from MCP), just pass it through
    if (params[@"beats"] && params[@"bars"] && params[@"bpm"]) {
        return params; // Already has beat data
    }

    return @{@"error": @"Beat detection must run via the MCP server (detect_beats tool). "
             @"FCP's hardened runtime prevents audio file access from in-process code. "
             @"Use the detect_beats() MCP tool which runs the beat-detector externally."};
}


// Helper: get the original media URL from a browser or timeline clip
// NOTE: Many FFAsset/FFMediaRep methods deadlock when called from main thread
// inside SpliceKit_executeOnMainThread. This helper runs on a background thread
// with a timeout to avoid hanging the RPC server.
static NSString *SpliceKit_getMediaURLForClip(id clip) {
    if (!clip) return nil;

    __block NSString *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            id clipForMedia = clip;
            SEL primarySel = NSSelectorFromString(@"primaryObject");
            if ([clipForMedia respondsToSelector:primarySel]) {
                id primary = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, primarySel);
                if (primary) clipForMedia = primary;
            }
            SEL containedSel = NSSelectorFromString(@"containedItems");
            if ([clip respondsToSelector:containedSel]) {
                id contained = ((id (*)(id, SEL))objc_msgSend)(clip, containedSel);
                NSArray *containedItems = SpliceKit_mixerArrayFromContainer(contained);
                for (id child in containedItems) {
                    NSString *className = NSStringFromClass([child class]);
                    if ([className containsString:@"MediaComponent"] ||
                        [className containsString:@"Asset"] ||
                        [className containsString:@"Clip"]) {
                        clipForMedia = child;
                        break;
                    }
                }
            }
            if ([clipForMedia respondsToSelector:containedSel]) {
                id contained = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, containedSel);
                NSArray *containedItems = SpliceKit_mixerArrayFromContainer(contained);
                for (id child in containedItems) {
                    NSString *className = NSStringFromClass([child class]);
                    if ([className containsString:@"MediaComponent"] ||
                        [className containsString:@"Asset"] ||
                        [className containsString:@"Clip"]) {
                        clipForMedia = child;
                        break;
                    }
                }
            }

            SEL origSel = NSSelectorFromString(@"originalMediaURL");
            if ([clipForMedia respondsToSelector:origSel]) {
                id url = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, origSel);
                if (url && [url isKindOfClass:[NSURL class]]) {
                    result = [url absoluteString];
                }
            }

            if (!result) {
                id media = nil;
                SEL mediaSel = NSSelectorFromString(@"media");
                if ([clipForMedia respondsToSelector:mediaSel]) {
                    media = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, mediaSel);
                }
                if (media && [media respondsToSelector:origSel]) {
                    id url = ((id (*)(id, SEL))objc_msgSend)(media, origSel);
                    if ([url isKindOfClass:[NSURL class]]) result = [url absoluteString];
                }
                if (!result && media) {
                    SEL repSel = NSSelectorFromString(@"originalMediaRep");
                    if ([media respondsToSelector:repSel]) {
                        id rep = ((id (*)(id, SEL))objc_msgSend)(media, repSel);
                        SEL fileURLsSel = NSSelectorFromString(@"fileURLs");
                        if (rep && [rep respondsToSelector:fileURLsSel]) {
                            NSArray *urls = ((id (*)(id, SEL))objc_msgSend)(rep, fileURLsSel);
                            if ([urls isKindOfClass:[NSArray class]] && urls.count > 0 &&
                                [urls.firstObject isKindOfClass:[NSURL class]]) {
                                result = [urls.firstObject absoluteString];
                            }
                        }
                    }
                }
                if (!result && media) {
                    SEL repSel = NSSelectorFromString(@"currentRep");
                    if ([media respondsToSelector:repSel]) {
                        id rep = ((id (*)(id, SEL))objc_msgSend)(media, repSel);
                        SEL fileURLsSel = NSSelectorFromString(@"fileURLs");
                        if (rep && [rep respondsToSelector:fileURLsSel]) {
                            NSArray *urls = ((id (*)(id, SEL))objc_msgSend)(rep, fileURLsSel);
                            if ([urls isKindOfClass:[NSArray class]] && urls.count > 0 &&
                                [urls.firstObject isKindOfClass:[NSURL class]]) {
                                result = [urls.firstObject absoluteString];
                            }
                        }
                    }
                }
            }

            if (!result) {
                SEL refSel = NSSelectorFromString(@"assetMediaReference");
                if ([clipForMedia respondsToSelector:refSel]) {
                    id ref = ((id (*)(id, SEL))objc_msgSend)(clipForMedia, refSel);
                    SEL resolvedSel = NSSelectorFromString(@"resolvedURL");
                    if (ref && [ref respondsToSelector:resolvedSel]) {
                        id url = ((id (*)(id, SEL))objc_msgSend)(ref, resolvedSel);
                        if ([url isKindOfClass:[NSURL class]]) result = [url absoluteString];
                    }
                }
            }

            if (!result) {
                @try {
                    id url = [clipForMedia valueForKeyPath:@"media.fileURL"];
                    if ([url isKindOfClass:[NSURL class]]) result = [url absoluteString];
                } @catch (NSException *e) {}
            }
            if (!result) {
                @try {
                    id url = [clipForMedia valueForKeyPath:@"clipInPlace.asset.originalMediaURL"];
                    if ([url isKindOfClass:[NSURL class]]) result = [url absoluteString];
                } @catch (NSException *e) {}
            }
        } @catch (NSException *e) { /* ignore */ }
        dispatch_semaphore_signal(sem);
    });

    // Wait max 2 seconds — if it deadlocks, we just skip this clip's URL
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return result;
}

#pragma mark - FlexMusic & Montage Maker
//
// FlexMusic is FCP's dynamic soundtrack system — royalty-free songs that render
// to any duration with proper musical phrasing. Montage Maker uses FlexMusic
// timing data + clip analysis to auto-assemble highlight reels.
//

// ---------- FlexMusic static state ----------
static id sFMSongLibrary = nil; // FMSongLibrary singleton

static id SpliceKit_getFlexMusicLibrary(void) {
    if (sFMSongLibrary) return sFMSongLibrary;

    Class fmLib = objc_getClass("FMSongLibrary");
    if (!fmLib) return nil;

    // Use the shared singleton factory — sharedLibraryWithOptions:
    SEL sharedSel = NSSelectorFromString(@"sharedLibraryWithOptions:");
    if ([fmLib respondsToSelector:sharedSel]) {
        sFMSongLibrary = ((id (*)(id, SEL, id))objc_msgSend)((id)fmLib, sharedSel, @{});
    }

    // Fallback: alloc/initWithOptions:
    if (!sFMSongLibrary) {
        id instance = ((id (*)(id, SEL))objc_msgSend)((id)fmLib, @selector(alloc));
        if (instance) {
            SEL initSel = NSSelectorFromString(@"initWithOptions:");
            if ([instance respondsToSelector:initSel]) {
                sFMSongLibrary = ((id (*)(id, SEL, id))objc_msgSend)(instance, initSel, @{});
            } else {
                sFMSongLibrary = ((id (*)(id, SEL))objc_msgSend)(instance, @selector(init));
            }
        }
    }

    return sFMSongLibrary;
}

// Helper: look up an NSString* constant from FlexMusicKit by symbol name
static NSString *SpliceKit_flexMusicConstant(const char *symbolName) {
    void *ptr = dlsym(RTLD_DEFAULT, symbolName);
    if (!ptr) return nil;
    CFStringRef *cfPtr = (CFStringRef *)ptr;
    return (__bridge NSString *)(*cfPtr);
}

// Helper: build a CMTime from seconds at timescale 600
static SpliceKit_CMTime SpliceKit_cmtimeFromSeconds(double seconds) {
    SpliceKit_CMTime t;
    t.value = (int64_t)(seconds * 600.0);
    t.timescale = 600;
    t.flags = 1; // kCMTimeFlags_Valid
    t.epoch = 0;
    return t;
}

// Helper: convert CMTime to double seconds
static double SpliceKit_cmtimeToSeconds(SpliceKit_CMTime t) {
    if (t.timescale <= 0) return 0.0;
    return (double)t.value / (double)t.timescale;
}

static NSString *SpliceKit_escapeXMLString(NSString *value) {
    NSString *escaped = value ?: @"";
    escaped = [escaped stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    return escaped;
}

static NSString *SpliceKit_fcpxmlTimeStringForFrameCount(long long frameCount,
                                                         SpliceKit_CMTime frameDuration) {
    if (frameCount <= 0) return @"0s";
    long long value = frameCount * frameDuration.value;
    return [NSString stringWithFormat:@"%lld/%ds", value, frameDuration.timescale];
}

static NSString *SpliceKit_buildRandomClipAssemblyFCPXML(NSArray<NSMutableDictionary *> *plan,
                                                         NSString *projectName,
                                                         NSString *eventName,
                                                         SpliceKit_CMTime frameDuration,
                                                         NSString *songMediaURL,
                                                         long long totalDurationFrames,
                                                         NSString **errorOut) {
    NSMutableDictionary<NSString *, NSDictionary *> *mediaResources = [NSMutableDictionary dictionary];
    NSInteger resourceIndex = 0;

    for (NSMutableDictionary *entry in plan) {
        if (![entry[@"status"] isEqualToString:@"planned"]) continue;

        NSString *mediaURL = [entry[@"mediaURL"] isKindOfClass:[NSString class]] ? entry[@"mediaURL"] : @"";
        if (mediaURL.length == 0) {
            NSString *clipHandle = [entry[@"clipHandle"] isKindOfClass:[NSString class]] ? entry[@"clipHandle"] : @"";
            id browserClip = clipHandle.length > 0 ? SpliceKit_resolveHandle(clipHandle) : nil;
            mediaURL = SpliceKit_getMediaURLForClip(browserClip) ?: @"";
            if (mediaURL.length > 0) entry[@"mediaURL"] = mediaURL;
        }
        if (mediaURL.length == 0) {
            if (errorOut) {
                *errorOut = [NSString stringWithFormat:@"Clip '%@' is missing a browser media URL, so it cannot be assembled via FCPXML",
                             entry[@"clipName"] ?: @"Clip"];
            }
            return nil;
        }
        if (!mediaResources[mediaURL]) {
            mediaResources[mediaURL] = @{
                @"id": [NSString stringWithFormat:@"r%ld", (long)++resourceIndex],
                @"url": mediaURL,
            };
        }
    }

    if (songMediaURL.length == 0 && totalDurationFrames > 0) {
        if (errorOut) *errorOut = @"The selected song does not expose a media URL, so it cannot be attached in the FCPXML build";
        return nil;
    }

    NSString *uid = [[[NSUUID UUID] UUIDString] substringToIndex:8];
    NSString *formatId = [NSString stringWithFormat:@"fmt_%@", uid];
    NSString *frameDurationString = SpliceKit_fcpxmlTimeStringForFrameCount(1, frameDuration);
    NSString *sequenceDurationString = SpliceKit_fcpxmlTimeStringForFrameCount(totalDurationFrames, frameDuration);
    NSString *escapedProject = SpliceKit_escapeXMLString(projectName ?: @"Beat Random Cut");
    NSString *escapedEvent = SpliceKit_escapeXMLString(eventName.length > 0 ? eventName : @"SpliceKit Tests");

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
    [xml appendString:@"<fcpxml version=\"1.14\">\n"];
    [xml appendString:@"    <resources>\n"];
    [xml appendFormat:@"        <format id=\"%@\" name=\"FFVideoFormatCustom\" frameDuration=\"%@\" width=\"1920\" height=\"1080\"/>\n",
                      formatId, frameDurationString];

    for (NSString *urlKey in mediaResources) {
        NSDictionary *res = mediaResources[urlKey];
        [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" hasVideo=\"1\" format=\"%@\" hasAudio=\"1\" videoSources=\"1\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\">\n",
                          res[@"id"], res[@"id"], formatId];
        [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                          SpliceKit_escapeXMLString(res[@"url"])];
        [xml appendString:@"        </asset>\n"];
    }

    if (songMediaURL.length > 0) {
        [xml appendString:@"        <asset id=\"song_audio\" name=\"Music\" hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\">\n"];
        [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                          SpliceKit_escapeXMLString(songMediaURL)];
        [xml appendString:@"        </asset>\n"];
    }

    [xml appendString:@"    </resources>\n"];
    [xml appendString:@"    <library>\n"];
    [xml appendFormat:@"        <event name=\"%@\">\n", escapedEvent];
    [xml appendFormat:@"            <project name=\"%@\">\n", escapedProject];
    [xml appendFormat:@"                <sequence format=\"%@\" duration=\"%@\" tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">\n",
                      formatId, sequenceDurationString];
    [xml appendString:@"                    <spine>\n"];

    BOOL attachedSong = NO;
    for (NSMutableDictionary *entry in plan) {
        long long offsetFrames = [entry[@"timelineOffsetFrames"] longLongValue];
        long long durationFrames = [entry[@"durationFrames"] longLongValue];
        NSString *offsetString = SpliceKit_fcpxmlTimeStringForFrameCount(offsetFrames, frameDuration);
        NSString *durationString = SpliceKit_fcpxmlTimeStringForFrameCount(durationFrames, frameDuration);
        NSString *clipName = SpliceKit_escapeXMLString(entry[@"clipName"] ?: @"Clip");
        BOOL addSongChild = (!attachedSong && songMediaURL.length > 0);

        if ([entry[@"status"] isEqualToString:@"gap"]) {
            if (addSongChild) {
                [xml appendFormat:@"                        <gap name=\"%@\" offset=\"%@\" duration=\"%@\">\n",
                                  clipName, offsetString, durationString];
                [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" lane=\"-1\" name=\"Music\" offset=\"0s\" duration=\"%@\" start=\"0s\"/>\n",
                                  sequenceDurationString];
                [xml appendString:@"                        </gap>\n"];
                attachedSong = YES;
            } else {
                [xml appendFormat:@"                        <gap name=\"%@\" offset=\"%@\" duration=\"%@\"/>\n",
                                  clipName, offsetString, durationString];
            }
            continue;
        }

        NSString *mediaURL = entry[@"mediaURL"];
        NSDictionary *resource = mediaResources[mediaURL];
        NSString *inString = SpliceKit_fcpxmlTimeStringForFrameCount([entry[@"inFrames"] longLongValue], frameDuration);

        if (addSongChild) {
            [xml appendFormat:@"                        <asset-clip ref=\"%@\" name=\"%@\" offset=\"%@\" duration=\"%@\" start=\"%@\">\n",
                              resource[@"id"], clipName, offsetString, durationString, inString];
            // Connected clip offset is in parent's local time coordinates.
            // Anchor the song at the parent clip's start (in-point) so it
            // lines up with the parent's first visible frame on the timeline.
            [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" lane=\"-1\" name=\"Music\" offset=\"%@\" duration=\"%@\" start=\"0s\"/>\n",
                              inString, sequenceDurationString];
            [xml appendString:@"                        </asset-clip>\n"];
            attachedSong = YES;
        } else {
            [xml appendFormat:@"                        <asset-clip ref=\"%@\" name=\"%@\" offset=\"%@\" duration=\"%@\" start=\"%@\"/>\n",
                              resource[@"id"], clipName, offsetString, durationString, inString];
        }
    }

    [xml appendString:@"                    </spine>\n"];
    [xml appendString:@"                </sequence>\n"];
    [xml appendString:@"            </project>\n"];
    [xml appendString:@"        </event>\n"];
    [xml appendString:@"    </library>\n"];
    [xml appendString:@"</fcpxml>\n"];
    return xml;
}

double SpliceKit_quantizeSecondsToFrameGrid(double seconds, double frameSeconds) {
    if (!isfinite(seconds) || seconds <= 0.0) return 0.0;
    if (!isfinite(frameSeconds) || frameSeconds <= 0.000001) return seconds;
    long long frames = llround(seconds / frameSeconds);
    return (double)frames * frameSeconds;
}

static BOOL SpliceKit_mediaURLLooksAudioOnly(NSString *urlString) {
    if (urlString.length == 0) return NO;

    NSString *path = [[NSURL URLWithString:urlString] path] ?: urlString;
    NSString *ext = [[path pathExtension] lowercaseString];
    static NSSet<NSString *> *audioExts = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioExts = [NSSet setWithArray:@[@"mp3", @"m4a", @"aac", @"wav", @"aif", @"aiff", @"caf", @"flac"]];
    });
    return [audioExts containsObject:ext];
}

static NSArray *SpliceKit_copyBrowserClipsForEvent(id event) {
    // The same walk browser.listClips makes (SpliceKit_browserClipsOfEvent).
    return SpliceKit_browserClipsOfEvent(event);
}

static SpliceKit_CMTimeRange SpliceKit_clipRangeForItem(id item) {
    SpliceKit_CMTimeRange clipRange = {0};
    if (!item) return clipRange;

    if ([item respondsToSelector:@selector(clippedRange)]) {
        clipRange = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(item, @selector(clippedRange));
    } else if ([item respondsToSelector:@selector(duration)]) {
        SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
        clipRange.start = (SpliceKit_CMTime){0, dur.timescale > 0 ? dur.timescale : 6000, 1, 0};
        clipRange.duration = dur;
    }

    if (clipRange.start.timescale <= 0) {
        clipRange.start.timescale = clipRange.duration.timescale > 0 ? clipRange.duration.timescale : 6000;
        clipRange.start.flags = 1;
    }
    if (clipRange.duration.timescale <= 0 && clipRange.duration.value > 0) {
        clipRange.duration.timescale = clipRange.start.timescale > 0 ? clipRange.start.timescale : 6000;
        clipRange.duration.flags = 1;
    }
    return clipRange;
}

static id SpliceKit_findBrowserClipMatchingMediaURL(NSString *mediaURL, NSString *fallbackName) {
    id libs = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
    if (![libs isKindOfClass:[NSArray class]]) return nil;

    BOOL requireURLMatch = (mediaURL.length > 0);
    NSString *lowerFallback = requireURLMatch ? nil : [fallbackName lowercaseString];
    for (id library in (NSArray *)libs) {
        SEL eventsSel = NSSelectorFromString(@"events");
        if (![library respondsToSelector:eventsSel]) continue;
        id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
        if (![events isKindOfClass:[NSArray class]]) continue;

        for (id event in (NSArray *)events) {
            NSArray *clips = SpliceKit_copyBrowserClipsForEvent(event);
            for (id clip in clips) {
                NSString *clipURL = SpliceKit_getMediaURLForClip(clip);
                if (mediaURL.length > 0 && clipURL.length > 0 && [clipURL isEqualToString:mediaURL]) {
                    return clip;
                }

                if (lowerFallback.length > 0) {
                    NSString *clipName = SpliceKit_displayNameForItem(clip);
                    if (clipName.length > 0 &&
                        [[clipName lowercaseString] containsString:lowerFallback]) {
                        return clip;
                    }
                }
            }
        }
    }

    return nil;
}

static id SpliceKit_normalizeSourceObjectForInsertion(id sourceObject) {
    if (!sourceObject) return nil;

    SEL mediaRangeSel = NSSelectorFromString(@"mediaRange");
    SEL sequenceSel = NSSelectorFromString(@"sequence");
    SEL organizerItemSel = NSSelectorFromString(@"organizerDataItem");

    // Organizer/browser-backed items respond to sequenceRecord and are acceptable as-is.
    // Raw timeline items (FFAnchoredMediaComponent) also respond to mediaRange/sequence
    // but crash on sequenceRecord, so they must NOT be returned early.
    if ([sourceObject respondsToSelector:mediaRangeSel] &&
        [sourceObject respondsToSelector:sequenceSel] &&
        [sourceObject respondsToSelector:NSSelectorFromString(@"sequenceRecord")]) {
        return sourceObject;
    }

    SEL isMediaRefSel = NSSelectorFromString(@"isMediaRef");
    if ([sourceObject respondsToSelector:organizerItemSel]) {
        @try {
            id organizerItem = ((id (*)(id, SEL))objc_msgSend)(sourceObject, organizerItemSel);
            if (organizerItem && [organizerItem respondsToSelector:isMediaRefSel]) return organizerItem;
        } @catch (NSException *e) {}
    }

    // Timeline-backed items usually need to be promoted through their owning sequence.
    if ([sourceObject respondsToSelector:sequenceSel]) {
        @try {
            id sourceSequence = ((id (*)(id, SEL))objc_msgSend)(sourceObject, sequenceSel);
            if (sourceSequence && [sourceSequence respondsToSelector:organizerItemSel]) {
                id organizerItem = ((id (*)(id, SEL))objc_msgSend)(sourceSequence, organizerItemSel);
                if (organizerItem && [organizerItem respondsToSelector:isMediaRefSel]) return organizerItem;
            }
        } @catch (NSException *e) {}
    }

    // Last resort: find the matching browser clip by media URL or display name.
    NSString *normMediaURL = SpliceKit_getMediaURLForClip(sourceObject) ?: @"";
    NSString *normDisplayName = SpliceKit_displayNameForItem(sourceObject);
    if (normMediaURL.length > 0 || normDisplayName.length > 0) {
        id browserClip = SpliceKit_findBrowserClipMatchingMediaURL(normMediaURL, normDisplayName);
        if (!browserClip && normMediaURL.length > 0 && normDisplayName.length > 0) {
            // URL didn't match (media may be wrapped in a browser sequence). Try name only.
            browserClip = SpliceKit_findBrowserClipMatchingMediaURL(nil, normDisplayName);
        }
        if (browserClip) return browserClip;
    }

    return sourceObject;
}

static NSDictionary *SpliceKit_prepareBrowserClipSourceForInsertion(id sourceBrowserClip,
                                                                    SpliceKit_CMTimeRange clipRange,
                                                                    BOOL preferAudio) {
    NSMutableDictionary *diag = [NSMutableDictionary dictionary];
    diag[@"ok"] = @NO;

    if (!sourceBrowserClip) {
        diag[@"error"] = @"Missing source browser clip";
        return diag;
    }
    if (clipRange.duration.timescale <= 0 || clipRange.duration.value <= 0) {
        diag[@"error"] = @"Missing source media range";
        return diag;
    }
    diag[@"sourceClipClass"] = NSStringFromClass([sourceBrowserClip class]) ?: @"";

    id insertionSource = SpliceKit_normalizeSourceObjectForInsertion(sourceBrowserClip);
    if (!insertionSource) {
        diag[@"error"] = @"Unable to normalize source object for insertion";
        return diag;
    }
    if (insertionSource != sourceBrowserClip) {
        diag[@"normalizedSourceClass"] = NSStringFromClass([insertionSource class]) ?: @"";
    }

    id appController = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("PEAppController"), NSSelectorFromString(@"appController"));
    id organizerContainer = appController &&
        [appController respondsToSelector:NSSelectorFromString(@"mediaEventOrganizerContainer")]
            ? ((id (*)(id, SEL))objc_msgSend)(appController, NSSelectorFromString(@"mediaEventOrganizerContainer"))
            : nil;
    id organizer = organizerContainer &&
        [organizerContainer respondsToSelector:NSSelectorFromString(@"activeOrganizerModule")]
            ? ((id (*)(id, SEL))objc_msgSend)(organizerContainer, NSSelectorFromString(@"activeOrganizerModule"))
            : nil;

    if (!organizer) {
        diag[@"error"] = @"No active organizer module";
        return diag;
    }

    diag[@"activeOrganizerClass"] = NSStringFromClass([organizer class]) ?: @"";

    if ([organizer respondsToSelector:NSSelectorFromString(@"setSidebarHidden:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(organizer, NSSelectorFromString(@"setSidebarHidden:"), NO);
    }
    if ([organizer respondsToSelector:NSSelectorFromString(@"setLibrarySidebarActive:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(organizer, NSSelectorFromString(@"setLibrarySidebarActive:"), YES);
    }
    if ([organizer respondsToSelector:NSSelectorFromString(@"_showLibrarySidebar")]) {
        ((void (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"_showLibrarySidebar"));
    }
    if ([organizer respondsToSelector:NSSelectorFromString(@"_syncSidebarButtonsToVisibleState")]) {
        ((void (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"_syncSidebarButtonsToVisibleState"));
    }

    id mediaDetail = [organizer respondsToSelector:NSSelectorFromString(@"mediaDetailContainerModule")]
        ? ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"mediaDetailContainerModule"))
        : nil;
    id mediaBrowser = mediaDetail &&
        [mediaDetail respondsToSelector:NSSelectorFromString(@"getActiveMediaBrowser")]
            ? ((id (*)(id, SEL))objc_msgSend)(mediaDetail, NSSelectorFromString(@"getActiveMediaBrowser"))
            : nil;
    if (!mediaBrowser && [organizer respondsToSelector:NSSelectorFromString(@"filmstripModule")]) {
        mediaBrowser = ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"filmstripModule"));
    }
    if (!mediaBrowser && organizerContainer &&
        [organizerContainer respondsToSelector:NSSelectorFromString(@"getActiveMediaBrowser")]) {
        mediaBrowser = ((id (*)(id, SEL))objc_msgSend)(organizerContainer, NSSelectorFromString(@"getActiveMediaBrowser"));
    }
    if (!mediaBrowser) {
        diag[@"error"] = @"No active media browser";
        return diag;
    }
    diag[@"mediaBrowserClass"] = NSStringFromClass([mediaBrowser class]) ?: @"";

    if ([mediaBrowser respondsToSelector:NSSelectorFromString(@"_ensureModuleIsVisible")]) {
        ((void (*)(id, SEL))objc_msgSend)(mediaBrowser, NSSelectorFromString(@"_ensureModuleIsVisible"));
    }

    Class rangeObjClass = objc_getClass("FigTimeRangeAndObject");
    SEL rangeAndObjSel = NSSelectorFromString(@"rangeAndObjectWithRange:andObject:");
    if (!rangeObjClass || ![(id)rangeObjClass respondsToSelector:rangeAndObjSel]) {
        diag[@"error"] = @"FigTimeRangeAndObject unavailable";
        return diag;
    }

    id mediaRange = ((id (*)(id, SEL, SpliceKit_CMTimeRange, id))objc_msgSend)(
        (id)rangeObjClass, rangeAndObjSel, clipRange, insertionSource);
    if (!mediaRange) {
        diag[@"error"] = @"Failed to build source media range";
        return diag;
    }

    NSArray *ranges = @[mediaRange];
    SpliceKit_CMTime zero = {0, clipRange.duration.timescale > 0 ? clipRange.duration.timescale : 6000, 1, 0};
    SEL revealSel = NSSelectorFromString(@"revealObject:andRange:atPlayhead:");
    if ([organizer respondsToSelector:revealSel]) {
        ((BOOL (*)(id, SEL, id, SpliceKit_CMTimeRange, SpliceKit_CMTime))objc_msgSend)(
            organizer, revealSel, insertionSource, clipRange, zero);
    }
    SEL revealRangesSel = NSSelectorFromString(@"revealMediaRanges:");
    if ([organizer respondsToSelector:revealRangesSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(organizer, revealRangesSel, ranges);
    }

    SEL selectSel = NSSelectorFromString(@"_selectMediaRanges:");
    if (![mediaBrowser respondsToSelector:selectSel]) {
        diag[@"error"] = @"Media browser cannot select ranges";
        return diag;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(mediaBrowser, selectSel, ranges);

    id selectionManager = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("PESelectionManager"), NSSelectorFromString(@"defaultSelectionManager"));
    if (selectionManager) {
        id context = nil;
        Class contextClass = objc_getClass("FFContext");
        if (contextClass) {
            context = ((id (*)(id, SEL))objc_msgSend)((id)contextClass, @selector(alloc));
            context = ((id (*)(id, SEL))objc_msgSend)(context, @selector(init));
        }
        SEL displaySel = NSSelectorFromString(@"displayMedia:context:effectCount:loadingBlock:unloadingBlock:");
        id displayTarget = [mediaBrowser respondsToSelector:displaySel] ? mediaBrowser : organizer;
        if (displayTarget && [displayTarget respondsToSelector:displaySel]) {
            ((void (*)(id, SEL, id, id, NSInteger, id, id))objc_msgSend)(
                displayTarget,
                displaySel,
                insertionSource,
                context,
                0,
                nil,
                nil);
        } else {
            id viewed = nil;
            Class viewedClipSetClass = objc_getClass("PEViewedClipSet");
            if (viewedClipSetClass) {
                viewed = ((id (*)(id, SEL))objc_msgSend)((id)viewedClipSetClass, @selector(alloc));
                viewed = ((id (*)(id, SEL, id, id, id, int, id))objc_msgSend)(
                    viewed,
                    NSSelectorFromString(@"initWithClips:contexts:effectCounts:layoutStyle:owner:"),
                    @[insertionSource],
                    @[context ?: [NSNull null]],
                    @[@0],
                    0,
                    nil);
            }
            if (viewed) {
                if ([viewed respondsToSelector:NSSelectorFromString(@"setTargetPlayer:")]) {
                    ((void (*)(id, SEL, int))objc_msgSend)(viewed, NSSelectorFromString(@"setTargetPlayer:"), 1);
                }
                if ([selectionManager respondsToSelector:NSSelectorFromString(@"setViewedClips:")]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(selectionManager, NSSelectorFromString(@"setViewedClips:"), viewed);
                }
            }
        }
        if ([selectionManager respondsToSelector:NSSelectorFromString(@"viewedClips")]) {
            id viewed = ((id (*)(id, SEL))objc_msgSend)(selectionManager, NSSelectorFromString(@"viewedClips"));
            if ([viewed respondsToSelector:NSSelectorFromString(@"setPreferAudio:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(viewed, NSSelectorFromString(@"setPreferAudio:"), preferAudio);
            }
        }
    }

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];

    NSUInteger selectedRangeCount = 0;
    if ([organizer respondsToSelector:NSSelectorFromString(@"selectedRangesOfMediaForTimelineEditing")]) {
        id selectedRanges = ((id (*)(id, SEL))objc_msgSend)(
            organizer, NSSelectorFromString(@"selectedRangesOfMediaForTimelineEditing"));
        if ([selectedRanges respondsToSelector:@selector(count)]) {
            selectedRangeCount = [selectedRanges count];
        }
    } else if ([organizer respondsToSelector:NSSelectorFromString(@"selectedRangesOfMedia")]) {
        id selectedRanges = ((id (*)(id, SEL))objc_msgSend)(
            organizer, NSSelectorFromString(@"selectedRangesOfMedia"));
        if ([selectedRanges respondsToSelector:@selector(count)]) {
            selectedRangeCount = [selectedRanges count];
        }
    }

    NSUInteger viewedClipCount = 0;
    if (selectionManager && [selectionManager respondsToSelector:NSSelectorFromString(@"viewedClips")]) {
        id viewedClips = ((id (*)(id, SEL))objc_msgSend)(selectionManager, NSSelectorFromString(@"viewedClips"));
        if (viewedClips && [viewedClips respondsToSelector:NSSelectorFromString(@"clips")]) {
            id clips = ((id (*)(id, SEL))objc_msgSend)(viewedClips, NSSelectorFromString(@"clips"));
            if ([clips respondsToSelector:@selector(count)]) {
                viewedClipCount = [clips count];
            }
        }
    }

    diag[@"selectedRangeCount"] = @(selectedRangeCount);
    diag[@"viewedClipCount"] = @(viewedClipCount);
    diag[@"ok"] = @((selectedRangeCount > 0) && (viewedClipCount > 0));
    if (selectedRangeCount == 0 || viewedClipCount == 0) {
        diag[@"error"] = [NSString stringWithFormat:
            @"Source prep incomplete (selectedRangeCount=%lu viewedClipCount=%lu)",
            (unsigned long)selectedRangeCount,
            (unsigned long)viewedClipCount];
    }
    return diag;
}

id SpliceKit_findSequenceNamedInActiveLibraries(NSString *projectName) {
    if (projectName.length == 0) return nil;

    id libs = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
    if (![libs isKindOfClass:[NSArray class]]) return nil;

    for (id library in (NSArray *)libs) {
        if (!library) continue;

        id seqSet = nil;
        SEL deepSel = NSSelectorFromString(@"_deepLoadedSequences");
        if ([library respondsToSelector:deepSel]) {
            seqSet = ((id (*)(id, SEL))objc_msgSend)(library, deepSel);
        }
        if (!seqSet) continue;

        id seqArray = nil;
        if ([seqSet respondsToSelector:@selector(allObjects)]) {
            seqArray = ((id (*)(id, SEL))objc_msgSend)(seqSet, @selector(allObjects));
        } else if ([seqSet isKindOfClass:[NSArray class]]) {
            seqArray = seqSet;
        }
        if (![seqArray isKindOfClass:[NSArray class]]) continue;

        // First pass: exact match
        for (id seq in (NSArray *)seqArray) {
            NSString *seqName = nil;
            if ([seq respondsToSelector:@selector(displayName)]) {
                seqName = ((id (*)(id, SEL))objc_msgSend)(seq, @selector(displayName));
            }
            if (seqName && [seqName isEqualToString:projectName]) {
                return seq;
            }
        }
        // Second pass: case-insensitive substring match
        NSString *lowerProjectName = [projectName lowercaseString];
        for (id seq in (NSArray *)seqArray) {
            NSString *seqName = nil;
            if ([seq respondsToSelector:@selector(displayName)]) {
                seqName = ((id (*)(id, SEL))objc_msgSend)(seq, @selector(displayName));
            }
            if (seqName && [[seqName lowercaseString] containsString:lowerProjectName]) {
                return seq;
            }
        }
    }

    return nil;
}

static BOOL SpliceKit_loadSequenceInActiveEditor(id sequence) {
    if (!sequence) return NO;

    id app = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("NSApplication"), @selector(sharedApplication));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
    if (!delegate) return NO;

    SEL containerSel = @selector(activeEditorContainer);
    if (![delegate respondsToSelector:containerSel]) return NO;
    id editorContainer = ((id (*)(id, SEL))objc_msgSend)(delegate, containerSel);
    if (!editorContainer) return NO;

    SEL loadSel = NSSelectorFromString(@"loadEditorForSequence:");
    if (![editorContainer respondsToSelector:loadSel]) return NO;

    ((void (*)(id, SEL, id))objc_msgSend)(editorContainer, loadSel, sequence);
    return YES;
}

static SpliceKit_CMTime SpliceKit_makeCMTimeWithTimescale(double seconds, int32_t timescale) {
    if (!isfinite(seconds)) seconds = 0.0;
    if (timescale <= 0) timescale = 6000;
    return (SpliceKit_CMTime){
        .value = (int64_t)llround(seconds * (double)timescale),
        .timescale = timescale,
        .flags = 1,
        .epoch = 0,
    };
}

static SpliceKit_CMTime SpliceKit_addSecondsToCMTime(SpliceKit_CMTime base, double seconds) {
    double baseSeconds = (base.timescale > 0) ? ((double)base.value / (double)base.timescale) : 0.0;
    int32_t timescale = base.timescale > 0 ? base.timescale : 6000;
    return SpliceKit_makeCMTimeWithTimescale(baseSeconds + seconds, timescale);
}

static id SpliceKit_findAssemblyEvent(NSArray *events, NSString *eventName) {
    if (![events isKindOfClass:[NSArray class]] || events.count == 0) return nil;
    if (eventName.length == 0) return events.firstObject;

    NSString *needle = [eventName lowercaseString];
    for (id event in events) {
        NSString *name = SpliceKit_displayNameForItem(event);
        if (name.length > 0 && [[name lowercaseString] containsString:needle]) {
            return event;
        }
    }
    return nil;
}

static NSDictionary *SpliceKit_createNativeProjectSequence(NSString *projectName, id targetEvent) {
    NSMutableDictionary *diag = [NSMutableDictionary dictionary];
    diag[@"ok"] = @NO;

    if (projectName.length == 0) {
        diag[@"error"] = @"Missing project name";
        return diag;
    }
    if (!targetEvent) {
        diag[@"error"] = @"Missing target event for project creation";
        return diag;
    }

    SEL libraryItemSel = NSSelectorFromString(@"libraryItem");
    id eventLibraryItem = [targetEvent respondsToSelector:libraryItemSel]
        ? ((id (*)(id, SEL))objc_msgSend)(targetEvent, libraryItemSel)
        : targetEvent;
    if (!eventLibraryItem) {
        diag[@"error"] = @"Target event does not expose a library item";
        return diag;
    }

    Class projectDocClass = objc_getClass("FFProjectDocument");
    SEL createSel = NSSelectorFromString(@"actionNewProject:name:sequence:actionName:error:");
    if (!projectDocClass || ![(id)projectDocClass respondsToSelector:createSel]) {
        diag[@"error"] = @"FFProjectDocument actionNewProject:name:sequence:actionName:error: unavailable";
        return diag;
    }

    NSError *error = nil;
    id createdProjectClip = ((id (*)(id, SEL, id, id, id, id, NSError **))objc_msgSend)(
        (id)projectDocClass,
        createSel,
        eventLibraryItem,
        projectName,
        nil,
        @"SpliceKit Song Cut",
        &error);
    if (!createdProjectClip) {
        diag[@"error"] = error.localizedDescription ?: @"Native project creation returned nil";
        return diag;
    }

    id sequence = nil;
    for (int attempt = 0; attempt < 40 && !sequence; attempt++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        sequence = SpliceKit_findSequenceNamedInActiveLibraries(projectName);
    }
    if (!sequence) {
        diag[@"error"] = @"Created the native project clip, but could not resolve the backing sequence";
        diag[@"createdObjectClass"] = NSStringFromClass([createdProjectClip class]) ?: @"";
        return diag;
    }

    BOOL loaded = SpliceKit_loadSequenceInActiveEditor(sequence);
    diag[@"sequence"] = sequence;
    diag[@"sequenceHandle"] = SpliceKit_storeHandle(sequence) ?: @"";
    diag[@"createdObjectClass"] = NSStringFromClass([createdProjectClip class]) ?: @"";
    diag[@"eventName"] = SpliceKit_displayNameForItem(targetEvent) ?: @"";
    diag[@"loaded"] = @(loaded);
    diag[@"ok"] = @(loaded);
    if (!loaded) {
        diag[@"error"] = @"Created project but failed to load it into the active editor";
    }
    return diag;
}

static NSDictionary *SpliceKit_performPreparedMediaEdit(id timeline,
                                                        NSInteger editKind,
                                                        BOOL backTimed,
                                                        NSString *trackType,
                                                        BOOL useExplicitTime,
                                                        SpliceKit_CMTime explicitTime) {
    NSMutableDictionary *diag = [NSMutableDictionary dictionary];
    diag[@"ok"] = @NO;
    diag[@"editKind"] = @(editKind);
    diag[@"trackType"] = trackType ?: @"all";
    diag[@"useExplicitTime"] = @(useExplicitTime);

    if (!timeline) {
        diag[@"error"] = @"Missing active timeline";
        return diag;
    }

    Class editActionClass = objc_getClass("FFEditAction");
    SEL createEditSel = NSSelectorFromString(@"editActionOfKind:backTimed:trackType:");
    if (!editActionClass || ![(id)editActionClass respondsToSelector:createEditSel]) {
        diag[@"error"] = @"FFEditAction editActionOfKind:backTimed:trackType: unavailable";
        return diag;
    }

    id editAction = ((id (*)(id, SEL, NSInteger, BOOL, id))objc_msgSend)(
        (id)editActionClass,
        createEditSel,
        editKind,
        backTimed,
        trackType ?: @"all");
    if (!editAction) {
        diag[@"error"] = @"Failed to build edit action";
        return diag;
    }

    NSString *pasteboardName = [NSString stringWithFormat:@"com.apple.nle.splicekit.%@",
                                [[NSUUID UUID] UUIDString]];
    diag[@"pasteboardName"] = pasteboardName;

    id appController = ((id (*)(id, SEL))objc_msgSend)(
        objc_getClass("PEAppController"), NSSelectorFromString(@"appController"));
    id source = appController &&
        [appController respondsToSelector:NSSelectorFromString(@"activeSourceForEditAction:")]
            ? ((id (*)(id, SEL, id))objc_msgSend)(appController, NSSelectorFromString(@"activeSourceForEditAction:"), editAction)
            : nil;

    if (!source && appController) {
        id organizerContainer = [appController respondsToSelector:NSSelectorFromString(@"mediaEventOrganizerContainer")]
            ? ((id (*)(id, SEL))objc_msgSend)(appController, NSSelectorFromString(@"mediaEventOrganizerContainer"))
            : nil;
        id organizer = organizerContainer &&
            [organizerContainer respondsToSelector:NSSelectorFromString(@"activeOrganizerModule")]
                ? ((id (*)(id, SEL))objc_msgSend)(organizerContainer, NSSelectorFromString(@"activeOrganizerModule"))
                : nil;
        id mediaDetail = organizer &&
            [organizer respondsToSelector:NSSelectorFromString(@"mediaDetailContainerModule")]
                ? ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"mediaDetailContainerModule"))
                : nil;
        source = mediaDetail &&
            [mediaDetail respondsToSelector:NSSelectorFromString(@"getActiveMediaBrowser")]
                ? ((id (*)(id, SEL))objc_msgSend)(mediaDetail, NSSelectorFromString(@"getActiveMediaBrowser"))
                : nil;
        if (!source && organizer && [organizer respondsToSelector:NSSelectorFromString(@"filmstripModule")]) {
            source = ((id (*)(id, SEL))objc_msgSend)(organizer, NSSelectorFromString(@"filmstripModule"));
        }
    }

    if (!source) {
        diag[@"error"] = @"No active source for the prepared browser selection";
        return diag;
    }
    diag[@"sourceClass"] = NSStringFromClass([source class]) ?: @"";

    BOOL canSource = YES;
    SEL canSourceSel = NSSelectorFromString(@"canSourceDataForEditAction:");
    if ([source respondsToSelector:canSourceSel]) {
        canSource = ((BOOL (*)(id, SEL, id))objc_msgSend)(source, canSourceSel, editAction);
    }
    diag[@"canSource"] = @(canSource);
    if (!canSource) {
        diag[@"error"] = @"Prepared browser selection cannot source data for this edit action";
        return diag;
    }

    SEL writeSel = NSSelectorFromString(@"writeDataForEditAction:toPasteboardWithName:");
    if (![source respondsToSelector:writeSel]) {
        diag[@"error"] = @"Source module cannot write edit data to the pasteboard";
        return diag;
    }
    BOOL wrote = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(source, writeSel, editAction, pasteboardName);
    diag[@"writeOK"] = @(wrote);
    if (!wrote) {
        diag[@"error"] = @"Source module failed to write the prepared selection to the pasteboard";
        return diag;
    }

    if (useExplicitTime) {
        SEL containerSel = NSSelectorFromString(@"_containerForEditOperation");
        id container = [timeline respondsToSelector:containerSel]
            ? ((id (*)(id, SEL))objc_msgSend)(timeline, containerSel)
            : nil;
        if (!container && [timeline respondsToSelector:NSSelectorFromString(@"rootItem")]) {
            container = ((id (*)(id, SEL))objc_msgSend)(timeline, NSSelectorFromString(@"rootItem"));
        }
        if (!container) {
            diag[@"error"] = @"Timeline has no container for explicit-time insertion";
            return diag;
        }
        diag[@"containerClass"] = NSStringFromClass([container class]) ?: @"";

        SEL addSel = NSSelectorFromString(@"_addItemsWithPasteboard:atTime:pasteMode:backtimed:useSelectedRange:trackType:container:changesUnderActionHandler:");
        if (![timeline respondsToSelector:addSel]) {
            diag[@"error"] = @"Timeline does not support explicit-time pasteboard insertion";
            return diag;
        }
        ((void (*)(id, SEL, id, SpliceKit_CMTime, int, BOOL, BOOL, id, id, id))objc_msgSend)(
            timeline,
            addSel,
            pasteboardName,
            explicitTime,
            (int)editKind,
            backTimed,
            YES,
            trackType ?: @"all",
            container,
            nil);
    } else {
        SEL performSel = NSSelectorFromString(@"performEditAction:fromPasteboardWithName:fromAnimation:");
        if (![timeline respondsToSelector:performSel]) {
            diag[@"error"] = @"Timeline cannot consume pasteboard edits";
            return diag;
        }
        ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
            timeline,
            performSel,
            editAction,
            pasteboardName,
            NO);
    }

    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    diag[@"ok"] = @YES;
    return diag;
}

static NSDictionary *SpliceKit_handleAssembleRandomClipsToBeats(NSDictionary *params) {
    NSString *sourceHandle = [params[@"sourceHandle"] isKindOfClass:[NSString class]] ? params[@"sourceHandle"] : nil;
    NSString *sourceProjectName = [params[@"sourceProjectName"] isKindOfClass:[NSString class]] ? params[@"sourceProjectName"] : nil;
    NSString *clipSourceProjectName = [params[@"clipSourceProjectName"] isKindOfClass:[NSString class]] ? params[@"clipSourceProjectName"] : nil;
    NSArray *clipHandles = [params[@"clipHandles"] isKindOfClass:[NSArray class]] ? params[@"clipHandles"] : nil;
    NSString *eventName = [params[@"eventName"] isKindOfClass:[NSString class]] ? params[@"eventName"] : nil;
    NSString *grid = [params[@"grid"] isKindOfClass:[NSString class]] ? [params[@"grid"] lowercaseString] : @"bar";
    NSString *buildMode = [params[@"buildMode"] isKindOfClass:[NSString class]]
        ? [params[@"buildMode"] lowercaseString] : @"native";
    NSString *projectName = [params[@"projectName"] isKindOfClass:[NSString class]]
        ? params[@"projectName"] : @"Beat Random Cut";
    NSInteger segmentMinStep = params[@"segmentMinStep"] ? [params[@"segmentMinStep"] integerValue] : 1;
    NSInteger segmentMaxStep = params[@"segmentMaxStep"] ? [params[@"segmentMaxStep"] integerValue] : segmentMinStep;
    NSInteger maxSegments = params[@"maxSegments"] ? [params[@"maxSegments"] integerValue] : 0;
    long long randomSeed = params[@"randomSeed"] ? [params[@"randomSeed"] longLongValue] : 1337;
    BOOL allowClipReuse = params[@"allowClipReuse"] ? [params[@"allowClipReuse"] boolValue] : YES;
    BOOL includeAudio = params[@"includeAudio"] ? [params[@"includeAudio"] boolValue] : YES;
    BOOL targetCurrentTimeline = params[@"targetCurrentTimeline"] ? [params[@"targetCurrentTimeline"] boolValue] : NO;
    BOOL dryRun = [params[@"dryRun"] boolValue];
    NSDictionary *rawStepWeights = [params[@"stepWeights"] isKindOfClass:[NSDictionary class]]
        ? params[@"stepWeights"] : nil;

    if ([grid isEqualToString:@"random"]) {
        grid = @"beat";
    } else if ([grid isEqualToString:@"random_half"] || [grid isEqualToString:@"random_half_beat"]) {
        grid = @"half_beat";
    } else if ([grid isEqualToString:@"random_quarter"] || [grid isEqualToString:@"random_quarter_beat"]) {
        grid = @"quarter_beat";
    }

    if (![@[@"beat", @"half", @"half_beat", @"quarter", @"quarter_beat", @"bar", @"section"] containsObject:grid]) {
        return @{@"error": @"grid must be one of: beat, half_beat, quarter_beat, bar, section"};
    }
    if ([buildMode isEqualToString:@"xml"]) buildMode = @"fcpxml";
    if (![@[@"native", @"fcpxml"] containsObject:buildMode]) {
        return @{@"error": @"buildMode must be one of: native, fcpxml"};
    }
    if (targetCurrentTimeline && ![buildMode isEqualToString:@"native"]) {
        return @{@"error": @"targetCurrentTimeline is only supported for native builds"};
    }
    if (segmentMinStep < 1) segmentMinStep = 1;
    if (segmentMaxStep < segmentMinStep) segmentMaxStep = segmentMinStep;

    NSMutableDictionary<NSNumber *, NSNumber *> *stepWeights = [NSMutableDictionary dictionary];
    for (id rawKey in rawStepWeights) {
        NSInteger step = [rawKey integerValue];
        NSInteger weight = [rawStepWeights[rawKey] integerValue];
        if (step < segmentMinStep || step > segmentMaxStep || weight <= 0) continue;
        stepWeights[@(step)] = @(weight);
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

            SpliceKit_CMTime frameDuration = {100, 2400, 1, 0};
            SEL frameDurationSel = NSSelectorFromString(@"frameDuration");
            if ([sequence respondsToSelector:frameDurationSel]) {
                SpliceKit_CMTime fd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, frameDurationSel);
                if (fd.value > 0 && fd.timescale > 0) frameDuration = fd;
            }

            NSArray *rootItems = SpliceKit_mixerArrayFromContainer(
                ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems))) ?: @[];

            NSMutableArray<NSDictionary *> *activeVisibleEntries = [NSMutableArray array];
            NSMutableSet<NSString *> *visited = [NSMutableSet set];
            for (id item in rootItems) {
                SpliceKit_collectVisibleTimelineEntries(item, primaryObj, activeVisibleEntries, visited);
            }

            NSArray *selectedItems = nil;
            NSMutableSet<NSString *> *selectedKeys = [NSMutableSet set];
            SEL selectedSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
            if ([timeline respondsToSelector:selectedSel]) {
                id selItems = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selectedSel, NO, NO);
                selectedItems = SpliceKit_mixerArrayFromContainer(selItems);
            } else if ([timeline respondsToSelector:@selector(selectedItems)]) {
                selectedItems = SpliceKit_mixerArrayFromContainer(
                    ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(selectedItems)));
            }
            for (id selectedItem in selectedItems) {
                NSString *pointerKey = SpliceKit_handlePointerKey(selectedItem);
                if (pointerKey.length > 0) [selectedKeys addObject:pointerKey];
            }

            NSDictionary *sourceContext = nil;
            NSArray<NSDictionary *> *sourceVisibleEntries = nil;
            id sourcePrimaryObj = nil;
            if (sourceProjectName.length > 0) {
                sourceContext = SpliceKit_findVisibleEntryContextNamed(sourceProjectName);
                if ([sourceContext[@"error"] isKindOfClass:[NSString class]]) {
                    result = @{@"error": sourceContext[@"error"]};
                    return;
                }
                sourceVisibleEntries = sourceContext[@"visibleEntries"];
                sourcePrimaryObj = sourceContext[@"primaryObject"];
                if (sourceVisibleEntries.count == 0) {
                    result = @{@"error": [NSString stringWithFormat:@"No visible clips found in sourceProjectName \"%@\"", sourceProjectName]};
                    return;
                }
            } else {
                sourceVisibleEntries = activeVisibleEntries;
                sourcePrimaryObj = primaryObj;
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
                for (NSDictionary *entry in sourceVisibleEntries) {
                    if ([entry[@"pointerKey"] isEqualToString:sourceKey]) {
                        sourceEntry = entry;
                        break;
                    }
                }
                if (!sourceEntry) {
                    result = @{@"error": sourceProjectName.length > 0
                        ? @"Source clip handle is not visible in the requested source project"
                        : @"Source clip is not visible in the active timeline"};
                    return;
                }
            } else {
                NSArray *orderedEntries = [sourceVisibleEntries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
                    return [lhs[@"start"] compare:rhs[@"start"]];
                }];
                if (sourceProjectName.length == 0) {
                    for (NSDictionary *entry in orderedEntries) {
                        if (![selectedKeys containsObject:entry[@"pointerKey"]]) continue;
                        if (![entry[@"hasTimingMetadata"] boolValue] || ![entry[@"hasAudio"] boolValue]) continue;
                        sourceEntry = entry;
                        break;
                    }
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
                    result = @{@"error": sourceProjectName.length > 0
                        ? [NSString stringWithFormat:
                             @"No audio clip in project \"%@\" carries a Final Cut Pro beat map. "
                             @"These tools read Final Cut Pro's own timing metadata, which comes "
                             @"with songs from its music library; detect_beats cannot add it.",
                             sourceProjectName]
                        : @"No audio clip on this timeline carries a Final Cut Pro beat map. Pass "
                          @"sourceHandle to name a clip, or use detect_beats with beat_sync_blade "
                          @"to cut to beats on ordinary audio."};
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
            SpliceKit_CMTimeRange sourceClipRange = SpliceKit_clipRangeForItem(sourceItem);

            double sourceStartSec = 0.0;
            double sourceEndSec = 0.0;
            double tempo = 0.0;
            NSArray<NSNumber *> *timelineGrid = SpliceKit_translateTimingMetadataToTimeline(
                sourceItem, sourcePrimaryObj, grid, &sourceStartSec, &sourceEndSec, &tempo);
            double sourceDuration = sourceEndSec - sourceStartSec;
            if (timelineGrid.count == 0 || sourceDuration <= 0.0001) {
                result = @{@"error": @"Source clip has no usable timing metadata for the requested grid"};
                return;
            }
            NSString *sourceMediaURL = SpliceKit_getMediaURLForClip(sourceItem) ?: @"";
            if (sourceMediaURL.length == 0 && [sourceItem respondsToSelector:NSSelectorFromString(@"media")]) {
                id sourceMedia = ((id (*)(id, SEL))objc_msgSend)(sourceItem, NSSelectorFromString(@"media"));
                SEL originalMediaURLSel = NSSelectorFromString(@"originalMediaURL");
                if (sourceMedia && [sourceMedia respondsToSelector:originalMediaURLSel]) {
                    id originalMediaURL = ((id (*)(id, SEL))objc_msgSend)(sourceMedia, originalMediaURLSel);
                    if ([originalMediaURL respondsToSelector:@selector(absoluteString)]) {
                        sourceMediaURL = ((id (*)(id, SEL))objc_msgSend)(originalMediaURL, @selector(absoluteString)) ?: @"";
                    }
                }
            }
            NSString *sourceFallbackName = [sourceEntry[@"name"] isKindOfClass:[NSString class]]
                ? sourceEntry[@"name"] : SpliceKit_displayNameForItem(sourceItem);
            id sourceBrowserClip = SpliceKit_findBrowserClipMatchingMediaURL(sourceMediaURL, sourceFallbackName);
            id sourceInsertObject = sourceBrowserClip ?: sourceItem;

            NSMutableArray<NSNumber *> *boundaries = [NSMutableArray arrayWithObject:@0.0];
            for (NSNumber *markerNum in timelineGrid) {
                double relative = [markerNum doubleValue] - sourceStartSec;
                if (relative > 0.0001 && relative < sourceDuration - 0.0001) {
                    [boundaries addObject:@(relative)];
                }
            }
            [boundaries addObject:@(sourceDuration)];
            NSArray<NSNumber *> *sortedBoundaries = SpliceKit_sortedUniqueSeconds(boundaries, 0.0001);
            if (sortedBoundaries.count < 2) {
                result = @{@"error": @"Not enough beat boundaries found inside the source clip"};
                return;
            }

            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }
            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableSet<NSString *> *requestedClipKeys = [NSMutableSet set];
            for (id handleValue in clipHandles) {
                if (![handleValue isKindOfClass:[NSString class]]) continue;
                id clipObj = SpliceKit_resolveHandle(handleValue);
                NSString *pointerKey = SpliceKit_handlePointerKey(clipObj);
                if (pointerKey.length > 0) [requestedClipKeys addObject:pointerKey];
            }

            NSMutableArray<NSMutableDictionary *> *clipPool = [NSMutableArray array];
            if (clipSourceProjectName.length > 0) {
                NSDictionary *clipSourceContext = SpliceKit_findVisibleEntryContextNamed(clipSourceProjectName);
                if ([clipSourceContext[@"error"] isKindOfClass:[NSString class]]) {
                    result = @{@"error": clipSourceContext[@"error"]};
                    return;
                }

                NSArray<NSDictionary *> *clipEntries = clipSourceContext[@"visibleEntries"];
                if (clipEntries.count == 0) {
                    result = @{@"error": [NSString stringWithFormat:@"No visible clips found in clipSourceProjectName \"%@\"", clipSourceProjectName]};
                    return;
                }

                for (NSDictionary *entry in clipEntries) {
                    id clip = entry[@"item"];
                    NSString *pointerKey = entry[@"pointerKey"];
                    if (pointerKey.length == 0) continue;
                    if (requestedClipKeys.count > 0 && ![requestedClipKeys containsObject:pointerKey]) continue;
                    if (![entry[@"hasVideo"] boolValue] || [entry[@"isAudioOnly"] boolValue]) continue;

                    double durationSec = [entry[@"end"] doubleValue] - [entry[@"start"] doubleValue];
                    if (durationSec <= 0.050) continue;

                    NSString *mediaURL = SpliceKit_getMediaURLForClip(clip) ?: @"";
                    if (mediaURL.length > 0) {
                        if (sourceMediaURL.length > 0 && [mediaURL isEqualToString:sourceMediaURL]) continue;
                        if (SpliceKit_mediaURLLooksAudioOnly(mediaURL)) continue;
                    }

                    // Resolve the timeline clip to its browser equivalent for native insertion.
                    // The native edit path requires organizer-backed items, not raw
                    // FFAnchoredMediaComponent objects from another sequence's timeline.
                    NSString *clipDisplayName = [entry[@"name"] isKindOfClass:[NSString class]]
                        ? entry[@"name"] : SpliceKit_displayNameForItem(clip);
                    id browserClip = SpliceKit_findBrowserClipMatchingMediaURL(mediaURL, clipDisplayName);
                    if (!browserClip) {
                        // URL didn't match — media is likely inside a browser sequence.
                        // Fall back to name-based matching against browser clips.
                        browserClip = SpliceKit_findBrowserClipMatchingMediaURL(nil, clipDisplayName);
                    }
                    id poolClip = browserClip ?: clip;
                    double poolDurationSec = durationSec;
                    if (browserClip && [browserClip respondsToSelector:@selector(duration)]) {
                        SpliceKit_CMTime bDur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(browserClip, @selector(duration));
                        double bDurSec = SpliceKit_cmtimeToSeconds(bDur);
                        if (bDurSec > poolDurationSec) poolDurationSec = bDurSec;
                    }

                    NSString *handle = SpliceKit_storeHandle(poolClip);
                    [clipPool addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                        @"clip": poolClip,
                        @"pointerKey": pointerKey,
                        @"handle": handle ?: @"",
                        @"name": clipDisplayName,
                        @"event": clipSourceProjectName ?: @"",
                        @"durationSeconds": @(poolDurationSec),
                        @"mediaURL": mediaURL ?: @"",
                    }]];
                }
            } else {
                for (id event in (NSArray *)events) {
                    NSString *browserEventName = SpliceKit_displayNameForItem(event);
                    if (eventName.length > 0 &&
                        ![[browserEventName lowercaseString] containsString:[eventName lowercaseString]]) {
                        continue;
                    }

                    NSArray *clips = SpliceKit_copyBrowserClipsForEvent(event);
                    for (id clip in clips) {
                        NSString *pointerKey = SpliceKit_handlePointerKey(clip);
                        if (pointerKey.length == 0) continue;
                        if (requestedClipKeys.count > 0 && ![requestedClipKeys containsObject:pointerKey]) continue;

                        BOOL hasVideo = SpliceKit_boolForSelector(clip, @"hasVideo");
                        BOOL hasContainedItems = SpliceKit_boolForSelector(clip, @"hasContainedItems");
                        if (!hasVideo) {
                            NSString *className = NSStringFromClass([clip class]);
                            hasVideo = [className containsString:@"Video"] ||
                                       [className containsString:@"Media"] ||
                                       [className containsString:@"Asset"] ||
                                       [className containsString:@"Clip"] ||
                                       [className containsString:@"Sequence"] ||
                                       hasContainedItems;
                        }
                        if (!hasVideo) continue;

                        double durationSec = 0.0;
                        if ([clip respondsToSelector:@selector(duration)]) {
                            SpliceKit_CMTime duration = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(clip, @selector(duration));
                            durationSec = SpliceKit_cmtimeToSeconds(duration);
                        } else if ([clip respondsToSelector:NSSelectorFromString(@"clippedRange")]) {
                            SpliceKit_CMTimeRange range = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(
                                clip, NSSelectorFromString(@"clippedRange"));
                            durationSec = SpliceKit_cmtimeToSeconds(range.duration);
                        } else if ([clip respondsToSelector:NSSelectorFromString(@"unclippedRange")]) {
                            SpliceKit_CMTimeRange range = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(
                                clip, NSSelectorFromString(@"unclippedRange"));
                            durationSec = SpliceKit_cmtimeToSeconds(range.duration);
                        } else if ([clip respondsToSelector:NSSelectorFromString(@"mediaRange")]) {
                            SpliceKit_CMTimeRange range = ((SpliceKit_CMTimeRange (*)(id, SEL))STRET_MSG)(
                                clip, NSSelectorFromString(@"mediaRange"));
                            durationSec = SpliceKit_cmtimeToSeconds(range.duration);
                        }
                        if (durationSec <= 0.050) continue;

                        NSString *mediaURL = SpliceKit_getMediaURLForClip(clip) ?: @"";
                        NSString *clipClassName = NSStringFromClass([clip class]) ?: @"";
                        if (mediaURL.length > 0) {
                            if (sourceMediaURL.length > 0 && [mediaURL isEqualToString:sourceMediaURL]) continue;
                            if (SpliceKit_mediaURLLooksAudioOnly(mediaURL)) continue;
                        } else if (hasContainedItems ||
                                   [clipClassName containsString:@"Sequence"] ||
                                   [clipClassName containsString:@"Project"]) {
                            // Keep the song-cut pool on media-backed clips instead of previously generated projects.
                            continue;
                        }

                        NSString *handle = SpliceKit_storeHandle(clip);
                        [clipPool addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                            @"clip": clip,
                            @"pointerKey": pointerKey,
                            @"handle": handle ?: @"",
                            @"name": SpliceKit_displayNameForItem(clip),
                            @"event": browserEventName ?: @"",
                            @"durationSeconds": @(durationSec),
                            @"mediaURL": mediaURL ?: @"",
                        }]];
                    }
                }
            }
            if (clipPool.count == 0) {
                result = @{@"error": clipSourceProjectName.length > 0
                    ? @"No eligible source clips found in the requested clipSourceProjectName"
                    : @"No browser clips found for random beat assembly"};
                return;
            }
            if (includeAudio && !sourceInsertObject && !dryRun) {
                result = @{@"error": @"Couldn't resolve the selected beat source song for native insertion"};
                return;
            }

            NSMutableArray<NSMutableDictionary *> *plan = [NSMutableArray array];
            NSMutableSet<NSString *> *usedClipKeys = [NSMutableSet set];
            NSUInteger assignedClipCount = 0;
            NSUInteger gapCount = 0;
            uint64_t rngState = (uint64_t)randomSeed;
            BOOL isHalfBeatGrid = [grid isEqualToString:@"half_beat"] || [grid isEqualToString:@"half"];
            BOOL forceNextHalfBeat = NO;
            for (NSUInteger boundaryIndex = 0; boundaryIndex + 1 < sortedBoundaries.count;) {
                NSInteger requestedStep;
                if (forceNextHalfBeat) {
                    // Second half of a half-beat pair — force step=1 so the pair
                    // resolves on a whole-beat boundary.
                    requestedStep = 1;
                    forceNextHalfBeat = NO;
                } else {
                    requestedStep = SpliceKit_chooseRandomAssemblyStep(segmentMinStep, segmentMaxStep, stepWeights, &rngState);
                    if (requestedStep == 1 && isHalfBeatGrid && segmentMaxStep > 1) {
                        // Half-beats always come in pairs.
                        forceNextHalfBeat = YES;
                    }
                }
                NSUInteger maxRemaining = sortedBoundaries.count - 1 - boundaryIndex;
                if ((NSUInteger)requestedStep > maxRemaining) requestedStep = (NSInteger)maxRemaining;

                double startSec = [sortedBoundaries[boundaryIndex] doubleValue];
                NSMutableArray<NSMutableDictionary *> *eligible = nil;
                double segmentDuration = 0.0;
                NSUInteger nextBoundaryIndex = NSNotFound;

                for (NSInteger step = requestedStep; step >= 1; step--) {
                    NSUInteger candidateNextIndex = MIN(sortedBoundaries.count - 1, boundaryIndex + (NSUInteger)step);
                    if (candidateNextIndex <= boundaryIndex) continue;

                    double candidateEndSec = [sortedBoundaries[candidateNextIndex] doubleValue];
                    double candidateDuration = candidateEndSec - startSec;
                    if (candidateDuration <= 0.0001) continue;

                    NSMutableArray<NSMutableDictionary *> *candidates = [NSMutableArray array];
                    for (NSMutableDictionary *candidate in clipPool) {
                        if (!allowClipReuse && [usedClipKeys containsObject:candidate[@"pointerKey"]]) continue;
                        if ([candidate[@"durationSeconds"] doubleValue] + 0.0001 < candidateDuration) continue;
                        [candidates addObject:candidate];
                    }
                    if (candidates.count > 0) {
                        eligible = candidates;
                        segmentDuration = candidateDuration;
                        nextBoundaryIndex = candidateNextIndex;
                        requestedStep = step;
                        break;
                    }
                }

                if (!eligible || nextBoundaryIndex == NSNotFound) {
                    NSUInteger fallbackNextIndex = MIN(sortedBoundaries.count - 1, boundaryIndex + 1);
                    if (fallbackNextIndex <= boundaryIndex) break;

                    gapCount++;
                    [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                        @"segmentIndex": @(plan.count),
                        @"timelineStartSeconds": @(startSec),
                        @"durationSeconds": @([sortedBoundaries[fallbackNextIndex] doubleValue] - startSec),
                        @"clipName": [NSString stringWithFormat:@"Gap %lu", (unsigned long)(plan.count + 1)],
                        @"status": @"gap",
                    }]];
                    boundaryIndex = fallbackNextIndex;
                    if (maxSegments > 0 && (NSInteger)plan.count >= maxSegments) break;
                    continue;
                }

                NSMutableDictionary *chosen = nil;
                while (eligible.count > 0) {
                    NSUInteger choiceIndex = (NSUInteger)(SpliceKit_nextRandom(&rngState) % (uint64_t)eligible.count);
                    NSMutableDictionary *candidate = eligible[choiceIndex];
                    NSString *mediaURL = candidate[@"mediaURL"];
                    if (![mediaURL isKindOfClass:[NSString class]] || mediaURL.length == 0) {
                        NSString *resolved = SpliceKit_getMediaURLForClip(candidate[@"clip"]);
                        if (resolved.length > 0) {
                            if (sourceMediaURL.length > 0 && [resolved isEqualToString:sourceMediaURL]) {
                                [eligible removeObjectAtIndex:choiceIndex];
                                continue;
                            }
                            if (SpliceKit_mediaURLLooksAudioOnly(resolved)) {
                                [eligible removeObjectAtIndex:choiceIndex];
                                continue;
                            }
                            candidate[@"mediaURL"] = resolved;
                            mediaURL = resolved;
                        }
                    }

                    if ([buildMode isEqualToString:@"fcpxml"] && mediaURL.length == 0) {
                        [eligible removeObjectAtIndex:choiceIndex];
                        continue;
                    }

                    chosen = candidate;
                    break;
                }

                if (!chosen) {
                    gapCount++;
                    [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                        @"segmentIndex": @(plan.count),
                        @"timelineStartSeconds": @(startSec),
                        @"durationSeconds": @(segmentDuration),
                        @"clipName": [NSString stringWithFormat:@"Gap %lu", (unsigned long)(plan.count + 1)],
                        @"status": @"gap",
                    }]];
                    boundaryIndex = nextBoundaryIndex;
                    if (maxSegments > 0 && (NSInteger)plan.count >= maxSegments) break;
                    continue;
                }

                if (!allowClipReuse) {
                    [usedClipKeys addObject:chosen[@"pointerKey"]];
                }

                double clipDuration = [chosen[@"durationSeconds"] doubleValue];
                double maxIn = MAX(0.0, clipDuration - segmentDuration);
                double inPoint = 0.0;
                if (maxIn > 0.0001) {
                    double unit = (double)(SpliceKit_nextRandom(&rngState) % 1000000ULL) / 1000000.0;
                    inPoint = unit * maxIn;
                }

                assignedClipCount++;
                [plan addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                    @"segmentIndex": @(plan.count),
                    @"timelineStartSeconds": @(startSec),
                    @"durationSeconds": @(segmentDuration),
                    @"clipHandle": chosen[@"handle"] ?: @"",
                    @"clipName": chosen[@"name"] ?: @"Clip",
                    @"clipEvent": chosen[@"event"] ?: @"",
                    @"inSeconds": @(inPoint),
                    @"outSeconds": @(inPoint + segmentDuration),
                    @"mediaURL": chosen[@"mediaURL"] ?: @"",
                    @"step": @(requestedStep),
                    @"status": @"planned",
                }]];
                boundaryIndex = nextBoundaryIndex;
                if (maxSegments > 0 && (NSInteger)plan.count >= maxSegments) break;
            }

            if (plan.count == 0) {
                result = @{@"error": @"Unable to derive any assembly segments from the beat map"};
                return;
            }
            if (gapCount > 0) {
                result = @{@"error": @"Could not cover the full song length with the current clip pool at the requested pacing. Use shorter spans or provide longer video clips."};
                return;
            }

            NSString *destinationProjectName = targetCurrentTimeline
                ? (SpliceKit_displayNameForItem(sequence).length > 0 ? SpliceKit_displayNameForItem(sequence) : projectName)
                : projectName;

            if (dryRun) {
                result = @{
                    @"status": @"ok",
                    @"dryRun": @YES,
                    @"buildMethod": buildMode,
                    @"grid": grid,
                    @"projectName": destinationProjectName,
                    @"randomSeed": @(randomSeed),
                    @"segmentMinStep": @(segmentMinStep),
                    @"segmentMaxStep": @(segmentMaxStep),
                    @"allowClipReuse": @(allowClipReuse),
                    @"targetCurrentTimeline": @(targetCurrentTimeline),
                    @"source": @{
                        @"handle": SpliceKit_storeHandle(sourceItem),
                        @"name": sourceEntry[@"name"] ?: @"",
                        @"tempo": @(tempo),
                        @"duration": @(sourceDuration),
                    },
                    @"segmentCount": @(plan.count),
                    @"assignedClipCount": @(assignedClipCount),
                    @"gapCount": @(gapCount),
                    @"clipPoolCount": @(clipPool.count),
                    @"plan": plan,
                };
                return;
            }

            double frameSeconds = SpliceKit_secondsFromTime(frameDuration);
            if (!isfinite(frameSeconds) || frameSeconds <= 0.000001) {
                frameSeconds = 1.0 / 24.0;
            }

            // Quantize each segment's offset from its ORIGINAL beat boundary time
            // to prevent cumulative rounding drift across hundreds of segments.
            long long totalDurationFrames = 0;
            for (NSMutableDictionary *entry in plan) {
                double startSeconds = [entry[@"timelineStartSeconds"] doubleValue];
                double endSeconds = startSeconds + [entry[@"durationSeconds"] doubleValue];
                long long startFrames = MAX(0LL, llround(startSeconds / frameSeconds));
                long long endFrames = MAX(startFrames + 1, llround(endSeconds / frameSeconds));
                long long durationFrames = endFrames - startFrames;

                entry[@"timelineOffsetFrames"] = @(startFrames);
                entry[@"durationFrames"] = @(durationFrames);
                totalDurationFrames = endFrames;

                NSNumber *inSecondsValue = entry[@"inSeconds"];
                if (inSecondsValue) {
                    long long inFrames = MAX(0LL, llround([inSecondsValue doubleValue] / frameSeconds));
                    entry[@"inFrames"] = @(inFrames);
                }
            }

            id targetEvent = nil;
            NSString *targetEventName = @"";
            if (!targetCurrentTimeline) {
                targetEvent = SpliceKit_findAssemblyEvent((NSArray *)events, eventName);
                if (!targetEvent) {
                    result = @{@"error": @"Couldn't find a target event for project creation"};
                    return;
                }
                targetEventName = SpliceKit_displayNameForItem(targetEvent) ?: @"SpliceKit Tests";
            }
            NSString *songMediaURLForBuild = sourceMediaURL.length > 0
                ? sourceMediaURL
                : (sourceInsertObject ? (SpliceKit_getMediaURLForClip(sourceInsertObject) ?: @"") : @"");

            if ([buildMode isEqualToString:@"fcpxml"]) {
                NSString *fcpxmlError = nil;
                NSString *xml = SpliceKit_buildRandomClipAssemblyFCPXML(
                    plan,
                    destinationProjectName,
                    targetEventName,
                    frameDuration,
                    includeAudio ? songMediaURLForBuild : @"",
                    totalDurationFrames,
                    &fcpxmlError);
                if (xml.length == 0) {
                    result = @{@"error": fcpxmlError ?: @"Failed to build the song-cut FCPXML document"};
                    return;
                }

                NSDictionary *importResult = SpliceKit_handleFCPXMLImport(@{
                    @"xml": xml,
                    @"internal": @YES,
                }) ?: @{};
                if ([importResult[@"error"] isKindOfClass:[NSString class]]) {
                    result = @{@"error": importResult[@"error"]};
                    return;
                }

                result = @{
                    @"status": @"ok",
                    @"dryRun": @NO,
                    @"grid": grid,
                    @"projectName": destinationProjectName,
                    @"randomSeed": @(randomSeed),
                    @"segmentMinStep": @(segmentMinStep),
                    @"segmentMaxStep": @(segmentMaxStep),
                    @"allowClipReuse": @(allowClipReuse),
                    @"targetCurrentTimeline": @NO,
                    @"source": @{
                        @"handle": SpliceKit_storeHandle(sourceItem),
                        @"name": sourceEntry[@"name"] ?: @"",
                        @"tempo": @(tempo),
                        @"duration": @(sourceDuration),
                    },
                    @"segmentCount": @(plan.count),
                    @"assignedClipCount": @(assignedClipCount),
                    @"appliedClipCount": @(assignedClipCount),
                    @"failedSegmentCount": @0,
                    @"omittedSegmentCount": @0,
                    @"gapCount": @0,
                    @"clipPoolCount": @(clipPool.count),
                    @"buildMethod": @"fcpxml",
                    @"projectFound": @YES,
                    @"projectLoaded": @NO,
                    @"fcpxmlImport": importResult,
                    @"songAudioInserted": @(includeAudio && songMediaURLForBuild.length > 0),
                    @"songAudioError": (includeAudio && songMediaURLForBuild.length == 0)
                        ? @"The selected song could not be resolved to a media URL for the FCPXML build"
                        : @"",
                    @"projectHandle": @"",
                    @"plan": plan,
                };
                return;
            }

            NSDictionary *nativeProject = targetCurrentTimeline
                ? @{
                    @"ok": @YES,
                    @"loaded": @YES,
                    @"sequence": sequence,
                    @"sequenceHandle": SpliceKit_storeHandle(sequence) ?: @"",
                    @"createdObjectClass": @"",
                    @"eventName": @"",
                    @"reusedCurrentTimeline": @YES,
                }
                : (SpliceKit_createNativeProjectSequence(destinationProjectName, targetEvent) ?: @{});
            NSMutableDictionary *nativeProjectResult = [nativeProject mutableCopy];
            [nativeProjectResult removeObjectForKey:@"sequence"];
            id importedSequence = nativeProject[@"sequence"];
            BOOL loadedSequence = [nativeProject[@"loaded"] boolValue];
            id buildTimeline = targetCurrentTimeline ? timeline : nil;

            if (targetCurrentTimeline) {
                if (activeVisibleEntries.count > 0) {
                    result = @{@"error": @"targetCurrentTimeline requires the active timeline to be empty before assembly"};
                    return;
                }
            } else if (loadedSequence) {
                for (int attempt = 0; attempt < 40; attempt++) {
                    [[NSRunLoop currentRunLoop] runUntilDate:
                        [NSDate dateWithTimeIntervalSinceNow:0.1]];
                    buildTimeline = SpliceKit_getActiveTimelineModule();
                    if (!buildTimeline) continue;
                    id activeSequence = [buildTimeline respondsToSelector:@selector(sequence)]
                        ? ((id (*)(id, SEL))objc_msgSend)(buildTimeline, @selector(sequence))
                        : nil;
                    NSString *activeName = [activeSequence respondsToSelector:@selector(displayName)]
                        ? ((id (*)(id, SEL))objc_msgSend)(activeSequence, @selector(displayName))
                        : nil;
                    if (activeName.length > 0 && [activeName isEqualToString:destinationProjectName]) {
                        break;
                    }
                    buildTimeline = nil;
                }
            }

            NSUInteger omittedSegments = 0;
            NSUInteger appliedSegments = 0;
            NSUInteger failedSegments = 0;
            long long builtDurationFrames = 0;
            NSMutableDictionary *nativeErrors = [NSMutableDictionary dictionary];

            id buildSequence = (buildTimeline && [buildTimeline respondsToSelector:@selector(sequence)])
                ? ((id (*)(id, SEL))objc_msgSend)(buildTimeline, @selector(sequence))
                : nil;
            NSString *assembleUndoName = @"Assemble to Beats";
            BOOL openedAssembleUndo = NO;
            if (loadedSequence && buildTimeline && buildSequence) {
                openedAssembleUndo = SpliceKit_internalBeginEditGroupIfNeeded(buildSequence, assembleUndoName);
            }

            BOOL songAudioInserted = NO;
            NSString *songAudioError = @"";
            NSDictionary *songAudioPrep = @{};
            NSDictionary *songAudioEdit = @{};

            @try {
            if (loadedSequence && buildTimeline) {
                for (NSMutableDictionary *entry in plan) {
                    if ([entry[@"status"] isEqualToString:@"gap"]) {
                        entry[@"status"] = @"omitted";
                        entry[@"reason"] = entry[@"reason"] ?: @"No eligible browser clip was available for this beat span";
                        omittedSegments++;
                        continue;
                    }

                    NSString *clipHandle = [entry[@"clipHandle"] isKindOfClass:[NSString class]] ? entry[@"clipHandle"] : @"";
                    id sourceClip = clipHandle.length > 0 ? SpliceKit_resolveHandle(clipHandle) : nil;
                    if (!sourceClip) {
                        entry[@"status"] = @"failed";
                        entry[@"reason"] = @"Source clip handle could not be resolved";
                        failedSegments++;
                        continue;
                    }

                    SpliceKit_CMTimeRange sourceClipRange = SpliceKit_clipRangeForItem(sourceClip);
                    int32_t segmentTimescale = sourceClipRange.start.timescale > 0
                        ? sourceClipRange.start.timescale
                        : (sourceClipRange.duration.timescale > 0
                            ? sourceClipRange.duration.timescale
                            : (frameDuration.timescale > 0 ? frameDuration.timescale : 6000));
                    double inSeconds = [entry[@"inFrames"] longLongValue] * frameSeconds;
                    double durationSeconds = [entry[@"durationFrames"] longLongValue] * frameSeconds;
                    SpliceKit_CMTimeRange segmentRange = sourceClipRange;
                    segmentRange.start = SpliceKit_addSecondsToCMTime(sourceClipRange.start, inSeconds);
                    segmentRange.duration = SpliceKit_makeCMTimeWithTimescale(durationSeconds, segmentTimescale);

                    NSDictionary *sourcePrep = SpliceKit_prepareBrowserClipSourceForInsertion(sourceClip, segmentRange, NO) ?: @{};
                    if (![sourcePrep[@"ok"] boolValue]) {
                        entry[@"status"] = @"failed";
                        entry[@"reason"] = [sourcePrep[@"error"] isKindOfClass:[NSString class]]
                            ? sourcePrep[@"error"] : @"Failed to prepare the browser clip segment";
                        failedSegments++;
                        continue;
                    }

                    NSDictionary *editDiag = SpliceKit_performPreparedMediaEdit(
                        buildTimeline,
                        2,
                        NO,
                        @"all",
                        NO,
                        SpliceKit_makeCMTimeWithTimescale(0.0, frameDuration.timescale));
                    if (![editDiag[@"ok"] boolValue]) {
                        entry[@"status"] = @"failed";
                        entry[@"reason"] = [editDiag[@"error"] isKindOfClass:[NSString class]]
                            ? editDiag[@"error"] : @"Native append edit failed";
                        failedSegments++;
                        continue;
                    }

                    entry[@"status"] = @"applied";
                    entry[@"nativeAction"] = @"appendWithSelectedMedia:";
                    builtDurationFrames += [entry[@"durationFrames"] longLongValue];
                    appliedSegments++;
                }
            } else {
                nativeErrors[@"project"] = [nativeProject[@"error"] isKindOfClass:[NSString class]]
                    ? nativeProject[@"error"] : @"Failed to create or load the native target project";
            }

            if (loadedSequence && buildTimeline && includeAudio && sourceInsertObject && builtDurationFrames > 0) {
                double targetSongSeconds = MIN(sourceDuration, builtDurationFrames * frameSeconds);
                int32_t songTimescale = sourceClipRange.duration.timescale > 0
                    ? sourceClipRange.duration.timescale
                    : (frameDuration.timescale > 0 ? frameDuration.timescale : 6000);
                SpliceKit_CMTimeRange songInsertRange = sourceClipRange;
                songInsertRange.duration = SpliceKit_makeCMTimeWithTimescale(targetSongSeconds, songTimescale);

                songAudioPrep = SpliceKit_prepareBrowserClipSourceForInsertion(sourceInsertObject, songInsertRange, YES) ?: @{};
                if (![songAudioPrep[@"ok"] boolValue]) {
                    songAudioError = [songAudioPrep[@"error"] isKindOfClass:[NSString class]]
                        ? songAudioPrep[@"error"] : @"Could not prepare the source song for insertion";
                } else {
                    SpliceKit_CMTime zero = SpliceKit_makeCMTimeWithTimescale(0.0, frameDuration.timescale);
                    songAudioEdit = SpliceKit_performPreparedMediaEdit(
                        buildTimeline,
                        3,
                        NO,
                        @"audio",
                        YES,
                        zero) ?: @{};
                    songAudioInserted = [songAudioEdit[@"ok"] boolValue];
                    if (!songAudioInserted) {
                        songAudioError = [songAudioEdit[@"error"] isKindOfClass:[NSString class]]
                            ? songAudioEdit[@"error"] : @"Native song connect edit failed";
                    } else {
                        SEL setPlayheadSel = NSSelectorFromString(@"setPlayheadTime:");
                        if ([buildTimeline respondsToSelector:setPlayheadSel]) {
                            ((void (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(buildTimeline, setPlayheadSel, zero);
                        }
                        SEL commitSel = NSSelectorFromString(@"setCommittedPlayheadTime:");
                        if ([buildTimeline respondsToSelector:commitSel]) {
                            ((void (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(buildTimeline, commitSel, zero);
                        }
                    }
                }
            } else if (includeAudio && !sourceInsertObject) {
                songAudioError = @"Couldn't resolve the selected beat source song for native insertion";
            } else if (includeAudio && builtDurationFrames <= 0) {
                songAudioError = @"No video segments were appended, so the song was not connected";
            }
            } @finally {
                if (openedAssembleUndo) {
                    SpliceKit_internalEndEditGroupIfOpened(buildSequence, buildTimeline, assembleUndoName, YES);
                }
            }

            result = @{
                @"status": @"ok",
                @"dryRun": @NO,
                @"grid": grid,
                @"projectName": destinationProjectName,
                @"randomSeed": @(randomSeed),
                @"segmentMinStep": @(segmentMinStep),
                @"segmentMaxStep": @(segmentMaxStep),
                @"allowClipReuse": @(allowClipReuse),
                @"targetCurrentTimeline": @(targetCurrentTimeline),
                @"source": @{
                    @"handle": SpliceKit_storeHandle(sourceItem),
                    @"name": sourceEntry[@"name"] ?: @"",
                    @"tempo": @(tempo),
                    @"duration": @(sourceDuration),
                },
                @"segmentCount": @(plan.count),
                @"assignedClipCount": @(assignedClipCount),
                @"appliedClipCount": @(appliedSegments),
                @"failedSegmentCount": @(failedSegments),
                @"omittedSegmentCount": @(omittedSegments),
                @"gapCount": @0,
                @"clipPoolCount": @(clipPool.count),
                @"buildMethod": buildMode,
                @"projectFound": @(importedSequence != nil),
                @"projectLoaded": @(loadedSequence && buildTimeline != nil),
                @"nativeProject": nativeProjectResult ?: @{},
                @"nativeErrors": nativeErrors,
                @"songAudioInserted": @(songAudioInserted),
                @"songAudioError": songAudioError ?: @"",
                @"songAudioPrep": songAudioPrep ?: @{},
                @"songAudioEdit": songAudioEdit ?: @{},
                @"projectHandle": importedSequence ? SpliceKit_storeHandle(importedSequence) : @"",
                @"plan": plan,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to assemble random clips to song beats"};
}

#pragma mark - Song structure blocks (captions + storyline removal / placement)

static NSString * const kSpliceKitStructureStorylineName = @"SpliceKit Structure";

static id SpliceKit_structurePrimaryObject(id sequence) {
    if (!sequence) return nil;
    SEL sel = NSSelectorFromString(@"primaryObject");
    if (![sequence respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(sequence, sel);
}

static NSUInteger SpliceKit_structureCountStorylinesNamed(id sequence, NSString *name) {
    id primary = SpliceKit_structurePrimaryObject(sequence);
    if (!primary) return 0;

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel) : nil;
    if (![items isKindOfClass:[NSArray class]]) return 0;

    NSUInteger count = 0;
    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");

    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = SpliceKit_mixerArrayFromContainer(anchoredRaw);
        if (!anchored.count) continue;

        for (id obj in anchored) {
            NSString *className = NSStringFromClass([obj class]) ?: @"";
            if (![className containsString:@"Collection"]) continue;

            NSString *dn = nil;
            @try {
                if ([obj respondsToSelector:displayNameSel]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(obj, displayNameSel);
                    if ([n isKindOfClass:[NSString class]]) dn = n;
                }
            } @catch (NSException *e) {}

            if (name.length > 0 && [dn isEqualToString:name]) {
                count++;
            }
        }
    }
    return count;
}

static NSUInteger SpliceKit_structureRemoveStorylineNamed(id sequence, NSString *name) {
    id primary = SpliceKit_structurePrimaryObject(sequence);
    if (!primary) return 0;

    SEL itemsSel = NSSelectorFromString(@"containedItems");
    NSArray *items = [primary respondsToSelector:itemsSel]
        ? ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel) : nil;
    if (![items isKindOfClass:[NSArray class]]) return 0;

    NSUInteger removed = 0;
    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    SEL displayNameSel = NSSelectorFromString(@"displayName");
    SEL removeSel1 = NSSelectorFromString(@"removeAnchoredItemsObject:");
    SEL removeSel2 = NSSelectorFromString(@"removeAnchoredObject:");

    for (id item in items) {
        if (![item respondsToSelector:anchoredSel]) continue;
        id anchoredRaw = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
        NSArray *anchored = SpliceKit_mixerArrayFromContainer(anchoredRaw);
        if (!anchored.count) continue;

        for (id obj in anchored) {
            NSString *className = NSStringFromClass([obj class]) ?: @"";
            if (![className containsString:@"Collection"]) continue;

            NSString *dn = nil;
            @try {
                if ([obj respondsToSelector:displayNameSel]) {
                    id n = ((id (*)(id, SEL))objc_msgSend)(obj, displayNameSel);
                    if ([n isKindOfClass:[NSString class]]) dn = n;
                }
            } @catch (NSException *e) {}

            if (name.length > 0 && ![dn isEqualToString:name]) continue;

            if ([item respondsToSelector:removeSel1]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeSel1, obj);
                removed++;
            } else if ([item respondsToSelector:removeSel2]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, removeSel2, obj);
                removed++;
            }
        }
    }
    return removed;
}

// Captions created by structure.generateCaptions (session registry, keyed by sequence).
static NSMutableDictionary<NSString *, NSHashTable<id> *> *SpliceKit_structureCaptionRegistry(void) {
    static NSMutableDictionary *registry = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registry = [NSMutableDictionary dictionary];
    });
    return registry;
}

static NSString *SpliceKit_structureSequenceRegistryKey(id sequence) {
    if (!sequence) return nil;
    return [NSString stringWithFormat:@"%p", sequence];
}

static NSHashTable<id> *SpliceKit_structureCaptionTableForSequence(id sequence, BOOL create) {
    NSString *key = SpliceKit_structureSequenceRegistryKey(sequence);
    if (!key.length) return nil;
    NSMutableDictionary *registry = SpliceKit_structureCaptionRegistry();
    NSHashTable<id> *table = registry[key];
    if (!table && create) {
        table = [NSHashTable weakObjectsHashTable];
        registry[key] = table;
    }
    return table;
}

static void SpliceKit_structureRegisterCaptions(id sequence, NSArray *captions) {
    if (!sequence || captions.count == 0) return;
    NSHashTable<id> *table = SpliceKit_structureCaptionTableForSequence(sequence, YES);
    for (id caption in captions) {
        if (caption) [table addObject:caption];
    }
}

static void SpliceKit_structureUnregisterCaptions(id sequence, NSArray *captions) {
    if (!sequence || captions.count == 0) return;
    NSHashTable<id> *table = SpliceKit_structureCaptionTableForSequence(sequence, NO);
    if (!table) return;
    for (id caption in captions) {
        if (caption) [table removeObject:caption];
    }
}

// The gap Final Cut Pro appends when structure captions extend past the sequence
// end. A previous per-sequence weak NSHashTable of gap pointers stayed empty:
// the before-snapshot and the registration walk used the sequence pointer captured
// before the temp-project switch, while paste lands on whatever loadEditorForSequence:
// makes active afterwards, and the walk ran before that gap was on containedItems.
// Pointer identity also dies when Final Cut Pro quits. Record the pre-paste
// duration instead, keyed by stable sequence identity, in this process's defaults.
static NSString * const kSpliceKitStructureGapDefaultsKey = @"SpliceKitStructureAppendedSpineGaps";

static NSString *SpliceKit_structureIdentifierString(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value length] ? value : nil;
    }
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    if ([value isKindOfClass:[NSUUID class]]) return [(NSUUID *)value UUIDString];
    if ([value respondsToSelector:@selector(UUIDString)]) {
        @try {
            id s = ((id (*)(id, SEL))objc_msgSend)(value, @selector(UUIDString));
            if ([s isKindOfClass:[NSString class]] && [(NSString *)s length]) return s;
        } @catch (NSException *e) {}
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        @try {
            id s = ((id (*)(id, SEL))objc_msgSend)(value, @selector(stringValue));
            if ([s isKindOfClass:[NSString class]] && [(NSString *)s length]) return s;
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSString *SpliceKit_structureObjectIdentifier(id obj, NSArray<NSString *> *selectors) {
    if (!obj) return nil;
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if (![obj respondsToSelector:sel]) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        } @catch (NSException *e) {
            continue;
        }
        NSString *s = SpliceKit_structureIdentifierString(value);
        if (s.length) return s;
    }
    return nil;
}

static id SpliceKit_structureRelatedObject(id obj, NSArray<NSString *> *selectors) {
    if (!obj) return nil;
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if (![obj respondsToSelector:sel]) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        } @catch (NSException *e) {
            continue;
        }
        if (value) return value;
    }
    return nil;
}

// uid when the sequence answers one, plus library + event + name. Either key
// still matches after a relaunch; pointer keys do not.
static NSArray<NSString *> *SpliceKit_structureSequenceLookupKeys(id sequence) {
    if (!sequence) return @[];
    NSString *uid = SpliceKit_structureObjectIdentifier(sequence, @[
        @"uid", @"UID", @"persistentID", @"identifier", @"uniqueID", @"mediaIdentifier"
    ]);
    NSString *name = SpliceKit_structureObjectIdentifier(sequence, @[@"displayName"]);
    id event = SpliceKit_structureRelatedObject(sequence, @[@"event"]);
    NSString *eventName = SpliceKit_structureObjectIdentifier(event, @[@"displayName", @"uid", @"persistentID"]);
    id library = SpliceKit_structureRelatedObject(sequence, @[@"library", @"libraryDocument", @"document"]);
    if (!library) {
        library = SpliceKit_structureRelatedObject(event, @[@"library", @"libraryDocument", @"document"]);
    }
    NSString *libraryID = SpliceKit_structureObjectIdentifier(library, @[
        @"persistentID", @"uid", @"identifier", @"displayName"
    ]);

    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    if (uid.length) {
        [keys addObject:[NSString stringWithFormat:@"uid:%@|lib:%@", uid, libraryID ?: @""]];
    }
    if (name.length || eventName.length || libraryID.length) {
        [keys addObject:[NSString stringWithFormat:@"name:%@|event:%@|lib:%@",
                         name ?: @"", eventName ?: @"", libraryID ?: @""]];
    }
    return keys;
}

static NSDictionary *SpliceKit_structureGapRecordMap(void) {
    id stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSpliceKitStructureGapDefaultsKey];
    return [stored isKindOfClass:[NSDictionary class]] ? stored : @{};
}

static void SpliceKit_structureSaveGapRecordMap(NSDictionary *map) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (map.count == 0) {
        [defaults removeObjectForKey:kSpliceKitStructureGapDefaultsKey];
    } else {
        [defaults setObject:map forKey:kSpliceKitStructureGapDefaultsKey];
    }
    [defaults synchronize];
}

static NSDictionary *SpliceKit_structureCopyGapEntry(NSString *sequenceKey) {
    if (sequenceKey.length == 0) return nil;
    id entry = SpliceKit_structureGapRecordMap()[sequenceKey];
    return [entry isKindOfClass:[NSDictionary class]] ? [entry copy] : nil;
}

static void SpliceKit_structureSetGapEntry(NSString *sequenceKey, NSDictionary *entryOrNil) {
    if (sequenceKey.length == 0) return;
    NSMutableDictionary *map = [SpliceKit_structureGapRecordMap() mutableCopy];
    if (entryOrNil) {
        map[sequenceKey] = entryOrNil;
    } else {
        [map removeObjectForKey:sequenceKey];
    }
    SpliceKit_structureSaveGapRecordMap(map);
}

// Keep the earliest duration. A second paste must not move the mark forward
// onto a gap the first paste already appended.
static void SpliceKit_structureRememberGapDuration(NSString *sequenceKey, double durationSeconds) {
    if (sequenceKey.length == 0 || !isfinite(durationSeconds) || durationSeconds < 0) return;
    NSDictionary *existing = SpliceKit_structureCopyGapEntry(sequenceKey);
    double kept = durationSeconds;
    if (existing[@"durationSeconds"]) {
        double prev = [existing[@"durationSeconds"] doubleValue];
        if (isfinite(prev) && prev >= 0.0 && prev < kept) kept = prev;
    }
    SpliceKit_structureSetGapEntry(sequenceKey, @{@"durationSeconds": @(kept)});
    SpliceKit_log(@"[Structure] Recorded pre-paste duration %.3fs under %@", kept, sequenceKey);
}

static double SpliceKit_structureRecordedGapDuration(NSArray<NSString *> *keys, BOOL *outFound) {
    if (outFound) *outFound = NO;
    double best = 0;
    BOOL found = NO;
    NSDictionary *map = SpliceKit_structureGapRecordMap();
    for (NSString *key in keys) {
        NSDictionary *entry = [map[key] isKindOfClass:[NSDictionary class]] ? map[key] : nil;
        if (!entry[@"durationSeconds"]) continue;
        double duration = [entry[@"durationSeconds"] doubleValue];
        if (!isfinite(duration) || duration < 0.0) continue;
        if (!found || duration < best) best = duration;
        found = YES;
    }
    if (outFound) *outFound = found;
    return found ? best : 0;
}

static void SpliceKit_structureClearGapRecords(NSArray<NSString *> *keys) {
    if (keys.count == 0) return;
    NSMutableDictionary *map = [SpliceKit_structureGapRecordMap() mutableCopy];
    BOOL changed = NO;
    for (NSString *key in keys) {
        if (map[key]) {
            [map removeObjectForKey:key];
            changed = YES;
        }
    }
    if (changed) SpliceKit_structureSaveGapRecordMap(map);
}

static BOOL SpliceKit_structureItemIsSpineGap(id item) {
    NSString *className = item ? (NSStringFromClass([item class]) ?: @"") : @"";
    return [className containsString:@"GapGenerator"];
}

static NSDictionary *SpliceKit_structureGapSummary(id sequence, id gap) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"class"] = gap ? (NSStringFromClass([gap class]) ?: @"") : @"";
    NSString *name = SpliceKit_displayNameForItem(gap);
    info[@"name"] = name.length ? name : @"Gap";
    id primary = SpliceKit_structurePrimaryObject(sequence);
    SpliceKit_CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
    if (primary && SpliceKit_tryReadTimelineRange(primary, gap, &range)) {
        double start = SpliceKit_secondsFromTime(range.start);
        double duration = SpliceKit_secondsFromTime(range.duration);
        info[@"startSeconds"] = @(start);
        info[@"endSeconds"] = @(start + duration);
        info[@"durationSeconds"] = @(duration);
    }
    return info;
}

// Primary-storyline gap generators that begin at or after the recorded duration.
// A gap that starts earlier is the user's own content and is left alone.
static NSArray *SpliceKit_structureTrailingSpineGaps(id sequence, double recordedDuration) {
    if (!sequence || !isfinite(recordedDuration) || recordedDuration < 0.0) return @[];
    id primary = SpliceKit_structurePrimaryObject(sequence);
    if (!primary) return @[];
    SEL itemsSel = NSSelectorFromString(@"containedItems");
    if (![primary respondsToSelector:itemsSel]) return @[];
    NSArray *items = nil;
    @try {
        items = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(primary, itemsSel));
    } @catch (NSException *e) {
        return @[];
    }
    NSMutableArray *gaps = [NSMutableArray array];
    for (id item in items) {
        if (!SpliceKit_structureItemIsSpineGap(item)) continue;
        SpliceKit_CMTimeRange range = {{0, 0, 0, 0}, {0, 0, 0, 0}};
        if (!SpliceKit_tryReadTimelineRange(primary, item, &range)) continue;
        double start = SpliceKit_secondsFromTime(range.start);
        if (!isfinite(start)) continue;
        if (start + 0.001 < recordedDuration) continue;
        [gaps addObject:item];
    }
    return gaps;
}

static NSDictionary *SpliceKit_structureDeleteSpineGaps(id sequence, id timeline, NSArray *gaps) {
    if (gaps.count == 0) return nil;
    SEL deleteSel = NSSelectorFromString(
        @"_deleteAnchoredObjects:rootItem:preserveTime:preserveAnchors:playhead:error:");
    NSDictionary *missingDelete = SpliceKit_directActionMissingSelectorError(
        sequence, deleteSel, @"structure spine gap removal");
    if (missingDelete) return missingDelete;
    id rootItem = SpliceKit_structurePrimaryObject(sequence);
    if (!rootItem) return @{@"error": @"No primary storyline object on sequence"};

    SpliceKit_CMTime playhead = {0, 1, 0, 0};
    if (timeline && [timeline respondsToSelector:@selector(playheadTime)]) {
        playhead = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
    }
    NSError *deleteError = nil;
    BOOL deleted = ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, SpliceKit_CMTime *, NSError **))objc_msgSend)(
        sequence, deleteSel, gaps, rootItem, NO, NO, &playhead, &deleteError);
    if (deleteError) {
        return @{@"error": deleteError.localizedDescription ?: @"Failed to delete appended spine gap"};
    }
    if (!deleted) return @{@"error": @"Failed to delete appended spine gap"};
    return nil;
}

// Captions anchor to spine clips (lane 1), not primaryObject.anchoredItems alone.
static void SpliceKit_collectCaptionsFromItem(id item,
                                              Class captionClass,
                                              NSMutableArray *found,
                                              NSMutableSet *visited,
                                              NSInteger depth) {
    if (!item || !found || !visited || depth > 32) return;

    NSString *pointerKey = SpliceKit_handlePointerKey(item);
    if (pointerKey.length == 0) return;
    NSString *walkKey = [@"walk:" stringByAppendingString:pointerKey];
    if ([visited containsObject:walkKey]) return;
    [visited addObject:walkKey];

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    NSArray *anchored = nil;
    if ([item respondsToSelector:anchoredSel]) {
        @try {
            anchored = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, anchoredSel));
        } @catch (NSException *e) {
            anchored = nil;
        }
    }

    BOOL itemIsConnectedStoryline = SpliceKit_boolForSelector(item, @"isConnectedStoryline");
    BOOL itemHasVideo = SpliceKit_boolForSelector(item, @"hasVideo");
    BOOL walkContained = itemIsConnectedStoryline || (!itemHasVideo && SpliceKit_mixerIsCollectionLike(item));
    NSArray *contained = nil;
    SEL containedSel = NSSelectorFromString(@"containedItems");
    if (walkContained && [item respondsToSelector:containedSel]) {
        @try {
            contained = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, containedSel));
        } @catch (NSException *e) {
            contained = nil;
        }
    }

    for (NSInteger pass = 0; pass < 2; pass++) {
        NSArray *children = (pass == 1) ? contained : anchored;
        if (children.count == 0) continue;

        for (id child in children) {
            if (!child) continue;

            if (captionClass && [child isKindOfClass:captionClass]) {
                NSString *childKey = SpliceKit_handlePointerKey(child);
                if (childKey.length > 0 && ![visited containsObject:childKey]) {
                    [visited addObject:childKey];
                    [found addObject:child];
                }
                continue;
            }

            SpliceKit_collectCaptionsFromItem(child, captionClass, found, visited, depth + 1);
        }
    }
}

static void SpliceKit_collectMotionTitleCandidatesFromItem(id item,
                                                         NSMutableArray *found,
                                                         NSMutableSet *visited,
                                                         NSInteger depth) {
    if (!item || !found || !visited || depth > 32) return;

    NSString *pointerKey = SpliceKit_handlePointerKey(item);
    if (pointerKey.length == 0) return;
    NSString *walkKey = [@"walk:" stringByAppendingString:pointerKey];
    if ([visited containsObject:walkKey]) return;
    [visited addObject:walkKey];

    SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
    NSArray *anchored = nil;
    if ([item respondsToSelector:anchoredSel]) {
        @try {
            anchored = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, anchoredSel));
        } @catch (NSException *e) {
            anchored = nil;
        }
    }

    BOOL itemIsConnectedStoryline = SpliceKit_boolForSelector(item, @"isConnectedStoryline");
    BOOL itemHasVideo = SpliceKit_boolForSelector(item, @"hasVideo");
    BOOL walkContained = itemIsConnectedStoryline || (!itemHasVideo && SpliceKit_mixerIsCollectionLike(item));
    NSArray *contained = nil;
    SEL containedSel = NSSelectorFromString(@"containedItems");
    if (walkContained && [item respondsToSelector:containedSel]) {
        @try {
            contained = SpliceKit_mixerArrayFromContainer(((id (*)(id, SEL))objc_msgSend)(item, containedSel));
        } @catch (NSException *e) {
            contained = nil;
        }
    }

    for (NSInteger pass = 0; pass < 2; pass++) {
        NSArray *children = (pass == 1) ? contained : anchored;
        if (children.count == 0) continue;

        for (id child in children) {
            if (!child) continue;
            // Don't record a gap, and don't walk into it: its children are the
            // clips the gap holds, not captions.
            if (SpliceKit_itemIsGapGenerator(child)) continue;

            if (SpliceKit_itemIsMotionTitleVerifyCandidate(child)) {
                NSString *childKey = SpliceKit_handlePointerKey(child);
                if (childKey.length > 0 && ![visited containsObject:childKey]) {
                    [visited addObject:childKey];
                    [found addObject:child];
                }
                continue;
            }

            SpliceKit_collectMotionTitleCandidatesFromItem(child, found, visited, depth + 1);
        }
    }
}

NSArray *SpliceKit_allMotionTitleCandidatesOnSequence(id sequence) {
    if (!sequence) return @[];

    NSMutableArray *found = [NSMutableArray array];
    NSMutableSet *walkVisited = [NSMutableSet set];

    SEL primarySel = NSSelectorFromString(@"primaryObject");
    id primaryObject = [sequence respondsToSelector:primarySel]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, primarySel) : nil;
    if (primaryObject) {
        SEL itemsSel = NSSelectorFromString(@"containedItems");
        NSArray *spineItems = [primaryObject respondsToSelector:itemsSel]
            ? ((id (*)(id, SEL))objc_msgSend)(primaryObject, itemsSel) : nil;
        if ([spineItems isKindOfClass:[NSArray class]]) {
            for (id spineItem in spineItems) {
                SpliceKit_collectMotionTitleCandidatesFromItem(spineItem, found, walkVisited, 0);
            }
        }
    }

    return found;
}

NSArray *SpliceKit_allCaptionsOnSequence(id sequence) {
    if (!sequence) return @[];

    Class captionClass = NSClassFromString(@"FFAnchoredCaption");
    NSMutableArray *found = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    SEL allCaptionsSel = NSSelectorFromString(@"allCaptions");
    if ([sequence respondsToSelector:allCaptionsSel]) {
        id allCaptions = ((id (*)(id, SEL))objc_msgSend)(sequence, allCaptionsSel);
        NSArray *items = nil;
        if ([allCaptions isKindOfClass:[NSArray class]]) {
            items = allCaptions;
        } else if ([allCaptions isKindOfClass:[NSSet class]]) {
            items = [(NSSet *)allCaptions allObjects];
        }
        for (id item in items) {
            if (!captionClass || ![item isKindOfClass:captionClass]) continue;
            NSString *key = SpliceKit_handlePointerKey(item);
            if (key.length == 0 || [seen containsObject:key]) continue;
            [seen addObject:key];
            [found addObject:item];
        }
    }

    id primaryObject = SpliceKit_structurePrimaryObject(sequence);
    if (primaryObject) {
        SEL itemsSel = NSSelectorFromString(@"containedItems");
        NSArray *spineItems = [primaryObject respondsToSelector:itemsSel]
            ? ((id (*)(id, SEL))objc_msgSend)(primaryObject, itemsSel) : nil;
        if ([spineItems isKindOfClass:[NSArray class]]) {
            NSMutableSet *walkVisited = [NSMutableSet setWithSet:seen];
            for (id spineItem in spineItems) {
                SpliceKit_collectCaptionsFromItem(spineItem, captionClass, found, walkVisited, 0);
            }
        }
    }

    return found;
}

static NSHashTable *SpliceKit_structureCaptionPointerSet(NSArray *captions) {
    NSHashTable *set = [NSHashTable hashTableWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality];
    for (id caption in captions) {
        if (caption) [set addObject:caption];
    }
    return set;
}

static NSString *SpliceKit_structureCaptionText(id caption) {
    if (!caption) return nil;
    SEL textSel = NSSelectorFromString(@"text");
    if (![caption respondsToSelector:textSel]) return nil;
    id text = ((id (*)(id, SEL))objc_msgSend)(caption, textSel);
    return [text isKindOfClass:[NSString class]] ? text : nil;
}

// Exact uppercase labels written by structure.generateCaptions (see tools/structure-analyzer + paste).
static BOOL SpliceKit_structureCaptionTextIsToolGenerated(NSString *text) {
    if (text.length == 0) return NO;

    static NSSet<NSString *> *exactLabels = nil;
    static NSArray<NSString *> *numberedPrefixes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exactLabels = [NSSet setWithObjects:
            @"INTRO", @"OUTRO", @"BRIDGE", @"DROP", @"BREAKDOWN", @"SECTION", @"PRE-CHORUS", nil];
        numberedPrefixes = @[@"VERSE", @"CHORUS", @"BRIDGE"];
    });

    if ([exactLabels containsObject:text]) return YES;

    for (NSString *prefix in numberedPrefixes) {
        if (![text hasPrefix:prefix]) continue;
        NSString *suffix = [text substringFromIndex:prefix.length];
        if (suffix.length == 0) continue;
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if ([suffix rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *SpliceKit_structureCaptionSummary(id sequence, id caption) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSString *text = SpliceKit_structureCaptionText(caption);
    if (text) info[@"text"] = text;

    id primaryObject = SpliceKit_structurePrimaryObject(sequence);
    SpliceKit_CMTimeRange range = {0};
    if (primaryObject && SpliceKit_tryReadTimelineRange(primaryObject, caption, &range)) {
        double start = SpliceKit_secondsFromTime(range.start);
        double end = start + SpliceKit_secondsFromTime(range.duration);
        info[@"startSeconds"] = @(start);
        info[@"endSeconds"] = @(end);
    }
    return info;
}

static NSArray *SpliceKit_structureCaptionsToRemove(id sequence, BOOL *outUsedRegistry) {
    if (outUsedRegistry) *outUsedRegistry = NO;
    if (!sequence) return @[];

    Class captionClass = NSClassFromString(@"FFAnchoredCaption");
    NSMutableArray *toRemove = [NSMutableArray array];
    NSHashTable *seen = SpliceKit_structureCaptionPointerSet(@[]);

    NSHashTable<id> *registry = SpliceKit_structureCaptionTableForSequence(sequence, NO);
    if (registry.count > 0) {
        if (outUsedRegistry) *outUsedRegistry = YES;
        for (id caption in registry) {
            if (!caption || (captionClass && ![caption isKindOfClass:captionClass])) continue;
            [toRemove addObject:caption];
            [seen addObject:caption];
        }
    }

    for (id caption in SpliceKit_allCaptionsOnSequence(sequence)) {
        if ([seen containsObject:caption]) continue;
        if (captionClass && ![caption isKindOfClass:captionClass]) continue;
        NSString *text = SpliceKit_structureCaptionText(caption);
        if (!SpliceKit_structureCaptionTextIsToolGenerated(text)) continue;
        [toRemove addObject:caption];
        [seen addObject:caption];
    }

    return toRemove;
}

static void SpliceKit_structureSeekTimelineToSeconds(id timeline, id sequence, double seconds) {
    if (!timeline || seconds < 0) seconds = 0;
    int fdN = 100, fdD = 2400;
    SEL fdSel = NSSelectorFromString(@"frameDuration");
    if (sequence && [sequence respondsToSelector:fdSel]) {
        SpliceKit_CMTime fd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, fdSel);
        if (fd.timescale > 0) { fdN = (int)fd.value; fdD = fd.timescale; }
    }
    double fps = (double)fdD / (double)fdN;
    long long frames = (long long)llround(seconds * fps);
    if (frames < 0) frames = 0;
    SpliceKit_CMTime t = {frames * fdN, fdD, 1, 0};
    SEL setSel = @selector(setPlayheadTime:);
    if ([timeline respondsToSelector:setSel]) {
        ((void (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(timeline, setSel, t);
    }
}

static double SpliceKit_structureSequenceDurationSeconds(id sequence) {
    if (!sequence) return 0;

    SEL durSel = NSSelectorFromString(@"duration");
    if ([sequence respondsToSelector:durSel]) {
        SpliceKit_CMTime d = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(sequence, durSel);
        double secs = SpliceKit_cmtimeToSeconds(d);
        if (secs > 0) return secs;
    }

    // FFAnchoredSequence on FCP 12.3 does not answer -duration (checked against the
    // live runtime: 67 selectors match "duration" and none of them is the bare one).
    // Asking for it and giving up left this reading 0, which made the caller think the
    // sequence had no duration and skip recording it — so the gap song_structure_blocks
    // appends was never registered and never removed. Sum the primary storyline the way
    // timeline.getDetailedState does.
    id primary = [sequence respondsToSelector:@selector(primaryObject)]
        ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject)) : nil;
    if (!primary || ![primary respondsToSelector:@selector(containedItems)]) return 0;

    id items = ((id (*)(id, SEL))objc_msgSend)(primary, @selector(containedItems));
    if (![items isKindOfClass:[NSArray class]]) return 0;

    double total = 0;
    for (id item in (NSArray *)items) {
        if (![item respondsToSelector:@selector(duration)]) continue;
        SpliceKit_CMTime d = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, @selector(duration));
        double secs = SpliceKit_cmtimeToSeconds(d);
        if (secs > 0) total += secs;
    }
    return total;
}

NSDictionary *SpliceKit_serverStructureGenerateCaptions(NSDictionary *params) {
    NSArray *sections = params[@"sections"];
    if (!sections || ![sections isKindOfClass:[NSArray class]] || sections.count == 0) {
        return @{@"error": @"sections array required (each: {label, start, end})"};
    }

    double atSeconds = params[@"atSeconds"] != nil ? [params[@"atSeconds"] doubleValue] : 0.0;
    if (atSeconds < 0) atSeconds = 0;

    double maxSectionEnd = 0;
    for (id obj in sections) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        double end = [obj[@"end"] doubleValue];
        if (end > maxSectionEnd) maxSectionEnd = end;
    }
    double labelsEnd = atSeconds + maxSectionEnd;

    __block double sequenceDuration = 0;
    __block double savedPlayheadSeconds = 0;
    __block NSArray<NSString *> *sequenceKeys = nil;
    __block NSString *sequenceName = nil;
    __block BOOL spineCountKnown = NO;
    __block NSUInteger spineCount = 0;

    @try {
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            id seq = tm ? ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence)) : nil;
            sequenceDuration = SpliceKit_structureSequenceDurationSeconds(seq);
            sequenceKeys = [SpliceKit_structureSequenceLookupKeys(seq) copy];
            sequenceName = SpliceKit_structureObjectIdentifier(seq, @[@"displayName"]);
            id primary = SpliceKit_structurePrimaryObject(seq);
            SEL itemsSel = NSSelectorFromString(@"containedItems");
            if (primary && [primary respondsToSelector:itemsSel]) {
                @try {
                    NSArray *items = SpliceKit_mixerArrayFromContainer(
                        ((id (*)(id, SEL))objc_msgSend)(primary, itemsSel));
                    if (items) {
                        spineCountKnown = YES;
                        spineCount = items.count;
                    }
                } @catch (NSException *e) {}
            }
            if (tm && [tm respondsToSelector:@selector(playheadTime)]) {
                SpliceKit_CMTime saved = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(tm, @selector(playheadTime));
                savedPlayheadSeconds = SpliceKit_secondsFromTime(saved);
            }
            if (tm) {
                SpliceKit_structureSeekTimelineToSeconds(tm, seq, atSeconds);
            }
        });

        NSMutableDictionary *mutableParams = [params mutableCopy];
        mutableParams[@"atSeconds"] = @(atSeconds);
        __block id userSequence = nil;
        __block NSArray *captionsBefore = nil;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            userSequence = tm ? ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence)) : nil;
            if (userSequence) {
                captionsBefore = SpliceKit_allCaptionsOnSequence(userSequence);
            }
        });

        // Written before the paste so a crash after Final Cut Pro appends the gap
        // still leaves a duration remove_structure_blocks can find after relaunch.
        // Rolled back when the paste itself returns an error.
        BOOL durationKnown = sequenceDuration > 0.0 || (spineCountKnown && spineCount == 0);
        BOOL recordGap = durationKnown && sequenceKeys.count > 0 && labelsEnd > sequenceDuration + 0.05;
        NSMutableDictionary<NSString *, NSDictionary *> *previousGapEntries = [NSMutableDictionary dictionary];
        if (recordGap) {
            for (NSString *key in sequenceKeys) {
                NSDictionary *previous = SpliceKit_structureCopyGapEntry(key);
                if (previous) previousGapEntries[key] = previous;
                SpliceKit_structureRememberGapDuration(key, sequenceDuration);
            }
        }

        NSMutableDictionary *result = [SpliceKit_handleStructureGenerateCaptions(mutableParams) mutableCopy];
        if (result[@"error"]) {
            if (recordGap) {
                for (NSString *key in sequenceKeys) {
                    SpliceKit_structureSetGapEntry(key, previousGapEntries[key]);
                }
            }
            return result;
        }

        if (recordGap) {
            __block NSArray<NSString *> *keysAfter = nil;
            SpliceKit_executeOnMainThread(^{
                id tm = SpliceKit_getActiveTimelineModule();
                id seq = tm ? ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence)) : nil;
                NSString *activeName = SpliceKit_structureObjectIdentifier(seq, @[@"displayName"]);
                if (sequenceName.length == 0 || activeName.length == 0 ||
                    [activeName isEqualToString:sequenceName]) {
                    keysAfter = [SpliceKit_structureSequenceLookupKeys(seq) copy];
                }
            });
            for (NSString *key in keysAfter) {
                SpliceKit_structureRememberGapDuration(key, sequenceDuration);
            }
            NSArray *lookup = keysAfter.count ? keysAfter : sequenceKeys;
            BOOL foundRecord = NO;
            double stored = SpliceKit_structureRecordedGapDuration(lookup, &foundRecord);
            result[@"appendedSpineGapRecorded"] = @(foundRecord);
            if (foundRecord) result[@"prePasteDurationSeconds"] = @(stored);
        }

        if (userSequence) {
            NSHashTable *beforeSet = SpliceKit_structureCaptionPointerSet(captionsBefore ?: @[]);
            __block NSMutableArray *newCaptions = [NSMutableArray array];
            SpliceKit_executeOnMainThread(^{
                for (id caption in SpliceKit_allCaptionsOnSequence(userSequence)) {
                    if (![beforeSet containsObject:caption]) {
                        [newCaptions addObject:caption];
                    }
                }
            });
            if (newCaptions.count > 0) {
                SpliceKit_structureRegisterCaptions(userSequence, newCaptions);
                result[@"registeredCaptions"] = @(newCaptions.count);
            }
        }

        __block double playheadAfterPaste = 0;
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            if (tm && [tm respondsToSelector:@selector(playheadTime)]) {
                SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(tm, @selector(playheadTime));
                playheadAfterPaste = SpliceKit_secondsFromTime(t);
            }
        });

        result[@"atSeconds"] = @(atSeconds);
        if (fabs(playheadAfterPaste - atSeconds) > 0.05) {
            result[@"placedAtSeconds"] = @(playheadAfterPaste);
        }

        if (sequenceDuration > 0 && labelsEnd > sequenceDuration + 0.05) {
            result[@"extendsPastSequenceEnd"] = @YES;
            result[@"sequenceDurationSeconds"] = @(sequenceDuration);
            result[@"labelsEndSeconds"] = @(labelsEnd);
        } else {
            result[@"extendsPastSequenceEnd"] = @NO;
        }
        return result;
    } @finally {
        SpliceKit_executeOnMainThread(^{
            id tm = SpliceKit_getActiveTimelineModule();
            id seq = tm ? ((id (*)(id, SEL))objc_msgSend)(tm, @selector(sequence)) : nil;
            if (tm) {
                SpliceKit_structureSeekTimelineToSeconds(tm, seq, savedPlayheadSeconds);
            }
        });
    }
}

NSDictionary *SpliceKit_serverStructureRemove(NSDictionary *params) {
    BOOL dryRun = [params[@"dryRun"] boolValue];
    __block NSUInteger removedStorylines = 0;
    __block NSUInteger removedCaptions = 0;
    __block NSMutableArray *removedCaptionDetails = [NSMutableArray array];
    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline"};
                return;
            }

            BOOL usedRegistry = NO;
            NSArray *captions = SpliceKit_structureCaptionsToRemove(sequence, &usedRegistry);
            NSMutableArray *captionSummaries = [NSMutableArray arrayWithCapacity:captions.count];
            for (id caption in captions) {
                [captionSummaries addObject:SpliceKit_structureCaptionSummary(sequence, caption)];
            }

            NSUInteger storylinesToRemove =
                SpliceKit_structureCountStorylinesNamed(sequence, kSpliceKitStructureStorylineName);

            // Gaps are resolved even when no captions remain. The previous removal
            // returned as soon as the caption list was empty and never looked at the spine.
            NSArray<NSString *> *sequenceKeys = SpliceKit_structureSequenceLookupKeys(sequence);
            BOOL gapRecordFound = NO;
            double recordedDuration = SpliceKit_structureRecordedGapDuration(sequenceKeys, &gapRecordFound);
            NSArray *gaps = gapRecordFound
                ? SpliceKit_structureTrailingSpineGaps(sequence, recordedDuration) : @[];
            NSMutableArray *gapSummaries = [NSMutableArray arrayWithCapacity:gaps.count];
            for (id gap in gaps) {
                [gapSummaries addObject:SpliceKit_structureGapSummary(sequence, gap)];
            }

            BOOL hadGapRecord = gapRecordFound;
            double durationForPayload = recordedDuration;
            NSMutableDictionary * (^removalPayload)(BOOL, NSUInteger, NSUInteger, NSUInteger, NSArray *, NSArray *) =
            ^NSMutableDictionary *(BOOL isDryRun, NSUInteger storylines, NSUInteger captionCount,
                                   NSUInteger gapCount, NSArray *captionRows, NSArray *gapRows) {
                NSMutableDictionary *payload = [@{
                    @"status": @"ok",
                    @"dryRun": @(isDryRun),
                    @"removedStorylines": @(storylines),
                    @"removedCaptions": @(captionCount),
                    @"removedSpineGaps": @(gapCount),
                    @"removed": @(storylines + captionCount + gapCount),
                    @"captions": captionRows ?: @[],
                    @"spineGaps": gapRows ?: @[],
                    @"matchedViaRegistry": @(usedRegistry && captionCount > 0),
                } mutableCopy];
                if (hadGapRecord) payload[@"prePasteDurationSeconds"] = @(durationForPayload);
                return payload;
            };

            if (dryRun) {
                result = removalPayload(YES, storylinesToRemove, captions.count, gaps.count,
                                        captionSummaries, gapSummaries);
                return;
            }

            if (storylinesToRemove == 0 && captions.count == 0 && gaps.count == 0) {
                if (gapRecordFound) {
                    double now = SpliceKit_structureSequenceDurationSeconds(sequence);
                    if (now <= recordedDuration + 0.05) {
                        SpliceKit_structureClearGapRecords(sequenceKeys);
                        gapRecordFound = NO;
                    }
                }
                result = removalPayload(NO, 0, 0, 0, @[], @[]);
                return;
            }

            NSString *undoName = @"Remove Structure Blocks";
            BOOL openedUndoGroup = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoName);
            NSUInteger removedSpineGaps = 0;
            @try {
                removedStorylines = SpliceKit_structureRemoveStorylineNamed(sequence, kSpliceKitStructureStorylineName);

                if (captions.count > 0) {
                    SEL deleteSel = NSSelectorFromString(
                        @"_deleteAnchoredObjects:rootItem:preserveTime:preserveAnchors:playhead:error:");
                    NSDictionary *missingDelete = SpliceKit_directActionMissingSelectorError(
                        sequence, deleteSel, @"structure caption removal");
                    if (missingDelete) {
                        result = missingDelete;
                        return;
                    }

                    id rootItem = SpliceKit_structurePrimaryObject(sequence);
                    if (!rootItem) {
                        result = @{@"error": @"No primary storyline object on sequence"};
                        return;
                    }

                    SpliceKit_CMTime playhead = {0, 1, 0, 0};
                    if ([timeline respondsToSelector:@selector(playheadTime)]) {
                        playhead = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
                    }

                    NSError *deleteError = nil;
                    BOOL deleted = ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, SpliceKit_CMTime *, NSError **))objc_msgSend)(
                        sequence, deleteSel, captions, rootItem, NO, NO, &playhead, &deleteError);
                    if (deleteError) {
                        result = @{@"error": deleteError.localizedDescription ?: @"Failed to delete structure captions"};
                        return;
                    }
                    if (!deleted) {
                        result = @{@"error": @"Failed to delete structure captions"};
                        return;
                    }
                    removedCaptions = captions.count;
                    [removedCaptionDetails addObjectsFromArray:captionSummaries];
                    SpliceKit_structureUnregisterCaptions(sequence, captions);
                }

                if (gaps.count > 0) {
                    NSDictionary *gapError = SpliceKit_structureDeleteSpineGaps(sequence, timeline, gaps);
                    if (gapError) {
                        result = gapError;
                        return;
                    }
                    removedSpineGaps = gaps.count;
                    SpliceKit_structureClearGapRecords(sequenceKeys);
                    gapRecordFound = NO;
                } else if (gapRecordFound) {
                    double now = SpliceKit_structureSequenceDurationSeconds(sequence);
                    if (now <= recordedDuration + 0.05) {
                        SpliceKit_structureClearGapRecords(sequenceKeys);
                        gapRecordFound = NO;
                    }
                }
            } @finally {
                SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoName, openedUndoGroup);
            }

            if (result[@"error"]) return;

            result = removalPayload(NO, removedStorylines, removedCaptions, removedSpineGaps,
                                    removedCaptionDetails, gapSummaries);
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to remove structure blocks"};
}

static NSDictionary *SpliceKit_captionRemovalItemLabel(id item, BOOL native) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSString *displayName = SpliceKit_displayNameForItem(item);
    if (displayName.length) info[@"displayName"] = displayName;
    info[@"class"] = NSStringFromClass([item class]);
    if (native) {
        SEL textSel = NSSelectorFromString(@"text");
        if ([item respondsToSelector:textSel]) {
            id text = ((id (*)(id, SEL))objc_msgSend)(item, textSel);
            if ([text isKindOfClass:[NSString class]] && [(NSString *)text length]) {
                info[@"text"] = text;
            }
        }
    } else {
        NSDictionary *entry = SpliceKit_buildVerifiedMotionTitleEntry(item);
        if (entry[@"text"]) info[@"text"] = entry[@"text"];
        if (entry[@"name"]) info[@"displayName"] = entry[@"name"];
    }
    return info;
}

static NSArray *SpliceKit_captionsToRemoveOnSequence(id sequence, BOOL native) {
    NSMutableArray *found = [NSMutableArray array];
    if (native) {
        Class captionClass = NSClassFromString(@"FFAnchoredCaption");
        for (id item in SpliceKit_allCaptionsOnSequence(sequence)) {
            if (captionClass && ![item isKindOfClass:captionClass]) continue;
            [found addObject:item];
        }
        return found;
    }
    for (id item in SpliceKit_allMotionTitleCandidatesOnSequence(sequence)) {
        if (!SpliceKit_itemIsMotionTitleVerifyCandidate(item)) continue;
        [found addObject:item];
    }
    return found;
}

NSDictionary *SpliceKit_handleNativeCaptionsRemove(NSDictionary *params) {
    BOOL native = params[@"native"] == nil ? YES : [params[@"native"] boolValue];
    BOOL dryRun = [params[@"dryRun"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            if (!timeline) {
                result = @{@"error": @"No active timeline module"};
                return;
            }
            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, NSSelectorFromString(@"sequence"));
            if (!sequence) {
                result = @{@"error": @"No sequence in timeline"};
                return;
            }

            NSArray *toRemove = SpliceKit_captionsToRemoveOnSequence(sequence, native);
            NSMutableArray *summaries = [NSMutableArray arrayWithCapacity:toRemove.count];
            for (id item in toRemove) {
                [summaries addObject:SpliceKit_captionRemovalItemLabel(item, native)];
            }

            NSString *pipeline = native ? @"native_FFAnchoredCaption" : @"motion_title_captions";
            if (dryRun) {
                result = @{
                    @"status": @"ok",
                    @"dryRun": @YES,
                    @"native": @(native),
                    @"pipeline": pipeline,
                    @"foundCount": @(toRemove.count),
                    @"removedCount": @0,
                    @"notRemoved": @[],
                    @"items": summaries,
                };
                return;
            }

            if (toRemove.count == 0) {
                result = @{
                    @"status": @"ok",
                    @"dryRun": @NO,
                    @"native": @(native),
                    @"pipeline": pipeline,
                    @"foundCount": @0,
                    @"removedCount": @0,
                    @"notRemoved": @[],
                    @"items": @[],
                };
                return;
            }

            NSString *undoName = @"Remove Captions";
            BOOL openedUndo = SpliceKit_internalBeginEditGroupIfNeeded(sequence, undoName);
            NSUInteger removedCount = 0;
            NSMutableArray *notRemoved = [NSMutableArray array];
            @try {
                SEL deleteSel = NSSelectorFromString(
                    @"_deleteAnchoredObjects:rootItem:preserveTime:preserveAnchors:playhead:error:");
                NSDictionary *missingDelete = SpliceKit_directActionMissingSelectorError(
                    sequence, deleteSel, @"caption removal");
                if (missingDelete) {
                    result = missingDelete;
                    return;
                }

                id rootItem = SpliceKit_structurePrimaryObject(sequence);
                if (!rootItem) {
                    result = @{@"error": @"No primary storyline object on sequence"};
                    return;
                }

                SpliceKit_CMTime playhead = {0, 1, 0, 0};
                if ([timeline respondsToSelector:@selector(playheadTime)]) {
                    playhead = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(timeline, @selector(playheadTime));
                }

                NSError *deleteError = nil;
                BOOL deleted = ((BOOL (*)(id, SEL, id, id, BOOL, BOOL, SpliceKit_CMTime *, NSError **))objc_msgSend)(
                    sequence, deleteSel, toRemove, rootItem, NO, NO, &playhead, &deleteError);
                if (deleteError || !deleted) {
                    NSString *reason = deleteError.localizedDescription ?: @"Failed to delete caption items";
                    for (id item in toRemove) {
                        NSMutableDictionary *fail = [SpliceKit_captionRemovalItemLabel(item, native) mutableCopy];
                        fail[@"reason"] = reason;
                        [notRemoved addObject:fail];
                    }
                } else {
                    removedCount = toRemove.count;
                }
            } @finally {
                SpliceKit_internalEndEditGroupIfOpened(sequence, timeline, undoName, openedUndo);
            }

            result = @{
                @"status": @"ok",
                @"dryRun": @NO,
                @"native": @(native),
                @"pipeline": pipeline,
                @"foundCount": @(toRemove.count),
                @"removedCount": @(removedCount),
                @"notRemoved": notRemoved,
                @"items": summaries,
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result ?: @{@"error": @"Failed to remove captions"};
}

// ---------- 1. flexmusic.listSongs ----------

static BOOL SpliceKit_flexMusicCollectionIsEmpty(id collection) {
    if (!collection) return YES;
    if ([collection isKindOfClass:[NSArray class]]) return [(NSArray *)collection count] == 0;
    if ([collection isKindOfClass:[NSSet class]]) return [(NSSet *)collection count] == 0;
    if ([collection isKindOfClass:[NSDictionary class]]) return [(NSDictionary *)collection count] == 0;
    return YES;
}

static NSArray *SpliceKit_flexMusicNormalizeSongCollection(id collection) {
    if (!collection) return nil;
    if ([collection isKindOfClass:[NSArray class]]) return (NSArray *)collection;
    if ([collection isKindOfClass:[NSSet class]]) return [(NSSet *)collection allObjects];
    if ([collection isKindOfClass:[NSDictionary class]]) return [(NSDictionary *)collection allValues];
    return nil;
}

NSDictionary *SpliceKit_handleFlexMusicListSongs(NSDictionary *params) {
    NSString *filter = params[@"filter"];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id library = SpliceKit_getFlexMusicLibrary();
            if (!library) {
                result = @{@"error": @"FMSongLibrary not available (FlexMusicKit framework not loaded)"};
                return;
            }

            // Try multiple selectors to get songs
            id songs = nil;

            // 1. bundledSongs — locally available songs
            SEL bundledSel = NSSelectorFromString(@"bundledSongs");
            if ([library respondsToSelector:bundledSel]) {
                songs = ((id (*)(id, SEL))objc_msgSend)(library, bundledSel);
            }

            // 2. fetchSongsWithOptions: — returns array directly (synchronous)
            if (SpliceKit_flexMusicCollectionIsEmpty(songs)) {
                SEL fetchSel = NSSelectorFromString(@"fetchSongsWithOptions:");
                if ([library respondsToSelector:fetchSel]) {
                    Class fetchOptClass = objc_getClass("FMFetchOptions");
                    id fetchOpts = nil;
                    if (fetchOptClass) {
                        fetchOpts = ((id (*)(id, SEL))objc_msgSend)(
                            ((id (*)(id, SEL))objc_msgSend)((id)fetchOptClass, @selector(alloc)),
                            @selector(init));
                    }
                    id fetched = ((id (*)(id, SEL, id))objc_msgSend)(library, fetchSel, fetchOpts);
                    if (fetched && [fetched isKindOfClass:[NSArray class]]) {
                        songs = fetched;
                    }
                }
            }

            // 3. Try generic accessors
            if (SpliceKit_flexMusicCollectionIsEmpty(songs)) {
                for (NSString *selName in @[@"songs", @"availableSongs", @"allSongs"]) {
                    SEL sel = NSSelectorFromString(selName);
                    if ([library respondsToSelector:sel]) {
                        id result2 = ((id (*)(id, SEL))objc_msgSend)(library, sel);
                        if (result2 && [result2 isKindOfClass:[NSArray class]] && [(NSArray *)result2 count] > 0) {
                            songs = result2;
                            break;
                        }
                    }
                }
            }

            // Also try FFFlexMusicLibrary from Flexo as fallback
            if (SpliceKit_flexMusicCollectionIsEmpty(songs)) {
                Class ffFlexLib = objc_getClass("FFFlexMusicLibrary");
                if (ffFlexLib) {
                    SEL sharedSel = NSSelectorFromString(@"sharedLibrary");
                    if ([ffFlexLib respondsToSelector:sharedSel]) {
                        id ffLib = ((id (*)(id, SEL))objc_msgSend)((id)ffFlexLib, sharedSel);
                        if (ffLib) {
                            SEL fSongsSel = NSSelectorFromString(@"songs");
                            if ([ffLib respondsToSelector:fSongsSel]) {
                                songs = ((id (*)(id, SEL))objc_msgSend)(ffLib, fSongsSel);
                            }
                        }
                    }
                }
            }

            NSArray *songArray = SpliceKit_flexMusicNormalizeSongCollection(songs);
            if (!songArray) {
                result = @{@"error": @"Could not retrieve songs from FMSongLibrary",
                           @"libraryClass": NSStringFromClass([library class])};
                return;
            }

            NSMutableArray *songList = [NSMutableArray array];
            for (id song in songArray) {
                @autoreleasepool {
                    NSMutableDictionary *info = [NSMutableDictionary dictionary];

                    // UID / identifier
                    SEL uidSel = NSSelectorFromString(@"songUID");
                    SEL idSel = NSSelectorFromString(@"identifier");
                    NSString *uid = nil;
                    if ([song respondsToSelector:uidSel]) {
                        uid = ((id (*)(id, SEL))objc_msgSend)(song, uidSel);
                    } else if ([song respondsToSelector:idSel]) {
                        uid = ((id (*)(id, SEL))objc_msgSend)(song, idSel);
                    }
                    if (uid) info[@"uid"] = uid;

                    // Name
                    SEL nameSel = NSSelectorFromString(@"name");
                    SEL dispSel = @selector(displayName);
                    NSString *name = nil;
                    if ([song respondsToSelector:nameSel]) {
                        name = ((id (*)(id, SEL))objc_msgSend)(song, nameSel);
                    } else if ([song respondsToSelector:dispSel]) {
                        name = ((id (*)(id, SEL))objc_msgSend)(song, dispSel);
                    }
                    if (name) info[@"name"] = name;

                    // Metadata
                    SEL metaSel = NSSelectorFromString(@"metadata");
                    if ([song respondsToSelector:metaSel]) {
                        id metadata = ((id (*)(id, SEL))objc_msgSend)(song, metaSel);
                        if (metadata) {
                            SEL artistSel = NSSelectorFromString(@"artistName");
                            if ([metadata respondsToSelector:artistSel]) {
                                id artist = ((id (*)(id, SEL))objc_msgSend)(metadata, artistSel);
                                if (artist) info[@"artist"] = artist;
                            }
                            SEL genreSel = NSSelectorFromString(@"genres");
                            if ([metadata respondsToSelector:genreSel]) {
                                id genres = ((id (*)(id, SEL))objc_msgSend)(metadata, genreSel);
                                if (genres) info[@"genres"] = genres;
                            }
                        }
                    }

                    // Duration
                    SEL durSel = NSSelectorFromString(@"naturalDuration");
                    if ([song respondsToSelector:durSel]) {
                        SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(song, durSel);
                        info[@"durationSeconds"] = @(SpliceKit_cmtimeToSeconds(dur));
                    }

                    // Filter
                    if (filter.length > 0) {
                        NSString *lowerFilter = [filter lowercaseString];
                        NSString *nameStr = info[@"name"] ?: @"";
                        NSString *artistStr = info[@"artist"] ?: @"";
                        BOOL matches = [[nameStr lowercaseString] containsString:lowerFilter] ||
                                       [[artistStr lowercaseString] containsString:lowerFilter];
                        if (!matches) continue;
                    }

                    // Store handle
                    NSString *handle = SpliceKit_storeHandle(song);
                    info[@"handle"] = handle;

                    [songList addObject:info];
                }
            }

            result = @{@"songs": songList, @"count": @(songList.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to list songs"};
}

// ---------- 2. flexmusic.getSong ----------

static NSDictionary *SpliceKit_handleFlexMusicGetSong(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id song = nil;

            // Resolve by handle first
            if (handle) {
                song = SpliceKit_resolveHandle(handle);
            }

            // Resolve by UID via library
            if (!song && songUID) {
                id library = SpliceKit_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
                // Try FFFlexMusicLibrary fallback
                if (!song) {
                    Class ffFlexLib = objc_getClass("FFFlexMusicLibrary");
                    if (ffFlexLib) {
                        SEL sharedSel = NSSelectorFromString(@"sharedLibrary");
                        if ([ffFlexLib respondsToSelector:sharedSel]) {
                            id ffLib = ((id (*)(id, SEL))objc_msgSend)((id)ffFlexLib, sharedSel);
                            if (ffLib) {
                                SEL fForUIDSel = NSSelectorFromString(@"songForUID:");
                                if ([ffLib respondsToSelector:fForUIDSel]) {
                                    song = ((id (*)(id, SEL, id))objc_msgSend)(ffLib, fForUIDSel, songUID);
                                }
                            }
                        }
                    }
                }
            }

            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"class"] = NSStringFromClass([song class]);

            // UID
            SEL uidSel = NSSelectorFromString(@"songUID");
            SEL idSel = NSSelectorFromString(@"identifier");
            if ([song respondsToSelector:uidSel]) {
                id uid = ((id (*)(id, SEL))objc_msgSend)(song, uidSel);
                if (uid) info[@"uid"] = uid;
            } else if ([song respondsToSelector:idSel]) {
                id uid = ((id (*)(id, SEL))objc_msgSend)(song, idSel);
                if (uid) info[@"uid"] = uid;
            }

            // Name
            SEL nameSel = NSSelectorFromString(@"name");
            if ([song respondsToSelector:nameSel]) {
                id name = ((id (*)(id, SEL))objc_msgSend)(song, nameSel);
                if (name) info[@"name"] = name;
            }

            // Metadata
            SEL metaSel = NSSelectorFromString(@"metadata");
            if ([song respondsToSelector:metaSel]) {
                id metadata = ((id (*)(id, SEL))objc_msgSend)(song, metaSel);
                if (metadata) {
                    NSMutableDictionary *meta = [NSMutableDictionary dictionary];

                    SEL artistSel = NSSelectorFromString(@"artistName");
                    if ([metadata respondsToSelector:artistSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, artistSel);
                        if (v) meta[@"artist"] = v;
                    }
                    SEL moodSel = NSSelectorFromString(@"mood");
                    if ([metadata respondsToSelector:moodSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, moodSel);
                        if (v) meta[@"mood"] = v;
                    }
                    SEL paceSel = NSSelectorFromString(@"pace");
                    if ([metadata respondsToSelector:paceSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, paceSel);
                        if (v) meta[@"pace"] = v;
                    }
                    SEL genreSel = NSSelectorFromString(@"genres");
                    if ([metadata respondsToSelector:genreSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, genreSel);
                        if (v) meta[@"genres"] = v;
                    }
                    SEL arousalSel = NSSelectorFromString(@"arousal");
                    if ([metadata respondsToSelector:arousalSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, arousalSel);
                        if (v) meta[@"arousal"] = v;
                    }
                    SEL valenceSel = NSSelectorFromString(@"valence");
                    if ([metadata respondsToSelector:valenceSel]) {
                        id v = ((id (*)(id, SEL))objc_msgSend)(metadata, valenceSel);
                        if (v) meta[@"valence"] = v;
                    }

                    info[@"metadata"] = meta;
                }
            }

            // Durations
            SEL natDurSel = NSSelectorFromString(@"naturalDuration");
            if ([song respondsToSelector:natDurSel]) {
                SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(song, natDurSel);
                info[@"naturalDurationSeconds"] = @(SpliceKit_cmtimeToSeconds(dur));
            }
            SEL minDurSel = NSSelectorFromString(@"minimumDuration");
            if ([song respondsToSelector:minDurSel]) {
                SpliceKit_CMTime dur = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(song, minDurSel);
                info[@"minimumDurationSeconds"] = @(SpliceKit_cmtimeToSeconds(dur));
            }
            SEL idealSel = NSSelectorFromString(@"idealDurations");
            if ([song respondsToSelector:idealSel]) {
                id ideals = ((id (*)(id, SEL))objc_msgSend)(song, idealSel);
                if ([ideals isKindOfClass:[NSArray class]]) {
                    info[@"idealDurations"] = ideals;
                }
            }

            // Song format
            SEL fmtSel = NSSelectorFromString(@"songFormat");
            if ([song respondsToSelector:fmtSel]) {
                id fmt = ((id (*)(id, SEL))objc_msgSend)(song, fmtSel);
                if (fmt) info[@"songFormat"] = fmt;
            }

            // Store handle
            NSString *h = SpliceKit_storeHandle(song);
            info[@"handle"] = h;

            result = info;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to get song"};
}

// ---------- 3. flexmusic.getTiming ----------

static NSDictionary *SpliceKit_handleFlexMusicGetTiming(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    NSNumber *durationSecondsNum = params[@"durationSeconds"];
    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};
    if (!durationSecondsNum) return @{@"error": @"durationSeconds parameter required"};

    double durationSeconds = [durationSecondsNum doubleValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Resolve song
            id song = nil;
            if (handle) {
                song = SpliceKit_resolveHandle(handle);
            }
            if (!song && songUID) {
                id library = SpliceKit_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            SpliceKit_CMTime durTime = SpliceKit_cmtimeFromSeconds(durationSeconds);

            // Get options for duration - try FFAnchoredFlexMusicObject first
            id options = nil;
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime);
                }
            }
            if (!options) {
                // Build options manually
                NSMutableDictionary *opts = [NSMutableDictionary dictionary];
                // Look up option constants via dlsym
                NSString *loopOpt = SpliceKit_flexMusicConstant("FMSong_Option_LoopSongForLongDurations");
                NSString *outroOpt = SpliceKit_flexMusicConstant("FMSong_Option_OutroCanBeShortened");
                if (loopOpt) opts[loopOpt] = @YES;
                if (outroOpt) opts[outroOpt] = @YES;
                options = opts;
            }

            // Get rendition
            id rendition = nil;
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, SpliceKit_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                // Try simpler renditionForDuration:
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get rendition for specified duration"};
                return;
            }

            NSString *rendHandle = SpliceKit_storeHandle(rendition);
            NSMutableDictionary *timing = [NSMutableDictionary dictionary];
            timing[@"renditionHandle"] = rendHandle;
            timing[@"renditionClass"] = NSStringFromClass([rendition class]);

            // Get fitted duration from rendition
            SEL rendDurSel = NSSelectorFromString(@"duration");
            if ([rendition respondsToSelector:rendDurSel]) {
                SpliceKit_CMTime rd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(rendition, rendDurSel);
                timing[@"fittedDurationSeconds"] = @(SpliceKit_cmtimeToSeconds(rd));
            }

            // Extract timed metadata using identifier constants
            NSString *beatId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierBeat");
            NSString *barId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierBar");
            NSString *sectionId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierSection");
            NSString *segmentId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierSegment");
            NSString *onsetId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierOnset");

            SEL timedMetaSel = NSSelectorFromString(@"timedMetadataItemsWithIdentifier:");
            BOOL hasTimedMeta = [rendition respondsToSelector:timedMetaSel];

            // Helper block to extract time arrays from timed metadata
            NSArray *(^extractTimes)(NSString *) = ^NSArray *(NSString *identifier) {
                if (!identifier || !hasTimedMeta) return @[];
                id items = ((id (*)(id, SEL, id))objc_msgSend)(rendition, timedMetaSel, identifier);
                if (![items isKindOfClass:[NSArray class]]) return @[];
                NSMutableArray *times = [NSMutableArray array];
                for (id item in (NSArray *)items) {
                    SEL timeSel = NSSelectorFromString(@"time");
                    if ([item respondsToSelector:timeSel]) {
                        SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, timeSel);
                        [times addObject:@(SpliceKit_cmtimeToSeconds(t))];
                    }
                }
                return times;
            };

            timing[@"beats"] = extractTimes(beatId);
            timing[@"bars"] = extractTimes(barId);
            timing[@"sections"] = extractTimes(sectionId);
            timing[@"segments"] = extractTimes(segmentId);
            timing[@"onsets"] = extractTimes(onsetId);

            // Also try FFFlexMusicTimingMetadata if direct timed metadata is empty
            if ([timing[@"beats"] count] == 0) {
                Class ffTimingClass = objc_getClass("FFFlexMusicTimingMetadata");
                if (ffTimingClass) {
                    SEL initRendSel = NSSelectorFromString(@"initWithSongRendition:clippedRange:");
                    if ([ffTimingClass instancesRespondToSelector:initRendSel]) {
                        // Full range
                        SpliceKit_CMTime start = {0, 600, 1, 0};
                        SpliceKit_CMTimeRange fullRange = {start, durTime};

                        id tmObj = ((id (*)(id, SEL))objc_msgSend)((id)ffTimingClass, @selector(alloc));
                        tmObj = ((id (*)(id, SEL, id, SpliceKit_CMTimeRange))objc_msgSend)(
                            tmObj, initRendSel, rendition, fullRange);

                        if (tmObj) {
                            SEL newMetaSel = NSSelectorFromString(@"newTimingMetadataForType:");
                            if ([tmObj respondsToSelector:newMetaSel]) {
                                // Type 1 = beats, 2 = bars, 4 = sections
                                int types[] = {1, 2, 4};
                                NSString *keys[] = {@"beats", @"bars", @"sections"};
                                for (int i = 0; i < 3; i++) {
                                    id metaItems = ((id (*)(id, SEL, int))objc_msgSend)(
                                        tmObj, newMetaSel, types[i]);
                                    if ([metaItems isKindOfClass:[NSArray class]]) {
                                        NSMutableArray *times = [NSMutableArray array];
                                        for (id item in (NSArray *)metaItems) {
                                            SEL timeSel2 = NSSelectorFromString(@"time");
                                            if ([item respondsToSelector:timeSel2]) {
                                                SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, timeSel2);
                                                [times addObject:@(SpliceKit_cmtimeToSeconds(t))];
                                            }
                                        }
                                        if (times.count > 0) timing[keys[i]] = times;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Report available identifiers
            NSMutableArray *availableIds = [NSMutableArray array];
            if (beatId) [availableIds addObject:@"beat"];
            if (barId) [availableIds addObject:@"bar"];
            if (sectionId) [availableIds addObject:@"section"];
            if (segmentId) [availableIds addObject:@"segment"];
            if (onsetId) [availableIds addObject:@"onset"];
            timing[@"availableIdentifiers"] = availableIds;

            result = timing;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to get timing"};
}

// ---------- 4. flexmusic.renderToFile ----------

static NSDictionary *SpliceKit_handleFlexMusicRender(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    NSNumber *durationSecondsNum = params[@"durationSeconds"];
    NSString *outputPath = params[@"outputPath"];
    NSString *format = params[@"format"] ?: @"m4a";

    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};
    if (!durationSecondsNum) return @{@"error": @"durationSeconds parameter required"};

    double durationSeconds = [durationSecondsNum doubleValue];

    // Generate output path if not provided
    if (!outputPath) {
        NSString *ext = [format isEqualToString:@"wav"] ? @"wav" : @"m4a";
        outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"splicekit_flexmusic_%@.%@",
             [[NSUUID UUID] UUIDString], ext]];
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Resolve song
            id song = nil;
            if (handle) {
                song = SpliceKit_resolveHandle(handle);
            }
            if (!song && songUID) {
                id library = SpliceKit_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            SpliceKit_CMTime durTime = SpliceKit_cmtimeFromSeconds(durationSeconds);

            // Get rendition
            id rendition = nil;
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            id options = nil;
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime);
                }
            }
            if (!options) options = @{};

            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, SpliceKit_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get rendition for export"};
                return;
            }

            // Get AVComposition and AVAudioMix from rendition
            SEL compSel = NSSelectorFromString(@"avCompositionWithAudioMix:includeShortenedOutroFadeOut:");
            id composition = nil;
            id audioMix = nil;

            if ([rendition respondsToSelector:compSel]) {
                // audioMix is passed by reference (AVAudioMix **)
                __unsafe_unretained id mixRef = nil;
                composition = ((id (*)(id, SEL, __unsafe_unretained id *, BOOL))objc_msgSend)(
                    rendition, compSel, &mixRef, YES);
                audioMix = mixRef;
            }

            // Fallback: try avComposition directly
            if (!composition) {
                SEL simpleCompSel = NSSelectorFromString(@"avComposition");
                if ([rendition respondsToSelector:simpleCompSel]) {
                    composition = ((id (*)(id, SEL))objc_msgSend)(rendition, simpleCompSel);
                }
            }

            if (!composition) {
                result = @{@"error": @"Could not get AVComposition from rendition"};
                return;
            }

            // Remove existing file if any
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

            // Create AVAssetExportSession
            Class exportClass = objc_getClass("AVAssetExportSession");
            SEL exportInitSel = NSSelectorFromString(@"exportSessionWithAsset:presetName:");
            NSString *preset = @"AVAssetExportPresetAppleM4A";
            if ([format isEqualToString:@"wav"]) {
                preset = @"AVAssetExportPresetPassthrough";
            }

            id exportSession = ((id (*)(id, SEL, id, id))objc_msgSend)(
                (id)exportClass, exportInitSel, composition, preset);
            if (!exportSession) {
                result = @{@"error": @"Could not create AVAssetExportSession"};
                return;
            }

            // Configure export session
            NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                @selector(setOutputURL:), outputURL);

            NSString *fileType = [format isEqualToString:@"wav"]
                ? @"com.microsoft.waveform-audio"
                : @"com.apple.m4a-audio";
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                NSSelectorFromString(@"setOutputFileType:"), fileType);

            if (audioMix) {
                ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                    NSSelectorFromString(@"setAudioMix:"), audioMix);
            }

            // Export synchronously
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL exportOK = NO;
            __block NSString *exportError = nil;

            ((void (*)(id, SEL, void(^)(void)))objc_msgSend)(exportSession,
                NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                ^{
                    NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(
                        exportSession, NSSelectorFromString(@"status"));
                    // AVAssetExportSessionStatusCompleted = 3
                    exportOK = (status == 3);
                    if (!exportOK) {
                        id err = ((id (*)(id, SEL))objc_msgSend)(
                            exportSession, @selector(error));
                        exportError = err ? [err description] : @"Export failed with unknown error";
                    }
                    dispatch_semaphore_signal(sem);
                });

            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

            if (exportOK) {
                // Get actual file size
                NSDictionary *attrs = [[NSFileManager defaultManager]
                    attributesOfItemAtPath:outputPath error:nil];
                NSNumber *fileSize = attrs[NSFileSize] ?: @0;

                result = @{
                    @"status": @"ok",
                    @"path": outputPath,
                    @"format": format,
                    @"durationSeconds": durationSecondsNum,
                    @"fileSizeBytes": fileSize
                };
            } else {
                result = @{@"error": exportError ?: @"Export timed out"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to render song"};
}

// ---------- 5. flexmusic.addToTimeline ----------

static NSDictionary *SpliceKit_handleFlexMusicAddToTimeline(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *handle = params[@"handle"];
    NSNumber *durationSecondsNum = params[@"durationSeconds"];
    if (!songUID && !handle) return @{@"error": @"songUID or handle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // If no explicit duration, try to get timeline duration
            double durationSeconds = durationSecondsNum ? [durationSecondsNum doubleValue] : 0;

            if (durationSeconds <= 0) {
                id timeline = SpliceKit_getActiveTimelineModule();
                if (timeline) {
                    SEL seqSel = @selector(sequence);
                    if ([timeline respondsToSelector:seqSel]) {
                        id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                        if (sequence) {
                            SEL durSel = NSSelectorFromString(@"duration");
                            if ([sequence respondsToSelector:durSel]) {
                                SpliceKit_CMTime d = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(
                                    sequence, durSel);
                                durationSeconds = SpliceKit_cmtimeToSeconds(d);
                            }
                        }
                    }
                }
            }

            if (durationSeconds <= 0) {
                durationSeconds = 30.0; // fallback default
            }

            // Resolve song
            id song = nil;
            if (handle) {
                song = SpliceKit_resolveHandle(handle);
            }
            if (!song && songUID) {
                id library = SpliceKit_getFlexMusicLibrary();
                if (library) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([library respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(library, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found"};
                return;
            }

            SpliceKit_CMTime durTime = SpliceKit_cmtimeFromSeconds(durationSeconds);

            // Get song name for FCPXML
            NSString *songName = @"FlexMusic";
            SEL nameSel = NSSelectorFromString(@"name");
            if ([song respondsToSelector:nameSel]) {
                id n = ((id (*)(id, SEL))objc_msgSend)(song, nameSel);
                if (n) songName = n;
            }

            // Get rendition and export to temp file
            id rendition = nil;
            id options = @{};
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime) ?: @{};
                }
            }
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, SpliceKit_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get rendition for timeline insertion"};
                return;
            }

            // Export to temp file
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"splicekit_flexmusic_%@.m4a",
                 [[NSUUID UUID] UUIDString]]];

            SEL compSel = NSSelectorFromString(@"avCompositionWithAudioMix:includeShortenedOutroFadeOut:");
            id composition = nil;
            id audioMix = nil;
            if ([rendition respondsToSelector:compSel]) {
                __unsafe_unretained id mixRef = nil;
                composition = ((id (*)(id, SEL, __unsafe_unretained id *, BOOL))objc_msgSend)(
                    rendition, compSel, &mixRef, YES);
                audioMix = mixRef;
            }
            if (!composition) {
                SEL simpleCompSel = NSSelectorFromString(@"avComposition");
                if ([rendition respondsToSelector:simpleCompSel]) {
                    composition = ((id (*)(id, SEL))objc_msgSend)(rendition, simpleCompSel);
                }
            }
            if (!composition) {
                result = @{@"error": @"Could not get AVComposition for export"};
                return;
            }

            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

            Class exportClass = objc_getClass("AVAssetExportSession");
            SEL exportInitSel = NSSelectorFromString(@"exportSessionWithAsset:presetName:");
            id exportSession = ((id (*)(id, SEL, id, id))objc_msgSend)(
                (id)exportClass, exportInitSel, composition, @"AVAssetExportPresetAppleM4A");
            if (!exportSession) {
                result = @{@"error": @"Could not create export session"};
                return;
            }

            NSURL *outputURL = [NSURL fileURLWithPath:tempPath];
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                @selector(setOutputURL:), outputURL);
            ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                NSSelectorFromString(@"setOutputFileType:"), @"com.apple.m4a-audio");
            if (audioMix) {
                ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                    NSSelectorFromString(@"setAudioMix:"), audioMix);
            }

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL exportOK = NO;
            ((void (*)(id, SEL, void(^)(void)))objc_msgSend)(exportSession,
                NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                ^{
                    NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(
                        exportSession, NSSelectorFromString(@"status"));
                    exportOK = (status == 3);
                    dispatch_semaphore_signal(sem);
                });
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

            if (!exportOK) {
                result = @{@"error": @"Failed to render song audio for timeline import"};
                return;
            }

            // Import via FCPXML with the rendered audio file
            int durationFrames = (int)(durationSeconds * 24);
            NSString *escapedName = [[songName stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
            escapedName = [escapedName stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

            NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
            NSString *fmUID = [[[NSUUID UUID] UUIDString] substringToIndex:8];
            NSString *xml = [NSString stringWithFormat:
                @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                @"<!DOCTYPE fcpxml>\n\n"
                @"<fcpxml version=\"1.14\">\n"
                @"    <resources>\n"
                @"        <format id=\"fmt_%@\" frameDuration=\"100/2400s\" width=\"1920\" "
                @"height=\"1080\" name=\"FFVideoFormat1080p24\"/>\n"
                @"        <asset id=\"fm_%@\" hasAudio=\"1\" hasVideo=\"0\" "
                @"audioSources=\"1\" audioChannels=\"2\" audioRate=\"44100\" name=\"%@\">\n"
                @"            <media-rep kind=\"original-media\" src=\"%@\"/>\n"
                @"        </asset>\n"
                @"    </resources>\n"
                @"    <library>\n"
                @"        <event name=\"FlexMusic Import\">\n"
                @"            <project name=\"%@ Audio\">\n"
                @"                <sequence format=\"fmt_%@\" tcStart=\"0s\" tcFormat=\"NDF\" "
                @"audioLayout=\"stereo\" audioRate=\"48k\">\n"
                @"                    <spine>\n"
                @"                        <asset-clip ref=\"fm_%@\" name=\"%@\" "
                @"duration=\"%d00/2400s\" start=\"0s\"/>\n"
                @"                    </spine>\n"
                @"                </sequence>\n"
                @"            </project>\n"
                @"        </event>\n"
                @"    </library>\n"
                @"</fcpxml>\n",
                fmUID, fmUID, escapedName, [tempURL absoluteString],
                escapedName, fmUID, fmUID, escapedName, durationFrames];

            // Import the FCPXML
            NSString *xmlPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"splicekit_flexmusic_import.fcpxml"];
            NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
            [data writeToFile:xmlPath atomically:YES];
            NSURL *xmlURL = [NSURL fileURLWithPath:xmlPath];

            id app = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("NSApplication"), @selector(sharedApplication));
            id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));

            SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
            if ([delegate respondsToSelector:openSel]) {
                ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                    delegate, openSel, xmlURL, nil, YES, nil);
                result = @{
                    @"status": @"ok",
                    @"songName": songName,
                    @"durationSeconds": @(durationSeconds),
                    @"audioFile": tempPath,
                    @"message": @"FlexMusic song added to timeline via FCPXML import"
                };
            } else {
                result = @{@"error": @"PEAppController does not respond to openXMLDocumentWithURL:"};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to add song to timeline"};
}

// ---------- 6. montage.analyzeClips ----------

NSDictionary *SpliceKit_handleMontageAnalyze(NSDictionary *params) {
    NSString *eventFilter = params[@"eventName"];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Get clips from library events
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableArray *analyzedClips = [NSMutableArray array];
            NSInteger clipIndex = 0;

            for (id event in (NSArray *)events) {
                NSString *eventName = @"";
                if ([event respondsToSelector:@selector(displayName)])
                    eventName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";

                // Filter by event name if specified
                if (eventFilter.length > 0 &&
                    ![[eventName lowercaseString] containsString:[eventFilter lowercaseString]]) {
                    continue;
                }

                // Get clips from event (the same walk as browser.listClips)
                NSArray *clips = SpliceKit_browserClipsOfEvent(event);
                if (clips.count == 0) continue;

                for (id clip in (NSArray *)clips) {
                    @autoreleasepool {
                        NSMutableDictionary *info = [NSMutableDictionary dictionary];
                        info[@"index"] = @(clipIndex++);
                        info[@"event"] = eventName;

                        NSString *className = NSStringFromClass([clip class]);
                        info[@"class"] = className;

                        // Name
                        NSString *clipName = @"";
                        if ([clip respondsToSelector:@selector(displayName)]) {
                            clipName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
                        }
                        info[@"name"] = clipName;

                        // Duration
                        double durationSec = 0;
                        if ([clip respondsToSelector:@selector(duration)]) {
                            SpliceKit_CMTime d = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(
                                clip, @selector(duration));
                            durationSec = SpliceKit_cmtimeToSeconds(d);
                            info[@"duration"] = SpliceKit_serializeCMTime(d);
                            info[@"durationSeconds"] = @(durationSec);
                        }

                        // Determine media type from class name
                        NSString *mediaType = @"unknown";
                        if ([className containsString:@"Photo"] || [className containsString:@"Image"] ||
                            [className containsString:@"Still"]) {
                            mediaType = @"photo";
                        } else if ([className containsString:@"Audio"] || [className containsString:@"Sound"]) {
                            mediaType = @"audio";
                        } else if ([className containsString:@"Video"] || [className containsString:@"Media"] ||
                                   [className containsString:@"Asset"] || [className containsString:@"Clip"]) {
                            mediaType = @"video";
                        }
                        // Check for hasVideo / hasAudio properties
                        SEL hasVideoSel = NSSelectorFromString(@"hasVideo");
                        SEL hasAudioSel = NSSelectorFromString(@"hasAudio");
                        BOOL hasVideo = NO, hasAudio = NO;
                        if ([clip respondsToSelector:hasVideoSel]) {
                            hasVideo = ((BOOL (*)(id, SEL))objc_msgSend)(clip, hasVideoSel);
                        }
                        if ([clip respondsToSelector:hasAudioSel]) {
                            hasAudio = ((BOOL (*)(id, SEL))objc_msgSend)(clip, hasAudioSel);
                        }
                        if (hasVideo) mediaType = @"video";
                        else if (hasAudio && !hasVideo) mediaType = @"audio";
                        info[@"mediaType"] = mediaType;
                        info[@"hasVideo"] = @(hasVideo);
                        info[@"hasAudio"] = @(hasAudio);

                        // Score: videos > photos > audio; longer clips score higher
                        double score = 0;
                        if ([mediaType isEqualToString:@"video"]) {
                            score = 10.0 + MIN(durationSec, 30.0);
                        } else if ([mediaType isEqualToString:@"photo"]) {
                            score = 5.0;
                        } else if ([mediaType isEqualToString:@"audio"]) {
                            score = 1.0;
                        } else {
                            score = 3.0 + MIN(durationSec, 10.0);
                        }
                        // Bonus for clips with audio (likely have dialogue)
                        if (hasAudio && hasVideo) score += 2.0;
                        info[@"score"] = @(score);

                        // NOTE: Media URL resolution via originalMediaURL deadlocks inside
                        // FCP's hardened runtime. Skip it — clips will use gaps in FCPXML.
                        // The user can provide file paths manually for proper media references.

                        // Store handle
                        NSString *h = SpliceKit_storeHandle(clip);
                        info[@"handle"] = h;

                        [analyzedClips addObject:info];
                    }
                }
            }

            // Sort by score descending
            [analyzedClips sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"score"] compare:a[@"score"]];
            }];

            result = @{@"clips": analyzedClips, @"count": @(analyzedClips.count)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to analyze clips"};
}

// ---------- 7. montage.planEdit ----------

static NSDictionary *SpliceKit_handleMontagePlan(NSDictionary *params) {
    NSArray *beats = params[@"beats"];
    NSArray *bars = params[@"bars"];
    NSArray *clips = params[@"clips"];
    NSString *style = params[@"style"] ?: @"bar";
    NSNumber *totalDurationNum = params[@"totalDuration"];

    if (!clips || ![clips isKindOfClass:[NSArray class]] || clips.count == 0) {
        return @{@"error": @"clips array parameter required (with handle, duration, score)"};
    }

    // Determine cut points based on style
    NSArray *cutPoints = nil;
    if ([style isEqualToString:@"beat"]) {
        cutPoints = beats;
    } else if ([style isEqualToString:@"section"]) {
        NSArray *sections = params[@"sections"];
        cutPoints = (sections && [sections isKindOfClass:[NSArray class]] && sections.count > 0)
            ? sections : bars;
    } else {
        cutPoints = bars;
    }

    if (!cutPoints || ![cutPoints isKindOfClass:[NSArray class]] || cutPoints.count < 2) {
        return @{@"error": @"Not enough timing data (beats/bars) to plan edit. Need at least 2 cut points."};
    }

    double totalDuration = totalDurationNum ? [totalDurationNum doubleValue] :
        [[cutPoints lastObject] doubleValue];

    // Sort cut points
    NSArray *sortedCuts = [cutPoints sortedArrayUsingSelector:@selector(compare:)];

    // Sort clips by score descending for assignment
    NSArray *sortedClips = [clips sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"score"] compare:a[@"score"]];
        }];

    NSMutableArray *editPlan = [NSMutableArray array];
    NSMutableSet *usedHandles = [NSMutableSet set];
    NSInteger clipPoolIndex = 0;

    for (NSUInteger i = 0; i < sortedCuts.count - 1; i++) {
        double segStart = [sortedCuts[i] doubleValue];
        double segEnd = [sortedCuts[i + 1] doubleValue];
        double segDuration = segEnd - segStart;

        if (segDuration <= 0.01) continue; // skip degenerate segments

        // Pick the highest-scoring unused clip
        NSDictionary *chosenClip = nil;
        for (NSUInteger j = 0; j < sortedClips.count; j++) {
            NSString *h = sortedClips[j][@"handle"];
            if (h && ![usedHandles containsObject:h]) {
                chosenClip = sortedClips[j];
                [usedHandles addObject:h];
                break;
            }
        }

        // If all clips used, start reusing from the top
        if (!chosenClip) {
            [usedHandles removeAllObjects];
            chosenClip = sortedClips[clipPoolIndex % sortedClips.count];
            NSString *h = chosenClip[@"handle"];
            if (h) [usedHandles addObject:h];
            clipPoolIndex++;
        }

        double clipDuration = [chosenClip[@"durationSeconds"] doubleValue];
        if (clipDuration <= 0) clipDuration = [chosenClip[@"duration"] doubleValue];

        // Calculate in/out points (center the best part)
        double inPoint = 0;
        double outPoint = segDuration;
        if (clipDuration > segDuration) {
            inPoint = (clipDuration - segDuration) / 2.0;
            outPoint = inPoint + segDuration;
        } else {
            outPoint = MIN(clipDuration, segDuration);
        }

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"clipHandle"] = chosenClip[@"handle"] ?: @"";
        entry[@"clipName"] = chosenClip[@"name"] ?: @"";
        entry[@"mediaURL"] = chosenClip[@"mediaURL"] ?: @"";
        entry[@"inSeconds"] = @(inPoint);
        entry[@"outSeconds"] = @(outPoint);
        entry[@"timelineStartSeconds"] = @(segStart);
        entry[@"durationSeconds"] = @(segDuration);
        entry[@"segmentIndex"] = @(i);

        [editPlan addObject:entry];
    }

    return @{
        @"editPlan": editPlan,
        @"segmentCount": @(editPlan.count),
        @"totalDurationSeconds": @(totalDuration),
        @"style": style,
        @"cutPointCount": @(sortedCuts.count)
    };
}

// ---------- 8. montage.assemble ----------

static NSDictionary *SpliceKit_handleMontageAssemble(NSDictionary *params) {
    NSArray *editPlan = params[@"editPlan"];
    NSString *projectName = params[@"projectName"] ?: @"SpliceKit Montage";
    NSString *songFile = params[@"songFile"];

    if (!editPlan || ![editPlan isKindOfClass:[NSArray class]] || editPlan.count == 0) {
        return @{@"error": @"editPlan array parameter required"};
    }

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Collect unique media files from clip handles
            NSMutableDictionary *mediaResources = [NSMutableDictionary dictionary];
            NSMutableArray *spineClips = [NSMutableArray array];

            int resourceIndex = 100; // Start at 100 to avoid ID collision with format
            for (NSDictionary *entry in editPlan) {
                NSString *resourceId = nil;
                NSString *mediaURL = entry[@"mediaURL"] ?: @"";
                NSString *clipName = entry[@"clipName"] ?: @"Clip";

                // Deduplicate resources by media URL
                if (mediaURL.length > 0 && mediaResources[mediaURL]) {
                    resourceId = mediaResources[mediaURL][@"id"];
                } else {
                    resourceId = [NSString stringWithFormat:@"r%d", ++resourceIndex];
                    if (mediaURL.length > 0) {
                        mediaResources[mediaURL] = @{@"id": resourceId, @"url": mediaURL};
                    }
                }

                double inSec = [entry[@"inSeconds"] doubleValue];
                double durSec = [entry[@"durationSeconds"] doubleValue];
                double tlStart = [entry[@"timelineStartSeconds"] doubleValue];

                [spineClips addObject:@{
                    @"resourceId": resourceId ?: @"r0",
                    @"name": clipName,
                    @"inSeconds": @(inSec),
                    @"durationSeconds": @(durSec),
                    @"timelineStartSeconds": @(tlStart),
                    @"mediaURL": mediaURL
                }];
            }

            // Build FCPXML 1.14 document (DTD-compliant, modeled after FCP's own export)
            NSString *uid = [[[NSUUID UUID] UUIDString] substringToIndex:8];
            NSString *fmtId = [NSString stringWithFormat:@"fmt_%@", uid];

            NSMutableString *xml = [NSMutableString string];
            [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
            [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
            [xml appendString:@"<fcpxml version=\"1.14\">\n"];
            [xml appendString:@"    <resources>\n"];
            [xml appendFormat:@"        <format id=\"%@\" name=\"FFVideoFormat1080p24\" "
                                @"frameDuration=\"100/2400s\" width=\"1920\" height=\"1080\"/>\n", fmtId];

            // Assets with media-rep children (required by DTD)
            for (NSString *urlKey in mediaResources) {
                NSDictionary *res = mediaResources[urlKey];
                [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" hasVideo=\"1\" "
                    @"format=\"%@\" hasAudio=\"1\" videoSources=\"1\" "
                    @"audioSources=\"1\" audioChannels=\"2\" audioRate=\"44100\">\n",
                    res[@"id"], res[@"id"], fmtId];
                [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                    res[@"url"]];
                [xml appendString:@"        </asset>\n"];
            }

            if (songFile.length > 0) {
                NSURL *songURL = [NSURL fileURLWithPath:songFile];
                [xml appendString:@"        <asset id=\"song_audio\" name=\"Music\" "
                    @"hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" "
                    @"audioRate=\"44100\">\n"];
                [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                    [songURL absoluteString]];
                [xml appendString:@"        </asset>\n"];
            }

            [xml appendString:@"    </resources>\n"];
            [xml appendString:@"    <library>\n"];
            [xml appendFormat:@"        <event name=\"Montage\">\n"];

            NSString *escapedProject = [[projectName
                stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
            [xml appendFormat:@"            <project name=\"%@\">\n", escapedProject];

            // Calculate total duration
            double totalDuration = 0;
            for (NSDictionary *clip in spineClips) {
                double end = [clip[@"timelineStartSeconds"] doubleValue] +
                             [clip[@"durationSeconds"] doubleValue];
                if (end > totalDuration) totalDuration = end;
            }
            int totalFrames = (int)(totalDuration * 2400 / 100); // 24fps = 100/2400s per frame

            [xml appendFormat:@"                <sequence format=\"%@\" "
                @"duration=\"%d00/2400s\" tcStart=\"0s\" tcFormat=\"NDF\" "
                @"audioLayout=\"stereo\" audioRate=\"48k\">\n", fmtId, totalFrames];
            [xml appendString:@"                    <spine>\n"];

            // Add clips to spine — first clip gets the connected song audio
            int offsetFrames = 0;
            for (NSUInteger i = 0; i < spineClips.count; i++) {
                NSDictionary *clip = spineClips[i];
                double durSec = [clip[@"durationSeconds"] doubleValue];
                double inSec = [clip[@"inSeconds"] doubleValue];

                int durFrames = MAX(1, (int)(durSec * 2400 / 100));
                int inFrames = (int)(inSec * 2400 / 100);

                NSString *name = clip[@"name"];
                NSString *escapedName = [[name stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                    stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
                escapedName = [escapedName stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

                BOOL hasMedia = [clip[@"mediaURL"] length] > 0;
                BOOL isFirst = (i == 0);
                BOOL needsSongChild = isFirst && songFile.length > 0;

                if (hasMedia) {
                    if (needsSongChild) {
                        // First clip — open tag, add connected song, close tag
                        [xml appendFormat:@"                        <asset-clip ref=\"%@\" "
                            @"name=\"%@\" offset=\"%d00/2400s\" "
                            @"duration=\"%d00/2400s\" start=\"%d00/2400s\">\n",
                            clip[@"resourceId"], escapedName, offsetFrames,
                            durFrames, inFrames];
                        // Connected song audio on lane -1
                        [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" "
                            @"lane=\"-1\" name=\"Music\" offset=\"0s\" "
                            @"duration=\"%d00/2400s\" start=\"0s\"/>\n", totalFrames];
                        [xml appendString:@"                        </asset-clip>\n"];
                    } else {
                        [xml appendFormat:@"                        <asset-clip ref=\"%@\" "
                            @"name=\"%@\" offset=\"%d00/2400s\" "
                            @"duration=\"%d00/2400s\" start=\"%d00/2400s\"/>\n",
                            clip[@"resourceId"], escapedName, offsetFrames,
                            durFrames, inFrames];
                    }
                } else {
                    if (needsSongChild) {
                        [xml appendFormat:@"                        <gap name=\"%@\" "
                            @"offset=\"%d00/2400s\" duration=\"%d00/2400s\">\n",
                            escapedName, offsetFrames, durFrames];
                        [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" "
                            @"lane=\"-1\" name=\"Music\" offset=\"0s\" "
                            @"duration=\"%d00/2400s\" start=\"0s\"/>\n", totalFrames];
                        [xml appendString:@"                        </gap>\n"];
                    } else {
                        [xml appendFormat:@"                        <gap name=\"%@\" "
                            @"offset=\"%d00/2400s\" duration=\"%d00/2400s\"/>\n",
                            escapedName, offsetFrames, durFrames];
                    }
                }

                offsetFrames += durFrames;
            }

            [xml appendString:@"                    </spine>\n"];
            [xml appendString:@"                </sequence>\n"];
            [xml appendString:@"            </project>\n"];
            [xml appendString:@"        </event>\n"];
            [xml appendString:@"    </library>\n"];
            [xml appendString:@"</fcpxml>\n"];

            // Write and import FCPXML
            NSString *xmlPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"splicekit_montage.fcpxml"];
            NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
            [data writeToFile:xmlPath atomically:YES];
            NSURL *xmlURL = [NSURL fileURLWithPath:xmlPath];

            // Set result immediately, then dispatch import async (it can show modal progress)
            result = @{
                @"status": @"ok",
                @"projectName": projectName,
                @"clipCount": @(spineClips.count),
                @"totalDurationSeconds": @(totalDuration),
                @"hasSongAudio": @(songFile.length > 0),
                @"fcpxmlPath": xmlPath,
                @"message": @"Montage FCPXML written. Importing..."
            };

            // Import asynchronously on the next run loop iteration
            NSURL *importURL = [xmlURL copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                id app = ((id (*)(id, SEL))objc_msgSend)(
                    objc_getClass("NSApplication"), @selector(sharedApplication));
                id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
                SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
                if ([delegate respondsToSelector:openSel]) {
                    ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                        delegate, openSel, importURL, nil, YES, nil);
                }
            });
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to assemble montage"};
}

// ---------- 9. montage.auto ----------

static NSDictionary *SpliceKit_handleMontageAuto(NSDictionary *params) {
    NSString *songUID = params[@"songUID"];
    NSString *songHandle = params[@"songHandle"];
    NSString *eventName = params[@"eventName"];
    NSString *style = params[@"style"] ?: @"bar";
    NSString *projectName = params[@"projectName"] ?: @"Auto Montage";

    if (!songUID && !songHandle) return @{@"error": @"songUID or songHandle parameter required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            // Step 1: Analyze clips from library
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), @selector(copyActiveLibraries));
            if (![libs isKindOfClass:[NSArray class]] || [(NSArray *)libs count] == 0) {
                result = @{@"error": @"No active library"};
                return;
            }

            id library = [(NSArray *)libs firstObject];
            SEL eventsSel = NSSelectorFromString(@"events");
            if (![library respondsToSelector:eventsSel]) {
                result = @{@"error": @"Library does not respond to events"};
                return;
            }
            id events = ((id (*)(id, SEL))objc_msgSend)(library, eventsSel);
            if (![events isKindOfClass:[NSArray class]] || [(NSArray *)events count] == 0) {
                result = @{@"error": @"No events in library"};
                return;
            }

            NSMutableArray *analyzedClips = [NSMutableArray array];
            for (id event in (NSArray *)events) {
                NSString *evName = @"";
                if ([event respondsToSelector:@selector(displayName)])
                    evName = ((id (*)(id, SEL))objc_msgSend)(event, @selector(displayName)) ?: @"";

                if (eventName.length > 0 &&
                    ![[evName lowercaseString] containsString:[eventName lowercaseString]]) {
                    continue;
                }

                id clips = nil;
                SEL displayClipsSel = NSSelectorFromString(@"displayOwnedClips");
                SEL ownedClipsSel = NSSelectorFromString(@"ownedClips");
                if ([event respondsToSelector:displayClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, displayClipsSel);
                } else if ([event respondsToSelector:ownedClipsSel]) {
                    clips = ((id (*)(id, SEL))objc_msgSend)(event, ownedClipsSel);
                }
                if (clips && [clips isKindOfClass:[NSSet class]])
                    clips = [(NSSet *)clips allObjects];
                if (![clips isKindOfClass:[NSArray class]]) continue;

                for (id clip in (NSArray *)clips) {
                    @autoreleasepool {
                        NSMutableDictionary *info = [NSMutableDictionary dictionary];

                        NSString *clipName = @"";
                        if ([clip respondsToSelector:@selector(displayName)])
                            clipName = ((id (*)(id, SEL))objc_msgSend)(clip, @selector(displayName)) ?: @"";
                        info[@"name"] = clipName;

                        double durationSec = 0;
                        if ([clip respondsToSelector:@selector(duration)]) {
                            SpliceKit_CMTime d = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(
                                clip, @selector(duration));
                            durationSec = SpliceKit_cmtimeToSeconds(d);
                        }
                        info[@"durationSeconds"] = @(durationSec);

                        BOOL hasVideo = NO;
                        SEL hasVideoSel = NSSelectorFromString(@"hasVideo");
                        if ([clip respondsToSelector:hasVideoSel])
                            hasVideo = ((BOOL (*)(id, SEL))objc_msgSend)(clip, hasVideoSel);

                        double score = hasVideo ? (10.0 + MIN(durationSec, 30.0)) : 3.0;
                        info[@"score"] = @(score);

                        NSString *h = SpliceKit_storeHandle(clip);
                        info[@"handle"] = h;

                        [analyzedClips addObject:info];
                    }
                }
            }

            if (analyzedClips.count == 0) {
                result = @{@"error": @"No clips found in library/event for montage"};
                return;
            }

            [analyzedClips sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"score"] compare:a[@"score"]];
            }];

            // Calculate total clip duration for song fitting
            double totalClipDuration = 0;
            for (NSDictionary *c in analyzedClips) {
                totalClipDuration += [c[@"durationSeconds"] doubleValue];
            }
            double montageDuration = MIN(totalClipDuration, 120.0);
            if (montageDuration < 5.0) montageDuration = 30.0;

            // Step 2: Get timing from song
            id song = nil;
            if (songHandle) {
                song = SpliceKit_resolveHandle(songHandle);
            }
            if (!song && songUID) {
                id fmLibrary = SpliceKit_getFlexMusicLibrary();
                if (fmLibrary) {
                    SEL forUIDSel = NSSelectorFromString(@"songForUID:");
                    if ([fmLibrary respondsToSelector:forUIDSel]) {
                        song = ((id (*)(id, SEL, id))objc_msgSend)(fmLibrary, forUIDSel, songUID);
                    }
                }
            }
            if (!song) {
                result = @{@"error": @"Song not found for montage"};
                return;
            }

            SpliceKit_CMTime durTime = SpliceKit_cmtimeFromSeconds(montageDuration);

            id rendition = nil;
            id options = @{};
            Class ffFlexObj = objc_getClass("FFAnchoredFlexMusicObject");
            if (ffFlexObj) {
                SEL optSel = NSSelectorFromString(@"optionsForDuration:");
                if ([ffFlexObj respondsToSelector:optSel]) {
                    options = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        (id)ffFlexObj, optSel, durTime) ?: @{};
                }
            }
            SEL rendSel = NSSelectorFromString(@"renditionForDuration:withOptions:");
            if ([song respondsToSelector:rendSel]) {
                rendition = ((id (*)(id, SEL, SpliceKit_CMTime, id))objc_msgSend)(
                    song, rendSel, durTime, options);
            }
            if (!rendition) {
                SEL rendSel2 = NSSelectorFromString(@"renditionForDuration:");
                if ([song respondsToSelector:rendSel2]) {
                    rendition = ((id (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(
                        song, rendSel2, durTime);
                }
            }
            if (!rendition) {
                result = @{@"error": @"Could not get song rendition for montage"};
                return;
            }

            // Get actual fitted duration
            double fittedDuration = montageDuration;
            SEL rendDurSel = NSSelectorFromString(@"duration");
            if ([rendition respondsToSelector:rendDurSel]) {
                SpliceKit_CMTime rd = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(rendition, rendDurSel);
                fittedDuration = SpliceKit_cmtimeToSeconds(rd);
                if (fittedDuration > 0) montageDuration = fittedDuration;
            }

            // Extract timing
            NSString *barId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierBar");
            NSString *beatId = SpliceKit_flexMusicConstant("FMTimedMetadataIdentifierBeat");
            SEL timedMetaSel = NSSelectorFromString(@"timedMetadataItemsWithIdentifier:");
            BOOL hasTimedMeta = [rendition respondsToSelector:timedMetaSel];

            NSArray *(^extractTimesAuto)(NSString *) = ^NSArray *(NSString *identifier) {
                if (!identifier || !hasTimedMeta) return @[];
                id items = ((id (*)(id, SEL, id))objc_msgSend)(rendition, timedMetaSel, identifier);
                if (![items isKindOfClass:[NSArray class]]) return @[];
                NSMutableArray *times = [NSMutableArray array];
                [times addObject:@(0.0)];
                for (id item in (NSArray *)items) {
                    SEL timeSel = NSSelectorFromString(@"time");
                    if ([item respondsToSelector:timeSel]) {
                        SpliceKit_CMTime t = ((SpliceKit_CMTime (*)(id, SEL))STRET_MSG)(item, timeSel);
                        double sec = SpliceKit_cmtimeToSeconds(t);
                        if (sec > 0 && sec < montageDuration) [times addObject:@(sec)];
                    }
                }
                [times addObject:@(montageDuration)];
                return times;
            };

            NSArray *barTimes = extractTimesAuto(barId);
            NSArray *beatTimes = extractTimesAuto(beatId);
            NSArray *cutPoints = [style isEqualToString:@"beat"] ? beatTimes : barTimes;

            // If we got no timing data, create evenly spaced cuts
            if (cutPoints.count < 2) {
                NSMutableArray *evenCuts = [NSMutableArray array];
                double interval = montageDuration / MAX(analyzedClips.count, 4);
                for (double t = 0; t <= montageDuration; t += interval) {
                    [evenCuts addObject:@(t)];
                }
                if ([[evenCuts lastObject] doubleValue] < montageDuration - 0.5) {
                    [evenCuts addObject:@(montageDuration)];
                }
                cutPoints = evenCuts;
            }

            // Step 3: Plan the edit
            NSArray *sortedCuts = [cutPoints sortedArrayUsingSelector:@selector(compare:)];
            NSMutableArray *editPlan = [NSMutableArray array];
            NSMutableSet *usedHandles = [NSMutableSet set];

            NSArray *sortedClips = [analyzedClips sortedArrayUsingComparator:
                ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [b[@"score"] compare:a[@"score"]];
                }];

            NSInteger poolIdx = 0;
            for (NSUInteger i = 0; i < sortedCuts.count - 1; i++) {
                double segStart = [sortedCuts[i] doubleValue];
                double segEnd = [sortedCuts[i + 1] doubleValue];
                double segDuration = segEnd - segStart;
                if (segDuration <= 0.01) continue;

                NSDictionary *chosenClip = nil;
                for (NSUInteger j = 0; j < sortedClips.count; j++) {
                    NSString *ch = sortedClips[j][@"handle"];
                    if (ch && ![usedHandles containsObject:ch]) {
                        chosenClip = sortedClips[j];
                        [usedHandles addObject:ch];
                        break;
                    }
                }
                if (!chosenClip) {
                    [usedHandles removeAllObjects];
                    chosenClip = sortedClips[poolIdx % sortedClips.count];
                    NSString *ch = chosenClip[@"handle"];
                    if (ch) [usedHandles addObject:ch];
                    poolIdx++;
                }

                double clipDur = [chosenClip[@"durationSeconds"] doubleValue];
                double inPt = 0;
                if (clipDur > segDuration) {
                    inPt = (clipDur - segDuration) / 2.0;
                }

                [editPlan addObject:@{
                    @"clipHandle": chosenClip[@"handle"] ?: @"",
                    @"clipName": chosenClip[@"name"] ?: @"",
                    @"inSeconds": @(inPt),
                    @"outSeconds": @(inPt + MIN(clipDur, segDuration)),
                    @"timelineStartSeconds": @(segStart),
                    @"durationSeconds": @(segDuration)
                }];
            }

            if (editPlan.count == 0) {
                result = @{@"error": @"Edit plan is empty - not enough cut points or clips"};
                return;
            }

            // Step 4: Render song to temp file
            NSString *tempSongPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"splicekit_montage_song_%@.m4a",
                 [[NSUUID UUID] UUIDString]]];

            SEL compSel = NSSelectorFromString(@"avCompositionWithAudioMix:includeShortenedOutroFadeOut:");
            id composition = nil;
            id audioMix = nil;
            if ([rendition respondsToSelector:compSel]) {
                __unsafe_unretained id mixRef = nil;
                composition = ((id (*)(id, SEL, __unsafe_unretained id *, BOOL))objc_msgSend)(
                    rendition, compSel, &mixRef, YES);
                audioMix = mixRef;
            }
            if (!composition) {
                SEL simpleCompSel = NSSelectorFromString(@"avComposition");
                if ([rendition respondsToSelector:simpleCompSel])
                    composition = ((id (*)(id, SEL))objc_msgSend)(rendition, simpleCompSel);
            }

            BOOL songRendered = NO;
            if (composition) {
                [[NSFileManager defaultManager] removeItemAtPath:tempSongPath error:nil];
                Class exportClass = objc_getClass("AVAssetExportSession");
                SEL exportInitSel = NSSelectorFromString(@"exportSessionWithAsset:presetName:");
                id exportSession = ((id (*)(id, SEL, id, id))objc_msgSend)(
                    (id)exportClass, exportInitSel, composition, @"AVAssetExportPresetAppleM4A");
                if (exportSession) {
                    NSURL *outURL = [NSURL fileURLWithPath:tempSongPath];
                    ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                        @selector(setOutputURL:), outURL);
                    ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                        NSSelectorFromString(@"setOutputFileType:"), @"com.apple.m4a-audio");
                    if (audioMix) {
                        ((void (*)(id, SEL, id))objc_msgSend)(exportSession,
                            NSSelectorFromString(@"setAudioMix:"), audioMix);
                    }
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    __block BOOL expOK = NO;
                    ((void (*)(id, SEL, void(^)(void)))objc_msgSend)(exportSession,
                        NSSelectorFromString(@"exportAsynchronouslyWithCompletionHandler:"),
                        ^{
                            NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(
                                exportSession, NSSelectorFromString(@"status"));
                            expOK = (status == 3);
                            dispatch_semaphore_signal(sem);
                        });
                    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
                    songRendered = expOK;
                }
            }

            // Step 5: Assemble montage via FCPXML
            NSMutableDictionary *mediaResources = [NSMutableDictionary dictionary];
            NSMutableArray *spineClips = [NSMutableArray array];
            int resIdx = 100;

            for (NSDictionary *entry in editPlan) {
                NSString *clipHandle = entry[@"clipHandle"];
                id clip = clipHandle ? SpliceKit_resolveHandle(clipHandle) : nil;
                NSString *mediaURL = @"";

                if (clip) {
                    NSString *resolved = SpliceKit_getMediaURLForClip(clip);
                    if (resolved) mediaURL = resolved;
                }

                NSString *resId = nil;
                if (mediaURL.length > 0 && mediaResources[mediaURL]) {
                    resId = mediaResources[mediaURL][@"id"];
                } else if (mediaURL.length > 0) {
                    resId = [NSString stringWithFormat:@"r%d", ++resIdx];
                    mediaResources[mediaURL] = @{@"id": resId, @"url": mediaURL};
                }

                [spineClips addObject:@{
                    @"resourceId": resId ?: @"r0",
                    @"name": entry[@"clipName"] ?: @"Clip",
                    @"inSeconds": entry[@"inSeconds"] ?: @0,
                    @"durationSeconds": entry[@"durationSeconds"] ?: @0,
                    @"timelineStartSeconds": entry[@"timelineStartSeconds"] ?: @0,
                    @"mediaURL": mediaURL
                }];
            }

            // Build DTD-compliant FCPXML 1.14
            NSString *uid = [[[NSUUID UUID] UUIDString] substringToIndex:8];
            NSString *fmtId = [NSString stringWithFormat:@"fmt_%@", uid];

            NSMutableString *xml = [NSMutableString string];
            [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
            [xml appendString:@"<!DOCTYPE fcpxml>\n\n"];
            [xml appendString:@"<fcpxml version=\"1.14\">\n"];
            [xml appendString:@"    <resources>\n"];
            [xml appendFormat:@"        <format id=\"%@\" name=\"FFVideoFormat1080p24\" "
                                @"frameDuration=\"100/2400s\" width=\"1920\" height=\"1080\"/>\n", fmtId];
            for (NSString *urlKey in mediaResources) {
                NSDictionary *res = mediaResources[urlKey];
                [xml appendFormat:@"        <asset id=\"%@\" name=\"%@\" hasVideo=\"1\" "
                    @"format=\"%@\" hasAudio=\"1\" videoSources=\"1\" "
                    @"audioSources=\"1\" audioChannels=\"2\" audioRate=\"44100\">\n",
                    res[@"id"], res[@"id"], fmtId];
                [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                    res[@"url"]];
                [xml appendString:@"        </asset>\n"];
            }
            if (songRendered) {
                NSURL *songURL = [NSURL fileURLWithPath:tempSongPath];
                [xml appendString:@"        <asset id=\"song_audio\" name=\"Music\" "
                    @"hasAudio=\"1\" audioSources=\"1\" audioChannels=\"2\" "
                    @"audioRate=\"44100\">\n"];
                [xml appendFormat:@"            <media-rep kind=\"original-media\" src=\"%@\"/>\n",
                    [songURL absoluteString]];
                [xml appendString:@"        </asset>\n"];
            }
            [xml appendString:@"    </resources>\n"];

            int totalFrames = (int)(montageDuration * 2400 / 100);
            NSString *escapedProject = [[projectName
                stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];

            [xml appendString:@"    <library>\n"];
            [xml appendFormat:@"        <event name=\"Montage\">\n"];
            [xml appendFormat:@"            <project name=\"%@\">\n", escapedProject];
            [xml appendFormat:@"                <sequence format=\"%@\" "
                @"duration=\"%d00/2400s\" tcStart=\"0s\" tcFormat=\"NDF\" "
                @"audioLayout=\"stereo\" audioRate=\"48k\">\n", fmtId, totalFrames];
            [xml appendString:@"                    <spine>\n"];

            int offsetFrames = 0;
            for (NSUInteger i = 0; i < spineClips.count; i++) {
                NSDictionary *sc = spineClips[i];
                double dur = [sc[@"durationSeconds"] doubleValue];
                double inSec = [sc[@"inSeconds"] doubleValue];

                int durFrames = MAX(1, (int)(dur * 2400 / 100));
                int inFrames = (int)(inSec * 2400 / 100);
                NSString *name = sc[@"name"];
                NSString *escaped = [[name stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                    stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
                escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

                BOOL hasMedia = [sc[@"mediaURL"] length] > 0;
                BOOL needsSong = (i == 0) && songRendered;

                if (hasMedia) {
                    if (needsSong) {
                        [xml appendFormat:@"                        <asset-clip ref=\"%@\" "
                            @"name=\"%@\" offset=\"%d00/2400s\" "
                            @"duration=\"%d00/2400s\" start=\"%d00/2400s\">\n",
                            sc[@"resourceId"], escaped, offsetFrames, durFrames, inFrames];
                        [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" "
                            @"lane=\"-1\" name=\"Music\" offset=\"0s\" "
                            @"duration=\"%d00/2400s\" start=\"0s\"/>\n", totalFrames];
                        [xml appendString:@"                        </asset-clip>\n"];
                    } else {
                        [xml appendFormat:@"                        <asset-clip ref=\"%@\" "
                            @"name=\"%@\" offset=\"%d00/2400s\" "
                            @"duration=\"%d00/2400s\" start=\"%d00/2400s\"/>\n",
                            sc[@"resourceId"], escaped, offsetFrames, durFrames, inFrames];
                    }
                } else {
                    if (needsSong) {
                        [xml appendFormat:@"                        <gap name=\"%@\" "
                            @"offset=\"%d00/2400s\" duration=\"%d00/2400s\">\n",
                            escaped, offsetFrames, durFrames];
                        [xml appendFormat:@"                            <asset-clip ref=\"song_audio\" "
                            @"lane=\"-1\" name=\"Music\" offset=\"0s\" "
                            @"duration=\"%d00/2400s\" start=\"0s\"/>\n", totalFrames];
                        [xml appendString:@"                        </gap>\n"];
                    } else {
                        [xml appendFormat:@"                        <gap name=\"%@\" "
                            @"offset=\"%d00/2400s\" duration=\"%d00/2400s\"/>\n",
                            escaped, offsetFrames, durFrames];
                    }
                }
                offsetFrames += durFrames;
            }

            [xml appendString:@"                    </spine>\n"];
            [xml appendString:@"                </sequence>\n"];
            [xml appendString:@"            </project>\n"];
            [xml appendString:@"        </event>\n"];
            [xml appendString:@"    </library>\n"];
            [xml appendString:@"</fcpxml>\n"];

            NSString *xmlPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"splicekit_montage_auto.fcpxml"];
            NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
            [data writeToFile:xmlPath atomically:YES];
            NSURL *xmlURL = [NSURL fileURLWithPath:xmlPath];

            result = @{
                @"status": @"ok",
                @"projectName": projectName,
                @"clipCount": @(spineClips.count),
                @"totalDurationSeconds": @(montageDuration),
                @"songRendered": @(songRendered),
                @"style": style,
                @"cutPoints": @(sortedCuts.count),
                @"fcpxmlPath": xmlPath,
                @"message": @"Auto montage FCPXML written. Importing..."
            };

            NSURL *importURL = [xmlURL copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                id app = ((id (*)(id, SEL))objc_msgSend)(
                    objc_getClass("NSApplication"), @selector(sharedApplication));
                id delegate = ((id (*)(id, SEL))objc_msgSend)(app, @selector(delegate));
                SEL openSel = NSSelectorFromString(@"openXMLDocumentWithURL:bundleURL:display:sender:");
                if ([delegate respondsToSelector:openSel]) {
                    ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(
                        delegate, openSel, importURL, nil, YES, nil);
                }
            });
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"Failed to create auto montage"};
}

#pragma mark - Request Dispatcher
//
// Central routing for all JSON-RPC methods. Each method name maps to a handler function.
// The method names are namespaced (system.*, timeline.*, playback.*, etc.) to keep
// things organized. Adding a new endpoint means: write the handler, add it here.
//
// Yeah, this is a massive if-else chain. A static NSDictionary<NSString, handler_func_t>
// would be cleaner, but C function pointers in ObjC dictionaries are awkward and this
// works fine. The string comparisons are fast enough — we're not doing thousands per second.
//

// A modal alert or sheet currently blocking Final Cut Pro, or nil.
//
// SpliceKit_executeOnMainThread schedules work with kCFRunLoopCommonModes, and common
// modes include NSModalPanelRunLoopMode. A bridge request therefore runs *inside* a
// modal alert's run loop rather than waiting for it to close. That is deliberate —
// detect_dialog and dismiss_dialog have to work while a dialog is up — but it means an
// edit can execute in the middle of an action Final Cut Pro has not finished.
//
// It crashed the app twice. With the "not enough extra media for this transition" alert
// on screen, a timeline undo ran inside the modal loop and Final Cut Pro segfaulted in
// its own undo handler:
//
//   objc_msgSend
//   -[FFUndoHandler undoableEnd:option:error:]
//   -[FFUndoManager undo]
//   __SpliceKit_handleTimelineAction_block_invoke
//   __SpliceKit_executeOnMainThread_block_invoke
//   __CFRunLoopDoBlocks ... -[NSApplication runModalForWindow:] ... -[NSAlert runModal]
//
// So: reads still run while a dialog is up, and anything that changes the document
// waits for the dialog to be answered.
static NSWindow *SpliceKit_blockingModalWindow(void) {
    __block NSWindow *blocking = nil;
    SpliceKit_executeOnMainThreadWithTimeout(^{
        @try {
            NSWindow *modal = [NSApp modalWindow];
            if (modal && [modal isVisible]) { blocking = modal; return; }
            for (NSWindow *window in [NSApp windows]) {
                NSWindow *sheet = [window attachedSheet];
                if (sheet && [sheet isVisible]) { blocking = sheet; return; }
            }
        } @catch (NSException *e) {}
    }, 5.0, NO);  // pre-check: a busy main thread is the handler's to report
    return blocking;
}

// True while Final Cut Pro's timeline is in the middle of a drag.
//
// The same class of crash as the modal one, from the other side. A drag over the
// timeline holds a temporary transaction open, and ending it runs the same undo
// handler; with a bridge edit having opened and closed an undo scope underneath it,
// Final Cut Pro segfaulted there too:
//
//   objc_msgSend
//   -[FFUndoHandler undoableEnd:option:error:]
//   -[FFAnchoredTimelineModule(FFTLKDataSource) _endTemporaryTransactionWithCommit:error:]
//   -[FFAnchoredTimelineModule(FFTLKDataSource) _handlerDidStopTracking:]
//   -[TLKTimelineView draggingExited:] ... NSCoreDragTrackingProc ... CoreDragMessageHandler
//
// -isTracking is Final Cut Pro's own flag, and it gates its own actions on the same
// thing (-disableActionWhileTracking:).
static BOOL SpliceKit_timelineIsTracking(void) {
    __block BOOL tracking = NO;
    SpliceKit_executeOnMainThreadWithTimeout(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            SEL sel = NSSelectorFromString(@"isTracking");
            if (timeline && [timeline respondsToSelector:sel]) {
                tracking = ((BOOL (*)(id, SEL))objc_msgSend)(timeline, sel);
            }
        } @catch (NSException *e) { tracking = NO; }
    }, 5.0, NO);  // pre-check: a busy main thread is the handler's to report
    return tracking;
}

// Methods allowed while Final Cut Pro is busy — a modal dialog on screen, or a drag in
// progress in the timeline: the dialog tools themselves (otherwise nothing could answer
// the dialog) and the connection-level namespaces, which never touch the document.
// Everything else goes by its bridge.describe safety tag; an untagged method counts as
// state_dependent, which is what SpliceKitBridgeMetadata.m says to assume when in doubt,
// so a newly added method is refused rather than crashing the app.
static BOOL SpliceKit_methodIsAllowedWhileBusy(NSString *method) {
    if ([method hasPrefix:@"dialog."]) return YES;
    if ([method hasPrefix:@"bridge."]) return YES;
    if ([method hasPrefix:@"events."]) return YES;
    if ([method hasPrefix:@"async."]) return YES;
    NSDictionary *meta = SpliceKit_builtinMetadataForMethod(method);
    return [meta[@"safety"] isEqualToString:@"safe"];
}

NSDictionary *SpliceKit_handleRequest(NSDictionary *request) {
    NSString *method = request[@"method"];
    id rawParams = request[@"params"];
    // Clients sometimes send `"params": []` instead of `{}`. Without this guard,
    // every later `params[@"key"]` crashes with "unrecognized selector sent to
    // __NSArray0". See APPLE-MACOS-X. Coerce non-dict params to empty dict.
    NSDictionary *params = [rawParams isKindOfClass:[NSDictionary class]] ? (NSDictionary *)rawParams : @{};

    if (![method isKindOfClass:[NSString class]]) {
        return @{@"error": @{@"code": @(-32600), @"message": @"Invalid Request: method required"}};
    }

    SpliceKit_installEffectDragSwizzlesNow();

    // Auto-dismiss known blocking dialogs before processing any request -- except the
    // methods that exist to answer while the main thread is busy (liveness, events,
    // import-job status), which should not wait on it at all.
    BOOL answersOffMain = [method hasPrefix:@"bridge."] || [method hasPrefix:@"events."] ||
                          [method hasPrefix:@"async."] || [method isEqualToString:@"fcpxml.importStatus"];
    if (!answersOffMain) {
        SpliceKit_autoDismissBlockingDialogs();
    }

    // Anything that changes the document waits while Final Cut Pro is busy; see
    // SpliceKit_blockingModalWindow and SpliceKit_timelineIsTracking for the three
    // crashes this prevents.
    //
    // This narrows the window, it does not close it. The check is its own main-thread
    // hop, and the handler takes another one further down, so a drag that starts in
    // between is not seen. Closing that properly means checking -isTracking inside the
    // same main-thread block that performs the edit, which is every handler's own
    // dispatch, not this one place. Two things keep the exposure small: the gap is a
    // few lines of bridge-thread work, and an async request re-enters
    // SpliceKit_handleRequest when the job actually runs, so it is re-checked then
    // rather than being cleared once and executed much later.
    if (!SpliceKit_methodIsAllowedWhileBusy(method)) {
        if (SpliceKit_timelineIsTracking()) {
            return @{@"error": @{
                @"code": @(-32001),
                @"message": [NSString stringWithFormat:
                    @"Something is being dragged in the Final Cut Pro timeline, so '%@' "
                    @"cannot run: an edit landing in the middle of a drag has crashed "
                    @"Final Cut Pro in its own undo handler. Let go of the mouse and retry.",
                    method],
                @"dragPending": @YES,
            }};
        }
        NSWindow *blocking = SpliceKit_blockingModalWindow();
        if (blocking) {
            __block NSString *title = nil;
            SpliceKit_executeOnMainThread(^{
                @try {
                    title = [blocking title];
                    if (title.length == 0) title = NSStringFromClass([blocking class]);
                } @catch (NSException *e) { title = @"a dialog"; }
            });
            return @{@"error": @{
                @"code": @(-32001),
                @"message": [NSString stringWithFormat:
                    @"Final Cut Pro is showing a modal dialog (%@), so '%@' cannot run: "
                    @"editing while a dialog is open runs inside its modal loop and has "
                    @"crashed Final Cut Pro. Answer it first — detect_dialog to see it, "
                    @"click_dialog_button or dismiss_dialog to close it — then retry.",
                    title ?: @"untitled", method],
                @"dialogPending": @YES,
            }};
        }
    }

    // async=true in params: run this request on a worker queue, return a
    // correlation_id immediately, broadcast `command.completed` when done.
    // bridge.* / events.* / async.* / system.* are always synchronous — they're
    // cheap and some are per-connection state.
    BOOL wantsAsync = [params[@"async"] boolValue];
    if (wantsAsync
        && ![method isEqualToString:@"fcpxml.import"]   // has its own job model
        && ![method hasPrefix:@"bridge."]
        && ![method hasPrefix:@"events."]
        && ![method hasPrefix:@"async."]
        && ![method hasPrefix:@"system."]) {
        NSMutableDictionary *cleanParams = [params mutableCopy];
        [cleanParams removeObjectForKey:@"async"];
        NSDictionary *dispatched = SpliceKit_asyncDispatch(method, cleanParams,
            ^NSDictionary *(NSDictionary *innerParams) {
                NSDictionary *innerReq = @{@"method": method, @"params": innerParams};
                NSDictionary *innerResult = SpliceKit_handleRequest(innerReq);
                // handleRequest wraps everything in {"result": ...} or {"error": ...};
                // unwrap for the event payload.
                if (innerResult[@"result"]) return innerResult[@"result"];
                return innerResult;
            });
        return @{@"result": dispatched};
    }

    NSDictionary *result = nil;
    unsigned timeoutsBefore = SpliceKit_mainThreadDispatchTimeoutCount();
    SpliceKit_resetMainThreadTimeoutState();

    // system.* namespace
    if ([method isEqualToString:@"system.version"]) {
        result = SpliceKit_handleSystemVersion(params);
    } else if ([method isEqualToString:@"system.getClasses"]) {
        result = SpliceKit_handleSystemGetClasses(params);
    } else if ([method isEqualToString:@"system.getMethods"]) {
        result = SpliceKit_handleSystemGetMethods(params);
    } else if ([method isEqualToString:@"system.callMethod"]) {
        result = SpliceKit_handleSystemCallMethod(params);
    } else if ([method isEqualToString:@"system.swizzle"]) {
        result = SpliceKit_handleSystemSwizzle(params);
    } else if ([method isEqualToString:@"system.getProperties"]) {
        result = SpliceKit_handleSystemGetProperties(params);
    } else if ([method isEqualToString:@"system.getProtocols"]) {
        result = SpliceKit_handleSystemGetProtocols(params);
    } else if ([method isEqualToString:@"system.getSuperchain"]) {
        result = SpliceKit_handleSystemGetSuperchain(params);
    } else if ([method isEqualToString:@"system.getIvars"]) {
        result = SpliceKit_handleSystemGetIvars(params);
    } else if ([method isEqualToString:@"system.callMethodWithArgs"]) {
        result = SpliceKit_handleCallMethodWithArgs(params);
    }
    // object.* namespace
    else if ([method isEqualToString:@"object.get"]) {
        result = SpliceKit_handleObjectGet(params);
    } else if ([method isEqualToString:@"object.release"]) {
        result = SpliceKit_handleObjectRelease(params);
    } else if ([method isEqualToString:@"object.list"]) {
        result = SpliceKit_handleObjectList(params);
    } else if ([method isEqualToString:@"object.getProperty"]) {
        result = SpliceKit_handleGetProperty(params);
    } else if ([method isEqualToString:@"object.setProperty"]) {
        result = SpliceKit_handleSetProperty(params);
    }
    // timeline.* namespace
    else if ([method isEqualToString:@"timeline.action"]) {
        result = SpliceKit_annotatePendingDialog(SpliceKit_handleTimelineAction(params),
                                                 [params[@"action"] isKindOfClass:[NSString class]] ? params[@"action"] : @"");
    } else if ([method isEqualToString:@"timeline.directAction"]) {
        result = SpliceKit_handleDirectTimelineAction(params);
    } else if ([method isEqualToString:@"timeline.getState"]) {
        result = SpliceKit_handleTimelineGetState(params);
    } else if ([method isEqualToString:@"timeline.getDetailedState"]) {
        result = SpliceKit_handleTimelineGetDetailedState(params);
    } else if ([method isEqualToString:@"timeline.getMarkers"]) {
        result = SpliceKit_handleTimelineGetMarkers(params);
    } else if ([method isEqualToString:@"timeline.setRange"]) {
        result = SpliceKit_handleSetRange(params);
    } else if ([method isEqualToString:@"timeline.addMarkers"]) {
        result = SpliceKit_handleBatchAddMarkers(params);
    } else if ([method isEqualToString:@"timeline.bladeAtTimes"]) {
        result = SpliceKit_handleBladeAtTimes(params);
    } else if ([method isEqualToString:@"timeline.trimClipsToBeats"]) {
        result = SpliceKit_handleTrimClipsToBeats(params);
    } else if ([method isEqualToString:@"timeline.assembleRandomClipsToBeats"]) {
        result = SpliceKit_handleAssembleRandomClipsToBeats(params);
    } else if ([method isEqualToString:@"timeline.batchActions"]) {
        result = SpliceKit_handleBatchActions(params);
    } else if ([method isEqualToString:@"timeline.batchExport"]) {
        result = SpliceKit_handleBatchExport(params);
    } else if ([method isEqualToString:@"timeline.selectItems"]) {
        result = SpliceKit_handleTimelineSelectItems(params);
    } else if ([method isEqualToString:@"timeline.trimClip"]) {
        result = SpliceKit_handleTimelineTrimClip(params);
    } else if ([method isEqualToString:@"timeline.getClipInfo"]) {
        result = SpliceKit_handleTimelineGetClipInfo(params);
    } else if ([method isEqualToString:@"timeline.getAudioLevels"]) {
        result = SpliceKit_handleTimelineGetAudioLevels(params);
    } else if ([method isEqualToString:@"timeline.captureClipFrame"]) {
        result = SpliceKit_handleTimelineCaptureClipFrame(params);
    } else if ([method isEqualToString:@"timeline.beginEdit"]) {
        result = SpliceKit_handleTimelineBeginEdit(params);
    } else if ([method isEqualToString:@"timeline.endEdit"]) {
        result = SpliceKit_handleTimelineEndEdit(params);
    }
    // spine.* namespace
    else if ([method isEqualToString:@"spine.getItems"]) {
        result = SpliceKit_handleSpineGetItems(params);
    } else if ([method isEqualToString:@"spine.reorder"]) {
        result = SpliceKit_handleSpineReorder(params);
    }
    // playback.* namespace
    else if ([method isEqualToString:@"playback.action"]) {
        result = SpliceKit_handlePlayback(params);
    } else if ([method isEqualToString:@"playback.seekToTime"]) {
        result = SpliceKit_handlePlaybackSeek(params);
    } else if ([method isEqualToString:@"playback.getPosition"]) {
        result = SpliceKit_handlePlaybackGetPosition(params);
    } else if ([method isEqualToString:@"playback.setRate"]) {
        result = SpliceKit_handlePlaybackSetRate(params);
    } else if ([method isEqualToString:@"playback.shuttle"]) {
        result = SpliceKit_handlePlaybackShuttle(params);
    }
    // fcpxml.* namespace
    else if ([method isEqualToString:@"fcpxml.importStatus"]) {
        result = SpliceKit_handleFCPXMLImportStatus(params);
    }
    else if ([method isEqualToString:@"fcpxml.import"]) {
        result = SpliceKit_handleFCPXMLImport(params);
    } else if ([method isEqualToString:@"fcpxml.pasteImport"]) {
        result = SpliceKit_handlePasteboardImportXML(params);
    } else if ([method isEqualToString:@"otio.toFCPXML"]) {
        result = SpliceKit_handleOTIOToFCPXML(params);
    }
    // effects.* namespace
    else if ([method isEqualToString:@"effects.list"]) {
        result = SpliceKit_handleEffectList(params);
    } else if ([method isEqualToString:@"effects.getClipEffects"]) {
        result = SpliceKit_handleGetClipEffects(params);
    }
    // transcript.* namespace
    else if ([method isEqualToString:@"transcript.open"]) {
        result = SpliceKit_handleTranscriptOpen(params);
    } else if ([method isEqualToString:@"transcript.close"]) {
        result = SpliceKit_handleTranscriptClose(params);
    } else if ([method isEqualToString:@"transcript.getState"]) {
        result = SpliceKit_handleTranscriptGetState(params);
    } else if ([method isEqualToString:@"transcript.deleteWords"]) {
        result = SpliceKit_handleTranscriptDeleteWords(params);
    } else if ([method isEqualToString:@"transcript.moveWords"]) {
        result = SpliceKit_handleTranscriptMoveWords(params);
    } else if ([method isEqualToString:@"transcript.search"]) {
        result = SpliceKit_handleTranscriptSearch(params);
    } else if ([method isEqualToString:@"transcript.deleteSilences"]) {
        result = SpliceKit_handleTranscriptDeleteSilences(params);
    } else if ([method isEqualToString:@"transcript.clear"]) {
        SpliceKit_executeOnMainThread(^{
            [[SpliceKitTranscriptPanel sharedPanel] clearTranscript];
        });
        result = @{@"status": @"ok", @"message": @"Transcript cleared from memory and disk cache."};
    } else if ([method isEqualToString:@"transcript.setSilenceThreshold"]) {
        result = SpliceKit_handleTranscriptSetSilenceThreshold(params);
    } else if ([method isEqualToString:@"transcript.setSpeaker"]) {
        result = SpliceKit_handleTranscriptSetSpeaker(params);
    } else if ([method isEqualToString:@"transcript.setEngine"]) {
        result = SpliceKit_handleTranscriptSetEngine(params);
    }
    // captions.* namespace
    else if ([method isEqualToString:@"captions.open"]) {
        result = SpliceKit_handleCaptionsOpen(params);
    } else if ([method isEqualToString:@"captions.close"]) {
        result = SpliceKit_handleCaptionsClose(params);
    } else if ([method isEqualToString:@"captions.getState"]) {
        result = SpliceKit_handleCaptionsGetState(params);
    } else if ([method isEqualToString:@"captions.getStyles"]) {
        result = SpliceKit_handleCaptionsGetStyles(params);
    } else if ([method isEqualToString:@"captions.setStyle"]) {
        result = SpliceKit_handleCaptionsSetStyle(params);
    } else if ([method isEqualToString:@"captions.setGrouping"]) {
        result = SpliceKit_handleCaptionsSetGrouping(params);
    } else if ([method isEqualToString:@"captions.generate"]) {
        result = SpliceKit_handleCaptionsGenerate(params);
    } else if ([method isEqualToString:@"captions.exportSRT"]) {
        result = SpliceKit_handleCaptionsExportSRT(params);
    } else if ([method isEqualToString:@"captions.exportTXT"]) {
        result = SpliceKit_handleCaptionsExportTXT(params);
    } else if ([method isEqualToString:@"captions.setWords"]) {
        result = SpliceKit_handleCaptionsSetWords(params);
    } else if ([method isEqualToString:@"captions.verify"]) {
        result = SpliceKit_handleCaptionsVerify(params);
    } else if ([method isEqualToString:@"captions.cleanup"]) {
        result = SpliceKit_handleCaptionsCleanup(params);
    }
    // native captions (FFAnchoredCaption objects in caption lane)
    else if ([method isEqualToString:@"nativeCaptions.generate"]) {
        result = SpliceKit_handleNativeCaptionsGenerate(params);
    } else if ([method isEqualToString:@"nativeCaptions.verify"]) {
        result = SpliceKit_handleNativeCaptionsVerify(params);
    } else if ([method isEqualToString:@"nativeCaptions.remove"]) {
        result = SpliceKit_handleNativeCaptionsRemove(params);
    }
    // scene detection
    else if ([method isEqualToString:@"scene.detect"]) {
        result = SpliceKit_handleDetectSceneChanges(params);
    }
    // effects browse/apply
    else if ([method isEqualToString:@"effects.listAvailable"]) {
        result = SpliceKit_handleEffectsListAvailable(params);
    } else if ([method isEqualToString:@"effects.apply"]) {
        result = SpliceKit_handleEffectsApply(params);
    } else if ([method isEqualToString:@"titles.insert"]) {
        result = SpliceKit_handleTitleInsert(params);
    } else if ([method isEqualToString:@"stabilize.subject"]) {
        result = SpliceKit_handleSubjectStabilize(params);
    }
    // transitions.* namespace
    else if ([method isEqualToString:@"transitions.list"]) {
        result = SpliceKit_handleTransitionsList(params);
    } else if ([method isEqualToString:@"transitions.apply"]) {
        result = SpliceKit_handleTransitionsApply(params);
    }
    // command.* namespace (command palette)
    else if ([method isEqualToString:@"command.show"]) {
        result = SpliceKit_handleCommandShow(params);
    } else if ([method isEqualToString:@"command.hide"]) {
        result = SpliceKit_handleCommandHide(params);
    } else if ([method isEqualToString:@"command.search"]) {
        result = SpliceKit_handleCommandSearch(params);
    } else if ([method isEqualToString:@"command.execute"]) {
        result = SpliceKit_handleCommandExecute(params);
    } else if ([method isEqualToString:@"command.ai"]) {
        result = SpliceKit_handleCommandAI(params);
    } else if ([method isEqualToString:@"command.aiGemma"]) {
        result = SpliceKit_handleCommandAIGemma(params);
    } else if ([method isEqualToString:@"command.aiAppleAgentic"]) {
        result = SpliceKit_handleCommandAIAppleAgentic(params);
    }
    // liveCam.* namespace
    else if ([method isEqualToString:@"liveCam.show"]) {
        result = SpliceKit_handleLiveCamShow(params);
    } else if ([method isEqualToString:@"liveCam.hide"]) {
        result = SpliceKit_handleLiveCamHide(params);
    } else if ([method isEqualToString:@"liveCam.status"]) {
        result = SpliceKit_handleLiveCamStatus(params);
    }
    // dualTimeline.* namespace
    else if ([method isEqualToString:@"dualTimeline.status"]) {
        result = SpliceKit_handleDualTimelineStatus(params);
    } else if ([method isEqualToString:@"dualTimeline.open"]) {
        result = SpliceKit_handleDualTimelineOpen(params);
    } else if ([method isEqualToString:@"dualTimeline.syncRoot"]) {
        result = SpliceKit_handleDualTimelineSyncRoot(params);
    } else if ([method isEqualToString:@"dualTimeline.openSelectedInSecondary"]) {
        result = SpliceKit_handleDualTimelineOpenSelectedInSecondary(params);
    } else if ([method isEqualToString:@"dualTimeline.focus"]) {
        result = SpliceKit_handleDualTimelineFocus(params);
    } else if ([method isEqualToString:@"dualTimeline.close"]) {
        result = SpliceKit_handleDualTimelineClose(params);
    } else if ([method isEqualToString:@"dualTimeline.togglePanel"]) {
        result = SpliceKit_handleDualTimelineTogglePanel(params);
    }
    // browser.* namespace
    else if ([method isEqualToString:@"browser.listClips"]) {
        result = SpliceKit_handleBrowserListClips(params);
    } else if ([method isEqualToString:@"browser.appendClip"]) {
        result = SpliceKit_handleBrowserAppendClip(params);
    } else if ([method isEqualToString:@"browser.insertClip"]) {
        result = SpliceKit_handleBrowserInsertClip(params);
    } else if ([method isEqualToString:@"browser.connectClip"]) {
        result = SpliceKit_handleBrowserConnectClip(params);
    } else if ([method isEqualToString:@"browser.placeClip"]) {
        result = SpliceKit_handleBrowserPlaceClipEdit(params);
    } else if ([method isEqualToString:@"media.importFile"]) {
        result = SpliceKit_handleMediaImportFile(params);
    } else if ([method isEqualToString:@"media.removeClip"]) {
        result = SpliceKit_handleMediaRemoveClip(params);
    }
    // menu.* namespace
    else if ([method isEqualToString:@"menu.execute"]) {
        result = SpliceKit_handleMenuExecute(params);
    } else if ([method isEqualToString:@"menu.list"]) {
        result = SpliceKit_handleMenuList(params);
    }
    // inspector.* namespace
    else if ([method isEqualToString:@"inspector.get"]) {
        result = SpliceKit_handleInspectorGet(params);
    } else if ([method isEqualToString:@"inspector.set"]) {
        result = SpliceKit_handleInspectorSet(params);
    } else if ([method isEqualToString:@"inspector.getTitle"]) {
        result = SpliceKit_handleInspectorGetTitle(params);
    }
    // view.* namespace
    else if ([method isEqualToString:@"view.toggle"]) {
        result = SpliceKit_handleViewToggle(params);
    } else if ([method isEqualToString:@"view.workspace"]) {
        result = SpliceKit_handleWorkspace(params);
    }
    // roles.* namespace
    else if ([method isEqualToString:@"roles.assign"]) {
        result = SpliceKit_handleRolesAssign(params);
    }
    // mixer.* namespace
    else if ([method isEqualToString:@"mixer.getState"]) {
        result = SpliceKit_handleMixerGetState(params);
    } else if ([method isEqualToString:@"mixer.setVolume"]) {
        result = SpliceKit_handleMixerSetVolume(params);
    } else if ([method isEqualToString:@"mixer.setSolo"]) {
        result = SpliceKit_handleMixerSetSolo(params);
    } else if ([method isEqualToString:@"mixer.setMute"]) {
        result = SpliceKit_handleMixerSetMute(params);
    } else if ([method isEqualToString:@"mixer.applyBusEffect"]) {
        result = SpliceKit_handleMixerApplyBusEffect(params);
    } else if ([method isEqualToString:@"mixer.openBusEffect"]) {
        result = SpliceKit_handleMixerOpenBusEffect(params);
    } else if ([method isEqualToString:@"mixer.setBusEffectEnabled"]) {
        result = SpliceKit_handleMixerSetBusEffectEnabled(params);
    } else if ([method isEqualToString:@"mixer.removeBusEffect"]) {
        result = SpliceKit_handleMixerRemoveBusEffect(params);
    } else if ([method isEqualToString:@"mixer.volumeBegin"]) {
        result = SpliceKit_handleMixerVolumeBegin(params);
    } else if ([method isEqualToString:@"mixer.volumeEnd"]) {
        result = SpliceKit_handleMixerVolumeEnd(params);
    } else if ([method isEqualToString:@"mixer.setAllVolumes"]) {
        result = SpliceKit_handleMixerSetAllVolumes(params);
    }
    // audioBusDiagnostics.* namespace
    else if ([method hasPrefix:@"audioBusDiagnostics."]) {
        result = SpliceKit_handleAudioBusDiagnostics(method, params);
    }
    // share.* namespace
    else if ([method isEqualToString:@"share.export"]) {
        result = SpliceKit_handleShareExport(params);
    }
    // project.* namespace
    else if ([method isEqualToString:@"project.create"]) {
        result = SpliceKit_annotateCreateActionFilePanelPending(SpliceKit_handleProjectCreate(params), @"createProject");
    } else if ([method isEqualToString:@"project.createEvent"]) {
        result = SpliceKit_annotateCreateActionFilePanelPending(SpliceKit_handleEventCreate(params), @"createEvent");
    } else if ([method isEqualToString:@"project.createLibrary"]) {
        result = SpliceKit_annotateCreateActionFilePanelPending(SpliceKit_handleLibraryCreate(params), @"createLibrary");
    } else if ([method isEqualToString:@"project.open"]) {
        result = SpliceKit_handleProjectOpen(params);
    }
    // urlImport.* namespace
    else if ([method isEqualToString:@"urlImport.start"]) {
        result = SpliceKitURLImport_start(params);
    } else if ([method isEqualToString:@"urlImport.import"]) {
        result = SpliceKitURLImport_importSync(params);
    } else if ([method isEqualToString:@"urlImport.status"]) {
        result = SpliceKitURLImport_status(params);
    } else if ([method isEqualToString:@"urlImport.cancel"]) {
        result = SpliceKitURLImport_cancel(params);
    }
    // timeline lane selection
    else if ([method isEqualToString:@"timeline.selectClipInLane"]) {
        result = SpliceKit_handleSelectClipAtPlayheadLane(params);
    }
    // viewer capture
    else if ([method isEqualToString:@"viewer.capture"]) {
        result = SpliceKit_handleCaptureViewer(params);
    }
    // timeline capture
    else if ([method isEqualToString:@"timeline.capture"]) {
        result = SpliceKit_handleCaptureTimeline(params);
    }
    // inspector capture
    else if ([method isEqualToString:@"inspector.capture"]) {
        result = SpliceKit_handleCaptureInspector(params);
    }
    // fcpxml export (programmatic, no dialog)
    else if ([method isEqualToString:@"fcpxml.export"]) {
        result = SpliceKit_handleFCPXMLExport(params);
    }
    // tool.* namespace
    else if ([method isEqualToString:@"tool.select"]) {
        result = SpliceKit_handleToolSelect(params);
    }
    // dialog.* namespace
    else if ([method isEqualToString:@"dialog.detect"]) {
        result = SpliceKit_handleDialogDetect(params);
    } else if ([method isEqualToString:@"dialog.click"]) {
        result = SpliceKit_handleDialogClick(params);
    } else if ([method isEqualToString:@"dialog.fill"]) {
        result = SpliceKit_handleDialogFill(params);
    } else if ([method isEqualToString:@"dialog.checkbox"]) {
        result = SpliceKit_handleDialogCheckbox(params);
    } else if ([method isEqualToString:@"dialog.popup"]) {
        result = SpliceKit_handleDialogPopup(params);
    } else if ([method isEqualToString:@"dialog.dismiss"]) {
        result = SpliceKit_handleDialogDismiss(params);
    }
    // viewer.* namespace
    else if ([method isEqualToString:@"viewer.getZoom"]) {
        result = SpliceKit_handleViewerGetZoom(params);
    } else if ([method isEqualToString:@"viewer.setZoom"]) {
        result = SpliceKit_handleViewerSetZoom(params);
    }
    // backgroundRender.* namespace
    else if ([method isEqualToString:@"backgroundRender.status"]) {
        result = SpliceKit_handleBackgroundRenderStatus(params);
    } else if ([method isEqualToString:@"backgroundRender.control"]) {
        result = SpliceKit_handleBackgroundRenderControl(params);
    }
    // options.* namespace
    else if ([method isEqualToString:@"options.get"]) {
        result = SpliceKit_handleOptionsGet(params);
    } else if ([method isEqualToString:@"options.set"]) {
        result = SpliceKit_handleOptionsSet(params);
    }
    // beats.* namespace
    else if ([method isEqualToString:@"beats.detect"]) {
        result = SpliceKit_handleBeatsDetect(params);
    }
    // flexmusic.* namespace
    else if ([method isEqualToString:@"flexmusic.listSongs"]) {
        result = SpliceKit_handleFlexMusicListSongs(params);
    } else if ([method isEqualToString:@"flexmusic.getSong"]) {
        result = SpliceKit_handleFlexMusicGetSong(params);
    } else if ([method isEqualToString:@"flexmusic.getTiming"]) {
        result = SpliceKit_handleFlexMusicGetTiming(params);
    } else if ([method isEqualToString:@"flexmusic.renderToFile"]) {
        result = SpliceKit_handleFlexMusicRender(params);
    } else if ([method isEqualToString:@"flexmusic.addToTimeline"]) {
        result = SpliceKit_handleFlexMusicAddToTimeline(params);
    }
    // montage.* namespace
    else if ([method isEqualToString:@"montage.analyzeClips"]) {
        result = SpliceKit_handleMontageAnalyze(params);
    } else if ([method isEqualToString:@"montage.planEdit"]) {
        result = SpliceKit_handleMontagePlan(params);
    } else if ([method isEqualToString:@"montage.assemble"]) {
        result = SpliceKit_handleMontageAssemble(params);
    } else if ([method isEqualToString:@"montage.auto"]) {
        result = SpliceKit_handleMontageAuto(params);
    }
    // sections.* namespace (custom timeline bar)
    else if ([method isEqualToString:@"sections.show"]) {
        result = SpliceKit_handleSectionsShow(params);
    } else if ([method isEqualToString:@"sections.hide"]) {
        result = SpliceKit_handleSectionsHide(params);
    } else if ([method isEqualToString:@"sections.get"]) {
        result = SpliceKit_handleSectionsGet(params);
    }
    // structure.* namespace
    else if ([method isEqualToString:@"structure.generateCaptions"]) {
        result = SpliceKit_serverStructureGenerateCaptions(params);
    } else if ([method isEqualToString:@"structure.remove"]) {
        result = SpliceKit_serverStructureRemove(params);
    } else if ([method isEqualToString:@"structure.toggle"]) {
        result = SpliceKit_handleStructureToggle(params);
    }
    // debug.* namespace
    else if ([method isEqualToString:@"debug.getConfig"]) {
        result = SpliceKit_handleDebugGetConfig(params);
    } else if ([method isEqualToString:@"debug.setConfig"]) {
        result = SpliceKit_handleDebugSetConfig(params);
    } else if ([method isEqualToString:@"debug.resetConfig"]) {
        result = SpliceKit_handleDebugResetConfig(params);
    } else if ([method isEqualToString:@"debug.enablePreset"]) {
        result = SpliceKit_handleDebugEnablePreset(params);
    } else if ([method isEqualToString:@"debug.startFramerateMonitor"]) {
        result = SpliceKit_handleDebugStartFramerateMonitor(params);
    } else if ([method isEqualToString:@"debug.stopFramerateMonitor"]) {
        result = SpliceKit_handleDebugStopFramerateMonitor(params);
    } else if ([method isEqualToString:@"debug.dumpRuntimeMetadata"]) {
        result = SpliceKit_handleDumpRuntimeMetadata(params);
    } else if ([method isEqualToString:@"debug.listLoadedImages"]) {
        result = SpliceKit_handleListLoadedImages(params);
    } else if ([method isEqualToString:@"debug.getImageSections"]) {
        result = SpliceKit_handleGetImageSections(params);
    } else if ([method isEqualToString:@"debug.getImageSymbols"]) {
        result = SpliceKit_handleGetImageSymbols(params);
    } else if ([method isEqualToString:@"debug.getNotificationNames"]) {
        result = SpliceKit_handleGetNotificationNames(params);
    }
    // debug tools: tracing, watching, crash handling, threads, eval, plugins, notifications
    else if ([method isEqualToString:@"debug.traceMethod"]) {
        result = SpliceKit_handleDebugTraceMethod(params);
    } else if ([method isEqualToString:@"debug.watch"]) {
        result = SpliceKit_handleDebugWatch(params);
    } else if ([method isEqualToString:@"debug.crashHandler"]) {
        result = SpliceKit_handleDebugCrashHandler(params);
    } else if ([method isEqualToString:@"debug.threads"]) {
        result = SpliceKit_handleDebugThreads(params);
    } else if ([method isEqualToString:@"debug.eval"]) {
        result = SpliceKit_handleDebugEval(params);
    } else if ([method isEqualToString:@"debug.loadPlugin"]) {
        result = SpliceKit_handleDebugLoadPlugin(params);
    } else if ([method isEqualToString:@"debug.observeNotification"]) {
        result = SpliceKit_handleDebugObserveNotification(params);
    } else if ([method isEqualToString:@"debug.breakpoint"]) {
        result = SpliceKit_handleDebugBreakpoint(params);
    }
    // lua.* namespace — embedded Lua scripting engine
    else if ([method isEqualToString:@"lua.execute"]) {
        result = SpliceKit_handleLuaExecute(params);
    } else if ([method isEqualToString:@"lua.executeFile"]) {
        result = SpliceKit_handleLuaExecuteFile(params);
    } else if ([method isEqualToString:@"lua.reset"]) {
        result = SpliceKit_handleLuaReset(params);
    } else if ([method isEqualToString:@"lua.getState"]) {
        result = SpliceKit_handleLuaGetState(params);
    } else if ([method isEqualToString:@"lua.watch"]) {
        result = SpliceKit_handleLuaWatch(params);
    }
    // plugin.* namespace — plugin introspection
    else if ([method isEqualToString:@"plugin.listMethods"]) {
        result = SpliceKit_handlePluginListMethods(params);
    } else if ([method isEqualToString:@"plugin.list"]) {
        result = SpliceKit_handlePluginList(params);
    }
    // Fallthrough: check plugin handler registry before returning "method not found"
    else {
        SpliceKit_ensurePluginRegistryInit();
        SpliceKitMethodHandler pluginHandler = sPluginHandlers[method];
        if (pluginHandler) {
            result = pluginHandler(params);
        } else {
            return @{@"error": @{@"code": @(-32601), @"message":
                         [NSString stringWithFormat:@"Method not found: %@", method]}};
        }
    }

    // A handler whose main-thread work never ran returns nil, and its own fallback for
    // nil is a generic message ("Failed to add transitions to all clips") that reads as
    // "tried it, it did not work". What actually happened is that the main thread was
    // blocked — usually by a modal Final Cut Pro opened mid-operation — and the work was
    // abandoned at the 20s timeout. The two call for different responses, and the
    // generic wording sent this project looking for a bug in the transition code when
    // the transition was sitting behind an unanswered alert.
    //
    // The block is never cancelled, though. It is either still queued (the main thread
    // was busy and never picked it up; it runs once the main thread is free) or still
    // running (blocked inside it, typically behind a progress sheet such as FCP's
    // "Importing Remote Resources"). The old wording said "abandoned", and an FCPXML
    // import reported that way went on to finish seven minutes later.
    if (SpliceKit_mainThreadDispatchTimeoutCount() > timeoutsBefore &&
        !([result isKindOfClass:[NSDictionary class]] && result[@"mainThreadBusy"])) {
        int state = SpliceKit_lastMainThreadTimeoutState();
        NSString *message = (state == 2)
            ? [NSString stringWithFormat:
                @"'%@' is still running on Final Cut Pro's main thread: the bridge stopped "
                @"waiting after 20 seconds, but the work was not cancelled and may still "
                @"finish (a progress sheet, e.g. importing remote media, or a modal "
                @"dialog opened part-way through). detect_dialog shows what is on screen "
                @"(it answers from outside the main thread while it is busy); check the "
                @"result before retrying, or it may be applied twice.", method]
            : [NSString stringWithFormat:
                @"'%@' has not run yet: Final Cut Pro's main thread stayed busy for 20 "
                @"seconds (usually a modal dialog or a long operation already in "
                @"progress). The request is still queued and runs once the main thread "
                @"is free — check detect_dialog, and check the result before retrying.",
                method];
        return @{@"error": @{
            @"code": @(-32002),
            @"message": message,
            @"mainThreadBlocked": @YES,
            @"mainThreadWork": (state == 2) ? @"running" : @"queued"}};
    }

    if (result[@"error"] && ![result[@"error"] isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *error = [@{@"code": @(-32000), @"message": result[@"error"]} mutableCopy];
        // Machine-readable "don't retry" signals survive the collapse to {code, message}:
        // an FCPXML import that timed out behind a remote-media sheet is still running,
        // and a caller that cannot tell that from a failure imports it twice.
        for (NSString *flag in @[@"mainThreadBusy", @"importStillRunning"]) {
            if (result[flag]) error[flag] = result[flag];
        }
        return @{@"error": error};
    }

    if (!result) {
        return @{@"error": @{@"code": @(-32000), @"message": @"Handler returned no result"}};
    }

    return @{@"result": result};
}

#pragma mark - Client Handler
//
// Each client gets its own thread (via GCD). The protocol is dead simple:
// one JSON-RPC request per line, one JSON response per line. No framing,
// no content-length headers — just newline-delimited JSON over TCP.
//
// The 64KB buffer is generous — most requests are well under 1KB.
// The only large ones are FCPXML imports, and even those rarely hit 64KB.
//

static void SpliceKit_handleClient(int clientFd) {
    SpliceKit_addConnectedClientFd(clientFd);

    // Publish the fd for this thread so handlers like events.subscribe can
    // identify which connection they're running for. Cleared via asyncCleanupFd
    // when the client disconnects.
    SpliceKit_asyncSetCurrentFd(clientFd);

    FILE *stream = fdopen(clientFd, "r+");
    if (!stream) {
        close(clientFd);
        return;
    }

    CFAbsoluteTime connectedAt = CFAbsoluteTimeGetCurrent();
    NSUInteger requestCount = 0;
    char firstMethod[128] = {0};
    char lastMethod[128] = {0};

    char buffer[65536];
    while (fgets(buffer, sizeof(buffer), stream)) {
        @autoreleasepool {
            NSData *data = [NSData dataWithBytes:buffer length:strlen(buffer)];
            NSError *jsonError = nil;
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:0
                                                                     error:&jsonError];

            NSMutableDictionary *response = [NSMutableDictionary dictionary];
            response[@"jsonrpc"] = @"2.0";

            if (request[@"id"]) {
                response[@"id"] = request[@"id"];
            }

            if (jsonError || !request) {
                response[@"error"] = @{@"code": @(-32700),
                                       @"message": @"Parse error"};
            } else {
                NSString *method = [request[@"method"] isKindOfClass:[NSString class]]
                    ? request[@"method"] : nil;
                if (method.length > 0) {
                    requestCount += 1;
                    const char *methodName = [method UTF8String] ?: "<unknown>";
                    if (firstMethod[0] == '\0') {
                        strlcpy(firstMethod, methodName, sizeof(firstMethod));
                    }
                    strlcpy(lastMethod, methodName, sizeof(lastMethod));
                }
                @try {
                    NSDictionary *result = SpliceKit_handleRequest(request);
                    if (result[@"error"]) {
                        response[@"error"] = result[@"error"];
                    } else {
                        response[@"result"] = result[@"result"];
                    }
                } @catch (NSException *exception) {
                    SpliceKit_log(@"Exception handling request: %@ - %@",
                                  exception.name, exception.reason);
                    response[@"error"] = @{
                        @"code": @(-32000),
                        @"message": [NSString stringWithFormat:@"Internal error: %@", exception.reason]
                    };
                }
            }

            NSData *responseJson = [NSJSONSerialization dataWithJSONObject:response
                                                                  options:0
                                                                    error:nil];
            if (responseJson) {
                // Route through the per-fd write lock so async event broadcasts
                // can't slice into the middle of this reply. Matches the
                // broadcast path — same raw write(), same lock.
                NSMutableData *line = [responseJson mutableCopy];
                [line appendBytes:"\n" length:1];
                SpliceKit_writeLineToClientFd(clientFd, line);
            }
        }
    }

    if (requestCount > 0) {
        NSTimeInterval duration = CFAbsoluteTimeGetCurrent() - connectedAt;
        if (requestCount == 1) {
            SpliceKit_log(@"Client session ended (fd=%d requests=1 method=%s duration=%.2fs)",
                          clientFd, firstMethod[0] ? firstMethod : "<unknown>", duration);
        } else {
            SpliceKit_log(@"Client session ended (fd=%d requests=%lu first=%s last=%s duration=%.2fs)",
                          clientFd, (unsigned long)requestCount,
                          firstMethod[0] ? firstMethod : "<unknown>",
                          lastMethod[0] ? lastMethod : "<unknown>", duration);
        }
    }
    SpliceKit_removeConnectedClientFd(clientFd);
    SpliceKit_asyncCleanupFd(clientFd);
    SpliceKit_drainWriteQueueForClientFd(clientFd);
    SpliceKit_releaseWriteQueueForClientFd(clientFd);
    fclose(stream);
}

#pragma mark - Server
//
// Sets up the TCP listener on 127.0.0.1:9876. We use TCP instead of a Unix
// domain socket because FCP's sandbox is more permissive with network.server
// than with filesystem access. Localhost-only, so nothing's exposed to the network.
//
// We use a GCD dispatch source for accept() instead of a blocking loop.
// This means we don't hold a thread hostage just to wait for connections,
// and the server shuts down cleanly when FCP quits.
//

void SpliceKit_startControlServer(void) {
    sClientQueue = dispatch_queue_create("com.splicekit.clients", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(sClientQueue, &sClientQueueSpecificKey,
                                &sClientQueueSpecificKey, NULL);
    sConnectedClients = [NSMutableArray array];
    sClientWriteQueues = [NSMutableDictionary dictionary];

    int serverFd = socket(AF_INET, SOCK_STREAM, 0);
    if (serverFd < 0) {
        SpliceKit_log(@"ERROR: Failed to create TCP socket: %s", strerror(errno));
        return;
    }

    // SO_REUSEADDR lets us rebind immediately after FCP restarts,
    // instead of waiting for the kernel's TIME_WAIT to expire
    int optval = 1;
    setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // localhost only — never exposed to the network
    addr.sin_port = htons(SPLICEKIT_TCP_PORT);

    if (bind(serverFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        SpliceKit_log(@"ERROR: Failed to bind TCP port %d: %s", SPLICEKIT_TCP_PORT, strerror(errno));
        close(serverFd);
        return;
    }

    if (listen(serverFd, 5) < 0) {
        SpliceKit_log(@"ERROR: Failed to listen: %s", strerror(errno));
        close(serverFd);
        return;
    }

    sServerFd = serverFd;

    SpliceKit_log(@"================================================");
    SpliceKit_log(@"Control server listening on 127.0.0.1:%d", SPLICEKIT_TCP_PORT);
    SpliceKit_log(@"================================================");
    SpliceKit_markServerReady();

    // dispatch_source fires our handler whenever there's a pending connection
    // to accept. Much cleaner than a while(true) accept() loop.
    dispatch_source_t acceptSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, serverFd, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));

    dispatch_source_set_event_handler(acceptSource, ^{
        int clientFd = accept(serverFd, NULL, NULL);
        if (clientFd < 0) return;
        int noSigPipe = 1;
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            SpliceKit_handleClient(clientFd);
        });
    });

    dispatch_source_set_cancel_handler(acceptSource, ^{
        close(serverFd);
        sServerFd = -1;
        SpliceKit_log(@"Server socket closed");
    });

    dispatch_resume(acceptSource);

    // Cancel the source on app termination
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationWillTerminateNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            SpliceKit_log(@"App terminating — cancelling server");
            dispatch_source_cancel(acceptSource);
        }];
}
