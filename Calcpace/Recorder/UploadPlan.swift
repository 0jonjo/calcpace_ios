import Foundation

/// What each answer of the site's POST /recordings means for a run in the
/// `Outbox` (calcpace_web's RecorderUploadsController says the same from its
/// side). The Android app's UploadPlan.kt.
enum UploadPlan {
    /// No answer at all: no network, a timeout, a dropped connection.
    static let noAnswer = -1

    enum Outcome: Equatable {
        /// 201 logged, 200 already logged: the phone's copy can go.
        case done
        /// 401: kept; sign in again and it goes.
        case signedOut
        /// 409: kept; the account needs its profile first.
        case noProfile
        /// Never going to work as it is (422, 413, other 4xx): kept, to be
        /// shared by hand or tried again by a tap.
        case refused
        /// Later: no network, 403, 429, 5xx, a redirect from something in between.
        case retry
    }

    static func outcome(_ code: Int) -> Outcome {
        switch code {
        case 200 ... 299: return .done
        case 401: return .signedOut
        case 409: return .noProfile
        // 403 is the site's "no app header" or something in between (a
        // Cloudflare challenge): neither is this file's fault. 404 is a site
        // without the endpoint yet, 408 a slow upload, 429 too many: all pass.
        case 403, 404, 408, 429: return .retry
        case 400 ... 499: return .refused
        default: return .retry
        }
    }

    /// What the recording screen says about a run still in the outbox.
    enum Card: Equatable { case sending, queued, failed, signedOut, noProfile, refused }

    /// `sending`: the upload is posting this run now. `online`: the phone has
    /// a network. A pending run never tried yet is on its way, so "sending"
    /// until an attempt says otherwise.
    static func card(_ state: Outbox.State, sending: Bool, online: Bool, attempted: Bool) -> Card {
        switch state {
        case .signedOut: return .signedOut
        case .noProfile: return .noProfile
        case .refused: return .refused
        case .pending:
            if sending { return .sending }
            if !online { return .queued }
            return attempted ? .failed : .sending
        }
    }

    struct Answer: Equatable {
        let id: Int64
        let editURL: String
    }

    /// The 2xx's `{ id, edit_url }`, or nil when it is not that.
    static func answer(_ body: Data) -> Answer? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let number = json["id"] as? NSNumber, let id = Int64(exactly: number.doubleValue),
              let url = json["edit_url"] as? String
        else { return nil }
        // A JSON true is an NSNumber too ("c", a char): only a whole number is an id.
        if String(cString: number.objCType) == "c" { return nil }
        return Answer(id: id, editURL: url)
    }

    /// Start as the site wants it: ISO 8601 to the second, with the phone's
    /// offset at that instant ("2026-10-18T07:11:03-03:00", "…Z" at UTC).
    static func startedAt(_ epochMillis: Int64, utcOffsetSeconds: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? TimeZone(identifier: "UTC")
        let seconds = epochMillis >= 0 ? epochMillis / 1000 : (epochMillis - 999) / 1000
        return formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
    }
}
