// Every program that uses an option includes this file. Values are compile-time
// Iris options; changing them recompiles the affected program.
#define AURELIA_DIRECT_LIGHT 1.00 // [0.70 0.85 0.90 1.00 1.05 1.15 1.20] Direct sunlight strength
#define AURELIA_SKY_SATURATION 1.00 // [0.85 0.95 1.00 1.05 1.15] Final colour saturation
#define AURELIA_LENS_FLARE // Sun glare, streak and lens ghosts when the sun is in view
#define AURELIA_LENS_FLARE_STRENGTH 1.00 // [0.50 0.75 1.00 1.50 2.00] Lens flare strength
//#define AURELIA_GOD_RAYS // Screen-space light shafts from the sun through gaps in terrain
#define AURELIA_GOD_RAYS_STRENGTH 1.00 // [0.50 0.75 1.00 1.50 2.00] God ray strength
//#define AURELIA_BLOOM // Soft glow around bright light, from the scene's mip chain
#define AURELIA_BLOOM_STRENGTH 1.00 // [0.50 0.75 1.00 1.50 2.00] Bloom strength
//#define AURELIA_SHARPEN // Contrast-adaptive sharpening
#define AURELIA_SHARPEN_STRENGTH 0.50 // [0.25 0.50 0.75 1.00] Sharpening strength
#define AURELIA_EXPOSURE 1.00 // [0.85 0.95 1.00 1.05 1.15] Pre-tonemap exposure
#define AURELIA_CONTRAST 1.00 // [0.90 0.95 1.00 1.05 1.10] Post-tonemap micro-contrast
#define AURELIA_FOG_DENSITY 1.00 // [0.70 0.85 0.90 1.00 1.20] Atmospheric fog density
#define AURELIA_NIGHT_LIFT 0.16 // [0.08 0.12 0.16 0.20 0.22] Playable night ambient floor
#define AURELIA_DEBUG_VIEW 0 // [0 1 2 3 4 5 6] Debug output mode

// --- Phase 5: physical rendering (docs/PHASE5.md) ----------------------------
// Sun path tilt, Iris's sunPathRotation (declared in final.fsh): a mid-latitude
// sun that never stands overhead, so noon keeps modelled shadows and shapes.
#define AURELIA_SUN_PATH_ROTATION -30.0 // [0.0 -10.0 -20.0 -30.0 -40.0] Sun path tilt in degrees
#define AURELIA_CITY_GLOW // Warm urban skyglow on the night horizon
#define AURELIA_MATERIALS // Block materials: metals, polished stone, concrete, glass and emissive lamps
#define AURELIA_SSR // Screen-space reflections on water, glass, metal, polished stone and wet streets
#define AURELIA_SSR_STEPS 16 // [8 12 16 24] Reflection ray steps
#define AURELIA_WATER_REFRACTION // Water bends and tints the view of the bed below it
#define AURELIA_AUTO_EXPOSURE // Eye adaptation: exposure follows the scene's brightness
#define AURELIA_PURKINJE // Night vision: dim scenes shift blue and lose colour

// Atmosphere/sky treatment. Boolean so it is revertible from the Iris options
// screen without a code edit; Potato disables it, the other presets enable it
// explicitly. Consumed by gbuffers_skybasic and lib/sky.glsl.

// Soft cloud treatment (P4): analytic character on the vanilla cloud slab -
// dissolved edges, pseudo-thickness shading, a sun-relative warm rim and a
// rain response, all ALU only with no texture, pass or target. Potato keeps
// the simplest treatment; the other presets enable it explicitly. A boolean
// option is recognised by this pack by its inline comment, so keep it.
// Painted 2D cloud layer in the sky pass (lib/clouds2d.glsl): procedural, sky
// pixels only, replaces the vanilla cloud slab while on. Potato keeps vanilla.
#define AURELIA_FOG_HAZE // Height fog (thins with altitude) and a warm sun haze in the fog
#define AURELIA_CLOUD_LAYER // Painted cloud layer: soft lit clouds drawn in the sky pass, replaces vanilla clouds
#define AURELIA_CLOUD_HIGH // High cirrus layer above the painted clouds (needs the cloud layer)
#define AURELIA_CLOUDS_SOFT // Soft clouds: dissolved edges, core shading, sun rim, rain response

// Shadow-map allocation and distance are reload-bound Iris options. Adaptive
// deliberately never changes them at runtime; it only changes PCF tap count.
#define AURELIA_SHADOW_RESOLUTION 1024 // [512 1024 1536] Shadow-map edge resolution
#define AURELIA_SHADOW_DISTANCE 96 // [64 96 128] Shadow coverage distance in blocks
#define AURELIA_SHADOW_FILTER_MAX 2 // [1 2 3] Maximum PCF quality tier
#define AURELIA_SHADOW_STRENGTH 1.00 // [0.70 0.82 0.90 1.00] Direct-light shadow strength (1.00 is physical: the sky fill lights the shade)
#define AURELIA_SHADOWS // Optional directional shadow map
// Which non-terrain casters draw into the shadow map: 0 terrain only, 1 plus the
// player, 2 every entity and block entity. Read only by shaders.properties
// (Iris's shadowEntities / shadowPlayer / shadowBlockEntities); every caster is
// another CPU draw in the shadow pass, which is what a busy town pays for.
#define AURELIA_SHADOW_CASTERS 1 // [0 1 2] Entity shadow casters

