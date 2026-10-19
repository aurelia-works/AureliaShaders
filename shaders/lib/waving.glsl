// Wind sway for plants and leaves (AURELIA_WAVING). Vertex stages only.
//
// Shared by the terrain vertex stage and shadow.vsh so a swaying leaf and its
// own shadow-map caster move identically (otherwise every leaf would shadow
// itself as it moves). Pure ALU per vertex: no texture, target or pass.
//
// The offset is in WORLD axes. Chunk geometry carries no rotation (its model
// matrix is a translation), so the caller adds it with
// gl_ModelViewProjectionMatrix * vec4(offset, 0.0), which holds in both the
// main pass and the shadow pass.
#ifndef AURELIA_WAVING_GLSL
#define AURELIA_WAVING_GLSL

// Plants share lighting and shadow treatment; block.properties lists them.
bool aureliaIsPlant(int blockId) {
    return blockId == 10001 || blockId == 10003 || blockId == 10004;
}

#ifdef AURELIA_WAVING
#ifndef AURELIA_LOOK_TIME_AND_CAMERA
uniform float frameTimeCounter; // seconds, wraps hourly in Iris
uniform vec3 cameraPosition;
#endif
// Iris: the texture-space centre of the vertex's sprite. Top vertices of a
// plant quad sit above it in the atlas (smaller v).
in vec2 mc_midTexCoord;

// Sway in blocks for one vertex, zero for anything that does not wave.
// `uv` is the vertex's atlas coordinate, `worldPosition` its world position.
vec3 aureliaWaveOffset(int blockId, vec2 uv, vec3 worldPosition, float rain) {
    float reach;
    if (blockId == 10001) {
        reach = uv.y < mc_midTexCoord.y ? 1.0 : 0.0;
    } else if (blockId == 10004) {
        reach = uv.y < mc_midTexCoord.y ? 2.0 : 1.0;
    } else if (blockId == 10002) {
        reach = 0.35;
    } else {
        return vec3(0.0);
    }
    if (reach == 0.0) return vec3(0.0);

    float t = frameTimeCounter;
    // Slow gusts roll across the land along the prevailing wind (+x, a little
    // +z), so neighbouring plants lean together instead of jittering apart.
    float gust = 0.5 + 0.5 * sin(t * 0.55 - dot(worldPosition.xz, vec2(0.045, 0.018)));
    gust *= gust;
    float strength = AURELIA_WAVING_STRENGTH * (0.55 + 0.9 * gust) * (1.0 + 0.8 * rain);
    // The fast flutter, phased by position so a field does not move in lockstep.
    float phase = t * 2.1 + dot(worldPosition, vec3(0.73, 0.21, 0.51));
    vec2 sway = vec2(sin(phase) + 0.6 * gust, 0.6 * sin(phase * 0.77 + 1.3));
    return vec3(sway.x, 0.0, sway.y) * (0.075 * reach * strength);
}
#endif

#endif
