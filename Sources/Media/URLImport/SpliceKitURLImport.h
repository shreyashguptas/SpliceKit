//
//  SpliceKitURLImport.h
//  Remote URL -> local media -> Final Cut import workflow.
//

#ifndef SpliceKitURLImport_h
#define SpliceKitURLImport_h

#import <Foundation/Foundation.h>

NSDictionary *SpliceKitURLImport_start(NSDictionary *params);
NSDictionary *SpliceKitURLImport_importSync(NSDictionary *params);
NSDictionary *SpliceKitURLImport_status(NSDictionary *params);
NSDictionary *SpliceKitURLImport_cancel(NSDictionary *params);
void SpliceKitURLImport_bootstrapAtLaunchPhase(NSString *phase);
void SpliceKitURLImport_installVP9ImportHook(void);

// Shared entry point: rewrites a local MKV/WebM file URL to an on-disk shadow
// MP4 (stream-copy remux via ffmpeg) if the file is classified as remuxable.
// Returns the original URL unchanged for anything that doesn't need rewriting
// (non-file URLs, non-remuxable formats, already-rewritten shadows).
// Synchronous; typical cost ~500ms for a full remux, effectively free for
// files that fall through the classifier.
NSURL *SpliceKitURLImport_CopyShadowURL(NSURL *fileURL, NSString **outError);

#endif /* SpliceKitURLImport_h */
