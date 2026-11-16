<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Checksum-pinned distributions

`make artifacts` writes `dist/manifest.json`, listing SHA-256 and byte size for
its selected outputs plus the clean source revision and actual compiler/SDK/NDK versions.
Commit tracked source changes before building a revision-bound manifest.
Freeze source for the entire build: do not edit, commit, check out, or merge while
`make artifacts` runs. Its end-of-build receipt does not detect every mid-build
source mutation; this is an explicit caller precondition. It builds the Rust toolchain pinned in rust-toolchain.toml
with locked dependencies. Install wasm-bindgen-cli **0.2.130** (matching the crate)
and expose it on PATH. Python 3, Cargo, and the platform tools below are required. The
notice bundle reads crate licences with `cargo metadata --offline`, so on a host whose
`CARGO_HOME` has not fetched this lockfile yet, run `cargo fetch --locked` first.
Nothing is published, signed or tagged by this command.

- Apple: full Xcode with macOS/iOS/tvOS and simulator SDKs on an Apple Silicon Mac. The
  XCFramework has arm64 macOS, arm64 iOS/tvOS devices, and arm64 simulators. Intel Macs are
  not supported (owner decision 2026-10-31).
- Android: set `ANDROID_NDK_HOME` to an NDK installation (qualified with
  28.2.13676358); JDK 9+ supplies `javac --release 8`. The AAR contains arm64-v8a
  and armeabi-v7a C ABI libraries plus JNI glue, classes.jar and the C headers.
  Minimum Android API is 21. Runtime qualification is `make platform-gate` (below).
- Windows: on Windows, Visual Studio MSVC x64/ARM64 tools, a Windows SDK, and a
  Windows-native rustup with the pinned toolchain and both `*-pc-windows-msvc` targets.
  Other hosts emit `windows-required-host.json`, explicitly a requirement record,
  not a DLL, and record `details.windows.status = "not-built"` with the reason in the
  manifest. Run `make artifacts ARTIFACT_TARGETS=windows` on that host.
- WASM: the npm tarball contains wasm-bindgen web ES modules, TypeScript types,
  wasm, and the C layout header. The manifest records raw and gzip wasm sizes;
  the enforced budget is at most 100 KiB gzip. No npm registry access is needed to consume it.

Every binary archive embeds LICENSE, LICENSING.md, THIRD-PARTY-NOTICES.md, SPDX.txt and registry
third-party attribution/licence texts. These are copied; packaging never changes
the source licensing terms. The Windows requirement JSON is not a binary archive.

`ARTIFACT_TARGETS=apple,android,windows,wasm` is the default; an explicit subset is
supported for individual build hosts. Missing SDKs or a mismatched wasm-bindgen
CLI fail. A failed run removes the old manifest, so old archives cannot constitute
a successful new run. Consumers must use the current manifest, not glob dist.

Archives normalize file order, permissions, owners and timestamps; static archives
use ZERO_AR_DATE. Shipped binaries carry no debug info: Apple slices pass through
`xcrun strip -S` (the prebuilt std otherwise ships about 16 MB of DWARF per slice) and Android
libraries through the NDK's `llvm-strip --strip-debug`. Compiler paths are remapped: `$HOME` to
`/home`, `CARGO_HOME` (registry and git sources) to `/cargo` and the checkout to `/oscillux`.
Before writing the manifest, `make artifacts` searches every shipped file, and every member of
nested archives, for `/Users/`, `/private/var/folders/` (the macOS per-user temporary
directory), `/opt/homebrew/`, `/Applications/Xcode`, the home directory and the checkout path,
and fails if one appears.
Reproducibility is checked with the
same pinned tool versions by saving the manifest, deleting only `target/artifacts`,
rebuilding, and comparing the manifests. Different SDK/tool versions are not claimed
to be byte-identical. Builds use the dedicated target/artifacts directory and must
not run concurrently within the same worktree.

## Platform matrix

What is claimed, what an artifact actually contains, and where the conformance vectors have
actually run. "Checked" means `cargo check` in `make gate` (`make targets`); it compiles the
crates and proves nothing at run time. "Header asserts" means the `header_layout` test in
`make gate` compiles C11 `_Static_assert`s for every struct size, alignment and field offset
with `clang --target=<triple>` and compares them with a pointer-width layout model that is
itself checked against rustc on the host.

