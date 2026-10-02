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
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path


INCLUDE = re.compile(r'^\s*#include\s+"([^"]+)"\s*$')
OPTION = re.compile(r"^#define\s+(AURELIA_[A-Z0-9_]+)(?:\s+([^/\s]+))?\s*//\s*\[([^]]*)\]")
# Boolean options may be declared on (`#define X`) or off by default
# (`//#define X`) - Iris recognises both as togglable booleans on its menu.
BOOLEAN_OPTION = re.compile(r"^(?://)?#define\s+(AURELIA_[A-Z0-9_]+)\s*//")
PROFILE = re.compile(r"^profile\.([A-Z]+)\s*=\s*(.*)$")
# Interpolated stage variables: `out` in a vertex stage, `in` in a fragment stage.
_VARYING_PREFIX = r"^\s*(?:flat\s+|smooth\s+|noperspective\s+)?"
_VARYING_SUFFIX = r"\s+(?:lowp\s+|mediump\s+|highp\s+)?\w+\s+(\w+)\s*;"
# A vertex stage's `in` declarations are attributes (gl_Vertex, mc_Entity, ...),
# not varyings, so the vertex side matches `out` only and the fragment side `in`.
_VERTEX_OUT_RE = re.compile(_VARYING_PREFIX + "out" + _VARYING_SUFFIX, re.MULTILINE)
_FRAGMENT_IN_RE = re.compile(_VARYING_PREFIX + "in" + _VARYING_SUFFIX, re.MULTILINE)
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


def apply_defines(
    source: str,
    overrides: dict[str, str],
    undefined: set[str],
    enabled: set[str] | None = None,
) -> str:
    """Apply compile-time Iris option choices to expanded source.

    ``undefined`` removes a boolean's ``#define``; ``enabled`` turns on a boolean
    that ships off (``//#define X``); ``overrides`` sets a valued option.
    """
    for name in undefined:
        pattern = re.compile(rf"^#define\s+{re.escape(name)}(?:\s+[^/\s]+)?(?:\s*//.*)?$", re.MULTILINE)
        source, replacements = pattern.subn(f"// validator undef {name}", source)
        if replacements > 1:
            raise ValueError(f"undef matched multiple option definitions: {name}")
    for name in enabled or ():
        if name in undefined:
            raise ValueError(f"option cannot be both enabled and undefined: {name}")
        pattern = re.compile(rf"^//#define\s+{re.escape(name)}(?:\s*//.*)?$", re.MULTILINE)
        source, replacements = pattern.subn(f"#define {name}", source)
        if replacements > 1:
            raise ValueError(f"enable matched multiple option definitions: {name}")
    for name, value in overrides.items():
        if name in undefined:
            raise ValueError(f"option cannot be both defined and undefined: {name}")
        pattern = re.compile(rf"^#define\s+{re.escape(name)}(?:\s+[^/\s]+)?(?:\s*//.*)?$", re.MULTILINE)
        source, replacements = pattern.subn(f"#define {name} {value}", source)
        if replacements > 1:
            raise ValueError(f"override matched multiple option definitions: {name}")
    return source


@dataclass(frozen=True)
class PackOptions:
    """The options ``lib/options.glsl`` exposes to Iris, with their defaults."""

    valued: dict[str, tuple[str, tuple[str, ...]]]  # name -> (default, allowed values)
    booleans: dict[str, bool]  # name -> on by default

    @property
    def names(self) -> set[str]:
        return set(self.valued) | set(self.booleans)


def read_options(shaders_root: Path) -> PackOptions:
    valued: dict[str, tuple[str, tuple[str, ...]]] = {}
    booleans: dict[str, bool] = {}
    for line in (shaders_root / "lib/options.glsl").read_text(encoding="utf-8").splitlines():
        match = OPTION.match(line)
        if match:
            name, default, values = match.groups()
            allowed = tuple(values.split())
            if default not in allowed:
                raise ValueError(f"default for {name} is absent from its value list")
            valued[name] = (default, allowed)
            continue
        match = BOOLEAN_OPTION.match(line)
        if match:
            booleans[match.group(1)] = not line.startswith("//")
    return PackOptions(valued, booleans)


