import SwiftUI

/// Sections with sticky headers that can be swiped, and whose sections and rows can be long-pressed
/// and dragged to a new place.
///
/// The caller owns the data, the order and the ``SectionedListState``, and receives disclosure and
/// move requests. The list never changes caller data; it only tracks the drag in progress.
///
/// Place it inside a vertical `ScrollView` and apply `sectionedListContainer(appearance:)` to that
/// scroll view; the scroll view may hold other content above or below the list. Dragging needs that
/// scroll view: the long press is installed on the UIKit scroll view behind it.
/// Rows are direct lazy children, so an `.id(_:)` applied inside `row` stays a scroll target.
public struct SectionedList<SectionModel: Identifiable, Item: Identifiable,
    Header: View, Row: View, LeadingActions: View, TrailingActions: View>: View
where SectionModel.ID: Sendable, Item.ID: Sendable {
    public typealias SectionID = SectionModel.ID
    public typealias RowID = Item.ID

    private let sections: [SectionModel]
    private let items: (SectionModel) -> [Item]
    private let state: SectionedListState<SectionID>
    private let appearance: SectionedListAppearance
    private let allowsLeadingFullSwipe: Bool
    private let allowsTrailingFullSwipe: Bool
    private let rowInsets: EdgeInsets
    private let sectionLabel: (SectionModel) -> String
    private let disclosureRequested: ((SectionID) -> Void)?
    private let canMoveRow: (Item) -> Bool
    private let sectionMoveRequested: ((SectionedListMove<SectionID>) -> Void)?
    private let rowMoveRequested: ((SectionedListRowMove<SectionID, RowID>) -> Void)?
    private let header: (SectionModel) -> Header
    private let row: (Item) -> Row
    private let leadingActions: (SectionModel) -> LeadingActions
    private let trailingActions: (SectionModel) -> TrailingActions

    @State private var geometry = SectionedListGeometry<SectionID, RowID>()
    @State private var drag: SectionedListDrag<SectionID, RowID>?
    /// A move the list requested whose result the caller's data doesn't show yet. See ``request(_:)``.
    @State private var pending: SectionedListPendingMove<SectionID, RowID>?
    @State private var pendingTimeout: Task<Void, Never>?
    @State private var liftCount = 0
    @State private var targetCount = 0

    /// - Parameters:
    ///   - sections: The sections in display order. IDs must be unique.
    ///   - items: The rows of a section. IDs must be unique within the section.
    ///   - state: Collapsed sections.
    ///   - rowInsets: Padding around each row. Pass `EdgeInsets()` when a row has its own swipe
    ///     actions, so the row pads itself inside the swipeable area.
    ///   - sectionLabel: Names a section for the disclosure control's VoiceOver label.
    ///   - disclosureRequested: Called when the person taps a section's chevron. When `nil`, sections
    ///     have no chevron and are always expanded.
    ///   - canMoveRow: Whether a row can be dragged. Rows that can't, such as an empty-section
    ///     message, stay in place and are never used as a destination.
    ///   - sectionMoveRequested: Called when the person drops a section in a new place or uses a
    ///     VoiceOver move action. When `nil`, sections can't be dragged. Pass `nil` whenever the
    ///     sections shown are not the complete order, such as while filtering.
    ///   - rowMoveRequested: Called when the person drops a row in a new place, in its own section or
    ///     another one, or uses a VoiceOver move action. When `nil`, rows can't be dragged.
    ///   - leadingActions: Swipe actions for a header's leading edge. Return `EmptyView()` for none.
    ///   - trailingActions: Swipe actions for a header's trailing edge. Return `EmptyView()` for none.
    public init(
        sections: [SectionModel],
        items: @escaping (SectionModel) -> [Item],
        state: SectionedListState<SectionID> = .init(),
        appearance: SectionedListAppearance = .groupedCards,
        allowsLeadingFullSwipe: Bool = false,
        allowsTrailingFullSwipe: Bool = false,
        rowInsets: EdgeInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16),
        sectionLabel: @escaping (SectionModel) -> String,
        disclosureRequested: ((SectionID) -> Void)? = nil,
        canMoveRow: @escaping (Item) -> Bool = { _ in true },
        sectionMoveRequested: ((SectionedListMove<SectionID>) -> Void)? = nil,
        rowMoveRequested: ((SectionedListRowMove<SectionID, RowID>) -> Void)? = nil,
        @ViewBuilder header: @escaping (SectionModel) -> Header,
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder leadingActions: @escaping (SectionModel) -> LeadingActions,
        @ViewBuilder trailingActions: @escaping (SectionModel) -> TrailingActions
    ) {
        self.sections = sections
        self.items = items
        self.state = state
        self.appearance = appearance
        self.allowsLeadingFullSwipe = allowsLeadingFullSwipe
        self.allowsTrailingFullSwipe = allowsTrailingFullSwipe
        self.rowInsets = rowInsets
        self.sectionLabel = sectionLabel
        self.disclosureRequested = disclosureRequested
        self.canMoveRow = canMoveRow
        self.sectionMoveRequested = sectionMoveRequested
        self.rowMoveRequested = rowMoveRequested
        self.header = header
        self.row = row
        self.leadingActions = leadingActions
        self.trailingActions = trailingActions
    }

    public var body: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(displaySections) { section in
                let slots = rowSlots(of: section)
                Section {
                    ForEach(slots) { slot in
                        rowSlotView(slot, isLast: slot.id == slots.last?.id)
                    }
                    // Spacing, and the section's bottom edge for drop targeting.
                    Color.clear
                        .frame(height: appearance.sectionSpacing)
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(SectionedListSpace.content)).maxY } action: {
                            geometry.bottoms[section.id] = $0
                        }
                        .onDisappear { geometry.bottoms[section.id] = nil }
                } header: {
                    headerView(section, hasVisibleRows: !slots.isEmpty)
                }
            }
            if drag != nil {
                // Room to drop below the last section.
                Color.clear
                    .frame(height: 88)
                    .accessibilityHidden(true)
            }
        }
        .animation(.snappy(duration: 0.25), value: drag?.sectionOrder)
        .animation(.snappy(duration: 0.25), value: drag?.rowTarget)
        .coordinateSpace(.named(SectionedListSpace.content))
        // Fills the list exactly, so the driver's coordinates are the list's coordinates.
        .background {
            if sectionMoveRequested != nil || rowMoveRequested != nil {
                SectionedListDragDriver(
                    canLift: { hit(at: $0) != nil },
                    began: lift,
                    moved: fingerMoved,
                    ended: dragEnded
                )
            }
        }
        .overlay(alignment: .topLeading) { floatingView }
        .sensoryFeedback(.impact(weight: .medium), trigger: liftCount)
        .sensoryFeedback(.selection, trigger: targetCount)
        .onChange(of: dataSnapshot) { dataChanged() }
    }

    // MARK: Display

    /// Sections in the order shown: during a section drag, the dragged section sits at its target.
    private var displaySections: [SectionModel] {
        guard let drag, case .section = drag.item else { return arrangedSections }
        let byID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = Set(drag.sectionOrder)
        // Sections that appeared during the drag keep their place at the end.
        return drag.sectionOrder.compactMap { byID[$0] } + sections.filter { !ordered.contains($0.id) }
    }

    private func isExpanded(_ section: SectionModel) -> Bool {
        disclosureRequested == nil || state.isExpanded(section.id)
    }

    /// A dragged section collapses for the duration of the drag.
    private func showsRows(of section: SectionModel) -> Bool {
        isExpanded(section) && drag?.item != .section(section.id)
    }

    private func rowSlots(of section: SectionModel) -> [RowSlot] {
        guard showsRows(of: section) else { return [] }
        let rows = displayedRows(of: section)
        guard let drag, case let .row(fromSection, rowID) = drag.item else {
            return rows.map { RowSlot.item(section.id, $0) }
        }
        var slots = rows.filter { section.id != fromSection || $0.id != rowID }.map { RowSlot.item(section.id, $0) }
        if let target = drag.rowTarget, target.sectionID == section.id {
            slots.insert(.placeholder(drag.size.height), at: min(target.index, slots.count))
        }
        return slots
    }

    private func headerView(_ section: SectionModel, hasVisibleRows: Bool) -> some View {
        let isLifted = drag?.item == .section(section.id)
        let isRowTarget = drag?.rowTarget?.sectionID == section.id && !showsRows(of: section)
        return SectionedListHeader(
            label: sectionLabel(section),
            isExpanded: isExpanded(section) && !isLifted,
            hasVisibleRows: hasVisibleRows,
            isDragging: drag != nil,
            isHighlighted: isRowTarget,
            appearance: appearance,
            disclosureRequested: disclosureRequested.map { request in { request(section.id) } },
            content: { header(section) }
        )
        .opacity(isLifted ? 0 : 1)
        .overlay {
            if isLifted {
                SectionedListPlaceholderOutline(cornerRadius: max(appearance.cornerRadius, 10))
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: allowsLeadingFullSwipe) {
            leadingActions(section)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: allowsTrailingFullSwipe) {
            trailingActions(section)
        }
        .accessibilityActions { sectionMoveActions(for: section) }
        // Measured outside the swipe wrapper, which doesn't see the list's coordinate space.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SectionedListSpace.content)) } action: {
            geometry.headers[section.id] = $0
        }
        .onDisappear { geometry.headers[section.id] = nil }
    }

    @ViewBuilder
    private func rowSlotView(_ slot: RowSlot, isLast: Bool) -> some View {
        switch slot {
        case let .item(sectionID, item):
            let key = SectionedListRowKey(sectionID: sectionID, rowID: item.id)
            rowChrome(item, isLast: isLast)
                .accessibilityActions { rowMoveActions(for: item, in: sectionID) }
                // Measured outside any swipe wrapper in `row`, which doesn't see the list's coordinate space.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SectionedListSpace.content)) } action: {
                    geometry.rows[key] = $0
                }
                .onDisappear { geometry.rows[key] = nil }
        case let .placeholder(height):
            SectionedListPlaceholderOutline(cornerRadius: 10)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(appearance.contentBackgroundColor)
                .clipShape(rowShape(isLast: isLast))
        }
    }

    private func rowChrome(_ item: Item, isLast: Bool) -> some View {
        row(item)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(rowInsets)
            .background(appearance.contentBackgroundColor)
            .overlay(alignment: .top) { Divider() }
            .clipShape(rowShape(isLast: isLast))
    }

    private func rowShape(isLast: Bool) -> UnevenRoundedRectangle {
        let radius = isLast ? appearance.cornerRadius : 0
        return UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
    }

    @ViewBuilder
    private var floatingView: some View {
        if let drag {
            Group {
                switch drag.item {
                case let .section(id):
                    if let section = sections.first(where: { $0.id == id }) {
                        SectionedListHeader(
                            label: sectionLabel(section),
                            isExpanded: false,
                            hasVisibleRows: false,
                            isDragging: true,
                            isHighlighted: false,
                            appearance: appearance,
                            disclosureRequested: disclosureRequested == nil ? nil : {},
                            content: { header(section) }
                        )
                    }
                case let .row(sectionID, rowID):
                    if let section = sections.first(where: { $0.id == sectionID }),
                       let item = items(section).first(where: { $0.id == rowID }) {
                        rowChrome(item, isLast: false)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(width: drag.size.width, height: drag.size.height)
            .scaleEffect(1.03)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            .offset(x: drag.finger.x - drag.grabOffset.x, y: drag.finger.y - drag.grabOffset.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: VoiceOver moves

    @ViewBuilder
    private func sectionMoveActions(for section: SectionModel) -> some View {
        if sectionMoveRequested != nil, let index = sections.firstIndex(where: { $0.id == section.id }) {
            if index > 0 {
                Button("Move up") {
                    request(.section(.init(sources: [section.id], destination: .before(sections[index - 1].id))))
                }
                .disabled(drag != nil || pending != nil)
            }
            if index + 1 < sections.count {
                Button("Move down") {
                    let destination: SectionedListMove<SectionID>.Destination =
                        index + 2 < sections.count ? .before(sections[index + 2].id) : .end
                    request(.section(.init(sources: [section.id], destination: destination)))
                }
                .disabled(drag != nil || pending != nil)
            }
        }
    }

    @ViewBuilder
    private func rowMoveActions(for item: Item, in sectionID: SectionID) -> some View {
        if rowMoveRequested != nil, canMoveRow(item),
           let section = sections.first(where: { $0.id == sectionID }) {
            let movable = items(section).filter(canMoveRow)
            if let index = movable.firstIndex(where: { $0.id == item.id }) {
                if index > 0 {
                    Button("Move up") {
                        request(.row(.init(row: item.id, fromSection: sectionID, toSection: sectionID,
                                           destination: .before(movable[index - 1].id))))
                    }
                    .disabled(drag != nil || pending != nil)
                }
                if index + 1 < movable.count {
                    Button("Move down") {
                        let destination: SectionedListRowMove<SectionID, RowID>.Destination =
                            index + 2 < movable.count ? .before(movable[index + 2].id) : .end
                        request(.row(.init(row: item.id, fromSection: sectionID, toSection: sectionID,
                                           destination: destination)))
                    }
                    .disabled(drag != nil || pending != nil)
                }
            }
        }
    }

    // MARK: Drag

    private enum Hit {
        case section(SectionID, CGRect)
        case row(SectionID, Item, CGRect)
    }

    private func hit(at point: CGPoint) -> Hit? {
        // No new drag until the last move shows up in the caller's data.
        guard drag == nil, pending == nil else { return nil }
        // Headers draw above rows (a pinned header covers rows), so they win.
        if let header = geometry.headers.first(where: { $0.value.contains(point) }) {
            return sectionMoveRequested == nil ? nil : .section(header.key, header.value)
        }
        guard rowMoveRequested != nil,
              let row = geometry.rows.first(where: { $0.value.contains(point) }),
              let section = sections.first(where: { $0.id == row.key.sectionID }),
              let item = items(section).first(where: { $0.id == row.key.rowID }),
              canMoveRow(item) else { return nil }
        return .row(section.id, item, row.value)
    }

    private func lift(at point: CGPoint) {
        switch hit(at: point) {
        case let .section(id, frame):
            drag = SectionedListDrag(
                item: .section(id), finger: point,
                grabOffset: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
                size: frame.size, sectionOrder: sections.map(\.id), rowTarget: nil
            )
        case let .row(sectionID, item, frame):
            guard let section = sections.first(where: { $0.id == sectionID }),
                  let index = items(section).firstIndex(where: { $0.id == item.id }) else { return }
            drag = SectionedListDrag(
                item: .row(sectionID, item.id), finger: point,
                grabOffset: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
                size: frame.size, sectionOrder: sections.map(\.id),
                rowTarget: .init(sectionID: sectionID, index: index)
            )
        case nil:
            return
        }
        liftCount += 1
    }

    private func fingerMoved(to point: CGPoint) {
        guard var drag else { return }
        drag.finger = point
        updateTarget(&drag)
        self.drag = drag
    }

    private func dragEnded(dropped: Bool) {
        guard let drag else { return }
        withAnimation(.snappy(duration: 0.25)) {
            self.drag = nil
            if dropped {
                requestMove(for: drag)
            }
        }
    }

    /// Turns a drop into a move request, worked out from the caller's current data: sections or rows
    /// that changed during the drag are taken into account, and IDs that disappeared are skipped.
    private func requestMove(for drag: SectionedListDrag<SectionID, RowID>) {
        switch drag.item {
        case let .section(id):
            let currentIDs = sections.map(\.id)
            let existing = Set(currentIDs)
            let order = drag.sectionOrder.filter { existing.contains($0) }
            guard order != currentIDs, let index = order.firstIndex(of: id) else { return }
            let destination: SectionedListMove<SectionID>.Destination = index + 1 < order.count ? .before(order[index + 1]) : .end
            request(.section(.init(sources: [id], destination: destination)))
        case let .row(fromSection, rowID):
            guard let target = drag.rowTarget,
                  let section = sections.first(where: { $0.id == target.sectionID }) else { return }
            let rows = items(section)
            if section.id == fromSection, rows.firstIndex(where: { $0.id == rowID }) == target.index { return }
            let remaining = rows.filter { section.id != fromSection || $0.id != rowID }
            // The destination is the next row that can move; rows that can't are never destinations.
            let before = remaining[min(target.index, remaining.count)...].first(where: canMoveRow)
            let destination: SectionedListRowMove<SectionID, RowID>.Destination = before.map { .before($0.id) } ?? .end
            request(.row(.init(row: rowID, fromSection: fromSection, toSection: section.id, destination: destination)))
        }
    }

    // MARK: Consistency with the caller's data

    /// How long the list keeps showing a requested move that the caller's data hasn't caught up with.
    private static var pendingDuration: Duration { .seconds(3) }

    /// Sends a move to the caller and keeps showing its result until the caller's data shows it.
    ///
    /// The caller saves asynchronously, so its data still has the old order for a moment after a drop.
    /// Showing that data would make the moved item jump back and then forward again. This is the role
    /// of `NSFetchedResultsController`'s user-driven-update flag: the change the person made isn't
    /// applied a second time when the data reports it. If the data never shows the move, because the
    /// save failed or was refused, the list returns to the data after ``pendingDuration``.
    /// The data is checked in ``dataChanged()``, when this view next receives the caller's data.
    private func request(_ move: SectionedListPendingMove<SectionID, RowID>) {
        pending = move
        switch move {
        case let .section(move): sectionMoveRequested?(move)
        case let .row(move): rowMoveRequested?(move)
        }
        pendingTimeout?.cancel()
        pendingTimeout = Task { @MainActor in
            try? await Task.sleep(for: Self.pendingDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.25)) { pending = nil }
        }
    }

    /// The caller's sections, with a pending section move applied.
    private var arrangedSections: [SectionModel] {
        if case let .section(move)? = pending, let reordered = move.reordered(sections) {
            return reordered
        }
        return sections
    }

    /// The caller's rows for a section, with a pending row move applied.
    private func displayedRows(of section: SectionModel) -> [Item] {
        let current = items(section)
        guard case let .row(move)? = pending,
              section.id == move.fromSection || section.id == move.toSection else { return current }
        if section.id == move.fromSection, move.fromSection != move.toSection {
            return current.filter { $0.id != move.row }
        }
        let source = sections.first(where: { $0.id == move.fromSection }).map(items) ?? []
        guard let moved = (source + current).first(where: { $0.id == move.row }) else { return current }
        var rows = current.filter { $0.id != move.row }
        switch move.destination {
        case let .before(id):
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return current }
            rows.insert(moved, at: index)
        case .end:
            rows.append(moved)
        }
        return rows
    }

    /// The IDs in the caller's data, to notice when it changes.
    private var dataSnapshot: SectionedListSnapshot<SectionID, RowID> {
        SectionedListSnapshot(sectionIDs: sections.map(\.id), rowIDs: sections.map { items($0).map(\.id) })
    }

    private func dataChanged() {
        if let pending, isShown(pending) {
            pendingTimeout?.cancel()
            pendingTimeout = nil
            self.pending = nil
        }
        // The dragged item was deleted, or moved by someone else: there's nothing left to drop.
        if drag != nil, !draggedItemExists {
            withAnimation(.snappy(duration: 0.25)) { drag = nil }
        }
    }

    /// Whether the caller's data already shows a pending move, or can no longer show it.
    private func isShown(_ pending: SectionedListPendingMove<SectionID, RowID>) -> Bool {
        switch pending {
        case let .section(move):
            // Nil when the move is already in place, or names a section that's gone.
            return move.reordered(sections) == nil
        case let .row(move):
            guard let target = sections.first(where: { $0.id == move.toSection }) else { return true }
            let targetIDs = items(target).map(\.id)
            let inSource = sections.first(where: { $0.id == move.fromSection })
                .map { items($0).contains { $0.id == move.row } } ?? false
            let inTarget = targetIDs.contains(move.row)
            if !inSource && !inTarget { return true }
            if move.fromSection != move.toSection && inSource { return false }
            // Nil when the row is already in place, or its destination row is gone.
            return move.reordered(targetIDs) == nil
        }
    }

    private var draggedItemExists: Bool {
        switch drag?.item {
        case nil:
            return true
        case let .section(id):
            return sections.contains { $0.id == id }
        case let .row(sectionID, rowID):
            return sections.first(where: { $0.id == sectionID }).map { items($0).contains { $0.id == rowID } } ?? false
        }
    }

    // MARK: Targets

    private func updateTarget(_ drag: inout SectionedListDrag<SectionID, RowID>) {
        switch drag.item {
        case let .section(id):
            updateSectionTarget(&drag, id: id)
        case let .row(fromSection, rowID):
            updateRowTarget(&drag, fromSection: fromSection, rowID: rowID)
        }
    }

    /// Swaps the dragged section with a neighbor once the finger passes the middle of that neighbor.
    private func updateSectionTarget(_ drag: inout SectionedListDrag<SectionID, RowID>, id: SectionID) {
        let rendered = drag.sectionOrder
        guard let index = rendered.firstIndex(of: id) else { return }
        let y = drag.finger.y
        var order = rendered
        if index > 0, let middle = blockMiddle(of: rendered[index - 1], in: rendered), y < middle {
            order.swapAt(index, index - 1)
        } else if index + 1 < rendered.count, let middle = blockMiddle(of: rendered[index + 1], in: rendered), y > middle {
            order.swapAt(index, index + 1)
        }
        if order != rendered {
            drag.sectionOrder = order
            targetCount += 1
        }
    }

    /// The middle of a section's block (header and rows), from the frames of the last layout.
    private func blockMiddle(of id: SectionID, in order: [SectionID]) -> CGFloat? {
        guard let bottom = geometry.bottoms[id], let index = order.firstIndex(of: id) else { return nil }
        let top: CGFloat
        if index == 0 {
            top = 0
        } else if let previousBottom = geometry.bottoms[order[index - 1]] {
            top = previousBottom
        } else {
            return nil
        }
        return (top + bottom) / 2
    }

    private func updateRowTarget(_ drag: inout SectionedListDrag<SectionID, RowID>, fromSection: SectionID, rowID: RowID) {
        let y = drag.finger.y
        let shown = displaySections
        // The section under the finger: the first whose content ends below it.
        guard let section = shown.first(where: { (geometry.bottoms[$0.id] ?? -.infinity) > y }) ?? shown.last else { return }
        let rows = items(section).filter { section.id != fromSection || $0.id != rowID }
        let index: Int
        if !showsRows(of: section) {
            index = rows.count
        } else if let firstBelow = rows.firstIndex(where: { row in
            guard let frame = geometry.rows[.init(sectionID: section.id, rowID: row.id)] else { return false }
            return frame.midY >= y
        }) {
            index = firstBelow
        } else if let lastKnown = rows.lastIndex(where: { geometry.rows[.init(sectionID: section.id, rowID: $0.id)] != nil }) {
            index = lastKnown + 1
        } else {
            index = 0
        }
        let target = SectionedListDrag<SectionID, RowID>.RowTarget(sectionID: section.id, index: index)
        if target != drag.rowTarget {
            drag.rowTarget = target
            targetCount += 1
        }
    }

    // MARK: Row slots

    private enum RowSlot: Identifiable {
        case item(SectionID, Item)
        case placeholder(CGFloat)

        enum ID: Hashable {
            case row(SectionedListRowKey<SectionID, RowID>)
            case placeholder
        }

        /// Keyed by section as well as row: the lazy stack gives every header and every section's
        /// rows one ID space, so a bare row ID could repeat a section ID or a row in another section.
        var id: ID {
            switch self {
            case let .item(sectionID, item): .row(.init(sectionID: sectionID, rowID: item.id))
            case .placeholder: .placeholder
            }
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

// MARK: - Drag model

private enum SectionedListSpace {
    static let content = "SectionedList.content"
}

/// A move the list asked the caller to save, kept on screen until the caller's data shows it.
private enum SectionedListPendingMove<SectionID: Hashable & Sendable, RowID: Hashable & Sendable>: Equatable {
    case section(SectionedListMove<SectionID>)
    case row(SectionedListRowMove<SectionID, RowID>)
}

/// The IDs in the caller's data, compared to notice changes.
private struct SectionedListSnapshot<SectionID: Hashable, RowID: Hashable>: Equatable {
    var sectionIDs: [SectionID]
    var rowIDs: [[RowID]]
}

private struct SectionedListRowKey<SectionID: Hashable, RowID: Hashable>: Hashable {
    let sectionID: SectionID
    let rowID: RowID
}

private struct SectionedListDrag<SectionID: Hashable, RowID: Hashable>: Equatable {
    enum Item: Equatable {
        case section(SectionID)
        /// A row and the section it was lifted from.
        case row(SectionID, RowID)
    }

    struct RowTarget: Equatable {
        var sectionID: SectionID
        /// The position among the target section's rows, not counting the dragged row.
        var index: Int
    }

    var item: Item
    /// The finger in the list's own coordinates.
    var finger: CGPoint
    /// Where the finger grabbed the lifted view, from its top-leading corner.
    var grabOffset: CGPoint
    var size: CGSize
    /// Section order shown during a section drag, with the dragged section at its target.
    var sectionOrder: [SectionID]
    /// Where a dragged row would land.
    var rowTarget: RowTarget?
}

/// Frames of realized views, kept outside SwiftUI state so scrolling doesn't redraw the list.
private final class SectionedListGeometry<SectionID: Hashable, RowID: Hashable> {
    var headers: [SectionID: CGRect] = [:]
    var rows: [SectionedListRowKey<SectionID, RowID>: CGRect] = [:]
    /// The bottom of each section's content, in the list's coordinates.
    var bottoms: [SectionID: CGFloat] = [:]
}

// MARK: - Building blocks

private struct SectionedListHeader<Content: View>: View {
    let label: String
    let isExpanded: Bool
    let hasVisibleRows: Bool
    let isDragging: Bool
    /// Marks the header as the drop target of a row whose section is collapsed.
    let isHighlighted: Bool
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
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : appearance.contentBackgroundColor)
        .clipShape(shape)
        // Fills the rounded corners so rows scrolling under a pinned header stay hidden.
        .background(appearance.backgroundColor)
        .contentShape(.interaction, Rectangle())
        .accessibilityElement(children: .contain)
    }
}

/// The dashed outline marking where a dragged section or row will land.
private struct SectionedListPlaceholderOutline: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [5]))
            .accessibilityHidden(true)
    }
}
