<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# C interface stability and deprecation policy

This policy covers the C interface: the declarations in `ffi/include/oscillux.h` and the
functions the library exports for them. The Rust crates are an implementation detail with no
stability promise. Bindings built on the C interface carry its version. The conformance vectors
under `conformance/` specify behavior, and a change to their expected outputs is a behavior
change under this policy.

## Two version numbers

- **ABI version** (`OSCILLUX_ABI_VERSION`, `oscillux_abi_version()`). It increments on any
  incompatible change: a changed signature, struct layout, constant or status value, or a
  removed function. Hosts require an exact match.
- **Release version** (`OSCILLUX_VERSION_MAJOR`, `_MINOR`, `_PATCH`, packed as
  `OSCILLUX_VERSION`; `oscillux_version()`). It is the crate version in the workspace
  `Cargo.toml`, follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html), and
  increments with every release:
  - an ABI version change increments MAJOR, or MINOR while MAJOR is 0;
  - an added function, constant or struct, a deprecation or an observable behavior change
    increments MINOR, or PATCH while MAJOR is 0;
  - a fix that keeps documented behavior increments PATCH.

  Pre-release and build suffixes are not used, because the packed value cannot carry them.
  MINOR and PATCH must stay below 256 and MAJOR below 65536.

Builds between releases report the last release's version. 0.0.0 means no release yet.

## Startup check

A host checks once, before any other call:

```c
if (oscillux_abi_version() != OSCILLUX_ABI_VERSION) {
    /* Signatures, layouts or statuses differ: do not use this library. */
} else if (oscillux_version() < OSCILLUX_VERSION) {
    /* Older release: functions added after it may be missing. Use only those its release
     * declares (CHANGELOG.md), or refuse it. */
}
```

The ABI test comes first. Packed versions from different ABI versions are not comparable for
compatibility. A library that predates `oscillux_version` (added within ABI version 1) does not
export it, so linking or symbol lookup fails rather than the check misreporting.

## Extensible structs

The header states the rule; this is its rationale and lifecycle.

- A configuration or policy struct added from now on begins with `uint32_t struct_size`. The
  caller sets it to `sizeof` the struct as its header declares it, before any call that takes the
  struct, including the struct's `*_default` function.
- Members are only appended, each with a documented default. They are never reordered, retyped
  or removed. A function reads and writes only the members within `struct_size` and uses the
  default for the rest, so a host built against an older header keeps working with a newer
  library.
- `struct_size` must be the size of that struct in some released header; any other value returns
  `OSCILLUX_ERR_INVALID_ARGUMENT`. A newer host on an older library fails with that status
  instead of having members silently ignored.
- Per-frame structs and array elements (for example `OscilluxDspFrame`, `OscilluxLimiterFrame`
  and `OscilluxUniformField`) never carry `struct_size`. A change to one adds a new struct and
  function, or waits for an ABI version change.
- `OscilluxDspConfig`, `OscilluxLimiterPolicy`, `OscilluxCurveConfig`, `OscilluxGovernorConfig`
  and `OscilluxMappingConfig` predate the rule. Adding the member would change their layouts,
  which ABI version 1 forbids. The next ABI version adds `struct_size` to each of them.
  `crates/oscillux-ffi/tests/abi_snapshot.rs` lists them and fails on any other configuration
  or policy struct that does not begin with `struct_size`.
- A new member for one of those structs goes in a new wrapper struct that begins with
  `struct_size`, embeds the old struct unchanged, and then appends the member.
  - `OscilluxDspVersionedConfig` does this for `behavior_version`, followed by a `reserved`
    member that must be 0. Without it the struct would end in 4 bytes of padding, so a 4-byte
    member appended later would not change `sizeof` and could not be told apart by
    `struct_size`.
  - The ABI-1 functions that take the bare struct keep their behaviour: `oscillux_dsp_create`
    stays at DSP behaviour version 1.

## Deprecation

1. A deprecated function, constant or member keeps working. Its header comment begins with
   `Deprecated since X.Y.Z:` and names the replacement. The release that deprecates it lists it
   under **Deprecated** in `CHANGELOG.md`.
2. It is removed only by an ABI version change, and no sooner than the second release after
   the deprecating release. The removal is listed under **Removed**.
3. An ABI version change gathers every pending removal and layout change, including
   `struct_size` for the structs above, so hosts migrate once.

## Recording a change

- Every change to the interface or to observable behavior adds a line under **Unreleased** in
  `CHANGELOG.md`, in the Keep a Changelog section that fits.
- A change to a function, constant or struct layout also regenerates `ffi/abi-snapshot.txt`
  with `make abi-snapshot` and commits it with the header. `make gate` runs `make abi-check`,
  which fails with a line diff when they differ. Reviewers read the snapshot diff to decide
  whether the change is additive or needs a new ABI version.
- A release sets the version in `Cargo.toml` and the `OSCILLUX_VERSION*` defines together;
  `crates/oscillux-ffi/tests/header_constants.rs` fails if they differ. It also moves
  **Unreleased** under a dated version heading.

The snapshot records layouts from a 64-bit host, where macOS and Linux agree. 32-bit targets
differ in `size_t` members. No gate step compiles the header for them; `make targets` checks
only the Rust side.
