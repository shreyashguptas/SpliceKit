//
//  method_hook_test.m
//  Offline checks for the forwarding hook in Sources/Core/SpliceKitMethodHook.m, built and
//  run by tests/test_method_hook.py (no Final Cut Pro needed).
//
//  Hooks methods of many signatures on a test class, calls them, and checks that every
//  argument reaches the original, every return value reaches the caller, the `before`
//  block sees self and the first object argument, and unsupported signatures are refused.
//
//  method_hook_test check    run the assertions; exit 1 on any failure
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "SpliceKitMethodHook.h"

typedef struct { long a, b, c; } HookTestBig;            // 24 bytes: passed by pointer
typedef struct { float x, y; } HookTestFloatPair;         // a float HFA
typedef struct { int32_t i; float f; } HookTestMixed;     // 8 bytes, not an HFA

@interface HookTestTarget : NSObject
@property (nonatomic, strong) NSMutableArray *calls;
@end

@implementation HookTestTarget
- (instancetype)init { if ((self = [super init])) _calls = [NSMutableArray array]; return self; }
- (id)echo:(id)object { return object; }
- (BOOL)flip:(BOOL)flag { return !flag; }
- (NSInteger)sumA:(NSInteger)a b:(NSInteger)b c:(NSInteger)c d:(NSInteger)d e:(NSInteger)e f:(NSInteger)f {
    return a + 10 * b + 100 * c + 1000 * d + 10000 * e + 100000 * f;
}
- (double)mixInt:(NSInteger)i number:(double)d single:(float)f object:(NSString *)o {
    return (double)i + d + (double)f + (double)o.length;
}
- (float)half:(float)x { return x / 2.0f; }
- (NSRect)offsetRect:(NSRect)r by:(CGFloat)dx { return NSOffsetRect(r, dx, dx * 2); }
- (NSPoint)pointX:(double)x y:(double)y { return NSMakePoint(x, y); }
- (NSRange)shiftRange:(NSRange)r by:(NSUInteger)n { return NSMakeRange(r.location + n, r.length * 2); }
- (long)sumBig:(HookTestBig)big { return big.a + big.b + big.c; }
- (HookTestFloatPair)swapFloats:(HookTestFloatPair)p { return (HookTestFloatPair){p.y, p.x}; }
- (HookTestMixed)mixed:(int32_t)i { return (HookTestMixed){i * 2, (float)i / 4.0f}; }
- (void)recordObject:(id)o count:(NSInteger)n { [self.calls addObject:@[o ?: [NSNull null], @(n)]]; }
- (NSString *)descriptionOf:(id)o { return [NSString stringWithFormat:@"<%@>", o]; }
- (HookTestBig)makeBig { return (HookTestBig){1, 2, 3}; }
- (NSInteger)seven:(NSInteger)a :(NSInteger)b :(NSInteger)c :(NSInteger)d :(NSInteger)e :(NSInteger)f :(NSInteger)g {
    return a + b + c + d + e + f + g;
}
+ (NSString *)classEcho:(NSString *)s { return [s stringByAppendingString:@"!"]; }
- (NSString *)textWithFormat:(NSString *)format, ... { return format; }
- (NSString *)greeting { return @"base"; }
@end

@interface HookTestChild : HookTestTarget
@end

@implementation HookTestChild
@end

static NSString *HookTestReplacementGreeting(id self, SEL _cmd) { return @"replaced"; }

static int sFailures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } \
} while (0)

// Hooks -[cls sel] (or the metaclass's) and records each `before` call.
static NSMutableArray *sBefore;

static BOOL Hook(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *types = method_getTypeEncoding(m);
    IMP hook = SpliceKit_makeForwardingHook(types, method_getImplementation(m), Nil, sel,
        ^(id self, id firstArgument) {
            [sBefore addObject:@[NSStringFromSelector(sel), self ?: [NSNull null],
                                 firstArgument ?: [NSNull null]]];
        });
    if (!hook) return NO;
    method_setImplementation(m, hook);
    return YES;
}

static NSString *Problem(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    return SpliceKit_hookSignatureProblem(sel, method_getTypeEncoding(m));
}