| Target | Claimed | Built (artifact) | Executed |
|---|---|---|---|
| macOS arm64 | yes | XCFramework | `make gate` (host tests); `make platform-gate` links the slice and runs the C harness |
| macOS x86_64 | no | **NOT BUILT**: not supported (owner decision 2026-10-31); `x86_64-apple-darwin` is not in rust-toolchain.toml | no |
| iOS arm64 device | yes | XCFramework | linked by `make platform-gate`; **NOT EXECUTED**: no device is attached to the gate |
| iOS arm64 simulator | yes | XCFramework | `make platform-gate`: C harness and the portable Rust suites on an iOS simulator |
| iOS x86_64 simulator | no | **NOT BUILT**: not supported (owner decision 2026-10-31); only Intel Macs need it | no |
| tvOS arm64 device | yes | XCFramework | linked by `make platform-gate`; **NOT EXECUTED**: no device |
| tvOS arm64 simulator | yes | XCFramework | `make platform-gate`: C harness and the portable Rust suites on a tvOS simulator |
| Mac Catalyst | no | **NOT BUILT**: `*-apple-ios-macabi` is not in rust-toolchain.toml; no slice | no |
| visionOS | no | **NOT BUILT**: `aarch64-apple-visionos(-sim)` is not in rust-toolchain.toml and no visionOS simulator runtime is installed on the qualification host | no |
| Android arm64-v8a | yes | AAR | `make platform-gate` on an arm64-v8a emulator: C harness, `AdapterSmoke` through the shipped classes.jar and JNI glue on ART, and the portable Rust suites |
| Android armeabi-v7a | yes | AAR | linked by `make platform-gate`; header asserts; **NOT EXECUTED**: Apple Silicon cannot run AArch32 and the gate's arm64 emulator reports no `armeabi-v7a` ABI (the gate runs the harness there if it ever does). Needs a 32-bit-capable device |
| Android x86_64 / x86 | no | **NOT BUILT**: `x86_64-linux-android` is not in rust-toolchain.toml and no x86 emulator runs on the qualification host | no |
| Windows x64 | yes | `oscillux-windows.zip`, built only by `make artifacts ARTIFACT_TARGETS=windows` on a Windows host; **NOT BUILT** on macOS/Linux, where the manifest records `not-built` and the requirement JSON | `make platform-gate` with `--windows-host`: `oscillux.dll` built from the same source with MSVC link.exe, then the C harness (cl.exe) and the portable Rust suites natively on Windows x64; header asserts. The shipped zip itself is **NOT EXECUTED** |
| Windows ARM64 | yes | `oscillux-windows.zip`, as Windows x64 (needs the MSVC ARM64 build tools) | header asserts; `make platform-gate --windows-host` links it when the host has the MSVC ARM64 tools and fails naming them otherwise; **NOT EXECUTED**: no Windows ARM64 device |
| Linux x86_64, aarch64 | crates only | **NOT BUILT**: no Linux artifact kind is defined | checked; **NOT EXECUTED** on Linux |
| wasm32 (npm) | yes | npm tarball | `make gate` runs the portable Rust suites on wasm32-wasip1 (`make test-wasi`); `make platform-gate` runs `tools/test-wasm-package.mjs` on the shipped package under Node; header asserts for `wasm32-unknown-unknown` |

The portable Rust suites are the `tools/test-wasi.py` list (`core2_*`, DSP streaming and
conformance, limiter, curves, governor and mapping vectors). The C harness
(`packaging/smoke/conformance_smoke.c`) runs every `conformance/dsp` fixture through
`oscillux_dsp_push_f64` and compares each frame within the Rust test's tolerances and the whole
output with the digest `dsp_conformance.rs` records, bit-exact; then it runs the region flash
sequences that `make jni-smoke` uses.

### Platform gate

`make platform-gate` is the runtime qualification for the Apple, Android and npm artifacts,
and, on request, for the Windows targets. It is not part of `make gate` (it takes minutes and
needs simulators, an emulator and, for Windows, a PC).
**Run it on the exact head before publishing or attaching artifacts, and after any change to
the C header, the FFI crate, packaging, or the artifact build.** Record its log with the
release evidence.

