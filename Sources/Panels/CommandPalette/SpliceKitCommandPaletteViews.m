//
//  SpliceKitCommandPaletteViews.m
//  Look and views of the command palette: colour/glass helpers, the search field,
//  Siri orb, table row views and the bubble / latency pill / result platter views.
//

#import "SpliceKitCommandPalette+Private.h"

NSColor *FCPPaletteColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

NSView *FCPCreateGlassContainerView(NSRect frame, NSVisualEffectMaterial fallbackMaterial, CGFloat cornerRadius) {
    Class glassClass = NSClassFromString(@"NSGlassContainerView");
    NSView *view = nil;
    if (glassClass && [glassClass isSubclassOfClass:[NSView class]]) {
        view = [[glassClass alloc] initWithFrame:frame];
    } else {
        NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:frame];
        effectView.material = fallbackMaterial;
        effectView.state = NSVisualEffectStateActive;
        effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        view = effectView;
    }

    view.wantsLayer = YES;
    view.layer.cornerRadius = cornerRadius;
    view.layer.masksToBounds = YES;

    SEL cornerRadiusSelector = NSSelectorFromString(@"_setMaterialCornerRadius:");
    if ([view respondsToSelector:cornerRadiusSelector]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(view, cornerRadiusSelector, cornerRadius);
    }

    return view;
}

static NSURL *FCPCommandPaletteSiriBlobURL(void) {
    static NSURL *blobURL = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = @"/System/Library/PrivateFrameworks/SiriUI.framework/Versions/A/Resources/Siri Blob.mov";
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            blobURL = [NSURL fileURLWithPath:path];
        }
    });
    return blobURL;
}

NSString *FCPCommandSymbolName(SpliceKitCommand *cmd) {
    if ([cmd.type isEqualToString:@"playback"]) return @"play.fill";
    if ([cmd.type isEqualToString:@"transition_browse"]) return @"square.on.square.squareshape.controlhandles";
    if ([cmd.type isEqualToString:@"effect_browse"]) return @"sparkles";
    if ([cmd.type isEqualToString:@"generator_browse"]) return @"square.stack.3d.up.fill";
    if ([cmd.type isEqualToString:@"title_browse"]) return @"textformat";
    if ([cmd.type isEqualToString:@"favorites_browse"]) return @"star.fill";
    if ([cmd.type isEqualToString:@"transcript"]) return @"quote.bubble.fill";
    if ([cmd.type isEqualToString:@"captions"]) return @"captions.bubble.fill";
    if ([cmd.type isEqualToString:@"mixer"]) return @"slider.horizontal.3";
    if ([cmd.type isEqualToString:@"livecam"]) return @"video.fill";
    if ([cmd.type isEqualToString:@"beats"] || [cmd.type isEqualToString:@"flexmusic"] || [cmd.type isEqualToString:@"montage"]) return @"music.note";

    switch (cmd.category) {
        case SpliceKitCommandCategoryPlayback: return @"play.fill";
        case SpliceKitCommandCategoryColor: return @"camera.filters";
        case SpliceKitCommandCategorySpeed: return @"speedometer";
        case SpliceKitCommandCategoryMarkers: return @"mappin.and.ellipse";
        case SpliceKitCommandCategoryTitles: return @"text.bubble.fill";
        case SpliceKitCommandCategoryKeyframes: return @"point.topleft.down.curvedto.point.bottomright.up";
        case SpliceKitCommandCategoryEffects: return @"wand.and.stars";
        case SpliceKitCommandCategoryTranscript: return @"waveform.and.mic";
        case SpliceKitCommandCategoryExport: return @"square.and.arrow.up.fill";
        case SpliceKitCommandCategoryMusic: return @"music.note.list";
        case SpliceKitCommandCategoryOptions: return @"slider.horizontal.3";
        case SpliceKitCommandCategoryEditing:
        default: return @"scissors";
    }
}