def read_properties(shaders_root: Path) -> list[str]:
    return (shaders_root / "shaders.properties").read_text(encoding="utf-8").splitlines()


def read_profiles(shaders_root: Path) -> dict[str, list[str]]:
    profiles: dict[str, list[str]] = {}
    for line in read_properties(shaders_root):
        match = PROFILE.match(line)
        if match:
            profiles[match.group(1)] = match.group(2).split()
    return profiles


# Names an adaptive custom-uniform expression may use besides the uniforms the
# file itself declares. Extend only after confirming Iris 1.7 supports the name.
EXPRESSION_NAMES = {
    "if", "smooth", "clamp", "min", "max", "abs", "sqrt", "pow", "exp", "log",
    "floor", "ceil", "frameTime", "frameTimeCounter", "frameCounter", "true", "false",
}
UNIFORM_DECL = re.compile(r"^uniform\.(float|int|bool|vec2|vec3|vec4)\.(\w+)\s*=\s*(.*)$")


def validate_uniform_expressions(shaders_root: Path) -> None:
    """Catch typos in the custom-uniform expressions Iris evaluates on the CPU.

    Iris reports a bad expression only in its load log; the pack then runs with
    the uniform stuck at zero. Check parentheses and identifiers.
    """
    known = set(EXPRESSION_NAMES)
    for line in read_properties(shaders_root):
        match = UNIFORM_DECL.match(line)
        if not match:
            continue
        _, name, expression = match.groups()
        if expression.count("(") != expression.count(")"):
            raise ValueError(f"unbalanced parentheses in uniform {name}")
        for identifier in re.findall(r"[A-Za-z_]\w*", re.sub(r"\b\d+\.?\d*\b", "", expression)):
            if identifier not in known:
                raise ValueError(f"uniform {name} uses unknown identifier '{identifier}'")
        known.add(name)


def validate_screens(shaders_root: Path, options: PackOptions) -> dict[str, list[str]]:
    """Every option reachable from the root screen; sliders and screens well formed."""
    screens: dict[str, list[str]] = {}
    sliders: list[str] = []
    for line in read_properties(shaders_root):
        match = re.match(r"^screen(?:\.(\w+))?\s*=\s*(.*)$", line)
        if match:
            screens[match.group(1) or ""] = match.group(2).split()
        elif line.startswith("sliders"):
            sliders = line.split("=", 1)[1].split()
    if "" not in screens:
        raise ValueError("shaders.properties has no root `screen =` line")
    screens.pop("columns", None)  # `screen.columns = 2` is a layout directive

    reachable: set[str] = set()
    pending, seen = [""], set()
    while pending:
        screen = pending.pop()
        if screen in seen:
            continue
        seen.add(screen)
        for token in screens[screen]:
            if token.startswith("[") and token.endswith("]"):
                if token[1:-1] not in screens:
                    raise ValueError(f"screen references undefined sub-screen {token}")
                pending.append(token[1:-1])
            elif token in ("<empty>", "<profile>"):
                continue
            elif token not in options.names:
                raise ValueError(f"screen '{screen or 'root'}' lists unknown option {token}")
            else:
                reachable.add(token)
    unreachable = sorted(options.names - reachable)
    if unreachable:
        raise ValueError(f"options not reachable from any screen: {', '.join(unreachable)}")
    unlinked = sorted(set(screens) - seen)
    if unlinked:
        raise ValueError(f"screens defined but never linked: {', '.join(unlinked)}")
    for slider in sliders:
        if slider not in options.valued:
            raise ValueError(f"slider {slider} is not a valued option")
    return screens


