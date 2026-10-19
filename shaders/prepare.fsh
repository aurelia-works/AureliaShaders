#version 330 compatibility

// Sky-view LUT, once per frame, before any geometry (lib/atmosphere.glsl).
// 16k texels of a 20-step single-scattering march plus eight reserved texels
// (light colours and sky irradiance); every later program reads the result
// with one fetch instead of evaluating a sky model per pixel.

#include "/lib/options.glsl"
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#define AURELIA_ATMOSPHERE_INTEGRATE
#include "/lib/atmosphere.glsl"

uniform int moonPhase; // 0 full .. 4 new .. 7

/*
const int colortex5Format = RGBA16F;
const bool colortex5Clear = false;
*/

/* RENDERTARGETS: 5 */
layout(location = 0) out vec4 aureliaLut;

// Night-sky floor: airglow and starlight, the light that is left on a
// moonless night far from a city. Faint and blue-shifted on screen by the
// final pass's Purkinje term, not here.
const vec3 AURELIA_NIGHT_AIRGLOW = vec3(0.00045, 0.00055, 0.00075);

// Urban skyglow: city light scattered back down by the low air, warm (sodium
// and warm-white LED) and hugging the horizon. Night only; overcast doubles
// it, because a cloud deck reflects the city back.
vec3 aureliaCityGlow(vec3 direction, float night, float overcast) {
#ifdef AURELIA_CITY_GLOW
    float low = exp(-max(direction.y, 0.0) * 7.0);
    return vec3(0.0042, 0.0026, 0.0014) * (low * night * (1.0 + overcast));
#else
    return vec3(0.0);
#endif
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec3 sunDirection = aureliaSunDirection();
    float altitude = aureliaCameraAltitude(cameraPosition.y);
    float overcast = clamp(rainStrength, 0.0, 1.0);
    float phase = float(moonPhase);
    float moonIrradiance = AURELIA_MOON_IRRADIANCE * mix(0.25, 1.0, 0.5 + 0.5 * cos(phase * (AURELIA_PI / 4.0)));
    float night = 1.0 - smoothstep(-0.20, 0.02, sunDirection.y);

    // Light under the cloud deck on flat ground: what the deck lets through
    // of the clear-day sun and sky, as one diffuse quantity. Closed form, so
    // every LUT texel can blend toward overcast without integrating the sky.
    float muSun = sunDirection.y;
    vec3 sunGround = AURELIA_SUN_IRRADIANCE * aureliaTransmittanceToSpace(altitude, max(muSun, 0.02))
                   * smoothstep(-0.12, 0.25, muSun) * (max(muSun, 0.0) + 0.12);
    vec3 moonGround = moonIrradiance * aureliaTransmittanceToSpace(altitude, max(-muSun, 0.02))
                    * smoothstep(-0.12, 0.25, -muSun) * (max(-muSun, 0.0) + 0.12);
    vec3 underDeck = 0.30 * (sunGround + moonGround) * vec3(0.92, 0.97, 1.05);

    if (texel.y < AURELIA_LUT_ROWS) {
        vec3 direction = aureliaSkyLutDirection(gl_FragCoord.xy, sunDirection);
        // Below the horizon the camera would see the planet's ground a few
        // kilometres off; in Minecraft that is the world past the render
        // distance, which the fog has to dissolve into. So the lower half is
        // the horizon haze along the same azimuth, dimming toward the nadir.
        float below = smoothstep(0.0, -0.55, direction.y);
        vec3 rayDirection = direction.y < 0.012
            ? normalize(vec3(direction.xz, 0.012).xzy) : direction;
        vec3 clear = aureliaScatter(altitude, rayDirection, sunDirection, AURELIA_SUN_IRRADIANCE, moonIrradiance, 20)
                   * mix(1.0, 0.45, below);
        vec3 sky = mix(clear, aureliaOvercastRadiance(direction, underDeck), overcast);
        sky += AURELIA_NIGHT_AIRGLOW * smoothstep(-0.1, 0.1, direction.y) + aureliaCityGlow(direction, night, overcast);
        aureliaLut = vec4(sky, 1.0);
        return;
    }

    // The sky irradiance texels (up, toward, away, down) are integrated from
    // this LUT by prepare1.fsh; here only the direct light.
    vec3 light = vec3(0.0);
    if (texel.x == AURELIA_LUT_SUN) {
        // The deck blocks nearly all of the direct beam.
        light = AURELIA_SUN_IRRADIANCE * aureliaTransmittanceToSpace(altitude, muSun) * (1.0 - 0.94 * overcast);
    } else if (texel.x == AURELIA_LUT_MOON) {
        light = moonIrradiance * aureliaTransmittanceToSpace(altitude, -muSun) * (1.0 - 0.94 * overcast);
    } else if (texel.x == AURELIA_LUT_CLOUD_LIGHT) {
        // Direct light at the cloud deck (~1.6 km): clouds stay sunlit, and
        // turn pink, for minutes after the ground has fallen into shadow.
        float cloudAltitude = max(altitude, 1600.0);
        light = AURELIA_SUN_IRRADIANCE * aureliaTransmittanceToSpace(cloudAltitude, muSun)
              + moonIrradiance * aureliaTransmittanceToSpace(cloudAltitude, -muSun);
    }
    aureliaLut = vec4(light, 1.0);
}
