//
//  SpliceKit.m
//  Main entry point — this is where everything starts.
//
//  The __attribute__((constructor)) at the bottom fires before FCP's main() runs.
//  From there we: set up logging, patch out crash-prone code paths (CloudContent,
//  shutdown hang), and wait for the app to finish launching. Once it does, we
//  install our menu, toolbar buttons, feature swizzles, and spin up the server.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitLua.h"
#import "SpliceKitPlugins.h"
#import "SpliceKitCommandPalette.h"
#import "SpliceKitDebugUI.h"
#import "SpliceKitLiveCam.h"
#import "SpliceKitURLImport.h"
#import "SpliceKitMKV.h"
#import "SpliceKitVP9.h"
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <math.h>
#import <signal.h>
#import <execinfo.h>
#import <time.h>
#import <setjmp.h>
#import <pthread.h>
#import "SpliceKitMenus.h"

#pragma mark - Logging
//
// We log to both NSLog (shows up in Console.app) and a file on disk.
// The file is invaluable for debugging crashes that happened while you
// weren't looking at Console — just `cat ~/Library/Logs/SpliceKit/splicekit.log`.
//

static NSString *sLogPath = nil;
static NSFileHandle *sLogHandle = nil;
static dispatch_queue_t sLogQueue = nil;
static int sLogFD = -1;

static NSString *SpliceKit_logTimestamp(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    struct tm localTime;
    localtime_r(&ts.tv_sec, &localTime);

    char buffer[32];
    strftime(buffer, sizeof(buffer), "%H:%M:%S", &localTime);
    return [NSString stringWithFormat:@"%s.%03ld", buffer, ts.tv_nsec / 1000000L];
}

static void SpliceKit_initLogging(void) {
    sLogQueue = dispatch_queue_create("com.splicekit.log", DISPATCH_QUEUE_SERIAL);

    NSString *logDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    sLogPath = [logDir stringByAppendingPathComponent:@"splicekit.log"];

    // Rotate: keep the previous launch's log so crash-on-startup is diagnosable.
    // splicekit.log -> splicekit.previous.log (overwrite), then start fresh.
    NSString *prevPath = [logDir stringByAppendingPathComponent:@"splicekit.previous.log"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:prevPath error:nil];
    [fm moveItemAtPath:sLogPath toPath:prevPath error:nil];

    [fm createFileAtPath:sLogPath contents:nil attributes:nil];
    sLogHandle = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
    [sLogHandle seekToEndOfFile];
    sLogFD = [sLogHandle fileDescriptor];
}

void SpliceKit_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    BOOL includeThreadInfo = [[NSUserDefaults standardUserDefaults] boolForKey:@"LogThread"];
    NSString *threadLabel = @"";
    if (includeThreadInfo) {
        NSThread *thread = [NSThread currentThread];
        NSString *name = thread.isMainThread ? @"main" : thread.name;
        if (name.length == 0) {
            name = [NSString stringWithFormat:@"%p", thread];
        }
        threadLabel = [NSString stringWithFormat:@"[%@] ", name];
    }

    NSString *consolePrefix = threadLabel.length
        ? [NSString stringWithFormat:@"[SpliceKit] %@", threadLabel]
        : @"[SpliceKit] ";
    NSLog(@"%@%@", consolePrefix, message);

    // Append to log file on a serial queue so we don't block the caller
    if (sLogHandle && sLogQueue) {
        NSString *timestamp = SpliceKit_logTimestamp();
        NSString *line = [NSString stringWithFormat:@"[%@] [SpliceKit] %@%@\n",
                          timestamp, threadLabel, message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_async(sLogQueue, ^{
            [sLogHandle writeData:data];
            [sLogHandle synchronizeFile];
        });
    }
}

#pragma mark - Startup Diagnostics
//
// Track swizzle results, capture crashes, and collect system info so that a
// log the user chooses to share has everything needed to diagnose the problem.
//

// Swizzle result tracker — records every swizzle attempt and outcome so
// bridge_status can report exactly which patches are active.
static NSMutableDictionary *sSwizzleResults = nil;

static void SpliceKit_trackSwizzle(NSString *name, BOOL success) {
    if (!sSwizzleResults) {
        sSwizzleResults = [NSMutableDictionary new];
    }
    sSwizzleResults[name] = @(success);
}

NSDictionary *SpliceKit_getSwizzleResults(void) {
    return sSwizzleResults ? [sSwizzleResults copy] : @{};
}

static NSString *SpliceKit_swizzleStateDescription(NSString *name) {
    NSNumber *value = sSwizzleResults[name];
    if (!value) return @"unset";
    return value.boolValue ? @"YES" : @"NO";
}

static void SpliceKit_logCloudContentGuardSummary(NSString *phase) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL firstLaunchDone = [defaults boolForKey:@"CloudContentFirstLaunchCompleted"];
    BOOL cloudContentDisabled = [defaults boolForKey:@"FFCloudContentDisabled"];
    SpliceKit_log(@"CloudContent guard (%@): firstLaunch=%@ disabled=%@ featureFlag=%@ firstLaunchFlag=%@ catalogUpdate=%@ catalogEnabled=%@ catalogSubscription=%@ activeListener=%@ helper=%@ helperCompletion=%@",
                  phase,
                  firstLaunchDone ? @"YES" : @"NO",
                  cloudContentDisabled ? @"YES" : @"NO",
                  SpliceKit_swizzleStateDescription(@"CloudContentFeatureFlag.isEnabled"),
                  SpliceKit_swizzleStateDescription(@"CloudContentFeatureFlag.shouldShowFirstLaunchExperience"),
                  SpliceKit_swizzleStateDescription(@"CloudContentCatalog.updateCatalogAndRegistry"),
                  SpliceKit_swizzleStateDescription(@"CloudContentCatalog.isCloudContentEnabled"),
                  SpliceKit_swizzleStateDescription(@"CloudContentCatalog.isRunningSubscriptionApp"),
                  SpliceKit_swizzleStateDescription(@"CloudContentCatalog.activeListener"),
                  SpliceKit_swizzleStateDescription(@"CloudContentFirstLaunchHelper.setupAndPresent"),
                  SpliceKit_swizzleStateDescription(@"CloudContentFirstLaunchHelper.setupAndPresent(completion:)"));
}

// Global uncaught exception handler — logs the exception and full stack trace
// to the log file BEFORE the process terminates. Apple's crash reporter doesn't
// capture our log, so this is the last chance to write diagnostic info.
static NSUncaughtExceptionHandler *sPreviousExceptionHandler = nil;

static void SpliceKit_uncaughtExceptionHandler(NSException *exception) {
    SpliceKit_log(@"!!! UNCAUGHT EXCEPTION !!!");
    SpliceKit_log(@"Name: %@", exception.name);
    SpliceKit_log(@"Reason: %@", exception.reason);
    NSArray *symbols = [exception callStackSymbols];
    for (NSString *frame in symbols) {
        SpliceKit_log(@"  %@", frame);
    }
    SpliceKit_log(@"UserInfo: %@", exception.userInfo);

    // Flush log synchronously so it hits disk before we die
    if (sLogHandle) {
        [sLogHandle synchronizeFile];
    }

    // Forward to previous handler if one was installed
    if (sPreviousExceptionHandler) {
        sPreviousExceptionHandler(exception);
    }
}

