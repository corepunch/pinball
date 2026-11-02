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
    NSMutableDictionary<NSString *, id> *_sources;
    NSBundle *_bundle;
}

+ (nullable instancetype)skinNamed:(NSString *)identifier bundle:(NSBundle *)bundle {
    NSURL *image = [bundle URLForResource:identifier withExtension:@"jpg" subdirectory:@"GameData/Skins"];
    NSURL *palette = [bundle URLForResource:identifier withExtension:@"json" subdirectory:@"GameData/Skins"];
    NSURL *layout = [bundle URLForResource:@"atlas_layout" withExtension:@"json" subdirectory:@"GameData"];
    if (!image || !palette || !layout) return nil;
    return [[self alloc] initWithIdentifier:identifier image:image palette:palette layout:layout bundle:bundle];
}

+ (NSArray<NSString *> *)availableSkinsInBundle:(NSBundle *)bundle {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    // Discover palettes, not JPEGs: separate playfield sources are not selectable skins.
    for (NSURL *url in [bundle URLsForResourcesWithExtension:@"json" subdirectory:@"GameData/Skins"]) {
        NSString *name = url.URLByDeletingPathExtension.lastPathComponent;
        if ([bundle URLForResource:name withExtension:@"jpg" subdirectory:@"GameData/Skins"]) [names addObject:name];
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

- (nullable instancetype)initWithIdentifier:(NSString *)identifier image:(NSURL *)imageURL palette:(NSURL *)paletteURL layout:(NSURL *)layoutURL bundle:(NSBundle *)bundle {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _bundle = bundle;
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)imageURL, NULL);
        if (!source) return nil;
        _atlas = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!_atlas) return nil;

        NSDictionary *layout = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:layoutURL] options:0 error:NULL];
        _palette = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:paletteURL] options:0 error:NULL];
        if (!_palette || !layout) return nil;
        layout = _palette[@"atlasLayout"] ?: layout;
        _slots = layout[@"slots"];
        NSArray *canvas = layout[@"canvas"];
        if (canvas.count != 2 || [canvas[0] doubleValue] <= 0 || [canvas[1] doubleValue] <= 0 || !_slots.count) return nil;
        _canvas = CGSizeMake([canvas[0] doubleValue], [canvas[1] doubleValue]);
        _bleed = [layout[@"bleed"] floatValue];

        _rubberColor = PBColor(_palette[@"rubber"], simd_make_float3(0.95f, 0.95f, 0.95f));
        _metalColor = PBColor(_palette[@"metal"], simd_make_float3(0.8f, 0.8f, 0.85f));
        _keyColor = PBColor(_palette[@"key"], simd_make_float3(1.0f, 0.95f, 0.9f));
        _dmdColor = PBColor(_palette[@"dmd"], simd_make_float3(1.0f, 0.4f, 0.1f));
        _keyIntensity = [_palette[@"keyIntensity"] floatValue] ?: 900.0f;
        _ambient = [_palette[@"ambient"] floatValue] ?: 1.0f;
        _plasticOpacity = [_palette[@"plasticOpacity"] floatValue] ?: 0.8f;
        _accentColor = PBColor(_palette[@"accent"], _metalColor);
        _flipperRubberColor = PBColor(_palette[@"flipperRubber"], simd_make_float3(0.75f, 0.05f, 0.08f));
        _slingLensColor = PBColor(_palette[@"slingLens"], [self lampColor:@"red"]);
        _capBaseColor = PBColor(_palette[@"capBase"], simd_make_float3(0.92f, 0.86f, 0.72f));
        _capStarColor = PBColor(_palette[@"capStar"], simd_make_float3(0.7f, 0.08f, 0.05f));
        _shellColor = PBColor(_palette[@"shell"], simd_make_float3(.62f, .07f, .05f));
        _coverColor = PBColor(_palette[@"cover"], simd_make_float3(.30f, .07f, .11f));
        NSDictionary *materials = _palette[@"materials"];
        _hardwareMetalness = materials[@"metalness"] ? [materials[@"metalness"] floatValue] : 1.0f;
        _hardwareRoughness = materials[@"roughness"] ? [materials[@"roughness"] floatValue] : 0.22f;
        _playfieldReflectivity = materials[@"playfieldReflectivity"] ? [materials[@"playfieldReflectivity"] floatValue] : 0.28f;
        _bloomIntensity = materials[@"bloom"] ? [materials[@"bloom"] floatValue] : 0.9f;
        _rampOpacity = materials[@"rampOpacity"] ? [materials[@"rampOpacity"] floatValue] : 0.55f;
        _rampGlassColor = PBColor(materials[@"rampGlass"], _accentColor);
        _hardwareMatcap = [materials[@"matcap"] copy] ?: @"courtyard";
        _rampMatcap = [materials[@"rampMatcap"] copy] ?: @"studio";
        _rampBlur = materials[@"rampBlur"] ? [materials[@"rampBlur"] floatValue] : 2.5f;
        _rampGloss = materials[@"rampGloss"] ? [materials[@"rampGloss"] floatValue] : 0.1f;
        _modelKit = [_palette[@"modelKit"] copy];
        _cache = [NSMutableDictionary dictionary];
        _sources = [NSMutableDictionary dictionary];
        // Reject malformed layouts at load time, rather than crashing in scene generation.
        NSArray *required = @[@"playfield", @"bumper_cap", @"slingshot", @"wall_top", @"side_rail", @"flipper", @"ramp",
                              @"plastic", @"drop_target", @"standup", @"spinner", @"gate", @"environment", @"inserts", @"dmd_bezel", @"detail"];
        for (NSString *slot in required) if (!_slots[slot]) return nil;
        for (NSString *slot in _slots) {
            if (![self imageForSlot:slot]) return nil;
        }
    }
    return self;
}

