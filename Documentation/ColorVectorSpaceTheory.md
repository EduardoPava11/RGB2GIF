# Color Vector Space Theory (732D Model)

## The 3-Adic Structure

Everything in RGB2GIF is built on **powers of 3**:

```
Level 0:  3⁰ = 1      (single voxel)
Level 1:  3² = 9      (tile row, tile col, time group, histogram bins)
Level 2:  3⁴ = 81     (frames, tiles, GO board positions)
Level 3:  3⁶ = 729    (macro-cells, CELL PRESENCE DIMENSIONS)
Level 4:  3⁸ = 6561   (pixels per frame)
Level 5:  3¹⁰= 59049  (max unique colors, total digest features)
```

---

## The Problem

We have:
- **81 × 81 = 6,561 pixels** per frame
- **81 frames**
- **531,441 total voxels** (6561 × 81)
- **Maximum 59,049 unique colors** (if every pixel is different)
- **Need exactly 256** for GIF palette

How do we choose which 256?

---

## The 729-Cell Cube

The video is organized as a **9 × 9 × 9 cube** of macro-cells:

```
THE CUBE STRUCTURE
══════════════════

            time_group (0-8)
               ↑
               │    ┌───┬───┬───┬───┬───┬───┬───┬───┬───┐
               │   ╱ 8 ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱   ╱│
              8│  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤ │
               │  │   │   │   │   │   │   │   │   │   │╱│
               │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤ │
               │  │   │   │   │   │   │   │   │   │   │╱│
               │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤ ╱
              0│  └───┴───┴───┴───┴───┴───┴───┴───┴───┘╱
               └─────────────────────────────────────→ tile_col (0-8)
              ╱ 0                                   8
             ╱
            ↓
         tile_row (0-8)


INDEXING:
  cell_index = time_group × 81 + tile_row × 9 + tile_col

  where:
    time_group ∈ [0, 8]  (which 9-frame chunk)
    tile_row ∈ [0, 8]    (which row of 9×9 tiles)
    tile_col ∈ [0, 8]    (which column of 9×9 tiles)


EACH CELL CONTAINS:
  9 frames × 9×9 pixels = 729 voxels

TOTAL VOXELS:
  729 cells × 729 voxels = 531,441 ✓
```

---

## The Color Vector (732 Dimensions)

For each unique color, we store a **732-dimensional vector**:

```
COLOR VECTOR (732D = 3 + 729)
═════════════════════════════

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   RGB COORDINATES (3D)                                          │
│   ════════════════════                                          │
│   (r, g, b) ∈ [0, 255]³                                         │
│                                                                 │
│   What color is it?                                             │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   CELL PRESENCE (729D)                                          │
│   ════════════════════                                          │
│                                                                 │
│   For each of 729 macro-cells:                                  │
│     cell_presence[i] = frequency of this color in cell i        │
│                                                                 │
│   Indexed as: cell = time_group × 81 + tile_row × 9 + tile_col  │
│                                                                 │
│   ┌─────────────────────────────────────────────────┐           │
│   │ p₀₀₀ │ p₀₀₁ │ ... │ p₀₈₈ │ p₁₀₀ │ ... │ p₈₈₈ │  ← 729 vals │
│   └─────────────────────────────────────────────────┘           │
│                                                                 │
│   This captures the JOINT distribution:                         │
│   • WHERE the color appears (which tiles)                       │
│   • WHEN the color appears (which time groups)                  │
│   • The CORRELATION (which tile at which time)                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Why 729D is Better Than 81+81

The old model (165D = 3 + 81 + 81) stored:
- `spatial_presence[81]`: presence per tile (summed over time)
- `temporal_presence[81]`: presence per frame (summed over tiles)

**What was lost:** The joint distribution.

```
EXAMPLE: Color C that appears in tile (4,4) during time_group 2

OLD MODEL (165D):
  spatial_presence[40] = high  (tile 4*9+4 = 40)
  temporal_presence[18-26] = high  (frames in time_group 2)

  But we LOSE the fact that it appears in THAT tile at THAT time.
  We can't distinguish:
    - C in tile (4,4) at time 2
    - C in tile (4,4) at time 5 AND in tile (0,0) at time 2

NEW MODEL (732D):
  cell_presence[2*81 + 4*9 + 4] = high  (cell 206)

  We KNOW exactly where and when.
  The joint distribution is preserved.
```

---

## The GO Games as Projections

Each GO game defines a **linear projection** from 729D to a scalar score:

```
SPATIAL GAME
════════════

Board: 9×9 = 81 tile positions
Produces: tile_weight[row][col]

To score a color:
  1. PROJECT cell_presence onto tiles (sum over time groups)
     tile_presence[r,c] = Σₜ cell_presence[t, r, c]

  2. DOT PRODUCT with tile weights
     spatial_score = Σ tile_weight[r,c] × tile_presence[r,c]

