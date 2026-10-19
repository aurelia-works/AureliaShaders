// Physical atmosphere (Phase 5).
//
// Single scattering through an Earth-like atmosphere over a spherical planet:
// Rayleigh (air molecules, blue sky), Mie (aerosol haze, the bright aureole
// around the sun) and ozone absorption (riding on the Rayleigh profile; it is
// what keeps the zenith blue at twilight instead of grey-orange). Optical depth
// toward the sun and moon is analytic (a Chapman grazing-incidence
// approximation), so each sample along a view ray costs two exp()s per body
// rather than a nested march. A cheap isotropic term stands in for multiple
// scattering, which lights the sky past the terminator during blue hour.
//
// prepare.fsh evaluates this once per frame into a small sky-view LUT
// (colortex5, 128x129, absolute size). Every other program only reads it:
// one bilinear fetch for sky radiance, one texelFetch for the light colours.
//
//   rows 0..127  sky radiance; u = azimuth from the sun's vertical plane
//                (0 toward the sun, 1 away from it), v = sine of the
//                elevation with a square-root squeeze that spends the rows
//                near the horizon. No asin, and a polynomial acos: every
//                pixel of sky, fog and reflection pays for this mapping.
//                The moon is always opposite the sun in Minecraft, so both
//                bodies share that plane and one half-turn of azimuth covers
//                the whole dome.
//   row 128      reserved texels, see AURELIA_LUT_* below.
//
// Units are relative: AURELIA_SUN_IRRADIANCE is the sun's irradiance above the
// atmosphere. Block light and emission are scaled against it, and the final
// pass's auto exposure brings any of it to display range.

#ifndef AURELIA_ATMOSPHERE_GLSL
#define AURELIA_ATMOSPHERE_GLSL

const float AURELIA_PI = 3.14159265;

// --- Medium -----------------------------------------------------------------
const float AURELIA_PLANET_RADIUS     = 6371.0e3;
const float AURELIA_ATMOSPHERE_RADIUS = 6471.0e3;
const vec3  AURELIA_RAYLEIGH          = vec3(5.802e-6, 13.558e-6, 33.100e-6); // scattering, /m
const float AURELIA_RAYLEIGH_HEIGHT   = 8000.0;
// Ozone column (Hillaire 2020 coefficients over a 15 km half-width layer)
// expressed on the Rayleigh scale height so the analytic airmass covers it.
const vec3  AURELIA_OZONE             = vec3(1.219e-6, 3.527e-6, 0.159e-6);
const float AURELIA_MIE_SCATTER       = 3.996e-6;
const float AURELIA_MIE_EXTINCTION    = 4.440e-6;
const float AURELIA_MIE_HEIGHT        = 1200.0;
const float AURELIA_MIE_G             = 0.78;

// --- Light ------------------------------------------------------------------
// The sun's irradiance above the atmosphere, in shader units. Ground-level
// clear-noon sun then lands near 14-16 and the open sky near 3, the real
// ~5:1 split between the sun and the sky's diffuse light.
const float AURELIA_SUN_IRRADIANCE  = 18.0;
// Full-moon light. Physically 1/400000 of the sun; the dark-adapted eye and
// the auto exposure make up most of that, and the remainder is a gameplay
// floor so a moonlit field reads as a night scene rather than a black frame.
const float AURELIA_MOON_IRRADIANCE = 0.018;
const float AURELIA_GROUND_ALBEDO   = 0.18;

// Reserved texels on LUT row 128.
const int AURELIA_LUT_ROWS        = 128;
const int AURELIA_LUT_SUN         = 0; // direct sun at the camera (rgb), a = sun share of the key light
const int AURELIA_LUT_MOON        = 1; // direct moon at the camera
const int AURELIA_LUT_SKY_UP      = 2; // sky irradiance on an up-facing surface
const int AURELIA_LUT_SKY_TOWARD  = 3; // ... on a wall facing the sun's azimuth
const int AURELIA_LUT_SKY_AWAY    = 4; // ... on a wall facing away from it
const int AURELIA_LUT_SKY_DOWN    = 5; // ground bounce on a down-facing surface
const int AURELIA_LUT_CLOUD_LIGHT = 6; // direct light at cloud altitude (rgb)
const int AURELIA_LUT_RESERVED    = 7;

// --- Geometry helpers --------------------------------------------------------

// Distances along a ray (origin relative to the planet centre) to the two
// intersections with a sphere; y < 0 means the sphere is behind or missed.
vec2 aureliaRaySphere(vec3 origin, vec3 direction, float radius) {
    float b = dot(origin, direction);
    float c = dot(origin, origin) - radius * radius;
    float d = b * b - c;
    if (d < 0.0) return vec2(-1.0);
    d = sqrt(d);
    return vec2(-b - d, -b + d);
}

