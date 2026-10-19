// Sun effects for the final pass: lens flare (AURELIA_LENS_FLARE) and
// screen-space god rays (AURELIA_GOD_RAYS).
//
// Cost model: the sun's screen position, and for the flare how much of the sun
// is visible, are computed ONCE PER VERTEX in final.vsh (nine depth reads
// around the sun on the fullscreen quad's four vertices) and cross as flat
// varyings. The fragment stage skips everything when the sun is hidden, set
// or behind the camera (uniform branches). Included by final.vsh and final.fsh
// after lib/look.glsl and lib/options.glsl; final.vsh includes the sky LUT
// first.
//
// Both effects are scattered sunlight, so they are scaled to the sun's
// radiometric light at the camera (the LUT's sun texel) and added before
// exposure: bright at noon, reddened and faint at sunset, gone once the sun
// is down, and the eye adaptation treats them like any other light.

#if defined(AURELIA_LENS_FLARE) || defined(AURELIA_GOD_RAYS)
    #define AURELIA_SUN_EFFECTS
#endif

#ifdef AURELIA_SUN_EFFECTS
#ifdef AURELIA_SUN_EFFECTS_VERTEX
uniform float viewWidth;
uniform float viewHeight;
uniform mat4 gbufferProjection;
uniform sampler2D depthtex0;
flat out vec3 aureliaFlareSun; // xy: sun position in screen uv, z: flare strength
flat out float aureliaRaysSun;  // god-ray strength: sun in front, up, clear sky
flat out vec3 aureliaSunTint;   // scattered share of the sun's light for this frame
uniform bool hasCeiling;        // Nether: the sun still moves, behind the roof
uniform bool hasSkylight;       // false in the End (and Nether): no sun to flare

void aureliaWriteSunEffects() {
    aureliaFlareSun = vec3(0.0);
    aureliaRaysSun = 0.0;
    // About 6% of the direct sun's irradiance as the scale of the lens's own
    // scatter; the LUT already dims it for low sun, overcast and night.
    aureliaSunTint = aureliaSunLight() * 0.06;
    vec4 clip = gbufferProjection * vec4(sunPosition, 1.0);
    if (clip.w <= 0.0 || hasCeiling || !hasSkylight) return; // behind the camera, or no open sky
    vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
    float day = smoothstep(0.0, 0.05, aureliaSunTint.g);
    float clear = 1.0 - rainStrength;
    aureliaFlareSun.xy = uv;
    // Rays reach in from a sun just outside the frame too, fading with distance.
    vec2 outside = max(max(-uv, uv - 1.0), 0.0);
    aureliaRaysSun = day * clear * (1.0 - smoothstep(0.0, 0.6, length(outside)));
    // Fade out as the sun leaves the frame instead of popping at the edge.
    vec2 inside = smoothstep(vec2(-0.05), vec2(0.08), uv) * smoothstep(vec2(-0.05), vec2(0.08), 1.0 - uv);
    float onScreen = inside.x * inside.y;
    if (onScreen <= 0.0) return;
    // Share of a small disc around the sun where nothing but sky is drawn.
    vec2 radius = vec2(0.012 * viewHeight / viewWidth, 0.012);
    float open = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            open += step(1.0, textureLod(depthtex0, uv + vec2(x, y) * radius, 0.0).r);
        }
    }
    aureliaFlareSun.z = (open / 9.0) * onScreen * day * clear * clear;
}
#else
// Fragment side: final.fsh declares viewWidth, viewHeight and depthtex0 and
// includes this file after them.
flat in vec3 aureliaFlareSun;
flat in float aureliaRaysSun;
flat in vec3 aureliaSunTint;

#ifdef AURELIA_LENS_FLARE
// One soft ghost disc at `centre`, in aspect-corrected screen units. Squared
// distances: no square root per ghost, and the edge stays soft.
float aureliaFlareGhost(vec2 p, vec2 centre, float radius) {
    vec2 offset = p - centre;
    float r2 = radius * radius;
    return clamp((r2 - dot(offset, offset)) / (0.7 * r2), 0.0, 1.0);
}

