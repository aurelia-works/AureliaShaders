#version 330 compatibility

// Solid terrain layer: no alpha test (see lib/terrain_fragment.glsl).
#define AURELIA_TERRAIN_SOLID
/* RENDERTARGETS: 0,1 */
layout(location = 0) out vec4 aureliaSceneColor;
layout(location = 1) out vec4 aureliaGbuffer; // lib/materials.glsl encoding

#include "/lib/terrain_fragment.glsl"
