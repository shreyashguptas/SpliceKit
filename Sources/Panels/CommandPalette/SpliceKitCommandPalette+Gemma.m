//
//  SpliceKitCommandPalette+Gemma.m
//  Gemma 4 engine: starting and talking to the local MLX server, the tool schema,
//  and mapping tool calls onto bridge methods.
//

#import "SpliceKitCommandPalette+Private.h"

@implementation SpliceKitCommandPalette (Gemma)

#pragma mark - Gemma 4 (MLX) AI Engine
//
// Multi-turn agentic loop using Gemma 4 via Apple's MLX framework.
// The mlx-lm server exposes an OpenAI-compatible HTTP API at localhost:8080.
// Each turn: send messages + tool schema -> parse tool_calls -> execute via
// SpliceKit_handleRequest -> append results -> repeat until text response.
//

- (BOOL)isMLXServerAvailable {
    NSURL *url = [NSURL URLWithString:@"http://localhost:8080/v1/models"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 3.0;
    req.HTTPMethod = @"GET";

    __block BOOL available = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (!err && [(NSHTTPURLResponse *)resp statusCode] == 200) {
                available = YES;
            }
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
    return available;
}

// Find a working python3 path (checks brew, pyenv, conda, system, common locations)
- (NSString *)findPython3Path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();

    // Check well-known locations first (fast, no subprocess)
    NSArray *candidates = @[
        @"/opt/homebrew/bin/python3",                                              // Apple Silicon brew
        @"/usr/local/bin/python3",                                                 // Intel brew
        [home stringByAppendingPathComponent:@".pyenv/shims/python3"],             // pyenv
        [home stringByAppendingPathComponent:@"miniforge3/bin/python3"],           // miniforge / conda
        [home stringByAppendingPathComponent:@"miniconda3/bin/python3"],           // miniconda
        [home stringByAppendingPathComponent:@"anaconda3/bin/python3"],            // anaconda
        @"/usr/bin/python3",                                                       // Xcode CLT / system
    ];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) return path;
    }

    // Fallback: shell out to find python3 on the user's PATH
    // Use login shell so .zprofile / .bash_profile PATH additions are picked up
    NSString *shell = [NSProcessInfo processInfo].environment[@"SHELL"] ?: @"/bin/zsh";
    int whichStatus = -1;
    NSData *data = nil;
    NSError *whichError = nil;
    SpliceKitProcessOutcome outcome = SpliceKit_runProcess(shell, @[@"-l", @"-c", @"which python3"], nil,
        SpliceKitProcessOptionsNone, 0, &whichStatus, &data, NULL, &whichError);
    if (outcome != SpliceKitProcessExited) {
        SpliceKit_log(@"[Gemma] Shell which python3 failed: %@", whichError.localizedDescription);
    } else if (whichStatus == 0) {
        NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        path = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (path.length > 0 && [fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

// Check if mlx_lm is installed for the given python
- (BOOL)isMLXLMInstalledForPython:(NSString *)pythonPath {
    int status = -1;
    return SpliceKit_runProcess(pythonPath, @[@"-c", @"import mlx_lm"], nil, SpliceKitProcessOptionsNone, 0,
                                &status, NULL, NULL, NULL) == SpliceKitProcessExited && status == 0;
}

// Install mlx-lm via pip. Tries normal install first, then --user, then --break-system-packages.
- (BOOL)installMLXLMForPython:(NSString *)pythonPath {
    SpliceKit_log(@"[Gemma] Installing mlx-lm package via %@", pythonPath);

    // Try install strategies in order of preference
    NSArray *argSets = @[
        @[@"-m", @"pip", @"install", @"mlx-lm"],                                         // normal
        @[@"-m", @"pip", @"install", @"--user", @"mlx-lm"],                              // no write to site-packages
        @[@"-m", @"pip", @"install", @"--break-system-packages", @"mlx-lm"],             // PEP 668 (macOS 14+)
    ];

    for (NSArray *args in argSets) {
        SpliceKit_log(@"[Gemma] Trying: %@ %@", pythonPath, [args componentsJoinedByString:@" "]);
        // pip's output is drained while it runs (it easily outgrows a pipe, which blocked
        // the old wait-then-read forever).
        int status = -1;
        NSData *errData = nil;
        NSError *launchError = nil;
        if (SpliceKit_runProcess(pythonPath, args, nil, SpliceKitProcessOptionsNone, 0,
                                 &status, NULL, &errData, &launchError) != SpliceKitProcessExited) {
            SpliceKit_log(@"[Gemma] pip install exception: %@", launchError.localizedDescription);
            continue;
        }
        if (status == 0) {
            SpliceKit_log(@"[Gemma] pip install succeeded with: %@", [args componentsJoinedByString:@" "]);
            return YES;
        }
        NSString *errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        SpliceKit_log(@"[Gemma] pip install failed (status %d): %@", status, errStr);

        // If error is "externally managed" (PEP 668), continue to next strategy
        // If error is something else, try next strategy anyway
    }

    return NO;
}

// Check if port 8080 is already in use (by another MLX server or something else)
- (BOOL)isPortInUse:(int)port {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    int result = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    close(sock);
    return result == 0;
}

// Kill any existing mlx_lm.server process that we didn't start
- (void)killOrphanedMLXServer {
    SpliceKit_runProcess(@"/usr/bin/pkill", @[@"-f", @"mlx_lm.server"], nil, SpliceKitProcessOptionsNone, 0,
                         NULL, NULL, NULL, NULL);
    // Give it a moment to release the port
    [NSThread sleepForTimeInterval:1.0];
}

// Tail the last N bytes of a log file for user-facing error messages
static NSString *SpliceKit_tailLogFile(NSString *path, NSUInteger maxBytes) {
    NSString *log = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!log.length) return @"(empty log)";
    if (log.length <= maxBytes) return log;
    // Find a newline boundary near the cut point so we don't show a partial line
    NSRange search = [log rangeOfString:@"\n" options:0
                                  range:NSMakeRange(log.length - maxBytes, maxBytes)];
    NSUInteger start = (search.location != NSNotFound) ? search.location + 1 : log.length - maxBytes;
    return [log substringFromIndex:start];
}

// Auto-start MLX server, installing mlx-lm first if needed.
// Returns nil on success, or an error string on failure.
// Model is auto-downloaded by Hugging Face Hub on first server start.
- (NSString *)autoStartMLXServer {
    NSString *model = self.gemmaModel ?: @"unsloth/gemma-4-E4B-it-UD-MLX-4bit";

    // If we already started a server and it's still running, just wait for it
    if (self.mlxServerTask && self.mlxServerTask.isRunning) {
        SpliceKit_log(@"[Gemma] MLX server already launched (PID %d), waiting for it to become ready...", self.mlxServerTask.processIdentifier);
        for (int i = 0; i < 60; i++) {
            if ([self isMLXServerAvailable]) return nil;
            if (!self.mlxServerTask.isRunning) break;
            [NSThread sleepForTimeInterval:1.0];
            [self updateGemmaStatus:[NSString stringWithFormat:@"Waiting for server... (%ds)", i]];
        }
        // Fall through to full restart below
        SpliceKit_log(@"[Gemma] Previously launched server didn't become ready, restarting...");
    }

    // Find Python
    [self updateGemmaStatus:@"Finding Python..."];
    NSString *python = [self findPython3Path];
    if (!python) {
        return @"Python 3 not found. Install via: brew install python3";
    }
    SpliceKit_log(@"[Gemma] Using Python: %@", python);

    // Verify it's a real Python (not a stub that prompts Xcode CLT install)
    {
        int verifyStatus = -1;
        NSData *data = nil;
        NSError *verifyError = nil;
        if (SpliceKit_runProcess(python, @[@"--version"], nil, SpliceKitProcessOptionsNone, 0,
                                 &verifyStatus, &data, NULL, &verifyError) != SpliceKitProcessExited) {
            return [NSString stringWithFormat:@"Python 3 failed to run: %@", verifyError.localizedDescription];
        }
        if (verifyStatus != 0) {
            return @"Python 3 found but not functional. Install via: brew install python3";
        }
        NSString *version = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        SpliceKit_log(@"[Gemma] Python version: %@", [version stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    }

    // Check / install mlx-lm
    [self updateGemmaStatus:@"Checking mlx-lm..."];
    if (![self isMLXLMInstalledForPython:python]) {
        [self updateGemmaStatus:@"Installing mlx-lm (first-time setup)..."];
        SpliceKit_log(@"[Gemma] mlx-lm not installed, installing...");
        if (![self installMLXLMForPython:python]) {
            return @"Failed to install mlx-lm. Try manually: pip3 install mlx-lm";
        }
        SpliceKit_log(@"[Gemma] mlx-lm installed successfully");

        // Verify the install actually worked (pip can exit 0 but fail silently)
        if (![self isMLXLMInstalledForPython:python]) {
            SpliceKit_log(@"[Gemma] mlx-lm still not importable after pip install");
            return @"mlx-lm installed but import failed. Try: pip3 install --force-reinstall mlx-lm";
        }
    }

    // Check for port conflict before starting
    if ([self isPortInUse:8080]) {
        SpliceKit_log(@"[Gemma] Port 8080 is in use but server not responding to /v1/models");
        // Something else is on 8080, or a stale mlx server is half-alive. Kill orphans.
        [self updateGemmaStatus:@"Clearing stale server on port 8080..."];
        [self killOrphanedMLXServer];

        // Check again — if still occupied by a non-mlx process, fail clearly
        if ([self isPortInUse:8080] && ![self isMLXServerAvailable]) {
            return @"Port 8080 is in use by another process. Stop it or set a custom port.";
        }
        // If it's now responding, great — we're done
        if ([self isMLXServerAvailable]) return nil;
    }

    // Start server in background
    [self updateGemmaStatus:@"Starting MLX server (downloading model if first run)..."];
    SpliceKit_log(@"[Gemma] Starting MLX server with model: %@", model);

    NSString *logPath = @"/tmp/mlx_server.log";

    NSTask *server = [[NSTask alloc] init];
    server.executableURL = [NSURL fileURLWithPath:python];
    server.arguments = @[@"-m", @"mlx_lm.server", @"--model", model];

    // Redirect output to log file for diagnostics (truncate previous log)
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (logHandle) {
        [logHandle truncateFileAtOffset:0];
        server.standardOutput = logHandle;
        server.standardError = logHandle;
    }

    @try {
        [server launch];
    } @catch (NSException *e) {
        SpliceKit_log(@"[Gemma] Failed to launch MLX server: %@", e.reason);
        return [NSString stringWithFormat:@"Failed to start MLX server: %@", e.reason];
    }

    // Store reference for lifecycle management
    self.mlxServerTask = server;
    SpliceKit_log(@"[Gemma] MLX server process launched (PID %d), waiting for it to be ready...", server.processIdentifier);

    // Poll until server is ready
    // First run with model download: could be several minutes (model is ~2-3 GB)
    // Subsequent runs with cached model: typically 5-30 seconds
    int maxAttempts = 300; // 5 minutes total (300 x 1s) — generous for first-run download
    for (int i = 0; i < maxAttempts; i++) {
        if (self.gemmaCancelled) {
            [server terminate];
            self.mlxServerTask = nil;
            return @"Cancelled by user";
        }
        if (!server.isRunning) {
            NSString *tail = SpliceKit_tailLogFile(logPath, 800);
            SpliceKit_log(@"[Gemma] MLX server exited (status %d). Log tail:\n%@", server.terminationStatus, tail);

            // Provide actionable error based on common failure patterns
            if ([tail containsString:@"No module named"]) {
                return @"MLX server failed: missing Python module. Try: pip3 install mlx-lm";
            } else if ([tail containsString:@"Address already in use"]) {
                return @"Port 8080 already in use. Kill the existing process: pkill -f mlx_lm.server";
            } else if ([tail containsString:@"out of memory"] || [tail containsString:@"MemoryError"]) {
                return @"Not enough memory to load model. Close other apps and try again.";
            } else if ([tail rangeOfString:@"Model type .* not supported" options:NSRegularExpressionSearch].location != NSNotFound) {
                // The model is on disk but this mlx-lm cannot run its architecture (seen with
                // mlx-lm 0.29 on Python 3.9 and the gemma4 model): name both, and what unlocks it.
                NSRange r = [tail rangeOfString:@"Model type [^ ]+ not supported" options:NSRegularExpressionSearch];
                NSString *what = r.location != NSNotFound ? [tail substringWithRange:r] : @"model type not supported";
                NSString *mlxVersion = @"unknown";
                {
                    int st = -1; NSData *out = nil;
                    if (SpliceKit_runProcess(python, @[@"-c", @"import mlx_lm; print(mlx_lm.__version__)"], nil,
                                             SpliceKitProcessOptionsNone, 0, &st, &out, NULL, NULL) == SpliceKitProcessExited && st == 0) {
                        mlxVersion = [[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]
                                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    }
                }
                return [NSString stringWithFormat:
                    @"Local model unavailable: the installed mlx-lm (%@, for %@) cannot load '%@' (%@). "
                    @"The model files are present; what is missing is an mlx-lm new enough for this model. "
                    @"To enable it: install a current mlx-lm on a Python 3.10+ (e.g. brew install python@3.12, then "
                    @"python3.12 -m pip install -U mlx-lm) so SpliceKit finds that python first.",
                    mlxVersion, python, model, what];
            } else if ([tail containsString:@"FileNotFoundError"] || [tail containsString:@"does not appear to have"]) {
                return [NSString stringWithFormat:@"Model '%@' not found. Check the model ID.", model];
            }
            return [NSString stringWithFormat:@"MLX server exited unexpectedly. Log:\n%@", tail];
        }
        if ([self isMLXServerAvailable]) {
            SpliceKit_log(@"[Gemma] MLX server ready after %d seconds", i);
            [logHandle closeFile];
            return nil; // success
        }

        // Show progress with download context for first ~60s
        if (i <= 5) {
            [self updateGemmaStatus:@"Starting MLX server..."];
        } else if (i <= 30) {
            [self updateGemmaStatus:[NSString stringWithFormat:@"Loading model... (%ds)", i]];
        } else {
            // After 30s it's likely downloading — read log for progress hints
            NSString *tail = SpliceKit_tailLogFile(logPath, 200);
            if ([tail containsString:@"Fetching"] || [tail containsString:@"Downloading"] || [tail containsString:@"%"]) {
                [self updateGemmaStatus:[NSString stringWithFormat:@"Downloading model... (%ds)", i]];
            } else {
                [self updateGemmaStatus:[NSString stringWithFormat:@"Loading model... (%ds)", i]];
            }
        }
        [NSThread sleepForTimeInterval:1.0];
    }

    [logHandle closeFile];
    return @"MLX server started but didn't respond within 5 minutes. Check /tmp/mlx_server.log";
}

- (NSDictionary *)gemmaCallMLXOnce:(NSArray *)messages tools:(NSArray *)tools {
    NSURL *url = [NSURL URLWithString:@"http://localhost:8080/v1/chat/completions"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 120.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSMutableDictionary *body = [@{
        @"model": self.gemmaModel ?: @"unsloth/gemma-4-E4B-it-UD-MLX-4bit",
        @"messages": messages,
        @"stream": @NO,
        @"temperature": @(0.2),
        @"max_tokens": @(2048),
    } mutableCopy];
    if (tools.count > 0) body[@"tools"] = tools;

    NSError *jsonErr = nil;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr) return @{@"error": jsonErr.localizedDescription};

    NSUInteger bodySize = req.HTTPBody.length;
    SpliceKit_log(@"[Gemma] POST /v1/chat/completions (%lu bytes, %lu messages, %lu tools)",
                  (unsigned long)bodySize, (unsigned long)messages.count, (unsigned long)tools.count);

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) {
                result = @{@"error": err.localizedDescription, @"_connection_error": @YES};
            } else if ([(NSHTTPURLResponse *)resp statusCode] != 200) {
                NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
                result = @{@"error": [NSString stringWithFormat:@"HTTP %ld: %@",
                           (long)[(NSHTTPURLResponse *)resp statusCode], body]};
            } else {
                NSError *parseErr = nil;
                id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
                if (parseErr || ![parsed isKindOfClass:[NSDictionary class]]) {
                    result = @{@"error": @"Failed to parse MLX response"};
                } else {
                    result = parsed;
                }
            }
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 125 * NSEC_PER_SEC));
    return result ?: @{@"error": @"MLX request timed out"};
}

- (NSDictionary *)gemmaCallMLX:(NSArray *)messages tools:(NSArray *)tools {
    NSDate *callStart = [NSDate date];
    NSDictionary *result = [self gemmaCallMLXOnce:messages tools:tools];
    NSTimeInterval elapsed = -[callStart timeIntervalSinceNow];

    // Log token usage if available
    NSDictionary *usage = result[@"usage"];
    if (usage) {
        SpliceKit_log(@"[Gemma] LLM response: %.1fs | prompt=%@ completion=%@ total=%@ tokens",
                      elapsed, usage[@"prompt_tokens"], usage[@"completion_tokens"], usage[@"total_tokens"]);
    }

    // Retry on connection error (mlx-lm tool parser crash drops the connection)
    if (result[@"_connection_error"]) {
        SpliceKit_log(@"[Gemma] Connection lost (likely mlx-lm tool parser crash) — waiting 2s for recovery...");
        [NSThread sleepForTimeInterval:2.0];

        // Check if server recovered on its own
        if (![self isMLXServerAvailable]) {
            // Server died — try auto-restart
            SpliceKit_log(@"[Gemma] MLX server did not recover, attempting auto-restart...");
            [self updateGemmaStatus:@"MLX server crashed, restarting..."];
            self.mlxServerTask = nil; // clear stale reference
            NSString *startErr = [self autoStartMLXServer];
            if (startErr) {
                SpliceKit_log(@"[Gemma] Auto-restart failed: %@", startErr);
                return @{@"error": [NSString stringWithFormat:@"MLX server crashed and restart failed: %@", startErr]};
            }
            SpliceKit_log(@"[Gemma] MLX server restarted successfully");
        }

        callStart = [NSDate date];
        result = [self gemmaCallMLXOnce:messages tools:tools];
        elapsed = -[callStart timeIntervalSinceNow];

        if (result[@"_connection_error"]) {
            SpliceKit_log(@"[Gemma] Retry also failed with connection error");
            return @{@"error": @"MLX server keeps crashing. Check /tmp/mlx_server.log for errors."};
        }

        usage = result[@"usage"];
        if (usage) {
            SpliceKit_log(@"[Gemma] LLM retry response: %.1fs | prompt=%@ completion=%@ total=%@ tokens",
                          elapsed, usage[@"prompt_tokens"], usage[@"completion_tokens"], usage[@"total_tokens"]);
        }
    }

    if (result[@"error"]) {
        SpliceKit_log(@"[Gemma] LLM error after %.1fs: %@", elapsed, result[@"error"]);
    }

    return result;
}

- (NSArray *)buildGemmaToolSchema {
    if (self.gemmaToolSchema) return self.gemmaToolSchema;

    // Each tool maps to a bridge method via the lookup in gemmaExecuteTool:arguments:
    NSMutableArray *tools = [NSMutableArray array];

    void (^addTool)(NSString *, NSString *, NSDictionary *) =
        ^(NSString *name, NSString *desc, NSDictionary *params) {
        [tools addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": name,
                @"description": desc,
                @"parameters": params ?: @{@"type": @"object", @"properties": @{}}
            }
        }];
    };

    // Timeline actions
    addTool(@"timeline_action",
        @"Execute a timeline editing action. Actions:\n"
        @"EDITING: blade, bladeAll, delete, cut, copy, paste, undo, redo, joinClips, replaceWithGap, pasteAsConnected, insertGap, insertPlaceholder\n"
        @"SELECTION: selectAll, deselectAll, selectClipAtPlayhead, selectToPlayhead\n"
        @"TRIM: trimToPlayhead, extendEditToPlayhead, trimStart, trimEnd, nudgeLeft, nudgeRight, nudgeUp, nudgeDown\n"
        @"RANGE: setRangeStart, setRangeEnd, clearRange, setClipRange\n"
        @"MARKERS: addMarker, addTodoMarker, addChapterMarker, deleteMarker, deleteMarkersInSelection, nextMarker, previousMarker\n"
        @"NAVIGATION: nextEdit, previousEdit, addTransition\n"
        @"COLOR: addColorBoard, addColorWheels, addColorCurves, addHueSaturation, addEnhanceLightAndColor, balanceColor, matchColor, addMagneticMask, addColorAdjustment, resetColorBoard, smartConform\n"
        @"AUDIO: adjustVolumeUp, adjustVolumeDown, volumeMute, detachAudio, addChannelEQ, enhanceAudio, matchAudio, expandAudio, expandAudioComponents, addAudioFadeIn, addAudioFadeOut\n"
        @"TITLES: addBasicTitle, addBasicLowerThird\n"
        @"SPEED: retimeNormal, retimeFast2x, retimeFast4x, retimeFast8x, retimeFast20x, retimeSlow50, retimeSlow25, retimeSlow10, retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed, retimeSpeedRampToZero, retimeSpeedRampFromZero\n"
        @"CLIPS: solo, disable, createCompoundClip, breakApartClipItems, addAdjustmentClip, liftFromPrimaryStoryline, createStoryline, overwriteToPrimaryStoryline, collapseToConnectedStoryline, renameClip, openClip, changeDuration, synchronizeClips, referenceNewParentClip\n"
        @"EFFECTS: removeEffects, pasteEffects, pasteAttributes, copyAttributes, removeAttributes, autoReframe, showTransformControls, showCropControls\n"
        @"CAPTIONS: addCaption, splitCaption, resolveOverlaps, importCaptions\n"
        @"MULTICAM: createMulticamClip, switchAngle01, switchAngle02, switchAngle03, switchAngle04, cutAndSwitchAngle01, cutAndSwitchAngle02\n"
        @"RATING: favorite, reject, unrate\n"
        @"KEYFRAMES: addKeyframe, deleteKeyframes, removeAllKeyframesFromClip, nextKeyframe, previousKeyframe\n"
        @"VIEW: zoomToFit, zoomIn, zoomOut, verticalZoomToFit, toggleSnapping, toggleSkimming, toggleClipSkimming, toggleInspector, toggleTimeline, toggleTimelineIndex, showAudioLanes, enterFullScreen, increaseClipHeight, decreaseClipHeight, showVideoAnimation, showAudioAnimation, showPrecisionEditor\n"
        @"PROJECT: duplicateProject, snapshotProject, projectProperties, newProject, newEvent, importMedia, find, findAndReplaceTitle, revealInFinder, renderAll, exportXML, analyzeAndFix, recordVoiceover, backgroundTasks, deleteGeneratedFiles, deleteRenderFiles, showPreferences\n"
        @"AUDITION: createAudition, finalizeAudition, nextAuditionPick, previousAuditionPick\n"
        @"STORYLINE: createStoryline, liftFromPrimaryStoryline, overwriteToPrimaryStoryline, collapseToConnectedStoryline",
        @{@"type": @"object",
          @"properties": @{
              @"action": @{@"type": @"string", @"description": @"Action name"}
          },
          @"required": @[@"action"]});

    // Playback actions
    addTool(@"playback_action",
        @"Execute a playback action: playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10, playAroundCurrent",
        @{@"type": @"object",
          @"properties": @{
              @"action": @{@"type": @"string", @"description": @"Playback action name"}
          },
          @"required": @[@"action"]});

    // Seek
    addTool(@"seek_to_time",
        @"Move playhead to exact time in seconds. Instant — no playback. Use for all time-based positioning.",
        @{@"type": @"object",
          @"properties": @{
              @"seconds": @{@"type": @"number", @"description": @"Time in seconds"}
          },
          @"required": @[@"seconds"]});

    // Timeline state
    addTool(@"get_timeline_clips",
        @"Get all clips on the timeline with positions, durations, and names. Call this first to understand timeline contents.",
        @{@"type": @"object",
          @"properties": @{
              @"limit": @{@"type": @"integer", @"description": @"Max clips to return (default 50)"}
          }});

    // Playhead position
    addTool(@"get_playhead_position",
        @"Get current playhead time, total duration, frame rate, and whether playback is active.",
        @{@"type": @"object", @"properties": @{}});

    // Selected clips
    addTool(@"get_selected_clips",
        @"Get details of currently selected clips in the timeline.",
        @{@"type": @"object", @"properties": @{}});

    // Transitions
    addTool(@"apply_transition",
        @"Apply a transition at the current edit point. Navigate to an edit point first with timeline_action(nextEdit).",
        @{@"type": @"object",
          @"properties": @{
              @"name": @{@"type": @"string", @"description": @"Transition name (e.g. Cross Dissolve, Flow, Wipe)"},
              @"effectID": @{@"type": @"string", @"description": @"Effect ID (alternative to name)"},
              @"freeze_extend": @{@"type": @"boolean", @"description": @"Auto freeze-extend if not enough media handles"}
          }});

    addTool(@"list_transitions",
        @"List available transitions, optionally filtered by name or category.",
        @{@"type": @"object",
          @"properties": @{
              @"filter": @{@"type": @"string", @"description": @"Filter by name or category"}
          }});

    // Effects
    addTool(@"apply_effect",
        @"Apply a video/audio effect to the selected clip. Common effects: "
        @"Gaussian Blur, Sharpen, Keyer, Luma Keyer, Vignette, Noise Reduction, Stabilization, "
        @"Black & White, Sepia, Aged Film, Film Grain, Bloom, Glow, Pixellate, Posterize, "
        @"Invert, Flipped, Tilt-Shift, Drop Shadow, Letterbox, Lens Flare, Underwater, Rolling Shutter. "
        @"Use list_effects() to discover all available effects.",
        @{@"type": @"object",
          @"properties": @{
              @"name": @{@"type": @"string", @"description": @"Effect name (e.g. Gaussian Blur, Keyer, Vignette)"},
              @"effectID": @{@"type": @"string", @"description": @"Effect ID (alternative to name)"}
          }});

    addTool(@"list_effects",
        @"List available video/audio effects, optionally filtered.",
        @{@"type": @"object",
          @"properties": @{
              @"filter": @{@"type": @"string", @"description": @"Filter by name or category"}
          }});

    addTool(@"get_clip_effects",
        @"Get effects applied to the currently selected clip.",
        @{@"type": @"object", @"properties": @{}});

    // Inspector
    addTool(@"get_inspector_properties",
        @"Read properties of the selected clip (transform, compositing, text, audio, etc).",
        @{@"type": @"object",
          @"properties": @{
              @"section": @{@"type": @"string", @"description": @"Section: transform, compositing, text, audio, or omit for all"}
          }});

    addTool(@"set_inspector_property",
        @"Set a property on the selected clip (opacity, volume, positionX, positionY, rotation, scaleX, scaleY, etc).",
        @{@"type": @"object",
          @"properties": @{
              @"property": @{@"type": @"string", @"description": @"Property name"},
              @"value": @{@"type": @"number", @"description": @"New value"}
          },
          @"required": @[@"property", @"value"]});

    // Menu
    addTool(@"execute_menu_command",
        @"Execute any FCP menu command by menu path (e.g. ['File','New','Project']).",
        @{@"type": @"object",
          @"properties": @{
              @"menu_path": @{@"type": @"array", @"items": @{@"type": @"string"},
                              @"description": @"Menu path from top to bottom"}
          },
          @"required": @[@"menu_path"]});

    // Project
    addTool(@"open_project",
        @"Open a project by name.",
        @{@"type": @"object",
          @"properties": @{
              @"name": @{@"type": @"string", @"description": @"Project name"},
              @"event": @{@"type": @"string", @"description": @"Optional event name to filter by"}
          },
          @"required": @[@"name"]});

    // Transcript
    addTool(@"open_transcript",
        @"Open the transcript panel and transcribe timeline clips.",
        @{@"type": @"object", @"properties": @{}});

    addTool(@"get_transcript",
        @"Get transcribed words with timestamps, speakers, and silences.",
        @{@"type": @"object", @"properties": @{}});

    addTool(@"delete_transcript_silences",
        @"Remove silence gaps from the timeline.",
        @{@"type": @"object",
          @"properties": @{
              @"min_duration": @{@"type": @"number", @"description": @"Only remove silences longer than this (seconds)"}
          }});

    // Captions
    addTool(@"generate_captions",
        @"Generate social media captions on the timeline.",
        @{@"type": @"object",
          @"properties": @{
              @"style": @{@"type": @"string", @"description": @"Style preset: bold_pop, neon_glow, clean_minimal, etc"}
          }});

    // FCPXML
    addTool(@"generate_fcpxml",
        @"Generate FCPXML for import (create projects, gaps, titles, markers).",
        @{@"type": @"object",
          @"properties": @{
              @"project_name": @{@"type": @"string", @"description": @"Project name"},
              @"frame_rate": @{@"type": @"string", @"description": @"Frame rate (24, 25, 30, etc)"},
              @"items": @{@"type": @"string", @"description": @"JSON array of items"}
          },
          @"required": @[@"project_name"]});

    addTool(@"import_fcpxml",
        @"Import FCPXML into FCP.",
        @{@"type": @"object",
          @"properties": @{
              @"xml": @{@"type": @"string", @"description": @"FCPXML content string"},
              @"internal": @{@"type": @"boolean", @"description": @"Use internal import (no dialog)"}
          },
          @"required": @[@"xml"]});

    addTool(@"import_url",
        @"Download a remote media URL, import it into Final Cut Pro, and optionally place it in the timeline.",
        @{@"type": @"object",
          @"properties": @{
              @"url": @{@"type": @"string", @"description": @"Direct media URL or a supported provider URL"},
              @"mode": @{@"type": @"string", @"description": @"import_only, insert_at_playhead, or append_to_timeline"},
              @"title": @{@"type": @"string", @"description": @"Optional clip title override"},
              @"target_event": @{@"type": @"string", @"description": @"Optional event name override"}
          },
          @"required": @[@"url"]});

    addTool(@"export_xml",
        @"Export current project as FCPXML to a file path.",
        @{@"type": @"object",
          @"properties": @{
              @"path": @{@"type": @"string", @"description": @"Output path (default /tmp/splicekit_export.fcpxml)"}
          }});

    // Scene detection
    addTool(@"detect_scene_changes",
        @"Detect scene changes in the timeline. Can add markers or blade at cuts.",
        @{@"type": @"object",
          @"properties": @{
              @"threshold": @{@"type": @"number", @"description": @"Sensitivity (0.0-1.0, lower=more sensitive)"},
              @"action": @{@"type": @"string", @"description": @"'markers' to add markers, 'blade' to cut at changes"}
          }});

    // Panels/View
    addTool(@"toggle_panel",
        @"Show or hide a panel: videoScopes, inspector, effectsBrowser, timeline, timelineIndex.",
        @{@"type": @"object",
          @"properties": @{
              @"panel": @{@"type": @"string", @"description": @"Panel name"}
          },
          @"required": @[@"panel"]});

    // Viewer
    addTool(@"capture_viewer",
        @"Take a screenshot of the FCP viewer.",
        @{@"type": @"object",
          @"properties": @{
              @"path": @{@"type": @"string", @"description": @"Output path (default /tmp/splicekit_viewer.png)"}
          }});

    addTool(@"capture_timeline",
        @"Take a screenshot of the FCP timeline.",
        @{@"type": @"object",
          @"properties": @{
              @"path": @{@"type": @"string", @"description": @"Output path (default /tmp/splicekit_timeline.png)"}
          }});

    addTool(@"background_render_status",
        @"Get live background-render state including low-overhead mode, queue concurrency, and relevant defaults.",
        @{@"type": @"object", @"properties": @{}});

    addTool(@"background_render_control",
        @"Temporarily reduce background-render impact while editing. "
        @"Use action='hold_off' to delay background-render auto-start, or action='low_overhead' to enter FCP's internal low-overhead mode.",
        @{@"type": @"object",
          @"properties": @{
              @"action": @{@"type": @"string", @"description": @"hold_off or low_overhead"},
              @"seconds": @{@"type": @"number", @"description": @"Duration in seconds"}
          },
          @"required": @[@"action", @"seconds"]});

    // Batch actions
    addTool(@"batch_timeline_actions",
        @"Execute multiple timeline/playback actions in sequence. Each action: {type:'timeline'|'playback'|'seek', action:'name', repeat:N, seconds:N}.",
        @{@"type": @"object",
          @"properties": @{
              @"actions": @{@"type": @"string", @"description": @"JSON array of action objects"}
          },
          @"required": @[@"actions"]});

    // Batch blade — the fastest way to make many cuts
    addTool(@"blade_at_times",
        @"Blade (cut) the timeline at multiple times in one call. For repetitive cuts (e.g. every 3s), compute all times and pass them as an array. Example: [3.0, 6.0, 9.0, 12.0]",
        @{@"type": @"object",
          @"properties": @{
              @"times": @{@"type": @"string", @"description": @"JSON array of times in seconds, e.g. [3.0, 6.0, 9.0]"}
          },
          @"required": @[@"times"]});

    // Lane selection
    addTool(@"select_clip_in_lane",
        @"Select a clip in a specific lane (connected clips). Lane 0 = primary, 1 = above, -1 = below.",
        @{@"type": @"object",
          @"properties": @{
              @"lane": @{@"type": @"integer", @"description": @"Lane number (0=primary, positive=above, negative=below)"}
          },
          @"required": @[@"lane"]});

    // Roles
    addTool(@"assign_role",
        @"Assign a role to the selected clip.",
        @{@"type": @"object",
          @"properties": @{
              @"type": @{@"type": @"string", @"description": @"Role type: audio or video"},
              @"role": @{@"type": @"string", @"description": @"Role name (e.g. Dialogue, Music, Titles)"}
          },
          @"required": @[@"type", @"role"]});

    // Share/Export
    addTool(@"share_project",
        @"Export the project using a share destination.",
        @{@"type": @"object",
          @"properties": @{
              @"destination": @{@"type": @"string", @"description": @"Share destination name (default: default destination)"}
          }});

    // Timeline range
    addTool(@"set_timeline_range",
        @"Set the in/out range on the timeline.",
        @{@"type": @"object",
          @"properties": @{
              @"start_seconds": @{@"type": @"number", @"description": @"Range start in seconds"},
              @"end_seconds": @{@"type": @"number", @"description": @"Range end in seconds"}
          },
          @"required": @[@"start_seconds", @"end_seconds"]});

    // Markers at times
    addTool(@"add_markers_at_times",
        @"Add markers at specific times (seconds). More efficient than seeking + adding one at a time.",
        @{@"type": @"object",
          @"properties": @{
              @"times": @{@"type": @"array", @"items": @{@"type": @"number"},
                          @"description": @"Array of times in seconds"},
              @"name": @{@"type": @"string", @"description": @"Marker name"},
              @"kind": @{@"type": @"string", @"description": @"Marker kind: standard, todo, chapter"}
          },
          @"required": @[@"times"]});

    // Analyze timeline
    addTool(@"analyze_timeline",
        @"Analyze timeline for pacing, flash frames, clip statistics.",
        @{@"type": @"object", @"properties": @{}});

    self.gemmaToolSchema = tools;
    return tools;
}

