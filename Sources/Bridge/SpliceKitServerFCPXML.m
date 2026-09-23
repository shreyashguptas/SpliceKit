//
//  SpliceKitServerFCPXML.m
//  SpliceKit - FCPXML in and out: fcpxml.import (sync and async jobs), the pasteboard
//  importer, the FCPXML direct-paste swizzle, and programmatic FCPXML export.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - FCPXML Import
//
// Two ways to import FCPXML:
// 1. Pasteboard path (preferred): Write XML to the pasteboard, create an
//    FFXMLTranslationTask, and import directly into the current library.
//    No dialogs, no user interaction needed.
// 2. File path (fallback): Write XML to a temp file and open it via NSWorkspace.
//    This triggers FCP's normal import flow which may show a library picker dialog.
//

NSDictionary *SpliceKit_handlePasteboardImportXML(NSDictionary *params);

// Convert .otio file → FCPXML via the native ObjC converter.
// This produces better FCPXML than the Python adapter (correct transitions,
// titles, connected clips, exact frame-rate math).
NSDictionary *SpliceKit_handleOTIOToFCPXML(NSDictionary *params) {
    NSString *path = params[@"path"];
    if (!path) return @{@"error": @"path parameter required (path to .otio file)"};

    // If raw JSON provided instead of file, write to temp file
    NSString *otioJson = params[@"otio_json"];
    NSString *tmpPath = nil;
    if (otioJson) {
        tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_otio_bridge.otio"];
        NSData *data = [otioJson dataUsingEncoding:NSUTF8StringEncoding];
        [data writeToFile:tmpPath atomically:YES];
        path = tmpPath;
    }

    NSString *eventName = [params[@"event"] isKindOfClass:[NSString class]] ? params[@"event"] : nil;
    NSString *fcpxml = SpliceKit_otioToFCPXMLInEvent(path, eventName);

    // Clean up temp file
    if (tmpPath) {
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
    }

    if (!fcpxml) {
        return @{@"error": @"Failed to convert .otio to FCPXML"};
    }
    return @{@"status": @"ok", @"fcpxml": fcpxml};
}

NSDictionary *SpliceKit_handleFCPXMLImportAsync(NSDictionary *params);

