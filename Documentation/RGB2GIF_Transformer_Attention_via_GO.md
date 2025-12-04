# RGB2GIF: Transformer-Style Attention via a GO Game (Implementing on iOS/Core ML)

## Overview of the 729-Cell Q–K–V "Battle Arena"

RGB2GIF is an innovative architecture that turns a video (81 frames of 81×81 pixels) into a structured 9×9×9 grid of "macro-cells" (729 cells), and then uses a dual neural-network mechanism to select a color palette for a GIF. It is directly inspired by transformer attention mechanisms, but here the attention is computed through a simulated 9×9 GO game between two AI players (spatial vs. temporal) on those 729 cells. In essence, each macro-cell (a 9×9 tile region across 9 frames) plays the role of a token with its own Query, Key, and Value components. The classic attention formula is realized in this setup as follows:

- **Query (Q)**: comes from a Spatial KataGo network focusing on *where* (which tile) needs attention (analogous to asking "which image regions are important?"). This network outputs 81 tile weights, later expanded to 729 cells (repeating each tile's weight across 9 time slices).

- **Key (K)**: comes from a Temporal KataGo network focusing on *when* (which frame group) needs attention (analogous to asking "which time segments are important?"). It outputs 81 time-step weights, expanded to 729 cells (broadcasting each frame weight across 81 tiles).

- **Value (V)**: is the color content of each cell – specifically the centroid RGB color of the 9×9×9 voxel block corresponding to that cell. There are 729 such 3D color vectors (one per cell).

In a standard transformer, attention weights are computed by comparing Q and K (dot product), normalizing via softmax, and then weighting the V's accordingly. Here, because each cell has a unique Q and K, the architecture simplifies the interaction: it combines the spatial and temporal weights per cell (using a merge function λ, e.g. a geometric mean) to produce a single attention weight for that cell. This weight plays the same role as the usual softmax(Q·K^T/√d) score – effectively indicating how much that cell's color contributes to the final palette.

Each cell's centroid color (Value) is then weighted by this attention score. The outcome is a weighted frequency count of colors: we sum up contributions of each cell's color to derive a score for every unique color in the video. Finally, the top 256 colors by score form the GIF's palette, giving more importance to colors appearing in salient regions or moments (as determined by the "Q–K" game). This mirrors the transformer's output which is a weighted combination of values, but here the "output" is a ranked color palette rather than a sequence of embeddings.

**Why a GO game?** In transformers, Q, K, V are usually learned linear projections of the input features. In RGB2GIF, however, the attention weights are learned through gameplay – the two KataGo networks actively "compete" to claim territory on the 9×9 board (one controlling spatial tiles, the other temporal frames). The result of the game (which intersections are controlled by which player) directly translates into a distribution of attention over the 729 cells. This approach is novel: it replaces the black-box learned attention of transformers with an interpretable, rule-based mechanism (a board game) that still achieves the effect of highlighting important parts of the data. In other words, "Transformers learn attention weights from data (via backpropagation), whereas RGB2GIF derives attention from gameplay" – yet both answer the question "What should I pay attention to?" in processing the input.

---

## 3-Adic Data Structure (Powers of 3)

The design relies on a 3-adic hierarchical structure that neatly factorizes space and time dimensions of the video. Key levels include: 81 frames (3⁴) of size 81×81 pixels, grouped into 9 time groups of 9 frames; each frame is divided into a 9×9 grid of tiles (81 tiles), yielding 9×9×9 = 729 macro-cells in the 3D grid. Each macro-cell contains 9×9 pixels × 9 frames = 729 voxels. This structure means:

- **Spatial axis**: 9×9 tiles cover each frame (level 2 grid).
- **Temporal axis**: 9 frame-groups cover the sequence (each group is 9 consecutive frames).
- **Combined**: A cell is identified by (time_group, tile_row, tile_col) each from 0–8, mapping 1-to-1 with an intersection on the 9×9 GO board. The total voxels (531,441) factor as 729 cells × 729 voxels per cell, which is a 729×729 matrix – conceptually analogous to an attention matrix indexing cells vs. color-occurrences.

```
THE 3-ADIC STRUCTURE
════════════════════

Level    Power    Value      RGB2GIF Meaning
─────    ─────    ─────      ──────────────────
0        3⁰       1          Single voxel
1        3²       9          Grid dimension, frames per group
2        3⁴       81         Frames, pixels per axis, GO board size
3        3⁶       729        MACRO-CELLS (9×9×9) ← THE BATTLEFIELD
4        3⁸       6561       Pixels per frame (81×81)
5        3¹⁰      59049      Max unique colors

TOTAL VOXELS:
81 frames × 81 pixels × 81 pixels = 531,441 = 729 × 729
```

Within each cell, an RGB centroid is computed (the average color of its 729 voxels, possibly with Gaussian weighting toward the center of the cell for smoothness). This gives the 729 Value vectors (each 3-dimensional for RGB). Additionally, we can compute a 729-dimensional "presence" vector for each distinct color encountered: essentially a histogram over the 729 cells for that color (how frequently it appears in each cell). This high-dimensional encoding means a color isn't described just by separate spatial or temporal histograms, but by a joint spatiotemporal distribution across all 729 cells. It's far more informative than treating space and time separately. In short, each color is embedded in a 732-dimensional vector: 3 for its RGB values, and 729 for the distribution of that color across the video cube.

---

## Spatial and Temporal Attention via Two KataGo Networks (Q and K)

To generate the Query and Key vectors (attention weights) in an interpretable way, RGB2GIF uses two instances of KataGo, a strong Go-playing neural network (adapted to 9×9 boards). One network (SpatialPlayer) plays on a board where each intersection corresponds to a spatial tile of the frame, while the other (TemporalPlayer) plays on a board where intersections correspond to frame indices (or frame groups) in the video.

### Network Configuration

```
SPATIAL PLAYER (Query Provider)
═══════════════════════════════
Rule Set:     Japanese (jp)
Strategy:     Territorial, stable regions
Board Input:  9×9 tiles with color variance/entropy features
Output:       81 tile importance weights

TEMPORAL PLAYER (Key Provider)
══════════════════════════════
Rule Set:     Tromp-Taylor (tt)
Strategy:     Fighting, dynamic moments
Board Input:  9×9 frame groups with motion/change features
Output:       81 frame importance weights
```

These networks are pre-trained on Go, but here they are repurposed: instead of actual Go stone positions, the board input is constructed from video-derived features. For example, for the spatial game, one could encode each tile's "importance" (such as color variance, edge strength, or motion within that tile) as an initial configuration on the board. The SpatialPlayer then "plays" a game on this 9×9 board to produce a territory map: regions it claims as important vs. unimportant.

The output of KataGo's policy head gives a probability for each board intersection being the next move – effectively a weight for each tile. Similarly, the TemporalPlayer analyzes frame-related features on a 9×9 board to assign importance weights to each time step.

Mathematically, if `s[y,x]` is the SpatialPlayer's weight for tile at row y, col x, and `t[z]` is the TemporalPlayer's weight for frame-group z, then the cell at (z, y, x) receives an attention weight:

```
w[z,y,x] = λ( s[y,x], t[z] )
```

The function λ merges the two scores; the geometric mean is a natural choice:

```
λ(a,b) = √(a·b)
```

This rewards cells where both spatial and temporal attention are high (their product is high) while balancing influence (neither can dominate alone).

---

## Palette Construction and Balanced Attention

After obtaining the weight for each cell and its centroid color, the system aggregates these to score the actual colors. For each unique color present in the video frames, we compute:

```
score = Σ (w[cell] × presence[cell])
```

summing over all cells. A color earns a high score if it appears often in cells that the attention mechanism has marked as important. Finally, the top 256 scoring colors are chosen as the palette for the GIF.

### The Balancing Effect of GO

A remarkable benefit of using the GO-based dual attention is **balance**. In uncontrolled color selection, a video with a dominant region (say, 90% of pixels are blue sky) would allocate most of the palette to similar blues. Here, the Spatial and Temporal players inherently enforce a more even-handed allocation of attention.

In a game of Go on an empty board with perfect play, territory tends to be split roughly 50/50 between Black and White. This means one player will claim roughly half the board's cells as "important" and the other implicitly de-emphasizes those. By analogy, no single region or time can dominate all the attention – the GO players will ensure a balanced contest.

```
WITHOUT GO:                          WITH GO:
═══════════                          ════════

Video with 90% sky:                  GO forces contest:
→ 230/256 colors = blue shades      → Black claims some sky
→ Only 26 colors for everything else → White claims some ground
→ Poor detail in non-sky areas      → Balanced 50/50 attention
                                     → Better overall detail
```

The GO mechanism distributes the "attention budget" across the frame and time dimensions more uniformly, leading to more balanced and visually rich color palettes.

---

## iOS Implementation: Swift and Core ML Tools

Building this pipeline into an iOS app is feasible with Apple's Core ML framework and Swift. The major components to implement are:

1. **Preprocessing** the video into the required 81×81×81 tensor cube
2. **Running the two neural networks** to get spatial and temporal weights (Q and K)
3. **Combining results** to compute the palette and output the GIF

### Video Preprocessing

Using AVFoundation or UIKit, capture or load a video clip and downsample it to 81 frames of 81×81 pixels. Arrange the frames into a 3D array `[time=81][height=81][width=81][RGB=3]`. Then partition this into the 9×9×9 macro-cells. The centroid color of each cell can be computed in Swift using Accelerate vDSP functions. If Gaussian weighting is desired (σ=2.5 spatially, 2.0 temporally), precompute a 9×9×9 weight kernel and apply element-wise multiplication before summing.

### Machine Learning Models (KataGo networks for Q and K)

The KataGo neural network needs to be integrated via Core ML. KataGo's model can be converted from TensorFlow or PyTorch format using coremltools.

```swift
// Loading CoreML models
let config = MLModelConfiguration()
config.computeUnits = .all  // Auto-select ANE/GPU/CPU

let spatialModel = try KataGo9x9_Spatial(configuration: config)
let temporalModel = try KataGo9x9_Temporal(configuration: config)
```

### Input Format

KataGo's network expects:
- `input_spatial`: (batch, 22, 9, 9) - 22 board feature planes
- `input_global`: (batch, 19) - 19 global game state features

### Output Format

```
policy: (batch, 82) - Move probabilities (81 intersections + pass)
value: (batch, 3) - Win/loss/draw predictions
ownership: (batch, 1, 9, 9) - Territory prediction per intersection
```

### Combining Outputs (Attention Weighting)

```swift
// For each of 729 macro-cells (9×9×9):
for z in 0..<9 {  // time groups
    for y in 0..<9 {  // tile rows
        for x in 0..<9 {  // tile cols
            let spatialWeight = spatialPolicy[y * 9 + x]
            let temporalWeight = temporalPolicy[z]
            let cellWeight = sqrt(spatialWeight * temporalWeight)  // Geometric merge
            attentionWeights[z * 81 + y * 9 + x] = cellWeight
        }
    }
}
```

### Palette Extraction

Using the weight array and color-presence data, calculate scores for each color:

```swift
for color in uniqueColors {
    var score: Float = 0
    for cell in 0..<729 {
        score += attentionWeights[cell] * colorPresence[color][cell]
    }
    colorScores[color] = score
}

// Select top 256 colors by score
let palette = colorScores.sorted { $0.value > $1.value }.prefix(256)
```

---

## Multi-Head Attention Analogy and Future Extensions

The parallel to multi-head attention in transformers is notable. In transformers, multiple heads operate on the same input with different learned projections, capturing different aspects. In RGB2GIF, the spatial and temporal players act as **two attention heads**, each focusing on a different domain (space vs. time).

Instead of concatenating their outputs, this design merges them via the λ function (effectively an elementwise product). The result is akin to an AND of two attention maps: a cell is highlighted only if both the "where" head and the "when" head find it important.

### Possible Extensions

1. **Third "Color" Head**: A network that attends to certain color patterns
2. **Different λ merges**: Sum or max for different effects
3. **Multiple rule sets**: Experiment with Chinese rules, area scoring variations
4. **Learned λ**: Use a small network to learn the optimal merge strategy

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│                    RGB2GIF: TRANSFORMER ATTENTION VIA GO GAME                │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │                     81×81×81 VOXEL CUBE                             │   │
│   │                           │                                         │   │
│   │                           ▼                                         │   │
│   │                   9×9×9 = 729 CELLS                                 │   │
│   │                           │                                         │   │
│   │          ┌────────────────┼────────────────┐                        │   │
│   │          │                │                │                        │   │
│   │          ▼                ▼                ▼                        │   │
│   │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │   │
│   │   │   SPATIAL   │  │  TEMPORAL   │  │   VALUE     │                 │   │
│   │   │   PLAYER    │  │  PLAYER     │  │   TENSOR    │                 │   │
│   │   │   (KataGo)  │  │  (KataGo)   │  │             │                 │   │
│   │   │             │  │             │  │             │                 │   │
│   │   │  Japanese   │  │ Tromp-Taylor│  │  729 RGB    │                 │   │
│   │   │   Rules     │  │   Rules     │  │  centroids  │                 │   │
│   │   │             │  │             │  │             │                 │   │
│   │   └──────┬──────┘  └──────┬──────┘  └──────┬──────┘                 │   │
│   │          │                │                │                        │   │
│   │          ▼                ▼                ▼                        │   │
│   │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │   │
│   │   │     Q       │  │      K      │  │      V      │                 │   │
│   │   │   (Query)   │  │    (Key)    │  │   (Value)   │                 │   │
│   │   │  81 weights │  │  81 weights │  │  729 RGB    │                 │   │
│   │   └──────┬──────┘  └──────┬──────┘  └──────┬──────┘                 │   │
│   │          │                │                │                        │   │
│   │          └────────────────┼────────────────┘                        │   │
│   │                           │                                         │   │
│   │                           ▼                                         │   │
│   │             ┌─────────────────────────────┐                         │   │
│   │             │      ATTENTION FORMULA      │                         │   │
│   │             │                             │                         │   │
│   │             │   weight = √(Q × K)         │                         │   │
│   │             │   output = weight × V       │                         │   │
│   │             │                             │                         │   │
│   │             └─────────────┬───────────────┘                         │   │
│   │                           │                                         │   │
│   │                           ▼                                         │   │
│   │             ┌─────────────────────────────┐                         │   │
│   │             │                             │                         │   │
│   │             │   256-COLOR GIF PALETTE     │                         │   │
│   │             │                             │                         │   │
│   │             └─────────────────────────────┘                         │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## File Structure for Implementation

```
RGB2GIF/
├── Sources/
│   ├── KataGo/                         # Neural network integration
│   │   ├── KataGoInference.swift       # CoreML wrapper
│   │   ├── BoardEncoder.swift          # TensorCube → 9×9 board
│   │   ├── DualPlayerAttention.swift   # Q-K-V orchestration
│   │   ├── AttentionWeights.swift      # Weight data structure
│   │   └── DualGameWeights.swift       # Merge strategies (λ)
│   │
│   ├── Pipeline/
│   │   ├── GIF81Pipeline.swift         # Main pipeline with attention stage
│   │   ├── TensorCube729.swift         # 729 macro-cell tensor
│   │   ├── OctreeColorQuantizer.swift  # Attention-weighted quantization
│   │   └── WeightedPaletteBuilder.swift# Palette from attention weights
│   │
│   └── ...
│
├── Resources/
│   └── Models/
│       ├── KataGo9x9_Spatial.mlpackage   # Japanese rules (territorial)
│       ├── KataGo9x9_Temporal.mlpackage  # Tromp-Taylor rules (fighting)
│       ├── kata9x9-spatial-config.json   # Spatial model config
│       └── kata9x9-temporal-config.json  # Temporal model config
│
└── Scripts/
    └── KataGo/
        ├── download_katago_9x9.sh        # Download weights
        ├── convert_to_dual_coreml.py     # Create dual models
        └── verify_coreml_models.swift    # Test inference
```

---

## Summary

The RGB2GIF architecture demonstrates a creative fusion of:

1. **Transformer attention mechanisms** (Q-K-V formula)
2. **Game theory** (GO territorial competition)
3. **Deep learning** (KataGo neural networks)
4. **Mobile ML** (Core ML on iOS)

By leveraging KataGo – an existing, powerful AI – within Core ML, we get a smart "attention module" without having to train it on videos explicitly. This showcases how Core ML can integrate unconventional models into an app: not just classifiers or object detectors, but even a game-playing AI can become a subroutine in a video processing pipeline.

The GO mechanism provides:
- **Balance** (roughly equal territory → balanced palette)
- **Intentionality** (game positions reflect importance)
- **Interpretability** (stones on board show attention distribution)
- **Creativity** (different games → different aesthetics)

The palette becomes a **lens** for viewing the video, and the GO game becomes the **language** for specifying that lens.

---

## References

- [Attention Is All You Need (Vaswani et al., 2017)](https://papers.neurips.cc/paper/7181-attention-is-all-you-need.pdf)
- [KataGo GitHub](https://github.com/lightvector/KataGo)
- [KataGo Specialized 9x9 Network](https://github.com/lightvector/KataGo/releases/tag/v1.13.2-kata9x9)
- [Core ML Documentation](https://developer.apple.com/documentation/coreml)
- [coremltools Conversion Guide](https://apple.github.io/coremltools/docs-guides/)
