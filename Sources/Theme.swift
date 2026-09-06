import SwiftUI

/// Fixed dark palette — the app always renders dark regardless of system appearance.
enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let panel = Color(red: 0.102, green: 0.102, blue: 0.114)
    static let panelRaised = Color(red: 0.145, green: 0.145, blue: 0.161)
    static let control = Color(red: 0.196, green: 0.196, blue: 0.216)
    static let border = Color.white.opacity(0.07)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.52)
    static let accent = Color(red: 0.204, green: 0.541, blue: 1.0)
    static let danger = Color(red: 0.937, green: 0.325, blue: 0.353)
    static let success = Color(red: 0.29, green: 0.80, blue: 0.51)

    static let panelRadius: CGFloat = 10
    static let controlRadius: CGFloat = 7
}

struct PanelBackground: ViewModifier {
    var padding: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.panelRadius)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.panelRadius)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func panel(padding: CGFloat = 10) -> some View {
        modifier(PanelBackground(padding: padding))
    }
}
