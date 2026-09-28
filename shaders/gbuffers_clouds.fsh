#version 330 compatibility

// Cloud pass: Minecraft's vanilla clouds. This pack previously had no cloud
// program, so Iris fell back to gbuffers_textured, whose only job is "leave
// the vanilla look alone" - clouds therefore rendered as the raw texture with
// no relationship to our sky, fog or light, which is what made them read as a
// flat white slab against the gradient.
//
// This program keeps the vanilla cloud texture (we have no volumetric cloud
// system yet - that is the later clouds phase) but re-lights it in one place:
//
//   - sRGB decode, consistent with the rest of the pack;
//   - lit with the contract sun colour by facing (a soft directional term);
//   - pulled toward the sky colour so cloud tint follows time of day;
//   - the pack's exponential fog at cloud height, so clouds fade like terrain.
//
// No shadow lookup: through-cloud shadows need a volumetric layer to be right.
// No normals are provided by this pass in 1.20.1, so lighting stays analytical.

#include "/lib/options.glsl"
#include "/lib/color.glsl"
#include "/lib/look.glsl"

uniform sampler2D gtexture;

in vec2 texcoord;
in vec4 vertexColor;
in vec3 playerPosition;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
#if AURELIA_DEBUG_VIEW == 5
    aureliaSceneColor = vec4(1.0);
#else
    vec4 textureColor = texture(gtexture, texcoord);
    if (textureColor.a < 0.01) discard;

    vec3 color = aureliaSrgbToLinear(textureColor.rgb) * aureliaSrgbToLinear(vertexColor.rgb);

    // Cloud tint follows the sky. The sun colour keeps golden-hour clouds
    // golden instead of grey-blue slabs.
    vec3 sunDirection = aureliaSunDirection();
    float day = aureliaSunVisibility();
    vec3 tint = mix(aureliaSrgbToLinear(skyColor),
                    aureliaSunColor(max(sunDirection.y, 0.0)),
                    0.22 * day);
    color *= mix(vec3(1.0), tint, 0.35);

    // Cheap directional shading: cloud tops are nominally sun-facing.
    float top = clamp(sunDirection.y, 0.0, 1.0);
    color *= 0.82 + 0.18 * top;

    // Fog at cloud height fades distant clouds into the sky so they no longer
    // end in a hard edge against the gradient. playerPosition's length is the
    // camera-relative distance in world axes, which is the right metric here.
    color = aureliaApplyFogContract(color, playerPosition, AURELIA_FOG_DENSITY, rainStrength);

    aureliaSceneColor = vec4(color, textureColor.a * vertexColor.a);
#endif
}
