//
//  SpliceKitURLImport.m
//  Native URL ingest pipeline for SpliceKit.
//

#import "SpliceKitURLImport.h"
#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/clonefile.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import "SpliceKitURLImport+Private.h"

#if defined(__x86_64__)
#define SPLICEKIT_URLIMPORT_STRET_MSG objc_msgSend_stret
#else
#define SPLICEKIT_URLIMPORT_STRET_MSG objc_msgSend
#endif

static NSString * const SpliceKitURLImportStateQueued = @"queued";
static NSString * const SpliceKitURLImportStateResolving = @"resolving";
static NSString * const SpliceKitURLImportStateDownloading = @"downloading";
NSString * const SpliceKitURLImportStateNormalizing = @"normalizing";
NSString * const SpliceKitURLImportStateImporting = @"importing";
NSString * const SpliceKitURLImportStateInserting = @"inserting";
NSString * const SpliceKitURLImportStateCompleted = @"completed";
NSString * const SpliceKitURLImportStateFailed = @"failed";
NSString * const SpliceKitURLImportStateCancelled = @"cancelled";

NSString *SpliceKitURLImportStringFromData(NSData *data);
static NSArray *SpliceKitURLImportArrayFromContainer(id value);

static NSString *SpliceKitURLImportString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSArray *SpliceKitURLImportArrayFromContainer(id value) {
    if (!value || value == (id)kCFNull) return @[];
    if ([value isKindOfClass:[NSArray class]]) return value;

    SEL allObjectsSel = NSSelectorFromString(@"allObjects");
    if ([value respondsToSelector:allObjectsSel]) {
        id allObjects = ((id (*)(id, SEL))objc_msgSend)(value, allObjectsSel);
        if ([allObjects isKindOfClass:[NSArray class]]) return allObjects;
    }

    SEL countSel = @selector(count);
    SEL objectAtIndexSel = @selector(objectAtIndex:);
    if ([value respondsToSelector:countSel] && [value respondsToSelector:objectAtIndexSel]) {
        NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(value, countSel);
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            id item = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(value, objectAtIndexSel, i);
            if (item) [items addObject:item];
        }
        return items;
    }

    return @[];
}

static NSString *SpliceKitURLImportDiagnosticString(id value) {
    if (!value || value == [NSNull null]) return @"";
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSString *message = SpliceKitURLImportString(value[@"message"]);
        if (message.length > 0) return message;
        if ([NSJSONSerialization isValidJSONObject:value]) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
            NSString *jsonString = SpliceKitURLImportStringFromData(json);
            if (jsonString.length > 0) return jsonString;
        }
    }
    if ([value isKindOfClass:[NSArray class]] && [NSJSONSerialization isValidJSONObject:value]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        NSString *jsonString = SpliceKitURLImportStringFromData(json);
        if (jsonString.length > 0) return jsonString;
    }
    NSString *description = [[value description] copy];
    return [description isKindOfClass:[NSString class]] ? description : @"";
}

