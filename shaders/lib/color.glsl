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

// Vertex colours are decoded ONCE PER VERTEX (aureliaDecodeVertexColor, called
// from each vertex stage) instead of once per fragment: a vec3 pow per pixel is
// one of the largest ALU items in the terrain pass. Interpolating the linear
// value differs from decoding the interpolated sRGB value only where the four
// corners of a face disagree (biome-blend edges), and there by far less than
// one 8-bit step. Alpha is never decoded.
vec4 aureliaDecodeVertexColor(vec4 vertexColor) {
    return vec4(aureliaSrgbToLinear(vertexColor.rgb), vertexColor.a);
}

// Texture and vertex colors are independent sRGB color inputs. Their alpha
// channels are coverage/modulation scalars and remain in their original space.
// `vertexLinear` is the already-decoded vertex colour (see above).
vec4 aureliaDecodeSrgbModulation(vec4 textureColor, vec4 vertexLinear) {
    return vec4(
        aureliaSrgbToLinear(textureColor.rgb) * vertexLinear.rgb,
        textureColor.a * vertexLinear.a
    );
}

// With separateAo=true, Iris moves terrain AO out of gl_Color.rgb and into
// gl_Color.a. Decode only the biome tint as a color, then apply AO as the
// linear scalar it is. Terrain alpha remains texture coverage.
vec4 aureliaDecodeSrgbTerrain(vec4 textureColor, vec4 vertexLinear) {
    return vec4(
        aureliaSrgbToLinear(textureColor.rgb) * vertexLinear.rgb * vertexLinear.a,
        textureColor.a
    );
}
