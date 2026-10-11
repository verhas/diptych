import Foundation

/// A pane's rows as the user put them with Shift-Command-Up and -Down.
///
/// Kept in memory only, and only for the listing it was made in: clicking a
/// column header sorts again, and leaving the folder forgets it. What is in it
/// is the order of the rows after the last move, and which rows were moved --
/// the rows that were not still say where the sort would put a new file.
nonisolated struct ManualOrder<ID: Hashable>: Equatable {
    var order: [ID]
    var moved: Set<ID> = []

    /// The ids of `sorted` -- the listing as its columns sort it -- in this
    /// order. Rows that are gone are left out. A new row goes after the last
    /// row the sort puts before it that was not moved, and after any new rows
    /// that went there and sort before it; with no such row, before the first
    /// unmoved row the sort puts after it; with neither, at the end.
    func arrange(_ sorted: [ID]) -> [ID] {
        let present = Set(sorted)
        let kept = order.filter(present.contains)
        let known = Set(kept)
        guard known.count < sorted.count else { return kept }

        // An anchor is a row that was there before and was not moved. One
        // pass in sort order: a new row goes with the last anchor before it,
        // so new rows by one anchor keep the sort's order. New rows with no
        // anchor before them all come before the first anchor there is.
        var after: [ID: [ID]] = [:]
        var leading: [ID] = []
        var first: ID?
        var last: ID?
        for id in sorted {
            if !known.contains(id) {
                if let last { after[last, default: []].append(id) } else { leading.append(id) }
            } else if !moved.contains(id) {
                last = id
                if first == nil { first = id }
            }
        }
        guard let first else { return kept + leading }
        let before: [ID: [ID]] = [first: leading]
        var result: [ID] = []
        result.reserveCapacity(sorted.count)
        for id in kept {
            result += before[id] ?? []
            result.append(id)
            result += after[id] ?? []
        }
        return result
    }
}
