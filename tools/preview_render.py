#!/usr/bin/env python3
"""Render Aurelia's real GLSL offscreen on the Mac's GPU, with no Minecraft.

Iris supplies a compatibility-profile environment and a set of runtime uniforms.
This module reconstructs just enough of it to execute the *unmodified* shader
programs from ``shaders/`` on a headless core-profile context: a camera, a
directional shadow map rendered with the pack's own ``shadow`` program, an
``RGBA16F`` scene target matching the pack's ``colortex0`` directive, and the
sun/sky/fog/lightmap uniforms a given time of day implies.

What this proves: the GLSL runs, links, interpolates as declared, and produces
the colour the maths implies. That is enough to grade a look offline.

What this does not prove: Iris's own uniform binding, render-layer assignment,
macOS compatibility-to-core source rewrite, or in-game frame pacing. Those still
require a real Iris run.
"""

from __future__ import annotations

import ctypes
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

import glfw
from OpenGL.GL import *  # noqa: F403

from preview_glsl import VERTEX_UPLOAD, VERTEX_UPLOAD_COMPONENTS, build_source
from preview_targets import (
    TargetConfig,
    collect_target_configs,
    composite_passes_present,
    parse_render_targets,
)

# Iris derives lmcoord as clamp(mc1 / (30/32) - (1/32), 0, 1) in every vertex
# stage. These are the constants that invert it, so a scene can state the light
# level it wants instead of the packed coordinate Iris would have produced.
_LIGHT_DIVISOR = np.float32(30.0 / 32.0)
_LIGHT_BIAS = np.float32(1.0 / 32.0)

_FAR = 1200.0
_NEAR = 0.08


# --------------------------------------------------------------------------- #
# Small matrix helpers (row-major maths, transposed on upload)
# --------------------------------------------------------------------------- #


def identity() -> np.ndarray:
    return np.eye(4, dtype=np.float64)


def perspective(fovy_degrees: float, aspect: float, near: float, far: float) -> np.ndarray:
    f = 1.0 / np.tan(np.radians(fovy_degrees) * 0.5)
    m = np.zeros((4, 4), np.float64)
    m[0, 0] = f / aspect
    m[1, 1] = f
    m[2, 2] = (far + near) / (near - far)
    m[2, 3] = (2.0 * far * near) / (near - far)
    m[3, 2] = -1.0
    return m


def ortho(left: float, right: float, bottom: float, top: float, near: float, far: float) -> np.ndarray:
    m = identity()
    m[0, 0] = 2.0 / (right - left)
    m[1, 1] = 2.0 / (top - bottom)
    m[2, 2] = -2.0 / (far - near)
    m[0, 3] = -(right + left) / (right - left)
    m[1, 3] = -(top + bottom) / (top - bottom)
    m[2, 3] = -(far + near) / (far - near)
    return m


def look_at(eye: np.ndarray, target: np.ndarray, up: np.ndarray) -> np.ndarray:
    forward = target - eye
    forward = forward / np.linalg.norm(forward)
    side = np.cross(forward, up)
    if np.linalg.norm(side) < 1e-6:
        # Looking straight up or down: any perpendicular axis will do.
        side = np.cross(forward, np.array([0.0, 0.0, 1.0]))
        if np.linalg.norm(side) < 1e-6:
            side = np.array([1.0, 0.0, 0.0])
    side = side / np.linalg.norm(side)
    true_up = np.cross(side, forward)
    m = identity()
    m[0, :3] = side
    m[1, :3] = true_up
    m[2, :3] = -forward
    m[0, 3] = -side @ eye
    m[1, 3] = -true_up @ eye
    m[2, 3] = forward @ eye
    return m


def normal_matrix(view: np.ndarray) -> np.ndarray:
    """The rotation part of ``inverse(transpose(view))``, as Iris defines it."""
    return np.linalg.inv(view[:3, :3]).T


def _upload(matrix: np.ndarray) -> np.ndarray:
    """Row-major maths -> contiguous column-major float32 for glUniformMatrix*."""
    return np.ascontiguousarray(matrix.T, dtype=np.float32)


def camera_basis(yaw: float, pitch: float) -> np.ndarray:
    """Minecraft-style basis: yaw 0 looks toward +Z, pitch is elevation.

    Columns are ``[right, up, forward]``. ``right = forward x worldUp`` is the
    standard handedness for this convention.
    """
    cy, sy = np.cos(yaw), np.sin(yaw)
    cp, sp = np.cos(pitch), np.sin(pitch)
    forward = np.array([cp * sy, sp, cp * cy])
    world_up = np.array([0.0, 1.0, 0.0])
    right = np.cross(forward, world_up)
    right = right / max(float(np.linalg.norm(right)), 1e-9)
    up = np.cross(right, forward)
    return np.column_stack([right, up, forward])


# --------------------------------------------------------------------------- #
# Time of day
# --------------------------------------------------------------------------- #


@dataclass
class Sky:
    """The uniforms a time of day implies.

    Stand-ins for values Minecraft/Iris would compute, not vanilla's exact sky
    model. They are a plausible, time-aware input so the pack's own colour
    handling can be judged. Iris treats both colours as sRGB.
    """

    time: float = 0.28
    rain: float = 0.0

    @property
    def sun_angle(self) -> float:
        # 0.0 dawn, 0.25 noon, 0.5 dusk, 0.75 midnight.
        return 2.0 * np.pi * (self.time - 0.25)

    @property
    def sun_direction(self) -> np.ndarray:
        a = self.sun_angle
        direction = np.array([0.28 * np.sin(a), np.cos(a), 0.94 * np.sin(a)])
        return direction / np.linalg.norm(direction)

    @property
    def moon_direction(self) -> np.ndarray:
        return -self.sun_direction

    @property
    def shadow_light_direction(self) -> np.ndarray:
        """Iris's shadowLightPosition body: the sun by day, the moon once the
        sun is below the horizon (Iris flips at sun height 0)."""
        sun = self.sun_direction
        return sun if sun[1] >= 0.0 else self.moon_direction

    @property
    def elevation(self) -> float:
        return float(self.sun_direction[1])

    def _blend(self) -> tuple[float, float]:
        """``(dayness, low_sun)``: overall brightness and horizon warmth."""
        elevation = self.elevation
        dayness = float(np.clip((elevation + 0.14) / 0.30, 0.0, 1.0))
        low = float(np.clip(1.0 - abs(elevation) / 0.32, 0.0, 1.0))
        return dayness, low**1.5

    def _grade(self, day: np.ndarray, night: np.ndarray, dusk: np.ndarray, dusk_weight: float) -> np.ndarray:
        dayness, low = self._blend()
        colour = night + (day - night) * dayness
        colour = colour * (1.0 - low) + dusk * low * dusk_weight
        if self.rain:
            grey = np.array([0.45, 0.48, 0.52])
            colour = colour * (1.0 - self.rain * 0.65) + grey * self.rain * 0.65
        return np.clip(colour, 0.0, 1.0).astype(np.float32)

    @property
    def sky_color(self) -> np.ndarray:
        return self._grade(
            day=np.array([0.44, 0.63, 1.00]),
            night=np.array([0.020, 0.030, 0.075]),
            dusk=np.array([0.95, 0.52, 0.30]),
            dusk_weight=0.85,
        )

    @property
    def fog_color(self) -> np.ndarray:
        return self._grade(
            day=np.array([0.68, 0.80, 0.97]),
            night=np.array([0.035, 0.045, 0.085]),
            dusk=np.array([0.86, 0.55, 0.38]),
            dusk_weight=0.75,
        )

    @property
    def daylight(self) -> float:
        """Lightmap scale, so a night shot is dark for the right reason."""
        dayness, _ = self._blend()
        return 0.09 + 0.91 * dayness