// A library's bundle URL. FFLibrary answers -URL; the lowercase -url the import code
// used to ask for answers nothing, so the target library was never matched by path
// and setLibraryURL: was never called.
static NSURL *SpliceKit_libraryBundleURL(id library) {
    for (NSString *name in @[@"URL", @"url", @"fileURL"]) {
        SEL sel = NSSelectorFromString(name);
        if (![library respondsToSelector:sel]) continue;
        @try {
            id u = ((id (*)(id, SEL))objc_msgSend)(library, sel);
            if ([u isKindOfClass:[NSURL class]]) return u;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// The <library location="file:///.../X.fcpbundle/"> an FCPXML document names, as a
// standardized filesystem path, or nil.
static NSString *SpliceKit_fcpxmlLibraryLocation(NSString *xml) {
    if (xml.length == 0) return nil;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"<library\\b[^>]*\\blocation\\s*=\\s*\"([^\"]+)\""
                             options:0 error:nil];
    // Only the head of the document: <library> encloses everything else.
    NSRange head = NSMakeRange(0, MIN(xml.length, (NSUInteger)65536));
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:head];
    if (!m) return nil;
    NSString *raw = [xml substringWithRange:[m rangeAtIndex:1]];
    raw = [raw stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    NSString *path = SpliceKit_filesystemPathFromParam(raw);
    return path.length ? [path stringByStandardizingPath] : nil;
}

NSDictionary *SpliceKit_handleFCPXMLImport(NSDictionary *params) {
    // async=true: start the import and return a job id at once (see
    // SpliceKit_handleFCPXMLImportAsync). An import whose media sits on a network
    // volume keeps FCP's "Importing Remote Resources" sheet up for minutes, far past
    // the 20 s the bridge waits for the main thread.
    if ([params[@"async"] boolValue]) {
        return SpliceKit_handleFCPXMLImportAsync(params);
    }

    NSString *xml = [params[@"xml"] isKindOfClass:[NSString class]] ? params[@"xml"] : nil;
    NSString *sourcePath = nil;
    if (!xml && params[@"path"]) {
        // Read the document on the Mac side, so a 30 KB FCPXML does not have to
        // travel inline through the MCP client.
        sourcePath = SpliceKit_filesystemPathFromParam(params[@"path"]);
        NSError *readError = nil;
        xml = sourcePath ? [NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding
                                                        error:&readError] : nil;
        if (!xml) {
            return @{@"error": [NSString stringWithFormat:@"Could not read FCPXML at %@: %@",
                                 sourcePath ?: params[@"path"],
                                 readError.localizedDescription ?: @"not a readable file"]};
        }
    }
    if (!xml) return @{@"error": @"xml or path parameter required (path: a .fcpxml file, plain path or file:// URL)"};
    // With a path the caller has not seen the XML go by; import it the safe way
    // unless told otherwise (the file route can open FCP's "which library?" chooser).
    BOOL useInternal = params[@"internal"] ? [params[@"internal"] boolValue] : (sourcePath != nil);
    BOOL allowFileFallback = params[@"allowFileFallback"] ?
        [params[@"allowFileFallback"] boolValue] : !useInternal;

    // The file route hands the document to FCP (NSWorkspace), and FCP then asks
    // "Which library do you want to import … into?" in a modal panel, even when the
    // library the XML's <library location> names is open, and that panel blocks every
    // main-thread RPC until someone answers it. When that library is open, import
    // through the internal importer instead, which targets it without asking.
    NSString *redirectNote = nil;
    if (!useInternal) {
        NSString *wantedPath = SpliceKit_fcpxmlLibraryLocation(xml);
        __block BOOL libraryOpen = NO;
        if (wantedPath.length) {
            SpliceKit_executeOnMainThreadWithTimeout(^{
                @try {
                    id libs = ((id (*)(id, SEL))objc_msgSend)(
                        objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
                    for (id lib in (NSArray *)libs) {
                        if ([[[SpliceKit_libraryBundleURL(lib) path] stringByStandardizingPath] isEqualToString:wantedPath]) {
                            libraryOpen = YES;
                            break;
                        }
                    }
                } @catch (__unused NSException *e) {}
            }, 5.0, NO);
        }
        if (libraryOpen) {
            useInternal = YES;
            allowFileFallback = NO;
            redirectNote = [NSString stringWithFormat:
                @"internal=false was asked for, but the library the XML names (%@) is open, so the "
                @"internal importer was used: the file route makes FCP ask which library to import "
                @"into in a modal panel that blocks the bridge.", wantedPath];
        }
    }

    // Try the clean path first — no dialogs, no file I/O
    if (useInternal) {
        NSMutableDictionary *pbParams = [@{@"xml": xml} mutableCopy];
        if (params[@"library"]) pbParams[@"library"] = params[@"library"];
        if (params[@"mainThreadTimeout"]) pbParams[@"mainThreadTimeout"] = params[@"mainThreadTimeout"];
        NSDictionary *pbResult = SpliceKit_handlePasteboardImportXML(pbParams);
        if (!pbResult[@"error"]) {
            if (sourcePath || redirectNote) {
                NSMutableDictionary *withPath = [pbResult mutableCopy];
                if (sourcePath) withPath[@"path"] = sourcePath;
                if (redirectNote) withPath[@"routeNote"] = redirectNote;
                return withPath;
            }
            return pbResult;
        }
        if (pbResult[@"mainThreadBusy"]) {
            // Still running (or queued) on the main thread: a file import now would
            // import it a second time.
            return pbResult;
        }
        SpliceKit_log(@"Pasteboard import failed (%@), falling back to file import",
                      pbResult[@"error"]);
        if (!allowFileFallback) {
            return @{@"error": [NSString stringWithFormat:
                         @"Internal FCPXML import failed and file fallback is disabled: %@",
                         pbResult[@"error"]],
                     @"method": @"pasteboard"};
        }
    }

    // Fallback: file-based import via NSWorkspace (async, won't block bridge)
    NSString *tmpPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"splicekit_import.fcpxml"];
    NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    [data writeToFile:tmpPath atomically:YES];
    NSURL *fileURL = [NSURL fileURLWithPath:tmpPath];

    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    __block BOOL opened = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSWorkspace sharedWorkspace] openURLs:@[fileURL]
        withApplicationAtURL:[[NSBundle mainBundle] bundleURL]
        configuration:config
        completionHandler:^(NSRunningApplication *app, NSError *error) {
            opened = (error == nil);
            dispatch_semaphore_signal(sem);
        }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return @{@"status": opened ? @"handedToFCP" : @"failed",
             @"method": @"file",
             @"message": opened ? @"The FCPXML was handed to Final Cut Pro to open; the import runs there and has "
                                  @"not finished yet. FCP may ask which library to import into in a modal panel "
                                  @"that blocks the bridge (detect_dialog shows it). Open the library the XML "
                                  @"names first and import with internal=true to avoid that."
                                : @"Failed to open file"};
}

#pragma mark - Final Cut Pro windows, read off the main thread
//
// CGWindowListCopyWindowInfo is thread-safe and needs nothing from FCP's main
// thread, so it answers while that thread is stuck inside a modal progress sheet
// (an FCPXML import pulling media over the network held it for seven minutes, and
// every main-thread read timed out meanwhile). A process may read the titles of its
// own windows without the Screen Recording permission.
NSArray<NSDictionary *> *SpliceKit_windowSnapshotOffMain(void) {
    NSMutableArray *out = [NSMutableArray array];
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    if (!list) return out;
    pid_t me = getpid();
    for (NSDictionary *w in (__bridge NSArray *)list) {
        if ([w[(id)kCGWindowOwnerPID] intValue] != me) continue;
        NSDictionary *b = w[(id)kCGWindowBounds];
        double width = [b[@"Width"] doubleValue], height = [b[@"Height"] doubleValue];
        if (width < 2 || height < 2) continue;
        NSString *title = w[(id)kCGWindowName] ?: @"";
        [out addObject:@{
            @"title": title,
            @"windowNumber": w[(id)kCGWindowNumber] ?: @0,
            @"layer": w[(id)kCGWindowLayer] ?: @0,
            @"alpha": w[(id)kCGWindowAlpha] ?: @1,
            @"bounds": [NSString stringWithFormat:@"{{%.0f, %.0f}, {%.0f, %.0f}}",
                        [b[@"X"] doubleValue], [b[@"Y"] doubleValue], width, height],
        }];
    }
    CFRelease(list);
    return out;
}

#pragma mark - Async FCPXML import jobs
//
// fcpxml.import with async=true runs the import on a worker thread that waits for
// the main thread as long as the import takes (up to an hour), and returns a job id
// at once. fcpxml.importStatus reports the job (running / ok / error, elapsed time,
// the result) and, while it runs, Final Cut Pro's on-screen windows read off the main
// thread, so the "Import XML" progress sheet shows up there. When the job ends a
// command.completed event is broadcast with correlation_id = the job id, for clients
// that subscribed to events.

static NSMutableDictionary<NSString *, NSMutableDictionary *> *sImportJobs = nil;
static dispatch_queue_t sImportJobsQueue = NULL;

static void SpliceKit_importJobsInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sImportJobs = [NSMutableDictionary dictionary];
        sImportJobsQueue = dispatch_queue_create("com.splicekit.fcpxml-import-jobs", DISPATCH_QUEUE_SERIAL);
    });
}

