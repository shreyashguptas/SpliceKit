//
//  SpliceKitCommandPalette+AppleAI.m
//  Apple Intelligence (FoundationModels) engines: the one-shot planner, the agentic
//  tool-calling engine, the Swift script runner they share, and running the resulting
//  action lists.
//

#import "SpliceKitCommandPalette+Private.h"

#pragma mark - Swift macro plugin path (FoundationModels @Generable, etc.)

static NSString *SpliceKitCachedSwiftMacroPluginDirectory = nil;
static BOOL SpliceKitSwiftMacroPluginDirectoryLookupDone = NO;

NSString *SpliceKitSwiftMacroPluginDirectory(void) {
    if (SpliceKitSwiftMacroPluginDirectoryLookupDone) {
        return SpliceKitCachedSwiftMacroPluginDirectory;
    }
    SpliceKitSwiftMacroPluginDirectoryLookupDone = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *xcodeAppPlugins =
        @"/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins";
    if ([fm fileExistsAtPath:xcodeAppPlugins]) {
        SpliceKitCachedSwiftMacroPluginDirectory = xcodeAppPlugins;
        return xcodeAppPlugins;
    }

    NSTask *select = [[NSTask alloc] init];
    select.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    select.arguments = @[@"-p"];
    NSPipe *selectOut = [NSPipe pipe];
    select.standardOutput = selectOut;
    select.standardError = [NSPipe pipe];
    @try {
        [select launch];
        [select waitUntilExit];
        if (select.terminationStatus == 0) {
            NSData *data = [selectOut.fileHandleForReading readDataToEndOfFile];
            NSString *devRoot = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            devRoot = [devRoot stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (devRoot.length) {
                NSString *plugins = [devRoot stringByAppendingPathComponent:
                    @"Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"];
                if ([fm fileExistsAtPath:plugins]) {
                    SpliceKitCachedSwiftMacroPluginDirectory = plugins;
                    return plugins;
                }
            }
        }
    } @catch (NSException *exception) {
        (void)exception;
    }

    return nil;
}

static NSArray<NSString *> *SpliceKitSwiftArgumentsForScriptPath(NSString *scriptPath) {
    NSString *pluginDir = SpliceKitSwiftMacroPluginDirectory();
    if (pluginDir.length) {
        return @[@"-plugin-path", pluginDir, scriptPath];
    }
    return @[scriptPath];
}

static NSString *SpliceKitFirstReadableSwiftErrorLine(NSString *stderrText) {
    if (stderrText.length == 0) {
        return @"Unknown error";
    }
    NSArray<NSString *> *lines = [stderrText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) {
            continue;
        }
        if ([trimmed containsString:@"error:"] || [trimmed hasSuffix:@": error"]) {
            return trimmed;
        }
    }
    NSString *trimmed = [stderrText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 400) {
        return [trimmed substringToIndex:400];
    }
    return trimmed;
}

NSString *SpliceKitAppleIntelligenceMacroPluginErrorMessage(void) {
    return @"Apple Intelligence requires Xcode (Swift macro plugins for FoundationModels). "
           @"Install Xcode from the App Store, then try again.";
}

BOOL SpliceKitStderrIndicatesMissingSwiftMacroPlugin(NSString *stderrText) {
    return stderrText.length > 0 && [stderrText containsString:@"plugin for module"];
}

NSString *SpliceKitFormatSwiftScriptFailure(NSString *stderrText,
                                                   BOOL usedPluginPath,
                                                   NSString *prefix) {
    if (!usedPluginPath && SpliceKitStderrIndicatesMissingSwiftMacroPlugin(stderrText)) {
        return SpliceKitAppleIntelligenceMacroPluginErrorMessage();
    }
    return [NSString stringWithFormat:@"%@%@", prefix, SpliceKitFirstReadableSwiftErrorLine(stderrText)];
}

void SpliceKitRunSwiftScriptAtPath(NSString *scriptPath, SpliceKitSwiftScriptCompletion completion) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/swift"];
    task.arguments = SpliceKitSwiftArgumentsForScriptPath(scriptPath);

    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;

    NSMutableData *outputData = [NSMutableData data];
    NSMutableData *errorData = [NSMutableData data];
    NSFileHandle *outputHandle = outputPipe.fileHandleForReading;
    NSFileHandle *errorHandle = errorPipe.fileHandleForReading;

    outputHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        if (chunk.length) {
            [outputData appendData:chunk];
        }
    };
    errorHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        if (chunk.length) {
            [errorData appendData:chunk];
        }
    };

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *finishedTask) {
        outputHandle.readabilityHandler = nil;
        errorHandle.readabilityHandler = nil;
        NSData *tailOut = [outputHandle readDataToEndOfFile];
        NSData *tailErr = [errorHandle readDataToEndOfFile];
        if (tailOut.length) {
            [outputData appendData:tailOut];
        }
        if (tailErr.length) {
            [errorData appendData:tailErr];
        }
        (void)finishedTask;
        dispatch_semaphore_signal(done);
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        outputHandle.readabilityHandler = nil;
        errorHandle.readabilityHandler = nil;
        completion(-1, @"", launchError.localizedDescription ?: @"Failed to launch swift");
        return;
    }

    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    NSString *stdoutText = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrText = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";
    completion((int)task.terminationStatus, stdoutText, stderrText);
}

@implementation SpliceKitCommandPalette (AppleAI)

