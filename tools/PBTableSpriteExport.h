// Export exact shipping shape pixels: alpha trimming, deduplication, then packing by each
// image's own outline with quarter-turn rotation, and a cut-out mesh per image.
// Included after PBSpriteSnapshot.h and Require in the native preview tool.

static const int PBAtlasGutter = 2;  // Clear pixels between any two images' outlines.

/// One image in one of its four atlas orientations. Rows are the image's opaque extent per pixel
/// row (holes inside a row are kept, never packed into), so the outline is exact to the pixel.
typedef struct {
    int w, h, turns;
    int *left, *right;          // Per row, right exclusive.
    int *padLeft, *padRight;    // Rows -gutter..h+gutter-1, grown by the gutter.
    int padMin, padMax;
    uint8_t *pixels;
} PBOrientation;

typedef struct { int count, capacity; int *spans; } PBAtlasRow;

/// Source (sx, sy) → atlas-local (u, v); both pixel-corner coordinates, top-left origin, y down.
/// `turns` quarter turns anticlockwise as seen in the image. `w`/`h` are the source size.
static CGPoint PBTurnForward(CGPoint s, int turns, int w, int h) {
    switch (turns & 3) {
        case 1: return CGPointMake(s.y, w - s.x);
        case 2: return CGPointMake(w - s.x, h - s.y);
        case 3: return CGPointMake(h - s.y, s.x);
        default: return s;
    }
}
static CGPoint PBTurnBack(CGPoint a, int turns, int w, int h) {
    switch (turns & 3) {
        case 1: return CGPointMake(w - a.y, a.x);
        case 2: return CGPointMake(w - a.x, h - a.y);
        case 3: return CGPointMake(a.y, h - a.x);
        default: return a;
    }
}

static PBOrientation PBMakeOrientation(const uint8_t *source, int w, int h, int turns) {
    PBOrientation o = { .turns = turns & 3 };
    o.w = (turns & 1) ? h : w; o.h = (turns & 1) ? w : h;
    o.pixels = malloc((size_t)o.w * o.h * 4);
    for (int y = 0; y < o.h; y++) for (int x = 0; x < o.w; x++) {
        CGPoint s = PBTurnBack(CGPointMake(x + .5, y + .5), turns, w, h);
        memcpy(o.pixels + ((size_t)y * o.w + x) * 4, source + ((size_t)floor(s.y) * w + (size_t)floor(s.x)) * 4, 4);
    }
    o.left = malloc(sizeof(int) * o.h); o.right = malloc(sizeof(int) * o.h);
    for (int y = 0; y < o.h; y++) {
        int l = -1, r = -1;
        for (int x = 0; x < o.w; x++) if (o.pixels[((size_t)y * o.w + x) * 4 + 3]) { if (l < 0) l = x; r = x + 1; }
        o.left[y] = l; o.right[y] = r;
    }
    // A fully transparent row inside an assembly keeps its neighbour's extent, conservatively.
    for (int y = 1; y < o.h; y++) if (o.left[y] < 0) { o.left[y] = o.left[y-1]; o.right[y] = o.right[y-1]; }
    for (int y = o.h - 2; y >= 0; y--) if (o.left[y] < 0) { o.left[y] = o.left[y+1]; o.right[y] = o.right[y+1]; }
    const int g = PBAtlasGutter, rows = o.h + 2 * g;
    o.padLeft = malloc(sizeof(int) * rows); o.padRight = malloc(sizeof(int) * rows);
    o.padMin = INT_MAX; o.padMax = INT_MIN;
    for (int i = 0; i < rows; i++) {
        int l = INT_MAX, r = INT_MIN;
        for (int y = MAX(0, i - 2 * g); y <= MIN(o.h - 1, i); y++) { l = MIN(l, o.left[y]); r = MAX(r, o.right[y]); }
        o.padLeft[i] = l - g; o.padRight[i] = r + g;
        o.padMin = MIN(o.padMin, l - g); o.padMax = MAX(o.padMax, r + g);
    }
    return o;
}
static void PBFreeOrientation(PBOrientation *o) { free(o->pixels); free(o->left); free(o->right); free(o->padLeft); free(o->padRight); }

