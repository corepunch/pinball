//
//  PBLayoutValidator.h
//  Checks a table the way the player sees it: every drawn element becomes a footprint,
//  projected through the overhead camera, so tall parts are tested where they appear on
//  screen. Footprints use the size of the drawn hardware, not the physics radius.
//

#import "PBTableDefinition.h"

NS_ASSUME_NONNULL_BEGIN

/// The overhead camera. The scene reads this too, so the test sees what the player sees.
extern const float PBTableCameraFieldOfView;

/// Drawn size of round hardware relative to its table value. Blender's manifest records
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
