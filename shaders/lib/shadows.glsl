// Compact forward shadow receiver. It intentionally uses a single hardware-
// compared depth texture and fixed PCF patterns: no screen-space
// reconstruction, noise, or temporal history means low bandwidth and stable
// camera/moving-sun behaviour.
//
// This file is included by lib/lighting.glsl immediately after lib/look.glsl, so
// the contract constants below are in scope. It deliberately does not include
// look.glsl itself: that would double-declare its uniforms and helpers.

#ifdef AURELIA_SHADOWS
uniform sampler2DShadow shadowtex0;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform float aureliaAdaptiveQuality;

// Hardware depth comparison with bilinear filtering: every texture() call below
// compares the receiver depth against the 2x2 texel footprint and returns the
// filtered visibility, i.e. a 4-sample PCF for the price of one fetch. This
// replaces the manual step(texture(..)) taps on an unfiltered map, which paid
// one fetch per sample and still stair-stepped at the 512 map Low uses. Iris
// reads this directive from the source and switches shadowtex0's compare mode
// on; shadowtex1 stays a plain depth texture (debug view 4 reads that one).
const bool shadowHardwareFiltering0 = true;

float aureliaShadowTap(vec3 screenPosition, vec2 texel, vec2 offset) {
    return texture(shadowtex0, vec3(screenPosition.xy + offset * texel, screenPosition.z));
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
// take the single filtered tap; tier 2 used to pay four manual fetches for a
// softness one hardware-filtered fetch now matches closely enough.
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

float aureliaShadowVisibility(vec3 playerPosition, vec3 worldNormal, vec3 lightDirection, float sunUp, float rain) {
    if (sunUp <= 0.001) return 1.0;

    vec4 shadowClip = shadowProjection * (shadowModelView * vec4(playerPosition, 1.0));
    // Behind-camera/invalid homogeneous coordinates can occur at the edge of
    // the legacy shadow frustum. Treat them as outside the map instead of
    // dividing by a near-zero w and producing horizon streaks.
    if (shadowClip.w <= 0.0001) return 1.0;
    vec3 shadowScreen = shadowClip.xyz / shadowClip.w * 0.5 + 0.5;
    if (shadowScreen.z <= 0.0 || shadowScreen.z >= 1.0) return 1.0;

    vec2 texel = vec2(1.0 / float(AURELIA_SHADOW_RESOLUTION));
    float border = min(min(shadowScreen.x, shadowScreen.y), min(1.0 - shadowScreen.x, 1.0 - shadowScreen.y));
    if (border <= 2.0 * texel.x) return 1.0;

    // Receiver-plane-style slope bias without a normal-position offset avoids
    // most acne while limiting detached/peter-panned contacts.
    float ndl = max(dot(normalize(worldNormal), lightDirection), 0.0);
    shadowScreen.z -= mix(0.00125, 0.00035, ndl);
    float filtered = aureliaShadowFiltered(shadowScreen, texel);

    // Fade only the map boundary, and lighten contrast in rain where direct
    // sunlight is already reduced by the forward-light weather term.
    float edgeFade = smoothstep(2.0 * texel.x, 0.025, border);
    float strength = AURELIA_SHADOW_STRENGTH * (1.0 - AURELIA_RAIN_SHADOW_SOFTEN * rain);
    return mix(1.0, mix(1.0, filtered, strength), edgeFade);
}
#else
float aureliaShadowVisibility(vec3 playerPosition, vec3 worldNormal, vec3 lightDirection, float sunUp, float rain) {
    return 1.0;
}
#endif