NSDictionary *SpliceKit_handleFCPXMLImportAsync(NSDictionary *params) {
    SpliceKit_importJobsInit();
    NSMutableDictionary *inner = [params mutableCopy];
    [inner removeObjectForKey:@"async"];
    if (!inner[@"mainThreadTimeout"]) inner[@"mainThreadTimeout"] = @3600;
    // The async path is for the import itself; reading a path that does not exist
    // should fail now, not in the job.
    if (!inner[@"xml"] && inner[@"path"]) {
        NSString *path = SpliceKit_filesystemPathFromParam(inner[@"path"]);
        if (!path || ![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
            return @{@"error": [NSString stringWithFormat:@"Could not read FCPXML at %@", path ?: inner[@"path"]]};
        }
    }
    if (!inner[@"xml"] && !inner[@"path"]) {
        return @{@"error": @"xml or path parameter required"};
    }

    NSString *jobId = [[[NSUUID UUID] UUIDString] substringToIndex:8].lowercaseString;
    NSDate *started = [NSDate date];
    NSMutableDictionary *job = [@{
        @"jobId": jobId,
        @"state": @"running",
        @"started": @([started timeIntervalSince1970]),
    } mutableCopy];
    if (inner[@"path"]) job[@"path"] = SpliceKit_filesystemPathFromParam(inner[@"path"]) ?: inner[@"path"];
    dispatch_sync(sImportJobsQueue, ^{
        // Keep the 49 most recent finished jobs plus this one; a running job is never dropped.
        NSArray *finished = [[sImportJobs.allValues filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"state != 'running'"]]
            sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"started" ascending:YES]]];
        NSInteger excess = (NSInteger)finished.count - 49;
        for (NSInteger i = 0; i < excess; i++) {
            [sImportJobs removeObjectForKey:finished[i][@"jobId"]];
        }
        sImportJobs[jobId] = job;
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = nil;
        NSString *exception = nil;
        @try {
            // Through the dispatcher, not straight to the handler: the busy check
            // (a modal dialog up, a drag in the timeline) must run when the import
            // does, not only when it was queued. An edit landing inside a modal loop
            // or mid-drag has crashed FCP in its undo handler.
            NSDictionary *response = SpliceKit_handleRequest(@{@"method": @"fcpxml.import", @"params": inner});
            if ([response[@"result"] isKindOfClass:[NSDictionary class]]) {
                result = response[@"result"];
            } else {
                id err = response[@"error"];
                NSMutableDictionary *failed = [NSMutableDictionary dictionary];
                failed[@"error"] = [err isKindOfClass:[NSDictionary class]] ? (err[@"message"] ?: [err description])
                                                                             : ([err description] ?: @"import failed");
                if ([err isKindOfClass:[NSDictionary class]]) {
                    for (NSString *flag in @[@"mainThreadBusy", @"importStillRunning", @"dialogPending", @"dragPending"]) {
                        if (err[flag]) failed[flag] = err[flag];
                    }
                }
                result = failed;
            }
        } @catch (NSException *e) {
            exception = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
        }
        NSTimeInterval elapsed = -[started timeIntervalSinceNow];
        __block NSDictionary *snapshot = nil;
        dispatch_sync(sImportJobsQueue, ^{
            NSMutableDictionary *j = sImportJobs[jobId];
            j[@"finished"] = @([[NSDate date] timeIntervalSince1970]);
            j[@"elapsedSeconds"] = @(round(elapsed * 10) / 10);
            if (exception || result[@"error"] || !result) {
                j[@"state"] = @"error";
                // Not "error": the dispatcher turns a reply's top-level error into an RPC
                // error, and importStatus would lose the job's state and id with it.
                j[@"importError"] = exception ?: result[@"error"] ?: @"import returned nothing";
            } else if ([result[@"status"] isEqualToString:@"handedToFCP"]) {
                // Opened with FCP: nothing here can tell when (or whether) it finished.
                j[@"state"] = @"handedToFCP";
                j[@"message"] = result[@"message"];
            } else {
                j[@"state"] = @"ok";
            }
            if (result) j[@"result"] = result;
            snapshot = [j copy];
        });
        SpliceKit_log(@"[FCPXMLImport] job %@ finished: %@ (%.1fs)", jobId, snapshot[@"state"], elapsed);
        NSMutableDictionary *evt = [NSMutableDictionary dictionary];
        evt[@"type"] = @"command.completed";
        evt[@"correlation_id"] = jobId;
        evt[@"method"] = @"fcpxml.import";
        evt[@"duration_ms"] = @((int)(elapsed * 1000));
        evt[@"status"] = [snapshot[@"state"] isEqualToString:@"ok"] ? @"ok" : @"error";
        if (snapshot[@"importError"]) evt[@"error"] = snapshot[@"importError"];
        if (snapshot[@"result"]) evt[@"result"] = snapshot[@"result"];
        SpliceKit_broadcastEvent(evt);
    });

    return @{
        @"status": @"started",
        @"jobId": jobId,
        @"correlation_id": jobId,
        @"message": @"Import started. Poll fcpxml.importStatus with this jobId; it also shows "
                    @"Final Cut Pro's progress sheet while the import runs.",
    };
}

NSDictionary *SpliceKit_handleFCPXMLImportStatus(NSDictionary *params) {
    SpliceKit_importJobsInit();
    NSString *jobId = [params[@"jobId"] isKindOfClass:[NSString class]] ? params[@"jobId"] : nil;
    __block NSArray *jobs = nil;
    dispatch_sync(sImportJobsQueue, ^{
        if (jobId.length) {
            NSDictionary *j = sImportJobs[jobId];
            jobs = j ? @[[j copy]] : @[];
        } else {
            NSMutableArray *all = [NSMutableArray array];
            for (NSDictionary *j in sImportJobs.allValues) [all addObject:[j copy]];
            [all sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"started"] compare:a[@"started"]];
            }];
            jobs = all;
        }
    });
    if (jobId.length && jobs.count == 0) {
        return @{@"error": [NSString stringWithFormat:@"No import job %@ (jobs live until Final Cut Pro quits)", jobId]};
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableArray *out = [NSMutableArray array];
    BOOL anyRunning = NO;
    for (NSDictionary *j in jobs) {
        NSMutableDictionary *m = [j mutableCopy];
        if ([j[@"state"] isEqualToString:@"running"]) {
            anyRunning = YES;
            m[@"elapsedSeconds"] = @(round((now - [j[@"started"] doubleValue]) * 10) / 10);
        }
        [out addObject:m];
    }
    NSMutableDictionary *answer = [NSMutableDictionary dictionary];
    if (jobId.length) [answer addEntriesFromDictionary:out.firstObject];
    else answer[@"jobs"] = out;
    if (anyRunning) {
        // What FCP shows while the job runs ("Import XML" sheet and the like).
        answer[@"windows"] = SpliceKit_windowSnapshotOffMain();
    }
    return answer;
}