// Optical depth (in scale heights x ground density) from altitude h along a
// direction with zenith cosine mu, to space. Chapman approximation after
// Schueler (GPU Pro 3): c / ((c - 1) mu + 1), c = sqrt(pi x / 2), with the
// tangent-path form below the local horizontal. x and h in scale heights.
float aureliaChapman(float planet, float h, float mu) {
    float x = planet + h;
    float c = sqrt(0.5 * AURELIA_PI * x);
    if (mu >= 0.0) {
        return c / ((c - 1.0) * mu + 1.0) * exp(-h);
    }
    float x0 = x * sqrt(max(1.0 - mu * mu, 0.0));
    float c0 = sqrt(0.5 * AURELIA_PI * x0);
    return 2.0 * c0 * exp(planet - x0) - c / ((c - 1.0) * -mu + 1.0) * exp(-h);
}

// Transmittance from a point at altitude h (metres) toward a direction with
// zenith cosine mu, out of the atmosphere. The planet's shadow is a soft edge
// a few tenths of a degree wide rather than a hard step, which would alias
// across the LUT's rows at sunset.
vec3 aureliaTransmittanceToSpace(float h, float mu) {
    float r = AURELIA_PLANET_RADIUS + h;
    // Zenith cosine of the ray that grazes the planet from this altitude.
    float horizonMu = -sqrt(max(1.0 - (AURELIA_PLANET_RADIUS * AURELIA_PLANET_RADIUS) / (r * r), 0.0));
    float lit = smoothstep(horizonMu - 0.004, horizonMu + 0.004, mu);
    if (lit <= 0.0) return vec3(0.0);
    mu = max(mu, horizonMu);
    float rayleigh = aureliaChapman(AURELIA_PLANET_RADIUS / AURELIA_RAYLEIGH_HEIGHT, h / AURELIA_RAYLEIGH_HEIGHT, mu)
                   * AURELIA_RAYLEIGH_HEIGHT;
    float mie = aureliaChapman(AURELIA_PLANET_RADIUS / AURELIA_MIE_HEIGHT, h / AURELIA_MIE_HEIGHT, mu)
              * AURELIA_MIE_HEIGHT;
    vec3 depth = (AURELIA_RAYLEIGH + AURELIA_OZONE) * rayleigh + AURELIA_MIE_EXTINCTION * mie;
    return exp(-depth) * lit;
}

float aureliaRayleighPhase(float nu) {
    return 3.0 / (16.0 * AURELIA_PI) * (1.0 + nu * nu);
}

// Cornette-Shanks: Henyey-Greenstein with the Rayleigh-like back lobe.
float aureliaMiePhase(float nu, float g) {
    float g2 = g * g;
    float denominator = 1.0 + g2 - 2.0 * g * nu;
    return 3.0 / (8.0 * AURELIA_PI) * ((1.0 - g2) * (1.0 + nu * nu))
         / ((2.0 + g2) * denominator * sqrt(denominator));
}

// Camera altitude above sea level in metres: a block is a metre and sea level
// is y 63. The floor keeps underground and void cameras inside the medium.
float aureliaCameraAltitude(float cameraY) {
    return clamp(cameraY - 63.0, 0.0, 8000.0) + 2.0;
}

// --- LUT mapping ---------------------------------------------------------------

// The azimuth reference: the horizontal direction toward the sun. At the
// zenith the sky is symmetric about it, so the fallback axis is never wrong.
vec2 aureliaSunAzimuthAxis(vec3 sunDirection) {
    float len = length(sunDirection.xz);
    return len > 1e-4 ? sunDirection.xz / len : vec2(1.0, 0.0);
}

// acos to about 7e-5 rad (Abramowitz & Stegun 4.4.45). The built-in costs
// several times more on the M1, and the sky mapping runs per pixel.
float aureliaFastAcos(float x) {
    float a = abs(x);
    float r = sqrt(1.0 - a) * (1.5707288 + a * (-0.2121144 + a * (0.0742610 - 0.0187293 * a)));
    return x >= 0.0 ? r : AURELIA_PI - r;
}

// LUT coordinates of the sky at `cosAzimuth` from the sun's azimuth and
// height y (sine of the elevation).
vec2 aureliaSkyLutUvAt(float cosAzimuth, float y) {
    float u = aureliaFastAcos(clamp(cosAzimuth, -1.0, 1.0)) * (1.0 / AURELIA_PI);
    y = clamp(y, -1.0, 1.0);
    float v = 0.5 + 0.5 * sign(y) * sqrt(abs(y));
    // Texel centres of the 128 sky rows; the reserved row stays out of reach.
    const vec2 size = vec2(128.0, 129.0);
    return vec2(0.5 + u * 127.0, 0.5 + v * 127.0) / size;
}

