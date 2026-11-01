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

static SKColor *PBInk(void) { return [SKColor colorWithRed:0.035 green:0.075 blue:0.10 alpha:1]; }
static SKColor *PBIvory(void) { return [SKColor colorWithRed:0.95 green:0.88 blue:0.73 alpha:1]; }
static SKColor *PBBrass(void) { return [SKColor colorWithRed:0.65 green:0.49 blue:0.28 alpha:1]; }
static SKColor *PBMuted(void) { return [SKColor colorWithRed:0.49 green:0.59 blue:0.60 alpha:1]; }
static SKColor *PBRed(void) { return [SKColor colorWithRed:0.88 green:0.23 blue:0.14 alpha:1]; }

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
- (void)refresh;
@end

@implementation PBUIKey
- (void)refresh {
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
    SKLabelNode *_scoreLabel, *_ballLabel, *_launchLabel;
    SKShapeNode *_launchPlate;
    CGFloat _logicalHeight, _topInset, _bottomInset;
    CGSize _inputViewSize;
    int64_t _score, _best;
    NSInteger _ball, _ballCount;
    BOOL _plungerReady;
}

- (instancetype)initWithBundle:(NSBundle *)bundle {
    if ((self = [super initWithSize:CGSizeMake(402, 874)])) {
        self.backgroundColor = SKColor.clearColor;
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.userInteractionEnabled = NO;
        _skinName = @"Orbital";
        _soundEnabled = _hapticsEnabled = YES;
        _ballCount = 3;
        _logicalHeight = 874;
        _inputViewSize = CGSizeMake(402, 874);
        _keys = [NSMutableArray array];
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
                    CGImageRef cell = CGImageCreateWithImageInRect(atlasPixels,
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
    self.size = size;
    CGFloat scale = size.width / 402.0;
    _root.xScale = _root.yScale = scale;
    _logicalHeight = size.height / scale;
    _topInset = top / scale;
    _bottomInset = bottom / scale;
    [self render];
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

- (SKShapeNode *)panel:(CGSize)size at:(CGPoint)position parent:(SKNode *)parent {
    SKShapeNode *panel = [SKShapeNode shapeNodeWithRectOfSize:size cornerRadius:12];
    panel.position = position;
    panel.fillColor = PBInk();
    panel.strokeColor = PBBrass();
    panel.lineWidth = 1.2;
    [parent addChild:panel];
    SKShapeNode *inner = [SKShapeNode shapeNodeWithRectOfSize:CGSizeMake(size.width - 10, size.height - 10) cornerRadius:8];
    inner.strokeColor = [PBBrass() colorWithAlphaComponent:0.28];
    inner.lineWidth = 0.7;
    [panel addChild:inner];
    return panel;
}

- (PBUIKey *)key:(NSString *)art title:(NSString *)title action:(PBUIAction)action
               x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width parent:(SKNode *)parent {
    BOOL wide = title != nil;
    CGFloat height = wide ? 88 : 62;
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
    key.hitRect = CGRectMake(-width * 0.48, -(wide ? 28 : 30), width * 0.96, wide ? 56 : 60);
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

- (void)render {
    [_root removeAllChildren];
    [_keys removeAllObjects];
    _scoreLabel = _ballLabel = _launchLabel = nil;
    _launchPlate = nil;
    if (_screen == PBMenuPlaying) { [self renderHUD]; return; }
    SKSpriteNode *scrim = [SKSpriteNode spriteNodeWithColor:[PBInk() colorWithAlphaComponent:0.84]
                                                     size:CGSizeMake(402, _logicalHeight)];
    scrim.position = CGPointMake(201, _logicalHeight * 0.5);
    [_root addChild:scrim];
    CGFloat height = _screen == PBMenuHome ? 700 : _screen == PBMenuPaused ? 520 :
                     _screen == PBMenuSettings ? 610 : _screen == PBMenuHelp ? 620 :
                     _screen == PBMenuResults ? 600 : 440;
    CGFloat top = MAX(18, _topInset + 12), bottom = MAX(18, _bottomInset + 12);
    CGFloat available = MAX(200, _logicalHeight - top - bottom);
    _menu = [SKNode node];
    _menu.position = CGPointMake(201, bottom + available * 0.5);
    _menu.xScale = _menu.yScale = MIN(1, available / (height + 12));
    [_root addChild:_menu];
    [self panel:CGSizeMake(362, height) at:CGPointZero parent:_menu];
    // Small cabinet fasteners, part of the panel construction rather than UI symbols.
    for (NSNumber *x in @[@-167, @167]) for (NSNumber *sign in @[@-1, @1]) {
        SKShapeNode *rivet = [SKShapeNode shapeNodeWithCircleOfRadius:2];
        rivet.fillColor = PBBrass(); rivet.strokeColor = SKColor.clearColor;
        rivet.position = CGPointMake(x.doubleValue, sign.doubleValue * (height * 0.5 - 14));
        [_menu addChild:rivet];
    }
    switch (_screen) {
        case PBMenuHome: [self renderHome]; break;
        case PBMenuPaused: [self renderPause]; break;
        case PBMenuSettings: [self renderSettings]; break;
        case PBMenuHelp: [self renderHelp]; break;
        case PBMenuResults: [self renderResults]; break;
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
    [self label:[NSString stringWithFormat:@"AURORA  /  %@", _skinName.uppercaseString]
          size:13 x:0 y:12 color:PBIvory() parent:_menu];
    [self label:@"PERSONAL BEST" size:10 x:0 y:-32 color:PBBrass() parent:_menu];
    [self label:PBScoreString(_best) size:28 x:0 y:-61 color:PBIvory() parent:_menu];
    [self key:@"primary" title:@"PLAY" action:PBUIPlay x:0 y:-140 width:320 parent:_menu];
    [self icon:@"trophy" caption:@"SCORES" action:PBUILeaderboard x:-92 y:-230];
    [self icon:@"settings" caption:@"SETTINGS" action:PBUISettings x:0 y:-230];
    [self icon:@"help" caption:@"HOW TO PLAY" action:PBUIHelp x:92 y:-230];
    [self label:[NSString stringWithFormat:@"%ld BALLS  •  ONE PLAYER", (long)_ballCount]
          size:10 x:0 y:-316 color:PBMuted() parent:_menu];
}

- (void)renderPause {
    [self heading:@"PAUSED" subtitle:@"YOUR BALL IS WAITING." height:520];
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
    [self settingLabel:@"HAPTICS" detail:@"Feel the flippers & bumpers" y:20];
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

- (void)renderResults {
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

- (void)renderHUD {
    // Keep all upper lanes visible: the score lives on the cabinet's apron.
    CGFloat y = MAX(_bottomInset + 35, 44);
    [self panel:CGSizeMake(324, 62) at:CGPointMake(201, y) parent:_root];
    SKLabelNode *caption = [self label:@"SCORE" size:9 x:63 y:y + 16 color:PBBrass() parent:_root];
    caption.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
    _scoreLabel = [self label:PBScoreString(_score) size:23 x:63 y:y - 8 color:PBIvory() parent:_root];
    _scoreLabel.fontName = @"Menlo-Bold";
    _scoreLabel.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
    _ballLabel = [self label:@"" size:12 x:302 y:y color:PBIvory() parent:_root];
    CGFloat top = _logicalHeight - MAX(_topInset + 30, 42);
    [self key:@"pause" title:nil action:PBUIPause x:355 y:top width:52 parent:_root];
    _launchPlate = [SKShapeNode shapeNodeWithRectOfSize:CGSizeMake(276, 26) cornerRadius:6];
    _launchPlate.fillColor = PBInk(); _launchPlate.strokeColor = PBBrass();
    _launchPlate.position = CGPointMake(165, top);
    [_root addChild:_launchPlate];
    _launchLabel = [self label:@"HOLD RIGHT  •  RELEASE TO LAUNCH" size:10 x:165 y:top color:PBIvory() parent:_root];
    [self updateScore:_score best:_best ball:_ball ballCount:_ballCount plungerReady:_plungerReady];
}

- (void)updateScore:(int64_t)score best:(int64_t)best ball:(NSInteger)ball
         ballCount:(NSInteger)ballCount plungerReady:(BOOL)ready {
    _score = score; _best = best; _ball = ball; _ballCount = ballCount; _plungerReady = ready;
    _scoreLabel.text = PBScoreString(score);
    _scoreLabel.xScale = 1;
    if (_scoreLabel.frame.size.width > 176) _scoreLabel.xScale = 176 / _scoreLabel.frame.size.width;
    _ballLabel.text = [NSString stringWithFormat:@"BALL %ld / %ld", (long)MAX(1, ball), (long)ballCount];
    _launchLabel.hidden = _launchPlate.hidden = !ready;
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
    for (PBUIKey *key in _keys.reverseObjectEnumerator) {
        if (key.enabled && [self key:key contains:logical]) {
            [_capturedPointers addObject:pointer];
            [_pressedKeys setObject:key forKey:pointer];
            key.pressed = YES; [key refresh];
            return YES;
        }
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
    if (activate && self.actionHandler) self.actionHandler(key.action);
    return YES;
}

- (void)cancelPointers {
    for (PBUIKey *key in _keys) { key.pressed = NO; [key refresh]; }
    [_pressedKeys removeAllObjects];
    [_capturedPointers removeAllObjects];
}

@end
