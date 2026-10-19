// Painted 2D cloud layer (AURELIA_CLOUD_LAYER), drawn in deferred.fsh over the
// sky pixels the world leaves visible, and in gbuffers_water's sky reflection.
//
// Cost model: sky pixels only. Value noise comes from Iris's built-in noisetex
// (256x256 random bytes, linear filtering, repeat): one fetch per octave at a
// smoothstep-adjusted lattice coordinate is the same smooth value noise the old
// four-hash version computed, at a fraction of the ALU. In the sky program it
// ran before terrain, on every pixel of the screen (~0.8 ms at 1080p on the
// M1); deferred.fsh now runs it only where the sky stays visible. While it is
// on, gbuffers_clouds discards the vanilla slab so the two cloud systems
// never stack.
//
// Included after lib/look.glsl and lib/sky.glsl (sun, LUT and rain); noisetex
// is declared behind AURELIA_NOISETEX_DECLARED so other includers can share it.

// frameTimeCounter and cameraPosition (clouds stay put as you move) come
// from lib/look.glsl.
#ifndef AURELIA_NOISETEX_DECLARED
#define AURELIA_NOISETEX_DECLARED
uniform sampler2D noisetex;     // Iris built-in, noiseTextureResolution = 256
#endif

const float AURELIA_CLOUD_ALTITUDE = 320.0;  // world Y of the layer
const float AURELIA_CLOUD_SCALE    = 0.0028; // noise frequency per block
const vec2  AURELIA_CLOUD_WIND     = vec2(2.4, 0.9); // blocks per second
const float AURELIA_NOISE_RES      = 256.0;

// One octave of smooth value noise in [0, 1]: the bilinear fetch blends the
// four lattice values with the smoothstepped fraction, exactly like the
// hash version's two mixes. textureLod: noisetex has no mips and this runs
// in branches.
float aureliaCloudNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return textureLod(noisetex, (i + f + 0.5) / AURELIA_NOISE_RES, 0.0).r;
}

// Four octaves, each rotated so the lattice never lines up into a grid, split
// into the two coarse octaves and the two fine ones so clear sky can stop
// after the coarse pair (see aureliaApplyCloudLayer). Coarse + fine is the full
// sum, ~[0, 0.94]; the fine pair adds at most 0.1875.
const mat2 AURELIA_CLOUD_ROT = mat2(0.80, 0.60, -0.60, 0.80);
const float AURELIA_CLOUD_FINE_MAX = 0.1875;

float aureliaCloudFbmCoarse(vec2 p) {
    float sum = 0.5 * aureliaCloudNoise(p);
    p = AURELIA_CLOUD_ROT * p * 2.03 + 17.1;
    return sum + 0.25 * aureliaCloudNoise(p);
}

float aureliaCloudFbmFine(vec2 p) {
    p = AURELIA_CLOUD_ROT * p * 2.03 + 17.1;
    p = AURELIA_CLOUD_ROT * p * 2.03 + 17.1;
    float sum = 0.125 * aureliaCloudNoise(p);
    p = AURELIA_CLOUD_ROT * p * 2.03 + 17.1;
    return sum + 0.0625 * aureliaCloudNoise(p);
}

