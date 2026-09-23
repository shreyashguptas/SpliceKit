#import "SpliceKit.h"
#import "SpliceKitMKV.h"
#import "SpliceKitURLImport.h"

#import <MediaToolbox/MediaToolbox.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

// Private MediaToolbox / VideoToolbox helpers used by FCP's pro-workflow path.
extern void MTRegisterPluginFormatReaderBundleDirectory(CFURLRef directoryURL);
extern void MTRegisterProfessionalVideoWorkflowFormatReaders(void);
extern void VTRegisterProfessionalVideoWorkflowVideoDecoders(void);

// ProCore private registration entry point.
typedef int64_t (*MKVPCRegisterFormatReadersFromDirectoryFn)(CFURLRef, bool);
typedef int64_t (*MKVPCRegisterFormatReadersFromAppBundleFn)(bool);
typedef int64_t (*MKVPCRegisterMediaExtensionFormatReadersFn)(void);

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

static BOOL SpliceKitMKVIsMatroskaUTIString(NSString *identifier) {
    if (identifier.length == 0) return NO;
    return [identifier isEqualToString:@"com.splicekit.matroska-movie"] ||
           [identifier isEqualToString:@"com.splicekit.webm-movie"] ||
           [identifier isEqualToString:@"org.matroska.mkv"] ||
           [identifier isEqualToString:@"org.webmproject.webm"] ||
           [identifier isEqualToString:@"uk.tarun.vidcore.mkv"] ||
           [identifier isEqualToString:@"uk.tarun.vidcore.webm"];
}

// Matroska UTIs conform to these "gate" types so AVFoundation / FCP stop
// treating the file as unknown. We intentionally keep the list narrow to
// media-shaped types.
static BOOL SpliceKitMKVShouldConformMatroskaTo(NSString *targetIdentifier) {
    if (targetIdentifier.length == 0) return NO;
    return [targetIdentifier isEqualToString:@"public.movie"] ||
           [targetIdentifier isEqualToString:@"public.audiovisual-content"] ||
           [targetIdentifier isEqualToString:@"public.video"] ||
           [targetIdentifier isEqualToString:@"public.mpeg-4"] ||
           [targetIdentifier isEqualToString:@"public.quicktime-movie"] ||
           [targetIdentifier isEqualToString:@"public.content"] ||
           [targetIdentifier isEqualToString:@"public.data"] ||
           [targetIdentifier isEqualToString:@"public.item"];
}

static BOOL SpliceKitMKVIsMatroskaExtension(NSString *ext) {
    if (ext.length == 0) return NO;
    return [ext caseInsensitiveCompare:@"mkv"] == NSOrderedSame
        || [ext caseInsensitiveCompare:@"webm"] == NSOrderedSame
        || [ext caseInsensitiveCompare:@"mka"] == NSOrderedSame
        || [ext caseInsensitiveCompare:@"mk3d"] == NSOrderedSame;
}

static BOOL SpliceKitMKVIsMatroskaURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]] || !url.isFileURL) return NO;
    return SpliceKitMKVIsMatroskaExtension(url.pathExtension);
}

static BOOL SpliceKitMKVMIMEOverrideEnabled(void) {
    static BOOL value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *off = getenv("SPLICEKIT_MKV_MIME_OFF");
        value = (off && (off[0] == '1' || off[0] == 'y' || off[0] == 'Y')) ? NO : YES;
    });
    return value;
}

// -----------------------------------------------------------------------
// UTType conformsToType: override
// -----------------------------------------------------------------------

static IMP sSpliceKitMKVOriginalUTTypeConformsToIMP = NULL;

static BOOL SpliceKitMKVUTTypeConformsToOverride(id self, SEL _cmd, id target) {
    NSString *selfID = nil;
    NSString *targetID = nil;
    @try {
        if ([self respondsToSelector:@selector(identifier)]) {
            selfID = ((NSString *(*)(id, SEL))objc_msgSend)(self, @selector(identifier));
        }
        if ([target respondsToSelector:@selector(identifier)]) {
            targetID = ((NSString *(*)(id, SEL))objc_msgSend)(target, @selector(identifier));
        }
    } @catch (NSException *e) {
        // fall through
    }

    if (SpliceKitMKVIsMatroskaUTIString(selfID) && SpliceKitMKVShouldConformMatroskaTo(targetID)) {
        return YES;
    }

    if (sSpliceKitMKVOriginalUTTypeConformsToIMP) {
        return ((BOOL (*)(id, SEL, id))sSpliceKitMKVOriginalUTTypeConformsToIMP)(self, _cmd, target);
    }
    return NO;
}

