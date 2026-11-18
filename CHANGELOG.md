<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Changelog

Notable changes to the C interface (`ffi/include/oscillux.h`) and to behavior a host can
observe through it. The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versions and deprecations follow [docs/api-stability.md](docs/api-stability.md).

0.2.0 is the first release published in this repository. `OSCILLUX_ABI_VERSION` is 1, and every
addition below kept ABI version 1: no existing signature, struct layout or status value changed.

## [Unreleased]

### Changed

- Visuals fit the frame's aspect (CORE-2491). `centered()` and `motionCentered()` in
  `shaders/library.glsl` lean toward the frame's short side below aspect 1 (scale aspect^-0.7),
  so subjects stay in frame on a portrait phone; output at 16:9 and wider is unchanged. Spectrum,
  Terrain and Spectral City choose their column count from the frame aspect with the new
  `fitColumns()`, never under one column per 4 px, so bars are not squeezed together on a phone.
  Ink sizes its dye splats against the short side and no longer whites out in portrait.
- Visuals keep within the general flash limit on their own (CORE-2492): under a loud master no
  catalogue visual makes more than 6 large-area luma transitions a second or any large-area red
  transition before the limiter, so the limiter holds far less (stale tiles). Beat accents in
  about 30 visuals are softer or ride on motion instead of brightness; Wave Tunnel's rings no
  longer flash on onsets. `make visual-flash-check` runs the budget
  (`limiter-red-audit.mjs --max-luma`).

### Fixed

- The frame flash limiter now limits fine patterns that reverse inside a sub-block, such as a
  10 Hz checkerboard of 4 px squares, whose sub-block means never change. The `rows` pass reads
  the previous output and counts pixels whose luma rose or fell by a step; a sub-block where at
  least 7/16 rose and 7/16 fell requests luma up and down, granted together at two tokens
  (CORE-2515). **Host binding change:** the `rows` pass now samples `uHist` (the previous output,
  the same texture the `output` pass reads) at texture unit 1 besides `uFrame` at unit 0; a host
  that does not bind it reads an unbound sampler. Frame conformance vectors re-recorded, with a
  new `fine-checker-10hz` case.
- The frame flash limiter's output pass feathers around a held sub-block on warm and red pixels
  too, instead of skipping every pixel with `r > g + b` (most oranges), which showed as hard
  rectangular tiles. A blended pixel whose saturated-red code would move further from history
  than the input's shows the input instead, so the feather adds no red transition (CORE-2413).
  Frame conformance vectors re-recorded.
- Feedback trails (`feedbackTrail`) and Ink's advection scale their per-frame decay, zoom and
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
