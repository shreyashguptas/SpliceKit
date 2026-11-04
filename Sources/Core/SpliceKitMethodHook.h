//
//  SpliceKitMethodHook.h
//  A replacement implementation that runs a block and then calls the original method with
//  the same arguments, returning what it returns. debug.traceMethod and debug.breakpoint
//  hook FCP's methods with it.
//
//  It forwards the argument registers unchanged rather than reading the arguments, so one
//  hook serves every signature whose arguments all travel in registers: objects, integers,
//  pointers, selectors, floats and doubles, and the structs the calling convention passes
//  in registers (CGPoint, CGRect, NSRange...). SpliceKit_hookSignatureProblem says which
//  signatures those are; anything else is refused, never hooked. Variadic methods cannot be
//  told apart by their type encoding, so it refuses them by name (...Format:, ...Objects:).
//
//  Everything declared here is hidden: it never shows up in the dylib's exports.
//

#ifndef SpliceKitMethodHook_h
#define SpliceKitMethodHook_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma GCC visibility push(hidden)

// Runs before the original on every call. `firstArgument` is the first argument after
// self and _cmd when it is an object, else nil.
typedef void (^SpliceKitHookBefore)(id self, id firstArgument);

// nil when this method can be hooked; otherwise why not, in a sentence for the caller (an
// argument passed on the stack, a large struct returned through memory, a memory
// management method the hook itself would call...).
NSString *SpliceKit_hookSignatureProblem(SEL selector, const char *typeEncoding);

// The replacement IMP, or NULL when SpliceKit_hookSignatureProblem has a problem with the
// method. It calls `original` with `selector` and the caller's arguments; when
// `lookupClass` is set it calls that class's current implementation instead, looked up on
// every call (for a method the hooked class only inherits). `before` is skipped when it is
// already running on this thread (a traced -description that the trace itself calls, say),
// so a hook never recurses into itself.
IMP SpliceKit_makeForwardingHook(const char *typeEncoding, IMP original, Class lookupClass,
                                 SEL selector, SpliceKitHookBefore before);

// Runs `work` with every hook's `before` skipped on this thread: for the code that records
// what a hook saw, so tracing a method that code calls cannot feed on itself.
void SpliceKit_hookWithoutBefore(dispatch_block_t work);

#pragma GCC visibility pop

#endif /* SpliceKitMethodHook_h */