# --------------------------------------------------------------------------- #
# GL plumbing
# --------------------------------------------------------------------------- #


class Context:
    """A hidden core-profile context. No window is ever shown."""

    def __init__(self, width: int, height: int) -> None:
        if not glfw.init():
            raise RuntimeError("glfw.init() failed; is a window server session available?")
        glfw.window_hint(glfw.VISIBLE, glfw.FALSE)
        glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 3)
        glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 3)
        glfw.window_hint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
        self.window = glfw.create_window(width, height, "aurelia-preview", None, None)
        if not self.window:
            glfw.terminate()
            raise RuntimeError("could not create an OpenGL 3.3 core context")
        glfw.make_context_current(self.window)
        # Use whatever size the driver actually gave us rather than trusting the
        # request. macOS can report a stale size immediately after window
        # creation, and a HiDPI display can legitimately return double it;
        # either way the render must follow the real framebuffer, not fail.
        width_now, height_now = glfw.get_framebuffer_size(self.window)
        if (width_now, height_now) != (width, height):
            print(
                f"note: requested {width}x{height}, framebuffer is "
                f"{width_now}x{height_now}; rendering at the framebuffer size"
            )
        if width_now <= 0 or height_now <= 0:
            glfw.terminate()
            raise RuntimeError(f"default framebuffer has no area: {width_now}x{height_now}")
        self.width, self.height = width_now, height_now

    def close(self) -> None:
        glfw.terminate()


def _numbered(source: str) -> str:
    return "\n".join(f"{i:4d}| {line}" for i, line in enumerate(source.splitlines(), 1))


def _compile(kind: int, source: str, label: str) -> int:
    shader = glCreateShader(kind)
    glShaderSource(shader, source)
    glCompileShader(shader)
    if glGetShaderiv(shader, GL_COMPILE_STATUS) != GL_TRUE:
        log = glGetShaderInfoLog(shader).decode(errors="replace")
        glDeleteShader(shader)
        raise RuntimeError(f"{label} failed to compile:\n{_numbered(source)}\n{log}")
    return shader


class Program:
    """A linked program with cached uniform locations and typed setters."""

    def __init__(self, vertex_source: str, fragment_source: str, label: str) -> None:
        self.label = label
        vertex = _compile(GL_VERTEX_SHADER, vertex_source, f"{label}.vsh")
        fragment = _compile(GL_FRAGMENT_SHADER, fragment_source, f"{label}.fsh")
        self.handle = glCreateProgram()
        glAttachShader(self.handle, vertex)
        glAttachShader(self.handle, fragment)
        glLinkProgram(self.handle)
        glDeleteShader(vertex)
        glDeleteShader(fragment)
        if glGetProgramiv(self.handle, GL_LINK_STATUS) != GL_TRUE:
            log = glGetProgramInfoLog(self.handle).decode(errors="replace")
            glDeleteProgram(self.handle)
            raise RuntimeError(f"{label} failed to link:\n{log}")
        self._locations: dict[str, int] = {}

    def use(self) -> None:
        glUseProgram(self.handle)

    def location(self, name: str) -> int | None:
        if name not in self._locations:
            self._locations[name] = glGetUniformLocation(self.handle, name)
        return None if self._locations[name] == -1 else self._locations[name]

    def set(self, name: str, value) -> None:
        location = self.location(name)
        if location is None:
            # Unused uniforms are stripped by the compiler; that is expected.
            return
        if isinstance(value, (bool, np.bool_)):
            glUniform1i(location, int(value))
        elif isinstance(value, (int, np.integer)):
            glUniform1i(location, int(value))
        elif isinstance(value, (float, np.floating)):
            glUniform1f(location, float(value))
        elif isinstance(value, np.ndarray):
            if value.shape == (4, 4):
                glUniformMatrix4fv(location, 1, GL_FALSE, _upload(value))
            elif value.shape == (3, 3):
                glUniformMatrix3fv(location, 1, GL_FALSE, _upload(value))
            elif value.shape == (3,):
                glUniform3fv(location, 1, np.ascontiguousarray(value, np.float32))
            elif value.shape == (4,):
                glUniform4fv(location, 1, np.ascontiguousarray(value, np.float32))
            else:
                raise ValueError(f"unsupported uniform shape for {name}: {value.shape}")
        else:
            raise TypeError(f"unsupported uniform type for {name}: {type(value)}")

    def sampler(self, name: str, unit: int, texture: int, compare_sampler: int = 0) -> None:
        """Bind ``texture`` to ``unit``.

        A uniform declared ``sampler2DShadow`` is how the pack opts into Iris's
        ``shadowHardwareFiltering``; for those, ``compare_sampler`` (a GL
        sampler object with compare mode and linear filtering) is bound to the
        unit, matching what Iris does to the texture. Every other binding
        resets the unit to no sampler object, so the texture's own nearest
        parameters apply exactly as before.
        """
        location = self.location(name)
        if location is not None:
            glActiveTexture(GL_TEXTURE0 + unit)
            glBindTexture(GL_TEXTURE_2D, texture)
            shadow = self.is_shadow_sampler(name)
            glBindSampler(unit, compare_sampler if shadow else 0)
            glUniform1i(location, unit)

    def is_shadow_sampler(self, name: str) -> bool:
        if not hasattr(self, "_shadow_samplers"):
            self._shadow_samplers = set()
            count = glGetProgramiv(self.handle, GL_ACTIVE_UNIFORMS)
            for index in range(count):
                uniform_name, _size, uniform_type = glGetActiveUniform(self.handle, index)
                if uniform_type == GL_SAMPLER_2D_SHADOW:
                    self._shadow_samplers.add(uniform_name.decode())
        return name in self._shadow_samplers

    def dispose(self) -> None:
        glDeleteProgram(self.handle)


def _make_rgba_texture(width: int, height: int, data: np.ndarray) -> int:
    """Upload an 8-bit RGBA image. The channel count is checked, not assumed.

    A short buffer uploaded as GL_RGBA can raise no GL error at all and still
    land as scrambled texels, so the shape is asserted instead of trusted.
    """
    if data.shape != (height, width, 4):
        raise ValueError(f"texture data must be ({height}, {width}, 4) uint8, got {data.shape}")
    texture = glGenTextures(1)
    glBindTexture(GL_TEXTURE_2D, texture)
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, data)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    return texture