// Signal handler for fatal signals — captures stack trace to log file.
// Handles SIGTRAP (CloudKit entitlement crashes), SIGABRT, SIGSEGV, SIGBUS.
static void SpliceKit_signalHandler(int sig) {
    const char *sigName = "UNKNOWN";
    switch (sig) {
        case SIGTRAP:  sigName = "SIGTRAP";  break;
        case SIGABRT:  sigName = "SIGABRT";  break;
        case SIGSEGV:  sigName = "SIGSEGV";  break;
        case SIGBUS:   sigName = "SIGBUS";   break;
    }

    // Can't use SpliceKit_log (not async-signal-safe), write directly.
    if (sLogFD >= 0) {
        void *frames[64];
        int count = backtrace(frames, 64);
        char **symbols = backtrace_symbols(frames, count);

        char header[256];
        snprintf(header, sizeof(header),
                 "\n!!! FATAL SIGNAL: %s (signal %d) !!!\nStack trace:\n", sigName, sig);
        write(sLogFD, header, strlen(header));

        if (symbols) {
            for (int i = 0; i < count; i++) {
                write(sLogFD, "  ", 2);
                write(sLogFD, symbols[i], strlen(symbols[i]));
                write(sLogFD, "\n", 1);
            }
            free(symbols);
        }
        fsync(sLogFD);
    }

    // Re-raise with default handler so macOS crash reporter also gets it
    signal(sig, SIG_DFL);
    raise(sig);
}

static void SpliceKit_installCrashHandlers(void) {
    sPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(SpliceKit_uncaughtExceptionHandler);

    signal(SIGTRAP, SpliceKit_signalHandler);
    signal(SIGABRT, SpliceKit_signalHandler);
    signal(SIGSEGV, SpliceKit_signalHandler);
    signal(SIGBUS,  SpliceKit_signalHandler);
}

// Dump applied entitlements — critical for diagnosing signing issues
static void SpliceKit_logEntitlements(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) {
        SpliceKit_log(@"Entitlements: could not create SecTask");
        return;
    }

    // Check the specific entitlements we care about
    struct { const char *key; const char *label; } checks[] = {
        {"com.apple.security.app-sandbox",                        "sandbox"},
        {"com.apple.security.cs.disable-library-validation",      "no-lib-val"},
        {"com.apple.security.cs.allow-dyld-environment-variables","dyld-env"},
        {"com.apple.security.get-task-allow",                     "task-allow"},
        {"com.apple.developer.icloud-services",                   "icloud"},
    };

    NSMutableArray *parts = [NSMutableArray new];
    for (int i = 0; i < 5; i++) {
        CFTypeRef val = SecTaskCopyValueForEntitlement(
            task, (__bridge CFStringRef)@(checks[i].key), NULL);
        if (val) {
            [parts addObject:[NSString stringWithFormat:@"%s=%@",
                              checks[i].label, (__bridge id)val]];
            CFRelease(val);
        }
    }
    CFRelease(task);

    if (parts.count > 0) {
        SpliceKit_log(@"Entitlements: %@", [parts componentsJoinedByString:@", "]);
    } else {
        SpliceKit_log(@"Entitlements: none detected (unsigned or missing)");
    }
}

// Log all loaded Mach-O images from FCP's app bundle (not system frameworks)
// to identify which FCP frameworks are present — useful for version differences.
static void SpliceKit_logLoadedFrameworks(void) {
    uint32_t count = _dyld_image_count();
    NSString *appPath = [[NSBundle mainBundle] bundlePath];
    NSMutableArray *fcpFrameworks = [NSMutableArray new];

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = @(name);
        if ([path hasPrefix:appPath] && [path containsString:@".framework"]) {
            // Extract framework name from path
            NSString *fw = [[path lastPathComponent] stringByDeletingPathExtension];
            if (!fw) fw = [path lastPathComponent];
            [fcpFrameworks addObject:fw];
        }
    }

    [fcpFrameworks sortUsingSelector:@selector(compare:)];
    SpliceKit_log(@"FCP frameworks loaded (%lu): %@",
                  (unsigned long)fcpFrameworks.count,
                  [fcpFrameworks componentsJoinedByString:@", "]);
}

// Measure and log startup timing for each phase
static CFAbsoluteTime sConstructorStart = 0;
static CFAbsoluteTime sWillLaunchTime = 0;
static CFAbsoluteTime sDidLaunchTime = 0;
static CFAbsoluteTime sServerReadyTime = 0;

void SpliceKit_markServerReady(void) {
    sServerReadyTime = CFAbsoluteTimeGetCurrent();
    double total = sServerReadyTime - sConstructorStart;
    double toLaunch = sDidLaunchTime - sConstructorStart;
    double toServer = sServerReadyTime - sDidLaunchTime;
    SpliceKit_log(@"Startup timing: constructor->launch=%.2fs, launch->server=%.2fs, total=%.2fs",
                  toLaunch, toServer, total);
}

#pragma mark - Cached Class References
//
// We look these up once and stash them globally. Most of these come from Flexo.framework
// (FCP's core editing engine). If Apple renames them in a future version, the compatibility
// check below will tell us exactly which ones are missing.
//

Class SpliceKit_FFAnchoredTimelineModule = nil;
Class SpliceKit_FFAnchoredSequence = nil;
Class SpliceKit_FFLibrary = nil;
Class SpliceKit_FFLibraryDocument = nil;
Class SpliceKit_FFEditActionMgr = nil;
Class SpliceKit_FFModelDocument = nil;
Class SpliceKit_FFPlayer = nil;
Class SpliceKit_FFActionContext = nil;
Class SpliceKit_PEAppController = nil;
Class SpliceKit_PEDocument = nil;

#pragma mark - Compatibility Check

// Runs after FCP finishes loading all its frameworks.
// Looks up each critical class by name and caches the reference.
// If something's missing, we log it but keep going — partial functionality
// is better than no functionality.
static void SpliceKit_checkCompatibility(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"];
    NSString *build = info[@"CFBundleVersion"];
    SpliceKit_log(@"FCP version %@ (build %@)", version, build);

    struct { const char *name; Class *ref; } classes[] = {
        {"FFAnchoredTimelineModule", &SpliceKit_FFAnchoredTimelineModule},
        {"FFAnchoredSequence",       &SpliceKit_FFAnchoredSequence},
        {"FFLibrary",                &SpliceKit_FFLibrary},
        {"FFLibraryDocument",        &SpliceKit_FFLibraryDocument},
        {"FFEditActionMgr",          &SpliceKit_FFEditActionMgr},
        {"FFModelDocument",          &SpliceKit_FFModelDocument},
        {"FFPlayer",                 &SpliceKit_FFPlayer},
        {"FFActionContext",          &SpliceKit_FFActionContext},
        {"PEAppController",         &SpliceKit_PEAppController},
        {"PEDocument",              &SpliceKit_PEDocument},
    };

    int found = 0, total = sizeof(classes) / sizeof(classes[0]);
    for (int i = 0; i < total; i++) {
        *classes[i].ref = objc_getClass(classes[i].name);
        if (*classes[i].ref) {
            // Log the method count as a quick sanity check — if it's wildly
            // different from what we expect, the class might have been gutted
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(*classes[i].ref, &methodCount);
            free(methods);
            SpliceKit_log(@"  OK: %s (%u methods)", classes[i].name, methodCount);
            found++;
        } else {
            SpliceKit_log(@"  MISSING: %s", classes[i].name);
        }
    }
    SpliceKit_log(@"Class check: %d/%d found", found, total);
}

#pragma mark - App Launch Handler
//
// This fires once FCP is fully loaded and its UI is ready. We can't do most of
// our setup in the constructor because FCP's frameworks aren't loaded yet at that
// point — you'll get nil back from objc_getClass for anything in Flexo.framework.
//

// ---------------------------------------------------------------------------
// Safe install wrapper — catches SIGSEGV/SIGBUS during feature install so a
// single broken swizzle doesn't bring down the whole process.
//
// Uses sigsetjmp/siglongjmp: set a recovery point, temporarily swap the signal
// handler, call the install function.  If it crashes, the handler longjmps back,
// logs which feature failed, and startup continues with the next one.
//
// Only used during startup on the main thread.  Thread identity is checked in
// the handler so a stray crash on another thread still hits the normal path.
// ---------------------------------------------------------------------------

