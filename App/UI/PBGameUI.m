#import <SceneKit/SceneKit.h>
#import "PBGameUI.h"
#import <ImageIO/ImageIO.h>

static CGImageRef PBCreateImageAtURL(NSURL *url) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    NSCAssert(source, @"Could not read UI artwork: %@", url);
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    NSCAssert(image, @"Could not decode UI artwork: %@", url);
    return image;
}

static SKTexture *PBTextureAtURL(NSURL *url) {
    CGImageRef image = PBCreateImageAtURL(url);
    if (!image) return nil;
    SKTexture *texture = [SKTexture textureWithCGImage:image];
    CGImageRelease(image);
    return texture;
}

/// A crop shares its parent's pixels, and on iOS a texture made from one can show the whole
/// parent. Drawing it into its own bitmap leaves nothing to share. Caller releases.
static CGImageRef PBCreateIndependentCrop(CGImageRef image, CGRect rect) CF_RETURNS_RETAINED;
static CGImageRef PBCreateIndependentCrop(CGImageRef image, CGRect rect) {
    CGImageRef crop = CGImageCreateWithImageInRect(image, rect);
    size_t width = CGImageGetWidth(crop), height = CGImageGetHeight(crop);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), crop);
    CGImageRef copy = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGImageRelease(crop);
    return copy;
}

static SKColor *PBInk(void) { return [SKColor colorWithRed:0.035 green:0.075 blue:0.10 alpha:1]; }
static SKColor *PBIvory(void) { return [SKColor colorWithRed:0.95 green:0.88 blue:0.73 alpha:1]; }
static SKColor *PBBrass(void) { return [SKColor colorWithRed:0.65 green:0.49 blue:0.28 alpha:1]; }
static SKColor *PBMuted(void) { return [SKColor colorWithRed:0.49 green:0.59 blue:0.60 alpha:1]; }
static SKColor *PBRed(void) { return [SKColor colorWithRed:0.88 green:0.23 blue:0.14 alpha:1]; }

/// A CoreGraphics path as a sprite, its fill and stroke drawn into a texture.
static SKSpriteNode *PBPathSprite(CGPathRef path, CGSize size, SKColor *fill, SKColor *stroke, CGFloat lineWidth) {
    const CGFloat scale = 3;
    size_t width = (size_t)ceil(size.width * scale), height = (size_t)ceil(size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextScaleCTM(c, scale, scale);
    CGContextTranslateCTM(c, size.width * .5, size.height * .5);
    CGContextAddPath(c, path);
    if (fill) { CGContextSetFillColorWithColor(c, fill.CGColor); CGContextDrawPath(c, kCGPathFill); }
    CGContextAddPath(c, path);
    if (stroke && lineWidth > 0) { CGContextSetStrokeColorWithColor(c, stroke.CGColor); CGContextSetLineWidth(c, lineWidth); CGContextSetLineJoin(c, kCGLineJoinRound); CGContextDrawPath(c, kCGPathStroke); }
    CGImageRef image = CGBitmapContextCreateImage(c);
    SKSpriteNode *sprite = [SKSpriteNode spriteNodeWithTexture:[SKTexture textureWithCGImage:image] size:size];
    CGImageRelease(image);
    CGContextRelease(c);
    return sprite;
}

static SKSpriteNode *PBStar(CGFloat radius, CGPoint position, BOOL earned) {
    CGMutablePathRef path = CGPathCreateMutable();
    for (int i = 0; i < 10; i++) {
        CGFloat r = i % 2 ? radius * 0.42 : radius, a = M_PI_2 + i * M_PI / 5;
        if (i == 0) CGPathMoveToPoint(path, NULL, r * cos(a), r * sin(a));
        else CGPathAddLineToPoint(path, NULL, r * cos(a), r * sin(a));
    }
    CGPathCloseSubpath(path);
    SKSpriteNode *star = PBPathSprite(path, CGSizeMake(radius * 2 + 4, radius * 2 + 4), earned ? [SKColor colorWithRed:1.0 green:0.76 blue:0.28 alpha:1] : [PBInk() colorWithAlphaComponent:0.9], PBBrass(), 0.8);
    CGPathRelease(path);
    star.position = position;
    return star;
}

static NSString *PBScoreString(int64_t score) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSNumberFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
    });
    return [formatter stringFromNumber:@(score)];
}

/// Nine textured quads give the SceneKit overlay explicit, fixed cap geometry.
@interface PBNineSliceFace : SKNode
- (instancetype)initWithStates:(NSArray<SKTexture *> *)states insets:(NSArray<NSNumber *> *)insets size:(CGSize)size;
- (void)setState:(NSUInteger)state;
@end

@implementation PBNineSliceFace {
    NSArray<SKSpriteNode *> *_patches;
    NSArray<NSArray<SKTexture *> *> *_statePatches;
}

- (instancetype)initWithStates:(NSArray<SKTexture *> *)states insets:(NSArray<NSNumber *> *)insets size:(CGSize)size {
    if ((self = [super init])) {
        CGSize source = states[0].size;
        CGFloat sx[] = {0, insets[0].doubleValue, source.width - insets[2].doubleValue, source.width};
        CGFloat sy[] = {0, insets[1].doubleValue, source.height - insets[3].doubleValue, source.height};
        CGFloat scale = size.height / source.height;
        CGFloat dx[] = {-size.width / 2, -size.width / 2 + sx[1] * scale,
                        size.width / 2 - (source.width - sx[2]) * scale, size.width / 2};
        CGFloat dy[] = {-size.height / 2, -size.height / 2 + sy[1] * scale,
                        size.height / 2 - (source.height - sy[2]) * scale, size.height / 2};
        NSAssert(sx[1] < sx[2] && sy[1] < sy[2] && dx[1] <= dx[2] && dy[1] <= dy[2], @"Invalid nine-slice caps");
        NSMutableArray *statePatches = [NSMutableArray array];
        for (SKTexture *texture in states) {
            NSMutableArray *patches = [NSMutableArray array];
            for (NSInteger row = 0; row < 3; row++) for (NSInteger column = 0; column < 3; column++) {
                CGRect rect = CGRectMake(sx[column] / source.width, sy[row] / source.height,
                                         (sx[column + 1] - sx[column]) / source.width,
                                         (sy[row + 1] - sy[row]) / source.height);
                [patches addObject:[SKTexture textureWithRect:rect inTexture:texture]];
            }
            [statePatches addObject:patches];
        }
        _statePatches = statePatches;
        NSMutableArray *patches = [NSMutableArray array];
        for (NSInteger row = 0; row < 3; row++) for (NSInteger column = 0; column < 3; column++) {
            SKSpriteNode *patch = [SKSpriteNode spriteNodeWithTexture:_statePatches[0][row * 3 + column]
                size:CGSizeMake(dx[column + 1] - dx[column], dy[row + 1] - dy[row])];
            patch.position = CGPointMake((dx[column] + dx[column + 1]) * 0.5, (dy[row] + dy[row + 1]) * 0.5);
            [self addChild:patch];
            [patches addObject:patch];
        }
        _patches = patches;
    }
    return self;
}

