//
//  SpliceKitServerRuntimeExport.m
//  SpliceKit - Bulk runtime metadata export for IDA Pro / reverse engineering:
//  class metadata dumps, loaded images, Mach-O sections, symbols, notification names.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Runtime Metadata Export (for IDA Pro)
//
// Extracts rich ObjC runtime metadata from the live FCP process as JSON.
// This data feeds into IDA Pro scripts that rename sub_XXXX functions to
// ObjC selectors, declare struct types from ivars, and add protocol comments.
//

// Helper: serialize a single method with dladdr info (which binary owns the IMP)
static NSDictionary *SpliceKit_serializeMethod(Method m) {
    SEL sel = method_getName(m);
    const char *types = method_getTypeEncoding(m);
    IMP imp = method_getImplementation(m);

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"selector"] = NSStringFromSelector(sel);
    info[@"typeEncoding"] = types ? @(types) : @"";
    info[@"imp"] = [NSString stringWithFormat:@"0x%lx", (unsigned long)imp];

    // dladdr: which image owns this IMP + nearest symbol name
    Dl_info dlinfo;
    if (dladdr((void *)imp, &dlinfo)) {
        if (dlinfo.dli_fname) info[@"image"] = [@(dlinfo.dli_fname) lastPathComponent];
        if (dlinfo.dli_sname) info[@"symbol"] = @(dlinfo.dli_sname);
        if (dlinfo.dli_saddr) info[@"symbolAddr"] = [NSString stringWithFormat:@"0x%lx",
                                                       (unsigned long)dlinfo.dli_saddr];
    }
    return info;
}

// Helper: serialize protocol method declarations
static NSDictionary *SpliceKit_serializeProtocol(Protocol *proto) {
    NSMutableDictionary *protoInfo = [NSMutableDictionary dictionary];
    protoInfo[@"name"] = @(protocol_getName(proto));

    // 4 variants: required/optional x instance/class
    NSString *keys[4] = {@"requiredInstanceMethods", @"requiredClassMethods",
                         @"optionalInstanceMethods", @"optionalClassMethods"};
    BOOL reqVals[4]  = {YES, YES, NO, NO};
    BOOL instVals[4] = {YES, NO, YES, NO};

    for (int v = 0; v < 4; v++) {
        unsigned int mCount = 0;
        struct objc_method_description *descs =
            protocol_copyMethodDescriptionList(proto, reqVals[v], instVals[v], &mCount);
        NSMutableArray *methods = [NSMutableArray arrayWithCapacity:mCount];
        if (descs) {
            for (unsigned int m = 0; m < mCount; m++) {
                [methods addObject:@{
                    @"selector": NSStringFromSelector(descs[m].name),
                    @"typeEncoding": descs[m].types ? @(descs[m].types) : @""
                }];
            }
            free(descs);
        }
        protoInfo[keys[v]] = methods;
    }

    // Protocol inheritance
    unsigned int parentCount = 0;
    Protocol * __unsafe_unretained *parents = protocol_copyProtocolList(proto, &parentCount);
    NSMutableArray *parentNames = [NSMutableArray arrayWithCapacity:parentCount];
    if (parents) {
        for (unsigned int p = 0; p < parentCount; p++) {
            [parentNames addObject:@(protocol_getName(parents[p]))];
        }
        free(parents);
    }
    protoInfo[@"inheritsFrom"] = parentNames;

    // Protocol properties
    unsigned int ppCount = 0;
    objc_property_t *ppList = protocol_copyPropertyList(proto, &ppCount);
    NSMutableArray *protoProps = [NSMutableArray arrayWithCapacity:ppCount];
    if (ppList) {
        for (unsigned int p = 0; p < ppCount; p++) {
            const char *name = property_getName(ppList[p]);
            const char *attrs = property_getAttributes(ppList[p]);
            [protoProps addObject:@{
                @"name": @(name),
                @"attributes": attrs ? @(attrs) : @""
            }];
        }
        free(ppList);
    }
    protoInfo[@"properties"] = protoProps;

    return protoInfo;
}

