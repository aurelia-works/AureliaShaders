#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/color.glsl"

// sunPosition, not shadowLightPosition. Iris documents shadowLightPosition as
// the *highest* celestial body, which is the moon at night, so deriving a sky
// term from it made the horizon haze follow the moon after sunset and left this
// file disagreeing with lib/lighting.glsl, which keeps daylight on sunPosition.
// sunPosition is the same view-space vector the forward passes use, so it is
// transformed by the same mat3(gbufferModelViewInverse) before any .y is read:
// reading the view-space component directly would make the gradient track camera
// pitch instead of the sun.
uniform vec3 sunPosition;
uniform vec3 skyColor;
uniform vec3 fogColor;
uniform float rainStrength;
uniform mat4 gbufferModelViewInverse;

in vec4 vertexColor;
in vec3 viewDirection;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
#if AURELIA_DEBUG_VIEW == 5
    // The analytical sky is outside the shadow receiver set.
    aureliaSceneColor = vec4(1.0);
#else
    // Iris/Minecraft supplies time-, biome-, and weather-aware colours in sRGB
    // encoding, but as single values with no directionality. Without a gradient
    // the whole upper frame is one flat colour, which is the most obvious
    // giveaway of a pack that never treats its sky.
    vec3 skyColorLinear = aureliaSrgbToLinear(skyColor);
    vec3 fogColorLinear = aureliaSrgbToLinear(fogColor);

    vec3 direction = normalize(viewDirection);
    float elevation = clamp(direction.y, -1.0, 1.0);

    // The horizon has to agree with what aureliaApplyFog resolves to at maximum
    // distance, or the far edge of the world shows a seam against the sky.
    // fogColor is exactly that colour, so it anchors the bottom of the ramp.
    vec3 horizon = fogColorLinear;
    // Zenith deepens rather than darkens: the ramp keeps more of the sky's own
    // hue overhead so a saturated sky does not turn into a flat dark cap.
    // Keep the offset small and neutral so Potato outdoor sky does not go
    // neon-blue while terrain stays dark (Complementary keeps one smooth ramp).
    vec3 zenith = skyColorLinear * 0.82 + vec3(0.010, 0.020, 0.040);
    float ramp = smoothstep(-0.06, 0.62, elevation);
    vec3 sky = mix(horizon, zenith, ramp);

    // A broad glow around the sun's azimuth, strongest when the sun is low. This
    // is the atmosphere, not the disc: the sun and moon themselves are Minecraft
    // textures drawn by gbuffers_skytextured, so an analytic disc here would
    // double them. Two cosines and a smoothstep, no texture read.
    vec3 lightDirection = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    vec2 viewAzimuth = direction.xz;
    vec2 lightAzimuth = lightDirection.xz;
    float azimuthLength = length(viewAzimuth) * length(lightAzimuth);
    float toward = azimuthLength > 1e-4
        ? max(dot(viewAzimuth, lightAzimuth) / azimuthLength, 0.0)
        : 0.0;
    toward = pow(toward, 3.0);
    float lowSun = 1.0 - smoothstep(0.0, 0.34, abs(lightDirection.y));
    vec3 glowColor = mix(vec3(1.00, 0.72, 0.42), vec3(1.00, 0.90, 0.74), smoothstep(0.0, 0.30, lightDirection.y));
    sky += glowColor * (toward * lowSun * 0.34 * (1.0 - ramp * 0.65)) * (1.0 - 0.55 * rainStrength);

    // Rain flattens the ramp toward the fog colour, which is what an overcast
    // sky does, instead of leaving a clear gradient over a dimmed sun.
    sky = mix(sky, fogColorLinear, 0.45 * rainStrength);

    float luma = dot(sky, vec3(0.2126, 0.7152, 0.0722));
    sky = mix(vec3(luma), sky, 1.00);
    aureliaSceneColor = vec4(sky * aureliaSrgbToLinear(vertexColor.rgb), 1.0);
#endif
}