static BOOL SpliceKitMKV_installUTTypeConformanceHook(void) {
    if (sSpliceKitMKVOriginalUTTypeConformsToIMP) return YES;
    Class utTypeClass = objc_getClass("UTType");
    if (!utTypeClass) {
        SpliceKit_log(@"[MKVHost] UTType class unavailable — conformance hook skipped");
        return NO;
    }
    Method m = class_getInstanceMethod(utTypeClass, @selector(conformsToType:));
    if (!m) {
        SpliceKit_log(@"[MKVHost] UTType conformsToType: not found — conformance hook skipped");
        return NO;
    }
    sSpliceKitMKVOriginalUTTypeConformsToIMP =
        method_setImplementation(m, (IMP)SpliceKitMKVUTTypeConformsToOverride);
    SpliceKit_log(@"[MKVHost] installed -[UTType conformsToType:] swizzle");
    return sSpliceKitMKVOriginalUTTypeConformsToIMP != NULL;
}

// -----------------------------------------------------------------------
// AVURLAsset initWithURL:options: + +URLAssetWithURL:options: overrides
// -----------------------------------------------------------------------

static IMP sSpliceKitMKVOriginalAVURLAssetInitIMP = NULL;
static IMP sSpliceKitMKVOriginalAVURLAssetClassMethodIMP = NULL;

static NSDictionary *SpliceKitMKVOptionsWithMIMEOverride(NSURL *url, NSDictionary *options) {
    if (!SpliceKitMKVMIMEOverrideEnabled()) return options;

    NSMutableDictionary *modified = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
    if (!modified[AVURLAssetOverrideMIMETypeKey]) {
        // Route through AVFoundation's QuickTime path.
        // Our MT plugin's CMMatchingInfo then routes the inner container parse
        // to libwebm via the UTI/extension match.
        modified[AVURLAssetOverrideMIMETypeKey] = @"video/quicktime";
        SpliceKit_log(@"[MKVHost] av-hook: injected MIME override video/quicktime for %@", url.path);
    }
    return modified;
}

// -----------------------------------------------------------------------
// Shadow URL cache + substitution
// -----------------------------------------------------------------------
//
// AVFoundation refuses to parse Matroska bytes even with every registration
// and MIME override in place. Fallback: substitute the URL AVURLAsset opens
// with a previously-remuxed shadow MP4. That gives FCP's Media Import
// browser correct Start/End/Duration/ProjectionMode columns and enables
// viewer preview, since the shadow is a valid ISO BMFF file.
//
// The cache ensures we only run the ~500ms remux once per source path per
// launch. Subsequent AVURLAsset opens return from the cache instantly.

static NSMutableDictionary<NSString *, NSURL *> *sSpliceKitMKVShadowCache;
static NSLock *sSpliceKitMKVShadowLock;

static void SpliceKitMKV_ensureShadowCache(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sSpliceKitMKVShadowCache = [NSMutableDictionary dictionary];
        sSpliceKitMKVShadowLock = [[NSLock alloc] init];
    });
}

static NSURL *SpliceKitMKV_CopyShadowForURL(NSURL *fileURL) {
    if (!fileURL || !fileURL.isFileURL) return nil;
    SpliceKitMKV_ensureShadowCache();

    NSString *key = fileURL.path.stringByStandardizingPath ?: @"";
    if (key.length == 0) return nil;

    [sSpliceKitMKVShadowLock lock];
    NSURL *cached = sSpliceKitMKVShadowCache[key];
    [sSpliceKitMKVShadowLock unlock];
    if (cached) {
        // Validate still on disk — user may have cleaned the shadow dir.
        if ([[NSFileManager defaultManager] fileExistsAtPath:cached.path]) {
            return cached;
        }
        [sSpliceKitMKVShadowLock lock];
        [sSpliceKitMKVShadowCache removeObjectForKey:key];
        [sSpliceKitMKVShadowLock unlock];
    }

    NSString *err = nil;
    NSURL *shadow = SpliceKitURLImport_CopyShadowURL(fileURL, &err);
    if (!shadow || [shadow isEqual:fileURL]) {
        if (err.length > 0) {
            SpliceKit_log(@"[MKVHost] shadow remux failed for %@: %@", fileURL.path, err);
        }
        return nil;
    }

    [sSpliceKitMKVShadowLock lock];
    sSpliceKitMKVShadowCache[key] = shadow;
    [sSpliceKitMKVShadowLock unlock];
    SpliceKit_log(@"[MKVHost] shadow cached: %@ -> %@", fileURL.lastPathComponent, shadow.lastPathComponent);
    return shadow;
}

