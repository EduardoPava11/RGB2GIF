# RGB2GIF Learning Architecture

## The Core Question

> **How does an app learn what a human values, using only their GO game moves?**

This document describes how RGB2GIF transforms implicit signals (GO moves) into explicit preferences (presets) using transformer-based learning.

---

## The Hierarchy of Choices

Human preferences exist at multiple levels of abstraction:

```
LEVEL 4: STYLE (highest abstraction)
═════════════════════════════════════
"I prefer vibrant, dynamic content"
"I like minimal, calm aesthetics"

    ▲ Emerges from patterns across many sessions
    │
LEVEL 3: CROSS-CELL RELATIONSHIPS
═════════════════════════════════════
"I value contrast between adjacent regions"
"I prefer coherent color zones"

    ▲ Learned from attention patterns
    │
LEVEL 2: MACRO-CELL IMPORTANCE
═════════════════════════════════════
"This tile matters more than that one"
"These frames are the key moments"

    ▲ Directly from GO moves
    │
LEVEL 1: TILE/FRAME PATTERNS
═════════════════════════════════════
"This tile has a face in it"
"This frame has motion blur"

    ▲ Computed from cube digest
    │
LEVEL 0: PIXEL COLORS (raw data)
═════════════════════════════════════
RGB values, luminance, saturation

    ▲ From camera capture
```

---

## The Implicit Signal: GO Moves as Preferences

Every move in the GO game is an implicit statement:

### Move Order = Priority

```
Move 1: "This is my HIGHEST priority"     → Weight 1.0
Move 5: "This is my FIFTH priority"       → Weight 0.85
Move 20: "This is a refinement"           → Weight 0.6
Move 40: "This is low priority"           → Weight 0.3
```

### Thinking Time = Certainty

```
Quick move (<2s):  "This is obvious to me"     → High confidence
Normal (2-10s):    "I'm considering options"   → Normal confidence
Slow move (>10s):  "This is uncertain"         → Low confidence
```

### Response to NN = Agreement/Disagreement

```
Accept NN suggestion: "I agree with the AI's assessment"
   → User values what NN detected (motion, contrast, etc.)

Reject NN suggestion: "I disagree, I want something else"
   → User has different priorities than NN detected

Play nearby: "I partially agree but want adjustment"
   → User agrees with region but not exact position
```

---

## Data Flow Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       RGB2GIF LEARNING PIPELINE                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   CAPTURE PHASE                                                             │
│   ═════════════                                                             │
│                                                                             │
│   Camera → 81 Frames → MacroCellDigest.compute()                            │
│                              │                                              │
│                              ▼                                              │
│                    ┌─────────────────────┐                                  │
│                    │  729 Cell Embeddings │                                  │
│                    │  (134 dimensions each)│                                  │
│                    └──────────┬──────────┘                                  │
│                               │                                              │
│   GAME PHASE                  │                                              │
│   ══════════                  ▼                                              │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │                    DUAL GO GAMES                                │       │
│   │                                                                 │       │
│   │   ┌─────────────────┐         ┌─────────────────┐               │       │
│   │   │  SPATIAL GAME   │         │  TEMPORAL GAME  │               │       │
│   │   │                 │         │                 │               │       │
│   │   │  Human: ●       │         │  Human: ●       │               │       │
│   │   │  NN:    ○       │         │  NN:    ○       │               │       │
│   │   │                 │         │                 │               │       │
│   │   │  "Which tiles?" │         │  "Which frames?"│               │       │
│   │   └────────┬────────┘         └────────┬────────┘               │       │
│   │            │                           │                         │       │
│   │            │   GameSessionRecorder     │                         │       │
│   │            │   records every move      │                         │       │
│   │            └─────────────┬─────────────┘                         │       │
│   │                          │                                       │       │
│   └──────────────────────────┼───────────────────────────────────────┘       │
│                              │                                              │
│                              ▼                                              │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │                    TRAINING DATA                                │       │
│   │                                                                 │       │
│   │   {                                                             │       │
│   │     sessionID: UUID,                                            │       │
│   │     cubeFeatures: [729 × 134],     // What the video looks like │       │
│   │     spatialMoves: [(player, pos, time, ...)],                   │       │
│   │     temporalMoves: [(player, pos, time, ...)],                  │       │
│   │     finalWeights: [729],            // Merged weights           │       │
│   │     finalPalette: [256 × 3],        // Resulting colors         │       │
│   │     userRating: 1-5,                // Optional feedback        │       │
│   │   }                                                             │       │
│   │                                                                 │       │
│   └──────────────────────────┬───────────────────────────────────────┘       │
│                              │                                              │
│   LEARNING PHASE             │                                              │
│   ══════════════             ▼                                              │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │                  PREFERENCE TRANSFORMER                         │       │
│   │                                                                 │       │
│   │   ENCODER                                                       │       │
│   │   ────────                                                      │       │
│   │   Input: 729 cell embeddings                                    │       │
│   │   + 3D positional encoding (row, col, time)                     │       │
│   │   → Self-attention (cells attend to each other)                 │       │
│   │   → Contextual cell representations                             │       │
│   │                                                                 │       │
│   │   DECODER                                                       │       │
│   │   ────────                                                      │       │
│   │   Input: Encoder output + move history                          │       │
│   │   → Cross-attention to encoder                                  │       │
│   │   → Multiple output heads:                                      │       │
│   │                                                                 │       │
│   │     ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────┐ │       │
│   │     │  MOVE HEAD  │ │ WEIGHT HEAD │ │PALETTE HEAD │ │  STYLE  │ │       │
│   │     │             │ │             │ │             │ │  HEAD   │ │       │
│   │     │ Predict     │ │ Predict     │ │ Predict     │ │         │ │       │
│   │     │ next move   │ │ 729 weights │ │ 256 colors  │ │ 64D     │ │       │
│   │     │ (for NN)    │ │ (auto-play) │ │ (direct)    │ │ embed   │ │       │
│   │     └─────────────┘ └─────────────┘ └─────────────┘ └─────────┘ │       │
│   │                                                                 │       │
│   └──────────────────────────┬───────────────────────────────────────┘       │
│                              │                                              │
│   INFERENCE PHASE            │                                              │
│   ═══════════════            ▼                                              │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────┐       │
│   │                    PRESET GENERATION                            │       │
│   │                                                                 │       │
│   │   Many sessions → Style embedding → Preset                      │       │
│   │                                                                 │       │
│   │   Preset can be applied to NEW videos:                          │       │
│   │     - No game required                                          │       │
│   │     - Instant style application                                 │       │
│   │     - Shareable between users                                   │       │
│   │                                                                 │       │
│   └─────────────────────────────────────────────────────────────────┘       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## The Macro-Cell Digest

