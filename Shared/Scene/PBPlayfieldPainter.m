//
//  PBPlayfieldPainter.m
//

#import "PBPlayfieldPainter.h"

static const size_t kPlayfieldWidth = 1417;

static CGContextRef PBCreateContext(size_t width, size_t height) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    return context;
}

static void PBSetFill(CGContextRef c, simd_float3 color, float alpha) {
    CGContextSetRGBFillColor(c, color.x, color.y, color.z, alpha);
}

/// Icons are white-on-black. Multiplying by the colour gives the tinted version.
static void PBDrawTintedIcon(CGContextRef c, CGImageRef icon, simd_float3 color, CGRect rect, float brightness) {
    CGContextSaveGState(c);
    CGContextSetBlendMode(c, kCGBlendModeScreen);
    CGContextRef layer = PBCreateContext(128, 128);
    CGContextDrawImage(layer, CGRectMake(0, 0, 128, 128), icon);
    CGContextSetBlendMode(layer, kCGBlendModeMultiply);
    PBSetFill(layer, color * brightness, 1.0f);
    CGContextFillRect(layer, CGRectMake(0, 0, 128, 128));
    CGImageRef tinted = CGBitmapContextCreateImage(layer);
    CGContextDrawImage(c, rect, tinted);
    CGImageRelease(tinted);
    CGContextRelease(layer);
    CGContextRestoreGState(c);
}

@implementation PBPlayfieldPainter

+ (CGImageRef)newPlayfieldForTable:(PBTableDefinition *)table skin:(PBSkin *)skin {
    CGFloat scale = (CGFloat)kPlayfieldWidth / table.size.x;
    size_t height = (size_t)round(table.size.y * scale);
    CGContextRef c = PBCreateContext(kPlayfieldWidth, height);
    CGRect full = CGRectMake(0, 0, kPlayfieldWidth, height);

    if ([skin hasImageForSlot:@"apron"]) {
        // Independent art zones keep the apron aligned for any table proportions.
        CGFloat apron = table.apronY * scale;
        CGContextDrawImage(c, CGRectMake(0, apron, kPlayfieldWidth, height - apron), [skin imageForSlot:@"playfield"]);
        CGContextDrawImage(c, CGRectMake(0, 0, kPlayfieldWidth, apron), [skin imageForSlot:@"apron"]);
    } else {
        CGContextDrawImage(c, full, [skin imageForSlot:@"playfield"]);
    }

    // Fine grain restores surface detail at phone resolution, where the art is upscaled.
    CGContextSaveGState(c);
    CGContextSetBlendMode(c, kCGBlendModeOverlay);
    CGContextSetAlpha(c, 0.35);
    CGImageRef detail = [skin imageForSlot:@"detail"];
    CGFloat tile = 320;
    for (CGFloat y = 0; y < height; y += tile) {
        for (CGFloat x = 0; x < kPlayfieldWidth; x += tile) CGContextDrawImage(c, CGRectMake(x, y, tile, tile), detail);
    }
    CGContextRestoreGState(c);

    // From here on, draw in table units.
    CGContextScaleCTM(c, scale, scale);
    [self paintLanesAndHoles:c table:table];
    [self paintContactShadows:c table:table scale:scale];
    [self paintInserts:c table:table skin:skin];

    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return image;
}

+ (void)strokeWall:(PBWallDef *)wall inContext:(CGContextRef)c {
    const simd_float2 *p = wall.points.points;
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, p[0].x, p[0].y);
    for (NSInteger i = 1; i < wall.points.count; i++) CGContextAddLineToPoint(c, p[i].x, p[i].y);
    if (wall.closed) CGContextClosePath(c);
    CGContextStrokePath(c);
}

+ (void)paintContactShadows:(CGContextRef)c table:(PBTableDefinition *)table scale:(CGFloat)scale {
    CGContextSaveGState(c);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat black[4] = { 0, 0, 0, 0.75 };
    CGColorRef shadow = CGColorCreate(space, black);
    CGColorSpaceRelease(space);
    CGContextSetShadowWithColor(c, CGSizeMake(0, -3), 14, shadow);
    CGColorRelease(shadow);
    CGContextSetRGBStrokeColor(c, 0, 0, 0, 0.6);
    CGContextSetRGBFillColor(c, 0, 0, 0, 0.6);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    for (PBWallDef *wall in table.walls) {
        if (wall.style == PBWallStyleNone) continue;
        CGContextSetLineWidth(c, wall.radius * 2.0f);
        [self strokeWall:wall inContext:c];
    }
    for (PBSpotDef *post in table.posts) {
        CGContextFillEllipseInRect(c, CGRectMake(post.position.x - post.radius, post.position.y - post.radius, post.radius * 2, post.radius * 2));
    }
    for (PBSpotDef *bumper in table.bumpers) {
        float r = bumper.radius * 1.05f;
        CGContextFillEllipseInRect(c, CGRectMake(bumper.position.x - r, bumper.position.y - r, r * 2, r * 2));
    }
    CGContextRestoreGState(c);
}

