// SpliceKit VP9 host-side bootstrap.
//
// One public entry point called from SpliceKit.m at the did-launch phase.
// Light up Apple's system supplemental VP9 decoder and register our proxy
// codec bundle through every path Flexo consults.

#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Idempotent. First call does the registration, later calls are no-ops.
void SpliceKitVP9_Bootstrap(void);

#ifdef __cplusplus
}
#endif