def _make_depth_texture(width: int, height: int) -> int:
    texture = glGenTextures(1)
    glBindTexture(GL_TEXTURE_2D, texture)
    glTexImage2D(
        GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT32F, width, height, 0, GL_DEPTH_COMPONENT, GL_FLOAT, None
    )
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    return texture


_GL_INTERNAL_FORMATS: dict[str, int] = {
    "RGBA32F": GL_RGBA32F,
    "RGBA16F": GL_RGBA16F,
    "RGB16F": GL_RGB16F,
    "RGBA8": GL_RGBA8,
    "RGB8": GL_RGB8,
    "RG8": GL_RG8,
    "R8": GL_R8,
}


def _internal_format(name: str) -> int:
    if name not in _GL_INTERNAL_FORMATS:
        raise ValueError(f"unsupported colortex format: {name}")
    return _GL_INTERNAL_FORMATS[name]


def _make_scene_target(config: TargetConfig, width: int, height: int) -> tuple[int, int, int]:
    """A colour target in the format the pack's directive declares, plus depth.

    colortex0 is always full-resolution with a depth attachment; the format is
    read from the ``colortex0Format`` directive rather than hardcoded.
    """
    color = glGenTextures(1)
    glBindTexture(GL_TEXTURE_2D, color)
    glTexImage2D(
        GL_TEXTURE_2D, 0, _internal_format(config.fmt), width, height, 0, GL_RGBA, GL_FLOAT, None
    )
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)

    depth = _make_depth_texture(width, height)
    fbo = glGenFramebuffers(1)
    glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth, 0)
    _require_complete("scene")
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    return fbo, color, depth


def _make_color_target(config: TargetConfig, width: int, height: int) -> tuple[int, int]:
    """A standalone colour target (no depth) for a composite-style pass output."""
    color = glGenTextures(1)
    glBindTexture(GL_TEXTURE_2D, color)
    glTexImage2D(
        GL_TEXTURE_2D, 0, _internal_format(config.fmt), width, height, 0, GL_RGBA, GL_FLOAT, None
    )
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    fbo = glGenFramebuffers(1)
    glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0)
    _require_complete(f"colortex{config.index}")
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    return fbo, color


def _make_shadow_target(resolution: int) -> tuple[int, int]:
    depth = _make_depth_texture(resolution, resolution)
    fbo = glGenFramebuffers(1)
    glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth, 0)
    # A depth-only FBO must explicitly declare that it draws no colour.
    glDrawBuffers(1, [GL_NONE])
    glReadBuffer(GL_NONE)
    _require_complete("shadow")
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    return fbo, depth


def _make_depth_only_target(width: int, height: int) -> tuple[int, int]:
    """A depth-only FBO holding a standalone copy of the scene depth.

    Iris hands gbuffers programs depth *copies*, never the live attachment:
    ``depthtex1`` is the pre-translucent opaque copy
    (``RenderTargets.copyPreTranslucentDepth`` into ``noTranslucents``,
    unconditionally before deferred/translucent rendering in Iris 1.7.6), while
    ``depthtex0`` is live during translucents. The harness mirrors that by
    blitting its opaque-pass depth into this texture and binding it as
    ``depthtex1`` for the water program.
    """
    depth = _make_depth_texture(width, height)
    fbo = glGenFramebuffers(1)
    glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth, 0)
    glDrawBuffers(1, [GL_NONE])
    glReadBuffer(GL_NONE)
    _require_complete("depth snapshot")
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    return fbo, depth


def _require_complete(label: str) -> None:
    status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
    if status != GL_FRAMEBUFFER_COMPLETE:
        raise RuntimeError(f"{label} framebuffer incomplete: 0x{status:04x}")


# --------------------------------------------------------------------------- #
# Sky textures
# --------------------------------------------------------------------------- #


def _disc_coordinate(size: int) -> np.ndarray:
    axis = np.linspace(-1.0, 1.0, size, dtype=np.float32)
    dx, dy = np.meshgrid(axis, axis)
    return np.sqrt(dx * dx + dy * dy)


def sun_texture(size: int = 128) -> np.ndarray:
    """A warm disc with a soft aureole, as 8-bit sRGB RGBA."""
    radius = _disc_coordinate(size)
    disc = np.clip((0.42 - radius) / 0.10, 0.0, 1.0)
    core = np.clip((0.34 - radius) / 0.08, 0.0, 1.0)
    glow = np.clip(1.0 - radius, 0.0, 1.0) ** 3.0 * 0.55
    alpha = np.clip(disc + glow, 0.0, 1.0)
    rgb = np.stack(
        [
            1.00 * core + 1.00 * glow,
            0.96 * core + 0.86 * glow,
            0.84 * core + 0.60 * glow,
        ],
        axis=-1,
    )
    return np.dstack([(np.clip(rgb, 0, 1) * 255).astype(np.uint8), (alpha * 255).astype(np.uint8)[..., None]])


def clouds_texture(size: int = 512, seed: int = 23) -> np.ndarray:
    """A stand-in for Minecraft's ``clouds.png``: white cells on transparency.

    Vanilla clouds are hard-edged cellular blobs, so this is thresholded value
    noise with one soft step, and an edge fade so the clamped texture wrap
    never shows. Alpha-only imagery: the pass re-lights the RGB itself.
    """
    from PIL import Image as _Image

    rng = np.random.default_rng(seed)
    noise = np.zeros((size, size), np.float32)
    for cells, weight in ((5, 1.0), (9, 0.55), (17, 0.30)):
        base = (rng.random((cells, cells)) * 255).astype(np.uint8)
        up = np.asarray(
            _Image.fromarray(base, "L").resize((size, size), _Image.BILINEAR), np.float32
        ) / 255.0
        noise += weight * up
    noise /= 1.85
    alpha = np.clip((noise - 0.52) / 0.16, 0.0, 1.0)
    y, x = np.mgrid[0:size, 0:size]
    edge = np.clip(
        np.minimum.reduce([x + 1, size - x, y + 1, size - y]) / (size * 0.08), 0.0, 1.0
    )
    alpha *= edge
    rgb = np.ones((size, size, 3), np.float32)
    return np.dstack([(rgb * 255).astype(np.uint8), (alpha * 255).astype(np.uint8)[..., None]])