Requirements: an Apple Silicon Mac with full Xcode and an installed iOS and tvOS simulator
runtime; `ANDROID_HOME` with the emulator, platform-tools, cmdline-tools, a build-tools with
`d8`, and the `system-images;android-34;aosp_atd;arm64-v8a` image; `ANDROID_NDK_HOME`; a
JDK; Node; and everything `make artifacts` needs. The gate downloads nothing and fails if a
runtime or image is missing.

It builds `make artifacts ARTIFACT_TARGETS=apple,android,wasm` for the clean HEAD and checks
each archive against the manifest. `PLATFORM_GATE_ARGS=--reuse-dist` accepts an existing
`dist/manifest.json` instead, only if it names exactly the clean HEAD. It then links and runs
every row above that says `make platform-gate`, and prints one line per slice and check with
PASS, FAIL or LINK ONLY. Any FAIL, including a simulator or emulator that does not boot, fails
the gate. The gate also checks that the XCFramework and the AAR carry exactly the expected
slices and ABIs, so a missing or unexpected one fails it.

It creates its own simulator devices (`oscillux-platform-gate-<system>-<pid>`) and AVD
(`oscillux-platform-gate-<pid>`, under `ANDROID_AVD_HOME`, default `target/platform-gate/avd`)
on emulator port 5810 (`PLATFORM_GATE_EMULATOR_PORT`), and shuts down and deletes them on
exit, failure, SIGINT, SIGTERM and SIGHUP. Existing simulators and AVDs are not touched. If the port
is in use the gate fails instead of reusing that emulator.

**Windows leg.** `PLATFORM_GATE_ARGS='--windows-host HOST'` adds it. Without that flag the gate
lists both Windows targets as NOT EXECUTED in its summary; NOT EXECUTED does not fail the gate.
HOST is an ssh destination (key authentication, no prompts) for the WSL shell of an x64 Windows
PC with WSL interop enabled and Visual Studio 2022 with the MSVC x64 build tools and a Windows
SDK. No Rust, Python or repository checkout is needed there, and the gate installs nothing. The
pinned rustc on the Mac compiles `x86_64-pc-windows-msvc`. Every link runs on HOST with the real
MSVC link.exe, through `tools/msvc-remote-link.py`: it uploads each input once into a
content-addressed cache, rewrites the paths, runs link.exe in the `vcvarsall` environment, and
copies the outputs back. The leg builds `oscillux-ffi` as `tools/artifacts.py` does, into its own
emptied target directory (`target/platform-gate/windows-target`), so every link is fresh. It then
builds `conformance_smoke.c` with `cl.exe /W3 /WX` against `oscillux.dll.lib` and runs it with
every DSP fixture and region sequence, then runs each portable Rust suite, all natively on
Windows. `aarch64-pc-windows-msvc` is linked only when the Visual Studio on HOST has
`VC\Tools\MSVC\<version>\lib\arm64` and `bin\Hostx64\arm64`. Otherwise that row fails and
names both paths. The work directory, `%TEMP%\oscillux-platform-gate-<pid>`, is removed on
exit, failure, SIGINT, SIGTERM and SIGHUP. The leg takes about three minutes.

The Windows leg qualifies the source and the C ABI on Windows; it does not build the shipped
`oscillux-windows.zip`. That takes `make artifacts ARTIFACT_TARGETS=windows` run natively on
the PC from a clean checkout.

## Adapter buffers

Both adapters wrap the C interface in `ffi/include/oscillux.h`; its comments define units,
ranges and status codes. Configuration and lifecycle calls (constructors, `*Default`,
`validate`, `statusString`, `free`/`close`) may allocate and belong off the frame path.
Frame calls (`push`, `process`, `processFrame`, `evaluate`, `record`, `reset`, `pack`)
reuse preallocated buffers and do not allocate.

### npm (wasm)

