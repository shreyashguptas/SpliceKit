//
//  SpliceKitTranscriptPanel+Parakeet.m
//  The Parakeet engine: locating or building the transcriber CLI and running it
//  for a whole timeline (batch) or a single file.
//

#import "SpliceKitTranscriptPanel+Private.h"

@implementation SpliceKitTranscriptPanel (Parakeet)

#pragma mark - Parakeet Transcription (NVIDIA Parakeet TDT via CLI tool)

- (NSString *)parakeetTranscriberPath {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Inside the FCP framework bundle (deployed by patcher)
    NSString *buildDir = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/Frameworks/SpliceKit.framework/Versions/A/Resources"];
    NSString *builtPath = [buildDir stringByAppendingPathComponent:@"parakeet-transcriber"];
    if ([fm fileExistsAtPath:builtPath]) {
        SpliceKit_log(@"[Transcript] Found parakeet-transcriber in framework bundle");
        return builtPath;
    }

    // 2. Standard tool locations (portable — no user-specific paths)
    NSString *home = NSHomeDirectory();
    NSArray *searchPaths = @[
        [home stringByAppendingPathComponent:@"Applications/SpliceKit/tools/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/tools/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Library/Caches/SpliceKit/tools/parakeet-transcriber/.build/release/parakeet-transcriber"],
    ];
    SpliceKit_log(@"[Transcript] Searching for parakeet-transcriber binary...");
    for (NSString *path in searchPaths) {
        BOOL exists = [fm fileExistsAtPath:path];
        SpliceKit_log(@"[Transcript]   %@ %@", exists ? @"FOUND" : @"not found:", path);
        if (exists) return path;
    }

    SpliceKit_log(@"[Transcript] parakeet-transcriber not found in any search path");
    return nil;
}

- (NSString *)findParakeetTranscriberProjectDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();
    NSArray *candidates = @[
        [home stringByAppendingPathComponent:@"Library/Caches/SpliceKit/tools/parakeet-transcriber"],
        [home stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/tools/parakeet-transcriber"],
    ];
    SpliceKit_log(@"[Transcript] Searching for Parakeet source project (Package.swift)...");
    for (NSString *path in candidates) {
        BOOL exists = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"Package.swift"]];
        SpliceKit_log(@"[Transcript]   %@ %@", exists ? @"FOUND" : @"not found:", path);
        if (exists) return path;
    }
    SpliceKit_log(@"[Transcript] No Parakeet source project found — cannot build from source");
    return nil;
}

- (BOOL)buildParakeetTranscriberWithStatus:(void(^)(NSString *status))statusUpdate {
    NSString *projectDir = [self findParakeetTranscriberProjectDir];
    if (!projectDir) {
        SpliceKit_log(@"[Transcript] Parakeet transcriber project not found in any known location");
        return NO;
    }

    statusUpdate(@"Building Parakeet transcriber (first time only)...");
    SpliceKit_log(@"[Transcript] Building Parakeet transcriber...");

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/swift";
    task.arguments = @[@"build", @"-c", @"release"];
    task.currentDirectoryPath = projectDir;

    NSPipe *outputPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = outputPipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] Failed to launch swift build: %@", e.reason);
        return NO;
    }

    NSData *outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];

    if (task.terminationStatus != 0) {
        SpliceKit_log(@"[Transcript] Parakeet build failed (exit code %d)", task.terminationStatus);
        // Log last 500 chars of build output for diagnostics
        NSString *tail = output.length > 500 ? [output substringFromIndex:output.length - 500] : output;
        SpliceKit_log(@"[Transcript] Build output (last 500 chars): %@", tail);

        // Check for specific build failures
        if ([output containsString:@"xcrun: error"] || [output containsString:@"xcode-select"]) {
            SpliceKit_log(@"[Transcript] CAUSE: Xcode Command Line Tools not installed");
        } else if ([output containsString:@"no such module"]) {
            SpliceKit_log(@"[Transcript] CAUSE: Swift package dependency resolution failed — check network");
        } else if ([output containsString:@"No space left"]) {
            SpliceKit_log(@"[Transcript] CAUSE: Disk full during build");
        } else if ([output containsString:@"Cannot find"]) {
            SpliceKit_log(@"[Transcript] CAUSE: Source files may be corrupted — re-run patcher");
        }
        return NO;
    }

    SpliceKit_log(@"[Transcript] Parakeet transcriber built successfully");
    return YES;
}

