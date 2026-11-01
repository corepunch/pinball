//
//  PBGeometry.m
//

#import "PBGeometry.h"

/// Accumulates an indexed triangle mesh and hands it to SceneKit.
@interface PBMeshBuilder : NSObject
- (uint32_t)addPosition:(simd_float3)position normal:(simd_float3)normal uv:(simd_float2)uv;
- (void)addQuad:(uint32_t)a :(uint32_t)b :(uint32_t)c :(uint32_t)d;
- (SCNGeometry *)geometry;
@end

@implementation PBMeshBuilder {
    NSMutableData *_positions, *_normals, *_uvs, *_indices;
    uint32_t _count;
}
- (instancetype)init {
    if ((self = [super init])) {
        _positions = [NSMutableData data];
        _normals = [NSMutableData data];
        _uvs = [NSMutableData data];
        _indices = [NSMutableData data];
    }
    return self;
}
- (uint32_t)addPosition:(simd_float3)p normal:(simd_float3)n uv:(simd_float2)uv {
    float position[3] = { p.x, p.y, p.z };
    float normal[3] = { n.x, n.y, n.z };
    float texcoord[2] = { uv.x, uv.y };
    [_positions appendBytes:position length:sizeof(position)];
    [_normals appendBytes:normal length:sizeof(normal)];
    [_uvs appendBytes:texcoord length:sizeof(texcoord)];
    return _count++;
}
- (void)addQuad:(uint32_t)a :(uint32_t)b :(uint32_t)c :(uint32_t)d {
    uint32_t tris[6] = { a, b, c, a, c, d };
    [_indices appendBytes:tris length:sizeof(tris)];
}
- (SCNGeometry *)geometry {
    SCNGeometrySource *positions = [SCNGeometrySource geometrySourceWithData:_positions semantic:SCNGeometrySourceSemanticVertex vectorCount:_count floatComponents:YES componentsPerVector:3 bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(float) * 3];
    SCNGeometrySource *normals = [SCNGeometrySource geometrySourceWithData:_normals semantic:SCNGeometrySourceSemanticNormal vectorCount:_count floatComponents:YES componentsPerVector:3 bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(float) * 3];
    SCNGeometrySource *uvs = [SCNGeometrySource geometrySourceWithData:_uvs semantic:SCNGeometrySourceSemanticTexcoord vectorCount:_count floatComponents:YES componentsPerVector:2 bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(float) * 2];
    SCNGeometryElement *element = [SCNGeometryElement geometryElementWithData:_indices primitiveType:SCNGeometryPrimitiveTypeTriangles primitiveCount:(NSInteger)(_indices.length / sizeof(uint32_t) / 3) bytesPerIndex:sizeof(uint32_t)];
    return [SCNGeometry geometryWithSources:@[positions, normals, uvs] elements:@[element]];
}
@end

static inline simd_float3 PBToScene(simd_float2 size, float x, float y, float h) {
    return simd_make_float3(x - size.x * 0.5f, h, -(y - size.y * 0.5f));
}

@implementation PBGeometry

+ (SCNGeometry *)latheWithProfile:(const simd_float2 *)profile count:(NSInteger)count segments:(NSInteger)segments {
    PBMeshBuilder *mesh = [PBMeshBuilder new];
    float maxRadius = 1e-4f;
    for (NSInteger i = 0; i < count; i++) maxRadius = MAX(maxRadius, profile[i].x);
    // Duplicate each profile point per edge, so creases in the profile stay crisp.
    uint32_t base = 0;
    for (NSInteger p = 0; p + 1 < count; p++) {
        simd_float2 a = profile[p], b = profile[p + 1];
        simd_float2 edge = simd_normalize(b - a);
        simd_float2 outward = simd_make_float2(edge.y, -edge.x);
        for (NSInteger s = 0; s <= segments; s++) {
            float angle = 2.0f * (float)M_PI * (float)s / (float)segments;
            float cs = cosf(angle), sn = sinf(angle);
            simd_float3 normal = simd_make_float3(outward.x * cs, outward.y, outward.x * sn);
            simd_float2 uvA = simd_make_float2(0.5f + 0.5f * a.x / maxRadius * cs, 0.5f + 0.5f * a.x / maxRadius * sn);
            simd_float2 uvB = simd_make_float2(0.5f + 0.5f * b.x / maxRadius * cs, 0.5f + 0.5f * b.x / maxRadius * sn);
            [mesh addPosition:simd_make_float3(a.x * cs, a.y, a.x * sn) normal:normal uv:uvA];
            [mesh addPosition:simd_make_float3(b.x * cs, b.y, b.x * sn) normal:normal uv:uvB];
        }
        for (NSInteger s = 0; s < segments; s++) {
            uint32_t i = base + (uint32_t)s * 2;
            [mesh addQuad:i :i + 1 :i + 3 :i + 2];
        }
        base += (uint32_t)(segments + 1) * 2;
    }
    return [mesh geometry];
}

