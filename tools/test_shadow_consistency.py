"""Static contract test for the shadow caster/receiver pair.

These are the failure modes that no single render makes obvious and that only
bite in game:

  1. The caster (shadow.vsh) and receiver (lib/shadows.glsl) must apply the SAME
     distortion from the SAME shared file. If they ever diverge, every lookup
     lands on the wrong texel.
  2. The shadow-camera body handover: Iris flips the shadow camera sun -> moon
     when the sun crosses the horizon, while the contract's sunUp is ~0.58 there.
     lib/lighting.glsl must gate each body on the camera actually pointing at it.
  3. The lookup must stay derivative-free (textureLod) because it sits behind a
     non-uniform branch (sky light == 0 underground).
  4. Lightmap decode must be the inverse of Minecraft's 1/32..31/32 packing.

Run: python3 tools/test_shadow_consistency.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "shaders"


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def main() -> int:
    failures = []
    vsh = strip_comments(read("shadow.vsh"))
    recv = strip_comments(read("lib/shadows.glsl"))
    light = strip_comments(read("lib/lighting.glsl"))
    distort = read("lib/shadow_distort.glsl")

    if '#include "/lib/shadow_distort.glsl"' not in vsh:
        failures.append("shadow.vsh does not include the shared distortion")
    if '#include "/lib/shadow_distort.glsl"' not in recv:
        failures.append("lib/shadows.glsl does not include the shared distortion")
    if not re.search(r"gl_Position\.xy\s*/=\s*aureliaShadowDistortScale\(gl_Position\.xy\)", vsh):
        failures.append("shadow.vsh must divide clip xy by aureliaShadowDistortScale")
    if len(re.findall(r"aureliaShadowDistortScale\(", recv)) < 2:
        failures.append("receiver must distort the sample xy and evaluate the local density")
    if "const float AURELIA_SHADOW_DISTORT_K" not in distort:
        failures.append("distortion constant missing from the shared file")
    if re.search(r"DISTORT_K\s*=", recv + vsh):
        failures.append("distortion constant must be defined once, in the shared file")

    if "textureLod(shadowtex0" not in recv or re.search(r"\btexture\(shadowtex0", recv):
        failures.append("shadow taps must use textureLod (derivative-free)")

    if not re.search(r"dot\(shadowDir,\s*sunDir\)", light) or not re.search(r"dot\(shadowDir,\s*moonDir\)", light):
        failures.append("lighting must gate sun/moon shadows on the shadow-camera direction")
    if "shadowTerms.y" not in light:
        failures.append("moonlight must be multiplied by its shadow term")

    for name in ("gbuffers_terrain", "gbuffers_entities", "gbuffers_textured_lit"):
        v = read(name + ".vsh")
        if "(lmcoord - 1.0 / 32.0) * (32.0 / 30.0)" not in v:
            failures.append(f"{name}.vsh lightmap decode is not (lm - 1/32) * 32/30")

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("PASS: shadow caster/receiver contract holds")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
