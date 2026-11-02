@testable import Calcpace
import XCTest

// POST /app_auth/apple, on the contract in calcpace_docs
// plans/calcpace_ios_plan.md ("A2b — contrato").
final class AppleSignInExchangeTests: XCTestCase {
    private let root = URL(string: "https://calcpace.app")!
    private let ticket = "t3xOHP60nCIs5golfu10UwzzY8aZSDSkcCQ7n4nnUl4"
    private let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    private let identityToken = "eyJraWQiOiJXNldjT0tCIiwiYWxnIjoiUlMyNTYifQ.eyJpc3MiOiJodHRwczovL2FwcGxlaWQuYXBwbGUuY29tIn0.c2lnbmF0dXJl"
    private let authorizationCode = "c1a2b3.0.rrsz.AbCdEf_-123"
    private let userAgent = "Calcpace iOS/1.0.0 (1); (Sign in with Apple)"

    private func request(token: Data?, code: Data?, challenge: String? = nil) -> URLRequest? {
        AppleSignInExchange.request(identityToken: token, authorizationCode: code, challenge: challenge ?? self.challenge,
                                    rootURL: root, userAgent: userAgent)
    }

    private func goodRequest() throws -> URLRequest {
        try XCTUnwrap(request(token: Data(identityToken.utf8), code: Data(authorizationCode.utf8)))
    }

    private func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    func testItPostsJsonToTheSite() throws {
        let request = try goodRequest()
        XCTAssertEqual(request.url?.absoluteString, "https://calcpace.app/app_auth/apple")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), userAgent)
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testTheBodyHasExactlyTheThreeKeys() throws {
        let body = try XCTUnwrap(try goodRequest().httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["identity_token", "authorization_code", "challenge"])
        XCTAssertEqual(object["identity_token"] as? String, identityToken)
        XCTAssertEqual(object["authorization_code"] as? String, authorizationCode)
        XCTAssertEqual(object["challenge"] as? String, challenge)
    }

    func testNothingIsSentWithoutATokenAndACode() {
        let token = Data(identityToken.utf8)
        let code = Data(authorizationCode.utf8)
        XCTAssertNil(request(token: nil, code: code))
        XCTAssertNil(request(token: token, code: nil))
        XCTAssertNil(request(token: Data(), code: code))
        XCTAssertNil(request(token: token, code: Data()))
        XCTAssertNil(request(token: Data([0xff, 0xfe]), code: code), "not UTF-8")
        XCTAssertNil(request(token: token, code: code, challenge: ""))
    }

    func testTheSitesTicketComesOutOfA200() {
        XCTAssertEqual(AppleSignInExchange.ticket(status: 200, body: json(#"{"ticket":"\#(ticket)"}"#)), ticket)
        XCTAssertEqual(AppleSignInExchange.ticket(status: 200, body: json(#"{"ticket":"\#(ticket)","extra":1}"#)), ticket)
    }

    func testAnythingElseHasNoTicket() {
        let good = json(#"{"ticket":"\#(ticket)"}"#)
        for status in [nil, 201, 204, 302, 400, 401, 422, 429, 500] as [Int?] {
            XCTAssertNil(AppleSignInExchange.ticket(status: status, body: good), String(describing: status))
        }
        for body in ["", "not json", "null", "[]", #"["\#(ticket)"]"#, "{}", #"{"ticket":null}"#, #"{"ticket":42}"#,
                     #"{"ticket":"short"}"#, #"{"ticket":"\#(ticket)x"}"#, #"{"ticket":"\#(ticket)\n"}"#,
                     #"{"ticket":"\#(ticket)&verifier=x"}"#, #"{"error":"failed"}"#] {
            XCTAssertNil(AppleSignInExchange.ticket(status: 200, body: json(body)), body)
        }
        XCTAssertNil(AppleSignInExchange.ticket(status: 200, body: nil))
    }

    func testFailedIsTheSitesExactFailedPage() {
        let failed = AppleSignInExchange.failedLocation(rootURL: root)
        XCTAssertEqual(failed.absoluteString, "https://calcpace.app/app_auth/failed")
        XCTAssertTrue(AppAuthPaths.isFailed(failed.absoluteString))
    }

    func testATicketGoesToTheRedeemAndAnythingElseToFailed() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppleSignInExchangeTests"))
        defer { defaults.removePersistentDomain(forName: "AppleSignInExchangeTests") }
        let auth = AppAuth(rootURL: root, defaults: defaults)
        let failed = URL(string: "https://calcpace.app/app_auth/failed")!

        XCTAssertEqual(AppleSignInExchange.destination(ticket: ticket, rootURL: root, redeem: auth.redeemLocation), failed,
                       "no sign-in of ours waiting")

        XCTAssertNotNil(auth.beginApple())
        XCTAssertEqual(AppleSignInExchange.destination(ticket: nil, rootURL: root, redeem: auth.redeemLocation), failed)
        let redeem = AppleSignInExchange.destination(ticket: ticket, rootURL: root, redeem: auth.redeemLocation)
        XCTAssertTrue(AppAuthPaths.isRedeem(redeem.absoluteString), redeem.absoluteString)
        XCTAssertTrue(auth.takeExpectedRedeem(redeem), "the one redeem the route handler lets through")
    }
}
