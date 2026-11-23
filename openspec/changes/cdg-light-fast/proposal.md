<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Lighter CD+G lettering, rendered well above real time

Ticket: **CORE-3260** (Corvint Tasks, beamfall core queue), plus owner feedback of 2026-11-22.

## Why

The owner finds composed CD+G lyrics too bold: strokes look thick and letters heavy. Three things
add weight. The box blur and the 112 threshold put each edge about 0.17 magnified pixels outside
the unblurred edge. Lower-rank layers paint a coloured fringe into the anti-aliased band of
higher-rank glyphs even where their own colour is nowhere near (a pink rim on white lyrics). And
the shadow is dark enough to read as a halo.

The live server composes CD+G under wazero and serves a segment only once its frames are drawn.
A busy disc (every colour inked on many rows, tiles changing every pack) renders at about 13
frames per CPU second at 960 x 540, far below the 30 frames per second the stream needs.

## What Changes

- Layer masks blur with the kernel [1, 4, 1] / 6 per axis instead of the box [1, 1, 1] / 3. The
  edge threshold rises from 112 to 171, just under the 177 a lone window pixel reaches, so each
  edge sits about 0.15 magnified pixels inside the unblurred edge. Strokes are lighter, counters
  open wider, and lone pixels still draw.
- A layer draws at a frame pixel only where its own index lies inside the blur support of its
  taps: its four tap levels differ from the next layer's. The last layer draws wherever it is
  not zero. The fringe goes; coverage geometry is unchanged.
- The shadow's alpha drops from 166 to 110.
- The presenter gets faster without changing any frame: index sets per magnified pixel replace
  scans of empty layers, and work goes only to rows whose source changed. A CPU-time guard in
  the frame budget bench fails when a worst-case stream presents below 120 frames per CPU second
  natively at 960 x 540, which keeps wasm32 under wazero above 60.
- Spec, oracle and vectors updated together.

## Non-goals

- Changing the decoder, ranks, ink selection, colours or the backdrop.
- Per-resolution weights: the threshold and kernel are the same at every frame size.
