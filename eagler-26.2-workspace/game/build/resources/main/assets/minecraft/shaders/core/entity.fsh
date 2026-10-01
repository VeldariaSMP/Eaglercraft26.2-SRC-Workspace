#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>

uniform sampler2D Sampler0;

#ifdef DISSOLVE
uniform sampler2D DissolveMaskSampler;
#endif

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
#ifdef PER_FACE_LIGHTING
in vec4 vertexPerFaceColorBack;
in vec4 vertexPerFaceColorFront;
#else
in vec4 vertexColor;
#endif

#ifndef EMISSIVE
in vec4 lightMapColor;
#endif

#ifndef NO_OVERLAY
in vec4 overlayColor;
#endif

in vec2 texCoord0;

out vec4 fragColor;

void main() {
    // Entity and skin textures are uploaded with exactly one mip level. Some WebGL2
    // drivers still derive a positive implicit LOD for a small on-screen mob before
    // applying the sampler clamp, which smears or drops one-pixel facial details.
    // Sampling the only level explicitly is exact and keeps vanilla pixels crisp.
    vec4 color = textureLod(Sampler0, texCoord0, 0.0);
#ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
#endif

#ifdef PER_FACE_LIGHTING
    vec4 faceVertexColor = gl_FrontFacing ? vertexPerFaceColorFront : vertexPerFaceColorBack;
#else
    vec4 faceVertexColor = vertexColor;
#endif

#ifdef DISSOLVE
    if (faceVertexColor.a < texture(DissolveMaskSampler, texCoord0).a) {
        discard;
    }
    // The dissolve effect entirely replaces translucency
    faceVertexColor.a = 1.0;
#endif

    color *= faceVertexColor * ColorModulator;
#ifndef NO_OVERLAY
    // Eagler 26.2 web robustness guard (entity "white blob" fix): on some real-GPU WebGL2
    // backends (ANGLE-D3D11 / Metal) the integer UV1 overlay coordinate can be mis-delivered,
    // making texelFetch sample the OverlayTexture's NEUTRAL WHITE "no-hurt" band with alpha < 1.
    // The unguarded mix then blends the whole entity toward white -> untextured "white blob"
    // mobs (terrain is unaffected: it has no overlay). Only let the overlay tint the model where
    // the sample is actually COLORED (the red hurt-flash); treat the neutral white/grey band as a
    // strict no-op, so a bad UV1 can never white-wash the texture. The common non-hurt case
    // (UV1.u == 0 -> overlay alpha 1.0) is already a no-op on every backend, so desktop/correct
    // hardware is unchanged for it; the red hurt-flash is fully preserved. Only cost: the rarely
    // seen white spawn/charge flash (u > 0 white band) is dropped in favor of correct textures.
    float overlayChroma = max(overlayColor.r, max(overlayColor.g, overlayColor.b))
                        - min(overlayColor.r, min(overlayColor.g, overlayColor.b));
    float overlayAmount = mix(1.0, overlayColor.a, step(0.04, overlayChroma));
    color.rgb = mix(overlayColor.rgb, color.rgb, overlayAmount);
#endif
#ifndef EMISSIVE
    color *= lightMapColor;
#endif

    fragColor = apply_fog(color, sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogColor);
}
