#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN
@class PBPointList;

/// Shipping sprite projection is overhead (zero). Retained 3D tools share this framing.
extern const float PBTableCameraTilt;

/// Screen-space rectangles have a top-left origin, in view points.
typedef struct {
    CGRect header;        // Floating text/control bounds; reserves no world space.
    CGRect pause;
    CGRect board;
    CGFloat scale;
} PBGameViewLayout;

typedef struct {
    float visibleHeight;  // Full vertical span in projected world units, not half-span.
    float centerY;        // Table-space y of the camera's look-at point on the floor.
} PBTableCameraFrame;

PBGameViewLayout PBGameViewLayoutMake(CGSize view, CGFloat topInset, CGFloat bottomInset);
PBTableCameraFrame PBTableCameraFrameMake(simd_float2 tableSize, CGSize view,
                                         CGFloat topInset, CGFloat bottomInset);
/// Flat projection into view points. Height does not change sprite position or scale.
CGPoint PBTableScreenPoint(simd_float2 tableSize, CGSize view, CGFloat topInset,
                           CGFloat bottomInset, simd_float2 point, float height);
simd_float2 PBTablePointFromScreen(simd_float2 tableSize, CGSize view, CGFloat topInset,
                                  CGFloat bottomInset, CGPoint point, float height);
/// Public UIKit APIs don't expose display corner radii. Approximate from safe area.
CGFloat PBDisplayCornerRadius(CGSize view, CGFloat topInset, CGFloat bottomInset);
/// Open contour, from lower right around the top to lower left. Drain stays open.
/// Points describe the collider centreline, offset by wall thickness so contact reaches the display edge.
PBPointList *PBTableDisplayBoundary(simd_float2 tableSize, CGSize view,
                                          CGFloat topInset, CGFloat bottomInset,
                                          float ballRadius, float wallRadius);

NS_ASSUME_NONNULL_END