+ (SCNGeometry *)tubeAlongPoints:(const SCNVector3 *)points count:(NSInteger)count radius:(float)radius sides:(NSInteger)sides {
    PBMeshBuilder *mesh = [PBMeshBuilder new];
    simd_float3 up = simd_make_float3(0.0f, 1.0f, 0.0f);
    float along = 0;
    for (NSInteger i = 0; i < count; i++) {
        simd_float3 p = simd_make_float3(points[i].x, points[i].y, points[i].z);
        simd_float3 prev = i > 0 ? simd_make_float3(points[i - 1].x, points[i - 1].y, points[i - 1].z) : p;
        simd_float3 next = i + 1 < count ? simd_make_float3(points[i + 1].x, points[i + 1].y, points[i + 1].z) : p;
        simd_float3 tangent = simd_normalize(next - prev);
        simd_float3 side = simd_cross(tangent, up);
        if (simd_length(side) < 1e-3f) side = simd_make_float3(1.0f, 0.0f, 0.0f);
        side = simd_normalize(side);
        simd_float3 lift = simd_normalize(simd_cross(side, tangent));
        if (i > 0) along += simd_distance(p, prev);
        for (NSInteger s = 0; s <= sides; s++) {
            float angle = 2.0f * (float)M_PI * (float)s / (float)sides;
            simd_float3 normal = side * cosf(angle) + lift * sinf(angle);
            [mesh addPosition:p + normal * radius normal:normal uv:simd_make_float2(along * 8.0f, (float)s / (float)sides)];
        }
    }
    uint32_t ring = (uint32_t)sides + 1;
    for (uint32_t i = 0; i + 1 < (uint32_t)count; i++) {
        for (uint32_t s = 0; s < (uint32_t)sides; s++) {
            uint32_t a = i * ring + s, b = a + 1, c = a + ring + 1, d = a + ring;
            [mesh addQuad:a :b :c :d];
        }
    }
    return [mesh geometry];
}

+ (SCNGeometry *)wallAlongPoints:(const simd_float2 *)points count:(NSInteger)count closed:(BOOL)closed
                       halfWidth:(float)halfWidth height:(float)height tableSize:(simd_float2)size {
    PBMeshBuilder *mesh = [PBMeshBuilder new];
    float bevel = MIN(halfWidth * 0.5f, 0.002f);
    NSInteger joints = closed ? count + 1 : count;

    simd_float2 (^jointNormal)(NSInteger) = ^simd_float2(NSInteger index) {
        NSInteger i = closed ? index % count : index;
        simd_float2 p = points[i];
        simd_float2 prev = (i > 0) ? points[i - 1] : (closed ? points[count - 1] : p);
        simd_float2 next = (i + 1 < count) ? points[i + 1] : (closed ? points[0] : p);
        simd_float2 inDir = simd_length(p - prev) > 1e-5f ? simd_normalize(p - prev) : simd_normalize(next - p);
        simd_float2 outDir = simd_length(next - p) > 1e-5f ? simd_normalize(next - p) : inDir;
        simd_float2 nIn = simd_make_float2(-inDir.y, inDir.x), nOut = simd_make_float2(-outDir.y, outDir.x);
        simd_float2 miter = nIn + nOut;
        float length = simd_length(miter);
        if (length < 1e-3f) return nOut;
        miter /= length;
        float scale = 1.0f / MAX(simd_dot(miter, nOut), 0.45f);
        return miter * scale;
    };

    // Cross-section, walking over the wall from one foot to the other: left side, left
    // bevel, top, right bevel, right side. Each band has its own vertices for hard edges.
    typedef struct { float offset, h, nx, ny; } PBSection;
    float w = halfWidth;
    PBSection section[10] = {
        { w, 0.0f, 1, 0 }, { w, height - bevel, 1, 0 },
        { w, height - bevel, 0.707f, 0.707f }, { w - bevel, height, 0.707f, 0.707f },
        { w - bevel, height, 0, 1 }, { -w + bevel, height, 0, 1 },
        { -w + bevel, height, -0.707f, 0.707f }, { -w, height - bevel, -0.707f, 0.707f },
        { -w, height - bevel, -1, 0 }, { -w, 0.0f, -1, 0 },
    };

    float along = 0;
    simd_float2 previous = points[0];
    for (NSInteger j = 0; j < joints; j++) {
        NSInteger i = closed ? j % count : j;
        simd_float2 p = points[i];
        along += simd_distance(p, previous);
        previous = p;
        simd_float2 n = jointNormal(j);
        simd_float2 unit = simd_length(n) > 1e-4f ? simd_normalize(n) : simd_make_float2(0.0f, 1.0f);
        for (NSInteger s = 0; s < 10; s++) {
            simd_float2 at = p + n * section[s].offset;
            simd_float3 normal = simd_make_float3(unit.x * section[s].nx, section[s].ny, -unit.y * section[s].nx);
            // Tile in table units: one texture repeat per 0.25 table widths.
            [mesh addPosition:PBToScene(size, at.x, at.y, section[s].h) normal:normal
                           uv:simd_make_float2(along * 4.0f, 0.5f + section[s].offset * 4.0f)];
        }
    }
    for (uint32_t j = 0; j + 1 < (uint32_t)joints; j++) {
        for (uint32_t s = 0; s < 10; s += 2) {
            uint32_t a = j * 10 + s, b = a + 1, c = a + 11, d = a + 10;
            [mesh addQuad:a :b :c :d];
        }
    }
    return [mesh geometry];
}

