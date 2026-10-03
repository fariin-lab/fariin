// VariableBlurUIView — from VariableBlur by Nikita Starshinov (github.com/nikstar/VariableBlur),
// itself credited to github.com/jtrivedi/VariableBlurView. Used by the owner's choice, 2026-10-03,
// via the ProgressiveBlurHeader package (github.com/dominikmartn/ProgressiveBlurHeader) he pointed to:
// "use that blur" for the chat header.
//
// MIT License
// Copyright (c) 2012-2023 Nikita Starshinov, Scott Chacon, and others
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute,
// sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
// NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import UIKit
import CoreImage.CIFilterBuiltins

/// A real progressive blur: strongest at the top, nothing at the bottom, the radius itself changing
/// line by line rather than one blur faded by opacity (which is what showed a line). It uses the
/// system's own backdrop layer with its standard filters replaced by `variableBlur`, the same filter
/// the system and the reference app use; the names are assembled backwards, as upstream does.
/// If the filter cannot be made on some future iOS, this stays a plain view and draws nothing.
final class VariableBlurUIView: UIVisualEffectView {
    init(maxBlurRadius: CGFloat = 20, startOffset: CGFloat = 0) {
        super.init(effect: UIBlurEffect(style: .regular))
        isUserInteractionEnabled = false

        let clsName = String("retliFAC".reversed())
        guard let cls = NSClassFromString(clsName) as? NSObject.Type else { return }
        let selName = String(":epyThtiWretlif".reversed())
        guard let made = cls.perform(NSSelectorFromString(selName), with: "variableBlur"),
              let variableBlur = made.takeUnretainedValue() as? NSObject else { return }

        // The radius at each pixel follows the mask's alpha: 1 is the full radius, 0 is none.
        variableBlur.setValue(maxBlurRadius, forKey: "inputRadius")
        variableBlur.setValue(Self.gradientMask(startOffset: startOffset), forKey: "inputMaskImage")
        variableBlur.setValue(true, forKey: "inputNormalizeEdges")

        // The effect view is here only for its backdrop layer, which filters what is behind it live.
        subviews.first?.layer.filters = [variableBlur]
        // Its dimming / tint views would draw a hard edge; they go.
        for subview in subviews.dropFirst() { subview.alpha = 0 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        // Upstream's fix for pixelation at the unblurred edge.
        guard let window, let backdrop = subviews.first?.layer else { return }
        backdrop.setValue(window.traitCollection.displayScale, forKey: "scale")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        // Deliberately empty: upstream notes that calling super here crashes.
    }

    /// Black at the top, clear at the bottom: blurred top, clear bottom.
    private static func gradientMask(startOffset: CGFloat) -> CGImage? {
        let size: CGFloat = 100
        let gradient = CIFilter.linearGradient()
        gradient.color0 = CIColor.black
        gradient.color1 = CIColor.clear
        gradient.point0 = CGPoint(x: 0, y: size)
        gradient.point1 = CGPoint(x: 0, y: startOffset * size)
        guard let output = gradient.outputImage else { return nil }
        return CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: size, height: size))
    }
}
