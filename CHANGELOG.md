<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Changelog

Notable changes to the C interface (`ffi/include/oscillux.h`) and to behavior a host can
observe through it. The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versions and deprecations follow [docs/api-stability.md](docs/api-stability.md).

0.2.0 is the first release published in this repository. `OSCILLUX_ABI_VERSION` is 1, and every
addition below kept ABI version 1: no existing signature, struct layout or status value changed.

## [Unreleased]

### Changed

- `ReactionSampler` holds the beat follower across backward sample-time jitter up to
  `HOLD_BACK_MS` (`100` ms) unless a resync flag is active or a newly set host `BeatClock`
  targets an earlier time, and tracker-mode resynchronisations land on the whole beat nearest
  the reached position rather than `floor(prev) + frac(target)` so beat position never steps
  backwards (CORE-3277, openspec/changes/beat-follower-continuous/).

## [0.2.22] - 2026-11-24

### Added

- Every catalog visual carries measured photosensitivity data (CORE-3417,
  openspec/changes/catalog-safety/): a `safety` block in `shaders/manifest.json` and each leg's
  `catalog.json` with `maxFlashHz`, `maxRedFlashHz`, `maxLuminanceDelta` and `textSafeZone`,
  measured from the shipped bodies through the present pass under loud audio.
  `make visual-safety-check` fails a visual whose measures exceed its declared data, whose text
  band is not dark and steady, or that was not measured. Spatial patterns are not measured yet:
  hosts must not read the block as a pattern clearance. The `android-gles` contract does not
  carry the block yet.

## [0.2.21] - 2026-11-23

### Added

- Cover Drift joins the release catalog (CORE-3286, openspec/changes/cover-drift-visual/): a
  calm, `lite`, `image + level` background visual (`cover-drift`, `visual.cover-drift.*`)
  modelling blurred album cover colours drifting and rotating slowly behind white player text.
  The legs and `catalog.json` now carry 63 visuals.

### Changed

- Fractal Flight moves colour, not brightness (CORE-3272, openspec/changes/fractal-flight-steady/).
  Every window pane sits at one luminance, so the panes turn through the palette with the bars and
  a beat swings them toward a contrasting palette colour without flashing. The sun shafts fade out in
  the air just in front of the camera, which every pixel shares, and a steady haze tinted from the
  palette keeps the frame as bright as before. The lace's beat wave recolours it at its own
  luminance. The pace follows the 32-beat flight profile, kept under twice cruise up to 240 BPM. In
  the loud-audio limiter audit the frame limiter now holds 1% of the frame on average instead of
  9%, and 12% at most instead of 31%. Fractal Flight is an original outside the release catalog, so
  this changes no release leg.
- Neon Run, Space Flight and Ocean Glide hold their light steady (CORE-3273..3275,
  openspec/changes/flights-steady/). Neon Run's lights are recoloured at a fixed luminance and its
  window grid, billboards and traffic are filtered over the pixel footprint and the frame's travel.
  Space Flight's streaks and stars are never thinner than a pixel, the treble swings star tint
  instead of brightening the field, and its rings are filtered over the pixel footprint. Ocean
  Glide's water luminance is held to the calm mirror with the sun's pinpoint glints on top. Under
  loud audio the limiter holds about half as much of the frame on average, or less. These are originals
  outside the release catalog, so this changes no release leg.

## [0.2.20] - 2026-11-22

### Added

- Disco Floor joins the release catalog (CORE-3263, openspec/changes/disco-floor-catalog/): a
  flagship, frequency + beat scene, last in `catalogOrder`, with Glow, Sway and Sparkle controls
  (`visual.disco-floor.*`). The legs and `catalog.json` now carry 62 visuals.

### Changed

- Disco Floor moves colour, not brightness (CORE-3263). Its LED tiles swap hue at a fixed
  luminance, step their palette on every beat, fade from one floor pattern to the next over a beat
  instead of cutting between them, and blush hot on the kick instead of flashing.
  The dancers are solid figures in the complement of the floor's palette at about the floor's
  luminance, edged in neon at the same luminance, so a fast move no longer sweeps a light step
  across the frame. The mirror-ball spots and the dress sequins are coloured and stay under the
  flash step on the displayed frame, spots fade out over the dresses so a spot and a sequin together
  stay within one glint's budget, and the sequins move with the dress. Strong reds ease toward grey, so the palette
  tour's red no longer spends the limiter's red budget. Beams sit at a fixed luminance, the spots
  turn slower and the trail is off. With the default palette and controls under the red audit's
  loud audio, the frame limiter now sees no large-area transitions instead of 55 a second and
  holds none of the frame, so the ghosting and stutter are gone. Other palettes and the vivid
  host grade can still trip it a few times a second.
- CD+G lyrics draw lighter, at regular weight (CORE-3260, openspec/changes/cdg-light-fast/).
  Layer masks blur with [1, 4, 1] / 6 per axis and the edge threshold rises from 112 to 171, so
  each edge sits just inside the unblurred edge while a lone window pixel whose eight neighbours
  share one index still draws at twice the window and above, outside the one-tile edge feather.
  A colour draws only where it lies inside the blur support of a pixel's
  weighted taps, so lower colours no longer fringe the edges of higher ones, and the shadow's
  alpha drops from 166 to 110. The `conformance/cdg-present/` vectors are regenerated, with a
  frame at exactly twice the window added per stream.
- The CD+G presenter's worst case is about 5x faster with frames bit-identical to the new look.
  All layers' levels are computed together in byte lanes, a pixel stops at the first fully
  covering layer, and a rebuild redoes only the magnified and frame pixels whose inputs changed.
  A 960 x 540 stream with every colour inked and a visible tile changed by every pack went from
  13 to over 70 frames per CPU second under wazero. The new `cdg_present_budget` bench (`make bench`)
  fails when that stream takes more than 7 ms of CPU time per frame natively.

## [0.2.19] - 2026-11-22

### Changed

- The CD+G presenter draws about twice as fast with bit-identical frames (CORE-3260). Rows with
  no overlay ink skip the blend and take a plain dithered backdrop, compose skips rows the layer
  masks leave empty, the layer blur runs only over rows that hold ink, and the backdrop
  interpolates with an accumulator instead of a divide per pixel. Under wazero on the Tower a
  960 x 540 canvas went from 49 to 95 fps and 1280 x 720 from 29 to 62 fps. The conformance
  vectors are unchanged, and a full song hashes the same at 960 x 540, 1280 x 720 and 643 x 357.

## [0.2.18] - 2026-11-22

### Changed

- The frame limiter's over test runs on windows of whole 64 x 36 sub-blocks (CORE-3238,
  openspec/changes/limiter-block-windows/). A host passes the window's columns and rows in
  sub-blocks in `limiter1.zw` (`windowOf()` returns them as `bcols` and `brows`); 0 and 0 keep
  the windows of whole 16 x 9 cells. At 480 x 270 a cell window was 1.75 times the 10° field, so
  ordinary motion read as over and was held, which showed as a ghost and then a jump when the
  hold released; a sub-block window is about 1.17 times the field. `conformance/limiter/frame/
  vectors.json` is regenerated and adds two cases, two patches that a sub-block window passes and
  a cell window holds.

## [0.2.17] - 2026-11-22

### Changed

- The CD+G presenter draws sharper and more legible graphics (CORE-3242,
  openspec/changes/cdg-legible/). The edge ramp after the smoothing blur is a little over half a
  frame pixel wide (was a full pixel) at a threshold of 112, so letters stay crisp without
  fattening. A graphics colour that touches the backdrop and falls under a 3.5:1 contrast ratio
  against the backdrop's luminance range is mixed toward white or black, fewest sixteenths first,
  unless a stage-legible contrasting colour outlines it; that protection lasts until the
  background index or palette changes. `conformance/cdg-present/` is regenerated and specifies
  the rules (README, Colours). The C interface is unchanged.

## [0.2.16] - 2026-11-22

### Changed

- `ReactionSampler`'s beat follower no longer races and stalls when the reference tempo wavers
  (CORE-3215, openspec/changes/smooth-beat-follower/). Its output rate slews towards the
  reference tempo, and the phase error is closed by a slewed correction of at most 15% of that
  rate, replacing the 50 ms slew clamped to 0.5 to 2 times the nominal rate. The output beat
  phase's frame-to-frame rate no longer steps (from up to 300% on a low-confidence track to about
  3%). The beat pulse's rise and decay use the output rate. `conformance/reaction/vectors.json`
  is regenerated.

## [0.2.15] - 2026-11-22

### Added

