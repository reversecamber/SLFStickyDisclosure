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

/// A change in whether sections are being dragged.
public enum SectionedListDragEvent<ID: Hashable & Sendable>: Equatable, Sendable {
    /// A drag lifted these sections. While a drag is active, every section's rows are hidden.
    case began([ID])
    /// The drag ended with a drop or a cancel. An accepted drop also arrives separately as a ``SectionedListMove``.
    case ended
}
