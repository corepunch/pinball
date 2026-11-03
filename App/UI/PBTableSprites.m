#import "PBTableSprites.h"
#import "PBTablePresentation.h"
#import "PBGateGeometry.h"

static SKColor *Ink(void) { return [SKColor colorWithRed:.025 green:.08 blue:.11 alpha:1]; }
static SKColor *Tone(NSString *name) {
    if ([name isEqualToString:@"green"]) return [SKColor colorWithRed:.36 green:.86 blue:.62 alpha:1];
    if ([name isEqualToString:@"cyan"]) return [SKColor colorWithRed:.26 green:.79 blue:.84 alpha:1];
    if ([name isEqualToString:@"red"]) return [SKColor colorWithRed:1 green:.38 blue:.28 alpha:1];
    return [SKColor colorWithRed:1 green:.73 blue:.31 alpha:1];
}

/// Rasterize once at authoring scale. The live game only moves textured sprites.
static SKSpriteNode *Sprite(CGPathRef path, SKColor *color, CGFloat stroke, BOOL shade) {
    CGRect b = CGRectInset(CGPathGetPathBoundingBox(path), -stroke - .014, -stroke - .014);
    CGFloat unit = 1200;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, ceil(b.size.width * unit), ceil(b.size.height * unit), 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextScaleCTM(c, unit, unit);
    CGContextTranslateCTM(c, -b.origin.x, -b.origin.y);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextSetLineCap(c, kCGLineCapRound);
    if (shade) {
        CGContextSetShadowWithColor(c, CGSizeMake(0, -.006), .005, [Ink() colorWithAlphaComponent:.65].CGColor);
    }
    CGContextAddPath(c, path);
    CGContextSetFillColorWithColor(c, color.CGColor);
    CGContextSetStrokeColorWithColor(c, Ink().CGColor);
    CGContextSetLineWidth(c, stroke);
    CGContextDrawPath(c, kCGPathFillStroke);
    CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
    if (shade) {
        CGContextSaveGState(c);
        CGContextAddPath(c, path); CGContextClip(c);
        CGColorSpaceRef gradientSpace = CGColorSpaceCreateDeviceRGB();
        CGFloat colors[] = {1,1,1,0, 1,1,1,.28};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(gradientSpace, colors, NULL, 2);
        CGContextDrawLinearGradient(c, gradient, CGPointMake(0, CGRectGetMinY(b)), CGPointMake(0, CGRectGetMaxY(b)), 0);
        CGGradientRelease(gradient); CGColorSpaceRelease(gradientSpace);
        CGContextRestoreGState(c);
    }
    CGImageRef pixels = CGBitmapContextCreateImage(c);
    SKTexture *texture = [SKTexture textureWithCGImage:pixels];
    SKSpriteNode *node = [SKSpriteNode spriteNodeWithTexture:texture size:b.size];
    node.anchorPoint = CGPointMake(-b.origin.x / b.size.width, -b.origin.y / b.size.height);
    CGImageRelease(pixels); CGContextRelease(c);
    return node;
}
static SKSpriteNode *Disc(float radius, SKColor *color, BOOL shade) {
    CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(-radius, -radius, radius*2, radius*2), NULL);
    SKSpriteNode *node = Sprite(path, color, .004, shade);
    CGPathRelease(path); return node;
}
static CGMutablePathRef Line(simd_float2 a, simd_float2 b, float radius) {
    CGMutablePathRef line = CGPathCreateMutable();
    CGPathMoveToPoint(line, NULL, a.x, a.y); CGPathAddLineToPoint(line, NULL, b.x, b.y);
    CGPathRef outline = CGPathCreateCopyByStrokingPath(line, NULL, radius * 2, kCGLineCapRound, kCGLineJoinRound, 2);
    CGPathRelease(line);
    CGMutablePathRef result = CGPathCreateMutableCopy(outline); CGPathRelease(outline);
    return result;
}