- A photo slideshow pass, `shaders/slideshow/slideshow.glsl` (CORE-2980,
  openspec/changes/add-photo-slideshow/, specified by `conformance/slideshow/`). A host fills
  `SlideshowInputs` and calls `slideshow(uv, s)` for each pixel. The pass pans and zooms slowly
  toward each photo's salient rectangle. It lays a photo out as cover, as fit over a blurred fill,
  or as a portrait pair. It changes photos with a dissolve, a light sweep or an iris. Tempo
  coupling is off by default (`amplitude` 0), and a host passes beats per slide in `extra.y`. The
  pass ships in the `glsl300` and `msl` legs, and `make slideshow-check` renders it in WebGL2 and
  Metal against the vectors. The C interface is unchanged.

### Changed

- The shader check harnesses launch Chromium with `--mute-audio`.

## [0.2.14] - 2026-11-21

### Added

- A CD+G presentation pass, `cdg::present` (CORE-3150, openspec/changes/cdg-presentation/,
  specified by `conformance/cdg-present/`). It finds the background and backdrop colours from the
  edge ring, doubles the window with an ink-priority Scale2x, draws each colour layer with smooth
  round-cornered coverage and no seams, casts a soft blurred shadow under the ink, and paints a
  slowly drifting two-glow backdrop tinted by the eased background colour. The C interface is
  unchanged.
- The `oscillux-cdg-render.wasm` release asset: a WASI command that reads a `.cdg` stream on stdin
  and writes presented RGBA frames to stdout (`--width --height --fps --start --tempo
  --frames`). Hosts that compose CD+G into video, such as the Beamfall server, run it in-process.

## [0.2.13] - 2026-11-21

### Changed

- The flash limiter counts red transitions by the u'v' rule of WCAG 2.1 and 2.2 as well as the
  320 rule (CORE-2935, openspec/changes/limiter-red-uv-chromaticity/): one state saturated red
  and the two states more than 0.2 apart in the CIE 1976 u'v' diagram. Each pixel keeps a box of
  the saturated chromaticities since its last red fall and one of the far chromaticities since
  its last red rise, so a red flash reached through intermediate colours on different frames
  counts. Black changes neither box.
- **Host change.** The tracker textures (`uTrack`, `oTrack`) are RGBA32UI (WebGL `RGBA32UI`,
  Metal `.rgba32Uint`, GLES `GL_RGBA32UI`), 16 bytes a pixel per copy, and every seed and clear
  is 32-bit. `BLACK_TEXEL` is (0, 32768, 2147508224, 0); zero and `UNTRACKED` (0, 8192, 0, 0) keep
  their meaning. A host checks at start that each tracker copy keeps bit 31 of every word and
  presents black if not. The `rows` pass reads the previous output: bind `uHist` (texture 2) to
  it as to the `output` pass. On a store of less than 32 bits every texel a pass writes loses the
  marker, then fires every direction at a changed colour and counts toward the area limit like
  any firing pixel (a zero seed survives and is tracked black); the format check is what keeps a
  16-bit store off screen.
- Vault, Ink, Event Horizon and Filament are calmer, so the limiter holds under 0.5% of their
  pixels a frame in the web player under loud audio. Vault's pattern crossfade runs evenly over
  its eight beats and its projector colours keep one brightness. Seven visuals' palette tour
  wrapped past the end of the 16-palette table out of the last palette; it now wraps at
  `OS_PAL_COUNT`.

## [0.2.12] - 2026-11-21

### Changed

- The release legs (`msl`, `glsl300`, `android-gles`) ship the rebuilt originals (CORE-2760,
  openspec/changes/release-legs-originals/). Until 0.2.11 they were built from the imported
  catalog alone, so clients shipped the old shaders while the lab showed the fixed visuals. Each
  catalog visual an original overrides now takes the original's body, wrapper, palette, params
  and post, and keeps the catalog's name, blurb, tier and place in the catalogue order. Every
  visual stays inside the flash limiter budget under loud audio.
- Owed red changes expire at a limiter restart after 1.25 s of exact black (CORE-2869,
  openspec/changes/limiter-red-expire-black/). A host restarts the limiter at its first start
  and after every frame change, presenting exact black (0, 0, 0) without running the limiter
  until it does. When that black has been on screen for at least `RED_EXPIRE_MS` (1250 ms, one
  frame of margin counted), the host starts the trackers at "black, nothing owed"
  (`BLACK_TEXEL`); otherwise at zero, as before. `G` is written fully spent at every start.
  During playback nothing expires. This ends the post-start red trickle, where a dark red glow
  after a start asked the grant for red transitions the viewer never saw and the web player held
  those pixels frame after frame. The auditor restarts with the host (`restart(seed)`). The
  safety argument is stated for the red-flash definition of WCAG 2.0 and of WCAG 2.1 as
  published in June 2018; the chromaticity reading of later WCAG 2.1 editions and WCAG 2.2 is
  CORE-2935.
- Every original finishes through `osOffRed` (`shaders/originals/common.glsl`), which makes a
  colour exactly grey below a near-black floor and keeps reds just off saturated red, so no
  saturated-red byte triple such as (1, 0, 0) is presented near black (CORE-2869).
- Aurora, Ink, Interference, Laser Tunnel, Photo Curtain, Photo Liquid, Plasma, Ribbons,
  Seismograph, Vault and Wave Cascade are calmer under the restart hold: their palettes no
  longer shift with the beat or the timbre, and under the vivid palette tour most change hue but
  keep their brightness. From a black start the 61 release visuals hold at most 0.4% of pixels
  a frame in the web player (CORE-2869).
- Dunes and Lumen Field keep the source flash budget before the limiter under loud audio
  (`make visual-flash-check`, CORE-2760). Dunes' near wind ripples are fainter, since the camera
  sweeps over them fast enough that deep ripples flickered the near sand at about 20 transitions
  a second. Lumen Field's beat ring still whitens the orbs but no longer swells them, since near
  bokeh discs growing on every beat made 8 large-area transitions a second.

## [0.2.11] - 2026-11-20

### Added

- The C ABI frame-window governor classifies p95 and p99 frame times and delivery health,
  then returns a hold, demote, or promote decision with the current streaks (CORE-2758).
  Hosts set `at_floor` to 1 when no lower step is available. Zero enables demotion.
  The defaults match the Apple kit's previous host-side steering, so hosts can drop their copy.
  The existing EMA governor functions are unchanged.

## [0.2.10] - 2026-11-19

### Changed

- Every catalogue visual keeps within the source flash budget on its own (CORE-2659). Under a loud
  master none makes more than 6 large-area luma transitions a second or any large-area red
  transition before the limiter, so `make visual-flash-check` passes for all 61 (0.2.9: 29 failed
  the luma budget). Beat accents ride on motion and hue instead of brightness flashes; phases that
  wrapped, reset or stepped on the beat are continuous; and band responses fade in and out around
  the kick instead of jumping on it, with a floor that keeps them following the spectrum without
  beat lock. Palette beat hue shifts (`palVisual`, `palRoleTrace`) follow `beatArc()`, which has no
  step at the beat wrap. Visuals that went flat or grey when first calmed have their contrast and
  saturation restored: Braid, Chrome, Comets, Crystal, Dunes, Filament, Helix, Ink, Lumen Field,
  Nebula, Petals, Phosphor Scope, Prism Room and Pulse. Aurora draws its scene layers in the right
  order, Loom draws the receding cloth at a steady floor, and Photo Glass and Rain leave no held
  ghosts in the limiter's output. Visuals' look, parameters and catalogue order are otherwise
  unchanged.

### Fixed

- The frame flash limiter dims a held pixel instead of freezing it (CORE-2543, CORE-2492,
  openspec/changes/limiter-dim-hold/). In 0.2.9 a pixel whose change the grant did not admit
  showed the previous output. Grants are scarce, so under loud audio most moving pixels froze,
  each on its own frame, and the picture broke into stale fragments over live content. A held
  pixel now shows the input with its luma moved the least distance into the band its tracker
  allows. When a fall is denied it is mixed with the least of the previous output that is needed.
  When a rise is denied it is mixed from the previous output as far toward the input as the band
  allows and then moved an eighth of the way to the input scaled toward black, so over black it is
  the input dimmed, and over a lit background it keeps the background's hue instead of showing a
  grey edge where a white line passes. A lit pixel whose input is far brighter than the band stays
  near what it showed, so a bright ring that moves across a lit fill does not draw a faint second
  ring. A mix from the previous output is the fallback when red would still fire. A held region
  shows the current frame at reduced contrast, and a bright area that went dark stays lit less
  than a step dimmer, in its own colour, until a fall is granted. The bound is unchanged: the
  output fires only what the input fires and the grant admitted, so at most the luma flash limit
  and one large-area red transition a second. Pass bindings, texture formats and the ABI are
  unchanged; hosts only take the new shaders. Two conformance cases (`colour-10hz-dim`,
  `colour-checker-15hz-dim`) cover the dimmed colours. The searches along a mix of two colours
  assume no order, since rounding can make a step qualify past ones that do not: each tests the
  16 steps nearest the input, then every 16th, then the 15 before the first that qualified (at
  most 45 tests, was 8), so a held pixel is no longer left far from the input when a nearer step
  is safe (cases `dim-fall-first-step`, `dim-rise-past-a-gap`, `dim-red-near-input`).

