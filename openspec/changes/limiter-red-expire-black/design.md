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
// longestMs: the longest single interval credited during this hold.
hold until blackShownMs > COVERAGE_MS and the view shows a whole texel       // unchanged
seed = hostBlackLongEnough(blackShownMs, longestMs) ? 'black' : 'zero'
clear every tracker texel to seed (BLACK_TEXEL or ZERO_TEXEL); write G fully spent
[256, 65025, 65025, 0]; restart the clock; the output starts black
```

`hostBlackLongEnough(ms, longestMs)` is `blackLongEnough(ms - longestMs)`, also in
`limiter-model.mjs`. A host that seeds black holds until it is true: at 60 Hz, 76 credited frames
(1266.7 ms) where the auditor's threshold is 75.

Error bound: every credited interval is a span during which a black frame was on screen (the
canvas is cleared to black and stays black until the limiter's first frame replaces it), so the
credited time can lead the black time displayed by at most one frame, a frame that was credited
but presented a refresh late. That frame is one of the credited intervals, so it is no longer
than `longestMs` (on any display of 10 Hz or more, since each interval is capped at 100 ms). The
host subtracts `longestMs` before the shared comparison, so when it seeds black, the black has
been displayed for at least `RED_EXPIRE_MS` on the auditor's presented timeline, and the auditor
finds every pixel eligible (Agreement, below). The host gives up one frame of black for this.

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
  pending = seed               // 'black' or 'zero'
  lastRestart = { seed, reseeded: 0, kept: 0 }   // every restart replaces it at once
  // 'zero' reseeds nothing: the limiter's unknown red memory is conservative ("A host reset is
  // conservative"), so the auditor keeps every pixel's history

push(px, dt):
  clock += dt * 1000           // frame k is on screen from clock_k to clock_k+1
  for each pixel j:
    if pending == 'black' and blackLongEnough(clock - blackSince[j]):   // NaN compares false
      ext[luma][j] = ref[luma][j] = 0; dir[luma][j] = -1     // the black seed, as BLACK_TEXEL
      ext[red][j]  = ref[red][j]  = 0; dir[red][j]  = -1
      redCounted[j] = 1; anySat[j] = 0                       // nothing owed, no saturated state
      lastRestart.reseeded++
    else if pending != null:
      lastRestart.kept++       // history kept: every pixel at a zero restart; at a black
                               // restart, a host that broke "Black before the start"
    if px[j] is (0, 0, 0): blackSince[j] = isNaN(blackSince[j]) ? clock : blackSince[j]
    else: blackSince[j] = NaN
    ... track luma and red exactly as before ...
  pending = null
```

The reseed reads `blackSince` before the current frame updates it. Black on frames b..t-1 has been
on screen for clock_t - clock_b = (t - b) / 60 s at 60 Hz, so 75 frames give 1250 ms and 74 frames
give 1233 ms. Nothing else in the auditor expires. The playback expiry of the round 3 build
(`redExpireMs`, the per-pixel restart during `push`) is removed. `lastRestart` describes the
latest restart only: `restart` replaces it for either seed, and that restart's first frame fills
the counts. It lets a test assert that a host kept the contract (`kept` 0 at every black
restart). A pixel left out keeps its history, so the auditor still judges what the limiter then
admits.

The reseed overwrites all six fields with the seed, so the state equals `BLACK_TEXEL` as decoded.
A pixel already black for a frame or more may hold other fields (round 1: red ref 11 with ext 0
after a sub-step red fade). Section 6 does not rely on those fields matching the seed's; it rests
on when the forgotten steps were on screen.

### Agreement

