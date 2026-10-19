// Surface materials from block IDs (block.properties, Phase 5).
//
// No resource pack is assumed: like Complementary's integrated PBR, each group
// gets a smoothness, a specular reflectance and an emission from its block ID
// and its own texel colour. Values are perceptual smoothness (1 = mirror) and
// F0 (normal-incidence reflectance; 0.04 for most dielectrics, the albedo for
// metals). A block without an ID is rough, dull ground.

#ifndef AURELIA_MATERIALS_GLSL
#define AURELIA_MATERIALS_GLSL

struct AureliaMaterial {
    float smoothness; // 0 rough .. 1 mirror
    float f0;         // dielectric reflectance at normal incidence
    float metal;      // 1: conductor, F0 is the albedo and there is no diffuse
    float emission;   // emitted radiance per unit albedo, shader light units
    float translucency; // thin foliage: light through the back face
    float porosity;   // how much a wet surface darkens (water fills the pores)
    float drains;     // 1: rain soaks in or runs through, no film or puddles
};

float aureliaLuma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

AureliaMaterial aureliaDefaultMaterial() {
    return AureliaMaterial(0.0, 0.04, 0.0, 0.0, 0.0, 0.6, 0.0);
}

AureliaMaterial aureliaMaterial(int id, vec3 albedo) {
    AureliaMaterial m = aureliaDefaultMaterial();
    float luma = aureliaLuma(albedo);
#ifdef AURELIA_MATERIALS
    if (id == 10001 || id == 10003 || id == 10004) {
        // Grass and flowers: waxy, thin, light passes through.
        m.smoothness = 0.18; m.translucency = 0.55; m.porosity = 0.2;
    } else if (id == 10002) {
        m.smoothness = 0.24; m.translucency = 0.70; m.porosity = 0.2;
    } else if (id == 10012) {
        // Clear glass in the cutout layer: its visible streaks are glass.
        m.smoothness = 0.96; m.f0 = 0.04; m.porosity = 0.0;
    } else if (id == 10011) {
        // Stained glass (translucent layer).
        m.smoothness = 0.94; m.f0 = 0.04; m.porosity = 0.0;
    } else if (id == 10013) {
        m.smoothness = 0.92; m.f0 = 0.018; m.porosity = 0.0;
    } else if (id == 10014) {
        // Slime and honey: wet-looking gel.
        m.smoothness = 0.70; m.f0 = 0.04; m.porosity = 0.0;
    } else if (id == 10015) {
        // Nether portal: the swirl is light, not paint.
        m.emission = 1.6 + 2.4 * smoothstep(0.25, 0.8, luma); m.smoothness = 0.6; m.porosity = 0.0;
    } else if (id == 10020) {
        // Lamp blocks: the bright texels are the bulb.
        m.emission = 3.2 * smoothstep(0.30, 0.85, luma); m.smoothness = 0.45; m.porosity = 0.0;
    } else if (id == 10021) {
        // Lava: on top of full block light; at 2.6 it tonemapped to pale peach
        // in the Nether (seen in game against vanilla orange).
        m.emission = 0.5 * (0.35 + 0.65 * smoothstep(0.2, 0.9, luma)); m.porosity = 0.0;
    } else if (id == 10022) {
        // Torches, lanterns, campfires: only the flame and the glass glow.
        float hot = smoothstep(0.55, 0.90, luma) * step(albedo.b, albedo.r + 0.05);
        m.emission = 4.0 * hot; m.smoothness = 0.35; m.porosity = 0.0;
    } else if (id == 10030) {
        // Metal: bright texels are polished face, dark ones are seams and grime.
        m.metal = 1.0; m.f0 = 1.0;
        m.smoothness = 0.50 + 0.40 * smoothstep(0.15, 0.75, luma); m.porosity = 0.0;
    } else if (id == 10031) {
        m.smoothness = 0.52 + 0.30 * luma * luma; m.f0 = 0.045; m.porosity = 0.25;
    } else if (id == 10032) {
        // Concrete and asphalt: a satin sheen, much glossier when wet.
        m.smoothness = 0.36; m.f0 = 0.04; m.porosity = 0.45;
    } else if (id == 10033) {
        m.smoothness = 0.78; m.f0 = 0.045; m.porosity = 0.0;
    } else if (id == 10035) {
        m.smoothness = 0.86; m.f0 = 0.05; m.porosity = 0.0;
    } else if (id == 10036) {
        // Soil and sand: matte, darken deeply when wet, hold no water.
        m.smoothness = 0.04; m.porosity = 0.9; m.drains = 1.0;
    } else if (id == 10037) {
        // Turf: the blades shed rain, so it darkens less than bare soil.
        m.smoothness = 0.06; m.porosity = 0.45; m.drains = 1.0;
    } else {
        // Generic ground: a hint of gloss on brighter, smoother-looking texels.
        m.smoothness = 0.12 * luma;
    }
#endif
#ifndef AURELIA_FOLIAGE_TRANSLUCENCY
    m.translucency = 0.0;
#endif
    return m;
}

// GGX roughness (alpha) from perceptual smoothness, floored so the sun's
// highlight stays a disc rather than a single bright texel.
float aureliaAlpha(float smoothness) {
    float roughness = 1.0 - smoothness;
    return max(roughness * roughness, 0.0025);
}

// --- G-buffer encoding (colortex1, RGBA8) -------------------------------------
// r,g  world normal, octahedral
// b    smoothness
// a    sky light (0..15, high nibble) | metal (bit 3) | reflective (bit 2)

vec2 aureliaOctEncode(vec3 n) {
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    vec2 e = n.y >= 0.0 ? n.xz : (1.0 - abs(n.zx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.z >= 0.0 ? 1.0 : -1.0);
    return e * 0.5 + 0.5;
}

vec3 aureliaOctDecode(vec2 e) {
    e = e * 2.0 - 1.0;
    vec3 n = vec3(e.x, 1.0 - abs(e.x) - abs(e.y), e.y);
    if (n.y < 0.0) n.xz = (1.0 - abs(n.zx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.z >= 0.0 ? 1.0 : -1.0);
    return normalize(n);
}

vec4 aureliaEncodeGbuffer(vec3 normal, float smoothness, float metal, float skyLight) {
    float sky = floor(clamp(skyLight, 0.0, 1.0) * 15.0 + 0.5);
    float flags = sky * 16.0 + (metal > 0.5 ? 8.0 : 0.0);
    return vec4(aureliaOctEncode(normal), smoothness, flags / 255.0);
}

#endif