NSColor *FCPCommandAccentColor(SpliceKitCommand *cmd) {
    switch (cmd.category) {
        case SpliceKitCommandCategoryPlayback: return FCPPaletteColor(0.35, 0.76, 0.96, 0.95);
        case SpliceKitCommandCategoryColor: return FCPPaletteColor(0.99, 0.57, 0.39, 0.95);
        case SpliceKitCommandCategorySpeed: return FCPPaletteColor(0.96, 0.55, 0.72, 0.95);
        case SpliceKitCommandCategoryMarkers: return FCPPaletteColor(0.99, 0.80, 0.34, 0.95);
        case SpliceKitCommandCategoryTitles: return FCPPaletteColor(0.71, 0.58, 0.99, 0.95);
        case SpliceKitCommandCategoryKeyframes: return FCPPaletteColor(0.63, 0.82, 0.39, 0.95);
        case SpliceKitCommandCategoryEffects: return FCPPaletteColor(0.45, 0.88, 0.80, 0.95);
        case SpliceKitCommandCategoryTranscript: return FCPPaletteColor(0.36, 0.74, 0.99, 0.95);
        case SpliceKitCommandCategoryExport: return FCPPaletteColor(0.99, 0.47, 0.47, 0.95);
        case SpliceKitCommandCategoryMusic: return FCPPaletteColor(0.47, 0.89, 0.64, 0.95);
        case SpliceKitCommandCategoryOptions: return FCPPaletteColor(0.78, 0.82, 0.92, 0.95);
        case SpliceKitCommandCategoryEditing:
        default: return FCPPaletteColor(0.54, 0.67, 0.99, 0.95);
    }
}

void FCPSelectSingleTableRow(NSTableView *tableView, NSInteger row) {
    if (!tableView || row < 0 || row >= tableView.numberOfRows) return;

    NSInteger rowCount = tableView.numberOfRows;
    NSIndexSet *previousSelection = tableView.selectedRowIndexes.copy;

    [tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [tableView scrollRowToVisible:row];

    NSMutableIndexSet *rowsToRedraw = [NSMutableIndexSet indexSetWithIndex:(NSUInteger)row];
    [previousSelection enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if ((NSInteger)idx < rowCount) {
            [rowsToRedraw addIndex:idx];
        }
    }];

    NSIndexSet *columns = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, tableView.numberOfColumns)];
    if (rowsToRedraw.count > 0 && columns.count > 0) {
        [tableView reloadDataForRowIndexes:rowsToRedraw columnIndexes:columns];
    }
    [tableView setNeedsDisplay:YES];
    [tableView.enclosingScrollView.contentView setNeedsDisplay:YES];
}

#pragma mark - Search Field
//
// Custom text field that intercepts arrow keys and forwards them to the
// results table. Without this, pressing Up/Down while typing would move
// the text cursor instead of navigating the command list.
//

@implementation SpliceKitCenteredTextFieldCell

- (NSRect)titleRectForBounds:(NSRect)rect {
    NSRect titleRect = [super titleRectForBounds:rect];
    CGFloat offset = floor((NSHeight(rect) - NSHeight(titleRect)) * 0.5) + 2.0;
    titleRect.origin.y += MAX(0.0, offset);
    return titleRect;
}

- (NSRect)drawingRectForBounds:(NSRect)rect {
    return [self titleRectForBounds:rect];
}

- (NSRect)editingRectForBounds:(NSRect)rect {
    return [self titleRectForBounds:rect];
}

- (void)selectWithFrame:(NSRect)rect inView:(NSView *)view editor:(NSText *)editor delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length {
    [super selectWithFrame:[self titleRectForBounds:rect]
                    inView:view
                    editor:editor
                  delegate:delegate
                     start:start
                    length:length];
}

@end

@implementation SpliceKitCommandSearchField

