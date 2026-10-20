import SwiftUI

/// Clips scrolling rows vertically while leaving room for native focus effects.
private struct NavigationFormVerticalClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -rect.width, dy: 0))
    }
}

extension View {
    func navigationFormViewport() -> some View {
        safeAreaPadding(.vertical)
            .clipShape(NavigationFormVerticalClip())
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
