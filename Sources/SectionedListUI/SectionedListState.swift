/// Interaction state for a ``SectionedList``: which sections are collapsed and which are being dragged.
///
/// Keep it in the owning feature's state and call its methods from that feature's actions.
/// Section data and ordering stay with the caller; ``handleMove(_:sections:id:)`` returns the new
/// order for the caller to save.
public struct SectionedListState<ID: Hashable & Sendable>: Equatable, Sendable {
    /// Sections the person collapsed. Every other section is expanded, so new sections start expanded.
    public var collapsedIDs: Set<ID>
    /// The sections being dragged; empty when no drag is active.
    public private(set) var draggingIDs: [ID] = []

    public init(collapsedIDs: Set<ID> = []) {
        self.collapsedIDs = collapsedIDs
    }

    public var isDragging: Bool { !draggingIDs.isEmpty }

    public func isExpanded(_ id: ID) -> Bool { !collapsedIDs.contains(id) }

    /// Collapses an expanded section or expands a collapsed one. Ignored while a drag is active.
    public mutating func toggleExpansion(of id: ID) {
        guard !isDragging else { return }
        if collapsedIDs.remove(id) == nil {
            collapsedIDs.insert(id)
        }
    }

    /// Records a drag event. Repeated events are harmless; the first `began` of a drag wins.
    public mutating func handleDrag(_ event: SectionedListDragEvent<ID>) {
        switch event {
        case let .began(ids):
            guard !isDragging, !ids.isEmpty else { return }
            draggingIDs = ids
        case .ended:
            draggingIDs = []
        }
    }

    /// Ends any active drag and returns `sections` in the requested order, or `nil` when there is nothing to save.
    ///
    /// The drop and the end of the drag are reported separately, in no guaranteed order,
    /// so a move also ends the drag. See ``SectionedListMove/reordered(_:id:)`` for when the result is `nil`.
    public mutating func handleMove<Element>(
        _ move: SectionedListMove<ID>,
        sections: [Element],
        id: (Element) -> ID
    ) -> [Element]? {
        draggingIDs = []
        return move.reordered(sections, id: id)
    }

    /// Ends any active drag and returns `sections` in the requested order, or `nil` when there is nothing to save.
    public mutating func handleMove<Element: Identifiable>(
        _ move: SectionedListMove<ID>,
        sections: [Element]
    ) -> [Element]? where Element.ID == ID {
        handleMove(move, sections: sections, id: \.id)
    }
}
