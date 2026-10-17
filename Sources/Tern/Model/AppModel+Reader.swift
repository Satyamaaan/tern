import Foundation
import TernCore

// What the reader needs from the list: the open thread's neighbours to prefetch, and its place in the
// list for the "12 of 48" control.
extension AppModel {
    /// The rows after and before the open thread, nearest first.
    var readerNeighbours: [ThreadKey] {
        guard let key = readerKey, let index = snapshot.position[key] else { return [] }
        let order = snapshot.order
        return [index + 1, index - 1, index + 2].filter(order.indices.contains).map { order[$0] }
    }

    var readerPosition: ReaderPosition? {
        guard let key = readerKey, let index = snapshot.position[key] else { return nil }
        let total = snapshot.order.count
        return ReaderPosition(
            index: index + 1, total: total,
            previous: index > 0 ? { [weak self] in self?.step(-1) } : nil,
            next: index + 1 < total ? { [weak self] in self?.step(1) } : nil)
    }

    /// Opens the next or previous thread from the reader's ‹ › buttons, reading it at once.
    func step(_ offset: Int) {
        guard let next = snapshot.key(from: cursor, offset: offset), next != cursor else { return }
        checked = []
        setCursor(next, open: true)
    }
}
