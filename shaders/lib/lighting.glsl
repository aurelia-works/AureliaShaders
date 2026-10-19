// Physically based forward lighting (Phase 5).
//
// Light comes from five sources, all in the shader units of lib/atmosphere.glsl
// and all read from the sky-view LUT the prepare pass bakes each frame:
//   - the sun and the moon (direct, shadow-mapped), coloured by the air they
//     cross, so noon is white, golden hour amber and a low moon dim and warm;
//   - the sky dome (irradiance from five directions, occluded by Minecraft's
//     sky light level and the vertex AO);
//   - block light, a warm 2700 K-like source with an inverse-square-like
//     falloff over Minecraft's light levels;
//   - emission from lamp blocks (lib/materials.glsl).
// Surfaces are Lambertian diffuse plus a GGX specular lobe for the sun and a
// split-sum sky reflection. Smooth surfaces also get screen-space reflections
// in deferred.fsh, which corrects the sky reflection added here where the
// reflected ray finds geometry.
//
// Inputs are world/player-space normals and the camera-relative player-space
// position; the camera sits at the origin.
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/sky.glsl"
#include "/lib/materials.glsl"
#include "/lib/brdf.glsl"

uniform vec3 shadowLightPosition;

#include "/lib/shadows.glsl"

// Block light: 2700 K-ish, between a candle flame and a warm-white bulb.
const vec3  AURELIA_BLOCK_LIGHT_COLOR = vec3(1.00, 0.58, 0.28);
const float AURELIA_BLOCK_LIGHT       = 2.4;
// Light that reaches everywhere, even a sealed cave: keeps black from being
// pure black. AURELIA_NIGHT_LIFT scales it (0.16 is the reference).
const float AURELIA_MIN_LIGHT         = 0.0035;
// Interreflection: light the LUT's sky integral cannot see, bounced between
// nearby sunlit walls, streets and foliage. Physically the open sky alone
// leaves a shaded wall about three stops under a sunlit one; neighbouring
// lit surfaces lift that to the two-and-a-bit stops a city street shows.
const float AURELIA_SKY_FILL          = 1.35;

// Block light irradiance at a light level (0..1). Level 15 is the source's
// own block; each step is a block further away. An inverse square of that
// distance, plus a slow tail so the far edge of a lit area does not vanish.
vec3 aureliaBlockLight(float level) {
    float distance = 15.0 * (1.0 - clamp(level, 0.0, 1.0));
    float falloff = 1.0 / ((distance + 1.0) * (distance + 1.0)) + 0.045 * level * level;
    return AURELIA_BLOCK_LIGHT_COLOR * (AURELIA_BLOCK_LIGHT * falloff * smoothstep(0.0, 0.07, level));
}

// --- Rain on surfaces ------------------------------------------------------------
#ifdef AURELIA_WET_SURFACES
    #ifdef AURELIA_TERRAIN_FRAGMENT
        #define AURELIA_WET_TERRAIN
    #endif
#endif
#ifdef AURELIA_WET_TERRAIN
uniform float wetness;          // Iris: rainStrength eased over wetnessHalflife
#ifndef AURELIA_NOISETEX_DECLARED
#define AURELIA_NOISETEX_DECLARED
uniform sampler2D noisetex;     // Iris built-in, 256x256 random bytes, linear
#endif

float aureliaWetNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return textureLod(noisetex, (i + f + 0.5) / 256.0, 0.0).g;
}

// One raindrop ring per cell: a jittered centre, a random start time, a ring
// that grows and fades over its life. Returns the ring's surface slope (xz).
vec2 aureliaRippleSlope(vec2 p, float time) {
    vec2 cell = floor(p);
    vec3 random = textureLod(noisetex, (cell + 0.5) / 256.0, 0.0).rgb;
    vec2 local = fract(p) - 0.25 - 0.5 * random.xy;
    float age = fract(time * 0.9 + random.z);
    float distanceToCentre = length(local);
    float band = 1.0 - smoothstep(0.0, 0.05, abs(distanceToCentre - age * 0.45));
    return local / max(distanceToCentre, 1e-3) * (band * (1.0 - age));
}

