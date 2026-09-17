// Color-space helpers for the forward scene pipeline.
//
// Minecraft texture, vertex, entity-overlay, sky, and fog colors are supplied
// as normalized sRGB-encoded values. Alpha, lightmap coordinates, and scalar
// lighting controls are not color channels and must not go through these
// transfers.

vec3 aureliaSrgbToLinear(vec3 srgb) {
    vec3 encoded = max(srgb, 0.0);
    vec3 low = encoded / 12.92;
    vec3 high = pow((encoded + 0.055) / 1.055, vec3(2.4));
    return mix(low, high, step(vec3(0.04045), srgb));
}

vec4 aureliaSrgbToLinear(vec4 srgb) {
    return vec4(aureliaSrgbToLinear(srgb.rgb), srgb.a);
}

vec3 aureliaLinearToSrgb(vec3 linear) {
    vec3 nonNegative = max(linear, 0.0);
    vec3 low = nonNegative * 12.92;
    vec3 high = 1.055 * pow(nonNegative, vec3(1.0 / 2.4)) - 0.055;
    return clamp(mix(low, high, step(vec3(0.0031308), nonNegative)), 0.0, 1.0);
}

// Texture and vertex colors are independent sRGB color inputs. Their alpha
// channels are coverage/modulation scalars and remain in their original space.
vec4 aureliaDecodeSrgbModulation(vec4 textureColor, vec4 vertexColor) {
    return vec4(
        aureliaSrgbToLinear(textureColor.rgb) * aureliaSrgbToLinear(vertexColor.rgb),
        textureColor.a * vertexColor.a
    );
}

// With separateAo=true, Iris moves terrain AO out of gl_Color.rgb and into
// gl_Color.a. Decode only the biome tint as a color, then apply AO as the
// linear scalar it is. Terrain alpha remains texture coverage.
vec4 aureliaDecodeSrgbTerrain(vec4 textureColor, vec4 vertexColor) {
    return vec4(
        aureliaSrgbToLinear(textureColor.rgb) * aureliaSrgbToLinear(vertexColor.rgb) * vertexColor.a,
        textureColor.a
    );
}