static sigjmp_buf sSafeInstallJmpBuf;
static pthread_t  sSafeInstallThread;
static volatile sig_atomic_t sSafeInstallActive = 0;

static void SpliceKit_safeInstallHandler(int sig, siginfo_t *info, void *ctx) {
    if (sSafeInstallActive && pthread_equal(pthread_self(), sSafeInstallThread)) {
        sSafeInstallActive = 0;
        siglongjmp(sSafeInstallJmpBuf, sig);
    }
    // Not our context — restore default and re-raise so the normal crash
    // handler (or macOS crash reporter) picks it up.
    signal(sig, SIG_DFL);
    raise(sig);
}

BOOL SpliceKit_safeInstall(const char *featureName, void (^block)(void)) {
    struct sigaction sa, prevSEGV, prevBUS;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = SpliceKit_safeInstallHandler;
    sa.sa_flags     = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);

    sigaction(SIGSEGV, &sa, &prevSEGV);
    sigaction(SIGBUS,  &sa, &prevBUS);

    sSafeInstallThread = pthread_self();
    sSafeInstallActive = 1;

    int sig = sigsetjmp(sSafeInstallJmpBuf, 1);
    if (sig == 0) {
        // Normal path — attempt the install
        @try {
            block();
        } @catch (NSException *e) {
            sSafeInstallActive = 0;
            sigaction(SIGSEGV, &prevSEGV, NULL);
            sigaction(SIGBUS,  &prevBUS,  NULL);
            SpliceKit_log(@"[SafeInstall] %s threw %@: %@ — feature disabled",
                          featureName, e.name, e.reason);
            return NO;
        }
        sSafeInstallActive = 0;
        sigaction(SIGSEGV, &prevSEGV, NULL);
        sigaction(SIGBUS,  &prevBUS,  NULL);
        return YES;
    } else {
        // Crash recovery — handler did siglongjmp back here.
        // Unblock the signal (blocked automatically during handler execution).
        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, SIGSEGV);
        sigaddset(&unblock, SIGBUS);
        pthread_sigmask(SIG_UNBLOCK, &unblock, NULL);

        sigaction(SIGSEGV, &prevSEGV, NULL);
        sigaction(SIGBUS,  &prevBUS,  NULL);
        SpliceKit_log(@"[SafeInstall] %s crashed (signal %d) — feature auto-disabled",
                      featureName, sig);
        return NO;
    }
}

// FCP registers Apple's AUSoundIsolation AU but hides it in the UI. Re-apply
// the visibility override after launch once the effect registry is ready so the
// effect browser can surface it on every startup.
static NSString *SpliceKit_soundIsolationEffectID(void) {
    Class effectStackClass = objc_getClass("FFEffectStack");
    SEL voiceIsolationSel = NSSelectorFromString(@"voiceIsolationEffectID");
    if (effectStackClass && [effectStackClass respondsToSelector:voiceIsolationSel]) {
        id effectID = ((id (*)(id, SEL))objc_msgSend)(effectStackClass, voiceIsolationSel);
        if ([effectID isKindOfClass:[NSString class]] && [effectID length] > 0) {
            return effectID;
        }
    }

    Class auEffectClass = objc_getClass("FFAudioUnitEffect");
    SEL identifierSel = NSSelectorFromString(@"effectIdentifierForType:subType:manufacturer:");
    if (auEffectClass && [auEffectClass respondsToSelector:identifierSel]) {
        id effectID = ((id (*)(id, SEL, unsigned int, unsigned int, unsigned int))objc_msgSend)(
            auEffectClass, identifierSel, 1635083896U, 1987012979U, 1634758764U);
        if ([effectID isKindOfClass:[NSString class]] && [effectID length] > 0) {
            return effectID;
        }
    }

    return @"AudioUnit: 0x61756678766f69736170706c";
}

static BOOL SpliceKit_tryUnhideSoundIsolationNow(void) {
    Class ffEffectClass = objc_getClass("FFEffect");
    if (!ffEffectClass) {
        SpliceKit_log(@"SoundIsolation unhide: FFEffect class not available yet");
        return NO;
    }

    SEL ensureSel = NSSelectorFromString(@"ensureEffectsRegistered");
    if ([ffEffectClass respondsToSelector:ensureSel]) {
        ((void (*)(id, SEL))objc_msgSend)(ffEffectClass, ensureSel);
    }

    NSString *effectID = SpliceKit_soundIsolationEffectID();
    if (effectID.length == 0) {
        SpliceKit_log(@"SoundIsolation unhide: could not resolve effect ID");
        return NO;
    }

    SEL registeredSel = NSSelectorFromString(@"effectIDIsRegistered:");
    if (![ffEffectClass respondsToSelector:registeredSel]) {
        SpliceKit_log(@"SoundIsolation unhide: FFEffect is missing effectIDIsRegistered:");
        return NO;
    }

    BOOL isRegistered = ((BOOL (*)(id, SEL, id))objc_msgSend)(ffEffectClass, registeredSel, effectID);
    if (!isRegistered) {
        SpliceKit_log(@"SoundIsolation unhide: %@ not registered yet", effectID);
        return NO;
    }

    SEL propertiesSel = NSSelectorFromString(@"propertiesForEffect:");
    NSDictionary *beforeProps = nil;
    if ([ffEffectClass respondsToSelector:propertiesSel]) {
        beforeProps = ((id (*)(id, SEL, id))objc_msgSend)(ffEffectClass, propertiesSel, effectID);
    }

    BOOL wasHidden = [beforeProps[@"FFEffectProperty_HiddenInUI"] boolValue];
    SEL updateHiddenSel = NSSelectorFromString(@"updatePropertyHiddenInUI:onEffectIDs:");
    if (![ffEffectClass respondsToSelector:updateHiddenSel]) {
        SpliceKit_log(@"SoundIsolation unhide: FFEffect is missing updatePropertyHiddenInUI:onEffectIDs:");
        return NO;
    }

    BOOL updated = ((BOOL (*)(id, SEL, BOOL, id))objc_msgSend)(
        ffEffectClass, updateHiddenSel, NO, @[effectID]);

    NSDictionary *afterProps = nil;
    if ([ffEffectClass respondsToSelector:propertiesSel]) {
        afterProps = ((id (*)(id, SEL, id))objc_msgSend)(ffEffectClass, propertiesSel, effectID);
    }

    BOOL isHidden = [afterProps[@"FFEffectProperty_HiddenInUI"] boolValue];
    if (!updated && isHidden) {
        SpliceKit_log(@"SoundIsolation unhide: update call failed for %@", effectID);
        return NO;
    }

    SpliceKit_log(@"SoundIsolation unhide: %@ hidden=%@ -> %@",
                  effectID,
                  wasHidden ? @"YES" : @"NO",
                  isHidden ? @"hidden" : @"visible");
    return !isHidden;
}

static void SpliceKit_scheduleSoundIsolationUnhideAttempt(NSUInteger attempt) {
    const NSUInteger kMaxAttempts = 20;
    if (attempt >= kMaxAttempts) {
        SpliceKit_log(@"SoundIsolation unhide: giving up after %lu attempts",
                      (unsigned long)attempt);
        return;
    }

    NSTimeInterval delay = (attempt == 0) ? 0.25 : 1.0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSThread sleepForTimeInterval:delay];
        __block BOOL success = NO;
        @try {
            SpliceKit_executeOnMainThread(^{
                @try {
                    success = SpliceKit_tryUnhideSoundIsolationNow();
                } @catch (NSException *e) {
                    SpliceKit_log(@"SoundIsolation unhide attempt %lu threw %@: %@",
                                  (unsigned long)attempt, e.name, e.reason);
                }
            });
        } @catch (NSException *e) {
            SpliceKit_log(@"SoundIsolation unhide dispatch %lu threw %@: %@",
                          (unsigned long)attempt, e.name, e.reason);
        }
        if (!success) {
            SpliceKit_scheduleSoundIsolationUnhideAttempt(attempt + 1);
        }
    });
}

