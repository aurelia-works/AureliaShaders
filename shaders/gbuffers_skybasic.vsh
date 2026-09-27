#version 330 compatibility

// The analytical sky needs the direction this fragment is being drawn for, and
// Iris hands a skybox vertex rather than a screen position. Player space is
// camera-relative, so the player-space position of a skybox vertex *is* the
// direction from the camera to it. This mirrors gbuffers_terrain.vsh exactly so
// it introduces no new convention: gbufferModelViewInverse maps view space back
// to that player space, and no rotation about the camera can leak into the
// result.
uniform mat4 gbufferModelViewInverse;

out vec4 vertexColor;
out vec3 viewDirection;

void main() {
    gl_Position = ftransform();
    vertexColor = gl_Color;
    vec3 viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
    viewDirection = normalize((gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz);
}
