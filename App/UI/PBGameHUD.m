#import "PBGameHUD.h"
#import "PBTablePresentation.h"
#import <CoreText/CoreText.h>

static NSString *PBHUDNumber(int64_t value) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSNumberFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
    });
    if (value >= 1000000000000LL) return [NSString stringWithFormat:@"%.1fT", value / 1e12];
    if (value >= 1000000000LL) return [NSString stringWithFormat:@"%.1fB", value / 1e9];
    return [formatter stringFromNumber:@(MAX(0, value))];
}

static CGGradientRef PBHUDGradient(void) CF_RETURNS_RETAINED;
static CGGradientRef PBHUDGradient(void) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    const CGFloat colors[] = {1, .57, .13, 1, 1, .84, .32, 1, 1, .99, .84, 1};
    const CGFloat stops[] = {0, .48, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, stops, 3);
    CGColorSpaceRelease(space);
    return gradient;
}

static SKTexture *PBHUDGradientTexture(void) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, 24, 256, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGGradientRef gradient = PBHUDGradient();
    CGContextDrawLinearGradient(c, gradient, CGPointZero, CGPointMake(0, 256), 0);
    CGGradientRelease(gradient);
    CGImageRef pixels = CGBitmapContextCreateImage(c);
    SKTexture *texture = [SKTexture textureWithCGImage:pixels];
    CGImageRelease(pixels); CGContextRelease(c);
    return texture;
}

static SKTexture *PBHUDTextTexture(NSString *text, CGFloat fontSize, CGFloat maxWidth,
                                 SKColor *outlineColor, CGFloat outlineWidth, CGSize *size) {
    CTFontRef font = CTFontCreateWithName(CFSTR("LuckiestGuy-Regular"), fontSize, NULL);
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text
        attributes:@{(__bridge NSString *)kCTFontAttributeName: (__bridge id)font}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGMutablePathRef path = CGPathCreateMutable();
    for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
        CTRunRef run = (__bridge CTRunRef)object;
        CTFontRef runFont = (__bridge CTFontRef)((__bridge NSDictionary *)CTRunGetAttributes(run))[(__bridge NSString *)kCTFontAttributeName];
        for (CFIndex i = 0; i < CTRunGetGlyphCount(run); i++) {
            CGGlyph glyph; CGPoint position;
            CTRunGetGlyphs(run, CFRangeMake(i, 1), &glyph);
            CTRunGetPositions(run, CFRangeMake(i, 1), &position);
            CGPathRef outline = CTFontCreatePathForGlyph(runFont, glyph, NULL);
            if (outline) {
                CGAffineTransform transform = CGAffineTransformMakeTranslation(position.x, position.y);
                CGPathAddPath(path, &transform, outline);
                CGPathRelease(outline);
            }
        }
    }
    CGRect bounds = CGPathGetPathBoundingBox(path);
    CGFloat fit = MIN(1, MAX(1, maxWidth - 10) / MAX(1, bounds.size.width));
    CGAffineTransform transform = CGAffineTransformMake(fit, 0, 0, fit, 5 - bounds.origin.x * fit, 5 - bounds.origin.y * fit);
    CGPathRef fitted = CGPathCreateCopyByTransformingPath(path, &transform);
    *size = CGSizeMake(ceil(bounds.size.width * fit + 10), ceil(bounds.size.height * fit + 10));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, ceil(size->width * 3), ceil(size->height * 3), 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextScaleCTM(c, 3, 3);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    // Shared outlined glyphs and warm candy face for HUD and flying awards.
    CGContextSetShadowWithColor(c, CGSizeMake(0, -1.2), .6,
        [SKColor colorWithRed:.08 green:.22 blue:.18 alpha:.6].CGColor);
    CGContextAddPath(c, fitted);
    CGContextSetStrokeColorWithColor(c, outlineColor.CGColor);
    CGContextSetLineWidth(c, outlineWidth);
    CGContextStrokePath(c);
    CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
    CGContextAddPath(c, fitted);
    CGContextClip(c);
    CGGradientRef gradient = PBHUDGradient();
    CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 5), CGPointMake(0, size->height - 5), 0);
    CGGradientRelease(gradient);
    CGImageRef pixels = CGBitmapContextCreateImage(c);
    SKTexture *texture = [SKTexture textureWithCGImage:pixels];
    CGImageRelease(pixels); CGContextRelease(c);
    CGPathRelease(fitted); CGPathRelease(path); CFRelease(line); CFRelease(font);
    return texture;
}