static id SpliceKitMKVAVURLAssetInitOverride(id self, SEL _cmd, NSURL *url, NSDictionary *options) {
    NSURL *effectiveURL = url;
    NSDictionary *effectiveOptions = options;
    @try {
        if (SpliceKitMKVIsMatroskaURL(url)) {
            NSURL *shadow = SpliceKitMKV_CopyShadowForURL(url);
            if (shadow && ![shadow isEqual:url]) {
                effectiveURL = shadow;
            } else {
                // Shadow unavailable — fall back to MIME override so at least
                // AVFoundation doesn't reject the URL purely on type-lookup.
                effectiveOptions = SpliceKitMKVOptionsWithMIMEOverride(url, options);
            }
        }
    } @catch (NSException *e) {
        effectiveURL = url;
        effectiveOptions = options;
    }

    if (sSpliceKitMKVOriginalAVURLAssetInitIMP) {
        return ((id (*)(id, SEL, NSURL *, NSDictionary *))sSpliceKitMKVOriginalAVURLAssetInitIMP)(
            self, _cmd, effectiveURL, effectiveOptions);
    }
    return self;
}

static id SpliceKitMKVAVURLAssetClassMethodOverride(id self, SEL _cmd, NSURL *url, NSDictionary *options) {
    NSURL *effectiveURL = url;
    NSDictionary *effectiveOptions = options;
    @try {
        if (SpliceKitMKVIsMatroskaURL(url)) {
            NSURL *shadow = SpliceKitMKV_CopyShadowForURL(url);
            if (shadow && ![shadow isEqual:url]) {
                effectiveURL = shadow;
            } else {
                effectiveOptions = SpliceKitMKVOptionsWithMIMEOverride(url, options);
            }
        }
    } @catch (NSException *e) {
        effectiveURL = url;
        effectiveOptions = options;
    }

    if (sSpliceKitMKVOriginalAVURLAssetClassMethodIMP) {
        return ((id (*)(id, SEL, NSURL *, NSDictionary *))sSpliceKitMKVOriginalAVURLAssetClassMethodIMP)(
            self, _cmd, effectiveURL, effectiveOptions);
    }
    return nil;
}

// -----------------------------------------------------------------------
// FFImportFileSystemNodeData.isValid override
// -----------------------------------------------------------------------
//
// The Media Import browser's row-selection + row-greyout logic consults
// -[FFImportFileSystemNodeData isValid] (via
//  -[FFImportOrganizerFilmListViewController shouldSelectItem:]). Because the
// MKV's UTI chain doesn't match FFProviderFig.utis through -conformsToType:,
// fresh nodes for a .mkv currently cache _isValid = @NO on first query —
// FFProvider's class-lookup returns nil for uk.tarun.vidcore.mkv.
// Extension fallback works in -providerClassForExtension: but isValid's
// direct call only consults the UTI branch.
//
// Force-return YES for any Matroska/WebM file URL so the row unifies with
// the rest of the folder: left-click selects it, text isn't dimmed, and
// Import All accepts it through the normal path.

static IMP sSpliceKitMKVOriginalIsValidIMP = NULL;

static BOOL SpliceKitMKVNodeDataIsValidOverride(id self, SEL _cmd) {
    @try {
        NSURL *url = nil;
        if ([self respondsToSelector:@selector(url)]) {
            url = ((NSURL *(*)(id, SEL))objc_msgSend)(self, @selector(url));
        }
        if (url && SpliceKitMKVIsMatroskaURL(url)) {
            return YES;
        }
    } @catch (NSException *) {
        // fall through to original
    }
    if (sSpliceKitMKVOriginalIsValidIMP) {
        return ((BOOL (*)(id, SEL))sSpliceKitMKVOriginalIsValidIMP)(self, _cmd);
    }
    return NO;
}