def clouds_layer(height: float = 108.0, extent: float = 1400.0, size: int = 512) -> RawBatch:
    """A flat cloud plane at ``height``, UV-mapped across the whole texture.

    One big top-facing grid, like Minecraft's cloud skin stretched over the
    visible sky. Kept well above the island so terrain occludes it correctly,
    and wide enough that its edges sit beyond the horizon in every camera.
    """
    corners = np.array([[-1.0, 0.0, -1.0], [1.0, 0.0, -1.0], [1.0, 0.0, 1.0], [-1.0, 0.0, 1.0]])
    positions, uvs, indices = [], [], []
    step = extent / 48.0
    half = extent * 0.5
    for i in range(48):
        for j in range(48):
            x0, z0 = -half + i * step, -half + j * step
            base = len(positions)
            for corner in corners:
                positions.append(
                    [x0 + corner[0] * step, height, z0 + corner[2] * step]
                )
                uvs.append(
                    [
                        (x0 + corner[0] * step + half) / extent,
                        1.0 - (z0 + corner[2] * step + half) / extent,
                    ]
                )
            indices.append([base, base + 1, base + 2])
            indices.append([base + 2, base + 3, base])
    count = len(positions)
    return RawBatch(
        positions,
        np.tile([0.0, 1.0, 0.0], (count, 1)),
        uvs,
        np.ones((count, 4), np.float32),
        np.ones((count, 2), np.float32),
        indices,
    )


def moon_texture(size: int = 128) -> np.ndarray:
    """A pale cratered disc, as 8-bit sRGB RGBA."""
    axis = np.linspace(-1.0, 1.0, size, dtype=np.float32)
    dx, dy = np.meshgrid(axis, axis)
    disc = np.clip((0.40 - _disc_coordinate(size)) / 0.06, 0.0, 1.0)
    craters = 1.0 - 0.16 * np.clip(np.sin(dx * 9.0) * np.sin(dy * 7.0), 0.0, 1.0)
    rgb = np.stack([disc * 0.92 * craters, disc * 0.93 * craters, disc * 0.88 * craters], axis=-1)
    return np.dstack([(np.clip(rgb, 0, 1) * 255).astype(np.uint8), (disc * 255).astype(np.uint8)[..., None]])


# --------------------------------------------------------------------------- #
# Batches handed to the GL layer
# --------------------------------------------------------------------------- #


def skybox(radius: float = 600.0) -> RawBatch:
    """A camera-centred cube in player space, standing in for Iris's skybox.

    gbuffers_skybasic derives its view direction from the player-space position,
    which is only a true ray if the geometry is a box around the camera. Drawing
    a fullscreen quad instead would hand the shader a diagonal of NDC corners and
    produce a plausible but meaningless gradient.
    """
    r = float(radius)
    # (normal, corner offsets) for the six faces, wound so the inside is visible.
    faces = (
        ((1, 0, 0), ((r, -r, -r), (r, -r, r), (r, r, r), (r, r, -r))),
        ((-1, 0, 0), ((-r, -r, r), (-r, -r, -r), (-r, r, -r), (-r, r, r))),
        ((0, 1, 0), ((-r, r, -r), (r, r, -r), (r, r, r), (-r, r, r))),
        ((0, -1, 0), ((-r, -r, r), (r, -r, r), (r, -r, -r), (-r, -r, -r))),
        ((0, 0, 1), ((-r, -r, r), (-r, r, r), (r, r, r), (r, -r, r))),
        ((0, 0, -1), ((r, -r, -r), (r, r, -r), (-r, r, -r), (-r, -r, -r))),
    )
    position, normal, index = [], [], []
    for face, (n, corners) in enumerate(faces):
        base = face * 4
        position.extend(corners)
        normal.extend([n] * 4)
        index.extend([[base, base + 1, base + 2], [base + 2, base + 3, base]])
    count = len(position)
    return RawBatch(
        position,
        np.asarray(normal, np.float32),
        np.zeros((count, 2), np.float32),
        np.ones((count, 4), np.float32),
        np.ones((count, 2), np.float32),
        index,
    )


class RawBatch:
    """Vertex arrays already in player space, for synthetic passes.

    Positions are stored as three components to match the interleaved layout in
    ``_create_buffers``; the shader's ``w`` comes from the default generic vertex
    attribute, which is 1.0. A four-component position here silently shifts every
    later attribute by one float, so it is stripped and rejected loudly.
    """

    def __init__(self, position, normal, uv, color, lightmap, index) -> None:
        position = np.asarray(position, np.float32)
        if position.ndim != 2 or position.shape[1] < 3:
            raise ValueError(f"position must be (N, >=3), got {position.shape}")
        self.pos, self.nrm, self.uv, self.col, self.lm, self.idx = (
            np.ascontiguousarray(position[:, :3], np.float32),
            np.ascontiguousarray(normal, np.float32),
            np.ascontiguousarray(uv, np.float32),
            np.ascontiguousarray(color, np.float32),
            np.ascontiguousarray(lightmap, np.float32),
            np.ascontiguousarray(index, np.uint32),
        )

    @property
    def count(self) -> int:
        """Triangle count."""
        return int(self.idx.shape[0])

    @property
    def index_count(self) -> int:
        """Indices for ``glDrawElements``; see ``preview_scene.Batch.index_count``."""
        return int(self.idx.shape[0]) * 3


def fullscreen_quad() -> RawBatch:
    return RawBatch(
        [[-1, -1, 0, 1], [1, -1, 0, 1], [1, 1, 0, 1], [-1, 1, 0, 1]],
        np.tile([0, 0, 1], (4, 1)),
        [[0, 0], [1, 0], [1, 1], [0, 1]],
        np.ones((4, 4)),
        np.ones((4, 2)),
        [[0, 1, 2], [2, 3, 0]],
    )


def view_billboard(view_direction: np.ndarray, half_angle: float = 0.075, distance: float = 500.0) -> RawBatch:
    """A camera-facing quad placed in **view space** along ``view_direction``."""
    centre = view_direction * distance
    right = np.cross(view_direction, np.array([0.0, 1.0, 0.0]))
    right = np.array([1.0, 0.0, 0.0]) if np.linalg.norm(right) < 1e-6 else right / np.linalg.norm(right)
    up = np.cross(right, view_direction)
    half = distance * half_angle
    return RawBatch(
        [
            centre - right * half - up * half,
            centre + right * half - up * half,
            centre + right * half + up * half,
            centre - right * half + up * half,
        ],
        np.tile([0, 0, 1], (4, 1)),
        [[0, 0], [1, 0], [1, 1], [0, 1]],
        np.ones((4, 4)),
        np.ones((4, 2)),
        [[0, 1, 2], [2, 3, 0]],
    )


# --------------------------------------------------------------------------- #
# Camera and renderer
# --------------------------------------------------------------------------- #


