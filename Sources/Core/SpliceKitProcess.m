//
//  SpliceKitProcess.m
//  See SpliceKitProcess.h.
//

#import "SpliceKitProcess.h"
#include <signal.h>

SpliceKitProcessOutcome SpliceKit_runProcess(NSString *path,
                                             NSArray<NSString *> *arguments,
                                             NSString *directory,
                                             SpliceKitProcessOptions options,
                                             NSTimeInterval timeout,
                                             int *statusOut,
                                             NSData **stdoutOut,
                                             NSData **stderrOut,
                                             NSError **errorOut) {
    if (statusOut) *statusOut = -1;
    if (stdoutOut) *stdoutOut = nil;
    if (stderrOut) *stderrOut = nil;
    if (errorOut) *errorOut = nil;

    BOOL merge = (options & SpliceKitProcessMergeStderr) != 0;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path ?: @""];
    task.arguments = arguments ?: @[];
    if (directory.length > 0) task.currentDirectoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = merge ? nil : [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = merge ? outPipe : errPipe;
    if (options & SpliceKitProcessNullStdin) task.standardInput = [NSFileHandle fileHandleWithNullDevice];

    NSError *launchError = nil;
    BOOL launched = NO;
    @try {
        launched = [task launchAndReturnError:&launchError];
    } @catch (NSException *e) {
        launchError = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOEXEC
                                      userInfo:@{NSLocalizedDescriptionKey: e.reason ?: e.name}];
    }
    if (!launched) {
        if (errorOut) *errorOut = launchError ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOEXEC
            userInfo:@{NSLocalizedDescriptionKey: @"unknown error"}];
        return SpliceKitProcessLaunchFailed;
    }

    NSFileHandle *outHandle = outPipe.fileHandleForReading;
    NSFileHandle *errHandle = errPipe.fileHandleForReading;
    __block NSData *outData = nil;
    __block NSData *errData = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    // The error-returning reads never throw (readDataToEndOfFile can raise on a GCD thread,
    // where nothing would catch it).
    dispatch_group_async(group, queue, ^{ outData = [outHandle readDataToEndOfFileAndReturnError:NULL] ?: [NSData data]; });
    if (errHandle) {
        dispatch_group_async(group, queue, ^{ errData = [errHandle readDataToEndOfFileAndReturnError:NULL] ?: [NSData data]; });
    }

    dispatch_time_t deadline = timeout > 0
        ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
        : DISPATCH_TIME_FOREVER;
    long timedOut = dispatch_group_wait(group, deadline);
    if (timedOut != 0) {
        [task terminate];
        long stillRunning = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
        if (stillRunning != 0) {
            kill(task.processIdentifier, SIGKILL);       // wedged: do not leak the readers
            dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
        }
        return SpliceKitProcessTimedOut;
    }
    [task waitUntilExit];

    if (statusOut) *statusOut = task.terminationStatus;
    if (stdoutOut) *stdoutOut = outData ?: [NSData data];
    if (stderrOut) *stderrOut = errData ?: [NSData data];
    return SpliceKitProcessExited;
}

NSString *SpliceKit_findHelperTool(NSString *name, NSString *envOverride) {
    if (name.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // Developer override (the environment Final Cut Pro was launched with).
    if (envOverride.length > 0) {
        NSString *override = [[NSProcessInfo processInfo] environment][envOverride];
        if (override.length > 0) [candidates addObject:override];
    }

    // Inside the patched app's SpliceKit.framework (make install / make deploy put it there).
    NSString *fwResources = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/Frameworks/SpliceKit.framework/Versions/A/Resources"];
    [candidates addObject:[fwResources stringByAppendingPathComponent:name]];

    // The per-user tool locations.
    NSString *home = NSHomeDirectory();
    for (NSString *dir in @[@"Applications/SpliceKit/tools",
                            @"Library/Application Support/SpliceKit/tools",
                            @"Library/Caches/SpliceKit/build"]) {
        [candidates addObject:[[home stringByAppendingPathComponent:dir] stringByAppendingPathComponent:name]];
    }

    for (NSString *p in candidates) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    return nil;
}