+ (Class)cellClass {
    return [SpliceKitCenteredTextFieldCell class];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Forward up/down arrows to the table view (skip separator rows)
    if (event.type == NSEventTypeKeyDown) {
        unsigned short keyCode = event.keyCode;
        if (keyCode == 126 || keyCode == 125) { // Up or Down
            SpliceKitCommandPalette *palette = [SpliceKitCommandPalette sharedPalette];
            NSInteger row = self.targetTableView.selectedRow;
            NSInteger maxRow = self.targetTableView.numberOfRows - 1;
            if (keyCode == 126 && row > 0) { // Up
                NSInteger newRow = row - 1;
                SpliceKitCommand *cmd = [palette commandForDisplayRow:newRow];
                if (cmd && cmd.isSeparatorRow && newRow > 0) newRow--;
                FCPSelectSingleTableRow(self.targetTableView, newRow);
            } else if (keyCode == 125 && row < maxRow) { // Down
                NSInteger newRow = row + 1;
                SpliceKitCommand *cmd = [palette commandForDisplayRow:newRow];
                if (cmd && cmd.isSeparatorRow && newRow < maxRow) newRow++;
                FCPSelectSingleTableRow(self.targetTableView, newRow);
            }
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

@end

#pragma mark - Siri Orb

@implementation SpliceKitCommandPalettePanel

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

@end

@implementation SpliceKitSiriOrbView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 14.0;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = FCPPaletteColor(0.12, 0.15, 0.26, 0.34).CGColor;

        NSURL *blobURL = FCPCommandPaletteSiriBlobURL();
        if (blobURL) {
            self.player = [[AVQueuePlayer alloc] init];
            self.player.muted = YES;
            AVPlayerItem *item = [AVPlayerItem playerItemWithURL:blobURL];
            self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
            AVPlayerLayer *playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
            playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            playerLayer.frame = self.bounds;
            playerLayer.cornerRadius = 14.0;
            playerLayer.masksToBounds = YES;
            [self.layer addSublayer:playerLayer];
            [self.player play];
        } else {
            self.fallbackLayer = [CAGradientLayer layer];
            self.fallbackLayer.colors = @[
                (__bridge id)FCPPaletteColor(1.00, 0.55, 0.48, 0.98).CGColor,
                (__bridge id)FCPPaletteColor(0.98, 0.74, 0.39, 0.98).CGColor,
                (__bridge id)FCPPaletteColor(0.35, 0.85, 0.96, 0.98).CGColor,
                (__bridge id)FCPPaletteColor(0.63, 0.44, 0.98, 0.98).CGColor
            ];
            self.fallbackLayer.startPoint = CGPointMake(0.0, 0.2);
            self.fallbackLayer.endPoint = CGPointMake(1.0, 0.8);
            self.fallbackLayer.cornerRadius = 14.0;
            self.fallbackLayer.frame = self.bounds;
            [self.layer addSublayer:self.fallbackLayer];

            CABasicAnimation *shift = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            shift.fromValue = @0.0;
            shift.toValue = @(M_PI * 2.0);
            shift.duration = 14.0;
            shift.repeatCount = HUGE_VALF;
            [self.fallbackLayer addAnimation:shift forKey:@"spin"];
        }

        self.layer.shadowColor = FCPPaletteColor(0.68, 0.77, 1.0, 0.22).CGColor;
        self.layer.shadowOpacity = 0.55;
        self.layer.shadowRadius = 16.0;
        self.layer.shadowOffset = CGSizeZero;
    }
    return self;
}

- (void)layout {
    [super layout];
    for (CALayer *layer in self.layer.sublayers) {
        layer.frame = self.bounds;
        layer.cornerRadius = 14.0;
    }
}

@end

#pragma mark - Glass Row Views

@implementation SpliceKitPaletteRowView

- (BOOL)isOpaque {
    return NO;
}

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    // Custom background handles both selected and unselected states.
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    // Row highlight/card rendering is handled by the reusable cell view. Drawing
    // it here can leave stale selected backgrounds when AppKit reuses row views.
}

- (void)drawSeparatorInRect:(NSRect)dirtyRect {
}

@end

#pragma mark - Command Row View