@dataclass
class Camera:
    """A world-space eye plus Minecraft-style orientation.

    The default stands off the island's near corner rather than its far diagonal:
    Aurelia's fog is exponential, so framing from ~85 blocks away replaces a
    quarter to a half of every surface with fog colour and the grade cannot be
    judged at all.
    """

    eye: tuple[float, float, float] = (-26.0, 24.0, -30.0)
    yaw: float = np.pi * 0.25
    pitch: float = -0.16
    fov: float = 70.0

    @property
    def basis(self) -> np.ndarray:
        return camera_basis(self.yaw, self.pitch)

    @property
    def forward(self) -> np.ndarray:
        return self.basis[:, 2]

    def view(self) -> np.ndarray:
        """Camera-relative player space -> view space.

        Scene geometry is rebased to the eye before upload, so the view matrix is
        the camera rotation with no translation, matching Iris's player space.
        The third row is ``-forward``: OpenGL view space looks down ``-z``, so a
        point in front of the camera must yield a positive clip ``w``.
        """
        basis = self.basis
        m = identity()
        m[0, :3] = basis[:, 0]
        m[1, :3] = basis[:, 1]
        m[2, :3] = -basis[:, 2]
        return m

    def model_view_inverse(self) -> np.ndarray:
        """Player space -> world, the exact inverse of :meth:`view`.

        Translation-free on purpose. Iris hands the vertex stage a
        *camera-relative* position, so view() is rotation-only and this is its
        exact inverse. Leaving the eye in the translation column silently makes
        ``playerPosition`` come out as an absolute world position, which breaks
        two things at once: any view-vector term in a fragment shader is handed
        a world direction instead of a view direction, and the pack's shadow
        receiver projects absolute coordinates while the caster pass renders
        camera-relative ones, so every receiver reads as fully lit.

        The pack reads only the rotation part of this matrix for direction work,
        so the matrix is built exactly only so the uniform can be checked
        against view().
        """
        basis = self.basis
        m = identity()
        # Columns are [right, up, -forward]: negating the third basis column is
        # what inverts the -forward third row of view().
        m[:3, :3] = basis * np.array([1.0, 1.0, -1.0])
        return m


