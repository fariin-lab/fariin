#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// A blur whose radius GROWS as it goes down the view, for the bottom of the profile poster.
//
// The concept is Variablur's (github.com/daprice/Variablur), studied and then written for the one
// job we have rather than vendored: a separable Gaussian run as a SwiftUI layerEffect, with the
// radius varying per pixel instead of being constant. Theirs reads the radius from a mask texture,
// which is the right call for a general library. Ours only ever ramps top-to-bottom, so the ramp is
// computed from the pixel's own y and there is no mask to render, upload or sample.
//
// SEPARABLE, so the caller runs it TWICE — once horizontally, once vertically. A true 2D Gaussian
// costs samples squared; two 1D passes cost samples times two and land on the same image. That is
// the difference between this being affordable while scrolling and not.
//
// Why a shader at all, when a gradient mask was already there: fading a photo to a flat colour still
// ends in a flat colour, and the eye finds the place where the picture stopped. Blurring it means
// the photo never stops — it loses its detail and keeps its colour, which is what a real material
// does and what the owner asked for.

/// One axis of a Gaussian bell. `sigma` is a third of the radius, so the curve has effectively
/// finished by the time the samples do.
inline half posterGaussian(half distance, half sigma) {
    return exp(-(distance * distance) / (2.0h * sigma * sigma));
}

/// - Parameter pos: pixel position, relative to the view's bounding rect.
/// - Parameter bounds: the view's bounding rect (x, y, width, height).
/// - Parameter startY: where the blur begins. Above this the pixel is returned untouched.
/// - Parameter radius: blur radius at the very bottom of the view.
/// - Parameter maxSamples: samples taken in EACH direction. Fewer is cheaper and bands sooner.
/// - Parameter vertical: 0 blurs along x, anything else along y. SwiftUI cannot pass a bool.
[[ stitchable ]] half4 posterFadeBlur(float2 pos,
                                      SwiftUI::Layer layer,
                                      float4 bounds,
                                      float startY,
                                      float radius,
                                      float maxSamples,
                                      float vertical) {
    const float span = max(bounds[3] - startY, 1.0);
    const float t = clamp((pos.y - startY) / span, 0.0, 1.0);
    // SQUARED, not linear. A linear ramp starts blurring immediately and the top of the fade reads
    // as slightly soft rather than sharp; squaring keeps the picture crisp for longer and then goes
    // quickly, which is what makes the join disappear instead of the whole photo looking hazy.
    const half r = half(radius) * half(t * t);

    if (r < 1.0h) {
        return layer.sample(pos);
    }

    const half sigma = max(r / 3.0h, 0.0001h);
    const half interval = max(1.0h, r / half(maxSamples));
    const half2 axis = vertical == 0.0 ? half2(1.0h, 0.0h) : half2(0.0h, 1.0h);

    half weight = posterGaussian(0.0h, sigma);
    half4 sum = layer.sample(pos) * weight;
    half total = weight;

    for (half d = interval; d <= r; d += interval) {
        const half w = posterGaussian(d, sigma);
        const float2 offset = float2(axis * d);
        sum += layer.sample(pos + offset) * w;
        sum += layer.sample(pos - offset) * w;
        total += w * 2.0h;
    }

    return sum / total;
}
