# SectionedListUI

A SwiftUI list of sections whose headers stay pinned while scrolling and can be swiped. Long-press a
header or a row and drag it to a new place: sections reorder, and rows move within a section or into
another one.

- iOS 27 or later, Swift 6.2 tools. No package dependencies.
- The app owns the data, the order and the collapsed sections. The list reports requests and never
  changes app data.
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
| `SectionedListState<ID>` | Collapsed sections. Keep it in the feature's state. |
| `SectionedListMove<ID>` | A requested section move: the moved section and a destination (`.before(id)` or `.end`). `reordered(_:)` applies it to an array. |
| `SectionedListRowMove<SectionID, RowID>` | A requested row move: the row, its section, the target section and a destination there. `reordered(_:)` returns the target section's new row order. |
| `SectionedListAppearance` | `.groupedCards` or `.plain`. |

## TCA integration

```swift
@ObservableState struct State {
    var sectionList = SectionedListState<Group.ID>()
    @FetchAll(Group.order(by: \.position)) var groups
}
enum Action {
    case sectionDisclosureTapped(Group.ID)
    case sectionMoveRequested(SectionedListMove<Group.ID>)
    case rowMoveRequested(SectionedListRowMove<Group.ID, Item.ID>)
}

case let .sectionDisclosureTapped(id):
    state.sectionList.toggleExpansion(of: id)
    return .none
case let .sectionMoveRequested(move):
    guard let groups = move.reordered(state.groups) else { return .none }
    return .run { _ in /* save groups.map(\.id) as the new order */ }
case let .rowMoveRequested(move):
    guard let order = move.reordered(/* the target section's row IDs, in order */) else { return .none }
    return .run { _ in /* in one write: move the row to move.toSection if it changed, then save order */ }
```

```swift
ScrollView {
    SectionedList(
        sections: store.groups,
        items: { $0.items },
        state: store.sectionList,
        sectionLabel: { $0.title },
        disclosureRequested: { store.send(.sectionDisclosureTapped($0)) },
        sectionMoveRequested: store.isFiltering ? nil : { store.send(.sectionMoveRequested($0)) },
        rowMoveRequested: store.isFiltering ? nil : { store.send(.rowMoveRequested($0)) }
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

ListFox's `SLFSectionedListDemoView` is a complete in-memory example, and its Home screen
(`SLFRootView`) is a database-backed one.

- Apply moves only from the move handlers, and save them in one write. A cross-section row move changes
  both the row's section and the target section's order.
- Don't edit the visible order after saving; let the database observation deliver the new order.
- Pass `nil` for a move handler whenever the shown sections or rows aren't the complete order (while
  searching or filtering), so a drop can't be computed against a partial list.

## Options

- **Collapsing.** Sections have a chevron only when `disclosureRequested` is supplied; otherwise all
  sections are expanded. State stores collapsed IDs, so sections added later start expanded.
- **Dragging.** Supply `sectionMoveRequested`, `rowMoveRequested`, or both. `canMoveRow` keeps rows such
  as an empty-section message in place; they're never used as a destination either.
- **Swipe actions.** Leading and trailing builders per header; return `EmptyView()` for an unused edge.
  Full swipe is off by default on each edge. Rows can carry their own `.swipeActions` inside `row`.
- **Rows.** Rows are padded by `rowInsets`. Pass `EdgeInsets()` when a row has its own swipe actions,
  so the row pads itself inside the swipeable area.
- **Scrolling to content.** Rows are direct children of the lazy stack, so an `.id(_:)` applied inside
  `row` is a `ScrollViewReader` target. Apply `.id(_:)` inside header content, never around the header.
- **Other content.** The host `ScrollView` can hold other views above or below the list.

## How dragging works

The list doesn't use the system's drag and drop or `reorderable()`. Those can't reorder pinned section
headers with live feedback, and a draggable section swallows long presses on its rows.

- **One long press, on the scroll view.** The list installs a UIKit long-press recognizer on the UIKit
  scroll view behind the SwiftUI `ScrollView`. It takes part only in touches that start on a header or
  row that can be dragged, found from frames the list records for each header and row.
- **Precedence.** For those touches, every other gesture waits for the long press to fail, except the
  scroll view's own pan and pinch. A quick tap still reaches a button, and moving first still scrolls
  or swipes. Holding still for 0.35 s lifts the item and cancels the button press. SwiftUI's own
  `.gesture` can't express this: a button claims its touch as soon as it lands.
- **While dragging.** The lifted header or row floats under the finger. Its place becomes a dashed gap
  that moves as neighbors slide apart. A dragged section collapses. Rows can go into empty sections and
  into collapsed ones, whose header highlights; they land at the end. The list can't scroll under the
  finger, and it auto-scrolls near the top and bottom edges. Haptics mark the lift and each new slot.
- **On release.** The list reports one move request, or nothing if the item lands where it started.

## Manual checks

Compiling proves nothing about gestures. On a device:

1. Scroll until a header pins. Rows must not show through its rounded corners. Invoke its leading and
   trailing swipe actions, with and without full swipe.
2. Tap rows and header buttons: they must respond. Scroll and swipe starting on a row: they must start
   without a delay.
3. Long-press a header: it lifts and collapses, and other sections slide apart. Drop it between
   sections, first, last, and below the last section.
4. Long-press a row: only the row lifts, and its button doesn't fire on release. Move it within its
   section, into another section, into an empty section, and onto a collapsed section's header.
5. Drag near the top and bottom edges: the list auto-scrolls. Drop after scrolling far.
6. Check VoiceOver (disclosure, header content, Move up/down on headers and rows, swipe actions), large
   text, and both appearances in light and dark mode.

## Known limitations

- The drop target is worked out from headers and rows currently on screen.
- The lifted item is a live copy of the header or row, so any `.id` or preference inside it appears
  twice during a drag.
- A button's pressed highlight appears a moment later, because the button waits to see whether the
  person is holding. A back swipe that starts on a row begins after a few points of movement.
- VoiceOver moves rows only within their section.
- VoiceOver text ("Move up", "Expanded", …) is English only.
- Dragging relies on SwiftUI's `ScrollView` being backed by a UIKit scroll view, and on how SwiftUI's
  button gestures interact with UIKit recognizers. Recheck it on each new iOS release.