class PreviewRenderer:
    def __init__(
        self,
        shaders_root: Path,
        width: int = 960,
        height: int = 540,
        overrides: dict[str, str] | None = None,
        undefined: set[str] | None = None,
        frame_time: float = 12.0,
        underwater_eye: bool = False,
    ) -> None:
        self.shaders_root = shaders_root
        self.width, self.height = width, height
        self.overrides = dict(overrides or {})
        self.undefined = set(undefined or set())
        # Continuous seconds fed to Iris's frameTimeCounter. Fixed by default so
        # existing preview evidence stays byte-for-byte reproducible.
        self.frame_time = float(frame_time)
        # Iris's isEyeInWater: 1 when the camera is submerged in water, 2 in
        # lava, 0 in air. Off by default so every existing command keeps the
        # 0 state and its evidence stays reproducible; only an explicit
        # --underwater-eye (or a direct constructor call) sets water. The pack
        # reads it only under AURELIA_WATER_UNDERWATER, so setting it while the
        # option is compiled out is a harmless no-op.
        self.underwater_eye = bool(underwater_eye)
        self.context = Context(width, height)
        self._programs: dict[str, Program] = {}
        self._geometry: dict[tuple, tuple[int, int, int]] = {}
        # AURELIA_SHADOWS is defined in lib/options.glsl and removed by a preset
        # via !AURELIA_SHADOWS, so its absence here is the disabled state.
        self.shadows_enabled = "AURELIA_SHADOWS" not in self.undefined
        self.shadow_resolution = int(self.overrides.get("AURELIA_SHADOW_RESOLUTION", "1024"))
        self.shadow_distance = float(self.overrides.get("AURELIA_SHADOW_DISTANCE", "96"))
        # Colour targets are derived from the pack's own directives, not assumed.
        self.target_configs = collect_target_configs(shaders_root)
        if 0 not in self.target_configs:
            raise RuntimeError("pack declares no colortex0 target")
        self._targets: dict[int, tuple[int, int, int, int]] = {}
        self.scene_fbo, self.scene_color, self.scene_depth = _make_scene_target(
            self.target_configs[0], width, height
        )
        self._targets[0] = (self.scene_fbo, self.scene_color, width, height)
        self.shadow_fbo, self.shadow_depth = _make_shadow_target(self.shadow_resolution)
        # Iris's shadowHardwareFiltering: depth compare (receiver <= stored)
        # with bilinear filtering. Applied only where a program declares the
        # sampler as sampler2DShadow; see Program.sampler.
        self.shadow_compare_sampler = glGenSamplers(1)
        glSamplerParameteri(self.shadow_compare_sampler, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE)
        glSamplerParameteri(self.shadow_compare_sampler, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL)
        glSamplerParameteri(self.shadow_compare_sampler, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
        glSamplerParameteri(self.shadow_compare_sampler, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
        glSamplerParameteri(self.shadow_compare_sampler, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glSamplerParameteri(self.shadow_compare_sampler, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        # A standalone copy of the opaque depth, blitted between the opaque pass
        # and the water pass so gbuffers_water can read the floor behind the
        # water as Iris's depthtex1 (the pre-translucent copy; depthtex0 is
        # live during translucents). Allocated once, reused every frame.
        self.depth_copy_fbo, self.depth_copy = _make_depth_only_target(width, height)

    def _target(self, index: int) -> tuple[int, int, int, int]:
        """The (fbo, colour, width, height) for a colour target, allocated lazily."""
        if index not in self._targets:
            config = self.target_configs.get(index)
            if config is None:
                raise RuntimeError(f"colortex{index} is not declared by the pack")
            width, height = config.size(self.width, self.height)
            fbo, color = _make_color_target(config, width, height)
            self._targets[index] = (fbo, color, width, height)
        return self._targets[index]

    def program(self, name: str) -> Program:
        if name not in self._programs:
            vertex = build_source(self.shaders_root, name, "vsh", self.overrides, self.undefined)
            fragment = build_source(self.shaders_root, name, "fsh", self.overrides, self.undefined)
            self._programs[name] = Program(vertex, fragment, name)
        return self._programs[name]

    def close(self) -> None:
        for vao, vbo, ibo, _ in self._geometry.values():
            glDeleteVertexArrays(1, [vao])
            glDeleteBuffers(2, [vbo, ibo])
        self._geometry.clear()
        for fbo, color, _, _ in self._targets.values():
            glDeleteFramebuffers(1, [fbo])
            glDeleteTextures(1, [color])
        self._targets.clear()
        if self.scene_depth:
            glDeleteTextures(1, [self.scene_depth])
        glDeleteFramebuffers(1, [self.depth_copy_fbo])
        glDeleteTextures(1, [self.depth_copy])
        glDeleteFramebuffers(1, [self.shadow_fbo])
        glDeleteTextures(1, [self.shadow_depth])
        glDeleteSamplers(1, [self.shadow_compare_sampler])
        for program in self._programs.values():
            program.dispose()
        self.context.close()

    # -- uniforms ---------------------------------------------------------- #

    def _common_uniforms(self, camera: Camera, sky: Sky, adaptive: float) -> dict[str, object]:
        # World -> view is the view matrix's rotation, not basis.T: the view
        # rotation is basis with its third axis negated. Using basis.T here makes
        # gbufferModelViewInverse fail to invert it, so every direction the pack
        # reconstructs from these uniforms comes back mirrored.
        to_view = camera.view()[:3, :3]
        # Iris documents sunPosition/moonPosition/shadowLightPosition as view
        # space with length 100; the pack rotates each by gbufferModelViewInverse
        # before treating it as a world vector.
        sun_view = (to_view @ sky.sun_direction) * 100.0
        return {
            "gbufferModelViewInverse": camera.model_view_inverse(),
            "sunPosition": sun_view,
            "moonPosition": (to_view @ sky.moon_direction) * 100.0,
            "shadowLightPosition": (to_view @ sky.shadow_light_direction) * 100.0,
            "skyColor": sky.sky_color,
            "fogColor": sky.fog_color,
            "rainStrength": float(sky.rain),
            "cameraPosition": np.asarray(camera.eye, np.float32),
            "aureliaAdaptiveQuality": float(adaptive),
            "aureliaSmoothedFrameTime": 0.0165,
            # Continuous seconds; the distant-rain curtain animates from this,
            # and water animation will read it too. The value is settable so a
            # motion preview can step it; the default keeps previews fixed and
            # therefore deterministic.
            "frameTimeCounter": self.frame_time,
            "aureliaAdaptiveShadowFilterSamples": 1.0 + 8.0 * float(adaptive),
            "alphaTestRef": 0.1,
            "entityColor": np.zeros(4, np.float32),
            # Iris's camera submersion state. 0 (air) by default; 1 (water) only
            # when this renderer was built for an underwater shot. The pack
            # declares and reads it only under AURELIA_WATER_UNDERWATER, so this
            # is a no-op everywhere else.
            "isEyeInWater": 1 if self.underwater_eye else 0,
        }

    # -- frame ------------------------------------------------------------- #

    def render(
        self,
        batches: dict,
        atlas: np.ndarray,
        camera: Camera,
        sky: Sky,
        adaptive: float = 0.7,
        draw_sky: bool = True,
    ) -> tuple[np.ndarray, dict[str, float]]:
        common = self._common_uniforms(camera, sky, adaptive)
        view = camera.view()
        projection = perspective(camera.fov, self.width / self.height, _NEAR, _FAR)
        # The sky stage rebuilds its ray from the pixel through the inverse
        # projection (Iris's gbuffers_skybasic convention), so these must be
        # present exactly as Iris provides them.
        common["gbufferProjectionInverse"] = np.linalg.inv(projection)
        common["viewWidth"] = float(self.width)
        common["viewHeight"] = float(self.height)
        eye = np.asarray(camera.eye, np.float32)
        light = self._light_matrices(camera, sky) if self.shadows_enabled else None

        atlas_texture = _make_rgba_texture(atlas.shape[1], atlas.shape[0], atlas)
        sun = _make_rgba_texture(128, 128, sun_texture())
        moon = _make_rgba_texture(128, 128, moon_texture())
        clouds = _make_rgba_texture(512, 512, clouds_texture())

        started = time.perf_counter()
        if self.shadows_enabled:
            self._render_shadow(batches, light, atlas_texture, eye, sky)
        self._render_scene(batches, camera, sky, common, view, projection, light, eye, atlas_texture, sun, moon, clouds, draw_sky)
        image = self._run_composite_passes(common)
        glFinish()
        elapsed_ms = (time.perf_counter() - started) * 1000.0

        for texture in (atlas_texture, sun, moon, clouds):
            glDeleteTextures(1, [texture])
        stats = {
            "frame_ms": elapsed_ms,
            "shadow": 1.0 if self.shadows_enabled else 0.0,
            "shadow_resolution": float(self.shadow_resolution),
        }
        return image, stats

    def _light_matrices(self, camera: Camera, sky: Sky) -> tuple[np.ndarray, np.ndarray]:
        """The orthographic light camera Iris 1.7 builds (ShadowMatrices).

        Centred on the eye, looking along shadowLightPosition from 100 blocks
        out, half-extent = shadowDistance, near 0.05, far 256. An earlier
        version used half the extent, which doubled texel density and hid
        shadow acne the game shows; it also never switched to the moon.
        """
        direction = sky.shadow_light_direction
        centre = np.zeros(3)
        up = np.array([0.0, 1.0, 0.0])
        if abs(float(direction @ up)) > 0.999:
            up = np.array([0.0, 0.0, 1.0])
        half = float(self.shadow_distance)
        return (
            look_at(centre + direction * 100.0, centre, up),
            ortho(-half, half, -half, half, 0.05, 256.0),
        )

    def _render_shadow(self, batches: dict, light, atlas: int, eye: np.ndarray, sky: Sky) -> None:
        light_view, light_projection = light
        program = self.program("shadow")
        glBindFramebuffer(GL_FRAMEBUFFER, self.shadow_fbo)
        glViewport(0, 0, self.shadow_resolution, self.shadow_resolution)
        glEnable(GL_DEPTH_TEST)
        glDepthFunc(GL_LEQUAL)
        glDepthMask(GL_TRUE)
        glDisable(GL_BLEND)
        glEnable(GL_CULL_FACE)
        # The pack biases on the receiver rather than the caster, so casters keep
        # their back faces here.
        glCullFace(GL_BACK)
        glClearDepth(1.0)
        glClear(GL_DEPTH_BUFFER_BIT)
        program.use()
        program.set("alphaTestRef", 0.1)
        program.sampler("gtexture", 0, atlas)
        for name in ("opaque", "cutout"):
            batch = batches[name]
            if batch.count:
                self._bind(program, batch, light_view, light_projection, eye, sky.daylight)
                glDrawElements(GL_TRIANGLES, batch.index_count, GL_UNSIGNED_INT, ctypes.c_void_p(0))

    def _snapshot_depth(self) -> int:
        """Blit the opaque-pass depth into the standalone depth texture.

        Called after the opaque/cutout pass and before water, so the water
        program reads the terrain floor depth behind the water surface. This
        blit is the harness equivalent of Iris's pre-translucent copy, bound
        as ``depthtex1`` (``depthtex0`` is live during translucents and is not
        what the water program reads).
        """
        glBindFramebuffer(GL_READ_FRAMEBUFFER, self.scene_fbo)
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, self.depth_copy_fbo)
        glBlitFramebuffer(
            0, 0, self.width, self.height,
            0, 0, self.width, self.height,
            GL_DEPTH_BUFFER_BIT, GL_NEAREST,
        )
        # Restore the scene target: this runs mid-scene, and the caller keeps
        # drawing into it. Leaving the default framebuffer bound here silently
        # sends the water and cloud passes to the window instead of colortex0.
        glBindFramebuffer(GL_FRAMEBUFFER, self.scene_fbo)
        return self.depth_copy

    def _render_scene(
        self, batches, camera, sky, common, view, projection, light, eye, atlas, sun, moon, clouds, draw_sky
    ) -> None:
        glBindFramebuffer(GL_FRAMEBUFFER, self.scene_fbo)
        glViewport(0, 0, self.width, self.height)
        # The pack declares colortex0ClearColor = black, so Iris's default sRGB
        # fog clear never enters the linear scene.
        glClearColor(0.0, 0.0, 0.0, 1.0)
        glClearDepth(1.0)
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

        if draw_sky:
            self._draw_sky(self.program("gbuffers_skybasic"), common, view, projection)
            self._draw_sun_moon(self.program("gbuffers_skytextured"), sun, moon, camera, projection, sky)

        terrain = self.program("gbuffers_terrain")
        for name in ("opaque", "cutout"):
            batch = batches[name]
            if batch.count:
                self._draw_geometry(terrain, batch, camera, common, view, projection, light, eye, atlas, sky)

        water = batches["water"]
        if water.count:
            water_program = self.program("gbuffers_water")
            # Snapshot the opaque depth only when the water program actually
            # reads depthtex1 (AURELIA_WATER_DEPTH). With the option compiled
            # out the uniform is stripped, so the default path pays no copy.
            depth_texture = None
            if water_program.location("depthtex1") is not None:
                depth_texture = self._snapshot_depth()
            self._draw_geometry(
                water_program,
                water,
                camera,
                common,
                view,
                projection,
                light,
                eye,
                atlas,
                sky,
                blend=True,
                depth_write=False,
                alpha_test=0.0,
                depth_texture=depth_texture,
            )

        # The pack's own cloud pass on real cloud geometry: same upload path,
        # same fog contract, so the vanilla-slab criticism can be judged
        # against what gbuffers_clouds actually produces.
        self._draw_clouds(common, view, projection, eye, sky, clouds)

    def _draw_clouds(self, common, view, projection, eye, sky, clouds) -> None:
        program = self.program("gbuffers_clouds")
        glEnable(GL_DEPTH_TEST)
        glDepthFunc(GL_LEQUAL)
        glDepthMask(GL_FALSE)
        glEnable(GL_BLEND)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        # The plane is top-facing; underwater and ground cameras see its
        # underside, so both faces must draw.
        glDisable(GL_CULL_FACE)
        program.use()
        for name, value in common.items():
            program.set(name, value)
        program.set("alphaTestRef", 0.0)
        program.sampler("gtexture", 0, clouds)
        batch = clouds_layer()
        self._bind(program, batch, view, projection, eye, sky.daylight)
        glDrawElements(GL_TRIANGLES, batch.index_count, GL_UNSIGNED_INT, ctypes.c_void_p(0))

    def _draw_sky(self, program: Program, common: dict, view: np.ndarray, projection: np.ndarray) -> None:
        glDisable(GL_DEPTH_TEST)
        glDepthMask(GL_FALSE)
        glDisable(GL_BLEND)
        glDisable(GL_CULL_FACE)
        program.use()
        for name, value in common.items():
            program.set(name, value)
        # A real skybox, not a fullscreen quad: the program reads its direction
        # from the player-space position, which only carries meaning on geometry
        # that surrounds the camera.
        box = skybox()
        self._bind(program, box, view, projection, None, 1.0)
        glDrawElements(GL_TRIANGLES, box.index_count, GL_UNSIGNED_INT, ctypes.c_void_p(0))

    def _draw_sun_moon(self, program, sun, moon, camera: Camera, projection: np.ndarray, sky: Sky) -> None:
        glEnable(GL_BLEND)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        glDisable(GL_DEPTH_TEST)
        glDepthMask(GL_FALSE)
        glDisable(GL_CULL_FACE)
        program.use()
        view_space = camera.view()[:3, :3]
        # Iris's renderStage: MC_RENDER_STAGE_SUN = 4, MC_RENDER_STAGE_MOON = 5.
        for texture, world_direction, stage in ((sun, sky.sun_direction, 4), (moon, sky.moon_direction, 5)):
            # Skip a body that has set below the horizon. View space looks down
            # -z, so a direction in front of the camera has a *negative* z: the
            # test has to be >=, not <=, or it discards everything visible.
            if world_direction[1] < -0.12:
                continue
            view_direction = view_space @ world_direction
            if view_direction[2] >= -0.02:
                continue
            program.sampler("gtexture", 0, texture)
            program.set("renderStage", stage)
            # The billboard is built in view space, so only the projection applies.
            quad = view_billboard(view_direction)
            self._bind(program, quad, identity(), projection, None, 1.0)
            glDrawElements(GL_TRIANGLES, quad.index_count, GL_UNSIGNED_INT, ctypes.c_void_p(0))

    def _draw_geometry(
        self,
        program: Program,
        batch,
        camera: Camera,
        common: dict,
        view: np.ndarray,
        projection: np.ndarray,
        light,
        eye: np.ndarray,
        atlas: int,
        sky: Sky,
        blend: bool = False,
        depth_write: bool = True,
        alpha_test: float = 0.1,
        depth_texture: int | None = None,
    ) -> None:
        glEnable(GL_DEPTH_TEST)
        glDepthFunc(GL_LEQUAL)
        glDepthMask(GL_TRUE if depth_write else GL_FALSE)
        glEnable(GL_CULL_FACE)
        glCullFace(GL_BACK)
        if blend:
            glEnable(GL_BLEND)
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        else:
            glDisable(GL_BLEND)
        program.use()
        for name, value in common.items():
            program.set(name, value)
        program.set("alphaTestRef", alpha_test)
        program.sampler("gtexture", 0, atlas)
        if light is not None:
            program.set("shadowModelView", light[0])
            program.set("shadowProjection", light[1])
            program.sampler("shadowtex0", 1, self.shadow_depth, self.shadow_compare_sampler)
        if depth_texture is not None:
            # Iris's depthtex1 is the pre-translucent opaque copy. Bound on unit
            # 2 to leave the atlas (0) and shadow map (1) where they are.
            program.sampler("depthtex1", 2, depth_texture)
        self._bind(program, batch, view, projection, eye, sky.daylight)
        glDrawElements(GL_TRIANGLES, batch.index_count, GL_UNSIGNED_INT, ctypes.c_void_p(0))

    # -- geometry upload --------------------------------------------------- #

    def _bind(
        self,
        program: Program,
        batch,
        view: np.ndarray,
        projection: np.ndarray,
        eye: np.ndarray | None,
        daylight: float,
    ) -> None:
        """Set the shimmed vertex uniforms and bind this batch's VAO."""
        program.set("aureliaViewMatrix", view)
        program.set("aureliaProjectionViewMatrix", projection @ view)
        program.set("aureliaNormalMatrix", normal_matrix(view))
        program.set("aureliaTextureMatrix0", identity())
        program.set("aureliaTextureMatrix1", identity())
        vao, _, _ = self._geometry_for(batch, eye, daylight)
        glBindVertexArray(vao)

    def _geometry_for(self, batch, eye: np.ndarray | None, daylight: float) -> tuple[int, int, int]:
        # The uploaded positions are rebased onto the eye (see _upload_batch),
        # so the eye VALUE is part of the key: keying only on `eye is None`
        # reused viewpoint N's eye-relative VAO for viewpoint N+1, rendering
        # every contact-sheet tile after the first from a wrong eye position.
        eye_key = None if eye is None else (float(eye[0]), float(eye[1]), float(eye[2]))
        key = (id(batch), round(float(daylight), 4), eye_key)
        if key in self._geometry:
            return self._geometry[key][0], self._geometry[key][1], self._geometry[key][2]

        position, normal, uv, color, lightmap, index = _upload_batch(batch, eye, daylight)
        vao, vbo, ibo = _create_buffers(position, normal, uv, color, lightmap, index)
        # Hold a reference to the batch: a temporary batch passed inline is freed
        # straight after this call, and CPython recycles ids, which would let a
        # later unrelated batch collide with this cache entry.
        self._geometry[key] = (vao, vbo, ibo, batch)
        return vao, vbo, ibo

    def _run_composite_passes(self, common: dict) -> np.ndarray:
        """Run every composite-style program the pack ships, in Iris order.

        ``final`` outputs to the default framebuffer and is the image returned.
        Any earlier pass (``deferred``/``composite*``) outputs to its declared
        RENDERTARGETS. A pack with no composite-style program, or one whose last
        pass is not ``final``, cannot produce a display image.
        """
        passes = composite_passes_present(self.shaders_root)
        if not passes:
            raise RuntimeError("pack ships no composite-style pass (final.vsh/.fsh required)")
        if passes[-1] != "final":
            raise RuntimeError(f"pack ships composite passes but no final: {passes}")
        image: np.ndarray | None = None
        for name in passes:
            image = self._run_composite_pass(name, common)
        assert image is not None
        return image

    def _run_composite_pass(self, name: str, common: dict) -> np.ndarray | None:
        is_final = name == "final"
        if is_final:
            glBindFramebuffer(GL_FRAMEBUFFER, 0)
            glViewport(0, 0, self.width, self.height)
        else:
            targets = parse_render_targets(
                (self.shaders_root / f"{name}.fsh").read_text(encoding="utf-8")
            )
            if not targets:
                raise RuntimeError(f"{name}.fsh declares no RENDERTARGETS")
            fbo, _, width, height = self._target(targets[0])
            glBindFramebuffer(GL_FRAMEBUFFER, fbo)
            glViewport(0, 0, width, height)

        glDisable(GL_DEPTH_TEST)
        glDepthMask(GL_TRUE)
        glDisable(GL_BLEND)
        glDisable(GL_CULL_FACE)
        program = self.program(name)
        program.use()
        for uniform_name, value in common.items():
            program.set(uniform_name, value)
        self._bind_composite_samplers(program)
        quad = fullscreen_quad()
        self._bind(program, quad, identity(), identity(), None, 1.0)
        glDrawElements(GL_TRIANGLES, quad.index_count, GL_UNSIGNED_INT, ctypes.c_void_p(0))
        return _read_pixels(self.width, self.height) if is_final else None

    def _bind_composite_samplers(self, program: Program) -> None:
        """Bind every colour target and depth/shadow texture a pass may read."""
        unit = 0
        for index in sorted(self._targets):
            program.sampler(f"colortex{index}", unit, self._targets[index][1])
            unit += 1
        program.sampler("depthtex0", unit, self.scene_depth)
        unit += 1
        if self.shadows_enabled:
            program.sampler("shadowtex0", unit, self.shadow_depth, self.shadow_compare_sampler)
            unit += 1
            # Iris's shadowtex1 is the opaque-caster map; with
            # shadowTranslucent = false it holds the same depth as shadowtex0.
            program.sampler("shadowtex1", unit, self.shadow_depth)


def _read_pixels(width: int, height: int) -> np.ndarray:
    raw = glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE)
    image = np.frombuffer(raw, np.uint8).reshape(height, width, 4)
    # The GL origin is bottom-left; image files are top-left.
    return np.ascontiguousarray(np.flipud(image))


def _upload_batch(batch, eye: np.ndarray | None, daylight: float):
    """Return the interleaved arrays in ``VERTEX_UPLOAD`` order."""
    position = np.asarray(batch.pos, np.float32)
    if eye is not None:
        # Rebase world space onto the camera: Iris hands shaders player space.
        position = position - eye
    # Scale the *target* light level, then invert the pack's packing formula.
    # Scaling the already-packed value would shift the constant term too.
    target = np.asarray(batch.lm, np.float32).copy()
    target[:, 1] *= daylight
    arrays = {
        "position": position,
        "normal": np.asarray(batch.nrm, np.float32),
        "color": np.asarray(batch.col, np.float32),
        "texcoord0": np.asarray(batch.uv, np.float32),
        "texcoord1": (target + _LIGHT_BIAS) * _LIGHT_DIVISOR,
    }
    resolved = [np.ascontiguousarray(arrays[name], np.float32) for name in VERTEX_UPLOAD]
    return tuple(resolved) + (np.ascontiguousarray(batch.idx, np.uint32),)


def _create_buffers(*arrays) -> tuple[int, int, int]:
    """Build a VAO from position, normal, color, texcoord0, texcoord1, index.

    The interleaved layout is positional: a wrong component count on any array
    shifts the ones after it and yields garbage geometry with no GL error. The
    component counts come from ``VERTEX_UPLOAD_COMPONENTS``, the same declaration
    the vertex prelude is generated from, and each array is checked regardless.
    """
    if len(VERTEX_UPLOAD) != len(VERTEX_UPLOAD_COMPONENTS):
        raise ValueError("VERTEX_UPLOAD and VERTEX_UPLOAD_COMPONENTS disagree in length")
    if len(arrays) != len(VERTEX_UPLOAD) + 1:
        raise ValueError(f"expected {len(VERTEX_UPLOAD) + 1} arrays, got {len(arrays)}")
    named = dict(zip(VERTEX_UPLOAD, arrays[:-1]))
    index = arrays[-1]
    rows = named["position"].shape[0]
    for name, components in zip(VERTEX_UPLOAD, VERTEX_UPLOAD_COMPONENTS):
        if named[name].shape != (rows, components):
            raise ValueError(
                f"{name} must be ({rows}, {components}) for the interleaved layout, "
                f"got {named[name].shape}"
            )
    if index.ndim != 2 or index.shape[1] != 3:
        raise ValueError(f"index must be (M, 3), got {index.shape}")

    vao = glGenVertexArrays(1)
    vbo = glGenBuffers(1)
    ibo = glGenBuffers(1)
    glBindVertexArray(vao)
    glBindBuffer(GL_ARRAY_BUFFER, vbo)
    stride = sum(VERTEX_UPLOAD_COMPONENTS) * 4
    data = np.concatenate([named[name] for name in VERTEX_UPLOAD], axis=1).astype(np.float32)
    glBufferData(GL_ARRAY_BUFFER, data.nbytes, data, GL_STATIC_DRAW)
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo)
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, index.nbytes, index, GL_STATIC_DRAW)
    offset = 0
    for location, components in enumerate(VERTEX_UPLOAD_COMPONENTS):
        glEnableVertexAttribArray(location)
        glVertexAttribPointer(location, components, GL_FLOAT, GL_FALSE, stride, ctypes.c_void_p(offset))
        offset += components * 4
    glBindVertexArray(0)
    return vao, vbo, ibo
