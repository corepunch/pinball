//
//  PBTableDefinition.h
//  An immutable, typed model of a table, parsed from GameData/Tables/<id>.json.
//  Everything table-specific lives in that file, so adding a table adds no code
//  and almost no app size. Coordinates: table widths, origin bottom-left, +y up the table.
//

#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, PBLayerMask) {
    PBLayerPlayfield = 1 << 0,
    PBLayerRamp      = 1 << 1,
    PBLayerCaptive   = 1 << 2,
    PBLayerDeck      = 1 << 3,  // The raised second level.
};

typedef NS_ENUM(NSInteger, PBWallStyle) {
    PBWallStyleNone,     // Collides but is not drawn.
    PBWallStyleWall,
    PBWallStyleRail,
    PBWallStyleRubber,
    PBWallStylePlastic,
};

/// Boxed simd points, since Foundation collections cannot hold simd values.
@interface PBPointList : NSObject
@property (nonatomic, readonly) NSInteger count;
@property (nonatomic, readonly) const simd_float2 *points;
- (instancetype)initWithCount:(NSInteger)count;
- (simd_float2 *)mutablePoints;
@end

@interface PBElementDef : NSObject
@property (nonatomic, copy) NSString *identifier;
@end

@interface PBWallDef : PBElementDef
@property (nonatomic) PBWallStyle style;
@property (nonatomic) float height;
@property (nonatomic) float radius;
@property (nonatomic) BOOL closed;
@property (nonatomic) PBLayerMask layers;
/// The raised block of the second level.
@property (nonatomic) BOOL isDeck;
@property (nonatomic, strong) PBPointList *points;
@end

/// A point element: posts, bumpers, rollovers, saucers, kickbacks, magnets, captive balls, flashers.
@interface PBSpotDef : PBElementDef
@property (nonatomic) simd_float2 position;
/// A rollover shows a grey plate. Set by the Pinball Rollover Bar modifier in the level file.
@property (nonatomic) BOOL hasPlate;
@property (nonatomic) float radius;
@property (nonatomic) simd_float2 direction;
@property (nonatomic) float speed;
@property (nonatomic) float captureSpeed;
@property (nonatomic) float holdSeconds;
@property (nonatomic, copy, nullable) NSString *color;
/// A post drawn as this kit part, rather than the plain post.
@property (nonatomic, copy, nullable) NSString *model;
/// Which level a saucer sits on.
@property (nonatomic) PBLayerMask layers;
/// A saucer with an exit is a drop hole: the ball goes underground, and comes up here.
@property (nonatomic) BOOL hasExit;
@property (nonatomic) simd_float2 exit;
@property (nonatomic) float transitSeconds;
@end

/// A line element: slingshots, drop targets, stand-ups, spinners, gates.
@interface PBEdgeDef : PBElementDef
/// A vari-target, for a standup: the harder it is hit, the more it scores.
@property (nonatomic) BOOL vari;
@property (nonatomic) simd_float2 a;
@property (nonatomic) simd_float2 b;
@property (nonatomic) simd_float2 passDirection;
@property (nonatomic) PBLayerMask layers;
@end

@interface PBFlipperDef : PBElementDef
@property (nonatomic) BOOL isLeft;
@property (nonatomic) simd_float2 pivot;
@property (nonatomic) float length;
@property (nonatomic) float baseRadius;
@property (nonatomic) float tipRadius;
@property (nonatomic) float restAngle;    // Radians.
@property (nonatomic) float activeAngle;  // Radians.
@property (nonatomic) PBLayerMask layers;
@end

@interface PBRampDef : PBElementDef
/// The shared model drawn for it, as tables reuse the same ramps.
@property (nonatomic, copy, nullable) NSString *model;
@property (nonatomic) float width;
/// The level a ball finishing the ramp lands on.
@property (nonatomic) PBLayerMask exitLayer;
@property (nonatomic) float wallHeight;
@property (nonatomic) float railWidth;
@property (nonatomic) float entranceFlare;
@property (nonatomic) float exitFlare;
@property (nonatomic) float transitionLength;
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *supportColumns;
@property (nonatomic) float supportRadius;
@property (nonatomic) float supportBase;
@property (nonatomic) simd_float2 mouthA;
@property (nonatomic) simd_float2 mouthB;
@property (nonatomic) NSInteger plasticUntil;
@property (nonatomic, strong) NSData *pointData;  // Packed simd_float3 (x, y, height).
@property (nonatomic, readonly) NSInteger pointCount;
- (simd_float3)pointAtIndex:(NSInteger)index;
@end

@interface PBLampDef : PBElementDef
@property (nonatomic) simd_float2 position;
@property (nonatomic) float size;
@property (nonatomic, copy) NSString *color;
@property (nonatomic) NSInteger icon;
@property (nonatomic, copy, nullable) NSString *bind;
@property (nonatomic) BOOL isArrow;      // A triangular insert pointing along angle, not a round one.
@property (nonatomic) float angle;       // Radians, counter-clockwise from +x.
@end

@interface PBPlasticDef : PBElementDef
@property (nonatomic) float height;
@property (nonatomic, strong) PBPointList *points;
@end