- (void)setState:(NSUInteger)state {
    for (NSUInteger i = 0; i < _patches.count; i++) _patches[i].texture = _statePatches[state][i];
}
@end

@interface PBUIKey : SKNode
@property (nonatomic) PBUIAction action;
@property (nonatomic, strong) SKSpriteNode *face;
@property (nonatomic, strong) PBNineSliceFace *slicedFace;
@property (nonatomic, copy) NSArray<SKTexture *> *states;
@property (nonatomic) CGRect hitRect;
@property (nonatomic) BOOL enabled, selected, pressed;
@property (nonatomic) NSInteger tag;
- (void)refresh;
@end

@implementation PBUIKey
- (void)refresh {
    PBGameUI *ui = (PBGameUI *)self.scene;
    if ([ui isKindOfClass:PBGameUI.class] && ![ui onRenderThread]) {
        [ui applyChange:^{ [self refresh]; }];
        return;
    }
    NSUInteger state = !self.enabled ? 4 : self.pressed ? 2 : self.selected ? 1 : 0;
    if (self.slicedFace) [self.slicedFace setState:state];
    else self.face.texture = self.states[state];
}
@end

@implementation PBGameUI {
    SKNode *_root, *_menu;
    SKTexture *_titleArt;
    NSDictionary<NSString *, NSArray<SKTexture *> *> *_textures;
    NSDictionary<NSString *, NSArray<NSNumber *> *> *_nineSliceInsets;
    NSMutableArray<PBUIKey *> *_keys;
    NSMapTable<id, PBUIKey *> *_pressedKeys;
    NSHashTable<id> *_capturedPointers;
    CGFloat _logicalHeight, _topInset, _bottomInset;
    CGSize _inputViewSize;
    int64_t _score, _best;
    SKSpriteNode *_scoreSprite, *_ballSprite, *_messageSprite;
    NSInteger _liveEffects;
    NSString *_message;
    NSInteger _ball, _ballCount, _levelPage;
    NSRecursiveLock *_changesLock;
    NSMutableArray<dispatch_block_t> *_changes;
    BOOL _applyingChanges;
}

static const NSInteger kLevelsPerPage = 12;

- (instancetype)initWithBundle:(NSBundle *)bundle {
    if ((self = [super initWithSize:CGSizeMake(402, 874)])) {
        self.backgroundColor = SKColor.clearColor;
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.userInteractionEnabled = NO;
        _skinName = @"Orbital";
        _tableName = @"Aurora";
        _soundEnabled = _hapticsEnabled = YES;
        _ballCount = 3;
        _messageColor = [SKColor colorWithRed:1 green:0.55 blue:0.13 alpha:1];
        _logicalHeight = 874;
        _inputViewSize = CGSizeMake(402, 874);
        _keys = [NSMutableArray array];
        _changesLock = [NSRecursiveLock new];
        _changes = [NSMutableArray array];
        _pressedKeys = [NSMapTable strongToStrongObjectsMapTable];
        _capturedPointers = [NSHashTable hashTableWithOptions:NSHashTableStrongMemory];
        _root = [SKNode node];
        [self addChild:_root];
        NSURL *atlasURL = [bundle URLForResource:@"controls" withExtension:@"png" subdirectory:@"GameData/UI"];
        NSURL *layoutURL = [bundle URLForResource:@"controls" withExtension:@"json" subdirectory:@"GameData/UI"];
        NSURL *titleURL = [bundle URLForResource:@"title-art" withExtension:@"png" subdirectory:@"GameData/UI"];
        NSAssert(atlasURL && layoutURL && titleURL, @"Missing custom UI artwork");
        CGImageRef atlasPixels = PBCreateImageAtURL(atlasURL);
        SKTexture *atlas = [SKTexture textureWithCGImage:atlasPixels];
        _titleArt = PBTextureAtURL(titleURL);
        NSDictionary *layout = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:layoutURL] options:0 error:NULL];
        _nineSliceInsets = layout[@"nineSliceInsets"];
        CGFloat width = [layout[@"canvas"][0] doubleValue], height = [layout[@"canvas"][1] doubleValue];
        NSMutableDictionary *textures = [NSMutableDictionary dictionary];
        NSDictionary *slots = layout[@"slots"];
        for (NSString *name in slots) {
            NSArray *slot = slots[name];
            NSMutableArray *states = [NSMutableArray array];
            for (NSInteger row = 0; row < 5; row++) {
                CGFloat y = [layout[@"rowTop"] doubleValue] + row * [layout[@"rowStep"] doubleValue];
                CGFloat h = [layout[@"rowHeight"] doubleValue];
                CGRect rect = CGRectMake([slot[0] doubleValue] / width, 1 - (y + h) / height,
                                         [slot[1] doubleValue] / width, h / height);
                SKTexture *texture;
                if (_nineSliceInsets[name]) {
                    // Upload the exact authored cell before subdividing it: nested
                    // atlas subtextures lose their expected UVs in the overlay.
                    CGImageRef cell = PBCreateIndependentCrop(atlasPixels,
                        CGRectMake([slot[0] doubleValue], y, [slot[1] doubleValue], h));
                    texture = [SKTexture textureWithCGImage:cell];
                    CGImageRelease(cell);
                } else {
                    texture = [SKTexture textureWithRect:rect inTexture:atlas];
                }
                texture.filteringMode = SKTextureFilteringLinear;
                [states addObject:texture];
            }
            textures[name] = states;
        }
        CGImageRelease(atlasPixels);
        _textures = textures;
        [self showScreen:PBMenuHome];
    }
    return self;
}

