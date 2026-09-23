//
//  SpliceKitURLImportHooks.m
//  Final Cut hooks for URL import: the provider shim, the FFFileImporter / timeline
//  drag swizzles that swap in shadow MP4s, and their installation at launch.
//

#import "SpliceKitURLImport+Private.h"

static id (*sSpliceKitURLImportOriginalNewClipFromURLManageFileType)(id, SEL, id, int) = NULL;
static id (*sSpliceKitURLImportOriginalFFFileImporterImportToEvent)(id, SEL, id, int, BOOL, BOOL, id *) = NULL;
static id (*sSpliceKitURLImportOriginalFFFileImporterImportFileURLs)(id, SEL, id, id, id, int, BOOL, BOOL, id, id, id) = NULL;
static BOOL (*sSpliceKitURLImportOriginalFFFileImporterValidateURLs)(id, SEL, id, id, id, BOOL, id, BOOL, id *, id) = NULL;
static void (*sSpliceKitURLImportOriginalFFFileImporterScanURLForFiles)(id, SEL, id, id, id, id, id, id, void *) = NULL;
static NSDragOperation (*sSpliceKitURLImportOriginalTLKTimelineViewDraggingEntered)(id, SEL, id) = NULL;
static char (*sSpliceKitURLImportOriginalTLKTimelineViewPerformDragOperation)(id, SEL, id) = NULL;
static IMP sSpliceKitURLImportOriginalProviderFigExtensionsIMP = NULL;
static IMP sSpliceKitURLImportOriginalProviderFigUTIsIMP = NULL;
static BOOL sSpliceKitURLImportVP9ImportHookInstalled = NO;
static BOOL sSpliceKitURLImportProviderShimInstalled = NO;

static id SpliceKitURLImportProviderFigExtensions(id self, SEL _cmd) {
    id base = sSpliceKitURLImportOriginalProviderFigExtensionsIMP
        ? ((id (*)(id, SEL))sSpliceKitURLImportOriginalProviderFigExtensionsIMP)(self, _cmd)
        : nil;
    return [SpliceKitURLImportUniqueStrings(base, @[@"mkv", @"webm"]) copy];
}

static id SpliceKitURLImportProviderFigUTIs(id self, SEL _cmd) {
    id base = sSpliceKitURLImportOriginalProviderFigUTIsIMP
        ? ((id (*)(id, SEL))sSpliceKitURLImportOriginalProviderFigUTIsIMP)(self, _cmd)
        : nil;
    return [SpliceKitURLImportUniqueStrings(base,
                                            @[@"org.matroska.mkv",
                                              @"org.webmproject.webm"]) copy];
}

static BOOL SpliceKitURLImport_installProviderShim(void) {
    if (sSpliceKitURLImportProviderShimInstalled) return YES;

    Class providerFigClass = objc_getClass("FFProviderFig");
    if (!providerFigClass) {
        SpliceKit_log(@"[VP9Import] FFProviderFig unavailable; Matroska provider shim not installed");
        return NO;
    }

    @try {
        Method extensionsMethod = class_getClassMethod(providerFigClass, @selector(extensions));
        Method utisMethod = class_getClassMethod(providerFigClass, @selector(utis));
        if (!extensionsMethod || !utisMethod) {
            SpliceKit_log(@"[VP9Import] FFProviderFig missing extensions/utis methods; Matroska provider shim not installed");
            return NO;
        }

        if (!sSpliceKitURLImportOriginalProviderFigExtensionsIMP) {
            sSpliceKitURLImportOriginalProviderFigExtensionsIMP = method_setImplementation(
                extensionsMethod,
                (IMP)SpliceKitURLImportProviderFigExtensions);
        }
        if (!sSpliceKitURLImportOriginalProviderFigUTIsIMP) {
            sSpliceKitURLImportOriginalProviderFigUTIsIMP = method_setImplementation(
                utisMethod,
                (IMP)SpliceKitURLImportProviderFigUTIs);
        }

        sSpliceKitURLImportProviderShimInstalled =
            (sSpliceKitURLImportOriginalProviderFigExtensionsIMP != NULL) &&
            (sSpliceKitURLImportOriginalProviderFigUTIsIMP != NULL);
        if (sSpliceKitURLImportProviderShimInstalled) {
            SpliceKit_log(@"[VP9Import] Installed FFProviderFig Matroska/WebM provider shim");
        } else {
            SpliceKit_log(@"[VP9Import] FFProviderFig Matroska/WebM provider shim incomplete");
        }
        return sSpliceKitURLImportProviderShimInstalled;
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception installing Matroska/WebM provider shim: %@", e.reason);
        return NO;
    }
}

