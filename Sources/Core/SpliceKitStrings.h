//
//  SpliceKitStrings.h
//  String helpers shared across SpliceKit.
//
//  Everything declared here is hidden: it never shows up in the dylib's exports.
//

#ifndef SpliceKitStrings_h
#define SpliceKitStrings_h

#import <Foundation/Foundation.h>

#pragma GCC visibility push(hidden)

// XML-escapes & < > " (element text and double-quoted attribute values).
// nil and NSNull give @""; any other non-string is escaped as its -description.
NSString *SpliceKit_escapeXML(id value);

// XML-escapes & < > " and ' (also safe in single-quoted attribute values).
// nil and anything that is not an NSString give @"".
NSString *SpliceKit_escapeXMLWithApostrophe(id value);

#pragma GCC visibility pop

#endif /* SpliceKitStrings_h */
