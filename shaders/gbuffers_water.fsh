#version 330 compatibility

// Phase 2B water surface. Behaviour beyond the gbuffers_terrain fallback lives
// behind AURELIA_WATER_SURFACE so it is revertible from the Iris options screen
// without a code edit, and so the fallback replacement and the new shading stay
// separable in review.
//
// Water is a shadow receiver only. shaders.properties keeps shadowTranslucent
// disabled, so this samples the shadow map but never enters the caster pass.
//
// No scene-colour or depth read: gbuffers_water renders after deferred while
// writing colortex0, so sampling colortex0 is a feedback loop. The reflection is
// analytical and the only thickness cue is Fresnel.

#include "/lib/options.glsl"
#include "/lib/lighting.glsl"
#include "/lib/debug.glsl"
#ifdef AURELIA_WATER_SURFACE
    #include "/lib/water.glsl"
#endif

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vertexColor;
in vec3 worldNormal;
in vec3 viewPosition;
in vec3 playerPosition;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
    vec4 albedo = aureliaDecodeSrgbTerrain(texture(gtexture, texcoord), vertexColor);
    if (albedo.a < alphaTestRef) discard;

    vec3 color = aureliaForwardLight(albedo.rgb, worldNormal, lmcoord, playerPosition);

#ifdef AURELIA_WATER_SURFACE
    // playerPosition is camera-relative, so the camera sits at the origin of
    // player space and normalizing it gives the direction to this fragment. That
    // is the view vector, and it needs no extra varying.
    vec3 viewDirection = normalize(playerPosition);
    vec3 surface = aureliaWaterNormal(playerPosition.xz, worldNormal, 0.045);

    float sunUp = aureliaSunVisibility();
    float fresnel = aureliaWaterFresnel(max(dot(surface, viewDirection), 0.0));
    vec3 reflected = reflect(-viewDirection, surface);
    vec3 reflectionColor = aureliaWaterReflection(reflected);

    // A tight specular lobe on the perturbed normal. The wave field is what
    // turns this from a single highlight into a scattered glint path, so this is
    // the term that most benefits from the perturbation being there at all.
    vec3 lightDir = aureliaSunDirection();
    vec3 glint = aureliaSunColor(lightDir.y)
        * pow(max(dot(reflected, lightDir), 0.0), 180.0)
        * (sunUp * 3.4 * (1.0 - AURELIA_RAIN_SUN_DIM * rainStrength));

    // Reflection is strongest at grazing angles, so it is weighted down from
    // full Fresnel; a full mirror at the shoreline looked like sheet metal.
    color = mix(color, reflectionColor, fresnel * 0.80) + glint;
#endif

    color = aureliaApplyFog(color, viewPosition);

#if AURELIA_DEBUG_VIEW == 1
    color = aureliaDebugLighting(worldNormal, lmcoord);
#elif AURELIA_DEBUG_VIEW == 5
    color = vec3(aureliaShadowVisibility(playerPosition, worldNormal, aureliaShadowDirection(), aureliaSunVisibility(), rainStrength));
#endif

#ifdef AURELIA_WATER_SURFACE
    // Grazing water reflects more and transmits less, so alpha tracks Fresnel.
    // Without this the surface stayed uniformly translucent and lost the bright
    // rim that reads as a waterline.
    float alpha = mix(albedo.a, 1.0, clamp(fresnel * 0.55, 0.0, 0.55));
#else
    float alpha = albedo.a;
#endif
    aureliaSceneColor = vec4(color, alpha);
}
