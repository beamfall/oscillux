# SPDX-License-Identifier: AGPL-3.0-only
# Resolve the toolchain rust-toolchain.toml selects, so cargo subcommands (fmt, clippy) are found.
export PATH := $(dir $(shell rustup which cargo)):$(PATH)
CARGO ?= $(shell rustup which cargo)
MSRV := 1.85
# Keep in step with the targets list in rust-toolchain.toml.
TARGETS := \
	aarch64-apple-darwin \
	aarch64-apple-ios aarch64-apple-ios-sim \
	aarch64-apple-tvos aarch64-apple-tvos-sim \
	aarch64-linux-android armv7-linux-androideabi \
	x86_64-pc-windows-msvc aarch64-pc-windows-msvc \
	x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu \
	wasm32-unknown-unknown wasm32-wasip1

.PHONY: gate spdx licenses fmt clippy test targets msrv

gate: spdx licenses fmt clippy test targets msrv

spdx:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools -p 'test_check_spdx.py'
	python3 tools/check-spdx.py

licenses:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools -p 'test_check_licenses.py'
	python3 tools/check-licenses.py

fmt:
	$(CARGO) fmt --all --check

clippy:
	$(CARGO) clippy --workspace --all-targets -- -D warnings

test:
	$(CARGO) test --workspace

targets:
	set -e; for t in $(TARGETS); do echo "check $$t"; $(CARGO) check --workspace --target $$t; done

# PATH above pins the toolchain's own cargo, which `cargo +1.85` or `rustup run` would not replace,
# so put the MSRV toolchain's bin directory first instead.
msrv:
	set -e; msrv_cargo=$$(rustup which --toolchain $(MSRV) cargo); \
	export PATH="$${msrv_cargo%/cargo}:$$PATH"; rustc --version; cargo check -p oscillux-core

# ABI snapshot (docs/api-stability.md): abi-check fails with a line diff when the header's
# functions, constants or struct layouts differ from ffi/abi-snapshot.txt; abi-snapshot rewrites it.
.PHONY: abi-check abi-snapshot
abi-check:
	$(CARGO) test -p oscillux-ffi --test abi_snapshot

abi-snapshot:
	OSCILLUX_UPDATE_ABI_SNAPSHOT=1 $(CARGO) test -p oscillux-ffi --test abi_snapshot

gate: abi-check

# Host per-frame budget for DSP, limiter, mapping, packing, beat tracking and adaptive levels in the
# release profile; the threshold and noise policy are in crates/oscillux-ffi/benches/frame_budget.rs.
# cargo-llvm.py lets the release strip load libLLVM on macOS.
.PHONY: bench
bench:
	python3 tools/cargo-llvm.py "$(CARGO)" bench -p oscillux-ffi --bench frame_budget

gate: bench

# Set ARTIFACT_TARGETS=apple,wasm for a host-local subset; default requires all SDKs.
ARTIFACT_TARGETS ?= apple,android,windows,wasm
.PHONY: artifacts packaging-test
artifacts:
	python3 tools/artifacts.py --targets $(ARTIFACT_TARGETS)

packaging-test:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools -p 'test_artifacts.py'
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools -p 'test_platform_gate.py'

gate: packaging-test

# Executes the conformance vectors on wasm32-wasip1; requires wasmtime on PATH.
.PHONY: test-wasi wasi-recipe-test
test-wasi:
	python3 tools/test-wasi.py "$(CARGO)"

wasi-recipe-test:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools -p 'test_wasi_recipe.py'
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools -p 'test_cargo_llvm.py'

gate: wasi-recipe-test test-wasi

# Links every shipped Apple and Android library and runs conformance vectors on macOS, iOS and
# tvOS simulators and an Android emulator it creates and deletes, plus the npm package under Node
# (docs/packaging.md, "Platform gate"). Apple Silicon Mac with Xcode, ANDROID_HOME,
# ANDROID_NDK_HOME, a JDK, Node, the make artifacts tools and a clean tree.
# Not part of gate: required before publishing artifacts and after native-ABI or packaging changes.
.PHONY: platform-gate
platform-gate:
	python3 tools/platform-gate.py "$(CARGO)" $(PLATFORM_GATE_ARGS)

# Optional host check of the JNI glue; requires a JDK and a C compiler. Not part of gate.
.PHONY: jni-smoke
jni-smoke:
	python3 tools/jni-smoke.py "$(CARGO)"

