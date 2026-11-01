//
//  PBGameController.m
//

#import "PBGameController.h"
#import "PBSkin.h"
#import "PBSoundEngine.h"
#import "PBTableScene.h"
#import "PBGameUI.h"
#import <stdatomic.h>

static NSString *const kSkinDefaultsKey = @"PBSkin";
static NSString *const kHighScoreKeyPrefix = @"PBHighScore.";
static NSString *const kSoundEnabledKey = @"PBSoundEnabled";
static NSString *const kHapticsEnabledKey = @"PBHapticsEnabled";

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
    NSLock *_lightingInputLock;
    simd_quatf _lightingAttitude;
    PBGameCenter *_gameCenter;
    _Atomic(BOOL) _applicationActive, _gameCenterPresented, _resetFrameClock, _menuPaused, _hapticsEnabled;
    PBMenuFlow *_menuFlow;
    PBGameUI *_interface;
    NSTimeInterval _lastUISnapshot;
    int64_t _startingHighScore;
}

- (instancetype)initWithView:(SCNView *)view {
    if ((self = [super init])) {
        _view = view;
        _applicationActive = YES;
        _gameCenter = [[PBGameCenter alloc] initWithBundle:NSBundle.mainBundle];
        _gameCenter.showsAccessPoint = NO;
        __weak typeof(self) weakSelf = self;
        _gameCenter.presentationChanged = ^(BOOL presented) {
            [weakSelf setGameCenterPresented:presented];
        };
        _lightingInputLock = [NSLock new];
        _lightingAttitude = simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f);
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
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _sound.enabled = [defaults objectForKey:kSoundEnabledKey] ? [defaults boolForKey:kSoundEnabledKey] : YES;
        _hapticsEnabled = [defaults objectForKey:kHapticsEnabledKey] ? [defaults boolForKey:kHapticsEnabledKey] : YES;
        [_game addObserver:_sound];
        [_sound start];

        _skins = [PBSkin availableSkinsInBundle:bundle];
        _skinName = [NSUserDefaults.standardUserDefaults stringForKey:kSkinDefaultsKey] ?: _table.defaultSkin;
        [self loadSkin:_skinName];

        _menuFlow = [PBMenuFlow new];
        _interface = [[PBGameUI alloc] initWithBundle:bundle];
        _interface.hidden = _game.autopilot;
        _interface.actionHandler = ^(PBUIAction action) { [weakSelf performUIAction:action]; };
        [self configureInterface];
        [_interface updateScore:0 best:highScore ball:0 ballCount:_table.rules.balls plungerReady:NO];
        [_interface showScreen:PBMenuHome];
        _menuPaused = !_game.autopilot;
        view.overlaySKScene = _interface;
        [self viewDidResize];

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
    NSAssert(skin, @"No valid skin available for %@", _table.identifier);
    _skinName = skin.identifier;
    PBTableScene *scene = [[PBTableScene alloc] initWithTable:_table skin:skin];
    // The render thread reads _tableScene; the transaction lock keeps the swap atomic.
    [SCNTransaction lock];
    [_game addObserver:scene];
    _tableScene = scene;
    SCNView *view = _view;
    view.scene = scene.scene;
    view.pointOfView = scene.cameraNode;
    [SCNTransaction unlock];
    [self viewDidResize];
}

- (void)selectNextSkin {
    if (!_skins.count) return;
    NSUInteger index = [_skins indexOfObject:_skinName];
    _skinName = _skins[index == NSNotFound ? 0 : (index + 1) % _skins.count];
    [NSUserDefaults.standardUserDefaults setObject:_skinName forKey:kSkinDefaultsKey];
    [self loadSkin:_skinName];
    [self configureInterface];
    [_interface showScreen:_menuFlow.screen];
}

- (void)configureInterface {
    _interface.skinName = _skinName.capitalizedString;
    _interface.soundEnabled = _sound.isEnabled;
    _interface.hapticsEnabled = self.hapticsEnabled;
}

- (void)performUIAction:(PBUIAction)action {
    if (_game.autopilot || atomic_load(&_gameCenterPresented)) return;
    if (action == PBUILeaderboard) { [self showLeaderboard]; return; }
    if (action == PBUINextSkin) { [self selectNextSkin]; return; }
    if (action == PBUISound) {
        _sound.enabled = !_sound.isEnabled;
        [NSUserDefaults.standardUserDefaults setBool:_sound.isEnabled forKey:kSoundEnabledKey];
    }
    if (action == PBUIHaptics) {
        atomic_store(&_hapticsEnabled, !self.hapticsEnabled);
        [NSUserDefaults.standardUserDefaults setBool:self.hapticsEnabled forKey:kHapticsEnabledKey];
    }
    PBMenuCommand command = [_menuFlow performAction:action];
    if (command == PBMenuStartGame) {
        [self releaseInputs];
        _interface.newRecord = NO;
        [_interface updateScore:0 best:_game.rules.highScore ball:1 ballCount:_table.rules.balls plungerReady:YES];
        [_game requestNewGame];
    }
    if (command == PBMenuAbandonGame) [self releaseInputs];
    BOOL paused = _menuFlow.screen != PBMenuPlaying;
    atomic_store(&_menuPaused, paused);
    atomic_store(&_resetFrameClock, YES);
    if (paused) [self releaseInputs];
    [self configureInterface];
    [_interface showScreen:_menuFlow.screen];
}

