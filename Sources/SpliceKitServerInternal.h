//
//  SpliceKitServerInternal.h
//  SpliceKit - Declarations shared between SpliceKitServer.m and its companion files
//  (SpliceKitServer*.m, SpliceKitFeature*.m). Only the bridge server's own files import
//  this; other files use SpliceKit.h and SpliceKitServerHandlers.h. The plugin method
//  registry the dispatcher falls back to is declared in SpliceKitPlugins.h.
//
//  The functions and variables below were file-static before SpliceKitServer.m was
//  split. They are declared hidden so they stay out of the dylib's exported symbols.
//

#ifndef SpliceKitServerInternal_h
#define SpliceKitServerInternal_h

// The imports SpliceKitServer.m has always been compiled with, shared so that every
// piece of the server sees the same declarations.
#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitLogPanel.h"
#import "SpliceKitTranscriptPanel.h"
#import "SpliceKitCaptionPanel.h"
#import "SpliceKitCommandPalette.h"
#import "SpliceKitDebugUI.h"
#import "SpliceKitLua.h"
#import "SpliceKitURLImport.h"
#import "SpliceKitAudioLevels.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <mach/thread_info.h>
#include <mach/thread_act.h>
#include <signal.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <objc/message.h>

// On x86_64, returning a struct larger than 16 bytes from objc_msgSend requires
// the _stret variant. ARM64 doesn't have this distinction — all structs go
// through the regular objc_msgSend. We build universal, so handle both.
#if defined(__x86_64__)
#define STRET_MSG objc_msgSend_stret
#else
#define STRET_MSG objc_msgSend
#endif

//
// We define our own CMTime/CMTimeRange structs so we can read them from
// objc_msgSend return values without importing CoreMedia headers (which
// would create a link dependency we don't want in a dylib).
// The layout matches Apple's — we just need the fields for serialization.
//

typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } SpliceKit_CMTime;
typedef struct { SpliceKit_CMTime start; SpliceKit_CMTime duration; } SpliceKit_CMTimeRange;

#pragma GCC visibility push(hidden)

#pragma mark - Defined in SpliceKitServer.m

NSArray *SpliceKit_browserClipsOfEvent(id event);
id SpliceKit_getSelectedTimelineItem(id timeline);
id SpliceKit_getSelectedClipEffectStack(id timeline, id *outClip);
NSArray<id> *SpliceKit_keyframeTargetsForClip(id clip);
NSDictionary *SpliceKit_removeAllKeyframesFromEffectStack(id effectStack, NSString *actionName);
void SpliceKit_collectTitleText(id folder, NSMutableArray *results, int depth);
NSString *SpliceKit_readClipRole(id clip);
NSArray *SpliceKit_mixerArrayFromContainer(id value);
BOOL SpliceKit_mixerIsCollectionLike(id item);
BOOL SpliceKit_mixerIsSkippableItem(id item);
NSDictionary *SpliceKit_handleCaptureViewer(NSDictionary *params);
NSDictionary *SpliceKit_describeWindow(NSWindow *window);
double SpliceKit_quantizeSecondsToFrameGrid(double seconds, double frameSeconds);
id SpliceKit_findSequenceNamedInActiveLibraries(NSString *projectName);
NSArray *SpliceKit_allMotionTitleCandidatesOnSequence(id sequence);
NSArray *SpliceKit_allCaptionsOnSequence(id sequence);

#pragma mark - Defined in SpliceKitServerUtil.m

extern NSMutableDictionary<NSString *, id> *sHandleMap;
NSString *SpliceKit_handlePointerKey(id object);
double SpliceKit_secondsSinceLoad(void);
uint64_t SpliceKit_handleGeneration(void);
NSDictionary *SpliceKit_serializeCMTime(SpliceKit_CMTime t);
id SpliceKit_serializeReturnValue(NSInvocation *invocation, BOOL returnHandle);

#pragma mark - Defined in SpliceKitServerRuntime.m

