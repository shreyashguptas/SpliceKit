//
//  SpliceKitServer.m
//  The brain of SpliceKit — JSON-RPC 2.0 server that listens on TCP 127.0.0.1:9876.
//
//  This file holds the server itself: client management and event broadcast, the
//  request dispatcher SpliceKit_handleRequest, the per-client handler thread and the
//  socket listener. Every handler lives in a companion file: SpliceKitServer*.m for
//  the bridge domains (timeline, FCPXML, effects, mixer, dialogs, music, ...) and
//  SpliceKitFeature*.m for the option-controlled feature swizzles. Declarations they
//  share are in SpliceKitServerInternal.h.
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

#define SPLICEKIT_TCP_PORT 9876

static int sServerFd = -1;

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

// Built-in RPC handlers, name -> function, from SpliceKitRPCTable.def. Rows with a NULL
// handler are dispatched explicitly in SpliceKit_handleRequest and are left out here.
typedef NSDictionary *(*SpliceKitRPCHandler)(NSDictionary *params);

static SpliceKitRPCHandler SpliceKit_builtinRPCHandler(NSString *method) {
    static NSDictionary<NSString *, NSValue *> *handlers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static const struct { const char *name; SpliceKitRPCHandler handler; } rows[] = {
#define SK_RPC(name, handler, safety, summary) { name, handler },
#include "SpliceKitRPCTable.def"
#undef SK_RPC
        };
        NSMutableDictionary<NSString *, NSValue *> *table =
            [NSMutableDictionary dictionaryWithCapacity:sizeof(rows) / sizeof(rows[0])];
        for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
            if (!rows[i].handler) continue;
            table[@(rows[i].name)] = [NSValue valueWithPointer:(const void *)rows[i].handler];
        }
        handlers = [table copy];
    });
    return (SpliceKitRPCHandler)[handlers[method] pointerValue];
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

    // Built-in methods: the rows of SpliceKitRPCTable.def. The ones below do more than
    // `result = handler(params)` and are dispatched here; their rows carry a NULL handler
    // and only supply metadata. Method names are unique, so the order of these checks
    // does not change which branch a name takes.
    SpliceKitRPCHandler builtinHandler = NULL;
    if ([method isEqualToString:@"timeline.action"]) {
        result = SpliceKit_annotatePendingDialog(SpliceKit_handleTimelineAction(params),
            [params[@"action"] isKindOfClass:[NSString class]] ? params[@"action"] : @"");
    } else if ([method isEqualToString:@"transcript.clear"]) {
        SpliceKit_executeOnMainThread(^{
            [[SpliceKitTranscriptPanel sharedPanel] clearTranscript];
        });
        result = @{@"status": @"ok", @"message": @"Transcript cleared from memory and disk cache."};
    } else if ([method isEqualToString:@"project.create"]) {
        result = SpliceKit_annotateCreateActionFilePanelPending(SpliceKit_handleProjectCreate(params), @"createProject");
    } else if ([method isEqualToString:@"project.createEvent"]) {
        result = SpliceKit_annotateCreateActionFilePanelPending(SpliceKit_handleEventCreate(params), @"createEvent");
    } else if ([method isEqualToString:@"project.createLibrary"]) {
        result = SpliceKit_annotateCreateActionFilePanelPending(SpliceKit_handleLibraryCreate(params), @"createLibrary");
    } else if ((builtinHandler = SpliceKit_builtinRPCHandler(method))) {
        result = builtinHandler(params);
    }
    // audioBusDiagnostics.* namespace (prefix route; no table row)
    else if ([method hasPrefix:@"audioBusDiagnostics."]) {
        result = SpliceKit_handleAudioBusDiagnostics(method, params);
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