The limiter's trackers make the auditor's decisions from a common state (frame-limiter
"Per-pixel transition trackers"). A host that keeps the contract seeds `BLACK_TEXEL` only when
`hostBlackLongEnough` holds, so the exact black has been displayed on every pixel for at least
1250 ms (error bound, above). At that restart the auditor therefore reseeds every pixel to the
same state, and the two agree again from the same frame. With a zero start the
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
    float s = c.g + c.b, t = 0.55 * c.r;        // the gate compares the summed partners
    if (s < t) c += vec3(0.0, 0.5 * (t - s), 0.5 * (t - s));  // with the product (round 3 P2)
    float m = max(c.r, max(c.g, c.b));
    if (m < OS_GREY_BELOW) return vec3(luma(c));  // three identical channels
    float p = max(c.g, c.b);
    if (c.r > p && m < OS_RED_FULL) {  // from OS_RED_FULL on, red is returned as it stands
        float w = clamp((m - OS_RED_FROM) / (OS_RED_FULL - OS_RED_FROM), 0.0, 1.0);
        c.r = w <= 0.0 ? p : p + w * (c.r - p);  // red equal to a partner below OS_RED_FROM
    }
    return c;
}
```

Below MF only red's excess over the larger partner is removed: a colour with red at or under it,
such as (0, 0.006, 0) or (0.004, 0.007, 0), passes unchanged. From M2 on red is not recomputed, so
a colour that already meets the share is returned bit for bit: (0.05, 0.014, 0.014) stays
(0.05, 0.014, 0.014) in float32, where `p + 1 * (r - p)` moved red by one ULP (round 2 P3).
The share rule is gated on the comparison of the rounded sum `g + b` with the rounded product
`0.55 * r`, not on the sign of a difference: `(0.55 * r - g) - b` is 2^-26 for
(0.75, f32(0.4125), 2^-26), where the two rounded values are equal, and raised blue by half
(round 3 P2). A colour whose float32 `g + b` is at least its float32 `0.55 * r` is therefore
never changed by the rule, and a compiler contracting `t - s` into a fused multiply-add can only
alter the amount added to a colour that is short of the share, not fire the rule on one that has
it.

Claim: for every finite input on every target, and for NaN and infinite inputs on a target whose
arithmetic honours IEEE special values (section 5), no pixel presented from `osOffRed`'s output on
the per-pixel present path is a `redSat` byte triple. Below the floor the claim is proved
(structural, below). Elsewhere it rests on 0 failures over the sampled coverage below, checked one
input at a time; there is no bound for colours between samples. The path is `suppressGreenCast`, the vivid
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
  - Rerun with the final form (red returned as it stands from M2): the grain-0 grid at dither 1,
    0.5 and 0; 100,000 random colours over [1e-4, 16] at grain 0 and the same dithers; at dither 1
    and 0.5 with 16 grain slices, 100,000 in [0.04, 0.08] at grain 0.1 and 0.25 and 100,000 in
    [0.005, 0.05] at grain 0.25; 0 failures. The change only removes a
    one-ULP move of red where the presented share is under 0.77, far from the 0.8 boundary.
  - Rerun again with the gated share rule (round 3): the same four sets, the random set over
    grain 0 drawn with the bound stated explicitly (MLO 1e-4, MHI 16; the round 2 rerun had
    left MHI at the sweep's default of 1); 0 failures.
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

The exact result is promised where the target's arithmetic honours IEEE NaN and infinity, which
WebGL 2 and GLSL ES 3.00 do not guarantee and Metal's default fast-math does not provide: a
compiler may fold `x != x` to false, or assume a clamp's input finite. There a NaN or infinite
input's result is unspecified, the visual-defaults requirement and the byte claim of section 3
promise nothing for it, and only the limiter's reading of the final 8-bit bytes holds. That is
the safety claim in any case; this section is quality only.

The shader test covers (0.1, NaN, 0), (NaN, 0, 0), (NaN, NaN, NaN), (+Inf, 0, 0), (0.1, -Inf, 0)
and (-1, 0, 0) in the emulation. It requires a finite result in [0, 16], no red-class bytes from
the checker, and for a NaN channel the result of the same colour with that channel at 0
((0.1, NaN, 0) gives (0.1, 0.0275, 0.0275)). It also checks that the GLSL selects with
`notEqual` before the clamp and the share rule, and does not call `sanitizeColor`.

## 6. WCAG 2.3.1 argument

**Metric.** The limiter's claim is stated in two measures:

- **Red:** the red-flash definition of WCAG 2.0 (2008) and of the WCAG 2.1 Recommendation as
  published on 5 June 2018. A state is saturated red when R / (R + G + B) >= 0.8 in linear
  light, and a red transition is a change of at least 20 in 320 * max(0, R - G - B) between
  adjacent peaks and valleys, to or from a saturated red. The auditor uses a step of 15 codes on
  a 255 scale, about 18.8 on WCAG's 320, so it counts every such transition (a superset).
- **Luma:** the general-flash definition, a relative luminance change of at least 0.1 where the
  darker state is under 0.8.

The claim: in the presented output, the pixel auditor counts at most 6 large-area luma
transitions (3 flashes) and at most 1 large-area red transition in every one-second window.

The later editions of WCAG 2.1 and WCAG 2.2 read red transitions by chromaticity instead: a CIE
1976 u'v' distance over 0.2 with one state saturated red. The claim does not cover that reading.
Full-screen (60, 0, 0) and (0, 60, 0) alternating every 100 ms differ by 11 red codes and a
sub-threshold luma step, so the auditor counts nothing, yet their u'v' distance is about 0.33.
This gap predates this change and is tracked separately as CORE-2935.

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
2. **The reseed drops only pairs that straddle the hold.** A red charge joins two things: a red
   step s, and a saturated state w that witnesses it (the state after s, a state shown since the
   step before s, or, for a step that did not count, the first saturated state after s and
   before the next step). Let pixel p show exact (0, 0, 0) from t0 until the restart at t1, with
   t1 - t0 >= 1250 ms of presented time. Exact black has red code 0 and is not saturated, so p
   has no step after t0 and before t1, and no witness from t0 to t1.
   - **Same steps.** From the first frame of exact black, the red tracker's range since its last
     step runs from 0 to under one step above it, in either direction (a wider range would have
     fired a step on that frame). From such a state, as from the black seed, no fall can fire and
     the first value a step above 0 fires a rise into the same state. So the reseeded and the
     never-restarted auditor find the same steps after t1.
   - **Two flags.** The reseed changes only whether the last step is still owed and whether a
     saturated state has shown since it. The owed step is at or before t0, and the saturated
     state behind the flag was shown before t0.
   - **Both sides.** Before t1 the two are one auditor. From t1 on, the reseeded auditor is the
     auditor of a black start, which the existing claim covers (spec: "Black before the
     start"): it charges every step after t1 that has a witness after t1.

   So every pair the never-restarted auditor charges after t1 and the reseeded one does not has
   one element at or before t0 and the other after t1:
   - a step at or before t0 whose witness is the first saturated state after t1 (Codex round 1:
     black, (110, 64, 0), 75 black frames, a restart, 100 black frames, (5, 0, 0), (128, 0, 0));
   - the first step after t1, when its only witness is a saturated state shown before t0 (Codex
     round 2: black, (5, 0, 0), 75 black frames, a black restart, black, (110, 64, 0)). If a
     witness follows that step after t1, the reseeded auditor charges the step there instead.
3. **No red transition under the metric is dropped.** Under the metric a red transition runs
   between adjacent peaks and valleys of 320 * max(0, R - G - B), to or from a saturated red: one
   of its two extremes is saturated. p's value is 0 from t0 to t1, the least it can take, so the
   hold lies in a valley. Every transition therefore lies wholly at or before t0, ending in the
   hold at the latest, or wholly after t1, starting in the hold at the earliest. The hold's state
   is exact black, not saturated, so a transition's saturated extreme is on the same side as its
   change. A straddling pair joins a step on one side with a saturated state on the other, which
   is not an extreme of the transition that holds the step: the pair is not a red transition.
   A reading that merges a faint peak such as (5, 0, 0) (red value 0.5) into the valley still
   takes the valley's extreme, black. Both auditors count every red transition at or before t0
   alike, and the reseeded auditor counts every red transition after t1 as any black-started
   auditor does, so it misses none. Changes on the two sides are at least 1250 ms apart, so no
   flash, a pair of opposing transitions within one second, straddles the hold. With the host's
   one-frame margin (section 1) the displayed hold is at least 1250 ms, and the 250 ms over one
   second is spare.
4. **Luma is untouched.** The luma reseed gives the same future step decisions after one black
   frame (section 1), so no luma transition is lost. `osOffRed` (sections 3 to 5) only changes
   which colours reach the limiter; safety rests on the limiter reading the final bytes, NaN or
   not.

The claim is therefore about red transitions as the metric defines them. A restarted auditor can
count fewer charges after the restart than a never-restarted one. Every charge it drops is for a
pair that straddles a hold of at least 1250 ms of exact black, which the metric does not count as
a red transition, and a step it charges later than the never-restarted auditor is still charged.

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
    `lastRestart.kept` counts the 74-frame pixels);
  - a zero restart after 2 s of black reseeds nothing, and after an eligible black restart it
    leaves `lastRestart` as `{ seed: 'zero', reseeded: 0, kept: N }`;
  - the Codex round 1 and round 2 sequences (section 6): in each, the restarted auditor drops
    the straddling pair and the never-restarted one charges it, the case section 6 accepts;
  - `blackLongEnough` on 75 intervals of 1000/60 ms accumulated from 1234 ms (true) and on 74
    (false); `hostBlackLongEnough` false at 75 credited intervals of 1000/60 ms and true at 76;
  - (1, 0, 0) and (5, 0, 0) break the run;
  - the round 18 and 19 tests, unchanged.
- `test-originals-red.mjs`: the conservative byte checker at CI density with the round 1 repro
  as its positive control, the NaN and infinity cases, (0.05, 0.014, 0.014) and
  (0.75, f32(0.4125), 2^-26) returned bit for bit
  in float32, and the GLSL form and wiring.