NSDictionary *SpliceKit_handleSystemGetClasses(NSDictionary *params);
NSDictionary *SpliceKit_handleSystemGetMethods(NSDictionary *params);
NSDictionary *SpliceKit_handleSystemCallMethod(NSDictionary *params);
NSDictionary *SpliceKit_handleSystemVersion(NSDictionary *params);
NSDictionary *SpliceKit_handleSystemSwizzle(NSDictionary *params);
NSDictionary *SpliceKit_handleSystemGetProperties(NSDictionary *params);
NSDictionary *SpliceKit_handleSystemGetProtocols(NSDictionary *params);
NSDictionary *SpliceKit_handleSystemGetSuperchain(NSDictionary *params);
NSDictionary *SpliceKit_handleSystemGetIvars(NSDictionary *params);
id SpliceKit_resolveTarget(NSDictionary *params);
NSDictionary *SpliceKit_handleCallMethodWithArgs(NSDictionary *params);
NSDictionary *SpliceKit_handleObjectGet(NSDictionary *params);
NSDictionary *SpliceKit_handleObjectRelease(NSDictionary *params);
NSDictionary *SpliceKit_handleObjectList(NSDictionary *params);
NSDictionary *SpliceKit_handleGetProperty(NSDictionary *params);
NSDictionary *SpliceKit_handleSetProperty(NSDictionary *params);

#pragma mark - Defined in SpliceKitServerRuntimeExport.m

NSDictionary *SpliceKit_handleDumpRuntimeMetadata(NSDictionary *params);
NSDictionary *SpliceKit_handleListLoadedImages(NSDictionary *params);
NSDictionary *SpliceKit_handleGetImageSections(NSDictionary *params);
NSDictionary *SpliceKit_handleGetImageSymbols(NSDictionary *params);
NSDictionary *SpliceKit_handleGetNotificationNames(NSDictionary *params);

#pragma mark - Defined in SpliceKitServerDebug.m