vec2 aureliaSkyLutUv(vec3 direction, vec3 sunDirection) {
    vec2 axis = aureliaSunAzimuthAxis(sunDirection);
    float horizontal = length(direction.xz);
    float cosAzimuth = horizontal > 1e-5 ? dot(direction.xz, axis) / horizontal : 1.0;
    return aureliaSkyLutUvAt(cosAzimuth, direction.y);
}

// The direction a LUT texel stands for, in the frame where the sun's azimuth
// is +x. Inverse of aureliaSkyLutUv for the texel grid.
vec3 aureliaSkyLutDirection(vec2 texel, vec3 sunDirection) {
    float u = (texel.x - 0.5) / 127.0;
    float v = (texel.y - 0.5) / 127.0;
    float s = 2.0 * v - 1.0;
    float y = sign(s) * s * s;
    float c = sqrt(max(1.0 - y * y, 0.0));
    float azimuth = u * AURELIA_PI;
    vec2 axis = aureliaSunAzimuthAxis(sunDirection);
    vec2 side = vec2(-axis.y, axis.x);
    vec2 horizontal = axis * cos(azimuth) + side * sin(azimuth);
    return vec3(horizontal.x * c, y, horizontal.y * c);
}

// --- Scattering integral (prepare pass only) ------------------------------------
#ifdef AURELIA_ATMOSPHERE_INTEGRATE

// Clear-sky radiance along a view ray from the camera, lit by the sun and the
// moon, plus the ground below the horizon. `steps` trades accuracy for cost:
// the LUT uses 20, the irradiance texels 8.
vec3 aureliaScatter(float altitude, vec3 direction, vec3 sunDirection, float sunIrradiance,
                    float moonIrradiance, int steps) {
    vec3 origin = vec3(0.0, AURELIA_PLANET_RADIUS + altitude, 0.0);
    vec2 atmosphere = aureliaRaySphere(origin, direction, AURELIA_ATMOSPHERE_RADIUS);
    vec2 ground = aureliaRaySphere(origin, direction, AURELIA_PLANET_RADIUS);
    bool hitsGround = ground.x > 0.0;
    float rayLength = hitsGround ? ground.x : atmosphere.y;
    if (rayLength <= 0.0) return vec3(0.0);

    vec3 moonDirection = -sunDirection;
    float nuSun = dot(direction, sunDirection);
    float nuMoon = -nuSun;
    float phaseRaySun = aureliaRayleighPhase(nuSun);
    float phaseMieSun = aureliaMiePhase(nuSun, AURELIA_MIE_G);
    float phaseRayMoon = aureliaRayleighPhase(nuMoon);
    float phaseMieMoon = aureliaMiePhase(nuMoon, AURELIA_MIE_G);

    vec3 inscatter = vec3(0.0);
    vec3 opticalDepth = vec3(0.0);
    float previous = 0.0;
    for (int i = 0; i < steps; ++i) {
        // Quadratic spacing: dense near the camera where the air is thickest
        // and the horizon rays spend most of their length.
        float t1 = float(i + 1) / float(steps);
        float t = rayLength * t1 * t1;
        float dt = t - previous;
        float mid = 0.5 * (t + previous);
        previous = t;

        vec3 position = origin + direction * mid;
        float radius = length(position);
        float h = max(radius - AURELIA_PLANET_RADIUS, 0.0);
        vec3 up = position / radius;
        float rayleighDensity = exp(-h / AURELIA_RAYLEIGH_HEIGHT);
        float mieDensity = exp(-h / AURELIA_MIE_HEIGHT);

        vec3 extinction = (AURELIA_RAYLEIGH + AURELIA_OZONE) * rayleighDensity
                        + AURELIA_MIE_EXTINCTION * mieDensity;
        vec3 viewTransmittance = exp(-(opticalDepth + extinction * (0.5 * dt)));
        opticalDepth += extinction * dt;

        vec3 rayleighScatter = AURELIA_RAYLEIGH * rayleighDensity;
        float mieScatter = AURELIA_MIE_SCATTER * mieDensity;

        float muSun = dot(up, sunDirection);
        vec3 sunTransmittance = aureliaTransmittanceToSpace(h, muSun);
        vec3 moonTransmittance = aureliaTransmittanceToSpace(h, -muSun);

        vec3 single = sunIrradiance * sunTransmittance * (rayleighScatter * phaseRaySun + mieScatter * phaseMieSun)
                    + moonIrradiance * moonTransmittance * (rayleighScatter * phaseRayMoon + mieScatter * phaseMieMoon);
        // Multiple scattering stand-in: light that has already bounced in the
        // air arrives from every direction. It keeps lighting the sky for a
        // while after the direct beam is cut by the planet's shadow.
        float sunAirglow = smoothstep(-0.30, 0.10, muSun) * (0.35 + 0.65 * max(muSun, 0.0));
        float moonAirglow = smoothstep(-0.30, 0.10, -muSun) * (0.35 + 0.65 * max(-muSun, 0.0));
        vec3 multiple = (rayleighScatter + mieScatter) * (1.0 / (4.0 * AURELIA_PI)) * 1.10
                      * (sunIrradiance * sunAirglow * aureliaTransmittanceToSpace(h, max(muSun, 0.15))
                       + moonIrradiance * moonAirglow * aureliaTransmittanceToSpace(h, max(-muSun, 0.15)));

        inscatter += (single + multiple) * viewTransmittance * dt;
    }

    if (hitsGround) {
        // Lambertian ground lit by the sun and moon through the air.
        vec3 hit = origin + direction * rayLength;
        vec3 up = normalize(hit);
        float muSun = dot(up, sunDirection);
        vec3 light = sunIrradiance * max(muSun, 0.0) * aureliaTransmittanceToSpace(0.0, muSun)
                   + moonIrradiance * max(-muSun, 0.0) * aureliaTransmittanceToSpace(0.0, -muSun);
        inscatter += exp(-opticalDepth) * light * (AURELIA_GROUND_ALBEDO / AURELIA_PI);
    }
    return inscatter;
}
#endif