- (void)layoutForViewSize:(CGSize)size topInset:(CGFloat)top bottomInset:(CGFloat)bottom {
    if (size.width <= 0 || size.height <= 0) return;
    _inputViewSize = size;
    CGFloat scale = size.width / 402.0;
    _logicalHeight = size.height / scale;
    _topInset = top / scale;
    _bottomInset = bottom / scale;
    [self applyChange:^{
        self.size = size;
        self->_root.xScale = self->_root.yScale = scale;
        [self rebuildNodes];
    }];
}

- (void)didChangeSize:(CGSize)oldSize {
    [super didChangeSize:oldSize];
    if (!_root || self.size.width <= 0) return;
    CGFloat scale = self.size.width / 402.0;
    _root.xScale = _root.yScale = scale;
    _logicalHeight = self.size.height / scale;
    [self render];
}

- (SKLabelNode *)label:(NSString *)text size:(CGFloat)size x:(CGFloat)x y:(CGFloat)y
                 color:(SKColor *)color parent:(SKNode *)parent {
    SKLabelNode *label = [SKLabelNode labelNodeWithFontNamed:@"AvenirNextCondensed-DemiBold"];
    label.text = text;
    label.fontSize = size;
    label.fontColor = color;
    label.verticalAlignmentMode = SKLabelVerticalAlignmentModeCenter;
    label.position = CGPointMake(x, y);
    [parent addChild:label];
    return label;
}

- (SKNode *)panel:(CGSize)size at:(CGPoint)position parent:(SKNode *)parent {
    CGPathRef outer = CGPathCreateWithRoundedRect(CGRectMake(-size.width * .5, -size.height * .5, size.width, size.height), 12, 12, NULL);
    SKSpriteNode *panel = PBPathSprite(outer, CGSizeMake(size.width + 4, size.height + 4), PBInk(), PBBrass(), 1.2);
    CGPathRelease(outer);
    panel.position = position;
    [parent addChild:panel];
    CGPathRef line = CGPathCreateWithRoundedRect(CGRectMake(-size.width * .5 + 5, -size.height * .5 + 5, size.width - 10, size.height - 10), 8, 8, NULL);
    [panel addChild:PBPathSprite(line, size, nil, [PBBrass() colorWithAlphaComponent:0.28], 0.7)];
    CGPathRelease(line);
    return panel;
}

- (PBUIKey *)key:(NSString *)art title:(NSString *)title action:(PBUIAction)action
               x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width parent:(SKNode *)parent {
    BOOL wide = title != nil;
    CGFloat height = wide ? 88 : width * 62.0 / 58.0;  // Icon keys keep their proportions.
    PBUIKey *key = [PBUIKey node];
    key.action = action;
    key.enabled = YES;
    key.states = _textures[art];
    NSAssert(key.states.count == 5, @"Missing authored button states for %@", art);
    key.position = CGPointMake(x, y);
    if (wide) {
        NSArray<NSNumber *> *caps = _nineSliceInsets[art]; // left, bottom, right, top; source pixels
        NSAssert(caps.count == 4, @"Missing nine-slice insets for %@", art);
        key.slicedFace = [[PBNineSliceFace alloc] initWithStates:key.states insets:caps size:CGSizeMake(width, height)];
        [key addChild:key.slicedFace];
    } else {
        key.face = [SKSpriteNode spriteNodeWithTexture:key.states[0] size:CGSizeMake(width, height)];
        [key addChild:key.face];
    }
    // Texture sampling and hit geometry are identical for every authored state.
    // A small indicator-sized key still takes a whole fingertip.
    CGFloat hitWidth = MAX(width * 0.96, 48);
    key.hitRect = CGRectMake(-hitWidth * 0.5, -(wide ? 28 : 30), hitWidth, wide ? 56 : 60);
    if (wide) [self label:title size:width < 150 ? 14 : 18 x:0 y:0 color:PBIvory() parent:key];
    [parent addChild:key];
    [_keys addObject:key];
    return key;
}

- (void)icon:(NSString *)art caption:(NSString *)caption action:(PBUIAction)action x:(CGFloat)x y:(CGFloat)y {
    [self key:art title:nil action:action x:x y:y width:58 parent:_menu];
    [self label:caption size:10 x:x y:y - 42 color:PBMuted() parent:_menu];
}

- (void)heading:(NSString *)text subtitle:(NSString *)subtitle height:(CGFloat)height {
    [self label:[NSString stringWithFormat:@"PINBALL  /  %@", _skinName.uppercaseString]
          size:10 x:0 y:height * 0.5 - 30 color:PBBrass() parent:_menu];
    [self label:text size:text.length > 15 ? 28 : 36 x:0 y:height * 0.5 - 78 color:PBIvory() parent:_menu];
    if (subtitle) [self label:subtitle size:11 x:0 y:height * 0.5 - 114 color:PBMuted() parent:_menu];
}

- (void)showScreen:(PBMenuScreen)screen {
    _screen = screen;
    [self render];
}

/// SceneKit draws this overlay on its render thread, and SCNTransaction's lock doesn't cover it: a node
/// changed from the main thread mid-frame crashes SpriteKit's renderer (SKCRenderer). So once running,
/// changes queue here and are applied by -update:, which runs on that thread just before each draw.
- (void)applyChange:(dispatch_block_t)change {
    [_changesLock lock];
    if (!_deferChanges || _applyingChanges) change();
    else [_changes addObject:[change copy]];
    [_changesLock unlock];
}

- (BOOL)onRenderThread {
    return !_deferChanges || _applyingChanges;
}

- (void)update:(NSTimeInterval)currentTime {
    [_changesLock lock];
    _applyingChanges = YES;
    NSArray *changes = _changes.copy;
    [_changes removeAllObjects];
    for (dispatch_block_t change in changes) change();
    _applyingChanges = NO;
    [_changesLock unlock];
}

- (void)render {
    [self applyChange:^{ [self rebuildNodes]; }];
}

