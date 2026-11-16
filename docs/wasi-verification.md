<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Portable WASI execution

Run `make test-wasi` from the repository root; `make gate` also runs it. Prerequisites
are the selected Rust toolchain's installed `wasm32-wasip1` standard library (listed in
`rust-toolchain.toml`), cached Cargo dependencies, and `wasmtime` on PATH. The
command is offline and never installs prerequisites. Missing compiler libraries,
targets, runner or dependencies fail explicitly.
`CARGO_TARGET_DIR=/absolute/scratch/path make test-wasi` forces a separate build.
The Makefile resolves Cargo through rustup's selected repository toolchain; an
explicit `CARGO` override must be an absolute executable path. An explicit `RUSTC`
override is also used for the compiler sysroot probe.

On macOS the helper asks that compiler for its sysroot, verifies `lib/libLLVM.dylib`
exists, and prepends that directory to `DYLD_LIBRARY_PATH` in the Cargo process
only, preserving any caller paths after it. Other hosts receive no loader-path
change. The helper replaces itself with Cargo; Cargo's failure status is preserved.
The runner is explicitly `wasmtime`. Interrupt the foreground process group as
usual; the helper creates neither a detached process nor a background keeper.

The command executes all workspace library unit tests and these portable integration
binaries: `core2_early`, `core2_boundaries`, `core2_vectors`, `dsp_streaming`,
`dsp_conformance`, `dsp_descriptors`, `limiter_vectors`, `limiter_safety`,
`limiter_properties`, `limiter_regions`, `core2_ffi`, `limiter_ffi`, `realtime_paths`,
`ffi_robustness`, `cdg_vectors`, `cdg_realtime` and `cdg_ffi`.
Keep this list current when adding portable integration tests. It does not execute
`header_layout` (which creates temporary files and invokes a host C compiler),
`header_matches_exports` (which reads repository source files), or doctests. Those
checks remain in the native steps of `make gate`; the WASI step adds to them and does
not replace them. Rust's WASI test harness ignores the two `should_panic` DSP
comparator tests; their native execution remains required.

## Observed loader failure and repair (2026-09-30)

On macOS arm64, installed Rust 1.98.1 (48a229cea, LLVM 22.1.8) and Wasmtime 49.0.1:

- Fresh plain `cargo test --workspace --target wasm32-wasip1 --offline`, with
  `DYLD_LIBRARY_PATH` unset, failed with exit 101 and `rust-lld` unable to load
  `@rpath/libLLVM.dylib`.
- `otool` found a recorded rpath `@loader_path/../lib`, which resolves under
  `lib/rustlib/aarch64-apple-darwin/lib`; that library is absent. The other rpath
  names a CI build directory. The existing LLVM library is in the toolchain's
  top-level `lib`. This proves the installed loader-path mismatch; the cause of
  that installed layout and upstream archive provenance remain unverified.
- Adding the local loader path made linking succeed. Attempting every workspace
  integration binary then failed at host-only `header_layout`, as expected from
  its filesystem/process requirements. That failure was retained, not suppressed
  into a successful whole-workspace WASI claim.
- Fresh `env -u DYLD_LIBRARY_PATH CARGO_TARGET_DIR=/tmp/oscillux-wasi-loader-r21/final-target make test-wasi`
  passed: **49 tests, zero failures, two harness-ignored should-panic tests**, across
  nine integration binaries and three workspace library harnesses.
- Seven recipe tests cover compiler selection, caller-path preservation, missing
  LLVM/runner, compiler failure, non-macOS behavior and actual exit-37 propagation.
- SIGINT of an owned fresh verification process group retired make, Cargo, rustc,
  and linker descendants; the post-interruption group inventory was empty.

Local raw logs, hashes, loader inspection and interruption inventory are retained
in `/tmp/oscillux-wasi-loader-r21/`. The unchanged native merge gate is owned by the
coordinator after this source commit; its result is recorded in the native Tasks
receipt rather than presumed here.