// Helper: parse ivar layout bitmap into array of strong/weak byte indices
static NSArray *SpliceKit_parseIvarLayout(const uint8_t *layout) {
    if (!layout) return @[];
    NSMutableArray *indices = [NSMutableArray array];
    NSUInteger byteIndex = 0;
    while (*layout != 0) {
        uint8_t skip = (*layout >> 4) & 0x0F;
        uint8_t scan = *layout & 0x0F;
        byteIndex += skip;
        for (uint8_t s = 0; s < scan; s++) {
            [indices addObject:@(byteIndex)];
            byteIndex++;
        }
        layout++;
    }
    return indices;
}

static NSDictionary *SpliceKit_classMetadata(Class cls) {
    NSString *className = NSStringFromClass(cls);

    // Instance methods with dladdr
    NSMutableArray *instanceMethods = [NSMutableArray array];
    unsigned int mCount = 0;
    Method *mList = class_copyMethodList(cls, &mCount);
    if (mList) {
        for (unsigned int i = 0; i < mCount; i++) {
            [instanceMethods addObject:SpliceKit_serializeMethod(mList[i])];
        }
        free(mList);
    }

    // Class methods with dladdr
    NSMutableArray *classMethods = [NSMutableArray array];
    Class metaCls = object_getClass(cls);
    if (metaCls) {
        unsigned int cmCount = 0;
        Method *cmList = class_copyMethodList(metaCls, &cmCount);
        if (cmList) {
            for (unsigned int i = 0; i < cmCount; i++) {
                [classMethods addObject:SpliceKit_serializeMethod(cmList[i])];
            }
            free(cmList);
        }
    }

    // Ivars with offsets
    NSMutableArray *ivars = [NSMutableArray array];
    unsigned int iCount = 0;
    Ivar *iList = class_copyIvarList(cls, &iCount);
    if (iList) {
        for (unsigned int i = 0; i < iCount; i++) {
            const char *name = ivar_getName(iList[i]);
            const char *type = ivar_getTypeEncoding(iList[i]);
            ptrdiff_t offset = ivar_getOffset(iList[i]);
            [ivars addObject:@{
                @"name": name ? @(name) : @"<anon>",
                @"type": type ? @(type) : @"?",
                @"offset": @(offset)
            }];
        }
        free(iList);
    }

    // Ivar layout bitmaps (strong/weak reference tracking)
    const uint8_t *strongLayout = class_getIvarLayout(cls);
    const uint8_t *weakLayout = class_getWeakIvarLayout(cls);
    NSArray *strongIndices = SpliceKit_parseIvarLayout(strongLayout);
    NSArray *weakIndices = SpliceKit_parseIvarLayout(weakLayout);

    // Properties with parsed attributes
    NSMutableArray *properties = [NSMutableArray array];
    unsigned int pCount = 0;
    objc_property_t *pList = class_copyPropertyList(cls, &pCount);
    if (pList) {
        for (unsigned int i = 0; i < pCount; i++) {
            const char *name = property_getName(pList[i]);
            const char *rawAttrs = property_getAttributes(pList[i]);

            NSMutableDictionary *propInfo = [NSMutableDictionary dictionary];
            propInfo[@"name"] = @(name);
            propInfo[@"rawAttributes"] = rawAttrs ? @(rawAttrs) : @"";

            // Parse structured attributes
            unsigned int attrCount = 0;
            objc_property_attribute_t *attrList = property_copyAttributeList(pList[i], &attrCount);
            if (attrList) {
                for (unsigned int a = 0; a < attrCount; a++) {
                    NSString *attrName;
                    char code = attrList[a].name[0];
                    switch (code) {
                        case 'T': attrName = @"type"; break;
                        case 'V': attrName = @"backingIvar"; break;
                        case 'S': attrName = @"setter"; break;
                        case 'G': attrName = @"getter"; break;
                        case 'R': attrName = @"readonly"; break;
                        case 'C': attrName = @"copy"; break;
                        case '&': attrName = @"strong"; break;
                        case 'N': attrName = @"nonatomic"; break;
                        case 'W': attrName = @"weak"; break;
                        case 'D': attrName = @"dynamic"; break;
                        default:  attrName = @(attrList[a].name); break;
                    }
                    propInfo[attrName] = (attrList[a].value && attrList[a].value[0])
                        ? @(attrList[a].value) : @YES;
                }
                free(attrList);
            }
            [properties addObject:propInfo];
        }
        free(pList);
    }

    // Protocols with full method declarations
    NSMutableArray *protocols = [NSMutableArray array];
    unsigned int prCount = 0;
    Protocol * __unsafe_unretained *prList = class_copyProtocolList(cls, &prCount);
    if (prList) {
        for (unsigned int i = 0; i < prCount; i++) {
            [protocols addObject:SpliceKit_serializeProtocol(prList[i])];
        }
        free(prList);
    }

    // Superchain
    NSMutableArray *superchain = [NSMutableArray array];
    Class current = class_getSuperclass(cls);
    while (current) {
        [superchain addObject:NSStringFromClass(current)];
        current = class_getSuperclass(current);
    }

    // Instance size
    size_t instanceSize = class_getInstanceSize(cls);

    return @{
        @"name": className,
        @"instanceSize": @(instanceSize),
        @"superchain": superchain,
        @"protocols": protocols,
        @"instanceMethods": instanceMethods,
        @"classMethods": classMethods,
        @"ivars": ivars,
        @"ivarLayout": @{@"strong": strongIndices, @"weak": weakIndices},
        @"properties": properties
    };
}