// Static mapping from Gemma tool names to bridge methods
static NSDictionary *SpliceKit_gemmaToolBridgeMap(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"timeline_action":          @"timeline.action",
            @"playback_action":          @"playback.action",
            @"seek_to_time":             @"playback.seekToTime",
            @"get_timeline_clips":       @"timeline.getDetailedState",
            @"get_playhead_position":    @"playback.getPosition",
            @"get_selected_clips":       @"timeline.getSelectedClips",
            @"apply_transition":         @"transitions.apply",
            @"list_transitions":         @"transitions.list",
            @"apply_effect":             @"effects.apply",
            @"list_effects":             @"effects.list",
            @"get_clip_effects":         @"effects.getClipEffects",
            @"get_inspector_properties": @"inspector.get",
            @"set_inspector_property":   @"inspector.set",
            @"execute_menu_command":      @"menu.execute",
            @"open_project":             @"project.open",
            @"open_transcript":          @"transcript.open",
            @"get_transcript":           @"transcript.get",
            @"delete_transcript_silences": @"transcript.deleteSilences",
            @"generate_captions":        @"captions.generate",
            @"generate_fcpxml":          @"fcpxml.generate",
            @"import_fcpxml":            @"fcpxml.import",
            @"import_url":               @"urlImport.import",
            @"export_xml":               @"fcpxml.export",
            @"detect_scene_changes":     @"scene.detect",
            @"toggle_panel":             @"view.toggle",
            @"capture_viewer":           @"viewer.capture",
            @"capture_timeline":         @"timeline.capture",
            @"background_render_status": @"backgroundRender.status",
            @"background_render_control": @"backgroundRender.control",
            @"batch_timeline_actions":   @"timeline.batchActions",
            @"blade_at_times":           @"timeline.bladeAtTimes",
            @"select_clip_in_lane":      @"timeline.selectClipInLane",
            @"assign_role":              @"roles.assign",
            @"share_project":            @"share.export",
            @"set_timeline_range":       @"timeline.setRange",
            @"add_markers_at_times":     @"timeline.addMarkers",
            @"analyze_timeline":         @"timeline.analyze",
        };
    });
    return map;
}

