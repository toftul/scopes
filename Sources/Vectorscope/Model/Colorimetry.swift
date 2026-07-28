import simd

/// Colour-space math for the vectorscope.
///
/// A vectorscope plots the two chroma components (Cb, Cr) of the picture. We
/// operate on the *gamma-encoded* R'G'B' the screen already gives us — that is
/// what broadcast scopes do, so no linearisation here on purpose.
enum Colorimetry {

    /// The luma coefficient set. Rec.709 is the HD/most-screen-content default;
    /// Rec.601 matches SD footage and some legacy tools.
    enum Space: CaseIterable {
        case rec709
        case rec601

        /// Kr, Kb luma weights. (Kg = 1 - Kr - Kb.)
        var kr: Float { self == .rec709 ? 0.2126 : 0.299 }
        var kb: Float { self == .rec709 ? 0.0722 : 0.114 }

        var label: String { self == .rec709 ? "Rec.709" : "Rec.601" }
    }

    /// Convert a gamma-encoded RGB triple (each in 0...1) to (Cb, Cr), each in
    /// roughly -0.5...0.5 with 0 = neutral grey.
    static func cbcr(r: Float, g: Float, b: Float, space: Space) -> SIMD2<Float> {
        let kr = space.kr
        let kb = space.kb
        let y = kr * r + (1.0 - kr - kb) * g + kb * b
        let cb = (b - y) / (2.0 * (1.0 - kb))
        let cr = (r - y) / (2.0 * (1.0 - kr))
        return SIMD2<Float>(cb, cr)
    }

    /// Scale that maps Cb/Cr into the scope's [-1, 1] display space. With 2.0,
    /// 75% colour-bar primaries land near ~0.77 radius (on the target boxes)
    /// and 100% bars sit just inside the outer ring — the usual convention.
    static let displayScale: Float = 2.0
}
