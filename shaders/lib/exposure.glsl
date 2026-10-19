// Eye adaptation (Phase 5). composite.fsh meters the frame into a 1x1
// history target (colortex4: r = adapted log2 luminance, a = 1 once valid);
// final.fsh turns it into an exposure. Partial adaptation: scenes darker than
// AURELIA_EV_MIN are not brightened further, so night and caves stay dark,
// and a bright snowfield is not pulled below AURELIA_EV_MAX.
#ifndef AURELIA_EXPOSURE_GLSL
#define AURELIA_EXPOSURE_GLSL

const float AURELIA_EV_MIN = -6.4;  // moonlit field: night stays night, not grey day
const float AURELIA_EV_MAX = 1.2;   // sunlit snow and sand
const float AURELIA_EXPOSURE_KEY = 0.21; // the metered average lands a little over mid grey

#ifdef AURELIA_EXPOSURE_READ
uniform sampler2D colortex4;

// Linear multiplier for the scene before the film curve.
float aureliaExposure() {
#ifdef AURELIA_AUTO_EXPOSURE
    vec4 metered = texelFetch(colortex4, ivec2(0), 0);
    float ev = metered.a > 0.5 ? metered.r : -1.0;
#else
    // Fixed exposure keyed to the time of day: the LUT's light on flat ground.
    vec3 sun = aureliaLutTexel(AURELIA_LUT_SUN).rgb;
    float ground = dot(sun * max(aureliaSunDirection().y, 0.0) + aureliaLutTexel(AURELIA_LUT_SKY_UP).rgb
                     + aureliaLutTexel(AURELIA_LUT_MOON).rgb * max(aureliaMoonDirection().y, 0.0),
                       vec3(0.2126, 0.7152, 0.0722)) * (0.25 / AURELIA_PI);
    float ev = clamp(log2(max(ground, 1e-6)), AURELIA_EV_MIN, AURELIA_EV_MAX);
#endif
    return AURELIA_EXPOSURE_KEY * exp2(-ev);
}
#endif

#endif