@implementation SpliceKitCommandRowView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;

        _cardView = [[NSView alloc] initWithFrame:NSZeroRect];
        _cardView.wantsLayer = YES;
        _cardView.layer.cornerRadius = 18.0;
        _cardView.layer.masksToBounds = YES;
        _cardView.layer.borderWidth = 1.0;
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;

        _iconPlate = [[NSView alloc] initWithFrame:NSZeroRect];
        _iconPlate.wantsLayer = YES;
        _iconPlate.layer.cornerRadius = 13.0;
        _iconPlate.layer.masksToBounds = YES;
        _iconPlate.translatesAutoresizingMaskIntoConstraints = NO;

        _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _iconView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightSemibold];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;

        _starLabel = [NSTextField labelWithString:@""];
        _starLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        _starLabel.textColor = FCPPaletteColor(1.00, 0.82, 0.34, 0.95);
        _starLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _nameLabel = [NSTextField labelWithString:@""];
        _nameLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        _nameLabel.textColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.94);
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _detailLabel = [NSTextField labelWithString:@""];
        _detailLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        _detailLabel.textColor = FCPPaletteColor(0.86, 0.89, 0.96, 0.66);
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _categoryLabel = [NSTextField labelWithString:@""];
        _categoryLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        _categoryLabel.textColor = FCPPaletteColor(0.92, 0.95, 1.0, 0.80);
        _categoryLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _categoryLabel.alignment = NSTextAlignmentRight;

        _shortcutLabel = [NSTextField labelWithString:@""];
        _shortcutLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium];
        _shortcutLabel.textColor = FCPPaletteColor(0.88, 0.92, 1.0, 0.54);
        _shortcutLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _shortcutLabel.alignment = NSTextAlignmentRight;

        [self addSubview:_cardView positioned:NSWindowBelow relativeTo:nil];
        [self addSubview:_iconPlate];
        [_iconPlate addSubview:_iconView];
        [self addSubview:_starLabel];
        [self addSubview:_nameLabel];
        [self addSubview:_detailLabel];
        [self addSubview:_categoryLabel];
        [self addSubview:_shortcutLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12.0],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12.0],
            [_cardView.topAnchor constraintEqualToAnchor:self.topAnchor constant:5.0],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-5.0],

            [_iconPlate.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:22.0],
            [_iconPlate.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_iconPlate.widthAnchor constraintEqualToConstant:34.0],
            [_iconPlate.heightAnchor constraintEqualToConstant:34.0],

            [_iconView.centerXAnchor constraintEqualToAnchor:_iconPlate.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:_iconPlate.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:18.0],
            [_iconView.heightAnchor constraintEqualToConstant:18.0],

            [_starLabel.leadingAnchor constraintEqualToAnchor:_iconPlate.trailingAnchor constant:12.0],
            [_starLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:14.0],
            [_starLabel.widthAnchor constraintEqualToConstant:11.0],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_starLabel.trailingAnchor constant:6.0],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12.0],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_categoryLabel.leadingAnchor constant:-10.0],

            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3.0],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_shortcutLabel.leadingAnchor constant:-10.0],

            [_categoryLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24.0],
            [_categoryLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12.0],
            [_categoryLabel.widthAnchor constraintLessThanOrEqualToConstant:130.0],

            [_shortcutLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24.0],
            [_shortcutLabel.topAnchor constraintEqualToAnchor:_categoryLabel.bottomAnchor constant:6.0],
            [_shortcutLabel.widthAnchor constraintLessThanOrEqualToConstant:130.0],
        ]];
    }
    return self;
}

- (void)configureWithCommand:(SpliceKitCommand *)cmd isFavorited:(BOOL)favorited {
    [self configureWithCommand:cmd isFavorited:favorited selected:NO];
}

- (void)configureWithCommand:(SpliceKitCommand *)cmd isFavorited:(BOOL)favorited selected:(BOOL)selected {
    NSColor *accent = FCPCommandAccentColor(cmd);
    self.nameLabel.stringValue = cmd.name ?: @"";
    self.detailLabel.stringValue = cmd.detail ?: @"";
    self.categoryLabel.stringValue = cmd.categoryName.length > 0 ? [cmd.categoryName uppercaseString] : @"";
    self.shortcutLabel.stringValue = cmd.shortcut ?: @"";
    self.starLabel.stringValue = favorited ? @"★" : @"";

    NSImage *symbol = [NSImage imageWithSystemSymbolName:FCPCommandSymbolName(cmd) accessibilityDescription:cmd.name];
    self.iconView.image = symbol;
    self.iconView.contentTintColor = accent;
    self.iconPlate.layer.backgroundColor = [accent colorWithAlphaComponent:0.10].CGColor;
    self.iconPlate.layer.borderColor = [accent colorWithAlphaComponent:0.18].CGColor;
    self.iconPlate.layer.borderWidth = 1.0;

    if (selected) {
        self.cardView.layer.backgroundColor = FCPPaletteColor(0.16, 0.20, 0.36, 0.58).CGColor;
        self.cardView.layer.borderColor = FCPPaletteColor(0.72, 0.84, 1.0, 0.22).CGColor;
        self.cardView.layer.shadowColor = FCPPaletteColor(0.20, 0.30, 0.60, 0.36).CGColor;
        self.cardView.layer.shadowOpacity = 0.28;
        self.cardView.layer.shadowRadius = 10.0;
        self.cardView.layer.shadowOffset = CGSizeZero;
    } else {
        self.cardView.layer.backgroundColor = FCPPaletteColor(0.04, 0.05, 0.07, 0.42).CGColor;
        self.cardView.layer.borderColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.08).CGColor;
        self.cardView.layer.shadowOpacity = 0.0;
    }
    self.needsDisplay = YES;
}

