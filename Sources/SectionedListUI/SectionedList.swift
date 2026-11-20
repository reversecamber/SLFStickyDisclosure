import SwiftUI

/// Sections with sticky headers that can be swiped and dragged to reorder.
///
/// The caller owns the data, the order and the ``SectionedListState``, and receives disclosure,
/// drag and move events. The list never changes caller data.
///
/// Place it inside a vertical `ScrollView` and apply `sectionedListContainer(appearance:)` to that
/// scroll view; the scroll view may hold other content above or below the list.
/// Rows are direct lazy children, so an `.id(_:)` applied inside `row` stays a scroll target.
/// Apply `.id(_:)` inside header content, never around the header.
public struct SectionedList<SectionModel: Identifiable, Item: Identifiable,
    Header: View, Row: View, LeadingActions: View, TrailingActions: View>: View
where SectionModel.ID: Sendable {
    private let sections: [SectionModel]
    private let items: (SectionModel) -> [Item]
    private let state: SectionedListState<SectionModel.ID>
    private let appearance: SectionedListAppearance
    private let isReorderEnabled: Bool
    private let allowsLeadingFullSwipe: Bool
    private let allowsTrailingFullSwipe: Bool
    private let rowInsets: EdgeInsets
    private let sectionLabel: (SectionModel) -> String
    private let disclosureRequested: ((SectionModel.ID) -> Void)?
    private let dragChanged: (SectionedListDragEvent<SectionModel.ID>) -> Void
    private let moveRequested: (SectionedListMove<SectionModel.ID>) -> Void
    private let header: (SectionModel) -> Header
    private let row: (Item) -> Row
    private let leadingActions: (SectionModel) -> LeadingActions
    private let trailingActions: (SectionModel) -> TrailingActions

    /// - Parameters:
    ///   - sections: The sections in display order. IDs must be unique.
    ///   - items: The rows of a section. IDs must be unique within the section.
    ///   - state: Collapsed and dragging sections.
    ///   - isReorderEnabled: Whether headers can be dragged or moved with VoiceOver. Turn it off when
    ///     the sections shown are not the complete order, such as while filtering.
    ///   - rowInsets: Padding around each row. Pass `EdgeInsets()` when a row has its own swipe
    ///     actions, so the row pads itself inside the swipeable area.
    ///   - sectionLabel: Names a section for the disclosure control's VoiceOver label.
    ///   - disclosureRequested: Called when the person taps a section's chevron. When `nil`, sections
    ///     have no chevron and are always expanded.
    ///   - dragChanged: Called when a header drag begins or ends.
    ///   - moveRequested: Called when the person drops headers in a new place or uses a VoiceOver move action.
    ///   - leadingActions: Swipe actions for a header's leading edge. Return `EmptyView()` for none.
    ///   - trailingActions: Swipe actions for a header's trailing edge. Return `EmptyView()` for none.
    public init(
        sections: [SectionModel],
        items: @escaping (SectionModel) -> [Item],
        state: SectionedListState<SectionModel.ID>,
        appearance: SectionedListAppearance = .groupedCards,
        isReorderEnabled: Bool = true,
        allowsLeadingFullSwipe: Bool = false,
        allowsTrailingFullSwipe: Bool = false,
        rowInsets: EdgeInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16),
        sectionLabel: @escaping (SectionModel) -> String,
        disclosureRequested: ((SectionModel.ID) -> Void)? = nil,
        dragChanged: @escaping (SectionedListDragEvent<SectionModel.ID>) -> Void,
        moveRequested: @escaping (SectionedListMove<SectionModel.ID>) -> Void,
        @ViewBuilder header: @escaping (SectionModel) -> Header,
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder leadingActions: @escaping (SectionModel) -> LeadingActions,
        @ViewBuilder trailingActions: @escaping (SectionModel) -> TrailingActions
    ) {
        self.sections = sections
        self.items = items
        self.state = state
        self.appearance = appearance
        self.isReorderEnabled = isReorderEnabled
        self.allowsLeadingFullSwipe = allowsLeadingFullSwipe
        self.allowsTrailingFullSwipe = allowsTrailingFullSwipe
        self.rowInsets = rowInsets
        self.sectionLabel = sectionLabel
        self.disclosureRequested = disclosureRequested
        self.dragChanged = dragChanged
        self.moveRequested = moveRequested
        self.header = header
        self.row = row
        self.leadingActions = leadingActions
        self.trailingActions = trailingActions
    }

    public var body: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { section in
                let rows = visibleRows(of: section)
                Section {
                    ForEach(rows) { item in
                        row(item)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(rowInsets)
                            .background(appearance.contentBackgroundColor)
                            .overlay(alignment: .top) { Divider() }
                            .clipShape(rowShape(isLast: item.id == rows.last?.id))
                    }
                    if appearance.sectionSpacing > 0 {
                        Color.clear
                            .frame(height: appearance.sectionSpacing)
                            .accessibilityHidden(true)
                    }
                } header: {
                    // Only headers join the shared reorder container; rows do not.
                    ForEach([section]) { section in
                        SectionedListHeader(
                            label: sectionLabel(section),
                            isExpanded: isExpanded(section),
                            hasVisibleRows: !rows.isEmpty,
                            isDragging: state.isDragging,
                            appearance: appearance,
                            disclosureRequested: disclosureRequested.map { request in { request(section.id) } },
                            content: { header(section) }
                        )
                        .swipeActions(edge: .leading, allowsFullSwipe: allowsLeadingFullSwipe) {
                            leadingActions(section)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: allowsTrailingFullSwipe) {
                            trailingActions(section)
                        }
                        .accessibilityActions { moveActions(for: section) }
                    }
                    .reorderable()
                }
            }
        }
        .reorderContainer(for: SectionModel.self, isEnabled: isReorderEnabled) { difference in
            reorderFinished(difference)
        }
        .onDragSessionUpdated { session in
            dragSessionUpdated(session)
        }
    }

    private func isExpanded(_ section: SectionModel) -> Bool {
        disclosureRequested == nil || state.isExpanded(section.id)
    }

    private func visibleRows(of section: SectionModel) -> [Item] {
        guard !state.isDragging, isExpanded(section) else { return [] }
        return items(section)
    }

    private func rowShape(isLast: Bool) -> UnevenRoundedRectangle {
        let radius = isLast ? appearance.cornerRadius : 0
        return UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
    }

    @ViewBuilder
    private func moveActions(for section: SectionModel) -> some View {
        if isReorderEnabled, let index = sections.firstIndex(where: { $0.id == section.id }) {
            if index > 0 {
                Button("Move up") {
                    moveRequested(.init(sources: [section.id], destination: .before(sections[index - 1].id)))
                }
                .disabled(state.isDragging)
            }
            if index + 1 < sections.count {
                Button("Move down") {
                    let destination: SectionedListMove<SectionModel.ID>.Destination =
                        index + 2 < sections.count ? .before(sections[index + 2].id) : .end
                    moveRequested(.init(sources: [section.id], destination: destination))
                }
                .disabled(state.isDragging)
            }
        }
    }

    private func reorderFinished(
        _ difference: ReorderDifference<SectionModel.ID, ReorderableSingleCollectionIdentifier>
    ) {
        let destination: SectionedListMove<SectionModel.ID>.Destination =
            switch difference.destination.position {
            case let .before(id): .before(id)
            case .end: .end
            }
        moveRequested(.init(sources: difference.sources, destination: destination))
    }

    private func dragSessionUpdated(_ session: DragSession) {
        switch session.phase {
        case .active:
            // Updates arrive with every finger movement; report the start once.
            guard !state.isDragging else { return }
            let sectionIDs = Set(sections.map(\.id))
            let ids = session.draggedItemIDs(for: SectionModel.ID.self).filter { sectionIDs.contains($0) }
            guard !ids.isEmpty else { return }
            dragChanged(.began(ids))
        case .ended, .dataTransferCompleted:
            // Always reported: this view may not have redrawn since the drag began.
            dragChanged(.ended)
        default:
            break
        }
    }
}

