// Compact forward shadow receiver. It intentionally uses a single hardware-
// compared depth texture and fixed PCF patterns: no screen-space
// reconstruction, noise, or temporal history means low bandwidth and stable
// camera/moving-sun behaviour.
//
// This file is included by lib/lighting.glsl immediately after lib/look.glsl, so
// the contract constants below are in scope. It deliberately does not include
// look.glsl itself: that would double-declare its uniforms and helpers.

#ifdef AURELIA_SHADOWS
#include "/lib/shadow_distort.glsl"

uniform sampler2DShadow shadowtex0;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform float aureliaAdaptiveQuality;

// Hardware depth comparison with bilinear filtering: every tap below compares
// the receiver depth against the 2x2 texel footprint and returns the filtered
// visibility, i.e. a 4-sample PCF for the price of one fetch. Iris reads this
// directive from the source and switches shadowtex0's compare mode on;
// shadowtex1 stays a plain depth texture (debug view 4 reads that one).
const bool shadowHardwareFiltering0 = true;

// textureLod, not texture: the shadow map has no mip chain, so the explicit
// LOD is identical in value but needs no screen-space derivatives. That keeps
// the lookup well defined inside the non-uniform "skip underground pixels"
// branch in lib/lighting.glsl.
float aureliaShadowTap(vec3 screenPosition, vec2 texel, vec2 offset) {
    return textureLod(shadowtex0, vec3(screenPosition.xy + offset * texel, screenPosition.z), 0.0);
}

float aureliaShadowOneTap(vec3 screenPosition, vec2 texel) {
    return aureliaShadowTap(screenPosition, texel, vec2(0.0));
}

// Four filtered taps at +/-0.75 texel: a ~3.5-texel tent, the same footprint
// the old manual nine-tap kernel covered, at four fetches instead of nine.
float aureliaShadowFourTap(vec3 screenPosition, vec2 texel) {
    const float r = 0.75;
    return 0.25 * (
        aureliaShadowTap(screenPosition, texel, vec2(-r, -r)) +
        aureliaShadowTap(screenPosition, texel, vec2( r, -r)) +
        aureliaShadowTap(screenPosition, texel, vec2(-r,  r)) +
        aureliaShadowTap(screenPosition, texel, vec2( r,  r))
    );
}

// Tier budget (fetches): FILTER_MAX 1 -> 1, 2 -> 1, 3 -> 4. Tiers 1 and 2 both
// take the single filtered tap.
float aureliaShadowFiltered(vec3 screenPosition, vec2 texel) {
#if AURELIA_SHADOW_FILTER_MAX <= 2
    return aureliaShadowOneTap(screenPosition, texel);
#else
    #ifdef AURELIA_SHADOW_ADAPTIVE
        // Uses the Phase 1 8-tick-down / 80-tick-up smoothed quality signal.
        // Below sustained headroom the single filtered tap is used.
        if (aureliaAdaptiveQuality < 0.82) return aureliaShadowOneTap(screenPosition, texel);
    #endif
    return aureliaShadowFourTap(screenPosition, texel);
#endif
}

// Raw receiver visibility for a light whose direction is `lightDirection`
// (the body the shadow camera is currently rendering). `worldNormal` must
// already be normalised. Returns 1 outside the map.
//
// Bias is expressed in WORLD units from the map's own texel size so that the
// same constants hold at 512/64, 1024/96 and 1536/128 and under distortion:
//  - a normal-direction offset (grows with the grazing angle) moves the
//    receiver off its own surface by a fraction of a texel, which kills acne
//    on slopes without the detached contact that a large depth bias causes;
//  - a small constant depth bias covers the remaining quantisation.
// The texel size comes from shadowProjection (ortho: P00 = 1 / halfExtent), so
// it is correct whatever extent Iris picks for shadowDistance.
float aureliaShadowReceive(vec3 playerPosition, vec3 worldNormal, vec3 lightDirection, float rain) {
    const float res = float(AURELIA_SHADOW_RESOLUTION);
    const float k = AURELIA_SHADOW_DISTORT_K;

    vec3 viewPos = (shadowModelView * vec4(playerPosition, 1.0)).xyz;
    vec2 scale = vec2(shadowProjection[0][0], shadowProjection[1][1]);
    vec2 ndc0 = viewPos.xy * scale + shadowProjection[3].xy;
    float d = aureliaShadowDistortScale(ndc0);

    // World size of one texel at this point: flat grid size (2 / (P00 * res))
    // times the radial density change of the distortion, d^2 / (1 - k).
    float texelWorld = (2.0 / (scale.x * res)) * (d * d / (1.0 - k));

    float ndl = max(dot(worldNormal, lightDirection), 0.0);
    float sinTheta = sqrt(max(1.0 - ndl * ndl, 0.0));
    viewPos += (mat3(shadowModelView) * worldNormal) * (texelWorld * (0.35 + 0.85 * sinTheta));

    vec3 shadowScreen;
    shadowScreen.xy = (viewPos.xy * scale + shadowProjection[3].xy);
    shadowScreen.xy = shadowScreen.xy / aureliaShadowDistortScale(shadowScreen.xy) * 0.5 + 0.5;
    // Orthographic depth is affine in view z; subtract the constant bias in
    // world blocks converted to depth units (1 block = |P22| / 2).
    shadowScreen.z = (viewPos.z * shadowProjection[2][2] + shadowProjection[3][2]) * 0.5 + 0.5
        + 0.5 * shadowProjection[2][2] * (texelWorld * 0.5);
    if (shadowScreen.z <= 0.0 || shadowScreen.z >= 1.0) return 1.0;

    vec2 texel = vec2(1.0 / res);
    float border = min(min(shadowScreen.x, shadowScreen.y), min(1.0 - shadowScreen.x, 1.0 - shadowScreen.y));
    if (border <= 2.0 * texel.x) return 1.0;

    float filtered = aureliaShadowFiltered(shadowScreen, texel);

    // Fade only the map boundary, and lighten contrast in rain where direct
    // sunlight is already reduced by the forward-light weather term.
    float edgeFade = smoothstep(2.0 * texel.x, 0.025, border);
    float strength = AURELIA_SHADOW_STRENGTH * (1.0 - AURELIA_RAIN_SHADOW_SOFTEN * rain);
    return mix(1.0, mix(1.0, filtered, strength), edgeFade);
}

// Compatibility entry point for passes that only need the sun-side raw factor
// (debug views). Keeps the original contract: 1.0 when the sun is down.
float aureliaShadowVisibility(vec3 playerPosition, vec3 worldNormal, vec3 lightDirection, float sunUp, float rain) {
    if (sunUp <= 0.001) return 1.0;
    return aureliaShadowReceive(playerPosition, normalize(worldNormal), lightDirection, rain);
}
#else
float aureliaShadowReceive(vec3 playerPosition, vec3 worldNormal, vec3 lightDirection, float rain) {
    return 1.0;
}

float aureliaShadowVisibility(vec3 playerPosition, vec3 worldNormal, vec3 lightDirection, float sunUp, float rain) {
    return 1.0;
}
#endif
