// Optional image effects for the final pass: bloom (AURELIA_BLOOM) and
// contrast-adaptive sharpening (AURELIA_SHARPEN). Both read the linear scene
// before grading. Included by final.fsh after its colortex0, viewWidth and
// viewHeight declarations.

#ifdef AURELIA_BLOOM
// Bloom from colortex0's own mip chain (final.fsh asks Iris for it with
// colortex0MipmapEnabled): no extra target and no extra pass, only the mip
// rebuild before final. Four levels, each read as a four-tap tent half a
// texel of that level apart, so the upsampled squares of the small mips do
// not show. The blurred image is mixed in, not added: bright areas spread
// their light into the dark around them while the total stays the same.
vec3 aureliaBloom(vec2 uv) {
    vec2 texel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 sum = vec3(0.0);
    float total = 0.0;
    float weight = 1.0;
    for (int level = 3; level <= 6; ++level) {
        float lod = float(level);
        vec2 offset = texel * exp2(lod) * 0.5;
        vec3 tap = textureLod(colortex0, uv + vec2(-offset.x, -offset.y), lod).rgb
                 + textureLod(colortex0, uv + vec2( offset.x, -offset.y), lod).rgb
                 + textureLod(colortex0, uv + vec2(-offset.x,  offset.y), lod).rgb
                 + textureLod(colortex0, uv + vec2( offset.x,  offset.y), lod).rgb;
        sum += tap * (0.25 * weight);
        total += weight;
        weight *= 0.75;
    }
    return sum / total;
}

vec3 aureliaApplyBloom(vec3 color, vec2 uv) {
    return mix(color, aureliaBloom(uv), 0.10 * AURELIA_BLOOM_STRENGTH);
}
#endif

#ifdef AURELIA_SHARPEN
// Contrast-adaptive sharpening: a negative-lobe cross filter whose strength
// falls where the neighbourhood already has strong contrast, so edges get
// crisper without halos and flat areas without grain. Four exact texel reads.
vec3 aureliaSharpen(vec3 center, ivec2 pixel) {
    ivec2 limit = ivec2(viewWidth, viewHeight) - 1;
    vec3 north = texelFetch(colortex0, clamp(pixel + ivec2(0, 1), ivec2(0), limit), 0).rgb;
    vec3 south = texelFetch(colortex0, clamp(pixel - ivec2(0, 1), ivec2(0), limit), 0).rgb;
    vec3 east  = texelFetch(colortex0, clamp(pixel + ivec2(1, 0), ivec2(0), limit), 0).rgb;
    vec3 west  = texelFetch(colortex0, clamp(pixel - ivec2(1, 0), ivec2(0), limit), 0).rgb;
    // Judge contrast on a tonemapped luma, so HDR highlights do not saturate it.
    vec4 luma = vec4(dot(north, vec3(0.2126, 0.7152, 0.0722)), dot(south, vec3(0.2126, 0.7152, 0.0722)),
                     dot(east,  vec3(0.2126, 0.7152, 0.0722)), dot(west,  vec3(0.2126, 0.7152, 0.0722)));
    float c = dot(center, vec3(0.2126, 0.7152, 0.0722));
    luma = luma / (1.0 + luma);
    c = c / (1.0 + c);
    float lo = min(c, min(min(luma.x, luma.y), min(luma.z, luma.w)));
    float hi = max(c, max(max(luma.x, luma.y), max(luma.z, luma.w)));
    float amount = sqrt(clamp(min(lo, 1.0 - hi) / max(hi, 1e-4), 0.0, 1.0));
    float lobe = -amount * mix(0.125, 0.2, AURELIA_SHARPEN_STRENGTH);
    return max((center + (north + south + east + west) * lobe) / (1.0 + 4.0 * lobe), 0.0);
}
#endif