static void CheckForwarding(void) {
    Class cls = [HookTestTarget class];
    SEL sels[] = {
        @selector(echo:), @selector(flip:), @selector(sumA:b:c:d:e:f:),
        @selector(mixInt:number:single:object:), @selector(half:), @selector(offsetRect:by:),
        @selector(pointX:y:), @selector(shiftRange:by:), @selector(sumBig:),
        @selector(swapFloats:), @selector(mixed:), @selector(recordObject:count:),
    };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        CHECK(Hook(cls, sels[i]), "could not hook %s: %s", sel_getName(sels[i]),
              [Problem(cls, sels[i]) UTF8String] ?: "no reason");
    }
    CHECK(Hook(object_getClass(cls), @selector(classEcho:)), "could not hook +classEcho:");

    HookTestTarget *t = [HookTestTarget new];
    NSString *word = [NSString stringWithFormat:@"word-%d", 42];

    CHECK([t echo:word] == word, "echo: returned a different object");
    CHECK([t flip:NO] == YES && [t flip:YES] == NO, "flip: lost its BOOL");
    CHECK([t sumA:1 b:2 c:3 d:4 e:5 f:6] == 654321, "sumA:...f: got %ld",
          (long)[t sumA:1 b:2 c:3 d:4 e:5 f:6]);
    double mixed = [t mixInt:7 number:0.25 single:0.5f object:@"abc"];
    CHECK(mixed == 10.75, "mixInt:number:single:object: got %f", mixed);
    CHECK([t half:5.0f] == 2.5f, "half: got %f", [t half:5.0f]);
    NSRect r = [t offsetRect:NSMakeRect(1, 2, 3, 4) by:10];
    CHECK(NSEqualRects(r, NSMakeRect(11, 22, 3, 4)), "offsetRect:by: got %s",
          NSStringFromRect(r).UTF8String);
    NSPoint pt = [t pointX:1.5 y:-2.5];
    CHECK(pt.x == 1.5 && pt.y == -2.5, "pointX:y: got %s", NSStringFromPoint(pt).UTF8String);
    NSRange range = [t shiftRange:NSMakeRange(5, 3) by:2];
    CHECK(range.location == 7 && range.length == 6, "shiftRange:by: got %s",
          NSStringFromRange(range).UTF8String);
    HookTestBig big = {100, 20, 3};
    long bigSum = [t sumBig:big];
    CHECK(bigSum == 123, "sumBig: got %ld", bigSum);
    HookTestFloatPair pair = {1.25f, 2.5f};
    HookTestFloatPair swapped = [t swapFloats:pair];
    CHECK(swapped.x == 2.5f && swapped.y == 1.25f, "swapFloats: got %f %f", swapped.x, swapped.y);
    HookTestMixed m = [t mixed:6];
    CHECK(m.i == 12 && m.f == 1.5f, "mixed: got %d %f", m.i, m.f);
    [t recordObject:word count:9];
    CHECK([t.calls.lastObject isEqual:(@[word, @9])], "recordObject:count: recorded %s",
          [t.calls.lastObject description].UTF8String);
    CHECK([[HookTestTarget classEcho:@"hi"] isEqualToString:@"hi!"], "+classEcho: lost its result");

    // `before` saw self and the first argument when it is an object
    NSArray *echoCall = nil, *flipCall = nil, *classCall = nil;
    for (NSArray *call in sBefore) {
        if ([call[0] isEqualToString:@"echo:"]) echoCall = call;
        if ([call[0] isEqualToString:@"flip:"]) flipCall = call;
        if ([call[0] isEqualToString:@"classEcho:"]) classCall = call;
    }
    CHECK(echoCall && echoCall[1] == t && echoCall[2] == word, "before for echo: saw %s",
          echoCall.description.UTF8String);
    CHECK(flipCall && flipCall[2] == [NSNull null], "before for flip: saw a first object");
    CHECK(classCall && classCall[1] == cls, "before for +classEcho: saw %s",
          classCall.description.UTF8String);
}

static void CheckRecursion(void) {
    // A `before` block that calls the hooked method itself runs once, not forever
    Class cls = [HookTestTarget class];
    SEL sel = @selector(descriptionOf:);
    Method m = class_getInstanceMethod(cls, sel);
    __block NSUInteger runs = 0;
    IMP hook = SpliceKit_makeForwardingHook(method_getTypeEncoding(m), method_getImplementation(m), Nil, sel,
        ^(id self, id firstArgument) {
            runs++;
            [(HookTestTarget *)self descriptionOf:@"inner"];
        });
    method_setImplementation(m, hook);
    NSString *result = [[HookTestTarget new] descriptionOf:@"outer"];
    CHECK([result isEqualToString:@"<outer>"], "descriptionOf: got %s", result.UTF8String);
    CHECK(runs == 1, "before ran %lu times", (unsigned long)runs);
}