#pragma mark - FCPXML Pasteboard Import (bypasses library dialog)
//
// This is the "good" import path. FCP internally uses FFXMLTranslationTask to
// parse FCPXML from the pasteboard during paste operations. We piggyback on
// that same mechanism: write our XML to the pasteboard using FCP's custom
// pasteboard types (IXXMLPasteboardType), then tell FFXMLTranslationTask
// to import it. Result: clean import, no dialogs, no temp files.
//
// After import, we also try to restore attributes (volume, opacity) that
// the import process strips out — FCPXML supports them but FCP's importer
// doesn't always apply them to the imported clips.
//

NSDictionary *SpliceKit_handlePasteboardImportXML(NSDictionary *params) {
    NSString *xml = params[@"xml"];
    double mainThreadTimeout = [params[@"mainThreadTimeout"] doubleValue];
    if (mainThreadTimeout <= 0) mainThreadTimeout = 20.0;

    __block NSDictionary *result = nil;
    __block NSString *targetLibraryPath = nil;
    __block NSString *targetLibraryReason = nil;
    __block NSString *targetLibraryNote = nil;
    SpliceKit_executeOnMainThreadWithTimeout(^{
        @try {
            // If xml provided, write it to the pasteboard
            if (xml) {
                NSData *xmlData = [xml dataUsingEncoding:NSUTF8StringEncoding];
                NSPasteboard *pb = [NSPasteboard generalPasteboard];
                [pb clearContents];
                // Use both generic and current versioned type
                Class IXType = objc_getClass("IXXMLPasteboardType");
                NSString *genericType = ((id (*)(id, SEL))objc_msgSend)((id)IXType, NSSelectorFromString(@"generic"));
                NSString *currentType = ((id (*)(id, SEL))objc_msgSend)((id)IXType, NSSelectorFromString(@"current"));
                if (genericType) [pb setData:xmlData forType:genericType];
                if (currentType) [pb setData:xmlData forType:currentType];
            }

            NSPasteboard *pb = [NSPasteboard generalPasteboard];

            // Check if pasteboard has XML
            SEL containsXMLSel = NSSelectorFromString(@"containsXML");
            if (![pb respondsToSelector:containsXMLSel]) {
                result = @{@"error": @"NSPasteboard does not have containsXML (Interchange not loaded)"};
                return;
            }
            BOOL hasXML = ((BOOL (*)(id, SEL))objc_msgSend)(pb, containsXMLSel);
            if (!hasXML) {
                result = @{@"error": @"No FCPXML on pasteboard"};
                return;
            }

            // Create FFXMLTranslationTask from pasteboard
            Class taskClass = objc_getClass("FFXMLTranslationTask");
            if (!taskClass) {
                result = @{@"error": @"FFXMLTranslationTask class not found"};
                return;
            }
            id task = ((id (*)(id, SEL))objc_msgSend)((id)taskClass, @selector(alloc));
            SEL initPBSel = NSSelectorFromString(@"initForPasteboard:");
            task = ((id (*)(id, SEL, id))objc_msgSend)(task, initPBSel, pb);
            if (!task) {
                result = @{@"error": @"Failed to create FFXMLTranslationTask from pasteboard"};
                return;
            }

            // Check for parse errors
            SEL errorSel = NSSelectorFromString(@"error");
            id parseError = ((id (*)(id, SEL))objc_msgSend)(task, errorSel);
            if (parseError) {
                NSString *errDesc = ((id (*)(id, SEL))objc_msgSend)(parseError, @selector(localizedDescription));
                result = @{@"error": [NSString stringWithFormat:@"FCPXML parse error: %@", errDesc]};
                return;
            }

            // Create FFXMLImportOptions for incremental import into current project
            Class optionsClass = objc_getClass("FFXMLImportOptions");
            if (!optionsClass) {
                result = @{@"error": @"FFXMLImportOptions class not found"};
                return;
            }
            id options = ((id (*)(id, SEL))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)((id)optionsClass, @selector(alloc)), @selector(init));

            // Set incremental import (merge into existing library)
            SEL setIncrementalSel = NSSelectorFromString(@"setIncrementalImport:");
            if ([options respondsToSelector:setIncrementalSel]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(options, setIncrementalSel, YES);
            }

            // Set conflict resolution to merge (type 3)
            SEL setConflictSel = NSSelectorFromString(@"setConflictResolutionType:");
            if ([options respondsToSelector:setConflictSel]) {
                ((void (*)(id, SEL, long long))objc_msgSend)(options, setConflictSel, 3);
            }

            // Set the target library (required to avoid "which library?" dialog).
            // Pick, in order: the library the caller named, the one the document's
            // <library location> names when it is open, else the first open library.
            // Always taking the first one put an import meant for library B into A
            // whenever two were open.
            id activeLibs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
            if (activeLibs && [(NSArray *)activeLibs count] > 0) {
                id library = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
                    activeLibs, @selector(objectAtIndex:), 0);
                NSString *wantedName = [params[@"library"] isKindOfClass:[NSString class]] ? params[@"library"] : nil;
                NSString *wantedPath = SpliceKit_fcpxmlLibraryLocation(xml);
                NSString *pickedBy = @"first open library";
                for (id candidate in (NSArray *)activeLibs) {
                    NSString *name = nil;
                    NSString *path = nil;
                    @try {
                        if ([candidate respondsToSelector:@selector(displayName)]) {
                            name = [((id (*)(id, SEL))objc_msgSend)(candidate, @selector(displayName)) description];
                        }
                        path = [[SpliceKit_libraryBundleURL(candidate) path] stringByStandardizingPath];
                    } @catch (__unused NSException *e) {}
                    if (wantedName.length && ([name isEqualToString:wantedName] ||
                        [[path lastPathComponent] isEqualToString:wantedName] ||
                        [[[path lastPathComponent] stringByDeletingPathExtension] isEqualToString:wantedName])) {
                        library = candidate; pickedBy = @"library parameter"; break;
                    }
                    if (!wantedName.length && wantedPath.length && [path isEqualToString:wantedPath]) {
                        library = candidate; pickedBy = @"<library location> in the XML"; break;
                    }
                }
                if (wantedName.length && ![pickedBy isEqualToString:@"library parameter"]) {
                    result = @{@"error": [NSString stringWithFormat:
                        @"No open library is named '%@'. Open it first, or leave library out.", wantedName]};
                    return;
                }
                targetLibraryPath = [SpliceKit_libraryBundleURL(library) path];
                targetLibraryReason = pickedBy;
                if (wantedPath.length && ![pickedBy isEqualToString:@"<library location> in the XML"] && !wantedName.length) {
                    targetLibraryNote = [NSString stringWithFormat:
                        @"The XML names library %@, which is not open; imported into %@ instead.",
                        wantedPath, targetLibraryPath ?: @"the first open library"];
                }
                SEL setLibrarySel = NSSelectorFromString(@"setLibrary:");
                if ([options respondsToSelector:setLibrarySel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(options, setLibrarySel, library);
                }
                // Not setLibraryURL: -- the older code asked the library for -url, which it
                // does not answer, so that call never happened; passing the real bundle URL
                // (-URL) makes FCP 12.3 show "Which library do you want to import (null)
                // into?" instead of importing. setLibrary: alone targets the library.
            }

            // Set target event from the current timeline's sequence
            id timeline = SpliceKit_getActiveTimelineModule();
            if (timeline) {
                SEL seqSel = NSSelectorFromString(@"sequence");
                id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, seqSel);
                if (sequence) {
                    SEL eventSel = NSSelectorFromString(@"event");
                    SEL containerEventSel = NSSelectorFromString(@"containerEvent");
                    id event = nil;
                    if ([sequence respondsToSelector:eventSel]) {
                        event = ((id (*)(id, SEL))objc_msgSend)(sequence, eventSel);
                    } else if ([sequence respondsToSelector:containerEventSel]) {
                        event = ((id (*)(id, SEL))objc_msgSend)(sequence, containerEventSel);
                    }
                    if (event) {
                        SEL setEventSel = NSSelectorFromString(@"setEvent:");
                        if ([options respondsToSelector:setEventSel]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(options, setEventSel, event);
                        }
                        SEL setTargetSel = NSSelectorFromString(@"setTarget:");
                        if ([options respondsToSelector:setTargetSel]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(options, setTargetSel, event);
                        }
                    }
                }
            }

            // Import full FCPXML documents first. importClipsWithOptions: only
            // imports browser clips from project XML and can miss the timeline.
            SEL importDocSel = NSSelectorFromString(@"importWithOptions:");
            id importObject = nil;
            BOOL importOK = NO;
            if ([task respondsToSelector:importDocSel]) {
                importObject = ((id (*)(id, SEL, id))objc_msgSend)(task, importDocSel, options);
                importOK = importObject != nil;
            }

            // Fallback: clip-only imports for XML snippets that do not contain
            // a project/sequence document.
            SEL importSel = NSSelectorFromString(@"importClipsWithOptions:");
            if (!importOK && [task respondsToSelector:importSel]) {
                importOK = ((BOOL (*)(id, SEL, id))objc_msgSend)(task, importSel, options);
            } else {
                // Fallback: try importWithOptions:
                SEL importSel2 = NSSelectorFromString(@"importWithOptions:");
                if (!importOK && [task respondsToSelector:importSel2]) {
                    importOK = ((BOOL (*)(id, SEL, id))objc_msgSend)(task, importSel2, options);
                }
            }

            // Check for import errors
            id importError = ((id (*)(id, SEL))objc_msgSend)(task, errorSel);
            if (importError) {
                NSString *errDesc = ((id (*)(id, SEL))objc_msgSend)(importError, @selector(localizedDescription));
                result = @{@"error": [NSString stringWithFormat:@"Import error: %@", errDesc],
                           @"parseOK": @YES};
                return;
            }

            // Get import results
            SEL resultsSel = NSSelectorFromString(@"importResults");
            id importResults = [task respondsToSelector:resultsSel] ?
                ((id (*)(id, SEL))objc_msgSend)(task, resultsSel) : nil;

            // No attribute "restore" step after the import. It used to parse
            // adjust-volume / adjust-blend from the XML, run selectAll: on whatever
            // timeline was open and set that value through the inspector on the
            // selection, so importing a project with one -96 dB clip selected every
            // clip in the user's open project and aimed the volume change at it. FCP
            // 12.3's importer applies adjust-volume and adjust-blend itself (verified:
            // a clip imported with adjust-volume -20dB reads gain 0.1).

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"status"] = @"ok";
            info[@"importOK"] = @(importOK);
            if (importResults) {
                info[@"hasResults"] = @YES;
                info[@"resultClass"] = NSStringFromClass([importResults class]);
            }
            if (targetLibraryPath) info[@"library"] = targetLibraryPath;
            if (targetLibraryReason) info[@"libraryChosenBy"] = targetLibraryReason;
            if (targetLibraryNote) info[@"libraryNote"] = targetLibraryNote;

            result = info;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    }, mainThreadTimeout, YES);
    if (!result && SpliceKit_lastMainThreadTimeoutState() != 0) {
        BOOL running = SpliceKit_lastMainThreadTimeoutState() == 2;
        return @{@"error": [NSString stringWithFormat:
                    @"The import %@ after %.0f s on Final Cut Pro's main thread and was not cancelled: "
                    @"it may still finish (media on a network volume keeps FCP's \"Importing Remote "
                    @"Resources\" sheet up for minutes). Do not import again; watch detect_dialog, then "
                    @"check the browser. Pass async=true to get a job id and poll fcpxml.importStatus instead.",
                    running ? @"was still running" : @"had not started", mainThreadTimeout],
                 @"mainThreadBusy": @YES,
                 @"importStillRunning": @(running)};
    }
    return result;
}

