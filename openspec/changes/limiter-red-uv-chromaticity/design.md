<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Design: red transitions by the u'v' chromaticity rule (CORE-2935)

Owner decision 2026-11-21, after Codex design round 1 held the zone design: "Widen limiter
memory". Each pixel keeps the u'v' chromaticity of the last saturated-red state it showed, in a
tracker texel widened from RGBA16UI to RGBA32UI. Section 12 maps each round 1 finding to its fix.

## 1. The rule

WCAG 2.1 and 2.2 (current Recommendations), "pair of opposing transitions involving a saturated
red", working definition: one state of a transition is saturated red, R / (R + G + B) >= 0.8, and
the two states are more than 0.2 apart in the CIE 1976 UCS (u', v') diagram. R, G and B are the
linearised sRGB channels.

- A colour's u'v' depends only on its chromaticity. The saturated set is a triangle in the
  chromaticity plane with vertices P (1, 0, 0), RG (0.8, 0.2, 0) and RB (0.8, 0, 0.2). The map to
  u'v' is projective, so the set maps to a triangle, P (0.4508, 0.5229), RG (0.3078, 0.5403), RB
  (0.3904, 0.4428) under the IEC 61966-2-1 matrix. Its diameter is 0.144, so two saturated states
  never make a transition.
- Black has no chromaticity (0 / 0). The u'v' rule neither starts nor ends a transition at black,
  and black keeps the pixel's reference. Changes to and from black stay with the luma rule and the
  320 rule. Reading black as the D65 white point would count every dark-red glow fading out; the
  definition does not say that and it is not adopted.

A transition here is measured the way `trackStep` measures luma: from a reference to the first
state past the threshold. The reference is the last saturated state the pixel showed (section 4).

## 2. Integer codes

Every decision is integer arithmetic on 8-bit display values, identical in the model, the
auditor and the GLSL legs. No intermediate exceeds 2^32 - 1, so it runs in `uint` on GLSL ES 3.00.

```
LIN24[k] = round(linear(k / 255) * 2^24)            // a generated LUT, as LUMA_LUT
s = LIN24[r] + LIN24[g] + LIN24[b]; s == 0: black, no code
k = the least shift with (s >> k) < 2^18             // 0..8, a bounded loop: no findMSB in ES 3.00
c_i = LIN24[i] >> k; s2 = c_r + c_g + c_b
n_i = (c_i << 14) / s2                               // chromaticity in 2^-14, each term < 2^32
X = 6757 n_r + 5859 n_g + 2957 n_b
Y = 3483 n_r + 11718 n_g + 1183 n_b
D = 59954 n_r + 187485 n_g + 67420 n_b;  q = D >> 14
u = 4 X / q;  v = 9 Y / q                            // u' and v' in 2^-14 (Q = 16384), 14 bits each
```

The coefficients are the IEC rows times 2^14 and (X_i + 15 Y_i + 3 Z_i) times 2^14. Measured over
every 8-bit colour, against both the IEC matrix and the matrix derived from the sRGB primaries
and D65:

- the code is within E = 2.0443e-4 of the true (u', v') (worst at (254, 1, 8));
- the vertex codes VC, P (7386, 8567), RG (5044, 8852) and RB (6396, 7255), are within
  EV = 1.0144e-4 of the true vertices;
- the largest intermediate is 4287119360; u <= 7386 and v <= 9216.

The thresholds below use the bounds E = 2.5e-4 and EV = 1.5e-4, which the check asserts.

**Saturated.** `s24(c)`: non-black and `LIN24[r] + 1 >= 4 (LIN24[g] + LIN24[b])`. Over every
8-bit colour it accepts every colour whose float64 r / (r + g + b) >= 0.8 and no colour below
0.8 - 1e-12. The 320 rule keeps its own `redSat`.

`tools/shader/limiter-uv-check.mjs` reproduces every number in this section and the next over
all 2^24 colours (about 10 s) and runs in `make limiter-check`.

## 3. Thresholds

All in squared code units.

- **T = 10683798** = floor(((0.2 - 2E) Q)^2). The down test is d^2 > T. Two states more than 0.2
  apart have codes more than 0.2 - 2E apart, so every WCAG transition passes. A pair between
  0.2 - 2E and 0.2 also passes: the early band.
- **TF = 10634475** = floor(((sqrt(T) / Q - E - EV - 1 / Q) Q)^2). A code is *far* when its d^2 to
  some vertex code exceeds TF.
- **TVF = 12125795** = ceil((R Q)^2), R = sqrt((sqrt(T) / Q + E + 1 / Q)^2 + (L / 2)^2) + EV,
  L = 0.143999 the longest edge of the vertex-code triangle. A code is *very far* when its d^2 to
  every vertex code exceeds TVF.

The check takes the convex hull of the 788060 distinct saturated codes (20 vertices) and asserts
over every distinct code:

- every code with d^2 > T to some hull point is far (farBad = 0), so a non-far code can never
  pass the down test against any saturated reference;
- every very-far code has d^2 > T to every hull point (vfBad = 0), so it passes the down test
  against any saturated reference.

