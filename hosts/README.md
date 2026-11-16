<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Reference hosts

Two small hosts that render the visuals in `shaders/` from one bundle: the imported reference
set and the Oscillux originals in `shaders/originals/`. They show
that the visuals do not depend on one host. Both hosts drive every visual with the same uniforms
and run the same pipeline:

- `web/`: a WebGL2 page that runs each visual's `web` target, GLSL ES 3.00.
- `apple/`: a SwiftUI app for macOS and iOS. It runs each visual's `msl` target through Metal.

Neither host is part of `make gate`, and neither is a product. A product host supplies its own
audio, images, catalog and UI.

## Running

| Command | Needs | Does |
|---|---|---|
| `make host-bundle` | the `shader-verify` toolchain (pinned glslangValidator and SPIRV-Cross) | wraps every visual that has both a `web` and an `msl` target into `out/hosts/visuals.json` |
| `make host-web` | `host-bundle`, python3, and for `host-wasm` the wasm32 target and `wasm-bindgen` | builds the wasm bindings into `out/hosts/wasm` and serves the repository on `http://127.0.0.1:8765/hosts/web/` (`HOST_PORT=…`) |
| `make host-mac` | `host-bundle`, Xcode, XcodeGen | generates `apple/OscilluxHost.xcodeproj` from `apple/project.yml` and builds the macOS app into `out/hosts/DerivedData` |
| `make host-ios` | as `host-mac`, plus an iOS Simulator runtime and the `aarch64-apple-ios-sim` Rust target | builds the core for the simulator and the app for the simulator named by `HOST_SIM` (default `iPhone 17`) on its latest OS |
| `make host-ios-device` | as `host-mac`, plus the `aarch64-apple-ios` Rust target | builds the core and the app for an iPhone or iPad; `HOST_TEAM=<team id>` signs it with that team's Apple Development identity, otherwise it is built unsigned |

`host-bundle`, `shader-verify` and `shader-render` put `SHADER_TOOLS` first on `PATH`. It defaults
to a local build of the pinned SPIRV-Cross 1.4.357.0 at `../../.oscillux-build/.tools/spirv-cross-1.4.357.0/bin`
relative to the checkout when that directory exists (the `Makefile` lists every place it looks).
Point it at another directory with `make host-mac SHADER_TOOLS=/path/to/bin`, or pass
`SHADER_TOOLS=` to use `PATH` unchanged. Without the pinned SPIRV-Cross, `host-bundle` stops
with a version mismatch rather than bundle Metal source that names the wrong compiler.

`host-bundle` reads `HOST_MANIFEST`, a space-separated list of manifests that defaults to
`shaders/originals/manifest.json shaders/manifest.json`, originals first. Ids must be unique
across the manifests, except that an entry marked `"overrides": true` replaces the visual with
its id in a later manifest. The originals use this to ship rebuilt versions of the imported
visuals under their existing ids, so the bundle holds 84 visuals: 23 native originals and 61
rebuilds. The imported bodies in `shaders/visuals/` stay as they are.

`host-bundle` also copies `hosts/collections.json` into the bundle's `collections` field: an
ordered list of curated sets, each an `id`, a `label`, a `labelKey` (`collection.<id>`) and an
ordered list of visual ids, and optionally `transitions`: the switch transitions a host uses
while the collection is shown. The one set so far, `calm`, holds slow, soft visuals with no beat
pulse, strobing or whiteouts for karaoke and quiet rooms, and only gentle transitions. The web host offers collections as a picker filter
(`collection=<id>`) and cycles the collection's transitions while one is chosen; the Apple host
does not yet. The bundle step fails when a collection names a visual or transition that is not
bundled or lists one twice (`--collections <path>` reads another file). Collections are reference-host data, not core
policy: a product host brings its own. The generated
Xcode project is not committed. Every Apple build is arm64 only (no Intel Macs, no x86_64
simulator). The app links the Oscillux static library on every platform: `target/release` on
macOS, and on iOS the per-SDK builds of the same targets the XCFramework packs
(`aarch64-apple-ios`, `aarch64-apple-ios-sim`). The macOS app is signed ad hoc. To run the iOS build, use
`xcrun simctl install booted out/hosts/DerivedData/Build/Products/Debug-iphonesimulator/OscilluxHost.app`
and then `xcrun simctl launch booted org.oscillux.host`.