- (void)rebuildNodes {
    [_root removeAllChildren];
    [_keys removeAllObjects];
    _scoreSprite = _ballSprite = _messageSprite = nil;
    if (_screen == PBMenuPlaying) { [self renderHUD]; return; }
    SKSpriteNode *scrim = [SKSpriteNode spriteNodeWithColor:[PBInk() colorWithAlphaComponent:0.84]
                                                     size:CGSizeMake(402, _logicalHeight)];
    scrim.position = CGPointMake(201, _logicalHeight * 0.5);
    [_root addChild:scrim];
    CGFloat height = _screen == PBMenuHome ? 700 : _screen == PBMenuPaused ? 520 :
                     _screen == PBMenuSettings ? 610 : _screen == PBMenuHelp ? 620 :
                     _screen == PBMenuResults ? 600 : _screen == PBMenuLevels ? 700 :
                     _screen == PBMenuLevelIntro ? 560 : 440;
    CGFloat top = MAX(18, _topInset + 12), bottom = MAX(18, _bottomInset + 12);
    CGFloat available = MAX(200, _logicalHeight - top - bottom);
    _menu = [SKNode node];
    _menu.position = CGPointMake(201, bottom + available * 0.5);
    _menu.xScale = _menu.yScale = MIN(1, available / (height + 12));
    [_root addChild:_menu];
    [self panel:CGSizeMake(362, height) at:CGPointZero parent:_menu];
    // Small cabinet fasteners, part of the panel construction rather than UI symbols.
    for (NSNumber *x in @[@-167, @167]) for (NSNumber *sign in @[@-1, @1]) {
        CGPathRef dot = CGPathCreateWithEllipseInRect(CGRectMake(-2, -2, 4, 4), NULL);
        SKSpriteNode *rivet = PBPathSprite(dot, CGSizeMake(6, 6), PBBrass(), nil, 0);
        CGPathRelease(dot);
        rivet.position = CGPointMake(x.doubleValue, sign.doubleValue * (height * 0.5 - 14));
        [_menu addChild:rivet];
    }
    switch (_screen) {
        case PBMenuHome: [self renderHome]; break;
        case PBMenuPaused: [self renderPause]; break;
        case PBMenuSettings: [self renderSettings]; break;
        case PBMenuHelp: [self renderHelp]; break;
        case PBMenuResults: [self renderResults]; break;
        case PBMenuLevels: [self renderLevels]; break;
        case PBMenuLevelIntro: [self renderLevelIntro]; break;
        case PBMenuConfirmHome:
        case PBMenuConfirmRestart: [self renderConfirmation]; break;
        default: break;
    }
}

- (void)renderHome {
    [self label:@"THE ARCADE COLLECTION" size:10 x:0 y:310 color:PBBrass() parent:_menu];
    [self label:@"PINBALL" size:52 x:0 y:263 color:PBIvory() parent:_menu];
    [self label:@"A LITTLE SKILL. A LOT OF PINBALL." size:11 x:0 y:222 color:PBMuted() parent:_menu];
    [self panel:CGSizeMake(156, 156) at:CGPointMake(0, 116) parent:_menu];
    SKSpriteNode *hero = [SKSpriteNode spriteNodeWithTexture:_titleArt size:CGSizeMake(144, 144)];
    hero.position = CGPointMake(0, 116);
    [_menu addChild:hero];
    if (_levelStars) {
        [self label:[NSString stringWithFormat:@"LEVEL %ld OF %lu", (long)_currentLevel + 1, (unsigned long)_levelStars.count]
              size:13 x:0 y:12 color:PBIvory() parent:_menu];
        [self label:@"STARS EARNED" size:10 x:0 y:-32 color:PBBrass() parent:_menu];
        [self label:[NSString stringWithFormat:@"%ld / %lu", (long)_totalStars, (unsigned long)_levelStars.count * 3]
              size:28 x:0 y:-61 color:PBIvory() parent:_menu];
    } else {
        [self label:[NSString stringWithFormat:@"%@  /  %@", _tableName.uppercaseString, _skinName.uppercaseString]
              size:13 x:0 y:12 color:PBIvory() parent:_menu];
        [self label:@"PERSONAL BEST" size:10 x:0 y:-32 color:PBBrass() parent:_menu];
        [self label:PBScoreString(_best) size:28 x:0 y:-61 color:PBIvory() parent:_menu];
    }
    [self key:@"primary" title:@"PLAY" action:PBUIPlay x:0 y:-140 width:320 parent:_menu];
    [self icon:@"trophy" caption:@"SCORES" action:PBUILeaderboard x:-92 y:-230];
    [self icon:@"settings" caption:@"SETTINGS" action:PBUISettings x:0 y:-230];
    [self icon:@"help" caption:@"HOW TO PLAY" action:PBUIHelp x:92 y:-230];
    [self label:[NSString stringWithFormat:@"%ld BALLS  •  ONE PLAYER", (long)_ballCount]
          size:10 x:0 y:-316 color:PBMuted() parent:_menu];
}

- (void)renderLevels {
    [self heading:@"LEVELS" subtitle:[NSString stringWithFormat:@"%ld / %lu STARS", (long)_totalStars, (unsigned long)_levelStars.count * 3] height:700];
    NSInteger count = (NSInteger)_levelStars.count, pages = MAX(1, (count + kLevelsPerPage - 1) / kLevelsPerPage);
    _levelPage = MAX(0, MIN(_levelPage, pages - 1));
    for (NSInteger slot = 0; slot < kLevelsPerPage; slot++) {
        NSInteger index = _levelPage * kLevelsPerPage + slot;
        if (index >= count) break;
        CGFloat x = (slot % 3 - 1) * 112.0, y = 168.0 - (slot / 3) * 100.0;
        NSInteger stars = _levelStars[(NSUInteger)index].integerValue;
        NSString *title = [NSString stringWithFormat:@"%ld", (long)index + 1];
        PBUIKey *tile = [self key:index == _currentLevel ? @"primary" : @"secondary" title:title action:PBUISelectLevel x:x y:y width:104 parent:_menu];
        tile.tag = index;
        tile.enabled = stars >= 0;
        [tile refresh];
        if (stars < 0) continue;
        for (NSInteger s = 0; s < 3; s++) [_menu addChild:PBStar(7, CGPointMake(x + (s - 1) * 17, y - 37), s < stars)];
    }
    if (pages > 1) {
        PBUIKey *previous = [self key:@"secondary" title:@"PREV" action:PBUIPreviousPage x:-112 y:-222 width:104 parent:_menu];
        previous.enabled = _levelPage > 0;
        [previous refresh];
        PBUIKey *next = [self key:@"secondary" title:@"NEXT" action:PBUINextPage x:112 y:-222 width:104 parent:_menu];
        next.enabled = _levelPage < pages - 1;
        [next refresh];
        [self label:[NSString stringWithFormat:@"%ld / %ld", (long)_levelPage + 1, (long)pages] size:13 x:0 y:-222 color:PBMuted() parent:_menu];
    }
    [self key:@"secondary" title:@"BACK" action:PBUIBack x:0 y:-295 width:260 parent:_menu];
}

- (void)showLevelPageForLevel:(NSInteger)index {
    _levelPage = MAX(index, 0) / kLevelsPerPage;
    _selectedLevel = index;
}

