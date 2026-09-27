#!/usr/bin/env python3
"""Expand Iris includes and validate every Aurelia GLSL program pair.

This is intentionally a development-only tool. Iris understands rooted includes
such as ``#include "/lib/lighting.glsl"``; the Khronos reference compiler does
not, so the validator resolves those includes to temporary source files before
compilation. It checks language syntax and vertex/fragment linkage, but cannot
emulate Iris's runtime uniforms, render layers, or GPU driver behavior.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


INCLUDE = re.compile(r'^\s*#include\s+"([^"]+)"\s*$')
OPTION = re.compile(r"^#define\s+(AURELIA_[A-Z_]+)(?:\s+([^/\s]+))?\s*//\s*\[([^]]*)\]")
BOOLEAN_OPTION = re.compile(r"^#define\s+(AURELIA_[A-Z_]+)\s*//")
PROFILE = re.compile(r"^profile\.([A-Z]+)\s*=\s*(.*)$")
# Interpolated stage variables: `out` in a vertex stage, `in` in a fragment stage.
_VARYING_RE = re.compile(r"^\s*(?:out|in)\s+(?:lowp\s+|mediump\s+|highp\s+)?\w+\s+(\w+)\s*;",
                         re.MULTILINE)
SHADOW_DISTANCE = re.compile(
    r"^\s*const\s+float\s+shadowDistance\s*=\s*([^;]+);", re.MULTILINE
)


def expand(source: Path, shaders_root: Path, stack: tuple[Path, ...] = ()) -> str:
    """Recursively inline Iris rooted includes, rejecting cyclic/escaping paths."""
    source = source.resolve()
    if source in stack:
        chain = " -> ".join(path.name for path in (*stack, source))
        raise ValueError(f"cyclic include: {chain}")

    output: list[str] = []
    for line in source.read_text(encoding="utf-8").splitlines(keepends=True):
        match = INCLUDE.match(line)
        if not match:
            output.append(line)
            continue

        include_name = match.group(1)
        include_path = (shaders_root / include_name.lstrip("/")).resolve()
        if shaders_root not in include_path.parents:
            raise ValueError(f"include escapes shaders root: {include_name}")
        if not include_path.is_file():
            raise ValueError(f"missing include from {source.name}: {include_name}")
        output.append(expand(include_path, shaders_root, (*stack, source)))
    return "".join(output)


def run_validator(validator: str, *args: str) -> None:
    result = subprocess.run([validator, *args], text=True, capture_output=True)
    if result.returncode:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError(f"GLSL validation failed: {' '.join(args)}")


def apply_defines(source: str, overrides: dict[str, str], undefined: set[str]) -> str:
    """Replace declared compile-time Iris option values for branch validation."""
    for name in undefined:
        pattern = re.compile(rf"^#define\s+{re.escape(name)}(?:\s+[^/\s]+)?(?:\s*//.*)?$", re.MULTILINE)
        source, replacements = pattern.subn(f"// validator undef {name}", source)
        if replacements > 1:
            raise ValueError(f"undef matched multiple option definitions: {name}")
    for name, value in overrides.items():
        if name in undefined:
            raise ValueError(f"option cannot be both defined and undefined: {name}")
        pattern = re.compile(rf"^#define\s+{re.escape(name)}(?:\s+[^/\s]+)?(?:\s*//.*)?$", re.MULTILINE)
        source, replacements = pattern.subn(f"#define {name} {value}", source)
        if replacements > 1:
            raise ValueError(f"override matched multiple option definitions: {name}")
    return source


def validate_settings(shaders_root: Path) -> None:
    """Check that every preset uses documented Iris option names and values."""
    options: dict[str, set[str]] = {}
    booleans: set[str] = set()
    for line in (shaders_root / "lib/options.glsl").read_text(encoding="utf-8").splitlines():
        match = OPTION.match(line)
        if match:
            name, default, values = match.groups()
            allowed = set(values.split())
            if default not in allowed:
                raise ValueError(f"default for {name} is absent from its value list")
            options[name] = allowed
            continue
        match = BOOLEAN_OPTION.match(line)
        if match:
            booleans.add(match.group(1))

    expected_profiles = {"POTATO", "LOW", "BALANCED", "CINEMATIC", "ADAPTIVE"}
    found_profiles: set[str] = set()
    for line in (shaders_root / "shaders.properties").read_text(encoding="utf-8").splitlines():
        match = PROFILE.match(line)
        if not match:
            continue
        profile, assignments = match.groups()
        found_profiles.add(profile)
        for assignment in assignments.split():
            if assignment.startswith("!"):
                if assignment[1:] not in booleans:
                    raise ValueError(f"{profile} disables non-boolean option {assignment}")
            elif "=" in assignment:
                name, value = assignment.split("=", 1)
                if value not in options.get(name, set()):
                    raise ValueError(f"{profile} assigns unsupported value {assignment}")
            elif assignment not in booleans:
                raise ValueError(f"{profile} enables non-boolean option {assignment}")
    if found_profiles != expected_profiles:
        raise ValueError(f"profiles mismatch: expected {sorted(expected_profiles)}, found {sorted(found_profiles)}")


def validate_iris_shadow_directives(shaders_root: Path) -> None:
    """Reject GLSL-valid expressions Iris 1.7.x cannot parse as directives."""
    shadow_source = expand(shaders_root / "shadow.fsh", shaders_root)
    match = SHADOW_DISTANCE.search(shadow_source)
    if not match:
        raise ValueError("shadow.fsh must declare a shadowDistance constant")
    value = match.group(1).strip()
    if value != "AURELIA_SHADOW_DISTANCE" and not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value):
        raise ValueError(
            "Iris 1.7.x requires shadowDistance to be a direct numeric literal "
            "or AURELIA_SHADOW_DISTANCE, not an expression"
        )


def validate_exposed_options_are_used(shaders_root: Path) -> None:
    """Reject a custom uniform or option that Iris exposes but nothing reads.

    Iris builds an options screen from shaders.properties, so a uniform declared
    there appears as a working control whether or not any program consumes it.
    That failure is invisible in every other check: the pack compiles, links and
    validates, and the control simply does nothing when used. This has shipped
    twice here, so it is a hard failure.
    """
    properties = (shaders_root / "shaders.properties").read_text(encoding="utf-8")
    declared = set(re.findall(r"uniform\.\w+\.(\w+)\s*=", properties))

    # Everything a program could read, taken from the fully expanded sources.
    readable: set[str] = set()
    for source in sorted(shaders_root.glob("*.vsh")) + sorted(shaders_root.glob("*.fsh")):
        text = expand(source, shaders_root)
        readable.update(re.findall(r"\b([A-Za-z_]\w*)\b", text))

    unused = sorted(name for name in declared if name not in readable)
    if unused:
        raise ValueError(
            f"uniform(s) declared in shaders.properties but read by no program: "
            f"{', '.join(unused)}. Iris still shows each as an options-screen control, "
            f"so it would appear to work and do nothing."
        )


def validate_varying_interfaces(shaders_root: Path) -> None:
    """Reject a half-applied change to a program pair.

    A vertex output that no fragment stage declares as an input is dead code, and
    it is the signature of a change that was applied to only one stage of a pair:
    the program still compiles, still links, still validates, and simply ignores
    the value. That is exactly what shipped once, so it is now a hard failure.
    """
    global _VARYING_RE
    for vertex_source in sorted(shaders_root.glob("*.vsh")):
        program = vertex_source.stem
        fragment_source = shaders_root / f"{program}.fsh"
        if not fragment_source.is_file():
            continue
        vertex_text = expand(vertex_source, shaders_root)
        fragment_text = expand(fragment_source, shaders_root)
        produced = set(_VARYING_RE.findall(vertex_text))
        if not produced:
            continue
        # `in` names that are Iris-provided vertex attributes are resolved in the
        # vertex stage, so only fragment declarations count here.
        consumed = set(_VARYING_RE.findall(fragment_text))
        orphans = sorted(produced - consumed)
        if orphans:
            listed = ", ".join(orphans)
            raise ValueError(
                f"{program}: vertex stage outputs {listed} but the fragment stage never "
                f"reads it; a change was applied to only one stage of the pair"
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validator", default="glslangValidator")
    parser.add_argument("--root", type=Path, default=Path(__file__).parents[1])
    parser.add_argument("--define", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--undef", action="append", default=[], metavar="NAME", help="remove a boolean Iris option for branch validation")
    args = parser.parse_args()

    validator = shutil.which(args.validator) if "/" not in args.validator else args.validator
    if not validator:
        parser.error(f"validator not found: {args.validator}")

    root = args.root.resolve()
    shaders_root = root / "shaders"
    validate_settings(shaders_root)
    validate_iris_shadow_directives(shaders_root)
    validate_exposed_options_are_used(shaders_root)
    validate_varying_interfaces(shaders_root)
    overrides: dict[str, str] = {}
    for item in args.define:
        if "=" not in item:
            raise ValueError(f"invalid define override: {item}")
        name, value = item.split("=", 1)
        overrides[name] = value
    undefined = set(args.undef)
    vertex_sources = sorted(shaders_root.glob("*.vsh"))
    fragment_sources = sorted(shaders_root.glob("*.fsh"))
    programs = {source.stem for source in vertex_sources} & {source.stem for source in fragment_sources}
    missing = ({source.stem for source in vertex_sources} ^ {source.stem for source in fragment_sources})
    if missing:
        raise ValueError(f"unpaired program stages: {', '.join(sorted(missing))}")
    if not programs:
        raise ValueError("no shader programs found")

    with tempfile.TemporaryDirectory(prefix="aurelia-glsl-") as temporary_dir:
        temp_root = Path(temporary_dir)
        for program in sorted(programs):
            vertex = temp_root / f"{program}.vert"
            fragment = temp_root / f"{program}.frag"
            vertex.write_text(apply_defines(expand(shaders_root / f"{program}.vsh", shaders_root), overrides, undefined), encoding="utf-8")
            fragment.write_text(apply_defines(expand(shaders_root / f"{program}.fsh", shaders_root), overrides, undefined), encoding="utf-8")
            run_validator(validator, "-S", "vert", str(vertex))
            run_validator(validator, "-S", "frag", str(fragment))
            run_validator(validator, "-l", str(vertex), str(fragment))
            print(f"PASS {program}")

    selections = []
    if overrides:
        selections.append(f"overrides {overrides}")
    if undefined:
        selections.append(f"undefined {sorted(undefined)}")
    suffix = f" with {', '.join(selections)}" if selections else ""
    print(f"Validated {len(programs)} linked Iris GLSL program pairs and 5 preset definitions{suffix}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
