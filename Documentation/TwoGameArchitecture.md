# RGB2GIF Two-Game Architecture

## The Core Insight

The 81×81×81 voxel cube factors into **two orthogonal 9×9 structures**:

```
SPATIAL FACTORIZATION                    TEMPORAL FACTORIZATION
════════════════════                    ═════════════════════

81×81 pixel frame                        81 frames
      │                                        │
      ▼                                        ▼
(9×9 tiles) × (9×9 pixels/tile)         (9×9 time-groups) × (1 frame/slot)
```

Each factorization maps naturally to a **9×9 GO board**. We play **two games**:

1. **Spatial Game**: Determines which *tiles* need accurate colors
2. **Temporal Game**: Determines which *time periods* need accurate colors

---

## The Lambda Merge

Both games produce 9×9 weight matrices. These combine via a lambda function:

```
weight(tile, time) = λ(spatial[tile], temporal[time])
```

### Merge Strategies

| Strategy | Formula | Effect |
|----------|---------|--------|
| **Multiply** | s × t | Both must agree (selective) |
| **Average** | (s + t) / 2 | Balanced blend (moderate) |
| **Maximum** | max(s, t) | Either can promote (inclusive) |
| **Minimum** | min(s, t) | Both must agree (strict) |
| **Geometric** | √(s × t) | Balanced contrast |

The **Geometric** merge is recommended as default—it provides contrast without being too extreme.

---

## Visual Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           RGB2GIF DUAL-GAME FLOW                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   CAMERA CAPTURE                                                            │
│   ═══════════════                                                           │
│   81 frames @ 81×81 pixels                                                  │
│         │                                                                   │
│         ▼                                                                   │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │                    81×81×81 VOXEL CUBE                          │       │
│   │                                                                 │       │
│   │   Each voxel = (x, y, frame) → RGB color                        │       │
│   │   Total: 531,441 voxels with potentially millions of colors     │       │
│   │                                                                 │       │
│   └───────────────────────────┬─────────────────────────────────────┘       │
│                               │                                             │
│                               ▼                                             │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │                      DUAL GAME SYSTEM                           │       │
│   │   ┌───────────────────┐       ┌───────────────────┐             │       │
│   │   │   SPATIAL GAME    │       │  TEMPORAL GAME    │             │       │
│   │   │                   │       │                   │             │       │
│   │   │   9×9 GO board    │       │   9×9 GO board    │             │       │
│   │   │   Each cell =     │       │   Each cell =     │             │       │
│   │   │   one 9×9 tile    │       │   9 frames        │             │       │
│   │   │                   │       │                   │             │       │
│   │   │   Black = crisp   │       │   Black = crisp   │             │       │
│   │   │   White = dither  │       │   White = dither  │             │       │
│   │   └─────────┬─────────┘       └─────────┬─────────┘             │       │
│   │             │                           │                       │       │
│   │             └─────────────┬─────────────┘                       │       │
│   │                           │                                     │       │
│   │                           ▼                                     │       │
│   │                   ┌───────────────┐                             │       │
│   │                   │ LAMBDA MERGE  │                             │       │
│   │                   │ λ(s, t)       │                             │       │
│   │                   │               │                             │       │
│   │                   │ 729 weights   │                             │       │
│   │                   │ (9×9×9)       │                             │       │
│   │                   └───────┬───────┘                             │       │
│   │                           │                                     │       │
│   └───────────────────────────┼─────────────────────────────────────┘       │
│                               │                                             │
│                               ▼                                             │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │               WEIGHTED PALETTE SELECTION                        │       │
│   │                                                                 │       │
│   │   1. Scan all voxels                                            │       │
│   │   2. Accumulate color weights: weight[color] += macro_weight    │       │
│   │   3. Sort by total weight                                       │       │
│   │   4. Select top 256 colors                                      │       │
│   │   5. Order by luminance                                         │       │
│   │                                                                 │       │
│   └───────────────────────────┬─────────────────────────────────────┘       │
│                               │                                             │
│                               ▼                                             │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │              ADAPTIVE DITHERING + INDEXING                      │       │
│   │                                                                 │       │
│   │   High-weight voxels → Direct mapping (crisp)                   │       │
│   │   Low-weight voxels  → Floyd-Steinberg dithering (approximate)  │       │
│   │                                                                 │       │
│   │   Output: 81 frames × 6561 indices = 531,441 palette indices    │       │
│   │                                                                 │       │
│   └───────────────────────────┬─────────────────────────────────────┘       │
│                               │                                             │
│                               ▼                                             │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │                      GIF89a OUTPUT                              │       │
│   │                                                                 │       │
│   │   Header (13 bytes) + Global Color Table (768 bytes)            │       │
│   │   + 81 LZW-compressed frames                                    │       │
│   │                                                                 │       │
│   │   ★ Palette swappable without re-encoding!                      │       │
│   │                                                                 │       │
│   └─────────────────────────────────────────────────────────────────┘       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## The 6D Cube Structure