NSString *SpliceKitURLImportTrimmedString(id value) {
    return [SpliceKitURLImportString(value)
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *SpliceKitURLImportNormalizeURLString(id value) {
    NSString *raw = SpliceKitURLImportTrimmedString(value);
    if (raw.length == 0) return @"";

    NSError *detectorError = nil;
    NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink
                                                               error:&detectorError];
    if (!detectorError && detector) {
        NSTextCheckingResult *match = [detector firstMatchInString:raw
                                                           options:0
                                                             range:NSMakeRange(0, raw.length)];
        if (match.URL.absoluteString.length > 0) {
            return match.URL.absoluteString;
        }
    }

    NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *joined = [NSMutableString string];
    for (NSString *part in parts) {
        if (part.length > 0) [joined appendString:part];
    }
    return [joined copy];
}

NSString *SpliceKitURLImportSanitizeFilename(NSString *input) {
    NSString *trimmed = SpliceKitURLImportTrimmedString(input);
    if (trimmed.length == 0) return @"Imported Clip";

    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>"];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:bad];
    NSString *joined = [[parts componentsJoinedByString:@"-"]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    while ([joined containsString:@"  "]) {
        joined = [joined stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    while ([joined containsString:@"--"]) {
        joined = [joined stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
    }

    if (joined.length == 0) return @"Imported Clip";
    return joined;
}

NSString *SpliceKitURLImportEscapeXML(NSString *input) {
    NSString *s = SpliceKitURLImportString(input);
    s = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    s = [s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    s = [s stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    s = [s stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
    return s;
}

static NSString *SpliceKitURLImportCMTimeString(CMTime time, NSString *fallback) {
    if (CMTIME_IS_VALID(time) && !CMTIME_IS_INDEFINITE(time) && time.timescale > 0 && time.value >= 0) {
        return [NSString stringWithFormat:@"%lld/%ds", time.value, time.timescale];
    }
    return fallback ?: @"2400/2400s";
}

BOOL SpliceKitURLImportIsDirectMediaExtension(NSString *extension) {
    static NSSet<NSString *> *allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowed = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"webm", @"mkv"]];
    });
    return [allowed containsObject:[extension lowercaseString]];
}

static NSString *SpliceKitURLImportEnsureDirectory(NSString *path) {
    if (path.length == 0) return @"";
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

static NSString *SpliceKitURLImportToolsDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/SpliceKit/tools"];
}

static NSString *SpliceKitURLImportSharedBaseDirectory(void) {
    return SpliceKitURLImportEnsureDirectory([NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/SpliceKit/URLImports"]);
}

NSString *SpliceKitURLImportSharedDownloadsDirectory(void) {
    return SpliceKitURLImportEnsureDirectory([SpliceKitURLImportSharedBaseDirectory()
        stringByAppendingPathComponent:@"downloads"]);
}

NSString *SpliceKitURLImportSharedNormalizedDirectory(void) {
    return SpliceKitURLImportEnsureDirectory([SpliceKitURLImportSharedBaseDirectory()
        stringByAppendingPathComponent:@"normalized"]);
}

BOOL SpliceKitURLImportPathIsWithinDirectory(NSString *path, NSString *directory) {
    NSString *standardPath = [SpliceKitURLImportTrimmedString(path) stringByStandardizingPath];
    NSString *standardDirectory = [SpliceKitURLImportTrimmedString(directory) stringByStandardizingPath];
    if (standardPath.length == 0 || standardDirectory.length == 0) return NO;
    if ([standardPath isEqualToString:standardDirectory]) return YES;
    NSString *prefix = [standardDirectory hasSuffix:@"/"]
        ? standardDirectory
        : [standardDirectory stringByAppendingString:@"/"];
    return [standardPath hasPrefix:prefix];
}

NSArray<NSString *> *SpliceKitURLImportUniqueStrings(id base, NSArray<NSString *> *extras) {
    NSMutableOrderedSet<NSString *> *values = [NSMutableOrderedSet orderedSet];
    for (id item in SpliceKitURLImportArrayFromContainer(base)) {
        if ([item isKindOfClass:[NSString class]] && ((NSString *)item).length > 0) {
            [values addObject:item];
        }
    }
    for (NSString *item in extras) {
        if (item.length > 0) {
            [values addObject:item];
        }
    }
    return values.array ?: @[];
}

NSString *SpliceKitURLImportUniquePathForFilename(NSString *filename, NSString *directory) {
    NSString *base = [[filename stringByDeletingPathExtension] copy];
    NSString *ext = [[filename pathExtension] lowercaseString];
    NSString *candidate = filename;
    NSInteger suffix = 1;

    while ([[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:candidate]]) {
        candidate = ext.length > 0
            ? [NSString stringWithFormat:@"%@-%ld.%@", base, (long)suffix, ext]
            : [NSString stringWithFormat:@"%@-%ld", base, (long)suffix];
        suffix++;
    }

    return [directory stringByAppendingPathComponent:candidate];
}

static void SpliceKitURLImportAddExecutableCandidate(NSMutableOrderedSet<NSString *> *candidates,
                                                     NSString *path) {
    NSString *trimmed = [SpliceKitURLImportTrimmedString(path) stringByStandardizingPath];
    if (trimmed.length > 0) [candidates addObject:trimmed];
}

static NSString *SpliceKitURLImportExecutablePath(NSArray<NSString *> *candidates) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

static NSString *SpliceKitURLImportExecutablePathFromLoginShell(NSString *name) {
    NSString *trimmedName = SpliceKitURLImportTrimmedString(name);
    if (trimmedName.length == 0) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableOrderedSet<NSString *> *shells = [NSMutableOrderedSet orderedSet];
    NSString *preferredShell = [NSProcessInfo processInfo].environment[@"SHELL"];
    if ([fm isExecutableFileAtPath:preferredShell]) {
        [shells addObject:[preferredShell stringByStandardizingPath]];
    }
    for (NSString *candidate in @[@"/bin/zsh", @"/bin/bash", @"/bin/sh"]) {
        if ([fm isExecutableFileAtPath:candidate]) [shells addObject:candidate];
    }

    NSString *command = [NSString stringWithFormat:@"command -v %@ 2>/dev/null || which %@ 2>/dev/null",
                         trimmedName, trimmedName];
    for (NSString *shellPath in shells) {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:shellPath];
        task.arguments = @[@"-lc", command];

        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;

        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            continue;
        }

        [task waitUntilExit];
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = SpliceKitURLImportStringFromData(data);
        NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]];
        for (NSString *line in lines) {
            NSString *resolved = [SpliceKitURLImportTrimmedString(line) stringByStandardizingPath];
            if ([fm isExecutableFileAtPath:resolved]) return resolved;
        }
    }

    return nil;
}

static NSString *SpliceKitURLImportDependencyPath(NSString *toolName,
                                                  NSString *overrideEnvVar) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];
    NSString *home = NSHomeDirectory();
    NSString *tools = SpliceKitURLImportToolsDirectory();

    SpliceKitURLImportAddExecutableCandidate(candidates,
        [NSProcessInfo processInfo].environment[overrideEnvVar]);
    SpliceKitURLImportAddExecutableCandidate(candidates,
        [tools stringByAppendingPathComponent:toolName]);

    NSString *processPath = [NSProcessInfo processInfo].environment[@"PATH"];
    for (NSString *directory in [processPath componentsSeparatedByString:@":"]) {
        NSString *trimmed = SpliceKitURLImportTrimmedString(directory);
        if (trimmed.length == 0) continue;
        SpliceKitURLImportAddExecutableCandidate(candidates,
            [trimmed stringByAppendingPathComponent:toolName]);
    }

    for (NSString *directory in @[
        [home stringByAppendingPathComponent:@".local/bin"],
        [home stringByAppendingPathComponent:@".pyenv/shims"],
        [home stringByAppendingPathComponent:@".asdf/shims"],
        [home stringByAppendingPathComponent:@".nix-profile/bin"],
        @"/nix/var/nix/profiles/default/bin",
        @"/opt/homebrew/bin",
        @"/usr/local/bin",
        @"/opt/local/bin",
        @"/usr/bin",
    ]) {
        SpliceKitURLImportAddExecutableCandidate(candidates,
            [directory stringByAppendingPathComponent:toolName]);
    }

    NSString *resolvedFromShell = SpliceKitURLImportExecutablePathFromLoginShell(toolName);
    if ([fm isExecutableFileAtPath:resolvedFromShell]) {
        SpliceKitURLImportAddExecutableCandidate(candidates, resolvedFromShell);
    }

    return SpliceKitURLImportExecutablePath(candidates.array);
}