- (void)executeAIResults:(NSArray<NSDictionary *> *)actions {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self executeActionList:actions];
    });
}

- (void)executeActionList:(NSArray<NSDictionary *> *)actions {
    for (NSDictionary *action in actions) {
        NSString *type = action[@"type"] ?: @"timeline";
        NSString *name = action[@"action"];
        NSNumber *repeatCount = action[@"repeat"];

        // Handle repeat_pattern: loop through inner actions N times
        if ([type isEqualToString:@"repeat_pattern"]) {
            int patternCount = [action[@"count"] intValue];
            NSArray *innerActions = action[@"actions"];
            if (patternCount > 0 && [innerActions isKindOfClass:[NSArray class]]) {
                SpliceKit_log(@"Executing repeat_pattern x%d (%lu inner actions)",
                              patternCount, (unsigned long)innerActions.count);
                for (int p = 0; p < patternCount; p++) {
                    [self executeActionList:innerActions];
                }
            }
            continue;
        }

        // Handle seek: {"type":"seek","seconds":3.0}
        if ([type isEqualToString:@"seek"]) {
            NSNumber *secs = action[@"seconds"];
            if (secs) {
                SpliceKit_handlePlaybackSeek(@{@"seconds": secs});
            }
            continue;
        }

        // Handle effect apply: {"type":"effect","name":"Keyer"}
        if ([type isEqualToString:@"effect"]) {
            NSString *effectName = action[@"name"];
            if (effectName) {
                // Select clip first
                [self executeCommand:@"selectClipAtPlayhead" type:@"timeline"];
                [NSThread sleepForTimeInterval:0.1];
                // Apply the effect
                [self executeCommand:effectName type:@"effect_apply_by_name"];
            }
            continue;
        }

        // Handle transition apply: {"type":"transition","name":"Flow"}
        if ([type isEqualToString:@"transition"]) {
            NSString *transitionName = action[@"name"];
            if (transitionName) {
                SpliceKit_handleTransitionsApply(@{@"name": transitionName});
                SpliceKit_log(@"AI applied transition: %@", transitionName);
            }
            continue;
        }

        // Handle menu command: {"type":"menu","path":["File","New","Project..."]}
        if ([type isEqualToString:@"menu"]) {
            NSArray *menuPath = action[@"path"];
            if ([menuPath isKindOfClass:[NSArray class]] && menuPath.count > 0) {
                NSDictionary *result = SpliceKit_handleMenuExecute(@{@"menuPath": menuPath});
                SpliceKit_log(@"AI executed menu: %@ -> %@", [menuPath componentsJoinedByString:@" > "], result);
            }
            continue;
        }

        int repeats = repeatCount ? repeatCount.intValue : 1;
        for (int i = 0; i < repeats; i++) {
            [self executeCommand:name type:type];
            if (repeats > 1 && i < repeats - 1) {
                [NSThread sleepForTimeInterval:0.03];
            }
        }
    }
}

#pragma mark - Apple Intelligence (FoundationModels)
//
// When the user types a natural language sentence and presses Tab, we ask
// Apple Intelligence (via FoundationModels framework) to figure out which
// commands to run. The LLM gets timeline context (clips, playhead, duration)
// and returns a JSON action list that we execute sequentially.
// Falls back to keyword matching when AI isn't available.
//