static void SpliceKit_appDidLaunch(void) {
    SpliceKit_log(@"================================================");
    SpliceKit_log(@"App launched. Starting control server...");
    SpliceKit_log(@"================================================");

    // Run compatibility check now that all frameworks are loaded
    SpliceKit_checkCompatibility();

    // Guard against the VTCopyVideoDecoderExtensionProperties nil-property crash
    // when a Media Extension returns incomplete CodecInfo.
    SpliceKit_safeInstall("MediaExtensionGuard", ^{
        SpliceKit_installMediaExtensionGuard();
    });

    SpliceKit_safeInstall("VP9Bootstrap", ^{
        SpliceKitVP9_Bootstrap();
    });

    SpliceKit_safeInstall("MKVBootstrap", ^{
        SpliceKitMKV_Bootstrap();
    });

    SpliceKit_safeInstall("VP9ImportHook", ^{
        SpliceKitURLImport_bootstrapAtLaunchPhase(@"did-launch");
    });

    // Install focused editor routing before commands and menus start querying
    // activeEditorContainer, so the secondary timeline can participate in the
    // normal responder path.
    SpliceKit_safeInstall("DualTimeline", ^{
        SpliceKit_installDualTimeline();
        SpliceKit_installDualTimelineCrossWindowDrag();
    });

    // Count total loaded classes
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    free(allClasses);
    SpliceKit_log(@"Total ObjC classes in process: %u", classCount);

    // Install Splices menu in the menu bar
    SpliceKit_installMenu();

    // Install toolbar button in FCP's main window
    [SpliceKitMenuController installToolbarButton];

    [[NSNotificationCenter defaultCenter] addObserverForName:SpliceKitLiveCamVisibilityDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        BOOL visible = [note.userInfo[@"visible"] boolValue];
        [[SpliceKitMenuController shared] updateLiveCamToolbarButtonState:visible];
    }];

    // Install transition freeze-extend swizzle (adds "Use Freeze Frames" button
    // to the "not enough extra media" dialog)
    SpliceKit_installTransitionFreezeExtendSwizzle();

    // Install effect-drag-as-adjustment-clip swizzle (allows dragging effects
    // to empty timeline space to create adjustment clips)
    SpliceKit_safeInstall("EffectDragAsAdjustmentClip", ^{
        SpliceKit_installEffectDragAsAdjustmentClip();
    });

    // Install viewer pinch-to-zoom if previously enabled
    if (SpliceKit_isViewerPinchZoomEnabled()) {
        SpliceKit_installViewerPinchZoom();
    }

    // Install video-only-keeps-audio-disabled swizzle if previously enabled
    if (SpliceKit_isVideoOnlyKeepsAudioDisabledEnabled()) {
        SpliceKit_installVideoOnlyKeepsAudioDisabled();
    }

    // Install suppress-auto-import swizzle if previously enabled. The mount-notification
    // observers were already set up at FCP launch before our dylib loaded, so we have
    // to intercept the handler methods themselves rather than the observer registration.
    if (SpliceKit_isSuppressAutoImportEnabled()) {
        SpliceKit_installSuppressAutoImport();
    }

    // Spring-loaded blade disabled — intercepting Option key breaks FCP's native
    // Option+click (extend edit) and Option+drag (copy clip) behaviors.
    if (SpliceKit_isSpringLoadedBladeEnabled()) {
        SpliceKit_setSpringLoadedBladeEnabled(NO);
        SpliceKit_log(@"  Spring-loaded blade auto-disabled (conflicts with Option+click editing)");
    }

    // Install default spatial conform swizzle if set to non-default value
    if (![SpliceKit_getDefaultSpatialConformType() isEqualToString:@"fit"]) {
        SpliceKit_installDefaultSpatialConformType();
    }

    // Install effect browser favorites context menu (always on)
    SpliceKit_installEffectFavoritesSwizzle();

    // Debounce FFSidebarModule KVO churn on the Effects sidebar's category
    // list during live scroll (fixes scrolling jerks with many effects).
    if (SpliceKit_isSidebarCoalesceLiveScrollEnabled()) {
        SpliceKit_safeInstall("SidebarCoalesceLiveScroll", ^{
            SpliceKit_installSidebarCoalesceLiveScroll();
        });
    }

    // Timeline Performance Mode — master toggle for the interaction-suspend,
    // 120Hz playhead overlay, and TLKOptimizedReload knob. Respects the user's
    // saved value; individual sub-toggles are applied independently if the
    // master is off.
    SpliceKit_safeInstall("TimelinePerformanceMode", ^{
        SpliceKit_installTimelinePerformanceMode();
    });

    // Latch skim state off the methods FCP actually calls so the mixer can
    // meter live skims even when isToolSkimming stays false.
    SpliceKit_installMixerSkimHooks();

    // Restore persisted social caption text after relaunch once a real sequence is
    // active. Automatic repair is intentionally limited to the Motion effect text
    // field API so relaunch does not wake the heavier channel/document machinery.
    Class captionPanelClass = objc_getClass("SpliceKitCaptionPanel");
    if (captionPanelClass) {
        id captionPanel = ((id (*)(id, SEL))objc_msgSend)((id)captionPanelClass, @selector(sharedPanel));
        SEL enableAutoRestoreSel = NSSelectorFromString(@"enableAutomaticRestore");
        if (captionPanel && [captionPanel respondsToSelector:enableAutoRestoreSel]) {
            ((void (*)(id, SEL))objc_msgSend)(captionPanel, enableAutoRestoreSel);
        }
    }

    // Install FCPXML direct paste support (converts FCPXML on pasteboard
    // to native clipboard format so pasteAnchored: can handle it)
    SpliceKit_installFCPXMLPasteSwizzle();

    // Swizzle J/L to use configurable speed ladders
    SpliceKit_installPlaybackSpeedSwizzle();

    // Rebuild FCP's hidden Debug pane (Apple strips the NIB in release builds;
    // we reconstruct it).
    SpliceKit_installDebugSettingsPanel();

    // Install right-click context menu for structure block color changes
    SpliceKit_safeInstall("StructureBlockContextMenu", ^{
        SpliceKit_installStructureBlockContextMenu();
    });

    // Inline miniature-timeline overview bar — install if user had it on
    if (SpliceKit_isTimelineOverviewBarEnabled()) {
        SpliceKit_safeInstall("TimelineOverviewBar", ^{
            SpliceKit_installTimelineOverviewBar();
        });
    }

    // Bridge metadata (bridge.describe / bridge.alive) and async/events
    // infrastructure must be registered before the control server starts
    // accepting requests, since they go through the plugin registry.
    SpliceKit_safeInstall("BridgeMetadata", ^{
        SpliceKit_installBridgeMetadata();
    });
    SpliceKit_safeInstall("AsyncEvents", ^{
        SpliceKit_installAsync();
    });

    // Mirror FCP haptics out over the event channel so external accessories
    // (Logi MX Master 4) can play matching feedback. Must run after
    // AsyncEvents so SpliceKit_broadcastEvent has a working subscriber path.
    SpliceKit_safeInstall("HapticBridge", ^{
        SpliceKit_installHapticBridge();
    });

    // Add tactile feedback for FCP timeline snap events that don't natively
    // fire a haptic — clip-body snap on the spine, playhead snap to edits/
    // markers, etc. Hooks the central snappingCalc:… delegate callback.
    SpliceKit_safeInstall("HapticSnapEmitters", ^{
        SpliceKit_installHapticSnapEmitters();
    });

    // Start the control server on a background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SpliceKit_startControlServer();
    });

    // Initialize Lua scripting VM
    SpliceKit_safeInstall("LuaVM", ^{
        SpliceKitLua_initialize();
    });

    // Load plugins from ~/Library/Application Support/SpliceKit/plugins/
    // Native plugins load independently of Lua — don't gate on Lua success.
    SpliceKitPlugins_loadAll();

    SpliceKit_log(@"SoundIsolation unhide: scheduling startup attempts");
    SpliceKit_scheduleSoundIsolationUnhideAttempt(0);
}

