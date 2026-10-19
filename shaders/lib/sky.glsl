// Analytic atmosphere for gbuffers_skybasic, and the shared sky/fog palette for
// every program that fogs. ALU only: no texture read, no render target, no
// extra pass. The dome is enabled by AURELIA_ATMOSPHERE; when that option is
// off gbuffers_skybasic uses the flat look.glsl ramp instead, so the treatment
// stays revertible from the Iris options screen without a code edit.
//
// Included after lib/look.glsl, so the contract helpers and constants are in
// scope. Uniforms declared here: hasCeiling and hasSkylight (always) and isEyeInWater (only
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
// entry points below return the fog colour directly in that case.
uniform bool hasCeiling;
// Iris: false in the Nether and the End. The End has no sun-driven atmosphere
// either; on the day palette its islands lit and hazed like Overworld noon
// (seen in game: white-blue island, untextured pillars). Unlike hasCeiling an
// unsupported uniform would read as the no-sky path, so this relies on Iris
// 1.7.6 providing it (it does: DimensionUniforms).
uniform bool hasSkylight;

// No sun-driven atmosphere: the Nether (ceiling) or the End (no sky light).
bool aureliaNoSky() {
    return hasCeiling || !hasSkylight;
}

// Fill light of a no-sky dimension: warm Nether embers or cool End void.
vec3 aureliaNoSkyAmbient() {
    return hasCeiling ? AURELIA_NETHER_AMBIENT : AURELIA_END_AMBIENT;
}

// Under AURELIA_WATER_UNDERWATER the underwater atmosphere needs the camera's
// submersion state. Iris exposes isEyeInWater as an int: 1 = water, 2 = lava,
// 0 = air. Only == 1 is handled; lava keeps the accepted air behaviour.
#ifdef AURELIA_WATER_UNDERWATER
uniform int isEyeInWater;
#endif

// Phase 5: the sky, its light and the aerial perspective all come from the
// physical sky-view LUT (lib/atmosphere.glsl, written by prepare.fsh).
#define AURELIA_SKY_LUT_READ
#include "/lib/atmosphere.glsl"
#ifdef AURELIA_WATER_UNDERWATER
    // The underwater atmosphere is the water column's own in-scatter.
    #include "/lib/water.glsl"
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

// --- Per-frame sky palette ----------------------------------------------------
// Everything in the gradient except the view direction depends only on
// uniforms: the day/night blend, the golden-hour bell, the zenith and horizon
// palette mixes, the sun tint, the overcast pair and the aureole weight. In the
// sky pass that work ran on every pixel of the screen (the sky is drawn before
// terrain), ~1 ms at 1080p on the M1 (docs/PHASE4.md). A program can opt in
// by defining AURELIA_SKY_FRAME_VERTEX in its vertex stage (and calling
// aureliaWriteSkyFrame()) and AURELIA_SKY_FRAME_FRAGMENT in its fragment
// stage; the values then cross as flat varyings, computed with the identical
// expressions. Every other caller computes them in place, as before.
struct AureliaSkyFrame {
    vec3 zenith;          // dry zenith: day/night blend plus the skyColor nod
    vec3 horizon;         // dry horizon: day/night blend plus the cool dusk pull
    vec3 sunTint;         // aureliaSunColor(max(sunHeight, 0))
    vec3 overcastHorizon; // the overcast pair, already dimmed by the day blend
    vec3 overcastZenith;
    float day;            // aureliaSunVisibility()
    float golden;         // aureliaGoldenBell(sunHeight)
    float glowWeight;     // aureliaGlowWeight(day, sunHeight, rain)
};

