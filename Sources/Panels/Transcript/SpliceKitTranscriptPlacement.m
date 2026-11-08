//
//  SpliceKitTranscriptPlacement.m
//  Where each transcribed word now plays on the timeline (see the header).
//

#import "SpliceKitTranscriptPlacement.h"

typedef struct {
    double trimStart;
    double sourceEnd;      // trimStart + duration in source seconds
    double timelineStart;
    double timelineEnd;
    double rate;           // timeline seconds per source second
    __unsafe_unretained NSString *path;
} SKPlacementClip;

static BOOL SKPlacement_pathsMatch(NSString *wordPath, NSString *clipPath) {
    if (wordPath.length == 0 || clipPath.length == 0) return YES;
    return [wordPath isEqualToString:clipPath];
}

// Whether some clip other than `skip` plays `sourceTime` of `path` at timeline time `t`.
static BOOL SKPlacement_timelinePlays(const SKPlacementClip *clips, NSUInteger count, NSUInteger skip,
                                      NSString *path, double t, double sourceTime, double tolerance) {
    for (NSUInteger k = 0; k < count; k++) {
        if (k == skip) continue;
        const SKPlacementClip *c = &clips[k];
        if (t < c->timelineStart - 1e-6 || t > c->timelineEnd + 1e-6) continue;
        if (!SKPlacement_pathsMatch(path, c->path)) continue;
        double played = c->trimStart + (t - c->timelineStart) / c->rate;
        if (fabs(played - sourceTime) <= tolerance) return YES;
    }
    return NO;
}

NSArray<NSDictionary *> *SpliceKitTranscript_placeWords(NSArray<NSDictionary *> *words,
                                                        NSArray<NSDictionary *> *clips,
                                                        double frameSeconds) {
    if (words.count == 0 || clips.count == 0) return @[];
    double frame = frameSeconds > 0 ? frameSeconds : 1.0 / 24.0;
    double tolerance = frame + 0.001;

    NSUInteger clipCount = clips.count;
    SKPlacementClip *table = calloc(clipCount, sizeof(SKPlacementClip));
    if (!table) return @[];
    for (NSUInteger j = 0; j < clipCount; j++) {
        NSDictionary *clip = clips[j];
        double rate = [clip[@"rateFactor"] doubleValue];
        if (!(rate > 0) || !isfinite(rate)) rate = 1.0;
        double duration = MAX(0.0, [clip[@"duration"] doubleValue]);
        table[j].trimStart = [clip[@"trimStart"] doubleValue];
        table[j].sourceEnd = table[j].trimStart + duration / rate;
        table[j].timelineStart = [clip[@"timelineStart"] doubleValue];
        table[j].timelineEnd = table[j].timelineStart + duration;
        table[j].rate = rate;
        id path = clip[@"path"];
        table[j].path = [path isKindOfClass:[NSString class]] ? path : nil;
    }

    NSMutableArray<NSDictionary *> *placements = [NSMutableArray array];
    for (NSUInteger i = 0; i < words.count; i++) {
        NSDictionary *word = words[i];
        id rawPath = word[@"path"];
        NSString *path = [rawPath isKindOfClass:[NSString class]] ? rawPath : nil;
        double sourceTime = [word[@"sourceMediaTime"] doubleValue];
        double duration = MAX(0.0, [word[@"duration"] doubleValue]);

        for (NSUInteger j = 0; j < clipCount; j++) {
            const SKPlacementClip *c = &table[j];
            if (c->timelineEnd <= c->timelineStart) continue;
            if (!SKPlacement_pathsMatch(path, c->path)) continue;
            double sourceDuration = duration / c->rate;
            double anchor = sourceTime + MIN(sourceDuration / 2.0, 2.0 * frame);
            if (anchor < c->trimStart || anchor >= c->sourceEnd) continue;

            double start = c->timelineStart + (sourceTime - c->trimStart) * c->rate;
            double end = start + duration;
            if (start < c->timelineStart &&
                !SKPlacement_timelinePlays(table, clipCount, j, path, start, sourceTime, tolerance)) {
                start = c->timelineStart;
            }
            if (end > c->timelineEnd &&
                !SKPlacement_timelinePlays(table, clipCount, j, path, end, sourceTime + sourceDuration, tolerance)) {
                end = c->timelineEnd;
            }
            [placements addObject:@{
                @"word": @(i),
                @"clip": @(j),
                @"startTime": @(start),
                @"duration": @(MAX(0.0, end - start)),
                @"sourceMediaTime": @(sourceTime),
            }];
        }
    }
    free(table);

    [placements sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double sa = [a[@"startTime"] doubleValue], sb = [b[@"startTime"] doubleValue];
        if (fabs(sa - sb) > 1e-9) return sa < sb ? NSOrderedAscending : NSOrderedDescending;
        NSInteger ca = [a[@"clip"] integerValue], cb = [b[@"clip"] integerValue];
        if (ca != cb) return ca < cb ? NSOrderedAscending : NSOrderedDescending;
        double ta = [a[@"sourceMediaTime"] doubleValue], tb = [b[@"sourceMediaTime"] doubleValue];
        if (ta != tb) return ta < tb ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return placements;
}
