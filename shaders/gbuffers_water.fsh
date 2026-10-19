#version 330 compatibility

// Translucent blocks: water, stained glass, ice, slime, honey and portals.
//
// Water (AURELIA_WATER_SURFACE) is an optical surface over a participating
// medium. The surface reflects the scene with Fresnel for IOR 1.33, traced
// in screen space against the opaque depth and colour (AURELIA_SSR) and
// falling back to the sky; the sun leaves a GGX glint on the waves. Through
// it, the bed is read from the opaque colour at a Snell-displaced position
// (AURELIA_WATER_REFRACTION) and attenuated per channel through the water
// column, and the column adds the light its particles scatter back out
// (lib/water.glsl). With refraction the pixel is the whole answer and is
// written opaque; without it the same terms are blended over the bed with a
// grey transmittance.
//
// Glass and the other translucents stay alpha-blended so stacked panes
// compose: the lit tinted body at the texture's alpha, plus a Fresnel
// reflection the alpha does not scale.
//
// Water is a shadow receiver only: shaders.properties keeps
// shadowTranslucent off.
//
// depthtex1 is the pre-translucent opaque depth Iris copies in
// beginTranslucents (verified in iris-1.7.6+mc1.20.1.jar); depthtex0 may hold
// the water surface itself. colortex6 is the opaque colour deferred.fsh
// copied; this pass never writes it, so reading it is no feedback loop.
//
// Fog is evaluated per pixel here, not per vertex: the offline preview draws
// water as one large plane, and the water's fog has to be split between the
// bed (already fogged in colortex6) and the surface terms.

#include "/lib/options.glsl"
#define AURELIA_FRAME_FRAGMENT
#include "/lib/lighting.glsl"
#include "/lib/debug.glsl"
#include "/lib/water.glsl"
#include "/lib/ssr.glsl"
#ifdef AURELIA_CLOUD_LAYER
    #include "/lib/clouds2d.glsl"
#endif

// The water column is measured whenever an option needs its thickness.
#ifdef AURELIA_WATER_DEPTH
    #define AURELIA_WATER_MEASURE
#endif
#if defined(AURELIA_WATER_SHORE) && !defined(AURELIA_WATER_MEASURE)
    #define AURELIA_WATER_MEASURE
#endif
#if defined(AURELIA_WATER_REFRACTION) && !defined(AURELIA_WATER_MEASURE)
    #define AURELIA_WATER_MEASURE
#endif

uniform sampler2D gtexture;
uniform float alphaTestRef;
uniform sampler2D depthtex1;  // pre-translucent opaque depth (see header)
uniform sampler2D colortex6;  // opaque scene colour (deferred.fsh)
uniform mat4 gbufferModelView;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 vertexColor;
in vec3 worldNormal;
in vec3 viewPosition;
in vec3 playerPosition;
flat in int aureliaBlockId;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

// What a reflected ray sees where screen space has nothing: the sky and its
// cloud layer. The sun disc is left to the glint.
vec3 aureliaReflectedSky(vec3 r, vec3 sunDirection) {
    r = normalize(vec3(r.x, max(r.y, 0.0), r.z));
    vec3 sky = aureliaSkyRadiance(r, sunDirection);
#ifdef AURELIA_CLOUD_LAYER
    sky = aureliaApplyCloudLayer(sky, r, sunDirection, aureliaMoonDirection(), rainStrength);
#endif
    return sky;
}

// Screen-space reflection against the opaque scene: rgb colour, a confidence.
vec4 aureliaTraceReflection(vec3 r) {
#ifdef AURELIA_SSR
    vec3 hit = aureliaTraceScreen(depthtex1, viewPosition, mat3(gbufferModelView) * r, 0.5, AURELIA_SSR_STEPS);
    if (hit.z > 0.0) return vec4(texture(colortex6, hit.xy).rgb, hit.z);
#endif
    return vec4(0.0);
}