static const NSTimeInterval SpliceKit_debugScanTimeBudgetSeconds = 2.0;

static BOOL SpliceKit_debugScanBudgetExpired(NSDate *deadline) {
    return deadline && [deadline timeIntervalSinceNow] <= 0;
}

static NSInteger SpliceKit_debugScanLimit(NSDictionary *params) {
    NSInteger limit = [params[@"limit"] integerValue];
    if (limit < 1) limit = 200;
    return limit;
}

NSDictionary *SpliceKit_handleDumpRuntimeMetadata(NSDictionary *params) {
    NSString *binaryFilter = params[@"binary"]; // optional: filter to one binary
    NSArray *includeFields = params[@"include"]; // optional: subset of fields
    BOOL classesOnly = [params[@"classesOnly"] boolValue]; // just class names, no details
    NSInteger limit = SpliceKit_debugScanLimit(params);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:SpliceKit_debugScanTimeBudgetSeconds];
    BOOL truncated = NO;
    NSString *stopReason = nil;
    NSUInteger classesScanned = 0;
    NSUInteger totalClassesInFilter = 0;

    NSMutableArray *images = [NSMutableArray array];
    NSMutableDictionary *classesByImage = [NSMutableDictionary dictionary];

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount && !truncated; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;

        NSString *imagePath = @(imageName);
        NSString *shortName = [imagePath lastPathComponent];

        // If binary filter specified, skip non-matching images
        if (binaryFilter && ![shortName localizedCaseInsensitiveContainsString:binaryFilter]
            && ![imagePath localizedCaseInsensitiveContainsString:binaryFilter]) {
            continue;
        }

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct mach_header *header = _dyld_get_image_header(i);
        uintptr_t baseAddr = (uintptr_t)header;

        NSDictionary *imageInfo = @{
            @"path": imagePath,
            @"name": shortName,
            @"index": @(i),
            @"baseAddress": [NSString stringWithFormat:@"0x%lx", (unsigned long)baseAddr],
            @"slide": [NSString stringWithFormat:@"0x%lx", (unsigned long)slide]
        };

        // Get classes for this image
        unsigned int classCount = 0;
        const char **classNames = objc_copyClassNamesForImage(imageName, &classCount);
        if (classCount == 0) {
            if (classNames) free(classNames);
            continue; // skip images with no ObjC classes
        }
        totalClassesInFilter += classCount;

        NSMutableArray *classData = [NSMutableArray array];
        if (classesOnly) {
            // Fast path: just class names
            for (unsigned int j = 0; j < classCount; j++) {
                if ((NSInteger)classData.count >= limit) {
                    truncated = YES;
                    stopReason = @"limit";
                    break;
                }
                if (SpliceKit_debugScanBudgetExpired(deadline)) {
                    truncated = YES;
                    stopReason = @"timeBudget";
                    break;
                }
                classesScanned++;
                [classData addObject:@(classNames[j])];
            }
        } else {
            // Full metadata for each class
            for (unsigned int j = 0; j < classCount; j++) {
                if ((NSInteger)classData.count >= limit) {
                    truncated = YES;
                    stopReason = @"limit";
                    break;
                }
                if (SpliceKit_debugScanBudgetExpired(deadline)) {
                    truncated = YES;
                    stopReason = @"timeBudget";
                    break;
                }
                classesScanned++;
                @try {
                    Class cls = objc_getClass(classNames[j]);
                    if (!cls) continue;
                    NSDictionary *meta = SpliceKit_classMetadata(cls);
                    [classData addObject:meta];
                } @catch (NSException *e) {
                    // Skip problematic classes
                    [classData addObject:@{@"name": @(classNames[j]), @"error": e.reason ?: @"unknown"}];
                }
            }
        }
        free(classNames);
        if (truncated) {
            NSMutableDictionary *entry = [imageInfo mutableCopy];
            entry[@"classCount"] = @(classCount);
            entry[@"classesReturned"] = @(classData.count);
            [images addObject:entry];
            classesByImage[shortName] = classData;
            break;
        }

        NSMutableDictionary *entry = [imageInfo mutableCopy];
        entry[@"classCount"] = @(classCount);
        [images addObject:entry];
        classesByImage[shortName] = classData;
    }

    NSUInteger totalClasses = 0;
    for (NSArray *arr in [classesByImage allValues]) {
        totalClasses += arr.count;
    }

    NSMutableDictionary *response = [@{
        @"images": images,
        @"classes": classesByImage,
        @"imageCount": @(images.count),
        @"totalClasses": @(totalClasses),
        @"truncated": @(truncated),
        @"limit": @(limit),
        @"classesScanned": @(classesScanned),
        @"totalClassesInFilter": @(totalClassesInFilter)
    } mutableCopy];
    if (truncated && stopReason) response[@"stopReason"] = stopReason;
    return response;
}