static BOOL SpliceKitMKV_installNodeDataValidityHook(void) {
    if (sSpliceKitMKVOriginalIsValidIMP) return YES;
    Class nodeDataClass = objc_getClass("FFImportFileSystemNodeData");
    if (!nodeDataClass) {
        SpliceKit_log(@"[MKVHost] FFImportFileSystemNodeData unavailable — isValid hook skipped");
        return NO;
    }
    Method m = class_getInstanceMethod(nodeDataClass, @selector(isValid));
    if (!m) {
        SpliceKit_log(@"[MKVHost] FFImportFileSystemNodeData.isValid not found");
        return NO;
    }
    sSpliceKitMKVOriginalIsValidIMP =
        method_setImplementation(m, (IMP)SpliceKitMKVNodeDataIsValidOverride);
    SpliceKit_log(@"[MKVHost] installed -[FFImportFileSystemNodeData isValid] swizzle");
    return sSpliceKitMKVOriginalIsValidIMP != NULL;
}

static BOOL SpliceKitMKV_installAVURLAssetMIMEHook(void) {
    Class cls = objc_getClass("AVURLAsset");
    if (!cls) {
        SpliceKit_log(@"[MKVHost] AVURLAsset class unavailable — MIME hook skipped");
        return NO;
    }

    if (!sSpliceKitMKVOriginalAVURLAssetInitIMP) {
        Method m = class_getInstanceMethod(cls, @selector(initWithURL:options:));
        if (m) {
            sSpliceKitMKVOriginalAVURLAssetInitIMP =
                method_setImplementation(m, (IMP)SpliceKitMKVAVURLAssetInitOverride);
            SpliceKit_log(@"[MKVHost] installed -[AVURLAsset initWithURL:options:] swizzle");
        }
    }

    if (!sSpliceKitMKVOriginalAVURLAssetClassMethodIMP) {
        Method m = class_getClassMethod(cls, @selector(URLAssetWithURL:options:));
        if (m) {
            sSpliceKitMKVOriginalAVURLAssetClassMethodIMP =
                method_setImplementation(m, (IMP)SpliceKitMKVAVURLAssetClassMethodOverride);
            SpliceKit_log(@"[MKVHost] installed +[AVURLAsset URLAssetWithURL:options:] swizzle");
        }
    }

    return (sSpliceKitMKVOriginalAVURLAssetInitIMP != NULL) ||
           (sSpliceKitMKVOriginalAVURLAssetClassMethodIMP != NULL);
}

// -----------------------------------------------------------------------
// Plugin-directory registration (MediaToolbox + ProCore)
// -----------------------------------------------------------------------

static NSURL *SpliceKitMKVFormatReadersDirectory(void) {
    NSString *appDir = [[NSBundle mainBundle] bundlePath];
    if (appDir.length == 0) return nil;
    NSString *pluginPath = [appDir stringByAppendingPathComponent:@"Contents/PlugIns/FormatReaders"];
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:pluginPath isDirectory:&isDir] || !isDir) {
        return nil;
    }
    return [NSURL fileURLWithPath:pluginPath isDirectory:YES];
}