The package ships `oscillux.d.ts` (`package.json` `types`) with camelCase names.
Configuration value classes (`DspConfig`, `LimiterPolicy`, `FlashConfig`, `CurveConfig`,
`CurveInput`, `GovernorConfig`, `TransitionConfig`, `MappingConfig`) start from the C defaults and expose each field as a
property, for example `config.sampleRateHz = 48000`. `DspConfig` wraps
`OscilluxDspVersionedConfig`: `behaviorVersion` defaults to 2, 1 selects the ABI-1
analysis, 3 adds the version 3 beat tracker and 4 the version 4 beat tracker (see
`conformance/dsp/README.md` and `conformance/dsp/music/README.md`). `DspConfig.validate()` returns the
first refused member as spelled in oscillux.h, or undefined. Constructors throw on a
refused configuration. Enums (`CurveKind`, `CurveEasing`, `CurveFlag`, `MappedValue`,
`FieldSource`, `DspFlag`, ...) carry the header constants.

Handle classes own preallocated buffers inside `wasmMemory().buffer`, addressed by byte
offsets:

- `new Dsp(config, sampleCapacity, frameCapacity)`: write Float32 interleaved PCM at
  `inputPtr()`, call `push(sampleCount, channels)` (`sampleCount` counts scalars), then
  read `produced()` frames from `outputPtr()`, each `frameBytes()` long. Read the sequence
  at offset 0 using `DataView.getBigUint64(offset, true)`; flags and band count are uint32
  at 8/12, then time, RMS, loudness, four onsets and 64 spectrum doubles at offset 16. No
  sequence is converted to a JavaScript Number. `consumed()` counts sample frames.
  `new Dsp(config, sampleCapacity, frameCapacity, f64Capacity)` also allocates a Float64
  input of `f64Capacity` scalars (default 0) at `inputF64Ptr()`; `pushF64(sampleCount,
  channels)` analyzes it through `oscillux_dsp_push_f64`, the same frames as `push` for
  Float32-representable samples. `pushExt(sampleCount, channels)` and
  `pushExtF64(sampleCount, channels)` produce the same frames and also write one
  `OscilluxDspFrameExt` per frame at `extPtr()`, each `extBytes()` long. The first of them
  allocates that buffer of `frameCapacity` elements; `extPtr()` is 0 until then. Each element
  holds struct_size and reserved uint32 at 0/4, then momentary LUFS, short-term LUFS, width, balance, centroid Hz
  and spectral flux as doubles at 8, 16, 24, 32, 40 and 48. The beat follows (tempo BPM, beat
  phase, bar phase and confidence as doubles at 56, 64, 72 and 80; beat, downbeat, beat in
  bar and reserved as uint32 at 88, 92, 96 and 100), then the levels (band count and reserved
  uint32 at 104/108, relative low/mid/high doubles at 112, absolute ones at 136 and 64
  relative band doubles from 160).
- `new Limiter(policy)`: two seven-double frames (time, broadband, low, mid, high, red,
  area) at `inputPtr()`/`outputPtr()`; `process()` and `reset()`.
- `new FlashAnalyzer(config)`: `regionCount()` (columns * rows) Float64 pairs (luminance,
  red), row-major, at `regionsPtr()`; `setRegionFromLinearRgb(index, r, g, b)` fills one
  from a mean linear-light color. `measure(timeMs)` or `admit(timeMs)` reads them and
  writes the report: `admitted`, `exceeds`, `generalTransition`, `redTransition`,
  `generalRegions`, `redRegions`, `flashesInWindow`, `redFlashesInWindow`, `timeMs`, or
  raw at `reportPtr()`. When `admitted` is false, keep presenting the last admitted image.
- `new Curve(config)`: `evaluate(input)` returns a number, or undefined when refused.
- `new Governor(config)`: `record(frameMs)`, `reset(level)`; `level`, `emaMs` (undefined
  until a sample is averaged) and `refreshMs` read the latest stats.
- `new Transition(config)` (`TransitionConfig`): `request(timeSeconds, beatPhase, barPhase,
  tempoBpm, confidence, quantise, maxWaitSeconds)`, `update(timeSeconds, beatPhase, barPhase,
  tempoBpm, confidence)` once per frame, `status(timeSeconds)` and `reset()`; `progress`,
  `state`, `requestSeconds`, `startSeconds`, `endSeconds`, `quantise` and `autoRequested` read
  the last successful call (`conformance/transition/README.md`).