The visual picker in both hosts filters by type (tunnels, flights, sky and space, light and
glass, liquid, scopes and meters, photo, dancers) and intensity (calm, lively, intense), from
`categories.json`. `host-bundle` copies each visual's category into the bundle and fails when a
bundled visual has none or the file names a visual that is not bundled, and `make shader-test`
checks the same against the default manifests. Prev and next, and the arrow keys on the web page,
step through the filtered visuals only.

Both hosts take the same twelve options, and the web page also takes `collection=<id>`. The web
page reads them from the query string, and the app reads them from launch arguments. The app also
takes `-capture <path>`, listed last.

| Web query | App argument | Effect |
|---|---|---|
| `visual=<id>` | `-visual <id>` | start on this visual |
| `collection=<id>` | none yet | show only this collection from `collections.json`, in its order, switching with its transitions |
| `type=<id>` | `-type <id>` | show only visuals of this type from `categories.json` |
| `intensity=<id>` | `-intensity <id>` | show only visuals of this intensity; ignored when the type has none |
| `frames=<N>` | `-frames <N>` | stop advancing after N frames |
| `size=<W>x<H>` | `-size <W>x<H>` | render at a fixed size instead of the view's size |
| `quality=auto\|0..3` | `-quality auto\|0..3` | fix the quality level, or let the governor pick it; the default is `auto`, except that a fixed size or frame count fixes it at 3 |
| `colour=manifest` | `-colour manifest` | use each visual's manifest palette and no saturation boost, instead of the default `vivid` mode |
| `transition=<id>` | `-transition <id>` | use this transition for every switch, instead of the default `auto` cycle |
| `trace` | `-beat-trace <path>` | record a trace for the checks: the page keeps its switches, their frames and the beat clock of every stepped frame in `window.__oscilluxTrace`; the app, given `-frames`, writes the synthetic source's beat clock per stepped frame (step, beat position, pulse, locked, tempo) to the file when it stops; a restart starts either trace again |
| `cdg=<url>` | `-cdg <path>` | show this CD+G stream's lyrics over the visuals, on the audio's clock; without it, the app loads a `.cdg` of the same name beside the audio file it opens. An MP3+G `.zip` here opens as `karaoke` |
| `karaoke=<url>` | `-karaoke <path>` | open an MP3+G `.zip` (a song and its `.cdg`, as karaoke is downloaded): play the song with its lyrics. In the app `-audio` takes one too |
| `cdgkey=auto\|preset\|table\|none\|index:<N>\|mask:<HHHH>` | `-cdgkey auto\|preset\|table\|none\|index:<N>\|mask:<HHHH>` | which CD+G colours show the visual beneath: `auto` (the default) keys the window's background colours, read from its edge on every upload; or the Memory Preset colour, the stream's transparent-colour table, none, colour index N, or the colours of a 16-bit hex mask |
| — | `-capture <path>` | macOS app only, with `-frames`: after the last frame, write the window (visuals and UI together) to a PNG and quit; it draws offscreen on a timer, so it needs no display, unlocked screen or Screen Recording permission |

For example, `?visual=aurora&frames=96&size=480x270` and
`-visual aurora -frames 96 -size 480x270` should show the same frame.

Both hosts have a visual picker, previous and next buttons, pause and restart. The web page also
has an image picker for image-input visuals. The Vivid / Manifest button switches the colour
mode, and the transition picker chooses the switch transition. On the web page, the left and right arrow keys
change the visual and the space bar pauses.

## Pipeline

In `manifest` colour mode the steps below match `tools/shader/render.mjs`. The `vivid` palette
tour and saturation boost are host-only:

- The step is a fixed 1/60 s: `time = frame / 60`, `dt = 1/60`.
- On the web page and the app, macOS and iOS alike, every audio uniform comes from the Oscillux reaction
  sampler (`oscillux_reaction_*`): PCM goes through DSP behaviour version 4 (the beat
  tracker), the mapper with relative levels, and the sampler, which each frame samples at its
  photon time. `web/audio.js` uses the wasm bindings; `apple/Sources/Reaction.swift` uses
  `ffi/include/oscillux.h` and the static library `make host-mac` or `make host-ios` builds.
- The default source is `syntheticPcm` in `tools/shader/synthetic-audio.mjs`: a 125 BPM, 4/4
  loop of kick, snare, hats and bass at 48 kHz, ported line for line in
  `apple/Sources/SyntheticAudio.swift` (`SyntheticPCM`). It is analysed one loop ahead and
  sampled on the step clock with no latency, so a capture is deterministic, and the two hosts
  give bit-identical values. It is not played.
