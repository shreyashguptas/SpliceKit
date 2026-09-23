// SpliceKit VP9 host-side bootstrap.
//
// At launch we:
//   1. Call VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
//      so VT's decoder list picks up Apple's system VP9 HW decoder for this
//      process. Without this, even VTDecompressionSessionCreate(vp09) returns
//      kVTVideoDecoderNotAvailableNowErr on Apple Silicon.
//   2. Install a minimal FFSourceVideoFig gate override so FCP stops treating
//      VP9/VP8 as "missing codec" when Apple's supplemental decoder is
//      available in-process.
//   3. Leave the proxy decoder bundle available behind
//      SPLICEKIT_VP9_USE_PROXY_DECODER=1 for fallback and A/B testing.

#import "SpliceKit.h"
#import "SpliceKitVP9.h"
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTProfessionalVideoWorkflow.h>
#import <MediaToolbox/MTProfessionalVideoWorkflow.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

extern "C" void VTRegisterSupplementalVideoDecoderIfAvailable(CMVideoCodecType codecType);
extern "C" void VTRegisterVideoDecoderBundleDirectory(CFURLRef directoryURL);

static NSString *const kVP9LogPath = @"/tmp/splicekit-vp9.log";

static void VP9HostLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void VP9HostLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [vp9-host] %@\n", [NSDate date], msg];
    FILE *f = fopen([kVP9LogPath UTF8String], "a");
    if (f) { fputs([line UTF8String], f); fclose(f); }
    NSLog(@"[SK-VP9-host] %@", msg);
}

typedef int64_t (*VP9RegisterVideoCodecsFromAppBundleFn)(CFDictionaryRef _Nullable *);
typedef int64_t (*VP9RegisterVideoCodecsDirectoryFn)(CFURLRef, bool, CFDictionaryRef _Nullable *);
typedef int64_t (*VP9RegisterVideoCodecBundleInProcessFn)(CFBundleRef, CFDictionaryRef _Nullable *);

static IMP sVP9OriginalCodecMissing = NULL;
static IMP sVP9OriginalCodecMissingDueToRosetta = NULL;
static IMP sVP9OriginalCodecDisabledExtension = NULL;
static IMP sVP9OriginalCodecConflictingExtension = NULL;

static BOOL VP9CodecTypeLooksLikeVP9(FourCharCode codecType) {
    return codecType == 'vp09' || codecType == 'vp08';
}

static BOOL VP9CodecNameLooksLikeVP9(NSString *codecName) {
    if (codecName.length == 0) return NO;
    NSString *lower = codecName.lowercaseString;
    return [lower containsString:@"vp9"] || [lower containsString:@"vp8"];
}

static BOOL VP9SourceHasVP9Codec(id self) {
    if (!self) return NO;
    if ([self respondsToSelector:@selector(codecType)]) {
        FourCharCode codecType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, @selector(codecType));
        if (VP9CodecTypeLooksLikeVP9(codecType)) return YES;
    }
    if ([self respondsToSelector:@selector(codecName)]) {
        id codecName = ((id (*)(id, SEL))objc_msgSend)(self, @selector(codecName));
        if ([codecName isKindOfClass:[NSString class]] &&
            VP9CodecNameLooksLikeVP9((NSString *)codecName)) {
            return YES;
        }
    }
    return NO;
}

static BOOL VP9SourceCodecMissingOverride(id self, SEL _cmd) {
    if (VP9SourceHasVP9Codec(self)) return NO;
    if (sVP9OriginalCodecMissing) {
        return ((BOOL (*)(id, SEL))sVP9OriginalCodecMissing)(self, _cmd);
    }
    return NO;
}

static BOOL VP9SourceCodecMissingDueToRosettaOverride(id self, SEL _cmd) {
    if (VP9SourceHasVP9Codec(self)) return NO;
    if (sVP9OriginalCodecMissingDueToRosetta) {
        return ((BOOL (*)(id, SEL))sVP9OriginalCodecMissingDueToRosetta)(self, _cmd);
    }
    return NO;
}

static BOOL VP9SourceCodecDisabledExtensionOverride(id self, SEL _cmd) {
    if (VP9SourceHasVP9Codec(self)) return NO;
    if (sVP9OriginalCodecDisabledExtension) {
        return ((BOOL (*)(id, SEL))sVP9OriginalCodecDisabledExtension)(self, _cmd);
    }
    return NO;
}

static BOOL VP9SourceCodecConflictingExtensionOverride(id self, SEL _cmd) {
    if (VP9SourceHasVP9Codec(self)) return NO;
    if (sVP9OriginalCodecConflictingExtension) {
        return ((BOOL (*)(id, SEL))sVP9OriginalCodecConflictingExtension)(self, _cmd);
    }
    return NO;
}