## [0.2.9] - 2026-11-19

### Changed

- Visuals fit the frame's aspect (CORE-2491). `centered()` and `motionCentered()` in
  `shaders/library.glsl` lean toward the frame's short side below aspect 1 (scale aspect^-0.7),
  so subjects stay in frame on a portrait phone; output at 16:9 and wider is unchanged. Spectrum,
  Terrain and Spectral City choose their column count from the frame aspect with the new
  `fitColumns()`, never under one column per 4 px, so bars are not squeezed together on a phone.
  Ink sizes its dye splats against the short side and no longer whites out in portrait.
- Calmer visual sources (CORE-2492): beat accents in about 30 visuals are softer or ride on
  motion instead of brightness, Wave Tunnel's rings no longer flash on onsets, and Particles has
  narrower size and brightness swings, half the burst range and half its beat and onset
  brightness swings, so the limiter holds less (at most 20% of a frame's pixels on loud audio).
  Particles' default palette is now deepSpace and Reactor's jade, instead of emberIce, whose red
  stop lit large areas in saturated red: on a loud master neither makes a large-area red transition
  before the limiter, and Particles holds under 9% of a frame. Under a loud master a few catalogue visuals still make
  large-area red transitions before the limiter, which the limiter holds to one a second; measured per pixel 29 of 61 still make more than 6 large-area luma transitions a second on their
  own; the limiter holds those. `make visual-flash-check` runs the source budget
  (`limiter-red-audit.mjs --max-luma`) and fails until they are calmed.

### Fixed

- The frame flash limiter tracks every pixel and holds only the pixels it limits (CORE-2543,
  CORE-2515, CORE-2541, CORE-2492). Each pixel keeps the audit counter's luma and red trackers and
  recency stamps in a new RGBA16UI track texture, so fine patterns that reverse inside a
  sub-block (a 10 Hz checkerboard of 4 px squares) and changes over part of a sub-block are
  limited exactly as the auditor counts them. The area test counts pixels that fire now or fired
  inside the coverage interval over the cell window covering the field, against a quarter of the
  field's pixels. Up and down in one frame are granted together only on a full token pair, and
  leave two tokens of deficit, so no 1 s window holds more than 6 transitions. A pixel whose
  trackers would fire in a direction the grant did not admit shows the previous output; every
  other pixel shows the input exactly, so holds no longer show as sub-block tiles and the hold
  feather from 0.2.5 is gone (a blended change could finish a transition late). Under loud audio
  every catalogue visual's output keeps within 6 luma transitions a second and at most one
  large-area red transition in any second, so no red flash; held pixels average 11% in Laser
  Tunnel (0.2.8: 37% of sub-blocks) and 28% in Interference (32%). Cost on an M2 Max: 0.31 ms a frame at 1080p, 0.87 ms at 4K.
  **Host binding change:** six passes (`rows`, `reduce`, `cells`, `windows`, `grant`, `output`).
  `rows` reads `uFrame` and `uTrack`; `output` reads `uFrame`, `uHist`, `uTrack` and `uG` and
  writes `oColor` and `oTrack` (MRT). Hosts start the output black and the track textures at
  zero (tracked black) with `G` written fully spent, and never clear `G` or the trackers under
  a frame on screen; a viewing-geometry change keeps the trackers and writes `G` fully spent; any
  change to the frame (its size, its display scale or the texels in view) fades the frame to
  black through the limiter (`G` fully spent, an area limit of 0, black fed in), presents black
  for longer than the coverage interval from the first black frame, then starts again tracked
  black with `G` fully spent, and a change during the fade or the black only moves that target;
  nothing is copied or stretched (shaders/limiter/README.md, "Ping-pong and reset"). Hosts pass
  the window from
  `windowOf()` and the limit in pixels, computed from physical pixels and divided by the square of
  the texel size. The area is one count of pixels changing in any channel and direction; the luma
  step is 3275 codes and the red step 15. Hosts carry the fraction of each frame's refill to the next frame, so a small `maxFlashHz` at a high frame rate still refills. A tracker fires on a full step back from its extreme or a further full step onward from its last transition, so an area whose pixels started rising at different times is counted when it rises together, and the reference follows a dip short of a step, so a step up from the dip fires; the refill earns one unit under a token a token period, the red refill carries its remainder exactly, and the first frame after the host writes the budget, the start included, refills nothing. A fall that ends above the dark cutoff keeps its high side, so a later fall from the same peak to below 0.8 still fires, and bits 15 of the track word's x and y hold a red memory (unknown, counted, pending, saturated seen), so a red change counts after a host reset, whatever the pixel showed before, and still counts again when it first saturates. `G.x` bits 4 to 7 are the held directions: those some pixel fires in that the grant did not admit (they were an over flag before this release); a host may stop drawing a paused frame only while they are clear. The auditor (`limiter-audit.mjs`) consumes a combined charge's evidence only when it records the charge, so a directional charge no longer erases the opposite direction's pending area, and records a charge only when some pixel inside its area fires on that frame (by frame, not by timestamp, so a zero interval cannot repeat a charge), so an unchanged frame makes no transition. The red release bound is stated on intervals capped at one refill period, which a mixed cadence of long and short frames stretches past nine frames. `deltaMs` is the least time the previous frame can have been shown when it was painted up to one refresh late: max(interval / 2, interval - R) for a refresh R known only from above, which a host drawing at its animation-frame rate credits as half of each interval. Frames are supported from 64 x 36 to 8192 x 8192;
  hosts clamp larger frames. `state.glsl` is removed. Frame conformance vectors re-recorded with all four grant words, a track digest and a window
  field, and new `fine-checker-10hz` and `tv-half-field-10hz-orange-drift` cases.
- Feedback trails (`feedbackTrail`) and Ink's advection and dye, caustic and edge injection scale their per-frame decay, zoom and
  rotation by the frame time, so trails last the same at 30, 60 and 120 Hz, and history sampled
  past the frame edge fades out instead of streaking inward from the edge texel. The GLSL ES 3.00
  wrapper declares `precision highp sampler2D` (CORE-2480).

## [0.2.8] - 2026-11-17

### Fixed

- The catalogue Particles (`shaders/visuals/particles.glsl`, carried by the msl, glsl300 and
  android-gles legs) brightens and bursts much less on beats and onsets, no longer rotates its
  feedback trail on beats, fades its streaks in instead of cutting them hard, and tints bass
  embers less red. The frame flash limiter no longer holds large areas of it and red embers no
  longer show as hard square tiles.
  Under loud audio the largest held fraction of limiter sub-blocks fell from 0.23 to 0.02.
  `make limiter-hold-check` (in `make gate`) keeps it under 5% (CORE-2409).

## [0.2.7] - 2026-11-17

### Fixed

- The frame flash limiter no longer freezes a lasting large-area saturated-red change. Red over
  the area limit now has its own token, refilled at an eighth of the luma rate: at most one
  large-area red transition in any 1 s window (still no red flash), and a held red change is
  admitted within 8 / (2 maxFlashHz) s (CORE-2382). The limiter conformance vectors changed.

## [0.2.6] - 2026-11-17

### Added

- `oscillux_palette_tour` and `oscillux_palette_vivid_present`, with
  `OSCILLUX_PALETTE_TOUR_COUNT` (16) and `OSCILLUX_PALETTE_TOUR_SECONDS` (6): the vivid colour
  mode's palette tour and present-pass saturation 1.35 and vibrance 1.2, so hosts take them from
  the core instead of porting `tools/shader/palette-tour.mjs`. npm `paletteTour` (returns `z`) and
  `vividPresent`; Java `Oscillux.paletteTour` and `Oscillux.vividPresent`. Conformance vectors in
  `conformance/palette-tour/` (CORE-2369).

## [0.2.5] - 2026-11-17

### Changed

- The catalogue Aurora (`shaders/visuals/aurora.glsl`, the one the msl, glsl300 and android-gles
  legs carry) moves and brightens less on bass and beats, so the frame flash limiter is a safety
  net for it and no longer a constant effect. On a hard-beat probe run at 960x540 the frames with
  any held sub-block fell from 141 to 11 of 300, and to none on ordinary audio. The 0.2.4 Aurora
  change reached only the `shaders/originals/` Aurora, which the legs do not carry.

## [0.2.4] - 2026-11-17

### Changed

- The frame flash limiter fades each hold out over a round field about four sub-blocks wide that
  is continuous in space, so a hold no longer shows staircases of squares after a few frames.
  What is held is unchanged, and red-dominant pixels are never blended. The `state` and `output`
  limiter passes changed in the msl and glsl300 legs; they take the same textures and uniforms,
  and `T1.w` now carries the hold in bit 0 and the hold field above it (CORE-2328).
- Aurora is about half as bright and reacts less to the beat and the bass, so the limiter rarely
  holds on it (CORE-2328).

## [0.2.3] - 2026-11-16

### Changed

- The frame flash limiter feathers each hold one sub-block outward, so a held sub-block no longer
  shows as a hard-edged rectangle. What is held is unchanged, and red-dominant pixels are never
  blended. Only the `output` limiter pass changed in the msl and glsl300 legs; it takes the same
  textures and uniforms (CORE-2231).

## [0.2.2] - 2026-11-16

### Changed

- Nebula follows the host's detail reduction (`presentation1.y`): 12 volume shells at 0, down
  to 6 at 1, each weighted so the cloud keeps its density. Its output at reduction 0 is
  unchanged, and no other emitted shader changed (CORE-2220).

### Fixed

- `OSCILLUX_VERSION_PATCH` and `OSCILLUX_VERSION` in `oscillux.h` match the crate version again;
  the 0.2.1 header still read 0.2.0 (`OSCILLUX_VERSION` 512).

## [0.2.1] - 2026-11-16

### Added

- Shader manifests take optional catalog fields per visual (`name`, `blurb`, `tier`, `input`,
  `overlay`, `calm`, with `imageCapable` and `unreadParamLabels`) and a top-level
  `catalogOrder`, validated by the manifest loader; `input` names `image` exactly when
  `imageInput` is true. The reference set carries them for all 61 visuals. No emitted shader
  changes (`docs/shader-toolchain.md`).
- The `msl` and `glsl300` shader legs carry `catalog.json`: every visual in catalog order with
  its catalog fields, params with labels and defaults, post tuning, palette and controls, listed
  in the leg's `index.json`.
- A third shader leg, `oscillux-android-gles.zip`: `AndroidGlesShaders.kt`, the Android GLES
  contract 1.0.0 (package, object, digest domains and payload format unchanged) generated by
  `tools/shader/bundle-legs.mjs android-gles`, with its `index.json`. Its contract tests run in
  `make shader-test`.

## [0.2.0] - 2026-11-16

### Added

- Shader manifests take an optional per-visual `post` object (`bloomStrength`,
  `bloomThreshold`, `chroma`, `vignette`, `grain`) with fixed ranges and effect-off defaults.
  The reference set carries values for all 61 visuals and the host bundle copies them
  (`docs/shader-toolchain.md`).
- Original Visual `falling-beams`: soft shafts of light falling through dust, for quiet screens
  with no audio. `param0` (Fill) lights the shafts one after another, so a host can map its own
  0 to 1 progress onto it. It is in the calm collection (OSC-0038).

### Fixed

- The limiter pixel auditor (`tools/shader/limiter-audit.mjs`) counts every large-area
  transition of sustained flashing. It used to count one for a run that kept a large area
  changing (a strobe over 15 Hz, or a moving pattern), which undercounted inputs and made the
  limiter appear to add transitions (CORE-1623). The limiter itself is unchanged.

### Changed

- Relicensed to AGPL v3 (`AGPL-3.0-only`). Releases 0.1.0 and 0.1.1 were released under a
  noncommercial licence from an earlier private repository; they were not published in this one. Their entries below are kept as history.
- `OSCILLUX_VERSION` is 0.2.0 (`OSCILLUX_VERSION_MINOR` 2, packed 512); `OSCILLUX_ABI_VERSION`
  stays 1.
- The shader hashes (the visual library's `hash11`/`hash21`/`hash22`/`hash31`, the visuals that
  inlined them, and the present pass's dither and grain hash) are Oscillux's own integer
  hashes, replacing third-party ones. The noise statistics are unchanged, but every
  noise-seeded layout re-rolls: star fields, particle and nebula placement and grain patterns
  differ from 0.1.x. The comets and the space-flight nebulae render about 30% dimmer, because
  their constants were tuned against the old noise field; a retune is optional follow-up work.

## [0.1.0] - 2026-11-13

### Added

- CD+G background keys for downloaded karaoke (OSC-CDG-DOWNLOADS): `OSCILLUX_CDG_KEY_MASK`
  makes every index whose bit is set in a 16-bit `key_index` transparent, and
  `oscillux_cdg_index_counts` counts the pixels of each colour index in the visible window or
  its edge ring (`OSCILLUX_CDG_REGION_WINDOW`, `OSCILLUX_CDG_REGION_EDGE`,
  `OSCILLUX_CDG_EDGE_PIXELS` 8928, `OSCILLUX_CDG_INDEX_COUNT` 16). Neither allocates. Bound for
  npm (`Cdg.indexCounts`, `Cdg.count`) and Java (`Oscillux.Cdg.indexCounts`). Two realistic
  synthetic streams, `karaoke-blue` (Memory Preset blue, outlined lyrics, a colour wipe) and
  `karaoke-tiles` (a tiled two-shade blue background), carry mask and count vectors in
  `conformance/cdg/`, and `make cdg-check` measures them under a flashing stress visual.
- MP3+G archives in the web and Apple hosts: a `.zip` holding a song and its `.cdg`, dropped
  (web page, macOS window), picked, or given by `?karaoke=` / `?cdg=` or `-karaoke` / `-audio` /
  `-cdg`, opens both. The readers (`hosts/web/karaoke-zip.js`,
  `hosts/apple/Sources/KaraokeZip.swift`) work in memory and refuse unsafe entry names, oversized
  or inflating archives and entries, ZIP64, encrypted and multi-part archives; `make shader-test`
  and `make karaoke-zip-swift` check both on the same archives. Host-only.
- Web host resilience (OSC-WEB-HOST-RESILIENCE). A lost WebGL context is rebuilt in place when
  the browser restores it: the current visual, its feedback targets and a switch in progress
  continue without a reload (a switch with a held outgoing layer ends on the incoming visual),
  and a context lost before start-up is restored before the host starts. Without
  `EXT_color_buffer_float` the feedback renders as RGBA16F through `EXT_color_buffer_half_float`
  or else as RGBA8, and the status line names the fallback. `preserveDrawingBuffer` is on only
  for `frames=`, `size=` and `trace` runs. `make web-host-check` checks all three headlessly.
- A calm visual set (OSC-VISUALS-CALM). Twelve new originals for karaoke and quiet rooms, each
  slow, softly lit and kept below whiteout, with audio that swells the light rather than
  strobing it: `moonlit-tide`, `lantern-drift`, `silk-veil`, `dusk-hills`, `still-pond`,
  `soft-bokeh`, `sunlit-shallows`, `starlit-haze`, `cloud-sea`, `ember-glow`, `pastel-drift` and
  `snowfall`, each with full param controls. `hosts/collections.json` names them as the `calm`
  collection with the transitions it uses, which `make host-bundle` copies into the bundle's
  new `collections` field and checks against the bundled visual and transition ids. The web
  host's collection picker (`collection=<id>`) plays a collection's visuals and switches with
  only its transitions. Collections are reference-host data, not core policy. Selection rule
  and metrics: OSC-VISUALS-CALM and OSC-0014.
- Type and intensity filters for the visual picker in the web and Apple reference hosts, from
  `hosts/categories.json` (8 types, 3 intensities, every bundled visual categorised). Prev and
  next step within the filter; `type=` / `-type` and `intensity=` / `-intensity` set it at
  launch. `make host-bundle` and `make shader-test` fail when a bundled visual has no category.
- Visual param metadata and presets (OSC-TUNE-PARAM-SCHEMA). A shader manifest's `params` is now
  one control per param uniform the visual reads: `id`, `label`, `labelKey`, `min`, `max`,
  `default`, `step`, `curve` and `group`. `tunables` lists the host uniforms the visual reads
  (`sensitivity`, `trailDecay`, `accent`, `motion`, `palette`). `make shader-test` and
  `tools/shader/bundle-hosts.mjs` reject a visual whose read params lack a control. The host
  bundle carries `controls` and `tunables` beside the positional `params`, which now hold the
  control defaults. `tools/shader/preset.mjs` defines preset schema version 1 (visual, params by
  control id, sensitivity, accent, motion, palette, trail decay, mapping). It refuses unknown
  keys, non-finite numbers and newer versions, clamps every value into its range, and migrates
  the positional version 0. Presets set only the tunable uniforms, never `presentation*` or
  `safeRect`. `conformance/presets/` holds 40 vectors and a 17-case adversarial set. The web host
  writes the uniforms from each visual's default preset, and `make overlay-check` takes
  `--preset`.
- CD+G lyrics in the web and macOS hosts: the lyric layer advances with the position heard (the
  song's, after output latency, or the synthetic loop's) on each frame and composites over the visual with the halo and contrast
  clamps. The web host loads `?cdg=<url>`, a dropped `.cdg` (alone or with its song) or the
  Lyrics… picker; the macOS host loads `-cdg <path>`, a `.cdg` beside an opened song, or the
  Lyrics… panel. `cdgkey=` / `-cdgkey` choose the transparency key. Lyrics belong to their song: another
  song or source replaces them with its own or none. `make cdg-host-check` checks the web
  host's pack clock, layer texture, drop (lyrics 160 ms behind the write position at a pinned
  latency) and canvas (OSC-CDG phase 2).
- CD+G lyric graphics (`oscillux_cdg_*`, `OscilluxCdgState`): a loaded pack stream decodes every
  TV-graphics instruction to the 300 x 216 indexed screen, colour table, scroll offsets and dirty
  rectangle, bit-exact with the stdlib oracle `tools/cdg-vectors.py` (`conformance/cdg/`).
  `oscillux_cdg_advance_to_time` decodes through pack `floor(t * 300)`; checkpoints made at load
  keep any seek in a 5-minute stream under 0.06 ms. `oscillux_cdg_window_rgba` writes the visible
  288 x 192 window as RGBA8 under a host-chosen transparency key (none, the stream's
  transparent-colour table, the preset colour or one index). Only create allocates. Bound for npm
  (`Cdg`) and Java (`Oscillux.Cdg`). `shaders/cdg/cdg-composite.glsl` lays the window over the
  visual with a sharp upscale, host-chosen fit and aspect, and a halo that holds every lyric pixel
  at 4.5:1 or more against the background it touches (`make cdg-check`). Hosts do not play CD+G
  yet.
- Reference visual catalog: the 61 upstream visuals and their shared `library.glsl` in
  `shaders/`, imported from beamfall-visual-shaders c3145a4 by `tools/shader/import-visuals.mjs`.
  `make shader-test` checks that each one wraps for web, Vulkan, MSL and HLSL with the schema's
  uniform block. Two reference hosts render them from one bundle with the same uniforms: a WebGL2
  page and a SwiftUI app for macOS and iOS (`hosts/README.md`). No C interface change.
- DSP behaviour version 3 (`OSCILLUX_DSP_BEHAVIOR_V3`): version 2 analysis with a beat tracker
  tuned on recorded music. Its tempo comes from an autocorrelation of the onset envelope with a
  110 BPM prior over 60 to 200 BPM, and its phase follows the bass on every frame. Frames, levels
  and descriptors equal version 2 bit for bit; only `OscilluxDspFrameExt.beat` differs. On annotated
  recorded music (not distributed) its mean beat F at +/-70 ms is higher than version 2's; on the
  synthetic scores it is 0.725 to 0.982. The default stays version 2, and versions 1 and 2 keep every vector.
  Specified in `conformance/dsp/music/README.md`, "Version 3".
- Offline beat grid (`oscillux_beatgrid_*`): analyses a whole decoded file, non-causally, into
  beats with local tempo, a 3/4 or 4/4 meter and bar indices. `oscillux_beatgrid_clock` gives
  the beat and bar phase at any media time without allocating. New structs
  `OscilluxBeatGridConfig`, `OscilluxBeatGridInfo`, `OscilluxBeatGridBeat` and
  `OscilluxBeatGridClock`; the DSP structs and every existing vector are unchanged. The output is
  bit-identical on native and wasm32 and is checked against a Python oracle
  (`conformance/beatgrid/`). Bound as `BeatGrid` and `BeatGridConfig` in npm and as
  `Oscillux.BeatGrid` in Java. The macOS host now takes the `-audio` beat from it.

- `oscillux_version()` and `OSCILLUX_VERSION_MAJOR`, `_MINOR`, `_PATCH` and the packed
  `OSCILLUX_VERSION`, taken from the crate version. The header documents the startup check
  `oscillux_abi_version() == OSCILLUX_ABI_VERSION && oscillux_version() >= OSCILLUX_VERSION`.
- `oscillux_status_string()`: a static description of any status, for logs.
- `oscillux_dsp_config_validate()`: checks an `OscilluxDspConfig` exactly as
  `oscillux_dsp_create` does and names the offending member.
- `oscillux_mapping_config_from_dsp()`: a mapping configuration whose hop and loudness reference
  come from the DSP configuration, so the mapper's release timing follows the sample rate.
- `OSCILLUX_DSP_FLAG_INPUT_REPLACED`: set on a frame when an input sample since the previous
  frame was replaced with 0 (see Changed).
- Named defines for curve kinds, units, easings, shapes and flags, mapped value indices, field
  sources and packer limits, and the `OSCILLUX_API` export/import macro for Windows DLLs.
- The extensible-struct rule: configuration and policy structs added from now on begin with
  `uint32_t struct_size`. The existing ones keep their layouts until the next ABI version.
- `ffi/abi-snapshot.txt`, a committed snapshot of every function, constant and struct layout.
  `make gate` fails with a line diff when the header and the snapshot differ.
- The region flash analyzer: `OscilluxFlashAnalyzer` with `oscillux_flash_config_default`,
  `oscillux_flash_analyzer_create`, `_destroy`, `_reset`, `_measure` and `_admit`, plus
  `oscillux_flash_region_from_linear_rgb`, `OscilluxFlashConfig` (begins with `struct_size`),
  `OscilluxFlashRegion`, `OscilluxFlashReport` and `OSCILLUX_FLASH_MAX_GRID`. It measures
  WCAG 2.3.1 general and red flashes from host-measured per-region luminance with a 10-degree
  field area window; see `conformance/limiter/README.md`. Pattern detection is not supported.
- npm (wasm) and Java (JNI) bindings for every header export (see `docs/packaging.md`,
  "Binding coverage"): configuration
  value classes, status strings, DSP config validation, curves, governor, mapping, packing, the
  region flash analyzer (`FlashConfig`, `FlashAnalyzer`; Java `Oscillux.FlashAnalyzer`,
  `flashConfigDefault`, `flashRegionFromLinearRgb`) and `version`. The npm package ships
  `oscillux.d.ts`. `packaging/wasm/tests/coverage.rs`, run by `make gate`, fails when a header
  export has neither a binding nor a documented exclusion.
- `make platform-gate`: links every shipped XCFramework slice and AAR ABI against a C
  conformance harness and runs the DSP vectors (bit-exact digests) and region flash sequences on
  macOS (native and Rosetta 2), an iOS and a tvOS simulator and an arm64-v8a Android emulator,
  runs `AdapterSmoke` through the AAR's JNI glue there, and runs the npm package smoke under
  Node. Required before publishing artifacts. `docs/packaging.md` now carries a claimed, built
  and executed platform matrix. The header layout test also compiles its asserts for
  armv7 Android, wasm32 and both Windows targets with `clang --target`.
- Shader toolchain: manifest target `hlsl` emits HLSL Shader Model 5.0 through SPIRV-Cross
  (`emit.mjs --hlsl`), with the reflected bindings (`b0`, `t0`, `t1`, `s0`), stage IO and
  each cbuffer member's type, array length and `packoffset` checked against the uniform schema
  (`make shader-test` runs the check on the HLSL goldens `conformance/shader/examples/*.hlsl`).
  `make shader-verify` compiles each one with FXC or DXC when `OSCILLUX_FXC`, `OSCILLUX_DXC`
  or `PATH` provides one, and reports SKIPPED otherwise. For the example manifest it also
  requires the emitted HLSL to equal those goldens byte for byte. Both example visuals pass
  DXC 1.9.
- Shader toolchain: a declarative pass-list format, `conformance/passes/pass-list.schema.json`,
  with targets, feedback ping-pong, blend and per-pass uniforms by schema name, validated by
  `tools/shader/passes.mjs` (in `make gate`), and examples for the feedback ping-pong and a
  bloom chain. Hosts execute pass lists; Oscillux only defines and validates them. Also
  `tools/shader/watch.mjs` (`make shader-watch`), a dev-only preview that re-validates and
  re-renders through `render.mjs` on every change.
- The ISO 9241-391 red-flash rule for the region flash analyzer, the rule the WCAG 2.1 and 2.2
  notes cite: a transition to or from saturated red whose states differ by more than 0.2 in
  CIE 1976 u'v'. `OscilluxFlashConfig` gains `red_rule` (`OSCILLUX_FLASH_RED_RULE_WCAG20`, the
  default, or `OSCILLUX_FLASH_RED_RULE_ISO_9241_391`) and a `reserved` member that must be 0,
  appended behind `struct_size`: the struct is now 56 bytes and a `struct_size` of 48, the
  first released size, still works and selects WCAG 2.0. `oscillux_flash_analyzer_measure_rgb`
  and `oscillux_flash_analyzer_admit_rgb` take an `OscilluxFlashColor` (linear r, g, b) per
  region; the ISO rule needs them and refuses the sample entry points with
  `OSCILLUX_ERR_INVALID_ARGUMENT`. npm: `FlashConfig.redRule`, `FlashRedRule`,
  `FlashAnalyzer.colorsPtr`, `measureRgb`, `admitRgb`; Java: `flashColorSize`,
  `FlashAnalyzer.measureRgb`, `admitRgb`. Eleven hand-derived sequences in
  `conformance/limiter/region-sequences.json` cover both rules, including pairs just under
  and just over the 0.2 u'v' threshold, a slow drift, and the bounding box's conservative
  over-count. `python3 tools/limiter-region-vectors.py --check` fails if the file differs
  from the generator.
- npm `Dsp.pushF64(sampleCount, channels)`, binding `oscillux_dsp_push_f64`: PCM written as
  Float64 at `inputF64Ptr()`. The buffer is sized by a new optional fourth `Dsp` constructor
  argument, `f64Capacity` (default 0), so existing hosts allocate nothing extra. On
  Float32-representable samples it produces the same frames as `push`.
- DSP behaviour version 2, selected through the new `OscilluxDspVersionedConfig`
  (`struct_size`, the unchanged `OscilluxDspConfig`, `behavior_version`, then a `reserved`
  member that must be 0), with `OSCILLUX_DSP_BEHAVIOR_V1` and `_V2`,
  `oscillux_dsp_versioned_config_default` (writes version 2),
  `oscillux_dsp_versioned_config_validate` and `oscillux_dsp_create_versioned`. Version 2:
  - gives each band triangular weights so no two bands share a bin range;
  - analyses bass bands from a decimated history of up to 8192 samples, with at most 90 ms of
    group delay;
  - normalises every onset detector the same way, with an absolute floor;
  - sums RMS in 64-sample blocks and uses a real-input FFT, cutting per-hop cost by about 32%.

  `oscillux_dsp_config_default`, `oscillux_dsp_create` and the rest of the ABI-1 DSP functions
  keep version 1 bit for bit; its vectors and digests are unchanged. Version 2 has its own
  vectors under `conformance/dsp/v2/` with an independent oracle, and differs from the Go
  reference (`conformance/dsp/README.md`, "Behaviour version 2").
  `python3 tools/dsp-v2-vectors.py --check`, part of `make gate`, fails if those vectors differ
  from the oracle's output. Java adds `dspVersionedConfigSize`, `dspVersionedConfigDefault`,
  `dspVersionedConfigValidate` and `Dsp.createVersioned`; npm adds `DspConfig.behaviorVersion`.
- `OscilluxDspBeat` and `OscilluxDspLevels`, beat tracking and adaptive levels computed from
  analysis frames and appended to `OscilluxDspFrameExt` as `beat` and `levels`. Their Rust stages are
  `oscillux_core::dsp::BeatTracker`, a streaming, allocation-free tempo, beat-phase, bar-phase,
  downbeat and confidence tracker, and `oscillux_core::dsp::Agc`, an adaptive normaliser that
  reports band and onset-group levels relative to their recent dB range beside the absolute
  group levels. Both are specified in `conformance/dsp/music/README.md`. Each has stdlib oracle
  vectors under `conformance/dsp/music/beat/` and `agc/`, checked bit for bit on the host
  and on wasm32-wasip1. `make gate` regenerates those vectors through
  `tools/dsp-beat-vectors.py --check` and `tools/dsp-agc-vectors.py --check`. Every analyzer
  runs one of each with its default configuration on every hop, whichever push function is
  used: the tracker for 80 to 160 BPM in 4/4, and the normaliser with a 4 s time constant, a
  12 dB minimum range and a noise gate 36 dB below each level's reference, a maximum that
  relaxes over 600 s. A section stays all zero when
  the analyzer's frame rate (below 64/3 or above 4096/3 frames per second) or `db_floor`
  (above -12 dB) cannot run that configuration. C, npm and Java callers get only these
  defaults; Rust callers can run the stages with their own configurations. The ext's
  `struct_size` may now be any section end: 56 (descriptors only, still accepted and still
  given only the descriptors), 104 (with the beat, a size no header declares) or 672 (with the
  levels); the push writes only the sections inside each element's `struct_size`. Beats stop, and confidence falls to 0, sixteen beats after the last
  onset; the bar position advances on every beat-phase wrap. The noise gate is relative: a
  relative level reads in full while its recent maximum is within 24 dB of its reference and 0
  from 36 dB below, so a quiet hiss after loud material stays near 0 for minutes, and a quiet
  master reads like a loud one (the same programme 20 dB quieter gives the same levels to
  within 1e-9). Levels below `db_floor` are clipped by the analyzer: at -20 dB input gain the
  scores' mid and high groups span 0.43 to 0.75 instead of 0.85 to 0.99, and lowering
  `db_floor` by the gain restores them. Running both stages costs about 0.3 to 0.7 microseconds
  per frame in `make bench`, paid by plain push callers too (min round median, three
  alternating runs against main fa7e322: 0.0332-0.0334 to 0.0335-0.0340 ms for behaviour
  version 2, 0.0473-0.0477 to 0.0480 ms for version 1). Frames and the existing output
  digests are unchanged. npm `Dsp.extBytes()` and Java `dspFrameExtSize()` now return 672.
  An npm `Dsp` now allocates its ext buffer on its first `pushExt` or `pushExtF64` instead of
  at construction (672 bytes per frame of `frameCapacity`, about 44 MB at 65536), and
  `extPtr()` is 0 until then.
- Synthetic music scores and edge-case fixtures under `conformance/dsp/music/`: rendered at
  test time, with onset (±50 ms) and beat (±70 ms) F-measure checks and an adaptive level
  span check in `make gate`, a span check at -12, -20 and -30 dB input gain, plus a held-out
  breakbeat score that no parameter was tuned on, reported but not asserted. On that score
  version 2 fails outright (beat F 0.453, downbeat F 0, against the 0.8 bound the tuned scores
  meet; version 1 reaches beat F 0.889), so the beat tracker's accuracy has not been shown to
  generalise beyond the scores it was tuned on. No licensed recording is included.

- Opt-in DSP descriptors, computed every hop for both behaviour versions:
  `OscilluxDspDescriptors` (BS.1770-4 momentary and short-term loudness in LUFS with
  K-weighting derived for the configured sample rate, mid/side stereo width, left/right
  balance, spectral centroid in Hz and half-wave rectified spectral flux) inside
  `OscilluxDspFrameExt { struct_size, reserved, descriptors }`. `oscillux_dsp_push_ext_f32` and
  `oscillux_dsp_push_ext_f64` fill one ext element per frame; their frames are bit-identical
  to `oscillux_dsp_push_f32`/`_f64`. Before any input is consumed, a null `ext` with a nonzero
  capacity fails with `OSCILLUX_ERR_NULL`, and a misaligned `ext`, an unreleased
  `struct_size` or a nonzero `reserved` with `OSCILLUX_ERR_INVALID_ARGUMENT`. Later sections
  only append to the struct. `OscilluxDspFrame`, `OscilluxDspConfig` and `loudness_db` are
  unchanged (`conformance/dsp/README.md`, "Descriptors", explains how `loudness_db` differs
  from LUFS). Loudness weights 5-, 6- and 8-channel input as 5.0, 5.1 and 7.1 (ITU-R BS.2051
  order) with the LFE excluded. The analyzer computes the descriptors on every hop, so plain
  `oscillux_dsp_push_f32`/`_f64` callers also pay for the K-weighting and spectral
  descriptors: about 10-13 % more time per frame in `make bench` (min round median 0.0282 to
  0.0317 ms for behaviour version 2, 0.0410 to 0.0452 ms for version 1), far inside the
  0.5 ms budget. `oscillux_mapping_process_ext` maps a frame with its descriptors: FLUX is the
  spectral flux clamped to 0..1 and CENTROID `log10(centroid_hz / 20) / 3` clamped to 0..1
  (20 Hz to 20 kHz). Rust adds
  `Analyzer::push_ext` and `Mapper::map_with`; npm adds `Dsp.pushExt`, `Dsp.pushExtF64`,
  `Mapper.processExt` and `Mapper.processFrameExt`; Java adds `Dsp.pushExt`,
  `Dsp.pushExtF64`, `Mapper.processExt` and `dspFrameExtSize`.
- `tools/dsp-descriptors-vectors.py`, a standard-library oracle that writes
  `conformance/dsp/descriptors/`: K-weighting coefficients at ten rates, with each rate's
  response checked against the published BS.1770-4 48 kHz filter; 28 loudness cases, EBU
  Tech 3341 cases 1, 2, 6, 9 and 12 and nine analytic signals (case 6 as 5.1 and as 7.1, mono,
  anti-phase, left only, DC offset, DC only, and 100 Hz and 10 kHz sines whose nominal loudness
  comes from the published filter's gain), each at 44.1 and 48 kHz with its nominal values; and
  centroid/flux against the librosa definition. `tools/mapping-vectors.py`, an independent
  model, reproduces every slot and packed byte of `conformance/packing/reference.json` and
  writes `conformance/packing/descriptors.json` for the descriptor path. Their `--check` modes
  are part of `make gate`.
  Novelty curves stay with hosts (`conformance/dsp/README.md`, "Novelty").
- `oscillux_mapping_set_level_source()` with `OSCILLUX_MAPPING_LEVELS_ABSOLUTE` (the default)
  and `OSCILLUX_MAPPING_LEVELS_RELATIVE`, an opt-in per mapper. The relative source maps BASS,
  MID, TREBLE and the spectrum from the ext frame's relative band levels, the same way the
  default maps the band energies; AMPLITUDE, LEVEL, ONSET, BASS_IMPACT, FLUX and CENTROID still
  read the frame and descriptors. It refuses available input without levels (plain
  `oscillux_mapping_process`, a null ext or an ext without the levels section), with a levels
  band count other than the frame's (including the all-zero levels written when the AGC
  configuration is refused) and with a non-finite relative band. `oscillux_mapping_reset`
  keeps the source. Default mapping and every existing vector are unchanged;
  `conformance/packing/levels.json`, written by `tools/mapping-vectors.py`, pins the relative
  path and is checked in `make gate`. npm `Mapper.setLevelSource` and Java
  `Oscillux.Mapper.setLevelSource` with `Mapper.LEVELS_ABSOLUTE` and `LEVELS_RELATIVE` bind it.
- Transition scheduler, `OscilluxTransition` (`oscillux_transition_*`): blend progress from
  presentation time, not frame count; a start quantised to the next beat or bar after a pre-roll,
  waiting at most `max_wait`, or at once without a confident beat; a duration of
  `duration_beats` clamped to 0.8–2.5 s (1.6 s without a beat); and bar-counted auto-advance.
  The last blending status has progress 1 exactly. `conformance/transition/reference.json`,
  written by the stdlib model `tools/transition-vectors.py`, is reproduced bit-exactly by the
  core, the C interface, the npm package (`Transition`) and the web host's port; JNI
  `Oscillux.Transition` binds it. No existing vector changed.
- DSP behaviour version 4 (`OSCILLUX_DSP_BEHAVIOR_V4`, OSC-BEAT-V4), an opt-in through
  `OscilluxDspVersionedConfig`: version 2 analysis with a causal beat-pointer tracker over
  every integer beat period from 60 to 200 BPM and a bar-position downbeat stage. It reports
  `beat_phase`, `bar_phase`, beats and downbeats at the frame's media time, compensating its own
  envelope delay, and re-acquires after silence or a tempo step within 2 s. An octave cue
  (OSC-BEAT-V4-OCTAVE) compares the hi-hat and snare onsets between beats with those on the
  beat, which moves fast backbeat music off half tempo for most of a track; it clears once no activity
  came for longer than the beat period, so a pause or a silent gap between songs decides
  afresh, while a gapless or crossfaded change keeps it unless the period moves by more than
  1.3 times other than halving or doubling; and it needs real mid-plus-high evidence, so
  bass-only pulses keep their tempo. Frames, levels and descriptors equal version 2 bit for
  bit; only `OscilluxDspFrameExt.beat` differs, and no field is added. It scores beat F 0.835 to 0.974 with a nonzero downbeat F on every synthetic
  score. It costs about 0.01 ms more per frame than version 3. The default stays version 2, and
  versions 1 to 3 keep every vector. Specified in `conformance/dsp/music/README.md`, "Beat
  tracker, version 4"; `conformance/dsp/music/beat-v4/` is written by the standard-library
  oracle `tools/dsp-beat-v4-vectors.py` and checked in `make gate`.
- `OSCILLUX_DSP_BEAT_LATENCY_V1_MS` to `OSCILLUX_DSP_BEAT_LATENCY_V4_MS` (16, 14, 16 and 3 ms;
  Rust `BEAT_LATENCY_V1_MS` to `BEAT_LATENCY_V4_MS`): the measured mean time from an onset to
  the media time of the frame whose beat output reports it, per behaviour version, for hosts
  that time a reaction to the beat (`conformance/dsp/music/README.md`, "Beat timing").
  Constants only; no entry point.

- Reaction sampler (`oscillux_reaction_*`, `OscilluxReaction`, `OscilluxReactionConfig`,
  `OscilluxBeatClock`; npm `ReactionSampler`, Java `Oscillux.ReactionSampler`): queues every
  mapped hop with its tracker beat and media time and samples the audio values of one display
  frame at its photon time. Onset, bass impact and flux are peak-held with release envelopes, so
  no onset between frames is lost; level, bands and spectrum are interpolated; beat phase is
  extrapolated from tempo, the beat and downbeat pulses peak at the beat's photon time, and a
  host beat clock can replace the tracker. Output, display, render-ahead and per-DSP-version
  analysis latencies are configuration (`oscillux_reaction_config_default`). Specified in
  `conformance/reaction/README.md` and pinned by `conformance/reaction/vectors.json`, written by
  the independent model `tools/reaction-vectors.py` and checked in `make gate`; `make gate`
  also runs the beat-to-photon harness (`make reaction-photon REACTION_DSP=1|2|3`).
- Beat-response lint (`make shader-beat-lint`, `tools/shader/beat-lint.mjs`): renders every
  bundled visual on a deterministic beat clock and fails one whose detrended luma or motion
  energy does not follow the beat pulse (r >= 0.35 at a peak lag of at most one frame) or that
  flashes more than three times a second, unless `conformance/shaders/beat-lint.json` lists it
  as ambient with a reason. Not part of gate (it needs Playwright Chromium). No C interface change.
- Overlay contract (`conformance/overlay/README.md`): up to `OSCILLUX_OVERLAY_MAX_REGIONS` (8)
  `OscilluxOverlayRegion`s, rounded rectangles in viewport fractions with
  `OSCILLUX_OVERLAY_MODE_*` bits (light or dark text, desaturate, blur, damp motion, damp
  flash), and an `OscilluxOverlayConfig` with the WCAG contrast ratio, presentation intensity,
  frame interval, alpha, output levels and the reduced-motion and premultiplied-alpha flags.
  `oscillux_overlay_pack()` writes the 320-byte std140 `OverlayUniforms` block
  (`conformance/packing/overlay-uniforms.schema.json`) that a present pass reads: the text
  background held at or below 0.18323 (light text) or at or above 0.17510 (dark text) at 4.5:1,
  and per-frame damping scaled by the frame interval. `oscillux_overlay_presentation_intensity()`
  and `oscillux_overlay_flash_config()` apply reduced motion (half intensity; at most 1 flash a
  second over 0.1 of the field) and never loosen the host's values. Invalid input is refused
  with `OSCILLUX_ERR_INVALID_ARGUMENT` before anything is written.
  `conformance/packing/overlay-uniforms.json`, written by `tools/overlay-uniforms-vectors.py`,
  pins packing and refusals and is checked in `make gate`. npm `OverlayConfig` and
  `OverlayRegions`, and Java `Oscillux.overlayConfigDefault`, `overlayPack`,
  `overlayPresentationIntensity` and `overlayFlashConfig`, bind it.
- Overlay regions as a stricter flash area: `oscillux_flash_analyzer_set_overlay()` with an
  `OscilluxFlashOverlay` (`oscillux_flash_overlay_default()`: a 0.05 luminance change, any
  darker end, 1 flash a second, no area allowance) holds the analyzer cells under damp-flash
  regions to it, and `oscillux_flash_analyzer_overlay_report()` gives the last frame's overlay
  outcome. Opt-in: an analyzer without an overlay measures and admits exactly as before, and
  every existing limiter vector is unchanged. `conformance/limiter/overlay-sequences.json`,
  written by `tools/limiter-overlay-vectors.py`, is checked in `make gate`. npm
  `FlashAnalyzer.setOverlay`, `clearOverlay` and `overlayReport`, and Java
  `Oscillux.FlashAnalyzer.setOverlay` and `overlayReport`, bind it.
- A shared present pass for the reference hosts, `shaders/present/present.glsl`: the WebGL2
  page and the SwiftUI app both draw it (`tools/shader/present.mjs` wraps it for GLSL ES 3.00
  and Metal) with a 336-byte block, 16 bytes of colour settings followed by the packed
  `OverlayUniforms`. The hosts mark their captions, badge and menu bar as overlay regions
  (`data-overlay` on the web, `.oscilluxOverlay` in SwiftUI), follow the platform's
  reduced-motion setting and move `safeRect` off the marked UI. `make overlay-check` measures
  every bundled visual through it. An optional host graphics
  layer (`OSCILLUX_PRESENT_LAYER`, `presentGLSL300/presentMSL({ layer })`) composites after tone
  mapping and before the contrast clamp, with a 128-byte `PresentLayerBlock` at buffer / block
  binding 1, texture 3 and sampler 1. Host-only; no C interface change.

### Changed

- The hosts' default CD+G key is `auto` instead of the Memory Preset colour: on each upload it
  keys the edge ring's commonest colour index and up to two more that each cover 1/8 of it
  (`hosts/README.md`). `cdgkey=mask:<hex>` / `-cdgkey mask:<hex>` key a mask directly.
- `cdg-composite.glsl`'s halo: a background pixel that touches both a light and a dark lyric
  colour now takes the clamp of the nearer one (the light one on a tie), instead of always the
  light one, so a dark outline around a white fill holds 4.5:1 against the visual.
- Apple artifacts are arm64 only: Intel Macs are not supported (owner decision 2026-10-31).
  The XCFramework's macOS slice is `macos-arm64` instead of the universal `macos-arm64_x86_64`,
  `x86_64-apple-darwin` is no longer a pinned target, and `make platform-gate` no longer runs
  the C harness under Rosetta 2. Hosts linking the macOS slice for x86_64 must drop that
  architecture.
- Release artifacts carry no debug info and no build-host paths. The Apple XCFramework slices
  are stripped of the prebuilt std's DWARF (about 18.4 MB to 2.4 MB per device slice, 37.6 MB
  to 4.9 MB for macOS). The Android libraries are stripped of debug sections. `$HOME`,
  `CARGO_HOME` and the checkout are remapped in panic locations, and `make artifacts` fails if
  a shipped file contains `/Users/`, `/private/var/folders/`, `/opt/homebrew/`,
  `/Applications/Xcode`, the home directory or the checkout path.