The factored cube has **6 dimensions** organized hierarchically:

```
OUTER CUBE (9×9×9 = 729 macro-cells)
═══════════════════════════════════

Dimension          Range       Meaning
──────────────────────────────────────
tile_row           0-8         Spatial row (of tiles)
tile_col           0-8         Spatial column (of tiles)
time_group         0-8         Temporal group (9 frames each)


INNER CUBE (9×9×9 = 729 voxels per macro-cell)
══════════════════════════════════════════════

Dimension          Range       Meaning
──────────────────────────────────────
pixel_y            0-8         Y within tile
pixel_x            0-8         X within tile
frame_in_group     0-8         Frame within time group


ADDRESS FORMULA
═══════════════

voxel(x, y, frame) maps to:
  outer: (tile_row, tile_col, time_group) = (y/9, x/9, frame/9)
  inner: (pixel_y, pixel_x, frame_in_group) = (y%9, x%9, frame%9)
```

---

## KataGo Opening Book Integration

The opening books provide **pre-computed professional analysis**:

```
book9x9jp (Japanese rules)
═════════════════════════
- ~750MB of analyzed positions
- More territorial, defensive style
- Good for: Spatial game (stable regions)

book9x9tt (Tromp-Taylor rules)
══════════════════════════════
- ~800MB of analyzed positions
- More aggressive, fighting style
- Good for: Temporal game (dynamic moments)
```

### Position Format

```javascript
const board = [0,0,0,0,0,0,0,0,0,  // 81 values: 0=empty, 1=black, 2=white
               0,1,0,1,0,2,1,0,0,
               ...];

const moves = [
  {'xy':[[5,7]],'p':0.8507,'wl':-0.0029,'v':110209},  // Best move
  {'move':'other','p':0.1410,'wl':0.9765,'v':10019}   // Alternatives
];
```

### Using Two Different Rule Sets

```swift
// Spatial game: Japanese rules (territorial)
let spatialBook = KataGoOpeningBook.BookCollection(
    rootDirectory: URL(fileURLWithPath: "/path/to/book9x9jp"),
    ruleSet: "jp"
)
let spatialPosition = try spatialBook.loadPosition(hashID: "...")

// Temporal game: Tromp-Taylor rules (fighting)
let temporalBook = KataGoOpeningBook.BookCollection(
    rootDirectory: URL(fileURLWithPath: "/path/to/book9x9tt"),
    ruleSet: "tt"
)
let temporalPosition = try temporalBook.loadPosition(hashID: "...")

// Apply to dual weights
var weights = DualGameWeights(strategy: .geometric)
weights.applyFromOpeningBooks(
    spatialBoard: spatialPosition.flatBoard,
    temporalBoard: temporalPosition.flatBoard
)
```

---

## Why GO Provides Balance

GO's fundamental property: **territory is roughly equal** after a well-played game.

```
TYPICAL END POSITION
════════════════════

┌─────────────────┐
│ ●●●●●○○○○ │     Black: ~40 points
│ ●●●●○○○○○ │     White: ~40 points
│ ●●●○○○○○○ │     (balanced by komi)
│ ●●○○○○○○○ │
│ ●●○○   ○○○ │     This FORCES palette balance:
│ ●●○○   ○○○ │     - ~50% high-weight (Black territory)
│ ●●●○○○○○○ │     - ~50% low-weight (White territory)
│ ●●●●○○○○○ │
│ ●●●●●○○○○ │
└─────────────────┘
```

