//
//  PBSkin.h
//  One skin is two files: GameData/Skins/<id>.jpg (the painted atlas) and <id>.json
//  (palette). This class slices the atlas by GameData/atlas_layout.json, the same
//  layout file the Python tool draws its guides from.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface PBSkin : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, readonly) simd_float3 rubberColor;
@property (nonatomic, readonly) simd_float3 metalColor;
@property (nonatomic, readonly) simd_float3 keyColor;
@property (nonatomic, readonly) simd_float3 dmdColor;
@property (nonatomic, readonly) float keyIntensity;
@property (nonatomic, readonly) float ambient;
@property (nonatomic, readonly) float plasticOpacity;

+ (nullable instancetype)skinNamed:(NSString *)identifier bundle:(NSBundle *)bundle;
+ (NSArray<NSString *> *)availableSkinsInBundle:(NSBundle *)bundle;

/// A slot cropped from the atlas with its bleed margin removed. Cached; owned by the skin.
- (CGImageRef)imageForSlot:(NSString *)slot CF_RETURNS_NOT_RETAINED;
/// One cell of the 4x4 lamp icon sheet.
- (CGImageRef)insertIcon:(NSInteger)index CF_RETURNS_NOT_RETAINED;
- (simd_float3)lampColor:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
