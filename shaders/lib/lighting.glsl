// Original compact forward lighting. Inputs are world/player-space normal,
// corrected Minecraft lightmap coordinates, and camera-relative view position.
//
// Contract quantities (sun direction/height/visibility/colour, ambient tint,
// fog curve, weather coefficients) live in lib/look.glsl and are included here.
// This file keeps the forward-lighting composition plus the shadow-receiver
// direction, which is deliberately NOT part of the visual contract: Iris exposes
// shadowLightPosition as the highest celestial body (the moon at night), while
// daylight terms stay on sunPosition, so the two must not be conflated.
// See docs/LOOK-CONTRACT.md and docs/PHASE2A.md.
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/sky.glsl"

uniform vec3 shadowLightPosition;

#include "/lib/shadows.glsl"

vec3 aureliaShadowDirection() {
    return normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
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

    // Sky light remains a broad fill: a neutral base with only a restrained
    // cool bias. The strong teal cast in the earlier grade came from blending
    // the fill toward the decoded sky colour - blue ambient landed on green
    // albedo and tinted the whole world. That is reverted: the ambient stays
    // the contract's neutral-with-cool-bias tint, and any sky-tinted shading
    // is deliberately not carried by the ambient term at all.
    vec3 ambientTint = aureliaAmbientTint(skyLight);
    // Rain cools the fill toward the sky tint and lifts it slightly: an
    // overcast dome dominates the ambient, and its colour is the sky's, not
    // the neutral ground bounce. Contrast falls via the direct term below.
    ambientTint = mix(ambientTint, AURELIA_AMBIENT_SKY, 0.35 * rainStrength);
    // Two fills: the existing sky-driven term, plus a small constant floor.
    // The floor is what stops shadowed and overhang faces crushing to black:
    // the steep ACES curve plus AURELIA_CONTRAST deepens anything already
    // below mid-grey, so a purely proportional fill cannot protect them.
    // The daylight part of the sky fill fades to a restrained residual at
    // night - moonlight below replaces it as the directional source - because
    // leaving it up made night terrain read as a dim overcast afternoon.
    float dayFill = mix(0.40, 1.0, sunUp);
    vec3 coolAmbient = ambientTint
        * (AURELIA_NIGHT_LIFT + AURELIA_AMBIENT_SKY_SCALE * skyLight * dayFill
           * (1.0 + 0.08 * rainStrength))
        + vec3(0.055, 0.057, 0.063);
    float shadow = aureliaShadowVisibility(playerPosition, worldNormal, shadowDir, sunUp, rainStrength);
    vec3 direct = aureliaSunColor(lightDir.y) * (sunUp * skyLight * ndl * AURELIA_DIRECT_LIGHT * shadow);
    vec3 torch = vec3(1.00, 0.66, 0.38) * (blockLight * blockLight * 1.10);
    // Rain suppresses direct sun contrast and saturation of the accumulated
    // light: overcast light is desaturated and soft. The desaturation is at
    // the material stage (the illumination, not the final image), and only in
    // rain, so dry weather stays bit-identical.
    direct *= 1.0 - AURELIA_RAIN_SUN_DIM * rainStrength;

    // Moonlight: the night's directional source. Without it night terrain is a
    // pure silhouette - only a proportional sky fill, which the grade then
    // crushes. Cool and dim, gated by the moon's own visibility so it cannot
    // leak into daylight, and softened by weather.
    float moonUp = smoothstep(-0.05, 0.05, aureliaMoonDirection().y);
    float moonNdl = max(dot(normal, aureliaMoonDirection()), 0.0);
    vec3 moonlight = vec3(0.20, 0.23, 0.30)
        * ((1.0 - sunUp) * moonUp * skyLight * moonNdl * (1.0 - 0.5 * rainStrength));

    // Optional per-pixel terms, both ALU only: no sampler, uniform, render
    // target, or pass. With both options undefined the additions below vanish
    // at compile time and this is the original expression.
    vec3 lit = coolAmbient + direct + torch + moonlight;

    // Rain desaturates the accumulated illumination toward its own luma: the
    // scene loses chroma without going grey (the ambient keeps its cool bias
    // and torches stay warm because only the sum is softened, and by 25%).
    float rainLuma = dot(lit, vec3(0.2126, 0.7152, 0.0722));
    lit = mix(vec3(rainLuma), lit, 1.0 - 0.25 * rainStrength);

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
    // going black while front-lit terrain gains nothing. The term is gated by
    // the shadow lookup: transmission is sunlight reaching the leaf, so a leaf
    // the shadow map says is blocked must not glow from the wrong side. The
    // previous version deliberately skipped that gate and read as a self-lit
    // glow in every shaded canopy. Tinted by albedo through the product below.
    float backLit = max(-dot(normal, lightDir), 0.0);
    float sunBehind = max(dot(viewDir, lightDir), 0.0);
    lit += aureliaSunColor(lightDir.y) * (sunUp * skyLight * 0.28 * shadow
        * (1.0 - AURELIA_RAIN_SUN_DIM * rainStrength) * backLit * sunBehind * sunBehind);
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

// The curve lives in lib/look.glsl; the direction-aware fog application lives
// beside the shared sky palette in lib/sky.glsl. Every pass uses this contract.
vec3 aureliaApplyFog(vec3 color, vec3 viewPosition) {
    return aureliaApplyFogContract(color, viewPosition, AURELIA_FOG_DENSITY, rainStrength);
}
