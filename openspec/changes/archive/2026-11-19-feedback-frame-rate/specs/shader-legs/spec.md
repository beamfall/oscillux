## ADDED Requirements

### Requirement: Feedback is frame-rate independent

A visual's feedback (the `feedbackTrail` helper and Ink) SHALL advance per second, not per drawn
frame: its decay, zoom, rotation, advection and injection authored per 60 Hz frame SHALL be scaled
by `n = dt * 60`, capped at 4, with one step when the host gives no frame clock. History sampled
outside the frame SHALL fade to zero within 1/32 of the frame instead of repeating the edge texel.

#### Scenario: Same trail at 30, 60 and 120 Hz

- **WHEN** a feedback visual runs at 120 Hz and at 60 Hz for one second
- **THEN** its trail has turned and zoomed by the same amount at both rates

#### Scenario: No streaks from the edge

- **WHEN** a feedback trail rotates so that history is sampled outside the frame
- **THEN** that history contributes nothing past 1/32 of the frame outside the edge

### Requirement: High-precision samplers in GLSL ES 3.00

The GLSL ES 3.00 visual, present and bloom passes SHALL declare `precision highp sampler2D`.

#### Scenario: HDR feedback is read at high precision

- **WHEN** a GLSL ES 3.00 leg's visual, present or bloom pass is generated
- **THEN** it declares `precision highp sampler2D`
