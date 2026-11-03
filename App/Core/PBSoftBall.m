#import "PBSoftBall.h"
#include <math.h>

static float PBNormSquared(simd_float3x3 matrix) {
    float sum = 0;
    for (int i = 0; i < 3; i++) sum += simd_length_squared(matrix.columns[i]);
    return sum;
}

static void PBLimitSoftBall(PBSoftBall *ball) {
    // Keeps every principal stretch positive, including simultaneous contacts.
    // A strong isolated hit compresses about 25%, with a smaller lateral bulge.
    float length = sqrtf(PBNormSquared(ball->strain));
    if (length > .32f) {
        float scale = .32f / length;
        for (int i = 0; i < 3; i++) {
            ball->strain.columns[i] *= scale;
            ball->velocity.columns[i] *= scale;
        }
    }
    float rate = sqrtf(PBNormSquared(ball->velocity));
    if (rate > 12) for (int i = 0; i < 3; i++) ball->velocity.columns[i] *= 12 / rate;
}

void PBSoftBallHit(PBSoftBall *ball, simd_float3 normal, float speed) {
    float length = simd_length(normal);
    if (!isfinite(speed) || speed <= .18f || !isfinite(length) || length < 1e-6f) return;
    normal /= length;
    float amplitude = .30f * (1 - expf(-(speed - .18f) / 1.25f));
    // A traceless strain: squash toward the contact, spread across both other axes.
    // Matrices let oblique/rapid contacts blend without snapping a single scale axis.
    for (int i = 0; i < 3; i++) {
        simd_float3 mode = .5f * matrix_identity_float3x3.columns[i] - 1.5f * normal * normal[i];
        ball->strain.columns[i] += mode * amplitude;
        ball->velocity.columns[i] += mode * amplitude * 4;
    }
    ball->contactNormal = normal;
    PBLimitSoftBall(ball);
}

void PBSoftBallAdvance(PBSoftBall *ball, float seconds) {
    if (!isfinite(seconds) || seconds <= 0) return;
    if (PBNormSquared(ball->strain) == 0 && PBNormSquared(ball->velocity) == 0) return;
    // Exact underdamped spring solution: no frame-rate dependent Euler wobble.
    // Readable at gameplay size and 60 Hz: compression lasts around 0.14 s,
    // followed by a small rebound. The old 48/22 spring lost its squash within
    // 0.05 s and was only obvious in the enlarged 4x slow-motion preview.
    const float omega = 20, damping = 12;
    float frequency = sqrtf(omega * omega - damping * damping);
    float decay = expf(-damping * seconds);
    float c = cosf(frequency * seconds), s = sinf(frequency * seconds) / frequency;
    for (int i = 0; i < 3; i++) {
        simd_float3 q = ball->strain.columns[i], v = ball->velocity.columns[i];
        ball->strain.columns[i] = decay * (q * c + (v + damping * q) * s);
        ball->velocity.columns[i] = decay * (v * c - (damping * v + omega * omega * q) * s);
    }
    PBLimitSoftBall(ball);
    if (PBNormSquared(ball->strain) < 1e-10f && PBNormSquared(ball->velocity) < 1e-8f) *ball = (PBSoftBall){0};
}

simd_float3x3 PBSoftBallShape(PBSoftBall ball) {
    simd_float3x3 shape = matrix_identity_float3x3;
    for (int i = 0; i < 3; i++) shape.columns[i] += ball.strain.columns[i];
    // Exact constant volume after the linear strain, including compound contacts.
    float volume = simd_determinant(shape);
    float scale = 1 / cbrtf(volume);
    for (int i = 0; i < 3; i++) shape.columns[i] *= scale;
    return shape;
}

float PBSoftBallSupport(simd_float3x3 shape, simd_float3 normal) {
    return simd_length(simd_mul(simd_transpose(shape), normal));
}