# Shader toolchain (tools/shader, docs/shader-toolchain.md). The wrap goldens need only node.
SHADER_MANIFEST ?= examples/shader/manifest.json
.PHONY: shader-test shader-verify shader-render shader-watch
shader-test:
	node tools/shader/test-wrap.mjs
	node tools/shader/test-passes.mjs
	node tools/shader/test-governor.mjs
	node tools/shader/test-palette-tour.mjs
	node tools/shader/test-preset.mjs
	node tools/shader/test-karaoke-zip.mjs
	node tools/shader/test-android-gles.mjs

gate: shader-test

# The Apple host's MP3+G reader (hosts/apple/Sources/KaraokeZip.swift) on the web reader's cases
# (tools/shader/test-karaoke-zip.mjs). Needs swiftc (macOS); not part of gate.
.PHONY: karaoke-zip-swift
karaoke-zip-swift:
	node tools/shader/test-karaoke-zip.mjs --write out/karaoke-zip
	swiftc -parse-as-library -O hosts/apple/Sources/KaraokeZip.swift tools/shader/karaoke-zip-check.swift -o out/karaoke-zip/check
	out/karaoke-zip/check out/karaoke-zip

# DSP behaviour version 2 vectors (conformance/dsp/README.md): fails when conformance/dsp/v2/,
# conformance/dsp/music/v2/ or the edge-case inputs differ from what the independent oracle
# tools/dsp-v2-vectors.py writes. Takes about 13 s.
.PHONY: dsp-v2-vectors-check
dsp-v2-vectors-check:
	python3 -I tools/dsp-v2-vectors.py --check

gate: dsp-v2-vectors-check

# Mapping vectors: fails when the independent model tools/mapping-vectors.py does not reproduce
# every TypeScript slot and packed byte of conformance/packing/reference.json, or would write a
# different conformance/packing/descriptors.json (the descriptor path) or
# conformance/packing/levels.json (the relative level source).
.PHONY: mapping-vectors-check
mapping-vectors-check:
	python3 -I tools/mapping-vectors.py --check

gate: mapping-vectors-check

# visual-uniforms.v1 goldens (docs/visual-uniforms.md): fails when a vendored AudioFrame input in
# conformance/uniforms/inputs/ differs from its provenance sha256 or tools/uniforms-vectors.py
# would write a different conformance/uniforms/*.uniforms.golden.json. The Rust mapper is
# checked against the same goldens by the uniforms_goldens test under `make test`.
.PHONY: uniforms-vectors-check
uniforms-vectors-check:
	python3 -I tools/uniforms-vectors.py --check

gate: uniforms-vectors-check

# DSP descriptors (conformance/dsp/README.md): fails when conformance/dsp/descriptors/ differs
# from what the independent standard-library oracle tools/dsp-descriptors-vectors.py writes,
# or when the oracle misses a Tech 3341 nominal value. Takes about 10 s.
.PHONY: dsp-descriptors-vectors-check
dsp-descriptors-vectors-check:
	python3 -I tools/dsp-descriptors-vectors.py --check

gate: dsp-descriptors-vectors-check

# Synthetic music scores, beat tracker and adaptive level vectors
# (conformance/dsp/music/README.md): fails when the committed scores or conformance/dsp/music/beat/
# and agc/ differ from what the independent oracles tools/dsp-music-vectors.py,
# tools/dsp-beat-vectors.py and tools/dsp-agc-vectors.py write.
.PHONY: dsp-music-vectors-check
dsp-music-vectors-check:
	python3 -I tools/dsp-music-vectors.py --check
	python3 -I tools/dsp-beat-vectors.py --check
	python3 -I tools/dsp-agc-vectors.py --check

gate: dsp-music-vectors-check

# Transition scheduler vectors (conformance/transition/README.md): fails when
# conformance/transition/reference.json differs from what the independent standard-library model
# tools/transition-vectors.py writes, or when the web host's port hosts/web/transition.js does not
# reproduce it exactly.
.PHONY: transition-vectors-check
transition-vectors-check:
	python3 -I tools/transition-vectors.py --check
	node tools/shader/test-transition.mjs

gate: transition-vectors-check

# Switch-transition vectors (conformance/switch-transition/README.md): fails when
# conformance/switch-transition/vectors.json differs from what the independent standard-library
# model tools/switch-transition-vectors.py writes or breaks its added-light and endpoint
# assertions, or when shaders/switch/switch.glsl drawn under WebGL2 (the pinned Playwright
# Chromium, SwiftShader) or, on macOS, the Metal device misses a golden by more than its
# tolerance. Needs glslangValidator and, on macOS, spirv-cross and swift.
.PHONY: switch-transition-check
switch-transition-check: tools/shader/node_modules
	python3 -I tools/switch-transition-vectors.py --check
	$(SHADER_PATH)node tools/shader/switch-transition-check.mjs

