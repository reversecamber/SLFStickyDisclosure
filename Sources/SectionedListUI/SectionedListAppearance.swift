import SwiftUI

public enum SectionedListAppearance: String, CaseIterable, Sendable {
    /// Each section is a rounded card on a grouped background.
    case groupedCards
    /// Edge-to-edge sections on the system background.
    case plain

    /// The page background behind the list. `sectionedListContainer(appearance:)` applies it.
    public var backgroundColor: Color {
        switch self {
        case .groupedCards: Color(.systemGroupedBackground)
        case .plain: Color(.systemBackground)
        }
    }

    var contentBackgroundColor: Color {
        switch self {
        case .groupedCards: Color(.secondarySystemGroupedBackground)
        case .plain: Color(.systemBackground)
        }
    }

    var cornerRadius: CGFloat { self == .groupedCards ? 12 : 0 }
    var horizontalMargin: CGFloat { self == .groupedCards ? 16 : 0 }
    var sectionSpacing: CGFloat { self == .groupedCards ? 16 : 0 }
}