static NSString *SpliceKitMKVBundlePath(void) {
    NSURL *dir = SpliceKitMKVFormatReadersDirectory();
    if (!dir) return nil;
    NSString *path = [dir.path stringByAppendingPathComponent:@"SpliceKitMKVImport.bundle"];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

// -----------------------------------------------------------------------
// Entry point
// -----------------------------------------------------------------------

void SpliceKitMKV_Bootstrap(void) {
    NSString *bundlePath = SpliceKitMKVBundlePath();
    if (!bundlePath) {
        SpliceKit_log(@"[MKVHost] SpliceKitMKVImport.bundle not found under PlugIns/FormatReaders — skipping bootstrap");
        return;
    }

    // 1. Force-load the bundle so its constructor fires and the factory
    //    function is resolvable when MT's plugin registry consults it.
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSError *loadError = nil;
    BOOL loaded = [bundle loadAndReturnError:&loadError];
    SpliceKit_log(@"[MKVHost] bundle=%@ loaded=%d%@",
                  bundlePath, (int)loaded,
                  loadError ? [NSString stringWithFormat:@" error=%@", loadError.localizedDescription] : @"");

    // 2. UTI conformance swizzle — make Matroska UTIs look like public.movie
    //    etc. so AVFoundation's gate trusts them.
    SpliceKitMKV_installUTTypeConformanceHook();

    // 3. AVURLAsset MIME override swizzle — inject video/quicktime for MKV/WebM
    //    files so AVFoundation routes through the QT path (and ultimately
    //    through MT's plugin registry where our bundle is registered).
    SpliceKitMKV_installAVURLAssetMIMEHook();

    // 3a. FFImportFileSystemNodeData.isValid override — the Media Import
    //     browser uses isValid to decide whether a row is selectable +
    //     drawn non-greyed. Without this shim, .mkv rows stay dim even
    //     though our provider shim teaches FCP the extension.
    SpliceKitMKV_installNodeDataValidityHook();

    // 4. Tell MediaToolbox about our plugin bundle. Process-local registration.
    NSURL *dirURL = SpliceKitMKVFormatReadersDirectory();
    if (dirURL) {
        SpliceKit_log(@"[MKVHost] MTRegisterPluginFormatReaderBundleDirectory %@", dirURL.path);
        MTRegisterPluginFormatReaderBundleDirectory((__bridge CFURLRef)dirURL);
    }

    // 5. Kick the professional-workflow registration paths. These load
    //    additional Apple format readers + video decoders that the standard
    //    AVFoundation plugin sweep skips in non-pro apps. MKV depends on
    //    this being called too — same helper symbols.
    @try {
        MTRegisterProfessionalVideoWorkflowFormatReaders();
        SpliceKit_log(@"[MKVHost] MTRegisterProfessionalVideoWorkflowFormatReaders called");
    } @catch (NSException *e) {
        SpliceKit_log(@"[MKVHost] MTRegisterProfessionalVideoWorkflowFormatReaders failed: %@", e.reason);
    }
    @try {
        VTRegisterProfessionalVideoWorkflowVideoDecoders();
        SpliceKit_log(@"[MKVHost] VTRegisterProfessionalVideoWorkflowVideoDecoders called");
    } @catch (NSException *e) {
        SpliceKit_log(@"[MKVHost] VTRegisterProfessionalVideoWorkflowVideoDecoders failed: %@", e.reason);
    }

    // 6. ProCore's own media plug-in registry. FCP consults this before MT for
    //    the Media Import preflight, so skipping it leaves Matroska files
    //    greyed out even with MT fully aware of the plugin.
    void *procore = RTLD_DEFAULT;
    MKVPCRegisterFormatReadersFromDirectoryFn registerFromDir =
        (MKVPCRegisterFormatReadersFromDirectoryFn)dlsym(
            procore,
            "_Z48PCMediaPlugInsRegisterFormatReadersFromDirectoryPK7__CFURLb");
    if (registerFromDir && dirURL) {
        int64_t result = registerFromDir((__bridge CFURLRef)dirURL, true);
        SpliceKit_log(@"[MKVHost] ProCore register-from-directory result=%lld", result);
    } else {
        SpliceKit_log(@"[MKVHost] ProCore register-from-directory symbol not resolved");
    }

    MKVPCRegisterFormatReadersFromAppBundleFn registerFromAppBundle =
        (MKVPCRegisterFormatReadersFromAppBundleFn)dlsym(
            procore,
            "_Z48PCMediaPlugInsRegisterFormatReadersFromAppBundleb");
    if (registerFromAppBundle) {
        int64_t result = registerFromAppBundle(true);
        SpliceKit_log(@"[MKVHost] ProCore register-from-app-bundle result=%lld", result);
    }

    // ProCore's MediaExtension format-reader helper. Even though
    // we don't ship a MediaExtension appex, triggering this ensures the MT
    // plugin registry gets fully flushed into ProCore's importer cache.
    MKVPCRegisterMediaExtensionFormatReadersFn registerMediaExt =
        (MKVPCRegisterMediaExtensionFormatReadersFn)dlsym(
            procore,
            "_Z49PCMediaPlugInsRegisterMediaExtensionFormatReadersv");
    if (registerMediaExt) {
        int64_t result = registerMediaExt();
        SpliceKit_log(@"[MKVHost] ProCore register-media-extension-format-readers result=%lld", result);
    }

    SpliceKit_log(@"[MKVHost] bootstrap complete");
}

void SpliceKitMKV_bootstrapAtLaunchPhase(NSString *phase) {
    NSString *phaseName = phase ? [phase lowercaseString] : @"did-launch";

    if ([phaseName isEqualToString:@"will-launch"] ||
        [phaseName isEqualToString:@"will-finish-launching"]) {
        // Install the UTI + AVURLAsset hooks as early as possible — before
        // FCP's import browser does its first metadata probe. Deferring these
        // to did-launch means the browser's initial greyout decision happens
        // without our overrides in place.
        SpliceKitMKV_installUTTypeConformanceHook();
        SpliceKitMKV_installAVURLAssetMIMEHook();
        SpliceKitMKV_installNodeDataValidityHook();
        SpliceKit_log(@"[MKVHost] will-launch hooks installed");
        return;
    }

    SpliceKitMKV_Bootstrap();
}