static BOOL VP9HookMethod(Class cls, SEL sel, IMP replacement, IMP *outOriginal, NSString *label) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        VP9HostLog(@"%@ method missing", label);
        return NO;
    }
    if (*outOriginal) {
        VP9HostLog(@"%@ already installed", label);
        return YES;
    }
    *outOriginal = method_setImplementation(method, replacement);
    VP9HostLog(@"installed %@", label);
    return *outOriginal != NULL;
}

static BOOL VP9ExtensionGateHooksEnabled(void) {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"SPLICEKIT_VP9_ENABLE_EXTENSION_GATE_HOOKS"];
    if (value.length == 0) return NO;
    NSString *lower = value.lowercaseString;
    return [lower isEqualToString:@"1"] ||
           [lower isEqualToString:@"yes"] ||
           [lower isEqualToString:@"true"] ||
           [lower isEqualToString:@"on"];
}

static void VP9InstallAvailabilityHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class sourceVideoFig = objc_getClass("FFSourceVideoFig");
        if (!sourceVideoFig) {
            VP9HostLog(@"FFSourceVideoFig missing; VP9 gate hooks not installed");
            return;
        }

        VP9HookMethod(sourceVideoFig,
                      @selector(codecMissing),
                      (IMP)VP9SourceCodecMissingOverride,
                      &sVP9OriginalCodecMissing,
                      @"FFSourceVideoFig.codecMissing");
        VP9HookMethod(sourceVideoFig,
                      @selector(codecMissingDueToRosetta),
                      (IMP)VP9SourceCodecMissingDueToRosettaOverride,
                      &sVP9OriginalCodecMissingDueToRosetta,
                      @"FFSourceVideoFig.codecMissingDueToRosetta");

        if (VP9ExtensionGateHooksEnabled()) {
            VP9HookMethod(sourceVideoFig,
                          @selector(codecIsDisabledExtension),
                          (IMP)VP9SourceCodecDisabledExtensionOverride,
                          &sVP9OriginalCodecDisabledExtension,
                          @"FFSourceVideoFig.codecIsDisabledExtension");
            VP9HookMethod(sourceVideoFig,
                          @selector(codecIsConflictingExtension),
                          (IMP)VP9SourceCodecConflictingExtensionOverride,
                          &sVP9OriginalCodecConflictingExtension,
                          @"FFSourceVideoFig.codecIsConflictingExtension");
        }
    });
}

static BOOL VP9GateHooksEnabled(void) {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"SPLICEKIT_VP9_ENABLE_GATE_HOOKS"];
    if (value.length == 0) return YES;
    NSString *lower = value.lowercaseString;
    return [lower isEqualToString:@"1"] ||
           [lower isEqualToString:@"yes"] ||
           [lower isEqualToString:@"true"] ||
           [lower isEqualToString:@"on"];
}

static BOOL VP9UseProxyDecoder(void) {
    NSString *value = [[[NSProcessInfo processInfo] environment] objectForKey:@"SPLICEKIT_VP9_USE_PROXY_DECODER"];
    if (value.length == 0) return NO;
    NSString *lower = value.lowercaseString;
    return [lower isEqualToString:@"1"] ||
           [lower isEqualToString:@"yes"] ||
           [lower isEqualToString:@"true"] ||
           [lower isEqualToString:@"on"];
}

static NSString *VP9BundleRootPath(NSString *subpath) {
    NSString *pluginsPath = [[NSBundle mainBundle] builtInPlugInsPath];
    if (pluginsPath.length == 0 || subpath.length == 0) return nil;
    return [pluginsPath stringByAppendingPathComponent:subpath];
}

static NSURL *VP9BundleRootURL(NSString *subpath) {
    NSString *path = VP9BundleRootPath(subpath);
    if (path.length == 0) return nil;
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static NSString *VP9ResolveProCorePath(void) {
    Class pcClass = objc_getClass("PCFeatureFlags");
    if (pcClass) {
        NSBundle *bundle = [NSBundle bundleForClass:pcClass];
        if (bundle.executablePath.length > 0) return bundle.executablePath;
    }
    NSString *privateFW = [[NSBundle mainBundle] privateFrameworksPath];
    if (privateFW.length > 0) {
        NSString *candidate = [privateFW stringByAppendingPathComponent:
            @"ProCore.framework/Versions/A/ProCore"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) return candidate;
    }
    return @"/Applications/Final Cut Pro.app/Contents/Frameworks/ProCore.framework/Versions/A/ProCore";
}

static void *VP9OpenProCore(void) {
    NSString *path = VP9ResolveProCorePath();
    void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (!h) h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!h) VP9HostLog(@"ProCore dlopen failed: %s", dlerror());
    return h;
}

static BOOL VP9LoadBundleAtPath(NSString *path, NSString *label) {
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        VP9HostLog(@"[%@] bundle missing at %@", label, path ?: @"<nil>");
        return NO;
    }
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (!bundle) {
        VP9HostLog(@"[%@] NSBundle bundleWithPath returned nil", label);
        return NO;
    }
    NSError *error = nil;
    BOOL loaded = bundle.loaded || [bundle loadAndReturnError:&error];
    VP9HostLog(@"[%@] load result=%@ error=%@", label, loaded ? @"YES" : @"NO",
               error.localizedDescription ?: @"<none>");
    return loaded;
}

