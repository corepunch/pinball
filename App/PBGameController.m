//
//  PBGameController.m
//

#import "PBGameController.h"
#import "PBBackdropBlur.h"
#import "PBSkin.h"
#import "PBSoundEngine.h"
#import "PBTableScene.h"
#import "PBGameUI.h"
#import "PBLevels.h"
#import <stdatomic.h>

static NSString *const kSkinDefaultsKey = @"PBSkin";
static NSString *const kHighScoreKeyPrefix = @"PBHighScore.";
static NSString *const kSoundEnabledKey = @"PBSoundEnabled";
static NSString *const kHapticsEnabledKey = @"PBHapticsEnabled";

@interface PBGameController () <PBGameObserver>
@end

@implementation PBGameController {
    __weak SCNView *_view;
    SCNTechnique *_backdropBlur;
    PBTableDefinition *_table;
    PBTableScene *_tableScene;
    PBSoundEngine *_sound;
    NSTimeInterval _lastTime;
    NSArray<NSString *> *_skins;
    NSString *_skinName;
    PBSkin *_skin;
    NSLock *_lightingInputLock;
    simd_quatf _lightingAttitude;
    PBGameCenter *_gameCenter;
    _Atomic(BOOL) _applicationActive, _gameCenterPresented, _resetFrameClock, _menuPaused, _hapticsEnabled;
    PBMenuFlow *_menuFlow;
    PBGameUI *_interface;
    NSTimeInterval _lastUISnapshot;
    int64_t _startingHighScore;
    simd_float2 _impactPosition;
    PBEventKind _impactKind;
    NSInteger _impactSparks;
    BOOL _hasImpact;
    int64_t _shownScore;
    NSMutableArray<id<PBGameObserver>> *_gameObservers;
    PBLevelCatalog *_catalog;   // Nil in free play: a table chosen at launch, or autopilot.
    PBLevelProgress *_progress;
    PBLevelSession *_session;
    NSInteger _levelIndex;
    NSString *_forcedSkin;
    PBLevelSession *_previousSession;
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
        NSUserDefaults *launch = NSUserDefaults.standardUserDefaults;
        NSDictionary *arguments = [launch volatileDomainForName:NSArgumentDomain];
        BOOL autopilot = [launch boolForKey:@"PBAutopilot"];
        NSError *error;
        if (!arguments[@"PBTable"] && !autopilot) {
            _catalog = [PBLevelCatalog catalogInBundle:bundle error:&error];
            NSAssert(_catalog, @"Could not load levels: %@", error);
            _progress = [[PBLevelProgress alloc] initWithDefaults:launch];
            _levelIndex = [_progress currentLevelIndexInCatalog:_catalog];
            if (arguments[@"PBLevel"]) _levelIndex = MAX(0, MIN([arguments[@"PBLevel"] integerValue] - 1, (NSInteger)_catalog.levels.count - 1));
        }
        NSString *tableName = _catalog ? _catalog.levels[(NSUInteger)_levelIndex].table
                                       : arguments[@"PBTable"] ?: [PBTableDefinition availableTablesInBundle:bundle].firstObject;
        _gameObservers = [NSMutableArray array];
        _sound = [PBSoundEngine new];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _sound.enabled = [defaults objectForKey:kSoundEnabledKey] ? [defaults boolForKey:kSoundEnabledKey] : YES;
        _hapticsEnabled = [defaults objectForKey:kHapticsEnabledKey] ? [defaults boolForKey:kHapticsEnabledKey] : YES;
        [_sound start];
        [self useTableNamed:tableName];
        _game.autopilot = autopilot;

        _skins = [PBSkin availableSkinsInBundle:bundle];
        // A level brings its own skin. -PBSkin at launch overrides it, for testing.
        _forcedSkin = arguments[kSkinDefaultsKey];
        if (_catalog) {
            [self loadSkin:_forcedSkin ?: _catalog.levels[(NSUInteger)_levelIndex].skin];
        } else {
            [self loadSkin:_forcedSkin ?: [defaults stringForKey:kSkinDefaultsKey] ?: _table.defaultSkin];
        }

        _menuFlow = [PBMenuFlow new];
        _menuFlow.usesLevelMap = _catalog != nil;
        _interface = [[PBGameUI alloc] initWithBundle:bundle];
        _interface.hidden = _game.autopilot;
        _interface.actionHandler = ^(PBUIAction action) { [weakSelf performUIAction:action]; };
        _interface.popupHandler = ^(BOOL shown) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf setBackdropBlurred:shown]; });
        };
        [self configureInterface];
        [_interface updateScore:0 best:_game.rules.highScore ball:0 ballCount:_table.rules.balls];
        [_interface showScreen:PBMenuHome];
        _menuPaused = !_game.autopilot;
        view.overlaySKScene = _interface;
        _interface.deferChanges = YES;
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

- (void)addGameObserver:(id<PBGameObserver>)observer {
    [_gameObservers addObject:observer];
    [_game addObserver:observer];
}