AureliaSkyFrame aureliaSkyFrameCompute(vec3 skyColorLinear, vec3 fogColorLinear, vec3 lightDirection, float rain) {
    AureliaSkyFrame frame;
    float sunHeight = lightDirection.y;
    frame.day = aureliaSunVisibility();
    frame.golden = aureliaGoldenBell(sunHeight);
    frame.glowWeight = aureliaGlowWeight(frame.day, sunHeight, rain);
    frame.sunTint = aureliaSunColor(max(sunHeight, 0.0));
    frame.zenith = mix(AURELIA_NIGHT_ZENITH, AURELIA_DAY_ZENITH, frame.day);
    // A weak nod to Minecraft's sky colour keeps time/biome alive by day
    // without letting its cyan lead the palette. Zero at night.
    frame.zenith = mix(frame.zenith, skyColorLinear * 0.55, 0.20 * frame.day);
    frame.horizon = mix(AURELIA_NIGHT_HORIZON, fogColorLinear, frame.day);
    // The anti-solar side is pulled toward a cool blue-grey while the warmth
    // is up, so the sunset ring does not read orange end to end. The pull
    // keeps a fogColor majority, so the silhouette edge against distant
    // terrain stays close. (The sun-facing warmth is per direction, below.)
    frame.horizon = mix(frame.horizon, AURELIA_COOL_HORIZON, 0.45 * frame.golden);
    float overcastGain = mix(0.14, 1.0, frame.day);
    frame.overcastHorizon = AURELIA_OVERCAST_HORIZON * overcastGain;
    frame.overcastZenith = AURELIA_OVERCAST_ZENITH * overcastGain;
    return frame;
}

#if defined(AURELIA_SKY_FRAME_VERTEX)
flat out vec3 aureliaSkyFrameZenith;
flat out vec3 aureliaSkyFrameHorizon;
flat out vec3 aureliaSkyFrameSunTint;
flat out vec3 aureliaSkyFrameOvercastHorizon;
flat out vec3 aureliaSkyFrameOvercastZenith;
flat out vec3 aureliaSkyFrameScalars; // day, golden, glowWeight

void aureliaWriteSkyFrame() {
    AureliaSkyFrame frame = aureliaSkyFrameCompute(
        aureliaSkyColorLinear(), aureliaFogColorLinear(), aureliaSunDirection(), rainStrength);
    aureliaSkyFrameZenith = frame.zenith;
    aureliaSkyFrameHorizon = frame.horizon;
    aureliaSkyFrameSunTint = frame.sunTint;
    aureliaSkyFrameOvercastHorizon = frame.overcastHorizon;
    aureliaSkyFrameOvercastZenith = frame.overcastZenith;
    aureliaSkyFrameScalars = vec3(frame.day, frame.golden, frame.glowWeight);
}
#elif defined(AURELIA_SKY_FRAME_FRAGMENT)
flat in vec3 aureliaSkyFrameZenith;
flat in vec3 aureliaSkyFrameHorizon;
flat in vec3 aureliaSkyFrameSunTint;
flat in vec3 aureliaSkyFrameOvercastHorizon;
flat in vec3 aureliaSkyFrameOvercastZenith;
flat in vec3 aureliaSkyFrameScalars;
#endif

// The frame for these inputs. Under AURELIA_SKY_FRAME_FRAGMENT the arguments
// are ignored and the vertex stage's values are returned: every caller in such
// a program passes exactly the frame inputs (the decoded sky/fog colours, the
// sun direction and rainStrength) that aureliaWriteSkyFrame() used.
AureliaSkyFrame aureliaSkyFrame(vec3 skyColorLinear, vec3 fogColorLinear, vec3 lightDirection, float rain) {
#ifdef AURELIA_SKY_FRAME_FRAGMENT
    return AureliaSkyFrame(
        aureliaSkyFrameZenith, aureliaSkyFrameHorizon, aureliaSkyFrameSunTint,
        aureliaSkyFrameOvercastHorizon, aureliaSkyFrameOvercastZenith,
        aureliaSkyFrameScalars.x, aureliaSkyFrameScalars.y, aureliaSkyFrameScalars.z);
#else
    return aureliaSkyFrameCompute(skyColorLinear, fogColorLinear, lightDirection, rain);
#endif
}

// The dry gradient shared by the dome and the fog colour: the frame's palette
// plus the two per-direction terms, the warm sun-facing horizon and the
// vertical ramp (also needed by the overcast pair). No aureole, no bodies, no
// rain: callers add what they need.
vec3 aureliaSkyGradient(AureliaSkyFrame frame, vec3 direction, vec3 lightDirection, out float ramp) {
    // Warmth belongs to the sun-facing horizon only; the azimuth gate keeps
    // the opposite side cool instead of painting the whole ring.
    vec2 viewAzimuth2 = direction.xz;
    vec2 sunAzimuth2 = lightDirection.xz;
    float azimuthSpan = length(viewAzimuth2) * length(sunAzimuth2);
    float azimuthAlign = azimuthSpan > 1e-4
        ? dot(viewAzimuth2, sunAzimuth2) / azimuthSpan : 0.0;
    float nearSun = smoothstep(0.05, 0.85, azimuthAlign);
    vec3 horizon = mix(frame.horizon, frame.sunTint * 0.90, 0.80 * frame.golden * nearSun);

    ramp = smoothstep(-0.28, 0.62, direction.y);
    return mix(horizon, frame.zenith, ramp);
}

