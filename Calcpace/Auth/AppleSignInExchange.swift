import Foundation

/// The app's half of POST /app_auth/apple, which trades what Apple's sheet
/// gave `AppleSignIn` for the site's one-time ticket. Contract in
/// calcpace_docs plans/calcpace_ios_plan.md ("A2b — contrato"):
///
/// - Sent from the app, outside the WebView: no cookie, no CSRF token. The
///   proof is the identity token, which the site checks against Apple's
///   keys, with the challenge as its nonce.
/// - `{"identity_token", "authorization_code", "challenge"}` as JSON →
///   200 `{"ticket": "…"}`, the same ticket the other sign-ins bring back
///   (`AppAuth.redeemLocation`).
/// - Anything else (another status, a body without a good ticket, no
///   answer) sends the WebView to /app_auth/failed, which shows the site's
///   sign-in page with its error.
///
/// Everything but `send` is pure, for the tests (AppleSignInExchangeTests).
enum AppleSignInExchange {
    /// The request for the site, or nil when Apple's credential lacks a
    /// token or a code (or they aren't UTF-8), and there is nothing to send.
    static func request(identityToken: Data?, authorizationCode: Data?, challenge: String, rootURL: URL, userAgent: String) -> URLRequest? {
        guard let token = text(identityToken), let code = text(authorizationCode), !challenge.isEmpty,
              let body = try? encoder.encode(Body(identityToken: token, authorizationCode: code, challenge: challenge))
        else { return nil }

        var request = URLRequest(url: rootURL.appendingPathComponent("app_auth/apple"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        return request
    }

    /// The ticket in the site's answer: only a 200 whose JSON has a
    /// well-formed "ticket".
    static func ticket(status: Int?, body: Data?) -> String? {
        guard status == 200, let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ticket = json["ticket"] as? String,
              AppAuth.isTicket(ticket)
        else { return nil }
        return ticket
    }

    /// Where the WebView goes once the exchange is over: the redeem for a
    /// ticket (`redeem` is `AppAuth.redeemLocation`), else /app_auth/failed.
    static func destination(ticket: String?, rootURL: URL, redeem: (String) -> URL?) -> URL {
        ticket.flatMap(redeem) ?? failedLocation(rootURL: rootURL)
    }

    /// Exactly /app_auth/failed on the site, the one spelling the route
    /// handler lets through (`AppAuthPaths.isFailed`).
    static func failedLocation(rootURL: URL) -> URL {
        var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)
        components?.path = "/app_auth/failed"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? rootURL
    }

    /// Sends the request and reads the ticket out of the answer; nil for
    /// anything but a good one, a network failure included. Never logs what
    /// is sent. Redirects are not followed: the site never sends one, and
    /// the token must not travel to wherever a redirect points.
    static func send(_ request: URLRequest) async -> String? {
        do {
            let (data, response) = try await session.data(for: request)
            return ticket(status: (response as? HTTPURLResponse)?.statusCode, body: data)
        } catch {
            return nil
        }
    }

    // MARK: Private

    private static let timeout: TimeInterval = 30

    private struct Body: Encodable {
        let identityToken: String
        let authorizationCode: String
        let challenge: String

        enum CodingKeys: String, CodingKey {
            case identityToken = "identity_token"
            case authorizationCode = "authorization_code"
            case challenge
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    // Ephemeral, as HealthUploader's: no cookie goes out or is kept.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private static func text(_ data: Data?) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