Each of the 729 macro-cells is represented by a **134-dimensional embedding**:

### Color Features (96D)

```
Luminance Histogram [32 bins]:
  ░░░▓▓▓▓▓███████▓▓▓▓░░░░░░░░░░░░░
  └─────────────────────────────────┘
  How brightness is distributed in this cell

Hue Histogram [32 bins]:
  For saturated pixels only - what colors appear

Saturation Histogram [32 bins]:
  How vivid vs muted the colors are
```

### Temporal Features (16D)

```
Frame-to-Frame Change [9 values]:
  f0→f1  f1→f2  f2→f3  f3→f4  f4→f5  f5→f6  f6→f7  f7→f8
  0.02   0.03   0.15   0.82   0.91   0.12   0.04   0.03
         ▲            ▲      ▲
         │            └──────┴── Motion detected in frames 3-5

Motion Direction [7 values]:
  Histogram of motion vectors (up, down, left, right, + magnitudes)
```

### Spatial Features (16D)

```
Edge Density [4 values]:    Horizontal, vertical, 2 diagonals
Texture Entropy [1 value]:  How random/patterned the texture is
Gradient Direction [1]:     Dominant edge angle
Contrast [1]:               Max - Min luminance
```

### Position Features (6D)

```
Normalized Position:     (row/8, col/8, time/8)
Center Distance:         How far from spatial center
Temporal Distance:       How far from middle frame
Region Type:             Corner (0), Edge (0.5), Center (1)
```

---

## Higher-Order Features

Patterns that emerge across **multiple sessions**:

### Contrast vs Harmony

```
Does the user prefer high-contrast adjacent cells?
  - Playing Black stones around bright regions
  - Playing White stones around dark regions
  → High contrast preference

Or similar adjacent cells?
  - Clustering stones in one color zone
  → High harmony preference
```

### Spatial Focus

```
Center vs Edge preference:
  ┌───────────────────┐
  │ ○ ○ ○ ○ ○ ○ ○ ○ ○ │  Edge-focused user
  │ ○             ○ │
  │ ○             ○ │
  │ ○             ○ │
  │ ○             ○ │
  │ ○             ○ │
  │ ○             ○ │
  │ ○             ○ │
  │ ○ ○ ○ ○ ○ ○ ○ ○ ○ │
  └───────────────────┘

  ┌───────────────────┐
  │                   │  Center-focused user
  │     ● ● ● ●     │
  │     ● ● ● ●     │
  │     ● ● ● ●     │
  │     ● ● ● ●     │
  │                   │
  │                   │
  └───────────────────┘
```

### Temporal Focus

```
Does the user value:
  - Beginning of clip (establishing shot)
  - Middle of clip (action)
  - End of clip (resolution)
  - Uniform across time

This emerges from temporal game move patterns
```

### Color Temperature

```
Does the user's Black territory correlate with:
  - Warm tones (red/orange/yellow) → Warm preference
  - Cool tones (blue/green/purple) → Cool preference
  - Neutral → No temperature preference
```

