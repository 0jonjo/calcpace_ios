import Foundation

/// The rules of one sync, the Android app's HcSyncPlan:
///
/// - With no anchor, the sync is the initial read of the last 30 days; with
///   one, it asks Apple Health what changed since.
/// - Before those 30 days, the history: runs only, back to `historyYears`,
///   a window of `historyStepDays` at a time, newest first, at most
///   `historyStepsPerSync` windows a sync. Each window is remembered once the
///   server took it, so a long history arrives over a few syncs and never
///   starts over. Only with the app on screen (a locked phone reads no
///   distance or route, and a window read that way would be lost), and at
///   most once per `historyPause`: opening the app starts a few syncs at
///   once, and the server takes 30 requests in 10 minutes from a link.
/// - The anchor only moves on once the server has answered every request of
///   the sync (`.advance`); otherwise the same changes are read and sent
///   again next time, which the server takes idempotently.
enum SyncPlan {
    enum After: Equatable {
        case advance
        case retry
        case unlink
    }

    /// No answer at all (the network).
    static let noAnswer = -1

    static let initialDays = 30
    static let historyYears = 3
    static let historyStepDays = 90
    static let historyStepsPerSync = 4
    static let historyPause: TimeInterval = 10 * 60

    /// How far back the history read has come (`edge`: the start of the
    /// last window the server took) and where it stops (`floor`).
    struct History: Equatable {
        let edge: Date
        let floor: Date
    }

    /// What an HTTP answer means for the anchor.
    static func after(_ status: Int) -> After {
        switch status {
        case 200 ... 299: return .advance
        // The link is gone (signed out, disconnected on the account page).
        case 401: return .unlink
        // Our own payload refused, or an account without a profile: sending
        // it again would loop for ever. The server is the judge; move on.
        case 400, 409, 413, 422: return .advance
        // 429, 5xx, a redirect, no answer: later.
        default: return .retry
        }
    }

    /// The answers of one sync's requests, sent in order until one isn't `.advance`.
    static func overall(_ afters: [After]) -> After {
        afters.first { $0 != .advance } ?? .advance
    }

    /// Where the initial read starts.
    static func initialStart(now: Date) -> Date {
        now.addingTimeInterval(-Double(initialDays) * day)
    }

    /// What an HTTP answer means for a history window: as `after`, except
    /// that an account without a profile yet (409) keeps the window for
    /// later instead of losing years of runs.
    static func historyAfter(_ status: Int) -> After {
        status == 409 ? .retry : after(status)
    }

    /// Whether a history pass may start, the last one having started at `last`.
    static func historyDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= historyPause || now < last
    }

    /// The history of a link whose initial read started at `start`.
    static func history(from start: Date) -> History {
        History(edge: start, floor: start.addingTimeInterval(-Double(historyYears) * 365 * day))
    }

    /// The next window to read, the one just before `edge`; nil once at the floor.
    static func historyWindow(_ history: History) -> DateInterval? {
        guard history.edge > history.floor else { return nil }
        let start = max(history.edge.addingTimeInterval(-Double(historyStepDays) * day), history.floor)
        return DateInterval(start: start, end: history.edge)
    }

    private static let day: TimeInterval = 24 * 60 * 60
}
