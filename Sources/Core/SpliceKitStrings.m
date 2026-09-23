//
//  SpliceKitStrings.m
//  See SpliceKitStrings.h.
//

#import "SpliceKitStrings.h"

static NSMutableString *SpliceKit_escapeXMLCore(NSString *str) {
    NSMutableString *s = [str mutableCopy];
    [s replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, s.length)];
    return s;
}

NSString *SpliceKit_escapeXML(id value) {
    if (!value || value == (id)kCFNull) return @"";
    NSString *str = [value isKindOfClass:[NSString class]] ? value : [value description];
    return SpliceKit_escapeXMLCore(str ?: @"");
}

NSString *SpliceKit_escapeXMLWithApostrophe(id value) {
    NSString *str = [value isKindOfClass:[NSString class]] ? value : @"";
    NSMutableString *s = SpliceKit_escapeXMLCore(str);
    [s replaceOccurrencesOfString:@"'" withString:@"&apos;" options:0 range:NSMakeRange(0, s.length)];
    return s;
}