extension View {
    /// Prepares the vertical `ScrollView` that hosts a ``SectionedList``: coordinates header swipe
    /// actions and applies the appearance's page background and side margins.
    public func sectionedListContainer(appearance: SectionedListAppearance = .groupedCards) -> some View {
        swipeActionsContainer()
            .contentMargins(.horizontal, appearance.horizontalMargin, for: .scrollContent)
            .background(appearance.backgroundColor)
    }
}

private struct SectionedListHeader<Content: View>: View {
    let label: String
    let isExpanded: Bool
    let hasVisibleRows: Bool
    let isDragging: Bool
    let appearance: SectionedListAppearance
    let disclosureRequested: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        let radius = appearance.cornerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: hasVisibleRows ? 0 : radius,
            bottomTrailingRadius: hasVisibleRows ? 0 : radius,
            topTrailingRadius: radius
        )
        HStack(spacing: 8) {
            if let disclosureRequested {
                Button(action: disclosureRequested) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDragging)
                .accessibilityLabel(label)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Hides section items" : "Shows section items")
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, disclosureRequested == nil ? 16 : 0)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .background(appearance.contentBackgroundColor)
        .clipShape(shape)
        // Fills the rounded corners so rows scrolling under a pinned header stay hidden.
        .background(appearance.backgroundColor)
        .contentShape(.dragPreview, shape)
        .contentShape(.interaction, Rectangle())
        .accessibilityElement(children: .contain)
    }
}
