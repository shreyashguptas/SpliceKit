//
//  SpliceKitProcess.h
//  Running a helper process to completion, and finding SpliceKit's helper tools.
//
//  Everything declared here is hidden: it never shows up in the dylib's exports.
//

#ifndef SpliceKitProcess_h
#define SpliceKitProcess_h

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SpliceKitProcessOutcome) {
    SpliceKitProcessExited = 0,        // ran to completion; *statusOut is its exit status
    SpliceKitProcessLaunchFailed,      // never started; *errorOut says why
    SpliceKitProcessTimedOut,          // killed after `timeout` seconds
};

typedef NS_OPTIONS(NSUInteger, SpliceKitProcessOptions) {
    SpliceKitProcessOptionsNone = 0,
    // stderr goes into the same pipe as stdout (the output comes back in *stdoutOut,
    // interleaved as the process wrote it; *stderrOut is empty).
    SpliceKitProcessMergeStderr = 1 << 0,
    // stdin is /dev/null instead of being inherited from Final Cut Pro.
    SpliceKitProcessNullStdin = 1 << 1,
};

#pragma GCC visibility push(hidden)

// Launch `path` with `arguments` and wait for it to exit. stdout and stderr are drained
// concurrently while it runs, so a process that writes more than a pipe buffer (64 KB)
// never blocks on a full pipe. `timeout` <= 0 waits without a limit; past a positive
// timeout the process is sent SIGTERM, then SIGKILL 5 s later.
// `directory` (nil: inherited) is the working directory. Any out-parameter may be NULL;
// the data ones are never nil when the process ran.
SpliceKitProcessOutcome SpliceKit_runProcess(NSString *path,
                                             NSArray<NSString *> *arguments,
                                             NSString *directory,
                                             SpliceKitProcessOptions options,
                                             NSTimeInterval timeout,
                                             int *statusOut,
                                             NSData **stdoutOut,
                                             NSData **stderrOut,
                                             NSError **errorOut);

// The first executable found for a SpliceKit helper tool called `name`, in this order:
//   the environment variable `envOverride` (Final Cut Pro's environment; nil: none),
//   the patched app's SpliceKit.framework/Versions/A/Resources/<name>,
//   ~/Applications/SpliceKit/tools/<name>,
//   ~/Library/Application Support/SpliceKit/tools/<name>,
//   ~/Library/Caches/SpliceKit/build/<name>.
// nil when none is executable.
NSString *SpliceKit_findHelperTool(NSString *name, NSString *envOverride);

#pragma GCC visibility pop

#endif /* SpliceKitProcess_h */
