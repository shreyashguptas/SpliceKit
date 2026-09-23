//
//  SpliceKitServerUtil.m
//  SpliceKit - The object handle table (obj_N strings standing in for ObjC objects
//  across the bridge) and the return-value serialization shared by the handlers.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Object Handle System
//
// JSON can't hold ObjC object pointers, so we assign each object a string handle
// like "obj_42" and keep it alive in this dictionary. The client passes handles
// back in subsequent requests to reference the same object.
//
// There's a hard cap to prevent memory leaks from clients that never clean up.
// When we hit the limit, we dump everything and start fresh. Not perfect, but
// it beats leaking FCP's entire object graph.
//

NSMutableDictionary<NSString *, id> *sHandleMap = nil;
static NSMutableDictionary<NSString *, NSString *> *sHandlePointerMap = nil;
static uint64_t sHandleCounter = 0;

NSString *SpliceKit_handlePointerKey(id object) {
    if (!object) return nil;
    return [NSString stringWithFormat:@"%p", (__bridge void *)object];
}

// When this dylib was loaded into the process (injected at launch, so effectively the
// process start); bridge_status reports the seconds since as process_uptime_seconds.
// Measured on the monotonic clock (-[NSProcessInfo systemUptime]), so a clock change
// or NTP step does not move it.
static NSTimeInterval sSpliceKitLoadedAtUptime = -1;
__attribute__((constructor)) static void SpliceKit_recordLoadTime(void) {
    sSpliceKitLoadedAtUptime = [[NSProcessInfo processInfo] systemUptime];
}
double SpliceKit_secondsSinceLoad(void) {
    if (sSpliceKitLoadedAtUptime < 0) return 0.0;
    double d = [[NSProcessInfo processInfo] systemUptime] - sSpliceKitLoadedAtUptime;
    return d > 0 ? d : 0.0;
}

// Incremented every time the handle table is cleared (see SPLICEKIT_MAX_HANDLES below).
// Callers that compare handles across two reads check it to know the comparison is valid.
static uint64_t sHandleGeneration = 0;

uint64_t SpliceKit_handleGeneration(void) {
    return sHandleGeneration;
}

NSString *SpliceKit_storeHandle(id object) {
    if (!object) return nil;
    if (!sHandleMap) sHandleMap = [NSMutableDictionary dictionary];
    if (!sHandlePointerMap) sHandlePointerMap = [NSMutableDictionary dictionary];

    NSString *pointerKey = SpliceKit_handlePointerKey(object);
    NSString *existingHandle = pointerKey ? sHandlePointerMap[pointerKey] : nil;
    if (existingHandle) {
        id existingObject = sHandleMap[existingHandle];
        if (existingObject == object) {
            return existingHandle;
        }
        if (!existingObject && pointerKey) {
            [sHandlePointerMap removeObjectForKey:pointerKey];
        }
    }

    if (sHandleMap.count >= SPLICEKIT_MAX_HANDLES) {
        SpliceKit_log(@"Handle limit reached (%d), clearing old handles", SPLICEKIT_MAX_HANDLES);
        [sHandleMap removeAllObjects];
        [sHandlePointerMap removeAllObjects];
        sHandleGeneration++;
    }
    sHandleCounter++;
    NSString *handle = [NSString stringWithFormat:@"obj_%llu", sHandleCounter];
    sHandleMap[handle] = object;
    if (pointerKey) {
        sHandlePointerMap[pointerKey] = handle;
    }
    return handle;
}

id SpliceKit_resolveHandle(NSString *handleId) {
    if (!handleId || !sHandleMap) return nil;
    return sHandleMap[handleId];
}

void SpliceKit_releaseHandle(NSString *handleId) {
    id object = sHandleMap[handleId];
    NSString *pointerKey = SpliceKit_handlePointerKey(object);
    if (pointerKey && [sHandlePointerMap[pointerKey] isEqualToString:handleId]) {
        [sHandlePointerMap removeObjectForKey:pointerKey];
    }
    [sHandleMap removeObjectForKey:handleId];
}

void SpliceKit_releaseAllHandles(void) {
    [sHandleMap removeAllObjects];
    [sHandlePointerMap removeAllObjects];
}

NSDictionary *SpliceKit_listHandles(void) {
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *key in sHandleMap) {
        id obj = sHandleMap[key];
        [entries addObject:@{
            @"handle": key,
            @"class": NSStringFromClass([obj class]) ?: @"<unknown>",
            @"description": [[obj description] substringToIndex:
                MIN((NSUInteger)200, [[obj description] length])]
        }];
    }
    return @{@"handles": entries, @"count": @(sHandleMap.count)};
}

#pragma mark - Type Helpers

NSDictionary *SpliceKit_serializeCMTime(SpliceKit_CMTime t) {
    double seconds = (t.timescale > 0) ? (double)t.value / t.timescale : 0;
    return @{@"value": @(t.value), @"timescale": @(t.timescale), @"seconds": @(seconds)};
}

// Takes an NSInvocation that's already been invoked and serializes whatever it returned
// into a JSON-safe dictionary. Handles objects, primitives, BOOL, CMTime structs, etc.
// If returnHandle is YES, objects get stored in the handle system instead of stringified.
id SpliceKit_serializeReturnValue(NSInvocation *invocation, BOOL returnHandle) {
    const char *retType = [[invocation methodSignature] methodReturnType];
    if (retType[0] == 'v') return @{@"result": @"void"};

    if (retType[0] == '@') {
        id __unsafe_unretained retObj = nil;
        [invocation getReturnValue:&retObj];
        if (!retObj) return @{@"result": [NSNull null]};
        if (returnHandle) {
            NSString *h = SpliceKit_storeHandle(retObj);
            return @{@"handle": h, @"class": NSStringFromClass([retObj class]),
                     @"description": [[retObj description] substringToIndex:
                         MIN((NSUInteger)500, [[retObj description] length])]};
        }
        return @{@"result": [[retObj description] substringToIndex:
                     MIN((NSUInteger)2000, [[retObj description] length])],
                 @"class": NSStringFromClass([retObj class])};
    }
    if (retType[0] == 'B' || retType[0] == 'c') {
        BOOL val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'q' || retType[0] == 'l') {
        long long val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'i') {
        int val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'Q' || retType[0] == 'L') {
        unsigned long long val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'd') {
        double val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    if (retType[0] == 'f') {
        float val; [invocation getReturnValue:&val];
        return @{@"result": @(val)};
    }
    // CMTime struct
    if (strstr(retType, "CMTime") || (retType[0] == '{' && strstr(retType, "qiIq"))) {
        SpliceKit_CMTime val;
        if ([[invocation methodSignature] methodReturnLength] == sizeof(SpliceKit_CMTime)) {
            [invocation getReturnValue:&val];
            return @{@"result": SpliceKit_serializeCMTime(val)};
        }
    }
    return @{@"result": @"<unsupported return type>", @"returnType": @(retType)};
}
