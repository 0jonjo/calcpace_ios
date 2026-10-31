import Foundation

/// The rules of one sync, the Android app's HcSyncPlan:
///
/// - With no anchor, the sync is the initial read of the last 30 days; with
///   one, it asks Apple Health what changed since.
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
        now.addingTimeInterval(-Double(initialDays) * 24 * 60 * 60)
    }
}