#pragma mark - Crash Prevention & Startup Fixes
//
// FCP has a few code paths that crash or hang when running outside its normal
// signed/entitled environment. We patch them out before they have a chance to fire.
//
// These swizzles are applied in the constructor (before main), so they need to
// target classes that are available early — mostly Swift classes in the main
// binary and ProCore framework classes.
//

// Replacement IMPs for blocking problematic methods
static void noopMethod(id self, SEL _cmd) {
    SpliceKit_log(@"BLOCKED: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static void noopMethodWithArg(id self, SEL _cmd, id arg) {
    SpliceKit_log(@"BLOCKED: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static void noopCloudContentFirstLaunchWithCompletion(id self, SEL _cmd, id completion) {
    SpliceKit_log(@"BLOCKED CloudContent first launch: -[%@ %@]",
                  NSStringFromClass([self class]), NSStringFromSelector(_cmd));
    if (!completion) return;

    @try {
        void (^completionBlock)(NSError *) = completion;
        completionBlock(nil);
    } @catch (NSException *e) {
        SpliceKit_log(@"CloudContent first-launch completion callback failed: %@ %@", e.name, e.reason);
    }
}

static BOOL returnNO(id self, SEL _cmd) {
    SpliceKit_log(@"BLOCKED (returning NO): +[%@ %@]",
                  NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
    return NO;
}

// Silent variant — no logging. Used for high-frequency swizzles like isSPVEnabled
// which gets called dozens of times during startup.
static BOOL returnNO_silent(id self, SEL _cmd) {
    return NO;
}

static void noopMethodWith2Args(id self, SEL _cmd, id arg1, id arg2) {}

// PCUserDefaultsMigrator runs on quit and calls copyDataFromSource:toTarget:,
// which walks a potentially massive media directory tree via getattrlistbulk.
// On large libraries this hangs for 30+ seconds, making FCP feel like it froze.
// Since we don't need the migration, we just no-op it.
static void SpliceKit_fixShutdownHang(void) {
    Class migrator = objc_getClass("PCUserDefaultsMigrator");
    if (migrator) {
        SEL sel = NSSelectorFromString(@"copyDataFromSource:toTarget:");
        Method m = class_getInstanceMethod(migrator, sel);
        if (m) {
            method_setImplementation(m, (IMP)noopMethodWith2Args);
            SpliceKit_log(@"Swizzled PCUserDefaultsMigrator.copyDataFromSource: (fixes shutdown hang)");
        }
    }
}

static BOOL SpliceKit_replaceInstanceMethod(Class cls,
                                            SEL sel,
                                            IMP imp,
                                            const char *phase,
                                            NSString *trackingKey) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    method_setImplementation(method, imp);
    SpliceKit_log(@"  [%s] Swizzled %s -%@", phase, class_getName(cls), NSStringFromSelector(sel));
    if (trackingKey.length > 0) {
        SpliceKit_trackSwizzle(trackingKey, YES);
    }
    return YES;
}

static BOOL SpliceKit_replaceClassMethod(Class cls,
                                         SEL sel,
                                         IMP imp,
                                         const char *phase,
                                         NSString *trackingKey) {
    Method method = class_getClassMethod(cls, sel);
    if (!method) return NO;

    method_setImplementation(method, imp);
    SpliceKit_log(@"  [%s] Swizzled %s +%@", phase, class_getName(cls), NSStringFromSelector(sel));
    if (trackingKey.length > 0) {
        SpliceKit_trackSwizzle(trackingKey, YES);
    }
    return YES;
}

static void SpliceKit_logCloudContentMethods(Class cls) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int j = 0; j < methodCount && j < 30; j++) {
        SpliceKit_log(@"    method: %@", NSStringFromSelector(method_getName(methods[j])));
    }
    if (methods) free(methods);
}

static void SpliceKit_swizzleCloudContentClass(Class cls, const char *phase) {
    if (!cls) return;

    const char *name = class_getName(cls);
    if (!name) return;

    if (strstr(name, "CCFirstLaunchHelper") || strstr(name, "CloudContentFirstLaunchHelper")) {
        SpliceKit_log(@"  [%s] Found class: %s", phase, name);

        BOOL handled = NO;
        SEL asyncCompletionSel = NSSelectorFromString(@"setupAndPresentFirstLaunchIfNeededWithCompletionHandler:");
        handled |= SpliceKit_replaceInstanceMethod(cls,
                                                   asyncCompletionSel,
                                                   (IMP)noopCloudContentFirstLaunchWithCompletion,
                                                   phase,
                                                   @"CloudContentFirstLaunchHelper.setupAndPresent(completion:)");

        SEL directSel = NSSelectorFromString(@"setupAndPresentFirstLaunchIfNeeded");
        handled |= SpliceKit_replaceInstanceMethod(cls,
                                                   directSel,
                                                   (IMP)noopMethod,
                                                   phase,
                                                   @"CloudContentFirstLaunchHelper.setupAndPresent");

        if (!handled) {
            SpliceKit_log(@"  [%s] WARNING: %s exists but first-launch selectors were not found", phase, name);
            SpliceKit_logCloudContentMethods(cls);
            SpliceKit_trackSwizzle(@"CloudContentFirstLaunchHelper.setupAndPresent", NO);
            SpliceKit_trackSwizzle(@"CloudContentFirstLaunchHelper.setupAndPresent(completion:)", NO);
        }
    }

    if (strstr(name, "CloudContentCatalog") && !strstr(name, "RegistryManifest")) {
        SpliceKit_log(@"  [%s] Found class: %s", phase, name);

        SpliceKit_replaceInstanceMethod(cls,
                                        NSSelectorFromString(@"isCloudContentEnabled"),
                                        (IMP)returnNO_silent,
                                        phase,
                                        @"CloudContentCatalog.isCloudContentEnabled");
        SpliceKit_replaceInstanceMethod(cls,
                                        NSSelectorFromString(@"isRunningSubscriptionApp"),
                                        (IMP)returnNO_silent,
                                        phase,
                                        @"CloudContentCatalog.isRunningSubscriptionApp");
        SpliceKit_replaceInstanceMethod(cls,
                                        NSSelectorFromString(@"startListeningForApplicationDidBecomeActiveNotifications"),
                                        (IMP)noopMethod,
                                        phase,
                                        @"CloudContentCatalog.activeListener");

        SEL updateSel = NSSelectorFromString(@"updateCatalogAndRegistry");
        Method updateMethod = class_getInstanceMethod(cls, updateSel);
        if (updateMethod) {
            method_setImplementation(updateMethod, (IMP)noopMethod);
            SpliceKit_log(@"  [%s] Swizzled %s -updateCatalogAndRegistry", phase, name);
            SpliceKit_trackSwizzle(@"CloudContentCatalog.updateCatalogAndRegistry", YES);
        } else {
            SpliceKit_log(@"  [%s] NOTE: %s has no ObjC -updateCatalogAndRegistry selector; guarded related ObjC entry points instead", phase, name);
            SpliceKit_trackSwizzle(@"CloudContentCatalog.updateCatalogAndRegistry", NO);
        }
    }

    // CloudContentFeatureFlag — prevent user-visible first-launch UI paths.
    if (strstr(name, "CloudContentFeatureFlag")) {
        SpliceKit_log(@"  [%s] Found class: %s", phase, name);
        BOOL handled = NO;
        handled |= SpliceKit_replaceClassMethod(cls,
                                                @selector(isEnabled),
                                                (IMP)returnNO,
                                                phase,
                                                @"CloudContentFeatureFlag.isEnabled");
        handled |= SpliceKit_replaceClassMethod(cls,
                                                NSSelectorFromString(@"shouldShowFirstLaunchExperience"),
                                                (IMP)returnNO_silent,
                                                phase,
                                                @"CloudContentFeatureFlag.shouldShowFirstLaunchExperience");
        if (!handled) {
            SpliceKit_log(@"  [%s] WARNING: %s exists but known feature-flag selectors were not found", phase, name);
            SpliceKit_trackSwizzle(@"CloudContentFeatureFlag.isEnabled", NO);
        }
    }
}