/// The lowest, then leftmost, position where the gutter-grown outline misses every placed outline.
static BOOL PBFindPlace(PBAtlasRow *rows, int canvasHeight, const PBOrientation *o, int width, int stopBottom, int *outX, int *outY) {
    const int g = PBAtlasGutter;
    for (int y = g; y + o->h + g <= canvasHeight && y + o->h < stopBottom; y++) {
        int x = -o->padMin;
        BOOL moved = YES;
        while (moved && x + o->padMax <= width) {
            moved = NO;
            for (int i = 0; i < o->h + 2 * g && !moved; i++) {
                const PBAtlasRow *row = &rows[y - g + i];
                int a = x + o->padLeft[i], b = x + o->padRight[i];
                for (int k = 0; k < row->count; k++) {
                    int p = row->spans[2*k], q = row->spans[2*k+1];
                    if (p < b && a < q) { x = q - o->padLeft[i]; moved = YES; break; }
                }
            }
        }
        if (!moved && x + o->padMax <= width) { *outX = x; *outY = y; return YES; }
    }
    return NO;
}

/// Packs at one canvas width. Returns the used area, or 0 when something cannot fit.
static NSInteger PBPackOutlines(PBOrientation (*orientations)[4], NSArray<NSNumber *> *order, int width, int canvasHeight,
                                int *placeX, int *placeY, int *placeTurns, int *usedWidth, int *usedHeight) {
    PBAtlasRow *rows = calloc(canvasHeight, sizeof(PBAtlasRow));
    int maxX = 0, maxY = 0; BOOL ok = YES;
    for (NSNumber *number in order) {
        NSUInteger index = number.unsignedIntegerValue;
        int bestX = 0, bestY = 0, bestTurn = -1, bestBottom = INT_MAX;
        for (int turn = 0; turn < 4; turn++) {
            const PBOrientation *o = &orientations[index][turn];
            int x, y;
            if (o->padMax - o->padMin > width) continue;
            if (PBFindPlace(rows, canvasHeight, o, width, bestBottom, &x, &y) && (y + o->h < bestBottom || (y + o->h == bestBottom && x < bestX))) {
                bestX = x; bestY = y; bestTurn = turn; bestBottom = y + o->h;
            }
        }
        if (bestTurn < 0) { ok = NO; break; }
        const PBOrientation *o = &orientations[index][bestTurn];
        for (int i = 0; i < o->h; i++) {
            PBAtlasRow *row = &rows[bestY + i];
            if (row->count == row->capacity) { row->capacity = MAX(4, row->capacity * 2); row->spans = realloc(row->spans, sizeof(int) * 2 * row->capacity); }
            row->spans[2*row->count] = bestX + o->left[i]; row->spans[2*row->count+1] = bestX + o->right[i]; row->count++;
        }
        placeX[index] = bestX; placeY[index] = bestY; placeTurns[index] = bestTurn;
        maxX = MAX(maxX, bestX + o->padMax); maxY = MAX(maxY, bestY + o->h + PBAtlasGutter);
    }
    for (int i = 0; i < canvasHeight; i++) free(rows[i].spans);
    free(rows);
    *usedWidth = maxX; *usedHeight = maxY;
    return ok ? (NSInteger)maxX * maxY : 0;
}

