#version 330 compatibility

// Cloud vertex stage. 1.20.1 cloud geometry is a camera-relative box skin
// (POSITION_TEX_COLOR_NORMAL): every face carries a real axis-aligned normal,
// and the vertex colour is vanilla's own time-of-day/rain tint multiplied by a
// fixed per-face shade (top 1.0, bottom 0.7, sides 0.8/0.9). The pack replaces
// both with one lighting model evaluated HERE, once per vertex (a face is flat,
// so the value is exact per face and the fragment stage only multiplies):
//
//   - face brightness follows the sun: a face turned toward the sun is lit, a
//     face turned away is in cool shade, so the underside is darker than the
//     top and the sun-facing flank takes the golden rim at dusk/dawn;
//   - the same wrap term against the moon gives night clouds a faint cool
//     lift instead of vanilla's near-black 0.1 tint;
//   - rain flattens the directional contrast and sinks everything toward the
//     overcast deck colour the sky dome uses.
//
// A missing/zero normal (a driver or pack that does not feed one) degrades to
// "top face" rather than NaN.

#include "/lib/options.glsl"
#define AURELIA_FRAME_VERTEX
#include "/lib/color.glsl"
#include "/lib/look.glsl"

out vec2 texcoord;
out vec4 cloudLight;      // rgb: lit face colour (linear), a: vanilla vertex alpha
out float cloudSide;      // 1 on vertical faces, 0 on top/bottom
out vec3 playerPosition;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    aureliaWriteFrameConstants();
    vec3 viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;

    vec3 normal = mat3(gbufferModelViewInverse) * (gl_NormalMatrix * gl_Normal);
    float normalLength = length(normal);
    normal = normalLength > 0.5 ? normal / normalLength : vec3(0.0, 1.0, 0.0);
    cloudSide = 1.0 - abs(normal.y);

    vec3 sunDirection = aureliaSunDirection();
    vec3 moonDirection = aureliaMoonDirection();
    float day = aureliaSunVisibility();
    float rain = clamp(rainStrength, 0.0, 1.0);

    // Wrap lighting: 1 facing the light, 0 facing away, soft in between so a
    // vertical face at noon is mid-bright rather than black. Overcast light has
    // no direction, so rain pulls the term toward a flat 0.6.
    float wrap = clamp(dot(normal, sunDirection) * 0.5 + 0.5, 0.0, 1.0);
    wrap = mix(wrap, 0.6, 0.7 * rain);
    float shade = mix(0.55, 1.0, wrap);

    // Shadowed faces are sky-lit (cool); lit faces take the contract sun colour,
    // which is what turns the sun-facing flank gold at the horizon.
    vec3 sunLit = mix(vec3(0.80, 0.88, 1.00), aureliaSunColor(max(sunDirection.y, 0.0)), wrap) * shade;
    // Rain: the overcast deck colour (the dome's overcast pair, dimmed), shaded
    // by the same flattened term so thick undersides still read darker.
    vec3 overcast = vec3(0.21, 0.24, 0.29) * shade;
    vec3 dayLight = mix(sunLit, overcast, smoothstep(0.0, 0.7, rain));

    // Night: moonlit cool grey a touch above the navy dome, dimmer in rain.
    float moonWrap = clamp(dot(normal, moonDirection) * 0.5 + 0.5, 0.0, 1.0);
    vec3 nightLight = vec3(0.050, 0.062, 0.100) * mix(0.60, 1.0, moonWrap) * (1.0 - 0.45 * rain);

    cloudLight = vec4(mix(nightLight, dayLight, day), gl_Color.a);
}