- An audio file plays on a loop instead: **Open audio…** in the app's source menu or `-audio
  <path>` (FLAC, WAV, AIFF, ALAC, MP3), **Audio…** on the web page. On iOS the file comes from
  the Files picker and plays through the `playback` audio session. The sampler targets the
  frame's photon time (the display link's target timestamp in the app, the rAF time plus one
  frame on the web) less the audio output latency. Both hosts can also analyse the microphone
  (**Microphone** in the app's menu, **Mic** on the web), never played back: its first channel,
  on the host clock, with no output latency (`apple/Sources/Microphone.swift`, `MicSource` in
  `web/audio.js`). The app asks for the record permission first (`NSMicrophoneUsageDescription`)
  and on iOS uses the `record` session in `measurement` mode, without the voice processing
  the web page also turns off. The status line shows tempo, the beat in the bar and the
  tracker's confidence. Pause also pauses playback, restart rewinds it, and **Synthetic** goes
  back to the synthetic source.
- `tools/shader/render.mjs` keeps the older closed-form signal, `audioAt` in
  `synthetic-audio.mjs` (about 124 BPM), with `barPhase` and `downbeat` at 0. Captures from the
  hosts therefore differ from `render.mjs` goldens in their audio uniforms.
- Under `-audio` the beat comes from the offline beat grid
  (`apple/Sources/BeatGrid.swift`, `oscillux_beatgrid_*`, `conformance/beatgrid/README.md`)
  instead of the v4 tracker. The grid analyses the whole file once, after the DSP pass, so it
  can use the music after each beat as well as before it. Each frame sets the grid position of
  the music heard at the photon time as the reaction sampler's host beat clock, so beat phase,
  the beat and downbeat pulses, the beat count and the status line's tempo and beat in the bar
  follow the grid; its meter is 3 or 4, chosen from the audio. Before the first and after the
  last grid beat the clock extrapolates at the first and last interval. A file the grid
  refuses, or one with fewer than two grid beats, keeps the v4 tracker beat.
- The uniforms are `VisualUniforms` in std140 layout (448 bytes), with offsets from
  `conformance/packing/visual-uniforms.schema.json`. The web host writes each visual's
  `sensitivity`, params, `accent`, `motion`, `trailDecay` and, in `manifest` colour mode,
  `palette` from its default preset (`tools/shader/preset.mjs`, resolved once when the bundle
  loads); the macOS host writes the same values from the bundle's `params`, `trailDecay` and
  `palette`. Preset controls in the hosts are ticket OSC-TUNE-HOST-PANEL.
  In `vivid` mode, the default, `palette` is `tools/shader/palette-tour.mjs`: free mode
  (`palette.x < 0`), in which the originals read sixteen vivid palettes from
  `shaders/originals/common.glsl` in place of the library's. The tour loops through them,
  cross-fading to the next one every 6 s, and walks the palette coordinate as it goes. Each
  visual starts at an offset equal to its manifest palette index. `apple/Sources/PaletteTour.swift` is a port of it. With the default preset,
  `sensitivity` is 1, `accent` (0.15, 0.9, 0.72, 1) and `motion` 0. The host values no preset
  can set are:
  - `presentation0` (0, 1, 0, 0)
  - `presentation1` (i, r, 0, 0), where i is the presentation intensity (1, or 0.5 under
    reduced motion; see Overlay below) and r is the detail reduction below
  - `safeRect` as (left, top, right, bottom) corners: (0.05, 0.05, 0.95, 0.95), moved off the
    marked UI (see Overlay below)
- Feedback uses two RGBA16F targets that swap each frame (ping-pong). The image is bound as
  texture 0 and the previous frame as texture 1. One linear, clamp-to-edge sampler is used.
  A browser that cannot render to RGBA16F through `EXT_color_buffer_float` gets it through
  `EXT_color_buffer_half_float`, or else RGBA8 targets, which clamp the feedback to [0, 1]; the
  status line names either fallback (`half-float feedback`, `8-bit feedback`).
- The web host rebuilds a lost WebGL context in place when the browser restores it: the GL
  objects, the running visuals' programs, feedback targets of the same size (their history is
  gone) and the switch in progress, which carries on from its schedule. A switch whose outgoing
  layer was baked and held (it interrupted another) ends on the incoming visual instead. A
  context lost before the host has started is restored before it starts. It keeps the drawing
  buffer only for capture and trace runs (`frames=`, `size=`, `trace`), which read the canvas.
  `make web-host-check` forces a loss with `WEBGL_lose_context` (steady, mid-switch, with a
  held layer, before the next switch and before start-up) and masks the float extensions
  (OSC-WEB-HOST-RESILIENCE).
- The quality ladder, lowest first, sets the render scale and the detail reduction passed in
  `presentation1.y`: 0.5 and 1, 0.67 and 0.6, 0.83 and 0.25, then 1 and 0. The originals read
  the reduction to cut ray-march steps and noise octaves; the imported visuals scale by
  resolution only.
- In `auto` quality a port of the Oscillux governor (`tools/shader/governor.mjs`,
  `apple/Sources/Governor.swift`) steps the level. It is fed GPU time per frame: from the command
  buffer's GPU start and end times in the app, and from `EXT_disjoint_timer_query_webgl2` on the
  web. The app's figure covers the whole command buffer, including the present pass; the web
  figure covers only the visual's draw. Its thresholds are set for GPU time: it steps down when
  the averaged GPU time passes 90% of the 16.7 ms budget and up when it falls below 20%. The next
  level can cost about 3.7 times as much, so a band narrower than that would oscillate. A browser without the timer feeds it the frame interval with the default
  thresholds.
- The web page steps at most 60 times a second whatever the display rate, so `time` advances in
  real time on 120 Hz displays too.
- The status line shows the frame, time, render size, quality level and the averaged frame
  interval, with the GPU time in brackets where it is known. It updates every ten frames.
- The image input is a 64×64 gradient stand-in. The web page can load a file in its place.
- The present pass is `shaders/present/present.glsl`, shared by both hosts:
  `tools/shader/present.mjs` wraps it for WebGL2 and compiles it to Metal, and `host-bundle`
  puts both in the bundle as `present`. It scales saturation around Rec.709 luma and clamps the
  result at 0. In `vivid` mode the factor is 1.35 + 1.2(1 − c)², where c is the chroma
  (max − min) / max, so dull colours gain the most; in `manifest` mode it is 1. It then applies
  the ACES fit `x(2.51x+0.03) / (x(2.43x+0.59)+0.14)` to the luminance and scales the colour to
  match, moving a colour that would clip toward its grey, so hues hold (v2, CORE-0108; v1 mapped
  each channel and shifted bright hues by up to 43 degrees). Then come the overlay steps below,
  the exact piecewise sRGB encode and, on the 8-bit output, one code of triangular dither seeded
  by a frame counter. The hosts used a 1/2.2 power before OSC-OVERLAY; the sRGB curve is up to
  9/255 darker in the deep shadows and up to 1.5/255 lighter in the mid-tones. Its 368-byte
  block is 16 bytes of colour settings, the 320-byte `OverlayUniforms`, then `post0` (bloom,
  aberration, grain, dither) and `post1` (frame seed). The hosts leave bloom, aberration and
  grain at 0 and bind the scene at texture 4, which the pass reads only for bloom; the bloom
  chain is `shaders/present/bloom.glsl` (`docs/shader-toolchain.md`, "Present pass").
- Changing the visual, or restarting one, blends from the old picture to the new one, as
  scheduled under "Switch scheduling" below. The new visual starts at frame 0 with cleared feedback. The present pass
  dissolves between the two linear images with smoothstep easing. Bright areas of the new
  image appear first, and the dissolve spreads outward from the centre. The incoming image settles
  from a 5% zoom and the outgoing image grows by 8%. When a switch starts, each host checks its
  averaged GPU time from before the switch: the visual pass on the web, the whole command buffer
  in the app. The outgoing visual keeps moving at its own speed: it steps every frame at or below
  45% of the budget, and otherwise every second or third frame, advancing its clock by as many
  steps, so the average frame stays within 90% of the budget. Above 67.5% of the budget it holds
  its last frame, so the frame rate does not drop. Without a GPU time it steps every second frame. During a switch the whole
  frame is timed for the governor (see "Switch scheduling"). A switch made during a switch first bakes the picture on screen into the outgoing
  layer, so nothing jumps. A size change ends the switch. The first visual starts directly, so
  `frames=` and `size=` captures do not change.
- Manifests can also list transitions (`"transitions"` entries with `id`, `body`, `targets` and
  `header`; bodies in `shaders/originals/transitions/`). A transition body defines
  `vec3 transition(vec2 uv, float p, VisualUniforms u)`: `FROM(uv)` reads the outgoing frame
  (texture 0) and `TO(uv)` the incoming one (texture 1), `p` is the progress from 0 to 1 and
  `presentation0.y` a seed for the switch. The other uniforms are the incoming visual's. With
  a transition, a switch renders this pass into an RGBA16F target at render size, and the
  present pass maps that target in place of its own dissolve. In `auto` both hosts take the
  transitions in the same fixed shuffle, one per switch; the seed is the switch count times
  0.618034, modulo 1. A switch during a switch bakes the transition's blend into the outgoing
  layer. A transition that has not compiled yet, or failed to, leaves that switch to the
  present pass's dissolve. Each switch, and each change of the transition picker, compiles the
  next transition ahead. On the web without `KHR_parallel_shader_compile`, that compile holds
  the frame instead.
- Compiling a visual held the frame for 13–123 ms on the web and 330–500 ms in the app on this
  machine, so the hosts compile ahead. The app compiles each pipeline on a background queue.
  The web page uses `KHR_parallel_shader_compile`. Without it, a visual that was not compiled
  ahead still holds the frame that switches to it.
  A switch waits for the compiled visual while the current one keeps running. After each
  switch both hosts compile the previous and next visuals, so those buttons switch at once.
  Compiled visuals are kept until the page or app closes.

## Overlay

Both hosts show a caption (the visual's title, white text), a badge (black text) and the
control bar over the visuals, and tell the present pass where they are, as Oscillux overlay
regions (`conformance/overlay/README.md`):

- On the web, an element marked `data-overlay="light-text desaturate blur damp-motion
  damp-flash"` (any of the mode names) is a region; `data-overlay-strength`,
  `data-overlay-radius` and `data-overlay-feather` (CSS pixels) shape it. `web/overlay.js`
  reads the marked elements' boxes again whenever their layout changes, and packs the block
  with a port of `oscillux_overlay_pack` (checked against the packing vectors by
  `make overlay-check`).
