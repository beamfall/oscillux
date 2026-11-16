<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Present pass v2

Ticket: **CORE-0108** (Corvint Tasks, beamfall core queue).

## Why

The shared present pass (`shaders/present/present.glsl`, OSC-OVERLAY) tone maps each channel with
ACES. That shifts the hue of bright saturated colours by up to 43 degrees: orange turns yellow and
blue turns purple. It also rounds straight to 8 bits, so dark gradients band into runs of up to
71 px. It has no bloom, grain or chromatic aberration. Hosts that want those effects would add
their own, and Oscillux is the only source of visual effects.

## What Changes

- Tone map on luminance (the same ACES fit), scale the colour to the mapped luminance, and move a
  colour that would clip toward the grey of that luminance. Hue is kept and greys map as before.
- Add triangular (TPDF) dither of `post0.w` codes before the fixed-point output. Within one code
  of either end the dither is rectangular, and within 1/1024 code of an end the value snaps to
  that end, so black and white stay exact. Text-region pixels keep rounding toward their bound.
- Add a 5-level soft-knee bloom chain (`shaders/present/bloom.glsl`): prefilter, 4 downsamples,
  then 4 additive upsamples, all rgba16f. Its L0 is added in linear light before the grade,
  scaled by `post0.x`.
- Add radial chromatic aberration (`post0.y`) and multiplicative film grain (`post0.z`) from an
  integer hash (`presentHash`, an xorshift-multiply mixer written for Oscillux, no `sin`). Grain is 0 under reduced motion, and the hosts also upload
  trail decay 0 under reduced motion.
- Extend the PresentBlock from 336 to 368 bytes with `post0` (bloom, aberration, grain, dither)
  and `post1` (frame seed). The bloom L0 binds at texture 4.
- Keep the existing region blur and desaturate, the text contrast bound and temporal damping.
- Add the gate target `present-v2-check`. It holds hue error and banding to fixed limits through
  a standard-library model and through the real pass on Metal, and compares every GPU code with
  the model.

Pipeline order is unchanged: present, then the flash limiter, then output. The limiter remains
the last stage.

## Non-goals

- The limiter itself (built separately), transitions, and the region packing schema.
- Turning bloom, aberration or grain on by default in either reference host. Hosts upload dither
  1 and a frame counter. The other effects stay at 0 until a host chooses a look.
- Wiring the bloom chain into the reference hosts. They bind the scene at texture 4 with
  `post0.x = 0`, and the pass does not read texture 4 when `post0.x` is 0.

## Failure modes

- A host that uploads the old 336-byte block reads garbage `post0` and `post1`.
  `present.mjs` checks the 368-byte block size, and both hosts pack 368 bytes.
- Dither on a float target adds noise without effect. Hosts dither only the 8-bit output (`levels
  > 0`).
- Bloom left at full strength over large HDR areas is heavy, because the up chain sums all five
  levels. Hosts pick small strengths (the evidence uses 0.12).

## Acceptance evidence

The CORE-0108 evidence record covers:

- hue error before and after;
- banding before and after;
- agreement between the GPU and the model;
- the 1080p chain time on a named Metal GPU;
- contact sheets (`make present-v2-gpu` writes them to `out/present-v2`);
- `make present-v2-check` in `gate`.

## Rollback

Revert the change. The v1 body is restorable from git (`532a4f4:shaders/present/present.glsl`),
and the hosts go back to the 336-byte block. No persisted state or wire format depends on the
pass.
