//
//  SpliceKitMethodHook.m
//  The forwarding hook declared in SpliceKitMethodHook.h.
//
//  The hook is a block made into an IMP. When FCP calls the method, the arguments sit in
//  registers: on arm64 x2-x7 for integers, pointers and objects (x0 and x1 are self and
//  _cmd, which the block trampoline turns into the block and self) and v0-v7 for floats,
//  doubles and the float structs (HFAs) such as CGRect; on x86_64 rdx-r9 and xmm0-xmm7.
//  The block declares all of them, so it receives the caller's registers unread and passes
//  them on in the same order. Integer and floating-point registers are assigned
//  independently, so this holds however the two kinds are interleaved. Its return type is
//  picked to come back in the same registers as the original's.
//
//  What cannot be forwarded this way is refused: arguments that spill onto the stack, and
//  structs returned through memory (and, on x86_64, any struct).
//

#import "SpliceKitMethodHook.h"

#if defined(__arm64__)
static const NSUInteger kHookIntegerRegisters = 6;   // x2-x7
#else
static const NSUInteger kHookIntegerRegisters = 4;   // rdx, rcx, r8, r9
#endif
static const NSUInteger kHookFloatRegisters = 8;     // v0-v7 / xmm0-xmm7

typedef NS_ENUM(NSInteger, SpliceKitHookReturn) {
    SpliceKitHookReturnVoid,
    SpliceKitHookReturnInteger,  // x0 / rax: objects, pointers, integers, BOOL
    SpliceKitHookReturnDouble,   // v0 / xmm0: float, double
    SpliceKitHookReturnFloats,   // v0-v3: a struct of up to four floats or doubles (arm64)
    SpliceKitHookReturnPair,     // x0-x1: any other struct of up to 16 bytes (arm64)
};

typedef struct { double a, b, c, d; } SpliceKitHookFloats;
typedef struct { uintptr_t a, b; } SpliceKitHookPair;

// Calls the hook makes on self on its own behalf, so hooking them would recurse or touch
// an object that is going away.
static NSSet<NSString *> *SpliceKit_hookRefusedSelectors(void) {
    static NSSet *refused;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        refused = [NSSet setWithArray:@[@"retain", @"release", @"autorelease", @"retainCount",
                                        @"dealloc", @".cxx_destruct", @"_tryRetain",
                                        @"_isDeallocating", @"allowsWeakReference",
                                        @"retainWeakReference"]];
    });
    return refused;
}

// Variadic methods (stringWithFormat:, arrayWithObjects:...) pass their extra arguments on
// the stack, and their type encoding does not say so. Apple names them after what the
// list holds, so a last selector part ending in one of these is refused.
static BOOL SpliceKit_hookLooksVariadic(NSString *selectorName) {
    NSArray<NSString *> *parts = [selectorName componentsSeparatedByString:@":"];
    if (parts.count < 2) return NO;  // no arguments
    NSString *last = [parts[parts.count - 2] lowercaseString];
    for (NSString *ending in @[@"format", @"objects", @"objectsandkeys", @"keysandobjects",
                               @"values", @"arguments"]) {
        if ([last hasSuffix:ending]) return YES;
    }
    return NO;
}

static const char *SpliceKit_hookSkipQualifiers(const char *type) {
    while (*type && strchr("rnNoORVA", *type)) type++;
    return type;
}

// long double: a double on Apple silicon; on Intel 80 bits on the stack and in st(0).
static BOOL SpliceKit_hookIsRegisterDouble(char c) {
#if defined(__arm64__)
    return c == 'D';
#else
    return NO;
#endif
}

static BOOL SpliceKit_hookIsIntegerClass(char c) {
    return c && strchr("cCsSiIlLqQB*#:@^?", c) != NULL;
}

// Reads one type at *cursor and counts its float leaves. NO when it holds anything else.
static BOOL SpliceKit_hookCountFloatLeaves(const char **cursor, char *kind, NSUInteger *count) {
    const char *p = SpliceKit_hookSkipQualifiers(*cursor);
    char c = *p;
    if (c == 'f' || c == 'd' || SpliceKit_hookIsRegisterDouble(c)) {
        char leaf = (c == 'f') ? 'f' : 'd';
        if (*kind && *kind != leaf) return NO;
        *kind = leaf;
        (*count)++;
        *cursor = p + 1;
        return YES;
    }
    if (c == '{') {
        p++;
        while (*p && *p != '=' && *p != '}') p++;
        if (*p != '=') return NO;  // an opaque struct: its members are unknown
        p++;
        while (*p && *p != '}') {
            if (*p == '"') {        // a member name
                p = strchr(p + 1, '"');
                if (!p) return NO;
                p++;
                continue;
            }
            if (!SpliceKit_hookCountFloatLeaves(&p, kind, count)) return NO;
        }
        if (*p != '}') return NO;
        *cursor = p + 1;
        return YES;
    }
    if (c == '[') {
        p++;
        NSUInteger elements = 0;
        while (*p >= '0' && *p <= '9') elements = elements * 10 + (NSUInteger)(*p++ - '0');
        NSUInteger before = *count;
        if (!SpliceKit_hookCountFloatLeaves(&p, kind, count)) return NO;
        if (*p != ']') return NO;
        *count = before + (*count - before) * elements;
        *cursor = p + 1;
        return YES;
    }
    return NO;
}