def validate_lang(shaders_root: Path, options: PackOptions, screens: dict[str, list[str]]) -> None:
    """Every option and screen has a label; no label points at nothing."""
    lang: dict[str, str] = {}
    for line in (shaders_root / "lang/en_us.lang").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            lang[key.strip()] = value
    for name in sorted(options.names):
        if f"option.{name}" not in lang:
            raise ValueError(f"lang: missing option.{name}")
    for screen in sorted(name for name in screens if name):
        if f"screen.{screen}" not in lang:
            raise ValueError(f"lang: missing screen.{screen}")
    for key in lang:
        parts = key.split(".")
        if parts[0] == "option" and parts[1] not in options.names:
            raise ValueError(f"lang: {key} labels an option that does not exist")
        if parts[0] == "value":
            if parts[2] not in options.valued.get(parts[1], ("", ()))[1]:
                raise ValueError(f"lang: {key} labels a value the option does not offer")
        if parts[0] == "screen" and parts[1] not in screens:
            raise ValueError(f"lang: {key} labels a screen that does not exist")


def apply_profile(options: PackOptions, assignments: list[str]) -> tuple[dict[str, str], set[str], set[str]]:
    """Resolve a profile line to (overrides, undefined, enabled) against defaults."""
    overrides: dict[str, str] = {}
    undefined: set[str] = set()
    enabled: set[str] = set()
    for assignment in assignments:
        if assignment.startswith("!"):
            if options.booleans.get(assignment[1:]):
                undefined.add(assignment[1:])
        elif "=" in assignment:
            name, value = assignment.split("=", 1)
            overrides[name] = value
        elif not options.booleans.get(assignment, True):
            enabled.add(assignment)
    return overrides, undefined, enabled


def validate_settings(shaders_root: Path) -> PackOptions:
    """Check presets, screens and lang against ``lib/options.glsl``."""
    options = read_options(shaders_root)
    profiles = read_profiles(shaders_root)
    expected_profiles = {"POTATO", "LOW", "BALANCED", "CINEMATIC", "ADAPTIVE"}
    if set(profiles) != expected_profiles:
        raise ValueError(f"profiles mismatch: expected {sorted(expected_profiles)}, found {sorted(profiles)}")
    for profile, assignments in profiles.items():
        covered: set[str] = set()
        for assignment in assignments:
            if assignment.startswith("!"):
                name = assignment[1:]
                if name not in options.booleans:
                    raise ValueError(f"{profile} disables non-boolean option {assignment}")
            elif "=" in assignment:
                name, value = assignment.split("=", 1)
                if value not in options.valued.get(name, ("", ()))[1]:
                    raise ValueError(f"{profile} assigns unsupported value {assignment}")
            else:
                name = assignment
                if name not in options.booleans:
                    raise ValueError(f"{profile} enables non-boolean option {assignment}")
            if name in covered:
                raise ValueError(f"{profile} sets {name} twice")
            covered.add(name)
        missing = sorted(options.names - covered)
        if missing:
            raise ValueError(f"{profile} does not set: {', '.join(missing)}")
    screens = validate_screens(shaders_root, options)
    validate_lang(shaders_root, options, screens)
    validate_uniform_expressions(shaders_root)
    return options


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


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def validate_exposed_options_are_used(shaders_root: Path, options: PackOptions) -> None:
    """Reject a custom uniform or option that Iris exposes but nothing reads.

    Iris builds an options screen from shaders.properties, so a uniform declared
    there appears as a working control whether or not any program consumes it.
    That failure is invisible in every other check: the pack compiles, links and
    validates, and the control simply does nothing when used. This has shipped
    twice here, so it is a hard failure. The same holds for an option whose only
    mention is its own ``#define`` line.
    """
    declared = set(re.findall(r"^uniform\.\w+\.(\w+)\s*=", "\n".join(read_properties(shaders_root)), re.MULTILINE))

    # Everything a program could read, from the fully expanded sources with
    # comments removed (a name in a comment is not a use).
    readable: set[str] = set()
    option_uses: set[str] = set()
    plain_tests: set[str] = set()
    define_line = re.compile(r"^\s*#define\s+(AURELIA_[A-Z0-9_]+)\b[^\n]*$", re.MULTILINE)
    for source in sorted(shaders_root.glob("*.vsh")) + sorted(shaders_root.glob("*.fsh")):
        text = strip_comments(expand(source, shaders_root))
        readable.update(re.findall(r"\b([A-Za-z_]\w*)\b", text))
        option_uses.update(re.findall(r"\b(AURELIA_[A-Z0-9_]+)\b", define_line.sub("", text)))
        plain_tests.update(re.findall(r"^\s*#\s*ifn?def\s+(AURELIA_[A-Z0-9_]+)\b", text, re.MULTILINE))

    unused = sorted(name for name in declared if name not in readable)
    if unused:
        raise ValueError(
            f"uniform(s) declared in shaders.properties but read by no program: "
            f"{', '.join(unused)}. Iris still shows each as an options-screen control, "
            f"so it would appear to work and do nothing."
        )
    dead = sorted(options.names - option_uses)
    if dead:
        raise ValueError(
            f"option(s) defined in lib/options.glsl but tested by no program: "
            f"{', '.join(dead)}. The menu entry would do nothing."
        )
    # Iris registers a boolean option only when it sees a plain #ifdef/#ifndef
    # of it; `#if defined(X)` alone leaves the menu entry unresolved in game
    # ("Unable to resolve shader pack option menu element").
    hidden = sorted(set(options.booleans) - plain_tests)
    if hidden:
        raise ValueError(
            f"boolean option(s) never tested with a plain #ifdef/#ifndef: "
            f"{', '.join(hidden)}. Iris will not list them in the options menu."
        )