// The overcast pair at a vertical ramp position (aureliaOvercast's value).
vec3 aureliaFrameOvercast(AureliaSkyFrame frame, float ramp) {
    return mix(frame.overcastHorizon, frame.overcastZenith, ramp);
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
    if (aureliaNoSky()) {
        return fogColorLinear;
    }
    AureliaSkyFrame frame = aureliaSkyFrame(skyColorLinear, fogColorLinear, lightDirection, rain);
    float ramp;
    vec3 sky = aureliaSkyGradient(frame, direction, lightDirection, ramp);

    // Solar aureole: both layers REPLACE-mix toward the sun tint, bounded, so
    // the glow is warm yellow at noon and orange at golden hour and can never
    // overflow into pink. (An additive broad term stacked orange on the blue
    // dome and showed as a red-purple ring.)
    float align = max(dot(direction, lightDirection), 0.0);
    sky = mix(sky, frame.sunTint, pow(align, 64.0) * 0.65 * frame.glowWeight);
    sky = mix(sky, frame.sunTint, pow(align, 5.0) * 0.25 * frame.glowWeight);

    // ONE rain response: an authored blue-grey overcast keeps the vertical
    // ramp recognisable instead of flattening to neutral grey.
    return mix(sky, aureliaFrameOvercast(frame, ramp), AURELIA_RAIN_SKY_FLATTEN * rain);
}

// Dedicated fog colour: the dome MINUS the solar aureole. Sky, fog and water
// stay one system because this shares aureliaSkyGradient and the overcast pair
// with the dome - it is not a second palette. The aureole is omitted because
// fog's directional warmth comes entirely from the gradient's horizon rule; the
// tight halo only matters within a couple of degrees of the disc, where fogged
// geometry rarely sits.
vec3 aureliaFogColor(vec3 skyColorLinear, vec3 fogColorLinear, vec3 direction, vec3 lightDirection, float rain) {
    if (aureliaNoSky()) {
        return fogColorLinear;
    }
    AureliaSkyFrame frame = aureliaSkyFrame(skyColorLinear, fogColorLinear, lightDirection, rain);
    float ramp;
    vec3 sky = aureliaSkyGradient(frame, direction, lightDirection, ramp);
#ifdef AURELIA_FOG_HAZE
    // Sun haze: the dome's broad aureole layer, identical to aureliaSkyDome's,
    // so fog looking sunward glows warm and distant terrain fades into the
    // same colour the dome paints behind it. (The tight pow-64 layer stays
    // dome-only; it sits within a few degrees of the disc.)
    float align = max(dot(direction, lightDirection), 0.0);
    sky = mix(sky, frame.sunTint, pow(align, 5.0) * 0.25 * frame.glowWeight);
#endif
    return mix(sky, aureliaFrameOvercast(frame, ramp), AURELIA_RAIN_SKY_FLATTEN * rain);
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
    float darkness = 1.0 - smoothstep(-0.28, -0.10, sunHeight);
    // Uniform per frame: by day (or under full overcast) every star term is
    // multiplied by zero, so skip the two hashes. They cost ~0.7 ms of a
    // full-screen daylight sky at 1080p on the M1 for no visible output.
    if (darkness * (1.0 - rain) <= 0.0) return sky;
    float elevation = clamp(direction.y, -1.0, 1.0);
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
    AureliaSkyFrame frame = aureliaSkyFrame(skyColorLinear, fogColorLinear, lightDirection, rain);
    float align = max(dot(direction, lightDirection), 0.0);
    vec3 sky = aureliaSkyDome(skyColorLinear, fogColorLinear, direction, lightDirection, rain);
    sky = aureliaApplySunDisc(sky, align, frame.glowWeight, rain);
    sky = aureliaApplyMoon(sky, direction, moonDirection, frame.day, rain);
    return aureliaApplyStars(sky, direction, sunHeight, rain);
}

