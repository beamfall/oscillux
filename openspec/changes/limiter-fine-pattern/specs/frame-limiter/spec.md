## ADDED Requirements

### Requirement: Fine reversing patterns

The frame limiter SHALL limit reversing patterns finer than a sub-block, and changes over part
of each sub-block, as the pixel auditor counts them (per-pixel trackers: the
`limiter-pixel-trackers` change).

#### Scenario: Fine checkerboard

- **WHEN** a full-frame checkerboard of 4 px squares inverts between white and black at 10 Hz
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

#### Scenario: A change over part of each sub-block

- **WHEN** the top 2 of every 5 rows toggle between grey 124 and 153 at 10 Hz, so no sub-block's
  mean moves by a luma step
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

#### Scenario: Reference visuals

- **WHEN** the reference visuals render through the limiter under loud audio
- **THEN** none makes more than 6 large-area luma transitions in any 1 s window of the output

### Requirement: A paired luma grant spends two tokens

When luma up and luma down are both over the area limit and requested in one frame, the grant
SHALL admit them together only when the luma token has also stood unspent for one refill period,
and SHALL then leave two tokens of deficit, so no 1 s window holds more transitions than singles
allow.

#### Scenario: A full-frame flash before a fine pattern

- **WHEN** the frame steps from black to white and then a full-frame checkerboard of 4 px squares
  inverts at 10 Hz
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

#### Scenario: Full-frame flashes after a fine pattern

- **WHEN** a fine checkerboard inverts once after a quiet second and the frame then alternates
  full-frame black and white every 11 frames at 60 Hz
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output
