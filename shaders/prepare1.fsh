#version 330 compatibility

// Sky irradiance texels of the LUT (Phase 5), integrated from the sky
// radiance prepare.fsh just wrote. Every texel is copied through; the four
// irradiance texels of the reserved row (up, toward the sun, away from it,
// down) sum the LUT over a cosine-weighted spiral instead.
//
// Marching the atmosphere again for these took hundreds of dependent steps
// in one SIMD group and held the whole pass for ~1 ms on the M1; a few dozen
// fetches of the finished LUT cost next to nothing. The ambient light now
// also matches the visible sky exactly, overcast, airglow and city glow
// included. Below the horizon the LUT holds haze for the fog, so irradiance
// sees the lit ground there instead.

#include "/lib/options.glsl"
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#define AURELIA_SKY_LUT_READ
#include "/lib/atmosphere.glsl"

/* RENDERTARGETS: 5 */
layout(location = 0) out vec4 aureliaLut;

// Irradiance on a surface with normal n: E = pi * mean(L) over a
// cosine-weighted Fibonacci spiral (area-uniform on the unit disc, lifted
// onto the hemisphere). `ground` is the radiance of the lit ground.
vec3 aureliaIrradiance(vec3 n, vec3 sunDirection, vec3 ground) {
    vec3 tangent = abs(n.y) < 0.9 ? normalize(cross(vec3(0.0, 1.0, 0.0), n)) : vec3(1.0, 0.0, 0.0);
    vec3 bitangent = cross(n, tangent);
    vec3 sum = vec3(0.0);
    const int samples = 48;
    for (int i = 0; i < samples; ++i) {
        float r = sqrt((float(i) + 0.5) / float(samples));
        float phi = float(i) * 2.39996323;
        vec2 disc = r * vec2(cos(phi), sin(phi));
        vec3 direction = tangent * disc.x + bitangent * disc.y + n * sqrt(max(1.0 - r * r, 0.0));
        sum += direction.y > 0.0 ? aureliaSkyRadiance(direction, sunDirection) : ground;
    }
    return sum * (AURELIA_PI / float(samples));
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    aureliaLut = texelFetch(colortex5, texel, 0);
    if (texel.y < AURELIA_LUT_ROWS || texel.x < AURELIA_LUT_SKY_UP || texel.x > AURELIA_LUT_SKY_DOWN) return;

    vec3 sunDirection = aureliaSunDirection();
    vec3 skyUp = aureliaIrradiance(vec3(0.0, 1.0, 0.0), sunDirection, vec3(0.0));
    // The ground under the camera: Lambertian, lit by the sky and by the
    // direct sun or moon (the moon is opposite the sun).
    vec3 direct = aureliaSunLight() * max(sunDirection.y, 0.0) + aureliaMoonLight() * max(-sunDirection.y, 0.0);
    vec3 ground = AURELIA_GROUND_ALBEDO * (skyUp + direct) * (1.0 / AURELIA_PI);

    vec3 light = skyUp;
    if (texel.x == AURELIA_LUT_SKY_DOWN) {
        light = ground * AURELIA_PI;
    } else if (texel.x != AURELIA_LUT_SKY_UP) {
        vec2 axis = aureliaSunAzimuthAxis(sunDirection);
        vec3 towardSun = vec3(axis.x, 0.0, axis.y);
        light = aureliaIrradiance(texel.x == AURELIA_LUT_SKY_TOWARD ? towardSun : -towardSun, sunDirection, ground);
    }
    aureliaLut = vec4(light, 1.0);
}
