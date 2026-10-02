// Analytic atmosphere for gbuffers_skybasic, and the shared sky/fog palette for
// every program that fogs. ALU only: no texture read, no render target, no
// extra pass. The dome is enabled by AURELIA_ATMOSPHERE; when that option is
// off gbuffers_skybasic uses the flat look.glsl ramp instead, so the treatment
// stays revertible from the Iris options screen without a code edit.
//
// Included after lib/look.glsl, so the contract helpers and constants are in
// scope. Uniforms declared here: hasCeiling (always) and isEyeInWater (only
// under AURELIA_WATER_UNDERWATER).
//
// The sun and moon are drawn analytically (soft limb, layered aureole) in place
// of Minecraft's square textures, which gbuffers_skytextured suppresses. This
// is a disc + glow, not light shafts: real rays need an occlusion-aware post
// pass and are a separate, measured change.
//
// Layout: palette -> shared gradient -> dome -> fog colour -> celestial bodies
// -> visible sky -> underwater -> fog apply.

// Iris: true in dimensions with a bedrock ceiling (the Nether). An unsupported
// uniform reads as false, which is the Overworld path, so this polarity cannot
// change Overworld behaviour. The Nether has no sun-driven atmosphere: its sun
// sits fixed below the horizon, so the day/night palette would fog everything
// to the night navy instead of Minecraft's own Nether fogColor. Both palette
// entry points below return the fog colour directly in that case. (The End has
// no uniform with a safe polarity and keeps the day palette.)
uniform bool hasCeiling;

// Under AURELIA_WATER_UNDERWATER the underwater atmosphere needs the camera's
// submersion state. Iris exposes isEyeInWater as an int: 1 = water, 2 = lava,
// 0 = air. Only == 1 is handled; lava keeps the accepted air behaviour.
#ifdef AURELIA_WATER_UNDERWATER
uniform int isEyeInWater;
#endif