gate: switch-transition-check

# Transition checks (tools/shader/transition-check.mjs): every
# transition's endpoints and pops, then the web host's switch timing, quantised start, warm
# incoming visual and live pops. They need the pinned Playwright Chromium, and the host check
# needs the bundled visuals and the wasm bindings (host-bundle, host-wasm). Not part of gate.
.PHONY: transition-check
transition-check: tools/shader/node_modules host-bundle host-wasm
	node tools/shader/transition-check.mjs shaders/originals/manifest.json
	node tools/shader/transition-check.mjs --host

# Version 4 beat tracker vectors (conformance/dsp/music/README.md, "Beat tracker, version 4"):
# fails when conformance/dsp/music/beat-v4/ differs from what the independent standard-library
# oracle tools/dsp-beat-v4-vectors.py writes. Takes about 5 s.
.PHONY: dsp-beat-v4-vectors-check
dsp-beat-v4-vectors-check:
	python3 -I tools/dsp-beat-v4-vectors.py --check

gate: dsp-beat-v4-vectors-check

# Reaction sampler beat-to-photon harness (crates/oscillux-core/tests/reaction_photon.rs): onsets in
# the first frame after each click at 30/60/120 Hz, beat pulse peak against the true beat at 60 Hz
# for a known clock and for the tracker of DSP version REACTION_DSP, smoothness and the analysis
# latency table.
REACTION_DSP ?= 3
.PHONY: reaction-photon
reaction-photon:
	OSCILLUX_REACTION_DSP=$(REACTION_DSP) $(CARGO) test --release -p oscillux-core --test reaction_photon -- --ignored --nocapture --test-threads 1

gate: reaction-photon

# Reaction vectors (conformance/reaction/README.md): fails when the independent model
# tools/reaction-vectors.py would write a different conformance/reaction/vectors.json. The
# replay against the core, tests/reaction_vectors.rs, runs in test and test-wasi.
.PHONY: reaction-vectors-check
reaction-vectors-check:
	python3 -I tools/reaction-vectors.py --check

gate: reaction-vectors-check

# Beat grid vectors (conformance/beatgrid/README.md): fails when the committed scores and grids
# differ from what the independent standard-library oracle tools/beatgrid-vectors.py writes.
# Takes about 35 s.
.PHONY: beatgrid-vectors-check
beatgrid-vectors-check:
	python3 -I tools/beatgrid-vectors.py --check

gate: beatgrid-vectors-check

# Overlay vectors (OSC-OVERLAY, conformance/overlay/README.md): fails when
# conformance/packing/overlay-uniforms.json or conformance/limiter/overlay-sequences.json differ
# from what the independent standard-library models tools/overlay-uniforms-vectors.py and
# tools/limiter-overlay-vectors.py write.
.PHONY: overlay-vectors-check
overlay-vectors-check:
	python3 -I tools/overlay-uniforms-vectors.py --check
	python3 -I tools/limiter-overlay-vectors.py --check

gate: overlay-vectors-check

# present-v2-check (CORE-0108, openspec/changes/present-pass-v2/): the present pass's hue error
# on a saturated-colour ramp and the banding of a dark gradient, v1 against v2, first through the
# standard-library colour-path model (with present.glsl's fingerprints, the post block and the
# bloom graph), then through the real pass on Metal, every code compared with the model (required
# on macOS, skipped elsewhere). present-v2-gpu adds the 1080p chain timing and writes contact
# sheets to out/present-v2; not part of gate (GPU timing depends on the machine's load).
.PHONY: present-v2-check present-v2-gpu
present-v2-check:
	node tools/shader/test-present-v2.mjs
	$(SHADER_PATH)node tools/shader/present-v2-check.mjs

gate: present-v2-check

present-v2-gpu:
	$(SHADER_PATH)node tools/shader/present-v2-check.mjs --timing --evidence out/present-v2 $(PRESENT_V2_ARGS)