// Rain under open sky. Porous surfaces darken as water fills them; hard wet
// surfaces turn glossy (a film over the grain, still rough enough that SSR
// blurs what it reflects); up-facing hard ground collects puddles where a
// world-space noise field dips, mirror-smooth and flat apart from raindrop
// rings. Soil, sand and turf (material `drains`) take the water instead:
// darker, a faint sheen, no standing water. The reflections themselves come
// from the shading below and from SSR.
void aureliaWetSurface(inout vec3 albedo, inout AureliaMaterial m, inout vec3 normal,
                       vec3 playerPosition, float skyLevel) {
    float wet = wetness * smoothstep(0.86, 0.97, skyLevel);
    if (wet <= 0.002) return;
    float up = smoothstep(0.70, 0.95, normal.y);
    vec2 world = playerPosition.xz + cameraPosition.xz;
    float field = 0.65 * aureliaWetNoise(world * 0.045) + 0.35 * aureliaWetNoise(world * 0.16 + 31.7);
    float edge = 0.62 - 0.12 * wetness;
    float puddle = smoothstep(edge, edge + 0.06, field) * up * wet * (1.0 - m.translucency) * (1.0 - m.drains);

    // Darkening: a wet surface's albedo moves toward its own square.
    float soak = wet * mix(0.45, 1.0, up) * m.porosity + puddle * 0.5;
    albedo = mix(albedo, albedo * albedo, clamp(soak, 0.0, 1.0));
    float film = mix(0.66, 0.30, m.drains);
    m.smoothness = mix(m.smoothness, max(m.smoothness, film), wet * mix(0.35, 1.0, up) * (1.0 - m.translucency));
    m.smoothness = mix(m.smoothness, 0.97, puddle);
    m.f0 = mix(m.f0, 0.02, puddle);

    if (puddle > 0.0 && rainStrength > 0.0) {
        vec2 slope = aureliaRippleSlope(world * 1.4, frameTimeCounter)
                   + aureliaRippleSlope(world * 1.4 + vec2(0.5, 0.37), frameTimeCounter * 1.13 + 0.4);
        slope *= 0.30 * rainStrength;
        normal = normalize(mix(normal, normalize(vec3(-slope.x, 1.0, -slope.y)), puddle));
    }
}
#endif

// --- Shadows -----------------------------------------------------------------------

vec3 aureliaShadowDirection() {
    return normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
}

// Sun and moon shadow factors, (sun, moon), each 1.0 where unshadowed or where
// that body is not the one the shadow camera is rendering.
//
// Iris points the shadow camera at the highest celestial body and flips from the
// sun to the moon when the sun crosses the horizon. Each body only reads the
// map while the camera actually points at it, and the weight ramps in over the
// first few degrees above the horizon so the hand-over never pops.
vec2 aureliaShadowTerms(vec3 playerPosition, vec3 normal, float skyLight) {
    vec2 terms = vec2(1.0);
#ifdef AURELIA_SHADOWS
    vec3 shadowDir = aureliaShadowDirection();
    vec3 sunDir = aureliaSunDirection();
    vec3 moonDir = aureliaMoonDirection();
    float sunMap = step(0.5, dot(shadowDir, sunDir)) * smoothstep(0.0, 0.05, sunDir.y);
    float moonMap = step(0.5, dot(shadowDir, moonDir)) * smoothstep(0.0, 0.06, moonDir.y);
    if (skyLight > 0.002 && sunMap + moonMap > 0.0) {
        float visibility = aureliaShadowReceive(playerPosition, normal, shadowDir, rainStrength);
        terms = vec2(mix(1.0, visibility, sunMap), mix(1.0, visibility, moonMap));
    }
#endif
    return terms;
}

// Debug-view helper: the combined shadow factor for a fully sky-lit pixel.
float aureliaShadowDebug(vec3 playerPosition, vec3 worldNormal) {
    vec2 terms = aureliaShadowTerms(playerPosition, normalize(worldNormal), 1.0);
    return terms.x * terms.y;
}

// --- Shading -----------------------------------------------------------------------

// The direct contribution of one celestial body: Lambert + GGX, and light
// through thin foliage.
vec3 aureliaDirect(vec3 albedo, vec3 n, vec3 v, vec3 l, vec3 irradiance, AureliaMaterial m,
                   vec3 f0, float alpha, float NdotV) {
    float NdotL = dot(n, l);
    vec3 result = vec3(0.0);
    if (NdotL > 0.0) {
        vec3 h = normalize(l + v);
        float NdotH = max(dot(n, h), 0.0);
        float VdotH = max(dot(v, h), 0.0);
        // The sun is a disc, not a point: its highlight never gets sharper
        // than about alpha 0.02 however smooth the surface.
        float specAlpha = max(alpha, 0.02);
        vec3 fresnel = aureliaSchlick(f0, VdotH);
        vec3 specular = fresnel * (aureliaGgx(NdotH, specAlpha) * aureliaSmithVisibility(NdotV, NdotL, specAlpha));
        vec3 diffuse = albedo * ((1.0 - m.metal) / AURELIA_PI) * (1.0 - fresnel);
        result = (diffuse + specular) * (irradiance * NdotL);
    }
    if (m.translucency > 0.0) {
        // Light through a leaf: diffuse transmission off the back face, with a
        // forward-scattering lobe when the camera looks toward the light.
        float back = max(-NdotL, 0.0);
        float forward = max(dot(-v, l), 0.0);
        forward *= forward;
        forward *= forward;
        result += albedo * albedo * irradiance
                * (m.translucency * (0.35 * back + 0.9 * forward + 0.08) / AURELIA_PI);
    }
    return result;
}

