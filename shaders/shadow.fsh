#version 330 compatibility

#include "/lib/options.glsl"

uniform sampler2D gtexture;
uniform float alphaTestRef;

// Allocation and culling are reload-bound Iris constants. 1024 at 96 blocks is
// the Balanced/Adaptive M1 target; 1536 is intentionally the Cinematic ceiling.
const int shadowMapResolution = AURELIA_SHADOW_RESOLUTION;
// Iris 1.7.x parses this directive before GLSL constant folding, so this must
// expand directly to a numeric literal rather than a float(...) expression.
const float shadowDistance = AURELIA_SHADOW_DISTANCE;
const float shadowDistanceRenderMul = 1.0;
// Hardware depth compare + bilinear filter on shadowtex0 (lib/shadows.glsl
// declares it too, beside the sampler2DShadow that depends on it).
const bool shadowHardwareFiltering0 = true;

in vec2 texcoord;

void main() {
    // Keep leaves, grass, cutout entities, and terrain silhouettes correct in
    // the map. Translucent layers are excluded in shaders.properties.
    // Terrain AO is in vertexColor.a when separateAo is enabled. It is not
    // alpha coverage, so use the sampled texture alpha for caster cutouts.
    vec4 albedo = texture(gtexture, texcoord);
    if (albedo.a < max(alphaTestRef, 0.10)) discard;
}