- `new Mapper(config)` (`MappingConfig.fromDsp(dspConfig)` matches an analyzer):
  `process(dsp, index, unavailable)` maps frame `index` of the last `push`;
  `processFrame(unavailable)` maps a frame written at `frameInputPtr()`.
  `processExt(dsp, index, unavailable)` maps frame `index` of the last `pushExt` with its
  descriptors (FLUX and CENTROID; refused after a plain `push`), and
  `processFrameExt(unavailable)` maps the frame at `frameInputPtr()` with the
  `OscilluxDspFrameExt` written at `extInputPtr()`. Without descriptors FLUX and CENTROID
  keep their deprecated proxies, the broadband onset and the band-index centroid.
  `setLevelSource(LevelSource.Relative)` maps BASS, MID, TREBLE and the spectrum from the ext
  frame's relative band levels (bandCount at 104, bands from 160); the mapper then refuses
  `process`, `processFrame` and ext levels whose band count is not the frame's.
  `LevelSource.Absolute` restores the default. Read results with
  `value(MappedValue.*)` and `spectrum(bin)`, or at `outputPtr()`.
- `new Packer(fields, blockSize, hostCapacity)` takes `UniformField` objects; write float64
  host values at `hostPtr()`, call `pack(mapper, hostCount)` and upload `blockSize()` bytes
  from `outputPtr()`.
- `new BeatGrid(config, samples)` analyses a whole interleaved Float32 PCM array offline
  (`BeatGridConfig`: `sampleRateHz`, `channels`, `beatsPerBar`, `minBpm`, `maxBpm`; it throws
  naming a refused member) and copies the beats to `beatsPtr()`: `beatCount` elements
  `beatBytes()` (24) apart, time and local tempo as doubles at 0/8, beat in bar and bar index
  as uint32 at 16/20. `tempoBpm`, `beatsPerBar`, `barCount`, `confidence` and
  `durationSeconds` summarize the grid. `clock(mediaTimeSeconds)` writes `beatPhase`,
  `barPhase`, `beatIndex` (-1 without a position), `beatInBar` and `localTempoBpm` without
  allocating; the constructor allocates and belongs off the frame path.

Frame methods return 0 or a negative status (`statusString(status)` describes it). Refresh
typed-array views after any constructor and after a `Dsp`'s first `pushExt` or `pushExtF64`,
since memory growth detaches them. Do not access
buffers after `.free()` or share an adapter across threads.

### Java (JNI)

The Java `org.oscillux.Oscillux` adapter exposes thread-confined AutoCloseable handles
(`Dsp`, `Limiter`, `FlashAnalyzer`, `Curve`, `Governor`, `Transition`, `Mapper`, `Packer`); construct, operate and close
on the same thread. Allocate native-order direct ByteBuffers with `Oscillux.buffer`, sized
by the `*Size()` natives; layouts follow oscillux.h, and `*Default` natives fill them.
JNI checks capacities, alignment, dimensions and input/output aliasing before access.
Buffers are used from offset zero regardless of their Java position; retain buffers until
each call returns and never mutate them concurrently. JNI rejects read-only output
buffers; read-only input buffers remain valid. DSP result counts are two uint64 values on
both Android ABIs. `Mapper.process(frames, index, ...)` reads frame `index` of a push
output buffer. `Dsp.pushExt`/`pushExtF64` also fill an ext buffer of
`capacity * dspFrameExtSize()` bytes, one `OscilluxDspFrameExt` per frame (the adapter
writes each struct_size; descriptors, beat and levels at the offsets listed for npm), and `Mapper.processExt(frames, ext, index, ...)` maps frame
`index` with element `index` of that buffer, or with no descriptors when `ext` is null.
`Mapper.setLevelSource(Mapper.LEVELS_RELATIVE)` maps BASS, MID, TREBLE and the spectrum from
that element's relative band levels; `process` and a null `ext` are then refused. Write `flashConfigSize()` as the uint32 at offset 0 of a flash config buffer
before `flashConfigDefault`, as in C. `new Dsp(config)` runs DSP behaviour version 1;
`Dsp.createVersioned(config)` runs the version a `dspVersionedConfigSize()` buffer selects
(struct_size at offset 0 before `dspVersionedConfigDefault`, which writes version 2 at
offset 136 and the reserved uint32 at offset 140, which must stay 0). `FlashAnalyzer.measure`/`admit` take `regionCount`
(at most 256) region pairs and pass unusable buffers to C as null, so a writable report
buffer still receives the zeroed error report. `statusString`, `dspConfigValidate` and `dspVersionedConfigValidate` return Strings, which allocate.

