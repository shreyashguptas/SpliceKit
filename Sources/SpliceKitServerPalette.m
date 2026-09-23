//
//  SpliceKitServerPalette.m
//  SpliceKit - Command palette handlers (command.*, including the Apple Intelligence
//  and Gemma natural-language commands) and the dual timeline handlers (dualTimeline.*).
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Command Palette Handlers

NSDictionary *SpliceKit_handleCommandShow(NSDictionary *params) {
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitCommandPalette sharedPalette] showPalette];
    });
    return @{@"status": @"ok"};
}

NSDictionary *SpliceKit_handleCommandHide(NSDictionary *params) {
    SpliceKit_executeOnMainThread(^{
        [[SpliceKitCommandPalette sharedPalette] hidePalette];
    });
    return @{@"status": @"ok"};
}

NSDictionary *SpliceKit_handleCommandSearch(NSDictionary *params) {
    NSString *query = params[@"query"] ?: @"";
    NSArray<SpliceKitCommand *> *results = [[SpliceKitCommandPalette sharedPalette] searchCommands:query];
    NSMutableArray *items = [NSMutableArray array];
    NSUInteger limit = [params[@"limit"] unsignedIntegerValue] ?: 20;
    for (NSUInteger i = 0; i < MIN(results.count, limit); i++) {
        SpliceKitCommand *cmd = results[i];
        [items addObject:@{
            @"name": cmd.name ?: @"",
            @"action": cmd.action ?: @"",
            @"type": cmd.type ?: @"",
            @"category": cmd.categoryName ?: @"",
            @"detail": cmd.detail ?: @"",
            @"shortcut": cmd.shortcut ?: @"",
            @"score": @(cmd.score),
        }];
    }
    return @{@"commands": items, @"total": @(results.count)};
}

NSDictionary *SpliceKit_handleCommandExecute(NSDictionary *params) {
    NSString *action = params[@"action"];
    NSString *type = params[@"type"] ?: @"timeline";
    if (!action) return @{@"error": @"action parameter required"};
    return [[SpliceKitCommandPalette sharedPalette] executeCommand:action type:type];
}

NSDictionary *SpliceKit_handleDualTimelineStatus(NSDictionary *params) {
    return SpliceKit_dualTimelineStatus();
}

NSDictionary *SpliceKit_handleDualTimelineOpen(NSDictionary *params) {
    return SpliceKit_dualTimelineOpen(params ?: @{});
}

NSDictionary *SpliceKit_handleDualTimelineSyncRoot(NSDictionary *params) {
    return SpliceKit_dualTimelineSyncRoot(params ?: @{});
}

NSDictionary *SpliceKit_handleDualTimelineOpenSelectedInSecondary(NSDictionary *params) {
    return SpliceKit_dualTimelineOpenSelectedInSecondary(params ?: @{});
}

NSDictionary *SpliceKit_handleDualTimelineFocus(NSDictionary *params) {
    return SpliceKit_dualTimelineFocus(params ?: @{});
}

NSDictionary *SpliceKit_handleDualTimelineClose(NSDictionary *params) {
    return SpliceKit_dualTimelineClose(params ?: @{});
}

NSDictionary *SpliceKit_handleDualTimelineTogglePanel(NSDictionary *params) {
    return SpliceKit_dualTimelineTogglePanel(params ?: @{});
}

NSDictionary *SpliceKit_handleCommandAI(NSDictionary *params) {
    NSString *query = params[@"query"];
    if (!query) return @{@"error": @"query parameter required"};

    // Allow overriding the engine via params: "engine": "standard" | "agentic" | "gemma"
    NSString *engineOverride = params[@"engine"];
    SpliceKitAIEngine engine = [SpliceKitCommandPalette sharedPalette].aiEngine;
    if ([engineOverride isEqualToString:@"standard"]) {
        engine = SpliceKitAIEngineAppleIntelligence;
    } else if ([engineOverride isEqualToString:@"agentic"]) {
        engine = SpliceKitAIEngineAppleAgentic;
    } else if ([engineOverride isEqualToString:@"gemma"]) {
        engine = SpliceKitAIEngineGemma4;
    }

    // Route to the configured AI engine
    if (engine == SpliceKitAIEngineAppleAgentic) {
        return SpliceKit_handleCommandAIAppleAgentic(params);
    }
    if (engine == SpliceKitAIEngineGemma4) {
        return SpliceKit_handleCommandAIGemma(params);
    }

    // Default: non-agentic Apple Intelligence
    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[SpliceKitCommandPalette sharedPalette] executeNaturalLanguage:query
        completion:^(NSArray<NSDictionary *> *actions, NSString *error) {
            if (error) {
                result = @{@"error": error};
            } else {
                result = @{@"actions": actions ?: @[], @"count": @(actions.count)};
            }
            dispatch_semaphore_signal(sem);
        }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    return result ?: @{@"error": @"AI request timed out"};
}

NSDictionary *SpliceKit_handleCommandAIGemma(NSDictionary *params) {
    NSString *query = params[@"query"];
    if (!query) return @{@"error": @"query parameter required"};

    NSString *model = params[@"model"];
    if (model) {
        [SpliceKitCommandPalette sharedPalette].gemmaModel = model;
    }

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[SpliceKitCommandPalette sharedPalette] executeNaturalLanguageGemma:query
        completion:^(NSString *summary, NSString *error) {
            if (error) {
                result = @{@"error": error};
            } else {
                result = @{@"summary": summary ?: @"Done."};
            }
            dispatch_semaphore_signal(sem);
        }];

    // 5 minute timeout — multi-turn loops take longer than single-shot AI
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC));
    return result ?: @{@"error": @"Gemma AI request timed out"};
}

NSDictionary *SpliceKit_handleCommandAIAppleAgentic(NSDictionary *params) {
    NSString *query = params[@"query"];
    if (!query) return @{@"error": @"query parameter required"};

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[SpliceKitCommandPalette sharedPalette] executeNaturalLanguageAppleAgentic:query
        completion:^(NSString *summary, NSString *error) {
            if (error) {
                result = @{@"error": error};
            } else {
                result = @{@"summary": summary ?: @"Done."};
            }
            dispatch_semaphore_signal(sem);
        }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC));
    return result ?: @{@"error": @"Apple Intelligence+ request timed out"};
}