This prevents any single region from **dominating the palette**:
- A video with 90% sky won't use 90% of palette for blue
- The GO game FORCES attention to other regions
- Result: more balanced, interesting color distribution

---

## Adaptive Dithering Strategy

The weights determine dithering application:

```
DITHERING ZONES
═══════════════

Weight > 0.7:  CRISP ZONE
               Direct color mapping
               No error diffusion
               Highest color accuracy

Weight 0.3-0.7: BLEND ZONE
                Light dithering
                Some error diffusion
                Good balance

Weight < 0.3:  DITHER ZONE
               Full Floyd-Steinberg
               Heavy error diffusion
               Colors approximated
```

### Visual Example

```
INPUT IMAGE                    OUTPUT WITH ADAPTIVE DITHERING
════════════                   ═══════════════════════════════

┌───────────────┐              ┌───────────────┐
│ ████████████  │              │ ████████████  │  ← High weight:
│ ████████████  │              │ ████████████  │    Crisp colors
│ ████████████  │              │ ████████████  │
│               │              │               │
│ ░░░░░░░░░░░░  │              │ ▒▓▒▓▒▓▒▓▒▓▒▓  │  ← Low weight:
│ ░░░░░░░░░░░░  │              │ ▓▒▓▒▓▒▓▒▓▒▓▒  │    Dithered
│ ░░░░░░░░░░░░  │              │ ▒▓▒▓▒▓▒▓▒▓▒▓  │
└───────────────┘              └───────────────┘
```

---

## Lambda Compositionality

The lambda merge is the **unifying principle**:

```
COMPOSITIONAL HIERARCHY
═══════════════════════

Level 0: VOXEL
         λ₀(r, g, b) → palette_index
         Basic color mapping

Level 1: PIXEL
         λ₁(voxels across frames) → temporal coherence
         Same pixel across time

Level 2: TILE
         λ₂(pixels in tile) → spatial region weight
         9×9 pixel block

Level 3: MACRO-CELL
         λ₃(spatial_w, temporal_w) → combined importance
         The dual-game merge

Level 4: CUBE
         λ₄(all macro-cells) → global palette
         256-color selection
```

Each level composes the level below, enabling:
- **Modularity**: Change one lambda without affecting others
- **Experimentation**: Try different merge strategies
- **Learning**: Train transformer to predict optimal lambdas

---

## Future: Transformer-Learned Lambdas

The ultimate goal is to **learn personalized lambdas**:

```
TRAINING DATA
═════════════

For each GIF created:
  - Cube features (color histograms per macro-cell)
  - User's GO game moves (implicit preference signal)
  - Final palette choices
  - User feedback (if any)

TRANSFORMER INPUT
═════════════════

729 macro-cell embeddings:
  [histogram_256d, spatial_pos_9d, temporal_pos_9d, user_history_nd]

TRANSFORMER OUTPUT
══════════════════

729 weights (one per macro-cell)
  OR
256 palette colors directly

LOSS FUNCTION
═════════════

L = α * color_accuracy + β * user_preference + γ * balance_term
```

---

## File Structure

```
RGB2GIF/Sources/GO/
├── DualGameWeights.swift       # Weight merge logic
├── KataGoOpeningBook.swift     # Opening book parser
└── WeightedPaletteBuilder.swift # Palette allocation

RGB2GIF/Sources/GIF/
├── GIF81Writer.swift           # Hard-constrained writer
└── PaletteSwapper.swift        # 768-byte replacement

RGB2GIF/Sources/Transform/
├── SpatialIndexer.swift        # Luminance-ordered indexing
└── CenterCropper.swift         # Square crop preprocessing

RGB2GIF/Sources/Core/
├── GIF81Pipeline.swift         # Pipeline orchestrator
└── Voxel/
    └── VoxelGIF81Adapter.swift # 3D visualization bridge
```

---

## Summary

The two-game architecture answers a fundamental question:

> **How do we select 256 colors from potentially millions in a video?**

Answer: Let the user play GO against a neural network. The game provides:

1. **Balance** (roughly equal territory → balanced palette)
2. **Intentionality** (user choices reflect what they value)
3. **Training data** (moves become preference signals)
4. **Creativity** (different games → different aesthetics)

The palette becomes a **lens** for viewing the video, and the GO game becomes the **language** for specifying that lens.
