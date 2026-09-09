import Pens
import SwiftUI

extension Color {
    public init(_ oklch: OKLCH) {
        let (r, g, b) = oklch.rgb
        self.init(.sRGB, red: r, green: g, blue: b)
    }
}
