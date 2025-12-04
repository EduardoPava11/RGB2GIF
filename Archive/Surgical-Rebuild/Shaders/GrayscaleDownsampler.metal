//
//  GrayscaleDownsampler.metal
//  RGB2GIF
//
//  Metal compute kernels for downsampling NV12 Y-plane to 80×80 or 128×128
//  Uses bilinear filtering for high-quality grayscale downsample
//
//  Input: Y-plane texture (r8Unorm, full camera resolution)
//  Output: Downsampled grayscale texture (r8Unorm, 80×80 or 128×128)
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Bilinear Downsampler (High Quality)

/// Downsample Y-plane with bilinear filtering
/// Reference: Metal Shading Language Specification (texture sampling)
kernel void grayscaleDownsample(
    texture2d<float, access::sample> inputY [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Early exit if thread is out of bounds
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    // Calculate normalized coordinates in input texture
    // Sample from center of output pixel
    float2 inputSize = float2(inputY.get_width(), inputY.get_height());
    float2 outputSize = float2(output.get_width(), output.get_height());

    float2 scale = inputSize / outputSize;
    float2 uv = (float2(gid) + 0.5) * scale / inputSize;

    // Sample with bilinear filtering
    constexpr sampler s(coord::normalized,
                       address::clamp_to_edge,
                       filter::linear);

    float grayscale = inputY.sample(s, uv).r;

    // Write to output
    output.write(float4(grayscale, 0, 0, 0), gid);
}

// MARK: - Box Filter Downsampler (Fast)

/// Downsample Y-plane with box filter (simple averaging)
/// Faster than bilinear, but lower quality
kernel void grayscaleDownsampleFast(
    texture2d<float, access::read> inputY [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    // Calculate input region for this output pixel
    uint inputWidth = inputY.get_width();
    uint inputHeight = inputY.get_height();
    uint outputWidth = output.get_width();
    uint outputHeight = output.get_height();

    float scaleX = float(inputWidth) / float(outputWidth);
    float scaleY = float(inputHeight) / float(outputHeight);

    uint startX = uint(float(gid.x) * scaleX);
    uint startY = uint(float(gid.y) * scaleY);
    uint endX = uint(float(gid.x + 1) * scaleX);
    uint endY = uint(float(gid.y + 1) * scaleY);

    // Box filter: average all pixels in the region
    float sum = 0.0;
    uint count = 0;

    for (uint y = startY; y < endY && y < inputHeight; ++y) {
        for (uint x = startX; x < endX && x < inputWidth; ++x) {
            sum += inputY.read(uint2(x, y)).r;
            ++count;
        }
    }

    float grayscale = (count > 0) ? (sum / float(count)) : 0.0;
    output.write(float4(grayscale, 0, 0, 0), gid);
}

// MARK: - Lanczos Downsampler (Maximum Quality)

/// Lanczos kernel function (a = 3)
inline float lanczos3(float x) {
    if (x == 0.0) return 1.0;
    if (abs(x) >= 3.0) return 0.0;

    float pi_x = M_PI_F * x;
    return (3.0 * sin(pi_x) * sin(pi_x / 3.0)) / (pi_x * pi_x);
}

/// Downsample Y-plane with Lanczos-3 filter
/// Highest quality, but most expensive (use for offline processing)
kernel void grayscaleDownsampleLanczos(
    texture2d<float, access::read> inputY [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    uint inputWidth = inputY.get_width();
    uint inputHeight = inputY.get_height();
    uint outputWidth = output.get_width();
    uint outputHeight = output.get_height();

    float scaleX = float(inputWidth) / float(outputWidth);
    float scaleY = float(inputHeight) / float(outputHeight);

    // Center of output pixel in input space
    float centerX = (float(gid.x) + 0.5) * scaleX;
    float centerY = (float(gid.y) + 0.5) * scaleY;

    // Lanczos-3 kernel radius
    const int radius = 3;

    float sum = 0.0;
    float weightSum = 0.0;

    // Sample 6×6 region around center
    for (int dy = -radius; dy < radius; ++dy) {
        for (int dx = -radius; dx < radius; ++dx) {
            float sx = centerX + float(dx);
            float sy = centerY + float(dy);

            // Clamp to input bounds
            uint ix = clamp(uint(sx), 0u, inputWidth - 1);
            uint iy = clamp(uint(sy), 0u, inputHeight - 1);

            // Compute Lanczos weight
            float wx = lanczos3((sx - centerX) / scaleX);
            float wy = lanczos3((sy - centerY) / scaleY);
            float weight = wx * wy;

            sum += inputY.read(uint2(ix, iy)).r * weight;
            weightSum += weight;
        }
    }

    float grayscale = (weightSum > 0.0) ? (sum / weightSum) : 0.0;
    output.write(float4(grayscale, 0, 0, 0), gid);
}

// MARK: - LUT Application (Y → Palette Index)

/// Apply 256-byte LUT to convert Y to palette index
/// Input: Y-plane texture (r8Unorm, grayscale)
/// LUT: 256-byte buffer mapping Y → palette index
/// Output: Index texture (r8Unorm, palette indices)
kernel void applyLUT(
    texture2d<float, access::read> grayscale [[texture(0)]],
    texture2d<float, access::write> indices [[texture(1)]],
    constant uchar* lut [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= grayscale.get_width() || gid.y >= grayscale.get_height()) {
        return;
    }

    // Read grayscale value [0.0, 1.0]
    float y = grayscale.read(gid).r;

    // Convert to 8-bit integer [0, 255]
    uint yInt = uint(y * 255.0 + 0.5);

    // Lookup palette index
    uchar index = lut[yInt];

    // Write index as normalized float [0.0, 1.0]
    float normalizedIndex = float(index) / 255.0;
    indices.write(float4(normalizedIndex, 0, 0, 0), gid);
}

// MARK: - Combined Downsample + LUT Application

/// Downsample and apply LUT in one pass (optimized for real-time capture)
kernel void downsampleAndApplyLUT(
    texture2d<float, access::sample> inputY [[texture(0)]],
    texture2d<float, access::write> indices [[texture(1)]],
    constant uchar* lut [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= indices.get_width() || gid.y >= indices.get_height()) {
        return;
    }

    // Bilinear downsample
    float2 inputSize = float2(inputY.get_width(), inputY.get_height());
    float2 outputSize = float2(indices.get_width(), indices.get_height());
    float2 scale = inputSize / outputSize;
    float2 uv = (float2(gid) + 0.5) * scale / inputSize;

    constexpr sampler s(coord::normalized,
                       address::clamp_to_edge,
                       filter::linear);

    float y = inputY.sample(s, uv).r;

    // Apply LUT
    uint yInt = uint(y * 255.0 + 0.5);
    uchar index = lut[yInt];

    // Write index
    float normalizedIndex = float(index) / 255.0;
    indices.write(float4(normalizedIndex, 0, 0, 0), gid);
}
