// Lightweight distant-rain curtain, drawn inside the existing final pass.
//
// WHY: Minecraft's weather geometry exists only in a local area around the
// player, so rain looks like it pours from one patch while the distant
// landscape and the horizon stay dry. This layer is a procedural curtain that
// fills the distant screen, composited into the linear scene colour BEFORE the
// grade so it rides the same pipeline as everything else. Minecraft's real
// gbuffers_weather rain stays responsible for nearby drops.
//
// COST: in rain, per pixel it is one depth fetch, one matrix unprojection, one
// or two curtain layers of ~a dozen ALU ops each, PLUS the camera-height
// estimator below: six further depth fetches and unprojections in a six-
// iteration loop. That estimator reads fixed screen positions, so its result is
// identical for every pixel; it is a candidate to hoist into final.vsh as a
// flat varying if this option is ever enabled by default (it is OFF in every
// preset). No extra buffers or passes. The whole path early-outs when
// rainStrength is ~zero, so clear weather pays one uniform compare.
//
// This file deliberately declares no uniforms of its own: depthtex0,
// frameTimeCounter, rainStrength, gbufferProjectionInverse and the celestial
// helpers come from the final pass / lib look contract.

// One cheap position hash, fract-based (no sin). The row index grows with
// frameTimeCounter, and a sin() of a large argument loses its low bits in fp32
// (and on Apple GPUs' fast-math sin), so the old sine hash degraded into
// visible banding the longer a session ran. This form stays well-conditioned
// for any row magnitude that fits a float. No texture lookups.
float aureliaRainHash(vec2 cell) {
    vec3 p3 = fract(vec3(cell.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// One curtain layer: narrow, slightly slanted falling streaks.
//
//   cols   - column count across the screen (per-layer scale)
//   speed  - fall speed in screen heights per second
//   len    - streak length as a fraction of a cell's height
//   cover  - fraction of cells that hold a streak
//   seed   - per-layer identity: slant, phase and hash offsets
//
// Returns coverage [0,1]. Movement is frameTimeCounter * speed, a continuous
// float, so there is no frame-number stepping. The polish pass thinned the
// streaks (edge 0.34 -> 0.22), shortened them and raised cell count/coverage:
// density should come from MANY subtle drops, not from a few long pale lines.
float aureliaRainLayer(vec2 screen, float cols, float speed, float len, float cover, float seed) {
    // Static wind shear: a small sideways lean that differs per layer, so the
    // two layers never read as identical vertical lines.
    vec2 uv = screen;
    uv.x += (uv.y - 0.5) * seed * 0.16;
    // Falling cell space. The per-column hash offsets the phase so columns do
    // not fall in lockstep.
    float columnHash = aureliaRainHash(vec2(floor(uv.x * cols), seed));
    float fall = uv.y * 3.0 - frameTimeCounter * speed + columnHash * 7.0;
    float row = floor(fall);
    float fy = fract(fall);
    // Per (column,row) hash decides presence, x position and width. The two
    // layers use different column scales and hashes, so on/off boundaries
    // never align into a visible tile.
    float cellHash = aureliaRainHash(vec2(floor(uv.x * cols) * 41.3 + seed, row * 17.7));
    float present = step(cellHash, cover);
    float centerX = 0.15 + 0.7 * fract(cellHash * 13.7);
    // Ordered smoothstep edges only: edge0 >= edge1 is undefined in GLSL and
    // is not guaranteed to mirror on Apple's driver.
    float across = 1.0 - smoothstep(0.0, 0.22, abs(fract(uv.x * cols) - centerX));
    float along = smoothstep(0.0, len, fy) * (1.0 - smoothstep(1.0 - len, 1.0, fy));
    return across * along * present;
}

// Height of the camera above the local visible surface, in blocks.
//
// WHY NOT WORLD Y: tall structures (mountains, skyscrapers, elevated rail)
// make absolute thresholds wrong - a player on a Y=180 roof is AT the local
// surface and must not get fake rain. The estimator instead reconstructs the
// player-space height of VISIBLE surfaces from a sparse fixed pattern of
// depthtex0 samples and takes the least-negative one: the surface closest to
// level with the camera IS the local surface. On a roof that is the roof
// (delta ~2, helper off); far above open terrain it is the ground (delta =
// altitude, helper on). Sky samples carry no surface and are skipped; if no
// ground is in frame the answer is "unknown", treated as ground level (helper
// off) - the safe reading, because vanilla rain follows the camera whenever
// the camera is near its own surface.
//
// Cost: six depth fetches + six unprojections, executed only after the
// rainStrength early-out, and only in rain. The pattern is fixed in screen
// space so the estimate does not pop between frames of ordinary play.
float aureliaCameraHeightAboveSurface(vec2 screen) {
    // Fixed sample pattern over the lower frame, where the local surface
    // lives in normal play. Texture v=0 is the screen BOTTOM.
    vec2 samples[6] = vec2[6](
        vec2(0.30, 0.05), vec2(0.70, 0.05), vec2(0.50, 0.14),
        vec2(0.14, 0.22), vec2(0.86, 0.22), vec2(0.50, 0.38)
    );
    // Least-negative reconstructed Y among surfaces below the camera: the
    // local surface. Surfaces above eye level (walls, mountain faces) do not
    // count - they are not the surface the player stands relative to.
    float closestToLevel = -1.0e5;   // sentinel: none found yet
    for (int i = 0; i < 6; ++i) {
        float depth = textureLod(depthtex0, samples[i], 0.0).r;
        if (depth < 1.0) {
            vec4 clip = vec4(samples[i] * 2.0 - 1.0, depth, 1.0);
            vec4 viewPos = gbufferProjectionInverse * clip;
            viewPos /= viewPos.w;
            // WORLD-axes height: view-space y tilts with camera pitch (looking
            // down, every surface has view-y near zero), so rotate to player
            // space before judging "below the camera".
            float height = (gbufferModelViewInverse * vec4(viewPos.xyz, 0.0)).y;
            if (height < 0.0) {
                closestToLevel = max(closestToLevel, height);
            }
        }
    }
    // No ground visible: unknown, treat as ground level (helper stays off).
    if (closestToLevel <= -1.0e4) {
        return 0.0;
    }
    return clamp(-closestToLevel, 0.0, 240.0);
}

// Composited distant rain for a screen pixel, in LINEAR light. The caller adds
// this to the scene before grading.
vec3 aureliaDistantRain(vec2 screen) {
    // Clear weather: one uniform compare, then nothing.
    if (rainStrength < 0.01) {
        return vec3(0.0);
    }
    // HIGH-ALTITUDE GATE. Minecraft's real weather already produces complete
    // rain around the player at ordinary heights (rain exists below each
    // column's precipitation height, which normally includes the camera), so
    // near the local surface the procedural contribution is exactly zero and
    // the function returns before any streak work. The helper exists for the
    // case the in-game evidence showed: the camera far above the surrounding
    // surface (falling, elytra, towers without nearby geometry), where vanilla
    // rain columns all terminate below the player.
    float heightAboveSurface = aureliaCameraHeightAboveSurface(screen);
    if (heightAboveSurface <= 0.0) {
        return vec3(0.0);
    }
    // <= ~25 blocks above the local surface: vanilla only. 25-60: gradual
    // fade. >= 60: full helper. Smooth by construction, no altitude pop, and
    // driven by the measured gap to the nearest surface - never world Y.
    float altitudeGate = smoothstep(25.0, 60.0, heightAboveSurface);
    if (altitudeGate <= 0.0) {
        return vec3(0.0);
    }
    // Depth behaviour: reconstruct true view distance from depthtex0, the same
    // way the shadow and water passes reason about space - no nonlinear-depth
    // threshold guesses. Depth 1.0 (sky) unprojects to the far plane. The
    // distance ramp is deliberately CAPPED below full weight: nearby vanilla
    // rain must stay the strongest rain on screen, so the curtain begins
    // subtly in the middle distance, becomes useful over distant terrain and
    // the sky, and never reaches the contrast of a real nearby drop just
    // because the depth mask saturated.
    // textureLod: this point is reached after data-dependent early returns, where
    // an implicit-derivative texture() has undefined LOD.
    float depth = textureLod(depthtex0, screen, 0.0).r;
    vec4 clip = vec4(screen * 2.0 - 1.0, depth, 1.0);
    vec4 viewPos = gbufferProjectionInverse * clip;
    viewPos /= viewPos.w;
    float distanceWeight = smoothstep(12.0, 40.0, length(viewPos.xyz)) * 0.85;
    if (distanceWeight <= 0.0) {
        return vec3(0.0);
    }
    // Polish pass: dense but individually subtle. More, shorter, thinner
    // streaks at lower opacity. Where two layers run (Cinematic) the second
    // adds depth at clearly lower weight instead of doubling brightness.
    // Low/Balanced/Adaptive run the single middle layer, which is also the
    // cheaper path.
    float rain;
#if AURELIA_DISTANT_RAIN_LAYERS >= 2
    rain = aureliaRainLayer(screen, 200.0, 3.1, 0.36, 0.55, 1.0) * 0.40
         + aureliaRainLayer(screen, 120.0, 4.6, 0.50, 0.62, 2.0) * 0.28;
#else
    rain = aureliaRainLayer(screen, 170.0, 3.8, 0.40, 0.58, 1.0) * 0.52;
#endif
    // Same subdued cool grey-blue family as gbuffers_weather, dimmed at night
    // so distant streaks never glow against the navy sky.
    float dayFactor = mix(0.45, 1.0, aureliaSunVisibility());
    return vec3(0.070, 0.080, 0.096) * (rain * rainStrength * distanceWeight * altitudeGate * dayFactor);
}