static void SpliceKit_swizzleKnownCloudContentClasses(const char *phase) {
    const char *classNames[] = {
        "CCFirstLaunchHelper",
        "_TtC13Final_Cut_Pro29CloudContentFirstLaunchHelper",
        "_TtC17Final_Cut_Pro_App29CloudContentFirstLaunchHelper",
        "_TtC13Final_Cut_Pro19CloudContentCatalog",
        "_TtC17Final_Cut_Pro_App19CloudContentCatalog",
        "_TtC13Final_Cut_Pro23CloudContentFeatureFlag",
        "_TtC17Final_Cut_Pro_App23CloudContentFeatureFlag",
        NULL
    };

    for (int i = 0; classNames[i] != NULL; i++) {
        SpliceKit_swizzleCloudContentClass(objc_getClass(classNames[i]), phase);
    }
}

// Brute-force CloudContent neutralizer: first targets the known Swift/ObjC
// classes by exact runtime name, then enumerates registered classes to catch
// Apple renames between FCP editions and point releases.
static void SpliceKit_swizzleCloudContentClasses(const char *phase) {
    SpliceKit_swizzleKnownCloudContentClasses(phase);

    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;

    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    if (!classes) return;
    objc_getClassList(classes, numClasses);

    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        if (strstr(name, "CCFirstLaunchHelper") ||
            strstr(name, "CloudContentFirstLaunchHelper") ||
            strstr(name, "CloudContentCatalog") ||
            strstr(name, "CloudContentFeatureFlag")) {
            SpliceKit_swizzleCloudContentClass(classes[i], phase);
        }
    }

    free(classes);
}

// CloudContent/ImagePlayground crashes at launch because:
//   PEAppController.presentMainWindowOnAppLaunch: checks CloudContentFeatureFlag.isEnabled,
//   which triggers CloudContentCatalog.shared -> CCFirstLaunchHelper -> CloudKit.
//   Without proper iCloud entitlements, CloudKit throws an uncaught exception.
//
// Fix: make the feature flag return NO so the entire code path is skipped.
// Same deal with FFImagePlayground.isAvailable — it goes through a similar CloudKit path.
static void SpliceKit_disableCloudContent(void) {
    SpliceKit_log(@"Disabling CloudContent/ImagePlayground...");

    // Swift class names get mangled. Try the mangled name first, then the demangled form.
    Class ccFlag = objc_getClass("_TtC13Final_Cut_Pro23CloudContentFeatureFlag");
    if (!ccFlag) {
        ccFlag = objc_getClass("Final_Cut_Pro.CloudContentFeatureFlag");
    }

    if (ccFlag) {
        Method m = class_getClassMethod(ccFlag, @selector(isEnabled));
        if (m) {
            method_setImplementation(m, (IMP)returnNO);
            SpliceKit_log(@"  Swizzled +[CloudContentFeatureFlag isEnabled] -> NO");
            SpliceKit_trackSwizzle(@"CloudContentFeatureFlag.isEnabled", YES);
        } else {
            SpliceKit_log(@"  WARNING: +isEnabled not found on CloudContentFeatureFlag");
            SpliceKit_trackSwizzle(@"CloudContentFeatureFlag.isEnabled", NO);
        }
    } else {
        SpliceKit_log(@"  WARNING: CloudContentFeatureFlag class not found");
        SpliceKit_trackSwizzle(@"CloudContentFeatureFlag.isEnabled", NO);
    }

    Class ipClass = objc_getClass("_TtC5Flexo17FFImagePlayground");
    if (!ipClass) ipClass = objc_getClass("Flexo.FFImagePlayground");
    if (ipClass) {
        Method m = class_getClassMethod(ipClass, @selector(isAvailable));
        if (m) {
            method_setImplementation(m, (IMP)returnNO);
            SpliceKit_log(@"  Swizzled +[FFImagePlayground isAvailable] -> NO");
        }
    }

    // Handle the first-launch helper directly — the feature flag swizzle may not
    // take effect on all FCP versions, so we also noop the helper that triggers
    // CloudKit (which requires iCloud entitlements lost after re-signing).
    //
    // FCP < 12.2: ObjC class CCFirstLaunchHelper, method -setupAndPresentFirstLaunchIfNeededWithCompletionHandler:
    // FCP >= 12.2: Swift class CloudContentFirstLaunchHelper, method -setupAndPresentFirstLaunchIfNeeded
    Class ccHelper = objc_getClass("CCFirstLaunchHelper");
    if (ccHelper) {
        SEL sel = NSSelectorFromString(@"setupAndPresentFirstLaunchIfNeededWithCompletionHandler:");
        Method m = class_getInstanceMethod(ccHelper, sel);
        if (m) {
            method_setImplementation(m, (IMP)noopMethodWithArg);
            SpliceKit_log(@"  Handled CCFirstLaunchHelper (CloudKit entitlements fix)");
            SpliceKit_trackSwizzle(@"CloudContentFirstLaunchHelper.setupAndPresent(completion:)", YES);
        } else {
            SpliceKit_trackSwizzle(@"CloudContentFirstLaunchHelper.setupAndPresent(completion:)", NO);
        }
    }

    // Brute-force scan: enumerate ALL registered ObjC classes and swizzle anything
    // with CloudContent in the name. This avoids guessing Swift mangled names, which
    // vary by FCP version and compiler. At constructor time Swift classes may not be
    // registered yet (lazy loading), so we also retry this in WillFinishLaunching.
    SpliceKit_swizzleCloudContentClasses("constructor");

    SpliceKit_log(@"CloudContent/ImagePlayground disabled.");
}

#pragma mark - App Store Receipt Validation
//
// Validates the App Store receipt from the original (unmodded) FCP installation.
// The receipt is a PKCS7-signed ASN.1 blob from Apple. We verify the signature
// via CMSDecoder and parse the payload to extract the bundle ID, confirming the
// user legitimately downloaded the app from the App Store.
//
// This runs locally — no network calls, no Apple servers.
//

#import <Security/CMSDecoder.h>

// Read a DER length field. Returns bytes consumed (0 on error).
static size_t SpliceKit_readDERLength(const uint8_t *buf, size_t bufLen, size_t *outLen) {
    if (bufLen == 0) return 0;
    uint8_t first = buf[0];
    if (!(first & 0x80)) {
        *outLen = first;
        return 1;
    }
    size_t numBytes = first & 0x7F;
    if (numBytes == 0 || numBytes > 4 || numBytes >= bufLen) return 0;
    size_t len = 0;
    for (size_t i = 0; i < numBytes; i++)
        len = (len << 8) | buf[1 + i];
    *outLen = len;
    return 1 + numBytes;
}