@end

#pragma mark - Separator Row View

@implementation FCPSeparatorRowView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        NSBox *line = [[NSBox alloc] initWithFrame:NSZeroRect];
        line.boxType = NSBoxSeparator;
        line.borderColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.08);
        line.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:30.0],
            [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-30.0],
            [line.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

@end

#pragma mark - Bubble Stage Views

@implementation SpliceKitSuggestionBubbleView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.material = NSVisualEffectMaterialMenu;
        self.state = NSVisualEffectStateActive;
        self.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 18.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.08).CGColor;
        self.layer.backgroundColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.012).CGColor;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _iconPlate = [[NSView alloc] initWithFrame:NSZeroRect];
        _iconPlate.wantsLayer = YES;
        _iconPlate.layer.cornerRadius = 12.0;
        _iconPlate.layer.masksToBounds = YES;
        _iconPlate.translatesAutoresizingMaskIntoConstraints = NO;

        _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _iconView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightSemibold];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        _titleLabel.textColor = FCPPaletteColor(0.97, 0.98, 1.0, 0.92);
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:_iconPlate];
        [_iconPlate addSubview:_iconView];
        [self addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_iconPlate.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0],
            [_iconPlate.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_iconPlate.widthAnchor constraintEqualToConstant:28.0],
            [_iconPlate.heightAnchor constraintEqualToConstant:28.0],

            [_iconView.centerXAnchor constraintEqualToAnchor:_iconPlate.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:_iconPlate.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:16.0],
            [_iconView.heightAnchor constraintEqualToConstant:16.0],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconPlate.trailingAnchor constant:10.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)configureWithCommand:(SpliceKitCommand *)cmd emphasis:(BOOL)emphasis {
    NSColor *accent = FCPCommandAccentColor(cmd);
    self.titleLabel.stringValue = cmd.name ?: @"";
    self.iconView.image = [NSImage imageWithSystemSymbolName:FCPCommandSymbolName(cmd) accessibilityDescription:cmd.name];
    self.iconView.contentTintColor = accent;
    self.iconPlate.layer.backgroundColor = [accent colorWithAlphaComponent:emphasis ? 0.16 : 0.10].CGColor;
    self.iconPlate.layer.borderWidth = 1.0;
    self.iconPlate.layer.borderColor = [accent colorWithAlphaComponent:0.18].CGColor;
    self.layer.backgroundColor = (emphasis
        ? FCPPaletteColor(0.25, 0.31, 0.55, 0.10)
        : FCPPaletteColor(1.0, 1.0, 1.0, 0.012)).CGColor;
    self.layer.borderColor = (emphasis
        ? [accent colorWithAlphaComponent:0.24].CGColor
        : FCPPaletteColor(1.0, 1.0, 1.0, 0.12).CGColor);
}

@end

@implementation SpliceKitLatencyPillView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.material = NSVisualEffectMaterialMenu;
        self.state = NSVisualEffectStateActive;
        self.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 20.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = FCPPaletteColor(0.72, 0.84, 1.0, 0.18).CGColor;
        self.layer.backgroundColor = FCPPaletteColor(0.23, 0.29, 0.50, 0.08).CGColor;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        _titleLabel.textColor = FCPPaletteColor(0.97, 0.98, 1.0, 0.94);
        _titleLabel.alignment = NSTextAlignmentCenter;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18.0],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];

        _shimmerLayer = [CAGradientLayer layer];
        _shimmerLayer.colors = @[
            (__bridge id)FCPPaletteColor(1.0, 1.0, 1.0, 0.0).CGColor,
            (__bridge id)FCPPaletteColor(1.0, 1.0, 1.0, 0.22).CGColor,
            (__bridge id)FCPPaletteColor(1.0, 1.0, 1.0, 0.0).CGColor
        ];
        _shimmerLayer.startPoint = CGPointMake(0.0, 0.5);
        _shimmerLayer.endPoint = CGPointMake(1.0, 0.5);
        _shimmerLayer.frame = CGRectMake(-120.0, 0.0, 120.0, 56.0);
        [self.layer addSublayer:_shimmerLayer];

        CABasicAnimation *shimmer = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        shimmer.fromValue = @(-140.0);
        shimmer.toValue = @(360.0);
        shimmer.duration = 1.15;
        shimmer.repeatCount = HUGE_VALF;
        shimmer.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_shimmerLayer addAnimation:shimmer forKey:@"shimmer"];
    }
    return self;
}

