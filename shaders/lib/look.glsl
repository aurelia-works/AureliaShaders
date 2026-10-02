// ============================================================================
// Aurelia Look Contract v1  (see docs/LOOK-CONTRACT.md)
// ============================================================================
//
// Single source of truth for the visual quantities shared by Aurelia Shaders
// and, later, Aurelia LOD. This is a contracts/deduplication file: every value
// and expression below is behaviour-identical to the code it replaces. It is
// not the place to tune the look; tuning starts in P3.1.
//
// Binding rules
//   - Directions are world/player-space unit vectors. Player space is
//     camera-relative and unrotated (docs/PHASE2A.md). Celestial uniforms such
//     as sunPosition are view space, so they are rotated by
//     mat3(gbufferModelViewInverse) exactly once, here.
//   - Colours are linear RGB. sRGB decoding stays where a value first enters
//     the pipeline (lib/color.glsl); this file never re-encodes.
//   - GLSL is the source of truth. shaders.properties cannot read GLSL, so
//     option values that also shape the look are duplicated there of
//     necessity; docs/LOOK-CONTRACT.md lists them and the sync rule.
//   - Aurelia LOD mirrors this contract in Java in P3.7. Nothing here is read
//     by the LOD yet.
//
// PROVISIONAL items are named now for P3.1 to tune and are intentionally
// unreferenced in v1.

// Contract uniform inputs (declared once, here).
uniform vec3 sunPosition;             // view space, length 100
uniform vec3 moonPosition;            // view space, length 100
uniform vec3 fogColor;                // sRGB-encoded
uniform vec3 skyColor;                // sRGB-encoded
uniform float rainStrength;           // [0,1]
uniform mat4 gbufferModelViewInverse; // view space -> player/world space

// --- Per-frame constants ----------------------------------------------------
// The sun/moon world directions and the linear sky/fog colours depend only on
// uniforms, yet were re-derived in every fragment (a mat3 rotate + normalize
// per body, and a vec3 pow per sRGB decode, several times per pixel). A
// program opts in by defining AURELIA_FRAME_VERTEX before including this file
// in its vertex stage (and calling aureliaWriteFrameConstants()) and
// AURELIA_FRAME_FRAGMENT in its fragment stage. The values then cross as flat
// varyings: computed once per vertex with the identical expression, so the
// result is the same value, not an approximation. Programs that do not opt in
// (final, and anything new) keep the direct uniform path below.
#if defined(AURELIA_FRAME_VERTEX)
flat out vec3 aureliaFrameSunDir;
flat out vec3 aureliaFrameMoonDir;
flat out vec3 aureliaFrameSkyLinear;
flat out vec3 aureliaFrameFogLinear;
#elif defined(AURELIA_FRAME_FRAGMENT)
flat in vec3 aureliaFrameSunDir;
flat in vec3 aureliaFrameMoonDir;
flat in vec3 aureliaFrameSkyLinear;
flat in vec3 aureliaFrameFogLinear;
#endif

// --- Sun direction and height ----------------------------------------------

vec3 aureliaSunDirection() {
#ifdef AURELIA_FRAME_FRAGMENT
    return aureliaFrameSunDir;
#else
    return normalize(mat3(gbufferModelViewInverse) * sunPosition);
#endif
}

// The moon is a separate body from the shadow light: shadowLightPosition is the
// highest celestial body (the sun by day), so the night disc must come from
// moonPosition, not from the shadow source.
vec3 aureliaMoonDirection() {
#ifdef AURELIA_FRAME_FRAGMENT
    return aureliaFrameMoonDir;
#else
    return normalize(mat3(gbufferModelViewInverse) * moonPosition);
#endif
}

// Linear forms of Minecraft's sRGB sky and fog colours. lib/color.glsl is
// always included before this file.
vec3 aureliaSkyColorLinear() {
#ifdef AURELIA_FRAME_FRAGMENT
    return aureliaFrameSkyLinear;
#else
    return aureliaSrgbToLinear(skyColor);
#endif
}

vec3 aureliaFogColorLinear() {
#ifdef AURELIA_FRAME_FRAGMENT
    return aureliaFrameFogLinear;
#else
    return aureliaSrgbToLinear(fogColor);
#endif
}

#ifdef AURELIA_FRAME_VERTEX
void aureliaWriteFrameConstants() {
    aureliaFrameSunDir = aureliaSunDirection();
    aureliaFrameMoonDir = aureliaMoonDirection();
    aureliaFrameSkyLinear = aureliaSkyColorLinear();
    aureliaFrameFogLinear = aureliaFogColorLinear();
}
#endif

float aureliaSunHeight() {
    return aureliaSunDirection().y;
}

// Directional-source visibility. Below the horizon the sun contributes no
// sunlight. v1 value, unchanged from lib/lighting.glsl.
float aureliaSunVisibility() {
    return smoothstep(-0.10, 0.08, aureliaSunHeight());
}

// Day -> night weight. PROVISIONAL: named for P3.1, unreferenced in v1.
float aureliaNightFactor() {
    return 1.0 - smoothstep(-0.15, 0.05, aureliaSunHeight());
}

// Horizon warmth factor from sun height. v1 value.
float aureliaHorizonFactor(float height) {
    // Warm band spans up to ~28 deg of sun elevation, not 19: dawn and golden
    // hour both sit above the old band edge, so low-sun times rendered with no
    // warmth at all while the sun was plainly low in the sky.
    return 1.0 - smoothstep(0.05, 0.48, max(height, 0.0));
}