// Parse the ASN.1 receipt payload and extract the bundle ID (attribute type 2).
// Receipt structure: SET { SEQUENCE { INTEGER type, INTEGER version, OCTET STRING value } ... }
static NSString *SpliceKit_extractBundleIdFromPayload(NSData *payload) {
    const uint8_t *buf = payload.bytes;
    size_t total = payload.length;
    if (total < 2) return nil;

    // Outer SET (tag 0x31)
    if (buf[0] != 0x31) return nil;
    size_t setLen = 0;
    size_t off = 1 + SpliceKit_readDERLength(buf + 1, total - 1, &setLen);
    size_t setEnd = off + setLen;
    if (setEnd > total) setEnd = total;

    while (off < setEnd) {
        // Each entry is a SEQUENCE (tag 0x30)
        if (buf[off] != 0x30) break;
        size_t seqLen = 0;
        size_t hdr = 1 + SpliceKit_readDERLength(buf + off + 1, setEnd - off - 1, &seqLen);
        size_t seqStart = off + hdr;
        size_t seqEnd = seqStart + seqLen;
        if (seqEnd > setEnd) break;

        // Parse: INTEGER type
        size_t p = seqStart;
        if (p >= seqEnd || buf[p] != 0x02) { off = seqEnd; continue; }
        p++;
        size_t intLen = 0;
        p += SpliceKit_readDERLength(buf + p, seqEnd - p, &intLen);
        int attrType = 0;
        for (size_t i = 0; i < intLen && i < 4; i++)
            attrType = (attrType << 8) | buf[p + i];
        p += intLen;

        // Skip: INTEGER version
        if (p >= seqEnd || buf[p] != 0x02) { off = seqEnd; continue; }
        p++;
        size_t verLen = 0;
        p += SpliceKit_readDERLength(buf + p, seqEnd - p, &verLen);
        p += verLen;

        // OCTET STRING value
        if (p >= seqEnd || buf[p] != 0x04) { off = seqEnd; continue; }
        p++;
        size_t valLen = 0;
        p += SpliceKit_readDERLength(buf + p, seqEnd - p, &valLen);

        // Type 2 = Bundle Identifier. The value is a UTF8String (tag 0x0C) inside the OCTET STRING.
        if (attrType == 2 && p + valLen <= seqEnd) {
            const uint8_t *val = buf + p;
            if (valLen >= 2 && val[0] == 0x0C) {
                size_t strLen = 0;
                size_t strHdr = 1 + SpliceKit_readDERLength(val + 1, valLen - 1, &strLen);
                if (strHdr + strLen <= valLen) {
                    return [[NSString alloc] initWithBytes:val + strHdr
                                                    length:strLen
                                                  encoding:NSUTF8StringEncoding];
                }
            }
        }

        off = seqEnd;
    }
    return nil;
}

// Log diagnostic details about a receipt (PKCS7 signature, bundle ID).
// This is informational only — the result does not gate app launch.
static void SpliceKit_logReceiptDiagnostics(NSData *receiptData, NSString *receiptPath) {
    CMSDecoderRef decoder = NULL;
    OSStatus status = CMSDecoderCreate(&decoder);
    if (status != noErr) {
        SpliceKit_log(@"[Receipt] CMSDecoderCreate failed: %d", (int)status);
        return;
    }

    status = CMSDecoderUpdateMessage(decoder, receiptData.bytes, receiptData.length);
    if (status != noErr) {
        SpliceKit_log(@"[Receipt] CMSDecoderUpdateMessage failed: %d", (int)status);
        CFRelease(decoder);
        return;
    }

    status = CMSDecoderFinalizeMessage(decoder);
    if (status != noErr) {
        SpliceKit_log(@"[Receipt] CMSDecoderFinalizeMessage failed: %d", (int)status);
        CFRelease(decoder);
        return;
    }

    size_t numSigners = 0;
    CMSDecoderGetNumSigners(decoder, &numSigners);
    if (numSigners == 0) {
        SpliceKit_log(@"[Receipt] No signers in receipt");
        CFRelease(decoder);
        return;
    }

    SecPolicyRef policy = SecPolicyCreateBasicX509();
    CMSSignerStatus signerStatus = kCMSSignerUnsigned;
    SecTrustRef trust = NULL;
    OSStatus certVerifyResult = 0;

    status = CMSDecoderCopySignerStatus(decoder, 0, policy, TRUE,
                                        &signerStatus, &trust, &certVerifyResult);

    BOOL signatureValid = (status == noErr && signerStatus == kCMSSignerValid);
    SpliceKit_log(@"[Receipt] Signature: %@ (signerStatus=%d certVerify=%d)",
        signatureValid ? @"VALID" : @"INVALID", (int)signerStatus, (int)certVerifyResult);

    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);

    CFDataRef contentRef = NULL;
    status = CMSDecoderCopyContent(decoder, &contentRef);
    CFRelease(decoder);

    if (status != noErr || !contentRef) {
        SpliceKit_log(@"[Receipt] Failed to extract payload: %d", (int)status);
        return;
    }

    NSData *payload = (__bridge_transfer NSData *)contentRef;
    NSString *bundleId = SpliceKit_extractBundleIdFromPayload(payload);
    if (bundleId) {
        BOOL bundleIdMatch = [bundleId isEqualToString:@"com.apple.FinalCut"] ||
                             [bundleId isEqualToString:@"com.apple.FinalCutApp"];
        SpliceKit_log(@"[Receipt] Bundle ID: \"%@\" %@",
            bundleId, bundleIdMatch ? @"MATCH" : @"MISMATCH");
    } else {
        SpliceKit_log(@"[Receipt] Could not extract bundle ID from payload");
    }
}

// Paths checked during the last receipt search (used in error reporting).
static NSArray *sCheckedReceiptPaths = nil;

// Search for an App Store receipt file at known locations.
// Returns YES if a receipt file is found (file existence is sufficient).
// PKCS7/signature details are logged for diagnostics but do not gate the result.
static BOOL SpliceKit_findReceiptFile(void) {
    NSMutableArray *paths = [NSMutableArray array];

    // 1. Running app's own receipt (patcher copies it into the modded bundle)
    NSURL *receiptURL = [[NSBundle mainBundle] appStoreReceiptURL];
    if (receiptURL.path) {
        [paths addObject:receiptURL.path];
    }

    // 2. Original Creator Studio install
    [paths addObject:
        @"/Applications/Final Cut Pro Creator Studio.app/Contents/_MASReceipt/receipt"];

    // 3. Standard FCP install (user may have both editions)
    [paths addObject:
        @"/Applications/Final Cut Pro.app/Contents/_MASReceipt/receipt"];

    sCheckedReceiptPaths = [paths copy];

    for (NSString *path in paths) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length > 0) {
            SpliceKit_log(@"[Receipt] Found: %@ (%lu bytes)", path, (unsigned long)data.length);
            SpliceKit_logReceiptDiagnostics(data, path);
            return YES;
        }
    }

    SpliceKit_log(@"[Receipt] No App Store receipt found. Checked:");
    for (NSString *path in paths) {
        SpliceKit_log(@"[Receipt]   %@", path);
    }
    return NO;
}

