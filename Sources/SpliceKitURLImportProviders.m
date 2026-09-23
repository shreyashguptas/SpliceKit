//
//  SpliceKitURLImportProviders.m
//  Remote providers: yt-dlp metadata and download for YouTube / Vimeo, and the
//  direct-file, YouTube and Vimeo resolver classes.
//

#import "SpliceKitURLImport+Private.h"

static NSString *SpliceKitURLImportProviderDependencyMessage(NSString *provider,
                                                            NSString *ytDLP,
                                                            NSString *ffmpeg) {
    NSString *label = provider.length > 0 ? provider : @"Provider";
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    if (ytDLP.length == 0) [missing addObject:@"yt-dlp"];
    if (ffmpeg.length == 0) [missing addObject:@"ffmpeg"];
    NSString *missingList = missing.count > 0
        ? [missing componentsJoinedByString:@" and "]
        : @"yt-dlp and ffmpeg";
    return [NSString stringWithFormat:
        @"%@ import requires %@. SpliceKit looks in ~/Applications/SpliceKit/tools, your PATH, and common package-manager locations. If they're already installed somewhere custom, run `make url-import-tools` or symlink them into ~/Applications/SpliceKit/tools/.",
        label, missingList];
}

static NSDictionary *SpliceKitURLImportProviderMetadata(NSString *ytDLP,
                                                        NSURL *url,
                                                        NSString *provider,
                                                        NSString **outError) {
    if (ytDLP.length == 0 || !url) {
        if (outError) *outError = @"Provider metadata check could not start.";
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ytDLP];
    task.arguments = @[
        @"--skip-download",
        @"--no-playlist",
        @"--no-warnings",
        @"--print", @"%(live_status)s\t%(is_live)s\t%(was_live)s\t%(title)s",
        url.absoluteString ?: @""
    ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (outError) {
            *outError = launchError.localizedDescription ?: @"Could not launch yt-dlp metadata check.";
        }
        return nil;
    }

    [task waitUntilExit];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = SpliceKitURLImportTrimmedString(SpliceKitURLImportStringFromData(data));
    if (task.terminationStatus != 0) {
        if (outError) {
            *outError = output.length > 0
                ? output
                : [NSString stringWithFormat:@"%@ metadata check failed.", provider ?: @"Provider"];
        }
        return nil;
    }

    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]];
    NSString *lastLine = @"";
    for (NSString *line in [lines reverseObjectEnumerator]) {
        NSString *trimmed = SpliceKitURLImportTrimmedString(line);
        if (trimmed.length > 0) {
            lastLine = trimmed;
            break;
        }
    }

    if (lastLine.length == 0) return @{};

    NSArray<NSString *> *parts = [lastLine componentsSeparatedByString:@"\t"];
    NSString *liveStatus = parts.count > 0 ? SpliceKitURLImportTrimmedString(parts[0]) : @"";
    NSString *isLive = parts.count > 1 ? SpliceKitURLImportTrimmedString(parts[1]) : @"";
    NSString *wasLive = parts.count > 2 ? SpliceKitURLImportTrimmedString(parts[2]) : @"";
    NSString *title = @"";
    if (parts.count > 3) {
        title = [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)]
            componentsJoinedByString:@"\t"];
        title = SpliceKitURLImportTrimmedString(title);
    }

    return @{
        @"live_status": liveStatus ?: @"",
        @"is_live": isLive ?: @"",
        @"was_live": wasLive ?: @"",
        @"title": title ?: @""
    };
}

static double SpliceKitURLImportPercentFromLine(NSString *line) {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+(?:\\.[0-9]+)?)%"
                                                         options:0
                                                           error:nil];
    });
    NSTextCheckingResult *match = [regex firstMatchInString:line
                                                    options:0
                                                      range:NSMakeRange(0, line.length)];
    if (!match || match.numberOfRanges < 2) return -1.0;
    NSString *number = [line substringWithRange:[match rangeAtIndex:1]];
    return [number doubleValue];
}

