#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// ANIMATED CHAT WALLPAPERS (owner 2026-11-06). Three moving grounds, drawn entirely here, no image or
// video files: Liquid Metal (dark liquid with silver bodies and cyan edges), Water (light bands
// rippling across a surface) and Aurora (curtains of light over a night sky, three palettes).
//
// ⛔ THE MOTION IS A CIRCLE, SO THE LOOP HAS NO SEAM. Every moving offset is cos/sin of `phase`
// (0…2π, one full turn per loop) times a radius, so the last frame of a loop IS the first frame of
// the next. A clock fed in raw seconds would also lose float precision after a few hours.
//
// Run by SwiftUI as a colorEffect on a view a third of the screen's size and scaled up (the looks
// are soft, so the lower resolution does not show), at most 30 frames a second, and not at all
// while the chat is hidden or motion is off (`AnimatedWallpaperView`).

// ── noise ─────────────────────────────────────────────────────────────────────────────────────────

inline float awHash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

/// Smooth value noise, 0…1.
inline float awNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = awHash(i);
    float b = awHash(i + float2(1.0, 0.0));
    float c = awHash(i + float2(0.0, 1.0));
    float d = awHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Four octaves, 0…1. Rotated between octaves so no grid shows.
inline float awFbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    const float2x2 rot = float2x2(0.8, -0.6, 0.6, 0.8);
    for (int i = 0; i < 4; i++) {
        v += amp * awNoise(p);
        p = rot * p * 2.03 + float2(17.1, 9.7);
        amp *= 0.5;
    }
    return v;
}

inline float2 awCircle(float phase, float r) { return float2(cos(phase), sin(phase)) * r; }

// ── Liquid Metal ──────────────────────────────────────────────────────────────────────────────────
// Domain-warped noise. Where the field is high there is a liquid body (silver in dark, blue-grey in
// light); a thin cyan line rides the body's edge; the rest is the deep ground.

[[ stitchable ]] half4 fariinLiquidMetal(float2 position, half4 color, float2 size, float phase, float dark) {
    float2 uv = position / max(size.y, 1.0) * 1.7;
    float2 m1 = awCircle(phase, 0.55);
    float2 m2 = awCircle(phase + 2.1, 0.45);
    float2 q = float2(awFbm(uv + m1), awFbm(uv + float2(5.2, 1.3) - m2));
    float2 r = float2(awFbm(uv + 2.0 * q + float2(1.7, 9.2) + m2 * 0.6),
                      awFbm(uv + 2.0 * q + float2(8.3, 2.8) - m1 * 0.6));
    float f = awFbm(uv + 2.2 * r);

    float body = smoothstep(0.52, 0.78, f);
    float glow = smoothstep(0.40, 0.80, f) * 0.35;
    // x*x, not pow(x, 2.0): pow is undefined for a negative base in Metal (half the edge).
    float e = (f - 0.53) / 0.016;
    float edge = exp(-e * e);

    float3 rgb;
    if (dark > 0.5) {
        float3 ground = float3(0.012, 0.020, 0.040);
        float3 metal = float3(0.78, 0.83, 0.90);
        float3 cyan = float3(0.30, 0.78, 1.00);
        rgb = ground + metal * (body * 0.80 + glow * 0.30) + cyan * edge * 0.85;
    } else {
        float3 ground = float3(0.90, 0.92, 0.95);
        float3 metal = float3(0.40, 0.48, 0.60);
        float3 cyan = float3(0.05, 0.55, 0.85);
        rgb = mix(ground, metal, body * 0.55 + glow * 0.20);
        rgb = mix(rgb, cyan, edge * 0.70);
    }
    return half4(half3(saturate(rgb)), 1.0h);
}

// ── Water ─────────────────────────────────────────────────────────────────────────────────────────
// Light seen through a moving surface: long soft bands, stretched sideways, drifting and bending.

