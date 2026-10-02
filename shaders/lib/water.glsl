// Analytic water surface for gbuffers_water.
//
// Scope, and why it is narrow. This pack has no second colour target and no
// composite pass, and gbuffers_water renders after deferred while writing
// colortex0, so sampling the scene for a refraction offset is a feedback loop
// with undefined results. Nothing here reads another target: the reflection is
// the analytical sky and the fog colour, both of which Iris already supplies.
//
// The surface normal is two crossed analytic gradients rather than a texture.
// That keeps the whole treatment to arithmetic, adds no sampler, and costs
// nothing per fragment beyond two cosines.
//
// The wave field is animated by two travelling analytic waves driven by
// frameTimeCounter, an Iris uniform documented in its own reference. The
// motion sits behind AURELIA_WATER_ANIMATED so it can be switched off from the
// options screen; with the option off the slope is the same static field as
// before, byte for byte.


// skyColor, fogColor and the sun direction/uniforms are declared by
// lib/look.glsl, which lib/lighting.glsl includes before this file. This file
// declares exactly one uniform of its own -- frameTimeCounter, and only under
// AURELIA_WATER_ANIMATED -- so the contract stays single-sourced. The reflection
// samples the pack's own sky dome (aureliaSkyDome, via lib/sky.glsl included
// through lib/lighting.glsl) so the water sees the same atmosphere the sky pass
// draws.

// Two crossed waves. The scales and headings are deliberately unrelated so the
// interference pattern does not read as a regular grid.
const vec2 AURELIA_WAVE_A = vec2(0.866, 0.500);
const vec2 AURELIA_WAVE_B = vec2(-0.423, 0.906);

#ifdef AURELIA_WATER_ANIMATED
    uniform float frameTimeCounter;   // seconds (Iris)
    const float AURELIA_WAVE_OMEGA_A = 0.55;  // rad/s (P4: was 0.30; ~11s period reads as living water, still far from strobing)
    const float AURELIA_WAVE_OMEGA_B = 1.30;  // rad/s (P4: was 0.75; ~5s period carries the visible motion)
#endif

// Slope of the wave height field in the horizontal plane, per unit amplitude.
// P4 retune: the two slope factors were 0.55/1.35 (ratio 2.45:1), so component
// B dominated into parallel corduroy fringes that sat near-static at noon
// (0.5 s frame-time pair moved 0.2/255 mean). 0.65/1.15 keeps long subtle
// wavelengths (9.7/5.5 blocks, no gelatin) with more balanced
// cross-interference; the static branch below keeps the identical field shape.
vec2 aureliaWaterSlope(vec2 horizontalPosition) {
#ifdef AURELIA_WATER_ANIMATED
    vec2 slope = AURELIA_WAVE_A * (0.65 * cos(dot(AURELIA_WAVE_A, horizontalPosition) * 0.65 - AURELIA_WAVE_OMEGA_A * frameTimeCounter));
    slope += AURELIA_WAVE_B * (1.15 * cos(dot(AURELIA_WAVE_B, horizontalPosition) * 1.15 - AURELIA_WAVE_OMEGA_B * frameTimeCounter));
#else
    vec2 slope = AURELIA_WAVE_A * (0.65 * cos(dot(AURELIA_WAVE_A, horizontalPosition) * 0.65));
    slope += AURELIA_WAVE_B * (1.15 * cos(dot(AURELIA_WAVE_B, horizontalPosition) * 1.15));
#endif
    return slope;
}

// World-space surface normal of the water at a player-space position.
// `worldNormal` is the geometric normal from the vertex stage, so a still-water
// surface passes through unchanged and the wave term only adds perturbation.
vec3 aureliaWaterNormal(vec2 horizontalPosition, vec3 worldNormal, float amplitude) {
    vec2 slope = aureliaWaterSlope(horizontalPosition) * amplitude;
    vec3 waveNormal = normalize(vec3(-slope.x, 1.0, -slope.y));
    // Blend toward the geometric normal so steep terrain-adjacent water and any
    // non-horizontal surface keep their own orientation.
    return normalize(mix(normalize(worldNormal), waveNormal, 0.75));
}

