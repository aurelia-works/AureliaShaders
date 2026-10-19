// Water optics (Phase 5), for gbuffers_water and the underwater atmosphere.
//
// The surface is a sum of three octaves of drifting value noise read from
// Iris's noisetex (nine fetches for the normal by finite differences). The
// body below it is a participating medium: Beer-Lambert absorption through
// the water column the view ray crosses (red goes first, then green, which is
// why deep water turns blue-green and then dark), and light scattered back
// out of the column by suspended particles, coloured by the same
// coefficients. A canal or river is murkier than open sea; the coefficients
// sit between clear coastal water and a city canal.
//
// Needs lib/atmosphere.glsl (LUT read) and lib/look.glsl first: the light
// that enters the water is the sky LUT's sun, moon and sky irradiance.

#ifndef AURELIA_WATER_GLSL
#define AURELIA_WATER_GLSL

#ifndef AURELIA_NOISETEX_DECLARED
#define AURELIA_NOISETEX_DECLARED
uniform sampler2D noisetex;
#endif

// Absorption and scattering per block (metre).
// Pure water absorbs (0.34, 0.06, 0.015); dissolved organic matter adds
// blue absorption and silt adds scattering, which turns it green-teal.
const vec3  AURELIA_WATER_ABSORPTION = vec3(0.36, 0.09, 0.06);
const float AURELIA_WATER_SCATTERING = 0.04;
// Share of in-scattered light that leaves through the surface toward the
// camera (a forward-peaked phase function sends most of it down).
const float AURELIA_WATER_BACKSCATTER = 0.14;
// Thickness assumed where the bed cannot be measured (depth option off).
const float AURELIA_WATER_DEFAULT_THICKNESS = 3.0;
// Reflectance at normal incidence (IOR 1.33).
const float AURELIA_WATER_F0 = 0.02;
// Minecraft's default water tint (#3F76E4), linear. Biomes whose tint departs
// from it get murkier or clearer water, not just a recoloured surface.
const vec3  AURELIA_WATER_REFERENCE_TINT = vec3(0.0497, 0.1779, 0.7758);

float aureliaWaveNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return textureLod(noisetex, (i + f + 0.5) / 256.0, 0.0).r;
}

float aureliaWaveHeight(vec2 p, float t) {
    const mat2 turn1 = mat2(0.80, 0.60, -0.60, 0.80);
    const mat2 turn2 = mat2(0.36, -0.93, 0.93, 0.36);
    float h = 0.55 * aureliaWaveNoise(p * 0.32 + vec2(0.30, 0.11) * t);
    h += 0.30 * aureliaWaveNoise(turn1 * p * 0.85 - vec2(0.17, 0.38) * t);
    h += 0.15 * aureliaWaveNoise(turn2 * p * 2.10 + vec2(0.52, -0.29) * t);
    return h;
}

// World-space wave normal of an up-facing water surface. `strength` is the
// slope scale; it falls off with distance so far water does not alias into
// noise, and rises with rain.
vec3 aureliaWaveNormal(vec2 world, float strength, float t) {
    const float e = 0.08;
    float h0 = aureliaWaveHeight(world, t);
    float hx = aureliaWaveHeight(world + vec2(e, 0.0), t);
    float hz = aureliaWaveHeight(world + vec2(0.0, e), t);
    vec2 slope = vec2(hx - h0, hz - h0) * (strength / e);
    return normalize(vec3(-slope.x, 1.0, -slope.y));
}

// Raindrop rings on the surface: one jittered ring per cell, returning slope.
vec2 aureliaRainRings(vec2 p, float time) {
    vec2 cell = floor(p);
    vec3 random = textureLod(noisetex, (cell + 0.5) / 256.0, 0.0).rgb;
    vec2 local = fract(p) - 0.25 - 0.5 * random.xy;
    float age = fract(time * 1.1 + random.z);
    float r = length(local);
    float band = 1.0 - smoothstep(0.0, 0.06, abs(r - age * 0.45));
    return local / max(r, 1e-3) * (band * (1.0 - age));
}

// Extinction of water whose biome tint is `tint` (linear vertex colour).
// The tint's departure from the default makes the matching channels absorb
// more: a swamp's brown-green tint takes out blue. tintRatio returns the
// damped ratio, which also colours the in-scatter.
vec3 aureliaWaterExtinction(vec3 tint, out vec3 tintRatio) {
    tintRatio = pow(clamp(tint / AURELIA_WATER_REFERENCE_TINT, 0.25, 4.0), vec3(0.3));
    return AURELIA_WATER_ABSORPTION + 0.25 * max(1.0 - tintRatio, 0.0) + AURELIA_WATER_SCATTERING;
}

// Irradiance entering the water from above: sun, moon and sky, each through
// its own visibility.
vec3 aureliaWaterDownwelling(float sunVisibility, float moonVisibility, float skyVisibility) {
    return aureliaSunLight() * (max(aureliaSunDirection().y, 0.0) * sunVisibility)
         + aureliaMoonLight() * (max(aureliaMoonDirection().y, 0.0) * moonVisibility)
         + aureliaLutTexel(AURELIA_LUT_SKY_UP).rgb * skyVisibility;
}

// Light scattered toward the camera by a water column of `thickness`
// blocks, lit from above by `downwelling` irradiance.
vec3 aureliaWaterInscatter(vec3 downwelling, vec3 extinction, float thickness) {
    vec3 albedo = AURELIA_WATER_SCATTERING / extinction;
    vec3 transmittance = exp(-extinction * thickness);
    return downwelling * albedo * (AURELIA_WATER_BACKSCATTER / AURELIA_PI) * (1.0 - transmittance);
}

// Radiance of open water seen from inside it along `direction`: the column's
// in-scatter, brighter looking up toward the light than down into the dark.
vec3 aureliaWaterColumnRadiance(vec3 direction, vec3 downwelling) {
    vec3 extinction = AURELIA_WATER_ABSORPTION + AURELIA_WATER_SCATTERING;
    float up = smoothstep(-0.6, 1.0, direction.y);
    return downwelling * (AURELIA_WATER_SCATTERING / extinction) * (mix(0.12, 0.90, up * up) / AURELIA_PI);
}

#endif