- (void)layout {
    [super layout];
    self.shimmerLayer.frame = CGRectMake(-120.0, 0.0, 120.0, NSHeight(self.bounds));
}

- (void)configureWithText:(NSString *)text {
    self.titleLabel.stringValue = text.length > 0 ? text : @"Working...";
}

@end

@implementation SpliceKitResultPlatterView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.material = NSVisualEffectMaterialMenu;
        self.state = NSVisualEffectStateActive;
        self.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 24.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.10).CGColor;
        self.layer.backgroundColor = FCPPaletteColor(1.0, 1.0, 1.0, 0.015).CGColor;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _iconPlate = [[NSView alloc] initWithFrame:NSZeroRect];
        _iconPlate.wantsLayer = YES;
        _iconPlate.layer.cornerRadius = 16.0;
        _iconPlate.layer.masksToBounds = YES;
        _iconPlate.translatesAutoresizingMaskIntoConstraints = NO;

        _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _iconView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightSemibold];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;

        _badgeLabel = [NSTextField labelWithString:@""];
        _badgeLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
        _badgeLabel.textColor = FCPPaletteColor(0.89, 0.93, 0.99, 0.74);
        _badgeLabel.alignment = NSTextAlignmentRight;
        _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
        _titleLabel.textColor = FCPPaletteColor(0.98, 0.99, 1.0, 0.96);
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _subtitleLabel = [NSTextField wrappingLabelWithString:@""];
        _subtitleLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        _subtitleLabel.textColor = FCPPaletteColor(0.88, 0.92, 0.99, 0.76);
        _subtitleLabel.maximumNumberOfLines = 2;
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _footnoteLabel = [NSTextField labelWithString:@""];
        _footnoteLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        _footnoteLabel.textColor = FCPPaletteColor(0.76, 0.84, 0.99, 0.68);
        _footnoteLabel.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:_iconPlate];
        [_iconPlate addSubview:_iconView];
        [self addSubview:_badgeLabel];
        [self addSubview:_titleLabel];
        [self addSubview:_subtitleLabel];
        [self addSubview:_footnoteLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_iconPlate.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18.0],
            [_iconPlate.topAnchor constraintEqualToAnchor:self.topAnchor constant:18.0],
            [_iconPlate.widthAnchor constraintEqualToConstant:34.0],
            [_iconPlate.heightAnchor constraintEqualToConstant:34.0],

            [_iconView.centerXAnchor constraintEqualToAnchor:_iconPlate.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:_iconPlate.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:18.0],
            [_iconView.heightAnchor constraintEqualToConstant:18.0],

            [_badgeLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18.0],
            [_badgeLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:16.0],
            [_badgeLabel.widthAnchor constraintLessThanOrEqualToConstant:150.0],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconPlate.trailingAnchor constant:12.0],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_badgeLabel.leadingAnchor constant:-12.0],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:17.0],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18.0],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4.0],

            [_footnoteLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_footnoteLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18.0],
            [_footnoteLabel.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:8.0],
        ]];
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                     badge:(NSString *)badge
                  footnote:(NSString *)footnote
                symbolName:(NSString *)symbolName
                    accent:(NSColor *)accent {
    self.titleLabel.stringValue = title ?: @"Ready";
    self.subtitleLabel.stringValue = subtitle ?: @"";
    self.badgeLabel.stringValue = [badge uppercaseString] ?: @"";
    self.footnoteLabel.stringValue = footnote ?: @"";
    self.iconView.image = [NSImage imageWithSystemSymbolName:(symbolName ?: @"sparkles") accessibilityDescription:title];
    self.iconView.contentTintColor = accent ?: FCPPaletteColor(0.61, 0.61, 0.99, 0.95);
    self.iconPlate.layer.backgroundColor = [(accent ?: FCPPaletteColor(0.61, 0.61, 0.99, 0.95)) colorWithAlphaComponent:0.14].CGColor;
    self.iconPlate.layer.borderWidth = 1.0;
    self.iconPlate.layer.borderColor = [(accent ?: FCPPaletteColor(0.61, 0.61, 0.99, 0.95)) colorWithAlphaComponent:0.22].CGColor;
}

@end
