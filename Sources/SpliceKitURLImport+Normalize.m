//
//  SpliceKitURLImport+Normalize.m
//  Normalizing a download for Final Cut: the remux / transcode step (ffmpeg)
//  that runs between download and import.
//

#import "SpliceKitURLImport+Private.h"

@implementation SpliceKitURLImportService (Normalize)

- (void)normalizeJob:(SpliceKitURLImportJob *)job {
    NSString *sourcePath = SpliceKitURLImportTrimmedString(job.downloadPath);
    SpliceKit_log(@"[URLImport] normalizeJob starting for %@ with path %@",
                  job.jobID ?: @"<unknown>", sourcePath);
    NSDictionary *mediaInfo = [self inspectMediaAtPath:sourcePath];
    if (mediaInfo[@"error"]) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Downloaded file could not be inspected."
                  error:mediaInfo[@"error"]];
        return;
    }

    BOOL requiresNormalization = [mediaInfo[@"requiresNormalization"] boolValue];
    NSString *normalizationMode = SpliceKitURLImportTrimmedString(mediaInfo[@"normalizationMode"]);
    if (!requiresNormalization) {
        job.normalizedPath = sourcePath;
        [self importJobIntoFinalCut:job mediaInfo:mediaInfo];
        return;
    }

    if (SpliceKitURLImportNormalizationModeUsesStreamCopy(normalizationMode)) {
        NSString *ffmpeg = SpliceKitURLImportFFmpegPath();
        if (ffmpeg.length == 0) {
            NSString *operationLabel = [normalizationMode isEqualToString:@"remux_copy"] ||
                                       [normalizationMode isEqualToString:@"remux_copy_rewrite_timestamps"]
                ? @"stream-copy remuxing"
                : @"VP9 timestamp normalization";
            [self finishJob:job
                    success:NO
                      state:SpliceKitURLImportStateFailed
                    message:[NSString stringWithFormat:@"%@ requires ffmpeg.",
                             [operationLabel capitalizedString]]
                      error:@"SpliceKit could not find ffmpeg to normalize this media without transcoding. Run `make url-import-tools` or put ffmpeg in ~/Applications/SpliceKit/tools/."];
            return;
        }

        BOOL needsTimestampRewrite = SpliceKitURLImportNormalizationModeNeedsTimestampRewrite(normalizationMode);
        NSNumber *timescaleValue = mediaInfo[@"canonicalFrameTimescale"];
        NSNumber *frameTicksValue = mediaInfo[@"canonicalFrameTicks"];
        int canonicalTimescale = timescaleValue.intValue;
        int canonicalFrameTicks = frameTicksValue.intValue;
        if (needsTimestampRewrite && (canonicalTimescale <= 0 || canonicalFrameTicks <= 0)) {
            [self finishJob:job
                    success:NO
                      state:SpliceKitURLImportStateFailed
                    message:@"VP9 timestamp normalization could not determine a stable frame rate."
                      error:@"SpliceKit could not derive a canonical CFR time base for this VP9 source."];
            return;
        }

        NSString *progressMessage = nil;
        if ([normalizationMode isEqualToString:@"remux_copy_rewrite_timestamps"]) {
            progressMessage = @"Remuxing into MP4 and rewriting VP9 timestamps for Final Cut Pro...";
        } else if ([normalizationMode isEqualToString:@"remux_copy"]) {
            progressMessage = @"Remuxing into MP4 for Final Cut Pro...";
        } else {
            progressMessage = @"Rewriting VP9 timestamps for smoother Final Cut playback...";
        }
        [self updateJob:job state:SpliceKitURLImportStateNormalizing
                message:progressMessage
               progress:0.82];

        NSString *outputExtension = SpliceKitURLImportOutputExtensionForNormalizationMode(normalizationMode);
        NSString *outputName = [NSString stringWithFormat:@"%@.%@",
            SpliceKitURLImportSanitizeFilename(job.clipName ?: @"Imported Clip"),
            outputExtension];
        NSString *outputPath = [self pathForFilename:outputName directory:[self normalizedDirectory]];
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

        BOOL audioCanStreamCopy = ![mediaInfo[@"audioCanStreamCopy"] isKindOfClass:[NSNumber class]] ||
            [mediaInfo[@"audioCanStreamCopy"] boolValue];
        NSString *videoCodec = SpliceKitURLImportTrimmedString(mediaInfo[@"videoCodec"]).lowercaseString;
        BOOL videoIsHEVC = [videoCodec isEqualToString:@"hevc"] ||
                           [videoCodec isEqualToString:@"h265"] ||
                           [videoCodec isEqualToString:@"hev1"] ||
                           [videoCodec isEqualToString:@"hvc1"];

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:ffmpeg];
        // Map only the first video and audio track explicitly. `-map 0` would
        // pull subtitle and attachment streams into the MP4 mux and fail on
        // any container (e.g. MKV with a subrip subtitle track, or WebM with
        // an embedded image attachment) that isn't valid inside ISO BMFF.
        NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[
            @"-hide_banner",
            @"-y",
            @"-i", sourcePath,
            @"-map", @"0:v:0",
            @"-map", @"0:a:0?",
            @"-c:v", @"copy",
        ]];
        if (videoIsHEVC) {
            // Apple's AVFoundation / Final Cut / QuickTime stack only decodes
            // HEVC when the MP4 sample-entry is `hvc1` (parameter sets in
            // extradata). Matroska's HEVC comes out as `hev1` by default from
            // ffmpeg — which plays in VLC but refuses to open in FCP. Force
            // the Apple-friendly tag.
            [arguments addObjectsFromArray:@[@"-tag:v", @"hvc1"]];
        }
        if (audioCanStreamCopy) {
            [arguments addObjectsFromArray:@[@"-c:a", @"copy"]];
        } else {
            [arguments addObjectsFromArray:@[
                @"-c:a", @"aac",
                @"-b:a", @"192k",
                @"-ac", @"2",
            ]];
        }
        if (needsTimestampRewrite) {
            // B-frame-safe CFR timestamp rewrite.
            //   DTS = N * frameTicks — packets arrive in decode (DTS) order
            //     so the packet index N is already the decode index.
            //   PTS = DTS + round((src_pts - src_dts) in source frames) * frameTicks
            //     preserves h264/hevc/av1 B-frame display order. The round()
            //     snaps the offset to a whole frame-duration, cancelling the
            //     millisecond quantization in the source MKV — without it the
            //     output timestamps inherit the 42/41ms source jitter. The
            //     conversion chain: `(PTS-DTS)*TB` is the offset in seconds,
            //     times `canonicalTimescale/canonicalFrameTicks` (= fps) yields
            //     the offset in source frames, round() snaps to whole frames,
            //     times `canonicalFrameTicks` converts back to output ticks.
            //   For VP9/VP8 the source PTS always equals DTS, so the offset
            //     term collapses to 0 and this reduces to `pts=N*frameTicks`.
            NSString *settsArg = [NSString stringWithFormat:
                @"setts=time_base=1/%d:dts=N*%d:pts=N*%d+round((PTS-DTS)*TB*%d/%d)*%d:duration=%d",
                canonicalTimescale,
                canonicalFrameTicks,
                canonicalFrameTicks,
                canonicalTimescale,
                canonicalFrameTicks,
                canonicalFrameTicks,
                canonicalFrameTicks];
            [arguments addObjectsFromArray:@[@"-bsf:v", settsArg]];
        }
        [arguments addObjectsFromArray:@[@"-movflags", @"+faststart", outputPath]];
        task.arguments = arguments;

        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;

        NSMutableString *logBuffer = [NSMutableString string];
        NSFileHandle *readHandle = [pipe fileHandleForReading];
        readHandle.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *data = [handle availableData];
            if (data.length == 0) return;
            NSString *chunk = SpliceKitURLImportStringFromData(data);
            if (chunk.length == 0) return;
            @synchronized (logBuffer) {
                [logBuffer appendString:chunk];
            }
        };

        task.terminationHandler = ^(__unused NSTask *finishedTask) {
            readHandle.readabilityHandler = nil;
            NSData *tail = [readHandle readDataToEndOfFile];
            if (tail.length > 0) {
                NSString *tailString = SpliceKitURLImportStringFromData(tail);
                @synchronized (logBuffer) {
                    [logBuffer appendString:tailString ?: @""];
                }
            }

            @synchronized (job) {
                if (job.resolverTask == task) job.resolverTask = nil;
            }

            if (job.cancelled) {
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateCancelled
                        message:@"URL import was cancelled during media normalization."
                          error:nil];
                return;
            }

            NSString *fullLog = nil;
            @synchronized (logBuffer) {
                fullLog = [logBuffer copy];
            }
            NSString *trimmedLog = SpliceKitURLImportTrimmedString(fullLog);

            if (task.terminationStatus != 0) {
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateFailed
                        message:@"Media normalization failed."
                          error:(trimmedLog.length > 0 ? trimmedLog : @"ffmpeg failed while normalizing the source media.")];
                return;
            }

            NSDictionary *rewrittenInfo = [self inspectMediaAtPath:outputPath];
            if (rewrittenInfo[@"error"]) {
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateFailed
                        message:@"Normalized media could not be inspected."
                          error:rewrittenInfo[@"error"]];
                return;
            }

            dispatch_async(self.stateQueue, ^{
                job.normalizedPath = outputPath;
                job.updatedAt = [NSDate date];
            });

            NSMutableDictionary *normalizedInfo = [rewrittenInfo mutableCopy];
            normalizedInfo[@"requiresNormalization"] = @NO;
            normalizedInfo[@"normalizationMode"] = @"none";
            [self importJobIntoFinalCut:job mediaInfo:normalizedInfo];
        };

        NSError *launchError = nil;
        @synchronized (job) {
            job.resolverTask = task;
        }
        if (![task launchAndReturnError:&launchError]) {
            @synchronized (job) {
                if (job.resolverTask == task) job.resolverTask = nil;
            }
            [self finishJob:job
                    success:NO
                      state:SpliceKitURLImportStateFailed
                    message:@"Media normalization could not start."
                      error:(launchError.localizedDescription ?: @"Could not launch ffmpeg for stream-copy normalization.")];
            return;
        }
        return;
    }

    [self updateJob:job state:SpliceKitURLImportStateNormalizing
            message:@"Normalizing media for Final Cut Pro..."
           progress:0.82];

    NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:asset
                                                                    presetName:AVAssetExportPresetHighestQuality];
    if (!export) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Media normalization could not start."
                  error:@"Could not create AVAssetExportSession for this file."];
        return;
    }

    NSString *outputName = [NSString stringWithFormat:@"%@.mov",
        SpliceKitURLImportSanitizeFilename(job.clipName ?: @"Imported Clip")];
    NSString *outputPath = [self pathForFilename:outputName directory:[self normalizedDirectory]];
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

    export.outputURL = [NSURL fileURLWithPath:outputPath];
    export.outputFileType = [export.supportedFileTypes containsObject:AVFileTypeQuickTimeMovie]
        ? AVFileTypeQuickTimeMovie
        : export.supportedFileTypes.firstObject;
    export.shouldOptimizeForNetworkUse = YES;

    dispatch_async(self.stateQueue, ^{
        job.exportSession = export;
    });

    [export exportAsynchronouslyWithCompletionHandler:^{
        switch (export.status) {
            case AVAssetExportSessionStatusCompleted: {
                dispatch_async(self.stateQueue, ^{
                    job.normalizedPath = outputPath;
                    job.transcoded = YES;
                    job.exportSession = nil;
                });
                NSMutableDictionary *normalizedInfo = [mediaInfo mutableCopy];
                normalizedInfo[@"requiresNormalization"] = @NO;
                [self importJobIntoFinalCut:job mediaInfo:normalizedInfo];
                break;
            }
            case AVAssetExportSessionStatusCancelled:
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateCancelled
                        message:@"URL import was cancelled during normalization."
                          error:nil];
                break;
            default: {
                NSString *errorMessage = export.error.localizedDescription ?: @"Media normalization failed.";
                [self finishJob:job
                        success:NO
                          state:SpliceKitURLImportStateFailed
                        message:@"Media normalization failed."
                          error:errorMessage];
                break;
            }
        }
    }];
}

@end