// Handle subscription validation based on which FCP edition is running.
// - Standard FCP (com.apple.FinalCut): perpetual license, no receipt check needed.
// - Creator Studio (com.apple.FinalCutApp): subscription-based, verify receipt file exists.
// - Unknown: proceed without blocking (future-proofing).
//
// Creator Studio uses an online subscription validation flow (SPV) at launch.
// After ad-hoc re-signing for dylib injection, the entitlements required for that
// online check are lost, causing a "Cannot Connect" error on startup. We route
// around it by making isSPVEnabled return NO.
static void SpliceKit_handleSubscriptionValidation(void) {
    SpliceKit_log(@"Checking subscription status...");

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    SpliceKit_log(@"  Bundle identifier: %@", bundleId ?: @"(nil)");

    BOOL isCreatorStudio = [bundleId isEqualToString:@"com.apple.FinalCutApp"];
    BOOL isStandardFCP   = [bundleId isEqualToString:@"com.apple.FinalCut"];

    if (isStandardFCP) {
        // Standard FCP is a perpetual license — no subscription to validate.
        SpliceKit_log(@"  Standard FCP detected — skipping receipt validation");
    } else if (isCreatorStudio) {
        // Creator Studio requires a subscription. Verify the App Store receipt
        // file exists to confirm the user downloaded it from the App Store.
        SpliceKit_log(@"  Creator Studio detected — checking for App Store receipt");
        BOOL receiptFound = SpliceKit_findReceiptFile();
        if (!receiptFound) {
            SpliceKit_log(@"  No App Store receipt found");
            [[NSNotificationCenter defaultCenter]
                addObserverForName:NSApplicationDidFinishLaunchingNotification
                object:nil queue:nil usingBlock:^(NSNotification *note) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSMutableString *info = [NSMutableString stringWithString:
                            @"SpliceKit could not find an App Store receipt for "
                            @"Final Cut Pro Creator Studio.\n\nChecked locations:\n"];
                        for (NSString *path in sCheckedReceiptPaths) {
                            [info appendFormat:@"  \u2022 %@\n", path];
                        }
                        [info appendString:
                            @"\nPossible causes:\n"
                            @"  \u2022 Final Cut Pro was not installed from the App Store\n"
                            @"  \u2022 The original app was deleted before patching\n"
                            @"  \u2022 Volume license or MDM installation (no App Store receipt)\n"
                            @"\nPlease reinstall Final Cut Pro Creator Studio from the "
                            @"App Store, then re-run the SpliceKit patcher."];

                        NSAlert *alert = [[NSAlert alloc] init];
                        [alert setMessageText:@"No Valid Subscription Found"];
                        [alert setInformativeText:info];
                        [alert setAlertStyle:NSAlertStyleCritical];
                        [alert addButtonWithTitle:@"Quit"];
                        [alert runModal];
                        [NSApp terminate:nil];
                    });
                }];
            return;
        }
        SpliceKit_log(@"  Receipt found — proceeding with offline validation");
    } else {
        // Unknown bundle ID — don't block. Could be a renamed app or future edition.
        SpliceKit_log(@"  Unknown bundle ID \"%@\" — proceeding without receipt check", bundleId);
    }

    // Route the subscription check through the standard (non-online) launch path.
    // For standard FCP this is a harmless no-op. For Creator Studio it bypasses
    // the broken online SPV check.
    Class flexo = objc_getClass("Flexo");
    if (flexo) {
        Method m = class_getClassMethod(flexo, @selector(isSPVEnabled));
        if (m) {
            method_setImplementation(m, (IMP)returnNO_silent);
            SpliceKit_log(@"  Configured offline subscription validation");
        }
    }

    Class pcFeature = objc_getClass("PCAppFeature");
    if (pcFeature) {
        Method m = class_getClassMethod(pcFeature, @selector(isSPVEnabled));
        if (m)
            method_setImplementation(m, (IMP)returnNO_silent);
    }

    // The standard launch path triggers a CloudContent first-launch flow that
    // requires CloudKit entitlements (lost after re-signing). Mark it as already
    // completed to prevent the CloudKit crash.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"CloudContentFirstLaunchCompleted"];
    [defaults setBool:YES forKey:@"FFCloudContentDisabled"];

    SpliceKit_log(@"  Subscription validation configured");
    SpliceKit_logCloudContentGuardSummary(@"subscription-validation");
}

#pragma mark - Constructor
//
// __attribute__((constructor)) means this runs automatically when the dylib is loaded,
// before FCP's main() function. At this point most of FCP's frameworks aren't loaded
// yet, so we can only do early setup: logging, crash prevention patches, and
// registering for the "app finished launching" notification where the real work happens.
//

__attribute__((constructor))
static void SpliceKit_init(void) {
    SpliceKit_initLogging();

    SpliceKit_log(@"================================================");
    SpliceKit_log(@"SpliceKit v%s initializing...", SPLICEKIT_VERSION);
    SpliceKit_log(@"PID: %d", getpid());
    SpliceKit_log(@"Home: %@", NSHomeDirectory());

    // Log OS + FCP version early (before any swizzles) so crash logs are diagnosable.
    // SpliceKit_checkCompatibility logs FCP version too, but runs at didFinishLaunching
    // which is too late if the app crashes during startup.
    NSOperatingSystemVersion osv = [[NSProcessInfo processInfo] operatingSystemVersion];
    SpliceKit_log(@"macOS: %ld.%ld.%ld", (long)osv.majorVersion, (long)osv.minorVersion, (long)osv.patchVersion);
    NSDictionary *fcpInfo = [[NSBundle mainBundle] infoDictionary];
    SpliceKit_log(@"FCP: %@ (build %@)",
                  fcpInfo[@"CFBundleShortVersionString"] ?: @"?",
                  fcpInfo[@"CFBundleVersion"] ?: @"?");

    // Log signing status — critical for diagnosing CloudKit/entitlement crashes
    SecStaticCodeRef staticCode = NULL;
    OSStatus codeErr = SecStaticCodeCreateWithPath(
        (__bridge CFURLRef)[[NSBundle mainBundle] bundleURL], kSecCSDefaultFlags, &staticCode);
    if (codeErr == errSecSuccess && staticCode) {
        CFDictionaryRef signingInfo = NULL;
        OSStatus infoErr = SecCodeCopySigningInformation(
            (SecCodeRef)staticCode, kSecCSSigningInformation, &signingInfo);
        if (infoErr == errSecSuccess && signingInfo) {
            NSString *teamID = ((__bridge NSDictionary *)signingInfo)[@"teamid"];
            NSNumber *flags  = ((__bridge NSDictionary *)signingInfo)[@"flags"];
            SpliceKit_log(@"Signing: team=%@, flags=%@",
                          teamID ?: @"(ad-hoc)", flags ?: @"?");
            CFRelease(signingInfo);
        } else {
            SpliceKit_log(@"Signing: could not read (err=%d)", (int)infoErr);
        }
        CFRelease(staticCode);
    } else {
        SpliceKit_log(@"Signing: no static code (err=%d)", (int)codeErr);
    }

    // Log entitlements applied to this binary
    SpliceKit_logEntitlements();

    SpliceKit_log(@"================================================");

    sConstructorStart = CFAbsoluteTimeGetCurrent();

    // Crash handling stays on this Mac: exceptions and signals are written to
    // ~/Library/Logs/SpliceKit and nothing is reported anywhere.
    SpliceKit_installCrashHandlers();
    SpliceKit_log(@"Crash handlers installed (NSException + SIGTRAP/SIGABRT/SIGSEGV/SIGBUS); reports stay local");

    // These patches need to land before FCP's own init code runs
    SpliceKit_disableCloudContent();
    SpliceKit_handleSubscriptionValidation();
    SpliceKit_fixShutdownHang();

    // Retry CloudContent swizzles at WillFinishLaunching — Swift classes that were
    // lazily registered at constructor time should be available now. This fires BEFORE
    // DidFinishLaunching where the CloudContent first-launch flow runs.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationWillFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            sWillLaunchTime = CFAbsoluteTimeGetCurrent();
            SpliceKit_log(@"WillFinishLaunching (%.2fs after constructor)",
                          sWillLaunchTime - sConstructorStart);
            SpliceKit_swizzleCloudContentClasses("willLaunch");
            SpliceKit_logCloudContentGuardSummary(@"will-launch");
            SpliceKit_logLoadedFrameworks();
            SpliceKitURLImport_bootstrapAtLaunchPhase(@"will-launch");
            SpliceKit_safeInstall("MKVWillLaunchHooks", ^{
                SpliceKitMKV_bootstrapAtLaunchPhase(@"will-launch");
            });
        }];

    // Everything else waits for the app to finish launching
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            sDidLaunchTime = CFAbsoluteTimeGetCurrent();
            SpliceKit_appDidLaunch();
        }];

    SpliceKit_log(@"Constructor complete. Waiting for app launch...");
}