/// Static dressing: a named model from the skin's kit, with no effect on play.
@interface PBDecorDef : PBElementDef
@property (nonatomic, copy) NSString *model;
@property (nonatomic) simd_float2 position;
@property (nonatomic) float size;     // Half length, in table widths. Models are built to unit half length.
@property (nonatomic) float angle;    // Radians, counter-clockwise from +x.
@property (nonatomic) float base;     // Height of the surface it is mounted on.
@property (nonatomic) float height;   // Its own height above that surface.
@property (nonatomic) float radius;   // Footprint: a capsule of this radius...
@property (nonatomic) float extent;   // ...reaching this far either side of position, along angle.
@end

@interface PBPlungerDef : NSObject
@property (nonatomic) simd_float2 position;
@property (nonatomic) float width;
@property (nonatomic) float travel;
@end

@interface PBRuleGroupDef : PBElementDef
@property (nonatomic, copy) NSArray<NSString *> *members;
@property (nonatomic, copy) NSArray<NSString *> *lamps;
@property (nonatomic) BOOL rotateWithFlippers;
@property (nonatomic) NSInteger completeScore;
@property (nonatomic, copy) NSArray<NSString *> *actions;
@property (nonatomic, copy) NSString *message;
@end

@interface PBRulesDef : NSObject
@property (nonatomic) NSInteger balls;
@property (nonatomic) double ballSaveSeconds;
@property (nonatomic) NSInteger locksForMultiball;
@property (nonatomic) NSInteger multiballBalls;
@property (nonatomic) double skillShotSeconds;
@property (nonatomic) NSInteger tiltWarnings;
@property (nonatomic) NSInteger rampsForExtraBall;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *scores;
@property (nonatomic, copy) NSArray<PBRuleGroupDef *> *groups;
@property (nonatomic, copy) NSString *skillShotTarget;
/// Finishing every group in one game starts wizard mode.
@property (nonatomic) BOOL wizard;
- (NSInteger)scoreFor:(NSString *)key;
@end

@interface PBTableDefinition : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *defaultSkin;
@property (nonatomic, readonly) simd_float2 size;

@property (nonatomic, readonly) float gravity;
@property (nonatomic, readonly) float rampGravity;
@property (nonatomic, readonly) float ballRadius;
@property (nonatomic, readonly) float drainY;
@property (nonatomic, readonly) float plungerSpeed;

/// Nothing but the drain lies below this line.
@property (nonatomic, readonly) float apronY;
/// How far the second level stands above the board. Zero when a table has none.
@property (nonatomic, readonly) float deckHeight;

@property (nonatomic, strong, readonly) PBPlungerDef *plunger;
@property (nonatomic, copy, readonly) NSArray<PBWallDef *> *walls;
@property (nonatomic, copy, readonly) NSArray<PBSpotDef *> *posts;
@property (nonatomic, copy, readonly) NSArray<PBFlipperDef *> *flippers;
@property (nonatomic, copy, readonly) NSArray<PBSpotDef *> *bumpers;
@property (nonatomic, copy, readonly) NSArray<PBEdgeDef *> *slingshots;
@property (nonatomic, copy, readonly) NSArray<PBEdgeDef *> *dropTargets;
@property (nonatomic, copy, readonly) NSArray<PBEdgeDef *> *standups;
@property (nonatomic, copy, readonly) NSArray<PBSpotDef *> *rollovers;
@property (nonatomic, copy, readonly) NSArray<PBEdgeDef *> *spinners;
@property (nonatomic, copy, readonly) NSArray<PBSpotDef *> *saucers;
@property (nonatomic, copy, readonly) NSArray<PBEdgeDef *> *gates;
@property (nonatomic, copy, readonly) NSArray<PBSpotDef *> *kickbacks;
/// Centre posts: down until earned, then up for a while between the flippers.
@property (nonatomic, copy, readonly) NSArray<PBSpotDef *> *stoppers;
@property (nonatomic, copy, readonly) NSArray<PBSpotDef *> *magnets;
@property (nonatomic, copy, readonly) NSArray<PBSpotDef *> *captiveBalls;
@property (nonatomic, copy, readonly) NSArray<PBRampDef *> *ramps;
@property (nonatomic, copy, readonly) NSArray<PBLampDef *> *lamps;
@property (nonatomic, copy, readonly) NSArray<PBSpotDef *> *flashers;
@property (nonatomic, copy, readonly) NSArray<PBPlasticDef *> *plastics;
@property (nonatomic, copy, readonly) NSArray<PBDecorDef *> *decor;
@property (nonatomic, strong, readonly) PBRulesDef *rules;

- (nullable instancetype)initWithJSONData:(NSData *)data error:(NSError **)error;
+ (nullable instancetype)tableNamed:(NSString *)identifier bundle:(NSBundle *)bundle error:(NSError **)error;
/// Table identifiers found in GameData/Tables, sorted. Dropping in a JSON file is enough to list it.
+ (NSArray<NSString *> *)availableTablesInBundle:(NSBundle *)bundle;
@end

NS_ASSUME_NONNULL_END
