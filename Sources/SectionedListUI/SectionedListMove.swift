/// A request to move whole sections, reported after a drop or a VoiceOver move action.
public struct SectionedListMove<ID: Hashable & Sendable>: Equatable, Sendable {
    /// Where the moved sections go, judged after the moved sections are taken out.
    public enum Destination: Equatable, Sendable {
        /// Immediately before the section with this ID.
        case before(ID)
        /// After the last section.
        case end
    }

    /// The sections being moved.
    public let sources: [ID]
    public let destination: Destination

    public init(sources: [ID], destination: Destination) {
        self.sources = sources
        self.destination = destination
    }

    /// Returns `elements` with the moved sections placed at the destination, keeping their current relative order.
    ///
    /// Returns `nil` when the move names no section, repeats a section, names a section missing from `elements`,
    /// targets one of the moved sections, or leaves the order unchanged.
    public func reordered<Element>(_ elements: [Element], id: (Element) -> ID) -> [Element]? {
        let sourceIDs = Set(sources)
        guard !sources.isEmpty, sourceIDs.count == sources.count else { return nil }
        let currentIDs = elements.map(id)
        guard sourceIDs.isSubset(of: currentIDs) else { return nil }
        let moving = elements.filter { sourceIDs.contains(id($0)) }
        var reordered = elements.filter { !sourceIDs.contains(id($0)) }
        switch destination {
        case let .before(target):
            guard let index = reordered.firstIndex(where: { id($0) == target }) else { return nil }
            reordered.insert(contentsOf: moving, at: index)
        case .end:
            reordered.append(contentsOf: moving)
        }
        guard reordered.map(id) != currentIDs else { return nil }
        return reordered
    }

    /// Returns `elements` with the moved sections placed at the destination. See ``reordered(_:id:)``.
    public func reordered<Element: Identifiable>(_ elements: [Element]) -> [Element]? where Element.ID == ID {
        reordered(elements, id: \.id)
    }
}

/// A request to move one row, within its section or into another section, reported after a drop
/// or a VoiceOver move action.
public struct SectionedListRowMove<SectionID: Hashable & Sendable, RowID: Hashable & Sendable>: Equatable, Sendable {
    /// Where the row goes in the target section, judged after the row is taken out.
    public enum Destination: Equatable, Sendable {
        /// Immediately before the row with this ID.
        case before(RowID)
        /// After the last row.
        case end
    }

    public let row: RowID
    public let fromSection: SectionID
    public let toSection: SectionID
    public let destination: Destination

    public init(row: RowID, fromSection: SectionID, toSection: SectionID, destination: Destination) {
        self.row = row
        self.fromSection = fromSection
        self.toSection = toSection
        self.destination = destination
    }

    /// Returns the target section's row IDs with the moved row placed at the destination.
    ///
    /// Pass the target section's current row IDs in order; the moved row may be among them when the
    /// move stays within its section. Returns `nil` when the destination row is missing or the
    /// order doesn't change.
    public func reordered(_ targetRowIDs: [RowID]) -> [RowID]? {
        var reordered = targetRowIDs.filter { $0 != row }
        switch destination {
        case let .before(target):
            guard let index = reordered.firstIndex(of: target) else { return nil }
            reordered.insert(row, at: index)
        case .end:
            reordered.append(row)
        }
        guard reordered != targetRowIDs else { return nil }
        return reordered
    }
}