// Map Gemma tool arguments to bridge params (some need key remapping)
static NSDictionary *SpliceKit_gemmaMapArgs(NSString *toolName, NSDictionary *args) {
    if (!args) return @{};
    NSMutableDictionary *mapped = [args mutableCopy];

    // Remap keys where the tool schema uses different names than the bridge
    if ([toolName isEqualToString:@"execute_menu_command"]) {
        if (mapped[@"menu_path"]) {
            mapped[@"menuPath"] = mapped[@"menu_path"];
            [mapped removeObjectForKey:@"menu_path"];
        }
    } else if ([toolName isEqualToString:@"set_inspector_property"]) {
        // Bridge expects: property -> property, value -> value (same names)
    } else if ([toolName isEqualToString:@"get_inspector_properties"]) {
        // Bridge expects: section -> section (same)
    } else if ([toolName isEqualToString:@"toggle_panel"]) {
        // Bridge expects: panel -> panel (same)
    } else if ([toolName isEqualToString:@"seek_to_time"]) {
        // Bridge expects: seconds -> seconds (same)
    } else if ([toolName isEqualToString:@"delete_transcript_silences"]) {
        if (mapped[@"min_duration"]) {
            mapped[@"minDuration"] = mapped[@"min_duration"];
            [mapped removeObjectForKey:@"min_duration"];
        }
    } else if ([toolName isEqualToString:@"set_timeline_range"]) {
        if (mapped[@"start_seconds"]) {
            mapped[@"startSeconds"] = mapped[@"start_seconds"];
            [mapped removeObjectForKey:@"start_seconds"];
        }
        if (mapped[@"end_seconds"]) {
            mapped[@"endSeconds"] = mapped[@"end_seconds"];
            [mapped removeObjectForKey:@"end_seconds"];
        }
    } else if ([toolName isEqualToString:@"add_markers_at_times"]) {
        // Bridge expects same keys
    } else if ([toolName isEqualToString:@"generate_fcpxml"]) {
        if (mapped[@"project_name"]) {
            mapped[@"projectName"] = mapped[@"project_name"];
            [mapped removeObjectForKey:@"project_name"];
        }
        if (mapped[@"frame_rate"]) {
            mapped[@"frameRate"] = mapped[@"frame_rate"];
            [mapped removeObjectForKey:@"frame_rate"];
        }
    } else if ([toolName isEqualToString:@"batch_timeline_actions"]) {
        // Parse actions JSON string to array if needed
        if ([mapped[@"actions"] isKindOfClass:[NSString class]]) {
            NSData *d = [(NSString *)mapped[@"actions"] dataUsingEncoding:NSUTF8StringEncoding];
            NSArray *arr = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            if (arr) mapped[@"actions"] = arr;
        }
    } else if ([toolName isEqualToString:@"blade_at_times"]) {
        // Parse times JSON string to array if needed
        if ([mapped[@"times"] isKindOfClass:[NSString class]]) {
            NSData *d = [(NSString *)mapped[@"times"] dataUsingEncoding:NSUTF8StringEncoding];
            NSArray *arr = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            if (arr) mapped[@"times"] = arr;
        }
    } else if ([toolName isEqualToString:@"select_clip_in_lane"]) {
        // Bridge expects: lane -> lane (same)
    } else if ([toolName isEqualToString:@"assign_role"]) {
        // Bridge expects: type -> type, role -> role (same)
    } else if ([toolName isEqualToString:@"share_project"]) {
        // Bridge expects: destination -> destination (same)
    } else if ([toolName isEqualToString:@"apply_transition"]) {
        if (mapped[@"freeze_extend"]) {
            mapped[@"freezeExtend"] = mapped[@"freeze_extend"];
            [mapped removeObjectForKey:@"freeze_extend"];
        }
    }
    return mapped;
}