// Lightweight: just list loaded images with addresses/slides (no class enumeration)
NSDictionary *SpliceKit_handleListLoadedImages(NSDictionary *params) {
    NSString *filter = params[@"filter"];
    NSMutableArray *images = [NSMutableArray array];

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;

        NSString *imagePath = @(imageName);
        NSString *shortName = [imagePath lastPathComponent];

        if (filter && ![shortName localizedCaseInsensitiveContainsString:filter]
            && ![imagePath localizedCaseInsensitiveContainsString:filter]) {
            continue;
        }

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct mach_header *header = _dyld_get_image_header(i);
        uintptr_t baseAddr = (uintptr_t)header;

        // Count classes for this image
        unsigned int classCount = 0;
        const char **classNames = objc_copyClassNamesForImage(imageName, &classCount);
        if (classNames) free(classNames);

        [images addObject:@{
            @"path": imagePath,
            @"name": shortName,
            @"index": @(i),
            @"baseAddress": [NSString stringWithFormat:@"0x%lx", (unsigned long)baseAddr],
            @"slide": [NSString stringWithFormat:@"0x%lx", (unsigned long)slide],
            @"classCount": @(classCount)
        }];
    }

    return @{@"images": images, @"count": @(images.count)};
}

#pragma mark - Mach-O Section & Symbol Table Export
//
// Reads raw Mach-O sections (__objc_selrefs, __objc_classrefs) and the symbol
// table from loaded binaries, revealing cross-reference patterns. Falls back to
// runtime APIs for shared-cache frameworks where raw section walking is unsafe.
//

// Enumerate ObjC selector references, class references, and categories for an image
// Helper: check if an image is in the dyld shared cache (unsafe for section/symtab walking)
static BOOL SpliceKit_isInSharedCache(const struct mach_header_64 *header) {
    // MH_DYLIB_IN_CACHE flag (0x80000000) indicates shared cache membership
    return (header->flags & 0x80000000) != 0;
}