static NSArray<NSURL *> *SpliceKitURLImportFileURLsFromPasteboard(NSPasteboard *pasteboard) {
    if (![pasteboard isKindOfClass:[NSPasteboard class]]) return @[];

    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
                                                       options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
    if (urls.count > 0) return urls;

    NSArray *filenamePaths = [pasteboard propertyListForType:NSFilenamesPboardType];
    if (![filenamePaths isKindOfClass:[NSArray class]] || filenamePaths.count == 0) return @[];

    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray arrayWithCapacity:filenamePaths.count];
    for (id item in filenamePaths) {
        if (![item isKindOfClass:[NSString class]]) continue;
        [fileURLs addObject:[NSURL fileURLWithPath:[(NSString *)item stringByStandardizingPath]]];
    }
    return [fileURLs copy];
}

static BOOL SpliceKitURLImportRewriteFileURLsOnPasteboard(NSPasteboard *pasteboard) {
    NSArray<NSURL *> *fileURLs = SpliceKitURLImportFileURLsFromPasteboard(pasteboard);
    if (fileURLs.count == 0) return NO;

    NSMutableArray<NSURL *> *rewrittenURLs = [NSMutableArray arrayWithCapacity:fileURLs.count];
    BOOL changed = NO;

    for (NSURL *fileURL in fileURLs) {
        NSString *errorText = nil;
        NSURL *rewrittenURL = SpliceKitURLImportMaybeRewriteLocalFileURL(fileURL, &errorText);
        if (rewrittenURL && ![rewrittenURL isEqual:fileURL]) {
            changed = YES;
            SpliceKit_log(@"[VP9Import] Rewrote dragged URL %@ -> %@",
                          fileURL.path, rewrittenURL.path);
        } else if (errorText.length > 0) {
            SpliceKit_log(@"[VP9Import] Drag rewrite failed for %@: %@. Falling back to original file.",
                          fileURL.path, errorText);
        }
        [rewrittenURLs addObject:rewrittenURL ?: fileURL];
    }

    if (!changed) return NO;

    @try {
        [pasteboard clearContents];
        BOOL wrote = [pasteboard writeObjects:rewrittenURLs];
        if (!wrote) {
            SpliceKit_log(@"[VP9Import] Failed to write rewritten dragged URLs back to pasteboard");
            return NO;
        }
        SpliceKit_log(@"[VP9Import] Rewrote %lu dragged file URL(s) on pasteboard",
                      (unsigned long)rewrittenURLs.count);
        return YES;
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception while rewriting drag pasteboard: %@", e.reason);
        return NO;
    }
}

static id SpliceKitURLImportRemapObject(id value, NSDictionary<NSURL *, NSURL *> *rewriteMap) {
    if (!value || rewriteMap.count == 0) return value;

    if ([value isKindOfClass:[NSURL class]]) {
        NSURL *mapped = rewriteMap[(NSURL *)value];
        return mapped ?: value;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSString *stringValue = (NSString *)value;
        for (NSURL *originalURL in rewriteMap) {
            NSURL *rewrittenURL = rewriteMap[originalURL];
            if ([stringValue isEqualToString:originalURL.path] ||
                [stringValue isEqualToString:originalURL.absoluteString]) {
                return [stringValue isEqualToString:originalURL.path]
                    ? rewrittenURL.path
                    : rewrittenURL.absoluteString;
            }
        }
        return value;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)value;
        NSMutableArray *mapped = [NSMutableArray arrayWithCapacity:array.count];
        BOOL changed = NO;
        for (id item in array) {
            id remapped = SpliceKitURLImportRemapObject(item, rewriteMap);
            if (remapped != item) changed = YES;
            [mapped addObject:remapped ?: [NSNull null]];
        }
        if (!changed) return value;
        return [value isKindOfClass:[NSMutableArray class]] ? mapped : [mapped copy];
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)value;
        NSMutableDictionary *mapped = [NSMutableDictionary dictionaryWithCapacity:dictionary.count];
        BOOL changed = NO;
        for (id key in dictionary) {
            id remappedKey = SpliceKitURLImportRemapObject(key, rewriteMap) ?: [NSNull null];
            id remappedValue = SpliceKitURLImportRemapObject(dictionary[key], rewriteMap) ?: [NSNull null];
            if (remappedKey != key || remappedValue != dictionary[key]) changed = YES;
            mapped[remappedKey] = remappedValue;
        }
        if (!changed) return value;
        return [value isKindOfClass:[NSMutableDictionary class]] ? mapped : [mapped copy];
    }

    return value;
}