// Specular reflection of a light (sun or moon) off a smooth surface:
// GGX x Smith x Fresnel x cosine, per unit irradiance.
vec3 aureliaLightSpecular(vec3 n, vec3 v, vec3 l, float alpha, vec3 f0) {
    float NdotL = dot(n, l);
    if (NdotL <= 0.0) return vec3(0.0);
    vec3 h = normalize(l + v);
    float NdotV = max(dot(n, v), 1e-3);
    return aureliaSchlick(f0, max(dot(v, h), 0.0))
         * (aureliaGgx(max(dot(n, h), 0.0), alpha) * aureliaSmithVisibility(NdotV, NdotL, alpha) * NdotL);
}

// Water column along the view ray from this surface to the opaque scene
// behind it at screen position uv; negative where something in front of
// the surface covers uv. Only the floor's view-space z is needed: the z row
// of the inverse projection gives it from two mads and a divide, and since
// the floor lies on the eye ray, thickness = |view| * (zFloor / zSurface - 1).
// Depth 1.0 (no floor) lands on the far plane: as deep as it gets.
float aureliaWaterThickness(vec2 uv) {
    float floorNdcZ = texture(depthtex1, uv).r * 2.0 - 1.0;
    float floorViewZ = (gbufferProjectionInverse[2][2] * floorNdcZ + gbufferProjectionInverse[3][2])
        / (gbufferProjectionInverse[2][3] * floorNdcZ + gbufferProjectionInverse[3][3]);
    return length(viewPosition) * (floorViewZ / viewPosition.z - 1.0);
}

