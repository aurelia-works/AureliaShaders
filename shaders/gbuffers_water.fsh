#version 330 compatibility

// Water surface. The shading lives behind AURELIA_WATER_SURFACE so it is
// revertible from the Iris options screen; with it off this is the plain
// gbuffers_terrain-equivalent fallback.
//
// Water is a shadow receiver only. shaders.properties keeps shadowTranslucent
// disabled, so this samples the shadow map but never enters the caster pass.
//
// No scene-colour read: gbuffers_water renders after deferred while writing
// colortex0, so sampling colortex0 is a feedback loop. The reflection is
// analytical. Under AURELIA_WATER_DEPTH / SHORE it also reads depthtex1, the
// pre-translucent opaque depth copy Iris takes in beginTranslucents (verified
// in the installed iris-1.7.6+mc1.20.1.jar) -- NOT depthtex0, which during
// translucents may hold the water surface itself.

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#include "/lib/lighting.glsl"
#include "/lib/debug.glsl"
#ifdef AURELIA_WATER_SURFACE
    #include "/lib/water.glsl"
#endif

uniform sampler2D gtexture;
uniform float alphaTestRef;

#if defined(AURELIA_WATER_DEPTH) || defined(AURELIA_WATER_SHORE)
    // depthtex1 is the pre-translucent opaque copy (see header); the shoreline
    // option reuses the same signal, so it is declared for either.
    uniform sampler2D depthtex1;
    uniform mat4 gbufferProjectionInverse;
    uniform float viewWidth;
    uniform float viewHeight;
#endif

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vertexColor;
in vec3 worldNormal;
in vec3 viewPosition;
in vec3 playerPosition;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
    vec4 albedo = aureliaDecodeSrgbTerrain(texture(gtexture, texcoord), vertexColor);
    if (albedo.a < alphaTestRef) discard;

#ifdef AURELIA_WATER_SURFACE
    // Pull the biome-tinted albedo toward a clear blue-teal. The atlas water is
    // a saturated pure blue; real shallow water reads teal because absorption
    // removes red first and scatter returns green. Half the tint survives, so
    // swamp and warm-ocean biomes still shift the hue.
    albedo.rgb = mix(albedo.rgb, AURELIA_WATER_ALBEDO, 0.6);
#endif
    vec3 color = aureliaForwardLight(albedo.rgb, worldNormal, lmcoord, playerPosition);
    float alpha = albedo.a;