static id SpliceKitURLImportRewriteURLCollection(id urlCollection,
                                                 NSMutableDictionary<NSURL *, NSURL *> *rewriteMap) {
    if (![urlCollection isKindOfClass:[NSArray class]]) return urlCollection;

    NSArray *urls = (NSArray *)urlCollection;
    NSMutableArray *rewritten = [NSMutableArray arrayWithCapacity:urls.count];
    BOOL changed = NO;

    for (id item in urls) {
        id newItem = item;
        if ([item isKindOfClass:[NSURL class]] && ((NSURL *)item).isFileURL) {
            NSURL *existingRewrite = rewriteMap[(NSURL *)item];
            if (existingRewrite) {
                newItem = existingRewrite;
                changed = YES;
            } else {
                NSString *errorText = nil;
                NSURL *rewrittenURL = SpliceKitURLImportMaybeRewriteLocalFileURL((NSURL *)item, &errorText);
                if (rewrittenURL && ![rewrittenURL isEqual:item]) {
                    rewriteMap[(NSURL *)item] = rewrittenURL;
                    newItem = rewrittenURL;
                    changed = YES;
                    SpliceKit_log(@"[VP9Import] Rewrote importer URL %@ -> %@",
                                  ((NSURL *)item).path, rewrittenURL.path);
                } else if (errorText.length > 0) {
                    SpliceKit_log(@"[VP9Import] Importer rewrite failed for %@: %@. Falling back to original file.",
                                  ((NSURL *)item).path, errorText);
                }
            }
        }
        [rewritten addObject:newItem ?: [NSNull null]];
    }

    if (!changed) return urlCollection;
    return [urlCollection isKindOfClass:[NSMutableArray class]] ? rewritten : [rewritten copy];
}

