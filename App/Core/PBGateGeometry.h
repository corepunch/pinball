#pragma once
#include <math.h>
#include <simd/simd.h>

/// A door hinged at endpoint a, turning in the table plane toward passDirection.
typedef struct {
    float wireRadius, barHeight, maxAngle;
} PBGateGeometry;

static inline PBGateGeometry PBGateGeometryMake(float ballRadius) {
    return (PBGateGeometry){.wireRadius = .0075f, .barHeight = ballRadius * (2.0f / 3.0f), .maxAngle = 1.48f};
}

static inline float PBGateOpeningSign(simd_float2 a, simd_float2 b, simd_float2 passDirection) {
    simd_float2 edge = b - a;
    return simd_dot(simd_make_float2(-edge.y, edge.x), passDirection) < 0 ? -1 : 1;
}

static inline simd_float2 PBGateTip(simd_float2 a, simd_float2 b, simd_float2 passDirection, float angle) {
    simd_float2 edge = b - a;
    float turn = angle * PBGateOpeningSign(a, b, passDirection), c = cosf(turn), s = sinf(turn);
    return a + simd_make_float2(edge.x * c - edge.y * s, edge.x * s + edge.y * c);
}
