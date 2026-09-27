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
// The wave field is static. Animating it would need a frame/time uniform, and
// this pack deliberately depends only on uniforms documented in Iris's own
// reference; adding an unverifiable uniform to a program nobody has run in game
// yet is not a trade worth making for a moving surface. A static field still
// breaks up the specular and keeps the surface from reading as a flat mirror.

uniform vec3 skyColor;

// Two crossed waves. The scales and headings are deliberately unrelated so the
// interference pattern does not read as a regular grid.
const vec2 AURELIA_WAVE_A = vec2(0.866, 0.500);
const vec2 AURELIA_WAVE_B = vec2(-0.423, 0.906);

// Slope of the wave height field in the horizontal plane, per unit amplitude.
vec2 aureliaWaterSlope(vec2 horizontalPosition) {
    vec2 slope = AURELIA_WAVE_A * (0.55 * cos(dot(AURELIA_WAVE_A, horizontalPosition) * 0.55));
    slope += AURELIA_WAVE_B * (1.35 * cos(dot(AURELIA_WAVE_B, horizontalPosition) * 1.35));
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
// ray is only used for its elevation: lookups blend the fog colour at the
// horizon into the sky colour overhead, which matches what the sky pass draws
// for the same direction.
vec3 aureliaWaterReflection(vec3 reflectedDirection) {
    float elevation = clamp(reflectedDirection.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 horizon = aureliaSrgbToLinear(fogColor);
    vec3 overhead = aureliaSrgbToLinear(skyColor);
    return mix(horizon, overhead, smoothstep(0.42, 0.92, elevation));
}