// Composite the layer over `sky` for a world-space view direction.
vec3 aureliaApplyCloudLayer(vec3 sky, vec3 direction, vec3 sunDirection, vec3 moonDirection, float rain) {
    // Below the horizon there is no layer; near it the plane runs to infinity,
    // so it fades out instead of aliasing into a band.
    if (direction.y <= 0.015) return sky;
    float horizonFade = smoothstep(0.015, 0.20, direction.y);

    // Intersect the camera ray with the plane. Above the layer, keep it a
    // ceiling-free sky rather than drawing it underneath.
    float height = AURELIA_CLOUD_ALTITUDE - cameraPosition.y;
    if (height <= 8.0) return sky;
    vec2 world = cameraPosition.xz + direction.xz * (height / direction.y)
        + AURELIA_CLOUD_WIND * frameTimeCounter;

    vec2 p = world * AURELIA_CLOUD_SCALE;
    // Rain thickens the deck toward overcast.
    float coverage = mix(0.50, 0.30, rain);
    // Clear sky: if the fine octaves cannot lift the coarse pair to coverage,
    // there is no cloud here, and two of the four fetches are skipped.
    float nCoarse = aureliaCloudFbmCoarse(p);
    if (nCoarse + AURELIA_CLOUD_FINE_MAX <= coverage) return sky;
    float n = nCoarse + aureliaCloudFbmFine(p);
    float density = smoothstep(coverage, coverage + 0.28, n);
    if (density <= 0.0) return sky;

    // Lighting: a second, offset tap toward the sun approximates self-shadow
    // (thicker toward the sun = darker underside), the cheapest cue that turns
    // a flat stencil into a lit cloud. Plus forward scatter near the sun. The
    // tap is 0.35 lattice units, so only the two coarse octaves carry the
    // thickness change; it compares against the same two octaves of `n`.
    // Phase 5 lighting, in the LUT's physical units. The density field is
    // read as the deck's optical thickness. Light comes from whichever body
    // is up (the LUT's cloud-altitude texel already holds sun plus moon,
    // reddened by the air above the deck), scatters through a two-lobe phase
    // (a bright forward silver lining, a soft back lobe), and is dimmed by the
    // deck's own thickness toward the light, sampled one step sunward.
    vec3 lightDirection = sunDirection.y > -0.04 ? sunDirection : moonDirection;
    vec2 toLight = normalize(lightDirection.xz + vec2(1e-4)) * 0.35;
    float towardLight = aureliaCloudFbmCoarse(p + toLight);
    float selfShadow = clamp((towardLight - nCoarse) * 2.5 + 0.55, 0.0, 1.0);
    float tau = density * mix(6.0, 10.0, rain);
    float transmittance = exp(-tau);
    vec3 direct = aureliaLutTexel(AURELIA_LUT_CLOUD_LIGHT).rgb * (1.0 - 0.85 * rain);
    vec3 skyLight = aureliaLutTexel(AURELIA_LUT_SKY_UP).rgb;
    float nu = dot(direction, lightDirection);
    float g = 0.78;
    float forwardPhase = (1.0 - g * g) / (4.0 * AURELIA_PI * pow(1.0 + g * g - 2.0 * g * nu, 1.5));
    float thinEdge = transmittance * (1.0 - transmittance) * 4.0;
    // Multiple scattering makes the lit side read like a bright diffuse
    // surface; the powder term darkens the thin fringes not facing the light.
    float powder = 1.0 - exp(-2.0 * tau);
    vec3 cloud = direct * ((0.85 / AURELIA_PI) * mix(0.22, 1.0, selfShadow) * mix(0.55, 1.0, powder)
                           + forwardPhase * thinEdge * 1.4)
               + skyLight * (0.75 / AURELIA_PI) * mix(0.55, 1.0, selfShadow);
    // Rain: a uniform grey deck seen from below.
    float luma = dot(cloud, vec3(0.2126, 0.7152, 0.0722));
    cloud = mix(cloud, vec3(luma) * vec3(0.94, 0.97, 1.02), 0.7 * rain);
    // Aerial perspective: far clouds sink into the haze of the sky behind.
    float distanceToCloud = height / direction.y;
    float haze = 1.0 - exp(-distanceToCloud * 1.6e-4);
    cloud = mix(cloud, sky, haze * 0.85);
    float alpha = (1.0 - transmittance) * horizonFade;
    return mix(sky, cloud, alpha);
}

// High cirrus layer (AURELIA_CLOUD_HIGH): thin, streaky ice cloud far above
// the main deck, drawn first so the main layer passes in front of it. Its own
// altitude, wind and scale, stretched along the wind into streaks. Two noise
// fetches, no self-shadow tap: cirrus is too thin to shade itself.
const float AURELIA_CIRRUS_ALTITUDE = 640.0;
const vec2  AURELIA_CIRRUS_WIND     = vec2(-1.1, 3.2); // blocks per second, crosswise to the deck

vec3 aureliaApplyCirrusLayer(vec3 sky, vec3 direction, vec3 sunDirection, float rain) {
    if (direction.y <= 0.03) return sky;
    float height = AURELIA_CIRRUS_ALTITUDE - cameraPosition.y;
    if (height <= 8.0) return sky;
    vec2 world = cameraPosition.xz + direction.xz * (height / direction.y)
        + AURELIA_CIRRUS_WIND * frameTimeCounter;
    // Stretch along the wind: frequency across it is ~4x the frequency along it.
    vec2 along = normalize(AURELIA_CIRRUS_WIND);
    vec2 p = vec2(dot(world, along) * 0.0011, dot(world, vec2(-along.y, along.x)) * 0.0045);
    float n = 0.65 * aureliaCloudNoise(p) + 0.35 * aureliaCloudNoise(p * 2.7 + 9.3);
    // Rain hides it behind the overcast deck rather than thickening it.
    float density = smoothstep(0.55, 0.85, n) * (1.0 - rain);
    if (density <= 0.0) return sky;

    // Thin ice cloud: optically thin, so it scatters rather than blocks, with
    // a strong forward lobe near the sun. Physical units (lib/atmosphere.glsl).
    vec3 direct = aureliaLutTexel(AURELIA_LUT_CLOUD_LIGHT).rgb;
    float nu = dot(direction, sunDirection.y > -0.04 ? sunDirection : -sunDirection);
    float g = 0.70;
    float phase = (1.0 - g * g) / (4.0 * AURELIA_PI * pow(1.0 + g * g - 2.0 * g * nu, 1.5));
    vec3 cirrus = direct * (0.30 / AURELIA_PI + phase * 0.5)
                + aureliaLutTexel(AURELIA_LUT_SKY_UP).rgb * (0.5 / AURELIA_PI);
    float alpha = density * smoothstep(0.03, 0.25, direction.y) * 0.35;
    return mix(sky, cirrus, alpha);
}
