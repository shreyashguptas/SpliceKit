//
//  SpliceKitURLImportRemux.m
//  Local-file remux: VP9 timestamp rewrite, shadow MP4s for MKV/WebM files and the
//  in-place hev1 -> hvc1 retag, used by the import hooks and the public shadow-URL call.
//

#import "SpliceKitURLImport+Private.h"

static NSDictionary *SpliceKitURLImportRewriteVP9TimestampsSynchronously(NSString *sourcePath,
                                                                         NSString *clipName,
                                                                         NSDictionary *mediaInfo,
                                                                         NSString **outError) {
    NSString *ffmpeg = SpliceKitURLImportFFmpegPath();
    if (ffmpeg.length == 0) {
        if (outError) {
            *outError = @"SpliceKit could not find ffmpeg to normalize this media during import.";
        }
        return nil;
    }

    NSString *normalizationMode = SpliceKitURLImportTrimmedString(mediaInfo[@"normalizationMode"]);
    BOOL needsTimestampRewrite = SpliceKitURLImportNormalizationModeNeedsTimestampRewrite(normalizationMode);
    if (!SpliceKitURLImportNormalizationModeUsesStreamCopy(normalizationMode)) {
        if (outError) {
            *outError = @"SpliceKit could not stream-copy normalize this source.";
        }
        return nil;
    }

    int canonicalTimescale = [mediaInfo[@"canonicalFrameTimescale"] intValue];
    int canonicalFrameTicks = [mediaInfo[@"canonicalFrameTicks"] intValue];
    if (needsTimestampRewrite && (canonicalTimescale <= 0 || canonicalFrameTicks <= 0)) {
        if (outError) {
            *outError = @"SpliceKit could not derive a canonical CFR time base for this VP9 source.";
        }
        return nil;
    }

    BOOL audioCanStreamCopy = ![mediaInfo[@"audioCanStreamCopy"] isKindOfClass:[NSNumber class]] ||
        [mediaInfo[@"audioCanStreamCopy"] boolValue];
    NSString *videoCodec = SpliceKitURLImportTrimmedString(mediaInfo[@"videoCodec"]).lowercaseString;
    BOOL videoIsHEVC = [videoCodec isEqualToString:@"hevc"] ||
                       [videoCodec isEqualToString:@"h265"] ||
                       [videoCodec isEqualToString:@"hev1"] ||
                       [videoCodec isEqualToString:@"hvc1"];

    NSString *safeName = SpliceKitURLImportSanitizeFilename(clipName.length > 0
        ? clipName
        : [[sourcePath lastPathComponent] stringByDeletingPathExtension]);
    NSString *outputExtension = SpliceKitURLImportOutputExtensionForNormalizationMode(normalizationMode);
    NSString *outputName = [NSString stringWithFormat:@"%@.%@", safeName, outputExtension];
    NSString *outputPath = SpliceKitURLImportUniquePathForFilename(outputName,
                                                                   SpliceKitURLImportSharedNormalizedDirectory());
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffmpeg];
    // Explicit per-stream mapping keeps subtitle/attachment streams out of the
    // MP4 mux. MKV files regularly ship with subrip subtitles and font
    // attachments that the ISO BMFF muxer can't handle.
    NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[
        @"-hide_banner",
        @"-y",
        @"-i", sourcePath,
        @"-map", @"0:v:0",
        @"-map", @"0:a:0?",
        @"-c:v", @"copy",
    ]];
    if (videoIsHEVC) {
        // Force the `hvc1` sample-entry tag — AVFoundation / Final Cut refuse
        // to decode HEVC muxed with ffmpeg's default `hev1` tag.
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
        // B-frame-safe CFR timestamp rewrite (see the matching comment in
        // normalizeJob:). DTS = N * frameTicks; PTS preserves the source
        // PTS-DTS offset snapped to whole frame-durations so h264/hevc/av1
        // display order survives. For VP9/VP8 the offset term collapses to 0.
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

    SpliceKit_log(@"[VP9Import] ffmpeg remux args: %@", [arguments componentsJoinedByString:@" "]);

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (outError) {
            *outError = launchError.localizedDescription ?: @"Could not launch ffmpeg for VP9 timestamp normalization.";
        }
        return nil;
    }

    NSData *logData = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *ffmpegLog = SpliceKitURLImportTrimmedString(SpliceKitURLImportStringFromData(logData));
    if (task.terminationStatus != 0) {
        if (outError) {
            *outError = ffmpegLog.length > 0 ? ffmpegLog : @"ffmpeg failed while rewriting VP9 timestamps.";
        }
        return nil;
    }

    NSDictionary *rewrittenInfo = [[SpliceKitURLImportService sharedService] inspectMediaAtPath:outputPath];
    if (rewrittenInfo[@"error"]) {
        if (outError) *outError = rewrittenInfo[@"error"];
        return nil;
    }

    return @{
        @"path": outputPath,
        @"mediaInfo": rewrittenInfo,
    };
}

