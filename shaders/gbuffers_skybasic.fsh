#version 330 compatibility

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/sky.glsl"

// sunPosition, not shadowLightPosition. Iris documents shadowLightPosition as
// the *highest* celestial body, which is the moon at night, so deriving a sky
// term from it made the horizon haze follow the moon after sunset and left this
// file disagreeing with lib/lighting.glsl, which keeps daylight on sunPosition.
// sunPosition is view space; aureliaSunDirection() in lib/look.glsl rotates it
// to world space, so no view-space component is read directly here.

uniform mat4 gbufferProjectionInverse;
uniform float viewWidth;
uniform float viewHeight;

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
    vec3 skyColorLinear = aureliaSkyColorLinear();
    vec3 fogColorLinear = aureliaFogColorLinear();
    // The view ray is rebuilt from the pixel, not from the sky geometry, and
    // at a FIXED far-plane depth. Minecraft rotates the sky DOME by the
    // celestial angle while the void plane below it is drawn unrotated, so a
    // direction read off the geometry disagrees between the two draw calls (a
    // hard seam across the horizon) and disagrees with sunPosition (the disc
    // lands away from the real sun). The depth passed to the unprojection is
    // pinned to NDC 1.0 (the far plane): gl_FragCoord.z is the depth of
    // whichever sky piece covered the pixel, and the dome and the void plane
    // sit at different camera distances, so letting the geometry's depth into
    // the unprojection tilted the ray differently per draw call. The
    // convention was verified against this pack's own projection: the inverse
    // of the standard GL perspective maps vec4(ndc.xy, 1.0, 1.0) to the
    // far-plane point on that pixel's ray (view space looks down -z), so
    // normalising after the w-divide yields the same camera ray for every
    // pixel of every sky draw.
    vec2 skyNdc = (gl_FragCoord.xy / vec2(viewWidth, viewHeight)) * 2.0 - 1.0;
    vec4 skyRayView = gbufferProjectionInverse * vec4(skyNdc, 1.0, 1.0);
    skyRayView /= skyRayView.w;
    vec3 direction = normalize((gbufferModelViewInverse * vec4(skyRayView.xyz, 0.0)).xyz);

#ifdef AURELIA_ATMOSPHERE
    // Directional atmosphere: see lib/sky.glsl. ALU only, no texture or target.
    // The sun and moon discs are analytic (lib/sky.glsl), so Minecraft's square
    // sun/moon textures are suppressed here rather than stacked on top.
    vec3 sky = aureliaAtmosphereSky(
        skyColorLinear, fogColorLinear, direction,
        aureliaSunDirection(), aureliaMoonDirection(), rainStrength);
#else
    // Revertible fallback: the flat analytical ramp used before P3.1.
    float elevation = clamp(direction.y, -1.0, 1.0);

    // The horizon has to agree with what aureliaApplyFog resolves to at maximum
    // distance, or the far edge of the world shows a seam against the sky.
    // fogColor is exactly that colour, so it anchors the bottom of the ramp,
    // through the named contract helper so sky and fog cannot drift apart.
    vec3 horizon = aureliaHorizonColor(fogColorLinear);
    // Zenith deepens rather than darkens: the ramp keeps more of the sky's own
    // hue overhead so a saturated sky does not turn into a flat dark cap.
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

    // The shared celestial bodies, so Potato keeps the same round sun, moon
    // and stars as the analytic presets instead of Minecraft's square
    // textures. ALU only: ~30 operations per sky pixel, no samplers, no
    // passes - negligible even on this preset's budget.
    float day = aureliaSunVisibility();
    float sunAlign = max(dot(direction, lightDirection), 0.0);
    sky = aureliaApplySunDisc(sky, sunAlign, day, rainStrength);
    sky = aureliaApplyMoon(sky, direction, aureliaMoonDirection(), day, rainStrength);
    sky = aureliaApplyStars(sky, direction, lightDirection.y, rainStrength);
#endif

    // Nether (hasCeiling): no sun-driven atmosphere and no celestial bodies,
    // only Minecraft's own fog colour (see lib/sky.glsl). Covers both paths.
    if (hasCeiling) {
        sky = fogColorLinear;
    }

#ifdef AURELIA_WATER_UNDERWATER
    // Submerged: the sky is seen through the water column, so background
    // pixels are the underwater atmosphere for this ray, not the air dome.
    // Replacing it here (rather than tinting the final image) keeps the
    // background, the translucent water surface's bleed-through and the
    // terrain fog all on the same palette. Gated on the runtime camera state,
    // so an above-water frame evaluates the accepted sky untouched.
    if (isEyeInWater == 1) {
        sky = aureliaUnderwaterColor(direction, rainStrength);
    }
#endif

    // BOTH paths own their RGB: the ramp is built from Iris's sky/fog colours,
    // which already carry time, biome and weather. Multiplying by the sky
    // mesh's vertex colour re-applied Minecraft's per-draw tinting a second
    // time - the same geometry-only state that split the analytic sky - and on
    // this fallback it multiplied the ramp by the near-black night vertex
    // colour, crushing Potato nights to black. Alpha stays 1.0: opaque sky.
    aureliaSceneColor = vec4(sky, 1.0);
#endif
}