+ (void)paintLanesAndHoles:(CGContextRef)c table:(PBTableDefinition *)table {
    // Darken below the flippers, so the drain reads as a hole.
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat colors[8] = { 0, 0, 0, 0.72, 0, 0, 0, 0 };
    CGGradientRef fade = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
    CGContextSaveGState(c);
    CGContextClipToRect(c, CGRectMake(0, table.apronY, table.plunger.position.x - table.plunger.width, 0.2));
    CGContextDrawLinearGradient(c, fade, CGPointMake(0, table.apronY), CGPointMake(0, table.apronY + 0.17), 0);
    CGContextRestoreGState(c);

    // Shooter lane: dark metal channel.
    PBPlungerDef *plunger = table.plunger;
    CGFloat laneHalf = 0.033;
    CGFloat laneTop = table.gates.count ? table.gates.firstObject.a.y : table.size.y;
    CGContextSetRGBFillColor(c, 0.03, 0.03, 0.04, 0.82);
    CGContextFillRect(c, CGRectMake(plunger.position.x - laneHalf, table.drainY - 0.02, laneHalf * 2, laneTop - table.drainY + 0.02));

    // Saucers: a dark well with a metal lip.
    for (PBSpotDef *saucer in table.saucers) {
        CGPoint center = CGPointMake(saucer.position.x, saucer.position.y);
        CGFloat r = saucer.radius * 1.15;
        CGFloat well[8] = { 0, 0, 0, 1, 0.08, 0.08, 0.1, 1 };
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, well, NULL, 2);
        CGContextDrawRadialGradient(c, gradient, center, 0, center, r, 0);
        CGGradientRelease(gradient);
        CGContextSetRGBStrokeColor(c, 0.75, 0.76, 0.8, 1);
        CGContextSetLineWidth(c, 0.005);
        CGContextStrokeEllipseInRect(c, CGRectMake(center.x - r, center.y - r, r * 2, r * 2));
    }

    // Magnets: a steel plate under the glass.
    for (PBSpotDef *magnet in table.magnets) {
        CGFloat r = 0.052;
        CGContextSetRGBStrokeColor(c, 0.7, 0.72, 0.78, 0.9);
        CGContextSetLineWidth(c, 0.004);
        CGContextStrokeEllipseInRect(c, CGRectMake(magnet.position.x - r, magnet.position.y - r, r * 2, r * 2));
    }

    // Rollover wires.
    CGContextSetLineCap(c, kCGLineCapRound);
    for (PBSpotDef *rollover in table.rollovers) {
        CGFloat r = rollover.radius * 0.7;
        CGContextSetRGBStrokeColor(c, 0, 0, 0, 0.55);
        CGContextSetLineWidth(c, 0.006);
        CGContextMoveToPoint(c, rollover.position.x, rollover.position.y - r);
        CGContextAddLineToPoint(c, rollover.position.x, rollover.position.y + r);
        CGContextStrokePath(c);
        CGContextSetRGBStrokeColor(c, 0.9, 0.9, 0.95, 1);
        CGContextSetLineWidth(c, 0.0028);
        CGContextMoveToPoint(c, rollover.position.x, rollover.position.y - r);
        CGContextAddLineToPoint(c, rollover.position.x, rollover.position.y + r);
        CGContextStrokePath(c);
    }
    CGGradientRelease(fade);
    CGColorSpaceRelease(space);
}

+ (void)paintInserts:(CGContextRef)c table:(PBTableDefinition *)table skin:(PBSkin *)skin {
    for (PBLampDef *lamp in table.lamps) {
        simd_float3 color = [skin lampColor:lamp.color];
        CGFloat r = lamp.size;
        CGRect rect = CGRectMake(lamp.position.x - r, lamp.position.y - r, r * 2, r * 2);

        // Dark rim, then the unlit coloured plastic.
        CGContextSetRGBFillColor(c, 0, 0, 0, 0.7);
        CGContextFillEllipseInRect(c, CGRectInset(rect, -0.0035, -0.0035));
        PBSetFill(c, color * 0.22f, 1.0f);
        CGContextFillEllipseInRect(c, rect);
        CGContextSaveGState(c);
        CGContextAddEllipseInRect(c, rect);
        CGContextClip(c);
        PBDrawTintedIcon(c, [skin insertIcon:lamp.icon], color, CGRectInset(rect, r * 0.08, r * 0.08), 0.55f);
        CGContextRestoreGState(c);
    }
}

+ (CGImageRef)newLitLampWithIcon:(CGImageRef)icon color:(simd_float3)color {
    size_t size = 128;
    CGContextRef c = PBCreateContext(size, size);
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(0, 0, size, size));

    // Halo, spilling past the lens. The sprite is 2.4x the lens size, set in the scene.
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat halo[8] = { color.x * 0.6, color.y * 0.6, color.z * 0.6, 1, 0, 0, 0, 1 };
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, halo, NULL, 2);
    CGPoint center = CGPointMake(size * 0.5, size * 0.5);
    CGContextDrawRadialGradient(c, gradient, center, 0, center, size * 0.5, 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);

    // The lens itself.
    CGFloat lens = size / 2.4;
    CGRect lensRect = CGRectMake(center.x - lens * 0.5, center.y - lens * 0.5, lens, lens);
    CGContextSaveGState(c);
    CGContextAddEllipseInRect(c, lensRect);
    CGContextClip(c);
    PBSetFill(c, color * 0.55f, 1.0f);
    CGContextFillRect(c, lensRect);
    PBDrawTintedIcon(c, icon, simd_make_float3(1.0f, 1.0f, 1.0f), lensRect, 0.9f);
    CGContextRestoreGState(c);

    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return image;
}

+ (CGImageRef)newGlowWithColor:(simd_float3)color {
    size_t size = 128;
    CGContextRef c = PBCreateContext(size, size);
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(0, 0, size, size));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat components[12] = { color.x, color.y, color.z, 1, color.x * 0.25, color.y * 0.25, color.z * 0.25, 1, 0, 0, 0, 1 };
    CGFloat locations[3] = { 0, 0.35, 1 };
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 3);
    CGPoint center = CGPointMake(size * 0.5, size * 0.5);
    CGContextDrawRadialGradient(c, gradient, center, 0, center, size * 0.5, 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return image;
}

@end
