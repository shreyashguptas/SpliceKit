//
//  SpliceKitTranscriptTextView.m
//  The transcript text view: clicks, keyboard deletes and word drag-and-drop,
//  forwarded to the panel.
//

#import "SpliceKitTranscriptPanel+Private.h"

#pragma mark - Custom Text View for Transcript
//
// We subclass NSTextView to intercept mouse and keyboard events.
// Clicks jump the playhead. Drags reorder clips. Delete key removes
// video segments. Spacebar and J/K/L get forwarded to FCP for transport control.
//

// J / K / L as FCP's command set sends them (NSProCommands.plist: JogBackward, Stop,
// JogForward): one action when the key goes down and one when it comes up, so holding J
// or L shuttles the way it does in the timeline. They are sent rather than re-posted as a
// key event: docked, this view is in FCP's main window, so a re-posted key would come
// straight back to it.
static const NSEventModifierFlags SpliceKitTranscriptCommandModifiers =
    NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption |
    NSEventModifierFlagCommand;

static NSDictionary<NSString *, NSArray<NSString *> *> *SpliceKit_transcriptTransportCommands(void) {
    return @{
        @"j": @[@"rewindDown:", @"rewindUp:"],
        @"k": @[@"stopPlayingDown:", @"stopPlayingUp:"],
        @"l": @[@"fastForwardDown:", @"fastForwardUp:"],
    };
}

@implementation SpliceKitTranscriptTextView

- (void)awakeFromNib {
    [super awakeFromNib];
    [self registerForDraggedTypes:@[SpliceKitTranscriptWordDragType]];
}

- (void)setupDragTypes {
    [self registerForDraggedTypes:@[SpliceKitTranscriptWordDragType]];
}

- (void)mouseDown:(NSEvent *)event {
    self.dragOrigin = [self convertPoint:event.locationInWindow fromView:nil];
    self.isDragging = NO;

    // If clicking inside an existing selection, prepare for potential drag
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];
    NSRange sel = self.selectedRange;
    if (sel.length > 0 && charIdx >= sel.location && charIdx < NSMaxRange(sel)) {
        return;
    }

    // Normal click — let NSTextView handle selection, then jump playhead
    [super mouseDown:event];
    charIdx = [self characterIndexForInsertionAtPoint:point];
    [self.transcriptPanel handleClickAtCharIndex:charIdx];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dx = point.x - self.dragOrigin.x;
    CGFloat dy = point.y - self.dragOrigin.y;

    // Check drag threshold (5px)
    if (!self.isDragging && (dx*dx + dy*dy) > 25) {
        NSRange sel = self.selectedRange;
        if (sel.length > 0) {
            self.isDragging = YES;
            [self startDragFromSelection:event];
            return;
        }
    }

    if (!self.isDragging) {
        [super mouseDragged:event];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (!self.isDragging) {
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];
        NSRange sel = self.selectedRange;
        if (sel.length > 0 && charIdx >= sel.location && charIdx < NSMaxRange(sel)) {
            [self.transcriptPanel handleClickAtCharIndex:charIdx];
        }
    }
    self.isDragging = NO;
    [super mouseUp:event];
}

