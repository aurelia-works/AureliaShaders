// Shared shadow-space distortion. The caster (shadow.vsh) and the receiver
// (lib/shadows.glsl) MUST apply exactly this mapping to the orthographic
// shadow-NDC xy, or every shadow lookup lands on the wrong texel.
//
// The map is orthographic and centred on the camera, so a flat texel grid
// spends most of its resolution on distant ground nobody inspects. A radial
// remap f(r) = r / (K*r + 1 - K) concentrates texels near the centre (density
// 1/(1-K) at r = 0, ~3.3x for K = 0.70) and gives up resolution at the rim
// (density 1-K at r = 1). The crossover where the remapped density equals the
// flat grid is r = (sqrt(1-K) - (1-K)) / K, about a third of the map radius -
// the 30-40 blocks where shadow detail is actually read. Depth is untouched.
// Pure ALU: no extra target, fetch, or pass.
#ifndef AURELIA_SHADOW_DISTORT_GLSL
#define AURELIA_SHADOW_DISTORT_GLSL

const float AURELIA_SHADOW_DISTORT_K = 0.70;

// Radial scale applied to shadow-NDC xy: distorted = ndc / d, d = K*|ndc| + 1 - K.
float aureliaShadowDistortScale(vec2 ndc) {
    return AURELIA_SHADOW_DISTORT_K * length(ndc) + (1.0 - AURELIA_SHADOW_DISTORT_K);
}

#endif