static NSString *SpliceKitURLImportDownloadedFileMatchingPrefix(NSString *directory, NSString *prefix) {
    if (directory.length == 0 || prefix.length == 0) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:directory error:nil];
    NSString *bestPath = nil;
    NSDate *bestDate = nil;

    for (NSString *name in entries) {
        if (![name hasPrefix:prefix]) continue;
        if ([name hasSuffix:@".part"] || [name hasSuffix:@".ytdl"] || [name hasSuffix:@".tmp"]) continue;

        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if ([attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;

        NSDate *modDate = attrs[NSFileModificationDate] ?: [NSDate distantPast];
        if (!bestPath || [modDate compare:bestDate] == NSOrderedDescending) {
            bestPath = path;
            bestDate = modDate;
        }
    }

    return bestPath;
}

static void SpliceKitURLImportResolveProviderURL(NSString *provider,
                                                 NSURL *url,
                                                 SpliceKitURLImportJob *job,
                                                 SpliceKitURLImportResolverProgressBlock progress,
                                                 SpliceKitURLImportResolverCompletionBlock completion) {
    NSString *ytDLP = SpliceKitURLImportYTDLPPath();
    NSString *ffmpeg = SpliceKitURLImportFFmpegPath();
    if (ytDLP.length == 0 || ffmpeg.length == 0) {
        completion(nil, nil, nil, SpliceKitURLImportProviderDependencyMessage(provider, ytDLP, ffmpeg));
        return;
    }

    if (progress) {
        progress([NSString stringWithFormat:@"Resolving %@ stream...", provider ?: @"provider"], 0.04);
    }
    SpliceKit_log(@"[URLImport] Starting %@ resolve for %@", provider ?: @"provider", url.absoluteString ?: @"");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (job.cancelled) {
            completion(nil, nil, nil, @"URL import was cancelled.");
            return;
        }
        NSString *resolvedTitle = nil;

        if (progress) {
            progress([NSString stringWithFormat:@"Checking %@ stream metadata...", provider ?: @"provider"], 0.05);
        }

        NSString *metadataError = nil;
        NSDictionary *metadata = SpliceKitURLImportProviderMetadata(ytDLP, url, provider, &metadataError);
        NSString *liveStatus = [SpliceKitURLImportTrimmedString(metadata[@"live_status"]) lowercaseString];
        NSString *isLive = [SpliceKitURLImportTrimmedString(metadata[@"is_live"]) lowercaseString];
        NSString *wasLive = [SpliceKitURLImportTrimmedString(metadata[@"was_live"]) lowercaseString];
        NSString *metadataTitle = SpliceKitURLImportTrimmedString(metadata[@"title"]);
        if (metadataTitle.length > 0) resolvedTitle = metadataTitle;

        BOOL providerIsLive = [liveStatus isEqualToString:@"is_live"] ||
                              [liveStatus isEqualToString:@"is_upcoming"] ||
                              [isLive isEqualToString:@"true"] ||
                              [isLive isEqualToString:@"yes"] ||
                              [isLive isEqualToString:@"1"];
        BOOL providerWasLive = [liveStatus isEqualToString:@"post_live"] ||
                               [wasLive isEqualToString:@"true"] ||
                               [wasLive isEqualToString:@"yes"] ||
                               [wasLive isEqualToString:@"1"];

        if (providerIsLive && !providerWasLive) {
            NSString *label = resolvedTitle.length > 0 ? resolvedTitle : (provider ?: @"This URL");
            NSString *detail = [NSString stringWithFormat:
                @"%@ is a live or upcoming stream. SpliceKit URL Import currently supports finished videos, not active live streams.",
                label];
            SpliceKit_log(@"[URLImport] %@ metadata rejected live stream: %@", provider ?: @"Provider", detail);
            completion(nil, resolvedTitle, nil, detail);
            return;
        }

        if (metadataError.length > 0) {
            SpliceKit_log(@"[URLImport] %@ metadata probe failed, continuing with download path: %@",
                          provider ?: @"Provider", metadataError);
        }

        NSString *baseName = job.titleOverride.length > 0
            ? job.titleOverride
            : (resolvedTitle.length > 0 ? resolvedTitle : job.clipName);
        baseName = SpliceKitURLImportSanitizeFilename(baseName);
        NSString *prefix = [NSString stringWithFormat:@"%@-%@",
            baseName,
            [[[NSUUID UUID] UUIDString] substringToIndex:8]];
        NSString *downloadsDir = SpliceKitURLImportSharedDownloadsDirectory();
        NSString *outputTemplate = [downloadsDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.%%(ext)s", prefix]];

        NSString *formatSpec = job.highestQuality
            ? @"bv*+ba[ext=m4a]/bv*+ba/b"
            : @"b[ext=mp4]/bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b";
        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:
            @"--newline",
            @"--no-playlist",
            @"--restrict-filenames",
            @"--no-warnings",
            @"--output", outputTemplate,
            @"-f", formatSpec,
            @"--merge-output-format", @"mp4",
            @"--ffmpeg-location", [ffmpeg stringByDeletingLastPathComponent],
            url.absoluteString ?: @"",
            nil];

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:ytDLP];
        task.arguments = args;

        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;

        NSMutableString *logBuffer = [NSMutableString string];
        __block double lastMappedProgress = 0.08;
        __block BOOL sawFragmentedDownload = NO;
        NSFileHandle *readHandle = [pipe fileHandleForReading];
        readHandle.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *data = [handle availableData];
            if (data.length == 0) return;

            NSString *chunk = SpliceKitURLImportStringFromData(data);
            if (chunk.length == 0) return;

            @synchronized (logBuffer) {
                [logBuffer appendString:chunk];
            }

            NSArray<NSString *> *lines = [chunk componentsSeparatedByCharactersInSet:
                [NSCharacterSet newlineCharacterSet]];
            for (NSString *rawLine in lines) {
                NSString *line = SpliceKitURLImportTrimmedString(rawLine);
                if (line.length == 0) continue;

                double percent = SpliceKitURLImportPercentFromLine(line);
                if (percent >= 0.0) {
                    double clamped = MIN(MAX(percent, 0.0), 100.0);
                    double mapped = 0.08 + clamped / 100.0 * 0.64;
                    if (progress && (mapped - lastMappedProgress >= 0.002 || mapped >= 0.72)) {
                        lastMappedProgress = mapped;
                        progress([NSString stringWithFormat:@"Downloading %@ media… %.1f%%",
                                  provider ?: @"provider", clamped],
                                 mapped);
                    }
                    continue;
                }

                NSString *lower = [line lowercaseString];
                if ([lower containsString:@"extracting url"] || [lower containsString:@"downloading webpage"]) {
                    if (progress) progress([NSString stringWithFormat:@"Resolving %@ stream...", provider ?: @"provider"], 0.05);
                } else if ([lower containsString:@"fragment"] ||
                           [lower containsString:@".part-frag"] ||
                           [lower containsString:@"hls"]) {
                    sawFragmentedDownload = YES;
                    double mapped = MIN(MAX(lastMappedProgress, 0.72) + 0.01, 0.79);
                    if (progress && mapped - lastMappedProgress >= 0.005) {
                        lastMappedProgress = mapped;
                        progress([NSString stringWithFormat:@"Downloading %@ media fragments...", provider ?: @"provider"],
                                 mapped);
                    }
                } else if ([lower containsString:@"recoding video"] ||
                           [lower containsString:@"post-process"] ||
                           [lower containsString:@"merging formats"]) {
                    lastMappedProgress = MAX(lastMappedProgress, 0.82);
                    if (progress) progress(@"Converting provider download to MP4...", lastMappedProgress);
                }
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
                job.resolverTask = nil;
            }

            if (job.cancelled) {
                completion(nil, resolvedTitle, nil, @"URL import was cancelled.");
                return;
            }

            NSString *fullLog = nil;
            @synchronized (logBuffer) {
                fullLog = [logBuffer copy];
            }
            NSString *trimmedLog = SpliceKitURLImportTrimmedString(fullLog);

            if (task.terminationStatus != 0) {
                NSString *detail = trimmedLog.length > 0
                    ? trimmedLog
                    : [NSString stringWithFormat:@"%@ download failed through yt-dlp.", provider ?: @"Provider"];
                SpliceKit_log(@"[URLImport] %@ download failed: %@", provider ?: @"Provider", detail);
                completion(nil, resolvedTitle, nil, detail);
                return;
            }

            NSString *downloadedFile = SpliceKitURLImportDownloadedFileMatchingPrefix(downloadsDir, prefix);
            if (downloadedFile.length == 0) {
                SpliceKit_log(@"[URLImport] %@ download completed but no file matched prefix %@", provider ?: @"Provider", prefix);
                completion(nil, resolvedTitle, nil,
                           @"yt-dlp finished, but SpliceKit could not locate the downloaded file in its cache.");
                return;
            }

            SpliceKit_log(@"[URLImport] %@ download complete: %@", provider ?: @"Provider", downloadedFile);
            if (progress) {
                double finalDownloadProgress = sawFragmentedDownload ? 0.84 : 0.76;
                progress(@"Provider download complete. Inspecting media...", finalDownloadProgress);
            }
            completion(nil, resolvedTitle, downloadedFile, nil);
        };

        NSError *launchError = nil;
        @synchronized (job) {
            job.resolverTask = task;
        }
        SpliceKit_log(@"[URLImport] Launching %@ download task via yt-dlp for %@",
                      provider ?: @"provider", url.absoluteString ?: @"");
        if (![task launchAndReturnError:&launchError]) {
            readHandle.readabilityHandler = nil;
            @synchronized (job) {
                job.resolverTask = nil;
            }
            completion(nil,
                       resolvedTitle,
                       nil,
                       launchError.localizedDescription ?: @"Could not launch yt-dlp download task.");
            return;
        }
    });
}

