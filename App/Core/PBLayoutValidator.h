//
//  PBLayoutValidator.h
//  Checks a table the way the player sees it: every drawn element becomes a footprint,
//  projected through the table camera, so tall parts are tested where they appear on
//  screen. Footprints use the size of the drawn hardware, not the physics radius.
//

#import "PBTableDefinition.h"

NS_ASSUME_NONNULL_BEGIN

/// The camera is orthographic, leaning this many degrees toward the player, as in the concept
/// art: every part shows the same side, and none splays away from the screen's centre.
/// The scene reads this too, so the test sees what the player sees.
/// The camera hangs straight over the middle of what it shows, a perspective lens looking down: the
/// floor maps to the screen unscaled, and anything raised leans away from the centre.
extern const float PBTableCameraFOV;      // Vertical field of view, degrees.
extern const float PBTableCameraBand;     // Board shown past the table's far end, for the readouts.
extern const float PBTablePhoneAspect;    // Height over width of the phone the layout is judged on.
/// What the phone shows: the height of the visible board, from -padding.y up.
float PBTableVisibleHeight(simd_float2 size, simd_float2 padding);
/// Where a point at a height lands on the floor as the phone sees it.
simd_float2 PBTableProject(simd_float2 size, simd_float2 padding, simd_float2 p, float height);

/// Drawn size of round hardware relative to its table value. Art/Models/manifest.json records
/// the real model extents, and a test keeps these in step with them.
extern const float PBBumperFootprintScale;
extern const float PBLampFootprintScale;
extern const float PBPostFootprintScale;

typedef NS_ENUM(NSInteger, PBLayoutIssueKind) {
    PBLayoutIssueOverlap,      // Two drawn elements cover each other.
    PBLayoutIssueNarrowGap,    // Two solids are closer than a ball's width, without touching.
    PBLayoutIssueOutOfBounds,  // Drawn off the table, or on the apron.
};

@interface PBLayoutIssue : NSObject
@property (nonatomic, readonly) PBLayoutIssueKind kind;
@property (nonatomic, copy, readonly) NSString *first;
@property (nonatomic, copy, readonly, nullable) NSString *second;
/// How far apart the pair is from being acceptable, in table widths.
@property (nonatomic, readonly) float amount;
@property (nonatomic, readonly) simd_float2 location;
@end

@interface PBLayoutValidator : NSObject
+ (NSArray<PBLayoutIssue *> *)issuesForTable:(PBTableDefinition *)table;
@end

NS_ASSUME_NONNULL_END