+ (SCNGeometry *)rampFromPoints:(const simd_float3 *)points count:(NSInteger)count width:(float)width
                      sideHeight:(float)sideHeight tableSize:(simd_float2)size {
    PBMeshBuilder *mesh = [PBMeshBuilder new];
    float half = width * 0.5f + 0.004f;
    float along = 0;
    for (NSInteger i = 0; i < count; i++) {
        simd_float3 p = points[i];
        simd_float3 prev = points[MAX(i - 1, 0)], next = points[MIN(i + 1, count - 1)];
        simd_float2 tangent = simd_normalize(next.xy - prev.xy);
        simd_float2 normal = simd_make_float2(-tangent.y, tangent.x);
        if (i > 0) along += simd_distance(p, prev);
        simd_float2 left = p.xy + normal * half, right = p.xy - normal * half;
        float v = along * 2.2f;
        simd_float3 up = simd_make_float3(0.0f, 1.0f, 0.0f);
        simd_float3 outwardL = simd_make_float3(normal.x, 0.0f, -normal.y);

        // Floor (0, 1), then the two low sides (2-3, 4-5).
        [mesh addPosition:PBToScene(size, left.x, left.y, p.z) normal:up uv:simd_make_float2(0.0f, -v)];
        [mesh addPosition:PBToScene(size, right.x, right.y, p.z) normal:up uv:simd_make_float2(1.0f, -v)];
        [mesh addPosition:PBToScene(size, left.x, left.y, p.z) normal:-outwardL uv:simd_make_float2(0.0f, -v)];
        [mesh addPosition:PBToScene(size, left.x, left.y, p.z + sideHeight) normal:-outwardL uv:simd_make_float2(0.05f, -v)];
        [mesh addPosition:PBToScene(size, right.x, right.y, p.z) normal:outwardL uv:simd_make_float2(1.0f, -v)];
        [mesh addPosition:PBToScene(size, right.x, right.y, p.z + sideHeight) normal:outwardL uv:simd_make_float2(0.95f, -v)];
    }
    for (uint32_t i = 0; i + 1 < (uint32_t)count; i++) {
        uint32_t row = i * 6, next = row + 6;
        [mesh addQuad:row :next :next + 1 :row + 1];
        [mesh addQuad:row + 2 :row + 3 :next + 3 :next + 2];
        [mesh addQuad:row + 4 :next + 4 :next + 5 :row + 5];
    }
    SCNGeometry *geometry = [mesh geometry];
    return geometry;
}

+ (SCNGeometry *)prismWithPath:(PBBezierPath *)path height:(float)height chamfer:(float)chamfer {
    SCNShape *shape = [SCNShape shapeWithPath:path extrusionDepth:height];
    shape.chamferMode = SCNChamferModeFront;
    shape.chamferRadius = chamfer;
    return shape;
}

+ (PBBezierPath *)pathFromPoints:(const simd_float2 *)points count:(NSInteger)count {
    PBBezierPath *path = [PBBezierPath bezierPath];
    path.flatness = 0.001;
    [path moveToPoint:CGPointMake(points[0].x, points[0].y)];
    for (NSInteger i = 1; i < count; i++) PBBezierLineTo(path, CGPointMake(points[i].x, points[i].y));
    [path closePath];
    return path;
}

+ (SCNGeometry *)flipperWithLength:(float)length baseRadius:(float)baseRadius tipRadius:(float)tipRadius height:(float)height {
    // Outline with the taper's tangent points, so sides meet the end arcs smoothly.
    const NSInteger arcSegments = 10;
    float tilt = asinf((baseRadius - tipRadius) / length);
    NSInteger count = (arcSegments + 1) * 2;
    simd_float2 *outline = calloc((size_t)count, sizeof(simd_float2));
    NSInteger n = 0;
    for (NSInteger i = 0; i <= arcSegments; i++) {
        float angle = (float)M_PI_2 - tilt + ((float)M_PI + 2.0f * tilt) * (float)i / (float)arcSegments;
        outline[n++] = simd_make_float2(cosf(angle), sinf(angle)) * baseRadius;
    }
    for (NSInteger i = 0; i <= arcSegments; i++) {
        float angle = -(float)M_PI_2 + tilt + ((float)M_PI - 2.0f * tilt) * (float)i / (float)arcSegments;
        outline[n++] = simd_make_float2(length + cosf(angle) * tipRadius, sinf(angle) * tipRadius);
    }
    PBBezierPath *path = [self pathFromPoints:outline count:n];
    free(outline);
    return [self prismWithPath:path height:height chamfer:0.003f];
}

@end