- (BOOL)pointerBegan:(id)pointer atPoint:(CGPoint)point {
    if (atomic_load(&_gameCenterPresented)) return YES;
    return [_interface pointerBegan:pointer atPoint:point];
}
- (BOOL)pointerMoved:(id)pointer atPoint:(CGPoint)point { return [_interface pointerMoved:pointer atPoint:point]; }
- (BOOL)pointerEnded:(id)pointer atPoint:(CGPoint)point cancelled:(BOOL)cancelled {
    return [_interface pointerEnded:pointer atPoint:point cancelled:cancelled];
}
- (void)cancelUIPointers { [_interface cancelPointers]; }
- (BOOL)hapticsEnabled { return atomic_load(&_hapticsEnabled); }

- (void)startGameCenterWithViewController:(UIViewController *)viewController {
    if (!_game.autopilot) [_gameCenter startWithViewController:viewController];
}

- (void)showLeaderboard {
    if (_menuFlow.screen == PBMenuPlaying) [self performUIAction:PBUIPause];
    if (!_game.autopilot) [_gameCenter showLeaderboardForTable:_table.identifier];
}

- (BOOL)isPaused {
    return !atomic_load(&_applicationActive) || atomic_load(&_gameCenterPresented) || atomic_load(&_menuPaused);
}

- (void)releaseInputs {
    [_game setLeftPressed:NO];
    [_game setRightPressed:NO];
    [_game setPlungerPressed:NO];
    [_game requestNudgeX:0 y:0];
}

- (void)setGameCenterPresented:(BOOL)presented {
    if (presented && _menuFlow.screen == PBMenuPlaying) [self performUIAction:PBUIPause];
    atomic_store(&_gameCenterPresented, presented);
    atomic_store(&_resetFrameClock, YES);
    if (presented) { [self releaseInputs]; [self cancelUIPointers]; }
}

- (void)setApplicationActive:(BOOL)active {
    if (!active && !_game.autopilot && _menuFlow.screen == PBMenuPlaying) [self performUIAction:PBUIPause];
    atomic_store(&_applicationActive, active);
    atomic_store(&_resetFrameClock, YES);
    if (!active) { [self releaseInputs]; [self cancelUIPointers]; }
    else if (!_game.autopilot) [_gameCenter retryPendingScores];
}

- (void)viewDidResize {
    CGSize size = _view.bounds.size;
    if (size.width > 0) [_tableScene fitCameraToAspect:size.height / size.width];
    UIEdgeInsets insets = _view.safeAreaInsets;
    [_interface layoutForViewSize:size topInset:insets.top bottomInset:insets.bottom];
}

- (void)setLightingAttitude:(simd_quatf)attitude {
    float lengthSquared = simd_length_squared(attitude.vector);
    if (!isfinite(lengthSquared) || lengthSquared < 1e-6f) return;
    [_lightingInputLock lock];
    _lightingAttitude = simd_normalize(attitude);
    [_lightingInputLock unlock];
}

#pragma mark - SCNSceneRendererDelegate

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time {
    if (self.isPaused) { _lastTime = 0; return; }
    BOOL resetClock = atomic_exchange(&_resetFrameClock, NO);
    double elapsed = _lastTime > 0 && !resetClock ? time - _lastTime : 1.0 / 60.0;
    _lastTime = time;
    [_lightingInputLock lock];
    simd_quatf attitude = _lightingAttitude;
    [_lightingInputLock unlock];
    [SCNTransaction lock];
    [_tableScene updateLightingForAttitude:attitude elapsed:elapsed];
    [_game update:elapsed];
    [_tableScene syncWithGame:_game elapsed:elapsed];
    if (!_game.autopilot && time - _lastUISnapshot > 0.1) {
        _lastUISnapshot = time;
        int64_t score = _game.rules.score, best = _game.rules.highScore;
        NSInteger ball = _game.rules.ballNumber;
        BOOL ready = _game.world.isBallOnPlunger;
        dispatch_async(dispatch_get_main_queue(), ^{
            // A queued live snapshot must not overwrite the frozen game-over result.
            if (self->_menuFlow.screen == PBMenuPlaying) {
                [self->_interface updateScore:score best:best ball:ball ballCount:self->_table.rules.balls plungerReady:ready];
            }
        });
    }
    [SCNTransaction unlock];
}

#pragma mark - PBGameObserver

- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {}
- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier {}
- (void)game:(PBGame *)game fanfare:(NSString *)name {
    if ([name isEqualToString:@"start"] && !game.autopilot) {
        _startingHighScore = game.rules.highScore;
        dispatch_async(dispatch_get_main_queue(), ^{ [self->_gameCenter beginGame]; });
    }
    if ([name isEqualToString:@"gameOver"]) {
        [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)game.rules.highScore forKey:[kHighScoreKeyPrefix stringByAppendingString:_table.identifier]];
        // Capture on the render thread; GameKit and its outbox run only on main.
        int64_t score = game.rules.score;
        int64_t best = game.rules.highScore;
        BOOL record = score > _startingHighScore;
        if (!game.autopilot) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_gameCenter finishGameWithScore:score tableIdentifier:self->_table.identifier];
                [self->_menuFlow gameDidFinish];
                atomic_store(&self->_menuPaused, YES);
                [self releaseInputs];
                [self->_interface updateScore:score best:best ball:self->_table.rules.balls
                                   ballCount:self->_table.rules.balls plungerReady:NO];
                self->_interface.newRecord = record;
                [self configureInterface];
                [self->_interface showScreen:PBMenuResults];
            });
        }
    }
}

@end
