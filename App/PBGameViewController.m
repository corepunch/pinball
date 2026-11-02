//
//  PBGameViewController.m
//

#import "PBGameViewController.h"
#import <CoreMotion/CoreMotion.h>
#import <SceneKit/SceneKit.h>
#import "PBGameController.h"

static const double kNudgeThreshold = 1.9;  // In g. A deliberate shove, not a normal grip shift.
static const float kNudgeImpulse = 0.42f;
// A rolling ball touches its surface almost every frame, at low speed. Only real bounces buzz.
static const float kHapticMinWallImpact = 0.7f;
// iOS quietly stops playing impacts requested faster than the motor can follow.
static const NSTimeInterval kHapticMinInterval = 0.06;

@interface PBGameViewController () <PBGameObserver>
@end

@implementation PBGameViewController {
    PBGameController *_controller;
    NSMutableSet<UITouch *> *_leftTouches, *_rightTouches;
    CMMotionManager *_motion;
    CMAttitude *_lightingReference;
    NSTimeInterval _lastNudge, _lastImpactHaptic;
    UIImpactFeedbackGenerator *_flipperHaptic, *_impactHaptic, *_springHaptic;
}

- (void)loadView {
    SCNView *view = [[SCNView alloc] initWithFrame:CGRectZero options:nil];
    view.multipleTouchEnabled = YES;
    view.backgroundColor = UIColor.blackColor;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _leftTouches = [NSMutableSet set];
    _rightTouches = [NSMutableSet set];
    _controller = [[PBGameController alloc] initWithView:(SCNView *)self.view];
    [_controller addGameObserver:self];

    _flipperHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
    _impactHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    _springHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
    [_flipperHaptic prepare];
    [_impactHaptic prepare];
    [_springHaptic prepare];

    UITapGestureRecognizer *nextSkin = [[UITapGestureRecognizer alloc] initWithTarget:_controller action:@selector(selectNextSkin)];
    nextSkin.numberOfTouchesRequired = 3;
    nextSkin.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:nextSkin];

    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_controller setApplicationActive:UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
    [_controller startGameCenterWithViewController:self];
    [self startMotion];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self clearTouches];
    [_controller setApplicationActive:NO];
    [self stopMotion];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (self.isViewLoaded && self.view.window) {
        [_controller setApplicationActive:YES];
        [self startMotion];
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self clearTouches];
    [_controller setApplicationActive:NO];
    [self stopMotion];
}

- (void)dealloc {
    [_motion stopDeviceMotionUpdates];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [_controller viewDidResize];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

#pragma mark - Touch

- (void)clearTouches {
    [_controller cancelUIPointers];
    [_leftTouches removeAllObjects];
    [_rightTouches removeAllObjects];
    [_controller.game setLeftPressed:NO];
    [_controller.game setRightPressed:NO];
}

- (void)applyTouches {
    if (_controller.isPaused) {
        // Clear gameplay fingers without cancelling a menu button still held down.
        [_leftTouches removeAllObjects]; [_rightTouches removeAllObjects];
        [_controller.game setLeftPressed:NO]; [_controller.game setRightPressed:NO];
        return;
    }
    [_controller.game setLeftPressed:_leftTouches.count > 0];
    [_controller.game setRightPressed:_rightTouches.count > 0];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGFloat middle = CGRectGetMidX(self.view.bounds);
    for (UITouch *touch in touches) {
        if ([_controller pointerBegan:touch atPoint:[touch locationInView:self.view]]) continue;
        if (_controller.isPaused) continue;
        if ([touch locationInView:self.view].x < middle) [_leftTouches addObject:touch];
        else [_rightTouches addObject:touch];
    }
    [self applyTouches];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) [_controller pointerMoved:touch atPoint:[touch locationInView:self.view]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        [_controller pointerEnded:touch atPoint:[touch locationInView:self.view] cancelled:NO];
        [_leftTouches removeObject:touch]; [_rightTouches removeObject:touch];
    }
    [self applyTouches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        [_controller pointerEnded:touch atPoint:[touch locationInView:self.view] cancelled:YES];
        [_leftTouches removeObject:touch]; [_rightTouches removeObject:touch];
    }
    [self applyTouches];
}