- **Breaking (Rust):** `oscillux_core::limiter::FlashConfig` gained the public `red_rule`
  field (`RedRule`), so code that builds it with a struct literal must set the field or use
  `..FlashConfig::default()`. The C ABI is unchanged: `OscilluxFlashConfig` grew behind
  `struct_size`, and 48-byte callers keep working.
- **Breaking (npm):** the package uses camelCase names: `abiVersion`, `wasmMemory`,
  `inputPtr`, `outputPtr`, `frameBytes`, `beginSegment` replace `abi_version`, `wasm_memory`,
  `input_ptr`, `output_ptr`, `frame_bytes`, `begin_segment`. `new Dsp(config, sampleCapacity,
  frameCapacity)` takes a `DspConfig` instead of positional sample rate, window, hop, bands and
  optional spectrum top, and `new Limiter(policy)` takes a `LimiterPolicy` instead of four
  positional values. Constructors throw an `Error` naming the refused status; `Limiter.reset`
  returns a status.
- **Breaking (npm, behaviour):** `new DspConfig()` selects DSP behaviour version 2, so
  `new Dsp` produces version 2 features by default. Set `behaviorVersion = 1` for the previous
  analysis.
- `make bench` and `benches/native-frame.c` time DSP behaviour version 2 by default. `make bench`
  also times version 1, and both must meet the frame budget.