- (void)renderLevelIntro {
    [self heading:_levelName.uppercaseString subtitle:[NSString stringWithFormat:@"LEVEL %ld", (long)_selectedLevel + 1] height:560];
    [self label:@"YOUR GOAL" size:11 x:0 y:112 color:PBBrass() parent:_menu];
    [self label:_levelGoal size:30 x:0 y:80 color:PBIvory() parent:_menu];
    NSInteger earned = _selectedLevel < (NSInteger)_levelStars.count ? MAX(_levelStars[(NSUInteger)_selectedLevel].integerValue, 0) : 0;
    NSArray *tiers = @[ @[ @1, @"COMPLETE THE GOAL" ],
                        @[ @2, [@"SCORE " stringByAppendingString:PBScoreString(_levelTwoStarScore)] ],
                        @[ @3, [@"SCORE " stringByAppendingString:PBScoreString(_levelThreeStarScore)] ] ];
    for (NSUInteger i = 0; i < tiers.count; i++) {
        CGFloat y = 30.0 - (CGFloat)i * 30.0;
        NSInteger stars = [tiers[i][0] integerValue];
        for (NSInteger s = 0; s < stars; s++) [_menu addChild:PBStar(8, CGPointMake(-132 + s * 19, y), earned >= stars)];
        SKLabelNode *label = [self label:tiers[i][1] size:14 x:-62 y:y color:PBIvory() parent:_menu];
        label.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
    }
    [self label:_levelBest > 0 ? [@"YOUR BEST  " stringByAppendingString:PBScoreString(_levelBest)] : @"THREE BALLS. GOOD LUCK."
          size:11 x:0 y:-58 color:PBMuted() parent:_menu];
    [self key:@"primary" title:@"PLAY" action:PBUIPlay x:0 y:-124 width:320 parent:_menu];
    [self key:@"secondary" title:@"BACK" action:PBUIBack x:0 y:-212 width:260 parent:_menu];
}

- (void)renderPause {
    [self heading:@"PAUSED" subtitle:_levelGoal ? [@"GOAL: " stringByAppendingString:_levelGoal] : @"YOUR BALL IS WAITING." height:520];
    [self label:PBScoreString(_score) size:28 x:0 y:82 color:PBIvory() parent:_menu];
    [self key:@"primary" title:@"RESUME" action:PBUIResume x:0 y:-6 width:320 parent:_menu];
    [self icon:@"settings" caption:@"SETTINGS" action:PBUISettings x:-92 y:-100];
    [self icon:@"restart" caption:@"RESTART" action:PBUIRestart x:0 y:-100];
    [self icon:@"close" caption:@"END GAME" action:PBUIHome x:92 y:-100];
    [self key:@"secondary" title:@"HOW TO PLAY" action:PBUIHelp x:0 y:-196 width:260 parent:_menu];
}

- (void)settingLabel:(NSString *)title detail:(NSString *)detail y:(CGFloat)y {
    SKLabelNode *label = [self label:title size:18 x:-132 y:y + 12 color:PBIvory() parent:_menu];
    label.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
    label = [self label:detail size:11 x:-132 y:y - 12 color:PBMuted() parent:_menu];
    label.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
}

- (void)renderSettings {
    [self heading:@"SETTINGS" subtitle:@"MAKE YOURSELF AT HOME." height:610];
    [self settingLabel:@"SOUND" detail:@"Table effects & fanfares" y:110];
    PBUIKey *sound = [self key:@"secondary" title:_soundEnabled ? @"ON" : @"OFF"
                       action:PBUISound x:106 y:110 width:108 parent:_menu];
    sound.selected = _soundEnabled; [sound refresh];
    [self settingLabel:@"HAPTICS" detail:@"Feel every bounce & launch" y:20];
    PBUIKey *haptics = [self key:@"secondary" title:_hapticsEnabled ? @"ON" : @"OFF"
                         action:PBUIHaptics x:106 y:20 width:108 parent:_menu];
    haptics.selected = _hapticsEnabled;
    [haptics refresh];
    [self settingLabel:_skinName.uppercaseString detail:@"Table finish" y:-70];
    [self key:@"secondary" title:@"CHANGE" action:PBUINextSkin x:106 y:-70 width:108 parent:_menu];
    [self key:@"primary" title:@"DONE" action:PBUIBack x:0 y:-218 width:320 parent:_menu];
    [self label:@"CHANGES ARE SAVED AUTOMATICALLY" size:9 x:0 y:-271 color:PBMuted() parent:_menu];
}

- (void)renderHelp {
    [self heading:@"HOW TO PLAY" subtitle:@"LAUNCH. AIM. KEEP IT ALIVE." height:620];
    NSArray *steps = @[@[@"01  LAUNCH", @"Hold the right side. Release to launch."],
                       @[@"02  FLIP", @"Touch the left or right half to flip that side."],
                       @[@"03  NUDGE", @"Give your phone a shove. Too much will tilt."],
                       @[@"04  BUILD YOUR SCORE", @"Complete lanes & targets. Chase multiball."],
                       @[@"05  KEEP GOING", @"Three balls. Bonus is counted after each drain."]];
    for (NSUInteger i = 0; i < steps.count; i++) {
        CGFloat y = 124.0 - (CGFloat)i * 64.0;
        SKLabelNode *title = [self label:steps[i][0] size:17 x:-138 y:y color:PBIvory() parent:_menu];
        title.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
        SKLabelNode *detail = [self label:steps[i][1] size:12 x:-138 y:y - 25 color:PBMuted() parent:_menu];
        detail.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
    }
    [self key:@"primary" title:@"GOT IT" action:PBUIBack x:0 y:-239 width:320 parent:_menu];
}

