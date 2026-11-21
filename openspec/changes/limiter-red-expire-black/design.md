<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Design: red expiry at host restart only (CORE-2869)

## 1. Restart events

A restart is the moment a host builds a new limiter: the first start, and the start after a frame
change (fade through the limiter, black, start; frame-limiter "Frame change"). There is no other.
Before every restart the host presents exact black, cleared to (0, 0, 0), without running the
limiter ("Black before the start"). It credits that black one presented frame at a time.

Both sides use one threshold, `blackLongEnough(ms)` in `tools/shader/limiter-model.mjs`:
`ms >= RED_EXPIRE_MS - 1e-3`. The tolerance absorbs float accumulation (75 frames of 1000/60 ms sum
to 1249.9999999999995 ms) and nothing else; it is a microsecond.

Host, at a restart:

```
// blackShownMs: presented time of the current exact-black hold. The host credits one presented
// frame at a time: at each animation frame after the first black one it adds the interval since
// the previous frame, capped at 100 ms, so a stall or a hidden tab overstates nothing.
hold until blackShownMs > COVERAGE_MS and the view shows a whole texel       // unchanged
seed = blackLongEnough(blackShownMs) ? 'black' : 'zero'
clear every tracker texel to seed (BLACK_TEXEL or ZERO_TEXEL); write G fully spent
[256, 65025, 65025, 0]; restart the clock; the output starts black
```

