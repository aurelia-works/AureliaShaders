#!/usr/bin/env python3
"""Parse Iris render-target directives for the offline preview harness.

The preview harness must know the pack's colour-target set, formats, clear
behaviour and relative sizes before it can allocate framebuffers and bind the
right attachments per pass. Iris reads this from directives carried inside block
comments in the fragment source (and from ``shaders.properties``), so the same
text the shader ships is the source of truth here.

This module is deliberately GL-free: it can be unit-tested without a context.

Iris directive forms handled:

    /* RENDERTARGETS: 0 1 */                       (in a fragment stage)
    const int  colortex0Format = RGBA16F;
    const bool colortex0Clear = true;
    const vec4 colortex0ClearColor = vec4(0.0, 0.0, 0.0, 1.0);
    size.buffer.colortex1 = 0.5 0.5                 (shaders.properties)

Run ``python3 tools/preview_targets.py`` for a self-check and a dump of the
current pack's target set.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

RENDERTARGETS = re.compile(r"/\*\s*RENDERTARGETS\s*:\s*([0-9][0-9\s]*)\*/")
FORMAT = re.compile(r"const\s+int\s+colortex(\d+)Format\s*=\s*(\w+)\s*;")
CLEAR = re.compile(r"const\s+bool\s+colortex(\d+)Clear\s*=\s*(true|false)\s*;")
CLEAR_COLOR = re.compile(
    r"const\s+vec4\s+colortex(\d+)ClearColor\s*=\s*vec4\(\s*([^)]*?)\s*\)\s*;"
)
SIZE = re.compile(r"size\.buffer\.colortex(\d+)\s*=\s*([0-9.]+)\s+([0-9.]+)")

DEFAULT_FORMAT = "RGBA8"

# Iris program-name order for composite-style passes. `final` is last and writes
# to the default framebuffer; the rest write to their declared RENDERTARGETS.
COMPOSITE_ORDER: tuple[str, ...] = (
    "prepare",
    "deferred",
    "composite",
    "composite1",
    "composite2",
    "composite3",
    "composite4",
    "composite5",
    "composite6",
    "composite7",
    "final",
)


@dataclass(frozen=True)
class TargetConfig:
    """One colour target's Iris-declared configuration."""

    index: int
    fmt: str = DEFAULT_FORMAT
    clear: bool = False
    clear_color: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    scale: tuple[float, float] = (1.0, 1.0)

    def size(self, width: int, height: int) -> tuple[int, int]:
        return (
            max(1, int(round(width * self.scale[0]))),
            max(1, int(round(height * self.scale[1]))),
        )


def parse_render_targets(source: str) -> list[int]:
    """Return the attachment indices a fragment stage writes to, in order."""
    match = RENDERTARGETS.search(source)
    if match is None:
        return []
    return [int(token) for token in match.group(1).split()]


def _explicit_fields(
    source: str, properties: str
) -> tuple[
    dict[int, str],
    dict[int, bool],
    dict[int, tuple[float, float, float, float]],
    dict[int, tuple[float, float]],
]:
    """Only the fields a source *explicitly* declares, per target index."""
    fmt: dict[int, str] = {}
    clear: dict[int, bool] = {}
    clear_color: dict[int, tuple[float, float, float, float]] = {}
    scale: dict[int, tuple[float, float]] = {}

    for match in FORMAT.finditer(source):
        fmt[int(match.group(1))] = match.group(2)
    for match in CLEAR.finditer(source):
        clear[int(match.group(1))] = match.group(2) == "true"
    for match in CLEAR_COLOR.finditer(source):
        components = [float(part) for part in match.group(2).split(",")]
        if len(components) != 4:
            raise ValueError(f"colortex{match.group(1)}ClearColor must have 4 components")
        clear_color[int(match.group(1))] = (
            components[0],
            components[1],
            components[2],
            components[3],
        )
    for match in SIZE.finditer(properties):
        scale[int(match.group(1))] = (float(match.group(2)), float(match.group(3)))
    return fmt, clear, clear_color, scale


