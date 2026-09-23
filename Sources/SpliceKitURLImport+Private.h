//
//  SpliceKitURLImport+Private.h
//  Private declarations shared by SpliceKitURLImport.m and its companion files
//  (SpliceKitURLImport*.m): the job, resolver and service interfaces, and the
//  service category methods called from another file.
//  The functions and variables below were file-static before SpliceKitURLImport.m
//  was split. They are declared hidden so they stay out of the dylib's exported symbols.
//

#ifndef SpliceKitURLImport_Private_h
#define SpliceKitURLImport_Private_h

// The imports SpliceKitURLImport.m has always been compiled with.
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

@interface SpliceKitURLImportJob : NSObject
@property (nonatomic, copy) NSString *jobID;
@property (nonatomic, copy) NSString *sourceURL;
@property (nonatomic, copy) NSString *sourceType;
@property (nonatomic, copy) NSString *state;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, copy) NSString *targetEvent;
@property (nonatomic, copy) NSString *titleOverride;
@property (nonatomic, copy) NSString *clipName;
@property (nonatomic, copy) NSString *downloadPath;
@property (nonatomic, copy) NSString *normalizedPath;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) BOOL success;
@property (nonatomic, assign) BOOL imported;
@property (nonatomic, assign) BOOL timelineInserted;
@property (nonatomic, assign) BOOL transcoded;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL highestQuality;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, strong) NSDate *updatedAt;
@property (nonatomic, strong) NSTask *resolverTask;
@property (nonatomic, strong) NSURLSessionDownloadTask *downloadTask;
@property (nonatomic, strong) AVAssetExportSession *exportSession;
@property (nonatomic) dispatch_semaphore_t completionSemaphore;
- (NSDictionary *)snapshot;
- (BOOL)isFinished;
@end

typedef void (^SpliceKitURLImportResolverProgressBlock)(NSString *message, double progress);
typedef void (^SpliceKitURLImportResolverCompletionBlock)(NSURL *downloadURL,
                                                          NSString *resolvedTitle,
                                                          NSString *localPath,
                                                          NSString *errorMessage);

@protocol SpliceKitURLResolver <NSObject>
- (NSString *)sourceType;
- (BOOL)canResolveURL:(NSURL *)url;
- (void)resolveURL:(NSURL *)url
               job:(SpliceKitURLImportJob *)job
          progress:(SpliceKitURLImportResolverProgressBlock)progress
        completion:(SpliceKitURLImportResolverCompletionBlock)completion;
@end

@interface SpliceKitDirectFileResolver : NSObject <SpliceKitURLResolver>
@end

@interface SpliceKitYouTubeResolver : NSObject <SpliceKitURLResolver>
@end

@interface SpliceKitVimeoResolver : NSObject <SpliceKitURLResolver>
@end

@interface SpliceKitURLImportService : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SpliceKitURLImportJob *> *jobs;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *taskToJob;
@property (nonatomic, strong) NSArray<id<SpliceKitURLResolver>> *resolvers;
+ (instancetype)sharedService;
- (NSDictionary *)startImportWithParams:(NSDictionary *)params waitForCompletion:(BOOL)wait;
- (NSDictionary *)statusForJobID:(NSString *)jobID;
- (NSDictionary *)cancelJobID:(NSString *)jobID;
- (NSDictionary *)inspectMediaAtPath:(NSString *)path;
@end

#pragma GCC visibility push(hidden)

#pragma mark - Defined in SpliceKitURLImport.m

