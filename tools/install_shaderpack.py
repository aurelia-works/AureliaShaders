#!/usr/bin/env python3
"""Package shaders/ into an Iris-loadable zip and install it into an instance.

    tools/.venv/bin/python tools/install_shaderpack.py
    tools/.venv/bin/python tools/install_shaderpack.py --dry-run
    tools/.venv/bin/python tools/install_shaderpack.py --target /path/to/shaderpacks

Iris loads a shaderpack archive whose root contains ``shaders/``. This builds
exactly that from the working tree, installs it, then re-reads the installed
archive and verifies the structure rather than trusting that the copy worked.

The archive is deterministic: entries are sorted and timestamps are fixed, so
installing an unchanged tree twice produces a byte-identical zip and a spurious
"changed" result in Iris cannot come from packaging noise.

This is a development convenience. It does not touch the game, the instance's
options, or any other shaderpack already in the target directory.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import zipfile
from pathlib import Path

# The PrismLauncher instance this project is developed against.
DEFAULT_TARGET = Path(
    "/Users/Boon/Library/Application Support/PrismLauncher"
    "/instances/Aurelia Metropolis/minecraft/shaderpacks"
)
DEFAULT_NAME = "AureliaShaders.zip"

# Root entries copied alongside shaders/. Iris ignores them; they travel with the
# archive so the pack keeps its licence and install notes.
EXTRA_FILES = ("LICENSE", "README.md")

# Fixed timestamp for reproducibility. 1980-01-01 is the zip epoch.
FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def collect(root: Path) -> list[tuple[Path, str]]:
    """Return ``(source path, archive name)`` pairs, sorted for determinism."""
    entries: list[tuple[Path, str]] = []
    for path in sorted((root / "shaders").rglob("*")):
        if path.is_dir():
            continue
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        entries.append((path, path.relative_to(root).as_posix()))
    for name in EXTRA_FILES:
        path = root / name
        if path.is_file():
            entries.append((path, name))
    return entries


def build(root: Path, destination: Path) -> tuple[Path, str, int]:
    entries = collect(root)
    if not any(name.startswith("shaders/") for _, name in entries):
        raise SystemExit("no files found under shaders/; nothing to package")
    missing = [
        name
        for name in ("shaders/shaders.properties", "shaders/lib/options.glsl")
        if not (root / name).is_file()
    ]
    if missing:
        raise SystemExit(f"required file(s) absent: {', '.join(missing)}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path, name in entries:
            info = zipfile.ZipInfo(name, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            # 0644, regular file: keeps the pack readable if the instance is
            # shared with another user account.
            info.external_attr = (0o100644 & 0xFFFF) << 16
            archive.writestr(info, path.read_bytes())
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()[:12]
    return destination, digest, len(entries)


def verify(archive_path: Path, root: Path) -> list[str]:
    """Re-open the installed archive and confirm Iris can load it.

    Checks the two things that actually break a shaderpack silently: the archive
    root must contain ``shaders/`` and not ``AureliaShaders/shaders/``, and
    ``shaders/shaders.properties`` must be present at the expected depth.
    """
    problems: list[str] = []
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        if "shaders/shaders.properties" not in names:
            problems.append("shaders/shaders.properties is not at the archive root")
        nested = [n for n in names if n.startswith("AureliaShaders/")]
        if nested:
            problems.append(
                f"archive contains a top-level AureliaShaders/ directory ({len(nested)} entries); "
                "Iris expects shaders/ at the root and would fail to load it"
            )
        if not any(n == "shaders/lib/options.glsl" for n in names):
            problems.append("shaders/lib/options.glsl missing; option overrides will not apply")

        # Every shader source Iris loads must be present in the archive.
        expected = {
            path.relative_to(root).as_posix()
            for path in (root / "shaders").rglob("*")
            if path.is_file()
        }
        missing = sorted(expected - set(names))
        if missing:
            problems.append(f"{len(missing)} file(s) in the tree are absent from the archive: "
                            f"{', '.join(missing[:6])}")
        staged = {n for n in names if n.startswith("shaders/")}
        programs = sorted(
            {Path(n).stem for n in staged if n.endswith((".vsh", ".fsh"))}
        )
        unpaired = [
            p
            for p in programs
            if f"shaders/{p}.vsh" not in staged or f"shaders/{p}.fsh" not in staged
        ]
        if unpaired:
            problems.append(f"unpaired program stages: {', '.join(unpaired)}")
    return problems


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--target", type=Path, default=DEFAULT_TARGET, help="shaderpacks directory")
    parser.add_argument("--name", default=DEFAULT_NAME, help="archive file name")
    parser.add_argument("--build-only", action="store_true", help="build in the tree, do not install")
    parser.add_argument("--dry-run", action="store_true", help="report what would happen and stop")
    args = parser.parse_args(argv)

    if args.build_only:
        destination = root / "dist" / args.name
    else:
        destination = args.target / args.name

    entries = collect(root)
    if args.dry_run:
        print(f"would package {len(entries)} file(s) from {root}")
        print(f"would write  {destination}")
        for _, name in entries[:8]:
            print(f"    {name}")
        if len(entries) > 8:
            print(f"    ... and {len(entries) - 8} more")
        return 0

    path, digest, count = build(root, destination)
    print(f"packaged {count} file(s) -> {path}")
    print(f"  sha256[:12] {digest}  {path.stat().st_size:,} bytes")

    problems = verify(path, root)
    if problems:
        print("VERIFY FAILED:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("  verified: shaders/ at archive root, all sources present, no unpaired stages")

    if not args.build_only:
        print(f"\ninstalled to {destination.parent}")
        print("In Iris: Video Settings -> Shader Packs -> AureliaShaders.")
        print("Compile-time options only take effect after a shader reload")
        print("(Iris: press F3+T, or re-select the pack).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