// Full shading of an opaque surface. albedo is linear and excludes the
// vertex AO, which only occludes the indirect terms. Returns radiance.
vec3 aureliaShade(vec3 albedo, vec3 n, vec2 lightLevel, vec3 playerPosition, AureliaMaterial m, float ao,
                  out float sunShadow) {
    vec3 v = -normalize(playerPosition); // surface to eye
    vec3 sunDir = aureliaSunDirection();
    vec3 moonDir = aureliaMoonDirection();
    float NdotV = max(dot(n, v), 1e-3);
    float alpha = aureliaAlpha(m.smoothness);
    float roughness = sqrt(alpha);
    vec3 f0 = mix(vec3(m.f0), albedo, m.metal);

    float skyLevel = clamp(lightLevel.y, 0.0, 1.0);
    float skyVisibility = aureliaSkyVisibility(skyLevel);
    // Direct light needs a view of the sky at all: beyond the shadow map, and
    // under Potato's missing one, this keeps the sun out of caves.
    float openSky = smoothstep(0.30, 0.85, skyLevel);
    vec2 shadowTerms = aureliaShadowTerms(playerPosition, n, skyLevel);
    sunShadow = shadowTerms.x;

    // Seen from under water, a surface is lit through the water above it.
    // Every water block dims sky light by one level, so the level gives the
    // depth away. Sun and moon lose red first along their slant path; the
    // sky fill, already dimmed by the lower level, takes only the colour.
    // The path back to the camera is the underwater fog's job.
    vec3 directThrough = vec3(1.0);
    vec3 skyTint = vec3(1.0);
#ifdef AURELIA_WATER_UNDERWATER
    if (isEyeInWater == 1) {
        float depth = 15.0 * (1.0 - skyLevel);
        vec3 extinction = AURELIA_WATER_ABSORPTION + AURELIA_WATER_SCATTERING;
        directThrough = exp(-extinction * (depth / max(abs(sunDir.y), 0.3)));
        vec3 column = exp(-extinction * depth);
        skyTint = column / max(column.b, max(column.g, column.r));
    }
#endif

    vec3 color = vec3(0.0);
    if (!hasCeiling) {
        vec3 sunLight = aureliaSunLight() * directThrough * (shadowTerms.x * openSky * AURELIA_DIRECT_LIGHT);
        vec3 moonLight = aureliaMoonLight() * directThrough * (shadowTerms.y * openSky);
        color += aureliaDirect(albedo, n, v, sunDir, sunLight, m, f0, alpha, NdotV);
        color += aureliaDirect(albedo, n, v, moonDir, moonLight, m, f0, alpha, NdotV);
    }

    // Indirect: sky dome, block light and the floor, through the vertex AO.
    vec3 envSpecular = aureliaEnvBrdf(f0, NdotV, roughness);
    vec3 diffuseWeight = albedo * ((1.0 - m.metal) / AURELIA_PI) * (1.0 - envSpecular);
    vec3 skyIrradiance = hasCeiling ? vec3(0.0) : aureliaSkyAmbient(n, sunDir) * (skyVisibility * skyTint);
    vec3 indirect = skyIrradiance * (AURELIA_SKY_FILL + 0.4 * m.translucency)
                  + aureliaBlockLight(lightLevel.x)
                  + vec3(AURELIA_MIN_LIGHT * (AURELIA_NIGHT_LIFT / 0.16));
    if (hasCeiling) indirect += AURELIA_NETHER_AMBIENT * 1.5;
    color += diffuseWeight * indirect * ao;

    // Sky reflection. Rough lobes see an average of the dome, so they fade to
    // the irradiance; the sky light level squared stands in for occlusion of
    // the reflected ray indoors. deferred.fsh swaps in SSR where it hits.
    if (!hasCeiling) {
        vec3 r = reflect(-v, n);
        r.y = max(r.y, -0.2);
        vec3 reflected = mix(aureliaSkyRadiance(r, sunDir) * skyTint, skyIrradiance / AURELIA_PI, roughness);
        color += envSpecular * reflected * (skyVisibility * skyVisibility * mix(ao, 1.0, m.smoothness));
    }

    color += albedo * m.emission;
    return color;
}

// Entities, hands and anything else without a block ID: the default rough
// dielectric, full AO.
vec3 aureliaForwardLight(vec3 albedo, vec3 worldNormal, vec2 lightLevel, vec3 playerPosition) {
    float shadow;
    return aureliaShade(albedo, normalize(worldNormal), lightLevel, playerPosition, aureliaDefaultMaterial(), 1.0, shadow);
}

// Fog is not applied here: the vertex stages evaluate the shared aerial
// perspective (lib/sky.glsl, aureliaFogTerms) per vertex from the camera-
// relative PLAYER-space position, and the fragment stages apply it with
// aureliaApplyFogTerms.