NSString *SpliceKitURLImportYTDLPPath(void) {
    return SpliceKitURLImportDependencyPath(@"yt-dlp", @"SPLICEKIT_YTDLP_PATH");
}

NSString *SpliceKitURLImportFFmpegPath(void) {
    return SpliceKitURLImportDependencyPath(@"ffmpeg", @"SPLICEKIT_FFMPEG_PATH");
}

NSString *SpliceKitURLImportFFprobePath(void) {
    return SpliceKitURLImportDependencyPath(@"ffprobe", @"SPLICEKIT_FFPROBE_PATH");
}

NSString *SpliceKitURLImportStringFromData(NSData *data) {
    if (data.length == 0) return @"";
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length > 0) return string;
    string = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return string ?: @"";
}

@implementation SpliceKitURLImportJob

- (instancetype)init {
    self = [super init];
    if (self) {
        _createdAt = [NSDate date];
        _updatedAt = [NSDate date];
        _completionSemaphore = dispatch_semaphore_create(0);
        _state = SpliceKitURLImportStateQueued;
        _message = @"Queued";
    }
    return self;
}

- (NSDictionary *)snapshot {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"job_id"] = self.jobID ?: @"";
    result[@"success"] = @(self.success);
    result[@"state"] = SpliceKitURLImportDiagnosticString(self.state);
    result[@"progress"] = @((self.progress < 0.0) ? 0.0 : (self.progress > 1.0 ? 1.0 : self.progress));
    result[@"source_url"] = SpliceKitURLImportDiagnosticString(self.sourceURL);
    result[@"source_type"] = SpliceKitURLImportDiagnosticString(self.sourceType ?: @"unknown");
    result[@"mode"] = SpliceKitURLImportDiagnosticString(self.mode ?: @"import_only");
    result[@"target_event"] = SpliceKitURLImportDiagnosticString(self.targetEvent);
    result[@"title"] = SpliceKitURLImportDiagnosticString(self.clipName);
    result[@"download_path"] = SpliceKitURLImportDiagnosticString(self.downloadPath);
    result[@"normalized_path"] = SpliceKitURLImportDiagnosticString(self.normalizedPath);
    result[@"transcoded"] = @(self.transcoded);
    result[@"imported"] = @(self.imported);
    result[@"timeline_inserted"] = @(self.timelineInserted);
    result[@"message"] = SpliceKitURLImportDiagnosticString(self.message);
    result[@"created_at"] = @([self.createdAt timeIntervalSince1970]);
    result[@"updated_at"] = @([self.updatedAt timeIntervalSince1970]);
    NSString *errorText = SpliceKitURLImportDiagnosticString(self.errorMessage);
    if (errorText.length > 0) result[@"error"] = errorText;
    return result;
}

- (BOOL)isFinished {
    return [self.state isEqualToString:SpliceKitURLImportStateCompleted] ||
           [self.state isEqualToString:SpliceKitURLImportStateFailed] ||
           [self.state isEqualToString:SpliceKitURLImportStateCancelled];
}

@end

@implementation SpliceKitURLImportService

+ (instancetype)sharedService {
    static SpliceKitURLImportService *service = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [[self alloc] init];
    });
    return service;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.splicekit.urlimport.state", DISPATCH_QUEUE_SERIAL);
        _jobs = [NSMutableDictionary dictionary];
        _taskToJob = [NSMutableDictionary dictionary];
        _resolvers = @[
            [[SpliceKitDirectFileResolver alloc] init],
            [[SpliceKitYouTubeResolver alloc] init],
            [[SpliceKitVimeoResolver alloc] init],
        ];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 1800.0;
        config.HTTPMaximumConnectionsPerHost = 4;

        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegateQueue];
    }
    return self;
}

