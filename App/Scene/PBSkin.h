//
//  PBSkin.h
//  A skin contains a hardware atlas, palette, optional slot layout and separate
//  playfield art. Legacy single-atlas skins still use GameData/atlas_layout.json.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface PBSkin : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, strong, readonly) NSBundle *resourceBundle;
@property (nonatomic, copy, readonly, nullable) NSString *modelKit;
@property (nonatomic, readonly) simd_float3 rubberColor;
@property (nonatomic, readonly) simd_float3 metalColor;
@property (nonatomic, readonly) simd_float3 keyColor;
@property (nonatomic, readonly) simd_float3 dmdColor;
@property (nonatomic, readonly) float keyIntensity;
@property (nonatomic, readonly) float ambient;
@property (nonatomic, readonly) float plasticOpacity;
@property (nonatomic, readonly) simd_float3 accentColor;
@property (nonatomic, readonly) simd_float3 flipperRubberColor;
@property (nonatomic, readonly) simd_float3 slingLensColor;
@property (nonatomic, readonly) simd_float3 capBaseColor, capStarColor;
@property (nonatomic, readonly) float hardwareMetalness;
@property (nonatomic, readonly) float hardwareRoughness;
@property (nonatomic, readonly) float playfieldReflectivity;
@property (nonatomic, readonly) float bloomIntensity;
@property (nonatomic, readonly) float rampOpacity;
@property (nonatomic, readonly) simd_float3 rampGlassColor;
/// Names in GameData/Materials: the MatCap for hardware, and for ramp floors.
@property (nonatomic, copy, readonly) NSString *hardwareMatcap, *rampMatcap;
/// How soft the ramp's reflections are, as a mip bias, and how strong its highlights, 0 to 1.
@property (nonatomic, readonly) float rampBlur, rampGloss;

+ (nullable instancetype)skinNamed:(NSString *)identifier bundle:(NSBundle *)bundle;
+ (NSArray<NSString *> *)availableSkinsInBundle:(NSBundle *)bundle;

/// A slot cropped from the atlas with its bleed margin removed. Cached; owned by the skin.
- (CGImageRef)imageForSlot:(NSString *)slot CF_RETURNS_NOT_RETAINED;
- (BOOL)hasImageForSlot:(NSString *)slot;
/// One cell of the 4x4 lamp icon sheet.
- (CGImageRef)insertIcon:(NSInteger)index CF_RETURNS_NOT_RETAINED;
- (simd_float3)lampColor:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
