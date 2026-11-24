/// Which sections of a ``SectionedList`` are collapsed.
///
/// Keep it in the owning feature's state and call its methods from that feature's actions.
/// Drags are tracked inside the list itself and reported as moves.
public struct SectionedListState<ID: Hashable & Sendable>: Equatable, Sendable {
    /// Sections the person collapsed. Every other section is expanded, so new sections start expanded.
    public var collapsedIDs: Set<ID>

    public init(collapsedIDs: Set<ID> = []) {
        self.collapsedIDs = collapsedIDs
    }

    public func isExpanded(_ id: ID) -> Bool { !collapsedIDs.contains(id) }

    /// Collapses an expanded section or expands a collapsed one.
    public mutating func toggleExpansion(of id: ID) {
        if collapsedIDs.remove(id) == nil {
            collapsedIDs.insert(id)
        }
    }
}