- (NSString *)baseDirectory {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/SpliceKit/URLImports"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

- (NSString *)downloadsDirectory {
    NSString *path = [[self baseDirectory] stringByAppendingPathComponent:@"downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

- (NSString *)normalizedDirectory {
    return SpliceKitURLImportSharedNormalizedDirectory();
}

- (void)updateJob:(SpliceKitURLImportJob *)job
            state:(NSString *)state
          message:(NSString *)message
         progress:(double)progress {
    dispatch_async(self.stateQueue, ^{
        NSString *safeState = SpliceKitURLImportDiagnosticString(state);
        NSString *safeMessage = SpliceKitURLImportDiagnosticString(message);
        if (safeState.length > 0) job.state = safeState;
        if (safeMessage.length > 0) job.message = safeMessage;
        if (progress >= 0.0) job.progress = progress;
        job.updatedAt = [NSDate date];
    });
}

- (void)finishJob:(SpliceKitURLImportJob *)job
          success:(BOOL)success
            state:(NSString *)state
          message:(NSString *)message
            error:(NSString *)errorMessage {
    dispatch_async(self.stateQueue, ^{
        job.success = success;
        NSString *safeState = SpliceKitURLImportDiagnosticString(state);
        NSString *safeMessage = SpliceKitURLImportDiagnosticString(message);
        NSString *safeError = SpliceKitURLImportDiagnosticString(errorMessage);
        job.state = safeState.length > 0
            ? safeState
            : (success ? SpliceKitURLImportStateCompleted : SpliceKitURLImportStateFailed);
        job.message = safeMessage.length > 0
            ? safeMessage
            : (success ? @"Completed" : @"Failed");
        job.errorMessage = safeError;
        job.progress = success ? 1.0 : job.progress;
        job.updatedAt = [NSDate date];
        dispatch_semaphore_signal(job.completionSemaphore);
    });
}

- (NSDictionary *)validationError:(NSString *)message {
    return @{@"success": @NO, @"error": message ?: @"Invalid request"};
}

- (NSString *)resolvedModeFromParams:(NSDictionary *)params {
    NSString *mode = [SpliceKitURLImportTrimmedString(params[@"mode"]) lowercaseString];
    NSString *timelineAction = [SpliceKitURLImportTrimmedString(params[@"timeline_action"]) lowercaseString];

    if (timelineAction.length > 0 && ![timelineAction isEqualToString:@"none"]) {
        if ([timelineAction isEqualToString:@"append"] ||
            [timelineAction isEqualToString:@"append_to_timeline"]) {
            return @"append_to_timeline";
        }
        if ([timelineAction isEqualToString:@"start"] ||
            [timelineAction isEqualToString:@"insert_at_start"] ||
            [timelineAction isEqualToString:@"insert_at_timeline_start"]) {
            return @"insert_at_timeline_start";
        }
        if ([timelineAction isEqualToString:@"insert"] ||
            [timelineAction isEqualToString:@"insert_at_playhead"]) {
            return @"insert_at_playhead";
        }
    }

    if ([mode isEqualToString:@"append"] || [mode isEqualToString:@"append_to_timeline"]) {
        return @"append_to_timeline";
    }
    if ([mode isEqualToString:@"start"] || [mode isEqualToString:@"insert_at_start"] ||
        [mode isEqualToString:@"insert_at_timeline_start"]) {
        return @"insert_at_timeline_start";
    }
    if ([mode isEqualToString:@"insert"] || [mode isEqualToString:@"insert_at_playhead"] ||
        [mode isEqualToString:@"timeline"]) {
        return @"insert_at_playhead";
    }
    return @"import_only";
}

- (id<SpliceKitURLResolver>)resolverForURL:(NSURL *)url {
    for (id<SpliceKitURLResolver> resolver in self.resolvers) {
        if ([resolver canResolveURL:url]) {
            return resolver;
        }
    }
    return nil;
}

- (NSString *)defaultClipNameForURL:(NSURL *)url titleOverride:(NSString *)titleOverride {
    if (titleOverride.length > 0) return SpliceKitURLImportSanitizeFilename(titleOverride);

    NSString *fromPath = [[url lastPathComponent] stringByDeletingPathExtension];
    if (fromPath.length > 0) return SpliceKitURLImportSanitizeFilename(fromPath);

    NSString *host = url.host ?: @"Imported Clip";
    return SpliceKitURLImportSanitizeFilename(host);
}

- (NSString *)pathForFilename:(NSString *)filename directory:(NSString *)directory {
    return SpliceKitURLImportUniquePathForFilename(filename, directory);
}

- (NSString *)filenameForJob:(SpliceKitURLImportJob *)job response:(NSURLResponse *)response {
    NSString *suggested = response.suggestedFilename ?: @"";
    NSString *ext = [[suggested pathExtension] lowercaseString];
    if (ext.length == 0) {
        ext = [[[NSURL URLWithString:job.sourceURL] pathExtension] lowercaseString];
    }
    if (ext.length == 0) ext = @"mp4";
    NSString *base = SpliceKitURLImportSanitizeFilename(job.clipName ?: @"Imported Clip");
    return [NSString stringWithFormat:@"%@.%@", base, ext];
}

- (NSDictionary *)inspectMediaAtPath:(NSString *)path {
    NSString *safePath = SpliceKitURLImportTrimmedString(path);
    if (safePath.length == 0) {
        SpliceKit_log(@"[URLImport] inspectMediaAtPath received an empty path");
        return @{@"error": @"Downloaded media did not produce a usable local file path"};
    }

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:safePath];
    if (!exists) {
        SpliceKit_log(@"[URLImport] inspectMediaAtPath missing file at %@", safePath);
        return @{@"error": @"Downloaded media file could not be found on disk"};
    }

    SpliceKit_log(@"[URLImport] Inspecting media at %@", safePath);

    NSString *ext = [[safePath pathExtension] lowercaseString];
    BOOL isMP4Family = [@[@"mp4", @"mov", @"m4v"] containsObject:ext];
    BOOL isMatroskaFamily = [@[@"mkv", @"webm"] containsObject:ext];
    if (isMatroskaFamily) {
        NSString *probeError = nil;
        NSDictionary *probe = SpliceKitURLImportFFprobeJSONForPath(safePath, &probeError);
        if (![probe isKindOfClass:[NSDictionary class]]) {
            return @{@"error": probeError ?: @"SpliceKit could not inspect this Matroska/WebM source."};
        }

        NSArray *streams = [probe[@"streams"] isKindOfClass:[NSArray class]] ? probe[@"streams"] : @[];
        NSDictionary *format = [probe[@"format"] isKindOfClass:[NSDictionary class]] ? probe[@"format"] : @{};
        NSDictionary *videoStream = nil;
        NSDictionary *audioStream = nil;
        for (id item in streams) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *stream = (NSDictionary *)item;
            NSString *codecType = SpliceKitURLImportTrimmedString(stream[@"codec_type"]).lowercaseString;
            if (!videoStream && [codecType isEqualToString:@"video"]) {
                videoStream = stream;
            } else if (!audioStream && [codecType isEqualToString:@"audio"]) {
                audioStream = stream;
            }
        }

        if (!videoStream && !audioStream) {
            return @{@"error": @"Matroska/WebM source has no readable audio or video streams."};
        }

        NSString *videoCodecName = SpliceKitURLImportTrimmedString(videoStream[@"codec_name"]).lowercaseString;
        NSString *audioCodecName = SpliceKitURLImportTrimmedString(audioStream[@"codec_name"]).lowercaseString;
        BOOL videoCanStreamCopy = (videoStream != nil) &&
            SpliceKitURLImportVideoCodecCanStreamCopyToMP4(videoCodecName);
        BOOL audioCanStreamCopy = (audioStream == nil) ||
            SpliceKitURLImportAudioCodecCanStreamCopyToMP4(audioCodecName);
        // The shadow-MP4 path can always handle audio — if the codec can't
        // stream-copy into MP4, we transcode just the audio track to AAC and
        // still stream-copy the video. The gating decision is therefore on the
        // video side only.
        BOOL canStreamCopyToMP4 = videoCanStreamCopy;

        double fps = SpliceKitURLImportParseFractionString(videoStream[@"avg_frame_rate"]);
        if (!(fps > 0.0)) {
            fps = SpliceKitURLImportParseFractionString(videoStream[@"r_frame_rate"]);
        }

        int canonicalTimescale = 0;
        int canonicalFrameTicks = 0;
        BOOL hasCanonicalTiming = SpliceKitURLImportCanonicalFrameTimingForRate(fps,
                                                                                &canonicalTimescale,
                                                                                &canonicalFrameTicks);
        BOOL frameTimingLooksCanonical = hasCanonicalTiming &&
            fabs(fps - ((double)canonicalTimescale / (double)canonicalFrameTicks)) <= 0.05;

        NSString *duration = SpliceKitURLImportCMTimeStringFromSeconds([format[@"duration"] doubleValue],
                                                                       @"2400/2400s");
        NSString *frameDuration = hasCanonicalTiming
            ? [NSString stringWithFormat:@"%d/%ds", canonicalFrameTicks, canonicalTimescale]
            : @"100/2400s";

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"duration"] = duration;
        info[@"width"] = @([videoStream[@"width"] intValue] ?: 1920);
        info[@"height"] = @([videoStream[@"height"] intValue] ?: 1080);
        info[@"frameDuration"] = frameDuration;
        info[@"hasVideo"] = @(videoStream != nil);
        info[@"hasAudio"] = @(audioStream != nil);
        info[@"audioRate"] = @([audioStream[@"sample_rate"] intValue]);
        info[@"videoCodec"] = videoCodecName ?: @"";
        if (audioCodecName.length > 0) info[@"audioCodec"] = audioCodecName;
        if (canonicalTimescale > 0) info[@"canonicalFrameTimescale"] = @(canonicalTimescale);
        if (canonicalFrameTicks > 0) info[@"canonicalFrameTicks"] = @(canonicalFrameTicks);
        info[@"frameTimingLooksCanonical"] = @(frameTimingLooksCanonical);
        info[@"canStreamCopyToMP4"] = @(canStreamCopyToMP4);
        info[@"audioCanStreamCopy"] = @(audioCanStreamCopy);

        if (canStreamCopyToMP4) {
            info[@"requiresNormalization"] = @YES;
            BOOL rewriteTimestamps = hasCanonicalTiming &&
                SpliceKitURLImportVideoCodecNeedsTimestampRewrite(videoCodecName);
            // Matroska + VP9/VP8: ALWAYS rewrite timestamps to canonical CFR
            // rather than trusting avg_frame_rate to be representative.
            // MKV packets are typically millisecond-quantized, so individual
            // frame deltas alternate (42ms, 41ms, 42ms, ...) even when the
            // average looks like a clean 24000/1001. If we just stream-copy
            // those timestamps into MP4 (time_base ends up 1/16000), FCP
            // plays back with visible pacing artifacts. The setts bsf gives
            // us a proper 24000/1001 time_base with uniform deltas.
            // Other codecs (h264/hevc/av1) get the clean MP4 time_base from
            // ffmpeg's muxer directly; running setts on them would risk
            // breaking B-frame DTS ordering.
            info[@"normalizationMode"] = rewriteTimestamps
                ? @"remux_copy_rewrite_timestamps"
                : @"remux_copy";
        } else {
            info[@"requiresNormalization"] = @YES;
            info[@"normalizationMode"] = @"transcode";
        }
        return info;
    }

    NSURL *url = [NSURL fileURLWithPath:safePath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    CMTime duration = asset.duration;

    if (!CMTIME_IS_VALID(duration) || CMTIME_IS_INDEFINITE(duration) || duration.timescale <= 0 || duration.value <= 0) {
        return @{@"error": @"Downloaded media has no readable duration"};
    }

    AVAssetTrack *videoTrack = videoTracks.firstObject;
    AVAssetTrack *audioTrack = audioTracks.firstObject;
    BOOL requiresNormalization = !isMP4Family;
    NSString *normalizationMode = requiresNormalization ? @"transcode" : @"none";

    int width = 1920;
    int height = 1080;
    NSString *frameDuration = @"100/2400s";
    FourCharCode videoCodecType = SpliceKitURLImportVideoCodecType(videoTrack);
    NSString *videoCodec = SpliceKitURLImportFourCCString(videoCodecType);
    FourCharCode audioCodecType = SpliceKitURLImportAudioCodecType(audioTrack);
    NSString *audioCodec = SpliceKitURLImportFourCCString(audioCodecType);
    int canonicalTimescale = 0;
    int canonicalFrameTicks = 0;
    BOOL frameTimingLooksCanonical = NO;
    NSString *audioCodecLower = audioCodec.lowercaseString ?: @"";
    BOOL audioIsAACOrAbsent = (audioTrack == nil) ||
        [audioCodecLower containsString:@"aac"] ||
        [audioCodecLower isEqualToString:@"mp4a"];
    BOOL canStreamCopyToMP4 = (videoCodecType == 'vp09' || videoCodecType == 'vp08') &&
        audioIsAACOrAbsent;

    // MP4 muxed with the `hev1` sample-entry tag (parameter sets inline in the
    // bitstream) refuses to decode in AVFoundation / Final Cut / QuickTime —
    // Apple's stack only accepts `hvc1` (parameter sets in the extradata).
    // When we see hev1 in an MP4, flag it for stream-copy remux with the
    // existing `-tag:v hvc1` path. No timestamp rewrite: the source MP4 already
    // has clean sample-table timestamps, unlike Matroska.
    BOOL videoIsHEV1Tagged = isMP4Family && (videoCodecType == 'hev1');
    if (videoIsHEV1Tagged) {
        requiresNormalization = YES;
        normalizationMode = @"remux_copy";
        canStreamCopyToMP4 = YES;
    }

    if (videoTrack) {
        CGSize size = CGSizeApplyAffineTransform(videoTrack.naturalSize, videoTrack.preferredTransform);
        width = (int)fabs(size.width);
        height = (int)fabs(size.height);
        if (width <= 0) width = 1920;
        if (height <= 0) height = 1080;

        CMTime minFrameDuration = videoTrack.minFrameDuration;
        if (CMTIME_IS_VALID(minFrameDuration) && !CMTIME_IS_INDEFINITE(minFrameDuration) &&
            minFrameDuration.value > 0 && minFrameDuration.timescale > 0) {
            frameDuration = SpliceKitURLImportCMTimeString(minFrameDuration, frameDuration);
        } else if (videoTrack.nominalFrameRate > 0.0f) {
            int timescale = 2400;
            int value = (int)lrint((double)timescale / videoTrack.nominalFrameRate);
            if (value > 0) {
                frameDuration = [NSString stringWithFormat:@"%d/%ds", value, timescale];
            }
        }

        if (SpliceKitURLImportCanonicalFrameTimingForTrack(videoTrack,
                                                           &canonicalTimescale,
                                                           &canonicalFrameTicks) &&
            (videoCodecType == 'vp09' || videoCodecType == 'vp08')) {
            frameDuration = [NSString stringWithFormat:@"%d/%ds",
                             canonicalFrameTicks,
                             canonicalTimescale];
            frameTimingLooksCanonical = SpliceKitURLImportCMTimeMatchesRational(minFrameDuration,
                                                                                canonicalFrameTicks,
                                                                                canonicalTimescale);
            if (isMatroskaFamily && canStreamCopyToMP4) {
                requiresNormalization = YES;
                normalizationMode = frameTimingLooksCanonical
                    ? @"remux_copy"
                    : @"remux_copy_rewrite_timestamps";
            } else if (isMP4Family && !frameTimingLooksCanonical) {
                requiresNormalization = YES;
                normalizationMode = @"rewrite_timestamps";
            }
        }
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"duration"] = SpliceKitURLImportCMTimeString(duration, @"2400/2400s");
    info[@"width"] = @(width);
    info[@"height"] = @(height);
    info[@"frameDuration"] = frameDuration;
    info[@"hasVideo"] = @(videoTrack != nil);
    info[@"hasAudio"] = @(audioTrack != nil);
    info[@"audioRate"] = @(audioTrack ? 48000 : 0);
    info[@"requiresNormalization"] = @(requiresNormalization);
    info[@"normalizationMode"] = normalizationMode;
    if (videoCodec.length > 0) info[@"videoCodec"] = videoCodec;
    if (audioCodec.length > 0) info[@"audioCodec"] = audioCodec;
    if (canonicalTimescale > 0) info[@"canonicalFrameTimescale"] = @(canonicalTimescale);
    if (canonicalFrameTicks > 0) info[@"canonicalFrameTicks"] = @(canonicalFrameTicks);
    info[@"frameTimingLooksCanonical"] = @(frameTimingLooksCanonical);
    info[@"canStreamCopyToMP4"] = @(canStreamCopyToMP4);
    return info;
}

- (void)beginDownloadForJob:(SpliceKitURLImportJob *)job downloadURL:(NSURL *)downloadURL {
    [self updateJob:job state:SpliceKitURLImportStateDownloading
            message:@"Downloading media..."
           progress:0.05];
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:downloadURL];
    dispatch_async(self.stateQueue, ^{
        job.downloadTask = task;
        self.taskToJob[@(task.taskIdentifier)] = job.jobID;
    });
    [task resume];
}

