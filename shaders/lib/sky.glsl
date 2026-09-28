// Analytic atmosphere for gbuffers_skybasic. ALU only: no texture read, no
// render target, no extra pass. Enabled by AURELIA_ATMOSPHERE; when that option
// is off the caller uses the flat look.glsl ramp instead, so the treatment
// stays revertible from the Iris options screen without a code edit.
//
// Included by gbuffers_skybasic.fsh *after* lib/look.glsl, so the contract
// helpers and constants are in scope. It deliberately declares no uniforms.

// Sparse procedural star field. A cheap position hash; no texture.
float aureliaStarHash(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

// Sky colour for a world-space view direction, given the contract inputs.
vec3 aureliaAtmosphereSky(
    vec3 skyColorLinear,
    vec3 fogColorLinear,
    vec3 direction,
    vec3 lightDirection,
    float rain
) {
    float elevation = clamp(direction.y, -1.0, 1.0);
    float sunHeight = lightDirection.y;
    float day = aureliaSunVisibility();
    // High whenever the sun is at or below the horizon: drives the sunset/night
    // palette independently of the twilight day/night blend.
    float dusk = aureliaHorizonFactor(sunHeight);

    // One smooth ramp. The horizon is anchored to the fog colour so the far
    // edge of the world cannot seam against the sky; at low sun it warms toward
    // the sunlight colour, which is what makes sunrise and sunset read.
    vec3 horizon = fogColorLinear;
    vec3 zenith = skyColorLinear * AURELIA_ZENITH_SCALE + AURELIA_ZENITH_OFFSET;
    // Keep the upper sky blue as the sun drops, so a sunset is a warm horizon
    // under a deepening blue rather than one uniform orange.
    zenith = mix(zenith, vec3(0.05, 0.10, 0.26), 0.60 * dusk);
    float warm = dusk * day;
    horizon = mix(horizon, aureliaSunColor(max(sunHeight, 0.0)) * 0.80, 0.35 * warm);

    float ramp = smoothstep(-0.06, 0.60, elevation);
    vec3 sky = mix(horizon, zenith, ramp);

    // Solar aureole: a broad halo plus a tight core, both following the true
    // direction to the sun so the whole halo tracks as the sun moves, not just
    // the azimuth. The disc itself stays a Minecraft texture in
    // gbuffers_skytextured.
    float align = max(dot(direction, lightDirection), 0.0);
    float broad = pow(align, 6.0);
    float core = pow(align, 220.0);
    float lowSun = 1.0 - smoothstep(0.0, 0.34, abs(sunHeight));
    vec3 glow = aureliaSunColor(max(sunHeight, 0.0))
        * (broad * 0.30 + core * 1.10) * day * (1.0 + 0.6 * lowSun)
        * (1.0 - AURELIA_RAIN_GLOW_DIM * rain);
    sky += glow;

    // Stars above the horizon, only once the sun is genuinely below it, and
    // faded by weather.
    float darkness = smoothstep(-0.04, -0.20, sunHeight);
    float above = smoothstep(0.0, 0.15, elevation);
    float star = smoothstep(0.9965, 1.0, aureliaStarHash(floor(direction * 260.0)));
    sky += vec3(0.85, 0.88, 1.0) * (star * darkness * above * (1.0 - 0.85 * rain) * 1.6);

    // Overcast: flatten the gradient toward the fog colour.
    sky = mix(sky, fogColorLinear, AURELIA_RAIN_SKY_FLATTEN * rain);
    return sky;
}