vec3 aureliaApplyLensFlare(vec3 color, vec2 uv) {
    float strength = aureliaFlareSun.z * AURELIA_LENS_FLARE_STRENGTH;
    if (strength <= 0.0) return color;
    float aspect = viewWidth / viewHeight;
    vec2 p = vec2(uv.x * aspect, uv.y);
    vec2 sun = vec2(aureliaFlareSun.x * aspect, aureliaFlareSun.y);
    vec2 centre = vec2(0.5 * aspect, 0.5);
    vec3 tint = aureliaSunTint;
    float lum = dot(tint, vec3(0.2126, 0.7152, 0.0722));

    vec2 toSun = p - sun;
    float d = length(toSun);
    // Glare: a broad veil that lifts everything near the sun.
    vec3 flare = tint * (0.10 * exp(-d * 7.0));
    // Streak: thin and wide, slightly cool, as from an anamorphic element.
    flare += vec3(0.55, 0.70, 1.00) * (0.12 * lum * exp(-abs(toSun.y) * 90.0) * exp(-abs(toSun.x) * 2.6));
    // Ghosts on the line from the sun through the centre of the frame.
    vec2 axis = centre - sun;
    flare += vec3(0.35, 0.55, 1.00) * (0.060 * lum * aureliaFlareGhost(p, sun + axis * 0.55, 0.035));
    flare += vec3(1.00, 0.70, 0.35) * (0.045 * lum * aureliaFlareGhost(p, sun + axis * 1.05, 0.060));
    flare += vec3(0.50, 1.00, 0.60) * (0.035 * lum * aureliaFlareGhost(p, sun + axis * 1.45, 0.025));
    flare += vec3(0.80, 0.50, 1.00) * (0.035 * lum * aureliaFlareGhost(p, sun + axis * 1.85, 0.110));
    // A faint ring around the sun opposite: the largest, dimmest element.
    vec2 ringOffset = p - (sun + axis * 2.10);
    float ring = abs(dot(ringOffset, ringOffset) - 0.0256); // radius 0.16, squared
    flare += tint * (0.020 * clamp(1.0 - ring / 0.0064, 0.0, 1.0));
    return color + flare * strength;
}
#endif

#ifdef AURELIA_GOD_RAYS
// depthtex0 is declared by final.fsh, which includes this file after it.

// Screen-space light shafts: march from the pixel toward the sun through the
// depth buffer and count how much open sky lies along the way. Shafts appear
// where sky shows between leaves, trees and buildings. Sixteen depth reads,
// dithered start so the steps do not band; only while the sun is up and near
// the frame.
vec3 aureliaApplyGodRays(vec3 color, vec2 uv, float dither) {
    float strength = aureliaRaysSun * AURELIA_GOD_RAYS_STRENGTH;
    if (strength <= 0.0) return color;
    const int AURELIA_RAY_STEPS = 16;
    vec2 stepUv = (aureliaFlareSun.xy - uv) * (0.75 / float(AURELIA_RAY_STEPS));
    vec2 sampleUv = uv + stepUv * dither;
    float light = 0.0;
    float weight = 1.0;
    for (int i = 0; i < AURELIA_RAY_STEPS; ++i) {
        vec2 clamped = clamp(sampleUv, vec2(0.0), vec2(1.0));
        light += step(1.0, textureLod(depthtex0, clamped, 0.0).r) * weight;
        weight *= 0.93;
        sampleUv += stepUv;
    }
    light /= 9.6; // sum of the weights, ~(1 - 0.93^16) / 0.07
    // Brightest looking into the sun, gone looking away from it.
    float aspect = viewWidth / viewHeight;
    vec2 toSun = (aureliaFlareSun.xy - uv) * vec2(aspect, 1.0);
    float falloff = exp(-length(toSun) * 2.2);
    return color + aureliaSunTint * (light * falloff * strength * 0.35);
}
#endif // AURELIA_GOD_RAYS
#endif // AURELIA_SUN_EFFECTS_VERTEX
#endif // AURELIA_SUN_EFFECTS