- (NSDictionary *)gemmaExecuteTool:(NSString *)toolName arguments:(NSDictionary *)args {
    NSDictionary *bridgeMap = SpliceKit_gemmaToolBridgeMap();
    NSString *bridgeMethod = bridgeMap[toolName];
    if (!bridgeMethod) {
        return @{@"error": [NSString stringWithFormat:@"Unknown tool: %@", toolName]};
    }

    NSDictionary *mappedArgs = SpliceKit_gemmaMapArgs(toolName, args);
    NSDictionary *request = @{@"method": bridgeMethod, @"params": mappedArgs};
    NSDictionary *result = SpliceKit_handleRequest(request);
    return result ?: @{@"error": @"No response from bridge"};
}

- (void)updateGemmaStatus:(NSString *)status {
    self.gemmaCurrentTask = status;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.aiLoading && self.aiEngine == SpliceKitAIEngineGemma4) {
            self.statusLabel.stringValue = status;
            // Also refresh the AI loading row in the table view
            if (self.tableView.numberOfRows > 0) {
                [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:0]
                                         columnIndexes:[NSIndexSet indexSetWithIndex:0]];
            }
        }
    });
}

NSString * const kGemmaSystemPrompt =
    @"You are a Final Cut Pro editing assistant with direct programmatic control via tools.\n"
    @"Execute edits by calling tools. Never describe steps — just do them.\n\n"
    @"Rules:\n"
    @"1. Call get_timeline_clips first if you need to know what's on the timeline\n"
    @"2. Use seek_to_time(seconds) for playhead positioning — it's instant\n"
    @"3. Most edits require selecting a clip first: timeline_action(\"selectClipAtPlayhead\")\n"
    @"4. For connected clips (titles, B-roll), use select_clip_in_lane(lane=1 above, -1 below)\n"
    @"5. If a tool returns an error, try an alternative approach\n"
    @"6. When done, respond with a brief summary of what you changed\n\n"
    @"CRITICAL — batch operations:\n"
    @"For repetitive tasks (cutting at intervals, adding many markers, etc.), ALWAYS use batch tools:\n"
    @"- blade_at_times([3.0, 6.0, 9.0, ...]) — cut at many times in ONE call\n"
    @"- add_markers_at_times([...]) — add many markers in ONE call\n"
    @"- batch_timeline_actions([...]) — chain many actions in ONE call\n"
    @"Compute all needed times/actions upfront, then execute in a single tool call.\n"
    @"NEVER loop step-by-step (seek+blade, seek+blade...) — use the batch tool instead.\n\n"
    @"CAPABILITIES:\n"
    @"- Color: addColorBoard/Wheels/Curves, addHueSaturation, balanceColor, matchColor, addMagneticMask\n"
    @"- Speed: retimeSlow50/25/10, retimeFast2x/4x/8x/20x, retimeReverse, freezeFrame, retimeHold, retimeBladeSpeed, retimeSpeedRampToZero/FromZero\n"
    @"- Audio: adjustVolumeUp/Down, volumeMute, addAudioFadeIn/Out, detachAudio, addChannelEQ, enhanceAudio, matchAudio\n"
    @"- Captions: addCaption, splitCaption, resolveOverlaps, generate_captions (social media style)\n"
    @"- Multicam: createMulticamClip, switchAngle01-04, cutAndSwitchAngle01-02\n"
    @"- Compound clips: createCompoundClip, breakApartClipItems, openClip (enter), backToParent (exit)\n"
    @"- Storylines: createStoryline, liftFromPrimaryStoryline, overwriteToPrimaryStoryline\n"
    @"- Transitions: apply_transition (Cross Dissolve, Flow, Wipe, etc.) with freeze_extend option\n"
    @"- Effects: apply_effect (Gaussian Blur, Keyer, Vignette, etc.), removeEffects, pasteEffects/Attributes\n"
    @"- Inspector: get/set_inspector_property (opacity, volume, positionX/Y, rotation, scaleX/Y)\n"
    @"- Transcript: open_transcript, get_transcript, delete_transcript_silences (remove pauses)\n"
    @"- Scene detection: detect_scene_changes (add markers or blade at cuts)\n"
    @"- FCPXML: generate_fcpxml, import_fcpxml, export_xml\n"
    @"- View: toggle_panel, capture_viewer/timeline for screenshots\n"
    @"- Trim: trimToPlayhead, trimStart, trimEnd, nudgeLeft/Right/Up/Down\n"
    @"- Auditions: createAudition, finalizeAudition, nextAuditionPick, previousAuditionPick\n"
    @"- Rating: favorite, reject, unrate\n"
    @"- Project: newProject, newEvent, duplicateProject, importMedia, analyzeAndFix, share_project";

@end
