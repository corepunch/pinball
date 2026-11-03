//
//  PBLayoutValidator.h
//  Checks a table the way the player sees it: every drawn element becomes a footprint,
//  projected through the table camera, so tall parts are tested where they appear on
//  screen. Footprints use the size of the drawn hardware, not the physics radius.
//

#import "PBTableDefinition.h"
#import "PBTablePresentation.h"

NS_ASSUME_NONNULL_BEGIN

/// Reference phone used for authoring. Runtime framing also respects each device's safe area.
extern const float PBTablePhoneAspect;    // Height over width of the phone the layout is judged on.
/// Visible span expressed in floor/table units for the authoring report.
float PBTableVisibleHeight(simd_float2 size, simd_float2 padding);
/// Floor-equivalent position seen by the tilted orthographic camera; no perspective growth.
simd_float2 PBTableProject(simd_float2 size, simd_float2 padding, simd_float2 p, float height);

/// Drawn size of round hardware relative to its table value, for footprint and spacing checks.
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