- (void)renderLevelResults {
    [self heading:_resultGoalMet ? @"LEVEL COMPLETE" : @"NOT THIS TIME"
         subtitle:[NSString stringWithFormat:@"%@  /  GOAL: %@", _levelName.uppercaseString, _levelGoal] height:600];
    for (NSInteger s = 0; s < 3; s++) {
        [_menu addChild:PBStar(s == 1 ? 28 : 22, CGPointMake((s - 1) * 62, s == 1 ? 142 : 134), s < _resultStars)];
    }
    [self label:PBScoreString(_score) size:40 x:0 y:82 color:_newRecord ? PBRed() : PBIvory() parent:_menu];
    [self label:_newRecord ? @"NEW LEVEL BEST" : [@"LEVEL BEST  " stringByAppendingString:PBScoreString(_best)]
          size:11 x:0 y:46 color:PBBrass() parent:_menu];
    if (_resultGoalMet && _hasNextLevel) {
        [self key:@"primary" title:@"NEXT LEVEL" action:PBUINextLevel x:0 y:-22 width:320 parent:_menu];
        [self key:@"secondary" title:@"PLAY AGAIN" action:PBUIPlay x:0 y:-104 width:260 parent:_menu];
    } else {
        [self key:@"primary" title:@"TRY AGAIN" action:PBUIPlay x:0 y:-40 width:320 parent:_menu];
    }
    [self icon:@"trophy" caption:@"SCORES" action:PBUILeaderboard x:-92 y:-196];
    [self icon:@"back" caption:@"LEVELS" action:PBUILevels x:0 y:-196];
    [self icon:@"settings" caption:@"SETTINGS" action:PBUISettings x:92 y:-196];
}

- (void)renderResults {
    if (_levelStars) { [self renderLevelResults]; return; }
    [self heading:@"GAME OVER" subtitle:_newRecord ? @"NEW PERSONAL BEST" : @"NICE RUN. GO AGAIN."
             height:600];
    [self label:PBScoreString(_score) size:44 x:0 y:106 color:_newRecord ? PBRed() : PBIvory() parent:_menu];
    [self label:@"PERSONAL BEST" size:10 x:0 y:48 color:PBBrass() parent:_menu];
    [self label:PBScoreString(_best) size:20 x:0 y:20 color:PBIvory() parent:_menu];
    [self key:@"primary" title:@"PLAY AGAIN" action:PBUIPlay x:0 y:-61 width:320 parent:_menu];
    [self icon:@"trophy" caption:@"SCORES" action:PBUILeaderboard x:-92 y:-161];
    [self icon:@"back" caption:@"MAIN MENU" action:PBUIHome x:0 y:-161];
    [self icon:@"settings" caption:@"SETTINGS" action:PBUISettings x:92 y:-161];
    [self label:@"ONE MORE GAME?" size:11 x:0 y:-257 color:PBMuted() parent:_menu];
}

- (void)renderConfirmation {
    BOOL restart = _screen == PBMenuConfirmRestart;
    [self heading:restart ? @"START AGAIN?" : @"END THIS GAME?" subtitle:nil height:440];
    [self label:@"This run will not be saved to the leaderboard." size:12 x:0 y:66 color:PBMuted() parent:_menu];
    [self label:restart ? @"Start fresh with three balls." : @"Your personal best stays safe."
          size:12 x:0 y:42 color:PBMuted() parent:_menu];
    [self key:@"primary" title:restart ? @"RESTART" : @"END GAME" action:PBUIConfirm x:0 y:-29 width:320 parent:_menu];
    [self key:@"secondary" title:@"KEEP PLAYING" action:PBUICancel x:0 y:-119 width:320 parent:_menu];
}

/// The classic 5x7 dot-matrix font: seven rows of five bits, top row first.
static const uint8_t *PBLEDGlyph(unichar c) {
    static const struct { char c; uint8_t rows[7]; } font[] = {
        {'0',{14,17,17,17,17,17,14}},{'1',{4,12,4,4,4,4,14}},{'2',{14,17,1,2,4,8,31}},{'3',{31,2,4,2,1,17,14}},
        {'4',{2,6,10,18,31,2,2}},{'5',{31,16,30,1,1,17,14}},{'6',{6,8,16,30,17,17,14}},{'7',{31,1,2,4,8,8,8}},
        {'8',{14,17,17,14,17,17,14}},{'9',{14,17,17,15,1,2,12}},
        {'A',{14,17,17,31,17,17,17}},{'B',{30,17,17,30,17,17,30}},{'C',{14,17,16,16,16,17,14}},{'D',{28,18,17,17,17,18,28}},
        {'E',{31,16,16,30,16,16,31}},{'F',{31,16,16,30,16,16,16}},{'G',{14,17,16,23,17,17,15}},{'H',{17,17,17,31,17,17,17}},
        {'I',{14,4,4,4,4,4,14}},{'J',{7,2,2,2,2,18,12}},{'K',{17,18,20,24,20,18,17}},{'L',{16,16,16,16,16,16,31}},
        {'M',{17,27,21,21,17,17,17}},{'N',{17,17,25,21,19,17,17}},{'O',{14,17,17,17,17,17,14}},{'P',{30,17,17,30,16,16,16}},
        {'Q',{14,17,17,17,21,18,13}},{'R',{30,17,17,30,20,18,17}},{'S',{15,16,16,14,1,1,30}},{'T',{31,4,4,4,4,4,4}},
        {'U',{17,17,17,17,17,17,14}},{'V',{17,17,17,17,17,10,4}},{'W',{17,17,17,21,21,21,10}},{'X',{17,17,10,4,10,17,17}},
        {'Y',{17,17,17,10,4,4,4}},{'Z',{31,1,2,4,8,16,31}},
        {'+',{0,4,4,31,4,4,0}},{'-',{0,0,0,31,0,0,0}},{'.',{0,0,0,0,0,12,12}},{',',{0,0,0,0,12,4,8}},{':',{0,12,12,0,12,12,0}},
        {'/',{0,1,2,4,8,16,0}},{'!',{4,4,4,4,4,0,4}},{'\'',{12,4,8,0,0,0,0}},
    };
    static const uint8_t blank[7] = {0};
    if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';
    for (size_t i = 0; i < sizeof(font) / sizeof(font[0]); i++) if (font[i].c == c) return font[i].rows;
    return blank;
}

