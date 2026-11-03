// Software capture of the shipping SpriteKit node graph, for hosts without Metal.
// Uses each sprite's actual texture, transforms, alpha and ordering; no alternate table artwork.
#import <SpriteKit/SpriteKit.h>
#import <objc/runtime.h>

@interface SKTexture (PBSnapshotSource)
+ (instancetype)pb_snapshotTextureWithCGImage:(CGImageRef)image;
+ (instancetype)pb_snapshotTextureWithRect:(CGRect)rect inTexture:(SKTexture *)parent;
@end
@implementation SKTexture (PBSnapshotSource)
+ (instancetype)pb_snapshotTextureWithCGImage:(CGImageRef)image {
    SKTexture *texture = [self pb_snapshotTextureWithCGImage:image];
    objc_setAssociatedObject(texture,@selector(pb_snapshotTextureWithCGImage:),(__bridge id)image,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return texture;
}
+ (instancetype)pb_snapshotTextureWithRect:(CGRect)rect inTexture:(SKTexture *)parent {
    SKTexture *texture = [self pb_snapshotTextureWithRect:rect inTexture:parent];
    CGImageRef image = (__bridge CGImageRef)objc_getAssociatedObject(parent,@selector(pb_snapshotTextureWithCGImage:));
    if (image) {
        CGRect crop = CGRectMake(rect.origin.x*CGImageGetWidth(image),(1-CGRectGetMaxY(rect))*CGImageGetHeight(image),rect.size.width*CGImageGetWidth(image),rect.size.height*CGImageGetHeight(image));
        CGImageRef pixels = CGImageCreateWithImageInRect(image,crop);
        objc_setAssociatedObject(texture,@selector(pb_snapshotTextureWithCGImage:),(__bridge id)pixels,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGImageRelease(pixels);
    }
    return texture;
}
@end
static void PBCaptureTextureSources(void) {
    method_exchangeImplementations(class_getClassMethod(SKTexture.class,@selector(textureWithRect:inTexture:)),class_getClassMethod(SKTexture.class,@selector(pb_snapshotTextureWithRect:inTexture:)));
    method_exchangeImplementations(class_getClassMethod(SKTexture.class,@selector(textureWithCGImage:)),class_getClassMethod(SKTexture.class,@selector(pb_snapshotTextureWithCGImage:)));
}
static CGImageRef PBTexturePixels(SKTexture *texture) {
    CGImageRef pixels = (__bridge CGImageRef)objc_getAssociatedObject(texture,@selector(pb_snapshotTextureWithCGImage:));
    return pixels ?: texture.CGImage;
}
static void PBCompositeNode(CGContextRef c, SKNode *node, CGFloat parentAlpha) {
    if (node.hidden || node.alpha <= 0) return;
    CGContextSaveGState(c);
    CGContextTranslateCTM(c,node.position.x,node.position.y);
    CGContextRotateCTM(c,node.zRotation);
    CGContextScaleCTM(c,node.xScale,node.yScale);
    CGFloat alpha = parentAlpha*node.alpha;
    CGContextSetAlpha(c,alpha);
    if ([node isKindOfClass:SKSpriteNode.class]) {
        SKSpriteNode *sprite = (SKSpriteNode *)node;
        CGRect rect = CGRectMake(-sprite.anchorPoint.x*sprite.size.width,-sprite.anchorPoint.y*sprite.size.height,sprite.size.width,sprite.size.height);
        if (sprite.texture) CGContextDrawImage(c,rect,PBTexturePixels(sprite.texture));
        else { CGContextSetFillColorWithColor(c,sprite.color.CGColor); CGContextFillRect(c,rect); }
    } else if ([node isKindOfClass:SKLabelNode.class]) {
        SKLabelNode *label = (SKLabelNode *)node;
        NSFont *font = [NSFont fontWithName:label.fontName size:label.fontSize] ?: [NSFont systemFontOfSize:label.fontSize];
        NSAttributedString *text = [[NSAttributedString alloc] initWithString:label.text ?: @"" attributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:label.fontColor ?: SKColor.whiteColor}];
        CGFloat x = label.horizontalAlignmentMode == SKLabelHorizontalAlignmentModeCenter ? -text.size.width*.5 : label.horizontalAlignmentMode == SKLabelHorizontalAlignmentModeRight ? -text.size.width : 0;
        CGFloat y = label.verticalAlignmentMode == SKLabelVerticalAlignmentModeCenter ? -text.size.height*.5 : label.verticalAlignmentMode == SKLabelVerticalAlignmentModeTop ? -text.size.height : font.descender;
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:c flipped:NO];
        [text drawAtPoint:CGPointMake(x,y)];
        [NSGraphicsContext restoreGraphicsState];
    } else if ([node isKindOfClass:SKShapeNode.class]) {
        SKShapeNode *shape = (SKShapeNode *)node;
        if (shape.path) {
            CGContextAddPath(c,shape.path); CGContextSetFillColorWithColor(c,shape.fillColor.CGColor);
            CGContextSetStrokeColorWithColor(c,shape.strokeColor.CGColor); CGContextSetLineWidth(c,shape.lineWidth);
            CGContextSetLineCap(c,shape.lineCap); CGContextSetLineJoin(c,shape.lineJoin);
            CGContextDrawPath(c,kCGPathFillStroke);
        }
    }
    if ([node isKindOfClass:SKCropNode.class]) {
        SKNode *mask = ((SKCropNode *)node).maskNode;
        if ([mask isKindOfClass:SKShapeNode.class]) {
            CGContextAddPath(c,((SKShapeNode *)mask).path); CGContextClip(c);
        } else if ([mask isKindOfClass:SKSpriteNode.class]) {
            SKSpriteNode *s = (SKSpriteNode *)mask;
            CGContextClipToRect(c,CGRectMake(s.position.x-s.anchorPoint.x*s.size.width,s.position.y-s.anchorPoint.y*s.size.height,s.size.width,s.size.height));
        }
    }
    NSArray *children = [node.children sortedArrayUsingComparator:^NSComparisonResult(SKNode *a,SKNode *b) {
        return a.zPosition < b.zPosition ? NSOrderedAscending : a.zPosition > b.zPosition ? NSOrderedDescending : NSOrderedSame;
    }];
    for (SKNode *child in children) PBCompositeNode(c,child,alpha);
    CGContextRestoreGState(c);
}
static NSImage *PBSpriteSnapshot(SKScene *scene, CGSize size) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL,size.width,size.height,8,0,space,kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextScaleCTM(c,size.width/scene.size.width,size.height/scene.size.height);
    PBCompositeNode(c,scene,1);
    CGImageRef image = CGBitmapContextCreateImage(c);
    NSImage *result = [[NSImage alloc] initWithCGImage:image size:size];
    CGImageRelease(image); CGContextRelease(c); return result;
}