NSDictionary *SpliceKit_handleDebugGetConfig(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugSetConfig(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugResetConfig(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugStartFramerateMonitor(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugStopFramerateMonitor(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugEnablePreset(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugTraceMethod(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugWatch(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugCrashHandler(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugThreads(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugEval(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugLoadPlugin(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugObserveNotification(NSDictionary *params);
NSDictionary *SpliceKit_handleDebugBreakpoint(NSDictionary *params);

#pragma mark - Defined in SpliceKitFeatureViewerZoom.m

NSDictionary *SpliceKit_handleViewerGetZoom(NSDictionary *params);
NSDictionary *SpliceKit_handleViewerSetZoom(NSDictionary *params);

#pragma mark - Defined in SpliceKitFeatureFreezeExtend.m

extern BOOL sFreezeExtendPendingAutoAccept;
extern BOOL sFreezeExtendDidApply;
void SpliceKit_armTransitionAlertAutoAccept(void);
double SpliceKit_transitionFrameDurationSeconds(id timeline);
double SpliceKit_transitionCurrentTimeSeconds(id timeline);
BOOL SpliceKit_transitionSeekToSeconds(id timeline, double seconds);
BOOL SpliceKit_sendTimelineSimpleAction(id timeline, NSString *selectorName);
NSUInteger SpliceKit_transitionCount(id timeline);
void SpliceKit_clearFreezeExtendTransientState(void);
BOOL SpliceKit_waitForTransitionInsertion(id timeline, NSUInteger previousCount,
                                          NSTimeInterval timeoutSeconds);

#pragma mark - Defined in SpliceKitFeatureEffectDrag.m

Class SpliceKit_findLoadedClassNamed(const char *wantedName);
id SpliceKit_effectDragVideoEffectsTarget(id clip);

#pragma mark - Defined in SpliceKitFeatureToggles.m

NSDictionary *SpliceKit_handleOptionsGet(NSDictionary *params);
NSDictionary *SpliceKit_handleOptionsSet(NSDictionary *params);

#pragma mark - Defined in SpliceKitServerTimelineRead.m

BOOL SpliceKit_selectorReturnsBOOL(id obj, SEL sel);
BOOL SpliceKit_selectorReturnsObject(id obj, SEL sel);
BOOL SpliceKit_tryReadBoolSelector(id obj, NSString *name, BOOL *out);
NSString *SpliceKit_itemContainerKind(id item);
BOOL SpliceKit_itemIsMulticamClip(id item);
BOOL SpliceKit_tryReadCMTimeSelector(id obj, NSString *name, SpliceKit_CMTime *out);
BOOL SpliceKit_tryReadCMTimeRangeSelector(id obj, NSString *name, SpliceKit_CMTimeRange *out);
NSString *SpliceKit_tryReadStringSelector(id obj, NSString *name);
SpliceKit_CMTime SpliceKit_endTimeForRange(SpliceKit_CMTimeRange range);
SpliceKit_CMTime SpliceKit_timeFromSeconds(double seconds, int32_t timescale);
BOOL SpliceKit_isMarkerLikeItem(id item);
NSDictionary *SpliceKit_describeMarker(id marker, id primaryObj, NSString *parentHandle,
                                       BOOL haveParentStart, double parentStartSeconds);
void SpliceKit_collectConnectedItems(id item,
                                     id primaryObj,
                                     id container,
                                     double containerStartSeconds,
                                     BOOL haveContainerStart,
                                     BOOL haveParentStart,
                                     double parentStartSeconds,
                                     NSString *parentHandle,
                                     NSInteger rootIndex,
                                     NSInteger depth,
                                     NSInteger parentEffectiveLane,
                                     NSSet *selectedSet,
                                     BOOL includeRoles,
                                     NSMutableArray *outItems,
                                     NSMutableArray *outMarkers,
                                     NSMutableSet *visited,
                                     NSInteger maxItems,
                                     NSInteger maxDepth);

#pragma mark - Defined in SpliceKitServerSpine.m

id SpliceKit_getUndoManager(void);
extern NSString *sOpenEditGroupName;
BOOL SpliceKit_internalBeginEditGroupIfNeeded(id sequence, NSString *name);
void SpliceKit_internalEndEditGroupIfOpened(id sequence, id timeline, NSString *name, BOOL openedByUs);

#pragma mark - Defined in SpliceKitServerFCPXML.m

NSDictionary *SpliceKit_handleOTIOToFCPXML(NSDictionary *params);
NSDictionary *SpliceKit_handleFCPXMLImportStatus(NSDictionary *params);

#pragma mark - Defined in SpliceKitServerTimelineActions.m

id SpliceKit_getEditorContainer(void);
NSDictionary *SpliceKit_makeFilePanelDialogPendingDictionary(NSString *action, NSDictionary *base);
NSDictionary *SpliceKit_annotateCreateActionFilePanelPending(NSDictionary *result, NSString *action);
NSDictionary *SpliceKit_annotatePendingDialog(NSDictionary *result, NSString *action);
NSDictionary *SpliceKit_directInsertGap(id timeline);

#pragma mark - Defined in SpliceKitServerDirectActions.m

id SpliceKit_getPlayerModule(void);
NSDictionary *SpliceKit_sendAppAction(NSString *selectorName);
NSDictionary *SpliceKit_directActionMissingSelectorError(id timeline, SEL sel, NSString *actionName);
NSDictionary *SpliceKit_sendAppActionAsyncNoWait(NSString *selectorName);

#pragma mark - Defined in SpliceKitServerBatchEdits.m

SpliceKit_CMTime SpliceKit_buildCMTime(double seconds, id timeline);
BOOL SpliceKit_seekAndMark(id timeline, SpliceKit_CMTime time, NSString *actionSelector);
NSDictionary *SpliceKit_handleBatchAddMarkers(NSDictionary *params);
NSDictionary *SpliceKit_handleBladeAtTimes(NSDictionary *params);
double SpliceKit_secondsFromTime(SpliceKit_CMTime t);
BOOL SpliceKit_tryReadTimelineRange(id primaryObj, id item, SpliceKit_CMTimeRange *outRange);
NSArray<NSNumber *> *SpliceKit_sortedUniqueSeconds(NSArray<NSNumber *> *values, double epsilon);
NSArray<NSNumber *> *SpliceKit_translateTimingMetadataToTimeline(id clip,
                                                                 id primaryObj,
                                                                 NSString *gridMode,
                                                                 double *outStartSec,
                                                                 double *outEndSec,
                                                                 double *outTempo);
BOOL SpliceKit_boolForSelector(id item, NSString *selectorName);
NSInteger SpliceKit_laneForItem(id item);
NSString *SpliceKit_displayNameForItem(id item);
void SpliceKit_collectVisibleTimelineEntries(id item,
                                             id primaryObj,
                                             NSMutableArray<NSDictionary *> *out,
                                             NSMutableSet<NSString *> *visited);
uint64_t SpliceKit_nextRandom(uint64_t *state);
NSInteger SpliceKit_chooseRandomAssemblyStep(NSInteger segmentMinStep,
                                             NSInteger segmentMaxStep,
                                             NSDictionary<NSNumber *, NSNumber *> *stepWeights,
                                             uint64_t *rngState);
NSDictionary *SpliceKit_findVisibleEntryContextNamed(NSString *projectName);
NSDictionary *SpliceKit_handleTrimClipsToBeats(NSDictionary *params);

#pragma mark - Defined in SpliceKitServerEditing.m

NSArray *SpliceKit_handleSelectionCurrentItems(id timeline);
NSMutableSet<NSString *> *SpliceKit_handleSelectionPointerKeys(NSArray *items);
BOOL SpliceKit_handleSelectionApply(id timeline, NSArray *items, NSString **outSelector);
id SpliceKit_handleResolveTimelineClip(NSString *handle, id primaryObj,
                                       SpliceKit_CMTimeRange *outRange,
                                       NSString **outError);

#pragma mark - Defined in SpliceKitServerClipInfo.m

id SpliceKit_clipInfoMediaComponentWithDepth(id item, int *outDepth);
NSURL *SpliceKit_clipInfoMediaURL(id item, NSString **outRepresentation, NSString **outSource);
NSString *SpliceKit_clipInfoKindForItem(id item, BOOL hasVideo, BOOL hasAudio);
NSDictionary *SpliceKit_handleBatchActions(NSDictionary *params);
NSDictionary *SpliceKit_handleSetRange(NSDictionary *params);
NSDictionary *SpliceKit_handleTimelineGetState(NSDictionary *params);

#pragma mark - Defined in SpliceKitServerTranscript.m

NSDictionary *SpliceKit_handleTranscriptOpen(NSDictionary *params);
NSDictionary *SpliceKit_handleTranscriptClose(NSDictionary *params);
NSDictionary *SpliceKit_handleTranscriptGetState(NSDictionary *params);
NSDictionary *SpliceKit_handleTranscriptDeleteWords(NSDictionary *params);
NSDictionary *SpliceKit_handleTranscriptMoveWords(NSDictionary *params);
NSDictionary *SpliceKit_handleTranscriptSearch(NSDictionary *params);
NSDictionary *SpliceKit_handleTranscriptDeleteSilences(NSDictionary *params);
NSDictionary *SpliceKit_handleTranscriptSetSilenceThreshold(NSDictionary *params);
NSDictionary *SpliceKit_handleTranscriptSetEngine(NSDictionary *params);
NSDictionary *SpliceKit_handleTranscriptSetSpeaker(NSDictionary *params);

#pragma mark - Defined in SpliceKitServerCaptions.m

NSDictionary *SpliceKit_handleCaptionsOpen(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsClose(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsGetState(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsGetStyles(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsSetStyle(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsSetGrouping(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsGenerate(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsExportSRT(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsExportTXT(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsSetWords(NSDictionary *params);
BOOL SpliceKit_itemIsGapGenerator(id item);
BOOL SpliceKit_itemIsMotionTitleVerifyCandidate(id item);
NSMutableDictionary *SpliceKit_buildVerifiedMotionTitleEntry(id connectedItem);
NSDictionary *SpliceKit_handleCaptionsVerify(NSDictionary *params);
NSDictionary *SpliceKit_handleCaptionsCleanup(NSDictionary *params);
NSDictionary *SpliceKit_handleNativeCaptionsGenerate(NSDictionary *params);
NSDictionary *SpliceKit_handleNativeCaptionsVerify(NSDictionary *params);

#pragma mark - Defined in SpliceKitServerEffects.m

NSDictionary *SpliceKit_handleEffectList(NSDictionary *params);
NSDictionary *SpliceKit_handleGetClipEffects(NSDictionary *params);
NSDictionary *SpliceKit_resolveEffectDescriptor(NSString *effectID,
                                                NSString *name,
                                                NSString *requiredType);

#pragma GCC visibility pop

#endif /* SpliceKitServerInternal_h */