- `make bench` times `oscillux_dsp_push_ext_f32`, so each timed frame also writes its
  descriptors, beat and levels, and prints a separate stages digest of the beat and levels. The
  existing output digests are unchanged.

- `oscillux_dsp_create` and `oscillux_dsp_config_validate` return
  `OSCILLUX_ERR_INVALID_ARGUMENT` when `spectrum_max_hz` is above `sample_rate_hz / 2`. The
  default 16 kHz top band is therefore refused at sample rates below 32 kHz; set
  `spectrum_max_hz` to at most Nyquist.
- `oscillux_dsp_push_f32` and `oscillux_dsp_push_f64` replace a NaN, infinite or larger than
  `FLT_MAX` sample with 0 and flag the next frame, so every output stays finite.
- `oscillux_governor_create` refuses a configuration whose promote threshold reaches its demote
  threshold, which made the level oscillate.
- `oscillux_limiter_process` writes the fail-safe frame on any error when `out` is not null,
  credits no elapsed time across a forward gap above 250 ms, and keeps the strobe ban across
  timeline discontinuities.
- `dist/manifest.json` from a non-Windows host records `details.windows` as `not-built` with the
  reason, so the Windows requirement record cannot be mistaken for a built DLL.
- Shader toolchain: `tools/shader/wrap.mjs` emits the GLSL 450 `VisualUniformBlock` members,
  `struct VisualUniforms` and `loadUniforms()` from `conformance/packing/visual-uniforms.schema.json`,
  one member per line. The `.vulkan.frag` and `.msl.frag` goldens changed in whitespace only,
  so byte parity with the Beamfall-era wrapper output is given up; the compiled SPIR-V is
  unchanged.