NSDictionary *SpliceKit_handleGetImageSections(NSDictionary *params) {
    NSString *binaryName = params[@"binary"];
    if (!binaryName) return @{@"error": @"binary parameter required"};
    NSInteger limit = SpliceKit_debugScanLimit(params);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:SpliceKit_debugScanTimeBudgetSeconds];
    BOOL truncated = NO;
    NSString *stopReason = nil;

    uint32_t imageCount = _dyld_image_count();
    const struct mach_header_64 *foundHeader = NULL;
    intptr_t foundSlide = 0;
    NSString *foundPath = nil;

    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;
        NSString *path = @(imageName);
        NSString *shortName = [path lastPathComponent];
        if ([shortName localizedCaseInsensitiveContainsString:binaryName]
            || [path localizedCaseInsensitiveContainsString:binaryName]) {
            foundHeader = (const struct mach_header_64 *)_dyld_get_image_header(i);
            foundSlide = _dyld_get_image_vmaddr_slide(i);
            foundPath = path;
            break;
        }
    }
    if (!foundHeader) return @{@"error": [NSString stringWithFormat:@"Image not found: %@", binaryName]};

    // Shared cache images have remapped sections — skip unsafe section reads
    BOOL inCache = SpliceKit_isInSharedCache(foundHeader);

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"binary"] = [foundPath lastPathComponent];
    result[@"path"] = foundPath;
    result[@"slide"] = [NSString stringWithFormat:@"0x%lx", (unsigned long)foundSlide];
    result[@"inSharedCache"] = @(inCache);

    if (inCache) {
        // For shared cache images, use ObjC runtime APIs instead of raw section reads
        // Get selectors referenced by classes in this image
        unsigned int classCount = 0;
        const char **classNames = objc_copyClassNamesForImage([foundPath UTF8String], &classCount);
        NSMutableSet *selectors = [NSMutableSet set];
        NSMutableSet *classRefs = [NSMutableSet set];
        unsigned int classesScanned = 0;
        unsigned int totalClassesInImage = classCount;
        if (classNames) {
            for (unsigned int j = 0; j < classCount; j++) {
                classesScanned = j + 1;
                if (SpliceKit_debugScanBudgetExpired(deadline)) {
                    truncated = YES;
                    stopReason = @"timeBudget";
                    break;
                }
                Class cls = objc_getClass(classNames[j]);
                if (!cls) continue;
                // Collect selectors from methods
                unsigned int mCount = 0;
                Method *methods = class_copyMethodList(cls, &mCount);
                if (methods) {
                    for (unsigned int m = 0; m < mCount; m++) {
                        if ((NSInteger)selectors.count >= limit) {
                            truncated = YES;
                            stopReason = @"limit";
                            free(methods);
                            goto sections_cache_done;
                        }
                        if (SpliceKit_debugScanBudgetExpired(deadline)) {
                            truncated = YES;
                            stopReason = @"timeBudget";
                            free(methods);
                            goto sections_cache_done;
                        }
                        [selectors addObject:NSStringFromSelector(method_getName(methods[m]))];
                    }
                    free(methods);
                }
                // Collect superclass name
                Class super = class_getSuperclass(cls);
                if (super) [classRefs addObject:NSStringFromClass(super)];
            }
sections_cache_done:
            free(classNames);
        }
        result[@"selectorRefs"] = [selectors allObjects];
        result[@"selectorRefCount"] = @(selectors.count);
        result[@"classRefs"] = [classRefs allObjects];
        result[@"classRefCount"] = @(classRefs.count);
        result[@"superclassRefs"] = @[];
        result[@"note"] = @"Shared cache image — used ObjC runtime APIs instead of raw section reads";
        result[@"truncated"] = @(truncated);
        result[@"limit"] = @(limit);
        result[@"classesScanned"] = @(classesScanned);
        result[@"totalClassesInImage"] = @(totalClassesInImage);
        if (truncated && stopReason) result[@"stopReason"] = stopReason;
        return result;
    }

    // Non-cache images: safe to read sections directly
    @try {
        unsigned long selrefsSize = 0;
        SEL *selrefs = (SEL *)getsectiondata(foundHeader, "__DATA_CONST", "__objc_selrefs", &selrefsSize);
        if (!selrefs) selrefs = (SEL *)getsectiondata(foundHeader, "__DATA", "__objc_selrefs", &selrefsSize);
        NSMutableArray *selectorRefs = [NSMutableArray array];
        unsigned long selCountTotal = 0;
        unsigned long selEntriesScanned = 0;
        if (selrefs) {
            unsigned long selCount = selrefsSize / sizeof(SEL);
            selCountTotal = selCount;
            for (unsigned long j = 0; j < selCount; j++) {
                selEntriesScanned = j + 1;
                if ((NSInteger)selectorRefs.count >= limit) {
                    truncated = YES;
                    stopReason = @"limit";
                    break;
                }
                if (SpliceKit_debugScanBudgetExpired(deadline)) {
                    truncated = YES;
                    stopReason = @"timeBudget";
                    break;
                }
                @try {
                    NSString *selName = NSStringFromSelector(selrefs[j]);
                    if (selName) [selectorRefs addObject:selName];
                } @catch (NSException *e) { /* skip */ }
            }
        }
        result[@"selectorRefs"] = selectorRefs;
        result[@"selectorRefCount"] = @(selectorRefs.count);
        result[@"selectorRefTotalInSection"] = @(selCountTotal);
        result[@"selectorRefEntriesScanned"] = @(selEntriesScanned);

        unsigned long classrefsSize = 0;
        void *classrefsRaw = (void *)getsectiondata(foundHeader, "__DATA_CONST", "__objc_classrefs", &classrefsSize);
        if (!classrefsRaw) classrefsRaw = (void *)getsectiondata(foundHeader, "__DATA", "__objc_classrefs", &classrefsSize);
        NSMutableArray *classRefNames = [NSMutableArray array];
        unsigned long crCountTotal = 0;
        unsigned long crEntriesScanned = 0;
        if (classrefsRaw && !truncated) {
            void **classrefs = (void **)classrefsRaw;
            unsigned long crCount = classrefsSize / sizeof(void *);
            crCountTotal = crCount;
            for (unsigned long j = 0; j < crCount; j++) {
                crEntriesScanned = j + 1;
                if ((NSInteger)classRefNames.count >= limit) {
                    truncated = YES;
                    stopReason = @"limit";
                    break;
                }
                if (SpliceKit_debugScanBudgetExpired(deadline)) {
                    truncated = YES;
                    stopReason = @"timeBudget";
                    break;
                }
                @try {
                    if (classrefs[j]) {
                        const char *name = class_getName((__bridge Class)classrefs[j]);
                        if (name) [classRefNames addObject:@(name)];
                    }
                } @catch (NSException *e) { /* skip */ }
            }
        } else if (classrefsRaw) {
            crCountTotal = classrefsSize / sizeof(void *);
        }
        result[@"classRefs"] = classRefNames;
        result[@"classRefCount"] = @(classRefNames.count);
        result[@"classRefTotalInSection"] = @(crCountTotal);
        result[@"classRefEntriesScanned"] = @(crEntriesScanned);
        result[@"superclassRefs"] = @[];
    } @catch (NSException *e) {
        result[@"error"] = [NSString stringWithFormat:@"Section read failed: %@", e.reason];
    }

    result[@"truncated"] = @(truncated);
    result[@"limit"] = @(limit);
    if (truncated && stopReason) result[@"stopReason"] = stopReason;
    return result;
}

