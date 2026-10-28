import HotwireNative
import UIKit
import WebKit

/// The runs list's "Export CSV" link (`CsvExport`): fetched here with the
/// WebView's session cookie, saved under the app's temporary folder with the
/// server's file name and handed to the share sheet, so the athlete can keep
/// it in Files or send it by email. The visit is always cancelled: no new
/// screen, and the list stays where it was. As in the Android app
/// (CsvExportRouteDecisionHandler.kt).
///
/// Both ways the link can be followed reach this handler: a Turbo visit
/// proposal and a plain link activation (data-turbo="false") both go through
/// the Navigator's router before any visit starts.
///
/// The fetch follows no redirect: signed out, the site answers with a
/// redirect to the sign-in page, and only a 200 that says it is text/csv is
/// shared. Anything else (that redirect, an error, no network, a file past
/// `CsvExport.maxBytes`) shows a short message and leaves the list alone.
/// One export at a time: a tap while one is on its way is ignored. Cookies
/// the response sets are not kept.
///
/// If the athlete left the app before it was ready, nothing is shown: the
/// share sheet would pop up over whatever they went to.
final class CsvExportRouteDecisionHandler: NSObject, RouteDecisionHandler, URLSessionTaskDelegate {
    let name = "csv-export"

    // Main thread only: the router calls in on it, and the export finishes there.
    private var exporting = false

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func matches(proposal: VisitProposal, configuration: Navigator.Configuration) -> Bool {
        CsvExport.isExport(proposal.url, rootURL: AppDelegate.rootURL)
    }

    func handle(proposal: VisitProposal, configuration: Navigator.Configuration, navigator: Navigating) -> Router.Decision {
        guard !exporting else { return .cancel }

        exporting = true
        let location = proposal.url
        Task { @MainActor in
            defer { exporting = false }
            let file = await download(location)
            guard UIApplication.shared.applicationState == .active,
                  let screen = navigator.activeNavigationController.visibleViewController,
                  screen.presentedViewController == nil
            else { return }

            if let file {
                present(UIActivityViewController(activityItems: [file], applicationActivities: nil), from: screen)
            } else {
                let alert = UIAlertController(title: nil, message: NSLocalizedString("export_csv_failed", comment: ""), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, from: screen)
            }
        }
        return .cancel
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: Private

    private func present(_ controller: UIViewController, from screen: UIViewController) {
        controller.popoverPresentationController?.sourceView = screen.view
        screen.present(controller, animated: true)
    }

    // The file, or nil when there is no CSV to share.
    @MainActor
    private func download(_ location: URL) async -> URL? {
        var request = URLRequest(url: location)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")
        request.setValue(Hotwire.config.userAgent, forHTTPHeaderField: "User-Agent")
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            .filter { CsvExport.cookie(for: $0.domain, isSentTo: location.host) }
        HTTPCookie.requestHeaderFields(with: cookies).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let session = session
        return await Task.detached(priority: .userInitiated) {
            await Self.fetch(request, with: session)
        }.value
    }

    private static func fetch(_ request: URLRequest, with session: URLSession) async -> URL? {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  CsvExport.isCSV(response.value(forHTTPHeaderField: "Content-Type"))
            else { return nil }

            // Reads at most one byte past the limit: a bigger file is refused
            // without being read whole.
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > CsvExport.maxBytes { return nil }
            }
            let filename = CsvExport.filename(response.value(forHTTPHeaderField: "Content-Disposition"))
            return try ShareFiles.write(data, named: filename, in: ShareFiles.exports)
        } catch {
            return nil
        }
    }
}
