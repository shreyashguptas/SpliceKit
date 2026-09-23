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
