//
//  SpliceKitBridgeEnums.m
//  Canonical allowed-value lists for JSON-RPC validation error messages.
//

#import "SpliceKit.h"
#import "SpliceKitCaptionPanel.h"

NSString *SpliceKit_joinAllowedValues(NSArray<NSString *> *values) {
    if (!values.count) return @"";
    return [values componentsJoinedByString:@", "];
}

NSString *SpliceKit_errorUnknownValue(NSString *label,
                                      NSString *value,
                                      NSArray<NSString *> *allowed,
                                      NSString *hintTool) {
    NSMutableString *msg = [NSMutableString stringWithFormat:@"Unknown %@: %@. Available: %@",
                            label, value ?: @"", SpliceKit_joinAllowedValues(allowed)];
    if (hintTool.length > 0) {
        [msg appendFormat:@". See also %@()", hintTool];
    }
    return msg;
}

static NSArray<NSString *> *SpliceKit_sortedCopy(NSArray<NSString *> *values) {
    return [values sortedArrayUsingSelector:@selector(compare:)];
}

NSArray<NSString *> *SpliceKit_debugPresetNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = SpliceKit_sortedCopy(@[
            @"timeline_visual", @"timeline_logging", @"performance",
            @"render_debug", @"verbose_logging", @"all_off",
        ]);
    });
    return names;
}

NSArray<NSString *> *SpliceKit_playbackActionNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = SpliceKit_sortedCopy([SpliceKit_playbackActionMap() allKeys]);
    });
    return names;
}

NSDictionary<NSString *, NSString *> *SpliceKit_playbackActionMap(void) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"playPause":         @"playPause:",
            @"goToStart":         @"gotoStart:",
            @"goToEnd":           @"gotoEnd:",
            @"nextFrame":         @"stepForward:",
            @"prevFrame":         @"stepBackward:",
            @"nextFrame10":       @"stepForward10Frames:",
            @"prevFrame10":       @"stepBackward10Frames:",
            @"playAroundCurrent": @"playAroundCurrentFrame:",
            @"playFromStart":     @"playFromStart:",
            @"playInToOut":       @"playInToOut:",
            @"playReverse":       @"playReverse:",
            @"stopPlaying":       @"stopPlaying:",
            @"loop":              @"loop:",
            @"fastForward":       @"fastForward:",
            @"rewind":            @"rewind:",
            @"playRate1X":        @"playRate1X:",
            @"playRate2X":        @"playRate2X:",
            @"playRate4X":        @"playRate4X:",
            @"playRate8X":        @"playRate8X:",
            @"playRate16X":       @"playRate16X:",
            @"playRate32X":       @"playRate32X:",
            @"playRateHalf":      @"playRateHalf:",
            @"playRateMinusHalf": @"playRateMinusHalf:",
            @"playRateMinus1X":   @"playRateMinus1X:",
            @"playRateMinus2X":   @"playRateMinus2X:",
            @"playRateMinus32X":  @"playRateMinus32X:",
        };
    });
    return map;
}

NSArray<NSString *> *SpliceKit_bridgeBooleanOptionNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = SpliceKit_sortedCopy(@[
            @"effectDragAsAdjustmentClip", @"viewerPinchZoom",
            @"videoOnlyKeepsAudioDisabled", @"suppressAutoImport",
            @"springLoadedBlade", @"sidebarCoalesceLiveScroll",
            @"timelineOverviewBar", @"timelinePerformanceMode",
            @"timelineInteractionSuspend", @"timelinePlayheadOverlay",
            @"tlkOptimizedReload",
        ]);
    });
    return names;
}

NSArray<NSString *> *SpliceKit_bridgeValueOptionNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = SpliceKit_sortedCopy(@[
            @"lLadder", @"jLadder", @"defaultSpatialConformType",
            @"aiEngine", @"gemmaModel",
        ]);
    });
    return names;
}

NSArray<NSString *> *SpliceKit_bridgeOptionNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *all = [NSMutableArray array];
        [all addObjectsFromArray:SpliceKit_bridgeBooleanOptionNames()];
        [all addObjectsFromArray:SpliceKit_bridgeValueOptionNames()];
        names = SpliceKit_sortedCopy(all);
    });
    return names;
}

NSArray<NSString *> *SpliceKit_directTimelineActionNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = SpliceKit_sortedCopy(@[
            @"changeMarkerType", @"changeMarkerName", @"markMarkerCompleted", @"removeMarker",
            @"retimeSetRate", @"retimeHoldPreset", @"retimeReverse", @"retimeBladeSpeedPreset",
            @"retimeSpeedRamp", @"retimeInstantReplay", @"retimeJumpCut", @"retimeRewind",
            @"retimeSetInterpolation", @"splitAtTime", @"trimDuration", @"extendOverNextClip",
            @"joinThroughEdits", @"removeEdits", @"insertGapDirect", @"insertFreezeFrame",
            @"nudgeAnchoredItems", @"nudgeSpineItems", @"changeAudioVolume",
            @"applyAudioFadesDirect", @"setAudioPlayEnable", @"setBackgroundMusic",
            @"detachAudioDirect", @"alignAudioToVideoDirect", @"deleteMultiAngle",
            @"renameAngle", @"audioSyncMultiAngle", @"addKeywords", @"removeKeywords",
            @"removeEffectByID", @"invertEffectMasks", @"toggleEnabled",
            @"breakApartClipItems", @"createCompoundClipDirect", @"liftAnchoredEdits",
            @"renameDirect", @"deleteItemsInArray", @"moveClipsToTrash", @"duplicateCaptions",
            @"addVariants", @"removeVariants", @"finalizeVariant", @"newProject", @"newEvent",
            @"validateAndRepair", @"autoReframeDirect", @"alignToMusicMarkers",
            @"alignClipsAtMusicMarkers", @"addTransitionsDirect", @"analyzeAndOptimize",
            @"resolveLaneConflicts", @"resolveLaneGaps",
        ]);
    });
    return names;
}

NSArray<NSString *> *SpliceKit_captionStylePresetIDs(void) {
    static NSArray<NSString *> *ids;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (SpliceKitCaptionStyle *style in [SpliceKitCaptionStyle builtInPresets]) {
            if (style.presetID.length > 0) {
                [list addObject:style.presetID];
            }
        }
        ids = SpliceKit_sortedCopy(list);
    });
    return ids;
}

NSArray<NSString *> *SpliceKit_debugResetConfigScopes(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = SpliceKit_sortedCopy(@[@"all", @"tlk", @"cfprefs", @"log"]);
    });
    return names;
}