- In the app, a view marked `.oscilluxOverlay(mode, cornerRadius:feather:strength:)` is a
  region, measured against the view marked `.oscilluxViewport()` (`apple/Sources/Overlay.swift`).
  The block comes from `oscillux_overlay_pack` on macOS and iOS.
- Under a light-text region the visual is held at or below relative luminance 0.18323, and
  under a dark-text region at or above 0.17510, so white or black text keeps 4.5:1 over any
  frame. The ceiling wins where the two overlap. Damp-motion and damp-flash regions, and with
  reduced motion the whole frame, blend each frame with the previous presented one and limit
  its luminance step. Reduced motion also halves `presentation1.x`, uploads `trailDecay` 0 and
  turns grain off. The web page follows
  `prefers-reduced-motion`, the app the system's Reduce Motion setting (macOS and iOS); `-reduceMotion
  yes` (or `no`) overrides it in the app.
- `safeRect` is the 5% margin with each region moved out of it across the viewport edge that
  costs the least depth, so visuals that read it keep their features clear of the UI.

- A host graphics layer (karaoke lyrics, say) builds the pass with
  `presentGLSL300({ layer })` / `presentMSL({ layer })` and a source defining
  `vec3 oscillux_present_layer(vec2 uv, vec3 c)`, which takes and returns display-linear colour.
  It runs after tone mapping and before the contrast bounds, which still hold over it, and
  reads `PresentLayerBlock { vec4 layer[8]; }` (block binding 1 / Metal buffer 1) and texture
  `uL` (unit 3 / Metal texture 3, sampler 1) through `PRESENT_LAYER_TEX(uv)` and
  `PRESENT_LAYER_FETCH(px)`. The layer is not damped and does not enter the history.
- CD+G lyrics are that layer in both hosts: the bundle's `presentCdg` pass
  (`tools/shader/cdg-layer.mjs`, `shaders/cdg/cdg-layer.glsl`), used on screen while a stream is
  loaded. Each stepped frame advances the core's decoder (`oscillux_cdg_*`; `Cdg` in the wasm
  bindings) to the frame's media time, the synthetic step clock or the file's position heard at
  the photon (after output latency, as the analysis), and copies the 288 x 192 window to the layer texture only when it changed
  (`web/cdg.js`, `apple/Sources/CdgLayer.swift`). The web page also takes a dropped `.cdg` with
  the audio, and both hosts have a Lyrics… picker. Lyrics belong to their song: another song brings its own (a dropped pair, a
  sidecar) or none.
- Karaoke is usually downloaded as an MP3+G `.zip`. Both hosts open one dropped (the web page,
  and the macOS app's window; the iOS app has no drop), picked in the Lyrics… or audio picker, or
  given by `karaoke=` / `-karaoke` (`web/karaoke-zip.js`, `apple/Sources/KaraokeZip.swift`, the
  same rules and messages). The archive is untrusted, so it is read in memory and refused whole
  for an unsafe entry name (absolute, a drive letter, a backslash, a NUL or `..`), more than 64
  entries, an archive over 64 MiB, a `.cdg` over 32 MiB or a song over 64 MiB (declared or
  inflated), ZIP64, multi-part or encrypted archives, a method other than stored or deflate,
  and a CRC or size mismatch. Directories, `__MACOSX/` and `._` AppleDouble files are skipped.
  One `.cdg` and one song (mp3, ogg, oga, opus, m4a, aac, wav, flac) pair whatever their names;
  otherwise the pair is the one stem with exactly one of each. The app writes the song to a
  temporary file only for its decoder to open, and deletes it after.
- The `auto` key is host data, not a core mode: on each upload the host reads the 16 per-index
  pixel counts of the window's edge ring (`oscillux_cdg_index_counts` with
  `OSCILLUX_CDG_REGION_EDGE`, 8928 pixels) and keys the commonest index, plus each next commonest,
  up to three in all, that covers at least 1/8 of the edge (ties go to the lower index), as a
  mask. Discs draw their background to the border, so this keys a blue background, or a tiled
  one, but not the lyric colours inside it. If the counts cannot be read, the host keys the preset colour.
  `make cdg-host-check` drives the web page headlessly and checks that every stepped frame
  holds exactly the packs of its media time (across the synthetic loop's wrap, a backward seek),
  that a dropped song's lyrics trail its write position by the output latency,
  that the layer texture matches the decoder's window, that the lyrics reach the canvas, that
  `auto` picks the expected masks on `karaoke-blue` and `karaoke-tiles`, and that an MP3+G `.zip`
  dropped or given by `karaoke=` opens its song and lyrics. `make shader-test`
  (`tools/shader/test-karaoke-zip.mjs`) and `make karaoke-zip-swift` check both readers on the same
  synthetic archives.

The hosts mark only their own UI. A product host marks its own menus and text the same way.
`make overlay-check` renders every bundled visual and a synthetic strobe through the present
pass with fixed regions, and measures the bounds, the damping, reduced motion, the sRGB encode
and WebGL2 / Metal parity. Each visual uses its default preset;
`OVERLAY_ARGS='--preset NAME'` uses the accepted case NAME of
`conformance/presets/adversarial.json` instead.

The present pass belongs to Oscillux. Parity with the upstream post chain (bloom, grading and the
GPU flash limiter pass) is ticket OSC-POST-PARITY. The hosts do not yet run the CPU flash limiter
(its overlay regions are part of the C API).

The app compiles each visual's MSL source at runtime, as `tools/shader/metal-smoke.swift` does,
and caches the pipeline for each visual. A visual that fails to compile shows its error in the
window.

## Switch scheduling

Both hosts schedule a switch with the same transition scheduler, `hosts/web/transition.js` and
`apple/Sources/TransitionDirector.swift`, ports of `crates/oscillux-core/src/transition.rs`
checked exactly against `conformance/transition/reference.json` (`make transition-vectors-check`
runs the web port; the Swift port was checked with a scratch harness).

- The blend progress p is a function of presentation time, not of frame count, so a switch
  takes the same wall time at 30, 60 or 120 Hz. Presentation time stops while paused. The last
  blended frame has p = 1 exactly, and the next frame shows the incoming visual alone.
- The incoming visual starts at the request and runs offscreen, with its feedback, for a 0.5 s
  pre-roll; until it shows it is stepped to keep up with presentation time. While p = 0 the
  outgoing visual shows alone. A switch made before the incoming visual has shown drops it.
- The blend starts on the next bar (by default) or beat of the visible visual's music after the
  pre-roll, waiting at most one bar, and lasts four beats clamped to 0.8–2.5 s. Without a
  confident beat it starts after the pre-roll and lasts 1.6 s. The synthetic music's beat
  comes from its clock; in the app a playing file's or the microphone's tracked beat is used.
- During a switch the governor times the whole frame, both visuals and the blend, and its level
  applies to the render size and detail only between switches.

| Web query | App argument | Effect |
|---|---|---|
| `quantise=bar\|beat\|none` | `-quantise bar\|beat\|none` | where a switch starts: the next bar (default) or beat after the pre-roll, or at once |
| `trace` | `-beat-trace <path>` | record each switch and the beat clock in `window.__oscilluxTrace` (the app writes only the beat clock), for `node tools/shader/transition-check.mjs --host` |
