//
//  SpliceKitServerRuntime.m
//  SpliceKit - Runtime introspection handlers: system.* (classes, methods, ivars,
//  properties, protocols, callMethod/callMethodWithArgs), object.* handles and KVC
//  property get/set.
//

#import "SpliceKit.h"
#import "SpliceKitServerHandlers.h"
#import "SpliceKitServerInternal.h"

#pragma mark - Request Handlers: Runtime Introspection (system.*)
//
// These handlers let clients explore FCP's ObjC runtime: list classes,
// enumerate methods, read ivars, walk inheritance chains. Essential for
// reverse-engineering FCP's private APIs without a debugger attached.
//

NSDictionary *SpliceKit_handleSystemGetClasses(NSDictionary *params) {
    NSString *filter = params[@"filter"];
    NSArray *allClasses = SpliceKit_allLoadedClasses();

    if (filter && filter.length > 0) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:
                                  @"SELF CONTAINS[cd] %@", filter];
        allClasses = [allClasses filteredArrayUsingPredicate:predicate];
    }

    return @{@"classes": allClasses, @"count": @(allClasses.count)};
}

NSDictionary *SpliceKit_handleSystemGetMethods(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    BOOL includeSuper = [params[@"includeSuper"] boolValue];
    NSMutableDictionary *allMethods = [NSMutableDictionary dictionary];

    Class current = cls;
    while (current) {
        NSDictionary *methods = SpliceKit_methodsForClass(current);
        [allMethods addEntriesFromDictionary:methods];
        if (!includeSuper) break;
        current = class_getSuperclass(current);
        if (current == [NSObject class]) break;
    }

    // Also get class methods
    NSMutableDictionary *classMethods = [NSMutableDictionary dictionary];
    Class metaCls = object_getClass(cls);
    if (metaCls) {
        unsigned int count = 0;
        Method *methodList = class_copyMethodList(metaCls, &count);
        if (methodList) {
            for (unsigned int i = 0; i < count; i++) {
                SEL sel = method_getName(methodList[i]);
                NSString *name = NSStringFromSelector(sel);
                const char *types = method_getTypeEncoding(methodList[i]);
                classMethods[name] = @{
                    @"selector": name,
                    @"typeEncoding": types ? @(types) : @"",
                    @"imp": [NSString stringWithFormat:@"0x%lx",
                             (unsigned long)method_getImplementation(methodList[i])]
                };
            }
            free(methodList);
        }
    }

    return @{
        @"className": className,
        @"instanceMethods": allMethods,
        @"classMethods": classMethods,
        @"instanceMethodCount": @(allMethods.count),
        @"classMethodCount": @(classMethods.count)
    };
}