This answers: "How much does this color appear in the tiles the user cares about?"


TEMPORAL GAME
═════════════

Board: 9×9 = 81 frame positions (frame f → position f/9, f%9)
Produces: frame_weight[row][col]

To score a color:
  1. PROJECT cell_presence onto time groups (sum over tiles)
     time_group_presence[t] = Σᵣ,ᶜ cell_presence[t, r, c]

  2. EXPAND to frame presence (each time group → 9 frames)
     frame_presence[f] = time_group_presence[f/9] / 9

  3. DOT PRODUCT with frame weights
     temporal_score = Σ frame_weight[f] × frame_presence[f]

This answers: "How much does this color appear in the frames the user cares about?"
```

---

## The Selection Algorithm

```
PALETTE SELECTION (732D → 256 colors)
═════════════════════════════════════

Step 1: Build Color Vector Space
────────────────────────────────
  For each of 531,441 voxels:
    - Determine which cell (from tile + time group)
    - Increment cell_presence for that color

  Result: N unique ColorVectors (N ≤ 59,049)


Step 2: Play Spatial GO Game
────────────────────────────
  Human vs NN on 9×9 board
  Each position = one tile
  Result: 81 tile weights (Black=1, White=0, Empty=0.5)


Step 3: Play Temporal GO Game
─────────────────────────────
  Human vs NN on 9×9 board
  Each position = one frame (mapped)
  Result: 81 frame weights


Step 4: Select Dual Palettes
────────────────────────────
  Spatial palette:  top 256 colors by spatial_score
  Temporal palette: top 256 colors by temporal_score

  Each game gets FULL expressive power (256 colors each).


Step 5: Merge via CIEDE2000
───────────────────────────
  1. Find EXACT matches (both games picked same color)
     → High confidence, keep these

  2. Find SIMILAR colors (ΔE < 5.0)
     → Average their RGB values

  3. Fill remaining slots alternating between games

  4. Result: Final 256 colors


Step 6: Sort by Luminance
─────────────────────────
  For GIF composability (palette swaps)
```

---

## Memory Analysis

```
MEMORY USAGE
════════════

Per unique color:
  - RGB: 3 bytes
  - cellPresence: 729 × 4 bytes = 2,916 bytes
  - overhead: ~100 bytes
  Total: ~3,000 bytes per color

If N = 59,049 unique colors (maximum):
  3,000 × 59,049 ≈ 177 MB

Typical video (N ≈ 10,000 unique colors):
  3,000 × 10,000 ≈ 30 MB

This is manageable for modern devices.
```

---

## The Metric on Colors

Colors that are "close" in the 732D space:
1. Have similar RGB values
2. Appear in the SAME cells (spatial-temporal co-occurrence)

```
DISTANCE FORMULA
════════════════

d(a, b) = rgb_distance × context_factor

where:
  rgb_distance = √((rₐ-rᵦ)² + (gₐ-gᵦ)² + (bₐ-bᵦ)²) / √3

  context_factor = (2 - cell_similarity) / 2

  cell_similarity = cosine_similarity(cell_presence[a], cell_presence[b])

Colors that appear TOGETHER (same cells) are CLOSER.
Colors that appear SEPARATELY are FARTHER.
```

---

## Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   VIDEO (81 frames × 81×81 pixels)                                          │
│     │                                                                       │
│     ▼                                                                       │
│   729-CELL CUBE (9×9×9)                                                     │
│     │                                                                       │
│     ▼                                                                       │
│   COLOR VECTOR SPACE (N colors × 732D)                                      │
│     │                                                                       │
│     ├──────────────────────────┬────────────────────────────┐               │
│     │                          │                            │               │
│     ▼                          ▼                            ▼               │
│   PROJECT                   PROJECT                   (future: 729D        │
│   onto tiles                onto time                  cell weights)        │
│   (sum time)                (sum tiles)                                     │
│     │                          │                                            │
│     ▼                          ▼                                            │
│   SPATIAL GAME              TEMPORAL GAME                                   │
│   (81 weights)              (81 weights)                                    │
│     │                          │                                            │
│     ▼                          ▼                                            │
│   Top 256 colors            Top 256 colors                                  │
│     │                          │                                            │
│     └──────────┬───────────────┘                                            │
│                │                                                            │
│                ▼                                                            │
│            MERGE (CIEDE2000)                                                │
│                │                                                            │
│                ▼                                                            │
│           256 COLORS                                                        │
│                │                                                            │
│                ▼                                                            │
│        SORT BY LUMINANCE                                                    │
│                │                                                            │
│                ▼                                                            │
│           GIF PALETTE                                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

The 732D color vector space provides a mathematically grounded foundation for GO-based palette selection, preserving the full spatial-temporal structure of where and when each color appears.