// Underwater atmosphere colour: open water seen from inside it, lit by the
// sun, moon and sky that enter through the surface (lib/water.glsl). The
// LUT already dims the light for rain and night, so the column follows the
// weather and the time of day with no palette of its own. Looking up the
// column reads brighter than looking down it, the cheapest honest depth cue.
#ifdef AURELIA_WATER_UNDERWATER
vec3 aureliaUnderwaterColor(vec3 direction, float rain) {
    vec3 downwelling = aureliaNoSky() ? aureliaNoSkyAmbient() : aureliaWaterDownwelling(1.0, 1.0, 1.0);
    return aureliaWaterColumnRadiance(direction, downwelling);
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
// playerPosition: camera-relative, WORLD axes. A view-space vector here tilts
// the fog palette with camera pitch/yaw, because the palette is world-space.
//
// The fog is returned as TERMS, rgb = fogColour * f and a = 1 - f, so that
// mix(color, fogColour, f) == color * a + rgb. Vertex stages evaluate the terms
// once per vertex and the fragment stage applies them with one multiply-add
// (aureliaApplyFogTerms): the fog colour is the full sky gradient, and running
// it per fragment cost terrain ~0.5 ms at 1080p on the M1 (docs/PHASE4.md).
// Faces are at most a block across, so linear interpolation of the terms is
// visually exact; weather was already fogged this way.
vec4 aureliaFogTerms(vec3 playerPosition, float density, float rain) {
    float distanceToCamera = length(playerPosition);
    vec3 direction = playerPosition / max(distanceToCamera, 1e-4);
#ifdef AURELIA_WATER_UNDERWATER
    // Submerged: every fragment in view is seen through the water column, so
    // fade toward the underwater atmosphere on its own denser curve. Lava
    // (isEyeInWater == 2) and air (0) fall through to the air path below.
    if (isEyeInWater == 1) {
        float underwater = aureliaUnderwaterFogFactor(distanceToCamera, rain);
        return vec4(aureliaUnderwaterColor(direction, rain) * underwater, 1.0 - underwater);
    }
#endif
    if (aureliaNoSky()) {
        // Nether air is thick and lit by its own fog colour; End air is
        // thinner (its far islands stay visible, as in vanilla). No sky.
        float fog = aureliaFogFactor(distanceToCamera, density * (hasCeiling ? 3.0 : 1.0), rain);
        return vec4(aureliaFogColorLinear() * (AURELIA_NETHER_FOG_SCALE * fog), 1.0 - fog);
    }
    // Aerial perspective. Haze extinction per block at sea level, far
    // stronger than clean air (a metre-scale world would otherwise show no
    // depth at all within a render distance), and thicker in rain.
    float sigma = AURELIA_HAZE_EXTINCTION * density * (1.0 + 1.8 * rain);
#ifdef AURELIA_FOG_HAZE
    // Height: the haze thins exponentially above the ground layer, and the
    // optical depth along the ray integrates that profile exactly, so a
    // tower top looks out over haze and down into it.
    float h0 = cameraPosition.y - AURELIA_HAZE_GROUND;
    float k = playerPosition.y / AURELIA_HAZE_SCALE_HEIGHT;
    float base = exp(-max(h0, -40.0) / AURELIA_HAZE_SCALE_HEIGHT);
    float profile = abs(k) > 1e-3 ? base * (1.0 - exp(-k)) / k : base;
    sigma *= clamp(profile, 0.08, 1.6);
#endif
    float transmittance = exp(-sigma * distanceToCamera);
    // In-scatter: the haze glows with what the sky shows just above the
    // horizon, sun aureole and city glow included, at the fragment's own
    // angle from the sun. Taking the horizon at the fragment's azimuth
    // instead put everything below a low sun into the aureole's peak (Mie
    // phase ~36x isotropic at 2 degrees, ~5x at the 25 degrees a roof below
    // the camera really is) and washed out golden-hour views over a city.
    vec3 sunDirection = aureliaSunDirection();
    vec3 haze = aureliaSkyRadianceAtAngle(dot(direction, sunDirection),
                                          0.04 + 0.5 * max(direction.y, 0.0), sunDirection);
    // The world's edge resolves into the sky behind it, as vanilla's fog
    // does. Off when `far` is unknown (offline tools).
    float border = far > 0.0 ? smoothstep(0.78 * far, far, distanceToCamera) : 0.0;
    vec3 behind = aureliaSkyRadiance(direction, sunDirection);
    vec3 inscatter = mix(haze * (1.0 - transmittance), behind, border);
    return vec4(inscatter, transmittance * (1.0 - border));
}

vec3 aureliaApplyFogTerms(vec3 color, vec4 fogTerms) {
    return color * fogTerms.a + fogTerms.rgb;
}

vec3 aureliaApplyFogContract(vec3 color, vec3 playerPosition, float density, float rain) {
    return aureliaApplyFogTerms(color, aureliaFogTerms(playerPosition, density, rain));
}

// --- Physical sky view (gbuffers_skybasic) ------------------------------------
// The LUT's sky radiance plus the bodies the LUT leaves out. The sun disc is
// limb-darkened and as bright as the half-float target sensibly holds; its
// colour is the direct sunlight at the camera, so it reddens and dims through
// the same air the light does. Rain covers it.
const float AURELIA_SUN_RADIUS = 0.0095;  // radians, about twice the real sun
const float AURELIA_MOON_RADIUS = 0.0105;

vec3 aureliaSkyView(vec3 direction, float rain) {
    vec3 sunDirection = aureliaSunDirection();
    vec3 moonDirection = aureliaMoonDirection();
    vec3 sky = aureliaSkyRadiance(direction, sunDirection);
    float clear = 1.0 - rain;
    if (clear <= 0.0) return sky;

    float sunCos = dot(direction, sunDirection);
    if (sunCos > 0.9995) {
        float angle = acos(clamp(sunCos, -1.0, 1.0));
        float r = angle / AURELIA_SUN_RADIUS;
        if (r < 1.15) {
            float mu = sqrt(max(1.0 - r * r, 0.0));
            // Limb darkening, Neckel-Labs-like: the rim at ~45% of the centre.
            vec3 limb = vec3(0.40, 0.33, 0.25) + vec3(0.60, 0.67, 0.75) * mu;
            float edge = 1.0 - smoothstep(0.92, 1.0, r);
            sky += aureliaSunLight() * (180.0 * edge * clear) * limb;
        }
    }

    float moonCos = dot(direction, moonDirection);
    if (moonCos > 0.9990) {
        float r = acos(clamp(moonCos, -1.0, 1.0)) / AURELIA_MOON_RADIUS;
        float disc = 1.0 - smoothstep(0.90, 1.0, r);
        // Maria: two octaves of the star hash in the disc's own frame.
        vec3 local = (direction - moonDirection) / AURELIA_MOON_RADIUS;
        float maria = 0.78 + 0.22 * aureliaStarHash(floor(local * 3.0)) * aureliaStarHash(floor(local * 7.0) + 3.0);
        vec3 moonDisc = vec3(0.92, 0.94, 1.00) * maria;
        float up = smoothstep(-0.03, 0.03, moonDirection.y);
        // Radiance of a grey (albedo 0.12) lit disc, kept well above the
        // night sky so it reads as the brightest thing in it.
        sky += moonDisc * (disc * up * clear * 0.9);
    }

    // Stars once the sky has darkened, faded by the Purkinje-free night
    // radiance scale (they sit around 1e-2 against a 1e-3 sky).
    float darkness = 1.0 - smoothstep(-0.25, -0.05, sunDirection.y);
    if (darkness * clear > 0.0 && direction.y > -0.02) {
        vec3 starCell = floor(direction * 300.0);
        float starMask = smoothstep(0.9968, 1.0, aureliaStarHash(starCell));
        float starBright = aureliaStarHash(starCell + vec3(17.0));
        vec3 starColor = mix(vec3(1.00, 0.86, 0.70), vec3(0.78, 0.86, 1.00), starBright);
        float extinction = smoothstep(-0.02, 0.25, direction.y);
        sky += starColor * (starMask * (0.007 + 0.05 * starBright * starBright) * darkness * clear * extinction);
    }
    return sky;
}
