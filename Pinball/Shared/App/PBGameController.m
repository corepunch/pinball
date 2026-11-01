//
//  PBGameController.m
//

#import "PBGameController.h"
#import "PBSkin.h"
#import "PBSoundEngine.h"
#import "PBTableScene.h"

static NSString *const kSkinDefaultsKey = @"PBSkin";
static NSString *const kHighScoreKeyPrefix = @"PBHighScore.";

@interface PBGameController () <PBGameObserver>
@end

@implementation PBGameController {
    __weak SCNView *_view;
    PBTableDefinition *_table;
    PBTableScene *_tableScene;
    PBSoundEngine *_sound;
    NSTimeInterval _lastTime;
    NSArray<NSString *> *_skins;
    NSString *_skinName;
}

- (instancetype)initWithView:(SCNView *)view {
    if ((self = [super init])) {
        _view = view;
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *tableName = [NSUserDefaults.standardUserDefaults stringForKey:@"PBTable"] ?: [PBTableDefinition availableTablesInBundle:bundle].firstObject;
        NSError *error;
        _table = [PBTableDefinition tableNamed:tableName bundle:bundle error:&error];
        NSAssert(_table, @"Could not load table %@: %@", tableName, error);

        int64_t highScore = [NSUserDefaults.standardUserDefaults integerForKey:[kHighScoreKeyPrefix stringByAppendingString:_table.identifier]];
        _game = [[PBGame alloc] initWithTable:_table highScore:highScore];
        _game.autopilot = [NSUserDefaults.standardUserDefaults boolForKey:@"PBAutopilot"];
        [_game addObserver:self];

        _sound = [PBSoundEngine new];
        [_game addObserver:_sound];
        [_sound start];

        _skins = [PBSkin availableSkinsInBundle:bundle];
        _skinName = [NSUserDefaults.standardUserDefaults stringForKey:kSkinDefaultsKey] ?: _table.defaultSkin;
        [self loadSkin:_skinName];

        view.delegate = self;
        view.antialiasingMode = SCNAntialiasingModeMultisampling4X;
        view.preferredFramesPerSecond = 60;
        view.rendersContinuously = YES;
        view.playing = YES;
        view.showsStatistics = [NSUserDefaults.standardUserDefaults boolForKey:@"PBStats"];
    }
    return self;
}

- (void)loadSkin:(NSString *)name {
    PBSkin *skin = [PBSkin skinNamed:name bundle:NSBundle.mainBundle] ?: [PBSkin skinNamed:_table.defaultSkin bundle:NSBundle.mainBundle];
    PBTableScene *scene = [[PBTableScene alloc] initWithTable:_table skin:skin];
    [_game addObserver:scene];
    // The render thread reads _tableScene; the transaction lock keeps the swap atomic.
    [SCNTransaction lock];
    _tableScene = scene;
    SCNView *view = _view;
    view.scene = scene.scene;
    view.pointOfView = scene.cameraNode;
    [SCNTransaction unlock];
    [self viewDidResize];
}

- (void)selectNextSkin {
    NSUInteger index = [_skins indexOfObject:_skinName];
    _skinName = _skins[index == NSNotFound ? 0 : (index + 1) % _skins.count];
    [NSUserDefaults.standardUserDefaults setObject:_skinName forKey:kSkinDefaultsKey];
    [self loadSkin:_skinName];
}

- (void)viewDidResize {
    CGSize size = _view.bounds.size;
    if (size.width > 0) [_tableScene fitCameraToAspect:size.height / size.width];
}

#pragma mark - SCNSceneRendererDelegate

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time {
    double elapsed = _lastTime > 0 ? time - _lastTime : 1.0 / 60.0;
    _lastTime = time;
    [SCNTransaction lock];
    [_game update:elapsed];
    [_tableScene syncWithGame:_game elapsed:elapsed];
    [SCNTransaction unlock];
}

#pragma mark - PBGameObserver

- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {}
- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier {}
- (void)game:(PBGame *)game fanfare:(NSString *)name {
    if ([name isEqualToString:@"gameOver"]) {
        [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)game.rules.highScore forKey:[kHighScoreKeyPrefix stringByAppendingString:_table.identifier]];
    }
}

@end
