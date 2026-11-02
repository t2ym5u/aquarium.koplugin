# Changelog

All notable changes to this project will be documented in this file.

## [1.0.1] - 2026-11-02

### Fixed
- Hard puzzles needed one-step trial ("assume this level, see if it breaks"),
  which on paper plays as guessing. No level needs it any more: Hard now
  draws smaller tanks and hides more clues (about 5 of 16 at 8×8), and is
  always solvable by line reasoning alone. Medium hides fewer clues (2–3)
  so it stays between Easy and Hard.

## [1.0.0] - 2026-10-30

### Added
- First release: Aquarium puzzles in 6×6, 8×8 and 10×10, Easy / Medium /
  Hard.
- Generator with a built-in logic solver: every puzzle is proven to have a
  single solution, and its difficulty is the hardest reasoning step the
  solver needed (Easy: line bounds with every clue shown; Medium: exact line
  counting, some clues hidden; Hard: one-step trial, more clues hidden).
- Gravity-aware taps: a dry cell fills its tank up to that row, a wet cell
  drains it below that row. Long-press marks a cell as staying dry.
- Live clue feedback, Check, Hint (two taps), Reveal, Undo, timer, auto-save.
