//
//  SpliceKitServerPalette.m
//  SpliceKit - The dual timeline handlers (dualTimeline.*).
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Dual Timeline Handlers

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
