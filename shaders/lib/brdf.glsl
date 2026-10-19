// Shared BRDF pieces (Phase 5): the forward lighting (lib/lighting.glsl),
// deferred.fsh's reflections and gbuffers_water all evaluate the same lobes,
// so a reflection swapped in by SSR matches the sky reflection it replaces.
#ifndef AURELIA_BRDF_GLSL
#define AURELIA_BRDF_GLSL

float aureliaGgx(float NdotH, float alpha) {
    float a2 = alpha * alpha;
    float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (AURELIA_PI * d * d);
}

// Height-correlated Smith visibility, Hammon's approximation.
float aureliaSmithVisibility(float NdotV, float NdotL, float alpha) {
    return 0.5 / max(mix(2.0 * NdotL * NdotV, NdotL + NdotV, alpha), 1e-4);
}

vec3 aureliaSchlick(vec3 f0, float cosTheta) {
    float f = 1.0 - cosTheta;
    float f2 = f * f;
    return f0 + (1.0 - f0) * (f2 * f2 * f);
}

// Split-sum environment BRDF, analytic fit for mobile GPUs (Karis 2014): the
// specular a sky reflection receives, averaged over the lobe.
vec3 aureliaEnvBrdf(vec3 f0, float NdotV, float roughness) {
    const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
    vec4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
    vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;
    return f0 * ab.x + ab.y;
}

// Sky visibility from Minecraft's sky light level (0..1). The level drops one
// step per block from an opening; real sky visibility falls much faster.
float aureliaSkyVisibility(float skyLevel) {
    float s = clamp(skyLevel, 0.0, 1.0);
    return s * s * sqrt(s);
}

#endif