/// The outline of a convex polyline swept by a disc: straight faces offset by `radius`, joined by
/// arcs centred on the points. For a slingshot body this is exactly its collider's outer boundary.
static CGMutablePathRef RoundedPolygon(const simd_float2 *points, NSInteger count, float radius) {
    float area = 0;
    for (NSInteger i = 0; i < count; i++) {
        simd_float2 p = points[i], q = points[(i + 1) % count];
        area += p.x * q.y - q.x * p.y;
    }
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSInteger k = 0; k < count; k++) {
        // Walk anticlockwise, so each outward normal is the edge direction turned clockwise.
        NSInteger i = area >= 0 ? k : count - 1 - k;
        NSInteger prev = area >= 0 ? (i + count - 1) % count : (i + 1) % count;
        NSInteger next = area >= 0 ? (i + 1) % count : (i + count - 1) % count;
        simd_float2 v = points[i], entering = simd_normalize(v - points[prev]), leaving = simd_normalize(points[next] - v);
        float start = atan2f(-entering.x, entering.y), end = atan2f(-leaving.x, leaving.y);
        while (end < start) end += 2 * M_PI;
        CGPathAddArc(path, NULL, v.x, v.y, radius, start, end, NO);
    }
    CGPathCloseSubpath(path);
    return path;
}

/// Moves a triangle's faces inward by `distance`, so sweeping it by that radius restores its faces.
static void InsetTriangle(simd_float2 *p, float distance) {
    float a = simd_distance(p[1], p[2]), b = simd_distance(p[2], p[0]), c = simd_distance(p[0], p[1]);
    simd_float2 centre = (a*p[0] + b*p[1] + c*p[2]) / (a+b+c);
    simd_float2 e1 = p[1]-p[0], e2 = p[2]-p[0];
    float inradius = fabsf(e1.x*e2.y - e1.y*e2.x) / (a+b+c);
    for (int i = 0; i < 3; i++) p[i] = centre + (p[i]-centre) * ((inradius-distance)/inradius);
}