# Optional: verify needs the pinned glslangValidator and spirv-cross (tools/shader/provision.mjs)
# plus Xcode; render and watch need the pinned Playwright Chromium. Not part of gate.
# shader-watch is dev-only: it re-renders on every change under the manifest's directory.
# SHADER_TOOLS is put first on PATH for every target that runs SPIRV-Cross. It defaults to a
# local build of the pinned SPIRV-Cross 1.4.357.0 (docs/shader-toolchain.md), found in the first of:
# $(OSCILLUX_BUILD_DIR) when set (and then only there); the .oscillux-build directory two levels
# above the main checkout (from the git common dir, so linked worktrees anywhere on disk find
# it); $(HOME)/projects/.oscillux-build. `make SHADER_TOOLS=` leaves PATH as it is.
SPIRV_CROSS_BIN_SUBDIR := .tools/spirv-cross-1.4.357.0/bin
ifeq ($(origin SHADER_TOOLS),undefined)
ifneq ($(OSCILLUX_BUILD_DIR),)
OSCILLUX_BUILD_DIRS := $(OSCILLUX_BUILD_DIR)
else
OSCILLUX_GIT_COMMON_DIR := $(shell git -C $(CURDIR) rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
OSCILLUX_BUILD_DIRS := $(if $(OSCILLUX_GIT_COMMON_DIR),$(abspath $(dir $(OSCILLUX_GIT_COMMON_DIR))../../.oscillux-build)) $(HOME)/projects/.oscillux-build
endif
SHADER_TOOLS := $(firstword $(wildcard $(addsuffix /$(SPIRV_CROSS_BIN_SUBDIR),$(OSCILLUX_BUILD_DIRS))))
endif
SHADER_PATH = $(if $(SHADER_TOOLS),PATH="$(SHADER_TOOLS):$$PATH" )

tools/shader/node_modules: tools/shader/package-lock.json
	npm --prefix tools/shader ci --no-audit --no-fund
	touch $@

shader-verify:
	$(SHADER_PATH)node tools/shader/verify.mjs $(SHADER_MANIFEST) $(if $(filter $(abspath examples/shader/manifest.json),$(abspath $(SHADER_MANIFEST))),--hlsl-goldens conformance/shader/examples)

shader-render: tools/shader/node_modules
	$(SHADER_PATH)node tools/shader/render.mjs $(SHADER_MANIFEST) $(RENDER_ARGS)

shader-watch: tools/shader/node_modules
	node tools/shader/watch.mjs $(SHADER_MANIFEST) $(WATCH_ARGS)

# Beat-response lint (tools/shader/beat-lint.mjs): renders the host bundle's visuals on a
# deterministic beat clock and fails a visual whose frames do not answer the beat within a frame,
# unless conformance/shaders/beat-lint.json lists it as ambient. Needs Playwright Chromium.
.PHONY: shader-beat-lint
shader-beat-lint: tools/shader/node_modules
	node tools/shader/beat-lint.mjs $(BEAT_LINT_ARGS)

# Frame flash limiter (shaders/limiter/README.md, conformance/limiter/frame/README.md): the
# vectors against the reference model, the model tests, the passes through the pinned
# glslangValidator and SPIRV-Cross, and the passes on WebGL2 (Playwright Chromium) and, with
# swiftc and a unified-memory Metal device, on Metal against the vectors.
.PHONY: limiter-check
limiter-check: tools/shader/node_modules
	node tools/shader/limiter-vectors.mjs --check
	node tools/shader/test-limiter.mjs
	$(SHADER_PATH)node tools/shader/limiter.mjs --check
	$(SHADER_PATH)node tools/shader/limiter-check.mjs --metal

gate: limiter-check

# Hold budget (CORE-2409, openspec/specs/visual-defaults/spec.md): the release-leg Particles
# (shaders/manifest.json, as the glsl300 bundle ships it) through the limiter model under the red
# audit's loud audio holds at most 15% of the pixels in any frame (14% at v0.2.9; until v0.2.9 the
# budget was 5% of sub-blocks, with sub-block trackers that missed changes). Needs Playwright Chromium.
.PHONY: limiter-hold-check
limiter-hold-check: tools/shader/node_modules
	node tools/shader/limiter-red-audit.mjs shaders/manifest.json --only particles --audio loud --max-held 0.15 --jobs 1

gate: limiter-hold-check

# Source flash budget: every release-leg visual (shaders/manifest.json) keeps within the general
# flash limit on its own, before the limiter, under the red audit's loud audio: at most 6
# large-area luma transitions in any second and no large-area red transition. It takes several
# minutes on a GPU, so it is not part of gate; run it after changing a visual. Needs Playwright
# Chromium.
.PHONY: visual-flash-check
visual-flash-check: tools/shader/node_modules
	node tools/shader/limiter-red-audit.mjs shaders/manifest.json --audio loud --max-luma 6 --jobs 4

# Reference hosts (hosts/README.md): the same bundled visuals in a browser and a
# SwiftUI macOS/iOS app. host-bundle needs the shader-verify toolchain; host-mac
# and host-ios need Xcode and XcodeGen. Not part of gate.
.PHONY: host-bundle host-wasm host-web host-mac host-ios host-ios-device
HOST_MANIFEST ?= shaders/originals/manifest.json shaders/manifest.json
HOST_PORT ?= 8765
HOST_SIM ?= iPhone 17

host-bundle:
	$(SHADER_PATH)node tools/shader/bundle-hosts.mjs $(HOST_MANIFEST)

# The web host's audio path loads the wasm bindings from out/hosts/wasm (built as dist's npm package).
host-wasm:
	python3 tools/cargo-llvm.py "$(CARGO)" build --locked --release --target wasm32-unknown-unknown -p oscillux-wasm
	wasm-bindgen --target web --out-name oscillux --out-dir out/hosts/wasm target/wasm32-unknown-unknown/release/oscillux_wasm.wasm

# overlay-check (OSC-OVERLAY, conformance/overlay/README.md): every bundled visual through the
# shared present pass with fixed overlay regions, in the pinned Playwright Chromium, plus the
# Metal leg on macOS. Not part of gate. OVERLAY_ARGS passes options, e.g. --frames 8.
.PHONY: overlay-check
overlay-check: host-bundle tools/shader/node_modules
	$(SHADER_PATH)node tools/shader/overlay-check.mjs $(OVERLAY_ARGS)

host-web: host-bundle host-wasm
	@echo "http://127.0.0.1:$(HOST_PORT)/hosts/web/"
	python3 -I -m http.server $(HOST_PORT) --bind 127.0.0.1 --directory $(CURDIR)

hosts/apple/OscilluxHost.xcodeproj: hosts/apple/project.yml $(wildcard hosts/apple/Sources/*)
	xcodegen generate --spec $< --project hosts/apple

# The macOS app links the release static library for its audio-file analysis.
host-mac: host-bundle hosts/apple/OscilluxHost.xcodeproj
	$(CARGO) build --release -p oscillux-ffi
	xcodebuild -project hosts/apple/OscilluxHost.xcodeproj -scheme OscilluxHost -destination 'platform=macOS' -derivedDataPath out/hosts/DerivedData build

# iOS links the slices the XCFramework packs (tools/artifacts.py): the simulator's for host-ios,
# the device's for host-ios-device, which needs a signing team (HOST_TEAM) to install.
host-ios: host-bundle hosts/apple/OscilluxHost.xcodeproj
	$(CARGO) build --release --target aarch64-apple-ios-sim -p oscillux-ffi
	xcodebuild -project hosts/apple/OscilluxHost.xcodeproj -scheme OscilluxHost -destination 'platform=iOS Simulator,name=$(HOST_SIM),OS=latest' -derivedDataPath out/hosts/DerivedData build

host-ios-device: host-bundle hosts/apple/OscilluxHost.xcodeproj
	$(CARGO) build --release --target aarch64-apple-ios -p oscillux-ffi
	xcodebuild -project hosts/apple/OscilluxHost.xcodeproj -scheme OscilluxHost -destination 'generic/platform=iOS' -derivedDataPath out/hosts/DerivedData $(if $(HOST_TEAM),DEVELOPMENT_TEAM=$(HOST_TEAM) CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development",CODE_SIGNING_ALLOWED=NO) build

# ==== CD+G (OSC-CDG) ====
# The oracle regenerates conformance/cdg/ into a temporary directory and fails on any difference.
.PHONY: cdg-vectors-check
cdg-vectors-check:
	python3 -I tools/cdg-vectors.py --check
gate: cdg-vectors-check

# CD+G lyric composite (shaders/cdg/): compiles it for WebGL2 and Metal and measures the 4.5:1
# lyric contrast over every bundled visual headlessly. Needs the shader-render toolchain; not
# part of gate.
.PHONY: cdg-check
cdg-check: tools/shader/node_modules
	$(SHADER_PATH)node tools/shader/cdg-check.mjs $(CDG_CHECK_ARGS)

# cdg-host-check (OSC-CDG): the web host's lyrics against the pack clock, its layer texture
# against the decoder, and the lyrics on the canvas; CDG_HOST_ARGS=--screenshot DIR.
.PHONY: cdg-host-check
cdg-host-check: tools/shader/node_modules host-bundle host-wasm
	node tools/shader/cdg-host-check.mjs $(CDG_HOST_ARGS)

# web-host-check (OSC-WEB-HOST-RESILIENCE): the web host through a forced context loss (steady
# and mid-switch), with the float render extensions masked, and its drawing-buffer preservation;
# WEB_HOST_ARGS=--json FILE.
.PHONY: web-host-check
web-host-check: tools/shader/node_modules host-bundle host-wasm
	node tools/shader/web-host-check.mjs $(WEB_HOST_ARGS)