- Reference hosts and transitions (OSC-TRANSITIONS, OSC-0011, OSC-0012): both hosts schedule a
  switch with the transition scheduler (`hosts/web/transition.js`,
  `hosts/apple/Sources/TransitionDirector.swift`), so a switch takes the same wall time at 30,
  60 and 120 Hz, starts on the visible music's next bar (`quantise=bar|beat|none`), warms the
  incoming visual for 0.5 s first and ends on a p = 1 frame. The governor times the whole frame
  during a switch. Nineteen transitions remap p through a pacing curve so no frame-to-frame
  change exceeds 3x the median; page-curl's foil has no lime, aurora-veil's back hem is soft
  and chromatic-split takes at most 24 taps. Host-only; no C interface change. `make
  transition-check` (not in gate) runs the endpoint, pop and host checks.

- **Breaking (Rust, shader block):** `VisualUniforms` gained the host members `barPhase` and
  `downbeat` after `trailDecay`, at the formerly padded std140 offsets 84 and 88. No existing
  member's byte offset or the 448-byte block size changed, but the host values of
  `oscillux_core::packing::visual_uniforms` (`HOST_VALUES` 36 to 38) from `accent` on move up
  by two, and every host prelude must declare the two members. The packing vector and the
  shader example goldens were regenerated; the HLSL goldens on the pinned SPIRV-Cross.