#pragma mark - FCPXML Direct Paste (swizzle pasteAnchored: and paste:)
//
// FCP's paste path only handles native proFFPasteboardUTI data. When FCPXML is
// on the pasteboard (from generate_captions, paste_fcpxml, etc.), paste actions
// silently ignore it because hasEdits: returns NO for FCPXML.
//
// This swizzle intercepts paste actions and transparently converts FCPXML to
// native clipboard format:
//
// 1. Check if pasteboard has FCPXML but no native edits
// 2. Check cache — if we've converted this exact FCPXML before, use cached data
// 3. Freeze screen updates to hide the project switch
// 4. Import FCPXML via FFXMLTranslationTask (creates temp project)
// 5. Load temp project, selectAll + copy (creates native clipboard data)
// 6. Cache the native data for future pastes
// 7. Restore playhead position, switch back to user's project
// 8. Unfreeze screen, call original paste (now finds native data)
// 9. Clean up temp project
//
// The shared conversion function SpliceKit_convertFCPXMLToNativeClipboard() can
// also be called directly by the caption system to avoid duplicating the pipeline.

static IMP sOrigPasteAnchored = NULL;
static IMP sOrigPaste = NULL;
static NSCache *sFCPXMLNativeCache = nil;

// --- Shared FCPXML-to-native conversion function ---
// Returns YES if native clipboard data is now on the pasteboard.
// Can be called from the paste swizzle or directly from the caption pipeline.
// Must be called on the main thread.
BOOL SpliceKit_convertFCPXMLToNativeClipboard(void) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    Class ffpbClass = objc_getClass("FFPasteboard");

    // --- Already have native data? Nothing to do. ---
    if (ffpbClass) {
        id ffpb = ((id (*)(id, SEL, id))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)ffpbClass, @selector(alloc)),
            NSSelectorFromString(@"initWithName:"), NSPasteboardNameGeneral);
        if (((BOOL (*)(id, SEL, BOOL))objc_msgSend)(ffpb, NSSelectorFromString(@"hasEdits:"), NO))
            return YES; // native data already present
    }

    // --- Check for FCPXML ---
    SEL containsXMLSel = NSSelectorFromString(@"containsXML");
    if (![pb respondsToSelector:containsXMLSel]) return NO;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(pb, containsXMLSel)) return NO;

    NSString *xmlString = [pb stringForType:
        ((id (*)(id, SEL))objc_msgSend)(objc_getClass("IXXMLPasteboardType"),
            NSSelectorFromString(@"generic"))];
    if (!xmlString || xmlString.length == 0) return NO;

    SpliceKit_log(@"[FCPXMLPaste] FCPXML detected — converting to native format");

    // --- Improvement #6: Check cache by content hash ---
    // Key = libraryUUID + SHA256(xml) to avoid stale cross-library entries
    NSString *cacheKey = nil;
    if (sFCPXMLNativeCache) {
        // Get current library UUID for cache key
        NSString *libUUID = @"";
        id activeLibs = ((id (*)(id, SEL))objc_msgSend)(
            objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
        if (activeLibs && [(NSArray *)activeLibs count] > 0) {
            id lib = [(NSArray *)activeLibs objectAtIndex:0];
            SEL pidSel = NSSelectorFromString(@"persistentID");
            if ([lib respondsToSelector:pidSel])
                libUUID = ((id (*)(id, SEL))objc_msgSend)(lib, pidSel) ?: @"";
        }
        // Simple hash — FNV-1a on the XML bytes
        const char *utf8 = xmlString.UTF8String;
        uint64_t hash = 14695981039346656037ULL;
        while (*utf8) { hash ^= (uint8_t)*utf8++; hash *= 1099511628211ULL; }
        cacheKey = [NSString stringWithFormat:@"%@_%llx", libUUID, hash];

        NSData *cached = [sFCPXMLNativeCache objectForKey:cacheKey];
        if (cached) {
            SpliceKit_log(@"[FCPXMLPaste] Cache hit — writing %lu bytes to pasteboard",
                (unsigned long)cached.length);
            [pb clearContents];
            [pb setData:cached forType:@"com.apple.flexo.proFFPasteboardUTI"];
            return YES;
        }
    }

    // --- Save user's current state ---
    id userSequence = nil;
    NSString *userSequenceName = nil;
    SpliceKit_CMTime savedPlayhead = {0, 600, 1, 0}; // default: 0s
    {
        id tm = SpliceKit_getActiveTimelineModule();
        if (tm) {
            userSequence = ((id (*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"sequence"));
            if (userSequence) {
                userSequenceName = ((id (*)(id, SEL))objc_msgSend)(userSequence,
                    NSSelectorFromString(@"displayName"));
            }
            // Improvement #10: Save playhead position for restore after switch-back
            SEL playheadSel = NSSelectorFromString(@"playheadTime");
            if ([tm respondsToSelector:playheadSel]) {
                savedPlayhead = ((SpliceKit_CMTime (*)(id, SEL))objc_msgSend)(tm, playheadSel);
            }
        }
    }
    if (!userSequence) {
        SpliceKit_log(@"[FCPXMLPaste] No active timeline");
        return NO;
    }

    // --- Inject unique project name for reliable lookup ---
    NSString *tempProjectName = [NSString stringWithFormat:@"_SKPaste_%u",
        arc4random() % 100000];
    NSRegularExpression *projRegex = [NSRegularExpression
        regularExpressionWithPattern:@"<project\\s+name=\"[^\"]*\""
        options:0 error:nil];
    xmlString = [projRegex stringByReplacingMatchesInString:xmlString
        options:0 range:NSMakeRange(0, xmlString.length)
        withTemplate:[NSString stringWithFormat:@"<project name=\"%@\"", tempProjectName]];

    SpliceKit_log(@"[FCPXMLPaste] Importing as: %@", tempProjectName);

    // --- Improvement #3: Freeze screen updates to hide project switch ---
    // NSDisableScreenUpdates() is deprecated but functional. Safety timeout
    // ensures screen unfreezes even if the pipeline hangs.
    NSDisableScreenUpdates();
    __block BOOL screenFrozen = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        if (screenFrozen) {
            NSEnableScreenUpdates();
            SpliceKit_log(@"[FCPXMLPaste] Safety: unfroze screen after timeout");
        }
    });

    BOOL success = NO;

    // --- Import FCPXML ---
    NSDictionary *importResult = SpliceKit_handlePasteboardImportXML(@{@"xml": xmlString});
    if (importResult[@"error"]) {
        SpliceKit_log(@"[FCPXMLPaste] Import failed: %@", importResult[@"error"]);
        goto cleanup;
    }

    // --- Find temp project by unique name ---
    {
        __block id tempSeq = nil;
        for (int attempt = 0; attempt < 30 && !tempSeq; attempt++) {
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.2]];
            id libs = ((id (*)(id, SEL))objc_msgSend)(
                objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
            if (!libs || ![(NSArray *)libs count]) continue;
            id lib = [(NSArray *)libs objectAtIndex:0];
            id seqs = ((id (*)(id, SEL))objc_msgSend)(lib,
                NSSelectorFromString(@"_deepLoadedSequences"));
            if (!seqs) continue;
            for (id seq in (NSSet *)seqs) {
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq,
                    NSSelectorFromString(@"displayName"));
                if (name && [name isEqualToString:tempProjectName]) {
                    tempSeq = seq;
                    break;
                }
            }
        }
        if (!tempSeq) {
            SpliceKit_log(@"[FCPXMLPaste] Temp project '%@' not found", tempProjectName);
            goto cleanup;
        }

        SpliceKit_log(@"[FCPXMLPaste] Found temp project: %@", tempProjectName);

        // --- Load temp project ---
        id appDelegate = [NSApp delegate];
        id editorContainer = ((id (*)(id, SEL))objc_msgSend)(appDelegate,
            NSSelectorFromString(@"activeEditorContainer"));
        if (!editorContainer) goto cleanup;

        ((void (*)(id, SEL, id))objc_msgSend)(editorContainer,
            NSSelectorFromString(@"loadEditorForSequence:"), tempSeq);

        BOOL tempLoaded = NO;
        for (int i = 0; i < 50 && !tempLoaded; i++) {
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.2]];
            id tm = SpliceKit_getActiveTimelineModule();
            if (!tm) continue;
            id seq = ((id (*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"sequence"));
            if (!seq) continue;
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
            if (name && [name isEqualToString:tempProjectName]) tempLoaded = YES;
        }
        if (!tempLoaded) {
            SpliceKit_log(@"[FCPXMLPaste] Failed to load temp project");
            ((void (*)(id, SEL, id))objc_msgSend)(editorContainer,
                NSSelectorFromString(@"loadEditorForSequence:"), userSequence);
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.5]];
            goto cleanup;
        }

        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.5]];

        // --- Copy to native clipboard format ---
        [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"selectAll:")
                                                   to:nil from:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"copy:")
                                                   to:nil from:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        SpliceKit_log(@"[FCPXMLPaste] Copied items to native clipboard");

        // --- Improvement #6: Cache the native data ---
        if (sFCPXMLNativeCache && cacheKey) {
            NSData *nativeData = [pb dataForType:@"com.apple.flexo.proFFPasteboardUTI"];
            if (nativeData) {
                [sFCPXMLNativeCache setObject:nativeData forKey:cacheKey cost:nativeData.length];
                SpliceKit_log(@"[FCPXMLPaste] Cached %lu bytes for future use",
                    (unsigned long)nativeData.length);
            }
        }

        // --- Switch back to user's project ---
        ((void (*)(id, SEL, id))objc_msgSend)(editorContainer,
            NSSelectorFromString(@"loadEditorForSequence:"), userSequence);

        BOOL userLoaded = NO;
        for (int i = 0; i < 50 && !userLoaded; i++) {
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.2]];
            id tm = SpliceKit_getActiveTimelineModule();
            if (!tm) continue;
            id seq = ((id (*)(id, SEL))objc_msgSend)(tm, NSSelectorFromString(@"sequence"));
            if (!seq) continue;
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(seq, NSSelectorFromString(@"displayName"));
            if (name && [name isEqualToString:userSequenceName]) userLoaded = YES;
        }

        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.2]];

        // --- Improvement #10: Restore playhead position ---
        {
            id tm = SpliceKit_getActiveTimelineModule();
            if (tm) {
                SEL setSel = NSSelectorFromString(@"setPlayheadTime:");
                if ([tm respondsToSelector:setSel]) {
                    ((void (*)(id, SEL, SpliceKit_CMTime))objc_msgSend)(tm, setSel, savedPlayhead);
                }
            }
        }

        // --- Clean up temp project ---
        // -[FFAnchoredTimelineModule deleteSequence:] was asked to do this and silently
        // did nothing — the module is back on the user's sequence by now, not the scratch
        // one — which is how three _SKPaste_* projects came to be sitting in the library.
        // Trash the project's own library record instead, and say so if it fails.
        @try {
            if (!SpliceKit_deleteSequenceLibraryItem(tempSeq)) {
                SpliceKit_log(@"[FCPXMLPaste] Could not remove temp project '%@' — "
                              @"cleanup_temp_projects will pick it up", tempProjectName);
            }
        } @catch (NSException *e) {
            SpliceKit_log(@"[FCPXMLPaste] Cleanup error: %@", e);
        }

        success = YES;
        SpliceKit_log(@"[FCPXMLPaste] Conversion complete — native data on pasteboard");
    }