// Sparse procedural star field. A cheap position hash; no texture.
float aureliaStarHash(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

// --- Authored sky palettes (linear light) ------------------------------------
// One zenith, one horizon, one sun-facing warmth term, one day/night blend,
// one rain response. The day horizon is the fog colour itself: terrain at
// maximum distance fades to exactly that colour, so anchoring the horizon
// there keeps the world's far edge seam-free by construction instead of by
// tuning. The day zenith is authored rather than scaled from Minecraft's sky
// colour, which is saturated cyan-blue at noon and was the flat cyan wash.
const vec3 AURELIA_DAY_ZENITH       = vec3(0.070, 0.160, 0.430); // medium blue
const vec3 AURELIA_NIGHT_ZENITH     = vec3(0.011, 0.019, 0.045); // deep desaturated navy
const vec3 AURELIA_NIGHT_HORIZON    = vec3(0.030, 0.047, 0.088); // lighter blue
const vec3 AURELIA_COOL_HORIZON     = vec3(0.30, 0.42, 0.62);    // anti-solar dusk pull
const vec3 AURELIA_OVERCAST_ZENITH  = vec3(0.16, 0.20, 0.27);    // blue-grey, not grey
const vec3 AURELIA_OVERCAST_HORIZON = vec3(0.34, 0.38, 0.44);

// Golden-hour bell in sun height: warmth rises as the sun nears the horizon and
// is fully gone by night and by noon alike. Shared by the sky, the fog and the
// underwater column so all three arrive and leave with the same sunset.
float aureliaGoldenBell(float sunHeight) {
    return smoothstep(-0.12, 0.02, sunHeight)
        * (1.0 - smoothstep(0.06, 0.30, sunHeight));
}

// The overcast pair for a given ramp position. It is a daylight palette, so it
// is dimmed by the same day/night blend as the dome: at full rain the night sky
// must stay the night navy (mixing the day overcast in at full weight
// brightened rainy nights ~4x). At day = 0 the 0.14 rest gain lands the
// overcast just above the night palette instead of far above it.
vec3 aureliaOvercast(float ramp, float day) {
    return mix(AURELIA_OVERCAST_HORIZON, AURELIA_OVERCAST_ZENITH, ramp)
        * mix(0.14, 1.0, day);
}

// Solar aureole strength: zero at night, boosted near the horizon, dimmed by
// rain. One definition for the dome and the sun disc.
float aureliaGlowWeight(float day, float sunHeight, float rain) {
    float lowSun = 1.0 - smoothstep(0.0, 0.34, abs(sunHeight));
    return day * (1.0 + 0.6 * lowSun) * (1.0 - AURELIA_RAIN_GLOW_DIM * rain);
}

// The dry gradient shared by the dome and the fog colour: night/day palette,
// the warm sun-facing horizon and the cool anti-solar pull. Returns the colour
// and the vertical ramp (also needed by the overcast pair). No aureole, no
// bodies, no rain: callers add what they need.
vec3 aureliaSkyGradient(
    vec3 skyColorLinear,
    vec3 fogColorLinear,
    vec3 direction,
    vec3 lightDirection,
    float day,
    out float ramp
) {
    float sunHeight = lightDirection.y;
    vec3 zenith = mix(AURELIA_NIGHT_ZENITH, AURELIA_DAY_ZENITH, day);
    vec3 horizon = mix(AURELIA_NIGHT_HORIZON, fogColorLinear, day);
    // A weak nod to Minecraft's sky colour keeps time/biome alive by day
    // without letting its cyan lead the palette. Zero at night.
    zenith = mix(zenith, skyColorLinear * 0.55, 0.20 * day);

    float golden = aureliaGoldenBell(sunHeight);
    // Warmth belongs to the sun-facing horizon only; the azimuth gate keeps
    // the opposite side cool instead of painting the whole ring.
    vec2 viewAzimuth2 = direction.xz;
    vec2 sunAzimuth2 = lightDirection.xz;
    float azimuthSpan = length(viewAzimuth2) * length(sunAzimuth2);
    float azimuthAlign = azimuthSpan > 1e-4
        ? dot(viewAzimuth2, sunAzimuth2) / azimuthSpan : 0.0;
    float nearSun = smoothstep(0.05, 0.85, azimuthAlign);
    // The anti-solar side is pulled toward a cool blue-grey while the warmth
    // is up, so the sunset ring does not read orange end to end. The pull
    // keeps a fogColor majority, so the silhouette edge against distant
    // terrain stays close.
    horizon = mix(horizon, AURELIA_COOL_HORIZON, 0.45 * golden);
    horizon = mix(horizon, aureliaSunColor(max(sunHeight, 0.0)) * 0.90,
                  0.80 * golden * nearSun);

    ramp = smoothstep(-0.28, 0.62, direction.y);
    return mix(horizon, zenith, ramp);
}

// The sky DOME for a player-space direction: the gradient, the solar aureole
// (atmospheric haze AROUND the sun, which is part of the dome, not a light
// source) and the rain overcast. Deliberately contains no sun disc, no moon,
// no stars and no direct glint: the visible sky pass adds those itself, and the
// water reflection reuses this dome while keeping its own explicit glint, so
// the sun is lit exactly once in the reflection.
vec3 aureliaSkyDome(
    vec3 skyColorLinear,
    vec3 fogColorLinear,
    vec3 direction,
    vec3 lightDirection,
    float rain
) {
    if (hasCeiling) {
        return fogColorLinear;
    }
    float sunHeight = lightDirection.y;
    // ONE day/night blend, driving both palette levels with the same curve.
    float day = aureliaSunVisibility();
    float ramp;
    vec3 sky = aureliaSkyGradient(skyColorLinear, fogColorLinear, direction,
                                  lightDirection, day, ramp);

    // Solar aureole: both layers REPLACE-mix toward the sun tint, bounded, so
    // the glow is warm yellow at noon and orange at golden hour and can never
    // overflow into pink. (An additive broad term stacked orange on the blue
    // dome and showed as a red-purple ring.)
    float align = max(dot(direction, lightDirection), 0.0);
    float glowWeight = aureliaGlowWeight(day, sunHeight, rain);
    vec3 sunTint = aureliaSunColor(max(sunHeight, 0.0));
    sky = mix(sky, sunTint, pow(align, 64.0) * 0.65 * glowWeight);
    sky = mix(sky, sunTint, pow(align, 5.0) * 0.25 * glowWeight);

    // ONE rain response: an authored blue-grey overcast keeps the vertical
    // ramp recognisable instead of flattening to neutral grey.
    return mix(sky, aureliaOvercast(ramp, day), AURELIA_RAIN_SKY_FLATTEN * rain);
}

// Dedicated fog colour: the dome MINUS the solar aureole. Sky, fog and water
// stay one system because this shares aureliaSkyGradient and aureliaOvercast
// with the dome - it is not a second palette. The aureole is omitted because
// fog's directional warmth comes entirely from the gradient's horizon rule; the
// tight halo only matters within a couple of degrees of the disc, where fogged
// geometry rarely sits.
vec3 aureliaFogColor(vec3 skyColorLinear, vec3 fogColorLinear, vec3 direction, vec3 lightDirection, float rain) {
    if (hasCeiling) {
        return fogColorLinear;
    }
    float day = aureliaSunVisibility();
    float ramp;
    vec3 sky = aureliaSkyGradient(skyColorLinear, fogColorLinear, direction,
                                  lightDirection, day, ramp);
    return mix(sky, aureliaOvercast(ramp, day), AURELIA_RAIN_SKY_FLATTEN * rain);
}

// --- Shared celestial bodies -------------------------------------------------
// Drawn by the analytic atmosphere AND by Potato's fallback ramp, so every
// preset gets the same round sun, moon and stars. Each function is pure: it
// takes the colour so far and returns it with the body composited.

// The round limb-darkened sun disc, replacing Minecraft's square texture. The
// centre is deliberately near-neutral white: the fitted ACES curve hue-shifts
// strongly saturated warm colours into salmon-pink as they clip, which is
// exactly the pink core the sun used to render with. The warm character lives
// in the aureole, which stays in the dome function. Full overcast hides the
// disc itself ((1 - rain): at rain 1.0 no disc, matching vanilla, where rain
// clouds cover the sun); the aureole keeps its own softer contract dimming,
// so haze near the sun's position survives without a visible orb.
vec3 aureliaApplySunDisc(vec3 sky, float align, float glowWeight, float rain) {
    float disc = smoothstep(0.99863, 0.99966, align);
    vec3 discColor = mix(vec3(1.00, 0.90, 0.78), vec3(1.00, 0.97, 0.92),
                         smoothstep(0.99939, 0.99980, align));
    return mix(sky, discColor * 3.0, disc * glowWeight * (1.0 - rain));
}

// Analytic moon: a small pale disc with a faint aureole, visible at night and
// near twilight. Driven by moonPosition, not the shadow light source. Full
// overcast hides it entirely ((1 - rain)).
vec3 aureliaApplyMoon(vec3 sky, vec3 direction, vec3 moonDirection, float day, float rain) {
    float moonAlign = max(dot(direction, moonDirection), 0.0);
    float moonDisc = smoothstep(0.99889, 0.99980, moonAlign);
    float moonUp = smoothstep(-0.05, 0.05, moonDirection.y);
    vec3 moonTint = vec3(0.86, 0.90, 1.00);
    return sky + moonTint * (moonDisc * 2.0 + pow(moonAlign, 180.0) * 0.35)
        * moonUp * (1.0 - 0.85 * day) * (1.0 - rain);
}

// Stars above the horizon, only once the sun is genuinely below it, with a
// brightness spread so they do not read as one flat sprinkle, and faded by
// weather. The fade is keyed to the sky's own day/night blend (the palette
// reaches its night navy at sunHeight -0.10), so stars never pop against a sky
// still at half day brightness. Written as 1.0 - smoothstep with ordered
// edges: smoothstep with edge0 > edge1 is undefined behaviour in GLSL.
vec3 aureliaApplyStars(vec3 sky, vec3 direction, float sunHeight, float rain) {
    float elevation = clamp(direction.y, -1.0, 1.0);
    float darkness = 1.0 - smoothstep(-0.28, -0.10, sunHeight);
    float above = smoothstep(0.0, 0.15, elevation);
    vec3 starCell = floor(direction * 260.0);
    float starMask = smoothstep(0.9965, 1.0, aureliaStarHash(starCell));
    float starBright = aureliaStarHash(starCell + vec3(17.0));
    vec3 starColor = mix(vec3(0.42, 0.46, 0.62), vec3(0.90, 0.93, 1.00),
                         smoothstep(0.94, 1.0, starBright));
    return sky + starColor * (starMask * darkness * above * (1.0 - rain) * 1.6);
}

// The visible sky: the shared dome (which already carries the rain overcast),
// then the sun, moon and stars drawn on top of it.
vec3 aureliaAtmosphereSky(
    vec3 skyColorLinear,
    vec3 fogColorLinear,
    vec3 direction,
    vec3 lightDirection,
    vec3 moonDirection,
    float rain
) {
    float sunHeight = lightDirection.y;
    float day = aureliaSunVisibility();
    float align = max(dot(direction, lightDirection), 0.0);
    float glowWeight = aureliaGlowWeight(day, sunHeight, rain);
    vec3 sky = aureliaSkyDome(skyColorLinear, fogColorLinear, direction, lightDirection, rain);
    sky = aureliaApplySunDisc(sky, align, glowWeight, rain);
    sky = aureliaApplyMoon(sky, direction, moonDirection, day, rain);
    return aureliaApplyStars(sky, direction, sunHeight, rain);
}

// Underwater atmosphere colour. Not a second palette: it is the dome's own
// zenith blue pushed toward the absorption direction the water body already
// leans (water.glsl multiplies the body by vec3(0.58, 0.78, 0.90) - red first),
// the dome's night navy left dark so a night dive is dark navy rather than a
// lit blue wash, and the dome's overcast pair sunk to water level for rain.
// The same day/night blend and golden-hour bell the dome uses drive it. The
// vertical term is downwelling light: looking up the column reads brighter
// than looking down it, the cheapest honest depth cue.
#ifdef AURELIA_WATER_UNDERWATER
vec3 aureliaUnderwaterColor(vec3 direction, float rain) {
    float day = aureliaSunVisibility();
    float golden = aureliaGoldenBell(aureliaSunDirection().y);
    vec3 dayWater = AURELIA_DAY_ZENITH * vec3(0.55, 1.15, 1.25);
    vec3 water = mix(AURELIA_NIGHT_ZENITH, dayWater, day);
    // A little golden-hour warmth leaks into the column before the water
    // absorbs it.
    water *= mix(vec3(1.0), vec3(1.30, 0.98, 0.82), 0.45 * golden);
    // Rain: the overcast pair sunk to water level and greyed, dimmed by the
    // day/night blend so a rainy night dive stays dark navy.
    vec3 overcast = aureliaOvercast(0.30, day) * vec3(0.45, 0.60, 0.72);
    water = mix(water, overcast, AURELIA_RAIN_SKY_FLATTEN * rain);
    // Downwelling light, bounded at both ends so neither the surface nor the
    // depth crushes out.
    float downwell = smoothstep(-0.5, 1.0, clamp(direction.y, -1.0, 1.0));
    return water * mix(0.62, 1.30, downwell);
}
#endif

// Fog a linear scene colour, direction-aware. Weather, sky and terrain all
// fade toward THE SAME atmospheric palette: aureliaFogColor along the
// direction to the fragment. Distant terrain therefore fades toward the colour
// the dome paints behind it (no seam by construction), golden-hour haze warms
// toward the sun and stays cool opposite it, night fog is the dome's navy, and
// rain fades toward the same overcast the sky shows. The distance/density curve
// itself (aureliaFogFactor) lives in lib/look.glsl. This helper lives here next
// to the palette it depends on.
vec3 aureliaApplyFogContract(vec3 color, vec3 viewPosition, float density, float rain) {
    vec3 direction = normalize(viewPosition);
#ifdef AURELIA_WATER_UNDERWATER
    // Submerged: every fragment in view is seen through the water column, so
    // fade toward the underwater atmosphere on its own denser curve. Lava
    // (isEyeInWater == 2) and air (0) fall through to the air path below.
    if (isEyeInWater == 1) {
        return mix(color, aureliaUnderwaterColor(direction, rain),
                   aureliaUnderwaterFogFactor(length(viewPosition), rain));
    }
#endif
    return mix(color,
               aureliaFogColor(aureliaSkyColorLinear(), aureliaFogColorLinear(),
                               direction, aureliaSunDirection(), rain),
               aureliaFogFactor(length(viewPosition), density, rain));
}
