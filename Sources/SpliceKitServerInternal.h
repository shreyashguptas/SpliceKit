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

id SpliceKit_getPlayerModule(void);
NSDictionary *SpliceKit_sendAppAction(NSString *selectorName);

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

#pragma GCC visibility pop

#endif /* SpliceKitServerInternal_h */