Distinct non-black codes: 1589569 very far, 4698521 far only, 2188875 neither.

## 4. Per-pixel state and the step

Each pixel keeps:

- `state`: unknown, none (no saturated state since the reference was dropped) or known;
- `ref`: the (u, v) code of the last saturated state shown when known; the last fired far code
  when unknown;
- `down`: the down transition from `ref` has fired;
- `far`: a far code has been shown since the last saturated state.

The step on a shown colour c returns the red direction it fires, or none, and the next state:

| c | state | fires | next |
|---|---|---|---|
| black | any | none | unchanged |
| saturated | any | up if `far` or unknown | known, ref = code(c), down = 0, far = 0 |
| other | known, not `down` | down if d^2(code, ref) > T | if fired: down = 1, far = 1; else far \|= far(code) |
| other | known with `down`, or none | none | far \|= far(code) |
| other, very far | unknown | down | none, far = 1 |
| other, far | unknown | down if code != ref | ref = code, far = 1 |
| other, neither | unknown | none | unchanged |

A pixel with no state yet (`UNTRACKED`) takes its first value without firing: known with
ref = code(c) if c is saturated, else none with far = far(code(c)); down = 0.

**Up.** An up transition from a state x to a saturated s exists only if d^2(x, s) > T, and then x
is far (farBad = 0). So firing up whenever a far code was shown since the last saturated state
fires every one.

**The unknown state** (the zero seed) has lost the reference. It fires on a superset of the first
crossings any reference would have made:

- up on every saturated colour;
- down on a very-far colour, which crosses from every saturated reference (vfBad = 0);
- down on a far code that differs from the last one it fired: a code equal to one already fired
  is at the same distance from the lost reference, so it is not a first crossing;
- nothing on a code that is neither, which no saturated reference is more than T from.

It leaves unknown at its first saturated or very-far colour.

**Black** changes nothing. So (255, 0, 0), black for 1.5 s with no restart, then (0, 255, 0) counts
a fall at black (320 rule) and another at green (u'v' rule).

**Why the last saturated state.** P1-a (section 12) alternates a saturated A with an
intermediate B 0.165 from A and a C 0.397 from A, staggered over two stripes. Measured from A,
both stripes cross at C together. The step fires both at that frame, so the area is summed.

## 5. One red direction per pixel

The red direction a pixel fires is the u'v' direction when that fires, else the 320 rule's.
`fires()`, the output's fired bits and stamps, and the auditor's count all use this merged
direction.

- **Safety.** The area test counts pixels firing in any direction and channel, and every granted
  red event spends the red token, which takes at least 1.33 s to refill. So no area makes two
  large-area red changes within 1.33 s, whichever rule each pixel's change is under.
- **Liveness (P1-b).** A constant (1, 0, 0) after a zero start asks for red up only (unknown
  state), where the zone design also asked down from the unknown 320 memory. It is granted at the
  first red grant and fires nothing after. A constant colour never asks for both directions.

## 6. Tracker texel and host contract

The tracker textures (`uTrack`, `oTrack`) become RGBA32UI. The low 16 bits of each word are the
existing texel, so every existing masked read is unchanged. The high 16 bits:

| Word | Bits 16 to 31 |
|---|---|
| x | ref u code (bits 16 to 29) |
| y | ref v code (bits 16 to 29) |
| z | state (bits 16 to 17: 0 unknown, 1 none, 2 known), `down` bit 18, `far` bit 19 |
| w | unused, written 0 |

- **Seeds.** Zero decodes as state unknown with ref (0, 0), a code no colour has, so the first far
  colour fires. "Black, nothing owed" becomes (x 0, y 32768, z 65536, w 0): state none, far 0.
  `UNTRACKED` stays (0, 8192, 0, 0).
- **Hosts.** Allocate both tracker textures RGBA32UI (WebGL `RGBA32UI`, Metal `.rgba32Uint`, GLES
  `GL_RGBA32UI`), and seed and clear them with 32-bit values. Memory is 16 bytes a pixel per copy:
  two copies are 265 MB at 3840 x 2160, up from 133 MB.
- **Rollout.** The web renderer changes in the core repin to v0.2.13. The Apple and Android hosts
  change when they repin. A host that keeps RGBA16UI loses the high halves, which then decode as
  unknown with ref (0, 0) every frame: safe, but every saturated or far pixel fires red on every
  frame. The host change is required.
- **Why not a second texture.** A second tracker texture would add an output attachment, a
  sampler and a ping-pong pair per leg and host. Widening the format changes one allocation and
  one seed per host.

## 7. The auditor

`limiter-audit.mjs` keeps the same state per pixel with the model's exported code functions and
thresholds, but is never unknown:

- at its first frame (`!live`) a saturated pixel is known with ref = its code, any other none
  with far = far(code);
- a black reseed sets none, far 0, down 0;
- a zero restart keeps the state.

Its count per pixel and frame is the u'v' direction when that fires, else the 320 rule's. Where
the limiter is unknown and the auditor is not, the limiter fires on a superset (section 4), so
the limiter's area includes every pixel the auditor counts.