// Schlick reflectance for water's index of refraction. F0 is small, so a
// surface seen face-on is almost pure transmitted body colour and only grazing
// angles pick up sky, which is what makes a shoreline read as a shoreline.
float aureliaWaterFresnel(float cosine) {
    float grazing = 1.0 - clamp(cosine, 0.0, 1.0);
    return 0.02 + 0.98 * pow(grazing, 5.0);
}

// Reflection colour. There is no sky render target to sample, so the reflected
// ray is evaluated against the pack's own sky dome (gradient + twilight palette
// + solar aureole + rain response, no discs or stars) for the same direction
// the sky pass would draw. The sun's direct glint stays in
// gbuffers_water.fsh, so the sun is lit once in the reflection, not twice.
vec3 aureliaWaterReflection(vec3 reflectedDirection) {
    // The dome already carries the rain response, so no extra weather term
    // here: that would flatten the reflection twice.
    return aureliaSkyDome(
        aureliaSkyColorLinear(),
        aureliaFogColorLinear(),
        normalize(reflectedDirection),
        aureliaSunDirection(),
        rainStrength);
}

// Depth-based body absorption, gated by AURELIA_WATER_DEPTH.
//
// gbuffers_water reads Iris's depthtex1: the pre-translucent opaque depth copy
// captured unconditionally in beginTranslucents, before deferred and
// translucent rendering (verified by disassembly in the installed
// iris-1.7.6+mc1.20.1.jar: copyPreTranslucentDepth into `noTranslucents`,
// bound to depthtex1 for gbuffers programs). depthtex0 is live during
// translucents and may hold the water surface itself, so it is not sampled.
// reads clear; a thickening column settles through the accepted mid palette
// vec3(0.58, 0.78, 0.90) and reaches a slightly deeper, richer limit. Only the
// `body` term moves: Fresnel, reflection, glint and alpha are untouched, and
// the multiplier never approaches black. One depth fetch and a handful of ALU
// ops; no loop, noise, refraction or shoreline detection.
#ifdef AURELIA_WATER_DEPTH
// V1-WATER: the shallow endpoint is deliberately NOT near-white. Bathymetry is
// voxel-stepped, so the thickness jumps by whole blocks at voxel walls; a
// near-white shallow end turned every 1-block floor step into a pale
// rectangular plate overhead (live ADAPTIVE evidence, 2026-09-29). This endpoint
// stays clearly lighter than MID for shallow readability but close enough that
// a single block step cannot imprint an edge. MID/DEEP are the accepted palette.
const vec3 AURELIA_WATER_BODY_SHALLOW = vec3(0.84, 0.91, 0.96);  // clear, not white
const vec3 AURELIA_WATER_BODY_MID = vec3(0.58, 0.78, 0.90);      // accepted P3.3A palette
const vec3 AURELIA_WATER_BODY_DEEP = vec3(0.46, 0.70, 0.80);     // subtly deeper limit
const float AURELIA_WATER_SHALLOW_TO_MID = 1.0;   // blocks
const float AURELIA_WATER_MID_TO_DEEP = 6.0;      // blocks
const float AURELIA_WATER_DEEP_FULL = 14.0;       // blocks

vec3 aureliaWaterBody(vec3 bodyColor, float thickness) {
    vec3 absorb = mix(AURELIA_WATER_BODY_SHALLOW, AURELIA_WATER_BODY_MID,
                      smoothstep(AURELIA_WATER_SHALLOW_TO_MID, AURELIA_WATER_MID_TO_DEEP, thickness));
    absorb = mix(absorb, AURELIA_WATER_BODY_DEEP,
                 smoothstep(AURELIA_WATER_MID_TO_DEEP, AURELIA_WATER_DEEP_FULL, thickness));
    return bodyColor * absorb;
}
#endif

// Shoreline softness, gated by AURELIA_WATER_SHORE.
//
// The waterline is where the water column thins to nothing against the floor.
// This maps the same thickness signal (no new depth read) onto a 0..1 fade over
// the first block of the column: 0 at the waterline, 1 once the water is a
// block deep. It is a scaling term only, so it can never brighten a pixel; the
// body curve above is untouched and the fade is smooth where they meet.
#ifdef AURELIA_WATER_SHORE
float aureliaWaterShoreFade(float thickness) {
    return smoothstep(0.0, 1.0, thickness);
}
#endif