NSDictionary *SpliceKit_handleSystemCallMethod(NSDictionary *params) {
    NSString *className = params[@"className"];
    NSString *selectorName = params[@"selector"];
    BOOL isClassMethod = [params[@"classMethod"] boolValue];

    if (!className || !selectorName)
        return @{@"error": @"className and selector required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    SEL selector = NSSelectorFromString(selectorName);

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id target = isClassMethod ? (id)cls : nil;

            if (!isClassMethod) {
                // For instance methods, we need an instance
                // Try common singleton patterns
                if ([cls respondsToSelector:@selector(sharedInstance)]) {
                    target = [cls performSelector:@selector(sharedInstance)];
                } else if ([cls respondsToSelector:@selector(shared)]) {
                    target = [cls performSelector:@selector(shared)];
                } else if ([cls respondsToSelector:@selector(defaultManager)]) {
                    target = [cls performSelector:@selector(defaultManager)];
                } else {
                    result = @{@"error": @"Cannot get instance. Use classMethod:true or provide an instance path"};
                    return;
                }
            }

            if (!target) {
                result = @{@"error": @"Target is nil"};
                return;
            }

            if (![target respondsToSelector:selector]) {
                result = @{@"error": [NSString stringWithFormat:@"%@ does not respond to %@",
                                      className, selectorName]};
                return;
            }

            // Get method signature for return type analysis
            NSMethodSignature *sig = isClassMethod
                ? [cls methodSignatureForSelector:selector]
                : [target methodSignatureForSelector:selector];
            const char *returnType = [sig methodReturnType];

            id returnValue = nil;

            // Handle based on return type
            if (returnType[0] == 'v') {
                // void return
                ((void (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @"void"};
            } else if (returnType[0] == 'B' || returnType[0] == 'c') {
                // BOOL return
                BOOL boolResult = ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @(boolResult)};
            } else if (returnType[0] == '@') {
                // Object return
                returnValue = ((id (*)(id, SEL))objc_msgSend)(target, selector);
                if (returnValue) {
                    result = @{
                        @"result": [returnValue description] ?: @"<nil description>",
                        @"class": NSStringFromClass([returnValue class])
                    };
                } else {
                    result = @{@"result": [NSNull null]};
                }
            } else if (returnType[0] == 'q' || returnType[0] == 'i' || returnType[0] == 'l') {
                // Integer return
                long long intResult = ((long long (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @(intResult)};
            } else if (returnType[0] == 'd') {
                // Double return
                double dblResult = ((double (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @(dblResult)};
            } else if (returnType[0] == 'f') {
                // Float return — must use float cast (x86_64 ABI returns float in XMM0[31:0])
                float fltResult = ((float (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @(fltResult)};
            } else {
                // Unknown type
                ((void (*)(id, SEL))objc_msgSend)(target, selector);
                result = @{@"result": @"<unknown return type>",
                           @"returnType": @(returnType)};
            }
        } @catch (NSException *exception) {
            result = @{
                @"error": [NSString stringWithFormat:@"Exception: %@ - %@",
                           exception.name, exception.reason]
            };
        }
    });

    return result;
}

NSDictionary *SpliceKit_handleSystemVersion(NSDictionary *params) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSOperatingSystemVersion osv = [[NSProcessInfo processInfo] operatingSystemVersion];
    NSString *osStr = [NSString stringWithFormat:@"%ld.%ld.%ld",
                       (long)osv.majorVersion, (long)osv.minorVersion, (long)osv.patchVersion];

    NSMutableDictionary *result = [@{
        @"splicekit_version": @SPLICEKIT_VERSION,
        @"fcp_version": info[@"CFBundleShortVersionString"] ?: @"unknown",
        @"fcp_build": info[@"CFBundleVersion"] ?: @"unknown",
        @"macos_version": osStr,
        @"pid": @(getpid()),
        @"arch": @
#if __arm64__
            "arm64"
#else
            "x86_64"
#endif
        ,
        @"swizzles": SpliceKit_getSwizzleResults(),
    } mutableCopy];

    // Uptime of this Final Cut Pro process: seconds since SpliceKit loaded into it,
    // which happens at launch (LC_LOAD_DYLIB, before main). -[NSProcessInfo
    // systemUptime], used before, is the Mac's time since boot.
    result[@"process_uptime_seconds"] = @((int)SpliceKit_secondsSinceLoad());

    // Add signing info
    SecStaticCodeRef staticCode = NULL;
    OSStatus codeErr = SecStaticCodeCreateWithPath(
        (__bridge CFURLRef)[[NSBundle mainBundle] bundleURL], kSecCSDefaultFlags, &staticCode);
    if (codeErr == errSecSuccess && staticCode) {
        CFDictionaryRef signingInfo = NULL;
        OSStatus infoErr = SecCodeCopySigningInformation(
            (SecCodeRef)staticCode, kSecCSSigningInformation, &signingInfo);
        if (infoErr == errSecSuccess && signingInfo) {
            NSString *teamID = ((__bridge NSDictionary *)signingInfo)[@"teamid"];
            result[@"signing_team"] = teamID ?: @"ad-hoc";
            CFRelease(signingInfo);
        }
        CFRelease(staticCode);
    }

    return result;
}

NSDictionary *SpliceKit_handleSystemSwizzle(NSDictionary *params) {
    // Swizzle is more complex -- for now just report capability
    return @{@"error": @"Swizzle requires compiled IMP. Use system.callMethod for direct calls."};
}

NSDictionary *SpliceKit_handleSystemGetProperties(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    NSMutableArray *properties = [NSMutableArray array];
    unsigned int count = 0;
    objc_property_t *propList = class_copyPropertyList(cls, &count);
    if (propList) {
        for (unsigned int i = 0; i < count; i++) {
            const char *name = property_getName(propList[i]);
            const char *attrs = property_getAttributes(propList[i]);
            [properties addObject:@{
                @"name": @(name),
                @"attributes": @(attrs)
            }];
        }
        free(propList);
    }

    return @{@"className": className, @"properties": properties, @"count": @(count)};
}

NSDictionary *SpliceKit_handleSystemGetProtocols(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    NSMutableArray *protocols = [NSMutableArray array];
    unsigned int count = 0;
    Protocol * __unsafe_unretained *protoList = class_copyProtocolList(cls, &count);
    if (protoList) {
        for (unsigned int i = 0; i < count; i++) {
            [protocols addObject:@(protocol_getName(protoList[i]))];
        }
        free(protoList);
    }

    return @{@"className": className, @"protocols": protocols, @"count": @(count)};
}

NSDictionary *SpliceKit_handleSystemGetSuperchain(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    NSMutableArray *chain = [NSMutableArray array];
    Class current = cls;
    while (current) {
        [chain addObject:NSStringFromClass(current)];
        current = class_getSuperclass(current);
    }

    return @{@"className": className, @"superchain": chain};
}

NSDictionary *SpliceKit_handleSystemGetIvars(NSDictionary *params) {
    NSString *className = params[@"className"];
    if (!className) return @{@"error": @"className required"};

    Class cls = objc_getClass([className UTF8String]);
    if (!cls) return @{@"error": [NSString stringWithFormat:@"Class %@ not found", className]};

    NSMutableArray *ivars = [NSMutableArray array];
    unsigned int count = 0;
    Ivar *ivarList = class_copyIvarList(cls, &count);
    if (ivarList) {
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivarList[i]);
            const char *type = ivar_getTypeEncoding(ivarList[i]);
            ptrdiff_t offset = ivar_getOffset(ivarList[i]);
            [ivars addObject:@{
                @"name": name ? @(name) : @"<anon>",
                @"type": type ? @(type) : @"?",
                @"offset": @(offset)
            }];
        }
        free(ivarList);
    }

    return @{@"className": className, @"ivars": ivars, @"count": @(count)};
}

#pragma mark - system.callMethodWithArgs
//
// The swiss army knife — call any ObjC method on any class/instance with
// typed arguments. This is what makes SpliceKit powerful enough to do
// anything FCP can do, even things we didn't anticipate.
//

// Figure out what object the caller wants to talk to.
// Could be a handle ("obj_42"), a class name for a class method,
// or a class name that we try to resolve to a singleton instance.
id SpliceKit_resolveTarget(NSDictionary *params) {
    NSString *target = params[@"target"] ?: params[@"className"];
    BOOL isClassMethod = [params[@"classMethod"] boolValue];

    if ([target hasPrefix:@"obj_"]) {
        return SpliceKit_resolveHandle(target);
    }

    Class cls = objc_getClass([target UTF8String]);
    if (!cls) return nil;

    if (isClassMethod) return (id)cls;

    // No explicit instance — try common singleton patterns
    for (NSString *sel in @[@"sharedInstance", @"shared", @"defaultManager",
                            @"sharedDocumentController", @"sharedApplication"]) {
        if ([cls respondsToSelector:NSSelectorFromString(sel)]) {
            return ((id (*)(id, SEL))objc_msgSend)((id)cls, NSSelectorFromString(sel));
        }
    }
    return nil;
}

// Safety valve: some FCP selectors crash if you pass nil for their error: parameter.
// We learned this the hard way — actionTrimDuration:forEdits:isDelta:error: crashes
// FCP when the trim is rejected and error: is NULL (it tries to write through the
// null pointer). Rather than letting callers accidentally nuke FCP, we block these
// known-bad combinations upfront.
static BOOL SpliceKit_isKnownUnsafeNilErrorSelector(NSString *selectorName, NSArray *args,
                                                    NSString **reason) {
    if (![selectorName isKindOfClass:[NSString class]]) return NO;
    if (![args isKindOfClass:[NSArray class]] || args.count == 0) return NO;

    static NSSet<NSString *> *unsafeSelectors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsafeSelectors = [NSSet setWithArray:@[
            @"actionTrimDuration:forEdits:isDelta:error:",
            @"operationTrimDuration:forEdits:isDelta:error:"
        ]];
    });

    if (![unsafeSelectors containsObject:selectorName]) return NO;

    NSDictionary *lastArg = [args.lastObject isKindOfClass:[NSDictionary class]] ? args.lastObject : nil;
    NSString *lastType = [lastArg[@"type"] isKindOfClass:[NSString class]] ? lastArg[@"type"] : @"nil";
    if (![lastType isEqualToString:@"nil"]) return NO;

    if (reason) {
        *reason = [NSString stringWithFormat:
                   @"Refusing %@ with nil error: pointer; this selector is known to crash Final Cut "
                   @"when the trim is constrained. Use a safe wrapper instead.",
                   selectorName];
    }
    return YES;
}

