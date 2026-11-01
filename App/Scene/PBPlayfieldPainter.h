//
//  PBPlayfieldPainter.h
//  Composites the final playfield texture at load: painted art from the skin, then
//  everything that must line up exactly with the physics, drawn crisply from the table
//  data (lamp lenses, saucers, rollover wires, contact shadows). The art therefore
//  never needs to be pixel-accurate, which matters when an image model paints it.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import "PBSkin.h"
#import "PBTableDefinition.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBPlayfieldPainter : NSObject

/// The composited playfield. Caller releases.
+ (CGImageRef)newPlayfieldForTable:(PBTableDefinition *)table skin:(PBSkin *)skin CF_RETURNS_RETAINED;

/// A square additive sprite for a lit lamp: soft halo around the tinted icon. Caller releases.
+ (CGImageRef)newLitLampWithIcon:(CGImageRef)icon color:(simd_float3)color CF_RETURNS_RETAINED;

/// The same for a triangular insert pointing along +x: the scene rotates the sprite. Caller releases.
+ (CGImageRef)newLitArrowWithColor:(simd_float3)color CF_RETURNS_RETAINED;

/// A moulded coloured lens, hot at the centre and deep at the edge. Caller releases.
+ (CGImageRef)newLensWithColor:(simd_float3)color CF_RETURNS_RETAINED;

/// A pop bumper's cap: a many-pointed star on enamel, filling the image. Caller releases.
+ (CGImageRef)newBumperCapWithBase:(simd_float3)base star:(simd_float3)star CF_RETURNS_RETAINED;

/// A glass dome with a lamp in it, highlight up and to the left. Caller releases.
+ (CGImageRef)newJewelWithColor:(simd_float3)color CF_RETURNS_RETAINED;

/// Round soft glow, for flashers and bumper flashes. Caller releases.
+ (CGImageRef)newGlowWithColor:(simd_float3)color CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
