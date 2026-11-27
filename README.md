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
.package(url: "https://github.com/reversecamber/SLFStickyDisclosure", exact: "0.2.0"),
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

## Staying consistent with SQLiteData

The package assumes the data comes from a SQLite database managed by SQLiteData, saved asynchronously
and observed with `@Fetch`/`@FetchAll`. It has no dependency on SQLiteData; the app follows these rules.

**Why there's no "Invalid update: invalid number of rows in section".** That exception comes from
`UITableView`/`UICollectionView` batch updates, where index-based inserts and deletes must add up to the
data source's new counts. `NSFetchedResultsController` kept them in step by reporting a batch of changes
between `controllerWillChangeContent` and `controllerDidChangeContent` (wrapped in
`beginUpdates`/`endUpdates`), while the data source read from the controller itself; since iOS 13 it can
deliver a diffable snapshot instead. This list has no index-based updates: SwiftUI compares whole
snapshots by ID. Its equivalent rule is that IDs are unique and stable, which the list enforces for rows
by keying them by section.

The remaining risks, and who handles each:

| Risk | `NSFetchedResultsController` equivalent | Handled by |
|---|---|---|
| A new result replaces the old one in the middle of main-thread work | Changes reported on the context's queue, once per `processPendingChanges()` | The app: observe on the main queue (below) |
| The person's own move jumps back until the save lands, or is applied twice | The user-driven-update flag | The list |
| A save computed from an older snapshot conflicts with changes saved since, such as an iCloud sync | Not applicable: edits went to the context directly | The app: save the intent (below) |
| The dragged item is deleted or moved while it's lifted | Not applicable | The list |

**1. Observe on the main queue.** By default, SQLiteData hands each new result over on GRDB's background
queue, where Sharing stores it at once and notifies the main thread later. Two reads of the same fetched
value in one reducer pass or view update can then see different data. Load with a main-queue scheduler
so a new result lands only between pieces of main-thread work. GRDB's schedulers aren't `Hashable`,
which `load(_:scheduler:)` requires, so define one:

```swift
struct MainQueueScheduler: ValueObservationScheduler, Hashable {
    func immediateInitialValue() -> Bool { false }
    func schedule(_ action: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: action)
    }
}

try await $groups.load(Group.order(by: \.position), scheduler: MainQueueScheduler())
```

Loading with an `animation:` also delivers on the main queue. GRDB still coalesces: when several
transactions commit quickly, you may get only the last result. That's fine for display, because each
result is complete.

**2. Save the intent, not the order.** Send "move X before Y" (or "to the end") to the database and work
out the new order inside the write transaction, from the rows as they are then. A full order computed
from the snapshot at drop time can be stale by the time the write runs. If Y no longer exists, place X
at the end. One move is one write transaction.

```swift
try await database.write { db in
    var ids = try Group.order(by: \.position).select(\.id).fetchAll(db).filter { $0 != movedID }
    if let beforeID, let index = ids.firstIndex(of: beforeID) { ids.insert(movedID, at: index) }
    else { ids.append(movedID) }
    for (position, id) in ids.enumerated() {
        try Group.find(id).update { $0.position = position }.execute(db)
    }
}
```

**3. What the list does.**
- After a drop or a VoiceOver move, the list keeps showing the moved arrangement, applied on top of the
  latest data, until the data shows the move. It then shows the data again with no visible change. If the
  data doesn't show the move within 3 seconds, because the save failed or the app refused it, the list
  returns to the data. No new drag can start meanwhile.
- If the dragged item disappears from the data during a drag, the drag is cancelled. A drop is worked out
  from the data current at that moment, skipping sections that disappeared.
- Changes arriving during a drag, such as a sync, update the list underneath the lifted item.

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
- **On release.** The list reports one move request, or nothing if the item lands where it started, and
  keeps showing the result until the app's data catches up (see "Staying consistent with SQLiteData").

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
6. After a drop, the item must stay where it was dropped while the save runs: no jump back and forward.
   Make the app refuse a save, and the item must return to its old place after about 3 seconds.
7. Delete or move the lifted item from another device while dragging (with iCloud sync on): the drag
   must cancel without a crash.
8. Check VoiceOver (disclosure, header content, Move up/down on headers and rows, swipe actions), large
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