static void CheckRefusals(void) {
    Class cls = [HookTestTarget class];
    CHECK(Problem(cls, @selector(makeBig)) != nil, "a struct returned through memory was accepted");
    CHECK(Problem(cls, @selector(seven:::::::)) != nil, "seven integer arguments were accepted");
    CHECK(Problem(cls, NSSelectorFromString(@"retain")) != nil, "-retain was accepted");
    CHECK(Problem(cls, @selector(echo:)) == nil, "echo: was refused");
    CHECK(Problem(cls, @selector(textWithFormat:)) != nil, "a variadic ...WithFormat: method was accepted");
    CHECK(SpliceKit_hookSignatureProblem(@selector(arrayWithObjects:), "@24@0:8@16") != nil,
          "arrayWithObjects: was accepted");
    CHECK(SpliceKit_hookSignatureProblem(@selector(raise:format:), "v32@0:8@16@24") != nil,
          "raise:format: was accepted");
    Method big = class_getInstanceMethod(cls, @selector(makeBig));
    CHECK(SpliceKit_makeForwardingHook(method_getTypeEncoding(big), method_getImplementation(big),
                                       Nil, @selector(makeBig), nil) == NULL,
          "a hook was made for a refused method");
    CHECK(SpliceKit_hookSignatureProblem(@selector(echo:), "this is not an encoding") != nil,
          "a garbage encoding was accepted");
}

static void CheckInheritedLookup(void) {
    // A hook on a subclass for an inherited method forwards to the superclass's current
    // implementation, so a later change there still reaches subclass callers.
    Class child = [HookTestChild class];
    Class parent = [HookTestTarget class];
    SEL sel = @selector(greeting);
    Method m = class_getInstanceMethod(parent, sel);
    __block NSUInteger runs = 0;
    IMP hook = SpliceKit_makeForwardingHook(method_getTypeEncoding(m), NULL, parent, sel,
        ^(id self, id firstArgument) { runs++; });
    CHECK(hook != NULL, "no hook for an inherited method");
    CHECK(class_addMethod(child, sel, hook, method_getTypeEncoding(m)), "could not add the hook to the subclass");
    HookTestChild *c = [HookTestChild new];
    CHECK([[c greeting] isEqualToString:@"base"], "inherited greeting got %s", [c greeting].UTF8String);
    method_setImplementation(m, (IMP)HookTestReplacementGreeting);
    CHECK([[c greeting] isEqualToString:@"replaced"], "the hook kept the old superclass implementation");
    CHECK([[[HookTestTarget new] greeting] isEqualToString:@"replaced"], "the superclass itself was hooked");
    CHECK(runs == 2, "before ran %lu times on the subclass", (unsigned long)runs);
}

static void CheckWithoutBefore(void) {
    // Code run through SpliceKit_hookWithoutBefore does not set off hooks' before blocks
    Class cls = [HookTestTarget class];
    __block NSUInteger runs = 0;
    SEL sel = @selector(half:);
    Method m = class_getInstanceMethod(cls, sel);
    IMP hook = SpliceKit_makeForwardingHook(method_getTypeEncoding(m), method_getImplementation(m), Nil, sel,
        ^(id self, id firstArgument) { runs++; });
    method_setImplementation(m, hook);
    HookTestTarget *t = [HookTestTarget new];
    __block float inside = 0;
    SpliceKit_hookWithoutBefore(^{ inside = [t half:8.0f]; });
    CHECK(inside == 4.0f, "half: inside hookWithoutBefore got %f", inside);
    CHECK(runs == 0, "before ran inside hookWithoutBefore");
    [t half:2.0f];
    CHECK(runs == 1, "before did not run afterwards");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2 || strcmp(argv[1], "check") != 0) {
            fprintf(stderr, "usage: method_hook_test check\n");
            return 2;
        }
        sBefore = [NSMutableArray array];
        CheckForwarding();
        CheckRecursion();
        CheckRefusals();
        CheckInheritedLookup();
        CheckWithoutBefore();
        if (sFailures) return 1;
        printf("ok\n");
        return 0;
    }
}