// --- Sun colour -------------------------------------------------------------

vec3 aureliaSunColor(float height) {
    float horizon = aureliaHorizonFactor(height);
    const vec3 noon   = vec3(1.00, 0.97, 0.91);
    const vec3 sunset = vec3(1.00, 0.57, 0.31);
    return mix(noon, sunset, horizon);
}

// --- Ambient / sky colours (linear) -----------------------------------------

const vec3  AURELIA_AMBIENT_NEUTRAL       = vec3(0.50);
const vec3  AURELIA_AMBIENT_SKY           = vec3(0.43, 0.50, 0.62);
const float AURELIA_AMBIENT_SKY_MIX_BASE  = 0.18;
const float AURELIA_AMBIENT_SKY_MIX_RANGE = 0.08;
const float AURELIA_AMBIENT_SKY_SCALE     = 0.44;

vec3 aureliaAmbientTint(float skyLight) {
    return mix(AURELIA_AMBIENT_NEUTRAL, AURELIA_AMBIENT_SKY,
               AURELIA_AMBIENT_SKY_MIX_BASE + AURELIA_AMBIENT_SKY_MIX_RANGE * skyLight);
}

// Zenith gradient base. P3.1 uses this as the base of the atmosphere gradient
// (lib/sky.glsl blends it toward a night blue as the sun drops) and the
// no-atmosphere fallback still uses it unchanged. Still a tuning surface.
const float AURELIA_ZENITH_SCALE  = 0.74;
const vec3  AURELIA_ZENITH_OFFSET = vec3(0.010, 0.020, 0.040);

vec3 aureliaZenithColor(vec3 skyColorLinear) {
    return skyColorLinear * AURELIA_ZENITH_SCALE + AURELIA_ZENITH_OFFSET;
}

// Horizon anchor: the linear form of fogColor, which is also where the fog
// resolves at maximum distance. Identity, kept named so sky and fog cannot
// silently drift apart.
vec3 aureliaHorizonColor(vec3 fogColorLinear) {
    return fogColorLinear;
}

// --- Fog curve --------------------------------------------------------------
// The band/mud problem came from a single global exponential: it hit hard at
// mid-range and clamped at 0.85, so any distant terrain was painted flat.
// The curve is gentler and the clamp is lower, so the far edge still shows
// terrain form through the haze (the MakeUp/Reimagined "depth" read) while
// nearby blocks stay crisp.
const float AURELIA_FOG_DENSITY_K  = 0.0045;
const float AURELIA_FOG_RAIN_MIN   = 0.80;
const float AURELIA_FOG_RAIN_RANGE = 0.20;
const float AURELIA_FOG_MAX        = 0.78;

float aureliaFogFactor(float distanceToCamera, float density, float rain) {
    float fog = 1.0 - exp(-distanceToCamera * AURELIA_FOG_DENSITY_K * density);
    return clamp(fog * (AURELIA_FOG_RAIN_MIN + AURELIA_FOG_RAIN_RANGE * rain),
                 0.0, AURELIA_FOG_MAX);
}

// --- Underwater fog curve ---------------------------------------------------
// The air curve above (K 0.0045, cap 0.78) is tuned for hundreds of blocks of
// atmosphere. A water column extinguishes far sooner, so underwater has its own
// denser curve under AURELIA_WATER_UNDERWATER. It is the same curve shape and
// the same rain response, reusing AURELIA_FOG_RAIN_MIN/RANGE, so weather moves
// both media the same way; only the extinction constant and the cap differ.
// The cap stays below 1.0 so the deepest view keeps a little structure: this
// must read as water, never as opaque soup. None of the air constants above are
// touched, so with the option off this file is byte-identical to the accepted
// state.
#ifdef AURELIA_WATER_UNDERWATER
const float AURELIA_UNDERWATER_FOG_K   = 0.070;
const float AURELIA_UNDERWATER_FOG_MAX = 0.86;

float aureliaUnderwaterFogFactor(float distanceToCamera, float rain) {
    float fog = 1.0 - exp(-distanceToCamera * AURELIA_UNDERWATER_FOG_K);
    return clamp(fog * (AURELIA_FOG_RAIN_MIN + AURELIA_FOG_RAIN_RANGE * rain),
                 0.0, AURELIA_UNDERWATER_FOG_MAX);
}
#endif

// The fog APPLY step moved to lib/sky.glsl, next to the dome palette it now
// fades toward: sky, fog and water all evaluate aureliaSkyDome, so the three
// systems cannot drift apart. This file keeps the distance/density curve,
// which is unchanged.

// --- Weather attenuation ----------------------------------------------------

const float AURELIA_RAIN_SUN_DIM       = 0.38; // direct sun and its water glint
const float AURELIA_RAIN_SKY_FLATTEN   = 0.45; // sky ramp lerp toward horizon
const float AURELIA_RAIN_GLOW_DIM      = 0.55; // solar glow dimming
const float AURELIA_RAIN_SHADOW_SOFTEN = 0.35; // shadow-strength reduction

// --- Exposure ---------------------------------------------------------------
// Exposure is applied in lib/tonemap.glsl through the AURELIA_EXPOSURE Iris
// option (P3.2). This constant remains the documented identity baseline the
// option's value list is built around; it is not read at runtime.
const float AURELIA_EXPOSURE_BASELINE = 1.0;