Error bound: every credited interval is a span during which a black frame was on screen (the
canvas is cleared to black and stays black until the limiter's first frame replaces it), so the
credited time is at most the black time displayed plus the presentation jitter of one frame.
At 60 Hz that is 16.7 ms. The 250 ms between `RED_EXPIRE_MS` and a one-second window covers it
(section 6).

`BLACK_TEXEL` = (0, 32768, 0, 0): luma falling at 0, red falling at 0, red memory `RED_MEM_LO`
(the latest red step counted, no saturated state since). `ZERO_TEXEL` = (0, 0, 0, 0): tracked
black, red memory unknown. Both already exist in the limiter's state space, so no shader changes.
The reference model takes `createLimiter({ start: 'untracked' | 'zero' | 'black' })`. The
conformance vectors start `untracked` and may restart mid-case with `reset: { at, seed }`.

Auditor (`tools/shader/limiter-audit.mjs`):

```
per pixel j: blackSince[j] = clock at the first frame of j's current exact-black run, else NaN
pending = null

restart(seed):                 // the host restarts before the next frame it presents
  if seed == 'black': pending = 'black'
  // 'zero': nothing; the limiter's unknown red memory is conservative ("A host reset is
  // conservative"), so the auditor keeps every pixel's history

push(px, dt):
  clock += dt * 1000           // frame k is on screen from clock_k to clock_k+1
  if pending == 'black': lastRestart = { reseeded: 0, ineligible: 0 }
  for each pixel j:
    if pending == 'black':
      if blackLongEnough(clock - blackSince[j]):             // NaN compares false
        ext[luma][j] = ref[luma][j] = 0; dir[luma][j] = -1   // the black seed, as BLACK_TEXEL
        ext[red][j]  = ref[red][j]  = 0; dir[red][j]  = -1
        redCounted[j] = 1; anySat[j] = 0                     // nothing owed, no saturated state
        lastRestart.reseeded++
      else:
        lastRestart.ineligible++                             // history kept; the host broke
                                                             // "Black before the start"
    if px[j] is (0, 0, 0): blackSince[j] = isNaN(blackSince[j]) ? clock : blackSince[j]
    else: blackSince[j] = NaN
    ... track luma and red exactly as before ...
  pending = null
```

The reseed reads `blackSince` before the current frame updates it. Black on frames b..t-1 has been
on screen for clock_t - clock_b = (t - b) / 60 s at 60 Hz, so 75 frames give 1250 ms and 74 frames
give 1233 ms. Nothing else in the auditor expires. The playback expiry of the round 3 build
(`redExpireMs`, the per-pixel restart during `push`) is removed. `lastRestart` lets a test assert
that a host kept the contract (`ineligible` 0 at every black restart). A pixel left ineligible
keeps its history, so the auditor still judges what the limiter then admits.

The reseed overwrites all six fields with the seed, so the state equals `BLACK_TEXEL` as decoded.
A pixel already black for a frame or more may hold other fields (round 1: red ref 11 with ext 0
after a sub-step red fade). Section 6 does not rely on those fields matching the seed's; it rests
on when the forgotten steps were on screen.

### Agreement

The limiter's trackers make the auditor's decisions from a common state (frame-limiter
"Per-pixel transition trackers"). A host that keeps the contract presents exact black on every
pixel for at least 1250 ms before seeding `BLACK_TEXEL`, so at that restart the auditor reseeds
every pixel to the same state, and the two agree again from the same frame. With a zero start the
auditor does not reseed and the limiter is conservative, as before ("A host reset is
conservative"). Neither side changes state during playback, which removes round 3 P1 #1 by
construction.

## 2. Exact black

Only the presented bytes (0, 0, 0) are black. Every other triple, (1, 0, 0) and (5, 0, 0)
included, ends the run, so a saturated state shown after the run began cannot be forgotten
(round 3 P1 #2). The host's hold is a clear to (0, 0, 0), which meets this exactly.

## 3. `osOffRed` near-black floor

The wrapper finishes every original with `suppressGreenCast(visual(uv, u))`, and each original
now returns `osOffRed(osBody(uv, u))`. Present then grades (vivid: saturation 1.35, vibrance 1.2),
tone maps, encodes sRGB and quantises to 8 bits with an optional dither. The dither's noise is
shared across channels, but its regime (rectangular under one code, triangular above) is chosen
per channel. That split is why a channel at code 0.9 and one at 1.1 can land at (1, 0, 0).

```glsl
const float OS_GREY_BELOW = 0.006;  // M0: below it the colour becomes exactly grey
const float OS_RED_FROM = 0.012;    // MF: below it red is at most the larger of green and blue
const float OS_RED_FULL = 0.05;     // M2: red's excess over it is whole from here
vec3 osOffRed(vec3 c) {
    c = mix(c, vec3(0.0), notEqual(c, c));      // NaN -> 0: a boolean select, exact (section 5)
    c = clamp(c, vec3(0.0), vec3(16.0));
    float need = 0.55 * c.r - c.g - c.b;
    if (need > 0.0) c += vec3(0.0, 0.5 * need, 0.5 * need);
    float m = max(c.r, max(c.g, c.b));
    if (m < OS_GREY_BELOW) return vec3(luma(c));  // three identical channels
    float p = max(c.g, c.b);
    if (c.r > p) {
        float w = clamp((m - OS_RED_FROM) / (OS_RED_FULL - OS_RED_FROM), 0.0, 1.0);
        c.r = w <= 0.0 ? p : p + w * (c.r - p);  // red equal to a partner below OS_RED_FROM
    }
    return c;
}
```

Below MF only red's excess over the larger partner is removed: a colour with red at or under it,
such as (0, 0.006, 0) or (0.004, 0.007, 0), passes unchanged.

Claim: for any input, NaN and infinities included, no pixel presented from `osOffRed`'s output on
the per-pixel present path is a `redSat` byte triple. The path is `suppressGreenCast`, the vivid
grade, the tone map, film grain of amplitude 0 to 0.25 (the whole `post.grain` range; the
originals carry no `post`, so their grain is 0), sRGB encoding, and 8-bit output with dither of 1
or 0.5 code, or with no dither and a target rounding that is one monotone function for all three
channels.

Evidence:

- **Structural, below the floor.** Two bitwise-equal channels stay equal through every per-pixel
  stage: grade, tone map, grain (one factor for all three), encode, dither (same code, same
  regime, same noise), and a target rounding that is one function. An exact grey therefore never
  presents red over green plus blue, and neither does a colour whose red equals green or blue.
  `suppressGreenCast` leaves both unchanged: its excess is `g - max(1.08 max(r, b), 0.78 l)`,
  negative when green is at most red or blue. So every colour with max channel under M0, and
  every red-dominant colour with max under MF, is safe on any 8-bit target by construction.
- **Conservative byte check, everywhere else.** The checker
  (`tools/shader/test-originals-red.mjs`) proves one input at a time. `redSat` is monotone: it
  stays true when red rises or green or blue falls. For an input it takes:
  - **Dither, every noise value.** The shared noise is u1, u2 in [0, 1), with rect = u1 - 0.5 and
    tri = rect + (u2 - 0.5). Each channel's code is a step function of one of them. So the
    (rect, tri) plane splits into cells by the lines rect = const, tri = const and
    tri = rect +- 0.5. The checker visits one point in every cell; within a cell every channel's
    code is constant.
  - **Grain, every factor.** It splits [1 - g, 1 + g] into 8 slices. Within a slice it takes red
    at the top and green and blue at the bottom.
  - **Regimes.** Within a slice, a channel can sit on either side of a regime boundary (snap
    under 1/1024, rect under 1, tri above). There red takes the largest code of the regimes
    reached and green and blue the smallest.
  - **No dither.** Red rounds up and green and blue round down.

  If none of those worst-case triples is `redSat`, no presented triple for that input is. The
  round 1 design sweep missed (27, 9, 0) at (0.0252, 0.0067, 0.0015) with grain factor 0.909
  because its cell walls left out the diagonals tri = rect +- 0.5. The checker finds that triple
  at the round 1 parameters.
- **Coverage at (M0, MF, M2) = (0.006, 0.012, 0.05): 0 redSat inputs.**
  - Grain 0, dither 1, 0.5 and 0:
    - a grid with the max channel at 201 log steps from 1e-4 to 16, the other two at every 1/32
      of it, each channel in turn as the max;
    - 600,000 random colours with the max log-uniform in [1e-4, 16];
    - 300,000 random colours in [5e-4, 0.03] (dither 1 and 0.5).
  - Grain 0.1 and 0.25, dither 1: 200,000 random colours in [0.005, 1].
  - Grain 0.05, 0.1, 0.15, 0.18 and 0.25, dither 1 and 0.5, with 16 grain slices: 1,000,000
    random colours in [5e-4, 0.08], the band where every failure above was found.
  - The random partners are the max times u², which weights them toward 0, the red-dominant side.
- **Margins.** Each neighbour below fails with the other two parameters at the chosen values:
  - M0 = 0.004 fails at grain 0.25 up to m = 0.0046 with (1, 0, 0), from green-dominant colours
    such as (0.0016, 0.0042, 0) that `suppressGreenCast` tints toward red. M0 = 0.003 fails at
    grain 0 up to m = 0.0035. M0 = 0.006 is 30 % over the largest failing m.
  - MF = 0.008 fails at grain 0.25 from m = 0.0080 to 0.0087 with (1, 0, 0). MF = 0.012 is 37 %
    over it.
  - M2 = 0.035 and 0.04 fail at grain 0.25 up to m = 0.0407 with (39, 15, 1); 0.045 passes.
    M2 = 0.05 is 23 % over the largest failing m.
  - The round 1 values (0.005, 0.008, 0.025) fail at grain 0.1 near m = 0.025 with (27, 9, 0),
    the Codex repro.
- **Cost.** Colours with max channel at 0.05 or more are unchanged from the round 3 form: green
  plus blue at least 0.55 of red, a presented share under 0.77. Below it, dim reds darken:
  - pure red 0.03 presents (24, 9, 9) instead of (34, 9, 9), and 0.02 (11, 5, 5) instead of
    (24, 5, 5);
  - red 0.01 presents grey (2, 2, 2), and orange (0.01, 0.005, 0) presents (5, 5, 0);
  - greens, blues and greys above 0.006 are unchanged.

The test carries the emulation and the checker at a CI-sized density (the grid and 20,000 random
colours per grain), checks the GLSL against the emulation's constants and form, and asserts the
round 1 repro at the round 1 parameters as the checker's own positive control.

## 4. Paths outside the claim

`osOffRed` is a quality measure. The limiter measures the bytes it is given and runs after
everything below, so a red-class byte on these paths costs held pixels, never safety. They are
excluded, each for a stated reason:

- **Channel-split sampling: present aberration (post0.y) and authored transitions such as Heat
  Haze.** Each output channel comes from a different source point, so the output is not a
  function of one `osOffRed` colour. A red tap on a neutral feature next to black reassembles
  saturated red at full brightness (round 3: (0.1, 0, 0) presents near (80, 0, 0)). No per-pixel
  floor can prevent that. The originals carry no `post`, so their aberration is 0 unless a host
  overrides it, and the Beamfall web host runs with post0 at no bloom, aberration or grain. A
  transition lasts one switch, under the limiter.
- **Pixel and frame mixes: bilinear resampling, bloom, the blur and desaturate regions, dissolves,
  and temporal damping with its luminance step limit.** These are non-negative weighted sums of
  colours that each meet the 0.55 share, and the share cone is convex, so mid and bright mixes
  stay out of the red class (round 3 confirmed this for dissolves and bloom). Near black, a mix
  of two floor colours is no longer bitwise grey or partner-equal, and its bytes can round into
  the class. The web host has damping keep 0 outside damp regions and reduced motion.
- **Text and layer regions.** The contrast floor and cap, and the composited layer, are host
  content, not the visual.

The 61-visual web probe measures what reaches the limiter on the real path, these effects
included.

## 5. NaN

`osOffRed` replaces NaN with 0 by boolean component selection,
`mix(c, vec3(0.0), notEqual(c, c))`. The `bvec3` overload of `mix` selects; it does not compute
`c * (1 - t) + 0 * t`, so a detected NaN never multiplies into the result. The library's
`sanitizeColor` uses the float-weight overload, which can return `NaN * 0`; `osOffRed` does not
call it (a ticket covers `sanitizeColor` and its copies). A clamp to [0, 16] then bounds
infinities. A NaN or infinite channel therefore never reaches the share rule (round 3 P3:
(0.1, NaN, 0) made `need` NaN and, after the wrapper's sanitise, presented pure red).

The exact result is promised where the target's comparisons honour IEEE NaN, which WebGL 2 and
GLSL ES 3.00 do not guarantee and Metal's default fast-math does not provide: a compiler may fold
`x != x` to false. There the NaN result is unspecified, and only the limiter's reading of the
final 8-bit bytes holds. That is the safety claim in any case; this section is quality only.

The shader test covers (0.1, NaN, 0), (NaN, 0, 0), (NaN, NaN, NaN), (+Inf, 0, 0), (0.1, -Inf, 0)
and (-1, 0, 0) in the emulation. It requires a finite result in [0, 16], no red-class bytes from
the checker, and for a NaN channel the result of the same colour with that channel at 0
((0.1, NaN, 0) gives (0.1, 0.0275, 0.0275)). It also checks that the GLSL selects with
`notEqual` before the clamp and the share rule, and does not call `sanitizeColor`.

## 6. WCAG 2.3.1 argument

**Metric.** The limiter's claim is stated in two measures:

- **Red:** the WCAG 2.0 and 2.1 red-flash definition. A state is saturated red when
  R / (R + G + B) >= 0.8 in linear light, and a red transition is a change of at least 20 in
  320 * max(0, R - G - B). The auditor uses a step of 15 codes on a 255 scale, about 18.8 on
  WCAG's 320, so it counts every such transition (a superset).
- **Luma:** the general-flash definition, a relative luminance change of at least 0.1 where the
  darker state is under 0.8.

The claim: in the presented output, the pixel auditor counts at most 6 large-area luma
transitions (3 flashes) and at most 1 large-area red transition in every one-second window.

WCAG 2.2 adds a chromaticity reading of red transitions: a CIE 1976 u'v' distance over 0.2 with
one state saturated red. The claim does not cover it. Full-screen (60, 0, 0) and (0, 60, 0)
alternating every 100 ms differ by 11 red codes and a sub-threshold luma step, so the auditor
counts nothing, yet their u'v' distance is about 0.33. This gap predates this change and is
tracked as its own ticket.

**Timing.** A transition happens at its on-screen step, the frame where the pixel's colour
changes. An auditor can charge a step later than it happened: a fall out of a state that was not
saturated is owed until a saturated state shows, and is then charged. Codex round 1 showed it:
black, (110, 64, 0), 75 black frames, a restart, 100 black frames, (5, 0, 0), (128, 0, 0). A
never-restarted auditor charges the owed fall from (110, 64, 0) at (5, 0, 0) and the rise 16.7 ms
later, two charges in one second. On screen only one step of red-transition size is in that
second, the rise; the fall happened more than 3 s earlier.

The owner approved this rule on 2026-11-21: owed red changes expire after black. The design
narrows it to host restarts after at least 1250 ms of exact black. Four points:

1. **Agreement.** During playback neither the limiter nor the auditor expires anything, so the
   existing proof (the limiter's trackers make the auditor's decisions and the grant rations
   them) holds frame for frame. At a black restart both reseed the same pixels to the same state
   at the same frame (section 1). At a zero restart neither reseeds anything. A host that sends
   a black seed without the hold is caught: the auditor keeps the history of every pixel that
   was not black for 1250 ms, and counts what the limiter then admits.
2. **The reseed drops only charges for steps at or before t0.** Let pixel p show exact
   (0, 0, 0) from t0 until the restart at t1, with t1 - t0 >= 1250 ms of presented time. Between
   t0 and t1 the pixel does not change, so it has no step there. The reseed forgets the owed
   step and the saturated-since flag, and both come from steps at or before t0. After t1 the
   reseeded auditor is the auditor of a black start, which the existing claim covers (spec:
   "Black before the start"): every later step is measured from black, the state on screen. A
   charge the never-restarted auditor makes after t1 and the reseeded one does not belongs to a
   step at or before t0.
3. **No one-second window holds steps from both sides.** Any step at or before t0 is at least
   1250 ms before any step after t1. So every one-second window holds steps from one side only.
   A window before t1 sees an auditor identical to the never-restarted one. A window after t0
   sees steps after t1 only, each counted from the true preceding state. No flash, a pair of
   opposing transitions within one second, is dropped. The 250 ms over one second bounds the
   host's credit error: the host credits presented frame intervals capped at 100 ms, and its
   count can run ahead of the screen by at most one frame (section 1).
4. **Luma is untouched.** The luma reseed gives the same future step decisions after one black
   frame (section 1), so no luma transition is lost. `osOffRed` (sections 3 to 5) only changes
   which colours reach the limiter; safety rests on the limiter reading the final bytes, NaN or
   not.

The claim is therefore about on-screen steps. A restarted auditor can count fewer charges in a
window after the restart than a never-restarted one, and every charge it drops is for a step more
than one second before that window.

## 7. Tests (implementation)

- Vectors (`limiter-vectors.mjs`, model, WebGL 2 and Metal):
  - `reset-short-black`, `reset-long-black`, `reset-black-at-expiry`, `black-start-red-10hz`
    (CORE-2869);
  - `black-start-sat-orange` (round 3 P1 #1, one black start, no later restart);
  - `black-start-faint-red` (round 3 P1 #2: (5, 0, 0), (110, 64, 0), (60, 0, 0));
  - `black-start-near-black-red` ((1, 0, 0) in place of (5, 0, 0)).
- `test-limiter.mjs`:
  - each vector audited end to end with `restart(seed)` at the reset;
  - the round 3 repros: output at most 1 red transition a second, and the auditor with and
    without the restart agrees on the input;
  - a black restart after 74, 75 and 90 frames of black (reseeded at 75 and 90, not at 74, and
    `lastRestart.ineligible` counts the 74-frame pixels);
  - a zero restart after 2 s of black reseeds nothing;
  - the Codex round 1 sequence (section 6): the restarted auditor counts the rise only, and the
    never-restarted one also charges the owed fall, the case section 6 accepts;
  - `blackLongEnough` on 75 intervals of 1000/60 ms accumulated from 1234 ms (true) and on 74
    (false);
  - (1, 0, 0) and (5, 0, 0) break the run;
  - the round 18 and 19 tests, unchanged.
- `test-originals-red.mjs`: the conservative byte checker at CI density with the round 1 repro
  as its positive control, the NaN and infinity cases, and the GLSL form and wiring.
