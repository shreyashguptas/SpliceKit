//
//  SpliceKitServerPalette.m
//  SpliceKit - Command palette handlers (command.*) and the dual timeline handlers
//  (dualTimeline.*).
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
