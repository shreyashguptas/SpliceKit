//
//  SpliceKitTranscriptPlacement.h
//  Where each transcribed word now plays on the timeline. Plain Foundation, no Final Cut
//  Pro objects, so tests/objc/transcript_placement_test.m can run it on its own.
//

#import <Foundation/Foundation.h>

#pragma GCC visibility push(hidden)

// Places transcribed words on the clips the timeline plays now.
//
// words: one dictionary per transcribed word, in any order:
//   @"path"            the source media file (empty: the word matches a clip of any file)
//   @"sourceMediaTime" where the word starts in that file, in the clips' trimStart space
//   @"duration"        its length in timeline seconds
// clips: one dictionary per clip on the timeline (primary storyline and connected clips):
//   @"path", @"trimStart" (source time of the clip's first frame), @"duration" (timeline
//   seconds), @"timelineStart", @"rateFactor" (optional; timeline seconds per source second)
//
// A word goes on every clip that plays its anchor, two frames into the word (the middle of a
// word shorter than four frames), so a word comes back once for each time the timeline uses
// its media: none when its piece was deleted or its clip removed, two when a clip is used
// twice. Not the start: a cut rounded to a frame can leave a sliver of a deleted word at the
// end of the piece before it, or put the start of the next word a frame before its piece
// begins. Not the middle: Delete Silences cuts the pause an engine folded into a long word's
// tail, from a typical word length after its start, and the spoken part that is left must
// keep the word. A word that reaches past its piece's edge
// keeps that part only when the neighbouring piece plays the same media on (a blade with
// nothing removed); otherwise it is cut at the edge, so deleting it never takes the next
// piece's frames.
//
// Returns the placements sorted by timeline start (then clip, then source time):
//   @"word" index into words, @"clip" index into clips, @"startTime", @"duration"
NSArray<NSDictionary *> *SpliceKitTranscript_placeWords(NSArray<NSDictionary *> *words,
                                                        NSArray<NSDictionary *> *clips,
                                                        double frameSeconds);

#pragma GCC visibility pop