// Deterministic shadow path: same source file → same .mp4 filename. The hash
// folds in size + mtime, so any change to the source invalidates the shadow
// automatically. Restarts don't produce duplicates (Fix.mp4, Fix-1.mp4,
// Fix-2.mp4, …) because the shadow path is a pure function of the source;
// before remuxing we just check whether the destination already exists.
//
// Using the filesystem as the cache has a nice side-effect: a single FCP
// session that triggers the hook 5× per Media Import row (thumbnail →
// metadata → preview → validate → import) pays the ~200ms ffmpeg cost once
// and then reuses the on-disk shadow instantly.
static NSString *SpliceKitURLImportShadowFilenameForSource(NSString *sourcePath, NSString *extension) {
    if (sourcePath.length == 0) return nil;
    NSError *attrError = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:sourcePath
                                                                            error:&attrError];
    NSDate *mtime = attrs.fileModificationDate;
    unsigned long long size = attrs.fileSize;
    long long mtimeInt = mtime ? (long long)llround(mtime.timeIntervalSince1970) : 0;

    NSString *base = SpliceKitURLImportSanitizeFilename(
        [[sourcePath lastPathComponent] stringByDeletingPathExtension]);
    if (base.length == 0) base = @"shadow";

    NSString *key = [NSString stringWithFormat:@"%@|%llu|%lld", sourcePath, size, mtimeInt];
    const char *cStr = key.UTF8String;
    NSUInteger hash = 5381;
    for (NSUInteger i = 0; cStr && cStr[i]; i++) {
        hash = ((hash << 5) + hash) ^ (unsigned char)cStr[i];
    }
    return [NSString stringWithFormat:@"%@.%08lx.%@", base, (unsigned long)(hash & 0xffffffff),
            extension.length > 0 ? extension : @"mp4"];
}

// Extensions we potentially remux. Matroska-family files are always inspected
// (and usually rewritten to a shadow MP4); MP4-family files are inspected only
// to catch the specific case of HEVC muxed with the `hev1` sample-entry tag,
// which AVFoundation / Final Cut refuse to decode (they require `hvc1`).
// Everything else short-circuits immediately — without the gate, a hook like
// FFFileImporter.scanURLForFiles: on a folder with thousands of Motion
// templates / JDownloader class files / thumbnails would spawn a tree-wide
// storm of ffprobe calls and stall FCP's Processing Files dialog.
static BOOL SpliceKitURLImportPathHasRemuxableExtension(NSString *path) {
    NSString *ext = [[path pathExtension] lowercaseString];
    if (ext.length == 0) return NO;
    return [ext isEqualToString:@"mkv"] ||
           [ext isEqualToString:@"webm"] ||
           [ext isEqualToString:@"mka"] ||
           [ext isEqualToString:@"mk3d"] ||
           [ext isEqualToString:@"mp4"] ||
           [ext isEqualToString:@"m4v"] ||
           [ext isEqualToString:@"mov"];
}

