# RGB2GIF Archive

This directory contains code preserved from the RGB2GIF project evolution.
These files are **NOT compiled** but are kept for future reference and re-integration.

## Project Evolution

```
MVP0 (Current) ─────────────────────────────────────────────────────────
│  Minimal 81×81×81 GIF camera app
│  - Camera preview with square frame guide
│  - Single capture button
│  - Direct pipeline: CGImage → OctreeQuantizer → LZW → GIF89a → Photos
│  - No settings, no modes, no themes
│
MVP1 (Future) ──────────────────────────────────────────────────────────
│  Dual Neural Network Games
│  - Spatial GO: Board positions as color palette choices
│  - Temporal GO: Frame sequences as game moves
│  - KataGo opening book integration
│  - Weighted palette building from game outcomes
│
MVP2 (Future) ──────────────────────────────────────────────────────────
│  Transformer Learning
│  - Record user editing sessions
│  - Learn preferences from corrections
│  - Auto-suggest palette improvements
│  - Federated learning across devices
```

## Archive Directory Contents

### MVP1-DualNN-GO/ (3 files)
Future feature: Dual neural network GO games for palette optimization.
- `DualGameWeights.swift` - Weight management for spatial/temporal GO
- `KataGoOpeningBook.swift` - Opening book integration
- `WeightedPaletteBuilder.swift` - Build palettes from game outcomes

### MVP2-Transformer/ (2 files)
Future feature: Transformer-based preference learning.
- `GameSessionRecorder.swift` - Record editing sessions
- `PreferenceTransformer.swift` - Learn from user corrections

### GIP-GIX-Pipeline/ (13 files)
The original intermediate format system (replaced by direct pipeline in MVP0).
- `GIP.swift` - GIF Interchange Palette format
- `GIX.swift` - GIF Interchange eXtended format
- `GIPGIXBridge.swift` - Bridge between formats
- `GIPGIXMerger.swift` - Merge multiple GIP/GIX streams
- And 9 more supporting files...

**Why archived:** MVP0 uses a direct CGImage→GIF pipeline without intermediate formats.
This system is needed for MVP1's advanced palette manipulation.

### Theme-System/ (7 files)
UI theming infrastructure for consistent look-and-feel.
- `ThemeManager.swift` - Central theme coordinator
- `UITheme.swift` - Theme definitions
- `GIPThemeableComponents.swift` - Themed UI components
- `CartridgeManager.swift` - Game cartridge system
- `AppLockManager.swift` - App locking features

**Why archived:** MVP0 uses standard UIKit for simplicity.

### UI-Gallery/ (6 files)
GIF browsing and management UI.
- `GIFGalleryView.swift` - Grid gallery view
- `GIFCatalogueView.swift` - Catalogue browser
- `GIFDetailView.swift` - Detail view with metadata
- `GIFCardListView.swift` - Card-based list
- `Palette3DView.swift` - 3D palette visualization
- `VoxelVisualizationViewController.swift` - Voxel renderer VC

**Why archived:** MVP0 just saves to Photos; no in-app gallery needed.

### Voxel-3D/ (6 files)
3D visualization of the 81×81×81 color cube.
- `VoxelCommon.swift` - Shared voxel types
- `VoxelCubeVisualizer.swift` - Interactive 3D cube
- `VoxelRenderer.swift` - Metal-based rendering
- `VoxelGIFProcessor.swift` - Process GIFs as voxel data
- And 2 more...

**Why archived:** Cool visualization but not essential for MVP0.

### Alternative-Algos/ (17 files)
Alternative approaches to color quantization and processing.
- `LumaQuantizer.swift` - Luma-based quantization
- `MetalYPlaneDownsampler.swift` - GPU-accelerated Y-plane extraction
- `PaletteShaderSystem.swift` - Shader-based palette application
- `ColorMerger.swift` - Color space merging
- `SpatialIndexer.swift` - Spatial color indexing
- And 12 more experimental approaches...