## 8. Consequences

- **Zero starts.** After a zero start, a pixel in the far band whose code keeps changing asks red
  down at each change until it shows a saturated or very-far colour. Over the area limit it
  changes once per red grant, about every 1.33 s. Grey and most mid colours are far only, so most
  of such a frame updates slowly until each pixel shows saturated red or a very-far colour, or
  the host restarts black. The web player starts black after `BLACK_S` and is not affected.
  Hosts should restart black where they can. A two-disk set reference, which would release these
  pixels sooner, was considered and rejected for its size.
- **Dark noise.** Dither between (1, 0, 0) and (0, 0, 1) is a saturated/far alternation, and it
  counts. The definition has no luminance floor and none is added. The probe (section 10)
  measures what this holds.
- **Cost.** The code costs five 32-bit divisions and up to eight shifts, only for non-black
  pixels whose state needs it: none for a saturated pixel in the rows pass, none for a known pixel
  with `down` set and `far` set. Held pixels evaluate it per search step, as they evaluate luma.

## 9. Vectors

New cases in `tools/shader/limiter-vectors.mjs`, written with `--write` and run on every leg:

| Case | Input | Checks |
|---|---|---|
| `red-green-dim-10hz` | 10 Hz, (60, 0, 0) / (0, 60, 0) | The CORE-2935 repro: only the u'v' rule counts it. |
| `red-blue-10hz` | 10 Hz, (255, 0, 0) / (0, 0, 255) | A full red flash: luma, 320 and u'v' all count. |
| `red-mask-10hz` | 10 Hz, (5, 0, 0) / (255, 0, 230) | Each change is a 320 rise and a u'v' fall: the merged direction. |
| `red-black-dim-10hz` | 10 Hz, (60, 0, 0) / black | No rule counts it; the output equals the input. |
| `red-stagger` | P1-a, 2.5 Hz | Two stripes, each 20% of the frame, cross 0.2 from A at the same frame after B at different frames. |
| `red-zero-constant` | zero start, `G` spent, constant (1, 0, 0) | P1-b: the frame shows (1, 0, 0) from the first red grant on. |

`red-stagger` uses a new signal kind, `bands`: columns x with x mod 5 = k show the k-th band's runs,
and the other columns show black. Stripe 1 shows A (60, 0, 18) at frame 0, B (35, 0, 32) at 1 to 7,
C (0, 0, 60) at 8, B at 9 to 15 and A at 16 to 23. Stripe 2 shows A at 0 to 6, B at 7, C at 8, B at
9 and A at 10 to 23. Neither luma nor the 320 rule counts it (red codes under 15).

`test-limiter.mjs` asserts, for the 10 Hz cases with a red flash and for `red-stagger`, that the
pixel auditor counts red transitions in the input (at least 18 a second for 10 Hz, at least 2 for
the stagger) and at most 1 a second in the output.

**No regressions.** The tracker digest hashes all four bytes of each word, so every case's
digest changes. A one-off script compares the new model's frames with the committed
`vectors.json` case by case and frame by frame: outputs, hold masks, grants, grant state, and the
low 16 bits of each tracker word. Every difference must come from the u'v' rule or from a seed's
new high halves (for example `reset-short-black` frame 308); the code review lists each one.

## 10. Probe and calming

1. `limiter-red-audit.mjs --release --audio loud` on the model at 480 x 270, before and after:
   each visual's input red transitions and held fraction under both rules.
2. The web player probe (`zz-pause-probe-player.spec.ts`) once over the 61 release visuals, on a
   build that vendors the candidate legs. No visual may hold more than 0.5% of pixels a frame.
   A visual over it is calmed in its shader and only that visual is probed again. Calmed visuals
   are listed in `tasks.md`.

## 11. Not done

- **Two metrics in one granted frame.** Read under a single metric, a granted frame can hold up
  and down areas made of different pixels. The token bounds large-area red changes either way
  (section 5).
- **The early band.** Pairs between 0.2 - 2E and 0.2 count. This over-counts, as the 320 rule's
  widened codes do.
- **A set-valued reference.** Only the last saturated state is kept: A, then a saturated A', then
  c measures from A'. A then c is not a transition of the sequence A, A', c, so this matches
  state-to-state reading. A slow saturated drift followed by a jump measures from where the drift
  ended.
- **A float auditor.** The auditor uses the integer codes, which are the measure, as for luma.
- **Zero-start liveness** (section 8).
- **Black as D65 white** (section 1).

## 12. Codex design round 1 findings

- **P1-a, staggered intermediate state:** fixed by the last-saturated reference (section 4) and
  covered by `red-stagger`.
- **P1-b, liveness from a zero seed:** fixed by the merged direction (section 5) and covered by
  `red-zero-constant`.
- **P2, the float saturated test:** the check asserts every non-black colour with float64
  r / (r + g + b) >= 0.8 is `s24` (section 2).
- **P2, seed changes in the no-regression rule:** allowed and listed (section 9).
- **P3, zero-start impact and flash counts:** restated in section 8 and the proposal.