[[ stitchable ]] half4 fariinWater(float2 position, half4 color, float2 size, float phase, float dark) {
    float2 uv = position / max(size.y, 1.0);
    float y = position.y / max(size.y, 1.0);
    float2 p = float2(uv.x * 1.3, uv.y * 4.5);
    float2 m = awCircle(phase, 0.9);
    float w = awFbm(float2(p.x * 0.9 + m.x, p.y * 0.8 + m.y));
    float w2 = awFbm(float2(p.x * 1.7 - m.y * 0.7, p.y * 1.4 + m.x * 0.7) + 4.0);
    float bands = pow(1.0 - abs(sin((p.y + w * 2.6) * 3.14159)), 9.0);
    float fine = pow(1.0 - abs(sin((p.y * 1.9 + w2 * 3.2) * 3.14159)), 14.0);
    float light = bands * 0.75 + fine * 0.45;

    float3 rgb;
    if (dark > 0.5) {
        float3 top = float3(0.14, 0.20, 0.26);
        float3 bottom = float3(0.08, 0.11, 0.15);
        float3 ground = mix(top, bottom, y);
        rgb = ground + float3(0.50, 0.57, 0.65) * light * 0.42;
    } else {
        float3 top = float3(0.16, 0.66, 0.74);
        float3 mid = float3(0.62, 0.84, 0.88);
        float3 bottom = float3(0.93, 0.94, 0.95);
        float3 ground = y < 0.45 ? mix(top, mid, y / 0.45) : mix(mid, bottom, (y - 0.45) / 0.55);
        rgb = ground + float3(1.0, 1.0, 1.0) * light * 0.34;
    }
    return half4(half3(saturate(rgb)), 1.0h);
}

// ── Aurora ────────────────────────────────────────────────────────────────────────────────────────
// Curtains of light leaning across a night sky: bright near a wavering base line, fading upward, with
// fine vertical rays. `palette` 0 green, 1 purple, 2 pink.

[[ stitchable ]] half4 fariinAurora(float2 position, half4 color, float2 size, float phase, float dark, float palette) {
    float2 uv = position / max(size.y, 1.0);
    float y = position.y / max(size.y, 1.0);
    // Lean the curtains: x runs along the slant.
    float2 s = float2(uv.x * 0.94 + uv.y * 0.34, uv.y * 0.94 - uv.x * 0.34);
    float2 m = awCircle(phase, 0.7);

    float3 a, b;
    if (palette < 0.5)      { a = float3(0.10, 0.95, 0.75); b = float3(0.15, 0.35, 1.00); }
    else if (palette < 1.5) { a = float3(0.80, 0.30, 1.00); b = float3(0.35, 0.22, 0.95); }
    else                    { a = float3(1.00, 0.28, 0.58); b = float3(1.00, 0.58, 0.38); }

    float3 sky = dark > 0.5
        ? mix(float3(0.015, 0.020, 0.055), float3(0.030, 0.025, 0.080), y)
        : mix(float3(0.090, 0.090, 0.170), float3(0.140, 0.120, 0.230), y);

    float3 light = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float wob = awFbm(float2(s.y * 1.2 + fi * 3.1, m.x * 0.8 + fi)) * 1.6;
        float x = s.x * 2.4 + wob + m.y * 0.35 + fi * 1.9;
        float curtain = pow(0.5 + 0.5 * sin(x * 3.14159), 7.0);
        float base = 0.55 + 0.18 * sin(s.x * 2.0 + phase + fi) + 0.08 * fi;
        // Brightest just above the base line, fading upward, cut off below it. (smoothstep's edges
        // must ascend in Metal, so the cut is written as 1 − an ascending step.)
        float rise = smoothstep(base - 0.75, base - 0.05, s.y) * (1.0 - smoothstep(base, base + 0.06, s.y));
        float rays = 0.55 + 0.45 * awNoise(float2(s.x * 38.0 + fi * 7.0 + cos(phase) * 2.0, fi * 5.0 + sin(phase) * 2.0));   // a circle: no seam
        float glow = curtain * rise * rays;
        light += mix(a, b, smoothstep(base - 0.6, base, s.y)) * glow * (0.85 - fi * 0.2);
    }
    float3 rgb = sky + light * 0.9;
    return half4(half3(saturate(rgb)), 1.0h);
}

// ── Liquid Glow ───────────────────────────────────────────────────────────────────────────────────
// Big soft blobs of colour drifting into one another (owner's reference: royal blue, sky blue and a
// pale lime). Each blob follows its own slow loop; the colour at a point is the blobs' blend there.