static BOOL SpliceKit_signatureExpectsObject(const char *sigType) {
    return sigType && sigType[0] == '@';
}

static BOOL SpliceKit_rejectScalarForObjectArgument(const char *sigType,
                                                    NSString *selectorName,
                                                    NSUInteger argIdx,
                                                    NSString *type,
                                                    NSDictionary **result) {
    if (!SpliceKit_signatureExpectsObject(sigType)) return NO;
    if (result) {
        *result = @{@"error": [NSString stringWithFormat:
            @"Refusing %@ argument %lu: caller supplied scalar type '%@' but selector expects an object",
            selectorName ?: @"selector",
            (unsigned long)(argIdx - 2),
            type ?: @"unknown"]};
    }
    return YES;
}

NSDictionary *SpliceKit_handleCallMethodWithArgs(NSDictionary *params) {
    NSString *targetName = params[@"target"] ?: params[@"className"];
    NSString *selectorName = params[@"selector"];
    NSArray *args = params[@"args"] ?: @[];
    BOOL returnHandle = [params[@"returnHandle"] boolValue];

    if (!targetName || !selectorName)
        return @{@"error": @"target and selector required"};

    __block NSDictionary *result = nil;

    SpliceKit_executeOnMainThread(^{
        @try {
            id target = SpliceKit_resolveTarget(params);
            if (!target) {
                result = @{@"error": [NSString stringWithFormat:@"Cannot resolve target: %@", targetName]};
                return;
            }

            SEL selector = NSSelectorFromString(selectorName);
            NSMethodSignature *sig = [target methodSignatureForSelector:selector];
            if (!sig) {
                result = @{@"error": [NSString stringWithFormat:@"%@ does not respond to %@",
                            targetName, selectorName]};
                return;
            }

            NSUInteger expectedArgs = [sig numberOfArguments] - 2;
            if (args.count != expectedArgs) {
                result = @{@"error": [NSString stringWithFormat:
                    @"Expected %lu args for %@, got %lu",
                    (unsigned long)expectedArgs, selectorName, (unsigned long)args.count]};
                return;
            }

            NSString *unsafeReason = nil;
            if (SpliceKit_isKnownUnsafeNilErrorSelector(selectorName, args, &unsafeReason)) {
                result = @{@"error": unsafeReason ?: @"Unsafe selector invocation blocked"};
                return;
            }

            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:target];
            [inv setSelector:selector];
            [inv retainArguments];

            // Set arguments
            for (NSUInteger i = 0; i < args.count; i++) {
                NSDictionary *arg = args[i];
                NSString *type = arg[@"type"] ?: @"nil";
                NSUInteger argIdx = i + 2;
                const char *sigType = [sig getArgumentTypeAtIndex:argIdx];

                if ([type isEqualToString:@"string"]) {
                    NSString *val = [arg[@"value"] description];
                    // setArgument: blindly memcpy's sigof(arg) bytes from the
                    // source pointer, so the layout of `val` must match the
                    // selector's expected ObjC type encoding. If the selector
                    // wants a C-string (`*` / `r*`) and we pass &NSString*, the
                    // callee later strlen()s the NSString's isa as if it were
                    // a char* and crashes deep inside _platform_strlen.
                    // See APPLE-MACOS-K.
                    if (sigType[0] == '*' || (sigType[0] == 'r' && sigType[1] == '*')) {
                        const char *cstr = [val UTF8String] ?: "";
                        [inv setArgument:&cstr atIndex:argIdx];
                    } else {
                        [inv setArgument:&val atIndex:argIdx];
                    }
                } else if ([type isEqualToString:@"int"]) {
                    if (SpliceKit_rejectScalarForObjectArgument(sigType, selectorName, argIdx, type, &result)) return;
                    long long val = [arg[@"value"] longLongValue];
                    if (sigType[0] == 'i') { int v = (int)val; [inv setArgument:&v atIndex:argIdx]; }
                    else if (sigType[0] == 'q') { [inv setArgument:&val atIndex:argIdx]; }
                    else if (sigType[0] == 'Q') { unsigned long long v = (unsigned long long)val; [inv setArgument:&v atIndex:argIdx]; }
                    else { [inv setArgument:&val atIndex:argIdx]; }
                } else if ([type isEqualToString:@"double"]) {
                    if (SpliceKit_rejectScalarForObjectArgument(sigType, selectorName, argIdx, type, &result)) return;
                    double val = [arg[@"value"] doubleValue];
                    if (sigType[0] == 'f') { float v = (float)val; [inv setArgument:&v atIndex:argIdx]; }
                    else { [inv setArgument:&val atIndex:argIdx]; }
                } else if ([type isEqualToString:@"float"]) {
                    if (SpliceKit_rejectScalarForObjectArgument(sigType, selectorName, argIdx, type, &result)) return;
                    float val = [arg[@"value"] floatValue];
                    [inv setArgument:&val atIndex:argIdx];
                } else if ([type isEqualToString:@"bool"]) {
                    if (SpliceKit_rejectScalarForObjectArgument(sigType, selectorName, argIdx, type, &result)) return;
                    BOOL val = [arg[@"value"] boolValue];
                    [inv setArgument:&val atIndex:argIdx];
                } else if ([type isEqualToString:@"nil"] || [type isEqualToString:@"sender"]) {
                    id val = nil;
                    [inv setArgument:&val atIndex:argIdx];
                } else if ([type isEqualToString:@"handle"]) {
                    id val = SpliceKit_resolveHandle(arg[@"value"]);
                    if (!val) {
                        result = @{@"error": [NSString stringWithFormat:
                            @"Handle not found: %@", arg[@"value"]]};
                        return;
                    }
                    [inv setArgument:&val atIndex:argIdx];
                } else if ([type isEqualToString:@"cmtime"]) {
                    NSDictionary *tv = arg[@"value"];
                    CMTime t = {
                        .value = [tv[@"value"] longLongValue],
                        .timescale = [tv[@"timescale"] intValue],
                        .flags = 1, .epoch = 0
                    };
                    [inv setArgument:&t atIndex:argIdx];
                } else if ([type isEqualToString:@"selector"]) {
                    SEL val = NSSelectorFromString(arg[@"value"]);
                    [inv setArgument:&val atIndex:argIdx];
                } else {
                    // Default: try as object (NSNull -> nil, otherwise wrap)
                    id val = nil;
                    [inv setArgument:&val atIndex:argIdx];
                }
            }

            [inv invoke];
            result = SpliceKit_serializeReturnValue(inv, returnHandle);
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@ - %@",
                        e.name, e.reason]};
        }
    });

    return result;
}

