#pragma once
#include <simd/simd.h>

/// Passive elastic shape in table axes (x, up-table y, height z). Collision
/// geometry stays spherical; this state never feeds back into the solver.
typedef struct {
    simd_float3x3 strain;
    simd_float3x3 velocity;
    simd_float3 contactNormal;
} PBSoftBall;

/// Zero-initialised state is a round ball. Tiny resting contacts are ignored.
void PBSoftBallHit(PBSoftBall *ball, simd_float3 normal, float closingSpeed);
void PBSoftBallAdvance(PBSoftBall *ball, float seconds);
/// Positive, volume-preserving elastic transform, independent of rolling rotation.
simd_float3x3 PBSoftBallShape(PBSoftBall ball);
/// Half-extent of the deformed unit sphere along a plane normal.
float PBSoftBallSupport(simd_float3x3 shape, simd_float3 normal);
