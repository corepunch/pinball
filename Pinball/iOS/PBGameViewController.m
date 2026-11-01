//
//  PBGameViewController.m
//

#import "PBGameViewController.h"
#import <CoreMotion/CoreMotion.h>
#import <SceneKit/SceneKit.h>
#import "PBGameController.h"

static const double kNudgeThreshold = 1.9;  // In g. A deliberate shove, not a normal grip shift.
static const float kNudgeImpulse = 0.42f;

@interface PBGameViewController () <PBGameObserver>
@end

@implementation PBGameViewController {
    PBGameController *_controller;
    NSMutableSet<UITouch *> *_leftTouches, *_rightTouches;
    CMMotionManager *_motion;
    NSTimeInterval _lastNudge;
    UIImpactFeedbackGenerator *_flipperHaptic, *_impactHaptic;
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
    [_controller.game addObserver:self];

    _flipperHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
    _impactHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [_flipperHaptic prepare];

    UITapGestureRecognizer *nextSkin = [[UITapGestureRecognizer alloc] initWithTarget:_controller action:@selector(selectNextSkin)];
    nextSkin.numberOfTouchesRequired = 3;
    nextSkin.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:nextSkin];

    [self startMotionNudges];
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

- (void)applyTouches {
    [_controller.game setLeftPressed:_leftTouches.count > 0];
    [_controller.game setRightPressed:_rightTouches.count > 0];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGFloat middle = CGRectGetMidX(self.view.bounds);
    for (UITouch *touch in touches) {
        if ([touch locationInView:self.view].x < middle) [_leftTouches addObject:touch];
        else [_rightTouches addObject:touch];
    }
    [self applyTouches];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) { [_leftTouches removeObject:touch]; [_rightTouches removeObject:touch]; }
    [self applyTouches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

#pragma mark - Nudge

- (void)startMotionNudges {
    _motion = [CMMotionManager new];
    if (!_motion.deviceMotionAvailable) return;
    _motion.deviceMotionUpdateInterval = 1.0 / 60.0;
    __weak typeof(self) weakSelf = self;
    [_motion startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *motion, NSError *error) {
        [weakSelf handleMotion:motion];
    }];
}

- (void)handleMotion:(CMDeviceMotion *)motion {
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
    if (kind != PBEventFlipperUp && kind != PBEventBumper && kind != PBEventSling && kind != PBEventDrain) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (kind == PBEventFlipperUp) {
            [self->_flipperHaptic impactOccurred];
            [self->_flipperHaptic prepare];
        } else {
            [self->_impactHaptic impactOccurred];
        }
    });
}

- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier {}
- (void)game:(PBGame *)game fanfare:(NSString *)name {}

@end
