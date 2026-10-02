#version 330 compatibility

#include "/lib/options.glsl"
#include "/lib/color.glsl"

uniform sampler2D gtexture;
// Iris render stage for this draw. skytextured carries the sun, the moon AND
// textured skies (the End sky box, resource-pack custom skies), so only the
// two bodies are suppressed; the old unconditional vec4(0.0) blanked the End
// sky to the black colortex0 clear.
uniform int renderStage;

// Iris injects the MC_RENDER_STAGE_* macros; these fallbacks (Iris 1.7
// WorldRenderingPhase ordinals) only serve the offline validator and preview.
#ifndef MC_RENDER_STAGE_SUN
    #define MC_RENDER_STAGE_SUN 4
#endif
#ifndef MC_RENDER_STAGE_MOON
    #define MC_RENDER_STAGE_MOON 5
#endif

in vec2 texcoord;
in vec4 vertexColor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 aureliaSceneColor;

void main() {
    // The analytic discs live in gbuffers_skybasic (lib/sky.glsl) on every
    // preset - Potato included - so Minecraft's square sun/moon textures are
    // suppressed and the two never stack.
#if AURELIA_DEBUG_VIEW == 5
    // Sky pixels do not receive a shadow-map lookup and are therefore fully lit.
    aureliaSceneColor = vec4(1.0);
#else
    if (renderStage == MC_RENDER_STAGE_SUN || renderStage == MC_RENDER_STAGE_MOON) {
        aureliaSceneColor = vec4(0.0);
    } else {
        // Textured sky: vanilla intent, decoded into the linear scene.
        vec4 textureColor = texture(gtexture, texcoord);
        aureliaSceneColor = vec4(
            aureliaSrgbToLinear(textureColor.rgb) * aureliaSrgbToLinear(vertexColor.rgb),
            textureColor.a * vertexColor.a);
    }
#endif
}