#ifdef AURELIA_WATER_SURFACE
    // playerPosition is camera-relative with the camera at its origin, so its
    // normalized direction points from the eye TOWARD this fragment (the way
    // the view ray travels); the vector toward the eye is its negation.
    vec3 eyeToWater = normalize(playerPosition);
    vec3 waterToEye = -eyeToWater;
    vec3 surface = aureliaWaterNormal(playerPosition.xz, worldNormal, 0.045);
    float cosView = dot(surface, waterToEye);
    // Orient the normal toward the viewer. A horizontal surface seen from below
    // (camera under the water) ends up with surface.y < 0.
    if (cosView < 0.0) {
        surface = -surface;
        cosView = -cosView;
    }
    vec3 reflected = reflect(eyeToWater, surface);

    if (surface.y < 0.0) {
        // Underside of the surface. Past the critical angle (cos < ~0.66) it is
        // a mirror for the water column; inside Snell's window the viewer sees
        // the sky, refracted toward the vertical and tinted by the water.
        // Reflecting the sky dome here, as the surface seen from above does,
        // would show the sky through opaque water.
        float window = smoothstep(0.62, 0.72, cosView);
#ifdef AURELIA_WATER_UNDERWATER
        color = aureliaUnderwaterColor(reflected, rainStrength);
#else
        color *= AURELIA_WATER_BODY_MID * 0.5;
#endif
        if (window > 0.0) {
            vec3 refracted = refract(eyeToWater, surface, 1.3333);
            color = mix(color, aureliaWaterReflection(refracted) * AURELIA_WATER_BODY_MID, window);
        }
        alpha = 1.0;
    } else {
        float sunUp = aureliaSunVisibility();
        float fresnel = aureliaWaterFresnel(cosView);
        vec3 reflectionColor = aureliaWaterReflection(reflected);

        // Sun glint. The ripple slope nudges the reflected ray before the
        // lobe test, which is what scatters one blob into a glint path. A polynomial lobe,
        // x^4 on a linear ramp (exactly zero outside its edge, no pow, no flat
        // top), replaces pow(x, 180); the 1.6 scale bounds the peak so it cannot
        // clip into a milky plateau (that read as a blob on the noon sea).
        vec3 lightDir = aureliaSunDirection();
        vec2 ripple = aureliaWaterRippleSlope(playerPosition.xz)
            * (AURELIA_RIPPLE_STRENGTH * (1.0 - smoothstep(30.0, 110.0, length(playerPosition))));
        vec3 sparkle = reflected + vec3(ripple.x, 0.0, ripple.y);
        float lobe = clamp((dot(sparkle, lightDir) * inversesqrt(dot(sparkle, sparkle)) - 0.95) * 20.0, 0.0, 1.0);
        lobe *= lobe;
        vec3 glint = aureliaSunColor(lightDir.y)
            * (lobe * lobe * sunUp * 1.6 * (1.0 - AURELIA_RAIN_SUN_DIM * rainStrength));

        // Body colour: the lit albedo absorbed toward cyan (red first).
        vec3 body = color * AURELIA_WATER_BODY_MID;
#if defined(AURELIA_WATER_DEPTH) || defined(AURELIA_WATER_SHORE)
        // Water column thickness along the view ray, shared by the body curve
        // and the shoreline fade. depthtex1 is sampled at this pixel's SCREEN
        // coordinate (texcoord is the atlas UV). Only the floor's view-space z
        // is needed: the z row of the inverse projection gives it from two
        // mads and a divide, and because the floor point lies on this same eye
        // ray, thickness = |view| * (zFloor / zSurface - 1). Depth 1.0 (no
        // floor) lands on the far plane and clamps to the deep end. Assumes a
        // symmetric frustum (x/y do not enter z), true for Minecraft.
        float waterThickness;
        {
            vec2 screenCoord = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
            float floorNdcZ = texture(depthtex1, screenCoord).r * 2.0 - 1.0;
            float floorViewZ = (gbufferProjectionInverse[2][2] * floorNdcZ + gbufferProjectionInverse[3][2])
                / (gbufferProjectionInverse[2][3] * floorNdcZ + gbufferProjectionInverse[3][3]);
            waterThickness = max(length(viewPosition) * (floorViewZ / viewPosition.z - 1.0), 0.0);
        }
#endif
#ifdef AURELIA_WATER_DEPTH
        body = aureliaWaterBody(color, waterThickness);
#endif

        // Reflection is weighted down from full Fresnel (a full mirror at the
        // shoreline looked like sheet metal) and, with the shoreline option,
        // eased near the waterline so a few centimetres of water cannot paint
        // the sky as a bright rim on the floor.
        float reflectionWeight = fresnel * 0.50;
#ifdef AURELIA_WATER_SHORE
        float shoreFade = aureliaWaterShoreFade(waterThickness);
        reflectionWeight *= mix(0.70, 1.0, shoreFade);
#endif
        color = mix(body, reflectionColor, reflectionWeight) + glint;

        // Grazing water reflects more and transmits less, so alpha tracks
        // Fresnel; that is the bright rim that reads as a waterline.
        alpha = mix(albedo.a, 1.0, clamp(fresnel * 0.55, 0.0, 0.55));
#ifdef AURELIA_WATER_SHORE
        // Shoreline softness: ease the surface as the column thins to nothing.
        // V1-WATER: the fade stops at 0.70, never 0. Fading to exactly zero made
        // sub-1-block columns vanish next to full-alpha neighbours, and because
        // the floor steps by whole blocks that imprinted as rectangular plates
        // overhead (live ADAPTIVE evidence, 2026-09-29); 0.70 also bounds the
        // bright-floor/shadowed-water corner (tools/test_water_plates.py).
        // Scaling-only, so alpha never exceeds the Fresnel value above. Radial
        // thickness overstates the true column at grazing angles (slant).
        alpha *= mix(0.70, 1.0, shoreFade);
#endif
    }
#endif

    color = aureliaApplyFog(color, playerPosition);

#if AURELIA_DEBUG_VIEW == 1
    color = aureliaDebugLighting(worldNormal, lmcoord);
#elif AURELIA_DEBUG_VIEW == 5
    color = vec3(aureliaShadowDebug(playerPosition, worldNormal));
#endif

    aureliaSceneColor = vec4(color, alpha);
}