---

## Training Objectives

The transformer learns from multiple loss functions:

### Move Prediction Loss (L_move)

```
"Given the cube and moves so far, predict the next human move"

Loss = CrossEntropy(predicted_logits, actual_move)

This teaches the NN to play like the human,
which means it learned what the human values.
```

### Weight Prediction Loss (L_weight)

```
"Predict the final 729 weights from cube features alone"

Loss = MSE(predicted_weights, actual_weights)

This enables auto-play mode (no game required).
```

### Palette Prediction Loss (L_palette)

```
"Predict the 256 colors that will result"

Loss = Σ ColorDistance(predicted[i], actual[i])

Using CIEDE2000 perceptual distance.
```

### Style Contrastive Loss (L_style)

```
"Similar users should have similar style embeddings"

Positive pairs: Different videos, same user
Negative pairs: Same video, different users

Loss = ContrastiveLoss(style_embeddings)

This learns a latent "user preference space".
```

### Total Loss

```
L_total = α·L_move + β·L_weight + γ·L_palette + δ·L_style

Recommended weights:
  α = 1.0  (move prediction is primary)
  β = 0.5  (weight prediction is secondary)
  γ = 0.3  (palette is end-to-end refinement)
  δ = 0.2  (style is regularization)
```

---

## Preset Generation

After training on many sessions, presets can be extracted:

### From Individual User

```swift
// Load all sessions for this user
let sessions = recorder.loadSessions()

// Extract style embedding
let style = PreferenceTransformer.extractStyleEmbedding(from: sessions)

// Generate preset
let preset = PreferenceTransformer.generatePreset(
    from: sessions,
    name: "My Style",
    description: "Vibrant colors with center focus"
)
```

### From Similar Users (Clustering)

```
All users' style embeddings
         │
         ▼
    ┌─────────┐
    │ K-Means │
    │Clustering│
    └────┬────┘
         │
         ▼
┌────────┴────────┬────────────────┐
│                 │                │
▼                 ▼                ▼
Cluster 1         Cluster 2        Cluster 3
"Minimalist"      "Vibrant"        "Cinematic"

Each cluster centroid becomes a shareable preset.
```

### Preset Application

```swift
// Apply preset to new video (no game required)
let weights = PreferenceTransformer.applyPreset(
    preset,
    to: newVideoDigest
)

// Use weights for palette building
let palette = WeightedPaletteBuilder.buildPalette(
    from: frames,
    weights: DualGameWeights(fromPredicted: weights)
)
```

---

## The Feedback Loop

Over time, the system improves through a virtuous cycle:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   User plays game    User rates result    System improves       │
│         │                  │                    │               │
│         ▼                  ▼                    ▼               │
│   ┌──────────┐       ┌──────────┐        ┌──────────┐          │
│   │  Moves   │──────▶│ Training │───────▶│  Better  │          │
│   │ recorded │       │   Data   │        │    NN    │          │
│   └──────────┘       └──────────┘        └────┬─────┘          │
│         ▲                                     │                │
│         │                                     ▼                │
│         │                              ┌──────────┐            │
│         └──────────────────────────────│  Better  │            │
│                                        │ Presets  │            │
│              User gets better          └──────────┘            │
│              recommendations                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Privacy Considerations

All learning happens **on-device by default**:

```
STORED LOCALLY:
  ✓ Cube features (derived, not raw pixels)
  ✓ Move histories
  ✓ Style embeddings
  ✓ Presets

NOT STORED:
  ✗ Raw video frames
  ✗ Personal information
  ✗ Location data

OPTIONAL CLOUD SYNC:
  - Encrypted style embeddings only
  - For cross-device preset sync
  - Opt-in only
```

---

## Future Extensions

### 1. Attention Visualization

Show the user what the model is "looking at":

```
"The model thinks you value this region because:
 - High motion (0.82 activity)
 - Warm colors in an otherwise cool video
 - You've focused on similar regions in 7 previous sessions"
```

### 2. Collaborative Filtering

"Users with similar styles to you liked these presets..."

### 3. Style Transfer

Apply one user's style to another's video.

### 4. Temporal Consistency

Use the style embedding to maintain consistency across a sequence of GIFs.

### 5. Multi-Modal Learning

Incorporate:
- Audio features (if video has sound)
- Text descriptions (user tags)
- Social signals (likes, shares)

---

## Summary

The RGB2GIF learning architecture transforms **implicit GO moves** into **explicit user preferences** through:

1. **MacroCellDigest**: Compress 81 frames into 729 rich embeddings
2. **GameSessionRecorder**: Capture every move with full context
3. **PreferenceTransformer**: Learn patterns across sessions
4. **HigherOrderFeatures**: Extract abstract preferences
5. **Preset Generation**: Convert learned preferences into reusable styles

The result: An app that **gets better at understanding you** every time you play.