@implementation PBGameHUD {
    SKSpriteNode *_score, *_progressFill;
    SKShapeNode *_progressTrack, *_progressTip;
    SKCropNode *_progressCrop;
    CGRect _progressRect;
    CGSize _scoreSize;
    CGFloat _scoreWidth;
    NSString *_caption;
    CGFloat _scale;
}

static SKColor *PBHUDCream(void) { return [SKColor colorWithRed:.98 green:.94 blue:.83 alpha:1]; }
static SKColor *PBHUDInk(void) { return [SKColor colorWithRed:.10 green:.20 blue:.21 alpha:1]; }

+ (void)registerFontsInBundle:(NSBundle *)bundle {
    NSURL *font = [bundle URLForResource:@"LuckiestGuy-Regular" withExtension:@"ttf" subdirectory:@"GameData/Fonts"];
    NSAssert(font, @"Missing bundled Luckiest Guy font");
    if (font) CTFontManagerRegisterFontsForURL((__bridge CFURLRef)font, kCTFontManagerScopeProcess, NULL);
}

+ (SKSpriteNode *)flyingScoreForPoints:(int64_t)points {
    CGSize size;
    SKTexture *texture = PBHUDTextTexture([NSString stringWithFormat:@"+%lld", points], 15, 280,
                                         SKColor.blackColor, 2, &size);
    SKSpriteNode *number = [SKSpriteNode spriteNodeWithTexture:texture size:size];
    number.name = @"effect.score";
    return number;
}

- (SKShapeNode *)shape:(CGPathRef)path fill:(SKColor *)fill stroke:(SKColor *)stroke width:(CGFloat)width {
    SKShapeNode *node = [SKShapeNode shapeNodeWithPath:path];
    node.fillColor = fill;
    node.strokeColor = stroke;
    node.lineWidth = width;
    node.antialiased = YES;
    [self addChild:node];
    return node;
}