@implementation PBTableSprites {
    PBTableDefinition *_table;
    SKNode *_world;
    NSMutableArray<SKNode *> *_balls, *_flippers, *_drops, *_spinners, *_gates, *_bumpers, *_lamps;
    SKNode *_spring;
}
- (void)add:(SKNode *)node name:(NSString *)name position:(simd_float2)p z:(CGFloat)z {
    node.name = name; node.position = CGPointMake(p.x, p.y); node.zPosition = z;
    [_world addChild:node];
}
- (instancetype)initWithTable:(PBTableDefinition *)table {
    if ((self = [super init])) {
        self.name = @"table.sprites";
        _table = table;
        _world = [SKNode node]; [self addChild:_world];
        _balls = [NSMutableArray array]; _flippers = [NSMutableArray array];
        _drops = [NSMutableArray array]; _spinners = [NSMutableArray array];
        _gates = [NSMutableArray array]; _bumpers = [NSMutableArray array]; _lamps = [NSMutableArray array];
        // Quiet, full-bleed petrol field. All hardware comes from physical geometry.
        SKSpriteNode *floor = [SKSpriteNode spriteNodeWithColor:[SKColor colorWithRed:.035 green:.16 blue:.20 alpha:1] size:CGSizeMake(8, 8)];
        [self add:floor name:@"table.floor" position:simd_make_float2(.5, 1) z:-10];
        for (PBWallDef *wall in table.walls) {
            if (wall.style == PBWallStyleNone) continue;
            CGMutablePathRef path = CGPathCreateMutable();
            for (NSInteger i = 0; i < wall.points.count; i++) {
                simd_float2 p = wall.points.points[i];
                if (!i) CGPathMoveToPoint(path, NULL, p.x, p.y); else CGPathAddLineToPoint(path, NULL, p.x, p.y);
            }
            // The collider is the polyline swept by its radius (and, when closed, everything inside),
            // so its corners are rounded. Inset by half the ink line: the line's outer edge is the face.
            CGFloat sweep = MAX(wall.radius - .0015, .0005);
            CGPathRef shape;
            if (wall.closed) {
                CGPathCloseSubpath(path);
                CGPathRef rim = CGPathCreateCopyByStrokingPath(path, NULL, sweep*2, kCGLineCapRound, kCGLineJoinRound, 2);
                shape = CGPathCreateCopyByUnioningPath(path, rim, NO);
                CGPathRelease(rim);
            } else shape = CGPathCreateCopyByStrokingPath(path, NULL, sweep*2, kCGLineCapRound, kCGLineJoinRound, 2);
            SKColor *color = wall.style == PBWallStyleRail ? Tone(@"cyan") : [SKColor colorWithRed:.29 green:.48 blue:.48 alpha:1];
            if (wall.style == PBWallStylePlastic) color = Ink();
            [self add:Sprite(shape, color, .003, YES) name:wall.identifier position:0 z:2];
            CGPathRelease(shape); CGPathRelease(path);
        }
        // Plastics are the retained 3D kit's sharp lens outlines. Sprite slingshots draw their
        // bodies from the colliders below instead, so nothing visible extends past what the ball hits.
        for (PBEdgeDef *sling in table.slingshots) {
            SKNode *assembly = [SKNode node];
            PBWallDef *body = nil;
            for (PBWallDef *wall in table.walls) if ([wall.identifier isEqualToString:sling.body]) body = wall;
            const CGFloat stroke = .005;
            if (body) {
                // Inset by half the ink line, so the line's outer edge is the collider's face.
                CGMutablePathRef path = RoundedPolygon(body.points.points, body.points.count, body.radius - stroke * .5);
                SKSpriteNode *plate = Sprite(path, Tone(@"amber"), stroke, YES);
                [assembly addChild:plate];
                CGPathRelease(path);
            }
            CGMutablePathRef rubber = Line(sling.a, sling.b, PBSlingshotRadius - .0015);
            SKSpriteNode *band = Sprite(rubber, Tone(@"cyan"), .003, YES);
            band.zPosition = .1; [assembly addChild:band];
            CGPathRelease(rubber);
            // A bolt at the centre of each rounded corner's arc, concentric with it.
            for (NSInteger i = 0; body && i < body.points.count; i++) {
                float r = body.radius * .42;
                CGPathRef head = CGPathCreateWithEllipseInRect(CGRectMake(-r, -r, r*2, r*2), NULL);
                SKSpriteNode *bolt = Sprite(head, [SKColor colorWithRed:1 green:.88 blue:.62 alpha:1], .002, YES);
                CGPathRelease(head);
                SKSpriteNode *socket = Disc(r * .3, Ink(), NO);
                socket.zPosition = .1; [bolt addChild:socket];
                bolt.position = CGPointMake(body.points.points[i].x, body.points.points[i].y);
                bolt.zPosition = .2; [assembly addChild:bolt];
            }
            [self add:assembly name:sling.identifier position:0 z:3];
        }
        for (PBSpotDef *post in table.posts) [self add:Disc(post.radius, Tone(@"cyan"), YES) name:post.identifier position:post.position z:3];
        for (PBSpotDef *bumper in table.bumpers) {
            SKNode *assembly = [SKNode node];
            [assembly addChild:Disc(bumper.radius, Tone(@"amber"), YES)];
            [assembly addChild:Disc(bumper.radius*.68, Tone(@"cyan"), YES)];
            SKSpriteNode *centre = Disc(bumper.radius*.28, [SKColor colorWithRed:.95 green:.92 blue:.75 alpha:1], NO);
            [assembly addChild:centre];
            [self add:assembly name:bumper.identifier position:bumper.position z:4]; [_bumpers addObject:assembly];
        }
        for (PBSpotDef *saucer in table.saucers) {
            SKNode *node = [SKNode node];
            [node addChild:Disc(saucer.radius, Tone(@"cyan"), YES)];
            [node addChild:Disc(saucer.radius*.73, Ink(), NO)];
            [self add:node name:saucer.identifier position:saucer.position z:2];
        }
        NSArray *groups = @[table.dropTargets, table.standups, table.spinners, table.gates];
        for (NSUInteger group = 0; group < groups.count; group++) for (PBEdgeDef *edge in groups[group]) {
            CGMutablePathRef path = Line(0, edge.b-edge.a, .009);
            SKSpriteNode *node = Sprite(path, Tone(group == 0 ? @"green" : group == 1 ? @"amber" : @"cyan"), .003, YES);
            CGPathRelease(path);
            [self add:node name:edge.identifier position:edge.a z:5];
            if (!group) [_drops addObject:node];
            if (group == 2) [_spinners addObject:node];
            if (group == 3) [_gates addObject:node];
        }
        for (PBFlipperDef *flipper in table.flippers) {
            // Tapered capsule has the exact physical base and tip radii.
            float slope = (flipper.baseRadius-flipper.tipRadius)/flipper.length;
            float a = acosf(slope);
            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddArc(path,NULL,0,0,flipper.baseRadius,a,2*M_PI-a,NO);
            CGPathAddArc(path,NULL,flipper.length,0,flipper.tipRadius,2*M_PI-a,2*M_PI+a,NO);
            CGPathCloseSubpath(path);
            SKSpriteNode *node = Sprite(path, [SKColor colorWithRed:1 green:.48 blue:.29 alpha:1], .004, YES);
            CGPathRelease(path);
            [node addChild:Disc(flipper.baseRadius*.35, [SKColor colorWithRed:1 green:.85 blue:.55 alpha:1], NO)];
            [self add:node name:flipper.identifier position:flipper.pivot z:6]; [_flippers addObject:node];
        }
        for (PBSpotDef *rollover in table.rollovers) {
            if (!rollover.hasPlate) continue;
            CGMutablePathRef path = Line(simd_make_float2(-rollover.radius,0), simd_make_float2(rollover.radius,0), .003);
            [self add:Sprite(path, Tone(@"amber"), .002, NO) name:rollover.identifier position:rollover.position z:1];
            CGPathRelease(path);
        }
        for (PBLampDef *lamp in table.lamps) {
            SKSpriteNode *node;
            if (lamp.isArrow) {
                simd_float2 tip[3] = { simd_make_float2(0, lamp.size), simd_make_float2(-lamp.size*.65, -lamp.size*.6),
                                       simd_make_float2(lamp.size*.65, -lamp.size*.6) };
                // Same outer faces as the sharp arrow, with corners rounded by a fifth of its size.
                InsetTriangle(tip, lamp.size*.2);
                CGMutablePathRef path = RoundedPolygon(tip, 3, lamp.size*.2);
                node = Sprite(path, Tone(lamp.color), .002, NO); CGPathRelease(path);
                node.zRotation = lamp.angle - M_PI_2;
            } else node = Disc(lamp.size, Tone(lamp.color), YES);
            [self add:node name:lamp.identifier position:lamp.position z:1]; [_lamps addObject:node];
        }
        CGMutablePathRef spring = Line(simd_make_float2(-.024,0), simd_make_float2(.024,0), .009);
        _spring = Sprite(spring, Tone(@"amber"), .003, YES); CGPathRelease(spring);
        [self add:_spring name:@"plunger" position:table.plunger.position-simd_make_float2(0,table.ballRadius+.018) z:3];
    }
    return self;
}
- (void)setPlayfieldColor:(SKColor *)color {
    ((SKSpriteNode *)[self childNodeWithName:@"//table.floor"]).color = color;
}
- (void)layoutForViewSize:(CGSize)size topInset:(CGFloat)top bottomInset:(CGFloat)bottom {
    PBTableCameraFrame frame = PBTableCameraFrameMake(_table.size,size,top,bottom);
    CGFloat unit = size.height / frame.visibleHeight;
    _world.xScale = _world.yScale = unit;
    CGPoint origin = PBTableScreenPoint(_table.size,size,top,bottom,0,0);
    _world.position = CGPointMake(origin.x,size.height-origin.y);
}
- (void)syncWithGame:(PBGame *)game {
    PBPhysicsWorld *world = game.world;
    for (NSUInteger i=0;i<_flippers.count;i++) _flippers[i].zRotation = [world flipperAngle:i];
    for (NSUInteger i=0;i<_drops.count;i++) { _drops[i].alpha = [world isDropTargetUp:i] ? 1 : .18; }
    for (NSUInteger i=0;i<_spinners.count;i++) _spinners[i].yScale = .2 + .8*fabs(cos([world spinnerAngle:i]));
    for (NSUInteger i=0;i<_gates.count;i++) {
        PBEdgeDef *gate = _table.gates[i];
        _gates[i].zRotation = [world gateAngle:i]*PBGateOpeningSign(gate.a,gate.b,gate.passDirection);
    }
    for (NSUInteger i=0;i<_bumpers.count;i++) {
        CGFloat pulse = 1 + .10*MAX(0,1-[world bumperFlash:i]/.15);
        _bumpers[i].xScale = _bumpers[i].yScale = pulse;
    }
    for (NSUInteger i=0;i<_lamps.count;i++) {
        PBLampMode mode = [game.rules modeForLamp:i];
        BOOL lit = mode == PBLampOn || (mode == PBLampBlink && (world.tick/320)%2) || (mode == PBLampFastBlink && (world.tick/120)%2);
        _lamps[i].alpha = lit ? 1 : .28;
    }
    while (_balls.count < (NSUInteger)world.ballCapacity) {
        SKSpriteNode *node = Disc(_table.ballRadius, Tone(@"red"), YES);
        [self add:node name:[NSString stringWithFormat:@"ball.%lu",(unsigned long)_balls.count] position:0 z:8];
        [_balls addObject:node];
    }
    for (NSInteger i=0;i<world.ballCapacity;i++) {
        PBBall ball = world.balls[i]; SKNode *node = _balls[i];
        node.hidden = ball.state == PBBallInactive || ball.state == PBBallInTransit || ball.state == PBBallInSaucer;
        node.position = CGPointMake(ball.position.x,ball.position.y);
        simd_float3x3 strain = PBSoftBallShape([world softBallAtIndex:i]);
        // Project the contact-driven ellipse, preserving its rotated major/minor axes.
        float xx = simd_dot(simd_make_float3(strain.columns[0].x,strain.columns[1].x,strain.columns[2].x),simd_make_float3(strain.columns[0].x,strain.columns[1].x,strain.columns[2].x));
        float yy = simd_dot(simd_make_float3(strain.columns[0].y,strain.columns[1].y,strain.columns[2].y),simd_make_float3(strain.columns[0].y,strain.columns[1].y,strain.columns[2].y));
        float xy = simd_dot(simd_make_float3(strain.columns[0].x,strain.columns[1].x,strain.columns[2].x),simd_make_float3(strain.columns[0].y,strain.columns[1].y,strain.columns[2].y));
        float delta = hypotf(xx-yy,2*xy);
        node.zRotation = .5*atan2f(2*xy,xx-yy);
        node.xScale = sqrtf(MAX(.01,(xx+yy+delta)*.5));
        node.yScale = sqrtf(MAX(.01,(xx+yy-delta)*.5));
    }
    _spring.position = CGPointMake(_table.plunger.position.x,_table.plunger.position.y-_table.ballRadius-.018-world.plungerPull*_table.plunger.travel);
}
@end
