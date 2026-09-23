//
//  SpliceKitAsync.m
//  Async dispatch with correlation IDs + per-connection event subscriptions.
//
//  Exposes three RPC endpoints:
//    events.subscribe      — per-fd allowlist of event types (wildcards supported)
//    events.unsubscribe    — drop the allowlist
//    async.status          — list in-flight async operations
//
//  Also provides C helpers used by the dispatcher:
//    SpliceKit_asyncSetCurrentFd(int fd)       — set the fd for the thread
//    SpliceKit_asyncCleanupFd(int fd)          — drop subscription state for a closed client
//    SpliceKit_asyncDispatch(method, params, handler)
//                                              — run handler on worker queue, broadcast
//                                                `command.completed` event on done
//    SpliceKit_asyncFdWantsEvent(fd, eventType)
//                                              — broadcast-time filter hook
//
//  Design: SpliceKit_broadcastEvent() already writes to every connected fd.
//  We wrap that with a per-fd allowlist check before writing. Default is
//  "deliver everything" so existing clients see no behavior change.
//

#import <Foundation/Foundation.h>
#import <pthread.h>
#import "SpliceKit.h"

static dispatch_queue_t sAsyncQueue = NULL;
static dispatch_queue_t sStateQueue = NULL;

static NSMutableDictionary<NSString *, NSDictionary *> *sInFlight = nil;
// fd -> NSSet of patterns. Missing fd == deliver everything (backwards compat).
static NSMutableDictionary<NSNumber *, NSSet<NSString *> *> *sFdSubscriptions = nil;

static pthread_key_t sCurrentFdKey;
static dispatch_once_t sKeyOnce;

static void SpliceKit_asyncInitKey(void) {
    dispatch_once(&sKeyOnce, ^{
        pthread_key_create(&sCurrentFdKey, NULL);
    });
}

void SpliceKit_asyncSetCurrentFd(int fd) {
    SpliceKit_asyncInitKey();
    // Store fd+1 so a zero-valued fd isn't mistaken for "not set"
    pthread_setspecific(sCurrentFdKey, (void *)(intptr_t)(fd + 1));
}

int SpliceKit_asyncCurrentFd(void) {
    SpliceKit_asyncInitKey();
    intptr_t v = (intptr_t)pthread_getspecific(sCurrentFdKey);
    return v == 0 ? -1 : (int)(v - 1);
}

void SpliceKit_asyncCleanupFd(int fd) {
    SpliceKit_asyncInitKey();
    if (SpliceKit_asyncCurrentFd() == fd) {
        pthread_setspecific(sCurrentFdKey, NULL);
    }
    if (!sStateQueue) return;
    dispatch_async(sStateQueue, ^{
        [sFdSubscriptions removeObjectForKey:@(fd)];
    });
}

static BOOL SpliceKit_matchesPattern(NSString *eventType, NSString *pattern) {
    if ([pattern isEqualToString:@"*"]) return YES;
    if ([pattern isEqualToString:eventType]) return YES;
    if ([pattern hasSuffix:@".*"]) {
        NSString *prefix = [pattern substringToIndex:pattern.length - 1];  // keep trailing dot
        return [eventType hasPrefix:prefix];
    }
    return NO;
}

BOOL SpliceKit_asyncFdWantsEvent(int fd, NSString *eventType) {
    if (!sStateQueue || !sFdSubscriptions || fd < 0) return NO;
    // Default: no events unless the client explicitly subscribed.
    //
    // Previously we delivered all events to any fd without a subscription on
    // the theory of "backwards compat" — but the MCP bridge (and any other
    // single-socket JSON-RPC client) reads frames by newline and assumes the
    // next frame is the response to the pending request. An unsolicited
    // `method:"event"` frame gets consumed in place of the real response,
    // poisons the buffer, and desyncs every subsequent tool call.
    //
    // Clients that want events must now call events.subscribe first. That's
    // consistent with the JSON-RPC spec (notifications are opt-in), and it
    // matches how the debug tracing / observe-notification paths already
    // gate themselves.
    __block BOOL wants = NO;
    dispatch_sync(sStateQueue, ^{
        NSSet *subs = sFdSubscriptions[@(fd)];
        if (!subs) return;
        for (NSString *pattern in subs) {
            if (SpliceKit_matchesPattern(eventType ?: @"", pattern)) { wants = YES; break; }
        }
    });
    return wants;
}

static NSString *SpliceKit_asyncNewCorrelationId(void) {
    return [[NSUUID UUID] UUIDString];
}