// The number of float registers a struct of only floats or only doubles takes (an HFA:
// one to four members), else 0.
static NSUInteger SpliceKit_hookFloatStructMembers(const char *type) {
    char kind = 0;
    NSUInteger count = 0;
    const char *cursor = type;
    if (!SpliceKit_hookCountFloatLeaves(&cursor, &kind, &count)) return 0;
    return (count >= 1 && count <= 4) ? count : 0;
}

static BOOL SpliceKit_hookSizeOf(const char *type, NSUInteger *size, NSUInteger *alignment) {
    @try {
        NSGetSizeAndAlignment(type, size, alignment);
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

// Classifies the method; nil when the hook can forward it.
static NSString *SpliceKit_hookClassify(SEL selector, const char *typeEncoding,
                                        SpliceKitHookReturn *returnKind, BOOL *firstIsObject) {
    if (!selector || !typeEncoding) return @"The method has no selector or type encoding.";
    NSString *name = NSStringFromSelector(selector);
    if ([SpliceKit_hookRefusedSelectors() containsObject:name]) {
        return [NSString stringWithFormat:@"-%@ is memory management the hook itself relies on; "
                "hooking it would recurse.", name];
    }
    if (SpliceKit_hookLooksVariadic(name)) {
        return [NSString stringWithFormat:@"%@ looks like a method that takes a variable list of "
                "arguments (a format string or an object list); those arrive on the stack, which "
                "the hook does not forward.", name];
    }

    NSMethodSignature *sig = nil;
    @try {
        sig = [NSMethodSignature signatureWithObjCTypes:typeEncoding];
    } @catch (NSException *e) {
        sig = nil;
    }
    if (!sig) {
        return [NSString stringWithFormat:@"The type encoding %s cannot be read.", typeEncoding];
    }

    NSUInteger integers = 0, floats = 0;
    if (firstIsObject) *firstIsObject = NO;
    for (NSUInteger i = 2; i < sig.numberOfArguments; i++) {
        const char *type = SpliceKit_hookSkipQualifiers([sig getArgumentTypeAtIndex:i]);
        char c = *type;
        if (i == 2 && firstIsObject) *firstIsObject = (c == '@');
        if (SpliceKit_hookIsIntegerClass(c)) {
            integers++;
        } else if (c == 'f' || c == 'd' || SpliceKit_hookIsRegisterDouble(c)) {
            floats++;
        } else if (c == '{') {
#if defined(__arm64__)
            NSUInteger size = 0, alignment = 0;
            NSUInteger members = SpliceKit_hookFloatStructMembers(type);
            if (members) {
                floats += members;
            } else if (!SpliceKit_hookSizeOf(type, &size, &alignment) || alignment > 8) {
                return [NSString stringWithFormat:@"Argument %lu (%s) is a struct the hook cannot "
                        "place in registers.", (unsigned long)(i - 1), type];
            } else {
                integers += (size <= 16) ? (size + 7) / 8 : 1;  // larger ones go as a pointer
            }
#else
            return [NSString stringWithFormat:@"Argument %lu (%s) is a struct; on Intel the hook "
                    "forwards only objects, integers, pointers and floating-point numbers.",
                    (unsigned long)(i - 1), type];
#endif
        } else {
            return [NSString stringWithFormat:@"Argument %lu has the type %s, which the hook "
                    "cannot forward.", (unsigned long)(i - 1), type];
        }
        if (integers > kHookIntegerRegisters || floats > kHookFloatRegisters) {
            return [NSString stringWithFormat:@"The method takes more arguments than fit in "
                    "registers (at most %lu integer or object arguments and %lu floating-point "
                    "ones); the rest would be on the stack, which the hook does not forward.",
                    (unsigned long)kHookIntegerRegisters, (unsigned long)kHookFloatRegisters];
        }
    }

    const char *ret = SpliceKit_hookSkipQualifiers(sig.methodReturnType);
    char r = *ret;
    SpliceKitHookReturn kind;
    if (r == 'v') {
        kind = SpliceKitHookReturnVoid;
    } else if (SpliceKit_hookIsIntegerClass(r)) {
        kind = SpliceKitHookReturnInteger;
    } else if (r == 'f' || r == 'd' || SpliceKit_hookIsRegisterDouble(r)) {
        kind = SpliceKitHookReturnDouble;
    } else if (r == '{') {
#if defined(__arm64__)
        NSUInteger size = 0, alignment = 0;
        if (SpliceKit_hookFloatStructMembers(ret)) {
            kind = SpliceKitHookReturnFloats;
        } else if (SpliceKit_hookSizeOf(ret, &size, &alignment) && size <= 16) {
            kind = SpliceKitHookReturnPair;
        } else {
            return [NSString stringWithFormat:@"The method returns %s, a struct returned through "
                    "memory, which the hook does not forward.", ret];
        }
#else
        return [NSString stringWithFormat:@"The method returns a struct (%s); on Intel the hook "
                "forwards only objects, integers, pointers and floating-point numbers.", ret];
#endif
    } else {
        return [NSString stringWithFormat:@"The method returns the type %s, which the hook cannot "
                "forward.", ret];
    }
    if (returnKind) *returnKind = kind;
    return nil;
}

NSString *SpliceKit_hookSignatureProblem(SEL selector, const char *typeEncoding) {
    return SpliceKit_hookClassify(selector, typeEncoding, NULL, NULL);
}

// How deep this thread is in `before` blocks: a hooked method called from a `before`
// block goes straight to its original.
static __thread NSUInteger sHookDepth = 0;

void SpliceKit_hookWithoutBefore(dispatch_block_t work) {
    if (!work) return;
    sHookDepth++;
    @try {
        work();
    } @finally {
        sHookDepth--;
    }
}

// The implementation the hook forwards to: the superclass's current one for a method the
// class only inherits, so a later change there still reaches it.
static inline IMP SpliceKit_hookTarget(IMP original, Class lookupClass, SEL selector) {
    return lookupClass ? class_getMethodImplementation(lookupClass, selector) : original;
}

static void SpliceKit_hookRunBefore(SpliceKitHookBefore before, id self, uintptr_t first,
                                    BOOL firstIsObject) {
    if (!before || sHookDepth > 0) return;
    sHookDepth++;
    @try {
        before(self, firstIsObject ? (__bridge id)(void *)first : nil);
    } @finally {
        sHookDepth--;
    }
}

// Every argument register, in order, then the original called with the same.
#define SK_HOOK_PARAMS __unsafe_unretained id receiver, uintptr_t a2, uintptr_t a3, uintptr_t a4, \
    uintptr_t a5, uintptr_t a6, uintptr_t a7, double d0, double d1, double d2, double d3, \
    double d4, double d5, double d6, double d7
#define SK_HOOK_PARAM_TYPES id, SEL, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, \
    uintptr_t, double, double, double, double, double, double, double, double
#define SK_HOOK_ARGS receiver, selector, a2, a3, a4, a5, a6, a7, d0, d1, d2, d3, d4, d5, d6, d7

IMP SpliceKit_makeForwardingHook(const char *typeEncoding, IMP original, Class lookupClass,
                                 SEL selector, SpliceKitHookBefore before) {
    SpliceKitHookReturn kind = SpliceKitHookReturnVoid;
    BOOL firstIsObject = NO;
    if ((!original && !lookupClass) ||
        SpliceKit_hookClassify(selector, typeEncoding, &kind, &firstIsObject)) {
        return NULL;
    }
    SpliceKitHookBefore runBefore = [before copy];

    switch (kind) {
        case SpliceKitHookReturnVoid:
            return imp_implementationWithBlock(^(SK_HOOK_PARAMS) {
                SpliceKit_hookRunBefore(runBefore, receiver, a2, firstIsObject);
                ((void (*)(SK_HOOK_PARAM_TYPES))SpliceKit_hookTarget(original, lookupClass, selector))(SK_HOOK_ARGS);
            });
        case SpliceKitHookReturnInteger:
            return imp_implementationWithBlock(^uintptr_t(SK_HOOK_PARAMS) {
                SpliceKit_hookRunBefore(runBefore, receiver, a2, firstIsObject);
                return ((uintptr_t (*)(SK_HOOK_PARAM_TYPES))SpliceKit_hookTarget(original, lookupClass, selector))(SK_HOOK_ARGS);
            });
        case SpliceKitHookReturnDouble:
            return imp_implementationWithBlock(^double(SK_HOOK_PARAMS) {
                SpliceKit_hookRunBefore(runBefore, receiver, a2, firstIsObject);
                return ((double (*)(SK_HOOK_PARAM_TYPES))SpliceKit_hookTarget(original, lookupClass, selector))(SK_HOOK_ARGS);
            });
        case SpliceKitHookReturnFloats:
            return imp_implementationWithBlock(^SpliceKitHookFloats(SK_HOOK_PARAMS) {
                SpliceKit_hookRunBefore(runBefore, receiver, a2, firstIsObject);
                return ((SpliceKitHookFloats (*)(SK_HOOK_PARAM_TYPES))SpliceKit_hookTarget(original, lookupClass, selector))(SK_HOOK_ARGS);
            });
        case SpliceKitHookReturnPair:
            return imp_implementationWithBlock(^SpliceKitHookPair(SK_HOOK_PARAMS) {
                SpliceKit_hookRunBefore(runBefore, receiver, a2, firstIsObject);
                return ((SpliceKitHookPair (*)(SK_HOOK_PARAM_TYPES))SpliceKit_hookTarget(original, lookupClass, selector))(SK_HOOK_ARGS);
            });
    }
    return NULL;
}
