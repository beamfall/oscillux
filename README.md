# Oscillux

**Visuals that hear the music.** Oscillux is the audio-reactive visual engine behind
[Beamfall](https://github.com/beamfall): it listens to a stream of audio, finds the beat, and
drives 61 visuals and 30 transitions that move with it, on every screen your app runs on.

[![Licence: AGPL-3.0-only](https://img.shields.io/badge/licence-AGPL--3.0--only-blue)](LICENSE)
[![Rust MSRV 1.85](https://img.shields.io/badge/rust-1.85%2B-orange)](Cargo.toml)

Drop one library into a macOS, iOS, tvOS, Android or Windows app, or a web page through
WebAssembly, and you get the whole path from samples to pixels: real-time analysis, a beat
tracker, latency-aware timing, a shader catalogue, transitions that land on the bar, and a
photosensitivity flash limiter watching every frame. Your app keeps the audio device, the GPU
surface and the UI. Oscillux makes them dance.

## Why Oscillux

**It feels alive, because it is on the beat.** The version 4 beat tracker follows tempo, beat
phase, bar phase and downbeats from live audio, compensates its own analysis delay, and lands
within a few milliseconds of the beat on click and kick trains (mean offset +3.4 ms). On most of
those trains it locks within one or two beats from a cold start; it holds through silence and
re-locks within two seconds of a tempo change. A reaction sampler then times each value to the
moment the frame's light actually reaches the viewer, not the moment it was computed.

**One engine, identical everywhere.** The same analysis, mapping and shaders run on a phone, a
TV, a desktop and a browser tab, and produce the same numbers on each, within each suite's
stated tolerance. Behaviour is specified by
conformance vectors from independent Python oracles, and every target, wasm32 included, must
reproduce them. No platform-specific floating-point shortcuts, no "close enough on Android".

**Safe to look at, by design.** A photosensitivity flash limiter, a red-flash-aware region
analyzer and a GPU frame flash limiter ship in the box, alongside overlay regions that hold the
contrast of your captions and controls over any visual.

**A catalogue, not a demo.** 61 visuals across tunnels, flights, sky and space, light and glass,
liquid, scopes and meters, photo and dancers, from calm to intense, plus 30 switch transitions.
Each is written once in portable GLSL and translated by a pinned toolchain for WebGL2, Vulkan,
Metal and HLSL. Another 23, a calmer set, are already written in `shaders/originals/` and on their
way into the catalogue.

**Built to be embedded.** One C header, opaque handles, caller-owned buffers and plain status
codes. The per-frame path never allocates, locks or touches I/O, and a panic never crosses the
boundary. The web build fits in 100 KiB gzip.

## The feature tour

| | |
|---|---|
| **Hear everything** | Streaming PCM in, one frame per hop out: RMS, loudness, log-spaced band energies, onsets, stereo and spectral descriptors and automatic gain, under four frozen behaviour versions. |
| **Find the beat** | A causal beat tracker (tempo, beat and bar phase, downbeats, confidence) for live audio, and an offline beat grid that analyses a whole track into beats, local tempo, a 3/4 or 4/4 meter and bar indices, with an allocation-free clock for any media time. |
| **Hit the frame** | Reaction timing samples the audio for the instant a display frame becomes visible, given the host's output and display latency. |
| **Feed the shaders** | One analysed frame becomes the `VisualUniforms` block every visual reads ([docs/visual-uniforms.md](docs/visual-uniforms.md)), packed to a fixed std140 layout. |
| **Switch on the bar** | A beat-quantised transition scheduler, easing, envelope and LFO curves, and governor math for the frame budget; the reference hosts use them to take a switch in the same wall time at 30, 60 and 120 Hz. |
| **Finish the frame** | A shared present pass for every visual and transition: tone mapping, bloom, grain and dither, overlay contrast and an optional host graphics layer, in GLSL ES 3.00 and Metal. |
| **Protect the viewer** | A flash limiter on host-supplied frame signals, a region flash analyzer, and a frame flash limiter that runs as GPU passes over the rendered frame. |
| **Sing along** | A CD+G decoder for karaoke graphics. |
| **Make your own** | A pass-list format and a toolchain that wraps, translates, validates, renders and live-previews shaders ([docs/shader-toolchain.md](docs/shader-toolchain.md)). |

### A note on photosensitivity

The flash limiter's tighten-only policy uses numeric defaults informed by the WCAG 2.3.1 and
ITU-R BT.1702 thresholds and the ISO 9241-391 red-flash rule. It works on the signals it is
given and claims no standards conformance; rendered-pixel and display compliance remain the
host's responsibility. Read [conformance/limiter/README.md](conformance/limiter/README.md) and
[shaders/limiter/README.md](shaders/limiter/README.md) before you rely on it.

## Runs where your users are

| Platform | Artifact | Notes |
|---|---|---|
| macOS, iOS, tvOS | `oscillux-xcframework.zip` (XCFramework) | arm64 devices and simulators; Intel Macs are not supported |
| Android | `oscillux.aar` | C libraries for arm64-v8a and armeabi-v7a, JNI bindings, minSdk 21 |
| Web | `oscillux-wasm.tgz` (npm package `@oscillux/core`) | wasm-bindgen ES modules with TypeScript types, at most 100 KiB gzip |
| Any GPU host | `oscillux-msl.zip`, `oscillux-glsl300.zip` | the Metal and GLSL ES 3.00 shader legs with a SHA-256 index and `catalog.json` (each visual's name, blurb, tier, input, flags, params, post tuning and palette), for hosts that compile shaders themselves |
| Android (GLES) | `oscillux-android-gles.zip` | `AndroidGlesShaders.kt`: the GLES 3.00 visuals and their catalog as a digest-checked Kotlin contract (1.0.0) with a SHA-256 index |
| Windows | `oscillux-windows.zip` | x64 and ARM64, built on a Windows host only; not yet attached to releases, so build it with `make artifacts` |
| Linux | crates only | checked by the gate; no packaged library |

`make artifacts` builds them with the pinned toolchain and writes `dist/manifest.json` with each
archive's SHA-256 and size, the source revision and the compiler and SDK versions. Every archive
carries the licence, [LICENSING.md](LICENSING.md) and the third-party notices. Nothing is
published to a package registry. [docs/packaging.md](docs/packaging.md) has the requirements per
platform and records which targets have run the conformance vectors and which have only been
linked.

## Up and running in minutes

### Rust

The crates are not on crates.io; depend on this repository.

```toml
[dependencies]
oscillux-core = { git = "https://github.com/beamfall/oscillux" }
```

```rust
use oscillux_core::dsp::{Analyzer, DspFrame, DspSettings, FrameExt, DSP_BEHAVIOR_V4};

fn main() {
    // Version 4 adds the causal beat tracker; its frames and levels equal version 2.
    let settings = DspSettings { behavior_version: DSP_BEHAVIOR_V4, ..DspSettings::default() };
    let mut analyzer = Analyzer::new(settings).expect("valid settings");

    // Caller-owned output buffers: the per-frame path never allocates.
    let mut frames = [DspFrame::ZERO; 16];
    let mut ext = [FrameExt::ZERO; 16];

    // Ten seconds of a 120 BPM click at 48 kHz, stereo interleaved, fed in 10 ms blocks.
    let pcm: Vec<f32> = (0..480_000)
        .flat_map(|i| {
            let s = if i % 24_000 < 480 { 0.8 } else { 0.0 };
            [s, s]
        })
        .collect();
    for block in pcm.chunks(960) {
        let pushed = analyzer.push_ext(block, 2, &mut frames, &mut ext).expect("stereo input");
        for (frame, ext) in frames[..pushed.produced].iter().zip(&ext) {
            if frame.sequence % 100 == 0 {
                println!(
                    "{:7.0} ms  rms {:.3}  band 0 {:.2}  tempo {:5.1} BPM  beat phase {:.2}",
                    frame.media_time_ms, frame.rms, frame.bands()[0], ext.beat.tempo_bpm, ext.beat.beat_phase
                );
            }
        }
    }
}
```

The tracker reports about 120 BPM within the first second. The Rust crates are an implementation
detail with no stability promise; for anything you ship, build against the C interface or a
binding that wraps it.

### C, Swift and Objective-C

The whole interface is one header, [ffi/include/oscillux.h](ffi/include/oscillux.h). Handles are
opaque, every buffer is owned by the caller, and functions return `OSCILLUX_OK` or a negative
`OSCILLUX_ERR_*` status. Check the version once at start-up:

```c
if (oscillux_abi_version() != OSCILLUX_ABI_VERSION || oscillux_version() < OSCILLUX_VERSION) {
    /* the linked library does not match this header */
}
```

[packaging/smoke/conformance_smoke.c](packaging/smoke/conformance_smoke.c) is a complete C program
that drives the analysis and the limiter. On Apple platforms, link the XCFramework; the SwiftUI
reference host in [hosts/apple/](hosts/apple/) shows the calls from Swift.

### Android

The AAR exposes the C interface to Java and Kotlin through
[packaging/android/Oscillux.java](packaging/android/Oscillux.java).

### Web

The npm package wraps the core in wasm-bindgen ES modules ([packaging/wasm/](packaging/wasm/)).
The web reference host ([hosts/web/](hosts/web/)) analyses live audio with it and renders the
catalogue in WebGL2.

### See the visuals

```sh
make host-web    # WebGL2 page on http://127.0.0.1:8765/hosts/web/
make host-mac    # SwiftUI and Metal app for macOS (needs Xcode and XcodeGen)
```

Both reference hosts render the full catalogue from one bundle and need the pinned shader
toolchain ([hosts/README.md](hosts/README.md)). They are references, not products.

## Repository layout

| Path | Contents |
|---|---|
| [`crates/oscillux-core`](crates/oscillux-core) | analysis, beat grid, limiter, mapping, packing, curves, transitions, governor, overlay, CD+G |
| [`crates/oscillux-ffi`](crates/oscillux-ffi) | the C interface, built as a static and a dynamic library, and the frame-budget bench |
| [`ffi/`](ffi) | the C header and the ABI snapshot it is checked against |
| [`packaging/`](packaging) | Android (JNI) and WebAssembly bindings, and the C smoke harness |
| [`shaders/`](shaders) | visuals, transitions, the present pass, the frame flash limiter and CD+G passes |
| [`conformance/`](conformance) | the vectors that specify behaviour, each suite with its README |
| [`tools/`](tools) | Python oracles for the vectors, licence and SPDX checks, artifact builder, shader toolchain (`tools/shader/`) |
| [`hosts/`](hosts) | the web and Apple reference hosts, visual categories and collections |
| [`benches/`](benches) | native frame-time benchmarks for Android and tvOS |
| [`docs/`](docs) | interface stability, packaging, portable math, the shader toolchain and uniforms |
| [`openspec/`](openspec) | specifications and change proposals |

## Build and test

The Rust toolchain is pinned in [rust-toolchain.toml](rust-toolchain.toml) (1.98.1 with every
target below), and rustup installs it on first use. The minimum supported Rust version is 1.85.

```sh
cargo test --workspace    # the core and C interface test suites
make gate                 # the full merge gate
```

`make gate` is the bar every change must clear. It runs, among others:

| Target | Checks |
|---|---|
| `spdx`, `licenses` | every source file is `AGPL-3.0-only`; every dependency is on the permissive allow-list |
| `fmt`, `clippy`, `test` | rustfmt, Clippy with warnings as errors, the workspace tests |
| `targets`, `msrv` | `cargo check` on all thirteen targets; the core on Rust 1.85 |
| `abi-check` | the header against [ffi/abi-snapshot.txt](ffi/abi-snapshot.txt) |
| `*-vectors-check` | each conformance suite regenerated by its independent Python oracle |
| `shader-test`, `limiter-check`, `present-v2-check` | the shader wrapper goldens, pass lists, governor and presets; the GPU limiter and present pass |
| `packaging-test`, `test-wasi`, `bench` | artifact packaging, the wasm32-wasip1 run of the vectors, the frame budget |

Beyond Cargo it needs Python 3, Node, clang, the wasm32 targets and the pinned glslangValidator
and SPIRV-Cross named in [docs/shader-toolchain.md](docs/shader-toolchain.md). While you iterate,
run the one target you are working on rather than the whole gate.

## Proven, not promised

Numeric behaviour is specified by the vectors under [conformance/](conformance/), not by the
code: a change to an expected output is a behaviour change. Each suite is generated by an
independent Python oracle in [tools/](tools/) and checked against the Rust implementation within
a stated tolerance on every supported target, including wasm32 and wasm32-wasip1
([docs/wasi-verification.md](docs/wasi-verification.md)). Numerics avoid platform-specific
floating-point paths ([docs/portable-math.md](docs/portable-math.md)).

Shaders get the same treatment: wrapper output is held to byte-exact goldens, `make
shader-verify` validates every Vulkan shader and compiles every Metal shader, and
`make shader-render` renders the catalogue under WebGL2 and, with `--frames 1`, diffs each
Metal frame against the WebGL2 frame from the same uniforms.

## Versioning

Oscillux is at 0.2.1 with C ABI version 1. Before 1.0 the interface may still change
incompatibly, but only under the versioning and deprecation rules in
[docs/api-stability.md](docs/api-stability.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Contributing

Bug reports, fixes and new visuals are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first:
new or changed behaviour starts as an OpenSpec change, conformance vectors are the
specification, and `make gate` must pass. Outside contributions need an accepted
[contributor agreement](CONTRIBUTOR-AGREEMENT.md) before merge.

## Licence

Oscillux is free software under the [GNU Affero General Public License v3](LICENSE), version 3
only (`AGPL-3.0-only`). You may use, study, change and share it, commercially or not, under the
licence's terms, including offering the corresponding source to users of a modified version
over a network. Third-party material keeps its own licence
([THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)). See [LICENSING.md](LICENSING.md) for details.

## A Beamfall project

Oscillux is built and maintained by [Beamfall](https://github.com/beamfall) as the visual engine
behind its apps, and it is developed in the open here. Beamfall's official products use it under
a separate permission from the copyright holder; that permission does not extend to forks or
third parties, who use Oscillux under the AGPL.