// Fast-path for MP4 sources whose only problem is the `hev1` sample-entry tag.
// A full ffmpeg stream-copy would rewrite all the video data (20+ GB on a
// Dolby Vision iTunes rip) just to change 4 bytes. Instead:
//   1. APFS clonefile() — near-instant COW snapshot, no disk duplication.
//   2. mmap the clone, scan the first 64 MB for "hev1" in a plausible box
//      header, verify it's a sample-entry (size in [32, 10MB], not metadata).
//   3. Overwrite those 4 bytes with "hvc1" and msync.
// Total extra disk usage: ~KB (the one modified block). Typical runtime: a
// few ms for the scan, bounded by the moov box size on disk.
//
// Only applies when the source MP4 already has HEVC parameter sets in its
// sample-description extradata (the common case — ffprobe reports
// extradata_size > 0). If the parameter sets were inline-only, the decoder
// would still fail after the tag flip; we leave that edge case to the ffmpeg
// fallback.
static BOOL SpliceKitURLImportRetagMP4HEVCInPlace(NSString *sourcePath,
                                                   NSString *shadowPath,
                                                   NSString **outError) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:shadowPath error:nil];
    [fm createDirectoryAtPath:[shadowPath stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:nil];

    const char *src = sourcePath.fileSystemRepresentation;
    const char *dst = shadowPath.fileSystemRepresentation;
    if (clonefile(src, dst, 0) != 0) {
        if (outError) {
            *outError = [NSString stringWithFormat:
                @"clonefile(%@ -> %@) failed: %s (likely cross-volume — shadow dir must live on the same APFS volume as the source)",
                sourcePath.lastPathComponent, shadowPath.lastPathComponent, strerror(errno)];
        }
        return NO;
    }

    int fd = open(dst, O_RDWR);
    if (fd < 0) {
        if (outError) {
            *outError = [NSString stringWithFormat:@"open clone for writing failed: %s", strerror(errno)];
        }
        return NO;
    }

    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        if (outError) *outError = [NSString stringWithFormat:@"fstat failed: %s", strerror(errno)];
        return NO;
    }

    // Scan bounds — moov box is normally at the start for faststart MP4s and
    // at the end otherwise. 64 MB from the start covers faststart movs, plus
    // we also scan 64 MB from the end for non-faststart cases.
    size_t fileSize = (size_t)st.st_size;
    size_t scanLen = fileSize < (64 * 1024 * 1024) ? fileSize : (64 * 1024 * 1024);

    BOOL found = NO;
    off_t regions[2][2] = {
        { 0, (off_t)scanLen },
        { (off_t)(fileSize > scanLen ? fileSize - scanLen : 0), (off_t)scanLen },
    };
    int regionCount = (fileSize > scanLen) ? 2 : 1;

    for (int r = 0; r < regionCount && !found; r++) {
        off_t offset = regions[r][0];
        size_t length = (size_t)regions[r][1];
        // mmap requires page-aligned offsets.
        long pageSize = sysconf(_SC_PAGESIZE);
        off_t alignedOffset = offset - (offset % pageSize);
        size_t alignBias = (size_t)(offset - alignedOffset);
        size_t mapLen = length + alignBias;
        if (alignedOffset + (off_t)mapLen > (off_t)fileSize) {
            mapLen = (size_t)(fileSize - alignedOffset);
        }

        unsigned char *map = mmap(NULL, mapLen, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd, alignedOffset);
        if (map == MAP_FAILED) continue;

        for (size_t i = alignBias; i + 8 <= mapLen; i++) {
            if (map[i] != 'h' || map[i + 1] != 'e' ||
                map[i + 2] != 'v' || map[i + 3] != '1') {
                continue;
            }
            // A sample entry box header is: [4 bytes size][4 bytes type].
            // The size field sits at bytes i-4 through i-1. Require it to be
            // in a plausible range for a sample entry so we don't rewrite
            // random metadata that happens to contain the ascii "hev1".
            if (i < 4) continue;
            uint32_t size = ((uint32_t)map[i - 4] << 24) |
                            ((uint32_t)map[i - 3] << 16) |
                            ((uint32_t)map[i - 2] <<  8) |
                            ((uint32_t)map[i - 1]);
            if (size < 32 || size > (10 * 1024 * 1024)) continue;

            // "hev1" -> "hvc1": index 1 changes e->v, index 2 changes v->c,
            // indices 0 (h) and 3 (1) stay. Don't write to index 3 without
            // changing it — in the cloned file that would allocate a fresh
            // block for a no-op write.
            map[i + 1] = 'v';
            map[i + 2] = 'c';
            msync(map + i, 4, MS_SYNC);
            SpliceKit_log(@"[VP9Import] retag: rewrote hev1 -> hvc1 at file offset %lld",
                          (long long)(alignedOffset + (off_t)i));
            found = YES;
            break;
        }

        munmap(map, mapLen);
    }

    close(fd);

    if (!found) {
        [fm removeItemAtPath:shadowPath error:nil];
        if (outError) {
            *outError = @"Did not find a hev1 sample-entry in the source MP4 within the first or last 64 MB.";
        }
        return NO;
    }
    return YES;
}

