import Foundation

/// Talks to the site with the link token as a bearer (no cookie, no CSRF):
/// POST /health_connect/sessions. Answers with the HTTP status, or
/// `SyncPlan.noAnswer` when the network failed. Never logs the token or what
/// is sent. Redirects are not followed: the server never sends one, and a
/// bearer must not travel to wherever a redirect points.
final class HealthUploader {
    private let session: URLSession
    private let baseURL: URL

    init(configuration: URLSessionConfiguration = .ephemeral, baseURL: URL = AppDelegate.rootURL) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        self.baseURL = baseURL
    }

    func send(_ upload: Upload, token: String) async -> Int {
        guard let body = HealthPayload.encode(upload) else { return 400 }

        var request = URLRequest(url: baseURL.appendingPathComponent("health_connect/sessions"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppUserAgent.prefix()) (Apple Health)", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? SyncPlan.noAnswer
        } catch {
            return SyncPlan.noAnswer
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
