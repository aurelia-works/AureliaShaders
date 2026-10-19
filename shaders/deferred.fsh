#version 330 compatibility

// Deferred pass (Phase 5): runs after the opaque geometry and the sky, before
// any translucent layer.
//   1. Screen-space reflections on smooth opaque surfaces (polished stone,
//      glazed tile, metal, wet streets and puddles). The forward pass already
//      added a sky reflection through the same BRDF; where the reflected ray
//      finds geometry, that sky term is swapped for what the ray hit. The hit
//      is read from colortex0's mip chain at the width the surface's GGX
//      lobe spreads to over the ray's length, so a puddle mirrors, a wet road
//      shows a soft smear and polished stone sits in between: glossy
//      reflections for one fetch, with no extra rays and no temporal filter.
//   2. The painted cloud layer (AURELIA_CLOUD_LAYER), on the open-sky pixels
//      gbuffers_skybasic marked and the world left visible. In the sky pass
//      it was paid on every pixel of the screen, terrain or not (~0.8 ms at
//      1080p on the M1); here only the sky that shows pays.
//   3. A copy of the finished opaque scene into colortex6, which the water
//      and glass pass reads for refraction and for its own reflections
//      (gbuffers_water cannot sample colortex0 while it draws into it).

#include "/lib/options.glsl"
#include "/lib/color.glsl"
#include "/lib/look.glsl"
#include "/lib/sky.glsl"
#include "/lib/materials.glsl"
#include "/lib/brdf.glsl"
#include "/lib/ssr.glsl"
#ifdef AURELIA_CLOUD_LAYER
    #include "/lib/clouds2d.glsl"
#endif

uniform sampler2D colortex0;
uniform sampler2D colortex1;
#ifdef AURELIA_SSR
const bool colortex0MipmapEnabled = true;
#endif
uniform sampler2D depthtex0;
uniform mat4 gbufferModelView;

/*
const int colortex1Format = RGBA8;
const bool colortex1Clear = true;
const vec4 colortex1ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const int colortex6Format = R11F_G11F_B10F;
const bool colortex6Clear = false;
*/

in vec2 texcoord;

/* RENDERTARGETS: 0,6 */
layout(location = 0) out vec4 aureliaSceneColor;
layout(location = 1) out vec4 aureliaOpaqueCopy;

void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    vec3 color = texelFetch(colortex0, pixel, 0).rgb;
#ifdef AURELIA_CLOUD_LAYER
    if (texelFetch(colortex1, pixel, 0).a > 0.999 && texelFetch(depthtex0, pixel, 0).r >= 1.0) {
        vec3 direction = normalize(mat3(gbufferModelViewInverse) * aureliaViewPosition(texcoord, 1.0));
#ifdef AURELIA_CLOUD_HIGH
        // High cirrus first: the main deck passes in front of it.
        color = aureliaApplyCirrusLayer(color, direction, aureliaSunDirection(), rainStrength);
#endif
        color = aureliaApplyCloudLayer(color, direction, aureliaSunDirection(), aureliaMoonDirection(), rainStrength);
    }
#endif

#ifdef AURELIA_SSR
    vec4 gbuffer = texelFetch(colortex1, pixel, 0);
    float smoothness = gbuffer.b;
    float depth = texelFetch(depthtex0, pixel, 0).r;
    // Hand pixels (depth < 0.56) and anything rough keep the forward result.
    if (smoothness > 0.42 && depth < 1.0 && depth > 0.56 && !aureliaNoSky()) {
        float flags = floor(gbuffer.a * 255.0 + 0.5);
        float skyLevel = floor(flags / 16.0) / 15.0;
        bool metal = mod(flags, 16.0) >= 8.0;
        vec3 normal = aureliaOctDecode(gbuffer.rg);
        vec3 viewPosition = aureliaViewPosition(texcoord, depth);
        vec3 viewNormal = mat3(gbufferModelView) * normal;
        vec3 viewDirection = normalize(viewPosition);
        vec3 reflected = reflect(viewDirection, viewNormal);
        vec3 hit = aureliaTraceScreen(depthtex0, viewPosition, reflected,
                                      0.5, AURELIA_SSR_STEPS);
        if (hit.z > 0.0) {
            // The reflected lobe is about 1.3 alpha wide either side, so its
            // footprint at the hit is ~2.6 alpha times the ray's screen length.
            float alpha = aureliaAlpha(smoothness);
            float rayPixels = length((hit.xy - texcoord) * vec2(viewWidth, viewHeight));
            float lod = clamp(log2(max(2.6 * alpha * rayPixels, 1.0)), 0.0, 5.0);
            vec3 hitColor = textureLod(colortex0, hit.xy, lod).rgb;
            // The sky reflection the forward pass added, rebuilt with the same
            // terms (lib/lighting.glsl aureliaShade).
            vec3 worldReflected = mat3(gbufferModelViewInverse) * reflected;
            worldReflected.y = max(worldReflected.y, -0.2);
            float roughness = sqrt(alpha);
            float NdotV = max(dot(viewNormal, -viewDirection), 1e-3);
            // Metals: F0 is the albedo, which survives as the hue of the shaded
            // colour. Dielectrics: the common 4%.
            vec3 tint = color / max(max(color.r, max(color.g, color.b)), 1e-4);
            vec3 f0 = metal ? clamp(tint * 0.9, 0.04, 1.0) : vec3(0.04);
            vec3 specular = aureliaEnvBrdf(f0, NdotV, roughness);
            float skyVisibility = aureliaSkyVisibility(skyLevel);
            vec3 sunDirection = aureliaSunDirection();
            vec3 skyReflection = mix(aureliaSkyRadiance(worldReflected, sunDirection),
                                     aureliaSkyAmbient(normal, sunDirection) * (skyVisibility / AURELIA_PI), roughness)
                               * (skyVisibility * skyVisibility);
            // Glossy, not mirror: the hit fades in with smoothness so a
            // satin floor does not show a perfect mirror image.
            float weight = hit.z * smoothstep(0.42, 0.75, smoothness);
            vec3 playerPosition = mat3(gbufferModelViewInverse) * viewPosition;
            float transmittance = aureliaFogTerms(playerPosition, AURELIA_FOG_DENSITY, rainStrength).a;
            color += specular * (hitColor - skyReflection) * (weight * transmittance);
            color = max(color, 0.0);
        }
    }
#endif

    aureliaSceneColor = vec4(color, 1.0);
    aureliaOpaqueCopy = vec4(color, 1.0);
}