[[ stitchable ]] half4 fariinLiquidGlow(float2 position, half4 color, float2 size, float phase, float dark) {
    float2 uv = position / max(size, float2(1.0));
    float3 cols[5];
    float3 ground;
    if (dark > 0.5) {
        ground = float3(0.03, 0.06, 0.20);
        cols[0] = float3(0.08, 0.18, 0.62); cols[1] = float3(0.16, 0.36, 0.78); cols[2] = float3(0.30, 0.42, 0.22);
        cols[3] = float3(0.05, 0.10, 0.40); cols[4] = float3(0.20, 0.30, 0.60);
    } else {
        ground = float3(0.42, 0.62, 0.98);
        cols[0] = float3(0.16, 0.32, 0.92); cols[1] = float3(0.50, 0.74, 1.00); cols[2] = float3(0.90, 0.95, 0.70);
        cols[3] = float3(0.22, 0.42, 0.95); cols[4] = float3(0.84, 0.92, 0.98);
    }
    // Where each blob sits on its loop (different radii and speeds, all whole turns per loop).
    float2 c0 = float2(0.25, 0.25) + float2(cos(phase), sin(phase)) * float2(0.18, 0.10);
    float2 c1 = float2(0.75, 0.35) + float2(cos(phase * 2.0 + 1.0), sin(phase + 2.0)) * float2(0.15, 0.14);
    float2 c2 = float2(0.50, 0.85) + float2(cos(phase + 3.0), sin(phase * 2.0)) * float2(0.25, 0.08);
    float2 c3 = float2(0.20, 0.65) + float2(sin(phase + 0.5), cos(phase * 3.0)) * float2(0.12, 0.12);
    float2 c4 = float2(0.80, 0.70) + float2(sin(phase * 2.0), cos(phase + 4.0)) * float2(0.10, 0.18);
    float2 cs[5] = { c0, c1, c2, c3, c4 };
    float rs[5] = { 0.30, 0.26, 0.34, 0.22, 0.24 };
    float aspect = size.x / max(size.y, 1.0);
    float3 sum = ground * 0.35;
    float wsum = 0.35;
    for (int i = 0; i < 5; i++) {
        float2 d = (uv - cs[i]) * float2(aspect, 1.0);
        float w = exp(-dot(d, d) / (rs[i] * rs[i]));
        sum += cols[i] * w;
        wsum += w;
    }
    return half4(half3(saturate(sum / wsum)), 1.0h);
}

// ── Liquid Edge ───────────────────────────────────────────────────────────────────────────────────
// One large soft shape slowly changing form on a near-black ground, outlined by a thin glowing edge
// (owner's reference). Light mode turns it over: a pale ground, a slightly deeper shape, a blue edge.

[[ stitchable ]] half4 fariinLiquidEdge(float2 position, half4 color, float2 size, float phase, float dark) {
    float2 uv = position / max(size.y, 1.0);
    float aspect = size.x / max(size.y, 1.0);
    float2 m = float2(cos(phase), sin(phase));
    // Three overlapping blobs make one body; a little noise keeps its outline organic.
    // A body that FLOATS on a phone screen (owner 2026-11-06): smaller blobs and a wider drift, so its
    // whole glowing outline is in view and changes shape as it moves, instead of one shape filling
    // the screen with only a glint of edge at the top.
    float2 b0 = float2(aspect * 0.55, 0.32) + m * float2(0.10, 0.08);
    float2 b1 = float2(aspect * 0.45, 0.52) + float2(m.y, -m.x) * float2(0.10, 0.08);
    float2 b2 = float2(aspect * 0.58, 0.70) + float2(-m.x, m.y) * float2(0.09, 0.08);
    float f = 0.020 / dot(uv - b0, uv - b0) + 0.028 / dot(uv - b1, uv - b1) + 0.018 / dot(uv - b2, uv - b2);
    f += (awFbm(uv * 3.0 + m * 0.4) - 0.5) * 0.35;
    // ⛔ SEEN, NOT GUESSED AT (owner 2026-11-06: "99% is black, let the user see it"). The body was
    // 0.075 on a 0.02 ground and the rim a hairline (0.06 of f), so on a phone only a corner glinted.
    // Now: a navy ground with its own gradient, a body clearly lighter than it with light falling
    // from the top, a rim four times wider, and a soft halo of the rim's colour outside the body.
    float inside = smoothstep(0.90, 1.15, f);
    float e = (f - 1.0) / 0.24;   // x*x, not pow (undefined for a negative base)
    float edge = exp(-e * e);
    float halo = exp(-max(0.0, 1.0 - f) * 2.5) * (1.0 - inside);
    float y = position.y / max(size.y, 1.0);
    float3 rgb;
    if (dark > 0.5) {
        float3 ground = mix(float3(0.035, 0.045, 0.095), float3(0.060, 0.045, 0.120), y);
        float3 body = mix(float3(0.16, 0.20, 0.30), float3(0.10, 0.12, 0.20), y);
        float3 rim = float3(0.35, 0.60, 0.95);
        rgb = mix(ground, body, inside) + rim * (edge * 0.85 + halo * 0.22);
    } else {
        float3 ground = mix(float3(0.93, 0.94, 0.97), float3(0.88, 0.90, 0.96), y);
        float3 body = mix(float3(0.80, 0.85, 0.94), float3(0.74, 0.79, 0.90), y);
        float3 rim = float3(0.25, 0.45, 0.85);
        rgb = mix(mix(ground, body, inside), rim, saturate(edge * 0.60 + halo * 0.15));
    }
    return half4(half3(saturate(rgb)), 1.0h);
}

