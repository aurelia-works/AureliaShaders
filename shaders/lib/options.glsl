// Every program that uses an option includes this file. Values are compile-time
// Iris options; changing them recompiles the affected program.
#define AURELIA_DIRECT_LIGHT 1.00 // [0.70 0.85 0.90 1.00 1.15] Direct sunlight strength
#define AURELIA_SKY_SATURATION 1.05 // [0.85 0.95 1.00 1.05 1.15] Final colour saturation
#define AURELIA_EXPOSURE 1.00 // [0.85 0.95 1.00 1.05 1.15] Pre-tonemap exposure
#define AURELIA_CONTRAST 1.00 // [0.90 0.95 1.00 1.05 1.10] Post-tonemap micro-contrast
#define AURELIA_FOG_DENSITY 1.00 // [0.70 0.85 0.90 1.00 1.20] Atmospheric fog density
#define AURELIA_NIGHT_LIFT 0.16 // [0.08 0.12 0.16 0.20 0.22] Playable night ambient floor
#define AURELIA_DEBUG_VIEW 0 // [0 1 2 3 4 5 6] Debug output mode

// Phase 3 atmosphere/sky treatment. Boolean so it is revertible from the Iris
// options screen without a code edit; Potato disables it, the other presets
// enable it explicitly. Consumed by gbuffers_skybasic from P3.1 on.
#define AURELIA_ATMOSPHERE // Analytic sky gradient, sun/moon glow and weather response

// Shadow-map allocation and distance are reload-bound Iris options. Adaptive
// deliberately never changes them at runtime; it only changes PCF tap count.
#define AURELIA_SHADOW_RESOLUTION 1024 // [512 1024 1536] Shadow-map edge resolution
#define AURELIA_SHADOW_DISTANCE 96 // [64 96 128] Shadow coverage distance in blocks
#define AURELIA_SHADOW_FILTER_MAX 2 // [1 2 3] Maximum PCF quality tier
#define AURELIA_SHADOW_STRENGTH 0.82 // [0.70 0.82 0.90] Direct-light shadow strength
#define AURELIA_SHADOWS // Optional directional shadow map

#define AURELIA_ADAPTIVE // Smooth frame-time controller for future secondary effects
#define AURELIA_SHADOW_ADAPTIVE // Runtime PCF budget only; no shadow-map reallocations

// Analytic water surface: wave-perturbed normal, Fresnel, sky reflection and a
// sun glint. Behind a boolean so it is revertible from the Iris options screen
// without a code edit, and so the fallback replacement and the new shading stay
// separable. Potato disables it; the other presets enable it explicitly.
// A boolean option is recognised by this pack by its inline comment, so keep it.
#define AURELIA_WATER_SURFACE // Analytic water: Fresnel, sky reflection, wave normal, sun glint

// Forward-light additions that are per-pixel ALU only: no new uniform, sampler,
// render target, or pass, and neither touches the existing direct-light or
// shadow terms. Potato disables both; the other presets enable them explicitly.
#define AURELIA_FOLIAGE_TRANSLUCENCY // Backlit leaves and grass pick up sunlight instead of going black
#define AURELIA_WETNESS_SPECULAR // Small rain-only sheen so wet weather reads as wet

// Keep an explicit test in source so Iris exposes this boolean option.
#ifdef AURELIA_ADAPTIVE
    #define AURELIA_ADAPTIVE_ENABLED 1
#else
    #define AURELIA_ADAPTIVE_ENABLED 0
#endif
