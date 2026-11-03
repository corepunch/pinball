// Export exact shipping shape pixels, with alpha trimming, deduplication and rectangular packing.
// Included after PBSpriteSnapshot.h and Require in the native preview tool.
static NSArray<NSValue *> *PBPackSprites(NSArray<NSDictionary *> *images, NSArray<NSNumber *> *order, NSInteger width, NSInteger height) {
    NSMutableArray<NSValue *> *free = [NSMutableArray arrayWithObject:[NSValue valueWithRect:CGRectMake(0,0,width,height)]];
    NSMutableArray *placed = [NSMutableArray array];
    for (NSUInteger i=0;i<images.count;i++) [placed addObject:NSNull.null];
    for (NSNumber *index in order) {
        NSDictionary *image = images[index.unsignedIntegerValue];
        CGFloat w = [image[@"width"] integerValue]+4, h = [image[@"height"] integerValue]+4;
        CGRect best = CGRectZero;
        CGFloat shortSide = CGFLOAT_MAX, longSide = CGFLOAT_MAX;
        for (NSValue *value in free) {
            CGRect f = value.rectValue;
            if (w>f.size.width || h>f.size.height) continue;
            CGFloat s = MIN(f.size.width-w,f.size.height-h), l = MAX(f.size.width-w,f.size.height-h);
            if (s<shortSide || (s==shortSide && l<longSide)) { best = CGRectMake(f.origin.x,f.origin.y,w,h); shortSide=s; longSide=l; }
        }
        if (!best.size.width) return nil;
        placed[index.unsignedIntegerValue] = [NSValue valueWithRect:best];
        NSMutableArray<NSValue *> *split = [NSMutableArray array];
        for (NSValue *value in free) {
            CGRect f = value.rectValue;
            if (!CGRectIntersectsRect(f,best)) { [split addObject:value]; continue; }
            if (CGRectGetMinX(best)>CGRectGetMinX(f)) [split addObject:[NSValue valueWithRect:CGRectMake(f.origin.x,f.origin.y,best.origin.x-f.origin.x,f.size.height)]];
            if (CGRectGetMaxX(best)<CGRectGetMaxX(f)) [split addObject:[NSValue valueWithRect:CGRectMake(CGRectGetMaxX(best),f.origin.y,CGRectGetMaxX(f)-CGRectGetMaxX(best),f.size.height)]];
            if (CGRectGetMinY(best)>CGRectGetMinY(f)) [split addObject:[NSValue valueWithRect:CGRectMake(f.origin.x,f.origin.y,f.size.width,best.origin.y-f.origin.y)]];
            if (CGRectGetMaxY(best)<CGRectGetMaxY(f)) [split addObject:[NSValue valueWithRect:CGRectMake(f.origin.x,CGRectGetMaxY(best),f.size.width,CGRectGetMaxY(f)-CGRectGetMaxY(best))]];
        }
        // MaxRects free regions may overlap; remove regions contained in another.
        free = [NSMutableArray array];
        for (NSUInteger i=0;i<split.count;i++) {
            BOOL contained = NO;
            for (NSUInteger j=0;j<split.count;j++) if (i!=j && CGRectContainsRect(split[j].rectValue,split[i].rectValue) &&
                (!CGRectEqualToRect(split[i].rectValue,split[j].rectValue) || j<i)) { contained=YES; break; }
            if (!contained) [free addObject:split[i]];
        }
    }
    return placed;
}