NSURL *SpliceKitURLImportMaybeRewriteLocalFileURL(NSURL *fileURL,
                                                         NSString **outError) {
    if (![fileURL isKindOfClass:[NSURL class]] || !fileURL.isFileURL) return fileURL;

    NSString *sourcePath = fileURL.path.stringByStandardizingPath;
    if (SpliceKitURLImportPathIsWithinDirectory(sourcePath,
                                                SpliceKitURLImportSharedNormalizedDirectory())) {
        return fileURL;
    }
    if (!SpliceKitURLImportPathHasRemuxableExtension(sourcePath)) {
        return fileURL;
    }

    // Filesystem-level cache: same source (path+size+mtime) → same shadow path.
    // If the shadow exists already (from a previous hook call in this session
    // or even a previous FCP launch), reuse it instead of re-running ffmpeg.
    NSString *shadowDir = SpliceKitURLImportSharedNormalizedDirectory();
    NSString *shadowName = SpliceKitURLImportShadowFilenameForSource(sourcePath, @"mp4");
    NSString *shadowPath = shadowName.length > 0
        ? [shadowDir stringByAppendingPathComponent:shadowName]
        : nil;

    if (shadowPath.length > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:shadowPath]) {
        SpliceKit_log(@"[VP9Import] shadow HIT: %@ -> %@",
                      sourcePath.lastPathComponent, shadowName);
        return [NSURL fileURLWithPath:shadowPath];
    }

    SpliceKit_log(@"[VP9Import] shadow MISS, remuxing: %@ -> %@",
                  sourcePath.lastPathComponent, shadowName ?: @"<nil>");

    NSDictionary *mediaInfo = [[SpliceKitURLImportService sharedService] inspectMediaAtPath:sourcePath];
    NSString *normalizationMode = SpliceKitURLImportTrimmedString(mediaInfo[@"normalizationMode"]);
    if (!SpliceKitURLImportNormalizationModeUsesStreamCopy(normalizationMode)) return fileURL;

    // Fast path: MP4 source whose only issue is the `hev1` sample-entry tag
    // (AVFoundation / Final Cut need `hvc1`). Clone + byte-edit instead of
    // running a full 20+ GB stream-copy remux that a user on a full disk
    // can't fit. We detect this case by source extension + codec — inspecting
    // already set mode=`remux_copy` for it, so we just intercept before the
    // ffmpeg path runs.
    NSString *videoCodec = SpliceKitURLImportTrimmedString(mediaInfo[@"videoCodec"]).lowercaseString;
    NSString *sourceExt = [[sourcePath pathExtension] lowercaseString];
    BOOL sourceIsMP4 = [sourceExt isEqualToString:@"mp4"] ||
                       [sourceExt isEqualToString:@"m4v"] ||
                       [sourceExt isEqualToString:@"mov"];
    BOOL sourceIsHEV1 = [videoCodec isEqualToString:@"hev1"];
    if (sourceIsMP4 && sourceIsHEV1 && shadowPath.length > 0) {
        NSString *retagError = nil;
        if (SpliceKitURLImportRetagMP4HEVCInPlace(sourcePath, shadowPath, &retagError)) {
            SpliceKit_log(@"[VP9Import] retag fast-path: %@ -> %@",
                          sourcePath.lastPathComponent, shadowName);
            return [NSURL fileURLWithPath:shadowPath];
        }
        SpliceKit_log(@"[VP9Import] retag fast-path failed (%@), falling back to ffmpeg", retagError);
    }

    NSString *clipName = [[sourcePath lastPathComponent] stringByDeletingPathExtension];
    NSDictionary *rewriteResult = SpliceKitURLImportRewriteVP9TimestampsSynchronously(sourcePath,
                                                                                      clipName,
                                                                                      mediaInfo,
                                                                                      outError);
    NSString *rewrittenPath = SpliceKitURLImportTrimmedString(rewriteResult[@"path"]);
    if (rewrittenPath.length == 0) return fileURL;

    // The synchronous remuxer picks a unique filename via
    // `SpliceKitURLImportUniquePathForFilename`, so its output may not match
    // our deterministic shadowPath. Rename into place so future calls hit the
    // shadow HIT branch above. Fall back to the remuxer's path if the rename
    // fails (e.g. cross-device move) so the import still works.
    if (shadowPath.length > 0 && ![rewrittenPath isEqualToString:shadowPath]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:shadowPath error:nil];
        NSError *moveError = nil;
        if ([fm moveItemAtPath:rewrittenPath toPath:shadowPath error:&moveError]) {
            rewrittenPath = shadowPath;
        } else {
            SpliceKit_log(@"[VP9Import] could not rename %@ -> %@: %@",
                          rewrittenPath.lastPathComponent,
                          shadowPath.lastPathComponent,
                          moveError.localizedDescription ?: @"unknown");
        }
    }

    return [NSURL fileURLWithPath:rewrittenPath];
}
