# Changelog

All notable changes to this project will be documented in this file.

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