- Reference hosts: the web page and the macOS app take every audio uniform from the reaction
  sampler, fed DSP version 3 and the mapper (`hosts/README.md`, "Pipeline"). The Swift beat
  envelope in `AudioTrack.swift` is gone. The default source is now a 125 BPM PCM loop
  (`syntheticPcm`) analysed through the same path, so host captures no longer match the
  `audioAt` signal that `render.mjs` and the iOS app still use. The web page adds audio file and
  microphone sources and `make host-wasm`. No C interface change.
- Visuals circuit, lattice, liquid-optics, lumen-field, memory-tunnel, rain, ribbons, vault and
  vinyl answer the beat within a frame: each ties one of its own elements to the beat pulse or
  decays it from the beat instead of easing in or peaking later. All 65 bundled visuals pass the
  beat-response lint with no ambient exemption. No C interface change.

### Deprecated

- Mapped slot 7 FLUX and slot 8 CENTROID without descriptors. `oscillux_mapping_process`, npm
  `Mapper.process` and `Mapper.processFrame`, and Java `Mapper.process` keep their earlier
  values bit for bit: FLUX repeats the broadband onset (slot 5 ONSET) and CENTROID is the
  band-index centroid of the band range. Both are deprecated proxies; map with descriptors
  through the `ext` variants for the spectral flux and the log-frequency centroid
  (`docs/portable-math.md`, "Mapping").