- (void)startDragFromSelection:(NSEvent *)event {
    NSRange sel = self.selectedRange;
    if (sel.length == 0) return;

    NSRange wordRange = [self.transcriptPanel selectedWordRange];
    if (wordRange.length == 0) return;

    NSString *data = [NSString stringWithFormat:@"%lu,%lu",
        (unsigned long)wordRange.location, (unsigned long)wordRange.length];
    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setString:data forType:SpliceKitTranscriptWordDragType];

    NSString *dragText = [[self.textStorage string] substringWithRange:sel];

    NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:16],
        NSForegroundColorAttributeName: [NSColor labelColor],
        NSBackgroundColorAttributeName: [NSColor colorWithCalibratedRed:0.2 green:0.5 blue:1.0 alpha:0.3],
    };
    NSAttributedString *dragAttr = [[NSAttributedString alloc] initWithString:dragText attributes:attrs];
    NSSize textSize = [dragAttr size];
    textSize.width = MIN(textSize.width, 300);
    textSize.height = MAX(textSize.height, 20);
    NSImage *dragImage = [[NSImage alloc] initWithSize:textSize];
    [dragImage lockFocus];
    [dragAttr drawInRect:NSMakeRect(0, 0, textSize.width, textSize.height)];
    [dragImage unlockFocus];

    NSPoint dragPoint = [self convertPoint:event.locationInWindow fromView:nil];
    [dragItem setDraggingFrame:NSMakeRect(dragPoint.x, dragPoint.y - textSize.height,
                                           textSize.width, textSize.height)
                      contents:dragImage];

    [self beginDraggingSessionWithItems:@[dragItem] event:event source:self];
}

// NSDraggingSource
- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationMove;
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    self.isDragging = NO;
}

// NSDraggingDestination
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    if ([pb availableTypeFromArray:@[SpliceKitTranscriptWordDragType]]) {
        return NSDragOperationMove;
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    if ([pb availableTypeFromArray:@[SpliceKitTranscriptWordDragType]]) {
        NSPoint point = [self convertPoint:[sender draggingLocation] fromView:nil];
        NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];
        [self setSelectedRange:NSMakeRange(charIdx, 0)];
        return NSDragOperationMove;
    }
    return NSDragOperationNone;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    NSString *data = [pb stringForType:SpliceKitTranscriptWordDragType];
    if (!data) return NO;

    NSArray *parts = [data componentsSeparatedByString:@","];
    if (parts.count != 2) return NO;

    NSUInteger srcStart = [parts[0] integerValue];
    NSUInteger srcCount = [parts[1] integerValue];

    NSPoint point = [self convertPoint:[sender draggingLocation] fromView:nil];
    NSUInteger charIdx = [self characterIndexForInsertionAtPoint:point];

    [self.transcriptPanel handleDropOfWordStart:srcStart count:srcCount atCharIndex:charIdx];
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    // Backspace / forward-delete → word deletion
    if (event.keyCode == 51 || event.keyCode == 117) {
        [self.transcriptPanel handleDeleteKeyInTextView];
        return;
    }

    // Spacebar and transport keys (J/K/L) → FCP's own commands via the responder chain
    NSString *chars = event.charactersIgnoringModifiers;
    if ([chars isEqualToString:@" "]) {
        [NSApp sendAction:NSSelectorFromString(@"playPause:") to:nil from:nil];
        return;
    }
    NSArray<NSString *> *transport = SpliceKit_transcriptTransportCommands()[chars];
    if (transport && !(event.modifierFlags & SpliceKitTranscriptCommandModifiers)) {
        [NSApp sendAction:NSSelectorFromString(transport[0]) to:nil from:nil];
        return;
    }

    // Arrow keys → let NSTextView handle for cursor/selection
    if (event.keyCode >= 123 && event.keyCode <= 126) {
        [super keyDown:event];
        return;
    }

    // Cmd+A (select all), Cmd+Z (undo), Cmd+F (find) → pass through
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        // Cmd+F → focus search field
        if ([chars isEqualToString:@"f"]) {
            [self.transcriptPanel focusSearchField];
            return;
        }
        [super keyDown:event];
        return;
    }

    // Block all other typing
    NSBeep();
}

- (void)keyUp:(NSEvent *)event {
    NSArray<NSString *> *transport = SpliceKit_transcriptTransportCommands()[event.charactersIgnoringModifiers];
    if (transport && !(event.modifierFlags & SpliceKitTranscriptCommandModifiers)) {
        [NSApp sendAction:NSSelectorFromString(transport[1]) to:nil from:nil];
        return;
    }
    [super keyUp:event];
}

@end
