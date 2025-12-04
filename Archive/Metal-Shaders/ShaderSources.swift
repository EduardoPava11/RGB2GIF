//
//  ShaderSources.swift
//  RGB2GIF
//
//  Embedded Metal shader sources compiled at runtime. This avoids
//  relying on the external `metal` command-line tool, which is not
//  available in some CI environments.
//

enum ShaderSources {
    /// Palette preview kernels (optimized + fallback) extracted from the
    /// original `PalettePreview.metal` and `PalettePreviewOptimized.metal`
    /// files. Both kernels are provided so runtime selection can prefer
    /// the optimized variant when supported.
    static let palettePreviewKernels: String = """
#include <metal_stdlib>
using namespace metal;

// MARK: - Optimized palette preview kernels (A19 tuned)

constant bool kUseThreadgroupCache [[function_constant(0)]];

kernel void palettePreviewOptimized(
    texture2d<float, access::read> yPlane       [[texture(0)]],
    device const uchar              *lut        [[buffer(0)]],
    texture1d<float, access::read>  palette     [[texture(1)]],
    texture2d<float, access::write> output      [[texture(2)]],
    threadgroup float4              tgPalette[256],
    uint2                           gid         [[thread_position_in_grid]],
    uint                            linearTid   [[thread_index_in_threadgroup]],
    uint2                           tgSize      [[threads_per_threadgroup]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    // Preload palette into shared threadgroup memory when enabled.
    if (kUseThreadgroupCache) {
        const uint threadsPerTG = tgSize.x * tgSize.y;
        for (uint i = linearTid; i < 256u; i += threadsPerTG) {
            float3 rgb = palette.read(i).rgb;
            tgPalette[i] = float4(rgb, 1.0);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    const float yNorm = yPlane.read(gid).r;
    const uint yValue = uint(clamp(yNorm * 255.0, 0.0, 255.0));
    const uint paletteIndex = uint(lut[yValue]);

    float4 color;
    if (kUseThreadgroupCache) {
        color = tgPalette[min(paletteIndex, 255u)];
    } else {
        color = float4(palette.read(min(paletteIndex, 255u)).rgb, 1.0);
    }

    output.write(color, gid);
}

kernel void palettePreviewOptimizedDirectIndex(
    texture2d<float, access::read> yPlane       [[texture(0)]],
    texture1d<float, access::read> palette      [[texture(1)]],
    texture2d<float, access::write> output      [[texture(2)]],
    threadgroup float4              tgPalette[256],
    uint2                           gid         [[thread_position_in_grid]],
    uint                            linearTid   [[thread_index_in_threadgroup]],
    uint2                           tgSize      [[threads_per_threadgroup]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    if (kUseThreadgroupCache) {
        const uint threadsPerTG = tgSize.x * tgSize.y;
        for (uint i = linearTid; i < 256u; i += threadsPerTG) {
            float3 rgb = palette.read(i).rgb;
            tgPalette[i] = float4(rgb, 1.0);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    const float yNorm = yPlane.read(gid).r;
    const uint paletteIndex = uint(clamp(yNorm * 255.0, 0.0, 255.0));

    float4 color;
    if (kUseThreadgroupCache) {
        color = tgPalette[min(paletteIndex, 255u)];
    } else {
        color = float4(palette.read(min(paletteIndex, 255u)).rgb, 1.0);
    }

    output.write(color, gid);
}

// MARK: - Fallback palette preview kernels

kernel void palettePreview(
    texture2d<float, access::read> yPlane       [[texture(0)]],
    device const uchar              *lut        [[buffer(0)]],
    texture1d<float, access::read>  palette     [[texture(1)]],
    texture2d<float, access::write> output      [[texture(2)]],
    uint2                           gid         [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const float yNorm = yPlane.read(gid).r;
    const uint yValue = uint(clamp(yNorm * 255.0, 0.0, 255.0));
    const uint paletteIndex = min(uint(lut[yValue]), 255u);

    float4 rgba = float4(palette.read(paletteIndex).rgb, 1.0);
    output.write(rgba, gid);
}

kernel void palettePreviewDirectIndex(
    texture2d<float, access::read> yPlane       [[texture(0)]],
    texture1d<float, access::read> palette      [[texture(1)]],
    texture2d<float, access::write> output      [[texture(2)]],
    uint2                           gid         [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const float yNorm = yPlane.read(gid).r;
    const uint paletteIndex = min(uint(clamp(yNorm * 255.0, 0.0, 255.0)), 255u);

    float4 rgba = float4(palette.read(paletteIndex).rgb, 1.0);
    output.write(rgba, gid);
}
"""
}
