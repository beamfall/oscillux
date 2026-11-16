<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Falling beams: a calm ambient light-shaft Visual

Tickets: OSC-0038

## Why

Hosts show low-interaction screens (sign-in, pairing, first-run setup) where a still backdrop
looks unfinished and an audio visual is too busy. The originals set has no light Visual that
reads as slow shafts of light: `volumetric-light` is a raymarched, audio-driven hall and costs
too much for a screen that sits behind a form. Such a screen also has one number worth showing,
how far along the user is, and no way to put it in the picture.

## What Changes

- Add the original Visual `falling-beams`: soft tilted shafts of light falling through dust
  and haze, in two dimensions with one nine-step loop.
- `param0` (Fill) sets how many shafts are lit and how warm they are. A host that wants the
  picture to follow progress maps its own 0..1 value onto this param.
- `param1` (Tilt) leans the shafts; `param2` (Dust) sets the motes.
- It joins the calm set: listed as `light` and `calm`, in the calm collection, with the calm
  beat-lint exemption. It moves on time alone, so it runs with no audio.

## Non-goals

- No new uniform and no change to the uniform packing schema.
- No host wiring. Which screen shows it, and what drives Fill, is the host's decision.
- No change to the post chain or the limiter.

## Failure modes

- Fill moved in steps by a host: each shaft fades in across one seventh of the range, so a
  stepped Fill shows a jump unless the host eases it. The host eases; the Visual does not hold
  state.
- No audio: `level` is 0, the breath term is 0, and the picture is driven by time only.
