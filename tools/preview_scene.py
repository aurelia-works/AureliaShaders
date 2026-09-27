#!/usr/bin/env python3
"""Procedural Minecraft-like scene for the Aurelia offline preview.

The preview needs geometry that exercises the parts of Aurelia that matter for
grading decisions: sRGB atlas textures, biome tint, per-vertex terrain AO in
``gl_Color.a`` (Iris ``separateAo``), a lightmap with real sky occlusion, an
alpha-cutout foliage path, a translucent water surface, and a block-light
source so the torch term is visible.

None of this is a Minecraft asset or a re-implementation of vanilla behaviour.
It is a synthetic stand-in with the same *interfaces* the shaders read, so the
programs under test are the real ones from ``shaders/``.

Sky light is stored **relative** (1.0 = unobstructed daylight) rather than
baked to a time of day, so one cached geometry build serves every lighting
condition the preview can render.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

GRASS_TOP, GRASS_SIDE, DIRT, STONE = 0, 1, 2, 3
COBBLE, SAND, LEAVES, LOG_SIDE = 4, 5, 6, 7
LOG_TOP, PLANKS, WATER, SNOW = 8, 9, 10, 11
GLOWSTONE, GRAVEL, BRICKS, SANDSTONE = 12, 13, 14, 15

TILE_PX = 32
ATLAS_COLS = 4
ATLAS_ROWS = 4
ATLAS_PX = TILE_PX * ATLAS_COLS

SEA_LEVEL = 14.0

# Minecraft applies a biome tint to these tiles only. Everything else is white.
# Biome tints, matched to Minecraft's plains/foliage/water values closely
# enough that a grade judgement transfers. A darker atlas makes the pack's own
# lighting look broken when it is only the input that was wrong.
TINT_PLAINS = np.array([0.57, 0.74, 0.35], np.float32)
TINT_FOLIAGE = np.array([0.45, 0.68, 0.31], np.float32)
TINT_WATER = np.array([0.32, 0.50, 0.85], np.float32)
TINT_WHITE = np.array([1.0, 1.0, 1.0], np.float32)

# Unit-cube face corners in counter-clockwise order when viewed from outside,
# paired with the outward normal. The top face is listed first so a caller can
# index it directly; the remaining four are +X, -X, +Z, -Z.
_FACE_SIDES: tuple[tuple[np.ndarray, tuple[tuple[int, int, int], ...]], ...] = (
    (np.array([0.0, 1.0, 0.0]), ((0, 0, 0), (0, 0, 1), (1, 0, 1), (1, 0, 0))),
    (np.array([1.0, 0.0, 0.0]), ((1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1))),
    (np.array([-1.0, 0.0, 0.0]), ((0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0))),
    (np.array([0.0, 0.0, 1.0]), ((0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1))),
    (np.array([0.0, 0.0, -1.0]), ((1, 0, 0), (0, 0, 0), (0, 1, 0), (1, 1, 0))),
)


@dataclass
class Batch:
    """Vertex arrays for one draw call, in world space."""

    pos: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), np.float32))
    nrm: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), np.float32))
    uv: np.ndarray = field(default_factory=lambda: np.zeros((0, 2), np.float32))
    col: np.ndarray = field(default_factory=lambda: np.zeros((0, 4), np.float32))
    lm: np.ndarray = field(default_factory=lambda: np.zeros((0, 2), np.float32))
    idx: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), np.uint32))

    @property
    def count(self) -> int:
        """Triangle count."""
        return int(self.idx.shape[0])

    @property
    def index_count(self) -> int:
        """Indices to pass to ``glDrawElements``.

        Distinct from :attr:`count` on purpose: passing the triangle count as the
        index count silently draws a sixth of the scene, and for a two-triangle
        batch draws nothing at all, with no GL error.
        """
        return int(self.idx.shape[0]) * 3


class _Builder:
    """Accumulates quads. Kept as plain lists; the batch count stays modest."""

    __slots__ = ("pos", "nrm", "uv", "col", "lm", "idx", "count")

    def __init__(self) -> None:
        self.pos: list[np.ndarray] = []
        self.nrm: list[np.ndarray] = []
        self.uv: list[np.ndarray] = []
        self.col: list[np.ndarray] = []
        self.lm: list[np.ndarray] = []
        self.idx: list[np.ndarray] = []
        # Running vertex total. Recomputing it from len() of every part would
        # make a full world build quadratic.
        self.count = 0

    def add(self, corners, normal, uvs, tint, ao, light) -> None:
        base = self.count
        self.count += 4
        self.pos.append(np.asarray(corners, np.float32))
        self.nrm.append(np.tile(np.asarray(normal, np.float32), (4, 1)))
        self.uv.append(np.asarray(uvs, np.float32))
        self.col.append(
            np.column_stack(
                [
                    np.full(4, tint[0], np.float32),
                    np.full(4, tint[1], np.float32),
                    np.full(4, tint[2], np.float32),
                    np.asarray(ao, np.float32),
                ]
            )
        )
        self.lm.append(np.tile(np.asarray(light, np.float32), (4, 1)))
        # (2, 3) rather than a flat (6,) so finish() yields a (M, 3) index buffer.
        self.idx.append(
            np.array([base, base + 1, base + 2, base + 2, base + 3, base], np.uint32).reshape(2, 3)
        )

    def finish(self) -> Batch:
        if not self.pos:
            return Batch()
        return Batch(
            pos=np.concatenate(self.pos),
            nrm=np.concatenate(self.nrm),
            uv=np.concatenate(self.uv),
            col=np.concatenate(self.col),
            lm=np.concatenate(self.lm),
            idx=np.concatenate(self.idx),
        )


# --------------------------------------------------------------------------- #
# Textures
# --------------------------------------------------------------------------- #


def _value_noise(rng: np.random.Generator, size: int, cells: int) -> np.ndarray:
    """Bilinear, smoothstep-interpolated value noise in 0..1."""
    cells = max(int(cells), 2)
    grid = rng.random((cells, cells)).astype(np.float32)
    axis = np.linspace(0.0, cells - 1, size, dtype=np.float32)
    low = np.floor(axis).astype(int)
    high = np.minimum(low + 1, cells - 1)
    frac = axis - low
    frac = frac * frac * (3.0 - 2.0 * frac)
    fy = frac[:, None]
    fx = frac[None, :]
    top = grid[np.ix_(low, low)] * (1 - fx) + grid[np.ix_(low, high)] * fx
    bottom = grid[np.ix_(high, low)] * (1 - fx) + grid[np.ix_(high, high)] * fx
    return top * (1 - fy) + bottom * fy


def _fbm(rng: np.random.Generator, size: int, octaves: int = 5) -> np.ndarray:
    total = np.zeros((size, size), np.float32)
    amplitude = 1.0
    weight = 0.0
    cells = 3
    for _ in range(octaves):
        total += amplitude * _value_noise(rng, size, cells)
        weight += amplitude
        amplitude *= 0.5
        cells *= 2
    return total / weight


def build_atlas(seed: int = 7) -> np.ndarray:
    """Return an ``ATLAS_PX`` square RGBA atlas in sRGB, as uint8."""
    rng = np.random.default_rng(seed)
    n = TILE_PX
    coarse = _value_noise(rng, n, 5)
    medium = _value_noise(rng, n, 8)
    fine = _value_noise(rng, n, 16)
    seams = np.arange(n) % 8 == 0
    tiles: dict[int, np.ndarray] = {}

    def shaded(base: np.ndarray, noise: np.ndarray, amount: float) -> np.ndarray:
        return np.asarray(base, np.float32) * (1.0 - amount / 2 + amount * noise)[..., None]

    tiles[GRASS_TOP] = shaded([0.52, 0.74, 0.34], medium, 0.36)
    dirt = shaded([0.56, 0.42, 0.30], fine, 0.30)
    side = dirt.copy()
    side[:7] = tiles[GRASS_TOP][:7]
    tiles[GRASS_SIDE] = side
    tiles[DIRT] = dirt
    tiles[STONE] = shaded([0.60, 0.60, 0.62], fine, 0.24)

    cobble = shaded([0.56, 0.56, 0.58], coarse, 0.40)
    cobble[fine > 0.60] *= 0.74
    tiles[COBBLE] = cobble
    tiles[SAND] = shaded([0.90, 0.85, 0.66], fine, 0.16)

    leaves = shaded([0.42, 0.64, 0.30], fine, 0.52)
    tiles[LEAVES] = np.dstack([leaves, (fine > 0.60).astype(np.float32)[:, :, None]])

    logs = shaded([0.44, 0.33, 0.20], _value_noise(rng, n, 3), 0.38)
    tiles[LOG_SIDE] = logs
    rings = np.sin(np.add.outer(np.arange(n), np.arange(n)).astype(np.float32) * 1.15) * 0.5 + 0.5
    tiles[LOG_TOP] = shaded([0.54, 0.42, 0.26], rings, 0.28)

    planks = shaded([0.68, 0.54, 0.35], fine, 0.20)
    planks[seams] *= 0.68
    tiles[PLANKS] = planks

    tiles[WATER] = np.dstack([shaded([0.22, 0.45, 0.82], coarse, 0.24), np.full((n, n, 1), 0.72, np.float32)])
    tiles[SNOW] = shaded([0.95, 0.97, 0.99], fine, 0.10)
    # Deliberately near-clipping, so the block-light and any future glow path
    # have a bright source to work with.
    tiles[GLOWSTONE] = shaded([1.00, 0.94, 0.74], coarse, 0.22)
    tiles[GRAVEL] = shaded([0.46, 0.44, 0.44], coarse, 0.55)
    bricks = shaded([0.58, 0.29, 0.23], fine, 0.26)
    bricks[seams, :] = 0.74
    bricks[:, seams] = 0.74
    tiles[BRICKS] = bricks
    sandstone = shaded([0.85, 0.78, 0.57], fine, 0.14)
    sandstone[6:9] *= 0.90
    tiles[SANDSTONE] = sandstone

    atlas = np.ones((ATLAS_PX, ATLAS_PX, 4), np.float32)
    for index, tile in tiles.items():
        cx, cy = index % ATLAS_COLS, index // ATLAS_COLS
        # The atlas is stored top-row-first; the preview's UV origin is bottom-left.
        y0 = (ATLAS_ROWS - 1 - cy) * TILE_PX
        block = atlas[y0:y0 + TILE_PX, cx * TILE_PX:(cx + 1) * TILE_PX]
        block[:, :, :3] = tile[:, :, :3]
        if tile.shape[2] == 4:
            block[:, :, 3] = tile[:, :, 3]
    return (np.clip(atlas, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)


def tile_uv(tile: int, inset: float = 0.25) -> tuple[float, float, float, float]:
    """Return ``(u0, v0, u1, v1)`` for a tile, inset to avoid neighbour bleed."""
    cx, cy = tile % ATLAS_COLS, tile // ATLAS_COLS
    u0 = (cx * TILE_PX + inset) / ATLAS_PX
    u1 = ((cx + 1) * TILE_PX - inset) / ATLAS_PX
    v1 = 1.0 - (cy * TILE_PX + inset) / ATLAS_PX
    v0 = 1.0 - ((cy + 1) * TILE_PX - inset) / ATLAS_PX
    return u0, v0, u1, v1


def _tile_uvs(tile: int) -> tuple[tuple[float, float], ...]:
    u0, v0, u1, v1 = tile_uv(tile)
    return ((u0, v0), (u0, v1), (u1, v1), (u1, v0))


# --------------------------------------------------------------------------- #
# World
# --------------------------------------------------------------------------- #


@dataclass
class World:
    size: int
    origin: int
    height: np.ndarray
    skylight: np.ndarray
    ao: np.ndarray
    blocklight: np.ndarray
    seed: int = 11
    # World coordinates of every glowstone block, drawn as real geometry.
    glowstone: tuple[tuple[int, int, int], ...] = ()


def _corner_ao(height: np.ndarray) -> np.ndarray:
    """Voxel-style ambient occlusion sampled at each block-lattice corner.

    A corner is shared by up to four columns with different surface heights, so
    the reference height is the lowest of them. That keeps the field continuous
    across the heightmap, which a per-face reference would not.
    """
    size = height.shape[0]
    padded = np.pad(height, 1, mode="edge")
    windows = [padded[dy:dy + size + 1, dx:dx + size + 1] for dy in range(2) for dx in range(2)]
    reference = np.minimum.reduce(windows)
    side_a = windows[0] > reference + 0.5
    side_b = windows[1] > reference + 0.5
    corner = windows[3] > reference + 0.5
    occlusion = np.where(
        side_a & side_b,
        0,
        3 - side_a.astype(np.int16) - side_b.astype(np.int16) - corner.astype(np.int16),
    )
    return (0.40 + 0.60 * (occlusion / 3.0)).astype(np.float32)


def _box_blur(values: np.ndarray, passes: int) -> np.ndarray:
    out = values
    for _ in range(passes):
        padded = np.pad(out, 1, mode="edge")
        out = (
            padded[:-2, 1:-1] + padded[2:, 1:-1] + padded[1:-1, :-2] + padded[1:-1, 2:] + 4.0 * out
        ) / 8.0
    return out


def _max_filter(values: np.ndarray, size: int) -> np.ndarray:
    radius = size // 2
    padded = np.pad(values, radius, mode="edge")
    out = np.full_like(values, -np.inf)
    for dy in range(size):
        for dx in range(size):
            out = np.maximum(out, padded[dy:dy + values.shape[0], dx:dx + values.shape[1]])
    return out


def _smoothstep(edge0: float, edge1: float, values: np.ndarray) -> np.ndarray:
    t = np.clip((values - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def build_world(seed: int = 11, size: int = 96) -> World:
    rng = np.random.default_rng(seed)
    relief = _fbm(rng, size, octaves=5)
    # Normalise so the intended height range is actually reached: the raw fbm
    # sum rarely approaches 1.0, which would otherwise sink the whole map below
    # sea level and leave nothing to look at.
    relief = relief / max(float(relief.max()), 1e-6)
    axis = np.linspace(-1.0, 1.0, size, dtype=np.float32)
    # Carve the border into open water so the map reads as an island with a
    # shoreline rather than a terrain slab that simply stops at the edge. This
    # parameter set was measured to hold ~45% land, with inland pools and
    # snow-capped highs, across several seeds.
    coast = 1.0 - _smoothstep(0.55, 0.96, np.abs(axis))
    coast = coast[None, :] * coast[:, None]
    height = np.floor(6.0 + relief * 36.0 - (1.0 - coast) * 36.0).astype(np.float32)

    # Sky occlusion: a column darkens when a neighbour towers over it, then the
    # field is blurred so lightmap gradients read like Minecraft's smooth light.
    # The falloff is deliberately gentle: Minecraft gives full skylight to any
    # block with a clear view upward, and an aggressive ramp made open hillside
    # read as dusk, which made the pack's own grade look far darker than it is.
    local_max = _max_filter(height, 9)
    skylight = np.clip(15.0 - (local_max - height) * 0.8, 0.0, 15.0) / 15.0
    skylight = _box_blur(skylight, 2)

    world = World(
        size=size,
        origin=-size // 2,
        height=height,
        skylight=skylight,
        ao=_corner_ao(height),
        blocklight=np.zeros((size, size), np.float32),
        seed=seed,
    )
    _place_glowstone(world)
    return world


def _place_glowstone(world: World) -> None:
    """A short glowstone pillar: the scene's only block-light source.

    It gives the block-light term in ``lib/lighting.glsl`` something to show, and
    puts a small hard-edged caster in the packed shadow map.
    """
    spot_x = world.origin + world.size // 2 - 12
    spot_z = world.origin + world.size // 2 + 10
    i, j = spot_x - world.origin, spot_z - world.origin
    if not (0 <= i < world.size and 0 <= j < world.size):
        return
    base = world.height[i, j]
    if base <= SEA_LEVEL + 1.0:
        return
    world.glowstone = tuple(
        (spot_x + dx, spot_z + dz, int(base) + dy)
        for dx in range(2)
        for dz in range(2)
        for dy in range(3)
    )
    ys, xs = np.mgrid[0:world.size, 0:world.size]
    distance = np.sqrt(
        (xs + world.origin - spot_x - 0.5) ** 2 + (ys + world.origin - spot_z - 0.5) ** 2
    )
    world.blocklight = (np.clip(1.0 - distance / 9.0, 0.0, 1.0) ** 1.6).astype(np.float32)


# --------------------------------------------------------------------------- #
# Geometry
# --------------------------------------------------------------------------- #


def _tint(tile: int) -> np.ndarray:
    if tile == WATER:
        return TINT_WATER
    if tile in (GRASS_TOP, GRASS_SIDE):
        return TINT_PLAINS
    if tile == LEAVES:
        return TINT_FOLIAGE
    return TINT_WHITE


def _light(world: World, x: int, z: int) -> np.ndarray:
    return np.array(
        [world.blocklight[x - world.origin, z - world.origin], world.skylight[x - world.origin, z - world.origin]],
        np.float32,
    )


def _top_tile(world: World, height: float) -> int:
    if height <= SEA_LEVEL + 1.0:
        return SAND
    if height > 26.0:
        return SNOW
    return GRASS_TOP


def _side_tile(world: World, height: float) -> int:
    if height <= SEA_LEVEL + 1.0:
        return SAND
    if height > 26.0:
        return SNOW
    return GRASS_SIDE


def _emit_voxel(builder: _Builder, origin: tuple[float, float, float], normal, corners, tile, tint, ao, light) -> None:
    builder.add(
        [(c[0] + origin[0], c[1] + origin[1], c[2] + origin[2]) for c in corners],
        normal,
        _tile_uvs(tile),
        tint,
        ao,
        light,
    )


def build_batches(world: World, tree_density: float = 0.02) -> dict[str, Batch]:
    """Build the opaque, cutout, and water batches for a heightfield world."""
    opaque = _Builder()
    cutout = _Builder()
    rng = np.random.default_rng(world.seed + 11)
    origin, size = world.origin, world.size
    top_normal, top_corners = _FACE_SIDES[0]

    for x in range(origin, origin + size):
        for z in range(origin, origin + size):
            i, j = x - origin, z - origin
            height = float(world.height[i, j])
            top, side = _top_tile(world, height), _side_tile(world, height)
            tint_top, tint_side = _tint(top), _tint(side)
            light = _light(world, x, z)
            ao_corner = world.ao[i:i + 2, j:j + 2]
            # AO corner order is (0,0) (1,0) (1,1) (0,1), matching _FACE_SIDES.
            ao = np.array([ao_corner[0, 0], ao_corner[1, 0], ao_corner[1, 1], ao_corner[0, 1]], np.float32)

            _emit_voxel(opaque, (x, height, z), top_normal, top_corners, top, tint_top, ao, light)

            for direction, (nx, nz) in enumerate(((x + 1, z), (x - 1, z), (x, z + 1), (x, z - 1))):
                if origin <= nx < origin + size and origin <= nz < origin + size:
                    neighbour = float(world.height[nx - origin, nz - origin])
                else:
                    neighbour = 0.0
                for y in range(int(min(height, neighbour)), int(max(height, neighbour))):
                    # _FACE_SIDES[1:] is ordered +X, -X, +Z, -Z, matching this loop.
                    normal, corners = _FACE_SIDES[1 + direction]
                    # Slightly darken the -X/-Z faces so the blocky silhouette
                    # stays readable even before any shading is applied.
                    facing_away = normal[0] < 0 or normal[2] < 0
                    _emit_voxel(
                        opaque,
                        (x, float(y), z),
                        normal,
                        corners,
                        side,
                        tint_side,
                        ao * (0.93 if facing_away else 1.0),
                        light,
                    )

    _build_trees(world, cutout, rng, tree_density)
    for x, z, tile, y in _props(world):
        light = _light(world, x, z)
        ao = np.ones(4, np.float32)
        for normal, corners in _FACE_SIDES[1:]:
            _emit_voxel(opaque, (float(x), y, float(z)), normal, corners, tile, _tint(tile), ao, light)
        _emit_voxel(opaque, (float(x), y + 1.0, float(z)), top_normal, top_corners, tile, _tint(tile), ao, light)

    return {"opaque": opaque.finish(), "cutout": cutout.finish(), "water": _build_water_surface(world)}


def _props(world: World) -> list[tuple[int, int, int, float]]:
    origin, size = world.origin, world.size
    props: list[tuple[int, int, int, float]] = []
    for x, z, tile in (
        (origin + 14, origin + 22, COBBLE),
        (origin + 62, origin + 32, PLANKS),
        (origin + 36, origin + 72, BRICKS),
    ):
        i, j = x - origin, z - origin
        if 0 <= i < size and 0 <= j < size and world.height[i, j] > SEA_LEVEL + 1.5:
            props.append((x, z, tile, float(world.height[i, j])))
    props.extend((x, z, GLOWSTONE, float(y)) for x, z, y in world.glowstone)
    return props


def _build_water_surface(world: World) -> Batch:
    """A double-sided quad at sea level, as a translucent batch.

    Terrain draws first with depth writes, so land above sea level occludes this
    plane for free. Keeping it a single quad also means the preview exercises the
    water program from both above and below the surface.

    Both windings are emitted because the water pass runs with back-face culling,
    which is Iris's per-program decision rather than something the pack controls:
    a single-sided plane would make the underwater viewpoint show no water at all
    and quietly hide whatever the water program does from below.
    """
    builder = _Builder()
    lo, hi = float(world.origin), float(world.origin + world.size)
    y = SEA_LEVEL + 0.9
    uvs = _tile_uvs(WATER)
    tint = TINT_WATER
    light = (0.0, 0.92)
    for corners, normal in (
        (((lo, y, lo), (lo, y, hi), (hi, y, hi), (hi, y, lo)), (0.0, 1.0, 0.0)),
        (((lo, y, lo), (hi, y, lo), (hi, y, hi), (lo, y, hi)), (0.0, -1.0, 0.0)),
    ):
        builder.add(corners, normal, uvs, tint, np.ones(4, np.float32), light)
    return builder.finish()


def _build_trees(world: World, cutout: _Builder, rng: np.random.Generator, density: float) -> None:
    origin, size = world.origin, world.size
    attempts = int(size * size * density * 0.5)
    for _ in range(attempts):
        x = int(rng.integers(origin + 4, origin + size - 8))
        z = int(rng.integers(origin + 4, origin + size - 8))
        i, j = x - origin, z - origin
        height = float(world.height[i, j])
        if not (SEA_LEVEL + 1.5 < height < 27.0):
            continue
        trunk = int(rng.integers(4, 7))
        light = _light(world, x, z)
        leaf_light = np.array([light[0], min(1.0, light[1] * 0.94)], np.float32)
        for dy in range(trunk):
            _emit_box(cutout, (float(x), height + dy, float(z)), (1, 1, 1), LOG_SIDE, TINT_WHITE, light, 1.0)
        # Canopy: two wide layers, then two narrow caps, optionally missing the
        # very top so the silhouette is not a perfect cube.
        for step, half in enumerate((2, 2, 1, 1)):
            if step == 3 and rng.random() < 0.5:
                continue
            span = 2 * half + 1
            _emit_box(
                cutout,
                (float(x - half), height + trunk - 2 + step, float(z - half)),
                (span, 1, span),
                LEAVES,
                TINT_FOLIAGE,
                leaf_light,
                0.93,
            )


def _emit_box(builder: _Builder, low, size_xyz, tile, tint, light, ao_value) -> None:
    for normal, corners in _FACE_SIDES:
        scaled = [(c[0] * size_xyz[0], c[1] * size_xyz[1], c[2] * size_xyz[2]) for c in corners]
        _emit_voxel(builder, low, normal, scaled, tile, tint, np.full(4, ao_value, np.float32), light)


# --------------------------------------------------------------------------- #
# Cache
# --------------------------------------------------------------------------- #


def load_scene(
    seed: int = 3,
    size: int = 96,
    atlas_seed: int = 7,
    tree_density: float = 0.02,
    cache_dir: Path | None = None,
) -> tuple[np.ndarray, World, dict[str, Batch]]:
    """Return ``(atlas, world, batches)``, caching the slow geometry build.

    Building the batches is a Python-level loop over tens of thousands of quads,
    which takes seconds; caching it keyed on every parameter that affects
    geometry keeps repeated preview runs instant.
    """
    key = hashlib.sha256(
        f"{seed}|{size}|{atlas_seed}|{tree_density}|{SEA_LEVEL}".encode()
    ).hexdigest()[:16]
    cache = (cache_dir or Path(__file__).resolve().parent / ".cache") / f"scene-{key}.npz"
    world = build_world(seed, size)
    atlas = build_atlas(atlas_seed)

    if cache.is_file():
        try:
            with np.load(cache) as data:
                batches = {name: Batch(*(data[f"{name}_{field}"] for field in ("pos", "nrm", "uv", "col", "lm", "idx"))) for name in ("opaque", "cutout", "water")}
            return atlas, world, batches
        except (KeyError, ValueError, OSError):
            # A stale or truncated cache is not worth failing a preview over.
            cache.unlink(missing_ok=True)

    batches = build_batches(world, tree_density)
    cache.parent.mkdir(parents=True, exist_ok=True)
    payload: dict[str, np.ndarray] = {}
    for name, batch in batches.items():
        for field_name in ("pos", "nrm", "uv", "col", "lm", "idx"):
            payload[f"{name}_{field_name}"] = getattr(batch, field_name)
    np.savez_compressed(cache, **payload)
    return atlas, world, batches
