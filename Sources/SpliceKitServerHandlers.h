//
//  SpliceKitServerHandlers.h
//  SpliceKit - Bridge handlers and helpers defined in SpliceKitServer.m that
//  other files call directly (in-process, without going through the socket).
//
//  Every declaration here must match its definition in SpliceKitServer.m,
//  which imports this header so the compiler checks both sides.
//

#ifndef SpliceKitServerHandlers_h
#define SpliceKitServerHandlers_h

#import <Foundation/Foundation.h>

#pragma mark - Dispatcher

// The universal dispatcher: routes any {"method", "params"} request to its handler.
NSDictionary *SpliceKit_handleRequest(NSDictionary *request);

#pragma mark - Timeline

NSDictionary *SpliceKit_handleTimelineAction(NSDictionary *params);
NSDictionary *SpliceKit_handleTimelineGetDetailedState(NSDictionary *params);
NSDictionary *SpliceKit_handleSpineGetItems(NSDictionary *params);
NSDictionary *SpliceKit_handleSpineReorder(NSDictionary *params);
NSDictionary *SpliceKit_handleDetectSceneChanges(NSDictionary *params);
NSDictionary *SpliceKit_handleBatchExport(NSDictionary *params);

#pragma mark - Playback

NSDictionary *SpliceKit_handlePlayback(NSDictionary *params);
NSDictionary *SpliceKit_handlePlaybackSeek(NSDictionary *params);
NSDictionary *SpliceKit_handlePlaybackGetPosition(NSDictionary *params);

#pragma mark - Effects, Transitions, Titles

NSDictionary *SpliceKit_handleEffectsListAvailable(NSDictionary *params);
NSDictionary *SpliceKit_handleEffectsApply(NSDictionary *params);
NSDictionary *SpliceKit_handleTransitionsList(NSDictionary *params);
NSDictionary *SpliceKit_handleTransitionsApply(NSDictionary *params);
NSDictionary *SpliceKit_handleTitleInsert(NSDictionary *params);
NSDictionary *SpliceKit_handleSubjectStabilize(NSDictionary *params);

#pragma mark - Menus, FCPXML, Music

NSDictionary *SpliceKit_handleMenuExecute(NSDictionary *params);
NSDictionary *SpliceKit_handleFCPXMLImport(NSDictionary *params);
NSDictionary *SpliceKit_handleFCPXMLExport(NSDictionary *params);
NSDictionary *SpliceKit_handlePasteboardImportXML(NSDictionary *params);
NSDictionary *SpliceKit_handleFlexMusicListSongs(NSDictionary *params);
NSDictionary *SpliceKit_handleMontageAnalyze(NSDictionary *params);

#pragma mark - Mixer

void SpliceKit_installMixerSkimHooks(void);
id SpliceKit_getMasterAudioDest(void);
BOOL SpliceKit_mixerSetStaticChannelValue(id channel, double value);
BOOL SpliceKit_removeChannelKeyframes(id channel);
BOOL SpliceKit_mixerWriteAutomationPoint(id clip, id channel, double value);
NSDictionary *SpliceKit_handleMixerGetState(NSDictionary *params);
NSDictionary *SpliceKit_handleMixerSetSolo(NSDictionary *params);
NSDictionary *SpliceKit_handleMixerSetMute(NSDictionary *params);
NSDictionary *SpliceKit_handleMixerApplyBusEffect(NSDictionary *params);
NSDictionary *SpliceKit_handleMixerOpenBusEffect(NSDictionary *params);
NSDictionary *SpliceKit_handleMixerSetBusEffectEnabled(NSDictionary *params);
NSDictionary *SpliceKit_handleMixerRemoveBusEffect(NSDictionary *params);

#endif /* SpliceKitServerHandlers_h */