- (void)triggerAI:(NSString *)query {
    if (self.aiLoading) return;
    // Don't re-trigger if we already have results for this exact query
    if ([query isEqualToString:self.aiCompletedQuery] && self.aiResults.count > 0) return;

    self.aiLoading = YES;
    self.aiQuery = query;
    self.aiResults = nil;
    self.aiError = nil;
    [self.tableView reloadData];
    [self updateStatusLabel];
    [self updateHeroStageAnimated:YES];

    // Intercept repetitive patterns (all engines) — models can't reliably loop 40+ times
    if ([self handleRepeatPatternIfNeeded:query completion:^(NSString *summary, NSString *error) {
        self.aiLoading = NO;
        if (error) {
            self.aiError = error;
        } else {
            self.aiResults = @[@{@"type": @"gemma_summary", @"summary": summary}];
            self.aiCompletedQuery = query;
        }
        [self.tableView reloadData];
        [self updateStatusLabel];
        [self updateHeroStageAnimated:YES];
    }]) return;

    // Dispatch to Gemma 4 if selected
    if (self.aiEngine == SpliceKitAIEngineGemma4) {
        [self executeNaturalLanguageGemma:query completion:^(NSString *summary, NSString *error) {
            self.aiLoading = NO;

            if (error) {
                self.aiError = error;
                self.aiResults = nil;
                SpliceKit_log(@"[Gemma] Palette completion: error=%@", error);
            } else {
                // Wrap summary as a single display-only result
                self.aiResults = @[@{@"type": @"gemma_summary", @"summary": summary ?: @"Done."}];
                self.aiError = nil;
                self.aiCompletedQuery = query;
                SpliceKit_log(@"[Gemma] Palette completion: summary=%@",
                              summary.length > 200 ? [summary substringToIndex:200] : summary);
            }
            [self.tableView reloadData];
            [self updateStatusLabel];
            [self updateHeroStageAnimated:YES];
            if (self.aiResults.count > 0) {
                [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                            byExtendingSelection:NO];
            }
        }];
        return;
    }

    // Dispatch to Apple Intelligence+ (agentic with tools)
    if (self.aiEngine == SpliceKitAIEngineAppleAgentic) {
        [self executeNaturalLanguageAppleAgentic:query completion:^(NSString *summary, NSString *error) {
            self.aiLoading = NO;

            if (error) {
                self.aiError = error;
                self.aiResults = nil;
                SpliceKit_log(@"[AppleAI+] Palette completion: error=%@", error);
            } else {
                self.aiResults = @[@{@"type": @"gemma_summary", @"summary": summary ?: @"Done."}];
                self.aiError = nil;
                self.aiCompletedQuery = query;
                SpliceKit_log(@"[AppleAI+] Palette completion: summary=%@",
                              summary.length > 200 ? [summary substringToIndex:200] : summary);
            }
            [self.tableView reloadData];
            [self updateStatusLabel];
            [self updateHeroStageAnimated:YES];
            if (self.aiResults.count > 0) {
                [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                            byExtendingSelection:NO];
            }
        }];
        return;
    }

    // Detect question-type queries that Apple Intelligence can't answer
    // (it can only return actions, not information)
    NSString *lowerQuery = [query lowercaseString];
    BOOL isQuestion = [lowerQuery hasSuffix:@"?"] ||
        [lowerQuery hasPrefix:@"how "] || [lowerQuery hasPrefix:@"what "] ||
        [lowerQuery hasPrefix:@"which "] || [lowerQuery hasPrefix:@"where "] ||
        [lowerQuery hasPrefix:@"when "] || [lowerQuery hasPrefix:@"why "] ||
        [lowerQuery hasPrefix:@"who "] || [lowerQuery hasPrefix:@"tell me"] ||
        [lowerQuery hasPrefix:@"show me"] || [lowerQuery hasPrefix:@"list "] ||
        [lowerQuery hasPrefix:@"describe "];
    if (isQuestion) {
        self.aiLoading = NO;
        self.aiError = @"Apple Intelligence can only execute actions, not answer questions. Switch to Gemma 4 for questions.";
        [self.tableView reloadData];
        [self updateStatusLabel];
        [self updateHeroStageAnimated:YES];
        SpliceKit_log(@"[AppleAI] Question detected — Apple Intelligence cannot answer questions, suggesting Gemma 4");
        return;
    }

    [self executeNaturalLanguage:query completion:^(NSArray<NSDictionary *> *actions, NSString *error) {
        self.aiLoading = NO;

        if (error) {
            self.aiError = error;
            self.aiResults = nil;
        } else {
            // Check if the AI result is a single effect or transition request —
            // if so, search installed effects/transitions and show all matches
            if (actions.count == 1) {
                NSDictionary *act = actions[0];
                NSString *actType = act[@"type"];
                NSString *actName = act[@"name"];
                if (actName && ([actType isEqualToString:@"effect"] || [actType isEqualToString:@"transition"])) {
                    self.aiCompletedQuery = query;
                    self.aiLoading = NO;
                    NSString *filterType = [actType isEqualToString:@"transition"] ? @"transition" : @"filter";
                    // Extract keyword from user query for broader search
                    NSString *keyword = [self extractKeywordFromQuery:query];
                    [self showMatchingEffects:keyword ?: actName type:filterType];
                    return;
                }
            }
            self.aiResults = actions;
            self.aiError = nil;
            self.aiCompletedQuery = query;
        }
        [self.tableView reloadData];
        [self updateStatusLabel];
        [self updateHeroStageAnimated:YES];
        if (self.aiResults.count > 0) {
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                        byExtendingSelection:NO];
        }
    }];
}

- (NSDictionary *)getTimelineContext {
    // Fetch timeline state to give the LLM context about duration, fps, clip count
    __block NSDictionary *state = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            state = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @(5)});
        } @catch (NSException *e) {
            SpliceKit_log(@"Failed to get timeline context: %@", e.reason);
        }
    });
    if (!state || state[@"error"]) return nil;

    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    NSDictionary *dur = state[@"duration"];
    NSDictionary *playhead = state[@"playheadTime"];
    if (dur[@"seconds"] && [dur[@"seconds"] doubleValue] > 0) {
        ctx[@"durationSeconds"] = dur[@"seconds"];
    }
    if (playhead[@"seconds"]) ctx[@"playheadSeconds"] = playhead[@"seconds"];
    if (state[@"itemCount"]) ctx[@"clipCount"] = state[@"itemCount"];
    if (state[@"sequenceName"]) ctx[@"sequenceName"] = state[@"sequenceName"];

    // If duration is missing or zero, compute from items
    if (!ctx[@"durationSeconds"] || [ctx[@"durationSeconds"] doubleValue] <= 0) {
        NSArray *items = state[@"items"];
        double maxEnd = 0;
        for (NSDictionary *item in items) {
            NSDictionary *endTime = item[@"endTime"];
            double end = [endTime[@"seconds"] doubleValue];
            if (end > maxEnd) maxEnd = end;
        }
        if (maxEnd > 0) {
            ctx[@"durationSeconds"] = @(maxEnd);
        }
    }

    // Use frameRate directly if available, otherwise derive from frameDuration
    if (state[@"frameRate"]) {
        ctx[@"fps"] = state[@"frameRate"];
    } else {
        NSDictionary *fd = state[@"frameDuration"];
        if (fd[@"seconds"] && [fd[@"seconds"] doubleValue] > 0) {
            ctx[@"fps"] = @((int)round(1.0 / [fd[@"seconds"] doubleValue]));
        } else {
            ctx[@"fps"] = @(24);
        }
    }
    return ctx;
}