NSDictionary *SpliceKit_asyncDispatch(NSString *method,
                                       NSDictionary *params,
                                       NSDictionary *(^handler)(NSDictionary *)) {
    if (!sAsyncQueue) {
        // Not initialized — run synchronously rather than silently dropping.
        return handler(params);
    }
    NSString *corrId = SpliceKit_asyncNewCorrelationId();
    NSTimeInterval started = [[NSDate date] timeIntervalSince1970];

    dispatch_async(sStateQueue, ^{
        sInFlight[corrId] = @{@"method": method, @"started": @(started)};
    });

    NSDictionary *(^safeHandler)(NSDictionary *) = [handler copy];
    dispatch_async(sAsyncQueue, ^{
        NSDictionary *result = nil;
        NSString *errorMsg = nil;
        @try {
            result = safeHandler(params) ?: @{};
        } @catch (NSException *exc) {
            errorMsg = [NSString stringWithFormat:@"%@: %@", exc.name, exc.reason];
        }
        NSTimeInterval finished = [[NSDate date] timeIntervalSince1970];

        dispatch_async(sStateQueue, ^{
            [sInFlight removeObjectForKey:corrId];
        });

        // Normal RPC errors come back in the result dict as {"error": "..."}
        // — they're not ObjC exceptions. Promote those to status:error too,
        // otherwise clients consuming command.completed have to poke at the
        // nested result payload to discover the command failed.
        id resultError = nil;
        if (!errorMsg && [result isKindOfClass:[NSDictionary class]]) {
            resultError = result[@"error"];
        }

        NSMutableDictionary *evt = [NSMutableDictionary dictionary];
        evt[@"type"] = @"command.completed";
        evt[@"correlation_id"] = corrId;
        evt[@"method"] = method;
        evt[@"duration_ms"] = @((int)((finished - started) * 1000));
        if (errorMsg) {
            evt[@"status"] = @"error";
            evt[@"error"] = errorMsg;
        } else if (resultError) {
            evt[@"status"] = @"error";
            evt[@"error"] = resultError;
            // Keep the original result too so clients that want the full payload
            // (e.g. partial results alongside an error) can still access it.
            evt[@"result"] = result;
        } else {
            evt[@"status"] = @"ok";
            evt[@"result"] = result;
        }
        SpliceKit_broadcastEvent(evt);
    });

    return @{
        @"status": @"dispatched",
        @"correlation_id": corrId,
        @"method": method,
        @"started": @(started),
    };
}

static NSDictionary *SpliceKit_handleAsyncStatus(NSDictionary *params) {
    __block NSDictionary *snapshot = @{};
    dispatch_sync(sStateQueue, ^{
        snapshot = [sInFlight copy];
    });
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableArray *ops = [NSMutableArray array];
    for (NSString *corrId in snapshot) {
        NSDictionary *info = snapshot[corrId];
        [ops addObject:@{
            @"correlation_id": corrId,
            @"method": info[@"method"] ?: @"",
            @"elapsed_ms": @((int)((now - [info[@"started"] doubleValue]) * 1000)),
        }];
    }
    return @{@"in_flight": ops, @"count": @(ops.count)};
}

static NSDictionary *SpliceKit_handleEventsSubscribe(NSDictionary *params) {
    int fd = SpliceKit_asyncCurrentFd();
    if (fd < 0) {
        return @{@"error": @"no connection context — events.subscribe must be called over TCP"};
    }
    NSArray *patterns = params[@"patterns"];
    NSSet *set = nil;
    if ([patterns isKindOfClass:[NSArray class]] && patterns.count > 0) {
        set = [NSSet setWithArray:patterns];
    } else {
        set = [NSSet setWithObject:@"*"];
    }
    dispatch_sync(sStateQueue, ^{
        sFdSubscriptions[@(fd)] = set;
    });
    return @{
        @"status": @"subscribed",
        @"patterns": [set allObjects],
        @"fd": @(fd),
    };
}

static NSDictionary *SpliceKit_handleEventsUnsubscribe(NSDictionary *params) {
    int fd = SpliceKit_asyncCurrentFd();
    if (fd < 0) return @{@"status": @"unsubscribed"};
    dispatch_sync(sStateQueue, ^{
        [sFdSubscriptions removeObjectForKey:@(fd)];
    });
    return @{@"status": @"unsubscribed", @"fd": @(fd)};
}

static NSDictionary *SpliceKit_handleEventsStatus(NSDictionary *params) {
    int fd = SpliceKit_asyncCurrentFd();
    __block NSSet *subs = nil;
    dispatch_sync(sStateQueue, ^{
        subs = [sFdSubscriptions[@(fd)] copy];
    });
    return @{
        @"fd": @(fd),
        @"subscribed": @(subs != nil),
        @"patterns": subs ? [subs allObjects] : @[@"*"],
    };
}

void SpliceKit_installAsync(void) {
    sAsyncQueue = dispatch_queue_create("com.splicekit.async",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT,
                                                 QOS_CLASS_USER_INITIATED, 0));
    sStateQueue = dispatch_queue_create("com.splicekit.async.state", DISPATCH_QUEUE_SERIAL);
    sInFlight = [NSMutableDictionary dictionary];
    sFdSubscriptions = [NSMutableDictionary dictionary];

    SpliceKit_registerPluginMethod(@"events.subscribe",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleEventsSubscribe(params); },
        @{@"safety": @"safe",
          @"summary": @"Subscribe this connection to an event pattern allowlist. Patterns: exact type, or 'prefix.*'. Default '*'.",
          @"source": @"builtin"});

    SpliceKit_registerPluginMethod(@"events.unsubscribe",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleEventsUnsubscribe(params); },
        @{@"safety": @"safe",
          @"summary": @"Remove this connection's event allowlist (reverts to deliver-everything).",
          @"source": @"builtin"});

    SpliceKit_registerPluginMethod(@"events.status",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleEventsStatus(params); },
        @{@"safety": @"safe",
          @"summary": @"Report this connection's current event subscription state.",
          @"source": @"builtin"});

    SpliceKit_registerPluginMethod(@"async.status",
        ^NSDictionary *(NSDictionary *params) { return SpliceKit_handleAsyncStatus(params); },
        @{@"safety": @"safe",
          @"summary": @"List in-flight async operations with elapsed time.",
          @"source": @"builtin"});

    SpliceKit_log(@"[Async] Registered events.subscribe/unsubscribe/status and async.status");
}
