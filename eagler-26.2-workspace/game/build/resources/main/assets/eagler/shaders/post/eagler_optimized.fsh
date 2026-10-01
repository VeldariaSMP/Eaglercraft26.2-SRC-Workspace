#version 330

/*
 * Copyright (c) 2026 Eagler 26.2 contributors.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Eagler 26.2 Optimized is a small, original depth-aware post shader for the
 * regular client. It runs after the world transparency/weather passes and
 * before hands, screen overlays, spectator effects, and the GUI.
 *
 * This shader was independently written for the 26.2 renderer. The
 * EaglercraftX 1.8 deferred renderer was consulted for pipeline integration
 * concepts; no 1.8 deferred shader source is copied here.
 */

uniform sampler2D SceneSampler;
uniform sampler2D SceneDepthSampler;

in vec2 texCoord;

out vec4 fragColor;

void main() {
    vec4 scene = texture(SceneSampler, texCoord);

    // Minecraft 26.2 uses reverse Z and clears sky/no-geometry pixels to zero.
    // Comparisons also reject NaN depth values without propagating them.
    float sampledDepth = texture(SceneDepthSampler, texCoord).r;
    float depth = sampledDepth > 0.0 && sampledDepth <= 1.0 ? sampledDepth : 0.0;
    float geometry = step(0.000001, depth);

    // fwidth gives a cheap scene-depth discontinuity signal without sampling
    // neighbouring colors. Only the geometry side is shaded, preventing sky,
    // water, particle, and weather color halos around silhouettes.
    float relativeDepthSlope = fwidth(depth) / max(depth, 0.0001);
    float depthDetail = clamp(relativeDepthSlope * 0.65, 0.0, 1.0) * geometry;

    vec3 color = clamp(scene.rgb, 0.0, 1.0);
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    vec3 gentlySaturated = luma + (color - luma) * 1.035;
    vec3 softContrast = gentlySaturated * gentlySaturated * (3.0 - 2.0 * gentlySaturated);
    vec3 graded = mix(gentlySaturated, softContrast, 0.10);
    color = mix(color, graded, geometry);
    color *= 1.0 - depthDetail * 0.035;

    fragColor = vec4(clamp(color, 0.0, 1.0), scene.a);
}