extern NSString * const SpliceKitURLImportStateNormalizing;
extern NSString * const SpliceKitURLImportStateImporting;
extern NSString * const SpliceKitURLImportStateInserting;
extern NSString * const SpliceKitURLImportStateCompleted;
extern NSString * const SpliceKitURLImportStateFailed;
extern NSString * const SpliceKitURLImportStateCancelled;
NSString *SpliceKitURLImportTrimmedString(id value);
NSString *SpliceKitURLImportSanitizeFilename(NSString *input);
NSString *SpliceKitURLImportEscapeXML(NSString *input);
BOOL SpliceKitURLImportIsDirectMediaExtension(NSString *extension);
NSString *SpliceKitURLImportSharedDownloadsDirectory(void);
NSString *SpliceKitURLImportSharedNormalizedDirectory(void);
BOOL SpliceKitURLImportPathIsWithinDirectory(NSString *path, NSString *directory);
NSArray<NSString *> *SpliceKitURLImportUniqueStrings(id base, NSArray<NSString *> *extras);
NSString *SpliceKitURLImportUniquePathForFilename(NSString *filename, NSString *directory);
NSString *SpliceKitURLImportYTDLPPath(void);
NSString *SpliceKitURLImportFFmpegPath(void);
NSString *SpliceKitURLImportFFprobePath(void);
NSString *SpliceKitURLImportStringFromData(NSData *data);

#pragma mark - Defined in SpliceKitURLImportMedia.m

FourCharCode SpliceKitURLImportVideoCodecType(AVAssetTrack *videoTrack);
FourCharCode SpliceKitURLImportAudioCodecType(AVAssetTrack *audioTrack);
NSString *SpliceKitURLImportFourCCString(FourCharCode code);
BOOL SpliceKitURLImportCanonicalFrameTimingForRate(double fps,
                                                   int *outTimescale,
                                                   int *outFrameTicks);
BOOL SpliceKitURLImportCanonicalFrameTimingForTrack(AVAssetTrack *videoTrack,
                                                    int *outTimescale,
                                                    int *outFrameTicks);
BOOL SpliceKitURLImportCMTimeMatchesRational(CMTime time, int value, int timescale);
BOOL SpliceKitURLImportNormalizationModeUsesStreamCopy(NSString *mode);
BOOL SpliceKitURLImportNormalizationModeNeedsTimestampRewrite(NSString *mode);
NSString *SpliceKitURLImportOutputExtensionForNormalizationMode(NSString *mode);
BOOL SpliceKitURLImportVideoCodecCanStreamCopyToMP4(NSString *codecName);
BOOL SpliceKitURLImportAudioCodecCanStreamCopyToMP4(NSString *codecName);
BOOL SpliceKitURLImportVideoCodecNeedsTimestampRewrite(NSString *codecName);
double SpliceKitURLImportParseFractionString(NSString *value);
NSString *SpliceKitURLImportCMTimeStringFromSeconds(double seconds, NSString *fallback);
NSDictionary *SpliceKitURLImportFFprobeJSONForPath(NSString *path, NSString **outError);

#pragma mark - Defined in SpliceKitURLImportRemux.m

NSURL *SpliceKitURLImportMaybeRewriteLocalFileURL(NSURL *fileURL,
                                                  NSString **outError);

#pragma GCC visibility pop

// Implemented in SpliceKitURLImport.m, called from another file.
@interface SpliceKitURLImportService ()
- (NSString *)normalizedDirectory;
- (void)updateJob:(SpliceKitURLImportJob *)job
            state:(NSString *)state
          message:(NSString *)message
         progress:(double)progress;
- (void)finishJob:(SpliceKitURLImportJob *)job
          success:(BOOL)success
            state:(NSString *)state
          message:(NSString *)message
            error:(NSString *)errorMessage;
- (NSString *)pathForFilename:(NSString *)filename directory:(NSString *)directory;
@end

// Implemented in SpliceKitURLImport+FinalCut.m, called from another file.
@interface SpliceKitURLImportService (FinalCut)
- (void)importJobIntoFinalCut:(SpliceKitURLImportJob *)job mediaInfo:(NSDictionary *)mediaInfo;
@end

// Implemented in SpliceKitURLImport+Normalize.m, called from another file.
@interface SpliceKitURLImportService (Normalize)
- (void)normalizeJob:(SpliceKitURLImportJob *)job;
@end

#endif /* SpliceKitURLImport_Private_h */
