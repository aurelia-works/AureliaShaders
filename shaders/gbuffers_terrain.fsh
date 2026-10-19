#version 330 compatibility

// Cutout and cutout-mipped terrain: alpha tested.
/* RENDERTARGETS: 0,1 */
layout(location = 0) out vec4 aureliaSceneColor;
layout(location = 1) out vec4 aureliaGbuffer; // lib/materials.glsl encoding

#include "/lib/terrain_fragment.glsl"