cleanup:
    // --- Improvement #3: Unfreeze screen ---
    if (screenFrozen) {
        screenFrozen = NO;
        NSEnableScreenUpdates();
    }

    return success;
}

// --- Generic paste swizzle handler (shared by pasteAnchored: and paste:) ---
static void SpliceKit_handleFCPXMLPaste(id self, SEL _cmd, id sender, IMP original) {
    SpliceKit_log(@"[FCPXMLPaste] Swizzle ENTERED for %@", NSStringFromSelector(_cmd));
    // Check if FCPXML needs conversion
    Class ffpbClass = objc_getClass("FFPasteboard");
    if (ffpbClass) {
        id ffpb = ((id (*)(id, SEL, id))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)ffpbClass, @selector(alloc)),
            NSSelectorFromString(@"initWithName:"), NSPasteboardNameGeneral);
        if (!((BOOL (*)(id, SEL, BOOL))objc_msgSend)(ffpb, NSSelectorFromString(@"hasEdits:"), NO)) {
            // No native data — try FCPXML conversion
            SpliceKit_convertFCPXMLToNativeClipboard();
        }
    }
    ((void (*)(id, SEL, id))original)(self, _cmd, sender);
}

// --- Improvement #8: Swizzle both pasteAnchored: and paste: ---
static void SpliceKit_swizzled_pasteAnchored(id self, SEL _cmd, id sender) {
    SpliceKit_handleFCPXMLPaste(self, _cmd, sender, sOrigPasteAnchored);
}

