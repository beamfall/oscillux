// SPDX-License-Identifier: AGPL-3.0-only
// CD+G lyric composite (OSC-CDG): functions a host's present pass calls to lay the CD+G window
// over the tone-mapped visual. Shared source for GLSL ES 3.00 (WebGL2) and GLSL 450 (SPIR-V to
// Metal): no #version, precision or resource declarations here; the including pass supplies them
// and defines OSC_CDG_FETCH(cell), the window texel at an ivec2 cell (texelFetch(tex, cell, 0)).
// A macro, not a sampler parameter: GLSL 450 for Vulkan builds a combined sampler from a separate
// texture and sampler only at its point of use, so it cannot be passed to a function.
// tools/shader/cdg-check.mjs compiles it for both and measures the contrast bar headlessly.
//
// oscCdgComposite(bg, frag, outSize, place, halo) returns vec4(rgb, lyric alpha):
//   bg       the visual at this pixel after the tone map: display-referred, sRGB-encoded, 0..1.
//   frag     the output pixel centre in pixels, origin top-left, y down (WebGL callers pass
//            vec2(gl_FragCoord.x, outSize.y - gl_FragCoord.y)).
//   outSize  the output size in pixels.
//   OSC_CDG_FETCH reads the 288 x 192 RGBA8 window from oscillux_cdg_window_rgba (straight
//            alpha), uploaded rows top to bottom so texel (0, 0) is the window's top-left.
//   place    host data for the layout: x fit (0 contain: the whole window, letterboxed; 1 cover:
//            fill and crop; 2 stretch), y the window's display aspect width / height (1.5 for
//            square pixels, 4/3 for the 4:3 TV picture), z 1 to snap a contain scale of 1 or more
//            down to whole output pixels per CD+G row. Outside the window the visual shows.
//   halo     x the contrast target (4.5 for WCAG AA), y the feather width in output pixels,
//            z 1 to enable the halo.
//
// Upscaling is nearest-neighbour (sharp pixel art). The transparency key is whatever alpha the
// host asked oscillux_cdg_window_rgba for; keyed (alpha 0) pixels show bg. The halo clamps the
// relative luminance of bg near lyric pixels: within OSC_CDG_CORE output pixels of an opaque
// lyric pixel it is held to at most (L + 0.05) / T - 0.05 next to a light colour and at least
// T (L + 0.05) - 0.05 next to a dark one (T the target times OSC_CDG_MARGIN, which absorbs 8-bit
// rounding; L the lyric colour's WCAG relative luminance, light when L >= 0.17913, where black
// and white give equal contrast), so every lyric pixel reaches the target against every
// background pixel it touches. Beyond the core the clamp fades out over the feather width. A
// background pixel within reach of both a light and a dark lyric colour takes the clamp of the
// nearer one, the light one's at equal distance: next to an outlined letter (a downloaded
// karaoke screen's white or coloured fill inside a black outline) the outline it touches decides,
// not the fill behind it. Pixels the halo does not reach are returned exactly as bg.

const int OSC_CDG_WINDOW_W = 288;
const int OSC_CDG_WINDOW_H = 192;
// Neighbourhood searched for the halo, in CD+G pixels each side: (2 R + 1)^2 texel reads.
const int OSC_CDG_HALO_CELLS = 3;
// Distance in output pixels within which the clamp is at full strength: covers every pixel that
// touches a lyric pixel, diagonals included.
const float OSC_CDG_CORE = 1.5;
const float OSC_CDG_MARGIN = 1.03;
const float OSC_CDG_LIGHT = 0.17913;

vec3 oscCdgLinear(vec3 c) {
  return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 oscCdgEncode(vec3 c) {
  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

float oscCdgLuminance(vec3 srgb) {
  return dot(oscCdgLinear(srgb), vec3(0.2126, 0.7152, 0.0722));
}

// The window's placement: xy its top-left in output pixels, zw output pixels per CD+G pixel.
vec4 oscCdgPlacement(vec2 outSize, vec4 place) {
  float aspect = place.y > 0.0 ? place.y : 1.5;
  vec2 disp = outSize;
  if (place.x < 1.5) {
    float h = place.x > 0.5 ? max(outSize.x / aspect, outSize.y) : min(outSize.x / aspect, outSize.y);
    disp = vec2(h * aspect, h);
  }
  vec2 window = vec2(float(OSC_CDG_WINDOW_W), float(OSC_CDG_WINDOW_H));
  vec2 scale = disp / window;
  if (place.z > 0.5 && place.x < 0.5 && scale.y >= 1.0) scale *= floor(scale.y) / scale.y;
  return vec4(floor((outSize - scale * window) * 0.5), scale);
}

bool oscCdgInside(ivec2 cell) {
  return cell.x >= 0 && cell.y >= 0 && cell.x < OSC_CDG_WINDOW_W && cell.y < OSC_CDG_WINDOW_H;
}

vec4 oscCdgComposite(vec3 bg, vec2 frag, vec2 outSize, vec4 place, vec4 halo) {
  vec4 pl = oscCdgPlacement(outSize, place);
  vec2 origin = pl.xy;
  vec2 scale = pl.zw;
  ivec2 cell = ivec2(floor((frag - origin) / scale));
  vec4 lyric = oscCdgInside(cell) ? OSC_CDG_FETCH(cell) : vec4(0.0);
  vec3 back = clamp(bg, 0.0, 1.0);
  if (halo.z > 0.5 && lyric.a < 1.0) {
    float target = max(halo.x, 1.0) * OSC_CDG_MARGIN;
    float reach = float(OSC_CDG_HALO_CELLS) * min(scale.x, scale.y);
    float feather = clamp(halo.y, 0.0, max(reach - OSC_CDG_CORE, 0.0));
    float lo = 0.0;
    float hi = 1.0;
    float nearLight = 1e9;
    float nearDark = 1e9;
    for (int dy = -OSC_CDG_HALO_CELLS; dy <= OSC_CDG_HALO_CELLS; dy++) {
      for (int dx = -OSC_CDG_HALO_CELLS; dx <= OSC_CDG_HALO_CELLS; dx++) {
        ivec2 n = cell + ivec2(dx, dy);
        if (!oscCdgInside(n)) continue;
        vec4 t = OSC_CDG_FETCH(n);
        if (t.a <= 0.0) continue;
        vec2 rmin = origin + vec2(n) * scale;
        float d = length(max(max(rmin - frag, frag - (rmin + scale)), vec2(0.0)));
        float w = d <= OSC_CDG_CORE ? 1.0
          : feather > 0.0 ? 1.0 - smoothstep(OSC_CDG_CORE, OSC_CDG_CORE + feather, d) : 0.0;
        w *= t.a;
        float l = oscCdgLuminance(t.rgb);
        if (l >= OSC_CDG_LIGHT) {
          hi = min(hi, mix(1.0, max((l + 0.05) / target - 0.05, 0.0), w));
          nearLight = min(nearLight, d);
        } else {
          lo = max(lo, mix(0.0, min(target * (l + 0.05) - 0.05, 1.0), w));
          nearDark = min(nearDark, d);
        }
      }
    }
    if (nearDark < nearLight) hi = max(hi, lo);
    else lo = min(lo, hi);
    vec3 lin = oscCdgLinear(back);
    float y = dot(lin, vec3(0.2126, 0.7152, 0.0722));
    if (y > hi) back = oscCdgEncode(lin * (hi / y));
    else if (y < lo) back = oscCdgEncode(mix(lin, vec3(1.0), (lo - y) / (1.0 - y)));
  }
  return vec4(mix(back, lyric.rgb, lyric.a), lyric.a);
}