- (NSDictionary *)startImportWithParams:(NSDictionary *)params waitForCompletion:(BOOL)wait {
    NSString *rawURLString = SpliceKitURLImportTrimmedString(params[@"url"]);
    NSString *urlString = SpliceKitURLImportNormalizeURLString(params[@"url"]);
    if (urlString.length == 0) return [self validationError:@"url parameter required"];
    if (rawURLString.length > 0 && ![rawURLString isEqualToString:urlString]) {
        SpliceKit_log(@"[URLImport] Normalized pasted URL from '%@' to '%@'", rawURLString, urlString);
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || url.scheme.length == 0 || url.host.length == 0) {
        return [self validationError:@"Invalid URL. Provide a full https:// or http:// media URL."];
    }

    id<SpliceKitURLResolver> resolver = [self resolverForURL:url];
    if (!resolver) {
        return [self validationError:
            @"Unsupported URL source. This build supports direct .mp4/.mov/.m4v/.webm/.mkv links plus YouTube and Vimeo URLs through yt-dlp."];
    }

    SpliceKitURLImportJob *job = [[SpliceKitURLImportJob alloc] init];
    job.jobID = [[NSUUID UUID] UUIDString];
    job.sourceURL = urlString;
    job.sourceType = [resolver sourceType];
    job.mode = [self resolvedModeFromParams:params];
    job.targetEvent = SpliceKitURLImportTrimmedString(params[@"target_event"]);
    job.titleOverride = SpliceKitURLImportTrimmedString(params[@"title"]);
    job.highestQuality = [params[@"highest_quality"] boolValue];
    job.clipName = [self defaultClipNameForURL:url titleOverride:job.titleOverride];
    job.progress = 0.01;
    job.message = @"Resolving URL...";
    job.state = SpliceKitURLImportStateResolving;

    dispatch_sync(self.stateQueue, ^{
        self.jobs[job.jobID] = job;
    });

    [resolver resolveURL:url
                     job:job
                progress:^(NSString *message, double progress) {
                    NSString *state = SpliceKitURLImportStateResolving;
                    NSString *lowerMessage = [SpliceKitURLImportString(message) lowercaseString];
                    if ([lowerMessage containsString:@"downloading"]) {
                        state = SpliceKitURLImportStateDownloading;
                    } else if ([lowerMessage containsString:@"converting"] ||
                               [lowerMessage containsString:@"normalizing"] ||
                               [lowerMessage containsString:@"inspecting media"]) {
                        state = SpliceKitURLImportStateNormalizing;
                    }
                    [self updateJob:job
                              state:state
                            message:message
                           progress:progress];
                }
              completion:^(NSURL *downloadURL,
                           NSString *resolvedTitle,
                           NSString *localPath,
                           NSString *errorMessage) {
        if (job.cancelled) return;

        if (errorMessage.length > 0 || (!downloadURL && localPath.length == 0)) {
            [self finishJob:job
                    success:NO
                      state:SpliceKitURLImportStateFailed
                    message:@"Could not resolve the media URL."
                      error:errorMessage ?: @"Resolver returned no download URL."];
            return;
        }

        if (resolvedTitle.length > 0 && job.titleOverride.length == 0) {
            job.clipName = SpliceKitURLImportSanitizeFilename(resolvedTitle);
        }

        if (localPath.length > 0) {
            job.downloadPath = localPath;
            if (job.titleOverride.length == 0) {
                NSString *downloadName = [[localPath lastPathComponent] stringByDeletingPathExtension];
                if (downloadName.length > 0) {
                    job.clipName = SpliceKitURLImportSanitizeFilename(downloadName);
                }
            }
            [self updateJob:job
                      state:SpliceKitURLImportStateNormalizing
                    message:@"Download complete. Inspecting media..."
                   progress:0.78];
            [self normalizeJob:job];
            return;
        }

        [self beginDownloadForJob:job downloadURL:downloadURL];
    }];

    if (!wait) {
        return [job snapshot];
    }

    NSTimeInterval timeout = 900.0;
    NSNumber *timeoutNum = params[@"timeout_seconds"];
    if ([timeoutNum respondsToSelector:@selector(doubleValue)] && [timeoutNum doubleValue] > 0) {
        timeout = [timeoutNum doubleValue];
    }

    long waitResult = dispatch_semaphore_wait(job.completionSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (waitResult != 0) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Timed out waiting for URL import to finish."
                  error:@"Timed out waiting for URL import to finish."];
    }
    return [self statusForJobID:job.jobID];
}

