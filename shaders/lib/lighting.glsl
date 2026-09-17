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
    vec3 noon = vec3(1.00, 0.96, 0.86);
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
    float ndl = max(dot(normalize(worldNormal), lightDir), 0.0);

    // Sky light remains a broad fill with only a restrained blue bias. The
    // Phase 1 blue vector was too strong and made shadowed daylight teal.
    vec3 ambientTint = mix(vec3(0.50), vec3(0.43, 0.50, 0.62), 0.18 + 0.08 * skyLight);
    vec3 coolAmbient = ambientTint * (AURELIA_NIGHT_LIFT + 0.60 * skyLight);
    float shadow = aureliaShadowVisibility(playerPosition, worldNormal, shadowDir, sunUp, rainStrength);
    vec3 direct = aureliaSunColor(lightDir.y) * (sunUp * skyLight * ndl * AURELIA_DIRECT_LIGHT * shadow);
    vec3 torch = vec3(1.00, 0.58, 0.27) * (blockLight * blockLight * 1.18);
    // Rain suppresses direct sun contrast, but should not turn ambient fill or
    // torch light teal/dim by multiplying the entire accumulated result.
    direct *= 1.0 - 0.38 * rainStrength;

    return albedo * (coolAmbient + direct + torch);
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