def validate_varying_interfaces(shaders_root: Path) -> None:
    """Reject a half-applied change to a program pair.

    A vertex output that no fragment stage declares as an input is dead code, and
    it is the signature of a change that was applied to only one stage of a pair:
    the program still compiles, still links, still validates, and simply ignores
    the value. That is exactly what shipped once, so it is now a hard failure.
    """
    for vertex_source in sorted(shaders_root.glob("*.vsh")):
        program = vertex_source.stem
        fragment_source = shaders_root / f"{program}.fsh"
        if not fragment_source.is_file():
            continue
        produced = set(_VERTEX_OUT_RE.findall(expand(vertex_source, shaders_root)))
        consumed = set(_FRAGMENT_IN_RE.findall(expand(fragment_source, shaders_root)))
        orphans = sorted(produced - consumed)
        if orphans:
            raise ValueError(
                f"{program}: vertex stage outputs {', '.join(orphans)} but the fragment stage never "
                f"reads it; a change was applied to only one stage of the pair"
            )


@dataclass(frozen=True)
class Combo:
    """One option combination to compile: overrides, booleans off, booleans on."""

    name: str
    overrides: dict[str, str] = field(default_factory=dict)
    undefined: frozenset[str] = frozenset()
    enabled: frozenset[str] = frozenset()