- (NSDictionary *)statusForJobID:(NSString *)jobID {
    __block NSDictionary *snapshot = nil;
    dispatch_sync(self.stateQueue, ^{
        SpliceKitURLImportJob *job = self.jobs[jobID];
        snapshot = job ? [job snapshot] : nil;
    });
    return snapshot ?: @{@"success": @NO, @"error": @"Unknown job_id"};
}

- (NSDictionary *)cancelJobID:(NSString *)jobID {
    __block NSDictionary *snapshot = nil;
    dispatch_sync(self.stateQueue, ^{
        SpliceKitURLImportJob *job = self.jobs[jobID];
        if (!job) {
            snapshot = @{@"success": @NO, @"error": @"Unknown job_id"};
            return;
        }

        job.cancelled = YES;
        @synchronized (job) {
            if (job.resolverTask) {
                [job.resolverTask terminate];
                job.resolverTask = nil;
            }
            if (job.downloadTask) {
                [job.downloadTask cancel];
                job.downloadTask = nil;
            }
            if (job.exportSession) {
                [job.exportSession cancelExport];
                job.exportSession = nil;
            }
        }
        if (![job isFinished]) {
            job.state = SpliceKitURLImportStateCancelled;
            job.message = @"Cancelled";
            job.updatedAt = [NSDate date];
            dispatch_semaphore_signal(job.completionSemaphore);
        }
        snapshot = [job snapshot];
    });
    return snapshot;
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didWriteData:(int64_t)bytesWritten
totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session;
    __block SpliceKitURLImportJob *job = nil;
    dispatch_sync(self.stateQueue, ^{
        NSString *jobID = self.taskToJob[@(downloadTask.taskIdentifier)];
        job = jobID ? self.jobs[jobID] : nil;
    });
    if (!job || totalBytesExpectedToWrite <= 0) return;

    double fraction = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
    double progress = 0.05 + MIN(MAX(fraction, 0.0), 1.0) * 0.65;
    NSString *message = [NSString stringWithFormat:@"Downloading media... %.0f%%", fraction * 100.0];
    [self updateJob:job state:SpliceKitURLImportStateDownloading message:message progress:progress];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    (void)session;
    __block SpliceKitURLImportJob *job = nil;
    dispatch_sync(self.stateQueue, ^{
        NSString *jobID = self.taskToJob[@(downloadTask.taskIdentifier)];
        job = jobID ? self.jobs[jobID] : nil;
        [self.taskToJob removeObjectForKey:@(downloadTask.taskIdentifier)];
        if (job) job.downloadTask = nil;
    });
    if (!job || job.cancelled) return;

    NSString *filename = [self filenameForJob:job response:downloadTask.response];
    NSString *destinationPath = [self pathForFilename:filename directory:[self downloadsDirectory]];
    NSError *moveError = nil;
    [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];
    [[NSFileManager defaultManager] moveItemAtURL:location
                                            toURL:[NSURL fileURLWithPath:destinationPath]
                                            error:&moveError];
    if (moveError) {
        [self finishJob:job
                success:NO
                  state:SpliceKitURLImportStateFailed
                message:@"Downloaded file could not be moved into the SpliceKit cache."
                  error:moveError.localizedDescription];
        return;
    }

    job.downloadPath = destinationPath;
    if (job.titleOverride.length == 0) {
        NSString *downloadName = [[destinationPath lastPathComponent] stringByDeletingPathExtension];
        if (downloadName.length > 0) {
            job.clipName = SpliceKitURLImportSanitizeFilename(downloadName);
        }
    }

    [self normalizeJob:job];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    if (!error) return;

    __block SpliceKitURLImportJob *job = nil;
    dispatch_sync(self.stateQueue, ^{
        NSString *jobID = self.taskToJob[@(task.taskIdentifier)];
        job = jobID ? self.jobs[jobID] : nil;
        [self.taskToJob removeObjectForKey:@(task.taskIdentifier)];
        if (job) job.downloadTask = nil;
    });
    if (!job || [job isFinished]) return;

    NSString *state = (error.code == NSURLErrorCancelled || job.cancelled)
        ? SpliceKitURLImportStateCancelled
        : SpliceKitURLImportStateFailed;
    NSString *message = [state isEqualToString:SpliceKitURLImportStateCancelled]
        ? @"URL import was cancelled."
        : @"Download failed.";
    [self finishJob:job
            success:NO
              state:state
            message:message
              error:[state isEqualToString:SpliceKitURLImportStateCancelled] ? nil : error.localizedDescription];
}