/// Text as a dot-matrix display, `columns` characters wide and right-aligned when `right`.
/// Strokes are two dots wide, as on Space Cadet's display. Each cell is seven dots across, seven high.
static SKTexture *PBLEDTexture(NSString *text, NSUInteger columns, BOOL right, SKColor *color, CGFloat *outWidthInDots) {
    columns = MAX(columns, text.length);
    const size_t cell = 9;  // Pixels per dot; the sprite scales it to the display's pitch.
    size_t dotsWide = columns * 7 - 1, width = dotsWide * cell, height = 7 * cell;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGFloat r = 1, g = 1, b = 1, a = 1;
#if TARGET_OS_IPHONE
    [color getRed:&r green:&g blue:&b alpha:&a];
#else
    [[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] getRed:&r green:&g blue:&b alpha:&a];
#endif
    NSUInteger offset = right ? columns - text.length : 0;
    for (size_t row = 0; row < 7; row++) {
        for (size_t x = 0; x < dotsWide; x++) {
            size_t column = x / 7, within = x % 7;
            BOOL lit = NO;
            if (within < 6 && column >= offset && column - offset < text.length) {
                uint8_t bits = PBLEDGlyph([text characterAtIndex:column - offset])[row];
                lit = (bits | bits << 1) >> (5 - within) & 1;
            }
            if (!lit) continue;
            // Nearly touching, so strokes read as solid lines of light rather than scattered specks.
            CGRect dot = CGRectInset(CGRectMake(x * cell, (6 - row) * cell, cell, cell), .3, .3);
            CGContextSetRGBFillColor(c, r, g, b, 1);
            CGContextFillEllipseInRect(c, dot);
        }
    }
    if (outWidthInDots) *outWidthInDots = dotsWide;
    CGImageRef image = CGBitmapContextCreateImage(c);
    SKTexture *texture = [SKTexture textureWithCGImage:image];
    CGImageRelease(image);
    CGContextRelease(c);
    return texture;
}

static SKColor *PBLEDColor(void) { return [SKColor colorWithRed:.72 green:.68 blue:1 alpha:1]; }

/// Black that fades out at its sides and foot, behind the display. No panel, no border.
static SKTexture *PBLEDBackdrop(size_t width, size_t height, size_t feather) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    uint8_t *pixels = CGBitmapContextGetData(c);
    size_t stride = CGBitmapContextGetBytesPerRow(c);
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            float side = MIN(1.0f, (float)MIN(x, width - 1 - x) / feather);
            // Bitmap rows run from the top of the image.
            float foot = MIN(1.0f, (float)(height - 1 - y) / feather);
            pixels[y * stride + x * 4 + 3] = (uint8_t)(255 * side * foot);
        }
    }
    CGImageRef image = CGBitmapContextCreateImage(c);
    SKTexture *texture = [SKTexture textureWithCGImage:image];
    CGImageRelease(image);
    CGContextRelease(c);
    return texture;
}

/// A round texture from three grey levels and their alphas, brightest at centre. CoreGraphics, so it builds for Mac previews too.
static SKTexture *PBRadialTexture(size_t pixels, const CGFloat tones[6], CGPoint centre) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, pixels, pixels, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGFloat stops[12];
    for (int i = 0; i < 3; i++) {
        stops[i * 4] = stops[i * 4 + 1] = stops[i * 4 + 2] = tones[i * 2];
        stops[i * 4 + 3] = tones[i * 2 + 1];
    }
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, stops, NULL, 3);
    CGContextAddEllipseInRect(c, CGRectMake(0, 0, pixels, pixels));
    CGContextClip(c);
    CGContextDrawRadialGradient(c, gradient, CGPointMake(pixels * centre.x, pixels * centre.y), 0, CGPointMake(pixels * .5, pixels * .5), pixels * .62, 0);
    CGImageRef image = CGBitmapContextCreateImage(c);
    SKTexture *texture = [SKTexture textureWithCGImage:image];
    CGImageRelease(image);
    CGGradientRelease(gradient);
    CGContextRelease(c);
    CGColorSpaceRelease(space);
    return texture;
}

/// Sets a sprite to show text as dots of this pitch, keeping its anchor where it is.
- (void)showLED:(NSString *)text on:(SKSpriteNode *)sprite columns:(NSUInteger)columns right:(BOOL)right pitch:(CGFloat)pitch color:(SKColor *)color maxWidth:(CGFloat)maxWidth {
    CGFloat dots = 0;
    sprite.texture = PBLEDTexture(text, columns, right, color, &dots);
    CGFloat scale = MIN(pitch, maxWidth / dots);
    sprite.size = CGSizeMake(dots * scale, 7 * scale);
}

- (void)renderHUD {
    // Dot-matrix readouts straight on black, between the corner flashers and above the ramps.
    CGFloat wingY = _logicalHeight - MAX(_topInset - 30, 30);
    PBUIKey *pause = [self key:@"pause" title:nil action:PBUIPause x:326 y:wingY width:30 parent:_root];
    pause.name = @"hud.pause";

    CGFloat top = MAX(_topInset, 26);
    const CGFloat backdropHeight = top + 66;
    SKSpriteNode *backdrop = [SKSpriteNode spriteNodeWithTexture:PBLEDBackdrop(120, 60, 22) size:CGSizeMake(360, backdropHeight)];
    backdrop.position = CGPointMake(201, _logicalHeight - backdropHeight * .5);
    backdrop.zPosition = -1;
    backdrop.name = @"hud.backdrop";
    [_root addChild:backdrop];

    _scoreSprite = [SKSpriteNode node];
    _scoreSprite.name = @"hud.score";
    _scoreSprite.position = CGPointMake(201, _logicalHeight - top - 18);
    [_root addChild:_scoreSprite];

    _ballSprite = [SKSpriteNode node];
    _ballSprite.name = @"hud.balls";
    _ballSprite.anchorPoint = CGPointMake(0, .5);
    _ballSprite.position = CGPointMake(22, wingY);
    [_root addChild:_ballSprite];

    _messageSprite = [SKSpriteNode node];
    _messageSprite.name = @"hud.message";
    _messageSprite.position = CGPointMake(201, _logicalHeight - top - 46);
    [_root addChild:_messageSprite];

    [self updateScore:_score best:_best ball:_ball ballCount:_ballCount];
    [self showMessage:_message];
}