void main() {
    vec4 texel = texture(gtexture, texcoord);
    if (texel.a < alphaTestRef) discard;

    float distanceToCamera = length(playerPosition);
    vec3 eyeToFragment = playerPosition / max(distanceToCamera, 1e-4);
    vec3 v = -eyeToFragment;
    // The face as the camera sees it (an underside when looking up from
    // below the surface).
    vec3 face = normalize(worldNormal);
    if (dot(face, v) < 0.0) face = -face;
    vec3 sunDirection = aureliaSunDirection();
    vec3 moonDirection = aureliaMoonDirection();
    float skyLevel = clamp(lmcoord.y, 0.0, 1.0);
    float skyVisibility = aureliaNoSky() ? 0.0 : aureliaSkyVisibility(skyLevel);
    float openSky = aureliaNoSky() ? 0.0 : smoothstep(0.30, 0.85, skyLevel);
    vec4 fog = aureliaFogTerms(playerPosition, AURELIA_FOG_DENSITY, rainStrength);

    vec3 color;
    float alpha;
    bool isWater = false;
#ifdef AURELIA_WATER_SURFACE
    isWater = aureliaBlockId == 10010;
#endif

    if (isWater) {
#ifdef AURELIA_WATER_ANIMATED
        float time = frameTimeCounter;
#else
        float time = 0.0;
#endif
        // Waves on the top face, flattening with distance so far water does
        // not alias into noise; raindrop rings where rain reaches it.
        vec3 n = face;
        if (abs(face.y) > 0.5) {
            vec2 world = playerPosition.xz + cameraPosition.xz;
            float strength = mix(0.10, 0.16, rainStrength) * (1.0 - 0.8 * smoothstep(12.0, 80.0, distanceToCamera));
            n = aureliaWaveNormal(world, strength, time);
            float rings = rainStrength * smoothstep(0.5, 0.9, skyLevel) * (1.0 - smoothstep(8.0, 40.0, distanceToCamera));
            if (rings > 0.01) {
                vec2 slope = aureliaRainRings(world * 2.0, time) * (0.35 * rings);
                n = normalize(n + vec3(-slope.x, 0.0, -slope.y));
            }
            n.y *= sign(face.y);
        }
        float cosView = clamp(dot(n, v), 0.02, 1.0);
        vec2 shadow = aureliaShadowTerms(playerPosition, face, skyLevel);

        if (face.y < -0.5) {
            // From below. Inside Snell's window the surface shows the sky,
            // bent toward the zenith; toward the critical angle the
            // transmission's Fresnel rises to total internal reflection of
            // the water column.
            // The column is lit as a volume: a shadow-map test at the surface
            // point says nothing about it, and drew hard shadow shapes.
            vec3 downwelling = aureliaWaterDownwelling(openSky, openSky, skyVisibility)
                             + aureliaBlockLight(lmcoord.x);
            vec3 below = aureliaWaterColumnRadiance(reflect(eyeToFragment, n), downwelling);
            vec3 refracted = refract(eyeToFragment, n, 1.333);
            color = below;
            if (dot(refracted, refracted) > 0.0) {
                float cosOut = max(dot(refracted, -n), 0.0);
                float fresnel = aureliaSchlick(vec3(AURELIA_WATER_F0), cosOut).x;
                vec3 sky = aureliaReflectedSky(refracted, sunDirection) * skyVisibility;
                color = mix(sky, below, fresnel);
            }
            // The water between the eye and the surface, per channel: the
            // window turns blue-green with depth as red is absorbed first.
            vec3 path = exp(-(AURELIA_WATER_ABSORPTION + AURELIA_WATER_SCATTERING) * distanceToCamera);
            color = color * path + aureliaWaterColumnRadiance(eyeToFragment, downwelling) * (1.0 - path);
            alpha = 1.0;
        } else {
            float fresnel = aureliaSchlick(vec3(AURELIA_WATER_F0), cosView).x;

            // Reflection: traced, else the sky this spot can see.
            vec3 r = reflect(eyeToFragment, n);
            r.y = max(r.y, 0.01);
            vec3 reflection = aureliaReflectedSky(r, sunDirection) * (skyVisibility * skyVisibility);
            vec4 traced = aureliaTraceReflection(normalize(r));
            reflection = mix(reflection, traced.rgb, traced.a);

            // Sun and moon glints. Far away the waves are below a pixel, so
            // their slopes widen the lobe into a glitter path.
            float glintAlpha = 0.02 + 0.06 * smoothstep(16.0, 96.0, distanceToCamera);
            vec3 glint = vec3(0.0);
            if (!aureliaNoSky()) {
                glint = aureliaLightSpecular(n, v, sunDirection, glintAlpha, vec3(AURELIA_WATER_F0))
                          * aureliaSunLight() * (shadow.x * openSky)
                      + aureliaLightSpecular(n, v, moonDirection, glintAlpha, vec3(AURELIA_WATER_F0))
                          * aureliaMoonLight() * (shadow.y * openSky);
                // Overcast hides the disc: the LUT keeps 6% of the sun as
                // diffuse light, but through this near-mirror lobe that still
                // showed as a white sparkle on rain-rippled water (in game).
                glint *= (1.0 - rainStrength) * (1.0 - rainStrength);
            }

            // The water column behind the surface.
            vec3 tintRatio;
            vec3 extinction = aureliaWaterExtinction(vertexColor.rgb, tintRatio);
            vec2 screenUv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
            vec2 bedUv = screenUv;
            float thickness = AURELIA_WATER_DEFAULT_THICKNESS;
#ifdef AURELIA_WATER_MEASURE
            thickness = max(aureliaWaterThickness(screenUv), 0.0);
#endif
#ifdef AURELIA_WATER_REFRACTION
            // Snell: a wave slope bends the ray by about a quarter of its
            // tilt (1 - 1/1.33), which moves the bed sideways by that times
            // the depth, projected to the screen. Where the moved sample lands
            // on something in front of the water, keep the straight view.
            vec3 tilt = mat3(gbufferModelView) * (n - face);
            vec2 offset = tilt.xy * (0.25 * min(thickness, 4.0)) * vec2(gbufferProjection[0][0], gbufferProjection[1][1])
                        * (0.5 / max(-viewPosition.z, 0.5));
            vec2 refractedUv = clamp(screenUv + offset, vec2(0.0), vec2(1.0));
            float refractedThickness = aureliaWaterThickness(refractedUv);
            if (refractedThickness > 0.02) {
                bedUv = refractedUv;
                thickness = refractedThickness;
            }
#endif
            // Light reaching the bed crossed the column too, about its depth
            // below the surface.
            float bedDepth = thickness * abs(eyeToFragment.y);
            vec3 transmittance = exp(-extinction * (thickness + bedDepth));
            vec3 downwelling = aureliaWaterDownwelling(shadow.x * openSky, shadow.y * openSky, skyVisibility)
                             + aureliaBlockLight(lmcoord.x);
            vec3 body = aureliaWaterInscatter(downwelling, extinction, thickness) * tintRatio;
#ifdef AURELIA_WATER_SHORE
            // A faint broken foam line where the surface meets a wall or a
            // bank, the only place the column thins to nothing.
            float foam = (1.0 - smoothstep(0.0, 0.30, thickness))
                       * smoothstep(0.45, 0.80, aureliaWaveNoise(playerPosition.xz * 3.0 + cameraPosition.xz * 3.0 + time * 0.4));
            body += downwelling * (0.25 * foam / AURELIA_PI);
            transmittance *= 1.0 - 0.6 * foam;
#endif
            vec3 surface = fresnel * reflection + glint + (1.0 - fresnel) * body;
            vec3 seen = (1.0 - fresnel) * transmittance;
#ifdef AURELIA_WATER_REFRACTION
            // The bed in colortex6 already carries its own fog from the
            // camera, so only the share of the pixel that is not the bed
            // takes this surface's in-scatter.
            vec3 bed = texture(colortex6, bedUv).rgb;
            color = bed * seen + surface * fog.a + fog.rgb * (1.0 - seen);
            alpha = 1.0;
#else
            // Blended over the bed with the grey part of the transmittance;
            // the column's colour comes from its in-scatter.
            alpha = clamp(1.0 - dot(seen, vec3(0.2126, 0.7152, 0.0722)), 0.02, 1.0);
            color = (surface * fog.a + fog.rgb * alpha) / alpha;
#endif
        }
    } else {
        // Glass, ice, slime, honey, portals (and water with the surface
        // option off): the lit body at the texture's alpha, without its own
        // reflection, plus a Fresnel reflection the alpha does not scale.
        vec3 albedo = aureliaSrgbToLinear(texel.rgb) * vertexColor.rgb;
        AureliaMaterial material = aureliaMaterial(aureliaBlockId, albedo);
        AureliaMaterial body = material;
        body.f0 = 0.0;
        float sunShadow;
        vec3 lit = aureliaShade(albedo, face, lmcoord, playerPosition, body, 1.0, sunShadow);

        float specAlpha = aureliaAlpha(material.smoothness);
        float roughness = sqrt(specAlpha);
        float cosView = max(dot(face, v), 0.02);
        float fresnel = aureliaEnvBrdf(vec3(material.f0), cosView, roughness).x;
        vec3 r = reflect(eyeToFragment, face);
        vec3 reflection = mix(aureliaReflectedSky(r, sunDirection), aureliaLutTexel(AURELIA_LUT_SKY_UP).rgb / AURELIA_PI, roughness)
                        * (skyVisibility * skyVisibility);
        if (material.smoothness > 0.7) {
            vec4 traced = aureliaTraceReflection(r);
            reflection = mix(reflection, traced.rgb, traced.a);
        }
        vec3 glint = aureliaNoSky() ? vec3(0.0)
                   : aureliaLightSpecular(face, v, sunDirection, max(specAlpha, 0.02), vec3(material.f0))
                       * aureliaSunLight() * (sunShadow * openSky * (1.0 - rainStrength) * (1.0 - rainStrength));

        alpha = mix(texel.a, 1.0, fresnel);
        vec3 premultiplied = lit * (texel.a * (1.0 - fresnel)) + fresnel * reflection + glint;
        color = (premultiplied * fog.a + fog.rgb * alpha) / max(alpha, 1e-3);
    }

#if AURELIA_DEBUG_VIEW == 1
    color = aureliaDebugLighting(worldNormal, lmcoord);
#elif AURELIA_DEBUG_VIEW == 5
    color = vec3(aureliaShadowDebug(playerPosition, worldNormal));
#endif

    aureliaSceneColor = vec4(color, alpha);
}
