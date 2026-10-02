#version 330 compatibility

// Phase 2B water surface. Behaviour beyond the gbuffers_terrain fallback lives
// behind AURELIA_WATER_SURFACE so it is revertible from the Iris options screen
// without a code edit, and so the fallback replacement and the new shading stay
// separable in review.
//
// Water is a shadow receiver only. shaders.properties keeps shadowTranslucent
// disabled, so this samples the shadow map but never enters the caster pass.
//
// No scene-colour read: gbuffers_water renders after deferred while writing
// colortex0, so sampling colortex0 is a feedback loop. The reflection is
// analytical. Under AURELIA_WATER_DEPTH it also reads depthtex1, the
// pre-translucent opaque depth copy Iris takes in beginTranslucents (verified
// in the installed iris-1.7.6+mc1.20.1.jar) -- NOT depthtex0, which during
// translucents may hold the water surface itself. Without the option the only
// thickness cue is Fresnel.

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
    // Floor depth comes from depthtex1: the pre-translucent opaque copy Iris
    // captures in RenderTargets.copyPreTranslucentDepth(), called
    // unconditionally from IrisRenderingPipeline.beginTranslucents() BEFORE
    // deferred and translucent rendering (verified by disassembly in the
    // installed iris-1.7.6+mc1.20.1.jar; IrisSamplers maps depthtex1 to
    // getDepthTextureNoTranslucents()). depthtex0 is the LIVE depth during
    // translucents -- it may equal this water surface -- so it must not be
    // sampled here. The shoreline option reuses this same signal, so it is
    // declared for either.
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

    vec3 color = aureliaForwardLight(albedo.rgb, worldNormal, lmcoord, playerPosition);

#ifdef AURELIA_WATER_SURFACE
    // playerPosition is camera-relative with the camera at its origin, so its
    // normalized direction points from the eye TOWARD this fragment. That is
    // the direction the view ray travels; the vector toward the eye is its
    // negation. Getting this backwards zeroes the Fresnel cosine (Schlick then
    // saturates to full reflectance at every angle) and makes reflect() fold
    // the ray down into the water instead of up into the sky.
    vec3 eyeToWater = normalize(playerPosition);
    vec3 waterToEye = -eyeToWater;
    vec3 surface = aureliaWaterNormal(playerPosition.xz, worldNormal, 0.045);

    float sunUp = aureliaSunVisibility();
    float fresnel = aureliaWaterFresnel(max(dot(surface, waterToEye), 0.0));
    vec3 reflected = reflect(eyeToWater, surface);
    vec3 reflectionColor = aureliaWaterReflection(reflected);

    // A tight specular lobe on the perturbed normal. The wave field is what
    // turns this from a single highlight into a scattered glint path. Kept
    // well below saturation: a glint that clips into a flat pink-white plateau
    // is what read as a milky blob on the noon sea.
    vec3 lightDir = aureliaSunDirection();
    vec3 glint = aureliaSunColor(lightDir.y)
        * pow(max(dot(reflected, lightDir), 0.0), 180.0)
        * (sunUp * 1.7 * (1.0 - AURELIA_RAIN_SUN_DIM * rainStrength));

    // Reflection is strongest at grazing angles, so it is weighted down from
    // full Fresnel; a full mirror at the shoreline looked like sheet metal.
    // The body colour is absorbed toward cyan the way real water absorbs red
    // first, which is what makes a clear lake read blue instead of milky -
    // and the reflection weight drops, so a wide noon sea stops washing the
    // whole lower frame into a pale slab.
    vec3 body = color * vec3(0.58, 0.78, 0.90);
#if defined(AURELIA_WATER_DEPTH) || defined(AURELIA_WATER_SHORE)
    // Hoisted out of the block so the shoreline fade can reuse the same
    // thickness the body curve consumes. With only the depth option on this is
    // the identical value at the identical point in the arithmetic.
    float waterThickness = 0.0;
    {
        // Unproject depthtex1 at this pixel's SCREEN coordinate. texcoord here
        // is the atlas UV, not screen space, so it must not be used for the
        // depth lookup. The depth buffer is [0,1] while clip space is [-1,1],
        // so NDC z = depth*2-1. depth 1.0 (no floor behind the water)
        // unprojects to the far plane, which clamps to the deep end; the
        // multiplier floor keeps it off black. The body term is the only thing
        // that moves here; the shoreline option reads the same thickness later
        // for its alpha/reflection fade.
        vec2 screenCoord = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
        float floorDepth = texture(depthtex1, screenCoord).r * 2.0 - 1.0;
        vec4 floorClip = vec4(screenCoord * 2.0 - 1.0, floorDepth, 1.0);
        vec4 floorView = gbufferProjectionInverse * floorClip;
        floorView /= floorView.w;
        waterThickness = max(length(floorView.xyz) - length(playerPosition), 0.0);
    }
#ifdef AURELIA_WATER_DEPTH
    body = aureliaWaterBody(color, waterThickness);
#endif
#endif

    // The reflection is weighted down from full Fresnel. The shoreline option
    // eases that weight near the waterline as well, so a few centimetres of
    // water cannot paint the sky as a bright rim on the floor. With the option
    // off this is exactly the accepted `fresnel * 0.50`.
    float reflectionWeight = fresnel * 0.50;
#ifdef AURELIA_WATER_SHORE
    float shoreFade = aureliaWaterShoreFade(waterThickness);
    reflectionWeight *= mix(0.70, 1.0, shoreFade);
#endif
    color = mix(body, reflectionColor, reflectionWeight) + glint;
#endif

    color = aureliaApplyFog(color, viewPosition);

#if AURELIA_DEBUG_VIEW == 1
    color = aureliaDebugLighting(worldNormal, lmcoord);
#elif AURELIA_DEBUG_VIEW == 5
    color = vec3(aureliaShadowVisibility(playerPosition, worldNormal, aureliaShadowDirection(), aureliaSunVisibility(), rainStrength));
#endif

#ifdef AURELIA_WATER_SURFACE
    // Grazing water reflects more and transmits less, so alpha tracks Fresnel.
    // Without this the surface stayed uniformly translucent and lost the bright
    // rim that reads as a waterline.
    float alpha = mix(albedo.a, 1.0, clamp(fresnel * 0.55, 0.0, 0.55));
#ifdef AURELIA_WATER_SHORE
    // Shoreline softness: ease the surface as the column thins to nothing, so
    // the floor shows through at the waterline instead of a hard albedo cutoff.
    // V1-WATER: the fade stops at 0.70, never 0. Fading to exactly zero made
    // sub-1-block columns vanish next to full-alpha neighbours, and because the
    // floor steps by whole blocks that binary imprinted as rectangular plates
    // overhead (live ADAPTIVE evidence, 2026-09-29). The 0.70 floor is the
    // cheapest value that also bounds the bright-floor/shadowed-water corner
    // (step 0.128 in the regression grid); at 0.60 that corner still stepped
    // 0.171. At 0.70 x albedo the waterline still dissolves visibly into the
    // floor; scaling-only is kept, so alpha can never exceed the accepted value.
    // Caveats: per-vertex biome tint steps are NOT excluded as a secondary
    // contributor (the screenshot alone cannot separate tint from bathymetry),
    // and at grazing angles the radial thickness overstates the true column
    // (slant), so this bound is proven overhead with a representative grazing
    // case only -- see tools/test_water_plates.py.
    alpha *= mix(0.70, 1.0, shoreFade);
#endif
#else
    float alpha = albedo.a;
#endif
    aureliaSceneColor = vec4(color, alpha);
}