// ── Stars ─────────────────────────────────────────────────────────────────────────────────────────
// A deep sky: a faint nebula drifting on a slow loop, and stars on a grid of cells (one per cell, at a
// random spot, random size), each twinkling at its own whole-number rate so the loop stays seamless.

[[ stitchable ]] half4 fariinStars(float2 position, half4 color, float2 size, float phase, float dark) {
    float2 uv = position / max(size.y, 1.0);
    float y = position.y / max(size.y, 1.0);
    float3 sky = dark > 0.5 ? mix(float3(0.010, 0.012, 0.040), float3(0.030, 0.020, 0.075), y)
                            : mix(float3(0.075, 0.085, 0.190), float3(0.150, 0.110, 0.260), y);
    float2 m = awCircle(phase, 0.25);
    float neb = awFbm(uv * 1.6 + m);
    float3 rgb = sky + float3(0.20, 0.10, 0.35) * smoothstep(0.45, 0.85, neb) * 0.45
                     + float3(0.05, 0.15, 0.30) * smoothstep(0.55, 0.90, awFbm(uv * 2.3 - m + 7.0)) * 0.35;
    for (int layer = 0; layer < 2; layer++) {
        float scale = layer == 0 ? 22.0 : 40.0;
        float2 g = uv * scale;
        float2 cell = floor(g);
        float2 f = fract(g);
        float h = awHash(cell + float(layer) * 31.0);
        float2 spot = float2(awHash(cell + 3.1), awHash(cell + 7.7)) * 0.8 + 0.1;
        float d = length(f - spot);
        float radius = (layer == 0 ? 0.06 : 0.04) * (0.5 + h);
        float star = (1.0 - smoothstep(0.0, radius, d));
        float rate = floor(1.0 + h * 4.0);                      // whole turns per loop: no seam
        float tw = 0.55 + 0.45 * sin(phase * rate + h * 6.2831);
        float show = step(0.55, h);                            // not every cell has a star
        rgb += float3(0.85, 0.90, 1.0) * star * tw * show * (layer == 0 ? 1.0 : 0.6);
    }
    return half4(half3(saturate(rgb)), 1.0h);
}

// ── Particles: snow, rain, glowing dots ───────────────────────────────────────────────────────────
// One particle per cell, cells scrolling down by a WHOLE number of cells per loop, so the last frame
// of a loop is the first. `kind` 0 snow, 1 rain, 2 glowing dots; `amount` 0…2 is the intensity (how
// many layers are drawn).