def option_matrix(shaders_root: Path, options: PackOptions) -> list[Combo]:
    """The option combinations that ship as presets or as menu toggles.

    Presets are compiled exactly as Iris applies them. Beyond that, every
    boolean is flipped on its own, every valued option takes each of its values
    on its own, and the shadow filter tiers are crossed with adaptive on/off,
    because those branches live in different programs and a preset-only run
    never reaches most of them.
    """
    combos = [Combo("defaults")]
    for profile, assignments in read_profiles(shaders_root).items():
        overrides, undefined, enabled = apply_profile(options, assignments)
        combos.append(Combo(f"profile {profile}", overrides, frozenset(undefined), frozenset(enabled)))

    for name, default_on in sorted(options.booleans.items()):
        if default_on:
            combos.append(Combo(f"{name} off", undefined=frozenset({name})))
        else:
            combos.append(Combo(f"{name} on", enabled=frozenset({name})))
    all_off = frozenset(name for name, on in options.booleans.items() if on)
    all_on = frozenset(name for name, on in options.booleans.items() if not on)
    combos.append(Combo("every default-on boolean off", undefined=all_off))
    combos.append(Combo("every boolean on", enabled=all_on))

    for name, (default, values) in sorted(options.valued.items()):
        for value in values:
            if value != default:
                combos.append(Combo(f"{name}={value}", {name: value}))

    if "AURELIA_SHADOW_FILTER_MAX" in options.valued:
        for tier in options.valued["AURELIA_SHADOW_FILTER_MAX"][1]:
            for adaptive in (False, True):
                undefined = frozenset() if adaptive else frozenset({"AURELIA_SHADOW_ADAPTIVE"})
                combos.append(Combo(f"filter {tier} adaptive {'on' if adaptive else 'off'}",
                                    {"AURELIA_SHADOW_FILTER_MAX": tier}, undefined))
        # Shadows off must stay clean whatever the filter tier says.
        combos.append(Combo("shadows off, filter 3", {"AURELIA_SHADOW_FILTER_MAX": "3"},
                            frozenset({"AURELIA_SHADOWS"})))
    if "AURELIA_DISTANT_RAIN" in options.booleans:
        for layers in options.valued.get("AURELIA_DISTANT_RAIN_LAYERS", ("2", ("2",)))[1]:
            combos.append(Combo(f"distant rain, {layers} layers",
                                {"AURELIA_DISTANT_RAIN_LAYERS": layers}, enabled=frozenset({"AURELIA_DISTANT_RAIN"})))
        overrides, undefined, enabled = apply_profile(options, read_profiles(shaders_root)["CINEMATIC"])
        combos.append(Combo("profile CINEMATIC + distant rain", overrides, frozenset(undefined),
                            frozenset(enabled | {"AURELIA_DISTANT_RAIN"})))
    return combos


def compile_pair(validator: str, workdir: Path, label: str, vertex_text: str, fragment_text: str) -> None:
    vertex = workdir / f"{label}.vert"
    fragment = workdir / f"{label}.frag"
    vertex.write_text(vertex_text, encoding="utf-8")
    fragment.write_text(fragment_text, encoding="utf-8")
    run_validator(validator, "-S", "vert", str(vertex))
    run_validator(validator, "-S", "frag", str(fragment))
    run_validator(validator, "-l", str(vertex), str(fragment))


def option_state(options: PackOptions, combo: Combo, name: str) -> str:
    """The compile-time value ``name`` takes under ``combo``."""
    if name in combo.overrides:
        return combo.overrides[name]
    if name in combo.undefined:
        return "undefined"
    if name in combo.enabled:
        return "defined"
    if name in options.valued:
        return options.valued[name][0]
    return "defined" if options.booleans[name] else "undefined"