static void SpliceKit_swizzled_paste(id self, SEL _cmd, id sender) {
    SpliceKit_handleFCPXMLPaste(self, _cmd, sender, sOrigPaste);
}

void SpliceKit_installFCPXMLPasteSwizzle(void) {
    Class tlClass = objc_getClass("FFAnchoredTimelineModule");
    if (!tlClass) {
        SpliceKit_log(@"[FCPXMLPaste] WARNING: FFAnchoredTimelineModule not found");
        return;
    }

    // Improvement #6: Initialize cache (50MB limit)
    sFCPXMLNativeCache = [[NSCache alloc] init];
    sFCPXMLNativeCache.totalCostLimit = 50 * 1024 * 1024;

    // Swizzle pasteAnchored: (paste as connected)
    SEL pasteAnchoredSel = NSSelectorFromString(@"pasteAnchored:");
    Method pasteAnchoredMethod = class_getInstanceMethod(tlClass, pasteAnchoredSel);
    if (pasteAnchoredMethod) {
        sOrigPasteAnchored = method_setImplementation(pasteAnchoredMethod,
            (IMP)SpliceKit_swizzled_pasteAnchored);
        SpliceKit_log(@"[FCPXMLPaste] Swizzled -[FFAnchoredTimelineModule pasteAnchored:]");
    }

    // Improvement #8: Swizzle paste: (insert paste)
    SEL pasteSel = NSSelectorFromString(@"paste:");
    Method pasteMethod = class_getInstanceMethod(tlClass, pasteSel);
    if (pasteMethod) {
        sOrigPaste = method_setImplementation(pasteMethod,
            (IMP)SpliceKit_swizzled_paste);
        SpliceKit_log(@"[FCPXMLPaste] Swizzled -[FFAnchoredTimelineModule paste:]");
    }
}

