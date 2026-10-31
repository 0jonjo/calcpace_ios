import Foundation
import UserNotifications

/// The answer the site's push bridge component gets: whether this phone will
/// show "your run is in" notifications, and whether it is worth asking. The
/// same words as the Android app's PushStatus, which the page
/// (push_controller.js) reads:
///
/// - "granted": the athlete allowed notifications (provisional and ephemeral
///   ones included: they are delivered). Only then is there a device token
///   to hand over.
/// - "default": never asked. The system would still show its prompt, so the
///   site may show its card.
/// - "denied": the athlete said no, at the prompt or later in Settings; only
///   Settings can change that, and the card stays hidden.
///
/// iOS asks once: after a "Don't Allow" the prompt never comes back, unlike
/// Android's. A status iOS adds later counts as denied, so the card stays
/// hidden rather than offering a prompt that may not exist.
enum PushStatus {
    static let granted = "granted"
    static let notAsked = "default"
    static let denied = "denied"

    static func of(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return granted
        case .notDetermined:
            return notAsked
        case .denied:
            return denied
        @unknown default:
            return denied
        }
    }
}

/// The APNs device token as the server sends to it: the bytes iOS hands
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, in
/// lowercase hex (32 bytes today, 64 characters; Apple says the length may
/// change, so nothing here assumes it).
enum PushToken {
    static func hex(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }
}