- (void)performParakeetTranscription {
    SpliceKit_log(@"[Transcript] ────────────────────────────────────────");
    SpliceKit_log(@"[Transcript] Starting Parakeet transcription (FluidAudio on-device)");
    SpliceKit_log(@"[Transcript] Model: Parakeet %@, Speakers: %@",
        self.parakeetModelVersion ?: @"v3",
        self.speakerDetectionEnabled ? @"ON" : @"OFF");

    // Diagnostic: system info and environment
    NSDate *diagStartTime = [NSDate date];
    SpliceKitTranscriptDiag_logSystemInfo();

    // Check / build the CLI tool
    NSString *binaryPath = [self parakeetTranscriberPath];
    if (!binaryPath) {
        SpliceKit_log(@"[Transcript] Pre-built binary not found, attempting to build from source...");
        __block BOOL buildOK = NO;
        buildOK = [self buildParakeetTranscriberWithStatus:^(NSString *status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateStatusUI:status];
                self.progressBar.indeterminate = YES;
            });
        }];
        if (!buildOK) {
            NSString *xcodeCheck = @"";
            NSTask *xcTask = [[NSTask alloc] init];
            xcTask.launchPath = @"/usr/bin/xcode-select";
            xcTask.arguments = @[@"-p"];
            NSPipe *xcPipe = [NSPipe pipe];
            xcTask.standardOutput = xcPipe;
            xcTask.standardError = xcPipe;
            @try {
                [xcTask launch];
                [xcTask waitUntilExit];
                if (xcTask.terminationStatus != 0) {
                    xcodeCheck = @"\n\nXcode Command Line Tools are NOT installed.\nRun this in Terminal: xcode-select --install";
                }
            } @catch (NSException *e) {}

            // Name the command that actually installs it. The old text pointed at
            // "the SpliceKit patcher app" and a path to copy a binary into by
            // hand — neither of which exists in a source checkout, so anyone who
            // followed it got nowhere.
            NSString *msg = [NSString stringWithFormat:
                @"Parakeet transcriber not installed.\n\n"
                @"Build and install it from your SpliceKit checkout:\n"
                @"    make install\n\n"
                @"(or 'make transcribers' to build just this). The first build "
                @"downloads the speech dependencies and takes a few minutes.\n\n"
                @"Meanwhile, the \"FCP Native\" engine in the dropdown above needs "
                @"no extra binary.%@",
                xcodeCheck];
            [self setErrorState:msg];
            SpliceKit_log(@"[Transcript] ERROR: Parakeet transcriber not found and could not be built.");
            SpliceKit_log(@"[Transcript] FIX: run 'make install' (or 'make transcribers') in the SpliceKit checkout.");
            return;
        }
        binaryPath = [self parakeetTranscriberPath];
        if (!binaryPath) {
            [self setErrorState:@"Parakeet transcriber built but could not be located afterwards. "
                                "Re-install it with 'make install', or switch engine in the dropdown above."];
            return;
        }
    }

    SpliceKit_log(@"[Transcript] Using parakeet-transcriber at: %@", binaryPath);
    SpliceKitTranscriptDiag_logBinaryInfo(binaryPath);

    // Verify the binary is executable
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:binaryPath]) {
        SpliceKit_log(@"[Transcript] ERROR: parakeet-transcriber exists but is not executable");
        [self setErrorState:[NSString stringWithFormat:
            @"Parakeet binary is not executable:\n%@\n\nRe-install it with: make install", binaryPath]];
        return;
    }

    // Collect clips from timeline (reuse existing logic)
    __block NSArray *clips = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = [self getActiveTimelineModule];
            if (!timeline) {
                [self setErrorState:@"No active timeline. Open a project first."];
                return;
            }

            // Detect frame rate
            if ([timeline respondsToSelector:@selector(sequenceFrameDuration)]) {
                SpliceKitTranscript_CMTime fd = ((SpliceKitTranscript_CMTime (*)(id, SEL))STRET_MSG)(
                    timeline, @selector(sequenceFrameDuration));
                if (fd.timescale > 0 && fd.value > 0) {
                    self.frameRate = (double)fd.timescale / fd.value;
                    self.frameRateKnown = YES;
                }
            }

            id sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
            if (!sequence) { [self setErrorState:@"No sequence in timeline."]; return; }

            id primaryObj = [sequence respondsToSelector:@selector(primaryObject)]
                ? ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject))
                : nil;

            NSString *collectError = nil;
            clips = [self collectClipInfosForSequence:sequence
                                         primaryObject:primaryObj
                                          errorMessage:&collectError];
            if (!clips) {
                [self setErrorState:collectError ?: @"No items on timeline."];
                return;
            }
        } @catch (NSException *e) {
            [self setErrorState:[NSString stringWithFormat:@"Error reading timeline: %@", e.reason]];
        }
    });

    if (!clips || clips.count == 0) {
        if (self.status != SpliceKitTranscriptStatusError) {
            [self setErrorState:@"No media clips found on timeline. Make sure you have a project open with clips."];
            SpliceKit_log(@"[Transcript] No clips found. Is a project/timeline open?");
        }
        return;
    }

    SpliceKit_log(@"[Transcript] Found %lu items on timeline", (unsigned long)clips.count);
    SpliceKitTranscriptDiag_logClipInfos(clips, @"Parakeet");

    // Filter to clips with media URLs
    NSMutableArray *transcribableClips = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *skipped = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *fileProblems = [NSMutableDictionary dictionary];
    NSUInteger skippedNoMedia = 0;
    NSUInteger skippedTooShort = 0;
    NSUInteger skippedMuted = 0;
    NSUInteger skippedUnreadable = 0;
    for (NSDictionary *clipInfo in clips) {
        if (!clipInfo[@"mediaURL"]) {
            skippedNoMedia++;
            continue;
        }
        double dur = [clipInfo[@"duration"] doubleValue];
        if (dur < 0.5) {
            skippedTooShort++;
            SpliceKit_log(@"[Transcript] Skipping clip (%.2fs, too short for transcription): %@",
                dur, [clipInfo[@"mediaURL"] lastPathComponent]);
            continue;
        }
        // A clip turned all the way down (-96 dB, FCP's floor) is not heard in the
        // edit, so its words would only be noise in the transcript of the cut.
        if (clipInfo[@"volumeDB"] && [clipInfo[@"volumeDB"] doubleValue] <= -60.0) {
            skippedMuted++;
            [skipped addObject:@{
                @"name": clipInfo[@"name"] ?: @"",
                @"file": [clipInfo[@"mediaURL"] path] ?: @"",
                @"timelineStart": clipInfo[@"timelineStart"] ?: @0,
                @"connected": clipInfo[@"connected"] ?: @NO,
                @"reason": [clipInfo[@"volumeDB"] doubleValue] <= -199.0 ? @"muted (volume at the -96 dB floor)"
                    : [NSString stringWithFormat:@"muted (volume %.0f dB)", [clipInfo[@"volumeDB"] doubleValue]],
            }];
            continue;
        }
        // Screen recordings with no audio track, media on an unmounted volume and
        // unreadable files used to go to the helper, which failed the whole batch
        // on the first one. Check each file once and leave the bad ones out.
        NSString *path = [clipInfo[@"mediaURL"] path];
        if (path && !fileProblems[path]) {
            fileProblems[path] = [SpliceKitTranscriptPanel audioProblemForFileAtPath:path] ?: @"";
        }
        NSString *problem = path ? fileProblems[path] : @"no file path";
        if (problem.length > 0) {
            skippedUnreadable++;
            [skipped addObject:@{
                @"name": clipInfo[@"name"] ?: @"",
                @"file": path ?: @"",
                @"timelineStart": clipInfo[@"timelineStart"] ?: @0,
                @"connected": clipInfo[@"connected"] ?: @NO,
                @"reason": problem,
            }];
            SpliceKit_log(@"[Transcript] Skipping %@: %@", path.lastPathComponent, problem);
            continue;
        }
        [transcribableClips addObject:clipInfo];
    }
    self.skippedSources = skipped;
    if (skippedMuted > 0) {
        SpliceKit_log(@"[Transcript] Skipped %lu muted clips", (unsigned long)skippedMuted);
    }

    if (skippedNoMedia > 0) {
        SpliceKit_log(@"[Transcript] Skipped %lu items without source media (gaps, generators, titles)",
            (unsigned long)skippedNoMedia);
    }
    if (skippedTooShort > 0) {
        SpliceKit_log(@"[Transcript] Skipped %lu clips shorter than 0.5s (too short for speech recognition)",
            (unsigned long)skippedTooShort);
    }

    // Deduplicate clip infos that share the same source file and time range.
    // FCP stores video (v1) and audio (a1) as separate FFAnchoredMediaComponent
    // objects — without dedup, the same words get mapped to both, doubling the count.
    {
        NSMutableArray *deduped = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *clipInfo in transcribableClips) {
            NSURL *mediaURL = clipInfo[@"mediaURL"];
            double trimStart = [clipInfo[@"trimStart"] doubleValue];
            double duration = [clipInfo[@"duration"] doubleValue];
            NSString *key = [NSString stringWithFormat:@"%@|%.2f|%.2f", mediaURL.path, trimStart, duration];
            if ([seen containsObject:key]) {
                SpliceKit_log(@"[Transcript] Dedup: skipping duplicate component for %@", mediaURL.lastPathComponent);
                continue;
            }
            [seen addObject:key];
            [deduped addObject:clipInfo];
        }
        if (deduped.count < transcribableClips.count) {
            SpliceKit_log(@"[Transcript] Deduplicated %lu → %lu clip infos (removed audio/video duplicates)",
                (unsigned long)transcribableClips.count, (unsigned long)deduped.count);
        }
        transcribableClips = deduped;
    }

    if (transcribableClips.count == 0) {
        NSString *reason = @"No transcribable clips found on timeline.";
        if (skippedUnreadable > 0 || skippedMuted > 0) {
            NSMutableArray *why = [NSMutableArray array];
            for (NSDictionary *entry in skipped) {
                NSString *line = [NSString stringWithFormat:@"%@: %@",
                    [entry[@"file"] lastPathComponent] ?: entry[@"name"], entry[@"reason"]];
                if (![why containsObject:line]) [why addObject:line];
                if (why.count >= 8) break;
            }
            reason = [NSString stringWithFormat:@"No clip on the timeline has audio that can be transcribed. %@",
                [why componentsJoinedByString:@"; "]];
        } else if (skippedTooShort > 0 && skippedNoMedia == 0) {
            reason = [NSString stringWithFormat:
                @"All %lu clips are too short for transcription (< 0.5 seconds). "
                @"Parakeet needs at least 1 second of audio.", (unsigned long)skippedTooShort];
        } else if (skippedNoMedia > 0) {
            reason = @"No clips with source media files found. The timeline may only contain gaps, generators, or titles.";
        }
        [self setErrorState:reason];
        SpliceKit_log(@"[Transcript] %@", reason);
        return;
    }

    [self.mutableWords removeAllObjects];
    [self.mutableSilences removeAllObjects];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusUI:[NSString stringWithFormat:@"Transcribing %lu clips with Parakeet...",
            (unsigned long)transcribableClips.count]];
        self.progressBar.hidden = NO;
        self.progressBar.indeterminate = NO;
        self.progressBar.doubleValue = 0;
    });

    // Build batch manifest — deduplicate so each source file is transcribed only once
    NSString *manifestPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splicekit_batch.json"];
    NSMutableOrderedSet *uniqueFiles = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *clipInfo in transcribableClips) {
        NSURL *mediaURL = clipInfo[@"mediaURL"];
        [uniqueFiles addObject:mediaURL.path];
    }
    NSMutableArray *manifestEntries = [NSMutableArray array];
    for (NSString *file in uniqueFiles) {
        [manifestEntries addObject:@{@"file": file}];
    }
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifestEntries options:0 error:nil];
    [manifestData writeToFile:manifestPath atomically:YES];

    SpliceKit_log(@"[Transcript] Parakeet batch: %lu clips, %lu unique source files",
        (unsigned long)transcribableClips.count, (unsigned long)uniqueFiles.count);
    for (NSString *file in uniqueFiles) {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:file];
        SpliceKit_log(@"[Transcript]   %@ %@", exists ? @"OK" : @"MISSING!", [file lastPathComponent]);
        if (!exists) {
            SpliceKit_log(@"[Transcript]   Full path: %@", file);
        }
    }

    SpliceKitTranscriptDiag_logBatchManifest(manifestEntries);

    // Build arguments for batch mode
    NSMutableArray *taskArgs = [NSMutableArray arrayWithObjects:@"--batch", manifestPath, @"--progress", nil];
    if (self.speakerDetectionEnabled) {
        [taskArgs addObject:@"--speakers"];
    }
    [taskArgs addObject:@"--model"];
    [taskArgs addObject:self.parakeetModelVersion ?: @"v3"];

    SpliceKitTranscriptDiag_logProcessLaunch(binaryPath, taskArgs);

    // Run the CLI tool with streaming stderr for progress
    NSDate *processStartTime = [NSDate date];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = binaryPath;
    task.arguments = taskArgs;

    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    // Read stdout asynchronously to prevent pipe buffer deadlock
    __block NSMutableData *stdoutAccum = [NSMutableData data];
    stdoutPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length > 0) {
            @synchronized (stdoutAccum) {
                [stdoutAccum appendData:data];
            }
        }
    };

    // Read stderr asynchronously for live progress updates. Keep every byte: the
    // handler consumes the pipe, so reading it again after exit found nothing and
    // every failure came back as a bare "exit code 1" without the helper's reason.
    self.totalTranscriptions = uniqueFiles.count;
    self.completedTranscriptions = 0;
    __block NSMutableData *stderrAccum = [NSMutableData data];
    stderrPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;
        @synchronized (stderrAccum) {
            [stderrAccum appendData:data];
        }

        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) return;

        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"PROGRESS:"]) {
                NSArray *parts = [line componentsSeparatedByString:@":"];
                if (parts.count >= 3) {
                    double frac = [parts[1] doubleValue];
                    NSString *msg = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)]
                        componentsJoinedByString:@":"];
                    self.progressFraction = frac;
                    self.progressMessage = msg;
                    // "Transcribing 3/7: name..." — the helper's per-file counter.
                    NSRegularExpression *re = [NSRegularExpression
                        regularExpressionWithPattern:@"^Transcribing (\\d+)/(\\d+)" options:0 error:nil];
                    NSTextCheckingResult *m = [re firstMatchInString:msg options:0 range:NSMakeRange(0, msg.length)];
                    if (m) {
                        self.completedTranscriptions = (NSUInteger)MAX(0, [[msg substringWithRange:[m rangeAtIndex:1]] integerValue] - 1);
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.progressBar.indeterminate = NO;
                        self.progressBar.doubleValue = frac;
                        [self updateStatusUI:[NSString stringWithFormat:@"Parakeet: %@", msg]];
                    });
                }
            } else if ([line hasPrefix:@"ERROR:"]) {
                NSString *errMsg = [line substringFromIndex:6];
                SpliceKit_log(@"[Transcript] Parakeet: %@", errMsg);
                // Show actionable errors in the UI too
                if ([errMsg containsString:@"Network"] || [errMsg containsString:@"network"] ||
                    [errMsg containsString:@"connect"] || [errMsg containsString:@"internet"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self updateStatusUI:@"Parakeet: Network error — check internet connection"];
                    });
                } else if ([errMsg containsString:@"rate-limited"] || [errMsg containsString:@"rate limit"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self updateStatusUI:@"Parakeet: Download rate-limited — wait a few minutes and retry"];
                    });
                } else if ([errMsg containsString:@"disk"] || [errMsg containsString:@"space"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self updateStatusUI:@"Parakeet: Not enough disk space (~475 MB needed)"];
                    });
                } else if ([errMsg containsString:@"INFO:"]) {
                    // Informational, just log
                } else if ([errMsg containsString:@"TIP:"]) {
                    SpliceKit_log(@"[Transcript] %@", errMsg);
                }
            }
        }
    };

    SpliceKit_log(@"[Transcript] Launching: %@ %@", binaryPath,
        [taskArgs componentsJoinedByString:@" "]);

    NSUInteger generation = self.runGeneration;
    @try {
        [task launch];
        self.activeHelperTask = task;
        SpliceKit_log(@"[Transcript] Parakeet process started (PID %d)", task.processIdentifier);
        [task waitUntilExit];
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] ERROR: Failed to launch parakeet-transcriber: %@", e.reason);
        stdoutPipe.fileHandleForReading.readabilityHandler = nil;
        stderrPipe.fileHandleForReading.readabilityHandler = nil;
        NSString *hint = @"";
        if ([e.reason containsString:@"launch path"]) {
            hint = @"\n\nThe binary may be corrupted. Try re-running the SpliceKit patcher.";
        } else if ([e.reason containsString:@"Permission"]) {
            hint = @"\n\nTry: chmod +x ~/Applications/SpliceKit/tools/parakeet-transcriber";
        }
        [self setErrorState:[NSString stringWithFormat:@"Could not launch Parakeet transcriber: %@%@", e.reason, hint]];
        return;
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    stderrPipe.fileHandleForReading.readabilityHandler = nil;
    if (generation != self.runGeneration) {
        SpliceKit_log(@"[Transcript] Dropping the result of a superseded timeline run");
        [[NSFileManager defaultManager] removeItemAtPath:manifestPath error:nil];
        return;
    }
    if (self.activeHelperTask == task) self.activeHelperTask = nil;

    NSData *remaining = [stdoutPipe.fileHandleForReading readDataToEndOfFile];
    if (remaining.length > 0) {
        @synchronized (stdoutAccum) {
            [stdoutAccum appendData:remaining];
        }
    }

    // Clean up manifest
    [[NSFileManager defaultManager] removeItemAtPath:manifestPath error:nil];

    // -[NSTask terminationStatus] throws NSInvalidArgumentException if the task
    // is still running. waitUntilExit normally guarantees termination, but in
    // edge cases (e.g. arm64-only binary launched on x86, signal interruption,
    // pipe failures) the task can be in an inconsistent state. Read it once,
    // defensively, and treat a throw as a non-zero exit. See APPLE-MACOS-17.
    int exitCode = -1;
    @try {
        if (task.isRunning) {
            SpliceKit_log(@"[Transcript] WARNING: task still running after waitUntilExit; terminating");
            [task terminate];
            [task waitUntilExit];
        }
        exitCode = task.terminationStatus;
    } @catch (NSException *e) {
        SpliceKit_log(@"[Transcript] ERROR: failed to read terminationStatus: %@", e.reason);
        exitCode = -1;
    }

    // Diagnostic: process exit details
    {
        NSTimeInterval processElapsed = -[processStartTime timeIntervalSinceNow];
        NSData *stderrDiagData = [stderrPipe.fileHandleForReading availableData];
        NSData *stdoutDiagData;
        @synchronized (stdoutAccum) {
            stdoutDiagData = [stdoutAccum copy];
        }
        SpliceKitTranscriptDiag_logProcessExit(exitCode,
                                                stdoutDiagData, stderrDiagData, processElapsed);
        SpliceKitTranscriptDiag_inspectRawOutput(stdoutDiagData);
    }

    if (exitCode != 0) {
        SpliceKit_log(@"[Transcript] ─── Parakeet failed (exit code %d) ───", exitCode);

        // Collect all stderr output for diagnostics: what the handler kept plus
        // anything still in the pipe.
        NSMutableData *stderrAll;
        @synchronized (stderrAccum) {
            stderrAll = [stderrAccum mutableCopy];
        }
        NSData *stderrRemaining = [stderrPipe.fileHandleForReading readDataToEndOfFile];
        if (stderrRemaining.length) [stderrAll appendData:stderrRemaining];
        NSString *stderrText = [[NSString alloc] initWithData:stderrAll encoding:NSUTF8StringEncoding] ?: @"";
        // PROGRESS lines carry file names ("Transcribing 2/5: Connecting rods.mov"),
        // which the keyword matching below would misread as a network/disk error.
        NSMutableArray *nonProgress = [NSMutableArray array];
        for (NSString *line in [stderrText componentsSeparatedByString:@"\n"]) {
            if (line.length && ![line hasPrefix:@"PROGRESS:"]) [nonProgress addObject:line];
        }
        stderrText = nonProgress.count ? [[nonProgress componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : @"";

        // Also check stdout for error JSON
        NSString *stdoutText = nil;
        @synchronized (stdoutAccum) {
            stdoutText = [[NSString alloc] initWithData:stdoutAccum encoding:NSUTF8StringEncoding] ?: @"";
        }

        // Log everything we have
        NSString *allOutput = [NSString stringWithFormat:@"%@%@", stderrText, stdoutText];
        if (allOutput.length > 0) {
            // Log full output line by line for readability
            for (NSString *line in [allOutput componentsSeparatedByString:@"\n"]) {
                if (line.length > 0) {
                    SpliceKit_log(@"[Transcript]   parakeet> %@", line);
                }
            }
        } else {
            SpliceKit_log(@"[Transcript]   (no output from parakeet-transcriber)");
        }

        // Build a user-friendly error with specific guidance. Classify on stderr only:
        // when every file fails the helper prints the per-file results (with their
        // paths) on stdout, and a path like ".../Connecting rods.mov" matched the
        // network keywords below.
        NSString *userError = nil;
        NSString *allLower = [stderrText lowercaseString];

        id failedFiles = stdoutText.length
            ? [NSJSONSerialization JSONObjectWithData:[stdoutText dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:nil]
            : nil;
        if ([failedFiles isKindOfClass:[NSArray class]]) {
            NSMutableArray *why = [NSMutableArray array];
            for (NSDictionary *entry in (NSArray *)failedFiles) {
                if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"error"] isKindOfClass:[NSString class]]) continue;
                [why addObject:[NSString stringWithFormat:@"%@: %@",
                    [entry[@"file"] description].lastPathComponent, entry[@"error"]]];
                if (why.count >= 8) break;
            }
            if (why.count > 0) {
                userError = [NSString stringWithFormat:@"Parakeet could not transcribe any clip. %@",
                    [why componentsJoinedByString:@"; "]];
            }
        }

        if (userError) {
            // per-file reasons from the helper, above
        } else if ([allLower containsString:@"invalid audio"] || [allLower containsString:@"at least 1 second"]) {
            userError = @"Audio clips are too short for transcription. Parakeet requires at least 1 second of audio per clip.";
        } else if ([allLower containsString:@"no such file"] || [allLower containsString:@"file not found"]) {
            userError = @"Source media file not found. The media may have been moved or is offline. Check File > Relink Files in FCP.";
        } else if ([allLower containsString:@"network"] || [allLower containsString:@"connect"] ||
                   [allLower containsString:@"urlsession"] || [allLower containsString:@"timed out"]) {
            userError = @"Could not download the Parakeet AI model. Check your internet connection and try again. "
                        @"The model (~475 MB) is downloaded once and cached locally.";
        } else if ([allLower containsString:@"rate-limited"] || [allLower containsString:@"rate limit"] ||
                   [allLower containsString:@"429"]) {
            userError = @"Model download was rate-limited. Wait a few minutes and try again.";
        } else if ([allLower containsString:@"disk"] || [allLower containsString:@"no space"] ||
                   [allLower containsString:@"not enough space"]) {
            userError = @"Not enough disk space for the Parakeet model (~475 MB required). Free up some space and try again.";
        } else if ([allLower containsString:@"memory"] || [allLower containsString:@"cannot allocate"] ||
                   [allLower containsString:@"out of memory"]) {
            userError = @"Not enough memory to run Parakeet. Close other apps and try again, or switch to Apple Speech engine.";
        } else if ([allLower containsString:@"intel"] || [allLower containsString:@"neural engine"] ||
                   [allLower containsString:@"coreml"] || [allLower containsString:@"not supported"]) {
            userError = @"Parakeet requires Apple Silicon (M1 or later). Switch to \"Apple Speech\" in the engine dropdown.";
        } else if ([allLower containsString:@"permission"] || [allLower containsString:@"denied"]) {
            userError = @"Permission denied reading media file. Check that FCP has Full Disk Access in System Settings > Privacy.";
        } else if ([allLower containsString:@"corrupt"] || [allLower containsString:@"invalid data"]) {
            userError = @"Media file appears to be corrupted or in an unsupported format.";
        } else if (exitCode == 9) {
            userError = @"Parakeet was killed (likely out of memory). Close other apps and try again with fewer clips.";
        } else if (exitCode == 6) {
            userError = @"Parakeet crashed (SIGABRT). This may be a compatibility issue. Try switching to Apple Speech engine.";
        } else {
            // Generic fallback with the actual output: the helper's ERROR: lines
            // (without its TIP: lines), else its last line.
            NSString *lastLine = @"";
            NSArray *lines = [stderrText componentsSeparatedByString:@"\n"];
            NSMutableArray *errorLines = [NSMutableArray array];
            for (NSString *line in lines) {
                if (![line hasPrefix:@"ERROR:"]) continue;
                NSString *body = [line substringFromIndex:6];
                if ([body hasPrefix:@"TIP:"] || [body hasPrefix:@"INFO:"]) continue;
                if (![errorLines containsObject:body]) [errorLines addObject:body];
            }
            if (errorLines.count > 0) {
                lastLine = [errorLines componentsJoinedByString:@" | "];
            }
            for (NSString *line in [lines reverseObjectEnumerator]) {
                if (lastLine.length > 0) break;
                if (line.length > 0 && ![line hasPrefix:@"PROGRESS:"]) {
                    lastLine = line;
                    break;
                }
            }
            if (lastLine.length > 0) {
                userError = [NSString stringWithFormat:@"Parakeet transcription failed: %@", lastLine];
            } else {
                userError = [NSString stringWithFormat:@"Parakeet transcription failed (exit code %d). "
                    @"Try switching to \"Apple Speech\" engine.", exitCode];
            }
        }

        SpliceKit_log(@"[Transcript] User-facing error: %@", userError);
        SpliceKit_log(@"[Transcript] ─── End of Parakeet error ───");
        [self setErrorState:userError];
        return;
    }

    SpliceKit_log(@"[Transcript] Parakeet finished successfully (exit code 0)");

    // Parse batch JSON output: [{"file":"path","words":[...]}, ...]
    NSData *jsonData;
    @synchronized (stdoutAccum) {
        jsonData = [stdoutAccum copy];
    }

    SpliceKit_log(@"[Transcript] Parsing output (%lu bytes)", (unsigned long)jsonData.length);

    if (jsonData.length == 0) {
        SpliceKit_log(@"[Transcript] ERROR: Parakeet produced no output (0 bytes on stdout)");
        [self setErrorState:@"Parakeet produced no output. The audio may be silent or too short. Try a longer clip."];
        return;
    }

    // CoreML's E5RT runtime can print error messages to stdout before the JSON.
    // Detect and strip any non-JSON prefix so parsing succeeds.
    NSString *rawOutput = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    BOOL hadCoreMLWarning = NO;
    if (rawOutput && [rawOutput hasPrefix:@"E5RT "]) {
        hadCoreMLWarning = YES;
        // Find the JSON array start — CoreML error text precedes it
        NSRange bracketRange = [rawOutput rangeOfString:@"["];
        if (bracketRange.location != NSNotFound) {
            NSString *errPrefix = [rawOutput substringToIndex:bracketRange.location];
            SpliceKit_log(@"[Transcript] CoreML warning on stdout (stripped): %@", [errPrefix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
            rawOutput = [rawOutput substringFromIndex:bracketRange.location];
            jsonData = [rawOutput dataUsingEncoding:NSUTF8StringEncoding];
        }
    }

    NSError *jsonError = nil;
    NSArray *batchResults = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];

    if (![batchResults isKindOfClass:[NSArray class]]) {
        SpliceKit_log(@"[Transcript] ERROR: Parakeet returned invalid JSON: %@",
            jsonError ? jsonError.localizedDescription : @"not an array");
        // Log first 500 chars of what we got
        NSString *preview = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"(binary data)";
        if (preview.length > 500) preview = [preview substringToIndex:500];
        SpliceKit_log(@"[Transcript] Raw output preview: %@", preview);
        [self setErrorState:@"Parakeet returned unexpected output. Check the log for details."];
        return;
    }

    SpliceKit_log(@"[Transcript] Got results for %lu files", (unsigned long)batchResults.count);
    SpliceKitTranscriptDiag_logParsedResults(batchResults);

    // Map results back to clips by file path
    NSMutableDictionary *resultsByFile = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *errorsByFile = [NSMutableDictionary dictionary];
    for (NSDictionary *result in batchResults) {
        NSString *file = result[@"file"];
        NSArray *words = result[@"words"];
        if ([result[@"error"] isKindOfClass:[NSString class]] && file) {
            errorsByFile[file] = result[@"error"];
            continue;
        }
        if (file && [words isKindOfClass:[NSArray class]]) {
            resultsByFile[file] = words;
        }
    }
    // A file the helper could not read no longer fails the batch; it comes back
    // with its own error. Report those clips as skipped, with the helper's reason.
    if (errorsByFile.count > 0) {
        NSMutableArray *skippedNow = [self.skippedSources mutableCopy] ?: [NSMutableArray array];
        for (NSDictionary *clipInfo in transcribableClips) {
            NSString *path = [clipInfo[@"mediaURL"] path];
            NSString *err = path ? errorsByFile[path] : nil;
            if (!err) continue;
            [skippedNow addObject:@{
                @"name": clipInfo[@"name"] ?: @"",
                @"file": path,
                @"timelineStart": clipInfo[@"timelineStart"] ?: @0,
                @"connected": clipInfo[@"connected"] ?: @NO,
                @"reason": [NSString stringWithFormat:@"transcriber could not read it: %@", err],
            }];
        }
        self.skippedSources = skippedNow;
        if (resultsByFile.count == 0) {
            NSMutableArray *why = [NSMutableArray array];
            for (NSString *file in errorsByFile) {
                [why addObject:[NSString stringWithFormat:@"%@: %@", file.lastPathComponent, errorsByFile[file]]];
                if (why.count >= 8) break;
            }
            [self setErrorState:[NSString stringWithFormat:@"Parakeet could not transcribe any clip. %@",
                [why componentsJoinedByString:@"; "]]];
            return;
        }
    }

    // Process results for each clip
    @synchronized (self.mutableWords) {
        for (NSDictionary *clipInfo in transcribableClips) {
            NSURL *mediaURL = clipInfo[@"mediaURL"];
            double timelineStart = [clipInfo[@"timelineStart"] doubleValue];
            double trimStart = [clipInfo[@"trimStart"] doubleValue];
            double clipDuration = [clipInfo[@"duration"] doubleValue];
            double mediaOrigin = [clipInfo[@"mediaOrigin"] doubleValue];
            // Timeline seconds per second of the file (conformed frame rate); 1 normally.
            double rateFactor = clipInfo[@"rateFactor"] ? [clipInfo[@"rateFactor"] doubleValue] : 1.0;
            if (!(rateFactor > 0)) rateFactor = 1.0;
            double fileSpan = clipDuration / rateFactor;
            NSString *clipHandle = clipInfo[@"handle"];

            NSArray *wordDicts = resultsByFile[mediaURL.path];
            if (!wordDicts) {
                SpliceKit_log(@"[Transcript] No results for %@", mediaURL.lastPathComponent);
                continue;
            }

            // Convert trimStart from FCP's timecode coordinate space to file-relative.
            // FCP stores times including embedded timecode offsets (e.g. camera TC at 22:32:24 = 81144s),
            // but Parakeet returns file-relative timestamps starting from 0.
            double fileRelativeTrimStart = trimStart - mediaOrigin;

            // Log diagnostics for coordinate mapping
            if (wordDicts.count > 0) {
                double minTime = [[wordDicts[0] valueForKey:@"startTime"] doubleValue];
                double maxTime = [[wordDicts[wordDicts.count - 1] valueForKey:@"startTime"] doubleValue];
                SpliceKit_log(@"[Transcript] %@ — %lu raw words (%.2fs-%.2fs), filter window: %.2fs-%.2fs (mediaOrigin=%.2fs)",
                    mediaURL.lastPathComponent, (unsigned long)wordDicts.count,
                    minTime, maxTime, fileRelativeTrimStart, fileRelativeTrimStart + clipDuration, mediaOrigin);
            }

            NSUInteger wordsAdded = 0;
            for (NSDictionary *wd in wordDicts) {
                NSString *text = wd[@"word"];
                double startTime = [wd[@"startTime"] doubleValue];
                double endTime = [wd[@"endTime"] doubleValue];
                double confidence = [wd[@"confidence"] doubleValue];
                NSString *speaker = wd[@"speaker"] ?: @"Unknown";
                // Expand short diarization labels (S1, S2) to readable names
                if (speaker.length <= 3 && [speaker hasPrefix:@"S"]) {
                    speaker = [NSString stringWithFormat:@"Speaker %@", [speaker substringFromIndex:1]];
                }

                if (startTime >= fileRelativeTrimStart && startTime < fileRelativeTrimStart + fileSpan) {
                    SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
                    word.text = text;
                    word.startTime = timelineStart + (startTime - fileRelativeTrimStart) * rateFactor;
                    word.duration = MIN(endTime - startTime, (fileRelativeTrimStart + fileSpan) - startTime) * rateFactor;
                    word.confidence = confidence;
                    word.clipHandle = clipHandle;
                    word.clipTimelineStart = timelineStart;
                    word.sourceMediaOffset = trimStart;
                    word.sourceMediaTime = startTime + mediaOrigin;
                    word.sourceMediaPath = mediaURL.path;
                    word.speaker = speaker;
                    [self.mutableWords addObject:word];
                    wordsAdded++;
                }
            }

            SpliceKit_log(@"[Transcript] Parakeet got %lu words from %@",
                (unsigned long)wordsAdded, mediaURL.lastPathComponent);
            SpliceKitTranscriptDiag_logWordFiltering(mediaURL.lastPathComponent,
                wordDicts, trimStart, mediaOrigin, clipDuration, wordsAdded);
        }
    }

    // If CoreML had an error and we got 0 words, surface actionable guidance
    NSUInteger totalWords;
    @synchronized (self.mutableWords) {
        totalWords = self.mutableWords.count;
    }
    if (totalWords == 0 && hadCoreMLWarning) {
        SpliceKit_log(@"[Transcript] ERROR: CoreML returned 0 words due to E5RT shape error. "
                       "This is a macOS CoreML compatibility issue with the current model.");
        [self setErrorState:@"CoreML model error (0 words). Try: (1) update macOS, "
                            "(2) switch to a different engine (Apple Speech or FCP Native), "
                            "or (3) delete ~/Library/Application Support/FluidAudio/Models/ and retry."];
        return;
    }

    // Finalize — sort, index, detect silences, build UI
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self.mutableWords) {
            [self.mutableWords sortUsingComparator:^NSComparisonResult(SpliceKitTranscriptWord *a, SpliceKitTranscriptWord *b) {
                if (a.startTime < b.startTime) return NSOrderedAscending;
                if (a.startTime > b.startTime) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            for (NSUInteger i = 0; i < self.mutableWords.count; i++) {
                self.mutableWords[i].wordIndex = i;
            }
        }

        [self detectSilences];
        [self assignSpeakers];

        self.completedTranscriptions = self.totalTranscriptions;
        self.status = SpliceKitTranscriptStatusReady;
        [self rebuildTextView];
        [self startPlayheadTimer];

        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.progressBar.hidden = YES;
        self.refreshButton.enabled = YES;
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);

        NSUInteger skippedCount = self.skippedSources.count;
        [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses (Parakeet)%@",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count,
            skippedCount ? [NSString stringWithFormat:@", %lu clips skipped", (unsigned long)skippedCount] : @""]];

        SpliceKit_log(@"[Transcript] Parakeet transcription complete: %lu words, %lu silences",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count);
        SpliceKitTranscriptDiag_logSummary(
            [NSString stringWithFormat:@"Parakeet %@", self.parakeetModelVersion ?: @"v3"],
            -[diagStartTime timeIntervalSinceNow],
            self.mutableWords.count,
            self.mutableSilences.count,
            transcribableClips.count,
            self.errorMessage);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SpliceKitTranscriptDidComplete" object:self];
    });
}