#define AURELIA_ADAPTIVE // Smooth frame-time controller (master switch for adaptive shadow filtering)
#define AURELIA_SHADOW_ADAPTIVE // Runtime PCF budget only; no shadow-map reallocations
// The controller's only runtime consumer is the PCF budget, so AURELIA_ADAPTIVE
// off means a fixed filter. (Iris lists options from the #define lines above;
// this #undef is invisible to it and only applies after the values are set.)
// Plain #ifndef on purpose: Iris only registers a boolean option it sees in a
// simple #ifdef/#ifndef test; `#if !defined(X) && ...` hid this toggle from
// the menu in game ("Unable to resolve shader pack option menu element").
#ifndef AURELIA_ADAPTIVE
    #undef AURELIA_SHADOW_ADAPTIVE
#endif

// Analytic water surface: wave-perturbed normal, Fresnel, sky reflection and a
// sun glint. Behind a boolean so it is revertible from the Iris options screen
// without a code edit, and so the fallback replacement and the new shading stay
// separable. Potato disables it; the other presets enable it explicitly.
// A boolean option is recognised by this pack by its inline comment, so keep it.
#define AURELIA_WATER_SURFACE // Analytic water: Fresnel, sky reflection, wave normal, sun glint
#define AURELIA_WATER_ANIMATED // Animated water: two travelling analytic waves, no texture noise

// Depth-based body colour: one depthtex1 read reconstructs the water column
// thickness so shallow water reads clearer and deep water settles to the
// accepted palette. Only the water body term changes; Fresnel, reflection,
// glint and alpha are untouched. Potato and Low disable it; the other presets
// enable it explicitly. A boolean option is recognised by this pack by its
// inline comment, so keep it.
#define AURELIA_WATER_DEPTH // Depth-based water body: shallow reads clearer, deep settles to the accepted palette

// Shoreline softness: reuses the depth-based thickness to fade the water's
// alpha, and ease the reflection weight, as the column thins to nothing, so
// shallow water dissolves into the floor instead of ending on a hard albedo
// edge. No foam, no wave change, no extra depth read, no extra pass. Potato and
// Low disable it; the other presets enable it explicitly. A boolean option is
// recognised by this pack by its inline comment, so keep it.
#define AURELIA_WATER_SHORE // Shoreline softness: fades the water edge against the floor using the depth-based thickness

// Underwater atmosphere: when the camera is submerged (Iris uniform
// isEyeInWater == 1), terrain, entities, the water surface, weather and clouds
// fade toward a palette-derived water colour on a denser curve, the vertical
// term reads brighter toward the surface, and the sky background becomes the
// same colour so nothing above the water leaks through a submerged frame. Uses
// the existing fog contract (lib/sky.glsl) and curve family (lib/look.glsl), so
// there is no parallel system, no extra pass, no render target, no noise and no
// extra texture read: one exp per fogged fragment. Lava (isEyeInWater == 2) and
// air (0) keep the accepted behaviour. Potato and Low disable it; the other
// presets enable it explicitly. A boolean option is recognised by this pack by
// its inline comment, so keep it.
#define AURELIA_WATER_UNDERWATER // Underwater atmosphere: depth-graded water fog and sky

// Forward-light additions that are per-pixel ALU only: no new uniform, sampler,
// render target, or pass, and neither touches the existing direct-light or
// shadow terms. Potato disables both; the other presets enable them explicitly.
#define AURELIA_OPAQUE_ICE // Plain ice renders opaque: no blending or sorting (block.properties)
#define AURELIA_WAVING // Plants and leaves sway in the wind (vertex only)
#define AURELIA_WAVING_STRENGTH 1.00 // [0.50 0.75 1.00 1.50 2.00] Wind sway strength
#define AURELIA_FOLIAGE_TRANSLUCENCY // Backlit leaves and grass pick up sunlight instead of going black
#define AURELIA_WET_SURFACES // Rain soaks terrain: darker ground, puddles, sky reflection, ripples

// Distant-rain curtain: EXPERIMENTAL, OFF in every preset. In-game evidence
// showed native Minecraft weather already surrounds the player at all test
// altitudes (Y78-Y155), so production presets carry no procedural streaks,
// no altitude estimation and no final-pass rain compositing. The option
// remains for manual experiments: enabling it adds the procedural layer
// (Potato excludes it by design). Keep the double-slash form so Iris still
// lists it as an unchecked boolean.
//#define AURELIA_DISTANT_RAIN // EXPERIMENTAL: procedural distant-rain curtain
#define AURELIA_DISTANT_RAIN_LAYERS 2 // [1 2] EXPERIMENTAL: curtain layers (only when the curtain is on)
