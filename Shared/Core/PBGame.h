//
//  PBGame.h
//  Top of the simulation: world + rules + input. No SceneKit, UIKit or AppKit here,
//  so the whole game runs headless in the unit tests.
//
//  Threading: -update: runs on SceneKit's render thread (the Fox sample's pattern
//  of game logic in renderer:updateAtTime:). Input setters may be called from any
//  thread; they only write atomics that -update: reads.
//

#import <Foundation/Foundation.h>
#import "PBPhysicsWorld.h"
#import "PBRuleEngine.h"

NS_ASSUME_NONNULL_BEGIN

@class PBGame;

@protocol PBGameObserver <NSObject>
- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event;
- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier;
- (void)game:(PBGame *)game fanfare:(NSString *)name;
@end

@interface PBGame : NSObject

@property (nonatomic, strong, readonly) PBTableDefinition *table;
@property (nonatomic, strong, readonly) PBPhysicsWorld *world;
@property (nonatomic, strong, readonly) PBRuleEngine *rules;
/// Plays by itself, for tests and for screenshots.
@property (nonatomic) BOOL autopilot;
@property (nonatomic, readonly) simd_float2 lastNudge;

- (instancetype)initWithTable:(PBTableDefinition *)table highScore:(int64_t)highScore;
- (void)addObserver:(id<PBGameObserver>)observer;
- (void)update:(double)elapsed;

#pragma mark Input, any thread
- (void)setLeftPressed:(BOOL)pressed;
- (void)setRightPressed:(BOOL)pressed;
- (void)setPlungerPressed:(BOOL)pressed;
- (void)requestNudgeX:(float)x y:(float)y;

@end

NS_ASSUME_NONNULL_END