/// Replaces the game when the table changes. The render thread reads it, hence the lock.
- (void)useTableNamed:(NSString *)name {
    if ([_table.identifier isEqualToString:name] && _game) return;
    NSError *error;
    PBTableDefinition *table = [PBTableDefinition tableNamed:name bundle:NSBundle.mainBundle error:&error];
    NSAssert(table, @"Could not load table %@: %@", name, error);
    int64_t highScore = [NSUserDefaults.standardUserDefaults integerForKey:[kHighScoreKeyPrefix stringByAppendingString:table.identifier]];
    PBGame *game = [[PBGame alloc] initWithTable:table highScore:highScore];
    [game addObserver:self];
    [game addObserver:_sound];
    for (id<PBGameObserver> observer in _gameObservers) [game addObserver:observer];
    [SCNTransaction lock];
    _table = table;
    _game = game;
    [SCNTransaction unlock];
}

/// Makes this level the one on the table, behind whichever menu is showing.
- (void)prepareLevelAtIndex:(NSInteger)index {
    _levelIndex = index;
    PBLevelDef *level = _catalog.levels[(NSUInteger)index];
    PBTableDefinition *previous = _table;
    [self useTableNamed:level.table];
    NSString *skin = _forcedSkin ?: level.skin;
    if (_table != previous || ![_skinName isEqualToString:skin]) [self loadSkin:skin];
    PBLevelSession *session = [[PBLevelSession alloc] initWithLevel:level];
    [SCNTransaction lock];
    _session = session;
    [_game removeObserver:_previousSession];
    _previousSession = session;
    [_game addObserver:session];
    [SCNTransaction unlock];
}

- (void)loadSkin:(NSString *)name {
    PBSkin *skin = [PBSkin skinNamed:name bundle:NSBundle.mainBundle] ?: [PBSkin skinNamed:_table.defaultSkin bundle:NSBundle.mainBundle];
    NSAssert(skin, @"No valid skin available for %@", _table.identifier);
    _skinName = skin.identifier;
    _skin = skin;
    PBTableScene *scene = [[PBTableScene alloc] initWithTable:_table skin:skin];
    // The render thread reads _tableScene; the transaction lock keeps the swap atomic.
    [SCNTransaction lock];
    if (_tableScene) [_game removeObserver:_tableScene];
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
    // In free play the choice is remembered. A level's own skin returns at the next level.
    if (!_catalog) [NSUserDefaults.standardUserDefaults setObject:_skinName forKey:kSkinDefaultsKey];
    [self loadSkin:_skinName];
    [self configureInterface];
    [_interface showScreen:_menuFlow.screen];
}

- (void)setBackdropBlurred:(BOOL)blurred {
    if (_game.autopilot) return;
    if (!_backdropBlur) _backdropBlur = [PBBackdropBlur techniqueForDevice:_view.device];
    _view.technique = blurred ? _backdropBlur : nil;
}

- (void)configureInterface {
    _interface.skinName = _skinName.capitalizedString;
    _interface.tableName = _table.name;
    simd_float3 message = _skin.dmdColor;
    _interface.messageColor = [SKColor colorWithRed:message.x green:message.y blue:message.z alpha:1];
    _interface.soundEnabled = _sound.isEnabled;
    _interface.hapticsEnabled = self.hapticsEnabled;
    if (!_catalog) return;
    NSMutableArray *stars = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)_catalog.levels.count; i++) {
        BOOL open = [_progress isLevelUnlockedAtIndex:i inCatalog:_catalog];
        [stars addObject:@(open ? [_progress starsForLevel:_catalog.levels[(NSUInteger)i]] : -1)];
    }
    PBLevelDef *level = _catalog.levels[(NSUInteger)_levelIndex];
    _interface.levelStars = stars;
    _interface.totalStars = _progress.totalStars;
    _interface.currentLevel = [_progress currentLevelIndexInCatalog:_catalog];
    _interface.levelName = level.name;
    _interface.levelGoal = level.goalText;
    _interface.levelTwoStarScore = level.twoStarScore;
    _interface.levelThreeStarScore = level.threeStarScore;
    _interface.levelBest = [_progress bestScoreForLevel:level];
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
    // Only a level the map offered, or the one that follows a completed level, can be chosen.
    if (_catalog && _menuFlow.screen == PBMenuLevels && action == PBUISelectLevel) {
        if (![_progress isLevelUnlockedAtIndex:_interface.selectedLevel inCatalog:_catalog]) return;
        [self prepareLevelAtIndex:_interface.selectedLevel];
    }
    if (_catalog && _menuFlow.screen == PBMenuResults && action == PBUINextLevel) {
        if (![_progress isLevelUnlockedAtIndex:_levelIndex + 1 inCatalog:_catalog]) return;
        [self prepareLevelAtIndex:_levelIndex + 1];
        [_interface showLevelPageForLevel:_levelIndex];
    }
    if (_catalog && _menuFlow.screen == PBMenuHome && action == PBUIPlay) {
        [_interface showLevelPageForLevel:[_progress currentLevelIndexInCatalog:_catalog]];
    }
    PBMenuCommand command = [_menuFlow performAction:action];
    if (command == PBMenuStartGame) {
        // First play from launch or a retry: the level is already on the table.
        if (_catalog && !_session) [self prepareLevelAtIndex:_levelIndex];
        [self releaseInputs];
        _interface.newRecord = NO;
        [_interface updateScore:0 best:_game.rules.highScore ball:1 ballCount:_table.rules.balls];
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
    if (size.width > 0) {
        [_tableScene fitCameraToAspect:size.height / size.width];
    }
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
    [self showImpacts];
    if (!_game.autopilot && time - _lastUISnapshot > 0.1) {
        _lastUISnapshot = time;
        int64_t score = _game.rules.score, best = _game.rules.highScore;
        NSInteger ball = _game.rules.ballNumber;
        NSInteger bonus = _game.rules.bonusMultiplier;
        NSString *message = _game.rules.displayIsMessage ? _game.rules.displayTop : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            // A queued live snapshot must not overwrite the frozen game-over result.
            if (self->_menuFlow.screen == PBMenuPlaying) {
                self->_interface.bonusMultiplier = bonus;
                [self->_interface updateScore:score best:best ball:ball ballCount:self->_table.rules.balls];
                [self->_interface showMessage:message];
            }
        });
    }
    [SCNTransaction unlock];
}

