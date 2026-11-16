// SPDX-License-Identifier: AGPL-3.0-only
// CD+G lyric layer for the present pass's host layer (shaders/present/present.glsl, "Optional
// host layer"). tools/shader/cdg-layer.mjs places it after cdg-composite.glsl, with
// OSC_CDG_FETCH reading the layer texture, and the reference hosts draw the result as their
// lyric present pass. The layer texture is the window from oscillux_cdg_window_rgba, its block:
//   pl.layer[0].xy  the output size in pixels
//   pl.layer[1]     place: fit, display aspect and integer snap (cdg-composite.glsl)
//   pl.layer[2]     halo: contrast target, feather in output pixels and enable
// The pass hands the layer display-linear light and the composite works on sRGB-encoded values,
// so the layer encodes the visual, composites, and decodes the result.

vec3 oscillux_present_layer(vec2 uv, vec3 c) {
  vec2 size = pl.layer[0].xy;
  vec4 r = oscCdgComposite(oscCdgEncode(clamp(c, 0.0, 1.0)), uv * size, size, pl.layer[1], pl.layer[2]);
  return oscCdgLinear(r.rgb);
}
