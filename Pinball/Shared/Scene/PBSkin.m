//
//  PBSkin.m
//

#import "PBSkin.h"
#import <ImageIO/ImageIO.h>

static simd_float3 PBColor(NSArray *rgb, simd_float3 fallback) {
    if (rgb.count < 3) return fallback;
    return simd_make_float3([rgb[0] floatValue], [rgb[1] floatValue], [rgb[2] floatValue]);
}

@implementation PBSkin {
    CGImageRef _atlas;
    NSDictionary *_slots;
    NSDictionary *_palette;
    CGSize _canvas;
    float _bleed;
    NSMutableDictionary<NSString *, id> *_cache;
}

+ (nullable instancetype)skinNamed:(NSString *)identifier bundle:(NSBundle *)bundle {
    NSURL *image = [bundle URLForResource:identifier withExtension:@"jpg" subdirectory:@"GameData/Skins"];
    NSURL *palette = [bundle URLForResource:identifier withExtension:@"json" subdirectory:@"GameData/Skins"];
    NSURL *layout = [bundle URLForResource:@"atlas_layout" withExtension:@"json" subdirectory:@"GameData"];
    if (!image || !palette || !layout) return nil;
    return [[self alloc] initWithIdentifier:identifier image:image palette:palette layout:layout];
}

+ (NSArray<NSString *> *)availableSkinsInBundle:(NSBundle *)bundle {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in [bundle URLsForResourcesWithExtension:@"jpg" subdirectory:@"GameData/Skins"]) {
        [names addObject:url.URLByDeletingPathExtension.lastPathComponent];
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

- (nullable instancetype)initWithIdentifier:(NSString *)identifier image:(NSURL *)imageURL palette:(NSURL *)paletteURL layout:(NSURL *)layoutURL {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)imageURL, NULL);
        if (!source) return nil;
        _atlas = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!_atlas) return nil;

        NSDictionary *layout = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:layoutURL] options:0 error:NULL];
        _slots = layout[@"slots"];
        NSArray *canvas = layout[@"canvas"];
        _canvas = CGSizeMake([canvas[0] doubleValue], [canvas[1] doubleValue]);
        _bleed = [layout[@"bleed"] floatValue];

        _palette = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:paletteURL] options:0 error:NULL];
        _rubberColor = PBColor(_palette[@"rubber"], simd_make_float3(0.95f, 0.95f, 0.95f));
        _metalColor = PBColor(_palette[@"metal"], simd_make_float3(0.8f, 0.8f, 0.85f));
        _keyColor = PBColor(_palette[@"key"], simd_make_float3(1.0f, 0.95f, 0.9f));
        _dmdColor = PBColor(_palette[@"dmd"], simd_make_float3(1.0f, 0.4f, 0.1f));
        _keyIntensity = [_palette[@"keyIntensity"] floatValue] ?: 900.0f;
        _ambient = [_palette[@"ambient"] floatValue] ?: 1.0f;
        _plasticOpacity = [_palette[@"plasticOpacity"] floatValue] ?: 0.8f;
        _cache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc { CGImageRelease(_atlas); }

/// Atlas may arrive at any resolution; slot rects are authored in canvas units.
- (CGRect)pixelRectForCanvasRect:(CGRect)rect {
    CGFloat sx = (CGFloat)CGImageGetWidth(_atlas) / _canvas.width;
    CGFloat sy = (CGFloat)CGImageGetHeight(_atlas) / _canvas.height;
    return CGRectIntegral(CGRectMake(rect.origin.x * sx, rect.origin.y * sy, rect.size.width * sx, rect.size.height * sy));
}

- (CGImageRef)imageForSlot:(NSString *)slot {
    id cached = _cache[slot];
    if (cached) return (__bridge CGImageRef)cached;
    NSArray *r = _slots[slot][@"rect"];
    CGRect rect = CGRectMake([r[0] doubleValue], [r[1] doubleValue], [r[2] doubleValue], [r[3] doubleValue]);
    // The playfield is edge to edge. Parts are inset, so a model's slightly drifting
    // layout doesn't sample the neighbouring slot.
    if (![slot isEqualToString:@"playfield"]) rect = CGRectInset(rect, _bleed, _bleed);
    CGImageRef image = CGImageCreateWithImageInRect(_atlas, [self pixelRectForCanvasRect:rect]);
    _cache[slot] = (__bridge_transfer id)image;
    return image;
}

- (CGImageRef)insertIcon:(NSInteger)index {
    NSString *key = [NSString stringWithFormat:@"icon%ld", (long)index];
    id cached = _cache[key];
    if (cached) return (__bridge CGImageRef)cached;
    NSArray *r = _slots[@"inserts"][@"rect"];
    CGFloat cell = [r[2] doubleValue] / 4.0;
    CGRect rect = CGRectMake([r[0] doubleValue] + (index % 4) * cell, [r[1] doubleValue] + (index / 4) * cell, cell, cell);
    CGImageRef image = CGImageCreateWithImageInRect(_atlas, [self pixelRectForCanvasRect:rect]);
    _cache[key] = (__bridge_transfer id)image;
    return image;
}

- (simd_float3)lampColor:(NSString *)name {
    return PBColor(_palette[@"lamps"][name], simd_make_float3(1.0f, 1.0f, 1.0f));
}

@end