// Enumerate exported symbols from an image's symbol table
NSDictionary *SpliceKit_handleGetImageSymbols(NSDictionary *params) {
    NSString *binaryName = params[@"binary"];
    if (!binaryName) return @{@"error": @"binary parameter required"};
    NSString *filter = params[@"filter"]; // optional name filter
    BOOL demangleSwift = ![params[@"demangle"] isEqual:@NO]; // default YES
    NSInteger limit = SpliceKit_debugScanLimit(params);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:SpliceKit_debugScanTimeBudgetSeconds];
    BOOL truncated = NO;
    NSString *stopReason = nil;

    // Find the image
    uint32_t imageCount = _dyld_image_count();
    const struct mach_header_64 *foundHeader = NULL;
    intptr_t foundSlide = 0;
    NSString *foundPath = nil;

    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;
        NSString *path = @(imageName);
        NSString *shortName = [path lastPathComponent];
        if ([shortName localizedCaseInsensitiveContainsString:binaryName]
            || [path localizedCaseInsensitiveContainsString:binaryName]) {
            foundHeader = (const struct mach_header_64 *)_dyld_get_image_header(i);
            foundSlide = _dyld_get_image_vmaddr_slide(i);
            foundPath = path;
            break;
        }
    }
    if (!foundHeader) return @{@"error": [NSString stringWithFormat:@"Image not found: %@", binaryName]};

    // Shared cache images have remapped symbol tables — LC_SYMTAB offsets are invalid
    if (SpliceKit_isInSharedCache(foundHeader)) {
        return @{
            @"binary": [foundPath lastPathComponent],
            @"path": foundPath,
            @"inSharedCache": @YES,
            @"symbols": @[],
            @"exportedCount": @0,
            @"swiftDemangledCount": @0,
            @"note": @"Shared cache image — LC_SYMTAB not accessible. Use dladdr per-method instead."
        };
    }

    // Use ObjC runtime + dladdr to discover symbols safely (no raw symtab walking)
    typedef char *(*swift_demangle_func)(const char *, size_t, char *, size_t *, uint32_t);
    swift_demangle_func swift_demangle = NULL;
    if (demangleSwift) {
        swift_demangle = (swift_demangle_func)dlsym(RTLD_DEFAULT, "swift_demangle");
    }

    NSMutableArray *symbols = [NSMutableArray array];
    NSMutableSet *seenAddresses = [NSMutableSet set];
    NSUInteger swiftCount = 0;

    // Enumerate all classes in this image and collect their method symbols via dladdr
    unsigned int classCount = 0;
    const char **classNames = objc_copyClassNamesForImage([foundPath UTF8String], &classCount);
    unsigned int classesScanned = 0;
    unsigned int totalClassesInImage = classCount;
    if (classNames) {
        for (unsigned int j = 0; j < classCount; j++) {
            classesScanned = j + 1;
            if (SpliceKit_debugScanBudgetExpired(deadline)) {
                truncated = YES;
                stopReason = @"timeBudget";
                break;
            }
            Class cls = objc_getClass(classNames[j]);
            if (!cls) continue;

            // Instance + class methods
            for (int pass = 0; pass < 2 && !truncated; pass++) {
                Class target = (pass == 0) ? cls : object_getClass(cls);
                unsigned int mCount = 0;
                Method *methods = class_copyMethodList(target, &mCount);
                if (!methods) continue;

                for (unsigned int m = 0; m < mCount; m++) {
                    if ((NSInteger)symbols.count >= limit) {
                        truncated = YES;
                        stopReason = @"limit";
                        free(methods);
                        goto image_symbols_done;
                    }
                    if (SpliceKit_debugScanBudgetExpired(deadline)) {
                        truncated = YES;
                        stopReason = @"timeBudget";
                        free(methods);
                        goto image_symbols_done;
                    }

                    IMP imp = method_getImplementation(methods[m]);
                    NSString *addrStr = [NSString stringWithFormat:@"0x%lx", (unsigned long)imp];
                    if ([seenAddresses containsObject:addrStr]) continue;
                    [seenAddresses addObject:addrStr];

                    Dl_info dlinfo;
                    if (!dladdr((void *)imp, &dlinfo) || !dlinfo.dli_sname) continue;

                    NSString *symName = @(dlinfo.dli_sname);

                    // Apply filter
                    if (filter && ![symName localizedCaseInsensitiveContainsString:filter]) continue;

                    NSMutableDictionary *symInfo = [NSMutableDictionary dictionary];
                    symInfo[@"name"] = symName;
                    symInfo[@"address"] = addrStr;

                    // Swift demangling
                    if (swift_demangle && ([symName hasPrefix:@"$s"] || [symName hasPrefix:@"_$s"])) {
                        const char *raw = [symName UTF8String];
                        const char *toMangle = (raw[0] == '_') ? raw + 1 : raw;
                        char *demangled = swift_demangle(toMangle, 0, NULL, NULL, 0);
                        if (demangled) {
                            symInfo[@"demangled"] = @(demangled);
                            free(demangled);
                            swiftCount++;
                        }
                    }

                    [symbols addObject:symInfo];
                    if ((NSInteger)symbols.count >= limit) {
                        truncated = YES;
                        stopReason = @"limit";
                        free(methods);
                        goto image_symbols_done;
                    }
                }
                free(methods);
            }
        }
image_symbols_done:
        free(classNames);
    }

    NSMutableDictionary *response = [@{
        @"binary": [foundPath lastPathComponent],
        @"path": foundPath,
        @"slide": [NSString stringWithFormat:@"0x%lx", (unsigned long)foundSlide],
        @"symbols": symbols,
        @"exportedCount": @(symbols.count),
        @"swiftDemangledCount": @(swiftCount),
        @"truncated": @(truncated),
        @"limit": @(limit),
        @"classesScanned": @(classesScanned),
        @"totalClassesInImage": @(totalClassesInImage)
    } mutableCopy];
    if (truncated && stopReason) response[@"stopReason"] = stopReason;
    return response;
}

