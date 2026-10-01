#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>

uniform sampler2D Sampler0;

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
in vec4 vertexColor;
in vec4 lightMapColor;
in vec4 overlayColor;
in vec2 texCoord0;

out vec4 fragColor;

void main() {
    vec4 color = texture(Sampler0, texCoord0);
#ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
#endif

    color *= vertexColor * ColorModulator;
    // Eagler 26.2 web robustness guard (see entity.fsh): a mis-delivered integer UV1 overlay
    // coord on some real-GPU backends samples the overlay's neutral white no-hurt band with
    // alpha < 1 and washes the item white. Only apply the overlay where it is a COLORED (red
    // hurt) tint; treat the neutral white band as a strict no-op. Keeps the red hurt-flash.
    float overlayChroma = max(overlayColor.r, max(overlayColor.g, overlayColor.b))
                        - min(overlayColor.r, min(overlayColor.g, overlayColor.b));
    float overlayAmount = mix(1.0, overlayColor.a, step(0.04, overlayChroma));
    color.rgb = mix(overlayColor.rgb, color.rgb, overlayAmount);
    color *= lightMapColor;

    fragColor = apply_fog(color, sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogColor);
}