// --- Weather -------------------------------------------------------------------

// A CIE overcast dome: zenith three times as bright as the horizon, luminance
// set from the light the cloud deck lets through. Slightly cool, as overcast
// daylight is. `diffuse` is the irradiance under the deck on flat ground.
vec3 aureliaOvercastRadiance(vec3 direction, vec3 diffuse) {
    float elevation = max(direction.y, -0.2);
    // E = L_zenith * pi * 7/9 for the CIE overcast distribution.
    vec3 zenith = diffuse / (AURELIA_PI * 7.0 / 9.0);
    return zenith * ((1.0 + 2.0 * max(elevation, 0.0)) / 3.0) * mix(0.55, 1.0, smoothstep(-0.2, 0.0, elevation));
}

// --- Readers -------------------------------------------------------------------
#ifdef AURELIA_SKY_LUT_READ
uniform sampler2D colortex5;

vec4 aureliaLutTexel(int index) {
    return texelFetch(colortex5, ivec2(index, AURELIA_LUT_ROWS), 0);
}

// Sky radiance seen along a world-space direction (sky only, no sun disc).
vec3 aureliaSkyRadiance(vec3 direction, vec3 sunDirection) {
    return textureLod(colortex5, aureliaSkyLutUv(direction, sunDirection), 0.0).rgb;
}

// Sky radiance at height y, at the azimuth whose angle from the sun has
// cosine `cosSun`: the sky the same scattering angle away from the sun (and
// from the moon, which stays opposite it).
vec3 aureliaSkyRadianceAtAngle(float cosSun, float y, vec3 sunDirection) {
    float horizontal = sqrt(max(1.0 - y * y, 0.0));
    float cosAzimuth = (cosSun - y * sunDirection.y) / max(horizontal * length(sunDirection.xz), 1e-4);
    return textureLod(colortex5, aureliaSkyLutUvAt(cosAzimuth, y), 0.0).rgb;
}

// Direct sun and moon at the camera (rgb), with rain and the horizon applied.
vec3 aureliaSunLight()  { return aureliaLutTexel(AURELIA_LUT_SUN).rgb; }
vec3 aureliaMoonLight() { return aureliaLutTexel(AURELIA_LUT_MOON).rgb; }

// Sky irradiance on a surface with world normal n, before sky-light
// occlusion. Built from five texels: up, down, and walls toward and away from
// the sun's azimuth (walls across it take their mean).
vec3 aureliaSkyAmbient(vec3 n, vec3 sunDirection) {
    vec3 up = aureliaLutTexel(AURELIA_LUT_SKY_UP).rgb;
    vec3 down = aureliaLutTexel(AURELIA_LUT_SKY_DOWN).rgb;
    vec3 toward = aureliaLutTexel(AURELIA_LUT_SKY_TOWARD).rgb;
    vec3 away = aureliaLutTexel(AURELIA_LUT_SKY_AWAY).rgb;
    vec2 axis = aureliaSunAzimuthAxis(sunDirection);
    float horizontal = length(n.xz);
    float facing = horizontal > 1e-4 ? dot(n.xz, axis) / horizontal : 0.0;
    vec3 wall = mix(away, toward, 0.5 + 0.5 * facing);
    // Quadratic blend over n.y: a wall is half sky, half ground.
    float y = clamp(n.y, -1.0, 1.0);
    return y >= 0.0 ? mix(wall, up, y * y * (2.0 - y)) : mix(wall, down, y * y * (2.0 + y));
}
#endif

#endif