// Enumerate notification name constants from exported symbols
// Safe notification name discovery using ObjC runtime + dladdr instead of raw symtab
NSDictionary *SpliceKit_handleGetNotificationNames(NSDictionary *params) {
    NSString *binaryFilter = params[@"binary"];
    NSMutableArray *notifications = [NSMutableArray array];

    // Strategy: scan all classes for methods containing "Notification" in their name,
    // then use dladdr to find which notification constants are nearby.
    // Also try well-known notification name patterns via dlsym.

    // Collect known notification names from ObjC class properties and method names
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;
        NSString *path = @(imageName);
        NSString *shortName = [path lastPathComponent];

        if (binaryFilter && ![shortName localizedCaseInsensitiveContainsString:binaryFilter]
            && ![path localizedCaseInsensitiveContainsString:binaryFilter]) {
            continue;
        }

        // Get classes for this image and look for notification-related selectors
        unsigned int classCount = 0;
        const char **classNames = objc_copyClassNamesForImage(imageName, &classCount);
        if (!classNames) continue;

        for (unsigned int j = 0; j < classCount; j++) {
            NSString *cn = @(classNames[j]);
            // Check for NotificationCenter subclasses or classes with Notification in name
            if ([cn containsString:@"Notification"]) {
                Class cls = objc_getClass(classNames[j]);
                if (!cls) continue;
                unsigned int mCount = 0;
                Method *methods = class_copyMethodList(cls, &mCount);
                if (methods) {
                    for (unsigned int m = 0; m < mCount; m++) {
                        NSString *sel = NSStringFromSelector(method_getName(methods[m]));
                        IMP imp = method_getImplementation(methods[m]);
                        Dl_info dlinfo;
                        if (dladdr((void *)imp, &dlinfo) && dlinfo.dli_sname) {
                            [notifications addObject:@{
                                @"symbol": @(dlinfo.dli_sname),
                                @"selector": sel,
                                @"class": cn,
                                @"image": shortName,
                                @"address": [NSString stringWithFormat:@"0x%lx", (unsigned long)imp]
                            }];
                        }
                    }
                    free(methods);
                }
            }
        }
        free(classNames);
    }

    // Also try resolving well-known notification name constants via dlsym
    NSArray *knownPatterns = @[
        @"FFAssetChangeNotification",
        @"FFEffectsChangedNotification",
        @"FFLibraryNameChangedNotification",
        @"FFEffectRegistryChangedNotification",
        @"LKWindowDidChangeFirstResponderNotification",
        @"LKDocumentWasAddedNotification",
        @"LKDocumentWasRemovedNotification",
    ];
    for (NSString *name in knownPatterns) {
        void *sym = dlsym(RTLD_DEFAULT, [name UTF8String]);
        if (sym) {
            @try {
                id obj = *(__unsafe_unretained id *)sym;
                if ([obj isKindOfClass:[NSString class]]) {
                    [notifications addObject:@{
                        @"symbol": name,
                        @"value": (NSString *)obj,
                        @"image": @"(resolved)"
                    }];
                }
            } @catch (NSException *e) { /* skip */ }
        }
    }

    return @{@"notifications": notifications, @"count": @(notifications.count)};
}