### Fixed

- The calm set no longer flashes (OSC-0014). Its visuals swelled with every kick, and in the web
  host's vivid mode the palette tour and its beat nudges recoloured them on the beat: 22–78
  light pulses in 15 seconds. They now breathe with the smoothed level through `osCalmBreath`
  and keep their own palette in vivid mode through `osPalCalm` (a host palette still applies),
  measured at 0 pulses in both colour modes. The eight existing visuals left the collection,
  which switches with `dissolve`, `heat-haze` and `smoke` only; `soft-bokeh`, `pastel-drift`,
  `ember-glow` and `still-pond` were reworked for colour and light (OSC-0014).
- The beat grid's sub-frame refinement interpolates only at a local maximum. A window maximum
  at the edge of a rising slope put the parabola's vertex outside the window. Synthetic
  beat-grid vectors are unchanged.
- The macOS reference app placed its overlay regions against the area below the title bar while
  the visuals fill the whole window, so top regions sat about 32 points above their text. The
  viewport is now measured over the full window. The app also takes `-capture <path>` with
  `-frames`: it writes the window, visuals and SwiftUI UI together, to a PNG and quits, with no
  display or Screen Recording permission.
- The limiter detects flashes on its input before applying `max_luminance_delta`. Before, a cap
  below 0.8 kept every onset under the flash threshold, so the flash-rate budget and strobe ban
  never ran and tightening the cap made the output less safe. Outputs at the default cap are
  unchanged.