def compile_combos(
    validator: str,
    shaders_root: Path,
    options: PackOptions,
    programs: list[str],
    combos: list[Combo],
) -> int:
    """Compile every program under every combo.

    A program only sees an option through the lines that test it, so two combos
    that agree on every option a program actually reads compile identically; the
    second is skipped rather than recompiled.
    """
    define_line = re.compile(r"^\s*#define\s+(AURELIA_[A-Z0-9_]+)\b[^\n]*$", re.MULTILINE)
    sources: dict[str, tuple[str, str]] = {}
    reads: dict[str, list[str]] = {}
    for program in programs:
        pair = (expand(shaders_root / f"{program}.vsh", shaders_root),
                expand(shaders_root / f"{program}.fsh", shaders_root))
        sources[program] = pair
        used = set()
        for text in pair:
            used.update(re.findall(r"\b(AURELIA_[A-Z0-9_]+)\b", define_line.sub("", strip_comments(text))))
        reads[program] = sorted(used & options.names)

    seen: dict[tuple, str] = {}
    jobs: list[tuple[str, str, str, str]] = []  # (origin, label, vertex, fragment)
    plan: list[tuple[Combo, int, int]] = []
    for combo in combos:
        fresh = 0
        for program in programs:
            key = (program, tuple(option_state(options, combo, name) for name in reads[program]))
            if key in seen:
                continue
            seen[key] = combo.name
            vertex_text, fragment_text = (
                apply_defines(text, combo.overrides, set(combo.undefined), set(combo.enabled))
                for text in sources[program]
            )
            jobs.append((f"{combo.name} / {program}", f"{program}-{len(jobs)}", vertex_text, fragment_text))
            fresh += 1
        plan.append((combo, fresh, len(programs) - fresh))

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="aurelia-glsl-") as temporary_dir:
        workdir = Path(temporary_dir)
        with ThreadPoolExecutor(max_workers=8) as pool:
            futures = [
                (origin, pool.submit(compile_pair, validator, workdir, label, vertex_text, fragment_text))
                for origin, label, vertex_text, fragment_text in jobs
            ]
            for origin, future in futures:
                try:
                    future.result()
                except RuntimeError as error:
                    failures.append(f"{origin}: {error}")
    if failures:
        raise RuntimeError("GLSL validation failed under option combinations:\n  " + "\n  ".join(failures))
    for combo, fresh, reused in plan:
        print(f"PASS {combo.name} ({fresh} compiled, {reused} unchanged from an earlier combination)")
    return len(jobs)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validator", default="glslangValidator")
    parser.add_argument("--root", type=Path, default=Path(__file__).parents[1])
    parser.add_argument("--define", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--undef", action="append", default=[], metavar="NAME", help="remove a boolean Iris option for branch validation")
    parser.add_argument("--enable", action="append", default=[], metavar="NAME", help="turn on a boolean option that ships off (//#define)")
    parser.add_argument("--no-matrix", action="store_true", help="compile only the selected combination, not the preset/toggle matrix")
    args = parser.parse_args()

    validator = shutil.which(args.validator) if "/" not in args.validator else args.validator
    if not validator:
        parser.error(f"validator not found: {args.validator}")

    root = args.root.resolve()
    shaders_root = root / "shaders"
    options = validate_settings(shaders_root)
    validate_iris_shadow_directives(shaders_root)
    validate_exposed_options_are_used(shaders_root, options)
    validate_varying_interfaces(shaders_root)
    overrides: dict[str, str] = {}
    for item in args.define:
        if "=" not in item:
            raise ValueError(f"invalid define override: {item}")
        name, value = item.split("=", 1)
        overrides[name] = value
    custom = bool(overrides or args.undef or args.enable)

    vertex_sources = sorted(shaders_root.glob("*.vsh"))
    fragment_sources = sorted(shaders_root.glob("*.fsh"))
    programs = sorted({source.stem for source in vertex_sources} & {source.stem for source in fragment_sources})
    missing = ({source.stem for source in vertex_sources} ^ {source.stem for source in fragment_sources})
    if missing:
        raise ValueError(f"unpaired program stages: {', '.join(sorted(missing))}")
    if not programs:
        raise ValueError("no shader programs found")

    selected = Combo("selected options" if custom else "defaults", overrides,
                     frozenset(args.undef), frozenset(args.enable))
    combos = [selected]
    if not args.no_matrix and not custom:
        combos = option_matrix(shaders_root, options)
    compiled = compile_combos(validator, shaders_root, options, programs, combos)

    print(f"Validated {len(programs)} linked Iris GLSL program pairs under {len(combos)} option "
          f"combination(s) ({compiled} distinct compiles) and 5 preset definitions.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