- (NSString *)buildSwiftScript:(NSString *)query timelineContext:(NSDictionary *)ctx {
    // Escape the query for embedding in Swift string
    NSString *escaped = [[query stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                          stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    // Build timeline context string for the prompt
    NSString *timelineInfo = @"No timeline info available.";
    if (ctx) {
        double duration = [ctx[@"durationSeconds"] doubleValue];
        double playhead = [ctx[@"playheadSeconds"] doubleValue];
        int fps = [ctx[@"fps"] intValue] ?: 24;
        int clips = [ctx[@"clipCount"] intValue];
        int totalFrames = (int)(duration * fps);
        timelineInfo = [NSString stringWithFormat:
            @"Current timeline: duration=%.2fs (%d frames), fps=%d, playhead=%.2fs, clips=%d",
            duration, totalFrames, fps, playhead, clips];
    }
    NSString *escapedCtx = [[timelineInfo stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                             stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    return [NSString stringWithFormat:@
        "import Foundation\n"
        "import FoundationModels\n"
        "\n"
        "let query = \"%@\"\n"
        "let timelineContext = \"%@\"\n"
        "\n"
        "let instructions = \"\"\"\n"
        "You are a Final Cut Pro command interpreter. Given a video editing instruction,\n"
        "return ONLY a JSON array of actions. No explanation, no markdown, just the JSON array.\n"
        "Output the MINIMUM actions needed. Never output more than 10 actions.\n"
        "\n"
        "ACTION TYPES:\n"
        "\n"
        "1. Timeline: {\"type\":\"timeline\",\"action\":\"NAME\"}\n"
        "   Edit: blade, bladeAll, delete, cut, copy, paste, undo, redo, joinClips, replaceWithGap, pasteAsConnected, insertGap\n"
        "   Select: selectAll, deselectAll, selectClipAtPlayhead\n"
        "   Trim: trimToPlayhead, trimStart, trimEnd, nudgeLeft, nudgeRight, nudgeUp, nudgeDown\n"
        "   Range: setRangeStart (mark in), setRangeEnd (mark out), clearRange\n"
        "   Markers: addMarker, addTodoMarker, addChapterMarker, deleteMarker, deleteMarkersInSelection, nextMarker, previousMarker\n"
        "   Nav: nextEdit, previousEdit, addTransition\n"
        "   Color: addColorBoard, addColorWheels, addColorCurves, addHueSaturation, addEnhanceLightAndColor, balanceColor, matchColor, addMagneticMask, resetColorBoard\n"
        "   Audio: adjustVolumeUp, adjustVolumeDown, detachAudio, volumeMute, addChannelEQ, enhanceAudio, matchAudio, addAudioFadeIn, addAudioFadeOut\n"
        "   Title: addBasicTitle, addBasicLowerThird\n"
        "   Speed: retimeNormal, retimeFast2x/4x/8x/20x, retimeSlow50/25/10, retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed, retimeSpeedRampToZero, retimeSpeedRampFromZero\n"
        "   Clips: solo, disable, createCompoundClip, breakApartClipItems, addAdjustmentClip, liftFromPrimaryStoryline, createStoryline, renameClip, openInTimeline, backToParent\n"
        "   FX: removeEffects, pasteEffects, pasteAttributes, autoReframe, showTransformControls, showCropControls\n"
        "   Caption: addCaption, splitCaption, resolveOverlaps, importCaptions\n"
        "   Multicam: createMulticamClip, switchAngle01/02/03/04, cutAndSwitchAngle01/02\n"
        "   Rate: favorite, reject, unrate\n"
        "   View: zoomToFit, zoomIn, zoomOut, toggleSnapping, toggleSkimming, toggleInspector, toggleTimelineIndex, showAudioLanes, enterFullScreen, increaseClipHeight, decreaseClipHeight\n"
        "   Project: duplicateProject, snapshotProject, projectProperties, deleteGeneratedFiles, deleteRenderFiles, newProject, newEvent, importMedia, find, findAndReplaceTitle, revealInFinder, renderAll, exportXML, analyzeAndFix, recordVoiceover, backgroundTasks\n"
        "   App: showPreferences (preferences/settings)\n"
        "\n"
        "2. Playback: {\"type\":\"playback\",\"action\":\"NAME\"}\n"
        "   playPause, goToStart, goToEnd, nextFrame, prevFrame, nextFrame10, prevFrame10\n"
        "\n"
        "3. Seek: {\"type\":\"seek\",\"seconds\":N} — jump to exact timestamp\n"
        "\n"
        "4. Effect: {\"type\":\"effect\",\"name\":\"NAME\"} — apply a video effect\n"
        "   Gaussian Blur, Sharpen, Keyer, Luma Keyer, Vignette, Noise Reduction,\n"
        "   Letterbox, Flipped, Black & White, Sepia, Aged Film, Film Grain,\n"
        "   Bloom, Glow, Pixellate, Posterize, Invert, Tilt-Shift, Drop Shadow,\n"
        "   Lens Flare, Stabilization, Rolling Shutter, Underwater\n"
        "\n"
        "5. Transition: {\"type\":\"transition\",\"name\":\"NAME\"} — apply a transition\n"
        "   Cross Dissolve, Flow, Fade To Color, Wipe, Push, Slide, Spin, Page Curl, Star, Zoom\n"
        "\n"
        "6. Menu: {\"type\":\"menu\",\"path\":[\"TopMenu\",\"SubMenu\",\"Item\"]} — execute any menu command\n"
        "   Use for app-level commands not in the lists above.\n"
        "   Example: open preferences = {\"type\":\"timeline\",\"action\":\"showPreferences\"}\n"
        "   Example: new project = {\"type\":\"menu\",\"path\":[\"File\",\"New\",\"Project...\"]}\n"
        "\n"
        "CRITICAL RULES:\n"
        "- Effects MUST use {\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"...\\\"}. NEVER put effect names in timeline actions.\n"
        "- Transitions MUST use {\\\"type\\\":\\\"transition\\\",\\\"name\\\":\\\"...\\\"}. NEVER put transition names in timeline actions.\n"
        "- ONLY use action names from the lists above. NEVER invent names like addGaussianBlur, addVignette, addPosterize, adjustHueSaturation, hold.\n"
        "- goToStart = go to beginning. goToEnd = go to end. NEVER use seek for start/end.\n"
        "- nextFrame/prevFrame = advance/go back one frame. nextFrame10/prevFrame10 = 10 frames.\n"
        "- Use seek ONLY for specific timestamps (e.g. \\\"go to 5 seconds\\\").\n"
        "- \\\"cut here\\\" or \\\"blade\\\" with no time = just blade, no seek needed.\n"
        "- Each action does ONE thing. Do not add extra unrelated actions.\n"
        "- Speed actions need selectClipAtPlayhead first: 50%%=retimeSlow50, 25%%=retimeSlow25, 10%%=retimeSlow10, 2x=retimeFast2x, 4x=retimeFast4x, 8x=retimeFast8x, 20x=retimeFast20x.\n"
        "- \\\"stabilize\\\" or \\\"reduce camera shake\\\" = effect Stabilization. \\\"rolling shutter\\\" = effect Rolling Shutter.\n"
        "\n"
        "EXAMPLES:\n"
        "- \\\"blur\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Gaussian Blur\\\"}]\n"
        "- \\\"black and white\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Black & White\\\"}]\n"
        "- \\\"stabilize\\\" -> [{\\\"type\\\":\\\"effect\\\",\\\"name\\\":\\\"Stabilization\\\"}]\n"
        "- \\\"cross dissolve\\\" -> [{\\\"type\\\":\\\"transition\\\",\\\"name\\\":\\\"Cross Dissolve\\\"}]\n"
        "- \\\"cut at 3s\\\" -> [{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":3},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"blade\\\"}]\n"
        "- \\\"blade here\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"blade\\\"}]\n"
        "- \\\"slow to half\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"retimeSlow50\\\"}]\n"
        "- \\\"go to start\\\" -> [{\\\"type\\\":\\\"playback\\\",\\\"action\\\":\\\"goToStart\\\"}]\n"
        "- \\\"next frame\\\" -> [{\\\"type\\\":\\\"playback\\\",\\\"action\\\":\\\"nextFrame\\\"}]\n"
        "- \\\"undo\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"undo\\\"}]\n"
        "- \\\"remove first 2s\\\" -> [{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":2},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"blade\\\"},{\\\"type\\\":\\\"seek\\\",\\\"seconds\\\":0},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"delete\\\"}]\n"
        "- \\\"open preferences\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"showPreferences\\\"}]\n"
        "- \\\"new project\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"newProject\\\"}]\n"
        "- \\\"mark in\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"setRangeStart\\\"}]\n"
        "- \\\"mute\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"volumeMute\\\"}]\n"
        "- \\\"detach audio\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"detachAudio\\\"}]\n"
        "- \\\"switch camera 2\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"switchAngle02\\\"}]\n"
        "- \\\"favorite\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"favorite\\\"}]\n"
        "- \\\"duplicate project\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"duplicateProject\\\"}]\n"
        "- \\\"show inspector\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"toggleInspector\\\"}]\n"
        "- \\\"crop\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"selectClipAtPlayhead\\\"},{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"showCropControls\\\"}]\n"
        "- \\\"nest clips\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"createCompoundClip\\\"}]\n"
        "- \\\"full screen\\\" -> [{\\\"type\\\":\\\"timeline\\\",\\\"action\\\":\\\"enterFullScreen\\\"}]\n"
        "\"\"\"\n"
        "\n"
        "let fullQuery = \"\\(timelineContext)\\n\\nUser request: \\(query)\"\n"
        "\n"
        "Task {\n"
        "    guard SystemLanguageModel.default.availability == .available else {\n"
        "        print(\"{\\\"error\\\": \\\"Apple Intelligence not available\\\"}\")\n"
        "        exit(1)\n"
        "    }\n"
        "    do {\n"
        "        let session = LanguageModelSession(instructions: instructions)\n"
        "        let response = try await session.respond(to: fullQuery)\n"
        "        print(response.content)\n"
        "    } catch LanguageModelSession.GenerationError.exceededContextWindowSize {\n"
        "        print(\"{\\\"error\\\": \\\"Exceeded model context window size\\\"}\")\n"
        "    } catch LanguageModelSession.GenerationError.guardrailViolation(_) {\n"
        "        print(\"{\\\"error\\\": \\\"Detected content likely to be unsafe\\\"}\")\n"
        "    } catch {\n"
        "        print(\"{\\\"error\\\": \\\"\\(error.localizedDescription)\\\"}\")\n"
        "    }\n"
        "    exit(0)\n"
        "}\n"
        "\n"
        "dispatchMain()\n",
        escaped, escapedCtx];
}

#pragma mark - Apple Intelligence+ (Agentic with FoundationModels Tools)

- (NSString *)buildAgenticSwiftScript:(NSString *)query timelineContext:(NSDictionary *)ctx {
    NSString *escaped = [[query stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                          stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    NSString *timelineInfo = @"No timeline info available.";
    if (ctx) {
        double duration = [ctx[@"durationSeconds"] doubleValue];
        double playhead = [ctx[@"playheadSeconds"] doubleValue];
        int fps = [ctx[@"fps"] intValue] ?: 24;
        int clips = [ctx[@"clipCount"] intValue];
        NSString *name = ctx[@"sequenceName"] ?: @"unknown";
        timelineInfo = [NSString stringWithFormat:
            @"Timeline: %.1fs, %d fps, %d clips, playhead at %.1fs, project: %@",
            duration, fps, clips, playhead, name];
    }
    NSString *escapedCtx = [[timelineInfo stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                             stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    // Build a compact Swift script — Apple Intelligence has a small context window
    // so we use minimal tool descriptions and only the most essential tools.
    return [NSString stringWithFormat:@
        "import Foundation\n"
        "import FoundationModels\n"
        "\n"
        "func bridge(_ method: String, _ params: [String: Any] = [:]) -> String {\n"
        "    let req: [String: Any] = [\"jsonrpc\":\"2.0\",\"id\":1,\"method\":method,\"params\":params]\n"
        "    guard let d = try? JSONSerialization.data(withJSONObject: req) else { return \"error\" }\n"
        "    var m = d; m.append(0x0a)\n"
        "    let fd = socket(AF_INET, SOCK_STREAM, 0)\n"
        "    guard fd >= 0 else { return \"error\" }\n"
        "    var a = sockaddr_in()\n"
        "    a.sin_family = sa_family_t(AF_INET)\n"
        "    a.sin_port = UInt16(9876).bigEndian\n"
        "    a.sin_addr.s_addr = inet_addr(\"127.0.0.1\")\n"
        "    let ok = withUnsafePointer(to: &a) { p in\n"
        "        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }\n"
        "    }\n"
        "    guard ok == 0 else { close(fd); return \"error\" }\n"
        "    m.withUnsafeBytes { _ = write(fd, $0.baseAddress!, m.count) }\n"
        "    var b = [UInt8](repeating: 0, count: 65536)\n"
        "    var r = Data()\n"
        "    while true { let n = read(fd, &b, b.count); if n <= 0 { break }; r.append(contentsOf: b[0..<n]); if r.contains(0x0a) { break } }\n"
        "    close(fd)\n"
        "    guard let j = try? JSONSerialization.jsonObject(with: r) as? [String:Any], let res = j[\"result\"] else {\n"
        "        if let j = try? JSONSerialization.jsonObject(with: r) as? [String:Any], let e = j[\"error\"] as? [String:Any] { return \"error: \\(e[\"message\"] ?? \"\")\" }\n"
        "        return \"error\"\n"
        "    }\n"
        "    guard let rd = try? JSONSerialization.data(withJSONObject: res) else { return \"{}\" }\n"
        "    var s = String(data: rd, encoding: .utf8) ?? \"{}\"\n"
        "    if s.count > 4000 { s = String(s.prefix(3900)) + \"...\" }\n"
        "    return s\n"
        "}\n"
        "\n"
        "// Constrained @Generable enums — model can ONLY output valid values\n"
        "@Generable enum EditAction: String {\n"
        "    // Editing\n"
        "    case blade, bladeAll, delete, cut, copy, paste, undo, redo, joinClips, replaceWithGap, pasteAsConnected, insertGap\n"
        "    // Selection\n"
        "    case selectAll, deselectAll, selectClipAtPlayhead\n"
        "    // Trim\n"
        "    case trimToPlayhead, trimStart, trimEnd, nudgeLeft, nudgeRight, nudgeUp, nudgeDown\n"
        "    // Range\n"
        "    case setRangeStart, setRangeEnd, clearRange\n"
        "    // Markers\n"
        "    case addMarker, addTodoMarker, addChapterMarker, deleteMarker, deleteMarkersInSelection, nextMarker, previousMarker\n"
        "    // Navigation\n"
        "    case nextEdit, previousEdit, addTransition\n"
        "    // Color\n"
        "    case addColorBoard, addColorWheels, addColorCurves, addHueSaturation, addEnhanceLightAndColor, balanceColor, matchColor, addMagneticMask, resetColorBoard\n"
        "    // Audio\n"
        "    case adjustVolumeUp, adjustVolumeDown, detachAudio, volumeMute, addChannelEQ, enhanceAudio, matchAudio, addAudioFadeIn, addAudioFadeOut\n"
        "    // Titles\n"
        "    case addBasicTitle, addBasicLowerThird\n"
        "    // Speed\n"
        "    case retimeNormal, retimeFast2x, retimeFast4x, retimeFast8x, retimeFast20x, retimeSlow50, retimeSlow25, retimeSlow10\n"
        "    case retimeReverse, retimeHold, freezeFrame, retimeBladeSpeed, retimeSpeedRampToZero, retimeSpeedRampFromZero\n"
        "    // Clips\n"
        "    case solo, disable, createCompoundClip, breakApartClipItems, addAdjustmentClip, liftFromPrimaryStoryline, createStoryline, renameClip, openInTimeline, backToParent\n"
        "    // Effects\n"
        "    case removeEffects, pasteEffects, pasteAttributes, autoReframe, showTransformControls, showCropControls\n"
        "    // Captions\n"
        "    case addCaption, splitCaption, resolveOverlaps, importCaptions\n"
        "    // Multicam\n"
        "    case createMulticamClip, switchAngle01, switchAngle02, switchAngle03, switchAngle04\n"
        "    case cutAndSwitchAngle01, cutAndSwitchAngle02\n"
        "    // Rating\n"
        "    case favorite, reject, unrate\n"
        "    // View\n"
        "    case zoomToFit, zoomIn, zoomOut, toggleSnapping, toggleSkimming, toggleInspector, toggleTimelineIndex\n"
        "    case showAudioLanes, enterFullScreen, increaseClipHeight, decreaseClipHeight\n"
        "    // Project\n"
        "    case duplicateProject, snapshotProject, projectProperties, deleteGeneratedFiles, deleteRenderFiles\n"
        "    case newProject, newEvent, importMedia, find, findAndReplaceTitle, revealInFinder\n"
        "    case renderAll, exportXML, analyzeAndFix, recordVoiceover, backgroundTasks\n"
        "    // App\n"
        "    case showPreferences\n"
        "}\n"
        "@Generable enum RepeatAction: String {\n"
        "    case blade, addMarker, addChapterMarker, addTodoMarker\n"
        "}\n"
        "@Generable enum EffectName: String {\n"
        "    case gaussianBlur = \"Gaussian Blur\", sharpen = \"Sharpen\", keyer = \"Keyer\", lumaKeyer = \"Luma Keyer\"\n"
        "    case vignette = \"Vignette\", noiseReduction = \"Noise Reduction\", stabilization = \"Stabilization\"\n"
        "    case blackAndWhite = \"Black & White\", sepia = \"Sepia\", agedFilm = \"Aged Film\", filmGrain = \"Film Grain\"\n"
        "    case bloom = \"Bloom\", glow = \"Glow\", pixellate = \"Pixellate\", posterize = \"Posterize\"\n"
        "    case invert = \"Invert\", flipped = \"Flipped\", tiltShift = \"Tilt-Shift\"\n"
        "    case dropShadow = \"Drop Shadow\", letterbox = \"Letterbox\", lensFlare = \"Lens Flare\"\n"
        "    case underwater = \"Underwater\", rollingShutter = \"Rolling Shutter\"\n"
        "}\n"
        "\n"
        "@Generable struct ActArgs { var action: EditAction }\n"
        "@Generable struct SeekArgs { @Guide(description: \"seconds\") var seconds: Double }\n"
        "@Generable struct ClipArgs { @Guide(description: \"max clips\") var limit: Int? }\n"
        "@Generable struct RepeatArgs {\n"
        "    var action: RepeatAction\n"
        "    @Guide(description: \"Interval in seconds\") var interval: Double\n"
        "    @Guide(description: \"Total duration (0 = auto)\") var duration: Double?\n"
        "}\n"
        "@Generable struct FxArgs { var name: EffectName }\n"
        "@Generable struct MenuArgs { @Guide(description: \"Menu path\") var path: [String] }\n"
        "@Generable struct ImportArgs {\n"
        "    @Guide(description: \"A direct .mp4/.mov/.m4v/.webm URL, or a supported provider URL\") var url: String\n"
        "    @Guide(description: \"import_only, insert_at_playhead, or append_to_timeline\") var mode: String?\n"
        "    @Guide(description: \"Optional clip title override\") var title: String?\n"
        "}\n"
        "\n"
        "struct Act: Tool {\n"
        "    let name = \"edit\"\n"
        "    let description = \"Timeline editing action. cut/split = blade. preferences = showPreferences. project settings = projectProperties.\"\n"
        "    func call(arguments: ActArgs) async throws -> String { bridge(\"timeline.action\", [\"action\": arguments.action.rawValue]) }\n"
        "}\n"
        "struct Seek: Tool {\n"
        "    let name = \"seek\"\n"
        "    let description = \"Move playhead to time in seconds\"\n"
        "    func call(arguments: SeekArgs) async throws -> String { bridge(\"playback.seekToTime\", [\"seconds\": arguments.seconds]) }\n"
        "}\n"
        "struct Clips: Tool {\n"
        "    let name = \"clips\"\n"
        "    let description = \"Get timeline clips\"\n"
        "    func call(arguments: ClipArgs) async throws -> String { bridge(\"timeline.getDetailedState\", [\"limit\": arguments.limit ?? 10]) }\n"
        "}\n"
        "struct Repeat: Tool {\n"
        "    let name = \"repeat_action\"\n"
        "    let description = \"Repeat blade/marker at intervals. For: cut/blade/marker every N seconds.\"\n"
        "    func call(arguments: RepeatArgs) async throws -> String {\n"
        "        let state = bridge(\"timeline.getDetailedState\", [\"limit\": 1])\n"
        "        var dur = arguments.duration ?? 0\n"
        "        if dur <= 0, let d = try? JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String:Any],\n"
        "           let ds = d[\"duration\"] as? [String:Any], let s = ds[\"seconds\"] as? Double { dur = s }\n"
        "        if dur <= 0 { return \"error: could not determine timeline duration\" }\n"
        "        var t = arguments.interval; var count = 0\n"
        "        while t < dur {\n"
        "            _ = bridge(\"playback.seekToTime\", [\"seconds\": t])\n"
        "            _ = bridge(\"timeline.action\", [\"action\": arguments.action.rawValue])\n"
        "            count += 1; t += arguments.interval\n"
        "        }\n"
        "        return \"Applied \\(arguments.action.rawValue) \\(count) times at \\(arguments.interval)s intervals\"\n"
        "    }\n"
        "}\n"
        "struct Fx: Tool {\n"
        "    let name = \"effect\"\n"
        "    let description = \"Apply video effect to selected clip\"\n"
        "    func call(arguments: FxArgs) async throws -> String { bridge(\"effects.apply\", [\"name\": arguments.name.rawValue]) }\n"
        "}\n"
        "struct Menu: Tool {\n"
        "    let name = \"menu\"\n"
        "    let description = \"Execute menu command by path. Only if edit tool doesn't have the action.\"\n"
        "    func call(arguments: MenuArgs) async throws -> String { bridge(\"menu.execute\", [\"menuPath\": arguments.path]) }\n"
        "}\n"
        "struct ImportURL: Tool {\n"
        "    let name = \"import_url\"\n"
        "    let description = \"Download a remote media URL, import it into Final Cut Pro, and optionally place it into the timeline\"\n"
        "    func call(arguments: ImportArgs) async throws -> String {\n"
        "        var params: [String: Any] = [\"url\": arguments.url, \"mode\": arguments.mode ?? \"import_only\"]\n"
        "        if let title = arguments.title, !title.isEmpty { params[\"title\"] = title }\n"
        "        return bridge(\"urlImport.import\", params)\n"
        "    }\n"
        "}\n"
        "\n"
        "Task {\n"
        "    do {\n"
        "        let s = LanguageModelSession(tools: [Act(), Seek(), Clips(), Repeat(), Fx(), Menu(), ImportURL()],\n"
        "            instructions: \"You control Final Cut Pro via tools. %@ cut/split means blade NOT delete. For repeating actions at intervals use repeat_action. If the request includes a media URL, use import_url. Always prefer edit tool over menu. Summarize what you did.\")\n"
        "        let r = try await s.respond(to: \"%@\")\n"
        "        print(r.content ?? \"Done.\")\n"
        "    } catch LanguageModelSession.GenerationError.exceededContextWindowSize {\n"
        "        print(\"Error: Context too large\")\n"
        "    } catch { print(\"Error: \\(error.localizedDescription)\") }\n"
        "    exit(0)\n"
        "}\n"
        "dispatchMain()\n",
        escapedCtx, escaped];
}

// Shared repeat pattern handler — returns YES if the pattern was detected and handled
- (BOOL)handleRepeatPatternIfNeeded:(NSString *)query
                         completion:(void(^)(NSString *summary, NSString *error))completion {
    NSString *lq = [query lowercaseString];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
        @"(?:cut|blade|split|mark|marker)s?.*ever(?:y)?\\s+(\\d+\\.?\\d*)\\s*(?:sec|s\\b)"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:lq options:0 range:NSMakeRange(0, lq.length)];
    if (!match) return NO;

    NSString *intervalStr = [lq substringWithRange:[match rangeAtIndex:1]];
    double interval = [intervalStr doubleValue];
    BOOL isMarker = [lq containsString:@"mark"];
    NSString *action = isMarker ? @"addMarker" : @"blade";
    if ([lq containsString:@"chapter"]) action = @"addChapterMarker";
    else if ([lq containsString:@"todo"]) action = @"addTodoMarker";

    SpliceKit_log(@"[AI] Intercepted repeat pattern: %@ every %.1fs", action, interval);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self updateGemmaStatus:[NSString stringWithFormat:@"Executing %@ every %.0fs...", action, interval]];

        __block double duration = 0;
        SpliceKit_executeOnMainThread(^{
            @try {
                NSDictionary *state = SpliceKit_handleTimelineGetDetailedState(@{@"limit": @(200)});
                duration = [state[@"duration"][@"seconds"] doubleValue];
                if (duration <= 0) {
                    for (NSDictionary *item in state[@"items"]) {
                        double end = [item[@"endTime"][@"seconds"] doubleValue];
                        if (end > duration) duration = end;
                    }
                }
            } @catch (NSException *e) {}
        });
        if (duration <= 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"Could not determine timeline duration");
            });
            return;
        }

        NSInteger count = 0;
        for (double t = interval; t < duration; t += interval) {
            NSDictionary *seekReq = @{@"method": @"playback.seekToTime", @"params": @{@"seconds": @(t)}};
            SpliceKit_handleRequest(seekReq);
            NSDictionary *actionReq = @{@"method": @"timeline.action", @"params": @{@"action": action}};
            SpliceKit_handleRequest(actionReq);
            count++;
        }

        NSString *summary = [NSString stringWithFormat:@"Applied %@ %ld times at %.0fs intervals (%.1fs timeline)",
                             action, (long)count, interval, duration];
        SpliceKit_log(@"[AI] Repeat done: %@", summary);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(summary, nil);
        });
    });
    return YES;
}

@end
