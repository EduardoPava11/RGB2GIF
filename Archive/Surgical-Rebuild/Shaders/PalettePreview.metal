//
//  PalettePreview.metal
//  RGB2GIF
//
//  Metal 4 compute kernel optimized for A19 Bionic (Apple10 GPU)
//  Target: iPhone 17 Pro with Neural Accelerators
//  Input: NV12 Y-plane (r8Unorm), 256×1 palette texture, 256-byte LUT
//  Output: RGBA8 texture
//
//  Optimization notes:
//  - A19 Bionic has 2x FP16 performance and Neural Accelerators per GPU core
//  - Optimal threadgroup size: 32×32 for maximizing cache coherency
//  - Uses texture reads (benefits from unified memory compression)
//

#include <metal_stdlib>
using namespace metal;

/// Palette skinning kernel: Y-plane → LUT → Palette → RGBA
///
/// @param yPlane NV12 Y-plane texture (r8Unorm, 0.0-1.0 normalized)
/// @param lut 256-byte lookup table mapping luma (0-255) to palette index
/// @param palette 256×1 RGB palette texture
/// @param output RGBA8 output texture
/// @param gid Thread position in grid (matches output dimensions)
kernel void palettePreview(
    texture2d<float, access::read> yPlane [[texture(0)]],
    device const uchar *lut [[buffer(0)]],
    texture1d<float, access::read> palette [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    // Bounds check
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    // Read Y-plane value (0.0-1.0) and convert to 0-255
    float yNormalized = yPlane.read(gid).r;
    uint yValue = uint(clamp(yNormalized * 255.0, 0.0, 255.0));

    // Look up palette index from LUT
    uint paletteIndex = uint(lut[yValue]);

    // Ensure palette index is valid (0-255)
    paletteIndex = min(paletteIndex, 255u);

    // Read RGB from palette
    float4 rgba = palette.read(paletteIndex);

    // Write to output (alpha = 1.0)
    rgba.a = 1.0;
    output.write(rgba, gid);
}

/// Alternative kernel with direct palette indexing (no LUT)
/// Useful for testing and simple grayscale mapping
kernel void palettePreviewDirectIndex(
    texture2d<float, access::read> yPlane [[texture(0)]],
    texture1d<float, access::read> palette [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    // Read Y-plane and use directly as palette index
    float yNormalized = yPlane.read(gid).r;
    uint paletteIndex = uint(clamp(yNormalized * 255.0, 0.0, 255.0));

    float4 rgba = palette.read(paletteIndex);
    rgba.a = 1.0;
    output.write(rgba, gid);
}