#pragma mark - PBGameObserver

- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    NSInteger sparks = 0;
    switch (event->kind) {
        case PBEventBumper: sparks = 26; break;
        case PBEventSling: sparks = 16; break;
        case PBEventDropTarget: sparks = 22; break;
        case PBEventStandup: sparks = 20; break;
        case PBEventRampComplete: sparks = 30; break;
        case PBEventSaucerCapture: case PBEventKickback: sparks = 24; break;
        case PBEventRollover: case PBEventSpinner: sparks = 6; break;
        case PBEventWallHit: sparks = event->magnitude > 2.2f ? 7 : 0; break;
        default: return;
    }
    // Scoring runs just before this, in the same frame; the frame's score difference is shown once.
    _impactPosition = event->position;
    _impactKind = event->kind;
    _impactSparks = MAX(_impactSparks, sparks);
    _hasImpact = YES;
}

/// Sparks and a flying number at the frame's last hit, in place of a HUD-only score change.
- (void)showImpacts {
    int64_t score = _game.rules.score;
    int64_t gained = score - _shownScore;
    _shownScore = score;
    if (!_hasImpact) return;
    _hasImpact = NO;
    NSInteger sparks = _impactSparks;
    _impactSparks = 0;
    if (_game.autopilot || _game.rules.phase != PBGamePhasePlaying) return;
    SCNVector3 world = [_tableScene worldPointAt:_impactPosition height:0.04f];
    SCNVector3 screen = [_view projectPoint:world];
    simd_float3 tone = [_tableScene impactColorForEvent:_impactKind];
    SKColor *color = [SKColor colorWithRed:tone.x green:tone.y blue:tone.z alpha:1];
    // Spinners and passing rollovers score too often for every number to be worth showing.
    int64_t points = gained >= 250 ? gained : 0;
    if (sparks == 0 && points == 0) return;
    CGPoint point = CGPointMake(screen.x, screen.y);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_interface showImpactAtPoint:point color:color sparks:sparks points:points];
    });
}
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
        PBLevelSession *session = _session;
        if (!game.autopilot) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_gameCenter finishGameWithScore:score tableIdentifier:self->_table.identifier];
                [self->_menuFlow gameDidFinish];
                atomic_store(&self->_menuPaused, YES);
                [self releaseInputs];
                [self->_interface updateScore:score best:best ball:self->_table.rules.balls
                                   ballCount:self->_table.rules.balls];
                self->_interface.newRecord = record;
                if (self->_catalog && session) {
                    // Read here, once every observer has seen the end of the game.
                    BOOL goalMet = session.goalMet;
                    PBLevelDef *level = session.level;
                    NSInteger stars = [level starsForScore:score goalMet:goalMet];
                    int64_t levelBest = [self->_progress bestScoreForLevel:level];
                    [self->_progress recordStars:stars score:score forLevel:level];
                    [self->_interface updateScore:score best:MAX(score, levelBest) ball:self->_table.rules.balls
                                       ballCount:self->_table.rules.balls];
                    self->_interface.newRecord = score > levelBest;
                    self->_interface.resultStars = stars;
                    self->_interface.resultGoalMet = goalMet;
                    self->_interface.hasNextLevel = self->_levelIndex + 1 < (NSInteger)self->_catalog.levels.count;
                }
                [self configureInterface];
                [self->_interface showScreen:PBMenuResults];
            });
        }
    }
}

@end