#pragma mark - Object Handlers

NSDictionary *SpliceKit_handleObjectGet(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    if (!handle) return @{@"error": @"handle required"};
    id obj = SpliceKit_resolveHandle(handle);
    if (!obj) return @{@"error": [NSString stringWithFormat:@"Handle not found: %@", handle]};
    return @{@"handle": handle, @"class": NSStringFromClass([obj class]),
             @"description": [[obj description] substringToIndex:
                 MIN((NSUInteger)500, [[obj description] length])], @"valid": @YES};
}

NSDictionary *SpliceKit_handleObjectRelease(NSDictionary *params) {
    if ([params[@"all"] boolValue]) {
        NSUInteger count = sHandleMap.count;
        SpliceKit_releaseAllHandles();
        return @{@"released": @(count)};
    }
    NSString *handle = params[@"handle"];
    if (!handle) return @{@"error": @"handle or all:true required"};
    BOOL existed = (SpliceKit_resolveHandle(handle) != nil);
    SpliceKit_releaseHandle(handle);
    return @{@"handle": handle, @"released": @(existed)};
}

NSDictionary *SpliceKit_handleObjectList(NSDictionary *params) {
    return SpliceKit_listHandles();
}

#pragma mark - KVC Property Access
//
// Key-Value Coding lets clients read/write properties on any ObjC object
// by name, without needing to know the exact selector. Super handy for
// exploring FCP's object graph interactively.
//

