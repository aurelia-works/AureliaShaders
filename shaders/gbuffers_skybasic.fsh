#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/color.glsl"

uniform vec3 skyColor;
uniform vec3 fogColor;
uniform vec3 shadowLightPosition;
uniform float rainStrength;

in vec4 vertexColor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
#if AURELIA_DEBUG_VIEW == 5
    // The analytical sky is outside the shadow receiver set.
    aureliaSceneColor = vec4(1.0);
#else
    // Iris/Minecraft supplies time- and weather-aware sky colours. Preserve that
    // work and only add a restrained saturation/horizon treatment here.
    // Iris/Minecraft supplies these time-, biome-, and weather-aware colors
    // in sRGB encoding. Decode before luminance, tinting, and fog blending.
    vec3 skyColorLinear = aureliaSrgbToLinear(skyColor);
    vec3 fogColorLinear = aureliaSrgbToLinear(fogColor);
    float luma = dot(skyColorLinear, vec3(0.2126, 0.7152, 0.0722));
    vec3 sky = mix(vec3(luma), skyColorLinear, 1.08);
    float horizon = clamp(1.0 - abs(normalize(shadowLightPosition).y), 0.0, 1.0);
    sky = mix(sky, fogColorLinear, 0.12 * horizon * (0.35 + rainStrength));
    aureliaSceneColor = vec4(sky * aureliaSrgbToLinear(vertexColor.rgb), 1.0);
#endif
}
