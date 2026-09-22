//
//  SpliceKitAudioLevels.h
//  SpliceKit
//
//  timeline.getAudioLevels: peak and RMS audio levels over time for timeline clips,
//  mapped to timeline seconds. The decoding runs in the `audio-levels` helper CLI
//  (tools/audio-levels.swift): AVFoundation audio decoding inside Final Cut Pro's
//  own process deadlocks, so nothing here touches AVAssetReader.
//

#import <Foundation/Foundation.h>

// JSON-RPC handler (SpliceKitAudioLevels.m). Runs on the RPC client thread; hops to
// the main thread only to resolve clips to their source media files.
NSDictionary *SpliceKit_handleTimelineGetAudioLevels(NSDictionary *params);

// Where the helper binary was found, or nil (SpliceKitAudioLevels.m).
NSString *SpliceKit_findAudioLevelsHelper(void);

// Defined in SpliceKitServer.m next to the getClipInfo helpers it shares. Main thread
// only, and it touches no file system (the caller checks that the file exists, off the
// main thread). Keys: class, name, kind, hasAudio, hasVideo, isCollection, path, fileName,
// representation, sourceStart, mediaOrigin, fileStart, retimed (BOOL or "unknown"),
// retimeSelector, error.
NSDictionary *SpliceKit_audioSourceForItem(id item);