static void VP9RegisterProfessionalWorkflowBundle(void) {
    VP9HostLog(@"registration start");

    // Step 1 — the critical one. Light up Apple's supplemental system VP9
    // decoder so VT can actually create sessions. Without this call,
    // VTDecompressionSessionCreate(vp09) returns kVTVideoDecoderNotAvailableNowErr
    // even though the decoder plug-in is listed in VTCopyVideoDecoderList.
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
    VP9HostLog(@"VTRegisterSupplementalVideoDecoderIfAvailable(vp09) called");

    if (VP9GateHooksEnabled()) {
        VP9InstallAvailabilityHooks();
    }

    if (!VP9UseProxyDecoder()) {
        VP9HostLog(@"using direct system VP9 decoder path; proxy registration skipped");
        VP9HostLog(@"registration end");
        return;
    }

    NSString *decoderBundlePath = VP9BundleRootPath(@"Codecs/SpliceKitVP9Decoder.bundle");
    NSURL *codecsURL = VP9BundleRootURL(@"Codecs");
    VP9HostLog(@"decoderBundlePath=%@ exists=%d",
               decoderBundlePath ?: @"<nil>",
               decoderBundlePath.length > 0 &&
                   [[NSFileManager defaultManager] fileExistsAtPath:decoderBundlePath]);

    // Step 2 — manually dlopen the bundle executable. Belt-and-suspenders so
    // the factory symbol is resolvable even before ProCore walks the directory.
    VP9LoadBundleAtPath(decoderBundlePath, @"decoder");

    // Step 3 — VT decoder bundle directory (public SPI).
    if (codecsURL) {
        VTRegisterVideoDecoderBundleDirectory((__bridge CFURLRef)codecsURL);
        VP9HostLog(@"VTRegisterVideoDecoderBundleDirectory(%@)", codecsURL.path);
    }

    // Step 4 — ProCore registration. This is the load-bearing step that
    // populates FCP's internal codec table. Without it Flexo's probe never
    // recognizes vp09 even though VT can decode it.
    void *proCore = VP9OpenProCore();
    if (!proCore) {
        VP9HostLog(@"ProCore unavailable — giving up");
        return;
    }

    VP9RegisterVideoCodecBundleInProcessFn registerBundle =
        (VP9RegisterVideoCodecBundleInProcessFn)dlsym(proCore,
            "_Z47PCMediaPlugInsRegisterVideoCodecBundleInProcessP10__CFBundlePP14__CFDictionary");
    VP9HostLog(@"PCMediaPlugInsRegisterVideoCodecBundleInProcess available=%d",
               registerBundle != NULL);

    if (registerBundle && decoderBundlePath.length > 0) {
        NSURL *bundleURL = [NSURL fileURLWithPath:decoderBundlePath isDirectory:YES];
        CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (CFURLRef)bundleURL);
        if (bundle) {
            CFDictionaryRef codecNames = NULL;
            int64_t result = registerBundle(bundle, &codecNames);
            VP9HostLog(@"PCMediaPlugInsRegisterVideoCodecBundleInProcess result=%lld", result);
            if (codecNames) {
                NSDictionary *map = (__bridge NSDictionary *)codecNames;
                VP9HostLog(@"codec name map count=%lu", (unsigned long)map.count);
                CFRelease(codecNames);
            }
            CFRelease(bundle);
        } else {
            VP9HostLog(@"CFBundleCreate returned nil for %@", decoderBundlePath);
        }
    }

    // Also poke the directory variant — some code
    // paths look up codecs via directory enumeration rather than a specific
    // bundle.
    VP9RegisterVideoCodecsDirectoryFn registerDirectory =
        (VP9RegisterVideoCodecsDirectoryFn)dlsym(proCore,
            "_Z42PCMediaPlugInsRegisterVideoCodecsDirectoryPK7__CFURLbPP14__CFDictionary");
    if (registerDirectory && codecsURL) {
        CFDictionaryRef codecNames = NULL;
        int64_t result = registerDirectory((__bridge CFURLRef)codecsURL, true, &codecNames);
        VP9HostLog(@"PCMediaPlugInsRegisterVideoCodecsDirectory result=%lld", result);
        if (codecNames) CFRelease(codecNames);
    }

    // Finalize with the public pro-video-workflow sweep. Safe to call; it's a
    // no-op for anything already registered.
    VTRegisterProfessionalVideoWorkflowVideoDecoders();
    VP9HostLog(@"VTRegisterProfessionalVideoWorkflowVideoDecoders called");

    VP9HostLog(@"registration end");
}

extern "C" void SpliceKitVP9_Bootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            VP9RegisterProfessionalWorkflowBundle();
        }
    });
}