static void SpliceKitURLImportRewriteFFFileImporterIvarsIfNeeded(id importer) {
    if (!importer) return;

    @try {
        Class importerClass = object_getClass(importer);
        Ivar importURLsIvar = class_getInstanceVariable(importerClass, "_importURLs");
        Ivar acceptedURLsIvar = class_getInstanceVariable(importerClass, "_acceptedURLs");
        Ivar importURLsInfoIvar = class_getInstanceVariable(importerClass, "_importURLsInfo");

        NSMutableDictionary<NSURL *, NSURL *> *rewriteMap = [NSMutableDictionary dictionary];

        if (importURLsIvar) {
            id originalImportURLs = object_getIvar(importer, importURLsIvar);
            id rewrittenImportURLs = SpliceKitURLImportRewriteURLCollection(originalImportURLs, rewriteMap);
            if (rewrittenImportURLs != originalImportURLs) {
                object_setIvar(importer, importURLsIvar, rewrittenImportURLs);
            }
        }

        if (acceptedURLsIvar) {
            id originalAcceptedURLs = object_getIvar(importer, acceptedURLsIvar);
            id rewrittenAcceptedURLs = SpliceKitURLImportRewriteURLCollection(originalAcceptedURLs, rewriteMap);
            if (rewrittenAcceptedURLs != originalAcceptedURLs) {
                object_setIvar(importer, acceptedURLsIvar, rewrittenAcceptedURLs);
            }
        }

        if (rewriteMap.count > 0 && importURLsInfoIvar) {
            id originalURLsInfo = object_getIvar(importer, importURLsInfoIvar);
            id rewrittenURLsInfo = SpliceKitURLImportRemapObject(originalURLsInfo, rewriteMap);
            if (rewrittenURLsInfo != originalURLsInfo) {
                object_setIvar(importer, importURLsInfoIvar, rewrittenURLsInfo);
            }
            SpliceKit_log(@"[VP9Import] Rewrote %lu importer pending URL(s) before Media Import ingest",
                          (unsigned long)rewriteMap.count);
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception while rewriting FFFileImporter ivars: %@", e.reason);
    }
}

static id SpliceKitURLImport_swizzled_newClipFromURL_manageFileType(id self,
                                                                    SEL _cmd,
                                                                    id sourceURL,
                                                                    int manageFileType) {
    id importURL = sourceURL;

    @try {
        if ([sourceURL isKindOfClass:[NSURL class]] && ((NSURL *)sourceURL).isFileURL) {
            NSURL *fileURL = (NSURL *)sourceURL;
            NSString *errorText = nil;
            // Route through the shared cache-aware helper so every remux site
            // benefits from the deterministic shadow path — avoids creating
            // Fix-1.mp4, Fix-2.mp4, … on each Media Import hook trigger.
            NSURL *rewrittenURL = SpliceKitURLImportMaybeRewriteLocalFileURL(fileURL, &errorText);
            if (rewrittenURL && ![rewrittenURL isEqual:fileURL]) {
                importURL = rewrittenURL;
                SpliceKit_log(@"[VP9Import] Rewrote local import %@ -> %@",
                              fileURL.path, rewrittenURL.path);
            } else if (errorText.length > 0) {
                SpliceKit_log(@"[VP9Import] Stream-copy normalization failed for %@: %@. Falling back to original file.",
                              fileURL.path, errorText);
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception while preparing local import: %@", e.reason);
    }

    if (sSpliceKitURLImportOriginalNewClipFromURLManageFileType) {
        return sSpliceKitURLImportOriginalNewClipFromURLManageFileType(self, _cmd, importURL, manageFileType);
    }
    return nil;
}

static id SpliceKitURLImport_swizzled_FFFileImporter_importToEvent(id self,
                                                                   SEL _cmd,
                                                                   id event,
                                                                   int manageFileType,
                                                                   BOOL processNow,
                                                                   BOOL warnClipsAlreadyExist,
                                                                   id *error) {
    SpliceKitURLImportRewriteFFFileImporterIvarsIfNeeded(self);
    if (sSpliceKitURLImportOriginalFFFileImporterImportToEvent) {
        return sSpliceKitURLImportOriginalFFFileImporterImportToEvent(self,
                                                                      _cmd,
                                                                      event,
                                                                      manageFileType,
                                                                      processNow,
                                                                      warnClipsAlreadyExist,
                                                                      error);
    }
    return nil;
}

static NSDragOperation SpliceKitURLImport_swizzled_TLKTimelineView_draggingEntered(id self,
                                                                                    SEL _cmd,
                                                                                    id draggingInfo) {
    @try {
        id pasteboard = [draggingInfo respondsToSelector:@selector(draggingPasteboard)]
            ? [draggingInfo draggingPasteboard]
            : nil;
        if (SpliceKitURLImportRewriteFileURLsOnPasteboard(pasteboard)) {
            SpliceKit_log(@"[VP9Import] Rewrote timeline drag pasteboard before draggingEntered");
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception in timeline draggingEntered rewrite: %@", e.reason);
    }

    if (sSpliceKitURLImportOriginalTLKTimelineViewDraggingEntered) {
        return sSpliceKitURLImportOriginalTLKTimelineViewDraggingEntered(self, _cmd, draggingInfo);
    }
    return NSDragOperationNone;
}

static char SpliceKitURLImport_swizzled_TLKTimelineView_performDragOperation(id self,
                                                                              SEL _cmd,
                                                                              id draggingInfo) {
    @try {
        id pasteboard = [draggingInfo respondsToSelector:@selector(draggingPasteboard)]
            ? [draggingInfo draggingPasteboard]
            : nil;
        if (SpliceKitURLImportRewriteFileURLsOnPasteboard(pasteboard)) {
            SpliceKit_log(@"[VP9Import] Rewrote timeline drag pasteboard before performDragOperation");
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception in timeline performDragOperation rewrite: %@", e.reason);
    }

    if (sSpliceKitURLImportOriginalTLKTimelineViewPerformDragOperation) {
        return sSpliceKitURLImportOriginalTLKTimelineViewPerformDragOperation(self, _cmd, draggingInfo);
    }
    return 0;
}

static BOOL SpliceKitURLImport_swizzled_FFFileImporter_validateURLs(id self,
                                                                    SEL _cmd,
                                                                    id urls,
                                                                    id urlsInfo,
                                                                    id importLocation,
                                                                    BOOL showWarnings,
                                                                    id window,
                                                                    BOOL copyFiles,
                                                                    id *acceptedURLs,
                                                                    id options) {
    NSMutableDictionary<NSURL *, NSURL *> *rewriteMap = [NSMutableDictionary dictionary];
    id rewrittenURLs = SpliceKitURLImportRewriteURLCollection(urls, rewriteMap);
    id rewrittenURLsInfo = rewriteMap.count > 0
        ? SpliceKitURLImportRemapObject(urlsInfo, rewriteMap)
        : urlsInfo;

    NSUInteger inputCount = [urls respondsToSelector:@selector(count)] ? [urls count] : 0;
    if (rewriteMap.count > 0) {
        SpliceKit_log(@"[VP9Import] Rewrote %lu of %lu URL(s) before FFFileImporter validation",
                      (unsigned long)rewriteMap.count, (unsigned long)inputCount);
    }

    BOOL result = NO;
    if (sSpliceKitURLImportOriginalFFFileImporterValidateURLs) {
        result = sSpliceKitURLImportOriginalFFFileImporterValidateURLs(self,
                                                                       _cmd,
                                                                       rewrittenURLs,
                                                                       rewrittenURLsInfo,
                                                                       importLocation,
                                                                       showWarnings,
                                                                       window,
                                                                       copyFiles,
                                                                       acceptedURLs,
                                                                       options);
    }

    // FCP's downstream processFiles:/_importBackgroundTask path accesses
    // keywordSets[i] in parallel with fileURLs[i]. If validation rejected any
    // URL, the counts diverge and -[__NSArrayM removeObjectsInRange:] (or
    // objectAtIndexedSubscript:) throws NSRangeException. This is an FCP
    // latent bug that surfaces any time our rewrite leads to a rejection —
    // even when the rewritten MP4 is technically valid, FCP's preflight can
    // still reject edge cases.
    //
    // Mitigation: after the real validateURLs runs, log counts so we can
    // diagnose mismatches, and normalize the ivars to match our rewriteMap.
    // The accepted-URL rewrite in importToEvent only fires on the instance
    // import path; mirror it here so the class-method path gets it too.
    if (rewriteMap.count > 0) {
        @try {
            NSUInteger acceptedCount =
                (acceptedURLs && *acceptedURLs && [(id)*acceptedURLs respondsToSelector:@selector(count)])
                    ? [(id)*acceptedURLs count] : 0;
            SpliceKit_log(@"[VP9Import] validateURLs returned result=%d acceptedURLs.count=%lu input.count=%lu",
                          (int)result, (unsigned long)acceptedCount, (unsigned long)inputCount);
            if (acceptedCount != inputCount) {
                SpliceKit_log(@"[VP9Import] WARNING: acceptedURLs.count != input.count — FCP rejected some rewrites. _importBackgroundTask may crash on keywordSets[i] overrun.");
            }

            Ivar importURLsIvar = class_getInstanceVariable(object_getClass(self), "_importURLs");
            Ivar acceptedURLsIvar = class_getInstanceVariable(object_getClass(self), "_acceptedURLs");
            if (importURLsIvar) {
                NSUInteger c = [(id)object_getIvar(self, importURLsIvar) respondsToSelector:@selector(count)]
                    ? [(id)object_getIvar(self, importURLsIvar) count] : 0;
                SpliceKit_log(@"[VP9Import] post-validate _importURLs.count=%lu", (unsigned long)c);
            }
            if (acceptedURLsIvar) {
                NSUInteger c = [(id)object_getIvar(self, acceptedURLsIvar) respondsToSelector:@selector(count)]
                    ? [(id)object_getIvar(self, acceptedURLsIvar) count] : 0;
                SpliceKit_log(@"[VP9Import] post-validate _acceptedURLs.count=%lu", (unsigned long)c);
            }

            // Rewrite ivars to fold any remaining original-MKV paths into our
            // shadow-MP4 paths. Safe even if FCP already rewrote — idempotent.
            SpliceKitURLImportRewriteFFFileImporterIvarsIfNeeded(self);
        } @catch (NSException *e) {
            SpliceKit_log(@"[VP9Import] Exception in post-validate instrumentation: %@", e.reason);
        }
    }

    return result;
}

static void SpliceKitURLImport_swizzled_FFFileImporter_scanURLForFiles(id self,
                                                                       SEL _cmd,
                                                                       id url,
                                                                       id fileURLs,
                                                                       id keywordSets,
                                                                       id keywords,
                                                                       id rejectedURLs,
                                                                       id rejectedURLExtensions,
                                                                       void *rejectedReasons) {
    id scannedURL = url;
    @try {
        if ([url isKindOfClass:[NSURL class]] && ((NSURL *)url).isFileURL) {
            NSString *errorText = nil;
            NSURL *rewrittenURL = SpliceKitURLImportMaybeRewriteLocalFileURL((NSURL *)url, &errorText);
            if (rewrittenURL && ![rewrittenURL isEqual:url]) {
                scannedURL = rewrittenURL;
                SpliceKit_log(@"[VP9Import] Rewrote scanned URL %@ -> %@",
                              ((NSURL *)url).path, rewrittenURL.path);
            } else if (errorText.length > 0) {
                SpliceKit_log(@"[VP9Import] Scan rewrite failed for %@: %@. Falling back to original file.",
                              ((NSURL *)url).path, errorText);
            }
        }
    } @catch (NSException *e) {
        SpliceKit_log(@"[VP9Import] Exception while rewriting scan URL: %@", e.reason);
    }

    if (sSpliceKitURLImportOriginalFFFileImporterScanURLForFiles) {
        sSpliceKitURLImportOriginalFFFileImporterScanURLForFiles(self,
                                                                 _cmd,
                                                                 scannedURL,
                                                                 fileURLs,
                                                                 keywordSets,
                                                                 keywords,
                                                                 rejectedURLs,
                                                                 rejectedURLExtensions,
                                                                 rejectedReasons);
    }
}

// Pads a parallel-per-URL array to the URL count so FCP's
// +_importBackgroundTask: can do array[i] without NSRangeException.
// `fill` is the value to use for missing slots — must be a type FCP will
// actually send messages to downstream (e.g. NSSet for keywords, NSDictionary
// for metadata). NSNull survives the index access but crashes in forwarding
// when FCP later calls set/dictionary selectors on it.
static id SpliceKitURLImportPadParallelArray(id candidate,
                                             NSUInteger targetCount,
                                             id fill,
                                             NSString *label) {
    if (targetCount == 0) return candidate;
    if (!candidate || ![candidate isKindOfClass:[NSArray class]]) {
        NSMutableArray *padded = [NSMutableArray arrayWithCapacity:targetCount];
        for (NSUInteger i = 0; i < targetCount; i++) {
            [padded addObject:fill];
        }
        SpliceKit_log(@"[VP9Import] Materialized missing %@ array (%lu entries)",
                      label, (unsigned long)targetCount);
        return padded;
    }

    NSArray *array = (NSArray *)candidate;
    if (array.count >= targetCount) return candidate;

    NSMutableArray *padded = [array mutableCopy];
    NSUInteger missing = targetCount - array.count;
    for (NSUInteger i = 0; i < missing; i++) {
        [padded addObject:fill];
    }
    SpliceKit_log(@"[VP9Import] Padded %@ %lu -> %lu to match URL count",
                  label, (unsigned long)array.count, (unsigned long)targetCount);
    return padded;
}

static id SpliceKitURLImport_swizzled_FFFileImporter_importFileURLs(id self,
                                                                    SEL _cmd,
                                                                    id fileURLs,
                                                                    id fileURLsInfo,
                                                                    id event,
                                                                    int manageFileType,
                                                                    BOOL processNow,
                                                                    BOOL warnClipsAlreadyExist,
                                                                    id keywordSets,
                                                                    id metadataArray,
                                                                    id completionBlock) {
    NSMutableDictionary<NSURL *, NSURL *> *rewriteMap = [NSMutableDictionary dictionary];
    id rewrittenURLs = SpliceKitURLImportRewriteURLCollection(fileURLs, rewriteMap);
    id rewrittenURLsInfo = rewriteMap.count > 0
        ? SpliceKitURLImportRemapObject(fileURLsInfo, rewriteMap)
        : fileURLsInfo;

    if (rewriteMap.count > 0) {
        SpliceKit_log(@"[VP9Import] Rewrote %lu Media Import URL(s) before FFFileImporter class import",
                      (unsigned long)rewriteMap.count);
    }

    // FCP's +_importBackgroundTask: iterates fileURLs and does
    //   keywordSets[i] and metadataArray[i]
    // under the assumption that keywordSets.count == metadataArray.count ==
    // fileURLs.count. When the Media Import UI never prepared keywords for
    // a greyed row (common for our remuxed MKVs), keywordSets can be an
    // empty array and keywordSets[0] throws NSRangeException — which
    // surfaces as a confusing -[__NSArrayM removeObjectsInRange:] crash
    // after exception unwinding. Force-pad both arrays to the URL count so
    // the parallel-index access always stays in range.
    NSUInteger urlCount = [rewrittenURLs respondsToSelector:@selector(count)]
        ? [rewrittenURLs count] : 0;
    // keywords per URL → empty NSSet; metadata per URL → empty NSDictionary.
    // FCP's downstream -newAnchoredSequenceFromAssetRef:...keywords:... sends
    // set-shaped selectors to each entry; handing it NSNull triggers the
    // `_CF_forwarding_prep_0` forwarding-failure crash.
    id safeKeywordSets = SpliceKitURLImportPadParallelArray(keywordSets,
                                                             urlCount,
                                                             [NSSet set],
                                                             @"keywordSets");
    id safeMetadataArray = SpliceKitURLImportPadParallelArray(metadataArray,
                                                               urlCount,
                                                               @{},
                                                               @"metadataArray");

    if (sSpliceKitURLImportOriginalFFFileImporterImportFileURLs) {
        return sSpliceKitURLImportOriginalFFFileImporterImportFileURLs(self,
                                                                       _cmd,
                                                                       rewrittenURLs,
                                                                       rewrittenURLsInfo,
                                                                       event,
                                                                       manageFileType,
                                                                       processNow,
                                                                       warnClipsAlreadyExist,
                                                                       safeKeywordSets,
                                                                       safeMetadataArray,
                                                                       completionBlock);
    }
    return nil;
}

void SpliceKitURLImport_installVP9ImportHook(void) {
    if (sSpliceKitURLImportVP9ImportHookInstalled) return;

    (void)SpliceKitURLImport_installProviderShim();

    Class projectClass = objc_getClass("FFMediaEventProject");
    SEL selector = NSSelectorFromString(@"newClipFromURL:manageFileType:");
    Method method = projectClass ? class_getInstanceMethod(projectClass, selector) : NULL;
    if (!method) {
        SpliceKit_log(@"[VP9Import] FFMediaEventProject.newClipFromURL:manageFileType: not available");
        return;
    }

    sSpliceKitURLImportOriginalNewClipFromURLManageFileType =
        (id (*)(id, SEL, id, int))method_setImplementation(
            method,
            (IMP)SpliceKitURLImport_swizzled_newClipFromURL_manageFileType);

    Class fileImporterClass = objc_getClass("FFFileImporter");
    SEL importToEventSelector = NSSelectorFromString(@"importToEvent:manageFileType:processNow:warnClipsAlreadyExist:error:");
    Method importToEventMethod = fileImporterClass ? class_getInstanceMethod(fileImporterClass, importToEventSelector) : NULL;
    if (importToEventMethod) {
        sSpliceKitURLImportOriginalFFFileImporterImportToEvent =
            (id (*)(id, SEL, id, int, BOOL, BOOL, id *))method_setImplementation(
                importToEventMethod,
                (IMP)SpliceKitURLImport_swizzled_FFFileImporter_importToEvent);
    } else {
        SpliceKit_log(@"[VP9Import] FFFileImporter.importToEvent:... not available");
    }

    SEL validateURLsSelector = NSSelectorFromString(@"validateURLs:withURLsInfo:forImportToLocation:showWarnings:window:copyFiles:acceptedURLs:options:");
    Method validateURLsMethod = fileImporterClass ? class_getInstanceMethod(fileImporterClass, validateURLsSelector) : NULL;
    if (validateURLsMethod) {
        sSpliceKitURLImportOriginalFFFileImporterValidateURLs =
            (BOOL (*)(id, SEL, id, id, id, BOOL, id, BOOL, id *, id))method_setImplementation(
                validateURLsMethod,
                (IMP)SpliceKitURLImport_swizzled_FFFileImporter_validateURLs);
    } else {
        SpliceKit_log(@"[VP9Import] FFFileImporter.validateURLs:... not available");
    }

    SEL scanURLSelector = NSSelectorFromString(@"scanURLForFiles:fileURLs:keywordSets:keywords:rejectedURLs:rejectedURLExtensions:rejectedReasons:");
    Method scanURLMethod = fileImporterClass ? class_getInstanceMethod(fileImporterClass, scanURLSelector) : NULL;
    if (scanURLMethod) {
        sSpliceKitURLImportOriginalFFFileImporterScanURLForFiles =
            (void (*)(id, SEL, id, id, id, id, id, id, void *))method_setImplementation(
                scanURLMethod,
                (IMP)SpliceKitURLImport_swizzled_FFFileImporter_scanURLForFiles);
    } else {
        SpliceKit_log(@"[VP9Import] FFFileImporter.scanURLForFiles:... not available");
    }

    // Re-enabled with keywordSets/metadataArray padding. The earlier crash at
    // +_importBackgroundTask + 420 surfaced as -[__NSArrayM removeObjectsInRange:]
    // after exception unwinding, but the real cause is FCP reading
    // keywordSets[i] and metadataArray[i] in parallel with fileURLs — and
    // those parallel arrays are under-populated when the Media Import UI
    // treated a file as greyed/not-importable. Our swizzle now pads them.
    SEL importFileURLsSelector = NSSelectorFromString(@"importFileURLs:fileURLsInfo:toEvent:manageFileType:processNow:warnClipsAlreadyExist:keywordSets:metadataArray:completionBlock:");
    Method importFileURLsMethod = fileImporterClass ? class_getClassMethod(fileImporterClass, importFileURLsSelector) : NULL;
    if (importFileURLsMethod) {
        sSpliceKitURLImportOriginalFFFileImporterImportFileURLs =
            (id (*)(id, SEL, id, id, id, int, BOOL, BOOL, id, id, id))method_setImplementation(
                importFileURLsMethod,
                (IMP)SpliceKitURLImport_swizzled_FFFileImporter_importFileURLs);
    } else {
        SpliceKit_log(@"[VP9Import] FFFileImporter.importFileURLs:... not available");
    }

    Class timelineViewClass = objc_getClass("TLKTimelineView");
    Method draggingEnteredMethod = timelineViewClass
        ? class_getInstanceMethod(timelineViewClass, @selector(draggingEntered:))
        : NULL;
    if (draggingEnteredMethod) {
        sSpliceKitURLImportOriginalTLKTimelineViewDraggingEntered =
            (NSDragOperation (*)(id, SEL, id))method_setImplementation(
                draggingEnteredMethod,
                (IMP)SpliceKitURLImport_swizzled_TLKTimelineView_draggingEntered);
    } else {
        SpliceKit_log(@"[VP9Import] TLKTimelineView.draggingEntered: not available");
    }

    Method performDragOperationMethod = timelineViewClass
        ? class_getInstanceMethod(timelineViewClass, @selector(performDragOperation:))
        : NULL;
    if (performDragOperationMethod) {
        sSpliceKitURLImportOriginalTLKTimelineViewPerformDragOperation =
            (char (*)(id, SEL, id))method_setImplementation(
                performDragOperationMethod,
                (IMP)SpliceKitURLImport_swizzled_TLKTimelineView_performDragOperation);
    } else {
        SpliceKit_log(@"[VP9Import] TLKTimelineView.performDragOperation: not available");
    }

    sSpliceKitURLImportVP9ImportHookInstalled = YES;
    SpliceKit_log(@"[VP9Import] Installed local-file + Media Import VP9 hooks");
}

void SpliceKitURLImport_bootstrapAtLaunchPhase(NSString *phase) {
    NSString *phaseName = [SpliceKitURLImportTrimmedString(phase) lowercaseString];
    if (phaseName.length == 0) phaseName = @"did-launch";

    if ([phaseName isEqualToString:@"will-launch"] ||
        [phaseName isEqualToString:@"will-finish-launching"]) {
        (void)SpliceKitURLImport_installProviderShim();
        return;
    }

    SpliceKitURLImport_installVP9ImportHook();
}
