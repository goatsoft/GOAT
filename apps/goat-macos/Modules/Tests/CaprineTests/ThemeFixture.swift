import Caprine
import Herd

/// Store tests need valid data, independently of the app's built-in theme catalogue.
func storedThemeFixture() -> ThemeSpec {
    ThemeSpec(
        id: "test-theme", name: "Test Theme", appearance: .light,
        bg: "#FFFFFF", surface: "#EEEEEE", ink: "#111111", muted: "#666666",
        accent: "#114488", accent2: "#225599", glow: "#3366AA",
        selection: "#114488", tint: "#114488", washOpacity: 0.1, bgOpacity: 0.4)
}
