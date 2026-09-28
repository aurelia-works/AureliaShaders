#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/color.glsl"
#include "/lib/look.glsl"

// sunPosition, not shadowLightPosition. Iris documents shadowLightPosition as
// the *highest* celestial body, which is the moon at night, so deriving a sky
// term from it made the horizon haze follow the moon after sunset and left this
// file disagreeing with lib/lighting.glsl, which keeps daylight on sunPosition.
// sunPosition is view space; aureliaSunDirection() in lib/look.glsl rotates it
// to world space, so no view-space component is read directly here.

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
    // fogColor is exactly that colour, so it anchors the bottom of the ramp,
    // through the named contract helper so sky and fog cannot drift apart.
    vec3 horizon = aureliaHorizonColor(fogColorLinear);
    // Zenith deepens rather than darkens: the ramp keeps more of the sky's own
    // hue overhead so a saturated sky does not turn into a flat dark cap.
    // The scale and offset are the contract's PROVISIONAL zenith starting
    // definition (lib/look.glsl); P3.1 replaces the shape.
    vec3 zenith = aureliaZenithColor(skyColorLinear);
    float ramp = smoothstep(-0.06, 0.62, elevation);
    vec3 sky = mix(horizon, zenith, ramp);

    // A broad glow around the sun's azimuth, strongest when the sun is low. This
    // is the atmosphere, not the disc: the sun and moon themselves are Minecraft
    // textures drawn by gbuffers_skytextured, so an analytic disc here would
    // double them. Two cosines and a smoothstep, no texture read.
    vec3 lightDirection = aureliaSunDirection();
    vec2 viewAzimuth = direction.xz;
    vec2 lightAzimuth = lightDirection.xz;
    float azimuthLength = length(viewAzimuth) * length(lightAzimuth);
    float toward = azimuthLength > 1e-4
        ? max(dot(viewAzimuth, lightAzimuth) / azimuthLength, 0.0)
        : 0.0;
    toward = pow(toward, 3.0);
    float lowSun = 1.0 - smoothstep(0.0, 0.34, abs(lightDirection.y));
    vec3 glowColor = mix(vec3(1.00, 0.72, 0.42), vec3(1.00, 0.90, 0.74), smoothstep(0.0, 0.30, lightDirection.y));
    sky += glowColor * (toward * lowSun * 0.34 * (1.0 - ramp * 0.65)) * (1.0 - AURELIA_RAIN_GLOW_DIM * rainStrength);

    // Rain flattens the ramp toward the fog colour, which is what an overcast
    // sky does, instead of leaving a clear gradient over a dimmed sun.
    sky = mix(sky, fogColorLinear, AURELIA_RAIN_SKY_FLATTEN * rainStrength);

    float luma = dot(sky, vec3(0.2126, 0.7152, 0.0722));
    sky = mix(vec3(luma), sky, 1.00);
    aureliaSceneColor = vec4(sky * aureliaSrgbToLinear(vertexColor.rgb), 1.0);
#endif
}
