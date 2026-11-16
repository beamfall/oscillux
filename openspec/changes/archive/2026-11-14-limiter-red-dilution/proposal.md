# Frame flash limiter: count red that covers part of a sub-block, and red-free default palettes

Ticket: CORE-1616 (P1, `queue:core:main`). Owner decision 2026-11-14: "Lower step + fix visuals"
(it replaces the earlier "Freeze, step/8").

## Why

On the catalog host manifest (macOS ANGLE Metal, Apple M2 Max, `limiter-red-audit.mjs --beats 12`,
61 visuals) four visuals keep large-area red transitions after the v0.1.0 limiter: reactor (4/s),
vault (2/s), loom (4/s) and laser-tunnel (6/s). The cause is dilution. A sub-block requests a red
transition when its mean red code moves by 4096 codes, while the pixel auditor applies that step to
each pixel. When red covers a quarter of a sub-block, the mean moves by a quarter of the pixel
change and the block never requests, so a window the auditor sees as more than 25% transitioning
red holds only 40–90 such blocks against a limit of 64. This is the "detail finer than a sub-block"
gap (CORE-0125 evidence record, Known gaps) applied to partial coverage.

## What Changes

- The red request step drops from 4096 codes to 512 (an eighth), in `tools/shader/limiter-model.mjs`
  and `shaders/limiter/common.glsl`, so red that covers about an eighth of a sub-block or more is
  counted toward the area limit. Luminance is unchanged.
- A `stripes` test signal and a `red-stripes-10hz` conformance case (one red column in three,
  `[110,0,0]` <-> black at 10 Hz) that the v0.1.0 model admits at 20 red transitions a second.
- The default palettes of four reference visuals in `shaders/manifest.json` move off red-dominant
  palettes: vault 12 (moltenGold) -> 17 (amber), reactor 20 (infrared) -> 1 (emberIce),
  laser-tunnel 20 -> 23 (absinthe), loom 26 (tuscany) -> 3 (deepSea). Reactor and loom take their
  originals' defaults. The bodies do not change, and the old palettes stay selectable.
- The evidence page records the diagnosis, the re-measured catalog and the held fractions.

## Owner decision

Asked on 2026-11-14 to choose between freezing red-heavy visuals, changing the catalog, re-scoping
the red rule, or per-pixel GPU trackers, the owner first chose to freeze (step/8). That froze vault
to 96% held on average (84% at v0.1.0) and laser-tunnel to 88% (55%). The owner then chose to lower
the step and also change the visuals: lower the step only as far as the catalog needs for 0 red,
and change the visuals or their default palettes so vault and laser-tunnel stop flashing red and
are not frozen.

The step is the largest one tried (4096, 1024, 512) that leaves 0 red after the limiter on the
catalog with its v0.1.0 palettes, which hosts can still select: 1024 leaves one red transition a
second on loom and on laser-tunnel. With the new default palettes no catalog visual flashes red at
all, and the smaller step costs at most 0.11 points of held area on any visual against 4096. Red that the auditor
would not count (a change under 20 on its scale) can be held when it sits in a block whose mean
moves by 512 codes.

## Non-goals

- The luminance excess. On the same audit 21 visuals show more large-area luma transitions after
  the limiter than before (ripple 8 -> 14/s, wave-cascade 10 -> 17/s). Those counts are the same at
  v0.1.0 and this change does not worsen any of them; the cause is grant-release edges and in-block
  cancellation, and its fix is a separate design (filed separately).
- Pattern detail that cancels inside a sub-block (half the pixels up, half down). No step on the
  mean sees it.
- The CPU `FlashAnalyzer` and the WCAG 2.2 u'v' red test.

## Failure modes

- A visual run with a red-dominant palette (one of the old defaults, or a host preset) freezes
  over most of the frame: vault holds 96% and laser-tunnel 88% with their v0.1.0 palettes. A host
  that finds that worse than its audience's risk must change the visual or its palette, not the
  limiter.
- The palette change reaches a host only with a release that carries it and the host's pin bump.
  Until then the catalog keeps the v0.1.0 palettes and the freezing above.
- JS and GPU results stay bit-identical only while both sides use the same constant;
  `make limiter-check` fails otherwise.

## Acceptance evidence

- `make limiter-check`: regenerated vectors (luminance-only cases unchanged), the model tests
  (including `red-stripes-10hz`, which fails against the parent commit's model), and the WebGL2 and
  Metal legs bit-identical to the model.
- The catalog audit on the reference host: 0 visuals with large-area red before or after the
  limiter with the new defaults, 0 after it with the v0.1.0 palettes, mean held well below the
  96% (vault) and 88% (laser-tunnel) of the freeze-only step, and no visual's luma output higher
  than at v0.1.0 unless it now equals its input.

## Rollback

Revert the commits and repin the previous release. No stored state depends on the step.

## Capabilities

### New Capabilities

- `visual-defaults`: the default palettes of the reference visual set produce no large-area red
  transitions on the catalog audit.

### Modified Capabilities

- `frame-limiter`: red requests use a step of one eighth of the pixel step.
