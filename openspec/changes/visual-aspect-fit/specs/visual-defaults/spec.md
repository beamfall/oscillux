## ADDED Requirements

### Requirement: Visuals fit the frame's aspect

Each visual in the reference set SHALL keep its main subject in frame and its repeated detail
(bars, columns, lines) at least about 4 px wide at any frame aspect from a portrait phone
(9:19.5) to ultrawide (21:9). The `centered()` and `motionCentered()` coordinate helpers SHALL
lean toward the frame's short side. Bar visuals SHALL choose their column count from the
frame aspect with `fitColumns`. At aspect 16:9 and wider a visual's output SHALL be unchanged by this fit.

#### Scenario: A phone held upright

- **WHEN** a centered visual renders at 390 x 844
- **THEN** coordinates scale by aspect^-0.7, so a subject authored within radius 0.8 fits the
  frame's width

#### Scenario: Bars on a narrow frame

- **WHEN** Spectrum renders at 390 x 844
- **THEN** it draws fewer, wider columns than at 16:9, each at least 4 px wide

#### Scenario: Landscape unchanged

- **WHEN** a visual renders at 480 x 270
- **THEN** its frame matches the frame before the change to within 1/255