#pragma mark - Motion lighting and nudge

- (void)startMotion {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (!_motion) _motion = [CMMotionManager new];
    if (!_motion.deviceMotionAvailable || _motion.deviceMotionActive) return;
    _lightingReference = nil;
    _lastNudge = NSProcessInfo.processInfo.systemUptime;
    _motion.deviceMotionUpdateInterval = 1.0 / 60.0;
    __weak typeof(self) weakSelf = self;
    [_motion startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical
                                               toQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (motion && !error) [weakSelf handleMotion:motion];
    }];
}

- (void)stopMotion {
    [_motion stopDeviceMotionUpdates];
    _lightingReference = nil;
    [_controller setLightingAttitude:simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f)];
}

- (void)handleMotion:(CMDeviceMotion *)motion {
    if (_controller.isPaused || !_motion.deviceMotionActive || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    // Recalibrate to the player's natural grip whenever the view/app becomes active.
    if (!_lightingReference) _lightingReference = [motion.attitude copy];
    CMAttitude *relative = [motion.attitude copy];
    [relative multiplyByInverseOfAttitude:_lightingReference];
    CMQuaternion q = relative.quaternion;
    [_controller setLightingAttitude:simd_quaternion((float)q.x, (float)q.y, (float)q.z, (float)q.w)];

    CMAcceleration a = motion.userAcceleration;
    double magnitude = sqrt(a.x * a.x + a.y * a.y);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (magnitude < kNudgeThreshold || now - _lastNudge < 0.6) return;
    _lastNudge = now;
    [_controller.game requestNudgeX:(float)(a.x / magnitude) * kNudgeImpulse y:(float)(a.y / magnitude) * kNudgeImpulse];
}

#pragma mark - PBGameObserver (haptics)

- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    PBEventKind kind = event->kind;
    CGFloat intensity;
    switch (kind) {
        case PBEventFlipperUp:
            intensity = 1.0;
            break;
        case PBEventWallHit:
            if (event->magnitude < kHapticMinWallImpact) return;
            intensity = 0.2 + 0.3 * MIN(1.0f, event->magnitude / 3.0f);
            break;
        case PBEventBumper:
        case PBEventSling:
        case PBEventDropTarget:
        case PBEventStandup:
        case PBEventSaucerCapture:
        case PBEventSaucerEject:
        case PBEventKickback:
            intensity = 0.65 + 0.35 * MIN(1.0f, event->magnitude / 3.0f);
            break;
        case PBEventPlungerRelease:
            if (event->magnitude <= 0.0f) return;
            // Plunger magnitude is already the applied pull, normalized to 0...1.
            intensity = 0.15 + 0.85 * MIN(1.0f, event->magnitude);
            break;
        case PBEventPlungerCoil:
            // Tightens as it is drawn, and ends on a firm stop at full pull.
            intensity = event->magnitude >= 1.0f ? 1.0 : 0.25 + 0.5 * event->magnitude;
            break;
        case PBEventDrain:
            intensity = 0.65;
            break;
        default:
            return;
    }
    // Copy values before dispatch: the event belongs to the physics queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_controller.hapticsEnabled || self->_controller.isPaused) return;
        if (kind == PBEventFlipperUp) {
            [self->_flipperHaptic impactOccurredWithIntensity:intensity];
            [self->_flipperHaptic prepare];
        } else if (kind == PBEventPlungerCoil) {
            [self->_springHaptic impactOccurredWithIntensity:intensity];
            [self->_springHaptic prepare];
        } else {
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            if (now - self->_lastImpactHaptic < kHapticMinInterval) return;
            self->_lastImpactHaptic = now;
            [self->_impactHaptic impactOccurredWithIntensity:intensity];
            [self->_impactHaptic prepare];
        }
    });
}

- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier {}
- (void)game:(PBGame *)game fanfare:(NSString *)name {}

@end