@end

NSDictionary *SpliceKitURLImport_start(NSDictionary *params) {
    return [[SpliceKitURLImportService sharedService] startImportWithParams:params waitForCompletion:NO];
}

NSDictionary *SpliceKitURLImport_importSync(NSDictionary *params) {
    return [[SpliceKitURLImportService sharedService] startImportWithParams:params waitForCompletion:YES];
}

NSDictionary *SpliceKitURLImport_status(NSDictionary *params) {
    NSString *jobID = SpliceKitURLImportTrimmedString(params[@"job_id"]);
    if (jobID.length == 0) return @{@"success": @NO, @"error": @"job_id parameter required"};
    return [[SpliceKitURLImportService sharedService] statusForJobID:jobID];
}

NSDictionary *SpliceKitURLImport_cancel(NSDictionary *params) {
    NSString *jobID = SpliceKitURLImportTrimmedString(params[@"job_id"]);
    if (jobID.length == 0) return @{@"success": @NO, @"error": @"job_id parameter required"};
    return [[SpliceKitURLImportService sharedService] cancelJobID:jobID];
}

NSURL *SpliceKitURLImport_CopyShadowURL(NSURL *fileURL, NSString **outError) {
    return SpliceKitURLImportMaybeRewriteLocalFileURL(fileURL, outError);
}