// Transcribe one file with the Parakeet CLI.
//
// Deliberately separate from performParakeetTranscription, which is built
// around the timeline: it collects clips, deduplicates their source media,
// runs the CLI in --batch mode and maps words back onto clip handles. None of
// that applies to a single file handed over by transcript.open(fileURL:), and
// reusing it would mean threading a synthetic clip through several hundred
// lines of timeline-specific code. Single-file mode is one CLI invocation.
- (void)transcribeFileWithParakeet:(NSURL *)audioURL timelineStart:(double)timelineStart generation:(NSUInteger)generation {
    NSString *binaryPath = [self parakeetTranscriberPath];
    if (!binaryPath) {
        [self setErrorState:@"Parakeet transcriber not installed.\n\n"
                            "Build and install it from your SpliceKit checkout:\n"
                            "    make install"];
        SpliceKit_log(@"[Transcript] ERROR: parakeet-transcriber not found for single-file transcription");
        return;
    }

    SpliceKit_log(@"[Transcript] Parakeet single file: %@", audioURL.path);
    SpliceKitTranscriptDiag_logBinaryInfo(binaryPath);

    NSMutableArray *args = [NSMutableArray arrayWithObjects:audioURL.path, @"--progress", nil];
    if (self.speakerDetectionEnabled) [args addObject:@"--speakers"];
    [args addObject:@"--model"];
    [args addObject:self.parakeetModelVersion ?: @"v3"];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = binaryPath;
    task.arguments = args;
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    // Drain both pipes on background handlers. A model download writes a lot of
    // progress to stderr, and a full pipe buffer would deadlock waitUntilExit.
    __block NSMutableData *outData = [NSMutableData data];
    __block NSMutableData *errData = [NSMutableData data];
    outPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (d.length) { @synchronized (outData) { [outData appendData:d]; } }
    };
    errPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (!d.length) return;
        @synchronized (errData) { [errData appendData:d]; }
        NSString *chunk = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        for (NSString *line in [chunk componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"PROGRESS:"]) continue;
            NSArray *parts = [line componentsSeparatedByString:@":"];
            if (parts.count < 3) continue;
            double fraction = [parts[1] doubleValue];
            NSString *message = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)]
                                    componentsJoinedByString:@":"];
            self.progressFraction = fraction;
            self.progressMessage = message;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressBar.indeterminate = NO;
                self.progressBar.doubleValue = fraction * 100.0;
                [self updateStatusUI:message];
            });
        }
    };

    @try {
        [task launch];
        self.activeHelperTask = task;
        [task waitUntilExit];
    } @catch (NSException *e) {
        [self setErrorState:[NSString stringWithFormat:@"Could not run parakeet-transcriber: %@", e.reason]];
        return;
    }
    outPipe.fileHandleForReading.readabilityHandler = nil;
    errPipe.fileHandleForReading.readabilityHandler = nil;
    if (generation != self.runGeneration) {
        SpliceKit_log(@"[Transcript] Dropping the result of a superseded file run (%@)", audioURL.lastPathComponent);
        return;
    }
    if (self.activeHelperTask == task) self.activeHelperTask = nil;

    NSData *stdoutData; NSData *stderrData;
    @synchronized (outData) { stdoutData = [outData copy]; }
    @synchronized (errData) { stderrData = [errData copy]; }
    NSString *stderrText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";

    if (task.terminationStatus != 0) {
        // Surface the tool's own ERROR: lines (not its TIP:/INFO: advice or the
        // FluidAudio "[Profiling]" chatter, which is what the last line often is).
        NSMutableArray *errors = [NSMutableArray array];
        NSString *lastLine = @"";
        for (NSString *line in [stderrText componentsSeparatedByString:@"\n"]) {
            if (line.length == 0 || [line hasPrefix:@"PROGRESS:"]) continue;
            if ([line hasPrefix:@"ERROR:"]) {
                NSString *body = [line substringFromIndex:6];
                if (![body hasPrefix:@"TIP:"] && ![body hasPrefix:@"INFO:"] && ![errors containsObject:body]) {
                    [errors addObject:body];
                }
            } else if (![line hasPrefix:@"[Profiling]"]) {
                lastLine = line;
            }
        }
        NSString *detail = errors.count ? [errors componentsJoinedByString:@" | "] : lastLine;
        if (task.terminationReason == NSTaskTerminationReasonUncaughtSignal) {
            detail = [NSString stringWithFormat:@"the transcriber was stopped by signal %d%@%@",
                      task.terminationStatus, detail.length ? @"; " : @"", detail];
        }
        [self setErrorState:[NSString stringWithFormat:
            @"Parakeet failed (exit %d)%@%@", task.terminationStatus,
            detail.length ? @": " : @"", detail]];
        SpliceKit_log(@"[Transcript] Parakeet single-file failed (%d): %@", task.terminationStatus, stderrText);
        return;
    }

    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:stdoutData options:0 error:&jsonError];
    if (![parsed isKindOfClass:[NSArray class]]) {
        [self setErrorState:[NSString stringWithFormat:
            @"Parakeet returned output that could not be parsed: %@",
            jsonError.localizedDescription ?: @"not a JSON array"]];
        return;
    }

    // The CLI emits {word, startTime, endTime, confidence} with file-relative
    // times. Shift by timelineStart so the panel's playhead sync lines up when
    // the caller placed the file somewhere other than the start of the timeline.
    NSMutableArray *words = [NSMutableArray array];
    for (NSDictionary *entry in (NSArray *)parsed) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = entry[@"word"] ?: entry[@"text"];
        if (![text isKindOfClass:[NSString class]] || text.length == 0) continue;

        double start = [entry[@"startTime"] doubleValue];
        double end = [entry[@"endTime"] doubleValue];
        if (end <= start) end = start + (1.0 / 30.0);

        SpliceKitTranscriptWord *word = [[SpliceKitTranscriptWord alloc] init];
        word.text = text;
        word.startTime = timelineStart + start;
        word.endTime = timelineStart + end;
        word.duration = end - start;
        word.confidence = entry[@"confidence"] ? [entry[@"confidence"] doubleValue] : 1.0;
        word.wordIndex = words.count;
        word.sourceMediaTime = start;
        word.sourceMediaOffset = 0;
        word.sourceMediaPath = audioURL.path;
        word.clipTimelineStart = timelineStart;
        NSString *speaker = entry[@"speaker"];
        if (speaker.length && speaker.length <= 3 && [speaker hasPrefix:@"S"]) {
            speaker = [NSString stringWithFormat:@"Speaker %@", [speaker substringFromIndex:1]];
        }
        word.speaker = speaker.length ? speaker : @"Unknown";
        [words addObject:word];
    }

    SpliceKit_log(@"[Transcript] Parakeet single file: %lu words", (unsigned long)words.count);

    if (words.count == 0) {
        [self setErrorState:@"Parakeet found no speech in that file."];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self.mutableWords) {
            [self.mutableWords removeAllObjects];
            [self.mutableWords addObjectsFromArray:words];
        }
        [self.mutableSilences removeAllObjects];
        [self detectSilences];
        [self assignSpeakers];

        self.completedTranscriptions = 1;
        self.status = SpliceKitTranscriptStatusReady;
        self.errorMessage = nil;
        [self rebuildTextView];
        [self startPlayheadTimer];
        self.deleteSilencesButton.enabled = (self.mutableSilences.count > 0);
        self.refreshButton.enabled = YES;
        self.spinner.hidden = YES;
        [self.spinner stopAnimation:nil];
        self.progressBar.hidden = YES;
        [self updateStatusUI:[NSString stringWithFormat:@"%lu words, %lu pauses",
            (unsigned long)self.mutableWords.count, (unsigned long)self.mutableSilences.count]];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SpliceKitTranscriptDidComplete" object:self];
    });
}

@end
