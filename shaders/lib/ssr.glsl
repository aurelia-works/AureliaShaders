// Screen-space reflection tracing (Phase 5), shared by deferred.fsh (opaque
// surfaces, against depthtex0) and gbuffers_water (water and glass, against
// depthtex1, the opaque depth Iris copies before translucents).
//
// The ray is projected once and marched in screen space, where a step is a
// fixed fraction of the on-screen ray: no samples are wasted on distance that
// projects to a few pixels. View depth along the ray is interpolated as 1/z,
// which is linear in screen space, so the depth test is perspective-correct.
// A hit is the first sample behind the depth buffer by less than a thickness
// that grows with distance; four bisection steps then pin it to the surface.
// Spacing grows toward the far end, a per-pixel dither breaks up the steps,
// and the result fades out at the screen edges and on rays toward the camera,
// where screen space has nothing to show.

#ifndef AURELIA_SSR_GLSL
#define AURELIA_SSR_GLSL

uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform float viewWidth;
uniform float viewHeight;

// View-space z (negative in front of the camera) of a depth-buffer value.
// Perspective projections only couple z and w, so two dot products suffice.
float aureliaViewZ(float depth) {
    float ndc = depth * 2.0 - 1.0;
    float z = gbufferProjectionInverse[2][2] * ndc + gbufferProjectionInverse[3][2];
    float w = gbufferProjectionInverse[2][3] * ndc + gbufferProjectionInverse[3][3];
    return z / w;
}

vec3 aureliaViewPosition(vec2 uv, float depth) {
    vec4 p = gbufferProjectionInverse * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
    return p.xyz / p.w;
}

// Interleaved gradient noise (Jimenez 2014): a cheap per-pixel dither.
float aureliaDither(vec2 pixel) {
    return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

// Returns (uv, confidence); confidence 0 means no hit.
vec3 aureliaTraceScreen(sampler2D depthTexture, vec3 origin, vec3 direction, float dither, int steps) {
    // Start just off the surface along the reflected ray, scaled with
    // distance, so depth-buffer precision cannot report the origin as a hit.
    origin += direction * (0.03 + 0.004 * -origin.z);
    // Keep the far end in front of the near plane.
    float rayLength = 256.0;
    if (origin.z + direction.z * rayLength > -0.1) rayLength = (-0.1 - origin.z) / direction.z;
    vec3 target = origin + direction * rayLength;

    vec4 h0 = gbufferProjection * vec4(origin, 1.0);
    vec4 h1 = gbufferProjection * vec4(target, 1.0);
    vec2 s0 = h0.xy / h0.w * 0.5 + 0.5;
    vec2 s1 = h1.xy / h1.w * 0.5 + 0.5;
    vec2 delta = s1 - s0;
    // Clip the screen-space segment to the viewport.
    float tMax = 1.0;
    if (delta.x > 1e-6) tMax = min(tMax, (1.0 - s0.x) / delta.x);
    else if (delta.x < -1e-6) tMax = min(tMax, -s0.x / delta.x);
    if (delta.y > 1e-6) tMax = min(tMax, (1.0 - s0.y) / delta.y);
    else if (delta.y < -1e-6) tMax = min(tMax, -s0.y / delta.y);
    if (tMax <= 0.0) return vec3(0.0);

    float inverseZ0 = 1.0 / origin.z;
    float inverseZ1 = 1.0 / target.z;
    vec2 screen = vec2(viewWidth, viewHeight);

    float previous = 0.0;
    float previousZ = origin.z;
    for (int i = 1; i <= steps; ++i) {
        float f = (float(i) - 1.0 + dither) / float(steps);
        float t = tMax * f * (0.35 + 0.65 * f); // denser near the origin
        vec2 uv = s0 + delta * t;
        float rayZ = 1.0 / mix(inverseZ0, inverseZ1, t);
        float sceneDepth = texelFetch(depthTexture, ivec2(uv * screen), 0).r;
        float sceneZ = aureliaViewZ(sceneDepth);
        float behind = sceneZ - rayZ; // > 0: the ray has passed behind the surface
        // At least the depth the ray itself crossed this step: a grazing ray
        // over a floor moves far in depth per step, and a fixed thickness
        // would miss every other row of the floor (seen as stripes).
        float thickness = max(0.35 + 0.035 * -rayZ, 1.2 * abs(rayZ - previousZ));
        // A hit needs a few pixels of travel: closer than that the ray is
        // still reading its own surface.
        bool travelled = dot((uv - s0) * screen, (uv - s0) * screen) > 9.0;
        if (behind > 0.0 && behind < thickness && sceneDepth < 1.0 && travelled) {
            // Bisect between the last sample in front and this one.
            float lo = previous;
            float hi = t;
            for (int j = 0; j < 4; ++j) {
                float mid = 0.5 * (lo + hi);
                vec2 midUv = s0 + delta * mid;
                float midZ = 1.0 / mix(inverseZ0, inverseZ1, mid);
                float midScene = aureliaViewZ(texelFetch(depthTexture, ivec2(midUv * screen), 0).r);
                if (midScene - midZ > 0.0) hi = mid; else lo = mid;
            }
            vec2 hitUv = s0 + delta * hi;
            vec2 edge = min(hitUv, 1.0 - hitUv);
            float confidence = smoothstep(0.0, 0.06, min(edge.x, edge.y))
                             * (1.0 - smoothstep(0.80, 1.0, f))
                             * smoothstep(-0.05, 0.20, -direction.z + 0.15);
            return vec3(hitUv, confidence);
        }
        previous = t;
        previousZ = rayZ;
    }
    return vec3(0.0);
}

#endif
