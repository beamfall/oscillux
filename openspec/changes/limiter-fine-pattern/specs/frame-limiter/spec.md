## ADDED Requirements

### Requirement: Fine reversing patterns

The frame limiter SHALL count, per sub-block, the pixels whose luma code rose by the luma step
against the previous output and those whose luma code fell by it, the darker side below the dark
threshold. When at least 7/16 of a sub-block's pixels rose and at least 7/16 fell, the sub-block
SHALL request a luma transition in each direction.

#### Scenario: Fine checkerboard

- **WHEN** a full-frame checkerboard of 4 px squares inverts between white and black at 10 Hz
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output

#### Scenario: Moving texture

- **WHEN** the reference visuals render under loud audio
- **THEN** their mean held fraction of sub-blocks stays within 0.001 of the value before the change

### Requirement: A paired luma grant spends two tokens

When luma up and luma down are both over the area limit and requested in one frame, the grant
SHALL admit them together only when the luma token has also stood unspent for one refill period,
so the pair falls where two single grants could have.

#### Scenario: A full-frame flash before a fine pattern

- **WHEN** the frame steps from black to white and then a full-frame checkerboard of 4 px squares
  inverts at 10 Hz
- **THEN** the pixel auditor counts at most 6 large-area luma transitions in every 1 s window of
  the output
