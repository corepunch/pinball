//
//  PBGeometry.h
//  Procedural meshes. Every part is generated from table data at load, so a new
//  table ships no model files; this is what keeps many tables small.
//
//  Table space maps to SceneKit as: x -> +X, height -> +Y, table y -> -Z.
//  Camera looks down -Y. All builders here take table-space input.
//

#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Table (x, y, height) to scene position, for a table of the given size.
static inline SCNVector3 PBScenePoint(simd_float2 size, float x, float y, float height) {
    return SCNVector3Make(x - size.x * 0.5f, height, -(y - size.y * 0.5f));
}

@interface PBGeometry : NSObject

/// Surface of revolution around +Y. Profile points are (radius, height), bottom to top.
/// UVs project from above, so a texture appears as a top-down picture on it.
+ (SCNGeometry *)latheWithProfile:(const simd_float2 *)profile count:(NSInteger)count segments:(NSInteger)segments;

/// Tube along a 3D polyline in scene space: wire rails, rubber bands.
+ (SCNGeometry *)tubeAlongPoints:(const SCNVector3 *)points count:(NSInteger)count radius:(float)radius sides:(NSInteger)sides;

/// Upright wall following a table-space polyline, with bevelled top. U runs along the wall.
+ (SCNGeometry *)wallAlongPoints:(const simd_float2 *)points count:(NSInteger)count closed:(BOOL)closed
                       halfWidth:(float)halfWidth height:(float)height tableSize:(simd_float2)size;

/// Ramp floor plus low sides from a table-space path. Each point carries its own height.
+ (SCNGeometry *)rampFromPoints:(const simd_float3 *)points count:(NSInteger)count width:(float)width
                      sideHeight:(float)sideHeight tableSize:(simd_float2)size;

/// Solid prism from a polygon (table space, in a node whose origin is the table origin).
/// Handles concave outlines and holes through SCNShape.
+ (SCNGeometry *)prismWithPath:(CGPathRef)path height:(float)height chamfer:(float)chamfer evenOdd:(BOOL)evenOdd;

+ (SCNGeometry *)prismWithPoints:(const simd_float2 *)points count:(NSInteger)count
                         height:(float)height chamfer:(float)chamfer;

/// Flipper bat pointing along +X from its pivot: a tapered capsule.
+ (SCNGeometry *)flipperWithLength:(float)length baseRadius:(float)baseRadius tipRadius:(float)tipRadius height:(float)height;

@end

NS_ASSUME_NONNULL_END