@implementation SpliceKitDirectFileResolver

- (NSString *)sourceType { return @"direct_file"; }

- (BOOL)canResolveURL:(NSURL *)url {
    NSString *ext = [[url pathExtension] lowercaseString];
    return SpliceKitURLImportIsDirectMediaExtension(ext);
}

- (void)resolveURL:(NSURL *)url
               job:(SpliceKitURLImportJob *)job
          progress:(SpliceKitURLImportResolverProgressBlock)progress
        completion:(SpliceKitURLImportResolverCompletionBlock)completion {
    (void)job;
    (void)progress;
    NSString *candidate = [[url lastPathComponent] stringByDeletingPathExtension];
    completion(url, candidate, nil, nil);
}

@end

@implementation SpliceKitYouTubeResolver

- (NSString *)sourceType { return @"youtube"; }

- (BOOL)canResolveURL:(NSURL *)url {
    NSString *host = [[url host] lowercaseString];
    return [host containsString:@"youtube.com"] || [host containsString:@"youtu.be"];
}

- (void)resolveURL:(NSURL *)url
               job:(SpliceKitURLImportJob *)job
          progress:(SpliceKitURLImportResolverProgressBlock)progress
        completion:(SpliceKitURLImportResolverCompletionBlock)completion {
    SpliceKitURLImportResolveProviderURL(@"YouTube", url, job, progress, completion);
}

@end

@implementation SpliceKitVimeoResolver

- (NSString *)sourceType { return @"vimeo"; }

- (BOOL)canResolveURL:(NSURL *)url {
    NSString *host = [[url host] lowercaseString];
    return [host containsString:@"vimeo.com"];
}

- (void)resolveURL:(NSURL *)url
               job:(SpliceKitURLImportJob *)job
          progress:(SpliceKitURLImportResolverProgressBlock)progress
        completion:(SpliceKitURLImportResolverCompletionBlock)completion {
    SpliceKitURLImportResolveProviderURL(@"Vimeo", url, job, progress, completion);
}

@end