- (void)layoutForViewSize:(CGSize)size topInset:(CGFloat)top bottomInset:(CGFloat)bottom {
    [self removeAllChildren];
    _caption = nil;
    _progressTrack = nil; _progressCrop = nil; _progressFill = nil; _progressTip = nil;
    PBGameViewLayout layout = PBGameViewLayoutMake(size, top, bottom);
    CGFloat h = size.height, s = layout.scale;
    _scale = s;
    // The drain keeps its dark well, with no decorative outline along the apron
    // or shooter channel. The display itself bounds the illustration.
    PBWallDef *apronL = nil, *apronR = nil, *shooter = nil;
    for (PBWallDef *wall in self.table.walls) {
        if ([wall.identifier isEqualToString:@"apronL"]) apronL = wall;
        if ([wall.identifier isEqualToString:@"apronR"]) apronR = wall;
        if ([wall.identifier isEqualToString:@"shooterInner"]) shooter = wall;
    }
    if (apronL.points.count >= 2 && apronR.points.count >= 2) {
        CGPoint (^project)(simd_float2) = ^CGPoint(simd_float2 p) {
            CGPoint screen = PBTableScreenPoint(self.table.size, size, top, bottom, p, 0);
            return CGPointMake(screen.x, h - screen.y);
        };
        CGPoint leftMouth = project(apronL.points.points[0]);
        CGPoint rightMouth = project(apronR.points.points[0]);
        CGFloat sinkY = MAX(0, project(simd_make_float2(0, -.035f)).y);
        CGFloat sinkMid = (leftMouth.x + rightMouth.x) * .5;
        CGFloat sinkHalf = (rightMouth.x - leftMouth.x) * .5;
        CGMutablePathRef sink = CGPathCreateMutable();
        CGPathMoveToPoint(sink, NULL, leftMouth.x, leftMouth.y);
        CGPathAddCurveToPoint(sink, NULL, leftMouth.x + sinkHalf * .25, sinkY,
                             sinkMid - sinkHalf * .5, sinkY, sinkMid, sinkY);
        CGPathAddCurveToPoint(sink, NULL, sinkMid + sinkHalf * .5, sinkY,
                             rightMouth.x - sinkHalf * .25, sinkY, rightMouth.x, rightMouth.y);
        CGPathCloseSubpath(sink);
        SKShapeNode *well = [self shape:sink fill:PBHUDInk() stroke:SKColor.clearColor width:0];
        well.name = @"hud.sink";
        well.zPosition = -.1;
        CGPathRelease(sink);
    }
    CGRect rect = layout.header;
    _score = [SKSpriteNode node];
    _score.name = @"hud.score";
    _score.anchorPoint = CGPointMake(0, .5);
    // The text texture contains five points of outline/shadow padding; align its
    // actual glyphs with the reference's left title margin.
    _score.position = CGPointMake(CGRectGetMinX(rect) - 5 * s, h - CGRectGetMidY(rect));
    _score.zPosition = 3;
    [self addChild:_score];
    _scoreWidth = CGRectGetMinX(layout.pause) - _score.position.x - 12 * s;

    if (shooter) {
        CGPoint base = PBTableScreenPoint(self.table.size, size, top, bottom,
            simd_make_float2(self.table.plunger.position.x, self.table.plunger.position.y + .12f), 0);
        CGPoint end = PBTableScreenPoint(self.table.size, size, top, bottom,
            shooter.points.points[shooter.points.count - 1], 0);
        // A thin inlaid gauge runs down the outer side of the launch channel.
        // Keep the lane's centre clear so the ball remains readable at all scores.
        CGFloat width = 7 * s;
        _progressRect = CGRectMake(size.width - 9 * s, h - base.y, width, MAX(1, base.y - end.y));
        SKShapeNode *track = [SKShapeNode shapeNodeWithRect:_progressRect cornerRadius:width * .5];
        track.name = @"hud.progress-track";
        track.fillColor = [SKColor colorWithRed:.15 green:.32 blue:.28 alpha:.32];
        track.strokeColor = [PBHUDCream() colorWithAlphaComponent:.75];
        track.lineWidth = s;
        [self addChild:track];
        _progressTrack = track;
        SKCropNode *crop = [SKCropNode node];
        SKShapeNode *mask = [SKShapeNode shapeNodeWithRect:_progressRect cornerRadius:width * .5];
        mask.fillColor = SKColor.whiteColor;
        mask.strokeColor = SKColor.clearColor;
        crop.maskNode = mask;
        crop.name = @"hud.progress";
        [self addChild:crop];
        _progressCrop = crop;
        _progressFill = [SKSpriteNode spriteNodeWithTexture:PBHUDGradientTexture()
            size:_progressRect.size];
        _progressFill.name = @"hud.progress-fill";
        _progressFill.anchorPoint = CGPointMake(.5, 0);
        _progressFill.position = CGPointMake(CGRectGetMidX(_progressRect), CGRectGetMinY(_progressRect));
        [crop addChild:_progressFill];
        // A bright rounded meniscus makes the current height easy to read.
        _progressTip = [SKShapeNode shapeNodeWithEllipseOfSize:CGSizeMake(width, 3 * s)];
        _progressTip.name = @"hud.progress-tip";
        _progressTip.fillColor = PBHUDCream();
        _progressTip.strokeColor = SKColor.clearColor;
        [crop addChild:_progressTip];
    }
}

- (void)updateScore:(int64_t)score goal:(int64_t)goal progress:(int64_t)progress kind:(NSString *)kind {
    BOOL scoreGoal = [kind isEqualToString:@"score"];
    NSString *text = PBHUDNumber(score);
    if (goal > 0) {
        text = scoreGoal ? [NSString stringWithFormat:@"%@ / %@", text, PBHUDNumber(goal)] :
            [NSString stringWithFormat:@"%@ · %@ / %@ %@", text, PBHUDNumber(progress), PBHUDNumber(goal), kind.uppercaseString];
    }
    if (![_caption isEqualToString:text]) {
        _caption = text;
        _score.texture = PBHUDTextTexture(text, 27 * _scale, _scoreWidth,
            [SKColor colorWithRed:.13 green:.30 blue:.24 alpha:1], 3.6, &_scoreSize);
        _score.size = _scoreSize;
    }
    BOOL visible = goal > 0;
    _progressTrack.hidden = _progressCrop.hidden = !visible;
    double fraction = visible ? fmin(1, fmax(0, (double)(scoreGoal ? score : progress) / (double)goal)) : 0;
    _progressFill.yScale = fraction;
    _progressFill.hidden = fraction <= 0;
    _progressTip.hidden = fraction <= 0;
    _progressTip.position = CGPointMake(CGRectGetMidX(_progressRect), CGRectGetMinY(_progressRect) + _progressRect.size.height * fraction);
}
@end
