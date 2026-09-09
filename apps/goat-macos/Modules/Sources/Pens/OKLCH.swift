import Foundation

/// A colour in OKLCH - perceptually-uniform lightness / chroma / hue. Stored on a Pen so
/// palettes stay even and legible; converted to sRGB for display (Björn Ottosson's OKLab).
public struct OKLCH: Codable, Sendable, Equatable, Hashable {
    public var l: Double  // lightness 0…1
    public var c: Double  // chroma 0…~0.37
    public var h: Double  // hue degrees 0…360

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    /// A pleasant default spread of pen colours (even lightness/chroma, hues around the wheel).
    public static let palette: [OKLCH] = stride(from: 20.0, to: 380.0, by: 40).map {
        OKLCH(l: 0.68, c: 0.16, h: $0)
    }

    public static let fallback = OKLCH(l: 0.68, c: 0.16, h: 250)

    /// Linear→gamma sRGB components in 0…1.
    public var rgb: (r: Double, g: Double, b: Double) {
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let b = c * sin(hr)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_
        let mc = m_ * m_ * m_
        let sc = s_ * s_ * s_
        let lr = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let lg = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let lb = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        func gamma(_ x: Double) -> Double {
            let v = max(0, min(1, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return (gamma(lr), gamma(lg), gamma(lb))
    }
}
