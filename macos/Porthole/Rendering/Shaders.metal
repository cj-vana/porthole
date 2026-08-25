#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

/// Fullscreen triangle from vertex id alone, so no vertex buffers needed.
vertex VertexOut testPatternVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    return out;
}

/// US-004 test pattern. Everything is derived from `time`, never from frame
/// count, so missed vsyncs are visible instead of merely slowing animation:
///   - top:    SMPTE-style 75% color bars with a sweeping luminance gradient
///   - middle: frame-pacing ticker with `frameRate` cells. At a steady rate
///     exactly one new cell lights per frame, one lap per second at any rate
///   - bottom: marker block traversing the width every 8 s
///   - a full-height marker line shares the block's position; stutter or
///     skipped ticker cells mean dropped frames.
fragment float4 testPatternFragment(VertexOut in [[stage_in]],
                                    constant float &time [[buffer(0)]],
                                    constant float2 &viewportSize [[buffer(1)]],
                                    constant float &frameRate [[buffer(2)]]) {
    float2 uv = in.uv;
    float3 color;

    // Shared time-derived marker position: one full traverse every 8 s.
    float markerX = fract(time / 8.0);

    if (uv.y > 0.28) {
        // SMPTE-style 75% color bars (gray, yellow, cyan, green, magenta, red, blue).
        const float3 bars[7] = {
            float3(0.75, 0.75, 0.75),
            float3(0.75, 0.75, 0.0),
            float3(0.0, 0.75, 0.75),
            float3(0.0, 0.75, 0.0),
            float3(0.75, 0.0, 0.75),
            float3(0.75, 0.0, 0.0),
            float3(0.0, 0.0, 0.75)
        };
        uint index = min(uint(uv.x * 7.0), 6u);
        color = bars[index];

        // Animated luminance sweep across the bars (one pass every 6 s).
        float sweep = 0.5 + 0.5 * sin((uv.x - fract(time / 6.0)) * 2.0 * M_PI_F);
        color *= 0.85 + 0.15 * sweep;

        // Full-height marker line.
        if (abs(uv.x - markerX) < 1.5 / viewportSize.x) {
            color = float3(1.0);
        }
    } else if (uv.y > 0.16) {
        // Frame-pacing ticker: one cell per frame at the selected rate; a
        // dropped frame leaves a visible gap.
        uint cells = max(uint(frameRate), 1u);
        uint cell = min(uint(uv.x * frameRate), cells - 1u);
        uint active = uint(floor(time * frameRate)) % cells;
        color = (cell == active) ? float3(1.0) : float3(0.12);
    } else {
        // Bottom strip: marker block on dark background.
        color = float3(0.05);
        if (abs(uv.x - markerX) < 8.0 / viewportSize.x) {
            color = float3(1.0, 0.85, 0.2);
        }
    }

    return float4(color, 1.0);
}
