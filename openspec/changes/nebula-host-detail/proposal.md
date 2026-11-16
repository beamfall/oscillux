<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Nebula follows the host's detail reduction

Ticket: **CORE-2220** (Corvint Tasks, beamfall core queue).

## Why

Hosts that govern their frame rate lower `presentation1.y`, a detail reduction in [0, 1], as
they drop quality levels. No library visual reads it, so a host's lowest level only shrinks the
render size. Nebula costs about 960 hash calls per pixel (12 shells, each with two `fbm` warps
and two `fbmRidged`). At the Beamfall Web Viewer's lowest level (half scale, reduction 1) on a
3840 x 2160 canvas, its visual pass alone takes about 14 ms on the reference Mac, so the viewer
holds about 54 fps and alternates between its two lowest levels.

## What Changes

- Nebula reads `detail = 1 - clamp(presentation1.y, 0, 1)` and runs `6 + round(6 * detail)` shells, 12 at detail 1 and 6 at detail 0, and scales each
  shell's alpha by `12 / shells` so the cloud keeps its overall density.
- At reduction 0 nebula renders as before. The shared library is untouched, so no other
  visual's emitted bytes change.

Measured on the live viewer (visual pass only, nebula, 20 draws): 14.2 ms to 7.6 ms at
1920 x 1080 with reduction 1; 24.5 ms to 16.9 ms at 2560 x 1440 with reduction 0.6; 52.6 ms
and 53.6 ms at 3840 x 2160 with reduction 0.