#pragma mark - Export FCPXML Programmatically

NSDictionary *SpliceKit_handleFCPXMLExport(NSDictionary *params) {
    NSString *outputPath = params[@"path"] ?: @"/tmp/splicekit_export.fcpxml";

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            // Use the same safe export path as FCP's own exportXML: action:
            //   1. Get the active sequence
            //   2. FFLibrary.eventClipForSequence: → get the event clip
            //   3. FFXMLTranslationTask.translationTaskForClips: → create export task
            //   4. task.exportToFile:withOptions: → write directly to file
            //
            // This uses FFXMLTranslationEventClipsExporter which only serializes the
            // sequence/clips, avoiding the whole-document crash in FFXMLExporter.

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

            // Step 1: Get the event clip for this sequence
            Class ffLibrary = objc_getClass("FFLibrary");
            if (!ffLibrary) {
                result = @{@"error": @"FFLibrary class not found"};
                return;
            }

            SEL eventClipSel = NSSelectorFromString(@"eventClipForSequence:");
            if (![ffLibrary respondsToSelector:eventClipSel]) {
                result = @{@"error": @"FFLibrary does not respond to eventClipForSequence:"};
                return;
            }

            id eventClip = ((id (*)(id, SEL, id))objc_msgSend)((id)ffLibrary, eventClipSel, sequence);
            if (!eventClip) {
                // eventClipForSequence: returns nil if the sequence IS the event clip
                // (happens for top-level sequences). Fall back to the sequence itself.
                eventClip = sequence;
            }

            // Step 2: Create translation task for export
            Class taskClass = objc_getClass("FFXMLTranslationTask");
            if (!taskClass) {
                result = @{@"error": @"FFXMLTranslationTask class not found"};
                return;
            }

            SEL taskForClipsSel = NSSelectorFromString(@"translationTaskForClips:");
            if (![taskClass respondsToSelector:taskForClipsSel]) {
                result = @{@"error": @"translationTaskForClips: not available"};
                return;
            }

            NSArray *clips = @[eventClip];
            id task = ((id (*)(id, SEL, id))objc_msgSend)((id)taskClass, taskForClipsSel, clips);
            if (!task) {
                result = @{@"error": @"Failed to create FFXMLTranslationTask"};
                return;
            }

            // Step 3: Create export options
            Class optionsClass = objc_getClass("FFXMLExportOptions");
            id options = nil;
            if (optionsClass) {
                SEL initDefSel = NSSelectorFromString(@"initWithUserDefaults");
                id optObj = [[optionsClass alloc] init];
                if ([optObj respondsToSelector:initDefSel]) {
                    options = ((id (*)(id, SEL))objc_msgSend)(optObj, initDefSel);
                } else {
                    options = optObj;
                }
            }

            // Step 4: Export to file
            NSURL *outURL = [NSURL fileURLWithPath:outputPath];
            SEL exportSel = NSSelectorFromString(@"exportToFile:withOptions:");
            if (![task respondsToSelector:exportSel]) {
                result = @{@"error": @"exportToFile:withOptions: not available on task"};
                return;
            }

            BOOL success = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(
                task, exportSel, outURL, options);

            // Check for error on the task
            NSError *taskError = nil;
            SEL errorSel = NSSelectorFromString(@"error");
            if ([task respondsToSelector:errorSel]) {
                taskError = ((id (*)(id, SEL))objc_msgSend)(task, errorSel);
            }

            if (!success || taskError) {
                NSString *errMsg = taskError ? [taskError localizedDescription] : @"Export returned false";
                result = @{@"error": [NSString stringWithFormat:@"Export failed: %@", errMsg]};
                return;
            }

            // Verify the file was written
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil];
            unsigned long long fileSize = [attrs[NSFileSize] unsignedLongLongValue];

            result = @{
                @"status": @"ok",
                @"path": outputPath,
                @"bytes": @(fileSize),
            };
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });

    return result;
}