/// Piecewise-linear edge between pixel-row boundaries, never inside the opaque rows and at most one
/// pixel outside them, with as few corners as that allows. `outward` is -1 for the left edge.
static NSArray<NSArray<NSNumber *> *> *PBFitEdge(const PBOrientation *o, int outward) {
    double *bound = malloc(sizeof(double) * (o->h + 1));
    for (int t = 0; t <= o->h; t++) {
        int above = MAX(t - 1, 0), below = MIN(t, o->h - 1);
        bound[t] = outward < 0 ? MIN(o->left[above], o->left[below]) : MAX(o->right[above], o->right[below]);
    }
    NSMutableArray *corners = [NSMutableArray arrayWithObject:@[@0, @(bound[0])]];
    int start = 0; double value = bound[0];
    while (start < o->h) {
        double low = -INFINITY, high = INFINITY; int end = start;
        for (int t = start + 1; t <= o->h; t++) {
            double a = outward < 0 ? bound[t] - 1 : bound[t], b = outward < 0 ? bound[t] : bound[t] + 1;
            double nl = MAX(low, (a - value) / (t - start)), nh = MIN(high, (b - value) / (t - start));
            if (nl > nh) break;
            low = nl; high = nh; end = t;
        }
        value += (low + high) * .5 * (end - start); start = end;
        [corners addObject:@[@(start), @(value)]];
    }
    free(bound);
    return corners;
}
static double PBEdgeAt(NSArray<NSArray<NSNumber *> *> *corners, double t) {
    for (NSUInteger i = 1; i < corners.count; i++) {
        double t0 = corners[i-1][0].doubleValue, t1 = corners[i][0].doubleValue;
        if (t <= t1 || i + 1 == corners.count) {
            double v0 = corners[i-1][1].doubleValue, v1 = corners[i][1].doubleValue;
            return v0 + (v1 - v0) * (t - t0) / (t1 - t0);
        }
    }
    return corners.firstObject[1].doubleValue;
}
static double PBRound3(double v) { return round(v * 1000) / 1000; }

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
    const NSUInteger count = images.count;
    Require(count > 0, @"atlas has images");
    PBOrientation (*orientations)[4] = calloc(count, sizeof(*orientations));
    NSInteger opaque = 0; int canvasHeight = 0, minSide = 0, maxSide = 0;
    NSMutableArray<NSNumber *> *bySide = [NSMutableArray array], *byArea = [NSMutableArray array];
    NSMutableArray<NSNumber *> *areas = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        int w = [images[i][@"width"] intValue], h = [images[i][@"height"] intValue];
        const uint8_t *bytes = [images[i][@"pixels"] bytes];
        for (int turn = 0; turn < 4; turn++) orientations[i][turn] = PBMakeOrientation(bytes, w, h, turn);
        NSInteger filled = 0;
        for (NSInteger p = 0; p < (NSInteger)w * h; p++) filled += bytes[p * 4 + 3] != 0;
        opaque += filled; [areas addObject:@(filled)];
        canvasHeight += MAX(w, h) + 2 * PBAtlasGutter + 1;
        minSide = MAX(minSide, MIN(w, h) + 2 * PBAtlasGutter); maxSide = MAX(maxSide, MAX(w, h) + 2 * PBAtlasGutter);
        [bySide addObject:@(i)]; [byArea addObject:@(i)];
    }
    // Large outlines first; the small ones then settle into the hollows they leave.
    [bySide sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSDictionary *x = images[a.unsignedIntegerValue], *y = images[b.unsignedIntegerValue];
        NSInteger d = MAX([y[@"width"] integerValue], [y[@"height"] integerValue]) - MAX([x[@"width"] integerValue], [x[@"height"] integerValue]);
        if (!d) d = [areas[b.unsignedIntegerValue] integerValue] - [areas[a.unsignedIntegerValue] integerValue];
        return d < 0 ? NSOrderedAscending : d > 0 ? NSOrderedDescending : [a compare:b];
    }];
    [byArea sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSInteger d = [areas[b.unsignedIntegerValue] integerValue] - [areas[a.unsignedIntegerValue] integerValue];
        return d < 0 ? NSOrderedAscending : d > 0 ? NSOrderedDescending : [a compare:b];
    }];
    int *trialX = malloc(sizeof(int) * count), *trialY = malloc(sizeof(int) * count), *trialTurn = malloc(sizeof(int) * count);
    int *placeX = malloc(sizeof(int) * count), *placeY = malloc(sizeof(int) * count), *placeTurn = malloc(sizeof(int) * count);
    __block NSInteger bestArea = NSIntegerMax; __block int width = 0, height = 0, bestCanvas = 0;
    void (^attempt)(int) = ^(int candidate) {
        for (NSArray<NSNumber *> *order in @[bySide, byArea]) {
            int w = 0, h = 0;
            NSInteger area = PBPackOutlines(orientations, order, candidate, canvasHeight, trialX, trialY, trialTurn, &w, &h);
            if (area && (area < bestArea || (area == bestArea && h < height))) {
                bestArea = area; width = w; height = h; bestCanvas = candidate;
                memcpy(placeX, trialX, sizeof(int) * count); memcpy(placeY, trialY, sizeof(int) * count); memcpy(placeTurn, trialTurn, sizeof(int) * count);
            }
        }
    };
    // Coarse canvas widths, then a fine search around the best. Nothing is ever split or scaled.
    for (int candidate = minSide; candidate <= maxSide + 32; candidate += 32) attempt(candidate);
    int coarse = bestCanvas;
    for (int candidate = MAX(minSide, coarse - 32); candidate <= coarse + 32; candidate += 4) attempt(candidate);
    Require(bestArea < NSIntegerMax, @"atlas packing");

    NSMutableData *atlas = [NSMutableData dataWithLength:(NSUInteger)width * height * 4];
    uint8_t *canvas = atlas.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) {
        const PBOrientation *o = &orientations[i][placeTurn[i]];
        for (int y = 0; y < o->h; y++) for (int x = 0; x < o->w; x++) {
            const uint8_t *p = o->pixels + ((size_t)y * o->w + x) * 4;
            if (!p[3]) continue;
            uint8_t *q = canvas + ((size_t)(placeY[i] + y) * width + placeX[i] + x) * 4;
            Require(placeX[i] + x >= 0 && placeX[i] + x < width && placeY[i] + y < height, @"packed image inside the canvas");
            Require(q[3] == 0, @"packed outlines and gutters do not overlap");
            memcpy(q, p, 4);
        }
    }
    NSMutableArray<NSDictionary *> *meshes = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        const PBOrientation *o = &orientations[i][placeTurn[i]];
        const int X = placeX[i], Y = placeY[i], sw = [images[i][@"width"] intValue], sh = [images[i][@"height"] intValue];
        NSArray *left = PBFitEdge(o, -1), *right = PBFitEdge(o, 1);
        // The cut-out covers every opaque pixel square of this image...
        for (int y = 0; y < o->h; y++) {
            double l = MAX(PBEdgeAt(left, y), PBEdgeAt(left, y + 1)), r = MIN(PBEdgeAt(right, y), PBEdgeAt(right, y + 1));
            Require(l <= o->left[y] + 1e-9 && r >= o->right[y] - 1e-9, @"cut-out mesh covers its image");
            // ...and every atlas pixel centred inside it is this image's pixel or transparent.
            double ml = X + PBEdgeAt(left, y + .5), mr = X + PBEdgeAt(right, y + .5);
            for (int x = MAX(0, (int)floor(ml)); x <= MIN(width - 1, (int)ceil(mr)); x++) {
                if (x + .5 < ml || x + .5 > mr) continue;
                int lx = x - X;
                BOOL own = lx >= 0 && lx < o->w && o->pixels[((size_t)y * o->w + lx) * 4 + 3];
                Require(own || canvas[((size_t)(Y + y) * width + x) * 4 + 3] == 0, @"cut-out mesh takes no neighbouring pixels");
            }
        }
        // The documented turn maps every source pixel to its atlas pixel.
        const uint8_t *source = [images[i][@"pixels"] bytes];
        for (int y = 0; y < sh; y++) for (int x = 0; x < sw; x++) {
            const uint8_t *p = source + ((size_t)y * sw + x) * 4;
            if (!p[3]) continue;
            CGPoint a = PBTurnForward(CGPointMake(x + .5, y + .5), placeTurn[i], sw, sh);
            Require(memcmp(canvas + ((size_t)(Y + (int)floor(a.y)) * width + X + (int)floor(a.x)) * 4, p, 4) == 0, @"atlas pixel round trip");
        }
        NSMutableOrderedSet<NSNumber *> *bands = [NSMutableOrderedSet orderedSet];
        for (NSArray *corner in [left arrayByAddingObjectsFromArray:right]) [bands addObject:corner[0]];
        NSArray<NSNumber *> *ts = [bands.array sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *positions = [NSMutableArray array], *uvs = [NSMutableArray array], *triangles = [NSMutableArray array];
        for (NSUInteger k = 0; k < ts.count; k++) {
            double t = ts[k].doubleValue;
            for (NSArray *edge in @[left, right]) {
                CGPoint local = CGPointMake(PBEdgeAt(edge, t), t), s = PBTurnBack(local, placeTurn[i], sw, sh);
                [uvs addObject:@[@(PBRound3(X + local.x)), @(PBRound3(Y + local.y))]];
                [positions addObject:@[@(PBRound3(s.x)), @(PBRound3(s.y))]];
            }
            if (k) {
                NSUInteger a = 2 * (k - 1);
                [triangles addObjectsFromArray:@[@(a), @(a + 1), @(a + 3), @(a), @(a + 3), @(a + 2)]];
            }
        }
        [meshes addObject:@{@"positions": positions, @"uvs": uvs, @"triangles": triangles}];
    }
    for (NSMutableDictionary *entry in entries) {
        NSUInteger index = [entry[@"imageIndex"] unsignedIntegerValue];
        const PBOrientation *o = &orientations[index][placeTurn[index]];
        entry[@"rect"] = @[@(placeX[index]), @(placeY[index]), @(o->w), @(o->h)];
        entry[@"atlasRotation"] = @(placeTurn[index] * 90);
        entry[@"mesh"] = meshes[index];
        [entry removeObjectForKey:@"imageIndex"];
    }
    for (NSUInteger i = 0; i < count; i++) for (int turn = 0; turn < 4; turn++) PBFreeOrientation(&orientations[i][turn]);
    free(orientations); free(trialX); free(trialY); free(trialTurn); free(placeX); free(placeY); free(placeTurn);
    if (!output) {
        CGColorSpaceRelease(space);
        NSLog(@"Verified outline packing, cut-out meshes and pixel round trips for %@ (%d x %d, %.1f%% opaque)", table.identifier, width, height, 100. * opaque / ((double)width * height));
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
        @"format":@2,@"table":table.identifier,@"image":@"sprites.png",@"pixelsPerUnit":@(unit),
        @"canvas":@[@(width),@(height)],@"uniqueImages":@(count),@"gutter":@(PBAtlasGutter),
        @"opaqueCoverage":@((double)opaque/((double)width*height)),
        @"tableSize":@[@(table.size.x),@(table.size.y)],@"ballRadius":@(table.ballRadius),
        @"coordinates":@"rect: atlas bounding box of the stored (turned) image, top-left pixels. atlasRotation: degrees the image is stored turned anticlockwise. mesh.positions and pivotPixels: source image pixels, top-left, y down. mesh.uvs: atlas pixels, top-left. mesh.triangles: index triples. localBounds and position: table units, y up; rotation: radians",
        @"artwork":@"Alpha-trimmed, unscaled, full-opacity source shapes packed by outline, so bounding boxes may overlap: draw each sprite with its mesh, never by cropping its rect. Identical artwork shares a placement. Apply placement and live physics/rules separately. Floor is a solid colour.",
        @"sprites":entries
    };
    NSData *json=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    Require([json writeToFile:[output stringByAppendingPathComponent:@"sprites.json"] atomically:YES],@"atlas manifest write");
    NSLog(@"Exported %lu assemblies, %lu unique images: %@ (%d x %d, %.1f%% opaque)",(unsigned long)entries.count,(unsigned long)count,png,width,height,100.*opaque/((double)width*height));
}