- (void)showImpactAtPoint:(CGPoint)point color:(SKColor *)color sparks:(NSInteger)sparks points:(int64_t)points {
    if (_screen != PBMenuPlaying || _liveEffects > 14) return;
    CGPoint at = [self logicalPoint:point];
    [self applyChange:^{
    self->_liveEffects++;
    __weak PBGameUI *weakSelf = self;
    SKAction *finish = [SKAction runBlock:^{ PBGameUI *me = weakSelf; if (me) me->_liveEffects--; }];
    SKNode *effect = [SKNode node];
    effect.position = at;
    effect.zPosition = 40;
    [_root addChild:effect];

    if (sparks > 0) {
        static SKTexture *dot;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            const CGFloat glow[6] = { 1, 1, 1, .85, 1, 0 };
            dot = PBRadialTexture(32, glow, CGPointMake(.5, .5));
        });
        SKEmitterNode *emitter = [SKEmitterNode new];
        emitter.particleTexture = dot;
        emitter.numParticlesToEmit = sparks;
        emitter.particleBirthRate = sparks * 40;
        emitter.particleLifetime = .38;
        emitter.particleLifetimeRange = .2;
        emitter.particleSpeed = 170;
        emitter.particleSpeedRange = 110;
        emitter.emissionAngleRange = 2 * M_PI;
        emitter.yAcceleration = -220;
        emitter.particleScale = .21;
        emitter.particleScaleRange = .1;
        emitter.particleScaleSpeed = -.4;
        emitter.particleAlphaSpeed = -1.8;
        emitter.particleColor = color;
        // A tint toward the part's colour, on a white-hot core. Additive blending over the
        // overlay's transparent background greys the particles out into smoke.
        emitter.particleColorBlendFactor = .55;
        emitter.particleBlendMode = SKBlendModeAlpha;
        [effect addChild:emitter];
    }
    if (points > 0) {
        NSString *text = [NSString stringWithFormat:@"+%lld", points];
        CGFloat pitch = MIN(3.4, 1.7 + log10((double)MAX(points, 10)) * .34);
        CGFloat dots = 0;
        SKTexture *lit = PBLEDTexture(text, text.length, NO, [SKColor colorWithRed:1 green:.86 blue:.42 alpha:1], &dots);
        SKSpriteNode *number = [SKSpriteNode spriteNodeWithTexture:lit size:CGSizeMake(dots * pitch, 7 * pitch)];
        [number setScale:.5];
        [effect addChild:number];
        SKAction *pop = [SKAction sequence:@[ [SKAction scaleTo:1.15 duration:.1], [SKAction scaleTo:1 duration:.08] ]];
        SKAction *rise = [SKAction moveByX:0 y:58 duration:.85];
        rise.timingMode = SKActionTimingEaseOut;
        SKAction *fade = [SKAction sequence:@[ [SKAction waitForDuration:.5], [SKAction fadeOutWithDuration:.35] ]];
        [number runAction:[SKAction group:@[ pop, rise, fade ]]];
    }
    [effect runAction:[SKAction sequence:@[ [SKAction waitForDuration:.95], finish, [SKAction removeFromParent] ]]];
    }];
}

- (void)showMessage:(NSString *)message {
    _message = message;
    [self applyChange:^{
    if (self->_messageSprite) {
        NSString *text = message ?: self.levelGoal ?: @"";
        const NSUInteger columns = 20;
        if (text.length > columns) text = [text substringToIndex:columns];
        [self showLED:text on:self->_messageSprite columns:text.length right:NO pitch:2.05 color:message ? self.messageColor : PBLEDColor() maxWidth:290];
    }
    }];
}

- (void)updateScore:(int64_t)score best:(int64_t)best ball:(NSInteger)ball
         ballCount:(NSInteger)ballCount {
    _score = score; _best = best; _ball = ball; _ballCount = ballCount;
    NSInteger multiplier = _bonusMultiplier;
    [self applyChange:^{
    if (self->_scoreSprite) {
        NSString *digits = [NSString stringWithFormat:@"%lld", score];
        [self showLED:digits on:self->_scoreSprite columns:digits.length right:NO pitch:3.9 color:PBLEDColor() maxWidth:230];
        NSString *balls = [NSString stringWithFormat:@"BALL %ld/%ld", (long)MAX(1, ball), (long)ballCount];
        if (multiplier > 1) balls = [NSString stringWithFormat:@"X%ld %@", (long)multiplier, balls];
        [self showLED:balls on:self->_ballSprite columns:balls.length right:NO pitch:1.9 color:PBLEDColor() maxWidth:104];
    }
    }];
}

- (CGPoint)logicalPoint:(CGPoint)point {
    CGFloat scale = _inputViewSize.width / 402.0;
    return CGPointMake(point.x / scale, (_inputViewSize.height - point.y) / scale);
}

- (BOOL)key:(PBUIKey *)key contains:(CGPoint)point {
    return CGRectContainsPoint(key.hitRect, [key convertPoint:point fromNode:_root]);
}

- (BOOL)pointerBegan:(id)pointer atPoint:(CGPoint)point {
    if (self.hidden) return NO;
    CGPoint logical = [self logicalPoint:point];
    // The render thread replaces these keys when it rebuilds a screen.
    [_changesLock lock];
    NSArray<PBUIKey *> *keys = _keys.copy;
    PBUIKey *pressed = nil;
    for (PBUIKey *key in keys.reverseObjectEnumerator) {
        if (key.enabled && [self key:key contains:logical]) { pressed = key; break; }
    }
    [_changesLock unlock];
    if (pressed) {
        [_capturedPointers addObject:pointer];
        [_pressedKeys setObject:pressed forKey:pointer];
        pressed.pressed = YES; [pressed refresh];
        return YES;
    }
    if (_screen != PBMenuPlaying) { [_capturedPointers addObject:pointer]; return YES; }
    return NO;
}

- (BOOL)pointerMoved:(id)pointer atPoint:(CGPoint)point {
    if (![_capturedPointers containsObject:pointer]) return NO;
    PBUIKey *key = [_pressedKeys objectForKey:pointer];
    if (key) { key.pressed = [self key:key contains:[self logicalPoint:point]]; [key refresh]; }
    return YES;
}

- (BOOL)pointerEnded:(id)pointer atPoint:(CGPoint)point cancelled:(BOOL)cancelled {
    if (![_capturedPointers containsObject:pointer]) return NO;
    PBUIKey *key = [_pressedKeys objectForKey:pointer];
    BOOL activate = key && key.parent && key.enabled && !cancelled && [self key:key contains:[self logicalPoint:point]];
    key.pressed = NO; [key refresh];
    [_pressedKeys removeObjectForKey:pointer];
    [_capturedPointers removeObject:pointer];
    if (activate && (key.action == PBUIPreviousPage || key.action == PBUINextPage)) {
        _levelPage += key.action == PBUINextPage ? 1 : -1;
        [self render];
    } else if (activate && self.actionHandler) {
        if (key.action == PBUISelectLevel) _selectedLevel = key.tag;
        self.actionHandler(key.action);
    }
    return YES;
}

- (void)cancelPointers {
    [_changesLock lock];
    NSArray<PBUIKey *> *keys = _keys.copy;
    [_changesLock unlock];
    for (PBUIKey *key in keys) { key.pressed = NO; [key refresh]; }
    [_pressedKeys removeAllObjects];
    [_capturedPointers removeAllObjects];
}

@end
