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
uniform vec3 fogColor;                // sRGB-encoded
uniform vec3 skyColor;                // sRGB-encoded
uniform float rainStrength;           // [0,1]
uniform mat4 gbufferModelViewInverse; // view space -> player/world space

// --- Sun direction and height ----------------------------------------------

vec3 aureliaSunDirection() {
    return normalize(mat3(gbufferModelViewInverse) * sunPosition);
}

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
    return 1.0 - smoothstep(0.04, 0.34, max(height, 0.0));
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
const float AURELIA_AMBIENT_SKY_SCALE     = 0.60;

vec3 aureliaAmbientTint(float skyLight) {
    return mix(AURELIA_AMBIENT_NEUTRAL, AURELIA_AMBIENT_SKY,
               AURELIA_AMBIENT_SKY_MIX_BASE + AURELIA_AMBIENT_SKY_MIX_RANGE * skyLight);
}

// Zenith starting definition. PROVISIONAL: P3.1 will replace this shape; v1 is
// the exact expression previously inline in gbuffers_skybasic.fsh.
const float AURELIA_ZENITH_SCALE  = 0.82;
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

const float AURELIA_FOG_DENSITY_K  = 0.0035;
const float AURELIA_FOG_RAIN_MIN   = 0.80;
const float AURELIA_FOG_RAIN_RANGE = 0.20;
const float AURELIA_FOG_MAX        = 0.85;

float aureliaFogFactor(float distanceToCamera, float density, float rain) {
    float fog = 1.0 - exp(-distanceToCamera * AURELIA_FOG_DENSITY_K * density);
    return clamp(fog * (AURELIA_FOG_RAIN_MIN + AURELIA_FOG_RAIN_RANGE * rain),
                 0.0, AURELIA_FOG_MAX);
}

// --- Weather attenuation ----------------------------------------------------

const float AURELIA_RAIN_SUN_DIM       = 0.38; // direct sun and its water glint
const float AURELIA_RAIN_SKY_FLATTEN   = 0.45; // sky ramp lerp toward horizon
const float AURELIA_RAIN_GLOW_DIM      = 0.55; // solar glow dimming
const float AURELIA_RAIN_SHADOW_SOFTEN = 0.35; // shadow-strength reduction

// --- Exposure ---------------------------------------------------------------
// v1 applies no exposure: the baseline is identity 1.0 and tonemap.glsl is
// intentionally unchanged. PROVISIONAL for P3.1+.
const float AURELIA_EXPOSURE_BASELINE = 1.0;