**Why archived:** MVP0 uses proven OctreeColorQuantizer; others are experimental.

### GIF-Advanced/ (10 files)
Advanced GIF processing beyond basic encode/decode.
- `GIF89aMuxer.swift` - Multi-stream GIF muxing
- `GIF89aValidator.swift` - GIF format validation
- `GIF89aDemuxer.swift` - Frame extraction
- `GIFStreamWriter.swift` - Streaming writer (has GIX dependencies)
- `GIF81Pipeline.swift` - Original 81×81×81 pipeline
- `PaletteSwapper.swift` - Runtime palette swapping

**Why archived:** SimpleGIF81Pipeline.swift replaces these with embedded minimal writer.

### Testing-Infra/ (5 files)
Test harnesses and validation tools.
- `MVP0TestLauncher.swift` - Auto-launch tests on app start
- `MVP0PipelineExecutor.swift` - Pipeline test execution
- `SyntheticFrameGenerator.swift` - Generate test frames
- `FrameValidator.swift` - Validate captured frames
- `ErrorRecovery.swift` - Error recovery strategies

**Why archived:** Tests should run separately, not in production app.

### Metal-Shaders/ (1 file)
GPU shader code for accelerated processing.
- `ShaderSources.swift` - Metal shader source strings

**Why archived:** MVP0 uses CPU-based processing for simplicity.

### Performance-Logging/ (5 files)
Performance monitoring and logging infrastructure.
- `PerformanceOptimizer.swift` - Auto-optimization
- `PerformanceTelemetry.swift` - Metrics collection
- `LoggingService.swift` - Centralized logging
- `LZWDecoder.swift` - LZW decoding (encode-only needed)
- `DataExtensions.swift` - Data type extensions

**Why archived:** MVP0 uses simple os.log; full telemetry not needed.

### Camera-Advanced/ (4 files)
Advanced camera capture pipelines.
- `CaptureToGIP2Pipeline.swift` - Full GIP/GIX pipeline
- `CaptureConfiguration.swift` - Complex capture configs
- `StructuredCapturePipeline.swift` - Structured capture
- `UnifiedCaptureController.swift` - Unified controller

**Why archived:** MVP0 uses simplified TemporalCubeCaptureManager.

---

## Re-integrating Archived Code

To bring back a feature:

1. Copy files from Archive/ to appropriate Sources/ location
2. Add to Xcode project (drag into navigator)
3. Ensure dependencies are also restored
4. Update any APIs that changed in MVP0

Example: To re-add the Theme System:
```bash
cp Archive/Theme-System/*.swift RGB2GIF/Sources/Core/Theme/
# Then add to Xcode project
```

---

## File Count Summary

| Category | Files | Purpose |
|----------|-------|---------|
| **Active MVP0** | **14** | Camera → GIF pipeline |
| Alternative-Algos | 17 | Experimental approaches |
| GIP-GIX-Pipeline | 13 | Intermediate formats |
| GIF-Advanced | 10 | Advanced GIF processing |
| Theme-System | 7 | UI theming |
| UI-Gallery | 6 | GIF browsing |
| Voxel-3D | 6 | 3D visualization |
| Testing-Infra | 5 | Test harnesses |
| Performance-Logging | 5 | Monitoring |
| Camera-Advanced | 4 | Complex capture |
| MVP1-DualNN-GO | 3 | Future: GO games |
| MVP2-Transformer | 2 | Future: Learning |
| Metal-Shaders | 1 | GPU shaders |
| **Total Archived** | **79** | Preserved for future |

---

## The Magic of 81

The number 81 is special:
- 81 = 3⁴ (power of 3)
- 81 frames × 81 pixels × 81 pixels = 531,441 voxels
- With 256 (2⁸) colors, creates a compact color cube
- GIF file size: ~50-200 KB per animation

This constraint enables efficient processing on mobile devices while
maintaining sufficient visual quality for social media sharing.

---

*Last updated: December 2024*
*MVP0 simplification completed*
