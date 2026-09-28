// Original compact forward lighting. Inputs are world/player-space normal,
// corrected Minecraft lightmap coordinates, and camera-relative view position.

// Iris exposes both the sun and the highest celestial shadow source in view
// space, each with length 100. Keep analytical daylight on sunPosition so the
// moon does not become warm "sunlight" after sunset; use shadowLightPosition
// for the receiver projection because it is exactly the shadow-camera source.
#include "/lib/color.glsl"

uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform vec3 fogColor;
uniform float rainStrength;
uniform mat4 gbufferModelViewInverse;

#include "/lib/shadows.glsl"

vec3 aureliaSunDirection() {
    return normalize(mat3(gbufferModelViewInverse) * sunPosition);
}

vec3 aureliaShadowDirection() {
    return normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
}

float aureliaSunHeight() {
    return aureliaSunDirection().y;
}

// Keep the terminator behavior identical for direct lighting and diagnostics:
// below the horizon the directional source contributes no sunlight.
float aureliaSunVisibility() {
    return smoothstep(-0.10, 0.08, aureliaSunHeight());
}

vec3 aureliaSunColor(float height) {
    float horizon = 1.0 - smoothstep(0.04, 0.34, max(height, 0.0));
    vec3 noon = vec3(1.00, 0.97, 0.91);
    vec3 sunset = vec3(1.00, 0.57, 0.31);
    return mix(noon, sunset, horizon);
}

vec3 aureliaForwardLight(vec3 albedo, vec3 worldNormal, vec2 lightLevel, vec3 playerPosition) {
    vec3 lightDir = aureliaSunDirection();
    vec3 shadowDir = aureliaShadowDirection();
    float sunUp = aureliaSunVisibility();
    // Lightmap coordinates are perceptual samples, not linear irradiance.
    // Recover a little mid-range energy before applying the analytical model;
    // this avoids the Phase 1 underexposure on ordinary outdoor blocks.
    float skyLight = pow(clamp(lightLevel.y, 0.0, 1.0), 0.72);
    float blockLight = pow(clamp(lightLevel.x, 0.0, 1.0), 0.80);
    // worldNormal already arrives normalized, so spend the one normalize() here
    // and let the optional terms below reuse this local instead of paying for a
    // second one. The direct-light expression is unchanged by the hoist.
    vec3 normal = normalize(worldNormal);
    float ndl = max(dot(normal, lightDir), 0.0);

    // Sky light remains a broad fill with only a restrained blue bias. The
    // Phase 1 blue vector was too strong and made shadowed daylight teal.
    vec3 ambientTint = mix(vec3(0.50), vec3(0.43, 0.50, 0.62), 0.18 + 0.08 * skyLight);
    vec3 coolAmbient = ambientTint * (AURELIA_NIGHT_LIFT + 0.60 * skyLight);
    float shadow = aureliaShadowVisibility(playerPosition, worldNormal, shadowDir, sunUp, rainStrength);
    vec3 direct = aureliaSunColor(lightDir.y) * (sunUp * skyLight * ndl * AURELIA_DIRECT_LIGHT * shadow);
    vec3 torch = vec3(1.00, 0.66, 0.38) * (blockLight * blockLight * 1.10);
    // Rain suppresses direct sun contrast, but should not turn ambient fill or
    // torch light teal/dim by multiplying the entire accumulated result.
    direct *= 1.0 - 0.38 * rainStrength;

    // Optional per-pixel terms, both ALU only: no sampler, uniform, render
    // target, or pass. With both options undefined the additions below vanish
    // at compile time and this is the original expression.
    vec3 lit = coolAmbient + direct + torch;

#if defined(AURELIA_FOLIAGE_TRANSLUCENCY) || defined(AURELIA_WETNESS_SPECULAR)
    // playerPosition is camera-relative player space, so the camera sits at its
    // origin and this is the camera-to-fragment view direction in world axes.
    // The celestial directions were already converted to world space above, so
    // view and light vectors can be combined directly.
    vec3 viewDir = normalize(playerPosition);
#endif

#ifdef AURELIA_FOLIAGE_TRANSLUCENCY
    // Wrapped transmission for thin geometry. backLit is high only where the
    // visible face is turned away from the sun, sunBehind only where the camera
    // looks sunward, so back-lit leaves and grass pick up sunlight instead of
    // going black while front-lit terrain gains nothing. Deliberately not
    // multiplied by `shadow`, so the term stays separable from
    // AURELIA_SHADOW_STRENGTH, and tinted by albedo through the product below.
    float backLit = max(-dot(normal, lightDir), 0.0);
    float sunBehind = max(dot(viewDir, lightDir), 0.0);
    lit += aureliaSunColor(lightDir.y) * (sunUp * skyLight * 0.55
        * (1.0 - 0.38 * rainStrength) * backLit * sunBehind * sunBehind);
#endif

    vec3 color = albedo * lit;

#ifdef AURELIA_WETNESS_SPECULAR
    // Rain sheen: one Blinn lobe on the existing sun/view pair. smoothstep is
    // exactly zero at rainStrength 0.05 and below, and the branch is uniform
    // per frame, so dry weather pays nothing and stays bit-identical. The ndl
    // mask keeps the sheen on faces the directional light actually reaches; it
    // is a surface reflection, so it is added after the albedo product.
    float wetness = smoothstep(0.05, 0.70, rainStrength);
    if (wetness > 0.0) {
        // Surface-to-eye is -viewDir, so the Blinn half vector is L + V.
        vec3 halfDir = normalize(lightDir - viewDir);
        float lobe = max(dot(normal, halfDir), 0.0);
        lobe *= lobe;
        lobe *= lobe;
        lobe *= lobe;
        color += vec3(0.70, 0.78, 0.92)
            * (wetness * sunUp * skyLight * ndl * lobe * 0.50);
    }
#endif

    return color;
}

vec3 aureliaApplyFog(vec3 color, vec3 viewPosition) {
    float distanceToCamera = length(viewPosition);
    // An exponential curve keeps nearby blocks crisp and costs no texture read.
    // At eight chunks, 0.010 caused mid-distance terrain to be replaced by
    // the supplied blue-green fog. Keep the atmosphere visible but let the
    // world retain daylight exposure until the far edge.
    float fog = 1.0 - exp(-distanceToCamera * 0.0035 * AURELIA_FOG_DENSITY);
    fog = clamp(fog * (0.80 + 0.20 * rainStrength), 0.0, 0.85);
    // fogColor is a Minecraft/Iris sRGB color; fog interpolation is linear.
    return mix(color, aureliaSrgbToLinear(fogColor), fog);
}
