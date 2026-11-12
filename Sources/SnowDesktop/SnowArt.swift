enum SnowArt {
    static let metalSource: String = #"""
#include <metal_stdlib>
using namespace metal;

// Buffer 0: one instance per flake or drift segment.
// Flake: shape = (clipX, clipY, radiusPx > 0, alpha), detail = (cos, sin, depth 0..1, 0)
// Drift: shape = (clipX center, clipY base, -halfWidthPx < 0, alpha), detail = (heightLeftPx, heightRightPx, softnessPx, 0)
struct SnowInstance {
    float4 shape;
    float4 detail;
};

constant float2 kSnowCorners[6] = {
    float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
    float2( 1.0, -1.0), float2( 1.0,  1.0), float2(-1.0,  1.0)
};

// 0 = distant rounded particle, 1 = branching crystal, 2 = drift segment
struct SnowVertexOut {
    float4 position [[position]];
    float2 local;
    float2 shadowOff [[flat]];
    float radius [[flat]];
    float alpha [[flat]];
    float4 params [[flat]];
    uint kind [[flat]];
};

static float snowSegDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
    return length(pa - ba * h);
}

// Signed distance (px) to a six-armed crystal. Folds into a 30° sector with
// abs() and one reflection, so the hexagonal symmetry costs no trigonometry.
static float snowCrystalDistance(float2 q, float R) {
    float2 a = abs(q);
    if (a.y > a.x * 0.57735027) {
        a = float2(dot(a, float2(0.5, 0.8660254)),
                   abs(dot(a, float2(-0.8660254, 0.5))));
    }

    float t = clamp(a.x / R, 0.0, 1.0);
    float halfArm = mix(max(0.13 * R, 0.9), max(0.035 * R, 0.35), t);
    float dArm = max(a.y - halfArm, a.x - R);

    float wb = max(0.07 * R, 0.4);
    float dB1 = snowSegDist(a, float2(0.40 * R, 0.0), float2(0.56 * R, 0.27 * R)) - wb;
    float dB2 = snowSegDist(a, float2(0.70 * R, 0.0), float2(0.82 * R, 0.20 * R)) - wb * 0.8;

    float dCore = length(a) - max(0.16 * R, 1.0);

    return min(min(dArm, dB1), min(dB2, dCore));
}

// Straight (non-premultiplied) alpha composite of a soft cool shadow under a body.
static float4 snowCompose(float body, float3 bodyCol,
                          float shadow, float shadowOpacity, float3 shadowCol,
                          float alpha)
{
    float aS = shadow * shadowOpacity * (1.0 - body);
    float aOut = body + aS;
    float3 col = (bodyCol * body + shadowCol * aS) / max(aOut, 1e-5);
    return float4(col, aOut * alpha);
}

static float4 snowDriftFragment(SnowVertexOut vin)
{
    float hw = vin.params.w;
    float u = clamp((vin.local.x + hw) / (2.0 * hw), 0.0, 1.0);
    float eased = u * u * (3.0 - 2.0 * u);
    float ramp = mix(u, eased, 0.5);
    float h = mix(vin.params.x, vin.params.y, ramp);
    float soft = vin.params.z;

    float cover = smoothstep(-0.5 * soft, 0.5 * soft, h - vin.local.y)
                * smoothstep(0.0, soft, h);

    float t = clamp(vin.local.y / max(h, 1.0), 0.0, 1.0);
    float3 base = float3(0.64, 0.77, 0.93);
    float3 top = float3(1.0, 1.0, 1.0);
    float3 col = mix(base, top, smoothstep(0.1, 0.85, t));

    return float4(col, cover * vin.alpha);
}

vertex SnowVertexOut snowVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device SnowInstance *instances [[buffer(0)]],
                                constant float2 &drawableSize [[buffer(1)]])
{
    SnowInstance inst = instances[iid];
    float2 corner = kSnowCorners[vid];
    float2 pxToClip = 2.0 / drawableSize;

    SnowVertexOut out;

    if (inst.shape.z < 0.0) {
        float hw = -inst.shape.z;
        float hL = max(inst.detail.x, 0.0);
        float hR = max(inst.detail.y, 0.0);
        float soft = max(inst.detail.z, 0.75);
        float top = max(hL, hR) + soft;

        float2 local = float2(corner.x * hw, (corner.y * 0.5 + 0.5) * top);

        out.position = float4(inst.shape.xy + local * pxToClip, 0.0, 1.0);
        out.local = local;
        out.shadowOff = float2(0.0);
        out.radius = hw;
        out.alpha = inst.shape.w;
        out.params = float4(hL, hR, soft, hw);
        out.kind = 2u;
    } else {
        float R = max(inst.shape.z, 0.5);
        float c = inst.detail.x;
        float s = inst.detail.y;
        float ext = R * 1.15 + 3.0;

        float2 local = corner * ext;
        out.position = float4(inst.shape.xy + local * pxToClip, 0.0, 1.0);

        // Inverse rotation into the crystal's own frame; linear, so it interpolates correctly.
        out.local = float2(c * local.x + s * local.y, -s * local.x + c * local.y);

        // Shadow falls down-right in world space, expressed in crystal frame.
        float2 shadowWorld = float2(0.7, -1.0);
        out.shadowOff = float2(c * shadowWorld.x + s * shadowWorld.y,
                               -s * shadowWorld.x + c * shadowWorld.y);

        out.radius = R;
        out.alpha = inst.shape.w;
        out.params = float4(0.0);
        out.kind = (inst.detail.z >= 0.45 && R >= 3.0) ? 1u : 0u;
    }

    return out;
}

fragment float4 snowFragment(SnowVertexOut vin [[stage_in]])
{
    if (vin.kind == 2u) {
        return snowDriftFragment(vin);
    }

    const float3 coolShadow = float3(0.56, 0.68, 0.86);
    float R = vin.radius;
    float2 q = vin.local;
    float2 qs = q - vin.shadowOff;

    float d;
    float dS;
    float shadowOpacity;

    if (vin.kind == 1u) {
        d = snowCrystalDistance(q, R);
        dS = snowCrystalDistance(qs, R);
        shadowOpacity = 0.30;
    } else {
        d = length(q) - R;
        dS = length(qs) - R;
        shadowOpacity = 0.22;
    }

    float body = 1.0 - smoothstep(-0.5, 0.5, d);
    float shadow = 1.0 - smoothstep(-1.0, 1.8, dS);
    float3 bodyCol = mix(float3(0.90, 0.95, 1.00), float3(1.0), smoothstep(-1.5, 0.0, d));

    return snowCompose(body, bodyCol, shadow, shadowOpacity, coolShadow, vin.alpha);
}
"""#
}
