#!/usr/bin/env python3
"""Turn Aurelia's Iris GLSL into standalone desktop GLSL for offline preview.

Iris injects a large compatibility-profile environment that the Khronos
reference compiler does not provide: ``ftransform()``, ``gl_ModelViewMatrix``,
``gl_NormalMatrix``, ``gl_TextureMatrix``, ``gl_MultiTexCoord*``, ``gl_Color``,
``gl_Vertex`` and ``gl_Normal``. This module resolves Iris rooted includes and
rewrites those compatibility builtins to explicit uniforms and attributes so the
*unmodified* Aurelia shader source can be compiled and executed by a normal
core-profile OpenGL context.

Nothing in ``shaders/`` is edited. The rewriting happens in memory, so a
preview shot can never drift from the shader Iris actually compiles.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_shaderpack import PROFILE, expand  # noqa: E402

# Compatibility builtins -> the names declared in the injected prelude.
# Longest first so gl_TextureMatrix[0] is not partially rewritten.
COMPAT_REWRITES: tuple[tuple[str, str], ...] = (
    (r"\bgl_TextureMatrix\[0\]", "aureliaTextureMatrix0"),
    (r"\bgl_TextureMatrix\[1\]", "aureliaTextureMatrix1"),
    (r"\bgl_ModelViewProjectionMatrix\b", "aureliaProjectionViewMatrix"),
    (r"\bgl_ModelViewMatrix\b", "aureliaViewMatrix"),
    (r"\bgl_NormalMatrix\b", "aureliaNormalMatrix"),
    (r"\bgl_MultiTexCoord0\b", "aureliaTexCoord0"),
    (r"\bgl_MultiTexCoord1\b", "aureliaTexCoord1"),
    (r"\bgl_Color\b", "aureliaColor"),
    (r"\bgl_Vertex\b", "aureliaVertex"),
    (r"\bgl_Normal\b", "aureliaNormal"),
    # ftransform() is gl_Position = P * MV * vertex, applied in that order.
    (r"\bftransform\s*\(\s*\)", "(aureliaProjectionViewMatrix * aureliaVertex)"),
)

# Single source of truth for the vertex layout. The prelude below is generated
# from this tuple and the renderer builds its interleaved buffer from
# ``VERTEX_UPLOAD``, so a declaration order and an upload order can never drift
# apart again -- a mismatch silently feeds every vertex the wrong attribute and
# produces a plausible-looking but flat or wrongly textured frame.
#
# Each entry is (GLSL declaration, floats actually uploaded). A declared vec4 fed
# by fewer floats takes its remaining components from the default generic vertex
# attribute, which is (0, 0, 0, 1); that is how the position's w becomes 1.0.
VERTEX_ATTRIBUTES: tuple[tuple[str, int, int], ...] = (
    ("vec4 aureliaVertex", 4, 3),
    ("vec3 aureliaNormal", 3, 3),
    ("vec4 aureliaColor", 4, 4),
    ("vec4 aureliaTexCoord0", 4, 2),
    ("vec4 aureliaTexCoord1", 4, 2),
)

# Interleaved buffer order: position, normal, colour, texcoord0, texcoord1.
VERTEX_UPLOAD: tuple[str, ...] = (
    "position",
    "normal",
    "color",
    "texcoord0",
    "texcoord1",
)
VERTEX_UPLOAD_COMPONENTS: tuple[int, ...] = tuple(upload for _, _, upload in VERTEX_ATTRIBUTES)

VERTEX_PRELUDE = (
    "// --- Aurelia offline preview: Iris compatibility shims -------------------\n"
    + "".join(
        f"layout(location = {index}) in {declaration};\n"
        for index, (declaration, _, _) in enumerate(VERTEX_ATTRIBUTES)
    )
    + "\nuniform mat4 aureliaViewMatrix;         // Iris gl_ModelViewMatrix\n"
    "uniform mat3 aureliaNormalMatrix;       // Iris gl_NormalMatrix\n"
    "uniform mat4 aureliaTextureMatrix0;     // Iris gl_TextureMatrix[0]\n"
    "uniform mat4 aureliaTextureMatrix1;     // Iris gl_TextureMatrix[1]\n"
    "// ftransform() expands to this, so a core context can still run the real\n"
    "// vertex sources: gl_Position = projection * view * vertex.\n"
    "uniform mat4 aureliaProjectionViewMatrix;\n"
    "// ---------------------------------------------------------------------\n"
)

FRAGMENT_PRELUDE = "// --- Aurelia offline preview ---------------------------------------\n"


class ProfileError(ValueError):
    """A preset in shaders.properties could not be mapped onto GLSL defines."""


def read_profile(shaders_root: Path, name: str) -> str | None:
    """Return the raw assignment string for ``profile.<name>``, or None."""
    for line in (shaders_root / "shaders.properties").read_text(encoding="utf-8").splitlines():
        match = PROFILE.match(line)
        if match and match.group(1) == name:
            return match.group(2)
    return None


def parse_profile(shaders_root: Path, name: str) -> tuple[dict[str, str], set[str]]:
    """Split a preset into numeric overrides and boolean option names.

    Returns ``(overrides, booleans)`` where ``overrides`` maps option name to its
    literal value and ``booleans`` holds every boolean option the preset turns
    on. Booleans the preset switches off are simply absent, which matches how
    ``validate_shaderpack.apply_defines`` removes the ``#define`` line.
    """
    assignments = read_profile(shaders_root, name)
    if assignments is None:
        raise ProfileError(f"no profile.{name} in shaders.properties")
    overrides: dict[str, str] = {}
    booleans: set[str] = set()
    for assignment in assignments.split():
        if assignment.startswith("!"):
            continue
        if "=" in assignment:
            option, value = assignment.split("=", 1)
            overrides[option] = value
        else:
            booleans.add(assignment)
    return overrides, booleans


def build_source(
    shaders_root: Path,
    program: str,
    stage: str,
    overrides: dict[str, str] | None = None,
    undefined: set[str] | None = None,
) -> str:
    """Expand includes, apply option overrides, and shim compat builtins.

    ``stage`` is ``"vsh"`` or ``"fsh"``. The returned source is a complete,
    self-contained GLSL 330 core shader ready for a desktop driver.
    """
    from validate_shaderpack import apply_defines

    if stage not in ("vsh", "fsh"):
        raise ValueError(f"unsupported stage: {stage}")
    source = expand(shaders_root / f"{program}.{stage}", shaders_root)
    source = apply_defines(source, overrides or {}, undefined or set())

    source = re.sub(r"^#version\s+330\s+compatibility\b", "#version 330 core", source, count=1, flags=re.M)
    for pattern, replacement in COMPAT_REWRITES:
        source = re.sub(pattern, replacement, source)

    prelude = VERTEX_PRELUDE if stage == "vsh" else FRAGMENT_PRELUDE
    # Keep the #version directive first; it is only legal there.
    body = source.split("\n", 1)[1] if source.startswith("#version") else source
    return f"{source.splitlines()[0]}\n{prelude}{body}"
