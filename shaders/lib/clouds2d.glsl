// Painted 2D cloud layer, drawn inside gbuffers_skybasic (AURELIA_CLOUD_LAYER).
//
// Cost model: sky pixels only, ALU only. Four octaves of value noise (four
// hashes each) on one world-anchored plane, no texture, no pass, no loop over
// samples. Terrain pixels never run it, so a frame looking at the ground pays
// nothing. While it is on, gbuffers_clouds discards the vanilla slab so the two
// cloud systems never stack.
//
// Included by gbuffers_skybasic.fsh only, after lib/look.glsl and lib/sky.glsl
// (it uses their sun colour and rain constants). It declares its own uniforms
// because no other program includes it.

uniform float frameTimeCounter; // seconds, wraps hourly in Iris
uniform vec3 cameraPosition;    // world position, so clouds stay put as you move

const float AURELIA_CLOUD_ALTITUDE = 320.0;  // world Y of the layer
const float AURELIA_CLOUD_SCALE    = 0.0028; // noise frequency per block
const vec2  AURELIA_CLOUD_WIND     = vec2(2.4, 0.9); // blocks per second

float aureliaCloudHash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float aureliaCloudNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(aureliaCloudHash(i), aureliaCloudHash(i + vec2(1.0, 0.0)), u.x),
               mix(aureliaCloudHash(i + vec2(0.0, 1.0)), aureliaCloudHash(i + vec2(1.0, 1.0)), u.x),
               u.y);
}

// Four octaves, each rotated so the lattice never lines up into a grid.
float aureliaCloudFbm(vec2 p) {
    const mat2 rot = mat2(0.80, 0.60, -0.60, 0.80);
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; ++i) {
        sum += amp * aureliaCloudNoise(p);
        p = rot * p * 2.03 + 17.1;
        amp *= 0.5;
    }
    return sum; // ~[0, 0.94]
}

// Composite the layer over `sky` for a world-space view direction.
vec3 aureliaApplyCloudLayer(vec3 sky, vec3 direction, vec3 sunDirection, vec3 moonDirection, float rain) {
    // Below the horizon there is no layer; near it the plane runs to infinity,
    // so it fades out instead of aliasing into a band.
    if (direction.y <= 0.015) return sky;
    float horizonFade = smoothstep(0.015, 0.20, direction.y);

    // Intersect the camera ray with the plane. Above the layer, keep it a
    // ceiling-free sky rather than drawing it underneath.
    float height = AURELIA_CLOUD_ALTITUDE - cameraPosition.y;
    if (height <= 8.0) return sky;
    vec2 world = cameraPosition.xz + direction.xz * (height / direction.y)
        + AURELIA_CLOUD_WIND * frameTimeCounter;

    vec2 p = world * AURELIA_CLOUD_SCALE;
    float n = aureliaCloudFbm(p);
    // Rain thickens the deck toward overcast.
    float coverage = mix(0.50, 0.30, rain);
    float density = smoothstep(coverage, coverage + 0.28, n);
    if (density <= 0.0) return sky;

    // Lighting: a second, offset tap toward the sun approximates self-shadow
    // (thicker toward the sun = darker underside), the cheapest cue that turns
    // a flat stencil into a lit cloud. Plus forward scatter near the sun.
    float sunUp = aureliaSunVisibility();
    vec2 toSun = normalize(sunDirection.xz + vec2(1e-4)) * 0.35;
    float towardSun = aureliaCloudFbm(p + toSun);
    float selfShadow = clamp((towardSun - n) * 2.5 + 0.55, 0.0, 1.0);

    vec3 sunColor = aureliaSunColor(max(sunDirection.y, 0.0));
    float scatter = pow(max(dot(direction, sunDirection), 0.0), 6.0);
    vec3 dayLit = sunColor * (0.55 + 0.75 * selfShadow + 0.9 * scatter);
    // Shadowed base takes the dome's own blue so the clouds sit in the sky.
    vec3 dayBase = mix(sky, vec3(0.62, 0.66, 0.74), 0.5);
    vec3 dayCloud = mix(dayBase, dayLit, 0.65);

    // Night: dim cool moonlit grey, never brighter than a faint lift.
    float moonUp = smoothstep(-0.05, 0.10, moonDirection.y);
    vec3 nightCloud = vec3(0.020, 0.024, 0.034) * (0.6 + 0.8 * selfShadow) * (0.5 + 0.5 * moonUp);
    vec3 cloud = mix(nightCloud, dayCloud, sunUp);

    // Rain: desaturate and darken to a slate deck. In game a partial flatten
    // left rain clouds brighter than the overcast sky behind them.
    float luma = dot(cloud, vec3(0.2126, 0.7152, 0.0722));
    cloud = mix(cloud, vec3(luma) * vec3(0.92, 0.96, 1.02), rain);
    cloud *= mix(1.0, 0.42, rain);

    // Thin edges stay translucent; cores are nearly opaque.
    float alpha = density * horizonFade * 0.92;
    return mix(sky, cloud, alpha);
}
