import Foundation

/// One entry of "sessions" in POST /health_connect/sessions. Nil fields are
/// left out of the JSON.
struct WireSession: Encodable, Equatable {
    let id: String
    let type: String
    let start: String
    let end: String
    var zoneOffset: Int? = nil
    let origin: String
    var device: String? = nil
    let distanceM: Double
    let durationS: Int
    var hrAvg: Int? = nil
    var hrMax: Int? = nil
    var elevationGainM: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, type, start, end, origin, device
        case zoneOffset = "zone_offset"
        case distanceM = "distance_m"
        case durationS = "duration_s"
        case hrAvg = "hr_avg"
        case hrMax = "hr_max"
        case elevationGainM = "elevation_gain_m"
    }
}

/// The body of one POST /health_connect/sessions.
struct Upload: Encodable, Equatable {
    let initial: Bool
    let sessions: [WireSession]
    let deleted: [String]
}

/// The wire format of POST /health_connect/sessions, the contract with
/// calcpace_web (HealthConnect::UploadsController, with an "ios" link:
/// HealthConnect::Store::IOS), and the link token the page hands over
/// through the "apple-health" bridge component. The Android app's HcPayload,
/// without steps, routes or pending sessions.
enum HealthPayload {
    static let maxSessions = 50
    static let maxDeleted = 200

    private static let linkToken = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{43}$")

    /// At most `maxSessions` sessions and `maxDeleted` ids per request.
    /// Nothing to say, no request: the anchor still moves on.
    static func batches(sessions: [WireSession], deleted: [String], initial: Bool) -> [Upload] {
        // The same workout twice: the last word wins.
        var seen = Set<String>()
        let unique = sessions.reversed().filter { seen.insert($0.id).inserted }.reversed()
        var seenDeleted = Set<String>()
        let gone = deleted.filter { seenDeleted.insert($0).inserted }

        let s = chunks(Array(unique), of: maxSessions)
        let d = chunks(gone, of: maxDeleted)
        return (0 ..< max(s.count, d.count)).map { index in
            Upload(
                initial: initial,
                sessions: index < s.count ? s[index] : [],
                deleted: index < d.count ? d[index] : []
            )
        }
    }

    static func encode(_ upload: Upload) -> Data? {
        try? JSONEncoder().encode(upload)
    }

    /// The link token: 43 base64url characters (HealthConnectLink on the server).
    static func isLinkToken(_ token: String?) -> Bool {
        guard let token else { return false }
        return linkToken.firstMatch(in: token, range: NSRange(token.startIndex ..< token.endIndex, in: token)) != nil
    }

    /// A "link" message's data, `{ "token": T, "grant": G }`.
    struct LinkRequest: Decodable {
        let token: String?
        let grant: String?
    }

    static func linkRequest(_ jsonData: String) -> LinkRequest? {
        try? JSONDecoder().decode(LinkRequest.self, from: Data(jsonData.utf8))
    }

    private static func chunks<T>(_ items: [T], of size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0 ..< min($0 + size, items.count)]) }
    }
}