static void PBExportTableSprites(PBTableSprites *tableNode, PBTableDefinition *table, NSString *output) {
    const CGFloat unit = 1200;
    SKNode *world = [tableNode childNodeWithName:@"//table.floor"].parent;
    NSMutableArray<NSMutableDictionary *> *entries = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *images = [NSMutableArray array];
    NSMutableDictionary<NSArray *, NSNumber *> *unique = [NSMutableDictionary dictionary];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    for (SKNode *source in world.children) {
        if ([source.name isEqualToString:@"table.floor"] || ([source.name hasPrefix:@"ball."] && ![source.name isEqualToString:@"ball.0"])) continue;
        SKNode *local = [source copy];
        local.position = CGPointZero; local.zRotation = 0;
        local.xScale = local.yScale = local.alpha = 1; local.hidden = NO;
        CGRect extent = [local calculateAccumulatedFrame];
        CGFloat bx = floor(CGRectGetMinX(extent)*unit)/unit, by = floor(CGRectGetMinY(extent)*unit)/unit;
        NSInteger w = ceil((CGRectGetMaxX(extent)-bx)*unit), h = ceil((CGRectGetMaxY(extent)-by)*unit);
        Require(w>0 && h>0, @"exportable sprite bounds");
        NSMutableData *raster = [NSMutableData dataWithLength:w*h*4];
        CGContextRef c = CGBitmapContextCreate(raster.mutableBytes,w,h,8,w*4,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        Require(c!=NULL,@"sprite raster context");
        CGContextScaleCTM(c,unit,unit); CGContextTranslateCTM(c,-bx,-by);
        PBCompositeNode(c,local,1); CGContextRelease(c);
        const uint8_t *pixels = raster.bytes;
        NSInteger x0=w,y0=h,x1=-1,y1=-1;
        for (NSInteger y=0;y<h;y++) for (NSInteger x=0;x<w;x++) if (pixels[(y*w+x)*4+3]) {
            x0=MIN(x0,x); y0=MIN(y0,y); x1=MAX(x1,x); y1=MAX(y1,y);
        }
        Require(x1>=x0 && y1>=y0,@"sprite has visible pixels");
        NSInteger tw=x1-x0+1, th=y1-y0+1;
        NSMutableData *trimmed = [NSMutableData dataWithLength:tw*th*4];
        for (NSInteger y=0;y<th;y++) memcpy((uint8_t *)trimmed.mutableBytes+y*tw*4,pixels+((y+y0)*w+x0)*4,tw*4);
        // Pixel rows run down from the image top; geometry and pivots remain y-up.
        bx += x0/unit; by += (h-1-y1)/unit;
        NSArray *key = @[@(tw),@(th),trimmed];
        NSNumber *index = unique[key];
        if (!index) {
            index = @(images.count); unique[key]=index;
            [images addObject:@{@"width":@(tw),@"height":@(th),@"pixels":trimmed}];
        }
        [entries addObject:[@{
            @"id": source.name, @"imageIndex": index,
            @"localBounds": @[@(bx),@(by),@(tw/unit),@(th/unit)],
            @"pivotPixels": @[@(-bx*unit),@(by*unit+th)],
            @"position": @[@(source.position.x),@(source.position.y)],
            @"rotation": @(source.zRotation), @"scale": @[@(source.xScale),@(source.yScale)],
            @"alpha": @(source.alpha), @"hidden": @(source.hidden), @"z": @(source.zPosition)
        } mutableCopy]];
    }
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    NSInteger minWidth=0,minHeight=0,totalHeight=0,area=0;
    for (NSUInteger i=0;i<images.count;i++) {
        [order addObject:@(i)];
        NSInteger w=[images[i][@"width"] integerValue]+4,h=[images[i][@"height"] integerValue]+4;
        minWidth=MAX(minWidth,w); minHeight=MAX(minHeight,h); totalHeight+=h; area+=w*h;
    }
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a,NSNumber *b) {
        NSDictionary *aa=images[a.unsignedIntegerValue],*bb=images[b.unsignedIntegerValue];
        NSInteger aw=[aa[@"width"] integerValue],ah=[aa[@"height"] integerValue],bw=[bb[@"width"] integerValue],bh=[bb[@"height"] integerValue];
        NSInteger d=MAX(bw,bh)-MAX(aw,ah);
        if (!d) d=bw*bh-aw*ah;
        return d<0 ? NSOrderedAscending : d>0 ? NSOrderedDescending : [a compare:b];
    }];
    NSArray<NSValue *> *best = nil;
    NSInteger bestArea=NSIntegerMax,width=0,height=0;
    // Search rectangular canvases; no power-of-two padding, no rotation, no splitting long rails.
    for (NSInteger candidate=minWidth;candidate<=MAX(2048,minWidth);candidate+=16) {
        NSInteger low=MAX(minHeight,(area+candidate-1)/candidate),high=totalHeight;
        NSArray<NSValue *> *packed = PBPackSprites(images,order,candidate,high);
        while (low<high) {
            NSInteger middle=(low+high)/2;
            NSArray<NSValue *> *attempt=PBPackSprites(images,order,candidate,middle);
            if (attempt) { high=middle; packed=attempt; } else low=middle+1;
        }
        NSInteger usedWidth=0,usedHeight=0;
        for (NSValue *value in packed) { usedWidth=MAX(usedWidth,CGRectGetMaxX(value.rectValue)); usedHeight=MAX(usedHeight,CGRectGetMaxY(value.rectValue)); }
        if (packed && usedWidth*usedHeight<bestArea) { bestArea=usedWidth*usedHeight; best=packed; width=usedWidth; height=usedHeight; }
    }
    Require(best!=nil && images.count>0,@"atlas packing");
    NSMutableData *atlas = [NSMutableData dataWithLength:width*height*4];
    for (NSUInteger i=0;i<images.count;i++) {
        CGRect rect=best[i].rectValue;
        NSInteger x=rect.origin.x+2,y=rect.origin.y+2,w=[images[i][@"width"] integerValue],h=[images[i][@"height"] integerValue];
        const uint8_t *source=[images[i][@"pixels"] bytes];
        for (NSInteger row=0;row<h;row++) memcpy((uint8_t *)atlas.mutableBytes+((y+row)*width+x)*4,source+row*w*4,w*4);
        for (NSUInteger j=0;j<i;j++) Require(!CGRectIntersectsRect(rect,best[j].rectValue),@"packed sprites and gutters do not overlap");
    }
    for (NSMutableDictionary *entry in entries) {
        NSUInteger index=[entry[@"imageIndex"] unsignedIntegerValue];
        CGRect rect=best[index].rectValue;
        NSInteger x=rect.origin.x+2,y=rect.origin.y+2,w=[images[index][@"width"] integerValue],h=[images[index][@"height"] integerValue];
        entry[@"rect"]=@[@(x),@(y),@(w),@(h)];
        [entry removeObjectForKey:@"imageIndex"];
        // Every placement, including aliases, must recover the exact uncompressed source pixels.
        const uint8_t *source=[images[index][@"pixels"] bytes];
        for (NSInteger row=0;row<h;row++) Require(memcmp((const uint8_t *)atlas.bytes+((y+row)*width+x)*4,source+row*w*4,w*4)==0,@"atlas crop round trip");
    }
    if (!output) {
        CGColorSpaceRelease(space);
        NSLog(@"Verified trimmed atlas packing and pixel round trips for %@",table.identifier);
        return;
    }
    CGContextRef c = CGBitmapContextCreate(atlas.mutableBytes,width,height,8,width*4,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    Require(c!=NULL,@"atlas context");
    CGImageRef pixels=CGBitmapContextCreateImage(c);
    NSString *png=[output stringByAppendingPathComponent:@"sprites.png"];
    CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:png],CFSTR("public.png"),1,NULL);
    Require(destination!=NULL,@"atlas PNG destination");
    CGImageDestinationAddImage(destination,pixels,NULL);
    Require(CGImageDestinationFinalize(destination),@"atlas PNG write");
    CFRelease(destination); CGImageRelease(pixels); CGContextRelease(c);
    NSDictionary *manifest=@{
        @"format":@1,@"table":table.identifier,@"image":@"sprites.png",@"pixelsPerUnit":@(unit),
        @"canvas":@[@(width),@(height)],@"uniqueImages":@(images.count),@"gutter":@2,
        @"packingOccupancy":@((double)area/(width*height)),
        @"tableSize":@[@(table.size.x),@(table.size.y)],@"ballRadius":@(table.ballRadius),
        @"coordinates":@"rect and pivotPixels: top-left pixels; localBounds and position: table units, y up; rotation: radians",
        @"artwork":@"Alpha-trimmed, unscaled, full-opacity source shapes. Identical artwork shares rects. Apply placement and live physics/rules separately. Floor is a solid colour.",
        @"sprites":entries
    };
    NSData *json=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    Require([json writeToFile:[output stringByAppendingPathComponent:@"sprites.json"] atomically:YES],@"atlas manifest write");
    NSLog(@"Exported %lu assemblies, %lu unique images: %@ (%ld x %ld, %.1f%% occupied)",(unsigned long)entries.count,(unsigned long)images.count,png,(long)width,(long)height,100.*area/(width*height));
}