[[ stitchable ]] half4 fariinParticles(float2 position, half4 color, float2 size, float phase, float dark,
                                       float kind, float amount) {
    float2 uv = position / max(size.y, 1.0);
    float y = position.y / max(size.y, 1.0);
    float t = phase / 6.28318;                                 // 0…1 over one loop
    float3 ground;
    if (kind < 0.5)      ground = dark > 0.5 ? mix(float3(0.06, 0.08, 0.14), float3(0.10, 0.12, 0.20), y)
                                             : mix(float3(0.70, 0.78, 0.88), float3(0.86, 0.90, 0.95), y);
    else if (kind < 1.5) ground = dark > 0.5 ? mix(float3(0.05, 0.07, 0.10), float3(0.09, 0.11, 0.15), y)
                                             : mix(float3(0.55, 0.62, 0.70), float3(0.72, 0.77, 0.82), y);
    else                 ground = dark > 0.5 ? mix(float3(0.03, 0.03, 0.08), float3(0.06, 0.04, 0.12), y)
                                             : mix(float3(0.92, 0.88, 0.96), float3(0.97, 0.93, 0.90), y);
    float3 rgb = ground;
    int layers = 1 + int(clamp(amount, 0.0, 2.0));
    for (int layer = 0; layer < 3; layer++) {
        if (layer >= layers) break;
        float fl = float(layer);
        float scale = kind < 1.5 ? (9.0 + fl * 5.0) : (6.0 + fl * 3.0);
        // ⛔ A LOOP WITH NO SEAM (5-angle check 2026-11-06): the rows a particle's randomness is read
        // from repeat every `rows` cells, and a layer falls exactly rows x (1 + layer) cells per loop,
        // so the last frame of a loop shows the same particles as the first. `rows` is more than a
        // screen of cells, so the repeat never shows.
        float rows = kind < 0.5 ? 24.0 : (kind < 1.5 ? 48.0 : 16.0);
        float speed = rows * (1.0 + fl);
        float2 g = uv * scale;
        // Rain leans a little. Set from the position BEFORE the fall, so the lean never moves with
        // time and the loop stays whole.
        if (kind > 0.5 && kind < 1.5) g.x += g.y * 0.12;
        g.y -= t * speed;                                     // whole cells per loop
        float2 cell = floor(g);
        cell.y = cell.y - rows * floor(cell.y / rows);          // the repeating rows (see above)
        float2 f = fract(g);
        float h = awHash(cell + fl * 17.0);
        if (h < (kind < 1.5 ? 0.35 : 0.55)) continue;          // empty cells keep it airy
        // Spots stay in the middle of their cell, so nothing is cut at a cell's edge.
        float2 spot = float2(awHash(cell + 1.3), awHash(cell + 5.9)) * 0.4 + 0.3;
        if (kind < 0.5) {
            spot.x += 0.12 * sin(phase * floor(1.0 + h * 2.0) * 8.0 + h * 6.2831);   // a flake sways
            float d = length(f - spot);
            float flake = (1.0 - smoothstep(0.0, 0.10 - fl * 0.02, d));
            float3 c = dark > 0.5 ? float3(0.92, 0.95, 1.0) : float3(1.0, 1.0, 1.0);
            rgb = mix(rgb, c, flake * (0.85 - fl * 0.2));
        } else if (kind < 1.5) {
            float2 q = f - spot;
            float streak = (1.0 - smoothstep(0.0, 0.018, abs(q.x))) * (1.0 - smoothstep(0.0, 0.22, abs(q.y)));
            float3 c = dark > 0.5 ? float3(0.65, 0.75, 0.90) : float3(0.95, 0.97, 1.0);
            rgb = mix(rgb, c, streak * (0.55 - fl * 0.12));
        } else {
            float2 drift = float2(cos(phase * floor(1.0 + h * 2.0) * 8.0 + h * 9.0), sin(phase * 8.0 + h * 5.0)) * 0.08;
            float d = length(f - spot - drift);
            float pulse = 0.6 + 0.4 * sin(phase * floor(1.0 + h * 3.0) * 16.0 + h * 6.2831);
            float core = (1.0 - smoothstep(0.0, 0.06, d));
            float halo = (1.0 - smoothstep(0.0, 0.20, d)) * 0.45;
            float3 c = dark > 0.5 ? mix(float3(1.0, 0.85, 0.45), float3(0.55, 0.85, 1.0), h)
                                  : mix(float3(1.0, 0.65, 0.35), float3(0.55, 0.55, 1.0), h);
            if (dark > 0.5) { rgb += c * (core + halo) * pulse * 0.9; }
            else { rgb = mix(rgb, c, saturate((core + halo) * pulse * 0.75)); }   // a light ground would only whiten
        }
    }
    return half4(half3(saturate(rgb)), 1.0h);
}
