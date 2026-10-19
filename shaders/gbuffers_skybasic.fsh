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
uniform int renderStage;

// Iris injects MC_RENDER_STAGE_*; fallbacks (Iris 1.7 ordinals) only serve the
// offline validator and preview, which never draw these stages.
#ifndef MC_RENDER_STAGE_SUNSET
    #define MC_RENDER_STAGE_SUNSET 2
#endif
#ifndef MC_RENDER_STAGE_STARS
    #define MC_RENDER_STAGE_STARS 6
#endif

/* RENDERTARGETS: 0,1 */
layout(location = 0) out vec4 aureliaSceneColor;
// Open-sky marker for deferred.fsh, which paints the cloud layer only where
// the dome is still visible after the opaque world is drawn. (0, 0, 0, 1)
// decodes to flags 255, which aureliaEncodeGbuffer never writes (max 248),
// and alpha 1 survives Iris's sky blend state either way.
layout(location = 1) out vec4 aureliaSkyMarker;

void main() {
    // Vanilla's star quads are drawn ADDITIVELY through this program, so
    // writing the sky colour there stacked a second copy of the dome on every
    // star: bright dots in a daylight/sunset sky (seen in game at time 12000).
    // The sunrise fan is likewise redundant. The analytic dome already holds
    // both, so neither draw contributes anything.
    if (renderStage == MC_RENDER_STAGE_STARS || renderStage == MC_RENDER_STAGE_SUNSET) discard;
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

    // Phase 5: the physical sky (lib/atmosphere.glsl LUT, baked once per
    // frame by prepare.fsh) plus the sun, moon and stars (lib/sky.glsl).
    // One bilinear fetch per pixel for the dome itself.
    vec3 sky = aureliaSkyView(direction, rainStrength);

    // The painted cloud layer is added in deferred.fsh, on the sky pixels the
    // world leaves visible (lib/clouds2d.glsl).
    bool openSky = !hasCeiling;

    // Nether (hasCeiling): no sun-driven atmosphere and no celestial bodies,
    // only Minecraft's own fog colour (see lib/sky.glsl). Covers both paths.
    if (hasCeiling) {
        sky = fogColorLinear * AURELIA_NETHER_FOG_SCALE;
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
        openSky = false;
    }
#endif

    // BOTH paths own their RGB: the ramp is built from Iris's sky/fog colours,
    // which already carry time, biome and weather. Multiplying by the sky
    // mesh's vertex colour re-applied Minecraft's per-draw tinting a second
    // time - the same geometry-only state that split the analytic sky - and on
    // this fallback it multiplied the ramp by the near-black night vertex
    // colour, crushing Potato nights to black. Alpha stays 1.0: opaque sky.
    aureliaSceneColor = vec4(sky, 1.0);
    aureliaSkyMarker = openSky ? vec4(0.0, 0.0, 0.0, 1.0) : vec4(0.0);
#endif
}
