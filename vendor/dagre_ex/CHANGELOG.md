# Changelog

## 0.1.0 (unreleased)

- First version: `Dagre.layout/1` — top-to-bottom layered layout with cycle breaking,
  longest-path ranking with tightening, dummy-node normalization with sized label dummies,
  median/transpose crossing reduction, Brandes–Köpf coordinate assignment, and self-loops.
- Edge `weight` (optional positive integer, default 1): a path of edges heavier than all their
  neighbours is laid out as one straight vertical line. Brandes–Köpf aligns a node only along a
  segment that is heaviest for both its ends, and a segment crossing a heavier one is a conflict;
  equal weights reproduce the unweighted layout.
- Node centres are rounded to integers before boxes are placed, so an odd-width node on a straight
  path no longer sits 1px off it.
- A node with a self-loop is aligned on its own box's centre; the loop's room extends to the right
  instead of pulling the box off its column.
