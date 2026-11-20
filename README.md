# SectionedListUI

A SwiftUI list of sections whose headers stay pinned while scrolling, can be swiped, and can be
dragged to reorder. It also provides the interaction logic: collapsing sections, tracking a drag,
and turning a drop into a new section order.

- iOS 27 or later, Swift 6.2 tools. No package dependencies.
- The app owns the data, the order and the state. The list reports events and never changes app data.
- Works with TCA or plain SwiftUI. Nothing here imports TCA.

## Add it to an app

```swift
.package(url: "https://github.com/reversecamber/SLFStickyDisclosure", exact: "0.1.0"),
...
.product(name: "SectionedListUI", package: "SLFStickyDisclosure"),
```

The repository is named SLFStickyDisclosure, so that is the `package:` name. The library and module are
named SectionedListUI, so code uses `import SectionedListUI`.

Public types are named `SectionedList…` without an app prefix. The module name scopes them, so apps
adopting the package treat it as exempt from their own `AppPrefix.md` rule.

## The pieces

| Type | Role |
|---|---|
| `SectionedList` | The view. Place it inside a vertical `ScrollView`. |
| `sectionedListContainer(appearance:)` | Apply to that `ScrollView`. Enables header swipe actions (`swipeActionsContainer()`), and sets the page background and side margins. |
| `SectionedListState<ID>` | Collapsed sections and the active drag. Keep it in the feature's state. |
| `SectionedListMove<ID>` | A requested move: source section IDs and a destination (`.before(id)` or `.end`). `reordered(_:)` applies it to an array. |
| `SectionedListDragEvent<ID>` | `.began(ids)` or `.ended`. |
| `SectionedListAppearance` | `.groupedCards` or `.plain`. |

## TCA integration

```swift
@ObservableState struct State {
    var sectionList = SectionedListState<Group.ID>()
    @FetchAll(Group.order(by: \.position)) var groups
}
enum Action {
    case sectionDisclosureTapped(Group.ID)
    case sectionDragChanged(SectionedListDragEvent<Group.ID>)
    case sectionMoveRequested(SectionedListMove<Group.ID>)
}

case let .sectionDisclosureTapped(id):
    state.sectionList.toggleExpansion(of: id)
    return .none
case let .sectionDragChanged(event):
    state.sectionList.handleDrag(event)
    return .none
case let .sectionMoveRequested(move):
    guard let groups = state.sectionList.handleMove(move, sections: state.groups) else { return .none }
    return .run { _ in /* save groups.map(\.id) as the new order */ }
```

```swift
ScrollView {
    SectionedList(
        sections: store.groups,
        items: { $0.items },
        state: store.sectionList,
        isReorderEnabled: !store.isFiltering,
        sectionLabel: { $0.title },
        disclosureRequested: { store.send(.sectionDisclosureTapped($0)) },
        dragChanged: { store.send(.sectionDragChanged($0)) },
        moveRequested: { store.send(.sectionMoveRequested($0)) }
    ) { group in
        GroupHeader(group: group)
    } row: { item in
        ItemRow(item: item)
    } leadingActions: { group in
        Button("Rename", systemImage: "pencil") { store.send(.renameSwiped(group.id)) }
    } trailingActions: { group in
        EmptyView()
    }
}
.sectionedListContainer()
```

ListFox's `SLFSectionedListDemoView` is a complete in-memory example.

Rules the state type already follows, which a hand-written reducer must also follow:

- Apply order changes only from a move. The end of a drag is not an accepted move.
- The drop and the end of the drag arrive separately, in no guaranteed order. A move also ends the drag.
- Ignore collapse taps while dragging.
- Moved sections keep their current relative order. Reject moves naming unknown or repeated IDs.
- Don't edit the visible order after saving; let the database observation deliver the new order.

## Options

- **Collapsing.** Sections have a chevron only when `disclosureRequested` is supplied; otherwise all
  sections are expanded. State stores collapsed IDs, so sections added later start expanded.
- **Reordering.** `isReorderEnabled: false` turns off header dragging and the VoiceOver move actions.
  Turn it off whenever the sections shown are not the complete order, such as while filtering.
- **Swipe actions.** Leading and trailing builders per header; return `EmptyView()` for an unused edge.
  Full swipe is off by default on each edge.
- **Rows.** Rows are padded by `rowInsets`. Pass `EdgeInsets()` when a row has its own swipe actions,
  so the row pads itself inside the swipeable area.
- **Scrolling to content.** Rows are direct children of the lazy stack, so an `.id(_:)` applied inside
  `row` is a `ScrollViewReader` target. Apply `.id(_:)` inside header content, never around the
  header: an `.id` on the reorderable header container has crashed drag starts on iOS 27.0.1.
- **Other content.** The host `ScrollView` can hold other views above or below the list.

## How it works

The view is a lazy stack with pinned section headers. Each header sits in its own one-element
`ForEach` marked `.reorderable()`, and all of them share one `reorderContainer`. That keeps the header
present with the same identity while its rows are hidden. Rows are not reorderable.

While a drag is active, every section's rows are hidden, so the person drags short headers past each
other. Drag start and end come from `onDragSessionUpdated`. The move-up and move-down accessibility
actions send the same `SectionedListMove` as a drop.

## Manual checks

Compiling proves nothing about gestures. On a device, ideally a Release build (the Xcode preview canvas
is not representative of drag smoothness):

1. Scroll until a header pins. Rows must not show through its rounded corners. Invoke its leading and
   trailing swipe actions, with and without full swipe.
2. Collapse some sections, drag a header, and confirm all rows disappear and the header follows the finger.
3. Drop before another section and at the end; check the new order and that collapsed sections stay
   collapsed. Repeat with the first, last and an empty section.
4. Start a drag while scrolled deep into a long section; check how far the content jumps.
5. Cancel a drag or release outside the list; the order must not change and rows must come back.
6. With `isReorderEnabled: false`, headers must not lift and the VoiceOver move actions must be gone.
7. Check VoiceOver (disclosure, header content, move actions, swipe actions), large text, Reduce
   Motion, and both appearances in light and dark mode.

## Known limitations

- Rows can't be reordered.
- VoiceOver text ("Move up", "Expanded", …) is English only.
- Unverified on device: that one-element `ForEach`s in a shared reorder container behave as one list;
  that `onDragSessionUpdated` reports reorder drags (if it reports a start but no end, rows stay
  hidden until the next drop); that swiping and long-press dragging coexist on a header; and that the
  drag preview uses the rounded header shape.