def _build(
    index: int,
    fmt: dict[int, str],
    clear: dict[int, bool],
    clear_color: dict[int, tuple[float, float, float, float]],
    scale: dict[int, tuple[float, float]],
) -> TargetConfig:
    return TargetConfig(
        index=index,
        fmt=fmt.get(index, DEFAULT_FORMAT),
        clear=clear.get(index, False),
        clear_color=clear_color.get(index, (0.0, 0.0, 0.0, 0.0)),
        scale=scale.get(index, (1.0, 1.0)),
    )


def parse_target_configs(source: str, properties: str = "") -> dict[int, TargetConfig]:
    """Collect every colour target a source (and properties text) declares."""
    fmt, clear, clear_color, scale = _explicit_fields(source, properties)
    indices = set(parse_render_targets(source)) | set(fmt) | set(clear) | set(clear_color)
    indices |= set(scale)
    return {
        index: _build(index, fmt, clear, clear_color, scale) for index in sorted(indices)
    }


def collect_target_configs(shaders_root: Path) -> dict[int, TargetConfig]:
    """Union of every target declared anywhere in the pack.

    A stage that only writes ``RENDERTARGETS: 0`` declares no format; only an
    explicit declaration sets one. Two stages that both explicitly declare the
    same target differently are a real conflict and rejected.
    """
    properties = ""
    properties_path = shaders_root / "shaders.properties"
    if properties_path.is_file():
        properties = properties_path.read_text(encoding="utf-8")

    fmt: dict[int, str] = {}
    clear: dict[int, bool] = {}
    clear_color: dict[int, tuple[float, float, float, float]] = {}
    scale: dict[int, tuple[float, float]] = {}
    written: set[int] = set()

    def merge(store: dict, incoming: dict, field: str) -> None:
        for index, value in incoming.items():
            if index in store and store[index] != value:
                raise ValueError(
                    f"conflicting explicit colortex{index} {field}: "
                    f"{store[index]} vs {value}"
                )
            store[index] = value

    for source_path in sorted(shaders_root.glob("*.fsh")):
        source = source_path.read_text(encoding="utf-8")
        written.update(parse_render_targets(source))
        file_fmt, file_clear, file_color, file_scale = _explicit_fields(source, properties)
        merge(fmt, file_fmt, "Format")
        merge(clear, file_clear, "Clear")
        merge(clear_color, file_color, "ClearColor")
        merge(scale, file_scale, "size")

    indices = written | set(fmt) | set(clear) | set(clear_color) | set(scale)
    return {
        index: _build(index, fmt, clear, clear_color, scale) for index in sorted(indices)
    }


def composite_passes_present(shaders_root: Path) -> list[str]:
    """Composite-style programs the pack ships, in Iris execution order."""
    present: list[str] = []
    for name in COMPOSITE_ORDER:
        if (shaders_root / f"{name}.fsh").is_file() and (shaders_root / f"{name}.vsh").is_file():
            present.append(name)
    return present


def _self_check() -> int:
    fixture = """
    /* RENDERTARGETS: 0 1 */
    layout(location = 0) out vec4 out0;
    const int colortex0Format = RGBA16F;
    const bool colortex0Clear = true;
    const vec4 colortex0ClearColor = vec4(0.0, 0.0, 0.0, 1.0);
    const int colortex1Format = RGBA8;
    """
    configs = parse_target_configs(fixture, "size.buffer.colortex1 = 0.5 0.5")
    assert parse_render_targets(fixture) == [0, 1], "RENDERTARGETS parse failed"
    assert configs[0].fmt == "RGBA16F" and configs[0].clear is True, configs[0]
    assert configs[0].clear_color == (0.0, 0.0, 0.0, 1.0), configs[0].clear_color
    assert configs[1].scale == (0.5, 0.5), configs[1].scale
    assert configs[1].size(960, 540) == (480, 270), configs[1].size(960, 540)
    print("preview_targets self-check: PASS")

    root = Path(__file__).resolve().parents[1] / "shaders"
    pack = collect_target_configs(root)
    print(f"pack targets: { {i: c.fmt for i, c in pack.items()} }")
    print(f"composite passes present: {composite_passes_present(root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_self_check())