- (void)dealloc { CGImageRelease(_atlas); }

- (NSBundle *)resourceBundle { return _bundle; }

- (BOOL)hasImageForSlot:(NSString *)slot { return _slots[slot] != nil; }

- (CGImageRef)sourceForSlot:(NSDictionary *)slot {
    NSString *filename = slot[@"file"];
    if (!filename) return _atlas;
    id cached = _sources[filename];
    if (cached) return (__bridge CGImageRef)cached;
    NSURL *url = [_bundle URLForResource:filename.stringByDeletingPathExtension
                         withExtension:filename.pathExtension subdirectory:@"GameData/Skins"];
    if (!url) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (image) _sources[filename] = (__bridge_transfer id)image;
    return image;
}

/// Slot coordinates are in its declared canvas, independent of source resolution.
- (CGImageRef)cropSlot:(NSDictionary *)slot rect:(CGRect)rect {
    CGImageRef source = [self sourceForSlot:slot];
    if (!source) return NULL;
    NSArray *canvas = slot[@"canvas"];
    CGSize size = canvas.count == 2 ? CGSizeMake([canvas[0] doubleValue], [canvas[1] doubleValue]) : _canvas;
    if (size.width <= 0 || size.height <= 0 || CGRectIsEmpty(rect) ||
        !CGRectContainsRect(CGRectMake(0, 0, size.width, size.height), rect)) return NULL;
    CGFloat sx = CGImageGetWidth(source) / size.width, sy = CGImageGetHeight(source) / size.height;
    return CGImageCreateWithImageInRect(source, CGRectIntegral(CGRectMake(rect.origin.x * sx, rect.origin.y * sy,
                                                                       rect.size.width * sx, rect.size.height * sy)));
}

- (CGImageRef)imageForSlot:(NSString *)name {
    id cached = _cache[name];
    if (cached) return (__bridge CGImageRef)cached;
    NSDictionary *slot = _slots[name];
    NSArray *r = slot[@"rect"];
    if (r.count != 4) return NULL;
    CGRect rect = CGRectMake([r[0] doubleValue], [r[1] doubleValue], [r[2] doubleValue], [r[3] doubleValue]);
    CGFloat bleed = slot[@"bleed"] ? [slot[@"bleed"] doubleValue] : ([name isEqualToString:@"playfield"] ? 0 : _bleed);
    CGImageRef image = [self cropSlot:slot rect:CGRectInset(rect, bleed, bleed)];
    if (image) _cache[name] = (__bridge_transfer id)image;
    return image;
}

- (CGImageRef)insertIcon:(NSInteger)index {
    index = MAX(0, MIN(index, 15));
    NSString *key = [NSString stringWithFormat:@"icon%ld", (long)index];
    id cached = _cache[key];
    if (cached) return (__bridge CGImageRef)cached;
    NSDictionary *slot = _slots[@"inserts"];
    NSArray *r = slot[@"rect"];
    CGFloat width = [r[2] doubleValue] / 4.0, height = [r[3] doubleValue] / 4.0;
    CGRect rect = CGRectMake([r[0] doubleValue] + (index % 4) * width,
                             [r[1] doubleValue] + (index / 4) * height, width, height);
    // Exclude authored cell dividers without altering the glyph artwork.
    CGFloat bleed = [slot[@"cellBleed"] doubleValue];
    CGImageRef image = [self cropSlot:slot rect:CGRectInset(rect, bleed, bleed)];
    if (image) _cache[key] = (__bridge_transfer id)image;
    return image;
}

- (simd_float3)lampColor:(NSString *)name {
    return PBColor(_palette[@"lamps"][name], simd_make_float3(1.0f, 1.0f, 1.0f));
}

@end
