//
//  PBDotMatrix.m
//

#import "PBDotMatrix.h"

static const NSInteger kColumns = 128;
static const NSInteger kRows = 32;

/// Classic 5x7 font. Each glyph is 5 columns, least significant bit at the top.
static const uint8_t *PBGlyph(unichar c) {
    static const uint8_t letters[26][5] = {
        {0x7E,0x09,0x09,0x09,0x7E},{0x7F,0x49,0x49,0x49,0x36},{0x3E,0x41,0x41,0x41,0x22},{0x7F,0x41,0x41,0x22,0x1C},
        {0x7F,0x49,0x49,0x49,0x41},{0x7F,0x09,0x09,0x09,0x01},{0x3E,0x41,0x49,0x49,0x7A},{0x7F,0x08,0x08,0x08,0x7F},
        {0x00,0x41,0x7F,0x41,0x00},{0x20,0x40,0x41,0x3F,0x01},{0x7F,0x08,0x14,0x22,0x41},{0x7F,0x40,0x40,0x40,0x40},
        {0x7F,0x02,0x0C,0x02,0x7F},{0x7F,0x04,0x08,0x10,0x7F},{0x3E,0x41,0x41,0x41,0x3E},{0x7F,0x09,0x09,0x09,0x06},
        {0x3E,0x41,0x51,0x21,0x5E},{0x7F,0x09,0x19,0x29,0x46},{0x46,0x49,0x49,0x49,0x31},{0x01,0x01,0x7F,0x01,0x01},
        {0x3F,0x40,0x40,0x40,0x3F},{0x1F,0x20,0x40,0x20,0x1F},{0x3F,0x40,0x38,0x40,0x3F},{0x63,0x14,0x08,0x14,0x63},
        {0x07,0x08,0x70,0x08,0x07},{0x61,0x51,0x49,0x45,0x43},
    };
    static const uint8_t digits[10][5] = {
        {0x3E,0x51,0x49,0x45,0x3E},{0x00,0x42,0x7F,0x40,0x00},{0x42,0x61,0x51,0x49,0x46},{0x21,0x41,0x45,0x4B,0x31},
        {0x18,0x14,0x12,0x7F,0x10},{0x27,0x45,0x45,0x45,0x39},{0x3C,0x4A,0x49,0x49,0x30},{0x01,0x71,0x09,0x05,0x03},
        {0x36,0x49,0x49,0x49,0x36},{0x06,0x49,0x49,0x29,0x1E},
    };
    static const uint8_t comma[5] = {0x00,0x50,0x30,0x00,0x00};
    static const uint8_t plus[5] = {0x08,0x08,0x3E,0x08,0x08};
    static const uint8_t blank[5] = {0,0,0,0,0};
    if (c >= 'A' && c <= 'Z') return letters[c - 'A'];
    if (c >= '0' && c <= '9') return digits[c - '0'];
    if (c == ',') return comma;
    if (c == '+') return plus;
    return blank;
}

@implementation PBDotMatrix {
    uint8_t _pixels[kRows][kColumns];
    NSString *_top, *_bottom;
    BOOL _large;
    SCNMaterial *_material;
    CGColorSpaceRef _rgb;
}

- (instancetype)initWithWidth:(float)width height:(float)height color:(simd_float3)color {
    if ((self = [super init])) {
        _rgb = CGColorSpaceCreateDeviceRGB();
        SCNPlane *plane = [SCNPlane planeWithWidth:width height:height];
        _material = plane.firstMaterial;
        _material.lightingModelName = SCNLightingModelConstant;
        _material.diffuse.minificationFilter = SCNFilterModeNearest;
        _material.diffuse.magnificationFilter = SCNFilterModeNearest;
        _material.diffuse.mipFilter = SCNFilterModeNone;
        _material.writesToDepthBuffer = YES;
        // Round dots on a grid. Values above 1 feed the camera's bloom, so the display glows.
        NSString *modifier = [NSString stringWithFormat:
            @"float2 pbGrid = _surface.diffuseTexcoord * float2(%ld.0, %ld.0);\n"
            @"float2 pbCell = fract(pbGrid) - 0.5;\n"
            @"float pbDot = 1.0 - smoothstep(0.30, 0.46, length(pbCell));\n"
            @"float pbLit = _output.color.r;\n"
            @"float3 pbColor = float3(%f, %f, %f);\n"
            @"_output.color.rgb = pbColor * (pbLit * 1.9 + 0.045) * pbDot;\n",
            (long)kColumns, (long)kRows, color.x, color.y, color.z];
        _material.shaderModifiers = @{ SCNShaderModifierEntryPointFragment: modifier };
        _node = [SCNNode nodeWithGeometry:plane];
        _node.eulerAngles = SCNVector3Make(-(float)M_PI_2, 0, 0);
        [self showTop:@"" bottom:@"" large:NO];
    }
    return self;
}

- (void)dealloc { CGColorSpaceRelease(_rgb); }

- (NSInteger)widthOf:(NSString *)text scale:(NSInteger)scale { return (NSInteger)text.length * 6 * scale - scale; }

- (void)draw:(NSString *)text atRow:(NSInteger)row scale:(NSInteger)scale {
    NSString *upper = text.uppercaseString;
    NSInteger x = (kColumns - [self widthOf:upper scale:scale]) / 2;
    for (NSUInteger i = 0; i < upper.length; i++) {
        const uint8_t *glyph = PBGlyph([upper characterAtIndex:i]);
        for (NSInteger column = 0; column < 5; column++) {
            for (NSInteger bit = 0; bit < 7; bit++) {
                if (!(glyph[column] >> bit & 1)) continue;
                for (NSInteger sy = 0; sy < scale; sy++) {
                    for (NSInteger sx = 0; sx < scale; sx++) {
                        NSInteger px = x + column * scale + sx, py = row + bit * scale + sy;
                        if (px >= 0 && px < kColumns && py >= 0 && py < kRows) _pixels[py][px] = 255;
                    }
                }
            }
        }
        x += 6 * scale;
    }
}

- (void)showTop:(NSString *)top bottom:(NSString *)bottom large:(BOOL)large {
    if ([top isEqualToString:_top] && [bottom isEqualToString:_bottom] && large == _large) return;
    _top = [top copy];
    _bottom = [bottom copy];
    _large = large;
    memset(_pixels, 0, sizeof(_pixels));

    // Pick the largest size that fits. Scores read best big.
    NSInteger topScale = [self widthOf:top.uppercaseString scale:3] <= kColumns ? 3 : ([self widthOf:top.uppercaseString scale:2] <= kColumns ? 2 : 1);
    if (large && bottom.length == 0) {
        topScale = MIN(topScale, 4);
        [self draw:top atRow:(kRows - 7 * topScale) / 2 scale:topScale];
    } else {
        topScale = MIN(topScale, 2);
        [self draw:top atRow:2 scale:topScale];
        [self draw:bottom atRow:21 scale:1];
    }

    // RGBA, because the simulator's Metal has no sRGB single-channel format.
    uint32_t rgba[kRows * kColumns];
    for (NSInteger y = 0; y < kRows; y++) {
        for (NSInteger x = 0; x < kColumns; x++) {
            uint32_t v = _pixels[y][x];
            rgba[y * kColumns + x] = 0xFF000000u | v << 16 | v << 8 | v;
        }
    }
    CGContextRef context = CGBitmapContextCreate(rgba, kColumns, kRows, 8, kColumns * 4, _rgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    _material.diffuse.contents = (__bridge id)image;
    CGImageRelease(image);
    CGContextRelease(context);
}

@end