NSDictionary *SpliceKit_handleGetProperty(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *key = params[@"key"];
    BOOL returnHandle = [params[@"returnHandle"] boolValue];
    if (!handle || !key) return @{@"error": @"handle and key required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id obj = SpliceKit_resolveHandle(handle);
            if (!obj) { result = @{@"error": @"Handle not found"}; return; }

            id value = [obj valueForKey:key];
            if (!value) {
                result = @{@"key": key, @"result": [NSNull null]};
            } else if (returnHandle) {
                NSString *h = SpliceKit_storeHandle(value);
                result = @{@"key": key, @"handle": h,
                           @"class": NSStringFromClass([value class]),
                           @"description": [[value description] substringToIndex:
                               MIN((NSUInteger)500, [[value description] length])]};
            } else {
                result = @{@"key": key, @"result": [[value description] substringToIndex:
                               MIN((NSUInteger)2000, [[value description] length])],
                           @"class": NSStringFromClass([value class])};
            }
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"KVC error: %@", e.reason]};
        }
    });
    return result;
}

NSDictionary *SpliceKit_handleSetProperty(NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *key = params[@"key"];
    if (!handle || !key) return @{@"error": @"handle and key required"};

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id obj = SpliceKit_resolveHandle(handle);
            if (!obj) { result = @{@"error": @"Handle not found"}; return; }

            NSDictionary *valSpec = params[@"value"];
            NSString *type = valSpec[@"type"] ?: @"string";
            id value = nil;
            if ([type isEqualToString:@"string"]) value = valSpec[@"value"];
            else if ([type isEqualToString:@"int"]) value = @([valSpec[@"value"] longLongValue]);
            else if ([type isEqualToString:@"double"]) value = @([valSpec[@"value"] doubleValue]);
            else if ([type isEqualToString:@"bool"]) value = @([valSpec[@"value"] boolValue]);
            else if ([type isEqualToString:@"nil"]) value = nil;

            [obj setValue:value forKey:key];
            result = @{@"key": key, @"status": @"ok",
                       @"warning": @"Direct KVC may bypass undo. Use action pattern for undoable edits."};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"KVC error: %@", e.reason]};
        }
    });
    return result;
}