`Oscillux.BeatGrid(config, pcm, frames)` analyses `frames` frames of interleaved float32 PCM
offline (write `beatGridConfigSize()` at offset 0 before `beatGridConfigDefault`); the
constructor allocates and belongs off the frame path. `beatCount()` returns the count,
`copyBeats(first, out, capacity)` the number of `beatGridBeatSize()` elements written,
`info(out)` writes the summary and `clock(mediaTimeSeconds, out)` the position, without
allocating. `beatGridConfigValidate` returns a String, which allocates.

### Binding coverage

Every `OSCILLUX_API` export in oscillux.h has a row below. `packaging/wasm/tests/coverage.rs`
(run by `make gate`) parses the header and fails when an export lacks a row, when a binding
named here is missing from its class in the adapter sources, when a C function is not called
outside comments, when a Java `native` and the `JNI(...)` definitions differ, or when an
exclusion has no reason.
`tools/test-wasm-package.mjs` checks the npm names against the built package and its types.

<!-- binding-coverage:start -->
| C export | npm (wasm) | Java (JNI) |
|---|---|---|
| `oscillux_abi_version` | `abiVersion` | `Oscillux.abiVersion` |
| `oscillux_version` | `version` | `Oscillux.version` |
| `oscillux_status_string` | `statusString` | `Oscillux.statusString` |
| `oscillux_dsp_config_default` | excluded: npm `DspConfig` wraps the versioned config, whose `behaviorVersion = 1` selects this same ABI-1 analysis | `Oscillux.dspConfigDefault` |
| `oscillux_dsp_config_validate` | excluded: npm `DspConfig` wraps the versioned config, whose `behaviorVersion = 1` selects this same ABI-1 analysis | `Oscillux.dspConfigValidate` |
| `oscillux_dsp_create` | excluded: npm `DspConfig` wraps the versioned config, whose `behaviorVersion = 1` selects this same ABI-1 analysis | `new Oscillux.Dsp` |
| `oscillux_dsp_versioned_config_default` | `new DspConfig` | `Oscillux.dspVersionedConfigDefault` |
| `oscillux_dsp_versioned_config_validate` | `DspConfig.validate` | `Oscillux.dspVersionedConfigValidate` |
| `oscillux_dsp_create_versioned` | `new Dsp` | `Oscillux.Dsp.createVersioned` |
| `oscillux_dsp_destroy` | `Dsp.free` | `Oscillux.Dsp.close` |
| `oscillux_dsp_begin_segment` | `Dsp.beginSegment` | `Oscillux.Dsp.beginSegment` |
| `oscillux_dsp_push_f32` | `Dsp.push` | `Oscillux.Dsp.push` |
| `oscillux_dsp_push_f64` | `Dsp.pushF64` | `Oscillux.Dsp.pushF64` |
| `oscillux_dsp_push_ext_f32` | `Dsp.pushExt` | `Oscillux.Dsp.pushExt` |
| `oscillux_dsp_push_ext_f64` | `Dsp.pushExtF64` | `Oscillux.Dsp.pushExtF64` |
| `oscillux_limiter_policy_default` | `new LimiterPolicy` | `Oscillux.limiterPolicyDefault` |
| `oscillux_limiter_create` | `new Limiter` | `new Oscillux.Limiter` |
| `oscillux_limiter_destroy` | `Limiter.free` | `Oscillux.Limiter.close` |
| `oscillux_limiter_reset` | `Limiter.reset` | `Oscillux.Limiter.reset` |
| `oscillux_limiter_process` | `Limiter.process` | `Oscillux.Limiter.process` |
| `oscillux_flash_config_default` | `new FlashConfig` | `Oscillux.flashConfigDefault` |
| `oscillux_flash_analyzer_create` | `new FlashAnalyzer` | `new Oscillux.FlashAnalyzer` |
| `oscillux_flash_analyzer_destroy` | `FlashAnalyzer.free` | `Oscillux.FlashAnalyzer.close` |
| `oscillux_flash_analyzer_reset` | `FlashAnalyzer.reset` | `Oscillux.FlashAnalyzer.reset` |
| `oscillux_flash_analyzer_measure` | `FlashAnalyzer.measure` | `Oscillux.FlashAnalyzer.measure` |
| `oscillux_flash_analyzer_admit` | `FlashAnalyzer.admit` | `Oscillux.FlashAnalyzer.admit` |
| `oscillux_flash_analyzer_measure_rgb` | `FlashAnalyzer.measureRgb` | `Oscillux.FlashAnalyzer.measureRgb` |
| `oscillux_flash_analyzer_admit_rgb` | `FlashAnalyzer.admitRgb` | `Oscillux.FlashAnalyzer.admitRgb` |
| `oscillux_flash_region_from_linear_rgb` | `FlashAnalyzer.setRegionFromLinearRgb` | `Oscillux.flashRegionFromLinearRgb` |
| `oscillux_overlay_config_default` | `new OverlayConfig` | `Oscillux.overlayConfigDefault` |
| `oscillux_overlay_pack` | `OverlayRegions.pack` | `Oscillux.overlayPack` |
| `oscillux_overlay_presentation_intensity` | `OverlayConfig.presentationIntensity` | `Oscillux.overlayPresentationIntensity` |
| `oscillux_overlay_flash_config` | `OverlayConfig.tightenFlashConfig` | `Oscillux.overlayFlashConfig` |
| `oscillux_flash_overlay_default` | `new FlashOverlay` | `Oscillux.flashOverlayDefault` |
| `oscillux_flash_analyzer_set_overlay` | `FlashAnalyzer.setOverlay`, `FlashAnalyzer.clearOverlay` | `Oscillux.FlashAnalyzer.setOverlay` |
| `oscillux_flash_analyzer_overlay_report` | `FlashAnalyzer.overlayReport` | `Oscillux.FlashAnalyzer.overlayReport` |
| `oscillux_curve_config_default` | `new CurveConfig` | `Oscillux.curveConfigDefault` |
| `oscillux_curve_create` | `new Curve` | `new Oscillux.Curve` |
| `oscillux_curve_destroy` | `Curve.free` | `Oscillux.Curve.close` |
| `oscillux_curve_evaluate` | `Curve.evaluate` | `Oscillux.Curve.evaluate` |
| `oscillux_governor_config_default` | `new GovernorConfig` | `Oscillux.governorConfigDefault` |
| `oscillux_governor_create` | `new Governor` | `new Oscillux.Governor` |
| `oscillux_governor_destroy` | `Governor.free` | `Oscillux.Governor.close` |
| `oscillux_governor_record` | `Governor.record` | `Oscillux.Governor.record` |
| `oscillux_governor_reset` | `Governor.reset` | `Oscillux.Governor.reset` |
| `oscillux_transition_config_default` | `new TransitionConfig` | `Oscillux.transitionConfigDefault` |
| `oscillux_transition_create` | `new Transition` | `new Oscillux.Transition` |
| `oscillux_transition_destroy` | `Transition.free` | `Oscillux.Transition.close` |
| `oscillux_transition_request` | `Transition.request` | `Oscillux.Transition.request` |
| `oscillux_transition_update` | `Transition.update` | `Oscillux.Transition.update` |
| `oscillux_transition_status` | `Transition.status` | `Oscillux.Transition.status` |
| `oscillux_transition_reset` | `Transition.reset` | `Oscillux.Transition.reset` |
| `oscillux_mapping_config_default` | `new MappingConfig` | `Oscillux.mappingConfigDefault` |
| `oscillux_mapping_config_from_dsp` | `MappingConfig.fromDsp` | `Oscillux.mappingConfigFromDsp` |
| `oscillux_mapping_create` | `new Mapper` | `new Oscillux.Mapper` |
| `oscillux_mapping_destroy` | `Mapper.free` | `Oscillux.Mapper.close` |
| `oscillux_mapping_reset` | `Mapper.reset` | `Oscillux.Mapper.reset` |
| `oscillux_mapping_process` | `Mapper.process`, `Mapper.processFrame` | `Oscillux.Mapper.process` |
| `oscillux_mapping_process_ext` | `Mapper.processExt`, `Mapper.processFrameExt` | `Oscillux.Mapper.processExt` |
| `oscillux_mapping_set_level_source` | `Mapper.setLevelSource` | `Oscillux.Mapper.setLevelSource` |
| `oscillux_packer_create` | `new Packer` | `new Oscillux.Packer` |
| `oscillux_packer_destroy` | `Packer.free` | `Oscillux.Packer.close` |
| `oscillux_packer_pack` | `Packer.pack` | `Oscillux.Packer.pack` |
| `oscillux_reaction_config_default` | `new ReactionConfig` | `Oscillux.reactionConfigDefault` |
| `oscillux_reaction_create` | `new ReactionSampler` | `new Oscillux.ReactionSampler` |
| `oscillux_reaction_destroy` | `ReactionSampler.free` | `Oscillux.ReactionSampler.close` |
| `oscillux_reaction_reset` | `ReactionSampler.reset` | `Oscillux.ReactionSampler.reset` |
| `oscillux_reaction_push` | `ReactionSampler.push`, `ReactionSampler.pushWithBeat` | `Oscillux.ReactionSampler.push` |
| `oscillux_reaction_set_beat_clock` | `ReactionSampler.setBeatClock`, `ReactionSampler.clearBeatClock` | `Oscillux.ReactionSampler.setBeatClock` |
| `oscillux_reaction_sample` | `ReactionSampler.sample` | `Oscillux.ReactionSampler.sample` |
| `oscillux_reaction_queued` | `ReactionSampler.queued` | `Oscillux.ReactionSampler.queued` |
| `oscillux_beatgrid_config_default` | `new BeatGridConfig` | `Oscillux.beatGridConfigDefault` |
| `oscillux_beatgrid_config_validate` | `BeatGridConfig.validate` | `Oscillux.beatGridConfigValidate` |
| `oscillux_beatgrid_create` | `new BeatGrid` | `new Oscillux.BeatGrid` |
| `oscillux_beatgrid_destroy` | `BeatGrid.free` | `Oscillux.BeatGrid.close` |
| `oscillux_beatgrid_beat_count` | `new BeatGrid` | `Oscillux.BeatGrid.beatCount` |
| `oscillux_beatgrid_info` | `new BeatGrid` | `Oscillux.BeatGrid.info` |
| `oscillux_beatgrid_copy_beats` | `new BeatGrid` | `Oscillux.BeatGrid.copyBeats` |
| `oscillux_beatgrid_clock` | `BeatGrid.clock` | `Oscillux.BeatGrid.clock` |
| `oscillux_cdg_create` | `new Cdg` | `new Oscillux.Cdg` |
| `oscillux_cdg_destroy` | `Cdg.free` | `Oscillux.Cdg.close` |
| `oscillux_cdg_advance_to_time` | `Cdg.advanceToTime` | `Oscillux.Cdg.advanceToTime` |
| `oscillux_cdg_advance_to_pack` | `Cdg.advanceToPack` | `Oscillux.Cdg.advanceToPack` |
| `oscillux_cdg_state` | `Cdg.state` | `Oscillux.Cdg.state` |
| `oscillux_cdg_screen` | `Cdg.screen` | `Oscillux.Cdg.screen` |
| `oscillux_cdg_window_rgba` | `Cdg.windowRgba` | `Oscillux.Cdg.windowRgba` |
| `oscillux_cdg_index_counts` | `Cdg.indexCounts`, `Cdg.count` | `Oscillux.Cdg.indexCounts` |
<!-- binding-coverage:end -->

### Smoke tests

`make packaging-test` checks archive metadata reproducibility. After unpacking the
npm archive to `target/npm-smoke`, run
`node tools/test-wasm-package.mjs target/npm-smoke/package` from the repository root. It
runs the pinned DSP, limiter, region flash, curve, governor, transition and mapping/packing vectors and the sine
fixture through DSP, mapping and packing via the shipped JS adapter, and checks the table
above against the package exports and `oscillux.d.ts`. `packaging/android/AdapterSmoke.java`
runs the DSP fixture (float32 and float64 PCM, behaviour versions 1 and 2), the same DSP, mapping and packing pipeline,
curve, governor, transition scheduler, limiter, the full-screen 10 Hz region flash sequences and invalid-buffer
checks through the actual JNI glue.
`make jni-smoke` compiles `oscillux_jni.c` against the host JDK's `jni.h` and a host
`liboscillux`, then runs `AdapterSmoke` on the host JVM; it fails if a read-only output
buffer is accepted. It needs a JDK and a C compiler, so it is not part of `make gate`.
